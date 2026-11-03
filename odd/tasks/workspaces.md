# Workspaces

Objective: fourth slice of the fileosmac.com functional clone: named pages that gather folders and files from anywhere.
Branch: `feat/workspaces` (stacked on `feat/dual-pane`). Delivery: ask-on-risk. Test runner: Swift Testing via `xcodebuild test -scheme FileFinder -only-testing:FileFinderTests`.

## Specs

Quoted from the reference site (fileosmac.com):

- S1 "Collects folders and files from anywhere on the Mac, including cloud and external drives, onto one page."
- S2 "Nothing is copied or moved."
  - Assumption: entries are stored as file bookmarks so they survive moves and renames; an entry whose item is gone shows as missing and can be removed. Inside a workspace, ⌘⌫ and "Remove from Workspace" only remove the entry, never trash the file. Pasting and New Folder are unavailable there; dropping items onto a workspace adds them.
- S3 "Open with ⌃1–⌃9. Create a new one with ⌥⌘N."
- S4 Sidebar: "A Workspaces section at the top" listing workspaces; rename and delete (deleting a workspace never touches its files).
- S5 "Workspace view: A single page that gathers folders and files from different locations." — the list shows a Location column; opening a folder entry navigates into it (Back returns to the workspace).
- S6 Workspaces persist across launches and are shared by all windows; a pane showing a workspace is restored after relaunch.

## Tasks

- [x] T1 S1,S2,S6 — WorkspaceStore: create/rename/delete, add/remove entries, bookmark resolution, JSON persistence — inline — 9972df6 (RED→GREEN, 148/148)
- [x] T2 S2,S5 — BrowserModel locations (folder or workspace), workspace listing with missing entries, history, folder-only operations guarded — inline — f31eb78 (RED→GREEN, 156/156)
- [x] T3 S3,S4,S5 — UI: sidebar section, ⌃1–⌃9, ⌥⌘N naming, rename/delete, Location column, Add to Workspace menu, drops onto workspaces — inline — 9518d97 (RED→GREEN for model commands, 165/165; UI not runtime-driven)
- [x] T4 S6 — window restoration of workspace panes — inline — 9518d97 (RED→GREEN, 3 restoration tests)

Route evidence: T2–T4 depend on T1 and share BrowserModel; no Writer trigger.

## Log

- L1 (2026-11-03) User: "start the workspaces slice"
- L2 T1: WorkspaceStore (bookmarks, follows moves/renames, Trash counts as missing, duplicate-free add, damaged JSON set aside as .damaged-<stamp>, saved to Application Support/FileFinder/workspaces.json).
- L3 T2: BrowserModel shows a folder or a workspace (workspaceID + BrowserLocation history); workspace listing with missingEntries; ⌘⌫ removes entries only; paste/New Folder no-ops; drops onto a workspace add; F5/F6 into a workspace pane add; deleting an open workspace falls back to the folder.
- L4 T3/T4: sidebar Workspaces section (⌃n badges, + button, drop to add, Rename…/Delete), WorkspaceNameSheet via BrowserWindowModel.namingRequest, ⌃1–⌃9 and ⌥⌘N commands, conditional Location column, Add to Workspace / Remove from Workspace / Show in Enclosing Folder menus, missing-items bar, path bar label; WindowState stores each pane's workspace (old state still decodes). PaneView body split into layout + PaneBehavior (type-checker limit).
- L5 Risk: none — new persisted file only adds records; ⌘⌫ in workspaces is strictly safer (never trashes). Not runtime-verified: sidebar interactions, ⌃1–⌃9, sheet, drops onto rows.
