import CoreMedia

extension CMTime {
    /// "mm:ss.ff" (or "h:mm:ss.ff") using the given frame rate.
    func timecode(frameRate: Int32) -> String {
        guard isNumeric else { return "--:--.--" }
        let totalFrames = Int((seconds * Double(frameRate)).rounded(.down))
        let fps = Int(frameRate)
        let frames = totalFrames % fps
        let totalSeconds = totalFrames / fps
        let s = totalSeconds % 60
        let m = (totalSeconds / 60) % 60
        let h = totalSeconds / 3600
        return h > 0
            ? String(format: "%d:%02d:%02d.%02d", h, m, s, frames)
            : String(format: "%02d:%02d.%02d", m, s, frames)
    }

    /// Short ruler label: "m:ss".
    var rulerLabel: String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func seconds(_ value: Double) -> CMTime {
        CMTime(seconds: value, preferredTimescale: 600)
    }
}
