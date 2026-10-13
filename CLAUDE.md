# Bacisc Video Editor

Native macOS (Apple Silicon) video editor for personal use. Swift, SwiftUI (+ AppKit where needed), AVFoundation, Core Image / Metal later.
Plan, decisions and phases: [docs/ROADMAP.md](docs/ROADMAP.md).

## Critical rules

- **English only**: code, identifiers, UI strings, comments, commit messages and all docs.
- **Comments**: only when useful; a short summary of at most 1–2 lines. No long explanations.
- **No builds without permission**: never run `xcodebuild`, `swift build`, `swift test` or launch the app unless the user asks.
- **No extra tests**: do not write new tests unless asked. The user runs and checks the work manually when it is done.
- **Plans**: when executing a plan, ask the user at decision points instead of assuming.
- **Workflow**: no phases after v0.0.1; each chat builds one feature for the user's workflow. Clarify it first; when done, bump the patch version (`scripts/set-version.sh x.y.z+1`), add the feature with that version to the Features list in `docs/ROADMAP.md`, and commit with the matching tag once the user approves.
- **No commit / push without permission**, and never run `scripts/install.sh` or install the app into `/Applications` on your own.

## Project layout

- `bacisc-video-editor/` — app target (file-system synchronized group: new files are added to the target automatically).
  - `App/` entry point (`DocumentGroup`), `Document/` `.vedproj` package document + undo, `Editor/` window layout, session, commands, tools panel, `Media/` media pool, import, caches, `Playback/` composition, compositor + player, `Export/` export sheet + session, `Timeline/` timeline views.
- `Packages/EditorCore/` — pure value-type model (`Project → Track → Clip`) and editing ops (insert, split, ripple delete). No UI.
- `Config/Info.plist` — document type declarations, merged with the generated Info.plist.
- `scripts/install.sh` — Release archive → `/Applications` (only when the user asks).
- `scripts/set-version.sh [x.y.z]` — version `x.y.z.DDMMYY` (date = today); only when the user asks. Commit a version change with a matching tag `vx.y.z.DDMMYY`.

## Conventions

- Every project mutation goes through `ProjectDocument.perform(_:undoManager:_:)` so it is a single undo step.
- Editing logic lives in `EditorCore`; views and `EditorSession` only call it.
- The main video track is magnetic (insert/delete/trim ripple); other tracks are free (gaps allowed, no overlap). Clips linked to a main-track clip follow it via `syncLinkedClips`.
- AVFoundation objects are rebuilt from the model by `CompositionBuilder`; preview and export share it. Frames are drawn by `LayerCompositor`; visual tracks (main + overlays) stack in array order, later = in front.
- Report user-facing errors with `EditorSession.report(ErrorReport(...))` instead of swallowing them with `try?`.
- Plain-key shortcuts (Space, B, T, Delete) must be off while `EditorSession.isEditingText` is true.
- Use the `AVVideoComposition.Configuration` APIs (the mutable classes are deprecated on macOS 26+).
- Media is referenced (path + bookmark), never copied. App Sandbox is off.
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `MemberImportVisibility` are on: import every module whose members you use (e.g. `Combine`, `EditorCore`).

## Commands (run only when the user asks)

```bash
swift test --package-path Packages/EditorCore --scratch-path ~/Library/Caches/bacisc-editorcore-build
xcodebuild -scheme bacisc-video-editor -configuration Debug -destination 'platform=macOS' build
scripts/install.sh
```

The `--scratch-path` must be outside Desktop: iCloud file attributes break code signing of the test bundle.
