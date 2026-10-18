import CoreMedia
import EditorCore
import Foundation

/// Transcribes a track: extracts each used stretch of its media's audio, sends it to OpenRouter
/// and turns the timestamps into subtitle segments in source time.
@Observable
final class TranscriptionController {
    enum Phase: Equatable {
        case idle
        case running(status: String, progress: Double)
        case failed(ErrorReport)
    }

    struct Result {
        let trackID: Track.ID
        let segments: [SubtitleSegment]
        let language: String?
    }

    enum TranscriptionError: LocalizedError {
        case nothingToTranscribe, mediaOffline(String), noTimestamps(model: String)

        var errorDescription: String? {
            switch self {
            case .nothingToTranscribe:
                "The track has no clips with audio."
            case .mediaOffline(let name):
                "\(name) is offline. Relink it and try again."
            case .noTimestamps(let model):
                "\(model) returned text without timestamps. Choose another model in Settings > AI > Speech to Text."
            }
        }
    }

    private(set) var phase: Phase = .idle
    @ObservationIgnored private var task: Task<Void, Never>?

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    func start(
        _ project: Project,
        trackID: Track.ID,
        assets: AssetCache,
        model: String,
        language: String?,
        onFinish: @escaping (Result) -> Void
    ) {
        task?.cancel()
        phase = .running(status: "Preparing…", progress: 0)
        task = Task {
            do {
                let result = try await transcribe(project, trackID: trackID, assets: assets, model: model, language: language)
                phase = .idle
                onFinish(result)
            } catch {
                phase = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
                    ? .idle
                    : .failed(ErrorReport(title: "Transcription Failed", error: error))
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// Back to the settings after a failure.
    func reset() {
        if !isRunning { phase = .idle }
    }

    private func transcribe(
        _ project: Project,
        trackID: Track.ID,
        assets: AssetCache,
        model: String,
        language: String?
    ) async throws -> Result {
        let client = try OpenRouterClient.configured()
        let ranges = project.transcriptionRanges(forTrack: trackID)
        guard !ranges.isEmpty else { throw TranscriptionError.nothingToTranscribe }

        var segments: [SubtitleSegment] = []
        var detectedLanguage: String?
        let steps = Double(ranges.count * 2)
        let audioURL = FileManager.default.temporaryDirectory.appending(path: "bacisc-transcribe-\(UUID().uuidString).\(AudioExtractor.fileFormat)")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        for (index, item) in ranges.enumerated() {
            guard let media = project.mediaRef(id: item.mediaID) else { continue }
            guard let url = assets.url(for: media) else { throw TranscriptionError.mediaOffline(media.name) }
            let part = ranges.count > 1 ? " (\(index + 1) of \(ranges.count))" : ""

            phase = .running(status: "Extracting audio\(part)…", progress: Double(index * 2) / steps)
            try await AudioExtractor.extract(from: url, range: item.range, to: audioURL)
            try Task.checkCancellation()
            let audio = try Data(contentsOf: audioURL)

            phase = .running(status: "Transcribing\(part)…", progress: Double(index * 2 + 1) / steps)
            let transcription = try await client.transcribe(audio: audio, format: AudioExtractor.fileFormat, model: model, language: language)
            try Task.checkCancellation()

            detectedLanguage = detectedLanguage ?? transcription.language
            let offset = item.range.start.seconds
            let end = item.range.end.seconds
            segments += try Self.cues(from: transcription, model: model).compactMap { cue in
                let start = cue.start + offset
                guard start < end else { return nil }
                return SubtitleSegment(mediaID: media.id, start: start, end: min(cue.end + offset, end), text: cue.text)
            }
        }
        return Result(trackID: trackID, segments: segments, language: detectedLanguage ?? language)
    }

    /// Word timings when the model gives them (tighter cues), otherwise its segments.
    private static func cues(from transcription: OpenRouterClient.Transcription, model: String) throws -> [SubtitleSegmenter.TimedText] {
        let words = (transcription.words ?? [])
            .filter { $0.type == nil || $0.type == "word" }
            .map { SubtitleSegmenter.TimedText(start: $0.start, end: $0.end, text: $0.word) }
        if !words.isEmpty { return SubtitleSegmenter.cues(fromWords: words) }

        let segments = (transcription.segments ?? [])
            .map { SubtitleSegmenter.TimedText(start: $0.start, end: $0.end, text: $0.text) }
        if !segments.isEmpty { return SubtitleSegmenter.cues(fromSegments: segments) }

        // Silence legitimately returns no text; text without timings is unusable.
        if transcription.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        throw TranscriptionError.noTimestamps(model: model)
    }
}
