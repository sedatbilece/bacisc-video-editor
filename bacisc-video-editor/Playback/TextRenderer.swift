import AppKit
import CoreGraphics
import EditorCore
import Foundation

/// Draws text layers into bitmaps. The compositor and the preview handles share its sizes.
enum TextRenderer {
    private struct Key: Hashable {
        let text: TextLayer
        let scale: CGFloat
    }

    private static var cache: [Key: CGImage] = [:]

    /// Logical size of the layer (render pixels), including the padding around the text.
    static func size(for text: TextLayer) -> CGSize {
        let bounds = attributedString(text).boundingRect(
            with: CGSize(width: 100_000, height: 100_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let pad = padding(text)
        return CGSize(width: ceil(bounds.width) + pad.width * 2, height: ceil(bounds.height) + pad.height * 2)
    }

    /// Bitmap of the layer at `scale` pixels per logical pixel.
    static func image(for text: TextLayer, scale: CGFloat) -> CGImage? {
        let key = Key(text: text, scale: scale)
        if let image = cache[key] { return image }

        let size = size(for: text)
        let width = Int(ceil(size.width * scale))
        let height = Int(ceil(size.height * scale))
        guard width > 0, height > 0, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.scaleBy(x: scale, y: scale)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let rect = CGRect(origin: .zero, size: size)
        if text.showsBackground {
            let radius = text.fontSize * 0.15
            text.backgroundColor.nsColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }
        let pad = padding(text)
        attributedString(text).draw(in: rect.insetBy(dx: pad.width, dy: pad.height))
        NSGraphicsContext.restoreGraphicsState()

        guard let image = context.makeImage() else { return nil }
        // Typing creates a new entry per committed edit; keep the cache small.
        if cache.count > 64 { cache.removeAll() }
        cache[key] = image
        return image
    }

    private static func padding(_ text: TextLayer) -> CGSize {
        CGSize(width: text.fontSize * 0.3, height: text.fontSize * 0.15)
    }

    private static func attributedString(_ text: TextLayer) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        switch text.alignment {
        case .leading: paragraph.alignment = .left
        case .center: paragraph.alignment = .center
        case .trailing: paragraph.alignment = .right
        }
        return NSAttributedString(string: text.string.isEmpty ? " " : text.string, attributes: [
            .font: font(text),
            .foregroundColor: text.color.nsColor,
            .paragraphStyle: paragraph,
        ])
    }

    private static func font(_ text: TextLayer) -> NSFont {
        let size = CGFloat(text.fontSize)
        let font = NSFontManager.shared.font(
            withFamily: text.fontFamily,
            traits: text.isBold ? .boldFontMask : [],
            weight: text.isBold ? 9 : 5,
            size: size
        )
        return font ?? (text.isBold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size))
    }
}

extension RGBAColor {
    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
