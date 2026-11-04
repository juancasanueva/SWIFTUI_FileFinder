# Smart Clean

Objective: seventh slice of the fileosmac.com functional clone: a storage overview plus nine cleanup suggestions, Trash-first with Undo.
Branch: `feat/smart-clean` (stacked on `feat/developer-tools`). Delivery: ask-on-risk, one stacked branch per slice (cached from earlier slices); work-unit commits, high-risk units committed alone. Test runner: Swift Testing via `xcodebuild test -scheme FileFinder -destination 'platform=macOS' -only-testing:FileFinderTests`.

## Specs

Quoted from the reference site (fileosmac.com):

- S1 "Space back, safely" — "Nine suggestions, each says why, with Undo." "Keep your Mac roomy. Nothing goes until you've seen it, everything goes to the Trash, and Undo brings it back."
- S2 "FileOS shows how full your Mac is, then nine suggestions sorted into Safe to clear and Your call. Each one says why." Storage bar: "8.8 GB free of 245 GB", "Macintosh HD 236.2 GB used", categories "Apps", "Your files", "System", "Other", "In the Trash"; "You could free about 34 GB."
  - Assumption: Apps = /Applications + ~/Applications; Your files = the home folder without ~/Library and the Trash; Other = ~/Library; In the Trash = ~/.Trash; System = the rest of the used space. "You could free about" = the ticked total. Measured in the background; sizes show as they arrive.
- S3 "Safe to clear comes ticked: developer caches, duplicates (the copy you opened last is kept), installers for apps you have, and Mail's copies of attachments you opened."
- S4 "Your call starts unticked: big files, apps you haven't opened in 6 months, old screen recordings, old downloads and leftovers of deleted apps."
- S5 "Caches, cleared safely: Xcode DerivedData, device support, Simulator caches, npm, Homebrew, pip, Yarn and CocoaPods, from a strict list." "node_modules in projects you haven't touched for 6 months is shown, never ticked."
- S6 "Everything goes to the Trash first, and Undo brings it back. Empty Trash always asks." Buttons "Look Again", "Empty Trash", "Undo"; dialog "Empty the Trash?" with "Cancel" and "Empty Trash".
- Assumptions shared by the suggestions (not on the site):
  - User folders scanned for duplicates, big files and node_modules: Desktop, Documents, Downloads, Movies, Music, Pictures, plus ~/Developer, ~/Projects, ~/src, ~/code for node_modules. Hidden items and packages (apps, Photos libraries…) are never entered or flagged as files; iCloud files not downloaded are never read.
  - Duplicates: regular files of 1 MB or more with identical contents (size, then hash); the most recently opened copy is kept (last opened, then modified).
  - Installers: .dmg/.pkg in Downloads and Desktop whose name, without version/platform words, matches an installed app.
  - Mail attachments: the entries of Mail's "Mail Downloads" folder (Mail keeps there the attachments you opened); skipped when unreadable.
  - Big files: regular files of 1 GB or more.
  - Apps not opened in 6 months: .app bundles in /Applications and ~/Applications, not Apple's (com.apple.*) and not this app, whose last-opened date is known and older than 6 months.
  - Old screen recordings: .mov/.mp4 screen captures (Spotlight says so, or the name starts with "Screen Recording") older than 30 days.
  - Old downloads: files directly in Downloads (or in its Tidy kind folders) added more than 90 days ago and not opened in 90 days.
  - Leftovers of deleted apps: entries in ~/Library/Application Support, Caches, Preferences (.plist), Saved Application State, HTTPStorages and WebKit named like a bundle id, not com.apple.*, matching no installed app (same id, or the same vendor.product prefix), unchanged for 30 days. Containers are left alone.
  - The Smart Clean window opens from the sidebar and File ▸ Smart Clean…; a Clean button moves the ticked items to the Trash as one undoable step ("Undo Smart Clean"). Empty Trash permanently deletes ~/.Trash contents after the dialog.

## Tasks

- [ ] T1 S1,S2,S6 — framework: suggestion catalog (9 kinds, group, why), candidates, scan environment + shared walker, storage overview, SmartCleanModel (scan, ticks, total, Clean as one undo step, Look Again, Empty Trash with confirmation) — inline
- [ ] T2 S3,S5 — developer caches (strict list) + node_modules scanner — delegated (writer A)
- [ ] T3 S3 — duplicates scanner — delegated (writer B)
- [ ] T4 S3,S4 — installers, Mail attachments, old downloads, old screen recordings scanners — delegated (writer C)
- [ ] T5 S4 — big files, unused apps, leftovers scanners — delegated (writer D)
- [ ] T6 S1,S2,S6 — Smart Clean window: storage bar, sections, rows with why and items, Clean, Undo, Look Again, Empty Trash dialog, sidebar + menu entry — inline

Route evidence: T2–T5 are four independent units with disjoint files (one scanner file + one test file each), each 150+ lines with tests, launched together after T1 → Writer trigger (a) parallelism; the parent owns git and the scanner registry. T1 and T6 inline. Risk: T1 item 1 (Empty Trash deletes permanently; bulk trashing of user files) → independent verifier + native review; T5 leftovers item 1 (heuristic targets in ~/Library).

## Log

- L1 (2026-11-04) User: "Smart Clean" (picked as the next slice).
