# Tidy

Objective: fifth slice of the fileosmac.com functional clone: tidy loose files into folders by kind, and group a folder by kind or date added.
Branch: `feat/tidy` (stacked on `feat/workspaces`). Delivery: ask-on-risk, one stacked branch per slice (as in earlier slices). Test runner: Swift Testing via `xcodebuild test -scheme FileFinder -destination 'platform=macOS' -only-testing:FileFinderTests`.

## Specs

Quoted from the reference site (fileosmac.com):

- S1 "Tidy moves every loose file into a folder for its kind." Kinds: "Videos, Images, PDFs, Documents, Installers, Other". "⌥⌘T: Tidy this folder"; a "Tidy Downloads…" button. "Your Downloads, sorted in one click."
  - Assumption: loose files are the visible non-folder items directly in the folder (packages such as .app count as files). Hidden files and in-progress downloads (.download, .crdownload, .part) never move. Files go into "<folder>/<Kind>"; an existing folder of that name is reused, a clash inside it keeps both ("name 2.ext"). A kind whose folder name is taken by a file is left out. Unavailable in workspaces.
- S2 "You see the plan before anything moves, and Undo puts it all back." "Nothing moves without a preview." "Moves, copies, renames and Move to Trash all undo with ⌘Z."
  - Assumption: the plan sheet lists each kind folder with its files and Cancel / Tidy. One ⌘Z moves every file back and trashes the kind folders the tidy created while they are still empty (folders that already existed are never trashed). Redo tidies again. Files gone or changed since the preview are skipped.
- S3 "Want a look first? Group by kind or date added: each kind becomes a folder in its own color, and nothing moves on disk." "Group a folder by kind or date added."
  - Assumption: View ▸ Group By: None / Kind / Date Added, remembered across launches. Kind groups: Folders, then the S1 kinds, each with its own color. Date Added groups: Today, Yesterday, Previous 7 Days, Previous 30 Days, then months of this year, then years. List and card views both show group headers; sorting applies inside each group; card arrow keys follow the grouped layout.

## Tasks

- [x] T1 S1,S2 — FileKind classifier, TidyPlanner, FileActions.tidy with one-step undo/redo — inline — 7199f58 (RED→GREEN, 176/176)
- [x] T2 S1,S2 — plan sheet, ⌥⌘T, Tidy Downloads…, toolbar button — inline — bb971a7 (RED→GREEN for model, 180/180; sheet not runtime-driven)
- [x] T3 S3 — date added, Group By (model, menu, list sections, card sections, grouped arrow keys) — inline — b5181e4 (RED→GREEN, 186/186; app launches)

Route evidence: T2 depends on T1; T3 shares BrowserModel and the views with T2; no Writer trigger. Forecast ~900 authored lines; stacked per-slice branch as before.

## Log

- L1 (2026-11-04) User: "lets continue this the implementation" → picked "Tidy" as the next slice.
- L2 T1: FileKind (extension lists + UTType), TidyPlan.make (loose files, reuse/blocked kind folders), FileActions.tidy on the serial queue: creates missing kind folders, keep-both naming via resolvedPlan, one undo group (folder undos registered first so undo moves files out before the empty check); New Folder undo helpers gained actionName/reuseExisting (New Folder behavior unchanged, existing tests green).
- L3 T2: BrowserModel.tidyPreview/prepareTidy/confirmTidy/cancelTidy/tidyDownloads; TidySheet; File ▸ Tidy This Folder… ⌥⌘T (in File so it wins over View ▸ Hide Toolbar ⌥⌘T), Tidy Downloads…; toolbar Tidy button.
- L4 T3: FileItem.dateAdded (addedToDirectoryDate, falls back to creation date), ItemGrouping (Folders + kinds; Today/Yesterday/Previous 7/30 Days/months/years/No Date), BrowserModel.groupBy persisted, items flattened in group order, grouped ↑/↓ (clamp only across groups; inside a group the old "no card below → stay" rule holds). Table Sections and LazyVGrid pinned section headers; View ▸ Group By and toolbar menu.
- L5 Native assess (base 0f32e5a, committed-only): medium, review_due false (under_budget) after T1 and after T3. Risk: none — moves reuse the guarded move/undo primitives, undo only trashes empty folders tidy created; shared code changed (New Folder undo, arrow keys, sorting) is pinned by unchanged existing tests. Not runtime-verified: ⌥⌘T vs toolbar toggle, the sheet, Table section headers, pinned card headers.
