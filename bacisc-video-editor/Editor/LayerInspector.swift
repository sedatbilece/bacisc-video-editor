import AppKit
import CoreMedia
import EditorCore
import Foundation
import SwiftUI

/// Text content and style. Edits are committed after a short pause so typing is not one undo step per key.
struct TextSection: View {
    let clip: Clip
    let text: TextLayer
    var session: EditorSession
    @State private var draft = TextLayer()
    @State private var committed = TextLayer()
    @FocusState private var isEditing: Bool

    private static let families = NSFontManager.shared.availableFontFamilies

    var body: some View {
        Section("Text") {
            TextEditor(text: $draft.string)
                .font(.body)
                .frame(minHeight: 60, maxHeight: 120)
                .focused($isEditing)

            Picker("Font", selection: $draft.fontFamily) {
                ForEach(Self.families, id: \.self) { family in
                    Text(family).tag(family)
                }
            }

            LabeledContent("Size") {
                HStack {
                    Slider(value: $draft.fontSize, in: 12...300)
                    Text("\(Int(draft.fontSize))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
            }

            Toggle("Bold", isOn: $draft.isBold)
            ColorPicker("Color", selection: colorBinding(\.color))

            Picker("Alignment", selection: $draft.alignment) {
                Image(systemName: "text.alignleft").tag(TextLayerAlignment.leading)
                Image(systemName: "text.aligncenter").tag(TextLayerAlignment.center)
                Image(systemName: "text.alignright").tag(TextLayerAlignment.trailing)
            }
            .pickerStyle(.segmented)

            Toggle("Background", isOn: $draft.showsBackground)
            if draft.showsBackground {
                ColorPicker("Background Color", selection: colorBinding(\.backgroundColor))
            }
        }
        .onAppear {
            draft = text
            committed = text
        }
        .onChange(of: text) { _, newValue in
            // Undo/redo or another edit; our own commits are ignored.
            guard newValue != committed else { return }
            draft = newValue
            committed = newValue
        }
        .task(id: draft) {
            guard draft != committed else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            commit()
        }
        .onChange(of: isEditing) { _, editing in
            session.isEditingText = editing
        }
        .onDisappear {
            session.isEditingText = false
            if draft != committed { commit() }
        }
    }

    private func commit() {
        committed = draft
        session.setText(draft, for: clip.id)
    }

    private func colorBinding(_ keyPath: WritableKeyPath<TextLayer, RGBAColor>) -> Binding<Color> {
        Binding(
            get: { draft[keyPath: keyPath].color },
            set: { draft[keyPath: keyPath] = RGBAColor($0) }
        )
    }
}

/// Position, scale, rotation and opacity. Sliders preview live and commit on release.
struct TransformSection: View {
    let clip: Clip
    var session: EditorSession
    /// Corner and square crop are for media clips (video, image), not text.
    var showsShape = true
    @State private var draft = ClipTransform.identity

    var body: some View {
        let renderSize = session.project.settings.renderSize
        Section("Transform") {
            row("Position X", -1...1, { Double($0.position.x) }, { $0.position.x = CGFloat($1) }) {
                "\(Int(($0 * Double(renderSize.width)).rounded())) px"
            }
            row("Position Y", -1...1, { Double($0.position.y) }, { $0.position.y = CGFloat($1) }) {
                "\(Int(($0 * Double(renderSize.height)).rounded())) px"
            }
            row("Scale", 0.05...4, { $0.scale }, { $0.scale = $1 }) { "\(Int(($0 * 100).rounded()))%" }
            row("Rotation", -180...180, { $0.rotation }, { $0.rotation = $1 }) { "\(Int($0.rounded()))°" }
            row("Opacity", 0...1, { $0.opacity }, { $0.opacity = $1 }) { "\(Int(($0 * 100).rounded()))%" }

            if showsShape {
                // 0–50: percent of the short side; 50 is fully round (a circle with Square Crop).
                row("Corner", ClipTransform.cornerRadiusRange, { $0.cornerRadius }, { $0.cornerRadius = $1 }) {
                    "\(Int(($0 * 100).rounded()))"
                }
                Toggle("Square Crop", isOn: Binding(
                    get: { draft.squareCrop },
                    set: { value in
                        draft.squareCrop = value
                        session.setTransform(draft, for: [clip.id])
                    }
                ))
                .help("Crop to a centered square; with Corner 50 it becomes a circle")
            }

            Button("Reset Transform") {
                draft = .identity
                session.setTransform(.identity, for: [clip.id])
            }
            .disabled(clip.transform == .identity)
        }
        .onAppear { draft = clip.transform }
        .onChange(of: clip.transform) { _, newValue in draft = newValue }
    }

    private func row(
        _ title: String,
        _ range: ClosedRange<Double>,
        _ get: @escaping (ClipTransform) -> Double,
        _ set: @escaping (inout ClipTransform, Double) -> Void,
        label: @escaping (Double) -> String
    ) -> some View {
        let value = Binding(
            get: { get(draft) },
            set: { newValue in
                set(&draft, newValue)
                session.previewTransform(draft, for: clip.id)
            }
        )
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(label(value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, onEditingChanged: { editing in
                if !editing { session.commitTransform(draft, for: clip.id) }
            })
        }
    }
}

/// Opacity fade at the start and end of a visual clip.
struct FadeSection: View {
    let clip: Clip
    var session: EditorSession

    var body: some View {
        let length = max(0, clip.duration.seconds)
        Section("Fade") {
            Stepper(value: fadeBinding(isIn: true), in: 0...length, step: 0.25) {
                LabeledContent("Fade In", value: String(format: "%.2f s", clip.fadeIn))
            }
            Stepper(value: fadeBinding(isIn: false), in: 0...length, step: 0.25) {
                LabeledContent("Fade Out", value: String(format: "%.2f s", clip.fadeOut))
            }
        }
    }

    private func fadeBinding(isIn: Bool) -> Binding<Double> {
        Binding(
            get: { isIn ? clip.fadeIn : clip.fadeOut },
            set: { value in
                session.setFades(in: isIn ? value : clip.fadeIn, out: isIn ? clip.fadeOut : value, for: [clip.id])
            }
        )
    }
}

extension RGBAColor {
    var color: Color { Color(nsColor: nsColor) }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(
            red: Double(ns.redComponent),
            green: Double(ns.greenComponent),
            blue: Double(ns.blueComponent),
            alpha: Double(ns.alphaComponent)
        )
    }
}
