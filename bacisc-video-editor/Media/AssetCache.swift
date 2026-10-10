import AVFoundation
import EditorCore

/// Resolves media references to files and caches their `AVURLAsset`s.
final class AssetCache {
    private var assets: [MediaRef.ID: AVURLAsset] = [:]

    /// The file for a media reference: its stored path, or — if the file was
    /// moved — wherever its bookmark now points. Nil when the file is offline.
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

    func asset(for media: MediaRef) -> AVURLAsset? {
        if let asset = assets[media.id] { return asset }
        guard let url = url(for: media) else { return nil }
        let asset = AVURLAsset(url: url)
        assets[media.id] = asset
        return asset
    }
}
