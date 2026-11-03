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
- S8 User: "fix the follow-ups first" — the six follow-ups in L9.

## Tasks

- [x] T1 S6 — conflict resolution in FileActions (keep both / replace / skip, apply to all, undoable replace) + prompt UI — inline — f801f72 (RED→GREEN, 99/99); Risk: item 1 (replace trashes existing items) → verifier; corrections f2d74d7, 1f513af
- [x] T2 S5 — copy progress via copyfile(3), cancellable transfer queue + progress UI — inline — f5ca4a3 (RED→GREEN, 107/107)
- [x] T3 S1,S2,S3,S7 — window model with two panes: split, active pane, Tab, ⌘U, F5/F6, state restoration + split UI — inline — ef71438 (RED→GREEN, 124/124)
- [x] T4 S4 — drag and drop between panes and onto folders (move, ⌥ copies) — inline — 60afd8e (RED→GREEN, 131/131)
- [ ] T5 S8 — fix the L9 follow-ups — inline

Route evidence: all units touch FileActions/BrowserModel or depend on them; no Writer trigger.

## Log

- L1 (2026-11-03) User: "start the dual pane slice"
- L2 T1 verifier: B1 — all Replace targets were trashed up front, so a failing transfer left the destination with neither old nor new items (also when the replaced item was another source of the batch). Advisories: prompt continuation never released on window close (would hang a shared queue), remaining count too broad, undo restored the incoming name's case, "Stop" wording.
- L3 Correction (this commit): replace per item inside performCopies/performMoves with rollback on failure; batch sources never replaced; real on-disk name used for the replaced item; remaining counts later clashes only; windowWillClose answers skip-all; "Skip All" shown only when more conflicts follow. RED→GREEN for 5 regression tests; 112/112.
- L4 T2 f5ca4a3: FileCopier (copyfile(3) with status callback, clone when possible, cancel via COPYFILE_QUIT), TransferProgress + TransferBar (shown after 0.4 s, Cancel, queued count), cancelCurrentTransfer cancels only the running operation; partial copies removed (not trashed); CancellationError never alerts.
- L5 T1 recheck at f2d74d7: B1, A3, A4 fixed; A1 still failing (a paste queued behind an open prompt asked after the window closed and blocked the queue). Second correction: BrowserModel.isClosed makes later prompts answer skip-all (committed with T3 since BrowserModel carries both); replaced items keep the incoming name's case; trashItem throws if the Trash gives no location. RED→GREEN (queued paste hung before); 124/124.
- L6 T3: BrowserWindowModel (one or two panes sharing one FileActions; toggleSplit/switchPane/swapPanes/activate; F5/F6 copyToOtherPane/moveToOtherPane with the conflict prompt; WindowState JSON restored via @SceneStorage with fallback for missing folders), PaneView, split HSplitView UI with active marker, menu commands ⌘D, Tab (disabled while typing), ⌘U, F5, F6; focus follows Tab via focusRequest. 10 window-model tests.
- L7 T1 final recheck at ef71438: A1 fixed (queued paste no longer prompts after close), trash-location guard and incoming-name case verified with undo/rollback probes.
- L8 T4 60afd8e: BrowserModel.beginDrag (carries the selection when the grabbed item is in it; pasteboard holds the grabbed item's file URL, so Finder accepts it), drop(_:into:copying:) moves or copies with the conflict prompt, ignores a folder dropped onto itself; Table rows (itemProvider + row dropDestination), cards (onDrag + dropDestination), pane background drops. Multi-item drags to other apps carry only the grabbed item (known limit).
- L9 Four-lens native review approved + acknowledged, non-blocking findings (follow-ups):
  1. performCopies trashes a replaced item before the "destination exists" guard, whose `continue` neither restores it nor records it for undo (raced destination) — the item stays in the Trash but undo can't bring it back.
  2. The app-wide drag session is only cleared by a drop in this app; a cancelled drag or a drop into Finder leaves it, so a later external drop of the same file can expand into the stale selection.
  3. Close Split View drops the inactive pane without releasing its pending conflict prompt (blocks the shared queue).
  4. Copies pre-measure their sources before the progress bar (and Cancel) appear; a huge folder means a long, uncancellable first pass.
  5. Readability: duplicate reload in transferToOtherPane, repeated skip-all literal, two path normalizations in resolvedPlan, drop handler duplicated four times.
  6. Tests missing for F5/F6 into a clash, F5/F6 failure alerts and cancellation.
- L10 (2026-11-03) User: "fix the follow-ups first"
- L11 T5 9beb190: (1) replace no longer pre-checks the destination (copyfile EXCL refuses safely); a replaced item that can't be put back stays recorded so undo can retry; steps with only trashed items still register undo. (2) drag sessions carry a private pasteboard marker; a drop expands only when the drag pasteboard holds the same session id (falls back to the dropped URLs). (3) Close Split View calls windowWillClose on the closing pane. (4) progress bar (with Cancel) shows "Preparing…" before sizes are measured; sizes are injectable and cancellation-aware. (5) skipAll constant, comparablePath helper, handleDrop helper, single reload pair. (6) tests for F5 clash prompt, F6 failure alert, quiet F5 cancel, split close release. RED observed for 1-4 tests; one stale test updated (bar now appears before totals are known). 138/138, 3 runs. Risk: item 1 → verifier.
