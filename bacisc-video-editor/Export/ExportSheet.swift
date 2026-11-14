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
    /// Frame format to export; starts at the one shown in the preview.
    @State private var frameFormat: AspectFormat?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export")
                .font(.title2.bold())

            switch exporter.phase {
            case .idle:
                settings
            case .preparingAudio:
                ProgressView {
                    Text("Preparing audio…")
                }
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
            case .failed(let report):
                Label("Export failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(report.message)
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
        .onAppear { frameFormat = session.activeFormat }
    }

    private var settings: some View {
        let project = session.project
        let frameSize = project.frameSize(for: frameFormat)
        return Form {
            FormatPicker(project: project, selection: $frameFormat, title: "Frame")
                .disabled(format.isAudioOnly)
            Picker("File Format", selection: $format) {
                ForEach(ExportFormat.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
            Picker("Resolution", selection: $resolution) {
                ForEach(ExportResolution.allCases) { resolution in
                    let size = resolution.size(for: frameSize)
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
        case .preparingAudio, .exporting:
            Button("Cancel", role: .cancel) { exporter.cancel() }
                .keyboardShortcut(.cancelAction)
        case .finished(let url):
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        case .failed(let report):
            Button("Copy Details") { report.copyToPasteboard() }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        let name = documentConfiguration?.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        // Other formats than the project frame get their shape in the name, e.g. "Trip 9x16".
        let suffix = session.project.layoutFormat(frameFormat).map { " \($0.ratio.width)x\($0.ratio.height)" } ?? ""
        panel.nameFieldStringValue = name + (format.isAudioOnly ? "" : suffix)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        session.playback.player.pause()
        exporter.start(
            session.project,
            frameFormat: frameFormat,
            assets: session.assets,
            audio: session.audio,
            format: format,
            resolution: resolution,
            to: url
        )
    }
}
