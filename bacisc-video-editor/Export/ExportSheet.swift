import AppKit
import AVFoundation
import CoreMedia
import EditorCore
import Foundation
import SwiftUI

/// Modal export flow: pick format and resolution, choose a file, watch progress, reveal the result.
struct ExportSheet: View {
    var session: EditorSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.documentConfiguration) private var documentConfiguration
    @AppStorage("exportFormat") private var format: ExportFormat = .h264
    @AppStorage("exportResolution") private var resolution: ExportResolution = .project
    @State private var exporter = ExportController()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export")
                .font(.title2.bold())

            switch exporter.phase {
            case .idle:
                settings
            case .exporting(let progress):
                ProgressView(value: progress) {
                    Text("Exporting \(format.title)…")
                } currentValueLabel: {
                    Text("\(Int((progress * 100).rounded()))%")
                        .monospacedDigit()
                }
            case .finished(let url):
                Label("Export complete", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(url.lastPathComponent)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Label("Export failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                buttons
            }
        }
        .padding(20)
        .frame(width: 440)
        .interactiveDismissDisabled(exporter.isExporting)
    }

    private var settings: some View {
        let project = session.project
        return Form {
            Picker("Format", selection: $format) {
                ForEach(ExportFormat.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
            Picker("Resolution", selection: $resolution) {
                ForEach(ExportResolution.allCases) { resolution in
                    let size = resolution.size(for: project.settings.renderSize)
                    Text("\(resolution.title) (\(Int(size.width))×\(Int(size.height)))").tag(resolution)
                }
            }
            .disabled(format.isAudioOnly)
            LabeledContent("Frame Rate", value: "\(project.settings.frameRate) fps")
            LabeledContent("Duration", value: project.duration.timecode(frameRate: project.settings.frameRate))
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch exporter.phase {
        case .idle:
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Export…") { chooseDestination() }
                .keyboardShortcut(.defaultAction)
        case .exporting:
            Button("Cancel", role: .cancel) { exporter.cancel() }
                .keyboardShortcut(.cancelAction)
        case .finished(let url):
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        case .failed:
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = documentConfiguration?.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        session.playback.player.pause()
        exporter.start(session.project, assets: session.assets, format: format, resolution: resolution, to: url)
    }
}
