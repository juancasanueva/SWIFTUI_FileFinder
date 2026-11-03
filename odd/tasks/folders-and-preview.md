# Folders and preview

Objective: second browser slice of the fileosmac.com functional clone: New Folder, keyboard navigation in card view, preview pane.
Branch: `feat/folders-and-preview` (stacked on `feat/core-browser`). Delivery: ask-on-risk. Test runner: Swift Testing via `xcodebuild test -scheme FileFinder -only-testing:FileFinderTests`.

## Specs

- S1 New Folder (Finder parity, ⇧⌘N): creates "untitled folder" ("untitled folder 2", … on clashes) in the current folder, selects it and starts renaming it. Undo moves it to the Trash only while it is still empty; otherwise it reports the folder was left in place. Redo creates it again.
- S2 Card view keyboard navigation: ← → move the selection by one item, ↑ ↓ by one row; ⇧ extends the selection; with nothing selected the first arrow selects the first (→ ↓) or last (← ↑) item; movement stops at the edges; the selected card scrolls into view. ⌘↓ opens the selection.
- S3 Preview pane (reference: "When a folder is selected, it shows its location and a two-level preview of its contents."): a right-side pane toggled with ⇧⌘P (and a toolbar button), remembered across launches.
  - One folder selected: name, location, size and item count, and its contents two levels deep (folders first, a capped number of entries per level, hidden items excluded).
  - One file selected: a large real preview, name, kind, size, created and modified dates, location.
  - Several selected: "N items" and their total size. Nothing selected: the current folder.

## Tasks

- [ ] T1 S1 — New Folder action with undo/redo, menu command — inline
- [ ] T2 S2 — card view arrow-key selection model + grid wiring — inline
- [ ] T3 S3 — folder two-level preview loader + preview pane UI + toggle — inline

Route evidence: small dependent units in one window; no Writer trigger.

## Log

- L1 (2026-11-03) User: "start the next slice" (slice proposed earlier: "New Folder, arrow keys in card view, the preview pane").
