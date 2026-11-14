import EditorCore
import SwiftUI

/// A small outline of a frame shape.
struct FrameShapeIcon: View {
    let width: CGFloat
    let height: CGFloat
    var size: CGFloat = 40

    var body: some View {
        let scale = size / max(width, height, 1)
        RoundedRectangle(cornerRadius: 3)
            .strokeBorder(lineWidth: 2)
            .frame(width: width * scale, height: height * scale)
            .frame(width: size, height: size)
    }
}

/// Asks a new document for its frame format; the choice is remembered for the next project.
struct NewProjectSheet: View {
    let document: ProjectDocument
    @Environment(\.dismiss) private var dismiss
    @AppStorage("newProjectAspect") private var aspect: AspectFormat = .widescreen

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Project")
                .font(.title2.bold())
            Text("Choose the frame of the project. You can preview and export the other formats too, each with its own layout.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                ForEach(AspectFormat.allCases) { format in
                    let size = format.size()
                    Button {
                        aspect = format
                    } label: {
                        VStack(spacing: 6) {
                            FrameShapeIcon(width: size.width, height: size.height, size: 44)
                            Text(format.title)
                                .font(.headline)
                            Text(format.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Text("\(Int(size.width))×\(Int(size.height))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 110, height: 130)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(aspect == format ? Color.accentColor.opacity(0.15) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(aspect == format ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: aspect == format ? 2 : 1)
                    )
                }
            }

            HStack {
                Spacer()
                Button("Create") {
                    document.setUpNewProject(aspect: aspect)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .interactiveDismissDisabled()
    }
}

/// Asks how media of another shape fills the project frame.
struct FitModeSheet: View {
    var session: EditorSession
    let request: EditorSession.PendingAdd
    @State private var remember = false

    var body: some View {
        let project = session.project
        let frame = project.settings.renderSize
        let media = request.mediaIDs.compactMap { project.mediaRef(id: $0) }
            .first { $0.kind != .audio && project.needsFitMode(forContentSize: $0.naturalSize) }

        VStack(alignment: .leading, spacing: 16) {
            Text("Fit to \(project.settings.aspect?.title ?? "Project") Frame")
                .font(.title2.bold())
            if let media {
                Text("\(media.name) is \(Int(media.naturalSize.width))×\(Int(media.naturalSize.height)), the project frame is \(Int(frame.width))×\(Int(frame.height)). How should it fill the frame?")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                ForEach(FitMode.allCases) { mode in
                    Button {
                        session.completePendingAdd(fitMode: mode, remember: remember)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: icon(for: mode))
                                .font(.title)
                                .frame(height: 32)
                            Text(mode.title)
                                .font(.headline)
                            Text(detail(for: mode))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(width: 130, height: 120)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                }
            }

            Toggle("Remember for this project", isOn: $remember)
                .help("Change it later in the inspector when no clip is selected")

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    session.completePendingAdd(fitMode: nil, remember: false)
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
    }

    private func icon(for mode: FitMode) -> String {
        switch mode {
        case .fit: "rectangle.inset.filled"
        case .fill: "crop"
        case .manual: "hand.draw"
        }
    }

    private func detail(for mode: FitMode) -> String {
        switch mode {
        case .fit: "Whole picture, bars on the sides"
        case .fill: "Covers the frame, edges cropped"
        case .manual: "Original size, place it yourself"
        }
    }
}

/// Picks a format: the project frame (nil) or another shape. Used by the preview and the export sheet.
struct FormatPicker: View {
    let project: Project
    @Binding var selection: AspectFormat?
    var title = "Format"

    var body: some View {
        Picker(title, selection: $selection) {
            if project.settings.aspect == nil {
                let size = project.settings.renderSize
                Text("Project (\(Int(size.width))×\(Int(size.height)))").tag(AspectFormat?.none)
            }
            ForEach(AspectFormat.allCases) { format in
                let size = project.frameSize(for: format)
                let isProject = project.layoutFormat(format) == nil
                Text("\(format.title)\(isProject ? " (Project)" : "")  \(Int(size.width))×\(Int(size.height))")
                    .tag(project.layoutFormat(format))
            }
        }
    }
}
