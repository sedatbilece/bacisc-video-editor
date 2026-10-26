import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import EditorCore
import Foundation
import Metal

/// What a layer draws: a composition video track, a ready-made image (still or rendered text) or a subtitle drawn on demand.
nonisolated enum LayerContent: @unchecked Sendable {
    case video(trackID: CMPersistentTrackID, preferredTransform: CGAffineTransform)
    case image(CIImage)
    case subtitle(text: String, style: SubtitleStyle, renderWidth: CGFloat, scale: CGFloat)
}

/// One visual clip inside an instruction. Geometry is precomputed by the builder.
nonisolated struct CompositionLayer: @unchecked Sendable {
    let clip: Clip
    let content: LayerContent
    let contentSize: CGSize
    let baseScale: Double
    /// The transform's position is the bottom center of the content (subtitles), not its center.
    var anchorsBottom = false
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
    /// The project frame size layers are laid out in; scaled to the render size when exporting at another resolution.
    let layoutSize: CGSize

    init(timeRange: CMTimeRange, layers: [CompositionLayer], liveTransforms: LiveTransforms, layoutSize: CGSize) {
        self.timeRange = timeRange
        self.layers = layers
        self.layoutSize = layoutSize
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
            let layoutSize = instruction.layoutSize
            let frame = CGRect(origin: .zero, size: renderSize)
            var output = CIImage(color: .black).cropped(to: frame)
            let toOutput = layoutSize.width > 0 && layoutSize.height > 0
                ? CGAffineTransform(scaleX: renderSize.width / layoutSize.width, y: renderSize.height / layoutSize.height)
                : .identity

            for layer in instruction.layers {
                guard var image = normalizedImage(for: layer, request: request) else { continue }
                var clip = layer.clip
                clip.transform = instruction.liveTransforms.transform(for: clip.id) ?? clip.transform
                if layer.anchorsBottom, layoutSize.height > 0 {
                    clip.transform.position.y -= layer.contentSize.height / 2 / layoutSize.height
                }
                let alpha = clip.opacity(at: request.compositionTime)
                guard alpha > 0.001 else { continue }
                image = Self.rounded(image, size: layer.contentSize, cornerRadius: clip.transform.cornerRadius)

                let matrix = clip.transform
                    .matrix(contentSize: layer.contentSize, renderSize: layoutSize, baseScale: layer.baseScale)
                    .concatenating(toOutput)
                var placed = Self.transformed(image, by: Self.flipped(matrix, contentHeight: layer.contentSize.height, renderHeight: renderSize.height))
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
        case .subtitle(let text, let style, let renderWidth, let scale):
            guard let bitmap = SubtitleRenderer.image(for: text, style: style, renderWidth: renderWidth, scale: scale) else { return nil }
            image = CIImage(cgImage: bitmap)
        case .video(let trackID, let preferredTransform):
            guard let buffer = request.sourceFrame(byTrackID: trackID) else { return nil }
            image = Self.oriented(CIImage(cvPixelBuffer: buffer), preferredTransform)
        }
        var extent = image.extent
        guard extent.width > 0, extent.height > 0, !extent.isInfinite else { return nil }
        // Square crop is decided at build time; `contentSize` is already square then.
        if layer.clip.text == nil, layer.clip.transform.squareCrop {
            let side = min(extent.width, extent.height)
            extent = CGRect(x: extent.midX - side / 2, y: extent.midY - side / 2, width: side, height: side)
            image = image.cropped(to: extent)
        }
        return image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
            .concatenating(CGAffineTransform(
                scaleX: layer.contentSize.width / extent.width,
                y: layer.contentSize.height / extent.height
            )))
    }

    /// Applies `matrix`; when it shrinks the image, downsamples with Lanczos first.
    /// A plain affine transform samples bilinearly, which aliases fine detail such as screen text.
    private static func transformed(_ image: CIImage, by matrix: CGAffineTransform) -> CIImage {
        let scaleX = hypot(matrix.a, matrix.b)
        let scaleY = hypot(matrix.c, matrix.d)
        guard scaleX > 0, scaleY > 0, min(scaleX, scaleY) < 0.95 else { return image.transformed(by: matrix) }
        let downsampled = image.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: scaleY,
            kCIInputAspectRatioKey: scaleX / scaleY,
        ])
        return downsampled.transformed(by: CGAffineTransform(scaleX: 1 / scaleX, y: 1 / scaleY).concatenating(matrix))
    }

    /// Masks the content (origin at zero, `size`) to a rounded rectangle; radius is a fraction of the short side.
    private static func rounded(_ image: CIImage, size: CGSize, cornerRadius: Double) -> CIImage {
        guard cornerRadius > 0 else { return image }
        let radius = CGFloat(cornerRadius) * min(size.width, size.height)
        guard let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: CGRect(origin: .zero, size: size)),
            "inputRadius": radius,
            "inputColor": CIColor.white,
        ])?.outputImage else { return image }
        return image.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask,
        ])
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
