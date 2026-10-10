import AVFoundation
import EditorCore

/// Audio peak levels per media file, computed in the background and kept in memory.
@Observable
final class WaveformCache {
    /// Peaks per second of source audio.
    nonisolated static let resolution = 100

    private(set) var peaks: [MediaRef.ID: [Float]] = [:]
    @ObservationIgnored private var loading: Set<MediaRef.ID> = []

    func load(_ media: MediaRef, from assets: AssetCache) async {
        guard media.hasAudio, peaks[media.id] == nil, !loading.contains(media.id),
              let url = assets.url(for: media)
        else { return }
        loading.insert(media.id)
        defer { loading.remove(media.id) }

        let result = await Task.detached(priority: .utility) {
            try? await Self.readPeaks(url: url)
        }.value
        if let result { peaks[media.id] = result }
    }

    /// Decodes the first audio track to 8 kHz mono and keeps the max level of each bucket.
    nonisolated private static func readPeaks(url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }

        let sampleRate = 8000
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AVError(.unknown) }

        let bucketSize = sampleRate / resolution
        var peaks: [Float] = []
        var bucketMax: Int16 = 0
        var bucketCount = 0

        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            var samples = [Int16](repeating: 0, count: length / MemoryLayout<Int16>.size)
            samples.withUnsafeMutableBytes { bytes in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
            }
            for sample in samples {
                let level = sample == .min ? .max : abs(sample)
                if level > bucketMax { bucketMax = level }
                bucketCount += 1
                if bucketCount == bucketSize {
                    peaks.append(Float(bucketMax) / Float(Int16.max))
                    bucketMax = 0
                    bucketCount = 0
                }
            }
        }
        if bucketCount > 0 { peaks.append(Float(bucketMax) / Float(Int16.max)) }
        return peaks
    }
}
