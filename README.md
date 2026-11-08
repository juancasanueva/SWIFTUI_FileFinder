# <img src="FileFinder/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" alt="FileFinder icon" width="112" align="center"> FileFinder

A keyboard-friendly file browser for macOS, written in SwiftUI. It browses the whole disk like Finder and adds dual panes, workspaces, tidying, developer tools and a safe cleanup page.

![FileFinder with two panes, the sidebar and the function key bar](docs/screenshots/dual-pane.png)

![FileFinder with the built-in terminal panel open in the current folder](docs/screenshots/terminal-panel.png)

![Smart Clean showing disk usage and cleanup suggestions grouped into Safe to clear and Your call](docs/screenshots/smart-clean.png)

## Install

```sh
brew install --cask juancasanueva/tap/filefinder
```

Apple silicon and macOS 15 or later only. Or download `FileFinder-<version>.zip` from [Releases](https://github.com/juancasanueva/SWIFTUI_FileFinder/releases).

The app updates itself through Sparkle: choose **FileFinder ▸ Check for Updates…**, or turn on automatic checks in Settings ▸ General.

## Features

- **Browser**: a sidebar with Favorites (add your own folders with Add Favorite at the end of the section; right-click one to remove it), Locations, external drives and a Settings button at the bottom; a path bar that accepts typed paths (Tab completes); list, card and column views (⌘1, ⌘2, ⌘3) with Small, Medium and Large icons; column view shows one column per folder from where you started down to the current one, plus the selected folder's contents or the selected file's details, with → to enter a folder and ← to go back (workspaces stay in list view); a Permissions column in list view (`drwxr-xr-x`, as `ls -l` shows it); folder sizes and item counts; a status bar showing the item count, selection and free space; a function key bar at the bottom (F2 Rename, F7 Mkdir, F8 Delete, F9 New MD, F10 New TXT, plus F5 Copy and F6 Move with two panes) whose entries are also buttons.
- **Command palette**: ⌘K opens one search box for every menu command that can run now, your workspaces, and files and folders anywhere on the Mac (found with Spotlight, so hidden files and folders Spotlight skips, such as `node_modules`, don't show up). Letters can be scattered (`nf` finds New Folder), and things you pick often or recently rank higher; with nothing typed it lists your recent picks and then every command with its shortcut. Return runs a command, opens a folder in the pane or a file in its app; ⌘Return shows the file in its folder instead.
- **Files**: Quick Look, rename in place, New Folder, New Markdown File and New Text File (an empty `new.md` or `new.txt`, from the right-click menu on empty space), show hidden files (⇧⌘. or Settings ▸ General, shared by every window), live refresh, Compress (right-click, the File menu or ⌘K) zips the selection into `name.zip` or `Archive.zip` next to it, copy/cut/paste that works with Finder, and Undo for moves, copies, renames and Move to Trash.
- **Preview**: cards show real previews (a document's first page, a photo, a video frame). A preview pane shows the selected file, or a two-level look into the selected folder. Code and config files show their first lines with syntax highlighting. A Markdown file shows rendered, with an Edit tab to change it: ⌘S saves, and edits are also saved when you select another file. If the file changed on disk in the meantime, nothing is overwritten: you choose Overwrite or Reload.
- **Dual pane**: two panes side by side, copy or move the selection to the other pane, drag to move (hold ⌥ to copy), a transfer queue with progress and Cancel, and a choice of keep both, replace or skip on name conflicts. With a second pane or the terminal open, a blue border marks the area that has keyboard focus. Both panes are restored after relaunch.
- **Workspaces**: named pages that gather folders and files from anywhere, including cloud and external drives. Nothing is copied or moved.
- **Tidy**: moves loose files into folders by kind (Videos, Images, PDFs, Documents, Installers, Other). You see the plan before anything moves, and Undo puts it all back. You can also group a folder by kind or date added without moving anything on disk.
- **Developer tools**: a built-in Ghostty terminal panel that opens a shell in the current folder and reads your Ghostty config (the Terminal toolbar button shows or hides it; ⌥⇧⌘T, Open in Terminal on a folder and `terminal` in the path bar open it there); the git branch and uncommitted changes in the path bar (read-only, it never fetches or changes anything); Open in external terminal on a folder opens it in the terminal app picked in Settings (Terminal, iTerm, Warp or Ghostty); open the current folder in your editor; type commands such as `code .`, `cursor .`, `xed .`, `zed` or `warp` in the path bar.
- **Smart Clean**: shows how full the Mac is, then nine suggestions in two groups. *Safe to clear* starts ticked: developer caches, duplicates (the copy you opened last is kept), installers for apps you already have, and Mail's copies of attachments. *Your call* starts unticked: big files, apps unused for 6 months, old screen recordings, old downloads and leftovers of deleted apps. Everything goes to the Trash first and Undo brings it back. Empty Trash always asks.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘K | Command palette |
| ⌘L | Type a path |
| Space | Quick Look |
| Return | Open the selected folder or file |
| Backspace | Go up to the enclosing folder |
| F2 | Rename |
| Escape | Cancel a rename or the typed path |
| ⇧⌘N or F7 | New Folder |
| F8 | Move to Trash (like ⌘⌫) |
| F9 | New Markdown File (an empty `new.md`; also in the right-click menu on empty space) |
| F10 | New Text File (an empty `new.txt`; also in the right-click menu on empty space) |
| ⇧⌘. | Show or hide hidden files |
| ⌘+ / ⌘− | Bigger or smaller icons |
| ⇧⌘P | Preview pane |
| ⌘S | Save the Markdown file being edited in the preview pane |
| ⌘Z | Undo |
| ⌘D | Split into two panes, or back to one (Settings ▸ General can open new windows with two panes) |
| ⌥⌘← / ⌥⌘→ | Focus the left / right pane; from the left pane, ⌥⌘← goes on to the sidebar (↑/↓ to move, Return to open) and ⌥⌘→ comes back |
| ⌥⌘↓ / ⌥⌘↑ | With the terminal open: move focus down into the terminal, and back up to the pane you came from; in the terminal, ⌥⌘← / ⌥⌘→ go to the left / right pane |
| ⌘U | Swap panes |
| F5 / F6 | Copy / move the selection to the other pane |
| ⌥⌘N | New workspace |
| ⌃1–⌃9 | Open a workspace |
| ⌥⌘T | Tidy this folder |
| ⌥⇧⌘T | Open the folder in the terminal panel |
| ⌃⌥⌘T | Open the folder in your external terminal |
| ⌥⇧⌘E | Open the folder in your editor |

On Mac keyboards the function keys control the Mac by default (F10 is Mute), so press fn with F2 and F5–F10, or turn on "Use F1, F2, etc. keys as standard function keys" in System Settings ▸ Keyboard. The entries in the function key bar are also buttons.

These are the defaults. Menu shortcuts can be changed in Settings ▸ Keyboard (click a shortcut, then type the new one; Escape cancels) or in `~/.config/filefinder/keybindings.json` (`$XDG_CONFIG_HOME/filefinder/keybindings.json` when that is set). The file is created with every action on first launch, and edits to it apply while the app runs:

```json
{
  "goBack": "cmd+[",
  "newFolder": "cmd+shift+n",
  "openInTerminal": "cmd+alt+shift+t",
  "smartClean": "",
  "splitView": "cmd+d"
}
```

A shortcut is modifiers (`cmd`, `ctrl`, `alt`, `shift`) and one key, joined with `+`: a character, `plus`, `tab`, `delete`, `return`, `escape`, `space`, `up`, `down`, `left`, `right` or `f1`–`f12`. An empty value means no shortcut. An action missing from the file, or with a value that can't be read, keeps its default. At launch, a file that isn't valid JSON is set aside as `keybindings.json.damaged-<time>` and the defaults are written again; saved with a mistake while the app runs, it is left alone and the shortcuts in use stay until it reads again. In Settings, a key needs ⌘, ⌃ or ⌥ (F1–F12 and Tab can stand alone), so a shortcut never takes a key needed for typing. ⌃1–⌃9, F7, F8, F9 and F10 (New Folder, Move to Trash, New Markdown File and New Text File in the function key bar) and the keys inside dialogs can't be changed; giving F7, F8, F9 or F10 to a menu action in the file takes it from the bar.

## Requirements

- macOS 15 or later to run it
- Xcode 27.2 to build it (the release uses the macOS 27.2 SDK)

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

## Releasing

A pushed `v*` tag builds, signs, notarizes and publishes a release and its update feed. See [RELEASING.md](RELEASING.md).

## Project layout

```
FileFinder/            App sources
  Browser/             Browser model and commands
    FileSystem/        Listing, watching, copying and file actions with Undo
    Keybindings/       Menu shortcuts and keybindings.json
    Model/             File items, grouping, refresh pacing
    Navigation/        Typed paths, sidebar locations, status text
    SmartClean/        Storage overview and cleanup scanners
    Tidy/              File kinds used by Tidy and grouping
    Developer/         Git status, terminals, editors, path bar commands
    Views/             SwiftUI views
    Workspaces/        Workspace storage
  Updates/             Check for Updates (Sparkle)
  Resources/           Update keys merged into Info.plist
FileFinderTests/       Unit tests
FileFinderUITests/     UI tests
scripts/               Release build and appcast scripts
.github/workflows/     The release pipeline
```

## License

MIT. See [LICENSE](LICENSE).
