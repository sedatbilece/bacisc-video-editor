import AVFoundation
import EditorCore

/// Owns the `AVPlayer` for a window and keeps the playhead in sync with it.
@Observable
final class PlaybackController {
    @ObservationIgnored let player = AVPlayer()
    private(set) var currentTime: CMTime = .zero
    private(set) var duration: CMTime = .zero
    private(set) var isPlaying = false

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var buildTask: Task<Void, Never>?

    init() {
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time
                self.isPlaying = self.player.rate != 0
            }
        }
    }

    /// Rebuilds the player item from the project, keeping the playhead position.
    func load(_ project: Project, assets: AssetCache) {
        buildTask?.cancel()
        buildTask = Task {
            let output = try? await CompositionBuilder.build(project, assets: assets)
            guard !Task.isCancelled else { return }

            duration = project.duration
            guard let output else {
                player.replaceCurrentItem(with: nil)
                currentTime = .zero
                return
            }
            let item = AVPlayerItem(asset: output.composition)
            item.videoComposition = output.videoComposition
            player.replaceCurrentItem(with: item)
            seek(to: currentTime)
        }
    }

    func togglePlayback() {
        if player.rate != 0 {
            player.pause()
        } else {
            if currentTime >= duration { seek(to: .zero) }
            player.play()
        }
        isPlaying = player.rate != 0
    }

    func seek(to time: CMTime) {
        let clamped = CMTimeClampToRange(time, range: CMTimeRange(start: .zero, duration: duration))
        currentTime = clamped
        player.seek(to: clamped, toleranceBefore: .zero, toleranceAfter: .zero)
    }
}
