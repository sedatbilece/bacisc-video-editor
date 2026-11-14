import CoreGraphics
import Foundation

/// Frame shapes a project is laid out and exported in.
public enum AspectFormat: String, Codable, CaseIterable, Identifiable, CodingKeyRepresentable, Sendable {
    case widescreen, vertical, square, portrait

    public var id: String { rawValue }

    /// "16:9", "9:16", …
    public var title: String {
        "\(ratio.width):\(ratio.height)"
    }

    public var name: String {
        switch self {
        case .widescreen: "Landscape"
        case .vertical: "Vertical (Shorts, Reels)"
        case .square: "Square"
        case .portrait: "Portrait (Feed)"
        }
    }

    public var ratio: (width: Int, height: Int) {
        switch self {
        case .widescreen: (16, 9)
        case .vertical: (9, 16)
        case .square: (1, 1)
        case .portrait: (4, 5)
        }
    }

    /// Short side of a new project's frame.
    public static let defaultShortSide: CGFloat = 1080

    /// Frame size with the given short side; dimensions are even.
    public func size(shortSide: CGFloat = AspectFormat.defaultShortSide) -> CGSize {
        let unit = shortSide / CGFloat(min(ratio.width, ratio.height))
        return CGSize(width: Self.even(CGFloat(ratio.width) * unit), height: Self.even(CGFloat(ratio.height) * unit))
    }

    private static func even(_ value: CGFloat) -> CGFloat {
        max(2, (value / 2).rounded() * 2)
    }
}

/// How media fills a frame whose shape differs from its own.
public enum FitMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Whole picture visible, bars on the sides.
    case fit
    /// Covers the frame, edges cropped.
    case fill
    /// Original pixel size; positioned and scaled by hand.
    case manual

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fit: "Fit"
        case .fill: "Fill (Crop)"
        case .manual: "Manual"
        }
    }
}

/// A clip's fit mode and transform in one format.
public struct ClipLayout: Codable, Equatable, Sendable {
    /// Nil: main-track media fits, overlay media only shrinks to fit.
    public var fitMode: FitMode?
    public var transform: ClipTransform

    public init(fitMode: FitMode? = nil, transform: ClipTransform = .identity) {
        self.fitMode = fitMode
        self.transform = transform
    }
}

extension Clip {
    /// Layout in a format already normalized by `Project.layoutFormat(_:)`; nil is the project frame.
    public func layout(in format: AspectFormat?) -> ClipLayout {
        if let format, let layout = formatLayouts[format] { return layout }
        return ClipLayout(fitMode: fitMode, transform: transform)
    }
}

/// Formats and per-format layouts. The project frame (`settings.renderSize`) holds each clip's own
/// fit mode and transform; other formats use an override when the clip has one, otherwise the same values.
extension Project {
    /// A new project with one main video track in the given frame shape.
    public static func empty(aspect: AspectFormat) -> Project {
        Project(settings: ProjectSettings(renderSize: aspect.size(), aspect: aspect), tracks: [Track(kind: .video)])
    }

    /// Nil when `format` is the project frame itself (or nil).
    public func layoutFormat(_ format: AspectFormat?) -> AspectFormat? {
        guard let format, format != settings.aspect else { return nil }
        return format
    }

    /// Frame size of a format; other formats share the project frame's short side.
    public func frameSize(for format: AspectFormat?) -> CGSize {
        guard let format = layoutFormat(format) else { return settings.renderSize }
        let shortSide = min(settings.renderSize.width, settings.renderSize.height)
        return format.size(shortSide: shortSide > 0 ? shortSide : AspectFormat.defaultShortSide)
    }

    public func layout(of clip: Clip, in format: AspectFormat?) -> ClipLayout {
        clip.layout(in: layoutFormat(format))
    }

    /// True when the clip has its own layout for a format other than the project frame.
    public func hasOwnLayout(_ clip: Clip, in format: AspectFormat?) -> Bool {
        guard let format = layoutFormat(format) else { return false }
        return clip.formatLayouts[format] != nil
    }

    /// True when media of this size has another shape than the project frame (more than 1 % apart).
    public func needsFitMode(forContentSize size: CGSize) -> Bool {
        let frame = settings.renderSize
        guard size.width > 0, size.height > 0, frame.width > 0, frame.height > 0 else { return false }
        let content = size.width / size.height
        let target = frame.width / frame.height
        return abs(content - target) / target > 0.01
    }

    public mutating func setFitMode(_ mode: FitMode?, for clipIDs: Set<Clip.ID>, format: AspectFormat? = nil) {
        let format = layoutFormat(format)
        updateClipLayouts(clipIDs, format: format) { $0.fitMode = mode }
    }

    /// Drops the clips' own layout for a format so they follow the project frame again.
    public mutating func removeLayouts(for clipIDs: Set<Clip.ID>, format: AspectFormat?) {
        guard let format = layoutFormat(format) else { return }
        for t in tracks.indices {
            for c in tracks[t].clips.indices where clipIDs.contains(tracks[t].clips[c].id) {
                tracks[t].clips[c].formatLayouts[format] = nil
            }
        }
    }

    /// Changes the layout in a normalized format, creating the clip's own layout for it when needed.
    mutating func updateClipLayouts(_ clipIDs: Set<Clip.ID>, format: AspectFormat?, _ change: (inout ClipLayout) -> Void) {
        for t in tracks.indices {
            for c in tracks[t].clips.indices where clipIDs.contains(tracks[t].clips[c].id) {
                var clip = tracks[t].clips[c]
                var layout = clip.layout(in: format)
                change(&layout)
                if let format {
                    clip.formatLayouts[format] = layout
                } else {
                    clip.fitMode = layout.fitMode
                    clip.transform = layout.transform
                }
                tracks[t].clips[c] = clip
            }
        }
    }
}
