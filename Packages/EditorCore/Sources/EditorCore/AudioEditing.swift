import CoreMedia
import Foundation

/// Audio, track and media-reference operations.
extension Project {

    // MARK: Tracks

    @discardableResult
    public mutating func addTrack(_ kind: TrackKind) -> Track.ID {
        let track = Track(kind: kind)
        tracks.append(track)
        return track.id
    }

    public mutating func toggleMute(_ trackID: Track.ID) {
        guard let t = trackIndex(id: trackID) else { return }
        tracks[t].isMuted.toggle()
    }

    // MARK: Detach / unlink

    public func canDetachAudio(_ id: Clip.ID) -> Bool {
        guard let loc = self.location(ofClip: id), tracks[loc.track].kind != .audio else { return false }
        let clip = tracks[loc.track].clips[loc.clip]
        return !clip.isAudioDetached && mediaRef(id: clip.mediaID)?.hasAudio == true
    }

    /// Moves a video clip's audio to a linked clip on the first free audio track; returns the new clip ID.
    @discardableResult
    public mutating func detachAudio(_ id: Clip.ID) -> Clip.ID? {
        guard canDetachAudio(id), let loc = self.location(ofClip: id) else { return nil }
        var clip = tracks[loc.track].clips[loc.clip]
        let group = clip.linkGroup ?? UUID()
        clip.linkGroup = group
        clip.isAudioDetached = true
        tracks[loc.track].clips[loc.clip] = clip

        let audio = Clip(
            mediaID: clip.mediaID,
            sourceRange: clip.sourceRange,
            timelineStart: clip.timelineStart,
            linkGroup: group,
            volume: clip.volume
        )
        let target: Int
        if let free = tracks.firstIndex(where: { $0.kind == .audio && $0.isFree(audio.timelineRange) }) {
            target = free
        } else {
            tracks.append(Track(kind: .audio))
            target = tracks.count - 1
        }
        tracks[target].clips.append(audio)
        tracks[target].sortClips()
        return audio.id
    }

    public func isLinked(_ id: Clip.ID) -> Bool {
        linkedClipIDs(of: id).count > 1
    }

    /// Breaks the link groups of the given clips so their members move independently.
    public mutating func unlink(_ clipIDs: Set<Clip.ID>) {
        let groups = Set(clipIDs.compactMap { clip(id: $0)?.linkGroup })
        for t in tracks.indices {
            for c in tracks[t].clips.indices where tracks[t].clips[c].linkGroup.map(groups.contains) == true {
                tracks[t].clips[c].linkGroup = nil
            }
        }
    }

    // MARK: Volume

    public static let volumeRange: ClosedRange<Float> = 0...2

    public mutating func setVolume(_ volume: Float, for clipIDs: Set<Clip.ID>) {
        let clamped = min(max(volume, Self.volumeRange.lowerBound), Self.volumeRange.upperBound)
        for t in tracks.indices {
            for c in tracks[t].clips.indices where clipIDs.contains(tracks[t].clips[c].id) {
                tracks[t].clips[c].volume = clamped
            }
        }
    }

    // MARK: Media

    /// Points a media reference at a new file location.
    public mutating func relinkMedia(_ mediaID: MediaRef.ID, path: String, bookmark: Data?) {
        guard let index = media.firstIndex(where: { $0.id == mediaID }) else { return }
        media[index].path = path
        media[index].bookmark = bookmark
    }
}
