import CoreMedia
import EditorCore
import SwiftUI

/// Read-only "CC" lane under the ruler: one numbered block per subtitle cue, numbered as in the Subtitles tab.
/// Clicking a block jumps to it and reveals it in the inspector.
struct SubtitleLaneView: View {
    static let storageKey = "timeline.showsSubtitleLane"
    static let height: CGFloat = 22

    let cues: [SubtitleCue]
    /// Dimmed while subtitles are hidden in the frame.
    let isVisible: Bool
    let pixelsPerSecond: Double
    let width: CGFloat
    var session: EditorSession

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(Array(cues.enumerated()), id: \.element.id) { index, cue in
                block(cue, number: index + 1)
            }
            ActiveCueOutline(cues: cues, playback: session.playback, pixelsPerSecond: pixelsPerSecond)
                .allowsHitTesting(false)
        }
        .frame(width: width, height: Self.height, alignment: .topLeading)
        .clipped()
    }

    private func block(_ cue: SubtitleCue, number: Int) -> some View {
        HStack(spacing: 4) {
            Text("\(number)")
                .font(.caption2.bold().monospacedDigit())
            Text(cue.text)
                .font(.caption2)
                .lineLimit(1)
        }
        .padding(.horizontal, 4)
        .frame(width: Self.blockWidth(cue, pixelsPerSecond), height: Self.height - 4, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 3).fill(Color.teal.opacity(isVisible ? 0.35 : 0.15)))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .contentShape(Rectangle())
        .offset(x: cue.timelineRange.start.seconds * pixelsPerSecond, y: 2)
        .onTapGesture { session.revealSubtitle(cue) }
        .help("\(number): \(cue.text)")
    }

    fileprivate static func blockWidth(_ cue: SubtitleCue, _ pixelsPerSecond: Double) -> CGFloat {
        max(cue.timelineRange.duration.seconds * pixelsPerSecond - 1, 2)
    }
}

/// Outlines the cue under the playhead; only this view follows playback, not every block.
private struct ActiveCueOutline: View {
    let cues: [SubtitleCue]
    let playback: PlaybackController
    let pixelsPerSecond: Double

    var body: some View {
        let time = playback.currentTime
        if let cue = cues.last(where: { $0.timelineRange.start <= time && time < $0.timelineRange.end }) {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(Color.accentColor, lineWidth: 1.5)
                .frame(width: SubtitleLaneView.blockWidth(cue, pixelsPerSecond), height: SubtitleLaneView.height - 4)
                .offset(x: cue.timelineRange.start.seconds * pixelsPerSecond, y: 2)
        }
    }
}
