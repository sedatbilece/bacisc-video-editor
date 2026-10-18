import AVFoundation
import EditorCore
import Foundation
import SwiftUI

/// Pick a video or audio track and transcribe its speech into subtitles through OpenRouter.
struct TranscribeSheet: View {
    var session: EditorSession
    @Environment(\.dismiss) private var dismiss
    @State private var transcriber = TranscriptionController()
    @State private var trackID: Track.ID?
    @State private var language = AISettings.speechToTextLanguage
    @State private var hasAPIKey = AISettings.apiKey?.isEmpty == false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Transcribe Subtitles")
                .font(.title2.bold())

            switch transcriber.phase {
            case .idle:
                settings
            case .running(let status, let progress):
                ProgressView(value: progress) {
                    Text(status)
                }
            case .failed(let report):
                Label("Transcription failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(report.message)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack {
                if case .idle = transcriber.phase {
                    SettingsLink {
                        Text("Settings…")
                    }
                }
                Spacer()
                buttons
            }
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled(transcriber.isRunning)
        .onAppear { trackID = defaultTrack }
    }

    private var settings: some View {
        let project = session.project
        return Form {
            Picker("Track", selection: $trackID) {
                ForEach(transcribableTracks) { track in
                    Text(trackTitle(track)).tag(Optional(track.id))
                }
            }
            Picker("Language", selection: $language) {
                ForEach(AISettings.languages, id: \.code) { item in
                    Text(item.name).tag(item.code)
                }
            }
            LabeledContent("Model", value: AISettings.speechToTextModel)

            if !hasAPIKey {
                Label("Add your OpenRouter API key in Settings > AI > OpenRouter.", systemImage: "key")
                    .foregroundStyle(.orange)
            }
            if project.subtitles != nil {
                Text("Replaces the current subtitles. Undo brings them back.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch transcriber.phase {
        case .idle:
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Transcribe") { start() }
                .keyboardShortcut(.defaultAction)
                .disabled(trackID == nil)
        case .running:
            Button("Cancel", role: .cancel) { transcriber.cancel() }
                .keyboardShortcut(.cancelAction)
        case .failed(let report):
            Button("Copy Details") { report.copyToPasteboard() }
            Button("Back") { transcriber.reset() }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private var transcribableTracks: [Track] {
        let project = session.project
        return project.tracks.filter { project.canTranscribe(track: $0.id) }
    }

    /// The current subtitle track, else the main track, else the first track with audio.
    private var defaultTrack: Track.ID? {
        let ids = transcribableTracks.map(\.id)
        let project = session.project
        if let id = project.subtitles?.trackID, ids.contains(id) { return id }
        if let id = project.mainTrackID, ids.contains(id) { return id }
        return ids.first
    }

    private func trackTitle(_ track: Track) -> String {
        let kind = switch track.kind {
        case .video: "Main Video"
        case .overlay: "Overlay"
        case .audio: "Audio"
        }
        return "\(session.project.label(ofTrack: track.id)) – \(kind)"
    }

    private func start() {
        guard let trackID else { return }
        hasAPIKey = AISettings.apiKey?.isEmpty == false
        session.playback.player.pause()
        transcriber.start(
            session.project,
            trackID: trackID,
            assets: session.assets,
            model: AISettings.speechToTextModel,
            language: language.isEmpty ? nil : language
        ) { result in
            session.applyTranscript(result)
            dismiss()
        }
    }
}
