# Core browser

Objective: functional (not branded) clone of the core file browser of https://fileosmac.com/. Branch: `feat/core-browser`.
Delivery: ask-on-risk. Test runner: Swift Testing via `xcodebuild test -scheme FileFinder -only-testing:FileFinderTests`.

## Specs

Quoted fragments come from the reference site's feature list (fileosmac.com).

- S1 Sidebar: "Favorites (Desktop, Documents, Downloads)", "Locations (iCloud Drive, ... the user's home folder, Macintosh HD)", external drives "appear in the sidebar", and "Trash". Workspaces and Smart Clean are out of scope for this feature.
- S2 Path bar: "Shows the breadcrumb path and accepts typed paths (⌘L)"; "⌘L | Type a path (Tab completes)".
- S3 Main pane: "Lists or cards of files and folders, with columns for name, date, size, and kind". "Icons come in Small, Medium, and Large sizes (⌘+ and ⌘−)".
- S4 Status bar: "Shows item count, selection, and free space (for example, \"21 items · 304.4 GB available\")".
- S5 Folder sizes: "Folders display their size and item count" (always on).
- S6 "Quick Look is available with Space."
- S7 "Rename in place with Return."
- S8 "Live refresh when folders change."
- S9 "Hidden files toggle with ⇧⌘."
- S10 "Copy, cut, and paste work with Finder."
- S11 "Undo for moves, copies, renames, and Trash moves (⌘Z)."
- S12 "Cards show real previews: the first page of a document, a photo, a video frame, or a slide."
- S13 App runs unsandboxed so it can browse the whole disk like Finder (assumption: required for a Finder replacement; Full Disk Access stays optional).

## Tasks

- [ ] T1 S3,S5,S9 — domain model + directory listing service + folder size calculator, with tests — inline
- [ ] T2 S10,S11 — file operations (rename, trash, copy, move, paste from pasteboard) with undo, with tests — inline
- [ ] T3 S1,S2,S4,S8 — sidebar locations, path parsing/completion, volume free space, directory watcher, with tests — inline
- [ ] T4 S3,S6,S7,S12,S13 — SwiftUI window: sidebar, path bar, list/grid, status bar, shortcuts, Quick Look, rename, thumbnails; disable sandbox — inline

Route evidence: one coherent app, units depend on each other (UI depends on T1-T3), so no Writer trigger; parent writes inline.

## Log

- L1 (2026-11-03) User: "I want to implement a MacOS app that is an exact clone of this app:  https://fileosmac.com/"
- L2 (2026-11-03) User: "A, start with the core browser"
- L3 Decision: clone functionality/UX only, not the FileOS name, logo, or marketing assets.
- L4 Baseline: scaffold committed at 5658fcd; baseline build succeeds (Xcode 27.2, macOS 27.2 target).
