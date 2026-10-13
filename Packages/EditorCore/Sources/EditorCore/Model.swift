import CoreMedia
import Foundation

/// The whole editable state of a `.vedproj` document. Pure value type so that
/// undo can simply restore a previous snapshot.
public struct Project: Codable, Equatable, Sendable {
    public var settings: ProjectSettings
    public var media: [MediaRef]
    public var tracks: [Track]

    public init(settings: ProjectSettings = .init(), media: [MediaRef] = [], tracks: [Track]) {
        self.settings = settings
        self.media = media
        self.tracks = tracks
    }

    /// A new project with a single main video track.
    public static func empty() -> Project {
        Project(tracks: [Track(kind: .video)])
    }

    /// The primary video track that clips land on by default.
    public var mainTrackID: Track.ID? {
        mainTrackIndex.map { tracks[$0].id }
    }

    public var mainTrackIndex: Int? {
        tracks.firstIndex(where: { $0.kind == .video })
    }

    public var duration: CMTime {
        tracks.map(\.endTime).max() ?? .zero
    }

    public func mediaRef(id: MediaRef.ID?) -> MediaRef? {
        guard let id else { return nil }
        return media.first(where: { $0.id == id })
    }

    public func trackIndex(id: Track.ID) -> Int? {
        tracks.firstIndex(where: { $0.id == id })
    }

    public func clip(id: Clip.ID) -> Clip? {
        guard let loc = self.location(ofClip: id) else { return nil }
        return tracks[loc.track].clips[loc.clip]
    }

    public func location(ofClip id: Clip.ID) -> (track: Int, clip: Int)? {
        for t in tracks.indices {
            if let c = tracks[t].clips.firstIndex(where: { $0.id == id }) { return (t, c) }
        }
        return nil
    }

    /// The clip itself plus every clip sharing its link group.
    public func linkedClipIDs(of id: Clip.ID) -> Set<Clip.ID> {
        guard let clip = clip(id: id) else { return [] }
        guard let group = clip.linkGroup else { return [id] }
        return Set(tracks.flatMap(\.clips).filter { $0.linkGroup == group }.map(\.id))
    }

    /// One frame at the project frame rate; the shortest allowed clip.
    public var frameDuration: CMTime {
        CMTime(value: 1, timescale: settings.frameRate)
    }
}

public struct ProjectSettings: Codable, Equatable, Sendable {
    public var renderSize: CGSize
    public var frameRate: Int32

    public init(renderSize: CGSize = CGSize(width: 1920, height: 1080), frameRate: Int32 = 30) {
        self.renderSize = renderSize
        self.frameRate = frameRate
    }
}

public enum MediaKind: String, Codable, Sendable {
    case video, audio, image
}

/// A reference to a media file on disk. Files are never copied into the project.
public struct MediaRef: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var path: String
    /// Bookmark data so the file can be found again after it is moved.
    public var bookmark: Data?
    public var kind: MediaKind
    public var duration: CMTime
    public var naturalSize: CGSize
    public var hasAudio: Bool

    public init(
        id: UUID = UUID(),
        path: String,
        bookmark: Data? = nil,
        kind: MediaKind,
        duration: CMTime,
        naturalSize: CGSize = .zero,
        hasAudio: Bool = false
    ) {
        self.id = id
        self.path = path
        self.bookmark = bookmark
        self.kind = kind
        self.duration = duration
        self.naturalSize = naturalSize
        self.hasAudio = hasAudio
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, bookmark, kind, duration, naturalSize, hasAudio
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        bookmark = try c.decodeIfPresent(Data.self, forKey: .bookmark)
        kind = try c.decode(MediaKind.self, forKey: .kind)
        duration = try c.decode(CMTime.self, forKey: .duration)
        naturalSize = try c.decode(CGSize.self, forKey: .naturalSize)
        hasAudio = try c.decode(Bool.self, forKey: .hasAudio)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(path, forKey: .path)
        try c.encodeIfPresent(bookmark, forKey: .bookmark)
        try c.encode(kind, forKey: .kind)
        try c.encode(duration, forKey: .duration)
        try c.encode(naturalSize, forKey: .naturalSize)
        try c.encode(hasAudio, forKey: .hasAudio)
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var name: String { url.lastPathComponent }
}

/// `video` is the single magnetic main track; `overlay` tracks are free. Visual tracks stack in array order (later = in front).
public enum TrackKind: String, Codable, Sendable {
    case video, audio, overlay

    /// True for tracks whose clips are drawn in the frame.
    public var isVisual: Bool { self != .audio }
}

public struct Track: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: TrackKind
    /// Always kept sorted by `timelineStart`.
    public var clips: [Clip]
    public var isMuted: Bool

    public init(id: UUID = UUID(), kind: TrackKind, clips: [Clip] = [], isMuted: Bool = false) {
        self.id = id
        self.kind = kind
        self.clips = clips
        self.isMuted = isMuted
    }

    public var endTime: CMTime {
        clips.map(\.timelineEnd).max() ?? .zero
    }

    /// Index of the clip covering `time` (start inclusive, end exclusive).
    public func clipIndex(at time: CMTime) -> Int? {
        clips.firstIndex(where: { $0.timelineStart <= time && time < $0.timelineEnd })
    }
}

/// A slice of a media file, or a generated text layer, placed on a track.
public struct Clip: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    /// Nil for generated clips (text).
    public var mediaID: MediaRef.ID?
    /// Text content; set for text clips only.
    public var text: TextLayer?
    /// The portion of the source media that is used. For stills (image, text) only the duration matters.
    public var sourceRange: CMTimeRange
    /// Where the clip starts on the timeline.
    public var timelineStart: CMTime
    /// Clips sharing a link group (e.g. video and its detached audio) are split
    /// and deleted together.
    public var linkGroup: UUID?
    /// Linear gain, 1 = original level.
    public var volume: Float
    /// True for a video clip whose audio was moved to its own clip; its own audio is not played.
    public var isAudioDetached: Bool
    /// Placement in the frame; ignored for audio.
    public var transform: ClipTransform
    /// Opacity ramp lengths in seconds.
    public var fadeIn: Double
    public var fadeOut: Double

    public init(
        id: UUID = UUID(),
        mediaID: MediaRef.ID?,
        text: TextLayer? = nil,
        sourceRange: CMTimeRange,
        timelineStart: CMTime,
        linkGroup: UUID? = nil,
        volume: Float = 1,
        isAudioDetached: Bool = false,
        transform: ClipTransform = .identity,
        fadeIn: Double = 0,
        fadeOut: Double = 0
    ) {
        self.id = id
        self.mediaID = mediaID
        self.text = text
        self.sourceRange = sourceRange
        self.timelineStart = timelineStart
        self.linkGroup = linkGroup
        self.volume = volume
        self.isAudioDetached = isAudioDetached
        self.transform = transform
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
    }

    private enum CodingKeys: String, CodingKey {
        case id, mediaID, text, sourceRange, timelineStart, linkGroup, volume, isAudioDetached, transform, fadeIn, fadeOut
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        mediaID = try c.decodeIfPresent(UUID.self, forKey: .mediaID)
        text = try c.decodeIfPresent(TextLayer.self, forKey: .text)
        sourceRange = try c.decode(CMTimeRange.self, forKey: .sourceRange)
        timelineStart = try c.decode(CMTime.self, forKey: .timelineStart)
        linkGroup = try c.decodeIfPresent(UUID.self, forKey: .linkGroup)
        volume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? 1
        isAudioDetached = try c.decodeIfPresent(Bool.self, forKey: .isAudioDetached) ?? false
        transform = try c.decodeIfPresent(ClipTransform.self, forKey: .transform) ?? .identity
        fadeIn = try c.decodeIfPresent(Double.self, forKey: .fadeIn) ?? 0
        fadeOut = try c.decodeIfPresent(Double.self, forKey: .fadeOut) ?? 0
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(mediaID, forKey: .mediaID)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encode(sourceRange, forKey: .sourceRange)
        try c.encode(timelineStart, forKey: .timelineStart)
        try c.encodeIfPresent(linkGroup, forKey: .linkGroup)
        try c.encode(volume, forKey: .volume)
        try c.encode(isAudioDetached, forKey: .isAudioDetached)
        try c.encode(transform, forKey: .transform)
        try c.encode(fadeIn, forKey: .fadeIn)
        try c.encode(fadeOut, forKey: .fadeOut)
    }

    public var duration: CMTime { sourceRange.duration }
    public var timelineEnd: CMTime { timelineStart + duration }
    public var timelineRange: CMTimeRange { CMTimeRange(start: timelineStart, duration: duration) }
}
