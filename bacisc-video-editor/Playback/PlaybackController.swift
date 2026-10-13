import AVFoundation
import Combine
import CoreMedia
import Dispatch
import EditorCore
import Foundation

/// Owns the `AVPlayer` for a window and keeps the playhead in sync with it.
@Observable
final class PlaybackController {
    @ObservationIgnored let player = AVPlayer()
    /// Transforms dragged in the preview, shown before they are committed.
    @ObservationIgnored let liveTransforms = LiveTransforms()
    private(set) var currentTime: CMTime = .zero
    private(set) var duration: CMTime = .zero
    private(set) var isPlaying = false

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var buildTask: Task<Void, Never>?
    @ObservationIgnored private var videoConfiguration: AVVideoComposition.Configuration?
    @ObservationIgnored private var statusSubscription: AnyCancellable?
    /// Receives preview build and playback errors.
    @ObservationIgnored var onError: ((ErrorReport) -> Void)?

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
            var output: CompositionBuilder.Output?
            do {
                output = try await CompositionBuilder.build(project, assets: assets, liveTransforms: liveTransforms)
            } catch {
                guard !Task.isCancelled else { return }
                onError?(ErrorReport(title: "Preview Could Not Be Built", error: error))
            }
            guard !Task.isCancelled else { return }

            duration = project.duration
            // The rebuilt project already contains any committed drag.
            liveTransforms.removeAll()
            videoConfiguration = output?.videoConfiguration
            guard let output else {
                player.replaceCurrentItem(with: nil)
                currentTime = .zero
                return
            }
            let item = AVPlayerItem(asset: output.composition)
            item.videoComposition = output.videoComposition
            item.audioMix = output.audioMix
            watchStatus(of: item)
            player.replaceCurrentItem(with: item)
            seek(to: currentTime)
        }
    }

    /// Reports the item failing (e.g. an invalid composition or unreadable media). Delivered on the main queue.
    private func watchStatus(of item: AVPlayerItem) {
        statusSubscription = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] status in
                guard status == .failed, let self else { return }
                self.onError?(ErrorReport(title: "Playback Failed", error: item?.error ?? AVError(.unknown)))
            }
    }

    /// Redraws the current frame while paused, e.g. after a live transform change.
    func refreshFrame() {
        guard player.rate == 0, let item = player.currentItem, let videoConfiguration else { return }
        item.videoComposition = AVVideoComposition(configuration: videoConfiguration)
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
