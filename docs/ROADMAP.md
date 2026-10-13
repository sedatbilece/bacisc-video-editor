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
- **Export flow (phase 4)**: File > Export… (⌘E) or the toolbar opens a modal sheet: format, resolution, save panel, progress with Cancel, then Show in Finder. Always the whole timeline. Resolutions set the short side and keep the project's aspect ratio (even dimensions). Layout stays in project coordinates and the compositor scales it to the output size, so text and media stay sharp.
- **Layers (phase 3)**: `LayerCompositor` (custom `AVVideoCompositing`, Core Image on Metal) draws every frame. Visual tracks (the main track and overlays) stack in `tracks` order, later = in front; the timeline lists them front to back and labels them V1 (back), V2, …. Any visual track, the main one included, is reordered by dragging its header. Overlay tracks are free like audio tracks and take video, image and text clips.
- **Track deletion**: header context menu → Delete Track, for overlay and audio tracks (never the main track). A track with clips asks for confirmation; its clips go too, links to them are cleared and video whose detached audio is deleted plays its own audio again.
- **Layer placement**: each visual clip has a `ClipTransform` (position as a fraction of the frame, scale, clockwise rotation, opacity) plus fade in/out. Main-track media is aspect-fit to the frame, overlay media only shrinks to fit, text keeps its pixel size. `LayerGeometry` is shared by the compositor and the preview handles.
- **Text layers**: font family, size, bold, color, alignment, optional background box; fade in/out. Images and text default to 5 s and can be trimmed to any length.
- **Inspector**: right-side panel showing the selected clip's settings (volume, text, transform, fades); one-off actions live in the clip's context menu.
- **Error reporting**: recoverable errors (preview build, playback, import) go to `EditorSession.report(_:)` and show in a sheet with the message, selectable details (app/macOS version, NSError chain) and Copy Details; export failures show in the export sheet with the same details. Hard crashes cannot be caught in-process.
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
2. **Audio** — detach audio (linked clip), audio tracks, clip move and trim, waveform, volume in the inspector panel; offline media + relink.
3. **Layers** — custom `AVVideoCompositing` (Core Image + Metal), text / image / video overlays, transform handles in the preview, z-index by dragging track headers.
4. **Export** — preset sheet, progress + cancel, M4A.

The basic version ends with phase 4 (v0.0.1.131026). After that there are no phases: each session adds one feature for the user's own workflow, listed under Features.

## Features

Workflow features added after the basic version, newest last.

- (none yet)

## Status

- Phases 1–4 are done: the basic version is complete (v0.0.1.131026).
- Next: workflow features, one per session; Open issues when the user asks.
- Bugs found along the way go to Open issues.

## Open issues

- **Crash on Option + full screen** (`brk #1`, Swift trap on Thread 1): backtrace (`bt`) still missing.
- **Crash (uncaught NSException on the main thread)**: not reproduced yet; the console reason and the steps are still missing. Suspect: video composition instructions with a gap or overlap after a move or trim.
- Dragging a linked audio clip moves its video; unlink first to move the audio alone.
- A clip dragged onto a lower lane can be drawn under it while dragging.
- Timeline menu items can show a stale enabled/disabled state.

## Versioning

- Format `x.y.z.DDMMYY`, e.g. `v0.0.1.131026`: `MARKETING_VERSION` is `x.y.z`, `CURRENT_PROJECT_VERSION` is the date. Shown in the About panel and in error reports (`AppVersion`).
- Updated by hand only: `scripts/set-version.sh [x.y.z]` sets the date to today and, if given, the `x.y.z` part.
- A version change is committed with a matching git tag (`v0.0.1.131026`).
- Each finished feature bumps the patch number (`scripts/set-version.sh 0.0.2` → `v0.0.2.DDMMYY`); its Features entry names that version.

## Development

```bash
# Core model tests. The scratch path must be outside Desktop: iCloud file
# attributes break code signing of the test bundle.
swift test --package-path Packages/EditorCore --scratch-path ~/Library/Caches/bacisc-editorcore-build
xcodebuild -scheme bacisc-video-editor build     # app
scripts/install.sh                               # Release build, install into /Applications
scripts/set-version.sh 0.0.2                     # set the version (date = today)
```
