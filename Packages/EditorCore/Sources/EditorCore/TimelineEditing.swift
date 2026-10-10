import CoreMedia
import Foundation

/// Editing operations on the timeline. All of them are pure mutations of the
/// value-type model so a single undo step can restore the previous state.
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

    /// Inserts the given media range at the boundary nearest to `time` and
    /// ripples every later clip on the track to the right.
    @discardableResult
    public mutating func insertClip(
        mediaID: MediaRef.ID,
        sourceRange: CMTimeRange,
        onTrack trackID: Track.ID,
        near time: CMTime
    ) -> Clip.ID? {
        guard let trackIndex = trackIndex(id: trackID), sourceRange.duration > .zero else { return nil }
        let start = insertionTime(near: time, onTrack: trackID)
        let clip = Clip(mediaID: mediaID, sourceRange: sourceRange, timelineStart: start)

        for i in tracks[trackIndex].clips.indices where tracks[trackIndex].clips[i].timelineStart >= start {
            tracks[trackIndex].clips[i].timelineStart = tracks[trackIndex].clips[i].timelineStart + clip.duration
        }
        tracks[trackIndex].clips.append(clip)
        tracks[trackIndex].sortClips()
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

    /// Splits the clip under `time` on the track into two. Clips linked to it
    /// are split at the same time and the right halves form a new link group.
    /// Returns the IDs of the new right-hand clips, or an empty array if
    /// `time` is not strictly inside a clip.
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

    /// Removes the clips (plus everything linked to them) and closes the gaps:
    /// each remaining clip on a track moves left by the total duration of the
    /// deleted clips that started before it on that same track. Tracks with no
    /// deleted clips are left untouched.
    public mutating func rippleDelete(_ clipIDs: Set<Clip.ID>) {
        var ids = clipIDs
        let groups = Set(tracks.flatMap(\.clips).filter { ids.contains($0.id) }.compactMap(\.linkGroup))
        if !groups.isEmpty {
            for clip in tracks.flatMap(\.clips) where clip.linkGroup.map(groups.contains) == true {
                ids.insert(clip.id)
            }
        }

        for t in tracks.indices {
            let removed = tracks[t].clips.filter { ids.contains($0.id) }
            guard !removed.isEmpty else { continue }
            tracks[t].clips.removeAll { ids.contains($0.id) }
            for c in tracks[t].clips.indices {
                let start = tracks[t].clips[c].timelineStart
                let shift = removed
                    .filter { $0.timelineStart < start }
                    .reduce(CMTime.zero) { $0 + $1.duration }
                tracks[t].clips[c].timelineStart = start - shift
            }
            tracks[t].sortClips()
        }
    }

    // MARK: Media

    /// Removes a media reference and every clip that uses it.
    public mutating func removeMedia(_ mediaID: MediaRef.ID) {
        let clipIDs = Set(tracks.flatMap(\.clips).filter { $0.mediaID == mediaID }.map(\.id))
        rippleDelete(clipIDs)
        media.removeAll { $0.id == mediaID }
    }

    // MARK: Helpers

    private func snapToGap(_ time: CMTime, in track: Track) -> CMTime {
        // In a gap between clips: snap to the end of the previous clip.
        track.clips.last(where: { $0.timelineEnd <= time })?.timelineEnd ?? .zero
    }
}

extension Track {
    mutating func sortClips() {
        clips.sort { $0.timelineStart < $1.timelineStart }
    }
}
