import CoreGraphics
import CoreMedia
import Foundation

/// Position, scale, rotation, opacity and shape of a visual clip.
public struct ClipTransform: Codable, Equatable, Sendable {
    /// Offset of the layer center from the frame center, as a fraction of the render size (y down).
    public var position: CGPoint
    public var scale: Double
    /// Degrees, clockwise.
    public var rotation: Double
    public var opacity: Double
    /// Corner radius as a fraction of the content's short side; 0.5 rounds it fully (a circle when square).
    public var cornerRadius: Double
    /// Crops media to a centered square (e.g. a round webcam bubble with `cornerRadius` 0.5).
    public var squareCrop: Bool

    public init(
        position: CGPoint = .zero,
        scale: Double = 1,
        rotation: Double = 0,
        opacity: Double = 1,
        cornerRadius: Double = 0,
        squareCrop: Bool = false
    ) {
        self.position = position
        self.scale = scale
        self.rotation = rotation
        self.opacity = opacity
        self.cornerRadius = cornerRadius
        self.squareCrop = squareCrop
    }

    private enum CodingKeys: String, CodingKey {
        case position, scale, rotation, opacity, cornerRadius, squareCrop
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        position = try c.decode(CGPoint.self, forKey: .position)
        scale = try c.decode(Double.self, forKey: .scale)
        rotation = try c.decode(Double.self, forKey: .rotation)
        opacity = try c.decode(Double.self, forKey: .opacity)
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 0
        squareCrop = try c.decodeIfPresent(Bool.self, forKey: .squareCrop) ?? false
    }

    public static let identity = ClipTransform()
    public static let scaleRange: ClosedRange<Double> = 0.05...10
    public static let cornerRadiusRange: ClosedRange<Double> = 0...0.5

    /// Content size after the optional square crop.
    public func croppedSize(_ size: CGSize) -> CGSize {
        guard squareCrop else { return size }
        let side = min(size.width, size.height)
        return CGSize(width: side, height: side)
    }

    /// Maps content (origin top-left, y down) into the render frame (y down).
    public func matrix(contentSize: CGSize, renderSize: CGSize, baseScale: Double) -> CGAffineTransform {
        let s = CGFloat(baseScale * scale)
        return CGAffineTransform(translationX: -contentSize.width / 2, y: -contentSize.height / 2)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(rotationAngle: CGFloat(rotation * .pi / 180)))
            .concatenating(CGAffineTransform(
                translationX: renderSize.width * (0.5 + position.x),
                y: renderSize.height * (0.5 + position.y)
            ))
    }

    /// Scale applied before the clip's own transform: main-track media fills the frame,
    /// overlay media only shrinks to fit, text keeps its pixel size.
    public static func baseScale(isText: Bool, isMainTrack: Bool, contentSize: CGSize, renderSize: CGSize) -> Double {
        guard !isText, contentSize.width > 0, contentSize.height > 0 else { return 1 }
        let fit = Double(min(renderSize.width / contentSize.width, renderSize.height / contentSize.height))
        return isMainTrack ? fit : min(1, fit)
    }
}

public struct RGBAColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let white = RGBAColor(red: 1, green: 1, blue: 1)
    public static let black = RGBAColor(red: 0, green: 0, blue: 0)
}

public enum TextLayerAlignment: String, Codable, CaseIterable, Sendable {
    case leading, center, trailing
}

/// Content and style of a text clip. Sizes are in render pixels.
public struct TextLayer: Codable, Hashable, Sendable {
    public var string: String
    public var fontFamily: String
    public var fontSize: Double
    public var isBold: Bool
    public var color: RGBAColor
    public var alignment: TextLayerAlignment
    public var showsBackground: Bool
    public var backgroundColor: RGBAColor

    public init(
        string: String = "Title",
        fontFamily: String = "Helvetica Neue",
        fontSize: Double = 96,
        isBold: Bool = true,
        color: RGBAColor = .white,
        alignment: TextLayerAlignment = .center,
        showsBackground: Bool = false,
        backgroundColor: RGBAColor = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.6)
    ) {
        self.string = string
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.isBold = isBold
        self.color = color
        self.alignment = alignment
        self.showsBackground = showsBackground
        self.backgroundColor = backgroundColor
    }

    public static let fontSizeRange: ClosedRange<Double> = 8...600
}

extension Clip {
    /// Opacity at a timeline time, including fades.
    public func opacity(at time: CMTime) -> Double {
        var value = transform.opacity
        if fadeIn > 0 { value *= min(1, max(0, (time - timelineStart).seconds / fadeIn)) }
        if fadeOut > 0 { value *= min(1, max(0, (timelineEnd - time).seconds / fadeOut)) }
        return value
    }
}

/// Layer (overlay, text, transform) operations.
extension Project {
    /// Default length of image and text clips.
    public static let defaultStillDuration = CMTime(value: 5, timescale: 1)

    /// True for clips without a time-based source (images, text): they can be trimmed to any length.
    public func isStill(_ clip: Clip) -> Bool {
        clip.text != nil || mediaRef(id: clip.mediaID)?.kind == .image
    }

    /// Overlay track indices from back to front.
    public var overlayTrackIndices: [Int] {
        tracks.indices.filter { tracks[$0].kind == .overlay }
    }

    /// Visual track indices (main and overlays) from back to front.
    public var visualTrackIndices: [Int] {
        tracks.indices.filter { tracks[$0].kind.isVisual }
    }

    /// Adds a text clip at `time` on the first overlay track with room, creating one if needed.
    @discardableResult
    public mutating func addTextClip(_ text: TextLayer, at time: CMTime, duration: CMTime = Project.defaultStillDuration) -> Clip.ID {
        let range = CMTimeRange(start: max(.zero, time), duration: duration)
        let target: Int
        if let free = overlayTrackIndices.first(where: { tracks[$0].isFree(range) }) {
            target = free
        } else {
            tracks.append(Track(kind: .overlay))
            target = tracks.count - 1
        }
        let clip = Clip(
            mediaID: nil,
            text: text,
            sourceRange: CMTimeRange(start: .zero, duration: duration),
            timelineStart: range.start
        )
        tracks[target].clips.append(clip)
        tracks[target].sortClips()
        return clip.id
    }

    public mutating func setTransform(_ transform: ClipTransform, for clipIDs: Set<Clip.ID>) {
        var value = transform
        value.scale = min(max(value.scale, ClipTransform.scaleRange.lowerBound), ClipTransform.scaleRange.upperBound)
        value.opacity = min(max(value.opacity, 0), 1)
        value.cornerRadius = min(max(value.cornerRadius, ClipTransform.cornerRadiusRange.lowerBound), ClipTransform.cornerRadiusRange.upperBound)
        updateClips(clipIDs) { $0.transform = value }
    }

    public mutating func setText(_ text: TextLayer, for clipID: Clip.ID) {
        var value = text
        value.fontSize = min(max(value.fontSize, TextLayer.fontSizeRange.lowerBound), TextLayer.fontSizeRange.upperBound)
        updateClips([clipID]) { clip in
            if clip.text != nil { clip.text = value }
        }
    }

    /// Sets fade lengths in seconds, each clamped to the clip duration.
    public mutating func setFades(in fadeIn: Double, out fadeOut: Double, for clipIDs: Set<Clip.ID>) {
        updateClips(clipIDs) { clip in
            let length = clip.duration.seconds
            clip.fadeIn = min(max(fadeIn, 0), length)
            clip.fadeOut = min(max(fadeOut, 0), length)
        }
    }

    /// Moves a visual track (the main track included) to `position` in the stacking order (0 = back).
    public mutating func reorderVisualTrack(_ trackID: Track.ID, to position: Int) {
        let indices = visualTrackIndices
        var visual = indices.map { tracks[$0] }
        guard let from = visual.firstIndex(where: { $0.id == trackID }) else { return }
        let track = visual.remove(at: from)
        visual.insert(track, at: min(max(position, 0), visual.count))
        for (index, track) in zip(indices, visual) {
            tracks[index] = track
        }
    }

    /// Removes a track and its clips; the main track cannot be removed.
    /// Clips linked to removed ones lose the link, and video whose detached audio is gone plays its own audio again.
    public mutating func removeTrack(_ trackID: Track.ID) {
        guard let t = trackIndex(id: trackID), t != mainTrackIndex else { return }
        let groups = Set(tracks[t].clips.compactMap(\.linkGroup))
        tracks.remove(at: t)
        if subtitles?.trackID == trackID, let main = mainTrackID {
            subtitles?.trackID = main
        }

        for group in groups {
            let members = tracks.indices.flatMap { t in
                tracks[t].clips.indices.filter { tracks[t].clips[$0].linkGroup == group }.map { (track: t, clip: $0) }
            }
            let hasAudioMember = members.contains { tracks[$0.track].kind == .audio }
            for (t, c) in members {
                if !hasAudioMember { tracks[t].clips[c].isAudioDetached = false }
                if members.count < 2 { tracks[t].clips[c].linkGroup = nil }
            }
        }
    }

    private mutating func updateClips(_ clipIDs: Set<Clip.ID>, _ change: (inout Clip) -> Void) {
        for t in tracks.indices {
            for c in tracks[t].clips.indices where clipIDs.contains(tracks[t].clips[c].id) {
                change(&tracks[t].clips[c])
            }
        }
    }
}
