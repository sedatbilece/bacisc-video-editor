import CoreGraphics
import EditorCore

/// Where a visual clip lands in the frame. Shared by the composition builder and the preview handles.
struct LayerGeometry {
    /// Size of the unscaled content (y down).
    let contentSize: CGSize
    let baseScale: Double
    /// Maps content into render coordinates (y down).
    let matrix: CGAffineTransform

    /// Nil for clips that draw nothing (audio or unsized media).
    init?(clip: Clip, in project: Project, transform: ClipTransform? = nil) {
        guard let natural = Self.contentSize(of: clip, in: project), natural.width > 0, natural.height > 0 else { return nil }
        let transform = transform ?? clip.transform
        // Square crop applies to media only; text keeps its own box.
        let size = clip.text == nil ? transform.croppedSize(natural) : natural
        let renderSize = project.settings.renderSize
        let isMain = project.location(ofClip: clip.id)?.track == project.mainTrackIndex
        contentSize = size
        baseScale = ClipTransform.baseScale(
            isText: clip.text != nil,
            isMainTrack: isMain,
            contentSize: size,
            renderSize: renderSize
        )
        matrix = transform.matrix(contentSize: size, renderSize: renderSize, baseScale: baseScale)
    }

    /// Corners of the content in render coordinates, clockwise from top-left.
    var corners: [CGPoint] {
        [
            CGPoint(x: 0, y: 0),
            CGPoint(x: contentSize.width, y: 0),
            CGPoint(x: contentSize.width, y: contentSize.height),
            CGPoint(x: 0, y: contentSize.height),
        ].map { $0.applying(matrix) }
    }

    /// True when a render-space point falls on the content.
    func contains(_ point: CGPoint) -> Bool {
        CGRect(origin: .zero, size: contentSize).contains(point.applying(matrix.inverted()))
    }

    private static func contentSize(of clip: Clip, in project: Project) -> CGSize? {
        if let text = clip.text { return TextRenderer.size(for: text) }
        guard let media = project.mediaRef(id: clip.mediaID), media.kind != .audio else { return nil }
        return media.naturalSize
    }
}
