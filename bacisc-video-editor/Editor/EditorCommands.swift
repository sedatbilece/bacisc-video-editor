import SwiftUI

extension FocusedValues {
    @Entry var editorSession: EditorSession?
}

/// The "Timeline" menu. Plain-key shortcuts (B, Delete, Space) live on the
/// in-window buttons; the menu carries the modifier variants.
struct EditorCommands: Commands {
    @FocusedValue(\.editorSession) private var session

    var body: some Commands {
        CommandMenu("Timeline") {
            Button("Play / Pause") { session?.playback.togglePlayback() }
                .keyboardShortcut(.space, modifiers: [.option])
                .disabled(session == nil)

            Divider()

            Button("Split at Playhead") { session?.splitAtPlayhead() }
                .keyboardShortcut("k")
                .disabled(session?.canSplit != true)

            Button("Delete Selected Clips") { session?.deleteSelection() }
                .keyboardShortcut(.delete)
                .disabled(session?.canDelete != true)

            Divider()

            Button("Detach Audio") { session?.detachAudio() }
                .keyboardShortcut("s", modifiers: [.control, .shift])
                .disabled(session?.canDetachAudio != true)

            Button("Unlink") { session?.unlink() }
                .disabled(session?.canUnlink != true)

            Button("Add Audio Track") { session?.addAudioTrack() }
                .disabled(session == nil)

            Divider()

            Button("Zoom In") { session?.zoomIn() }
                .keyboardShortcut("=")
                .disabled(session == nil)

            Button("Zoom Out") { session?.zoomOut() }
                .keyboardShortcut("-")
                .disabled(session == nil)
        }
    }
}
