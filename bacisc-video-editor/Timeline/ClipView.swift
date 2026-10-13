import AppKit
import CoreMedia
import EditorCore
import SwiftUI

/// A clip on a track lane. Positions itself, previews move/trim drags and reports them on release.
struct ClipView: View {
    let clip: Clip
    let trackKind: TrackKind
    let media: MediaRef?
    let isOffline: Bool
    let thumbnail: NSImage?
    let peaks: [Float]?
    let isSelected: Bool
    let pixelsPerSecond: Double
    let onSelect: (_ extending: Bool) -> Void
    let onMove: (CGSize) -> Void
    let onTrim: (TrimEdge, CGFloat) -> Void

    @State private var moveOffset: CGSize = .zero
    @State private var trimEdge: TrimEdge?
    @State private var trimOffset: CGFloat = 0

    private static let handleWidth: CGFloat = 6

    var body: some View {
        let frame = previewFrame
        let shape = RoundedRectangle(cornerRadius: 4)

        content
            .frame(width: frame.width, height: TimelineMetrics.trackHeight - 8)
            .background(background)
            .clipShape(shape)
            .overlay(shape.stroke(isSelected ? Color.yellow : Color.black.opacity(0.3), lineWidth: isSelected ? 2 : 1))
            .overlay(alignment: .leading) { trimHandle(.leading) }
            .overlay(alignment: .trailing) { trimHandle(.trailing) }
            .contentShape(shape)
            .offset(x: frame.x + moveOffset.width, y: 4 + moveOffset.height)
            .zIndex(moveOffset == .zero ? 0 : 1)
            .onTapGesture {
                onSelect(NSEvent.modifierFlags.contains(.command))
            }
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { moveOffset = $0.translation }
                    .onEnded { value in
                        moveOffset = .zero
                        onMove(value.translation)
                    }
            )
    }

    /// Clip position and width including an in-progress trim.
    private var previewFrame: (x: CGFloat, width: CGFloat) {
        var x = clip.timelineStart.seconds * pixelsPerSecond
        var width = clip.duration.seconds * pixelsPerSecond
        switch trimEdge {
        case .leading:
            x += trimOffset
            width -= trimOffset
        case .trailing:
            width += trimOffset
        case nil:
            break
        }
        return (x, max(2, width))
    }

    private var hasPlayableAudio: Bool {
        media?.hasAudio == true && !clip.isAudioDetached
    }

    private var background: Color {
        if isOffline { return .red.opacity(0.6) }
        if clip.text != nil { return .purple.opacity(0.7) }
        if media?.kind == .image { return .orange.opacity(0.7) }
        return trackKind == .audio ? .green.opacity(0.55) : .blue.opacity(0.7)
    }

    private var title: String {
        if let text = clip.text {
            return text.string.split(separator: "\n").first.map(String.init) ?? "Text"
        }
        return isOffline ? "Offline: \(media?.name ?? "missing media")" : media?.name ?? ""
    }

    @ViewBuilder
    private var content: some View {
        ZStack(alignment: .topLeading) {
            if trackKind != .audio, let thumbnail, !isOffline {
                HStack(spacing: 0) {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64)
                        .clipped()
                    Spacer(minLength: 0)
                }
            }

            if hasPlayableAudio, let peaks, !isOffline {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    WaveformView(peaks: peaks, sourceRange: clip.sourceRange, color: .white.opacity(0.6))
                        .frame(height: trackKind == .audio ? TimelineMetrics.trackHeight - 22 : 20)
                }
            }

            HStack(spacing: 4) {
                if isOffline {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                if clip.linkGroup != nil {
                    Image(systemName: "link")
                }
                if clip.text != nil {
                    Image(systemName: "textformat")
                }
                Text(title)
                    .lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 3))
            .padding(.leading, trackKind != .audio && thumbnail != nil ? 68 : 4)
            .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func trimHandle(_ edge: TrimEdge) -> some View {
        Rectangle()
            .fill(Color.white.opacity(isSelected ? 0.5 : 0.001))
            .frame(width: Self.handleWidth)
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        trimEdge = edge
                        trimOffset = value.translation.width
                    }
                    .onEnded { value in
                        trimEdge = nil
                        trimOffset = 0
                        onTrim(edge, value.translation.width)
                    }
            )
    }
}
