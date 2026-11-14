import CoreMedia
import EditorCore
import SwiftUI

/// Right-side panel showing the settings of the selected clip.
struct InspectorView: View {
    @ObservedObject var document: ProjectDocument
    var session: EditorSession

    var body: some View {
        @Bindable var session = session
        VStack(spacing: 0) {
            Picker("Inspector", selection: $session.inspectorTab) {
                ForEach(InspectorTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            switch session.inspectorTab {
            case .clip:
                clipInspector
            case .subtitles:
                SubtitlesInspector(document: document, session: session)
            }
        }
    }

    @ViewBuilder
    private var clipInspector: some View {
        if let clip = session.selectedClip {
            ClipInspector(clip: clip, session: session)
                .id(clip.id)
        } else if session.selection.count > 1 {
            ContentUnavailableView("\(session.selection.count) Clips Selected", systemImage: "square.stack")
        } else {
            ProjectInspector(project: document.project, session: session)
        }
    }
}

private struct ClipInspector: View {
    let clip: Clip
    var session: EditorSession

    var body: some View {
        let project = session.project
        let media = project.mediaRef(id: clip.mediaID)
        let fps = project.settings.frameRate
        let trackKind = project.location(ofClip: clip.id).map { project.tracks[$0.track].kind }

        Form {
            Section("Clip") {
                LabeledContent("Name", value: clip.text != nil ? "Text" : media?.name ?? "Missing media")
                LabeledContent("Track", value: trackName(trackKind))
                LabeledContent("Start", value: clip.timelineStart.timecode(frameRate: fps))
                LabeledContent("Duration", value: clip.duration.timecode(frameRate: fps))
                if !project.isStill(clip) {
                    LabeledContent("Source In", value: clip.sourceRange.start.timecode(frameRate: fps))
                }
            }

            if let text = clip.text {
                TextSection(clip: clip, text: text, session: session)
            }

            if trackKind?.isVisual == true, clip.text != nil || media?.kind != .audio {
                TransformSection(clip: clip, session: session, showsShape: clip.text == nil)
                FadeSection(clip: clip, session: session)
            }

            if clip.text == nil, media?.kind != .image {
                Section("Audio") {
                    if media?.hasAudio != true {
                        Text("This clip has no audio.")
                            .foregroundStyle(.secondary)
                    } else if clip.isAudioDetached {
                        Text("Audio is detached to its own clip.")
                            .foregroundStyle(.secondary)
                    } else {
                        VolumeControl(clip: clip, session: session)
                        AudioCleanupControls(clip: clip, media: media, session: session)
                    }
                }
            }

            if project.isLinked(clip.id) {
                Section("Link") {
                    Button("Unlink Clips") { session.unlink([clip.id]) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func trackName(_ kind: TrackKind?) -> String {
        switch kind {
        case .video: return "Main Video"
        case .overlay: return "Overlay"
        case .audio: return "Audio"
        case nil: return "-"
        }
    }
}

private struct VolumeControl: View {
    let clip: Clip
    var session: EditorSession
    @State private var value: Double = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Volume")
                Spacer()
                Text("\(Int((value * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack {
                // Applied on release so one drag is one undo step.
                Slider(
                    value: $value,
                    in: Double(Project.volumeRange.lowerBound)...Double(Project.volumeRange.upperBound),
                    onEditingChanged: { editing in
                        if !editing { commit() }
                    }
                )
                Button("Reset") {
                    value = 1
                    commit()
                }
                .disabled(clip.volume == 1)
            }
        }
        .onAppear { value = Double(clip.volume) }
        .onChange(of: clip.volume) { _, newValue in value = Double(newValue) }
    }

    private func commit() {
        session.setVolume(Float(value), for: [clip.id])
    }
}

/// Voice isolation and loudness normalization, rendered in the background into a cached file.
private struct AudioCleanupControls: View {
    let clip: Clip
    let media: MediaRef?
    var session: EditorSession

    var body: some View {
        Toggle(isOn: binding(\.isolatesVoice)) {
            labelWithInfo("Voice Isolation")
        }
        .help("Keeps only the voice: removes background noise, hum, fan, keyboard and room echo (Apple voice isolation). Meant for speech; music in the clip is removed too. Processed once in the background; the original plays until it is ready.")
        Toggle(isOn: binding(\.normalizesLoudness)) {
            labelWithInfo("Normalize Loudness")
        }
        .help("Evens out the level: brings the clip to \(Int(AudioCleanup.targetLoudness)) LUFS, the loudness YouTube, Shorts and Reels expect, so quiet and loud clips play at the same level. A limiter keeps peaks below -1 dB so nothing distorts.")
        if clip.audioCleanup.isActive, let media {
            switch session.audio.cleanupState(for: clip, media: media, assets: session.assets) {
            case .processing:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Processing audio… the original plays meanwhile.")
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            case .ready, nil:
                EmptyView()
            }
        }
    }

    /// The title with an info icon that hints at the hover help.
    private func labelWithInfo(_ title: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .imageScale(.small)
        }
    }

    private func binding(_ keyPath: WritableKeyPath<AudioCleanup, Bool>) -> Binding<Bool> {
        Binding(
            get: { clip.audioCleanup[keyPath: keyPath] },
            set: { value in
                var cleanup = clip.audioCleanup
                cleanup[keyPath: keyPath] = value
                session.setAudioCleanup(cleanup, for: [clip.id])
            }
        )
    }
}

private struct ProjectInspector: View {
    let project: Project
    var session: EditorSession

    var body: some View {
        Form {
            Section("Project") {
                LabeledContent("Format", value: project.settings.aspect.map { "\($0.title) \($0.name)" } ?? "Custom")
                LabeledContent("Resolution", value: "\(Int(project.settings.renderSize.width))×\(Int(project.settings.renderSize.height))")
                LabeledContent("Frame Rate", value: "\(project.settings.frameRate) fps")
                LabeledContent("Duration", value: project.duration.timecode(frameRate: project.settings.frameRate))
                Picker("Fit New Media", selection: Binding(
                    get: { project.settings.defaultFitMode },
                    set: { session.setDefaultFitMode($0) }
                )) {
                    Text("Ask").tag(FitMode?.none)
                    ForEach(FitMode.allCases) { mode in
                        Text(mode.title).tag(FitMode?.some(mode))
                    }
                }
                .help("How video and images of another shape than the frame are fitted when added")
            }
            Text("Select a clip to see its settings.")
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
