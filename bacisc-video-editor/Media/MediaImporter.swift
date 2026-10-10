import AVFoundation
import EditorCore

enum MediaImporter {
    enum ImportError: Error {
        case noAudioVisualTracks
    }

    /// Reads duration, size and track info of a file and creates a reference to it.
    static func makeRef(for url: URL) async throws -> MediaRef {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !videoTracks.isEmpty || !audioTracks.isEmpty, duration > .zero else {
            throw ImportError.noAudioVisualTracks
        }

        var size = CGSize.zero
        if let video = videoTracks.first {
            let (naturalSize, transform) = try await video.load(.naturalSize, .preferredTransform)
            let oriented = naturalSize.applying(transform)
            size = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        }

        return MediaRef(
            path: url.path,
            bookmark: try? url.bookmarkData(),
            kind: videoTracks.isEmpty ? .audio : .video,
            duration: duration,
            naturalSize: size,
            hasAudio: !audioTracks.isEmpty
        )
    }
}
