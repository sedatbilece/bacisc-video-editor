import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import EditorCore
import Foundation
import Metal

/// What a layer draws: a composition video track or a ready-made image (still or rendered text).
nonisolated enum LayerContent: @unchecked Sendable {
    case video(trackID: CMPersistentTrackID, preferredTransform: CGAffineTransform)
    case image(CIImage)
}

/// One visual clip inside an instruction. Geometry is precomputed by the builder.
nonisolated struct CompositionLayer: @unchecked Sendable {
    let clip: Clip
    let content: LayerContent
    let contentSize: CGSize
    let baseScale: Double
}

/// Transforms being dragged in the preview. The compositor reads them so the frame
/// follows the drag before the edit is committed.
nonisolated final class LiveTransforms: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Clip.ID: ClipTransform] = [:]

    func set(_ transform: ClipTransform?, for id: Clip.ID) {
        lock.withLock { values[id] = transform }
    }

    func removeAll() {
        lock.withLock { values.removeAll() }
    }

    func transform(for id: Clip.ID) -> ClipTransform? {
        lock.withLock { values[id] }
    }
}

/// The layers visible during one time range, back to front.
nonisolated final class CompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let layers: [CompositionLayer]
    let liveTransforms: LiveTransforms

    init(timeRange: CMTimeRange, layers: [CompositionLayer], liveTransforms: LiveTransforms) {
        self.timeRange = timeRange
        self.layers = layers
        self.liveTransforms = liveTransforms
        requiredSourceTrackIDs = layers.compactMap { layer -> NSValue? in
            guard case .video(let trackID, _) = layer.content else { return nil }
            return NSNumber(value: trackID)
        }
        super.init()
    }
}

/// Custom compositor: draws each instruction's layers over black with Core Image on Metal.
nonisolated final class LayerCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private static let pixelAttributes: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    let sourcePixelBufferAttributes: [String: any Sendable]? = LayerCompositor.pixelAttributes
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = LayerCompositor.pixelAttributes

    private let queue = DispatchQueue(label: "bacisc.compositor", qos: .userInteractive)
    // Color management off: video and text pixels pass through unchanged.
    private let context: CIContext = {
        let options: [CIContextOption: Any] = [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
            .cacheIntermediates: false,
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }()

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            guard let instruction = request.videoCompositionInstruction as? CompositionInstruction,
                  let buffer = request.renderContext.newPixelBuffer()
            else {
                request.finish(with: AVError(.unknown))
                return
            }
            let renderSize = request.renderContext.size
            let frame = CGRect(origin: .zero, size: renderSize)
            var output = CIImage(color: .black).cropped(to: frame)

            for layer in instruction.layers {
                guard let image = normalizedImage(for: layer, request: request) else { continue }
                var clip = layer.clip
                clip.transform = instruction.liveTransforms.transform(for: clip.id) ?? clip.transform
                let alpha = clip.opacity(at: request.compositionTime)
                guard alpha > 0.001 else { continue }

                let matrix = clip.transform.matrix(contentSize: layer.contentSize, renderSize: renderSize, baseScale: layer.baseScale)
                var placed = image.transformed(by: Self.flipped(matrix, contentHeight: layer.contentSize.height, renderHeight: renderSize.height))
                if alpha < 0.999 {
                    placed = placed.applyingFilter("CIColorMatrix", parameters: [
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
                    ])
                }
                output = placed.composited(over: output)
            }

            context.render(output.cropped(to: frame), to: buffer, bounds: frame, colorSpace: nil)
            request.finish(withComposedVideoFrame: buffer)
        }
    }

    /// The layer's image, upright, with its origin at zero and scaled to the logical content size.
    private func normalizedImage(for layer: CompositionLayer, request: AVAsynchronousVideoCompositionRequest) -> CIImage? {
        var image: CIImage
        switch layer.content {
        case .image(let still):
            image = still
        case .video(let trackID, let preferredTransform):
            guard let buffer = request.sourceFrame(byTrackID: trackID) else { return nil }
            image = Self.oriented(CIImage(cvPixelBuffer: buffer), preferredTransform)
        }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, !extent.isInfinite else { return nil }
        return image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
            .concatenating(CGAffineTransform(
                scaleX: layer.contentSize.width / extent.width,
                y: layer.contentSize.height / extent.height
            )))
    }

    /// Applies a track's preferred transform (defined with y down) to a Core Image frame (y up).
    private static func oriented(_ image: CIImage, _ transform: CGAffineTransform) -> CIImage {
        guard !transform.isIdentity else { return image }
        let source = CGRect(origin: .zero, size: image.extent.size)
        let rotated = source.applying(transform)
        let matrix = flipY(height: source.height)
            .concatenating(transform)
            .concatenating(CGAffineTransform(translationX: -rotated.minX, y: -rotated.minY))
            .concatenating(flipY(height: rotated.height))
        return image.transformed(by: matrix)
    }

    /// Converts a y-down content-to-render matrix to Core Image's y-up coordinates.
    private static func flipped(_ matrix: CGAffineTransform, contentHeight: CGFloat, renderHeight: CGFloat) -> CGAffineTransform {
        flipY(height: contentHeight).concatenating(matrix).concatenating(flipY(height: renderHeight))
    }

    private static func flipY(height: CGFloat) -> CGAffineTransform {
        CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
    }
}
