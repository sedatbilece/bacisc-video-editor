import CoreMedia
import EditorCore
import SwiftUI

enum TimelineMetrics {
    static let rulerHeight: CGFloat = 24
    static let trackHeight: CGFloat = 64
    /// Track height plus the divider below it.
    static let rowHeight: CGFloat = trackHeight + 1
    static let headerWidth: CGFloat = 96
    /// Extra empty space after the last clip, in seconds.
    static let tailPadding: Double = 30
}

/// Full-width timeline: track headers on the left, scrollable ruler and
/// track lanes on the right, playhead on top.
struct TimelineView: View {
    @ObservedObject var document: ProjectDocument
    var session: EditorSession

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    TrackHeaders(tracks: document.project.tracks, session: session)
                        .frame(width: TimelineMetrics.headerWidth)
                    Divider()
                    ScrollView(.horizontal) {
                        lanes(minWidth: geometry.size.width - TimelineMetrics.headerWidth - 1)
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func lanes(minWidth: CGFloat) -> some View {
        let pps = session.pixelsPerSecond
        let tracks = document.project.tracks
        let contentSeconds = document.project.duration.seconds + TimelineMetrics.tailPadding
        let width = max(minWidth, contentSeconds * pps)

        return ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                TimeRulerView(pixelsPerSecond: pps, width: width) { x in
                    session.playback.seek(to: .seconds(max(0, x) / pps))
                }
                .frame(height: TimelineMetrics.rulerHeight)
                Divider()
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    TrackLaneView(track: track, session: session, width: width) { clip, translation in
                        let rows = Int((translation.height / TimelineMetrics.rowHeight).rounded())
                        let target = tracks[min(max(index + rows, 0), tracks.count - 1)]
                        let start = max(0, clip.timelineStart.seconds + translation.width / pps)
                        session.moveClip(clip.id, toTrack: target.id, start: .seconds(start))
                    }
                    Divider()
                }
            }
            PlayheadView(height: TimelineMetrics.rulerHeight + 1 + CGFloat(tracks.count) * TimelineMetrics.rowHeight)
                .offset(x: session.playback.currentTime.seconds * pps)
                .allowsHitTesting(false)
        }
        .frame(width: width, alignment: .topLeading)
    }
}

private struct TrackHeaders: View {
    let tracks: [Track]
    var session: EditorSession

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: TimelineMetrics.rulerHeight)
            Divider()
            ForEach(tracks) { track in
                HStack(spacing: 6) {
                    Image(systemName: track.kind == .audio ? "waveform" : "film")
                    Text(label(for: track))
                        .font(.caption.bold())
                    Spacer(minLength: 0)
                    Button {
                        session.toggleMute(track.id)
                    } label: {
                        Image(systemName: track.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .foregroundStyle(track.isMuted ? .red : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(track.isMuted ? "Unmute track" : "Mute track")
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: TimelineMetrics.trackHeight)
                Divider()
            }
            Button {
                session.addAudioTrack()
            } label: {
                Label("Audio Track", systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .padding(.vertical, 8)
        }
    }

    /// "V1", "A1", "A2"… numbered per track kind.
    private func label(for track: Track) -> String {
        let sameKind = tracks.filter { $0.kind == track.kind }
        let number = (sameKind.firstIndex { $0.id == track.id } ?? 0) + 1
        switch track.kind {
        case .video: return "V\(number)"
        case .audio: return "A\(number)"
        case .overlay: return "O\(number)"
        }
    }
}

private struct TrackLaneView: View {
    let track: Track
    var session: EditorSession
    let width: CGFloat
    let onMove: (Clip, CGSize) -> Void
    @State private var isDropTargeted = false

    var body: some View {
        let pps = session.pixelsPerSecond
        let project = session.project
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(isDropTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    session.selection = []
                    session.playback.seek(to: .seconds(location.x / pps))
                }

            ForEach(track.clips) { clip in
                let media = project.mediaRef(id: clip.mediaID)
                ClipView(
                    clip: clip,
                    trackKind: track.kind,
                    media: media,
                    isOffline: media.map(session.assets.isOffline) ?? true,
                    thumbnail: session.thumbnails.images[clip.mediaID],
                    peaks: session.waveforms.peaks[clip.mediaID],
                    isSelected: session.selection.contains(clip.id),
                    pixelsPerSecond: pps,
                    onSelect: { session.select(clip.id, extending: $0) },
                    onMove: { onMove(clip, $0) },
                    onTrim: { edge, dx in
                        let base = edge == .leading ? clip.timelineStart : clip.timelineEnd
                        session.trimClip(clip.id, edge: edge, to: base + .seconds(dx / pps))
                    }
                )
                .contextMenu { contextMenu(for: clip) }
                .task(id: media?.path) {
                    if let media { await session.waveforms.load(media, from: session.assets) }
                }
            }
        }
        .frame(width: width, height: TimelineMetrics.trackHeight, alignment: .topLeading)
        .dropDestination(for: String.self) { items, location in
            let ids = items.compactMap(UUID.init(uuidString:))
            for id in ids.reversed() {
                session.addToTimeline(id, track: track.id, near: .seconds(max(0, location.x) / pps))
            }
            return !ids.isEmpty
        } isTargeted: {
            isDropTargeted = $0
        }
    }

    @ViewBuilder
    private func contextMenu(for clip: Clip) -> some View {
        let project = session.project
        let time = session.playback.currentTime
        Button("Split at Playhead") {
            session.selection = [clip.id]
            session.splitAtPlayhead()
        }
        .disabled(!(clip.timelineStart < time && time < clip.timelineEnd))

        Button("Detach Audio") { session.detachAudio([clip.id]) }
            .disabled(!project.canDetachAudio(clip.id))

        Button("Unlink") { session.unlink([clip.id]) }
            .disabled(!project.isLinked(clip.id))

        Divider()

        Button("Delete", role: .destructive) { session.delete([clip.id]) }
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
