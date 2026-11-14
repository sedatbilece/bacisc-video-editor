import CoreMedia
import Foundation

/// A snap: shifting by `offset` lines an edge up with `target`.
public struct SnapMatch: Equatable, Sendable {
    public let offset: CMTime
    public let target: CMTime
}

public enum Snapping {
    /// The smallest shift within `tolerance` that puts one of `edges` on one of `targets`.
    public static func match(edges: [CMTime], targets: [CMTime], tolerance: CMTime) -> SnapMatch? {
        var best: SnapMatch?
        for edge in edges {
            for target in targets {
                let offset = target - edge
                let distance = CMTimeAbsoluteValue(offset)
                guard distance <= tolerance else { continue }
                if best.map({ distance < CMTimeAbsoluteValue($0.offset) }) ?? true {
                    best = SnapMatch(offset: offset, target: target)
                }
            }
        }
        return best
    }
}

extension Project {
    /// Clip starts and ends on every track except the excluded clips, plus zero.
    public func snapTargets(excluding excluded: Set<Clip.ID>) -> [CMTime] {
        var targets: [CMTime] = [.zero]
        for track in tracks {
            for clip in track.clips where !excluded.contains(clip.id) {
                targets.append(clip.timelineStart)
                targets.append(clip.timelineEnd)
            }
        }
        return targets
    }

    /// True when moving the clip reorders the main track (it is on it or linked to a clip on it).
    public func movesWithMainTrack(_ clipID: Clip.ID) -> Bool {
        guard let main = mainTrackIndex else { return false }
        let linked = linkedClipIDs(of: clipID)
        return tracks[main].clips.contains { linked.contains($0.id) }
    }
}
