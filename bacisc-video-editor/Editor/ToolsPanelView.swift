import SwiftUI

/// One-click editing tools. New tools get added here as buttons.
struct ToolsPanelView: View {
    @ObservedObject var document: ProjectDocument
    var session: EditorSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tools")
                .font(.headline)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                ToolButton(title: "Split", systemImage: "scissors", hint: "B") {
                    session.splitAtPlayhead()
                }
                .keyboardShortcut(plainKey("b"))
                .disabled(!session.canSplit)

                ToolButton(title: "Delete", systemImage: "trash", hint: "⌫") {
                    session.deleteSelection()
                }
                .keyboardShortcut(plainKey(.delete))
                .disabled(!session.canDelete)

                ToolButton(title: "Detach Audio", systemImage: "waveform.badge.minus", hint: "⌃⇧S") {
                    session.detachAudio()
                }
                .disabled(!session.canDetachAudio)

                ToolButton(title: "Add Text", systemImage: "textformat", hint: "T") {
                    session.addText()
                }
                .keyboardShortcut(plainKey("t"))

                ToolButton(title: "Transcribe", systemImage: "captions.bubble", hint: "⌥⌘R") {
                    session.showTranscribe()
                }
                .disabled(!session.canTranscribe)

                ToolButton(
                    title: session.subtitlesVisible ? "Subtitles On" : "Subtitles Off",
                    systemImage: session.subtitlesVisible ? "captions.bubble.fill" : "captions.bubble",
                    hint: "⌥⌘C"
                ) {
                    session.toggleSubtitles()
                }
                .disabled(!session.hasSubtitles)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A shortcut without modifiers, switched off while typing so the key reaches the text field.
    private func plainKey(_ key: KeyEquivalent) -> KeyboardShortcut? {
        session.isEditingText ? nil : KeyboardShortcut(key, modifiers: [])
    }
}

private struct ToolButton: View {
    let title: String
    let systemImage: String
    let hint: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(title)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.bordered)
        .help("\(title) (\(hint))")
    }
}
