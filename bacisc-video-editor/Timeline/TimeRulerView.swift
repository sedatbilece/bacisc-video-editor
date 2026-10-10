import CoreMedia
import SwiftUI

/// Time ruler with tick marks; clicking or dragging on it scrubs the playhead.
struct TimeRulerView: View {
    let pixelsPerSecond: Double
    let width: CGFloat
    let onScrub: (CGFloat) -> Void

    /// Candidate spacings between labelled ticks, in seconds.
    private static let steps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]

    var body: some View {
        Canvas { context, size in
            let major = Self.steps.first { $0 * pixelsPerSecond >= 80 } ?? Self.steps.last!
            let minor = major / 5
            let count = Int(Double(size.width) / (minor * pixelsPerSecond)) + 1

            for i in 0...count {
                let seconds = Double(i) * minor
                let x = seconds * pixelsPerSecond
                let isMajor = i % 5 == 0
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x, y: size.height - (isMajor ? 10 : 5)))
                context.stroke(path, with: .color(.secondary), lineWidth: 1)

                if isMajor {
                    let label = Text(CMTime.seconds(seconds).rulerLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    context.draw(label, at: CGPoint(x: x + 3, y: 2), anchor: .topLeading)
                }
            }
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { onScrub($0.location.x) }
        )
    }
}
