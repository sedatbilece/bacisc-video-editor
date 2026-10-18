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

    /// Visual tracks front to back, then audio tracks.
    private var displayTracks: [Track] {
        let project = document.project
        let visual = project.visualTrackIndices.reversed().map { project.tracks[$0] }
        return visual + project.tracks.filter { $0.kind == .audio }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    TrackHeaders(tracks: displayTracks, project: document.project, session: session)
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
        let tracks = displayTracks
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
    /// In display order.
    let tracks: [Track]
    let project: Project
    var session: EditorSession
    @State private var draggedTrack: Track.ID?
    @State private var dragOffset: CGFloat = 0
    @State private var trackToDelete: Track?

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: TimelineMetrics.rulerHeight)
            Divider()
            ForEach(tracks) { track in
                header(for: track)
                    .background(draggedTrack == track.id ? Color.accentColor.opacity(0.15) : Color.clear)
                    .offset(y: draggedTrack == track.id ? dragOffset : 0)
                    .zIndex(draggedTrack == track.id ? 1 : 0)
                    .gesture(reorderGesture(for: track), including: track.kind.isVisual ? .all : .subviews)
                    .help(help(for: track))
                    .contextMenu {
                        Button("Delete Track", role: .destructive) { requestDelete(track) }
                            .disabled(track.kind == .video)
                    }
                Divider()
            }
            HStack(spacing: 10) {
                Button {
                    session.addOverlayTrack()
                } label: {
                    Label("Video", systemImage: "plus")
                        .font(.caption)
                }
                .help("Add a video track for overlays")
                Button {
                    session.addAudioTrack()
                } label: {
                    Label("Audio", systemImage: "plus")
                        .font(.caption)
                }
                .help("Add an audio track")
            }
            .buttonStyle(.borderless)
            .padding(.vertical, 8)
        }
        .confirmationDialog(
            "Delete track \(trackToDelete.map(label) ?? "")?",
            isPresented: Binding(get: { trackToDelete != nil }, set: { if !$0 { trackToDelete = nil } }),
            presenting: trackToDelete
        ) { track in
            Button("Delete Track", role: .destructive) { session.deleteTrack(track.id) }
            Button("Cancel", role: .cancel) {}
        } message: { track in
            Text(track.clips.count == 1 ? "Its clip will be deleted too." : "Its \(track.clips.count) clips will be deleted too.")
        }
    }

    /// Empty tracks go right away; tracks with clips ask first.
    private func requestDelete(_ track: Track) {
        if track.clips.isEmpty {
            session.deleteTrack(track.id)
        } else {
            trackToDelete = track
        }
    }

    private func help(for track: Track) -> String {
        switch track.kind {
        case .video: return "Main track (magnetic). Drag up or down to change the layer order."
        case .overlay: return "Drag up or down to change the layer order."
        case .audio: return ""
        }
    }

    private func header(for track: Track) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon(for: track))
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
        .contentShape(Rectangle())
    }

    /// Dragging a visual track header up brings it forward, down sends it back.
    private func reorderGesture(for track: Track) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                draggedTrack = track.id
                dragOffset = value.translation.height
            }
            .onEnded { value in
                draggedTrack = nil
                dragOffset = 0
                let rows = Int((value.translation.height / TimelineMetrics.rowHeight).rounded())
                guard rows != 0, let position = project.visualTrackIndices.firstIndex(of: index(of: track)) else { return }
                session.moveVisualTrack(track.id, to: position - rows)
            }
    }

    private func index(of track: Track) -> Int {
        project.trackIndex(id: track.id) ?? -1
    }

    private func icon(for track: Track) -> String {
        switch track.kind {
        case .video: return "film.fill"
        case .overlay: return "square.stack.3d.up"
        case .audio: return "waveform"
        }
    }

    private func label(for track: Track) -> String {
        project.label(ofTrack: track.id)
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
                    isOffline: clip.text == nil && (media.map(session.assets.isOffline) ?? true),
                    thumbnail: clip.mediaID.flatMap { session.thumbnails.images[$0] },
                    peaks: clip.mediaID.flatMap { session.waveforms.peaks[$0] },
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
