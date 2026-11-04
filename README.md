# FileFinder

A keyboard-friendly file browser for macOS, written in SwiftUI. It browses the whole disk like Finder and adds dual panes, workspaces, tidying, developer tools and a safe cleanup page.

## Features

- **Browser**: a sidebar with Favorites, Locations and external drives; a path bar that accepts typed paths (Tab completes); list and card views with Small, Medium and Large icons; folder sizes and item counts; a status bar showing the item count, selection and free space.
- **Files**: Quick Look, rename in place, New Folder, hidden files toggle, live refresh, copy/cut/paste that works with Finder, and Undo for moves, copies, renames and Move to Trash.
- **Preview**: cards show real previews (a document's first page, a photo, a video frame). A preview pane shows the selected file, or a two-level look into the selected folder.
- **Dual pane**: two panes side by side, copy or move the selection to the other pane, drag to move (hold ⌥ to copy), a transfer queue with progress and Cancel, and a choice of keep both, replace or skip on name conflicts. Both panes are restored after relaunch.
- **Workspaces**: named pages that gather folders and files from anywhere, including cloud and external drives. Nothing is copied or moved.
- **Tidy**: moves loose files into folders by kind (Videos, Images, PDFs, Documents, Installers, Other). You see the plan before anything moves, and Undo puts it all back. You can also group a folder by kind or date added without moving anything on disk.
- **Developer tools**: the git branch and uncommitted changes in the path bar (read-only, it never fetches or changes anything); open the current folder in your terminal or editor; type commands such as `code .`, `cursor .`, `xed .` or `zed` in the path bar.
- **Smart Clean**: shows how full the Mac is, then nine suggestions in two groups. *Safe to clear* starts ticked: developer caches, duplicates (the copy you opened last is kept), installers for apps you already have, and Mail's copies of attachments. *Your call* starts unticked: big files, apps unused for 6 months, old screen recordings, old downloads and leftovers of deleted apps. Everything goes to the Trash first and Undo brings it back. Empty Trash always asks.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘L | Type a path |
| Space | Quick Look |
| Return | Rename |
| ⇧⌘N | New Folder |
| ⇧⌘. | Show or hide hidden files |
| ⌘+ / ⌘− | Bigger or smaller icons |
| ⇧⌘P | Preview pane |
| ⌘Z | Undo |
| ⌘D | Split into two panes, or back to one |
| Tab | Switch panes |
| ⌘U | Swap panes |
| F5 / F6 | Copy / move the selection to the other pane |
| ⌥⌘N | New workspace |
| ⌃1–⌃9 | Open a workspace |
| ⌥⌘T | Tidy this folder |
| ⌥⇧⌘T | Open the folder in Terminal |
| ⌥⇧⌘E | Open the folder in your editor |

## Requirements

- macOS 27.2 or later
- Xcode with the macOS 27.2 SDK

The app runs without the App Sandbox so it can browse the whole disk. Full Disk Access is optional and only needed for protected folders.

## Build and run

Open `FileFinder.xcodeproj` in Xcode, choose the **FileFinder** scheme and press ⌘R.

From the command line:

```sh
xcodebuild build -scheme FileFinder -destination 'platform=macOS'
```

## Tests

Unit tests use Swift Testing:

```sh
xcodebuild test -scheme FileFinder -destination 'platform=macOS' -only-testing:FileFinderTests
```

Some tests move small files to your real Trash.

## Project layout

```
FileFinder/            App sources
  Browser/             Browser model and commands
    FileSystem/        Listing, watching, copying and file actions with Undo
    Model/             File items, grouping, refresh pacing
    Navigation/        Typed paths, sidebar locations, status text
    SmartClean/        Storage overview and cleanup scanners
    Tidy/              File kinds used by Tidy and grouping
    Developer/         Git status, terminals, editors, path bar commands
    Views/             SwiftUI views
    Workspaces/        Workspace storage
FileFinderTests/       Unit tests
FileFinderUITests/     UI tests
```
