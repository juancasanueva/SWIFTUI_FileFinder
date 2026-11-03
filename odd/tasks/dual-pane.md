# Dual pane

Objective: third browser slice of the fileosmac.com functional clone: two side-by-side panes with transfers between them.
Branch: `feat/dual-pane` (stacked on `feat/folders-and-preview`). Delivery: ask-on-risk. Test runner: Swift Testing via `xcodebuild test -scheme FileFinder -only-testing:FileFinderTests`.

## Specs

Quoted from the reference site (fileosmac.com), Dual Pane section:

- S1 "⌘D splits the window into two panes." (⌘D again returns to one pane.)
- S2 "F5 copies the selection to the other pane. F6 moves it."
- S3 "Tab switches panes. ⌘U swaps them."
- S4 "Dragging moves items. Holding ⌥ while dragging copies them."
- S5 "Long copies run in a queue with progress and Cancel."
- S6 "Name conflicts prompt for keep both, replace, or skip."
  - Assumption: applies to every copy/move into a different folder (paste, F5/F6, drag), like Finder; duplicating inside the same folder keeps Finder's "copy" naming without a prompt. The prompt offers "apply to all" for the rest of the batch. Replace moves the existing item to the Trash and is undoable.
- S7 "Both panes are restored after relaunch."

## Tasks

- [ ] T1 S6 — conflict resolution in FileActions (keep both / replace / skip, apply to all, undoable replace) + prompt UI — inline
- [ ] T2 S5 — copy progress via copyfile(3), cancellable transfer queue + progress UI — inline
- [ ] T3 S1,S2,S3,S7 — window model with two panes: split, active pane, Tab, ⌘U, F5/F6, state restoration + split UI — inline
- [ ] T4 S4 — drag and drop between panes and onto folders (move, ⌥ copies) — inline

Route evidence: all units touch FileActions/BrowserModel or depend on them; no Writer trigger.

## Log

- L1 (2026-11-03) User: "start the dual pane slice"
