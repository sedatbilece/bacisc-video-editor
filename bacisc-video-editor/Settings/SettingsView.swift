import Foundation
import SwiftUI

/// The Settings window: a sidebar of sections with sub-pages. New sections get added to `Page` and the sidebar.
struct SettingsView: View {
    enum Page: Hashable {
        case openRouter, speechToText
    }

    @State private var page: Page? = .openRouter

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Section("AI") {
                    Label("OpenRouter", systemImage: "key").tag(Page.openRouter)
                    Label("Speech to Text", systemImage: "waveform").tag(Page.speechToText)
                }
            }
            .navigationSplitViewColumnWidth(190)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            switch page {
            case .openRouter: OpenRouterSettingsPage()
            case .speechToText: SpeechToTextSettingsPage()
            case nil: ContentUnavailableView("Select a Section", systemImage: "gearshape")
            }
        }
        .frame(width: 700, height: 440)
    }
}

/// API key for all AI features, stored in the keychain.
private struct OpenRouterSettingsPage: View {
    @State private var key = ""
    @State private var hasSavedKey = false
    @State private var status: String?
    @State private var isChecking = false

    var body: some View {
        Form {
            Section {
                SecureField("API Key", text: $key, prompt: Text("sk-or-…"))
                HStack {
                    Button("Save") { save() }
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Remove") { remove() }
                        .disabled(!hasSavedKey)
                    Button("Check Key") { check() }
                        .disabled(!hasSavedKey || isChecking)
                    if isChecking { ProgressView().controlSize(.small) }
                }
                if let status {
                    Text(status)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("OpenRouter")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Used by AI features such as speech to text. The key is kept in your keychain.")
                    Link("Create a key on openrouter.ai", destination: URL(string: "https://openrouter.ai/settings/keys")!)
                }
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("OpenRouter")
        .onAppear {
            key = AISettings.apiKey ?? ""
            hasSavedKey = !key.isEmpty
        }
    }

    private func save() {
        do {
            try AISettings.setAPIKey(key)
            hasSavedKey = true
            status = "Saved."
        } catch {
            status = error.localizedDescription
        }
    }

    private func remove() {
        do {
            try AISettings.setAPIKey(nil)
            key = ""
            hasSavedKey = false
            status = "Removed."
        } catch {
            status = error.localizedDescription
        }
    }

    private func check() {
        isChecking = true
        status = nil
        Task {
            defer { isChecking = false }
            do {
                let info = try await OpenRouterClient.configured().keyInfo()
                var parts = ["Key is valid."]
                if let label = info.label, !label.isEmpty { parts.append("Label: \(label).") }
                if let usage = info.usage { parts.append(String(format: "Used: $%.2f.", usage)) }
                if let limit = info.limit { parts.append(String(format: "Limit: $%.2f.", limit)) }
                status = parts.joined(separator: " ")
            } catch {
                status = error.localizedDescription
            }
        }
    }
}

/// Model and default language for transcription.
private struct SpeechToTextSettingsPage: View {
    @AppStorage(AISettings.speechToTextModelKey) private var model = AISettings.defaultSpeechToTextModel
    @AppStorage(AISettings.speechToTextLanguageKey) private var language = ""
    @State private var models: [OpenRouterClient.Model] = []
    @State private var loadError: String?
    @State private var isLoading = false

    var body: some View {
        Form {
            Section {
                Picker("Model", selection: $model) {
                    ForEach(modelChoices) { model in
                        Text(model.name).tag(model.id)
                    }
                }
                TextField("Model ID", text: $model)
                    .font(.body.monospaced())
                HStack {
                    Button("Refresh Models") { load() }
                        .disabled(isLoading)
                    if isLoading { ProgressView().controlSize(.small) }
                    if let loadError {
                        Text(loadError)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            } header: {
                Text("Model")
            } footer: {
                Text("OpenRouter models with transcription output. Subtitles need timestamps: Whisper models return segments, others may return words; a model without either cannot be used.")
                    .foregroundStyle(.secondary)
            }

            Section("Language") {
                Picker("Default Language", selection: $language) {
                    ForEach(AISettings.languages, id: \.code) { item in
                        Text(item.name).tag(item.code)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Speech to Text")
        .task { if models.isEmpty { load() } }
    }

    /// Fetched models, plus the current ID when it is not among them.
    private var modelChoices: [OpenRouterClient.Model] {
        guard !model.isEmpty, !models.contains(where: { $0.id == model }) else { return models }
        return [OpenRouterClient.Model(id: model, name: model)] + models
    }

    private func load() {
        isLoading = true
        loadError = nil
        Task {
            defer { isLoading = false }
            do {
                models = try await OpenRouterClient.transcriptionModels()
            } catch {
                loadError = error.localizedDescription
            }
        }
    }
}
