import AVFoundation
import CoreGraphics
import CoreMedia
import EditorCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum MediaImporter {
    enum ImportError: LocalizedError {
        case noAudioVisualTracks, unreadableImage

        var errorDescription: String? {
            switch self {
            case .noAudioVisualTracks: "The file has no video or audio that can be played."
            case .unreadableImage: "The image could not be read."
            }
        }
    }

    /// Reads duration, size and track info of a file and creates a reference to it.
    static func makeRef(for url: URL) async throws -> MediaRef {
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
            return try makeImageRef(for: url)
        }
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

    /// Stills have no duration of their own; their clips get a default length.
    private static func makeImageRef(for url: URL) throws -> MediaRef {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw ImportError.unreadableImage }
        // EXIF orientations 5–8 are rotated by 90°.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let size = orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        return MediaRef(
            path: url.path,
            bookmark: try? url.bookmarkData(),
            kind: .image,
            duration: .zero,
            naturalSize: size
        )
    }
}
