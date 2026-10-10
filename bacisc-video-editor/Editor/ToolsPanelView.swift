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
                .keyboardShortcut("b", modifiers: [])
                .disabled(!session.canSplit)

                ToolButton(title: "Delete", systemImage: "trash", hint: "⌫") {
                    session.deleteSelection()
                }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(!session.canDelete)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
