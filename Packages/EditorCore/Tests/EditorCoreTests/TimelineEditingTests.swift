import CoreMedia
import Foundation
import Testing
@testable import EditorCore

private func sec(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }

/// A project with one 10s media file appended `count` times to the main track.
private func makeProject(clips count: Int = 3) -> (Project, Track.ID, MediaRef.ID) {
    var project = Project.empty()
    let media = MediaRef(path: "/tmp/a.mov", kind: .video, duration: sec(10), hasAudio: true)
    project.media.append(media)
    let track = project.mainTrackID!
    for _ in 0..<count { project.appendMedia(media.id, toTrack: track) }
    return (project, track, media.id)
}

private func starts(_ project: Project, _ track: Track.ID) -> [Double] {
    project.tracks[project.trackIndex(id: track)!].clips.map { $0.timelineStart.seconds }
}

@Suite struct InsertTests {
    @Test func appendPlacesClipsBackToBack() {
        let (project, track, _) = makeProject()
        #expect(starts(project, track) == [0, 10, 20])
        #expect(project.duration == sec(30))
    }

    @Test func insertSnapsToNearestBoundaryAndRipples() {
        var (project, track, media) = makeProject(clips: 2)
        // 13s is in the first half of the second clip -> inserted at 10s.
        project.insertClip(
            mediaID: media,
            sourceRange: CMTimeRange(start: .zero, duration: sec(4)),
            onTrack: track,
            near: sec(13)
        )
        #expect(starts(project, track) == [0, 10, 14])
        #expect(project.duration == sec(24))
    }
}

@Suite struct SplitTests {
    @Test func splitDividesSourceRange() throws {
        var (project, track, _) = makeProject(clips: 1)
        let created = project.split(at: sec(4), onTrack: track)
        #expect(created.count == 1)
        let clips = project.tracks[0].clips
        #expect(clips.count == 2)
        #expect(clips[0].sourceRange == CMTimeRange(start: .zero, duration: sec(4)))
        #expect(clips[1].sourceRange == CMTimeRange(start: sec(4), duration: sec(6)))
        #expect(clips[1].timelineStart == sec(4))
        #expect(project.duration == sec(10))
    }

    @Test(arguments: [0.0, 10.0, 30.0, 45.0])
    func splitAtBoundaryOrOutsideIsNoOp(at seconds: Double) {
        var (project, track, _) = makeProject()
        let before = project
        #expect(project.split(at: sec(seconds), onTrack: track).isEmpty)
        #expect(project == before)
    }

    @Test func splitAlsoSplitsLinkedClips() throws {
        var (project, track, media) = makeProject(clips: 1)
        let group = UUID()
        project.tracks[0].clips[0].linkGroup = group
        project.tracks.append(Track(kind: .audio, clips: [
            Clip(mediaID: media, sourceRange: CMTimeRange(start: .zero, duration: sec(10)),
                 timelineStart: .zero, linkGroup: group),
        ]))

        let created = project.split(at: sec(3), onTrack: track)
        #expect(created.count == 2)
        let video = project.tracks[0].clips
        let audio = project.tracks[1].clips
        #expect(video.count == 2 && audio.count == 2)
        #expect(video[0].linkGroup == group && audio[0].linkGroup == group)
        #expect(video[1].linkGroup != nil && video[1].linkGroup == audio[1].linkGroup)
        #expect(video[1].linkGroup != group)
    }
}

@Suite struct RippleDeleteTests {
    @Test func deletingMiddleClipShiftsLaterClips() {
        var (project, track, _) = makeProject()
        let middle = project.tracks[0].clips[1].id
        project.rippleDelete([middle])
        #expect(starts(project, track) == [0, 10])
        #expect(project.duration == sec(20))
    }

    @Test func deletingSplitPieceClosesGap() {
        var (project, track, _) = makeProject(clips: 2)
        project.split(at: sec(3), onTrack: track)
        project.split(at: sec(7), onTrack: track)
        // Clips: [0-3] [3-7] [7-10] [10-20]; delete the 4s piece.
        let piece = project.tracks[0].clips[1].id
        project.rippleDelete([piece])
        #expect(starts(project, track) == [0, 3, 6])
        #expect(project.duration == sec(16))
    }

    @Test func deletingMultipleClips() {
        var (project, track, _) = makeProject(clips: 4)
        let ids: Set = [project.tracks[0].clips[0].id, project.tracks[0].clips[2].id]
        project.rippleDelete(ids)
        #expect(starts(project, track) == [0, 10])
    }

    @Test func deleteRemovesLinkedClipsAndLeavesOtherTracks() {
        var (project, track, media) = makeProject(clips: 2)
        let group = UUID()
        project.tracks[0].clips[0].linkGroup = group
        let overlay = Clip(mediaID: media, sourceRange: CMTimeRange(start: .zero, duration: sec(2)),
                           timelineStart: sec(15))
        project.tracks.append(Track(kind: .audio, clips: [
            Clip(mediaID: media, sourceRange: CMTimeRange(start: .zero, duration: sec(10)),
                 timelineStart: .zero, linkGroup: group),
        ]))
        project.tracks.append(Track(kind: .overlay, clips: [overlay]))

        project.rippleDelete([project.tracks[0].clips[0].id])
        #expect(starts(project, track) == [0])
        #expect(project.tracks[1].clips.isEmpty)
        #expect(project.tracks[2].clips == [overlay])
    }

    @Test func removeMediaDeletesItsClips() {
        var (project, _, media) = makeProject()
        project.removeMedia(media)
        #expect(project.media.isEmpty)
        #expect(project.tracks[0].clips.isEmpty)
    }
}

@Suite struct CodingTests {
    @Test func jsonRoundTrip() throws {
        var (project, track, _) = makeProject()
        project.split(at: sec(12.5), onTrack: track)
        project.media[0].bookmark = Data([1, 2, 3])
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        #expect(decoded == project)
    }
}
