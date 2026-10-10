import CoreMedia
import EditorCore
import SwiftUI

enum TimelineMetrics {
    static let rulerHeight: CGFloat = 24
    static let trackHeight: CGFloat = 64
    static let headerWidth: CGFloat = 72
    /// Extra empty space after the last clip, in seconds.
    static let tailPadding: Double = 30
}

/// Full-width timeline: track headers on the left, scrollable ruler and
/// track lanes on the right, playhead on top.
struct TimelineView: View {
    @ObservedObject var document: ProjectDocument
    var session: EditorSession

    var body: some View {
        HStack(spacing: 0) {
            TrackHeaders(tracks: document.project.tracks)
                .frame(width: TimelineMetrics.headerWidth)
            Divider()
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    lanes(minWidth: geometry.size.width)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func lanes(minWidth: CGFloat) -> some View {
        let pps = session.pixelsPerSecond
        let contentSeconds = document.project.duration.seconds + TimelineMetrics.tailPadding
        let width = max(minWidth, contentSeconds * pps)

        return ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                TimeRulerView(pixelsPerSecond: pps, width: width) { x in
                    session.playback.seek(to: .seconds(max(0, x) / pps))
                }
                .frame(height: TimelineMetrics.rulerHeight)
                Divider()
                ForEach(document.project.tracks) { track in
                    TrackLaneView(track: track, session: session, width: width)
                    Divider()
                }
            }
            PlayheadView(height: TimelineMetrics.rulerHeight + CGFloat(document.project.tracks.count) * (TimelineMetrics.trackHeight + 1))
                .offset(x: session.playback.currentTime.seconds * pps)
                .allowsHitTesting(false)
        }
        .frame(width: width, alignment: .topLeading)
    }
}

private struct TrackHeaders: View {
    let tracks: [Track]

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: TimelineMetrics.rulerHeight)
            Divider()
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                HStack {
                    Image(systemName: track.kind == .audio ? "waveform" : "film")
                    Text(label(for: track, index: index))
                        .font(.caption.bold())
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: TimelineMetrics.trackHeight, maxHeight: TimelineMetrics.trackHeight)
                Divider()
            }
            Spacer(minLength: 0)
        }
    }

    private func label(for track: Track, index: Int) -> String {
        switch track.kind {
        case .video: "V\(index + 1)"
        case .audio: "A\(index + 1)"
        case .overlay: "O\(index + 1)"
        }
    }
}

private struct TrackLaneView: View {
    let track: Track
    var session: EditorSession
    let width: CGFloat
    @State private var isDropTargeted = false

    var body: some View {
        let pps = session.pixelsPerSecond
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(isDropTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    session.selection = []
                    session.playback.seek(to: .seconds(location.x / pps))
                }

            ForEach(track.clips) { clip in
                ClipView(
                    clip: clip,
                    media: session.project.mediaRef(id: clip.mediaID),
                    thumbnail: session.thumbnails.images[clip.mediaID],
                    isSelected: session.selection.contains(clip.id)
                )
                .frame(width: max(2, clip.duration.seconds * pps), height: TimelineMetrics.trackHeight - 8)
                .offset(x: clip.timelineStart.seconds * pps, y: 4)
                .onTapGesture {
                    session.select(clip.id, extending: NSEvent.modifierFlags.contains(.command))
                }
            }
        }
        .frame(width: width, height: TimelineMetrics.trackHeight)
        .dropDestination(for: String.self) { items, location in
            guard track.kind == .video else { return false }
            let ids = items.compactMap(UUID.init(uuidString:))
            for id in ids.reversed() {
                session.addToTimeline(id, near: .seconds(max(0, location.x) / pps))
            }
            return !ids.isEmpty
        } isTargeted: {
            isDropTargeted = $0
        }
    }
}

private struct PlayheadView: View {
    let height: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 10))
                .foregroundStyle(.red)
                .frame(width: 11, height: 10)
            Rectangle()
                .fill(.red)
                .frame(width: 1, height: max(0, height - 10))
        }
        .offset(x: -5.5)
    }
}
