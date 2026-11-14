import AVFoundation
import CoreMedia
import Foundation

/// Finds where a file has speech from its audio level, without transcription: stretches clearly above the
/// file's own noise floor, with short pauses bridged and short blips dropped.
nonisolated enum SpeechDetector {
    private static let sampleRate = 8000
    /// Level frames per second (20 ms each).
    private static let framesPerSecond = 50
    /// Pauses shorter than this stay inside one range.
    private static let bridgedPause = 0.3
    /// Ranges shorter than this are dropped (clicks, breaths).
    private static let shortestRange = 0.25

    /// Speech ranges in source seconds.
    static func speechRanges(in url: URL) async throws -> [ClosedRange<Double>] {
        let (levels, offset) = try await levels(in: url)
        guard !levels.isEmpty else { return [] }

        // Noise floor: the quietest tenth of the file. Speech is well above it.
        let sorted = levels.sorted()
        let floor = sorted[sorted.count / 10]
        let threshold = min(max(floor + 12, -50), -24)

        var ranges: [(start: Int, end: Int)] = []
        var start: Int?
        for (index, level) in levels.enumerated() {
            if level > threshold {
                if start == nil { start = index }
            } else if let open = start {
                ranges.append((open, index))
                start = nil
            }
        }
        if let open = start { ranges.append((open, levels.count)) }

        let frame = 1 / Double(framesPerSecond)
        var merged: [(start: Int, end: Int)] = []
        for range in ranges {
            if let last = merged.last, Double(range.start - last.end) * frame < bridgedPause {
                merged[merged.count - 1].end = range.end
            } else {
                merged.append(range)
            }
        }
        return merged
            .filter { Double($0.end - $0.start) * frame >= shortestRange }
            .map { (offset + Double($0.start) * frame)...(offset + Double($0.end) * frame) }
    }

    /// RMS level in dBFS per 20 ms frame of the first audio track (8 kHz mono), and the time of the first frame.
    private static func levels(in url: URL) async throws -> (levels: [Float], offset: Double) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return ([], 0) }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AVError(.unknown) }

        let frameSize = sampleRate / framesPerSecond
        var levels: [Float] = []
        var sum: Float = 0
        var count = 0
        var offset: Double?

        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            if offset == nil {
                let time = CMSampleBufferGetPresentationTimeStamp(buffer)
                offset = time.isNumeric ? max(0, time.seconds) : 0
            }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            samples.withUnsafeMutableBytes { bytes in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
            }
            for sample in samples {
                sum += sample * sample
                count += 1
                if count == frameSize {
                    levels.append(decibels(sum / Float(count)))
                    sum = 0
                    count = 0
                }
            }
        }
        if reader.status == .failed { throw reader.error ?? AVError(.unknown) }
        if count > 0 { levels.append(decibels(sum / Float(count))) }
        return (levels, offset ?? 0)
    }

    private static func decibels(_ meanSquare: Float) -> Float {
        10 * log10(max(meanSquare, 1e-12))
    }
}
