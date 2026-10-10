import SwiftUI

/// Window layout: media pool and tools on the left, preview on the right,
/// full-width timeline at the bottom.
struct EditorView: View {
    @ObservedObject var document: ProjectDocument
    @State private var session: EditorSession
    @Environment(\.undoManager) private var undoManager
    @State private var showsInspector = true

    init(document: ProjectDocument) {
        self.document = document
        _session = State(initialValue: EditorSession(document: document))
    }

    var body: some View {
        VSplitView {
            HSplitView {
                VSplitView {
                    MediaPoolView(document: document, session: session)
                        .frame(minHeight: 220)
                    ToolsPanelView(document: document, session: session)
                        .frame(minHeight: 140, idealHeight: 180)
                }
                .frame(minWidth: 240, idealWidth: 300, maxWidth: 480)

                PreviewPane(session: session)
                    .frame(minWidth: 420)
            }
            .frame(minHeight: 320)
            .inspector(isPresented: $showsInspector) {
                InspectorView(document: document, session: session)
                    .inspectorColumnWidth(min: 220, ideal: 280, max: 400)
            }

            TimelineView(document: document, session: session)
                .frame(minHeight: 180, idealHeight: 260)
        }
        .frame(minWidth: 1000, minHeight: 660)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help("Show or hide the inspector")
            }
        }
        .focusedSceneValue(\.editorSession, session)
        .onAppear {
            session.undoManager = undoManager
            session.projectDidChange()
        }
        .onChange(of: undoManager) { _, newValue in
            session.undoManager = newValue
        }
        .onChange(of: document.project) {
            session.projectDidChange()
        }
        .alert(
            "Import Failed",
            isPresented: Binding(get: { session.importError != nil }, set: { if !$0 { session.importError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.importError ?? "")
        }
    }
}
