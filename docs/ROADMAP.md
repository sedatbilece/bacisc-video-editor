# Bacisc Video Editor — Roadmap

Native, personal-use basic video editor for macOS (Apple Silicon).
Stack: Swift, SwiftUI (+ AppKit where needed), AVFoundation, Core Image / Metal.

## Decisions

- **Project = document package** (`.vedproj`) containing `project.json` (settings, media references, timeline).
- **Media is referenced only**: file path + bookmark are stored, nothing is copied. Missing media shows as "offline" with a "Relink" action (phase 2).
- **Ripple delete**: clips after the deleted piece shift left on the same track. Linked clips (detached audio) are deleted/shifted together; overlays stay in place.
- **Data model**: `Project → [Track] → [Clip]`, all `Codable` value types (`Packages/EditorCore`). AVFoundation objects are rebuilt from the model on every change.
- **Undo**: every edit goes through `ProjectDocument.perform`; the previous `Project` value is restored in a single step.
- **WYSIWYG**: preview and export share the same `CompositionBuilder` (and, from phase 3, the same custom compositor).
- **Export v1**: `AVAssetExportSession` presets — MP4 (H.264), MOV (HEVC), ProRes; 720p / 1080p / 4K / project resolution; M4A for audio only. Move to `AVAssetWriter` in v2 if fine-grained control is needed.
- **Distribution**: App Sandbox off, Personal Team signing, installed into `/Applications` via `scripts/install.sh`. No notarization.

## Window layout

```
┌────────────┬──────────────────────────┐
│ Media      │                          │
│ pool       │        Preview           │
├────────────┤                          │
│ Tools      │                          │
│ (1-click)  │                          │
├────────────┴──────────────────────────┤
│ Timeline (full width, multi-track)    │
└───────────────────────────────────────┘
```

## Phases

1. **Skeleton + basic editing** — document type, layout, media pool (drag & drop, thumbnails), single video track, playback/scrubbing, split (`B` / `⌘K`), ripple delete (`Delete`), undo, install script.
2. **Audio** — detach audio (linked clip), audio tracks, waveform, volume; offline media + relink.
3. **Layers** — custom `AVVideoCompositing` (Core Image + Metal), text / image / video overlays, transform handles in the preview, z-index by dragging track headers.
4. **Export** — preset sheet, progress + cancel, M4A.
5. **Polish** — snapping, better zoom, filmstrip thumbnails, shortcuts, more one-click buttons in the tools panel.

## Development

```bash
# Core model tests. The scratch path must be outside Desktop: iCloud file
# attributes break code signing of the test bundle.
swift test --package-path Packages/EditorCore --scratch-path ~/Library/Caches/bacisc-editorcore-build
xcodebuild -scheme bacisc-video-editor build     # app
scripts/install.sh                               # Release build, install into /Applications
```
