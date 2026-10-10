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

    var undoManager: UndoManager?
    var selection: Set<Clip.ID> = []
    var pixelsPerSecond: Double = 40
    var importError: String?

    init(document: ProjectDocument) {
        self.document = document
    }

    var project: Project { document.project }

    // MARK: Editing

    var canSplit: Bool {
        guard let trackID = project.mainTrackID,
              let track = project.tracks.first(where: { $0.id == trackID }),
              let index = track.clipIndex(at: playback.currentTime)
        else { return false }
        return playback.currentTime > track.clips[index].timelineStart
    }

    var canDelete: Bool { !selection.isEmpty }

    func splitAtPlayhead() {
        guard let trackID = project.mainTrackID else { return }
        let time = playback.currentTime
        document.perform("Böl", undoManager: undoManager) { project in
            project.split(at: time, onTrack: trackID)
        }
    }

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        let ids = selection
        document.perform("Sil", undoManager: undoManager) { project in
            project.rippleDelete(ids)
        }
        selection = []
    }

    func select(_ clipID: Clip.ID, extending: Bool) {
        if extending {
            if selection.contains(clipID) { selection.remove(clipID) } else { selection.insert(clipID) }
        } else {
            selection = [clipID]
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
                document.perform("Medya Ekle", undoManager: undoManager) { project in
                    project.media.append(contentsOf: refs)
                }
            }
            if !failed.isEmpty {
                importError = "Desteklenmeyen dosya: " + failed.joined(separator: ", ")
            }
        }
    }

    func removeMedia(_ mediaID: MediaRef.ID) {
        document.perform("Medyayı Kaldır", undoManager: undoManager) { project in
            project.removeMedia(mediaID)
        }
    }

    /// Adds a media file to the main track: at the clip boundary nearest to
    /// `time`, or at the end when `time` is nil.
    func addToTimeline(_ mediaID: MediaRef.ID, near time: CMTime? = nil) {
        guard let media = project.mediaRef(id: mediaID), let trackID = project.mainTrackID else { return }
        document.perform("Timeline'a Ekle", undoManager: undoManager) { project in
            // The first video on an empty timeline defines the render size.
            if project.duration == .zero, media.kind == .video, media.naturalSize.width > 0 {
                project.settings.renderSize = media.naturalSize
            }
            if let time {
                project.insertClip(
                    mediaID: mediaID,
                    sourceRange: CMTimeRange(start: .zero, duration: media.duration),
                    onTrack: trackID,
                    near: time
                )
            } else {
                project.appendMedia(mediaID, toTrack: trackID)
            }
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
