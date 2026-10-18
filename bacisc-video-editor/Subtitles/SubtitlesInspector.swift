import AppKit
import CoreGraphics
import CoreMedia
import EditorCore
import Foundation
import SwiftUI

/// Inspector tab for the transcript: visibility, timing track, style and the editable, timed text.
struct SubtitlesInspector: View {
    var session: EditorSession

    var body: some View {
        if let subtitles = session.project.subtitles {
            SubtitlesEditor(subtitles: subtitles, session: session)
        } else {
            ContentUnavailableView {
                Label("No Subtitles", systemImage: "captions.bubble")
            } description: {
                Text("Transcribe a video or audio track to create subtitles.")
            } actions: {
                Button("Transcribe…") { session.showTranscribe() }
                    .disabled(!session.canTranscribe)
            }
        }
    }
}

private enum SubtitleField: Hashable {
    case text(String), start(String), end(String)
}

private struct SubtitlesEditor: View {
    let subtitles: Subtitles
    var session: EditorSession
    @State private var activeCueID: String?
    @FocusState private var focus: SubtitleField?

    var body: some View {
        let project = session.project
        let cues = project.subtitleCues

        ScrollViewReader { proxy in
            Form {
                Section {
                    Toggle("Show Subtitles", isOn: Binding(
                        get: { subtitles.isVisible },
                        set: { _ in session.toggleSubtitles() }
                    ))
                    Picker("Timing Track", selection: Binding(
                        get: { subtitles.trackID },
                        set: { session.setSubtitleTrack($0) }
                    )) {
                        ForEach(project.tracks) { track in
                            Text(project.label(ofTrack: track.id)).tag(track.id)
                        }
                    }
                    .help("Subtitles follow the clips of this track")
                    if let language = subtitles.language, !language.isEmpty {
                        LabeledContent("Language", value: language)
                    }
                    HStack {
                        Button("Transcribe Again…") { session.showTranscribe() }
                            .disabled(!session.canTranscribe)
                        Button("Copy Text") { copy(cues) }
                            .disabled(cues.isEmpty)
                    }
                }

                SubtitleStyleSection(style: subtitles.style, session: session)

                Section("Transcript (\(cues.count))") {
                    if cues.isEmpty {
                        Text("No subtitles on the timing track's clips.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(cues) { cue in
                        SubtitleRow(cue: cue, isActive: cue.id == activeCueID, session: session, focus: $focus)
                            .id(cue.id)
                    }
                }
            }
            .formStyle(.grouped)
            .background {
                ActiveCueObserver(cues: cues, playback: session.playback, activeCueID: $activeCueID)
            }
            .onChange(of: activeCueID) { _, id in
                // Follow playback, but not while the user is typing.
                guard let id, session.playback.isPlaying, focus == nil else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .onChange(of: focus) { _, field in
            session.isEditingText = field != nil
        }
        .onDisappear { session.isEditingText = false }
    }

    private func copy(_ cues: [SubtitleCue]) {
        let text = cues.map { cue in
            "[\(SubtitleTime.format(cue.timelineRange.start.seconds)) – \(SubtitleTime.format(cue.timelineRange.end.seconds))] \(cue.text)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Reads the playhead so only this view updates every frame; the list changes only when the active cue does.
private struct ActiveCueObserver: View {
    let cues: [SubtitleCue]
    let playback: PlaybackController
    @Binding var activeCueID: String?

    var body: some View {
        let time = playback.currentTime
        let id = cues.last { $0.timelineRange.start <= time && time < $0.timelineRange.end }?.id
        Color.clear
            .onChange(of: id, initial: true) { _, newValue in activeCueID = newValue }
    }
}

/// One cue: start and end times (editable, timeline seconds), a jump button and the editable text.
private struct SubtitleRow: View {
    let cue: SubtitleCue
    let isActive: Bool
    var session: EditorSession
    var focus: FocusState<SubtitleField?>.Binding
    @State private var draft = ""
    @State private var committed = ""
    @State private var startText = ""
    @State private var endText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Button {
                    session.playback.seek(to: cue.timelineRange.start)
                } label: {
                    Image(systemName: isActive ? "play.circle.fill" : "play.circle")
                }
                .buttonStyle(.borderless)
                .help("Go to this subtitle")

                timeField($startText, field: .start(cue.id))
                Text("–").foregroundStyle(.secondary)
                timeField($endText, field: .end(cue.id))

                Spacer()

                Button {
                    session.removeSubtitle(cue.segmentID)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Delete this subtitle")
            }

            TextField("Subtitle", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused(focus, equals: .text(cue.id))
        }
        .padding(.vertical, 2)
        .listRowBackground(isActive ? Color.accentColor.opacity(0.18) : nil)
        .onAppear(perform: load)
        .onChange(of: cue) { _, _ in
            // Undo/redo or a retime; our own pending text is kept.
            if cue.text != committed {
                draft = cue.text
                committed = cue.text
            }
            if focus.wrappedValue != .start(cue.id) { startText = SubtitleTime.format(cue.timelineRange.start.seconds) }
            if focus.wrappedValue != .end(cue.id) { endText = SubtitleTime.format(cue.timelineRange.end.seconds) }
        }
        .task(id: draft) {
            guard draft != committed else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            commitText()
        }
        .onDisappear {
            if draft != committed { commitText() }
        }
    }

    private func timeField(_ text: Binding<String>, field: SubtitleField) -> some View {
        TextField("0:00.0", text: text)
            .textFieldStyle(.roundedBorder)
            .font(.callout.monospacedDigit())
            .frame(width: 70)
            .focused(focus, equals: field)
            .onSubmit(commitTiming)
            .onChange(of: focus.wrappedValue) { old, _ in
                if old == field { commitTiming() }
            }
    }

    private func load() {
        draft = cue.text
        committed = cue.text
        startText = SubtitleTime.format(cue.timelineRange.start.seconds)
        endText = SubtitleTime.format(cue.timelineRange.end.seconds)
    }

    private func commitText() {
        committed = draft
        session.setSubtitleText(draft, for: cue.segmentID)
    }

    /// Applies typed times; invalid input falls back to the current values.
    private func commitTiming() {
        let start = SubtitleTime.parse(startText) ?? cue.timelineRange.start.seconds
        let end = SubtitleTime.parse(endText) ?? cue.timelineRange.end.seconds
        startText = SubtitleTime.format(start)
        endText = SubtitleTime.format(max(end, start + 0.1))
        guard abs(start - cue.timelineRange.start.seconds) > 0.01 || abs(end - cue.timelineRange.end.seconds) > 0.01 else { return }
        session.setSubtitleTiming(cue, start: .seconds(start), end: .seconds(max(end, start + 0.1)))
    }
}

/// Size, colors, width and position; sliders preview position live and commit on release.
private struct SubtitleStyleSection: View {
    let style: SubtitleStyle
    var session: EditorSession
    @State private var draft = SubtitleStyle()

    var body: some View {
        Section("Style") {
            LabeledContent("Size") {
                HStack {
                    Slider(value: $draft.fontSize, in: 16...200, onEditingChanged: { editing in
                        if !editing { commit() }
                    })
                    Text("\(Int(draft.fontSize))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
            }
            LabeledContent("Width") {
                HStack {
                    Slider(value: $draft.maxWidth, in: SubtitleStyle.maxWidthRange, onEditingChanged: { editing in
                        if !editing { commit() }
                    })
                    Text("\(Int((draft.maxWidth * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
            Toggle("Bold", isOn: commitOnSet(\.isBold))
            ColorPicker("Color", selection: colorBinding(\.color))
            Toggle("Background", isOn: commitOnSet(\.showsBackground))
            if draft.showsBackground {
                ColorPicker("Background Color", selection: colorBinding(\.backgroundColor))
            }
            positionRow("Position X", axis: \.x)
            positionRow("Position Y", axis: \.y)
            Button("Reset Position") {
                draft.position = SubtitleStyle().position
                commit()
            }
            .disabled(style.position == SubtitleStyle().position)
        }
        .onAppear { draft = style }
        .onChange(of: style) { _, newValue in draft = newValue }
    }

    private func positionRow(_ title: String, axis: WritableKeyPath<CGPoint, CGFloat>) -> some View {
        let value = Binding(
            get: { Double(draft.position[keyPath: axis]) },
            set: { newValue in
                draft.position[keyPath: axis] = CGFloat(newValue)
                session.previewSubtitlePosition(draft.position)
            }
        )
        return VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Slider(value: value, in: -0.5...0.5, onEditingChanged: { editing in
                if !editing { session.commitSubtitlePosition(draft.position) }
            })
        }
    }

    private func commit() {
        guard draft != style else { return }
        session.setSubtitleStyle(draft)
    }

    private func commitOnSet(_ keyPath: WritableKeyPath<SubtitleStyle, Bool>) -> Binding<Bool> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: { value in
                draft[keyPath: keyPath] = value
                commit()
            }
        )
    }

    private func colorBinding(_ keyPath: WritableKeyPath<SubtitleStyle, RGBAColor>) -> Binding<Color> {
        Binding(
            get: { draft[keyPath: keyPath].color },
            set: { value in
                draft[keyPath: keyPath] = RGBAColor(value)
                commit()
            }
        )
    }
}

/// Subtitle times as "m:ss.s" (or "h:mm:ss.s"); input also accepts plain seconds.
enum SubtitleTime {
    static func format(_ seconds: Double) -> String {
        let tenths = Int((max(seconds, 0) * 10).rounded())
        let h = tenths / 36_000
        let m = (tenths / 600) % 60
        let s = (tenths % 600) / 10
        let t = tenths % 10
        return h > 0
            ? String(format: "%d:%02d:%02d.%d", h, m, s, t)
            : String(format: "%d:%02d.%d", m, s, t)
    }

    static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }
}
