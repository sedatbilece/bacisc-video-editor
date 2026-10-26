import AVKit
import CoreGraphics
import CoreMedia
import EditorCore
import SwiftUI

/// Video preview with layer handles, plus transport controls.
struct PreviewPane: View {
    var session: EditorSession

    var body: some View {
        VStack(spacing: 0) {
            PlayerLayerView(player: session.playback.player) { size in
                session.playback.setPaneDisplaySize(size)
            }
            .background(.black)
            .overlay { TransformOverlay(session: session) }
            Divider()
            TransportBar(session: session)
        }
    }
}

private struct TransportBar: View {
    var session: EditorSession
    @State private var fullScreen = FullScreenPreview()

    var body: some View {
        let playback = session.playback
        let fps = session.project.settings.frameRate
        HStack(spacing: 12) {
            Button {
                playback.seek(to: .zero)
            } label: {
                Image(systemName: "backward.end.fill")
            }
            .help("Go to start")

            Button {
                playback.togglePlayback()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .keyboardShortcut(session.isEditingText ? nil : KeyboardShortcut(.space, modifiers: []))
            .help("Play / Pause (Space)")

            Button {
                fullScreen.show(playback: playback)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .help("Full screen preview (Esc to exit)")
            .disabled(playback.duration <= .zero)

            Spacer()

            Text("\(playback.currentTime.timecode(frameRate: fps)) / \(playback.duration.timecode(frameRate: fps))")
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    var onDisplaySizeChange: (CGSize) -> Void

    func makeNSView(context: Context) -> SizeReportingPlayerView {
        let view = SizeReportingPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        view.onDisplaySizeChange = onDisplaySizeChange
        return view
    }

    func updateNSView(_ nsView: SizeReportingPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
        nsView.onDisplaySizeChange = onDisplaySizeChange
    }
}

/// Reports its size in pixels whenever its bounds or backing scale change.
private final class SizeReportingPlayerView: AVPlayerView {
    var onDisplaySizeChange: ((CGSize) -> Void)?

    override func layout() {
        super.layout()
        reportSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reportSize()
    }

    private func reportSize() {
        let scale = window?.backingScaleFactor ?? 2
        onDisplaySizeChange?(CGSize(width: bounds.width * scale, height: bounds.height * scale))
    }
}
