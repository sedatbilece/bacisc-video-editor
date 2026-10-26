import AVFoundation
import Combine
import CoreGraphics
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
    /// Pixel sizes the preview is shown at; the full-screen window wins while it is open.
    @ObservationIgnored private var paneDisplaySize: CGSize?
    @ObservationIgnored private var fullScreenDisplaySize: CGSize?
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    @ObservationIgnored private var layoutSize: CGSize = .zero
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
            if var configuration = output.videoConfiguration {
                configuration.renderSize = previewRenderSize(layoutSize: project.settings.renderSize)
                videoConfiguration = configuration
                item.videoComposition = AVVideoComposition(configuration: configuration)
            } else {
                item.videoComposition = output.videoComposition
            }
            layoutSize = project.settings.renderSize
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

    /// The preview pane's size in pixels. Frames are rendered at this size instead of the
    /// project size, so the player view doesn't shrink them again with a coarse filter.
    func setPaneDisplaySize(_ size: CGSize) {
        guard paneDisplaySize != size else { return }
        paneDisplaySize = size
        resizeTask?.cancel()
        resizeTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            applyPreviewRenderSize()
        }
    }

    /// The full-screen window's size in pixels, or nil when it closes.
    func setFullScreenDisplaySize(_ size: CGSize?) {
        fullScreenDisplaySize = size
        applyPreviewRenderSize()
    }

    private func applyPreviewRenderSize() {
        guard var configuration = videoConfiguration, let item = player.currentItem else { return }
        let size = previewRenderSize(layoutSize: layoutSize)
        guard configuration.renderSize != size else { return }
        configuration.renderSize = size
        videoConfiguration = configuration
        item.videoComposition = AVVideoComposition(configuration: configuration)
    }

    /// The project frame scaled down (never up) to fit the display, with even dimensions.
    private func previewRenderSize(layoutSize: CGSize) -> CGSize {
        guard let display = fullScreenDisplaySize ?? paneDisplaySize,
              display.width > 0, display.height > 0, layoutSize.width > 0, layoutSize.height > 0
        else { return layoutSize }
        let scale = min(display.width / layoutSize.width, display.height / layoutSize.height, 1)
        guard scale < 1 else { return layoutSize }
        return CGSize(
            width: max(2, (layoutSize.width * scale / 2).rounded() * 2),
            height: max(2, (layoutSize.height * scale / 2).rounded() * 2)
        )
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
