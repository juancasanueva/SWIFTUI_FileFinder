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

- [ ] T1 S1,S2 — FileKind classifier, TidyPlanner, FileActions.tidy with one-step undo/redo — inline
- [ ] T2 S1,S2 — plan sheet, ⌥⌘T, Tidy Downloads…, toolbar button — inline
- [ ] T3 S3 — date added, Group By (model, menu, list sections, card sections, grouped arrow keys) — inline

Route evidence: T2 depends on T1; T3 shares BrowserModel and the views with T2; no Writer trigger. Forecast ~900 authored lines; stacked per-slice branch as before.

## Log

- L1 (2026-11-04) User: "lets continue this the implementation" → picked "Tidy" as the next slice.
