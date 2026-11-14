import AppKit
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
    let audio = AudioProcessor()

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
    /// The format shown in the preview and edited by the handles and inspector; nil is the project frame.
    var activeFormat: AspectFormat? {
        didSet {
            if oldValue != activeFormat { reloadPlayback() }
        }
    }
    /// Media waiting for a fit mode choice before it is added.
    var pendingAdd: PendingAdd?
    var snappingEnabled = UserDefaults.standard.object(forKey: "snappingEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(snappingEnabled, forKey: "snappingEnabled") }
    }
    /// The time a timeline drag is snapped to, drawn as a guide line.
    var snapIndicator: CMTime?

    struct PendingAdd: Identifiable {
        let id = UUID()
        let mediaIDs: [MediaRef.ID]
        let trackID: Track.ID
        let time: CMTime?
    }

    init(document: ProjectDocument) {
        self.document = document
        playback.onError = { [weak self] report in self?.report(report) }
        audio.onChange = { [weak self] in self?.reloadPlayback() }
        audio.onError = { [weak self] report in self?.report(report) }
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

    func setAudioCleanup(_ cleanup: AudioCleanup, for ids: Set<Clip.ID>) {
        audio.clearFailures()
        document.perform("Audio Cleanup", undoManager: undoManager) { project in
            project.setAudioCleanup(cleanup, for: ids)
        }
    }

    func setDucking(_ ducking: Ducking?, onTrack trackID: Track.ID) {
        document.perform(ducking == nil ? "Remove Ducking" : "Duck Track", undoManager: undoManager) { project in
            project.setDucking(ducking, onTrack: trackID)
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

    /// Sets the transform in the active format.
    func setTransform(_ transform: ClipTransform, for ids: Set<Clip.ID>) {
        let format = activeFormat
        document.perform("Transform", undoManager: undoManager) { project in
            project.setTransform(transform, for: ids, format: format)
        }
    }

    /// Sets the fit mode in the active format.
    func setFitMode(_ mode: FitMode?, for ids: Set<Clip.ID>) {
        let format = activeFormat
        document.perform("Fit Mode", undoManager: undoManager) { project in
            project.setFitMode(mode, for: ids, format: format)
        }
    }

    /// Makes the clips follow the project frame's layout again in the active format.
    func removeFormatLayouts(for ids: Set<Clip.ID>) {
        let format = activeFormat
        document.perform("Use Project Layout", undoManager: undoManager) { project in
            project.removeLayouts(for: ids, format: format)
        }
    }

    func setDefaultFitMode(_ mode: FitMode?) {
        document.perform("Fit New Media", undoManager: undoManager) { project in
            project.settings.defaultFitMode = mode
        }
    }

    /// The fit mode and transform a clip has in the active format.
    func layout(of clip: Clip) -> ClipLayout {
        project.layout(of: clip, in: activeFormat)
    }

    /// Frame size of the active format.
    var frameSize: CGSize {
        project.frameSize(for: activeFormat)
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
        guard let clip = project.clip(id: id), layout(of: clip).transform != transform else {
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
            if let geometry = LayerGeometry(clip: clip, in: project, format: activeFormat), geometry.contains(point) {
                return clip.id
            }
        }
        return nil
    }

    /// Visual clips under the playhead, back to front.
    var visibleLayers: [Clip] {
        let time = playback.currentTime
        return project.visualTrackIndices.compactMap { t in
            project.tracks[t].clipIndex(at: time).map { project.tracks[t].clips[$0] }
        }
    }

    /// Boxes of the visual clips under the playhead (render coordinates of the active format), except `excluded`.
    func layerBounds(excluding excluded: Clip.ID) -> [CGRect] {
        visibleLayers.compactMap { clip in
            clip.id == excluded ? nil : LayerGeometry(clip: clip, in: project, format: activeFormat)?.bounds
        }
    }

    // MARK: Snapping

    /// Snapping is on and ⌘ is not held (holding it turns snapping off during a drag).
    var isSnapping: Bool {
        snappingEnabled && !NSEvent.modifierFlags.contains(.command)
    }

    /// Snap distance on the timeline: 8 points at the current zoom.
    private var timelineSnapTolerance: CMTime {
        .seconds(8 / pixelsPerSecond)
    }

    /// Start for a free-track clip dragged to `proposed`, snapped by either edge to clip edges or the playhead.
    func snappedMoveStart(_ clip: Clip, proposed: CMTime) -> CMTime {
        let start = max(.zero, proposed)
        guard isSnapping, !project.movesWithMainTrack(clip.id) else {
            snapIndicator = nil
            return start
        }
        let targets = project.snapTargets(excluding: project.linkedClipIDs(of: clip.id)) + [playback.currentTime]
        let match = Snapping.match(edges: [start, start + clip.duration], targets: targets, tolerance: timelineSnapTolerance)
        snapIndicator = match?.target
        return max(.zero, start + (match?.offset ?? .zero))
    }

    /// A trimmed edge's time snapped to clip edges or the playhead. Main-track clips after the clip are skipped (they ripple).
    func snappedTrimTime(_ clip: Clip, proposed: CMTime) -> CMTime {
        guard isSnapping else {
            snapIndicator = nil
            return proposed
        }
        var excluded = project.linkedClipIDs(of: clip.id)
        if let main = project.mainTrackIndex, project.movesWithMainTrack(clip.id) {
            excluded.formUnion(project.tracks[main].clips.filter { $0.timelineStart >= clip.timelineStart }.map(\.id))
        }
        let targets = project.snapTargets(excluding: excluded) + [playback.currentTime]
        let match = Snapping.match(edges: [proposed], targets: targets, tolerance: timelineSnapTolerance)
        snapIndicator = match?.target
        return proposed + (match?.offset ?? .zero)
    }

    /// A drop time snapped to clip edges or the playhead.
    func snappedDropTime(_ time: CMTime) -> CMTime {
        guard isSnapping else { return time }
        let targets = project.snapTargets(excluding: []) + [playback.currentTime]
        return time + (Snapping.match(edges: [time], targets: targets, tolerance: timelineSnapTolerance)?.offset ?? .zero)
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
        addToTimeline([mediaID], track: trackID, near: time)
    }

    /// Adds media in order. Pictures of another shape than the project frame ask for a fit mode first,
    /// unless the project remembers one.
    func addToTimeline(_ mediaIDs: [MediaRef.ID], track trackID: Track.ID? = nil, near time: CMTime? = nil) {
        guard let trackID = trackID ?? project.mainTrackID,
              let track = project.tracks.first(where: { $0.id == trackID })
        else { return }
        // Audio tracks only take media with sound; video tracks only media with a picture.
        let accepted = mediaIDs.filter { id in
            guard let media = project.mediaRef(id: id) else { return false }
            switch track.kind {
            case .audio: return media.hasAudio
            case .overlay: return media.kind != .audio
            case .video: return true
            }
        }
        guard !accepted.isEmpty else { return }
        let request = PendingAdd(mediaIDs: accepted, trackID: trackID, time: time)
        if project.settings.defaultFitMode == nil, needsFitMode(request) {
            pendingAdd = request
        } else {
            add(request, fitMode: project.settings.defaultFitMode, remember: false)
        }
    }

    /// Finishes a pending add with the chosen fit mode; nil cancels it.
    func completePendingAdd(fitMode: FitMode?, remember: Bool) {
        guard let request = pendingAdd else { return }
        pendingAdd = nil
        if let fitMode { add(request, fitMode: fitMode, remember: remember) }
    }

    private func needsFitMode(_ request: PendingAdd) -> Bool {
        guard project.settings.aspect != nil,
              project.tracks.first(where: { $0.id == request.trackID })?.kind.isVisual == true
        else { return false }
        return request.mediaIDs.contains { id in
            guard let media = project.mediaRef(id: id), media.kind != .audio else { return false }
            return project.needsFitMode(forContentSize: media.naturalSize)
        }
    }

    private func add(_ request: PendingAdd, fitMode: FitMode?, remember: Bool) {
        let isVisualTrack = project.tracks.first(where: { $0.id == request.trackID })?.kind.isVisual == true
        document.perform("Add to Timeline", undoManager: undoManager) { project in
            if remember, let fitMode { project.settings.defaultFitMode = fitMode }
            // Older projects without a chosen format take the first video's size.
            if project.settings.aspect == nil, project.duration == .zero,
               let first = request.mediaIDs.compactMap({ project.mediaRef(id: $0) }).first(where: { $0.kind == .video }),
               first.naturalSize.width > 0 {
                project.settings.renderSize = first.naturalSize
            }
            // At a time, each insert lands before the previous one, so go backwards; appends go forwards.
            let ids = request.time == nil ? request.mediaIDs : Array(request.mediaIDs.reversed())
            for id in ids {
                guard let media = project.mediaRef(id: id),
                      let track = project.tracks.first(where: { $0.id == request.trackID })
                else { continue }
                let length = media.kind == .image ? Project.defaultStillDuration : media.duration
                let mode = isVisualTrack && media.kind != .audio && project.needsFitMode(forContentSize: media.naturalSize)
                    ? fitMode : nil
                project.insertClip(
                    mediaID: id,
                    sourceRange: CMTimeRange(start: .zero, duration: length),
                    onTrack: request.trackID,
                    near: request.time ?? track.endTime,
                    fitMode: mode
                )
            }
        }
    }

    // MARK: Sync

    /// Called whenever the document's project changes (edits, undo, load).
    func projectDidChange() {
        let clipIDs = Set(project.tracks.flatMap(\.clips).map(\.id))
        selection.formIntersection(clipIDs)
        audio.update(project, assets: assets)
        reloadPlayback()
    }

    /// Rebuilds the preview in the active format.
    func reloadPlayback() {
        playback.load(project, format: activeFormat, assets: assets, audio: audio)
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
