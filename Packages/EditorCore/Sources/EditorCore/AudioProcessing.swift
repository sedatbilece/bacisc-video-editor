import CoreMedia
import Foundation

/// Per-clip audio cleanup, rendered once into a cached file by the app.
public struct AudioCleanup: Codable, Hashable, Sendable {
    /// Apple's voice isolation: keeps speech, removes background noise.
    public var isolatesVoice: Bool
    /// Brings the clip to `targetLoudness` with a peak limiter.
    public var normalizesLoudness: Bool

    public init(isolatesVoice: Bool = false, normalizesLoudness: Bool = false) {
        self.isolatesVoice = isolatesVoice
        self.normalizesLoudness = normalizesLoudness
    }

    public static let off = AudioCleanup()
    /// Integrated loudness in LUFS (YouTube, Shorts, Reels).
    public static let targetLoudness: Double = -14

    public var isActive: Bool { isolatesVoice || normalizesLoudness }
}

/// Lowers an audio track (music) while another track has speech.
public struct Ducking: Codable, Equatable, Sendable {
    public var voiceTrackID: Track.ID
    /// Gain change during speech in dB (negative).
    public var amount: Double

    public init(voiceTrackID: Track.ID, amount: Double = -12) {
        self.voiceTrackID = voiceTrackID
        self.amount = amount
    }

    public static let amountRange: ClosedRange<Double> = -30 ... -3
    /// Ramp lengths in seconds: down before speech starts, back up after it ends.
    public static let attack: Double = 0.25
    public static let release: Double = 0.6
    /// Speech pauses shorter than this keep the music down.
    public static let holdGap: Double = 0.8

    public var gain: Float { Float(pow(10, amount / 20)) }
}

/// A gain envelope point: linear ramps between points, 1 before the first and after the last.
public struct GainPoint: Equatable, Sendable {
    public let time: CMTime
    public let gain: Float

    public init(time: CMTime, gain: Float) {
        self.time = time
        self.gain = gain
    }
}

extension Project {
    /// Sets cleanup on the clips and the clips linked to them.
    public mutating func setAudioCleanup(_ cleanup: AudioCleanup, for clipIDs: Set<Clip.ID>) {
        let ids = clipIDs.reduce(into: Set<Clip.ID>()) { $0.formUnion(linkedClipIDs(of: $1)) }
        for t in tracks.indices {
            for c in tracks[t].clips.indices where ids.contains(tracks[t].clips[c].id) {
                tracks[t].clips[c].audioCleanup = cleanup
            }
        }
    }

    /// Ducks an audio track under a voice track; nil removes it.
    public mutating func setDucking(_ ducking: Ducking?, onTrack trackID: Track.ID) {
        guard let t = trackIndex(id: trackID), tracks[t].kind == .audio else { return }
        guard var value = ducking, value.voiceTrackID != trackID else {
            tracks[t].ducking = nil
            return
        }
        value.amount = min(max(value.amount, Ducking.amountRange.lowerBound), Ducking.amountRange.upperBound)
        tracks[t].ducking = value
    }

    /// Clips whose audio is heard on a track: not muted by detaching, with an audio source.
    public func audibleClips(onTrack trackID: Track.ID) -> [Clip] {
        guard let track = tracks.first(where: { $0.id == trackID }) else { return [] }
        return track.clips.filter { clip in
            clip.text == nil && !clip.isAudioDetached && mediaRef(id: clip.mediaID)?.hasAudio == true
        }
    }

    /// Timeline ranges with speech on a track, from speech ranges per media file in source seconds.
    /// Ranges closer than `Ducking.holdGap` are merged.
    public func speechRanges(onTrack trackID: Track.ID, speech: [MediaRef.ID: [ClosedRange<Double>]]) -> [CMTimeRange] {
        var ranges: [(start: Double, end: Double)] = []
        for clip in audibleClips(onTrack: trackID) {
            guard let mediaID = clip.mediaID, let segments = speech[mediaID] else { continue }
            let sourceStart = clip.sourceRange.start.seconds
            let sourceEnd = clip.sourceRange.end.seconds
            let shift = clip.timelineStart.seconds - sourceStart
            for segment in segments where segment.upperBound > sourceStart && segment.lowerBound < sourceEnd {
                ranges.append((max(segment.lowerBound, sourceStart) + shift, min(segment.upperBound, sourceEnd) + shift))
            }
        }
        ranges.sort { $0.start < $1.start }

        var merged: [(start: Double, end: Double)] = []
        for range in ranges {
            if let last = merged.last, range.start - last.end < Ducking.holdGap {
                merged[merged.count - 1].end = max(last.end, range.end)
            } else {
                merged.append(range)
            }
        }
        return merged.map {
            CMTimeRange(start: CMTime(seconds: $0.start, preferredTimescale: 600), end: CMTime(seconds: $0.end, preferredTimescale: 600))
        }
    }

    /// Gain points that ramp down to `gain` before each speech range and back up after it.
    public static func duckingEnvelope(speech: [CMTimeRange], gain: Float) -> [GainPoint] {
        let attack = CMTime(seconds: Ducking.attack, preferredTimescale: 600)
        let release = CMTime(seconds: Ducking.release, preferredTimescale: 600)
        // Ramps of neighbouring ranges must not overlap: merge ranges whose ramps would touch.
        var spans: [(start: CMTime, end: CMTime)] = []
        for range in speech.sorted(by: { $0.start < $1.start }) {
            if let last = spans.last, range.start - attack <= last.end + release {
                spans[spans.count - 1].end = max(last.end, range.end)
            } else {
                spans.append((range.start, range.end))
            }
        }
        return spans.flatMap { span in
            [
                GainPoint(time: span.start - attack, gain: 1),
                GainPoint(time: span.start, gain: gain),
                GainPoint(time: span.end, gain: gain),
                GainPoint(time: span.end + release, gain: 1),
            ]
        }
    }

    /// The envelope's gain at a time.
    public static func gain(of envelope: [GainPoint], at time: CMTime) -> Float {
        guard let next = envelope.firstIndex(where: { $0.time > time }) else { return envelope.last?.gain ?? 1 }
        guard next > 0 else { return 1 }
        let a = envelope[next - 1]
        let b = envelope[next]
        let span = (b.time - a.time).seconds
        guard span > 0 else { return b.gain }
        let fraction = Float((time - a.time).seconds / span)
        return a.gain + (b.gain - a.gain) * fraction
    }
}
