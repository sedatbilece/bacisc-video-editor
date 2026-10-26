import AppKit
import AVKit
import CoreGraphics

/// Shows the preview player in its own full-screen window. Space plays / pauses, Esc exits.
final class FullScreenPreview: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private weak var playback: PlaybackController?

    func show(playback: PlaybackController) {
        guard window == nil else { return }
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        let player = playback.player
        let playerView = AVPlayerView()
        playerView.controlsStyle = .floating
        playerView.videoGravity = .resizeAspect
        playerView.player = player

        let window = KeyHandlingWindow(
            contentRect: screen?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentView = playerView
        window.delegate = self
        window.onSpace = { [weak playback] in playback?.togglePlayback() }
        window.onEscape = { [weak self] in self?.close() }
        self.window = window
        self.playback = playback
        if let screen {
            playback.setFullScreenDisplaySize(CGSize(
                width: screen.frame.width * screen.backingScaleFactor,
                height: screen.frame.height * screen.backingScaleFactor
            ))
        }

        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)
    }

    func close() {
        guard let window else { return }
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        } else {
            tearDown()
        }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        tearDown()
    }

    func windowWillClose(_ notification: Notification) {
        (window?.contentView as? AVPlayerView)?.player = nil
        window?.delegate = nil
        window = nil
        playback?.setFullScreenDisplaySize(nil)
    }

    private func tearDown() {
        window?.close()
    }
}

/// Catches Space and Esc before the player view does.
private final class KeyHandlingWindow: NSWindow {
    var onSpace: (() -> Void)?
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            switch event.keyCode {
            case 49: onSpace?(); return
            case 53: onEscape?(); return
            default: break
            }
        }
        super.sendEvent(event)
    }
}
