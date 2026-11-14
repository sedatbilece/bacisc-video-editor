import Accelerate
import AudioToolbox
import AVFoundation
import CoreMedia
import EditorCore
import Foundation

/// Renders a media file's cleaned audio: decode at 48 kHz → optional voice isolation → optional loudness
/// normalization with a peak limiter → AAC. The result starts at the media's time zero, like the source.
nonisolated enum AudioCleanupRenderer {
    static let sampleRate: Double = 48000
    /// Peak ceiling after normalization (-1 dBFS).
    private static let ceiling: Float = 0.891
    private static let chunkFrames: AVAudioFrameCount = 48000

    enum CleanupError: LocalizedError {
        case noAudio, voiceIsolationUnavailable, renderFailed

        var errorDescription: String? {
            switch self {
            case .noAudio: "The file has no audio."
            case .voiceIsolationUnavailable: "Voice isolation is not available on this Mac."
            case .renderFailed: "The audio could not be processed."
            }
        }
    }

    static func render(source: URL, cleanup: AudioCleanup, to destination: URL) async throws {
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory.appending(path: "bacisc-cleanup-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }

        // Voice is processed in mono; music and other sound keep stereo.
        var stage = work.appending(path: "decoded.caf")
        try await decode(source, to: stage, channels: cleanup.isolatesVoice ? 1 : 2)
        if cleanup.isolatesVoice {
            let isolated = work.appending(path: "isolated.caf")
            try isolateVoice(stage, to: isolated)
            stage = isolated
        }
        let gain = cleanup.normalizesLoudness ? try normalizationGain(of: stage) : 1
        let encoded = work.appending(path: "encoded.m4a")
        try encode(stage, gain: gain, limits: cleanup.normalizesLoudness, to: encoded)

        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: encoded, to: destination)
    }

    // MARK: Decode

    /// First audio track as 48 kHz float PCM; audio that starts after zero is padded with silence.
    private static func decode(_ url: URL, to output: URL, channels: Int) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw CleanupError.noAudio }
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(readerOutput)
        guard reader.startReading() else { throw reader.error ?? CleanupError.renderFailed }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        ) else { throw CleanupError.renderFailed }
        let file = try AVAudioFile(forWriting: output, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        defer { file.close() }

        var isFirst = true
        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            if isFirst {
                isFirst = false
                let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                if time.isNumeric, time.seconds > 0 {
                    try writeSilence(frames: AVAudioFrameCount(time.seconds * sampleRate), format: format, to: file)
                }
            }
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let frames = CMBlockBufferGetDataLength(block) / (MemoryLayout<Float>.size * channels)
            guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let destination = pcm.floatChannelData
            else { continue }
            var interleaved = [Float](repeating: 0, count: frames * channels)
            interleaved.withUnsafeMutableBytes { bytes in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
            }
            for channel in 0..<channels {
                let samples = destination[channel]
                for frame in 0..<frames {
                    samples[frame] = interleaved[frame * channels + channel]
                }
            }
            pcm.frameLength = AVAudioFrameCount(frames)
            try file.write(from: pcm)
        }
        if reader.status == .failed { throw reader.error ?? CleanupError.renderFailed }
    }

    private static func writeSilence(frames: AVAudioFrameCount, format: AVAudioFormat, to file: AVAudioFile) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames), let data = buffer.floatChannelData else { return }
        for channel in 0..<Int(format.channelCount) {
            data[channel].update(repeating: 0, count: Int(chunkFrames))
        }
        var remaining = frames
        while remaining > 0 {
            let count = min(remaining, chunkFrames)
            buffer.frameLength = count
            try file.write(from: buffer)
            remaining -= count
        }
    }

    // MARK: Voice isolation

    /// Runs Apple's sound isolation unit (high-quality voice) offline; its latency is trimmed so speech stays in sync.
    private static func isolateVoice(_ input: URL, to output: URL) throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_AUSoundIsolation,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard AudioComponentFindNext(nil, &description) != nil else { throw CleanupError.voiceIsolationUnavailable }

        let source = try AVAudioFile(forReading: input)
        let format = source.processingFormat
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let isolation = AVAudioUnitEffect(audioComponentDescription: description)
        AudioUnitSetParameter(
            isolation.audioUnit,
            AudioUnitParameterID(kAUSoundIsolationParam_WetDryMixPercent),
            kAudioUnitScope_Global, 0, 100, 0
        )
        AudioUnitSetParameter(
            isolation.audioUnit,
            AudioUnitParameterID(kAUSoundIsolationParam_SoundToIsolate),
            kAudioUnitScope_Global, 0, AudioUnitParameterValue(kAUSoundIsolationSoundType_HighQualityVoice), 0
        )

        engine.attach(player)
        engine.attach(isolation)
        engine.connect(player, to: isolation, format: format)
        engine.connect(isolation, to: engine.mainMixerNode, format: format)
        player.scheduleFile(source, at: nil)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        player.play()
        defer {
            player.stop()
            engine.stop()
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount)
        else { throw CleanupError.renderFailed }
        let file = try AVAudioFile(forWriting: output, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        defer { file.close() }

        let total = source.length
        let latency = AVAudioFramePosition((max(isolation.latency, isolation.auAudioUnit.latency) * format.sampleRate).rounded())
        var rendered: AVAudioFramePosition = 0
        var written: AVAudioFramePosition = 0
        while written < total {
            try Task.checkCancellation()
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(buffer.frameCapacity), total + latency - rendered))
            guard try engine.renderOffline(frames, to: buffer) == .success else { throw CleanupError.renderFailed }
            // The first `latency` frames are the unit's delay, not audio.
            let skip = max(0, latency - rendered)
            rendered += AVAudioFramePosition(buffer.frameLength)
            let usable = AVAudioFramePosition(buffer.frameLength) - skip
            guard usable > 0 else { continue }
            let count = min(usable, total - written)
            if let slice = slice(buffer, from: skip, count: count) {
                try file.write(from: slice)
            }
            written += count
        }
    }

    private static func slice(_ buffer: AVAudioPCMBuffer, from start: AVAudioFramePosition, count: AVAudioFramePosition) -> AVAudioPCMBuffer? {
        if start == 0, count == AVAudioFramePosition(buffer.frameLength) { return buffer }
        guard let result = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(count)),
              let source = buffer.floatChannelData, let destination = result.floatChannelData
        else { return nil }
        for channel in 0..<Int(buffer.format.channelCount) {
            destination[channel].update(from: source[channel] + Int(start), count: Int(count))
        }
        result.frameLength = AVAudioFrameCount(count)
        return result
    }

    // MARK: Loudness

    /// Gain that brings the file to the target integrated loudness (ITU-R BS.1770: K-weighting, 400 ms gated blocks).
    private static func normalizationGain(of url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        guard format.sampleRate == sampleRate, channels > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames)
        else { throw CleanupError.renderFailed }

        // K-weighting at 48 kHz: high shelf, then high-pass ([b0, b1, b2, a1, a2] per section).
        let coefficients: [Double] = [
            1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585,
            1.0, -2.0, 1.0, -1.99004745483398, 0.99007225036621,
        ]
        var filters: [vDSP.Biquad<Float>] = []
        for _ in 0..<channels {
            guard let filter = vDSP.Biquad(coefficients: coefficients, channelCount: 1, sectionCount: 2, ofType: Float.self)
            else { throw CleanupError.renderFailed }
            filters.append(filter)
        }
        // A mono file plays on both speakers, so it counts twice.
        let channelWeight = channels == 1 ? 2.0 : 1.0
        let subBlockFrames = Int(sampleRate / 10)
        var subBlocks: [Double] = []
        var energy = 0.0
        var count = 0

        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: chunkFrames)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            var squares = [Double](repeating: 0, count: frames)
            for channel in 0..<channels {
                let weighted = filters[channel].apply(input: UnsafeBufferPointer(start: data[channel], count: frames))
                for frame in 0..<frames {
                    squares[frame] += Double(weighted[frame] * weighted[frame])
                }
            }
            for square in squares {
                energy += square
                count += 1
                if count == subBlockFrames {
                    subBlocks.append(energy * channelWeight / Double(subBlockFrames))
                    energy = 0
                    count = 0
                }
            }
        }
        guard subBlocks.count >= 4 else { return 1 }

        // 400 ms blocks, 75 % overlap; absolute gate at -70 LUFS, relative gate 10 LU below.
        let blocks = (0...(subBlocks.count - 4)).map { (subBlocks[$0] + subBlocks[$0 + 1] + subBlocks[$0 + 2] + subBlocks[$0 + 3]) / 4 }
        func loudness(_ meanSquare: Double) -> Double { -0.691 + 10 * log10(max(meanSquare, 1e-12)) }
        func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(values.count) }
        let audible = blocks.filter { loudness($0) > -70 }
        guard !audible.isEmpty else { return 1 }
        let relativeGate = loudness(mean(audible)) - 10
        let gated = audible.filter { loudness($0) > relativeGate }
        let integrated = loudness(mean(gated.isEmpty ? audible : gated))

        // Quiet recordings get at most +24 dB so noise is not blown up.
        let change = min(max(AudioCleanup.targetLoudness - integrated, -20), 24)
        return Float(pow(10, change / 20))
    }

    // MARK: Encode

    /// Applies the gain (and the limiter) and writes AAC.
    private static func encode(_ url: URL, gain: Float, limits: Bool, to output: URL) throws {
        let input = try AVAudioFile(forReading: url)
        let format = input.processingFormat
        let channels = Int(format.channelCount)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 1 ? 128_000 : 192_000,
        ]
        let file = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        defer { file.close() }

        var limiter = PeakLimiter(ceiling: ceiling, sampleRate: sampleRate)
        // Each read carries the limiter's look-ahead past the frames it writes.
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames + AVAudioFrameCount(limiter.lookahead))
        else { throw CleanupError.renderFailed }

        var position: AVAudioFramePosition = 0
        while position < input.length {
            try Task.checkCancellation()
            input.framePosition = position
            try input.read(into: buffer, frameCount: buffer.frameCapacity)
            let available = Int(buffer.frameLength)
            guard available > 0, let data = buffer.floatChannelData else { break }
            let count = min(Int(chunkFrames), available)
            if gain != 1 {
                for channel in 0..<channels {
                    vDSP_vsmul(data[channel], 1, [gain], data[channel], 1, vDSP_Length(available))
                }
            }
            if limits {
                limiter.process(data, channels: channels, count: count, available: available)
            }
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
            position += AVAudioFramePosition(count)
        }
    }
}

/// Look-ahead peak limiter: the gain drops smoothly before a peak would pass the ceiling and recovers slowly.
nonisolated private struct PeakLimiter {
    let ceiling: Float
    /// Look-ahead in frames (5 ms).
    let lookahead: Int
    /// Per-frame recovery toward unity gain (150 ms).
    private let release: Float
    private var level: Float = 1
    /// The last `lookahead + 1` released gains; their average is applied.
    private var history: [Float]
    private var historyIndex = 0

    init(ceiling: Float, sampleRate: Double) {
        self.ceiling = ceiling
        lookahead = Int(sampleRate * 0.005)
        release = Float(1 - exp(-1 / (sampleRate * 0.15)))
        history = Array(repeating: 1, count: lookahead + 1)
    }

    /// Limits the first `count` frames in place; frames up to `available` are only looked at.
    mutating func process(_ data: UnsafePointer<UnsafeMutablePointer<Float>>, channels: Int, count: Int, available: Int) {
        var needed = [Float](repeating: 1, count: available)
        for frame in 0..<available {
            var peak: Float = 0
            for channel in 0..<channels {
                peak = max(peak, abs(data[channel][frame]))
            }
            if peak > ceiling { needed[frame] = ceiling / peak }
        }

        // Smallest needed gain in [frame, frame + lookahead], with a monotonic queue.
        var windowMin = [Float](repeating: 1, count: count)
        var queue: [Int] = []
        queue.reserveCapacity(available)
        var head = 0
        for next in 0..<available {
            while queue.count > head, needed[queue[queue.count - 1]] >= needed[next] {
                queue.removeLast()
            }
            queue.append(next)
            let frame = next - lookahead
            if frame >= 0, frame < count {
                while queue[head] < frame { head += 1 }
                windowMin[frame] = needed[queue[head]]
            }
        }
        // At the end of the file the window runs out before `lookahead` frames.
        for frame in max(0, available - lookahead)..<count {
            while queue[head] < frame { head += 1 }
            windowMin[frame] = needed[queue[head]]
        }

        // Averaging over the look-ahead length keeps every frame at or under the gain it needs.
        var sum = history.reduce(0, +)
        for frame in 0..<count {
            level = windowMin[frame] < level ? windowMin[frame] : level + (windowMin[frame] - level) * release
            sum += level - history[historyIndex]
            history[historyIndex] = level
            historyIndex = (historyIndex + 1) % history.count
            let gain = min(1, sum / Float(history.count))
            for channel in 0..<channels {
                data[channel][frame] = min(max(data[channel][frame] * gain, -1), 1)
            }
        }
    }
}
