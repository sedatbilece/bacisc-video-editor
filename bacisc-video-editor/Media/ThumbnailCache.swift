import AppKit
import AVFoundation
import EditorCore

/// Poster frames for media files, generated on demand and kept in memory.
@Observable
final class ThumbnailCache {
    private(set) var images: [MediaRef.ID: NSImage] = [:]
    @ObservationIgnored private var loading: Set<MediaRef.ID> = []

    func load(_ media: MediaRef, from assets: AssetCache) async {
        guard media.kind == .video, images[media.id] == nil, !loading.contains(media.id),
              let asset = assets.asset(for: media)
        else { return }
        loading.insert(media.id)
        defer { loading.remove(media.id) }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        let time = CMTimeMinimum(.seconds(1), CMTimeMultiplyByRatio(media.duration, multiplier: 1, divisor: 2))
        if let (cgImage, _) = try? await generator.image(at: time) {
            images[media.id] = NSImage(cgImage: cgImage, size: .zero)
        }
    }
}
