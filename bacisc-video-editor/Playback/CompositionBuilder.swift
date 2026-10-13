import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import EditorCore

/// Turns the project model into AVFoundation objects. Preview and (later)
/// export both go through here so what you see is what you get.
enum CompositionBuilder {
    struct Output {
        let composition: AVComposition
        let videoComposition: AVVideoComposition?
        /// Kept so the preview can rebuild the video composition to redraw a paused frame.
        let videoConfiguration: AVVideoComposition.Configuration?
        let audioMix: AVAudioMix?
    }

    /// `outputSize` overrides the project frame size (export resolution); layout stays in project coordinates.
    static func build(
        _ project: Project,
        assets: AssetCache,
        liveTransforms: LiveTransforms,
        outputSize: CGSize? = nil
    ) async throws -> Output? {
        guard project.duration > .zero else { return nil }
        let layoutSize = project.settings.renderSize
        let renderSize = outputSize ?? layoutSize
        let outputScale = layoutSize.width > 0 ? renderSize.width / layoutSize.width : 1

        let composition = AVMutableComposition()
        let audio = AudioLanes(composition: composition)

        // An empty video track spanning the timeline keeps text- or image-only stretches playable.
        if let base = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            base.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: project.duration))
        }

        var layers: [CompositionLayer] = []
        for t in project.visualTrackIndices {
            let track = project.tracks[t]
            let lane = VideoLane(composition: composition)
            for clip in track.clips {
                if let layer = try await visualLayer(for: clip, project: project, lane: lane, assets: assets, outputScale: outputScale) {
                    layers.append(layer)
                }
                guard clip.text == nil, !clip.isAudioDetached,
                      let media = project.mediaRef(id: clip.mediaID), media.hasAudio,
                      let asset = assets.asset(for: media),
                      let source = try await asset.loadTracks(withMediaType: .audio).first
                else { continue }
                try audio.insert(source, clip: clip, volume: track.isMuted ? 0 : clip.volume)
            }
        }

        for track in project.tracks where track.kind == .audio {
            for clip in track.clips {
                guard let media = project.mediaRef(id: clip.mediaID), let asset = assets.asset(for: media),
                      let source = try await asset.loadTracks(withMediaType: .audio).first
                else { continue }
                try audio.insert(source, clip: clip, volume: track.isMuted ? 0 : clip.volume)
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
            audioMix: audio.makeMix()
        )
    }

    /// The clip's drawable layer; inserts video into the track's lane. Nil when nothing is drawn (offline, audio-only).
    private static func visualLayer(
        for clip: Clip,
        project: Project,
        lane: VideoLane,
        assets: AssetCache,
        outputScale: CGFloat
    ) async throws -> CompositionLayer? {
        guard let geometry = LayerGeometry(clip: clip, in: project) else { return nil }
        let content: LayerContent

        if let text = clip.text {
            // Rendered above 1x when scaled up or exported larger so it stays sharp.
            let scale = min(CGFloat(max(clip.transform.scale, 1)) * max(outputScale, 1), 8)
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
        return CompositionLayer(clip: clip, content: content, contentSize: geometry.contentSize, baseScale: geometry.baseScale)
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

    func insert(_ source: AVAssetTrack, clip: Clip, volume: Float) throws {
        let index = try laneIndex(freeAt: clip.timelineStart)
        if clip.timelineStart > lanes[index].end {
            lanes[index].track.insertEmptyTimeRange(CMTimeRange(start: lanes[index].end, end: clip.timelineStart))
        }
        try lanes[index].track.insertTimeRange(clip.sourceRange, of: source, at: clip.timelineStart)
        lanes[index].parameters.setVolume(volume, at: clip.timelineStart)
        lanes[index].end = clip.timelineEnd
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
