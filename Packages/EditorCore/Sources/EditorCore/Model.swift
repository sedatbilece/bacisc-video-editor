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
        tracks.first(where: { $0.kind == .video })?.id
    }

    public var duration: CMTime {
        tracks.map(\.endTime).max() ?? .zero
    }

    public func mediaRef(id: MediaRef.ID) -> MediaRef? {
        media.first(where: { $0.id == id })
    }

    public func trackIndex(id: Track.ID) -> Int? {
        tracks.firstIndex(where: { $0.id == id })
    }

    public func clip(id: Clip.ID) -> Clip? {
        for track in tracks {
            if let clip = track.clips.first(where: { $0.id == id }) { return clip }
        }
        return nil
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

public enum TrackKind: String, Codable, Sendable {
    case video, audio, overlay
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

/// A slice of a media file placed on a track.
public struct Clip: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var mediaID: MediaRef.ID
    /// The portion of the source media that is used.
    public var sourceRange: CMTimeRange
    /// Where the clip starts on the timeline.
    public var timelineStart: CMTime
    /// Clips sharing a link group (e.g. video and its detached audio) are split
    /// and deleted together.
    public var linkGroup: UUID?

    public init(
        id: UUID = UUID(),
        mediaID: MediaRef.ID,
        sourceRange: CMTimeRange,
        timelineStart: CMTime,
        linkGroup: UUID? = nil
    ) {
        self.id = id
        self.mediaID = mediaID
        self.sourceRange = sourceRange
        self.timelineStart = timelineStart
        self.linkGroup = linkGroup
    }

    private enum CodingKeys: String, CodingKey {
        case id, mediaID, sourceRange, timelineStart, linkGroup
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        mediaID = try c.decode(UUID.self, forKey: .mediaID)
        sourceRange = try c.decode(CMTimeRange.self, forKey: .sourceRange)
        timelineStart = try c.decode(CMTime.self, forKey: .timelineStart)
        linkGroup = try c.decodeIfPresent(UUID.self, forKey: .linkGroup)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(mediaID, forKey: .mediaID)
        try c.encode(sourceRange, forKey: .sourceRange)
        try c.encode(timelineStart, forKey: .timelineStart)
        try c.encodeIfPresent(linkGroup, forKey: .linkGroup)
    }

    public var duration: CMTime { sourceRange.duration }
    public var timelineEnd: CMTime { timelineStart + duration }
    public var timelineRange: CMTimeRange { CMTimeRange(start: timelineStart, duration: duration) }
}
