import AVFoundation
import EditorCore

/// Resolves media references to files and caches their `AVURLAsset`s.
final class AssetCache {
    private var assets: [MediaRef.ID: AVURLAsset] = [:]

    /// The stored path, or wherever the bookmark now points if the file moved; nil when offline.
    func url(for media: MediaRef) -> URL? {
        if FileManager.default.fileExists(atPath: media.path) {
            return media.url
        }
        guard let bookmark = media.bookmark else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func isOffline(_ media: MediaRef) -> Bool {
        url(for: media) == nil
    }

    /// Cached asset for the media's current file; recreated when the file location changes.
    func asset(for media: MediaRef) -> AVURLAsset? {
        guard let url = url(for: media) else {
            assets[media.id] = nil
            return nil
        }
        if let asset = assets[media.id], asset.url == url { return asset }
        let asset = AVURLAsset(url: url)
        assets[media.id] = asset
        return asset
    }
}
