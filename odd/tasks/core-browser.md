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
- S14 User: "fix the review findings first" — the review findings recorded in L8 (all code findings; R1 sandbox is an accepted decision, no change).
- S15 User: "fix the 5 smaller issues first" — the five follow-ups listed in L14/L13: (1) folder stuck on "Calculating…" when it changes mid-measure, (2) undo/redo of a multi-file move registers the full inverse even when the undo stops partway, (3) overlapping sidebar refreshes can apply an older snapshot, (4) leaving a deleted folder waits for in-flight size calculations, (5) a change deep inside a subfolder doesn't update its size.
- S13 App runs unsandboxed so it can browse the whole disk like Finder (assumption: required for a Finder replacement; Full Disk Access stays optional).

## Tasks

- [x] T1 S3,S5,S9 — domain model + directory listing service + folder size calculator, with tests — inline — 5fc1ccb (RED: missing symbols; GREEN 8/8)
- [x] T2 S10,S11 — file operations (rename, trash, copy, move, paste from pasteboard) with undo, with tests — inline — 4377a74 (GREEN 21/21; RED not run separately)
- [x] T3 S1,S2,S4,S8 — sidebar locations, path parsing/completion, volume free space, directory watcher, with tests — inline — f71101a (GREEN 33/33)
- [ ] T4 S3,S6,S7,S12,S13 — SwiftUI window, sidebar, path bar, list/cards, status bar, shortcuts, Quick Look, rename, thumbnails; sandbox off — inline — 388875d, 44ed215, 07902fb, 77796b7; 37/37 tests; verifier PASS after one correction; native review approved+acknowledged (review-ae1077e770259109). Open: manual UI check of Return-rename in list, Space/Return in cards, ⌘+, Tab completion (not drivable here)
- [x] T5 S14 — fix review findings — inline — 814fc91, ca57e40; 58/58 tests (3 runs); verifier PASS after one correction; native review review-21beb81078489c20 approved + acknowledged
- [x] T6 S15 — fix the 5 smaller issues — inline — cdbe8e5, 1927fe1, 67df663; 67/67 tests (3 runs); verifier PASS after two corrections; native review approved + acknowledged

Route evidence: one coherent app, units depend on each other (UI depends on T1-T3), so no Writer trigger; parent writes inline.

## Log

- L1 (2026-11-03) User: "I want to implement a MacOS app that is an exact clone of this app:  https://fileosmac.com/"
- L2 (2026-11-03) User: "A, start with the core browser"
- L3 Decision: clone functionality/UX only, not the FileOS name, logo, or marketing assets.
- L4 Baseline: scaffold committed at 5658fcd; baseline build succeeds (Xcode 27.2, macOS 27.2 target).
- L5 Added paste-and-move (⌥⌘V, Finder parity) with RED->GREEN test. URLs normalized via `URL.canonical` so folder URLs from listings, sidebar and pasted results compare equal.
- L6 Risk: item 2 (app sandbox disabled). RDD assess escalated to high; review due. Independent verifier launched first.
- L7 Verifier: B1 copy-into-itself recursion, P1 watcher started after measuring, P2 ⌘⌫ active while typing → fixed in 07902fb; recheck: all fixed. New advisory (duplicate measurements) fixed in 77796b7.
- L8 Native review (risk, resilience, reliability) approved with 12 non-blocking findings; acknowledged, authority burned. Follow-ups: file ops run on the main actor (big copies freeze UI); undo failures are silent; copy undo has no redo; folder stats go stale and failed measurements show "Calculating…" forever; sidebar does disk I/O in body; load error always suggests Full Disk Access; opening several folders navigates to each; BrowserModel has no tests.
- L9 Next: user runs the app to check the keyboard interactions; then next slice (New Folder, card arrow keys, preview pane) or the follow-ups above.
- L10 (2026-11-03) User: "fix the review findings first"
- L11 T5 first pass 814fc91 (55 tests). Verifier found change-caused ordering blockers: B1 rename undo not queued (double undo misapplies), B2 concurrent copies plan the same name and the loser's cleanup trashes the winner's copy, B3 redo copy trashes a newer file that took the name, B4 late cut-paste overwrites a newer clipboard. RED observed for B1-B3 tests.
- L12 Correction ca57e40: all operations serialized on one queue (rename async), copies never touch existing destinations, copy undo/redo share a CopyRecord with inode checks, clipboard rewrite guarded by changeCount, stale measurements dropped. 58/58 tests, 3 repeated runs. Deep (non-direct) subfolder changes still don't refresh sizes — accepted limit, documented. Recheck pending.
- L13 Recheck: B1-B4 fixed. New narrower race from the A1 change: a folder whose measurement is discarded stays in `measuring`, so the follow-up pass skips it and it can stay "Calculating…" until its next change. Fix: re-measure discarded folders before `measureFolders` returns. Logged as follow-up (correction bound reached).
- L14 Second native review approved with non-blocking findings (follow-ups): folder can stay "Calculating…" if changed mid-measure (same as L13); relocation undo/redo registers the full inverse even when the undo stops partway; overlapping sidebar refreshes can apply an older snapshot; run() now waits for in-flight measurements before stepping out of a deleted folder.
- L15 (2026-11-03) User: "fix the 5 smaller issues first"
- L16 T6 first pass cdbe8e5 (64 tests, RED observed for issues 1, 2, 4, 5). Verifier: issues 1-4 fixed; blocker B1 in 5 — FSEvents batches queued faster than the consumer drained them, so busy trees (~/Library) were re-walked non-stop and flickered to "Calculating…". Advisories: A2 "/" root never matched, A3 stale changedWhileMeasuring.
- L17 Correction 1927fe1: deep changes coalesced into one pending set, refreshed every 2 s, each folder at most once per 10 s, previous size kept during refresh; no subtree watching at "/"; root prefix fixed; changedWhileMeasuring removed. RED→GREEN for busy-folder and root tests; 66/66, 3 runs. Recheck pending.
- L18 Recheck of 1927fe1: B1 partially fixed (pacing stamped at walk start, so walks longer than the interval ran back to back). Second correction 67df663: lastDeepRefresh stamped when any walk finishes; interval injectable. RED→GREEN slowWalksArePaced; 67/67, 3 runs. Final recheck: B1 fixed.
- L19 Third native review approved with non-blocking findings (follow-ups): a huge busy tree (~/Library seen from home with hidden files shown) is still re-walked every walk-duration + 10 s; a folder that once failed to measure is never refreshed by deep changes; the busy-folder and pacing tests depend on wall-clock timing and could be flaky on slow machines.
