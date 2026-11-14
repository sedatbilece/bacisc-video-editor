import Combine
import CoreMedia
import EditorCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let videoEditorProject = UTType(exportedAs: "sedatbilece.bacisc.vedproj")
}

/// A `.vedproj` package: a directory containing `project.json`.
final class ProjectDocument: ReferenceFileDocument {
    static let readableContentTypes: [UTType] = [.videoEditorProject]
    private static let projectFileName = "project.json"

    @Published private(set) var project: Project
    /// True for a document created with New; it asks for its frame format first.
    let isNew: Bool

    init() {
        project = .empty()
        isNew = true
    }

    required init(configuration: ReadConfiguration) throws {
        isNew = false
        guard let data = configuration.file.fileWrappers?[Self.projectFileName]?.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        project = try JSONDecoder().decode(Project.self, from: data)
    }

    func snapshot(contentType: UTType) throws -> Project {
        project
    }

    func fileWrapper(snapshot: Project, configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        return FileWrapper(directoryWithFileWrappers: [
            Self.projectFileName: FileWrapper(regularFileWithContents: data),
        ])
    }

    /// Starts a new, empty document in a frame format. Not undoable: it is the document's starting point.
    func setUpNewProject(aspect: AspectFormat) {
        guard project.duration == .zero else { return }
        project = .empty(aspect: aspect)
    }

    /// Applies an edit as a single undoable step. Every change to the project
    /// must go through here so undo/redo and the dirty state stay correct.
    func perform(_ actionName: String, undoManager: UndoManager?, _ edit: (inout Project) -> Void) {
        var edited = project
        edit(&edited)
        guard edited != project else { return }
        replace(with: edited, actionName: actionName, undoManager: undoManager)
    }

    private func replace(with newProject: Project, actionName: String, undoManager: UndoManager?) {
        let previous = project
        project = newProject
        undoManager?.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated {
                document.replace(with: previous, actionName: actionName, undoManager: undoManager)
            }
        }
        undoManager?.setActionName(actionName)
    }
}
