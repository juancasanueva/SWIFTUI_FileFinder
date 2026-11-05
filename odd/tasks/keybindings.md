# Keybindings

Objective: keyboard shortcuts live in a JSON file in ~/.config and can be changed in Settings.
Branch: `feat/keybindings` from `main` (4a16335). Delivery: ask-on-risk; work-unit commits. Test runner: Swift Testing via `xcodebuild test -scheme FileFinder -destination 'platform=macOS' -only-testing:FileFinderTests`.

## Specs

- S1 "I want to have the keybindings in a file in .config folder, and be able to change then in the settings"
- S2 Format chosen by the user: "JSON (Recommended)" — "~/.config/filefinder/keybindings.json", e.g.
  `{ "newFolder": "cmd+shift+n", "openInTerminal": "cmd+alt+shift+t", "splitView": "cmd+d", "goBack": "cmd+[" }`
  - Assumptions: `$XDG_CONFIG_HOME/filefinder/keybindings.json` when XDG_CONFIG_HOME is set. Keys are action ids; values are modifiers (`cmd`, `ctrl`, `alt`, `shift`, written in that order) plus one key (a character, or `tab`, `delete`, `return`, `escape`, `space`, `up`, `down`, `left`, `right`, `f1`–`f12`), joined with `+`; `""` means no shortcut. Parsing ignores letter case and accepts `opt`/`option`/`command`/`control`.
- S3 The file (assumptions):
  - Created with every action and its default shortcut when missing.
  - An action missing from the file, or with a value that can't be read, keeps its default; unknown keys are ignored.
  - At launch, a file that isn't valid JSON is set aside as `keybindings.json.damaged-<stamp>` (`-2`, `-3`… when taken; as workspaces.json does) and the defaults are written again. Saved with a mistake while the app runs, it is left alone and the shortcuts in use stay (L5).
  - Edits made to the file while the app runs are picked up without relaunching.
- S4 Every menu command with a shortcut uses the file's shortcut (assumption: the menu commands in BrowserCommands, plus Tidy Downloads and Smart Clean, which have none by default; ⌃1–⌃9 for workspaces and the buttons inside sheets stay fixed).
- S5 Settings (assumptions): a Keyboard tab beside General (today's Terminal/Editor). Each action shows its shortcut; clicking it records the next key combination (Escape cancels); a shortcut already used by another action is refused with "Already used by “<action>”."; a key without ⌘, ⌃ or ⌥ (other than F1–F12 and Tab) is refused with "Add ⌘, ⌃ or ⌥: that key alone is needed for typing." (L5); resetting a row takes its default back from any action that has it; each row can be cleared or reset to its default; "Restore Defaults" resets all; "Open keybindings.json" opens the file. Changes are written to the file at once.

## Tasks

- [x] T1 S2,S3 — KeyBindings model: action catalog with titles and defaults, shortcut text parse/format, store (create, merge, damaged file set aside, save, set/clear/reset, external edits reloaded) — inline — ce15389 (tests written first; RED not run: they couldn't compile without the types; GREEN 14/14)
- [x] T2 S4 — menu commands take their shortcuts from the store — inline — c27e738 (no unit RED: SwiftUI menus can't be driven in tests; 31 shortcuts swapped one-for-one for their KeyAction, Tidy Downloads and Smart Clean added; full suite 357)
- [x] T3 S1,S5 — Settings: General and Keyboard tabs, shortcut recorder, clear, reset, Restore Defaults, open file; README — inline — 2e02e9e (RED observed for the key-press conversion: no such initializer; GREEN; full suite 359; Settings UI built, not runtime-driven)
- [x] T4 S3,S5 — L5 verifier findings: a broken file saved while the app runs is left alone; damaged backups never overwrite each other; Settings refuses keys needed for typing — inline — 902e3d0 (RED observed: 4 issues, then compile errors for typesText; GREEN 362)

Route evidence: T2 and T3 depend on T1; one area, sequential; no Writer trigger.

## Log

- L1 2026-11-05 User: "I want to have the keybindings in a file in .config folder, and be able to change then in the settings". Format asked; answer: "JSON (Recommended)".
- L2 T1: Shortcut (parse/format/display/KeyboardShortcut), KeyAction (33 actions, menus, titles, defaults = the menus' shortcuts at 4a16335), KeyBindingStore (XDG/~/.config path, defaults merged, file never rewritten on read, damaged JSON set aside, whole file written on each change, folder + file watchers for edits in place or by replacement). Saving writes every action; unknown keys in the file are dropped then.
- L3 T2: BrowserCommands reads KeyBindingStore.shared (observed, so menus follow changes); ⌃1–⌃9 stay fixed. A full run took 20–25 s instead of ~5 s while the Smart Clean verifier ran its timing probes (load average ~12); no single test was slow.
- L4 T3: SettingsView is a TabView (General, Keyboard). Keyboard lists the actions by menu; clicking a shortcut records the next key press in that window through a local key-down monitor (Escape cancels; the key is read unshifted); Clear, Reset per row, Restore Defaults, Open keybindings.json; a refused shortcut shows "Already used by “<action>”." under its row. The General footer shows the current terminal/editor/path bar shortcuts. README documents the file. The test host launches the app, so a test run creates the real ~/.config/filefinder/keybindings.json with the defaults (observed). Not runtime-verified: the recorder taking keys before the menus do.
- L5 Keybindings verifier (base 4a16335, HEAD 2e02e9e): points 1, 2, 3, 5 PASS, no blockers; point 4 (live menus following the file) UNAVAILABLE: osascript/System Events hung on a permission. Suite 359 (one run had the known TransferQueueTests.cancelLeavesQueue flake). All 31 baseline menu shortcuts equal the defaults (key code + modifiers); General footer identical to the base with the defaults. File: in-place, two-step and replacement edits picked up; never rewritten on read; no save loop; deleted file recreated. Recorder: only the Settings window, Escape cancels; menus can't act before the local monitor (reasoned, ~85–90%). XDG_CONFIG_HOME reaches the test host only as TEST_RUNNER_XDG_CONFIG_HOME. Advisories: A1 two damaged files in the same second: the second backup failed and was overwritten (lost); A2 "cmd + n" with spaces is rejected; A3 recording ⌘+ on a US layout stores cmd+shift+=; A4 a bare letter (or a key ending in `) can be recorded, taking that key from typing; A5 duplicates in the file aren't flagged; A6 a config folder that can't be created leaves nothing to watch. Accepted as corrections (T4): A1, A4, and a broken file saved mid-edit while the app runs being replaced by the defaults (found from A1). Left: A2, A3, A5, A6 and the ` in the footer. Scratch removed.
- L6 T4: load(whileRunning:) leaves a file that doesn't read alone (shortcuts in use stay); setAsideDamagedFile picks -2, -3… and, if the move fails, uses the defaults without writing; Shortcut.typesText + KeyBindingError.typesText refused by the Settings recorder (the file may still hold bare keys). A change made in Settings while the file is broken still writes the whole file over it.
