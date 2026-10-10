import SwiftUI

extension FocusedValues {
    @Entry var editorSession: EditorSession?
}

/// The "Kurgu" menu. Plain-key shortcuts (B, Delete, Space) live on the
/// in-window buttons; the menu carries the modifier variants.
struct EditorCommands: Commands {
    @FocusedValue(\.editorSession) private var session

    var body: some Commands {
        CommandMenu("Kurgu") {
            Button("Oynat / Durdur") { session?.playback.togglePlayback() }
                .keyboardShortcut(.space, modifiers: [.option])
                .disabled(session == nil)

            Divider()

            Button("Playhead'de Böl") { session?.splitAtPlayhead() }
                .keyboardShortcut("k")
                .disabled(session?.canSplit != true)

            Button("Seçili Klipleri Sil") { session?.deleteSelection() }
                .keyboardShortcut(.delete)
                .disabled(session?.canDelete != true)

            Divider()

            Button("Yakınlaştır") { session?.zoomIn() }
                .keyboardShortcut("=")
                .disabled(session == nil)

            Button("Uzaklaştır") { session?.zoomOut() }
                .keyboardShortcut("-")
                .disabled(session == nil)
        }
    }
}
