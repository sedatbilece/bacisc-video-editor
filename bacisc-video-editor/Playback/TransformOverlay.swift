import AppKit
import CoreGraphics
import CoreMedia
import EditorCore
import SwiftUI

/// Drawn over the preview: click selects the layer under the pointer; the selected layer
/// gets a box to move, corner handles to scale and a top handle to rotate. Moving snaps to the
/// frame edges and center and to other layers, with guide lines.
/// On the Subtitles inspector tab the subtitle box is shown instead and can be dragged.
struct TransformOverlay: View {
    var session: EditorSession
    @State private var drag: DragState?
    @State private var guides: [Guide] = []

    /// A snap line in render coordinates.
    enum Guide: Hashable {
        case vertical(CGFloat)
        case horizontal(CGFloat)
    }

    private struct DragState {
        let clipID: Clip.ID
        let start: ClipTransform
        var current: ClipTransform
    }

    private enum Handle {
        case move, scale, rotate
    }

    fileprivate static let space = "transformOverlay"
    private static let rotateHandleDistance: CGFloat = 24

    var body: some View {
        GeometryReader { geometry in
            let renderSize = session.frameSize
            let frame = Self.videoRect(renderSize, in: geometry.size)
            let k = frame.width / max(renderSize.width, 1)
            let toView = CGAffineTransform(scaleX: k, y: k).concatenating(CGAffineTransform(translationX: frame.minX, y: frame.minY))

            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .named(Self.space)) { location in
                        select(at: location, toView: toView)
                    }

                FrameOutline(
                    frame: frame,
                    title: frameTitle(renderSize),
                    overflows: overflows(renderSize),
                    showsTitle: !session.playback.isPlaying
                )

                if session.inspectorTab == .subtitles {
                    SubtitleHandle(session: session, toView: toView, k: k, renderSize: renderSize)
                } else if let clip = session.selectedLayer,
                   let layer = LayerGeometry(clip: clip, in: session.project, format: session.activeFormat, transform: transform(of: clip)) {
                    handles(for: clip, layer: layer, toView: toView, k: k, renderSize: renderSize)
                }

                GuideLines(guides: guides, renderSize: renderSize, toView: toView)
            }
            .coordinateSpace(.named(Self.space))
        }
    }

    @ViewBuilder
    private func handles(for clip: Clip, layer: LayerGeometry, toView: CGAffineTransform, k: CGFloat, renderSize: CGSize) -> some View {
        let corners = layer.corners.map { $0.applying(toView) }
        let center = CGPoint(
            x: corners.map(\.x).reduce(0, +) / 4,
            y: corners.map(\.y).reduce(0, +) / 4
        )
        let topMid = CGPoint(x: (corners[0].x + corners[1].x) / 2, y: (corners[0].y + corners[1].y) / 2)
        let rotateHandle = Self.point(from: center, through: topMid, extendedBy: Self.rotateHandleDistance)
        let outline = Path { path in
            path.addLines(corners)
            path.closeSubpath()
        }

        outline
            .fill(Color.white.opacity(0.001))
            .contentShape(outline)
            .onTapGesture(coordinateSpace: .named(Self.space)) { location in
                select(at: location, toView: toView)
            }
            .gesture(dragGesture(.move, clip: clip, center: center, k: k, renderSize: renderSize))
            .pointerStyle(.grabIdle)

        outline
            .stroke(Color.accentColor, lineWidth: 1.5)
            .allowsHitTesting(false)

        Path { path in
            path.move(to: topMid)
            path.addLine(to: rotateHandle)
        }
        .stroke(Color.accentColor, lineWidth: 1)
        .allowsHitTesting(false)

        ForEach(0..<4, id: \.self) { index in
            Rectangle()
                .fill(.white)
                .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1))
                .frame(width: 9, height: 9)
                .position(corners[index])
                .gesture(dragGesture(.scale, clip: clip, center: center, k: k, renderSize: renderSize))
                .help("Drag to scale")
        }

        Circle()
            .fill(.white)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 1))
            .frame(width: 11, height: 11)
            .position(rotateHandle)
            .gesture(dragGesture(.rotate, clip: clip, center: center, k: k, renderSize: renderSize))
            .help("Drag to rotate (Shift snaps to 15°)")
    }

    private func dragGesture(_ handle: Handle, clip: Clip, center: CGPoint, k: CGFloat, renderSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let start = drag?.clipID == clip.id ? drag!.start : session.layout(of: clip).transform
                var next = start
                switch handle {
                case .move:
                    next.position.x = start.position.x + value.translation.width / k / renderSize.width
                    next.position.y = start.position.y + value.translation.height / k / renderSize.height
                    let snap = snapped(next, clip: clip, tolerance: 6 / k, renderSize: renderSize)
                    next = snap.0
                    guides = snap.1
                case .scale:
                    let from = Self.distance(center, value.startLocation)
                    guard from > 1 else { return }
                    let scale = start.scale * Self.distance(center, value.location) / from
                    next.scale = min(max(scale, ClipTransform.scaleRange.lowerBound), ClipTransform.scaleRange.upperBound)
                case .rotate:
                    var degrees = start.rotation + (Self.angle(center, value.location) - Self.angle(center, value.startLocation))
                    degrees = Self.normalized(degrees)
                    if NSEvent.modifierFlags.contains(.shift) { degrees = (degrees / 15).rounded() * 15 }
                    next.rotation = degrees
                }
                drag = DragState(clipID: clip.id, start: start, current: next)
                session.previewTransform(next, for: clip.id)
            }
            .onEnded { _ in
                guides = []
                guard let drag, drag.clipID == clip.id else { return }
                self.drag = nil
                session.commitTransform(drag.current, for: clip.id)
            }
    }

    /// Moves the layer so its edges or center line up with the frame or another layer within `tolerance` (render px).
    private func snapped(_ transform: ClipTransform, clip: Clip, tolerance: CGFloat, renderSize: CGSize) -> (ClipTransform, [Guide]) {
        guard session.isSnapping,
              let geometry = LayerGeometry(clip: clip, in: session.project, format: session.activeFormat, transform: transform),
              renderSize.width > 0, renderSize.height > 0
        else { return (transform, []) }
        let box = geometry.bounds
        let others = session.layerBounds(excluding: clip.id)
        var result = transform
        var guides: [Guide] = []

        let xTargets: [CGFloat] = [0, renderSize.width / 2, renderSize.width] + others.flatMap { [$0.minX, $0.midX, $0.maxX] }
        if let snap = Self.nearest(edges: [box.minX, box.midX, box.maxX], targets: xTargets, tolerance: tolerance) {
            result.position.x += snap.offset / renderSize.width
            guides.append(.vertical(snap.target))
        }
        let yTargets: [CGFloat] = [0, renderSize.height / 2, renderSize.height] + others.flatMap { [$0.minY, $0.midY, $0.maxY] }
        if let snap = Self.nearest(edges: [box.minY, box.midY, box.maxY], targets: yTargets, tolerance: tolerance) {
            result.position.y += snap.offset / renderSize.height
            guides.append(.horizontal(snap.target))
        }
        return (result, guides)
    }

    /// The smallest shift within `tolerance` that puts an edge on a target.
    fileprivate static func nearest(edges: [CGFloat], targets: [CGFloat], tolerance: CGFloat) -> (offset: CGFloat, target: CGFloat)? {
        var best: (offset: CGFloat, target: CGFloat)?
        for edge in edges {
            for target in targets {
                let offset = target - edge
                if abs(offset) <= tolerance, abs(offset) < abs(best?.offset ?? .infinity) {
                    best = (offset, target)
                }
            }
        }
        return best
    }

    /// "16:9 · 1920×1080"; frames without a format show their ratio as "1.54:1".
    private func frameTitle(_ size: CGSize) -> String {
        let project = session.project
        let format = project.layoutFormat(session.activeFormat) ?? project.settings.aspect
        let ratio = format?.title ?? String(format: "%.2f:1", size.width / max(size.height, 1))
        return "\(ratio) · \(Int(size.width))×\(Int(size.height))"
    }

    /// True when a layer under the playhead reaches past the frame, so export crops it.
    private func overflows(_ renderSize: CGSize) -> Bool {
        let frame = CGRect(origin: .zero, size: renderSize).insetBy(dx: -1, dy: -1)
        return session.visibleLayers.contains { clip in
            guard let geometry = LayerGeometry(clip: clip, in: session.project, format: session.activeFormat, transform: transform(of: clip))
            else { return false }
            return !frame.contains(geometry.bounds)
        }
    }

    /// The transform to draw: the in-progress drag, or the one of the active format.
    private func transform(of clip: Clip) -> ClipTransform {
        drag?.clipID == clip.id ? drag!.current : session.layout(of: clip).transform
    }

    private func select(at location: CGPoint, toView: CGAffineTransform) {
        let point = location.applying(toView.inverted())
        if let id = session.layerClip(at: point) {
            session.selection = [id]
        } else {
            session.selection = []
        }
    }

    /// Where the render frame sits inside the view (aspect fit, centered), like the player's video gravity.
    private static func videoRect(_ renderSize: CGSize, in size: CGSize) -> CGRect {
        guard renderSize.width > 0, renderSize.height > 0 else { return CGRect(origin: .zero, size: size) }
        let scale = min(size.width / renderSize.width, size.height / renderSize.height)
        let width = renderSize.width * scale
        let height = renderSize.height * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        Double(hypot(b.x - a.x, b.y - a.y))
    }

    /// Angle in degrees, clockwise on screen (y down).
    private static func angle(_ center: CGPoint, _ point: CGPoint) -> Double {
        Double(atan2(point.y - center.y, point.x - center.x)) * 180 / .pi
    }

    private static func normalized(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value < -180 { value += 360 }
        return value
    }

    /// A point beyond `through`, on the line from `from`, by `distance`.
    private static func point(from: CGPoint, through: CGPoint, extendedBy distance: CGFloat) -> CGPoint {
        let dx = through.x - from.x
        let dy = through.y - from.y
        let length = max(hypot(dx, dy), 0.001)
        return CGPoint(x: through.x + dx / length * distance, y: through.y + dy / length * distance)
    }
}

/// Dashed box around the subtitle at the playhead (or a sample when none); dragging moves all subtitles.
private struct SubtitleHandle: View {
    var session: EditorSession
    let toView: CGAffineTransform
    let k: CGFloat
    let renderSize: CGSize
    @State private var dragStart: CGPoint?
    @State private var livePosition: CGPoint?
    @State private var centerGuide = false

    var body: some View {
        if let subtitles = session.project.subtitles, subtitles.isVisible {
            let style = subtitles.style
            let text = session.project.subtitleCue(at: session.playback.currentTime)?.text ?? "Subtitle"
            let size = SubtitleRenderer.size(for: text, style: style, renderWidth: renderSize.width)
            let position = livePosition ?? style.position
            // The position is the bottom center of the box.
            let rect = CGRect(
                x: renderSize.width * (0.5 + position.x) - size.width / 2,
                y: renderSize.height * (0.5 + position.y) - size.height,
                width: size.width,
                height: size.height
            ).applying(toView)

            Rectangle()
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                .contentShape(Rectangle())
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .gesture(drag(from: style.position))
                .pointerStyle(.grabIdle)
                .help("Drag to move the subtitles")

            GuideLines(guides: centerGuide ? [.vertical(renderSize.width / 2)] : [], renderSize: renderSize, toView: toView)
        }
    }

    private func drag(from position: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(TransformOverlay.space))
            .onChanged { value in
                let start = dragStart ?? position
                dragStart = start
                var next = CGPoint(
                    x: min(max(start.x + value.translation.width / k / renderSize.width, -0.5), 0.5),
                    y: min(max(start.y + value.translation.height / k / renderSize.height, -0.5), 0.5)
                )
                // Snaps the box center to the frame center.
                centerGuide = session.isSnapping && abs(next.x * renderSize.width) <= 6 / k
                if centerGuide { next.x = 0 }
                livePosition = next
                session.previewSubtitlePosition(next)
            }
            .onEnded { _ in
                centerGuide = false
                if let livePosition { session.commitSubtitlePosition(livePosition) }
                dragStart = nil
                livePosition = nil
            }
    }
}

/// Snap guide lines across the frame.
private struct GuideLines: View {
    let guides: [TransformOverlay.Guide]
    let renderSize: CGSize
    let toView: CGAffineTransform

    var body: some View {
        Path { path in
            for guide in guides {
                switch guide {
                case .vertical(let x):
                    path.move(to: CGPoint(x: x, y: 0).applying(toView))
                    path.addLine(to: CGPoint(x: x, y: renderSize.height).applying(toView))
                case .horizontal(let y):
                    path.move(to: CGPoint(x: 0, y: y).applying(toView))
                    path.addLine(to: CGPoint(x: renderSize.width, y: y).applying(toView))
                }
            }
        }
        .stroke(Color.pink, lineWidth: 1)
        .allowsHitTesting(false)
    }
}

/// Outline of the export frame with its format and size; red when a layer is cropped by it.
private struct FrameOutline: View {
    let frame: CGRect
    let title: String
    let overflows: Bool
    let showsTitle: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(overflows ? Color.red : Color.white.opacity(0.35), lineWidth: overflows ? 2 : 1)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
            if showsTitle {
                Text(overflows ? "\(title) · cropped" : title)
                    .font(.caption2.monospacedDigit().bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(overflows ? Color.red : Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                    .offset(x: frame.minX + 4, y: frame.minY + 4)
            }
        }
        .allowsHitTesting(false)
    }
}
