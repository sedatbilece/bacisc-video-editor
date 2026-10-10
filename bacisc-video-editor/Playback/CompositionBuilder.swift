import AVFoundation
import EditorCore

/// Turns the project model into AVFoundation objects. Preview and (later)
/// export both go through here so what you see is what you get.
enum CompositionBuilder {
    struct Output {
        let composition: AVComposition
        let videoComposition: AVVideoComposition?
    }

    static func build(_ project: Project, assets: AssetCache) async throws -> Output? {
        guard let mainTrack = project.tracks.first(where: { $0.kind == .video }), !mainTrack.clips.isEmpty else {
            return nil
        }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }

        let renderSize = project.settings.renderSize
        var instructions: [AVVideoCompositionInstruction] = []
        var cursor = CMTime.zero

        for clip in mainTrack.clips {
            if clip.timelineStart > cursor {
                instructions.append(emptyInstruction(CMTimeRange(start: cursor, end: clip.timelineStart)))
            }
            cursor = clip.timelineEnd

            guard let media = project.mediaRef(id: clip.mediaID), let asset = assets.asset(for: media) else {
                // Offline media: keep the timing, render black.
                videoTrack.insertEmptyTimeRange(clip.timelineRange)
                audioTrack.insertEmptyTimeRange(clip.timelineRange)
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

            if let source = try await asset.loadTracks(withMediaType: .audio).first {
                try audioTrack.insertTimeRange(clip.sourceRange, of: source, at: clip.timelineStart)
            } else {
                audioTrack.insertEmptyTimeRange(clip.timelineRange)
            }

            instructions.append(AVVideoCompositionInstruction(configuration: instruction))
        }

        let videoComposition = AVVideoComposition(configuration: .init(
            frameDuration: CMTime(value: 1, timescale: project.settings.frameRate),
            instructions: instructions,
            renderSize: renderSize
        ))

        return Output(composition: composition, videoComposition: videoComposition)
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
