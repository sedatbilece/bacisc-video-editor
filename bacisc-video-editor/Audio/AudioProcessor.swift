import AVFoundation
import CryptoKit
import EditorCore
import Foundation

/// Background audio work the composition needs: cleaned audio files (cached on disk) and speech ranges for ducking.
/// Results land asynchronously; `onChange` asks for a preview rebuild.
@Observable
final class AudioProcessor {
    enum CleanupState: Equatable {
        case processing
        case ready
        case failed(String)
    }

    /// Speech ranges per media file in source seconds.
    private(set) var speech: [MediaRef.ID: [ClosedRange<Double>]] = [:]
    /// Keyed by cache file name.
    private(set) var cleanupStates: [String: CleanupState] = [:]
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onError: ((ErrorReport) -> Void)?
    @ObservationIgnored private var cleanupTasks: [String: Task<Void, any Error>] = [:]
    @ObservationIgnored private var speechTasks: [MediaRef.ID: Task<Void, any Error>] = [:]
    @ObservationIgnored private var failedSpeech: Set<MediaRef.ID> = []
    /// Kept alive here: an `AVAssetTrack` does not retain its asset, and inserting from a released one fails.
    @ObservationIgnored private var cleanedAssets: [URL: AVURLAsset] = [:]

    static let cacheDirectory = URL.cachesDirectory.appending(path: "bacisc-video-editor/AudioCleanup", directoryHint: .isDirectory)

    // MARK: Lookup

    /// The cache file for a media file with these settings; it changes when the file changes. Nil when offline.
    func cacheURL(for media: MediaRef, cleanup: AudioCleanup, assets: AssetCache) -> URL? {
        guard let url = assets.url(for: media),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        else { return nil }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(size)|\(modified)|voice:\(cleanup.isolatesVoice)|loudness:\(cleanup.normalizesLoudness)|v1"
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return Self.cacheDirectory.appending(path: name + ".m4a")
    }

    /// The cleaned file for a clip when it is ready.
    func cleanedAudioURL(for clip: Clip, media: MediaRef, assets: AssetCache) -> URL? {
        guard clip.audioCleanup.isActive,
              let url = cacheURL(for: media, cleanup: clip.audioCleanup, assets: assets),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    /// The cleaned file's asset when it is ready; the same instance every time.
    func cleanedAudioAsset(for clip: Clip, media: MediaRef, assets: AssetCache) -> AVURLAsset? {
        guard let url = cleanedAudioURL(for: clip, media: media, assets: assets) else { return nil }
        if let asset = cleanedAssets[url] { return asset }
        let asset = AVURLAsset(url: url)
        cleanedAssets[url] = asset
        return asset
    }

    func cleanupState(for clip: Clip, media: MediaRef, assets: AssetCache) -> CleanupState? {
        guard clip.audioCleanup.isActive, let url = cacheURL(for: media, cleanup: clip.audioCleanup, assets: assets) else { return nil }
        if FileManager.default.fileExists(atPath: url.path) { return .ready }
        return cleanupStates[url.lastPathComponent]
    }

    /// Lets failed jobs run again (after the user changes a setting).
    func clearFailures() {
        cleanupStates = cleanupStates.filter { if case .failed = $0.value { false } else { true } }
        failedSpeech.removeAll()
    }

    // MARK: Jobs

    /// Starts the work the project needs that is not done or running yet.
    func update(_ project: Project, assets: AssetCache) {
        for job in cleanupJobs(in: project, assets: assets) where cleanupTasks[job.key] == nil {
            if case .failed = cleanupStates[job.key] { continue }
            startCleanup(job)
        }
        for (mediaID, url) in speechJobs(in: project, assets: assets)
        where speech[mediaID] == nil && speechTasks[mediaID] == nil && !failedSpeech.contains(mediaID) {
            startSpeechDetection(mediaID, url: url)
        }
    }

    /// Waits until everything the project needs is ready (export). Throws the first failure.
    func prepare(_ project: Project, assets: AssetCache) async throws {
        clearFailures()
        update(project, assets: assets)
        for job in cleanupJobs(in: project, assets: assets) {
            try await cleanupTasks[job.key]?.value
        }
        for (mediaID, _) in speechJobs(in: project, assets: assets) {
            try await speechTasks[mediaID]?.value
        }
    }

    private struct CleanupJob {
        let key: String
        let source: URL
        let destination: URL
        let cleanup: AudioCleanup
    }

    /// Distinct (file, settings) pairs of clips with cleanup whose audio is heard; finished ones are left out.
    private func cleanupJobs(in project: Project, assets: AssetCache) -> [CleanupJob] {
        var jobs: [String: CleanupJob] = [:]
        for track in project.tracks {
            for clip in project.audibleClips(onTrack: track.id) where clip.audioCleanup.isActive {
                guard let media = project.mediaRef(id: clip.mediaID),
                      let source = assets.url(for: media),
                      let destination = cacheURL(for: media, cleanup: clip.audioCleanup, assets: assets),
                      !FileManager.default.fileExists(atPath: destination.path)
                else { continue }
                let key = destination.lastPathComponent
                jobs[key] = CleanupJob(key: key, source: source, destination: destination, cleanup: clip.audioCleanup)
            }
        }
        return Array(jobs.values)
    }

    /// Media on voice tracks of ducked tracks.
    private func speechJobs(in project: Project, assets: AssetCache) -> [MediaRef.ID: URL] {
        var jobs: [MediaRef.ID: URL] = [:]
        for track in project.tracks {
            guard let ducking = track.ducking else { continue }
            for clip in project.audibleClips(onTrack: ducking.voiceTrackID) {
                guard let media = project.mediaRef(id: clip.mediaID), let url = assets.url(for: media) else { continue }
                jobs[media.id] = url
            }
        }
        return jobs
    }

    private func startCleanup(_ job: CleanupJob) {
        cleanupStates[job.key] = .processing
        let source = job.source
        let destination = job.destination
        let cleanup = job.cleanup
        let task = Task.detached(priority: .utility) {
            try await AudioCleanupRenderer.render(source: source, cleanup: cleanup, to: destination)
        }
        cleanupTasks[job.key] = task
        Task {
            do {
                try await task.value
                cleanupStates[job.key] = .ready
                cleanupTasks[job.key] = nil
                onChange?()
            } catch {
                cleanupTasks[job.key] = nil
                cleanupStates[job.key] = .failed(error.localizedDescription)
                onError?(ErrorReport(title: "Audio Cleanup Failed", error: error))
            }
        }
    }

    private func startSpeechDetection(_ mediaID: MediaRef.ID, url: URL) {
        let detection = Task.detached(priority: .utility) {
            try await SpeechDetector.speechRanges(in: url)
        }
        speechTasks[mediaID] = Task {
            do {
                let ranges = try await detection.value
                speech[mediaID] = ranges
                speechTasks[mediaID] = nil
                onChange?()
            } catch {
                speechTasks[mediaID] = nil
                failedSpeech.insert(mediaID)
                onError?(ErrorReport(title: "Speech Detection Failed", error: error))
                throw error
            }
        }
    }
}
