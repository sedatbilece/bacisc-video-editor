import Foundation
import SwiftUI

/// Terms that speech to text should keep as written, with the spellings to replace.
struct GlossarySettingsPage: View {
    @State private var entries = AISettings.glossary

    var body: some View {
        Form {
            Section {
                ForEach($entries) { $entry in
                    HStack(spacing: 8) {
                        TextField("Term", text: $entry.term, prompt: Text("buffer"))
                            .labelsHidden()
                            .frame(width: 170)
                        TextField("Heard As", text: $entry.heardAs, prompt: Text("bafır, bufır"))
                            .labelsHidden()
                        Button { remove(entry.id) } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Remove Term")
                    }
                }
                Button("Add Term") { entries.append(GlossaryEntry()) }
            } header: {
                Text("Terms")
            } footer: {
                Text("Left: the term as written, sent to the model as a keyterm (only some models use them). Right: comma-separated spellings the model writes instead; after transcription they are replaced by the term, also at the start of a word: \"bafırda\" becomes \"buffer'da\".")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Glossary")
        .onChange(of: entries) { AISettings.glossary = entries }
    }

    private func remove(_ id: GlossaryEntry.ID) {
        entries.removeAll { $0.id == id }
    }
}
