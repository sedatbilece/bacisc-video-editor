import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import EditorCore

/// Turns the project model into AVFoundation objects. Preview and export
/// both go through here so what you see is what you get.
enum CompositionBuilder {
    struct Output {
        let composition: AVComposition
        let videoComposition: AVVideoComposition?
        /// Kept so the preview can rebuild the video composition to redraw a paused frame.
        let videoConfiguration: AVVideoComposition.Configuration?
        let audioMix: AVAudioMix?
    }

    /// Lays the project out in `format` (nil: the project frame). `outputSize` overrides the frame size
    /// (export resolution); layout stays in format coordinates. Cleaned audio and ducking come from `audio` when ready.
    static func build(
        _ project: Project,
        format: AspectFormat?,
        assets: AssetCache,
        audio: AudioProcessor,
        liveTransforms: LiveTransforms,
        outputSize: CGSize? = nil
    ) async throws -> Output? {
        guard project.duration > .zero else { return nil }
        let layoutSize = project.frameSize(for: format)
        let renderSize = outputSize ?? layoutSize
        let outputScale = layoutSize.width > 0 ? renderSize.width / layoutSize.width : 1

        let composition = AVMutableComposition()
        let lanes = AudioLanes(composition: composition)

        // An empty video track spanning the timeline keeps text- or image-only stretches playable.
        if let base = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            base.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: project.duration))
        }

        var layers: [CompositionLayer] = []
        for t in project.visualTrackIndices {
            let track = project.tracks[t]
            let lane = VideoLane(composition: composition)
            for clip in track.clips {
                if let layer = try await visualLayer(
                    for: clip, project: project, format: format, lane: lane, assets: assets, outputScale: outputScale
                ) {
                    layers.append(layer)
                }
                guard clip.text == nil, !clip.isAudioDetached,
                      let media = project.mediaRef(id: clip.mediaID), media.hasAudio
                else { continue }
                try await insertAudio(
                    of: clip, media: media, volume: track.isMuted ? 0 : clip.volume, envelope: [],
                    into: lanes, assets: assets, audio: audio
                )
            }
        }

        layers += subtitleLayers(for: project, layoutSize: layoutSize, outputScale: outputScale)

        for track in project.tracks where track.kind == .audio {
            let envelope = track.ducking.map { ducking in
                Project.duckingEnvelope(
                    speech: project.speechRanges(onTrack: ducking.voiceTrackID, speech: audio.speech),
                    gain: ducking.gain
                )
            } ?? []
            for clip in track.clips {
                guard let media = project.mediaRef(id: clip.mediaID) else { continue }
                try await insertAudio(
                    of: clip, media: media, volume: track.isMuted ? 0 : clip.volume, envelope: envelope,
                    into: lanes, assets: assets, audio: audio
                )
            }
        }

        let configuration = AVVideoComposition.Configuration(
            customVideoCompositorClass: LayerCompositor.self,
            frameDuration: project.frameDuration,
            instructions: instructions(for: layers, duration: project.duration, liveTransforms: liveTransforms, layoutSize: layoutSize),
            renderSize: renderSize
        )
        return Output(
            composition: composition,
            videoComposition: AVVideoComposition(configuration: configuration),
            videoConfiguration: configuration,
            audioMix: lanes.makeMix()
        )
    }

    /// Inserts a clip's audio, from its cleaned file when that is ready.
    private static func insertAudio(
        of clip: Clip,
        media: MediaRef,
        volume: Float,
        envelope: [GainPoint],
        into lanes: AudioLanes,
        assets: AssetCache,
        audio: AudioProcessor
    ) async throws {
        var source: AVAssetTrack?
        var range = clip.sourceRange
        if let asset = audio.cleanedAudioAsset(for: clip, media: media, assets: assets) {
            if let track = try await asset.loadTracks(withMediaType: .audio).first {
                // The encoded file can end a few samples before the source.
                let duration = try await asset.load(.duration)
                range = CMTimeRangeGetIntersection(range, otherRange: CMTimeRange(start: .zero, duration: duration))
                source = track
            }
        }
        if source == nil {
            source = try await assets.asset(for: media)?.loadTracks(withMediaType: .audio).first
            range = clip.sourceRange
        }
        guard let source, range.duration > .zero else { return }
        try lanes.insert(source, range: range, at: clip.timelineStart, volume: volume, envelope: envelope)
    }

    /// The clip's drawable layer; inserts video into the track's lane. Nil when nothing is drawn (offline, audio-only).
    private static func visualLayer(
        for clip: Clip,
        project: Project,
        format: AspectFormat?,
        lane: VideoLane,
        assets: AssetCache,
        outputScale: CGFloat
    ) async throws -> CompositionLayer? {
        guard let geometry = LayerGeometry(clip: clip, in: project, format: format) else { return nil }
        // The compositor reads the transform from the layer's clip, so it carries the format's one.
        var placed = clip
        placed.transform = geometry.transform
        let content: LayerContent

        if let text = clip.text {
            // Rendered above 1x when scaled up or exported larger so it stays sharp.
            let scale = min(CGFloat(max(geometry.transform.scale, 1)) * max(outputScale, 1), 8)
            guard let image = TextRenderer.image(for: text, scale: scale) else { return nil }
            content = .image(CIImage(cgImage: image))
        } else {
            guard let media = project.mediaRef(id: clip.mediaID) else { return nil }
            switch media.kind {
            case .image:
                guard let image = assets.stillImage(for: media) else { return nil }
                content = .image(CIImage(cgImage: image))
            case .video:
                guard let asset = assets.asset(for: media),
                      let source = try await asset.loadTracks(withMediaType: .video).first
                else { return nil }
                let trackID = try lane.insert(source, clip: clip)
                let preferredTransform = try await source.load(.preferredTransform)
                content = .video(trackID: trackID, preferredTransform: preferredTransform)
            case .audio:
                return nil
            }
        }
        return CompositionLayer(clip: placed, content: content, contentSize: geometry.contentSize, baseScale: geometry.baseScale)
    }

    /// Visible subtitle cues as top-most layers; their bitmaps are drawn lazily by the compositor.
    private static func subtitleLayers(for project: Project, layoutSize: CGSize, outputScale: CGFloat) -> [CompositionLayer] {
        guard let style = project.subtitles?.style else { return [] }
        let renderWidth = layoutSize.width
        let scale = min(max(outputScale, 1), 8)
        return project.visibleSubtitleCues.map { cue in
            let clip = Clip(
                id: SubtitleRenderer.layerID,
                mediaID: nil,
                sourceRange: CMTimeRange(start: .zero, duration: cue.timelineRange.duration),
                timelineStart: cue.timelineRange.start,
                transform: ClipTransform(position: style.position)
            )
            return CompositionLayer(
                clip: clip,
                content: .subtitle(text: cue.text, style: style, renderWidth: renderWidth, scale: scale),
                contentSize: SubtitleRenderer.size(for: cue.text, style: style, renderWidth: renderWidth),
                baseScale: 1,
                anchorsBottom: true
            )
        }
    }

    /// One instruction per stretch where the set of visible layers stays the same; together they cover the timeline.
    private static func instructions(
        for layers: [CompositionLayer],
        duration: CMTime,
        liveTransforms: LiveTransforms,
        layoutSize: CGSize
    ) -> [CompositionInstruction] {
        let edges = ([CMTime.zero, duration] + layers.flatMap { [$0.clip.timelineStart, $0.clip.timelineEnd] })
            .filter { $0 >= .zero && $0 <= duration }
            .sorted()
        var times: [CMTime] = []
        for time in edges where times.last != time {
            times.append(time)
        }
        return zip(times, times.dropFirst()).map { start, end in
            let visible = layers.filter { $0.clip.timelineStart <= start && $0.clip.timelineEnd >= end }
            return CompositionInstruction(
                timeRange: CMTimeRange(start: start, end: end),
                layers: visible,
                liveTransforms: liveTransforms,
                layoutSize: layoutSize
            )
        }
    }
}

/// One composition video track per timeline track; clips on a track never overlap.
private final class VideoLane {
    private let composition: AVMutableComposition
    private var track: AVMutableCompositionTrack?
    private var end = CMTime.zero

    init(composition: AVMutableComposition) {
        self.composition = composition
    }

    func insert(_ source: AVAssetTrack, clip: Clip) throws -> CMPersistentTrackID {
        if track == nil {
            track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        }
        guard let track else { throw AVError(.unknown) }
        if clip.timelineStart > end {
            track.insertEmptyTimeRange(CMTimeRange(start: end, end: clip.timelineStart))
        }
        try track.insertTimeRange(clip.sourceRange, of: source, at: clip.timelineStart)
        end = clip.timelineEnd
        return track.trackID
    }
}

/// Composition audio tracks, each with its own volume automation. Overlapping clips go to separate lanes.
private final class AudioLanes {
    private struct Lane {
        let track: AVMutableCompositionTrack
        let parameters: AVMutableAudioMixInputParameters
        var end: CMTime
    }

    private let composition: AVMutableComposition
    private var lanes: [Lane] = []

    init(composition: AVMutableComposition) {
        self.composition = composition
    }

    /// Inserts `range` of `source` at `start`; `envelope` (ducking) scales the volume over time.
    func insert(_ source: AVAssetTrack, range: CMTimeRange, at start: CMTime, volume: Float, envelope: [GainPoint]) throws {
        let end = start + range.duration
        let index = try laneIndex(freeAt: start)
        if start > lanes[index].end {
            lanes[index].track.insertEmptyTimeRange(CMTimeRange(start: lanes[index].end, end: start))
        }
        try lanes[index].track.insertTimeRange(range, of: source, at: start)

        // Envelope points inside the clip become ramps; flat stretches keep the last volume.
        let times = [start] + envelope.map(\.time).filter { $0 > start && $0 < end } + [end]
        let gains = times.map { Project.gain(of: envelope, at: $0) }
        let parameters = lanes[index].parameters
        if gains.count < 2 || gains[0] == gains[1] {
            parameters.setVolume(volume * gains[0], at: start)
        }
        for i in 1..<times.count where gains[i] != gains[i - 1] {
            parameters.setVolumeRamp(
                fromStartVolume: volume * gains[i - 1],
                toEndVolume: volume * gains[i],
                timeRange: CMTimeRange(start: times[i - 1], end: times[i])
            )
        }
        lanes[index].end = end
    }

    func makeMix() -> AVAudioMix? {
        guard !lanes.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = lanes.map(\.parameters)
        return mix
    }

    private func laneIndex(freeAt time: CMTime) throws -> Int {
        if let index = lanes.firstIndex(where: { $0.end <= time }) { return index }
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw AVError(.unknown)
        }
        lanes.append(Lane(track: track, parameters: AVMutableAudioMixInputParameters(track: track), end: .zero))
        return lanes.count - 1
    }
}
