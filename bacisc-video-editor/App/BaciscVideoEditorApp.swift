import SwiftUI

@main
struct BaciscVideoEditorApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { ProjectDocument() }) { file in
            EditorView(document: file.document)
        }
        .commands {
            EditorCommands()
        }
    }
}
