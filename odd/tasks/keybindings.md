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
  - A file that isn't valid JSON is set aside as `keybindings.json.damaged-<stamp>` (as workspaces.json does) and the defaults are written again.
  - Edits made to the file while the app runs are picked up without relaunching.
- S4 Every menu command with a shortcut uses the file's shortcut (assumption: the menu commands in BrowserCommands, plus Tidy Downloads and Smart Clean, which have none by default; ⌃1–⌃9 for workspaces and the buttons inside sheets stay fixed).
- S5 Settings (assumptions): a Keyboard tab beside General (today's Terminal/Editor). Each action shows its shortcut; clicking it records the next key combination (Escape cancels); a shortcut already used by another action is refused with "Already used by “<action>”."; resetting a row takes its default back from any action that has it; each row can be cleared or reset to its default; "Restore Defaults" resets all; "Open keybindings.json" opens the file. Changes are written to the file at once.

## Tasks

- [x] T1 S2,S3 — KeyBindings model: action catalog with titles and defaults, shortcut text parse/format, store (create, merge, damaged file set aside, save, set/clear/reset, external edits reloaded) — inline — (T1 commit) (tests written first; RED not run: they couldn't compile without the types; GREEN 14/14)
- [x] T2 S4 — menu commands take their shortcuts from the store — inline — (T2 commit) (no unit RED: SwiftUI menus can't be driven in tests; 31 shortcuts swapped one-for-one for their KeyAction, Tidy Downloads and Smart Clean added; full suite 357)
- [ ] T3 S1,S5 — Settings: General and Keyboard tabs, shortcut recorder, clear, reset, Restore Defaults, open file; README — inline — pending

Route evidence: T2 and T3 depend on T1; one area, sequential; no Writer trigger.

## Log

- L1 2026-11-05 User: "I want to have the keybindings in a file in .config folder, and be able to change then in the settings". Format asked; answer: "JSON (Recommended)".
- L2 T1: Shortcut (parse/format/display/KeyboardShortcut), KeyAction (33 actions, menus, titles, defaults = the menus' shortcuts at 4a16335), KeyBindingStore (XDG/~/.config path, defaults merged, file never rewritten on read, damaged JSON set aside, whole file written on each change, folder + file watchers for edits in place or by replacement). Saving writes every action; unknown keys in the file are dropped then.
- L3 T2: BrowserCommands reads KeyBindingStore.shared (observed, so menus follow changes); ⌃1–⌃9 stay fixed. A full run took 20–25 s instead of ~5 s while the Smart Clean verifier ran its timing probes (load average ~12); no single test was slow.
