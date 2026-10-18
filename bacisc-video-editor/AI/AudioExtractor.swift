import AVFoundation
import CoreMedia
import Foundation

/// Writes a stretch of a media file's audio as small mono AAC (16 kHz, 32 kbps), enough for speech recognition.
nonisolated enum AudioExtractor {
    enum ExtractionError: LocalizedError {
        case noAudioTrack

        var errorDescription: String? {
            switch self {
            case .noAudioTrack: "The media has no audio track."
            }
        }
    }

    static let fileFormat = "m4a"

    static func extract(from url: URL, range: CMTimeRange, to outputURL: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ExtractionError.noAudioTrack }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        let provider = reader.outputProvider(for: output)

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ])
        let receiver = writer.inputReceiver(for: input)

        try reader.start()
        try writer.start()
        writer.startSession(atSourceTime: range.start)
        do {
            while let buffer = try await provider.next() {
                try Task.checkCancellation()
                try await receiver.append(buffer)
            }
        } catch {
            writer.cancelWriting()
            throw error
        }
        receiver.finish()
        await writer.finishWriting()
        if writer.status == .failed { throw writer.error ?? AVError(.unknown) }
    }
}
