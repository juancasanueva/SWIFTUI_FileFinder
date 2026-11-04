# Developer tools

Objective: sixth slice of the fileosmac.com functional clone: git at a glance, Open in Terminal / editor, path bar commands, Settings.
Branch: `feat/developer-tools` (stacked on `feat/tidy`). Delivery: ask-on-risk, one stacked branch per slice. Test runner: Swift Testing via `xcodebuild test -scheme FileFinder -destination 'platform=macOS' -only-testing:FileFinderTests`.

## Specs

Quoted from the reference site (fileosmac.com):

- S1 "Git at a glance: the branch and uncommitted changes in the path bar." "Read-only: it never fetches, pulls or changes anything." "FileOS spots your git projects and works with the terminal and editor you already use."
  - Assumption: shown when the current folder is inside a git work tree (a `.git` folder or worktree file above it). The branch comes from HEAD (a short commit id when detached). The change count includes untracked files and comes from `git --no-optional-locks status --porcelain`, so even the index stat cache is never rewritten; without a git binary only the branch shows. A git binary is used only from Homebrew, /usr/local or an installed developer directory, so the "install command line tools" prompt never appears. Refreshed when the folder loads or changes.
- S2 "The folder you're in, in your terminal. From the toolbar, a right-click or the keyboard." "⌥⇧⌘T: Open the folder in Terminal". Terminals: "Terminal, iTerm, Warp and Ghostty".
  - Assumption: right-clicking a folder opens that folder; in a workspace the single selected folder is used.
- S3 "Pick your editor once in Settings, then open any folder in it." "⌥⇧⌘E: Open in your editor". Editors: "VS Code, Cursor, Zed, Xcode, Sublime Text, Nova, BBEdit and JetBrains IDEs, whichever you have installed."
  - Assumption: a Settings window (⌘,) picks the terminal and the editor among the installed ones; until picked, the first installed in the listed order is used. Toolbar buttons and the right-click menu as in S2.
- S4 "No more `cd` into a project just to type `code .`." "Type it in the path bar: `code .`, `cursor .`, `xed .`, `zed`, `warp`, `terminal`"
  - Assumption: in the ⌘L field, these words (optionally followed by "." or a path) open the current folder, or that path, in VS Code, Cursor, Xcode, Zed, Warp, and the Settings terminal. A typed path to an existing folder still wins. A missing app gets an alert naming it.

## Tasks

- [x] T1 S1 — GitStatus reader (repo root, HEAD, porcelain count, safe git lookup), pane state, path bar display — inline — ad54e30 (RED→GREEN, 196/196)
- [x] T2 S2,S3 — developer app catalog, installed detection, preferences, open actions, ⌥⇧⌘T/⌥⇧⌘E, toolbar, right-click, Settings scene — inline — c785b04 (RED→GREEN, 205/205)
- [x] T3 S4 — path bar commands — inline — 3fde66e (RED→GREEN, 210/210; app launches)
- [ ] T4 S1 — git status must never run commands from the repository's config (core.fsmonitor, filter drivers, submodules) — inline — d5a760e (behavioral RED observed → GREEN, 212/212); Risk: item 2; independent verifier + native review pending

Route evidence: T3 depends on T2; T1 touches PathBar like T3; no Writer trigger.

## Log

- L1 (2026-11-04) User: "Developer feature" (picked developer features as the next slice). Developer caches belong to Smart Clean and are out of scope.
- L2 T1-T3: GitStatusReader (repository root incl. worktree .git files, HEAD from disk, `--no-optional-locks` porcelain count, git only from Homebrew/usr-local/CLT/Xcode so the install prompt never appears), pane gitStatus refreshed on reload and on deep changes; DeveloperTools catalog + Settings (⌘,) + ⌥⇧⌘T/⌥⇧⌘E + toolbar + right-click; PathBarCommand + BrowserModel.submitPath (an existing folder wins over a command).
- L3 Native assess (base 5f0fcb7, committed-only) after T3: medium, under_budget.
- L4 Found while writing the Risk line: `git status` runs commands from untrusted repo config (core.fsmonitor hook; clean filters on stat-dirty files). Behavioral RED reproduced (marker created by the reader). T4 fix: `-c core.fsmonitor=false`, every configured filter driver's clean/process emptied and required=false (driver names read via `git config --name-only --get-regexp`), `--ignore-submodules=all`. Test also proves plain git status still runs the trap.
- L5 (2026-11-04) User: "it all works" — manual checks passed (git badge, ⌥⇧⌘T/⌥⇧⌘E, Settings, path bar commands). T4 verifier still running.
