import AppKit
import EditorCore
import SwiftUI

struct ClipView: View {
    let clip: Clip
    let media: MediaRef?
    let thumbnail: NSImage?
    let isSelected: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        HStack(spacing: 6) {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64)
                    .clipped()
            }
            Text(media?.name ?? "Çevrimdışı medya")
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(media == nil ? Color.red.opacity(0.6) : Color.blue.opacity(0.7))
        .clipShape(shape)
        .overlay(shape.stroke(isSelected ? Color.yellow : Color.black.opacity(0.3), lineWidth: isSelected ? 2 : 1))
        .contentShape(shape)
    }
}
