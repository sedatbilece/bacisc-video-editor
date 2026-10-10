import AVFoundation
import EditorCore
import SwiftUI

/// Per-window editing state: selection, zoom, playback and the commands that
/// turn user actions into undoable document edits.
@Observable
final class EditorSession {
    let document: ProjectDocument
    let playback = PlaybackController()
    let assets = AssetCache()
    let thumbnails = ThumbnailCache()
    let waveforms = WaveformCache()

    var undoManager: UndoManager?
    var selection: Set<Clip.ID> = []
    var pixelsPerSecond: Double = 40
    var importError: String?

    init(document: ProjectDocument) {
        self.document = document
    }

    var project: Project { document.project }

    /// The selected clip when exactly one is selected.
    var selectedClip: Clip? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return project.clip(id: id)
    }

    // MARK: Split / delete

    /// Selected clips under the playhead, or the main-track clip when nothing is selected.
    private var splitTargets: [(clip: Clip.ID, track: Track.ID)] {
        let time = playback.currentTime
        let tracks = project.tracks.filter { track in
            selection.isEmpty ? track.id == project.mainTrackID : track.clips.contains { selection.contains($0.id) }
        }
        return tracks.compactMap { track in
            guard let index = track.clipIndex(at: time) else { return nil }
            let clip = track.clips[index]
            guard time > clip.timelineStart, selection.isEmpty || selection.contains(clip.id) else { return nil }
            return (clip: clip.id, track: track.id)
        }
    }

    var canSplit: Bool { !splitTargets.isEmpty }

    var canDelete: Bool { !selection.isEmpty }

    func splitAtPlayhead() {
        let targets = splitTargets
        guard !targets.isEmpty else { return }
        let time = playback.currentTime
        document.perform("Split", undoManager: undoManager) { project in
            for target in targets {
                project.split(at: time, onTrack: target.track)
            }
        }
    }

    func deleteSelection() {
        delete(selection)
    }

    func delete(_ ids: Set<Clip.ID>) {
        guard !ids.isEmpty else { return }
        document.perform("Delete", undoManager: undoManager) { project in
            project.rippleDelete(ids)
        }
        selection.subtract(ids)
    }

    func select(_ clipID: Clip.ID, extending: Bool) {
        if extending {
            if selection.contains(clipID) { selection.remove(clipID) } else { selection.insert(clipID) }
        } else {
            selection = [clipID]
        }
    }

    // MARK: Move / trim

    func moveClip(_ id: Clip.ID, toTrack trackID: Track.ID, start: CMTime) {
        document.perform("Move Clip", undoManager: undoManager) { project in
            project.moveClip(id, toTrack: trackID, start: start)
        }
    }

    func trimClip(_ id: Clip.ID, edge: TrimEdge, to time: CMTime) {
        document.perform("Trim Clip", undoManager: undoManager) { project in
            project.trim(id, edge: edge, to: time)
        }
    }

    // MARK: Audio

    /// Selected clips whose audio can be detached.
    private var detachableSelection: [Clip.ID] {
        project.tracks.flatMap(\.clips).map(\.id).filter { selection.contains($0) && project.canDetachAudio($0) }
    }

    var canDetachAudio: Bool { !detachableSelection.isEmpty }

    var canUnlink: Bool { selection.contains { project.isLinked($0) } }

    func detachAudio(_ ids: [Clip.ID]? = nil) {
        let targets = ids ?? detachableSelection
        guard !targets.isEmpty else { return }
        document.perform("Detach Audio", undoManager: undoManager) { project in
            for id in targets { project.detachAudio(id) }
        }
    }

    func unlink(_ ids: Set<Clip.ID>? = nil) {
        let targets = ids ?? selection
        document.perform("Unlink", undoManager: undoManager) { project in
            project.unlink(targets)
        }
    }

    func setVolume(_ volume: Float, for ids: Set<Clip.ID>) {
        document.perform("Change Volume", undoManager: undoManager) { project in
            project.setVolume(volume, for: ids)
        }
    }

    func addAudioTrack() {
        document.perform("Add Audio Track", undoManager: undoManager) { project in
            project.addTrack(.audio)
        }
    }

    func toggleMute(_ trackID: Track.ID) {
        document.perform("Mute Track", undoManager: undoManager) { project in
            project.toggleMute(trackID)
        }
    }

    // MARK: Media

    func importMedia(_ urls: [URL]) {
        let known = Set(project.media.map(\.path))
        let newURLs = urls.filter { !known.contains($0.path) }
        guard !newURLs.isEmpty else { return }
        Task {
            var refs: [MediaRef] = []
            var failed: [String] = []
            for url in newURLs {
                do {
                    refs.append(try await MediaImporter.makeRef(for: url))
                } catch {
                    failed.append(url.lastPathComponent)
                }
            }
            if !refs.isEmpty {
                document.perform("Add Media", undoManager: undoManager) { project in
                    project.media.append(contentsOf: refs)
                }
            }
            if !failed.isEmpty {
                importError = "Unsupported file: " + failed.joined(separator: ", ")
            }
        }
    }

    func removeMedia(_ mediaID: MediaRef.ID) {
        document.perform("Remove Media", undoManager: undoManager) { project in
            project.removeMedia(mediaID)
        }
    }

    func relinkMedia(_ mediaID: MediaRef.ID, to url: URL) {
        let bookmark = try? url.bookmarkData()
        document.perform("Relink Media", undoManager: undoManager) { project in
            project.relinkMedia(mediaID, path: url.path, bookmark: bookmark)
        }
    }

    /// Adds media to a track (the main track by default) near `time`, or at its end when `time` is nil.
    func addToTimeline(_ mediaID: MediaRef.ID, track trackID: Track.ID? = nil, near time: CMTime? = nil) {
        guard let media = project.mediaRef(id: mediaID), let trackID = trackID ?? project.mainTrackID,
              let track = project.tracks.first(where: { $0.id == trackID })
        else { return }
        // Audio tracks only take media with sound.
        guard track.kind != .audio || media.hasAudio else { return }

        document.perform("Add to Timeline", undoManager: undoManager) { project in
            // The first video on an empty timeline defines the render size.
            if project.duration == .zero, media.kind == .video, media.naturalSize.width > 0 {
                project.settings.renderSize = media.naturalSize
            }
            project.insertClip(
                mediaID: mediaID,
                sourceRange: CMTimeRange(start: .zero, duration: media.duration),
                onTrack: trackID,
                near: time ?? track.endTime
            )
        }
    }

    // MARK: Sync

    /// Called whenever the document's project changes (edits, undo, load).
    func projectDidChange() {
        let clipIDs = Set(project.tracks.flatMap(\.clips).map(\.id))
        selection.formIntersection(clipIDs)
        playback.load(project, assets: assets)
    }

    // MARK: Zoom

    func zoomIn() { pixelsPerSecond = min(pixelsPerSecond * 1.5, 600) }
    func zoomOut() { pixelsPerSecond = max(pixelsPerSecond / 1.5, 2) }
}
