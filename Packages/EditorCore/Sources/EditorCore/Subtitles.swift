import CoreGraphics
import CoreMedia
import Foundation

/// One transcribed phrase. Timed in its media's source seconds so it follows clips through edits.
public struct SubtitleSegment: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var mediaID: MediaRef.ID
    public var start: Double
    public var end: Double
    public var text: String

    public init(id: UUID = UUID(), mediaID: MediaRef.ID, start: Double, end: Double, text: String) {
        self.id = id
        self.mediaID = mediaID
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Look and placement of the subtitles. Sizes are in render pixels.
public struct SubtitleStyle: Codable, Equatable, Sendable {
    /// Bottom center of the subtitle box as an offset from the frame center, a fraction of the render size (y down).
    public var position: CGPoint
    public var fontSize: Double
    public var isBold: Bool
    public var color: RGBAColor
    public var showsBackground: Bool
    public var backgroundColor: RGBAColor
    /// Lines wrap at this fraction of the frame width.
    public var maxWidth: Double

    public init(
        position: CGPoint = CGPoint(x: 0, y: 0.44),
        fontSize: Double = 54,
        isBold: Bool = true,
        color: RGBAColor = .white,
        showsBackground: Bool = true,
        backgroundColor: RGBAColor = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.6),
        maxWidth: Double = 0.8
    ) {
        self.position = position
        self.fontSize = fontSize
        self.isBold = isBold
        self.color = color
        self.showsBackground = showsBackground
        self.backgroundColor = backgroundColor
        self.maxWidth = maxWidth
    }

    public static let maxWidthRange: ClosedRange<Double> = 0.2...1
}

/// The project's transcript and how it is shown. One set per project; transcribing again replaces it.
public struct Subtitles: Codable, Equatable, Sendable {
    /// The track whose clips place the segments on the timeline.
    public var trackID: Track.ID
    public var segments: [SubtitleSegment]
    /// ISO-639-1 code reported by the transcription, if any.
    public var language: String?
    public var isVisible: Bool
    public var style: SubtitleStyle

    public init(
        trackID: Track.ID,
        segments: [SubtitleSegment],
        language: String? = nil,
        isVisible: Bool = true,
        style: SubtitleStyle = .init()
    ) {
        self.trackID = trackID
        self.segments = segments
        self.language = language
        self.isVisible = isVisible
        self.style = style
    }
}

/// A segment as it appears on the timeline through one clip. A segment cut by a clip edge shows only the kept part.
public struct SubtitleCue: Identifiable, Equatable, Sendable {
    public let segmentID: SubtitleSegment.ID
    public let clipID: Clip.ID
    public let timelineRange: CMTimeRange
    public let text: String

    public var id: String { "\(segmentID)-\(clipID)" }
}

/// Source audio to transcribe: a merged stretch of one media file.
public struct TranscriptionRange: Equatable, Sendable {
    public let mediaID: MediaRef.ID
    public let range: CMTimeRange
}

extension Project {
    /// Subtitle cues in timeline order, from the segments and the clips of the subtitle track.
    public var subtitleCues: [SubtitleCue] {
        guard let subtitles, let t = trackIndex(id: subtitles.trackID) else { return [] }
        let byMedia = Dictionary(grouping: subtitles.segments, by: \.mediaID)
        var cues: [SubtitleCue] = []
        for clip in tracks[t].clips where clip.text == nil {
            guard let mediaID = clip.mediaID, let segments = byMedia[mediaID] else { continue }
            let sourceStart = clip.sourceRange.start.seconds
            let sourceEnd = clip.sourceRange.end.seconds
            for segment in segments {
                let start = max(segment.start, sourceStart)
                let end = min(segment.end, sourceEnd)
                // Slivers left by a cut are not worth showing.
                guard end - start >= 0.1 else { continue }
                let timelineStart = clip.timelineStart + Self.time(start - sourceStart)
                cues.append(SubtitleCue(
                    segmentID: segment.id,
                    clipID: clip.id,
                    timelineRange: CMTimeRange(start: timelineStart, duration: Self.time(end - start)),
                    text: segment.text
                ))
            }
        }
        return cues.sorted { $0.timelineRange.start < $1.timelineRange.start }
    }

    /// Source stretches to transcribe for a track: per media with audio, clip ranges merged across short gaps.
    public func transcriptionRanges(forTrack trackID: Track.ID, mergingGapsUpTo gap: Double = 5) -> [TranscriptionRange] {
        guard let t = trackIndex(id: trackID) else { return [] }
        var byMedia: [MediaRef.ID: [CMTimeRange]] = [:]
        var order: [MediaRef.ID] = []
        for clip in tracks[t].clips where clip.text == nil {
            guard let media = mediaRef(id: clip.mediaID), media.hasAudio else { continue }
            if byMedia[media.id] == nil { order.append(media.id) }
            byMedia[media.id, default: []].append(clip.sourceRange)
        }
        let maxGap = Self.time(gap)
        return order.flatMap { mediaID -> [TranscriptionRange] in
            var merged: [CMTimeRange] = []
            for range in byMedia[mediaID, default: []].sorted(by: { $0.start < $1.start }) {
                if let last = merged.last, range.start <= last.end + maxGap {
                    merged[merged.count - 1] = CMTimeRange(start: last.start, end: max(last.end, range.end))
                } else {
                    merged.append(range)
                }
            }
            return merged.map { TranscriptionRange(mediaID: mediaID, range: $0) }
        }
    }

    /// True when a track has clips with sound that can be transcribed.
    public func canTranscribe(track trackID: Track.ID) -> Bool {
        !transcriptionRanges(forTrack: trackID).isEmpty
    }

    /// Replaces the transcript, keeping the current style.
    public mutating func setTranscript(_ segments: [SubtitleSegment], language: String?, trackID: Track.ID) {
        let style = subtitles?.style ?? .init()
        subtitles = Subtitles(trackID: trackID, segments: segments.sorted { $0.start < $1.start }, language: language, style: style)
    }

    public mutating func setSubtitleText(_ text: String, for segmentID: SubtitleSegment.ID) {
        updateSegment(segmentID) { $0.text = text }
    }

    /// Retimes a segment from timeline times, mapped to source time through the clip it is shown in.
    public mutating func setSubtitleTiming(_ segmentID: SubtitleSegment.ID, clipID: Clip.ID, start: CMTime, end: CMTime) {
        guard let clip = clip(id: clipID) else { return }
        let offset = clip.sourceRange.start.seconds - clip.timelineStart.seconds
        let newStart = max(0, start.seconds + offset)
        let newEnd = max(newStart + 0.1, end.seconds + offset)
        updateSegment(segmentID) { segment in
            segment.start = newStart
            segment.end = newEnd
        }
        subtitles?.segments.sort { $0.start < $1.start }
    }

    public mutating func removeSubtitleSegment(_ segmentID: SubtitleSegment.ID) {
        subtitles?.segments.removeAll { $0.id == segmentID }
    }

    public mutating func setSubtitlesVisible(_ isVisible: Bool) {
        subtitles?.isVisible = isVisible
    }

    public mutating func setSubtitleStyle(_ style: SubtitleStyle) {
        var value = style
        value.fontSize = min(max(value.fontSize, TextLayer.fontSizeRange.lowerBound), TextLayer.fontSizeRange.upperBound)
        value.maxWidth = min(max(value.maxWidth, SubtitleStyle.maxWidthRange.lowerBound), SubtitleStyle.maxWidthRange.upperBound)
        subtitles?.style = value
    }

    public mutating func setSubtitleTrack(_ trackID: Track.ID) {
        subtitles?.trackID = trackID
    }

    /// "V1", "V2"… visual tracks from back to front (the main track included); "A1", "A2"… audio.
    public func label(ofTrack trackID: Track.ID) -> String {
        guard let index = trackIndex(id: trackID) else { return "-" }
        switch tracks[index].kind {
        case .video, .overlay:
            return "V\((visualTrackIndices.firstIndex(of: index) ?? 0) + 1)"
        case .audio:
            let audio = tracks.filter { $0.kind == .audio }
            return "A\((audio.firstIndex { $0.id == trackID } ?? 0) + 1)"
        }
    }

    private mutating func updateSegment(_ segmentID: SubtitleSegment.ID, _ change: (inout SubtitleSegment) -> Void) {
        guard let index = subtitles?.segments.firstIndex(where: { $0.id == segmentID }) else { return }
        change(&subtitles!.segments[index])
    }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }
}

/// Builds subtitle-sized segments from a transcription response.
public enum SubtitleSegmenter {
    public struct TimedText: Sendable {
        public let start: Double
        public let end: Double
        public let text: String

        public init(start: Double, end: Double, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    public static let maxCharacters = 84
    public static let maxDuration = 6.0

    /// Groups words into cues, breaking on length, duration, pauses and sentence ends.
    public static func cues(fromWords words: [TimedText]) -> [TimedText] {
        var cues: [TimedText] = []
        var current: [TimedText] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            cues.append(TimedText(start: first.start, end: last.end, text: join(current.map(\.text))))
            current.removeAll()
        }

        for word in words {
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let item = TimedText(start: word.start, end: word.end, text: text)
            if let first = current.first, let last = current.last {
                let length = join(current.map(\.text)).count + 1 + text.count
                let endsSentence = last.text.last.map { ".?!".contains($0) } ?? false
                if length > maxCharacters || item.end - first.start > maxDuration || item.start - last.end > 0.7
                    || (endsSentence && current.count >= 3) {
                    flush()
                }
            }
            current.append(item)
        }
        flush()
        return cues
    }

    /// Splits segments that are too long to read, spreading their time by character count.
    public static func cues(fromSegments segments: [TimedText]) -> [TimedText] {
        segments.flatMap { segment -> [TimedText] in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            let duration = max(segment.end - segment.start, 0)
            guard text.count > maxCharacters || duration > maxDuration else {
                return [TimedText(start: segment.start, end: segment.end, text: text)]
            }
            let parts = max(Int((Double(text.count) / Double(maxCharacters)).rounded(.up)), Int((duration / maxDuration).rounded(.up)))
            let chunks = split(text, into: parts)
            let total = Double(chunks.map(\.count).reduce(0, +))
            var start = segment.start
            return chunks.map { chunk in
                let end = start + duration * Double(chunk.count) / max(total, 1)
                defer { start = end }
                return TimedText(start: start, end: end, text: chunk)
            }
        }
    }

    /// Splits text into about `parts` pieces at word boundaries.
    private static func split(_ text: String, into parts: Int) -> [String] {
        let words = text.split(separator: " ").map(String.init)
        guard parts > 1, words.count > 1 else { return [text] }
        let target = Double(text.count) / Double(parts)
        var chunks: [String] = []
        var current: [String] = []
        for word in words {
            current.append(word)
            if Double(join(current).count) >= target, chunks.count < parts - 1 {
                chunks.append(join(current))
                current.removeAll()
            }
        }
        if !current.isEmpty { chunks.append(join(current)) }
        return chunks
    }

    /// Joins words with spaces, without a space before punctuation.
    private static func join(_ words: [String]) -> String {
        words.reduce(into: "") { result, word in
            if result.isEmpty || word.first.map({ ",.?!;:%)".contains($0) }) == true {
                result += word
            } else {
                result += " " + word
            }
        }
    }
}
