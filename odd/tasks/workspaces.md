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

- [ ] T1 S1,S2,S6 — WorkspaceStore: create/rename/delete, add/remove entries, bookmark resolution, JSON persistence — inline
- [ ] T2 S2,S5 — BrowserModel locations (folder or workspace), workspace listing with missing entries, history, folder-only operations guarded — inline
- [ ] T3 S3,S4,S5 — UI: sidebar section, ⌃1–⌃9, ⌥⌘N naming, rename/delete, Location column, Add to Workspace menu, drops onto workspaces — inline
- [ ] T4 S6 — window restoration of workspace panes — inline

Route evidence: T2–T4 depend on T1 and share BrowserModel; no Writer trigger.

## Log

- L1 (2026-11-03) User: "start the workspaces slice"
