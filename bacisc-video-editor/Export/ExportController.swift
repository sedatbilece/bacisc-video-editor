import AVFoundation
import CoreGraphics
import CoreMedia
import EditorCore
import Foundation
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case h264, hevc, proRes, m4a

    var id: String { rawValue }

    var title: String {
        switch self {
        case .h264: "MP4 (H.264)"
        case .hevc: "MOV (HEVC)"
        case .proRes: "MOV (ProRes 422)"
        case .m4a: "M4A (audio only)"
        }
    }

    var presetName: String {
        switch self {
        case .h264: AVAssetExportPresetHighestQuality
        case .hevc: AVAssetExportPresetHEVCHighestQuality
        case .proRes: AVAssetExportPresetAppleProRes422LPCM
        case .m4a: AVAssetExportPresetAppleM4A
        }
    }

    var fileType: AVFileType {
        switch self {
        case .h264: .mp4
        case .hevc, .proRes: .mov
        case .m4a: .m4a
        }
    }

    var contentType: UTType {
        switch self {
        case .h264: .mpeg4Movie
        case .hevc, .proRes: .quickTimeMovie
        case .m4a: .mpeg4Audio
        }
    }

    var isAudioOnly: Bool { self == .m4a }
}

enum ExportResolution: String, CaseIterable, Identifiable {
    case project, hd720, hd1080, uhd4K

    var id: String { rawValue }

    var title: String {
        switch self {
        case .project: "Project"
        case .hd720: "720p"
        case .hd1080: "1080p"
        case .uhd4K: "4K"
        }
    }

    /// Keeps the project's aspect ratio; the preset sets the short side. Dimensions are even for the encoders.
    func size(for renderSize: CGSize) -> CGSize {
        let shortSide: CGFloat
        switch self {
        case .project: shortSide = min(renderSize.width, renderSize.height)
        case .hd720: shortSide = 720
        case .hd1080: shortSide = 1080
        case .uhd4K: shortSide = 2160
        }
        let current = min(renderSize.width, renderSize.height)
        guard current > 0 else { return renderSize }
        let scale = shortSide / current
        return CGSize(width: Self.even(renderSize.width * scale), height: Self.even(renderSize.height * scale))
    }

    private static func even(_ value: CGFloat) -> CGFloat {
        max(2, (value / 2).rounded() * 2)
    }
}

/// Runs one export through the shared composition builder and reports its progress.
@Observable
final class ExportController {
    enum Phase: Equatable {
        case idle
        case exporting(progress: Double)
        case finished(URL)
        case failed(String)
    }

    enum ExportError: LocalizedError {
        case emptyTimeline, unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .emptyTimeline: "The timeline is empty."
            case .unsupportedFormat: "This format cannot be exported from this project."
            }
        }
    }

    private(set) var phase: Phase = .idle
    @ObservationIgnored private var task: Task<Void, Never>?

    var isExporting: Bool {
        if case .exporting = phase { return true }
        return false
    }

    func start(_ project: Project, assets: AssetCache, format: ExportFormat, resolution: ExportResolution, to url: URL) {
        task?.cancel()
        phase = .exporting(progress: 0)
        task = Task {
            do {
                try await Self.export(project, assets: assets, format: format, resolution: resolution, to: url) { progress in
                    self.phase = .exporting(progress: progress)
                }
                phase = .finished(url)
            } catch {
                // A cancelled or failed export leaves a partial file behind.
                try? FileManager.default.removeItem(at: url)
                phase = Task.isCancelled || error is CancellationError ? .idle : .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    private static func export(
        _ project: Project,
        assets: AssetCache,
        format: ExportFormat,
        resolution: ExportResolution,
        to url: URL,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        let outputSize = resolution.size(for: project.settings.renderSize)
        guard let output = try await CompositionBuilder.build(
            project,
            assets: assets,
            liveTransforms: LiveTransforms(),
            outputSize: outputSize
        ) else { throw ExportError.emptyTimeline }
        guard let session = AVAssetExportSession(asset: output.composition, presetName: format.presetName) else {
            throw ExportError.unsupportedFormat
        }
        if !format.isAudioOnly {
            session.videoComposition = output.videoComposition
        }
        session.audioMix = output.audioMix

        // The save panel already confirmed replacing an existing file.
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let progressTask = Task {
            for await state in session.states(updateInterval: 0.1) {
                if case .exporting(let progress) = state {
                    onProgress(progress.fractionCompleted)
                }
            }
        }
        defer { progressTask.cancel() }
        try await session.export(to: url, as: format.fileType)
    }
}
