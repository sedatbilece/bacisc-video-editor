import AVFoundation
import CoreGraphics
import CoreMedia
import EditorCore
import SwiftUI

enum InspectorTab: String, CaseIterable {
    case clip = "Clip"
    case subtitles = "Subtitles"
}

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
    /// Errors waiting to be shown, oldest first.
    var errorReports: [ErrorReport] = []
    /// True while a text field has focus; plain-key shortcuts (Space, B, T, Delete) are off meanwhile.
    var isEditingText = false
    var showsExportSheet = false
    var showsTranscribeSheet = false
    var showsInspector = true
    var inspectorTab: InspectorTab = .clip
    /// A cue the Subtitles tab should scroll to; cleared once it has.
    var revealedCueID: String?

    init(document: ProjectDocument) {
        self.document = document
        playback.onError = { [weak self] report in self?.report(report) }
    }

    // MARK: Errors

    /// Queues an error for the error sheet; an identical one already waiting is not added again.
    func report(_ report: ErrorReport) {
        guard !errorReports.contains(where: { $0.title == report.title && $0.message == report.message }) else { return }
        errorReports.append(report)
    }

    func dismissError() {
        if !errorReports.isEmpty { errorReports.removeFirst() }
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

    var canDelete: Bool { !selection.isEmpty && !isEditingText }

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

    // MARK: Layers

    func addText() {
        let time = playback.currentTime
        var newID: Clip.ID?
        document.perform("Add Text", undoManager: undoManager) { project in
            newID = project.addTextClip(TextLayer(), at: time)
        }
        if let newID { selection = [newID] }
    }

    func addOverlayTrack() {
        document.perform("Add Video Track", undoManager: undoManager) { project in
            project.addTrack(.overlay)
        }
    }

    /// Moves a visual track in the stacking order (0 = back).
    func moveVisualTrack(_ trackID: Track.ID, to position: Int) {
        document.perform("Reorder Tracks", undoManager: undoManager) { project in
            project.reorderVisualTrack(trackID, to: position)
        }
    }

    /// Removes a track with its clips (not the main track).
    func deleteTrack(_ trackID: Track.ID) {
        document.perform("Delete Track", undoManager: undoManager) { project in
            project.removeTrack(trackID)
        }
    }

    func setTransform(_ transform: ClipTransform, for ids: Set<Clip.ID>) {
        document.perform("Transform", undoManager: undoManager) { project in
            project.setTransform(transform, for: ids)
        }
    }

    func setText(_ text: TextLayer, for id: Clip.ID) {
        document.perform("Edit Text", undoManager: undoManager) { project in
            project.setText(text, for: id)
        }
    }

    func setFades(in fadeIn: Double, out fadeOut: Double, for ids: Set<Clip.ID>) {
        document.perform("Change Fade", undoManager: undoManager) { project in
            project.setFades(in: fadeIn, out: fadeOut, for: ids)
        }
    }

    /// Shows a transform in the preview without committing it (during a drag).
    func previewTransform(_ transform: ClipTransform, for id: Clip.ID) {
        playback.liveTransforms.set(transform, for: id)
        playback.refreshFrame()
    }

    /// Ends a live transform as a single undo step.
    func commitTransform(_ transform: ClipTransform, for id: Clip.ID) {
        guard project.clip(id: id)?.transform != transform else {
            playback.liveTransforms.set(nil, for: id)
            playback.refreshFrame()
            return
        }
        setTransform(transform, for: [id])
    }

    /// The selected clip when it is a visual clip under the playhead (the one the preview handles edit).
    var selectedLayer: Clip? {
        guard let clip = selectedClip, let loc = project.location(ofClip: clip.id),
              project.tracks[loc.track].kind.isVisual
        else { return nil }
        let time = playback.currentTime
        return clip.timelineStart <= time && time < clip.timelineEnd ? clip : nil
    }

    /// The front-most visual clip under the playhead that covers a render-space point.
    func layerClip(at point: CGPoint) -> Clip.ID? {
        let time = playback.currentTime
        for t in project.visualTrackIndices.reversed() {
            guard let c = project.tracks[t].clipIndex(at: time) else { continue }
            let clip = project.tracks[t].clips[c]
            if let geometry = LayerGeometry(clip: clip, in: project), geometry.contains(point) {
                return clip.id
            }
        }
        return nil
    }

    // MARK: Media

    func importMedia(_ urls: [URL]) {
        let known = Set(project.media.map(\.path))
        let newURLs = urls.filter { !known.contains($0.path) }
        guard !newURLs.isEmpty else { return }
        Task {
            var refs: [MediaRef] = []
            var failed: [(name: String, error: any Error)] = []
            for url in newURLs {
                do {
                    refs.append(try await MediaImporter.makeRef(for: url))
                } catch {
                    failed.append((url.lastPathComponent, error))
                }
            }
            if !refs.isEmpty {
                document.perform("Add Media", undoManager: undoManager) { project in
                    project.media.append(contentsOf: refs)
                }
            }
            if !failed.isEmpty {
                report(ErrorReport(
                    title: "Import Failed",
                    message: "Could not import: " + failed.map(\.name).joined(separator: ", "),
                    details: failed.map { "\($0.name)\n\(ErrorReport.describe($0.error))" }.joined(separator: "\n\n")
                ))
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
        // Audio tracks only take media with sound; overlay tracks only media with a picture.
        switch track.kind {
        case .audio: guard media.hasAudio else { return }
        case .overlay: guard media.kind != .audio else { return }
        case .video: break
        }
        let length = media.kind == .image ? Project.defaultStillDuration : media.duration

        document.perform("Add to Timeline", undoManager: undoManager) { project in
            // The first video on an empty timeline defines the render size.
            if project.duration == .zero, media.kind == .video, media.naturalSize.width > 0 {
                project.settings.renderSize = media.naturalSize
            }
            project.insertClip(
                mediaID: mediaID,
                sourceRange: CMTimeRange(start: .zero, duration: length),
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

    // MARK: Export

    var canExport: Bool { project.duration > .zero }

    func showExport() {
        if canExport { showsExportSheet = true }
    }

    // MARK: Subtitles

    var canTranscribe: Bool {
        project.tracks.contains { project.canTranscribe(track: $0.id) }
    }

    var hasSubtitles: Bool { project.subtitles?.segments.isEmpty == false }

    var subtitlesVisible: Bool { project.subtitles?.isVisible == true }

    func showTranscribe() {
        if canTranscribe { showsTranscribeSheet = true }
    }

    /// Replaces the transcript as one undo step and opens it in the inspector.
    func applyTranscript(_ result: TranscriptionController.Result) {
        document.perform("Transcribe", undoManager: undoManager) { project in
            project.setTranscript(result.segments, language: result.language, trackID: result.trackID)
        }
        showsInspector = true
        inspectorTab = .subtitles
    }

    func toggleSubtitles() {
        guard hasSubtitles else { return }
        let visible = !subtitlesVisible
        document.perform(visible ? "Show Subtitles" : "Hide Subtitles", undoManager: undoManager) { project in
            project.setSubtitlesVisible(visible)
        }
    }

    func setSubtitleText(_ text: String, for segmentID: SubtitleSegment.ID) {
        document.perform("Edit Subtitle", undoManager: undoManager) { project in
            project.setSubtitleText(text, for: segmentID)
        }
    }

    func setSubtitleTiming(_ cue: SubtitleCue, start: CMTime, end: CMTime) {
        document.perform("Retime Subtitle", undoManager: undoManager) { project in
            project.setSubtitleTiming(cue.segmentID, clipID: cue.clipID, start: start, end: end)
        }
    }

    func removeSubtitle(_ segmentID: SubtitleSegment.ID) {
        document.perform("Delete Subtitle", undoManager: undoManager) { project in
            project.removeSubtitleSegment(segmentID)
        }
    }

    func setSubtitleStyle(_ style: SubtitleStyle) {
        document.perform("Subtitle Style", undoManager: undoManager) { project in
            project.setSubtitleStyle(style)
        }
    }

    func setSubtitleTrack(_ trackID: Track.ID) {
        document.perform("Subtitle Track", undoManager: undoManager) { project in
            project.setSubtitleTrack(trackID)
        }
    }

    /// Jumps to a cue and shows it in the Subtitles tab.
    func revealSubtitle(_ cue: SubtitleCue) {
        playback.seek(to: cue.timelineRange.start)
        showsInspector = true
        inspectorTab = .subtitles
        revealedCueID = cue.id
    }

    /// Shows a subtitle position in the preview without committing it (during a drag).
    func previewSubtitlePosition(_ position: CGPoint) {
        playback.liveTransforms.set(ClipTransform(position: position), for: SubtitleRenderer.layerID)
        playback.refreshFrame()
    }

    /// Ends a subtitle drag as a single undo step.
    func commitSubtitlePosition(_ position: CGPoint) {
        guard var style = project.subtitles?.style, style.position != position else {
            playback.liveTransforms.set(nil, for: SubtitleRenderer.layerID)
            playback.refreshFrame()
            return
        }
        style.position = position
        setSubtitleStyle(style)
    }

    // MARK: Zoom

    func zoomIn() { pixelsPerSecond = min(pixelsPerSecond * 1.5, 600) }
    func zoomOut() { pixelsPerSecond = max(pixelsPerSecond / 1.5, 2) }
}
