import CoreMedia
import SwiftUI

/// Draws the peaks covering `sourceRange`, one bar every couple of points.
struct WaveformView: View {
    let peaks: [Float]
    let sourceRange: CMTimeRange
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty, size.width > 0 else { return }
            let resolution = Double(WaveformCache.resolution)
            let first = sourceRange.start.seconds * resolution
            let perPoint = sourceRange.duration.seconds * resolution / Double(size.width)
            let step: CGFloat = 2

            var path = Path()
            var x: CGFloat = 0
            while x < size.width {
                let lower = max(0, Int(first + Double(x) * perPoint))
                let upper = min(peaks.count, max(lower + 1, Int(first + Double(x + step) * perPoint)))
                let peak = lower < upper ? peaks[lower..<upper].max() ?? 0 : 0
                let height = max(1, CGFloat(peak) * size.height)
                path.addRect(CGRect(x: x, y: (size.height - height) / 2, width: 1, height: height))
                x += step
            }
            context.fill(path, with: .color(color))
        }
        .allowsHitTesting(false)
    }
}
