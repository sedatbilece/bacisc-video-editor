import SwiftUI

/// Window layout: media pool and tools on the left, preview on the right,
/// full-width timeline at the bottom.
struct EditorView: View {
    @ObservedObject var document: ProjectDocument
    @State private var session: EditorSession
    @Environment(\.undoManager) private var undoManager

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

                // A split pane, not `.inspector`: the inspector nested in a split view looped
                // Update Constraints on Option + full screen and crashed.
                if session.showsInspector {
                    InspectorView(document: document, session: session)
                        .frame(minWidth: 220, idealWidth: 280, maxWidth: 400)
                }
            }
            .frame(minHeight: 360)

            TimelineView(document: document, session: session)
                .frame(minHeight: 180, idealHeight: 260)
        }
        .frame(minWidth: 1000, minHeight: 660)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    session.showExport()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export the timeline (⌘E)")
                .disabled(!session.canExport)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    session.showsInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help("Show or hide the inspector")
            }
        }
        .sheet(isPresented: $session.showsExportSheet) {
            ExportSheet(session: session)
        }
        .sheet(isPresented: $session.showsTranscribeSheet) {
            TranscribeSheet(session: session)
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
        .sheet(item: Binding(get: { session.errorReports.first }, set: { if $0 == nil { session.dismissError() } })) { report in
            ErrorReportView(report: report)
        }
    }
}
