import AVKit
import EditorCore
import SwiftUI

/// Video preview plus transport controls.
struct PreviewPane: View {
    var session: EditorSession

    var body: some View {
        VStack(spacing: 0) {
            PlayerLayerView(player: session.playback.player)
                .background(.black)
            Divider()
            TransportBar(session: session)
        }
    }
}

private struct TransportBar: View {
    var session: EditorSession

    var body: some View {
        let playback = session.playback
        let fps = session.project.settings.frameRate
        HStack(spacing: 12) {
            Button {
                playback.seek(to: .zero)
            } label: {
                Image(systemName: "backward.end.fill")
            }
            .help("Başa git")

            Button {
                playback.togglePlayback()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help("Oynat / Durdur (Boşluk)")

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

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}
