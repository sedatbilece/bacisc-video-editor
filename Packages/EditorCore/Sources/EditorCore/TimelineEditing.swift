import CoreMedia
import Foundation

public enum TrimEdge: Sendable {
    case leading, trailing
}

/// Timeline editing operations. The main video track is magnetic (ripples); other tracks are free.
extension Project {

    // MARK: Insert

    /// The clip boundary closest to `time` on a track: inside a clip, the
    /// nearer of its start or end; past the last clip, the track end.
    public func insertionTime(near time: CMTime, onTrack trackID: Track.ID) -> CMTime {
        guard let track = tracks.first(where: { $0.id == trackID }) else { return .zero }
        guard let index = track.clipIndex(at: time) else {
            return time >= track.endTime ? track.endTime : snapToGap(time, in: track)
        }
        let clip = track.clips[index]
        let midpoint = clip.timelineStart + CMTimeMultiplyByRatio(clip.duration, multiplier: 1, divisor: 2)
        return time < midpoint ? clip.timelineStart : clip.timelineEnd
    }

    /// Inserts a media range near `time`: rippling on the main track, in the nearest free gap elsewhere.
    @discardableResult
    public mutating func insertClip(
        mediaID: MediaRef.ID,
        sourceRange: CMTimeRange,
        onTrack trackID: Track.ID,
        near time: CMTime
    ) -> Clip.ID? {
        guard let t = trackIndex(id: trackID), sourceRange.duration > .zero else { return nil }

        guard t == mainTrackIndex else {
            let start = nearestFreeStart(onTrack: t, duration: sourceRange.duration, desired: max(.zero, time))
            let clip = Clip(mediaID: mediaID, sourceRange: sourceRange, timelineStart: start)
            tracks[t].clips.append(clip)
            tracks[t].sortClips()
            return clip.id
        }

        let before = self
        let start = insertionTime(near: time, onTrack: trackID)
        let clip = Clip(mediaID: mediaID, sourceRange: sourceRange, timelineStart: start)
        for i in tracks[t].clips.indices where tracks[t].clips[i].timelineStart >= start {
            tracks[t].clips[i].timelineStart = tracks[t].clips[i].timelineStart + clip.duration
        }
        tracks[t].clips.append(clip)
        tracks[t].sortClips()
        syncLinkedClips(from: before)
        return clip.id
    }

    /// Appends the whole media file to the end of a track.
    @discardableResult
    public mutating func appendMedia(_ mediaID: MediaRef.ID, toTrack trackID: Track.ID) -> Clip.ID? {
        guard let media = mediaRef(id: mediaID), let track = tracks.first(where: { $0.id == trackID }) else {
            return nil
        }
        return insertClip(
            mediaID: mediaID,
            sourceRange: CMTimeRange(start: .zero, duration: media.duration),
            onTrack: trackID,
            near: track.endTime
        )
    }

    // MARK: Split

    /// Splits the clip under `time` (and its linked clips) in two; returns the new right-hand clip IDs.
    /// No-op when `time` is not strictly inside a clip.
    @discardableResult
    public mutating func split(at time: CMTime, onTrack trackID: Track.ID) -> [Clip.ID] {
        guard let trackIndex = trackIndex(id: trackID),
              let clipIndex = tracks[trackIndex].clipIndex(at: time)
        else { return [] }
        let target = tracks[trackIndex].clips[clipIndex]
        guard time > target.timelineStart else { return [] }

        var locations: [(track: Int, clip: Int)] = [(trackIndex, clipIndex)]
        if let group = target.linkGroup {
            for t in tracks.indices {
                for c in tracks[t].clips.indices
                where tracks[t].clips[c].linkGroup == group && tracks[t].clips[c].id != target.id {
                    let clip = tracks[t].clips[c]
                    if clip.timelineStart < time && time < clip.timelineEnd {
                        locations.append((t, c))
                    }
                }
            }
        }

        let newGroup: UUID? = locations.count > 1 ? UUID() : nil
        var created: [Clip.ID] = []
        for (t, c) in locations {
            var left = tracks[t].clips[c]
            let offset = time - left.timelineStart
            var right = left
            right.id = UUID()
            right.timelineStart = time
            right.sourceRange = CMTimeRange(start: left.sourceRange.start + offset, duration: left.duration - offset)
            right.linkGroup = newGroup ?? left.linkGroup
            left.sourceRange.duration = offset

            tracks[t].clips[c] = left
            tracks[t].clips.append(right)
            created.append(right.id)
        }
        for t in Set(locations.map(\.track)) {
            tracks[t].sortClips()
        }
        return created
    }

    // MARK: Delete

    /// Removes the clips plus their linked clips. Gaps close on the main track only;
    /// clips on other tracks stay in place unless linked to a main-track clip that moved.
    public mutating func rippleDelete(_ clipIDs: Set<Clip.ID>) {
        var ids = clipIDs
        let groups = Set(tracks.flatMap(\.clips).filter { ids.contains($0.id) }.compactMap(\.linkGroup))
        if !groups.isEmpty {
            for clip in tracks.flatMap(\.clips) where clip.linkGroup.map(groups.contains) == true {
                ids.insert(clip.id)
            }
        }

        let before = self
        for t in tracks.indices {
            let removed = tracks[t].clips.filter { ids.contains($0.id) }
            guard !removed.isEmpty else { continue }
            tracks[t].clips.removeAll { ids.contains($0.id) }
            guard t == mainTrackIndex else { continue }
            for c in tracks[t].clips.indices {
                let start = tracks[t].clips[c].timelineStart
                let shift = removed
                    .filter { $0.timelineStart < start }
                    .reduce(CMTime.zero) { $0 + $1.duration }
                tracks[t].clips[c].timelineStart = start - shift
            }
        }
        syncLinkedClips(from: before)
    }

    // MARK: Move

    /// Moves a clip so it starts near `start` on `trackID`; linked clips follow.
    /// Main-track clips reorder within the main track; clips linked to it move with their anchor.
    @discardableResult
    public mutating func moveClip(_ id: Clip.ID, toTrack trackID: Track.ID, start: CMTime) -> Bool {
        guard let loc = self.location(ofClip: id), let target = trackIndex(id: trackID) else { return false }
        let clip = tracks[loc.track].clips[loc.clip]
        let delta = start - clip.timelineStart

        if loc.track == mainTrackIndex {
            guard target == loc.track else { return false }
            return reorderOnMainTrack(id, start: start)
        }
        if let anchor = mainAnchor(of: clip), let main = mainTrackIndex {
            return moveClip(anchor.id, toTrack: tracks[main].id, start: anchor.timelineStart + delta)
        }
        // Non-main clips stay on tracks of the same kind (audio with audio, overlay with overlay).
        guard target != mainTrackIndex, tracks[target].kind == tracks[loc.track].kind else { return false }

        let linked = linkedClipIDs(of: id).subtracting([id])
        tracks[loc.track].clips.remove(at: loc.clip)
        var moved = clip
        moved.timelineStart = nearestFreeStart(onTrack: target, duration: clip.duration, desired: max(.zero, start))
        let applied = moved.timelineStart - clip.timelineStart
        tracks[target].clips.append(moved)

        for otherID in linked {
            guard let l = self.location(ofClip: otherID) else { continue }
            tracks[l.track].clips[l.clip].timelineStart = tracks[l.track].clips[l.clip].timelineStart + applied
        }
        for t in tracks.indices { tracks[t].sortClips() }
        return applied != .zero || target != loc.track
    }

    private mutating func reorderOnMainTrack(_ id: Clip.ID, start: CMTime) -> Bool {
        guard let t = mainTrackIndex, let c = tracks[t].clips.firstIndex(where: { $0.id == id }) else { return false }
        let before = self
        let clip = tracks[t].clips.remove(at: c)
        for i in tracks[t].clips.indices where tracks[t].clips[i].timelineStart > clip.timelineStart {
            tracks[t].clips[i].timelineStart = tracks[t].clips[i].timelineStart - clip.duration
        }

        // The dragged clip's center, mapped into the timeline without the clip.
        var center = start + CMTimeMultiplyByRatio(clip.duration, multiplier: 1, divisor: 2)
        if center >= clip.timelineEnd {
            center = center - clip.duration
        } else if center > clip.timelineStart {
            center = clip.timelineStart
        }
        let insertAt = insertionTime(near: max(.zero, center), onTrack: tracks[t].id)

        for i in tracks[t].clips.indices where tracks[t].clips[i].timelineStart >= insertAt {
            tracks[t].clips[i].timelineStart = tracks[t].clips[i].timelineStart + clip.duration
        }
        var moved = clip
        moved.timelineStart = insertAt
        tracks[t].clips.append(moved)
        tracks[t].sortClips()
        syncLinkedClips(from: before)
        return insertAt != clip.timelineStart
    }

    // MARK: Trim

    /// Trims a clip edge toward `time`. Ripples on the main track; on other tracks clamps to neighbours.
    /// Linked clips are trimmed by the same amount.
    @discardableResult
    public mutating func trim(_ id: Clip.ID, edge: TrimEdge, to time: CMTime) -> Bool {
        guard let loc = self.location(ofClip: id) else { return false }
        let clip = tracks[loc.track].clips[loc.clip]
        let isMain = loc.track == mainTrackIndex

        if !isMain, let anchor = mainAnchor(of: clip) {
            let offset = time - (edge == .leading ? clip.timelineStart : clip.timelineEnd)
            return trim(anchor.id, edge: edge, to: (edge == .leading ? anchor.timelineStart : anchor.timelineEnd) + offset)
        }
        let still = self.isStill(clip)
        guard still || mediaRef(id: clip.mediaID) != nil else { return false }
        // Stills have no source limit; cap them at an hour either way.
        let stillLimit = CMTime(value: 3600, timescale: 1)
        let mediaDuration = mediaRef(id: clip.mediaID)?.duration ?? .zero

        let others = tracks[loc.track].clips.filter { $0.id != id }
        let delta: CMTime
        switch edge {
        case .leading:
            var lower = still ? CMTime.zero - stillLimit : CMTime.zero - clip.sourceRange.start
            if !isMain {
                let previousEnd = others.filter { $0.timelineEnd <= clip.timelineStart }.map(\.timelineEnd).max() ?? .zero
                lower = max(lower, previousEnd - clip.timelineStart)
            }
            delta = clamp(time - clip.timelineStart, lower: lower, upper: clip.duration - frameDuration)
        case .trailing:
            var upper = still ? stillLimit : mediaDuration - clip.sourceRange.end
            if !isMain, let nextStart = others.filter({ $0.timelineStart >= clip.timelineEnd }).map(\.timelineStart).min() {
                upper = min(upper, nextStart - clip.timelineEnd)
            }
            delta = clamp(time - clip.timelineEnd, lower: frameDuration - clip.duration, upper: upper)
        }
        guard delta != .zero else { return false }

        let before = self
        for memberID in linkedClipIDs(of: id) {
            guard let l = self.location(ofClip: memberID) else { continue }
            var member = tracks[l.track].clips[l.clip]
            switch edge {
            case .leading:
                member.sourceRange = CMTimeRange(start: member.sourceRange.start + delta, duration: member.duration - delta)
                if !isMain { member.timelineStart = member.timelineStart + delta }
            case .trailing:
                member.sourceRange.duration = member.duration + delta
            }
            if still { member.sourceRange.start = .zero }
            tracks[l.track].clips[l.clip] = member
        }

        if isMain {
            let change = edge == .leading ? CMTime.zero - delta : delta
            for i in tracks[loc.track].clips.indices
            where tracks[loc.track].clips[i].timelineStart > clip.timelineStart {
                tracks[loc.track].clips[i].timelineStart = tracks[loc.track].clips[i].timelineStart + change
            }
            syncLinkedClips(from: before)
        }
        for t in tracks.indices { tracks[t].sortClips() }
        return true
    }

    // MARK: Media

    /// Removes a media reference and every clip that uses it.
    public mutating func removeMedia(_ mediaID: MediaRef.ID) {
        let clipIDs = Set(tracks.flatMap(\.clips).filter { $0.mediaID == mediaID }.map(\.id))
        rippleDelete(clipIDs)
        media.removeAll { $0.id == mediaID }
    }

    // MARK: Helpers

    /// The main-track clip sharing `clip`'s link group, if any.
    func mainAnchor(of clip: Clip) -> Clip? {
        guard let group = clip.linkGroup, let main = mainTrackIndex else { return nil }
        return tracks[main].clips.first { $0.linkGroup == group && $0.id != clip.id }
    }

    /// Shifts clips on other tracks by however much their linked main-track clip moved since `before`.
    mutating func syncLinkedClips(from before: Project) {
        guard let main = mainTrackIndex else { return }
        for anchor in tracks[main].clips {
            guard let group = anchor.linkGroup, let old = before.clip(id: anchor.id) else { continue }
            let delta = anchor.timelineStart - old.timelineStart
            guard delta != .zero else { continue }
            for t in tracks.indices where t != main {
                for c in tracks[t].clips.indices where tracks[t].clips[c].linkGroup == group {
                    tracks[t].clips[c].timelineStart = tracks[t].clips[c].timelineStart + delta
                }
            }
        }
        for t in tracks.indices where t != main { tracks[t].sortClips() }
    }

    /// The start closest to `desired` where a clip of `duration` fits without overlapping.
    func nearestFreeStart(onTrack t: Int, duration: CMTime, desired: CMTime) -> CMTime {
        let clips = tracks[t].clips
        func fits(_ start: CMTime) -> Bool {
            start >= .zero && clips.allSatisfy { $0.timelineEnd <= start || $0.timelineStart >= start + duration }
        }
        let candidates = [desired] + clips.map(\.timelineEnd) + clips.map { $0.timelineStart - duration }
        return candidates.filter(fits).min {
            CMTimeAbsoluteValue($0 - desired) < CMTimeAbsoluteValue($1 - desired)
        } ?? tracks[t].endTime
    }

    private func snapToGap(_ time: CMTime, in track: Track) -> CMTime {
        // In a gap between clips: snap to the end of the previous clip.
        track.clips.last(where: { $0.timelineEnd <= time })?.timelineEnd ?? .zero
    }

    private func clamp(_ value: CMTime, lower: CMTime, upper: CMTime) -> CMTime {
        min(max(value, lower), upper)
    }
}

extension Track {
    mutating func sortClips() {
        clips.sort { $0.timelineStart < $1.timelineStart }
    }

    /// True when no clip overlaps `range`.
    public func isFree(_ range: CMTimeRange) -> Bool {
        clips.allSatisfy { $0.timelineEnd <= range.start || $0.timelineStart >= range.end }
    }
}
