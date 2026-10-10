import AVFoundation
import EditorCore

/// Turns the project model into AVFoundation objects. Preview and (later)
/// export both go through here so what you see is what you get.
enum CompositionBuilder {
    struct Output {
        let composition: AVComposition
        let videoComposition: AVVideoComposition?
        let audioMix: AVAudioMix?
    }

    static func build(_ project: Project, assets: AssetCache) async throws -> Output? {
        guard project.duration > .zero else { return nil }

        let composition = AVMutableComposition()
        let audio = AudioLanes(composition: composition)
        var videoComposition: AVVideoComposition?

        if let main = project.mainTrackIndex, !project.tracks[main].clips.isEmpty {
            videoComposition = try await buildMainTrack(project.tracks[main], project: project, composition: composition, audio: audio, assets: assets)
        }

        for track in project.tracks where track.kind == .audio {
            for clip in track.clips {
                guard let media = project.mediaRef(id: clip.mediaID), let asset = assets.asset(for: media),
                      let source = try await asset.loadTracks(withMediaType: .audio).first
                else { continue }
                try audio.insert(source, clip: clip, volume: track.isMuted ? 0 : clip.volume)
            }
        }

        return Output(composition: composition, videoComposition: videoComposition, audioMix: audio.makeMix())
    }

    /// Inserts the main track's video (and non-detached audio) and returns its video composition.
    private static func buildMainTrack(
        _ track: Track,
        project: Project,
        composition: AVMutableComposition,
        audio: AudioLanes,
        assets: AssetCache
    ) async throws -> AVVideoComposition? {
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return nil
        }
        let renderSize = project.settings.renderSize
        var instructions: [AVVideoCompositionInstruction] = []
        var cursor = CMTime.zero

        for clip in track.clips {
            if clip.timelineStart > cursor {
                videoTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, end: clip.timelineStart))
                instructions.append(emptyInstruction(CMTimeRange(start: cursor, end: clip.timelineStart)))
            }
            cursor = clip.timelineEnd

            guard let media = project.mediaRef(id: clip.mediaID), let asset = assets.asset(for: media) else {
                // Offline media: keep the timing, render black.
                videoTrack.insertEmptyTimeRange(clip.timelineRange)
                instructions.append(emptyInstruction(clip.timelineRange))
                continue
            }

            var instruction = AVVideoCompositionInstruction.Configuration(timeRange: clip.timelineRange)
            if let source = try await asset.loadTracks(withMediaType: .video).first {
                try videoTrack.insertTimeRange(clip.sourceRange, of: source, at: clip.timelineStart)
                let (naturalSize, transform) = try await source.load(.naturalSize, .preferredTransform)
                var layer = AVVideoCompositionLayerInstruction.Configuration(assetTrack: videoTrack)
                layer.setTransform(aspectFit(naturalSize, transform: transform, in: renderSize), at: clip.timelineStart)
                instruction.layerInstructions = [AVVideoCompositionLayerInstruction(configuration: layer)]
            } else {
                videoTrack.insertEmptyTimeRange(clip.timelineRange)
            }
            instructions.append(AVVideoCompositionInstruction(configuration: instruction))

            if !clip.isAudioDetached, let source = try await asset.loadTracks(withMediaType: .audio).first {
                try audio.insert(source, clip: clip, volume: track.isMuted ? 0 : clip.volume)
            }
        }

        // Instructions must cover the whole composition, which audio tracks may extend.
        if cursor < project.duration {
            instructions.append(emptyInstruction(CMTimeRange(start: cursor, end: project.duration)))
        }

        return AVVideoComposition(configuration: .init(
            frameDuration: project.frameDuration,
            instructions: instructions,
            renderSize: renderSize
        ))
    }

    private static func emptyInstruction(_ range: CMTimeRange) -> AVVideoCompositionInstruction {
        AVVideoCompositionInstruction(configuration: .init(timeRange: range))
    }

    /// Orients the source frame and scales it to fit the render size, centered.
    private static func aspectFit(_ size: CGSize, transform: CGAffineTransform, in renderSize: CGSize) -> CGAffineTransform {
        let oriented = CGRect(origin: .zero, size: size).applying(transform)
        let scale = min(renderSize.width / oriented.width, renderSize.height / oriented.height)
        let scaledWidth = oriented.width * scale
        let scaledHeight = oriented.height * scale
        return transform
            .concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(
                translationX: (renderSize.width - scaledWidth) / 2,
                y: (renderSize.height - scaledHeight) / 2
            ))
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
