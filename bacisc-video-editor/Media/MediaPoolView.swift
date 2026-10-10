import EditorCore
import SwiftUI
import UniformTypeIdentifiers

/// The project's media references. Files dropped here are referenced, not copied.
struct MediaPoolView: View {
    @ObservedObject var document: ProjectDocument
    var session: EditorSession
    @State private var isImporting = false
    @State private var isDropTargeted = false

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Medya")
                    .font(.headline)
                Spacer()
                Button {
                    isImporting = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Medya içe aktar")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(document.project.media) { media in
                        MediaItemView(media: media, session: session)
                    }
                }
                .padding(10)
            }
            .overlay {
                if document.project.media.isEmpty {
                    ContentUnavailableView(
                        "Medya yok",
                        systemImage: "film.stack",
                        description: Text("Videoları buraya sürükleyin")
                    )
                }
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .padding(2)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            session.importMedia(urls.filter(\.isFileURL))
            return true
        } isTargeted: {
            isDropTargeted = $0
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.movie, .audio],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                session.importMedia(urls)
            }
        }
    }
}

private struct MediaItemView: View {
    let media: MediaRef
    var session: EditorSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                Rectangle()
                    .fill(.quaternary)
                if let image = session.thumbnails.images[media.id] {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: media.kind == .audio ? "waveform" : "film")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(alignment: .bottomTrailing) {
                Text(media.duration.timecode(frameRate: session.project.settings.frameRate))
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 4)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(.white)
                    .padding(3)
            }

            Text(media.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            if media.naturalSize.width > 0 {
                Text("\(Int(media.naturalSize.width))×\(Int(media.naturalSize.height))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .draggable(media.id.uuidString) {
            Label(media.name, systemImage: "film")
                .padding(6)
        }
        .onTapGesture(count: 2) {
            session.addToTimeline(media.id)
        }
        .contextMenu {
            Button("Timeline'ın Sonuna Ekle") { session.addToTimeline(media.id) }
            Divider()
            Button("Projeden Kaldır", role: .destructive) { session.removeMedia(media.id) }
        }
        .help(media.path)
        .task(id: media.id) {
            await session.thumbnails.load(media, from: session.assets)
        }
    }
}
