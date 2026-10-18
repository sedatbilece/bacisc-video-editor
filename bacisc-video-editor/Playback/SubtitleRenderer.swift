import CoreGraphics
import CoreMedia
import CoreText
import EditorCore
import Foundation

/// Draws subtitle boxes with Core Text. Thread-safe: the compositor renders cues lazily on its own queue.
nonisolated enum SubtitleRenderer {
    /// Shared by every subtitle layer so one live transform moves them all while dragging.
    static let layerID = UUID(uuidString: "5B1E0000-0000-4000-8000-00000000C0DE")!

    private struct Key: Hashable {
        let text: String
        let style: StyleKey
        let maxWidth: CGFloat
        let scale: CGFloat
    }

    /// The style fields that affect the bitmap (not the position).
    private struct StyleKey: Hashable {
        let fontSize: Double
        let isBold: Bool
        let color: RGBAColor
        let showsBackground: Bool
        let backgroundColor: RGBAColor

        init(_ style: SubtitleStyle) {
            fontSize = style.fontSize
            isBold = style.isBold
            color = style.color
            showsBackground = style.showsBackground
            backgroundColor = style.backgroundColor
        }
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var images: [Key: CGImage] = [:]

        func image(for key: Key, make: () -> CGImage?) -> CGImage? {
            if let image = lock.withLock({ images[key] }) { return image }
            guard let image = make() else { return nil }
            lock.withLock {
                if images.count > 48 { images.removeAll() }
                images[key] = image
            }
            return image
        }
    }

    private static let cache = Cache()

    /// Box size in render pixels; text wraps at `style.maxWidth` of the frame width.
    static func size(for text: String, style: SubtitleStyle, renderWidth: CGFloat) -> CGSize {
        let layout = layout(text, style: style, renderWidth: renderWidth)
        return layout.boxSize
    }

    /// Bitmap of the box at `scale` pixels per render pixel.
    static func image(for text: String, style: SubtitleStyle, renderWidth: CGFloat, scale: CGFloat) -> CGImage? {
        let key = Key(text: text, style: StyleKey(style), maxWidth: renderWidth * style.maxWidth, scale: scale)
        return cache.image(for: key) { draw(text, style: style, renderWidth: renderWidth, scale: scale) }
    }

    private struct Layout {
        let framesetter: CTFramesetter
        let textSize: CGSize
        let padding: CGSize

        var boxSize: CGSize {
            CGSize(width: textSize.width + padding.width * 2, height: textSize.height + padding.height * 2)
        }
    }

    private static func layout(_ text: String, style: SubtitleStyle, renderWidth: CGFloat) -> Layout {
        let size = CGFloat(style.fontSize)
        let padding = CGSize(width: size * 0.4, height: size * 0.2)
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString(text, style: style))
        let maxTextWidth = max(renderWidth * style.maxWidth - padding.width * 2, size)
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude), nil
        )
        return Layout(
            framesetter: framesetter,
            textSize: CGSize(width: ceil(fitted.width) + 1, height: ceil(fitted.height) + 1),
            padding: padding
        )
    }

    private static func draw(_ text: String, style: SubtitleStyle, renderWidth: CGFloat, scale: CGFloat) -> CGImage? {
        let layout = layout(text, style: style, renderWidth: renderWidth)
        let box = layout.boxSize
        let width = Int(ceil(box.width * scale))
        let height = Int(ceil(box.height * scale))
        guard width > 0, height > 0, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.scaleBy(x: scale, y: scale)

        if style.showsBackground {
            let radius = CGFloat(style.fontSize) * 0.15
            context.setFillColor(cgColor(style.backgroundColor))
            context.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: box), cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        }
        let textRect = CGRect(origin: CGPoint(x: layout.padding.width, y: layout.padding.height), size: layout.textSize)
        let frame = CTFramesetterCreateFrame(layout.framesetter, CFRange(location: 0, length: 0), CGPath(rect: textRect, transform: nil), nil)
        CTFrameDraw(frame, context)
        return context.makeImage()
    }

    private static func attributedString(_ text: String, style: SubtitleStyle) -> CFAttributedString {
        let base = CTFontCreateUIFontForLanguage(.system, CGFloat(style.fontSize), nil)
            ?? CTFontCreateWithName("Helvetica Neue" as CFString, CGFloat(style.fontSize), nil)
        let font = style.isBold
            ? CTFontCreateCopyWithSymbolicTraits(base, 0, nil, .traitBold, .traitBold) ?? base
            : base
        var alignment = CTTextAlignment.center
        let paragraph = withUnsafeMutableBytes(of: &alignment) { bytes in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: bytes.count, value: bytes.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: cgColor(style.color),
            kCTParagraphStyleAttributeName: paragraph,
        ]
        return CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)
    }

    private static func cgColor(_ color: RGBAColor) -> CGColor {
        CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}

extension Project {
    /// Cues drawn in the frame: none while subtitles are hidden or for empty text.
    var visibleSubtitleCues: [SubtitleCue] {
        guard subtitles?.isVisible == true else { return [] }
        return subtitleCues.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The visible cue at a timeline time.
    func subtitleCue(at time: CMTime) -> SubtitleCue? {
        visibleSubtitleCues.last { $0.timelineRange.start <= time && time < $0.timelineRange.end }
    }
}
