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
- [x] T4 S1 — git status must never run commands from the repository's config (core.fsmonitor, filter drivers, submodules, lazy fetch) — inline — d5a760e + correction 33a8afb (behavioral RED → GREEN, 216/216); Risk: item 2; verifier recheck B1–B4 FIXED; native review approved + acknowledged (review-41b976e8b59edc82)

- [x] T5 S1 — refuse status on git older than 2.44 (ignores GIT_NO_LAZY_FETCH) — inline — 4b94959 (behavioral RED → GREEN, 222/222); Risk: item 2; verifier PASS; native review approved + acknowledged (review-b7b9b8d53b7740ca)

Route evidence: T3 depends on T2; T1 touches PathBar like T3; no Writer trigger.

## Log

- L1 (2026-11-04) User: "Developer feature" (picked developer features as the next slice). Developer caches belong to Smart Clean and are out of scope.
- L2 T1-T3: GitStatusReader (repository root incl. worktree .git files, HEAD from disk, `--no-optional-locks` porcelain count, git only from Homebrew/usr-local/CLT/Xcode so the install prompt never appears), pane gitStatus refreshed on reload and on deep changes; DeveloperTools catalog + Settings (⌘,) + ⌥⇧⌘T/⌥⇧⌘E + toolbar + right-click; PathBarCommand + BrowserModel.submitPath (an existing folder wins over a command).
- L3 Native assess (base 5f0fcb7, committed-only) after T3: medium, under_budget.
- L4 Found while writing the Risk line: `git status` runs commands from untrusted repo config (core.fsmonitor hook; clean filters on stat-dirty files). Behavioral RED reproduced (marker created by the reader). T4 fix: `-c core.fsmonitor=false`, every configured filter driver's clean/process emptied and required=false (driver names read via `git config --name-only --get-regexp`), `--ignore-submodules=all`. Test also proves plain git status still runs the trap.
- L5 (2026-11-04) User: "it all works" — manual checks passed (git badge, ⌥⇧⌘T/⌥⇧⌘E, Settings, path bar commands). T4 verifier still running.
- L6 Independent verifier on d5a760e: S1 FAIL. Blockers: B1 `filter.clean` (driverless section) crashed the parser (range trap, T4-caused); B2 driver names with "=" can't be overridden by `-c` → filter ran; B3 empty driver name skipped → filter ran; B4 partial-clone lazy fetch ran remote.<n>.uploadpack / core.sshCommand and contacted the network (baseline too). Advisories: A1 FIFO include waited 2×5 s; A2 emptied filters (incl. user's global LFS) may over-count stat-dirty LFS files; A3 inherited GIT_* env reached git; A4 core.worktree / foreign gitdir scans another tree (no execution, capped by timeout). Held: include.path, config.worktree, dotted/uppercase names, hooks + index settings, FIFOs in the work tree.
- L7 Correction 33a8afb (one batch): verbatim driver parsing (no crash), overrides via GIT_CONFIG_COUNT/KEY_n/VALUE_n, GIT_NO_LAZY_FETCH=1, inherited GIT_* dropped (A3), fail closed when the filter listing fails, one shared 5 s deadline (A1). Regression tests for B1–B4, each proving the trap fires with plain git. 216/216. A2 and A4 accepted as advisories (counts only; nothing runs). Recheck limited to B1–B4 requested.
- L8 Verifier recheck (limited to B1–B4): all FIXED; A1 worst case now 5.4 s, fails closed. Scratch removed.
- L9 Native review (base 3fde66e, committed-only, escalated item 2; lenses risk/resilience/reliability; consent granted): approved, acknowledged, authority burned. Non-blocking advisories (follow-ups, not done): R1/R3/R4 GIT_NO_LAZY_FETCH is ignored by git < 2.44 (older Apple CLT/Xcode 2.39 line) — fix by refusing status on old git or failing closed when a promisor remote/partialClone is configured (installed gits here are 2.54/2.56); R3/R4 blanking every filter (incl. the user's global LFS) can over-count stat-dirty LFS files.
- L10 (2026-11-04) User: "yes, fix the older git hole" → T5: run `git --version` first (reads no repo config), cache per resolved binary, skip status (changes nil, branch still shown) below 2.44.
- L11 T5 verifier: S1/T5 PASS, no blockers (gate is the only path to config/status; stderr-only, non-zero exit, hanging --version all fail closed; 32 concurrent refreshes fine). Native review (base eb870d4, escalated item 2, lenses risk/resilience/reliability, consent granted): approved, acknowledged. Follow-ups (advisories, not done): the version cache is keyed by the resolved path only, so an in-place downgrade of the same binary while the app runs keeps a cached "recent" (needs local admin + a partial clone missing an object) — key by inode/mtime/size; `2.44.0.rc0` counts as 2.44; tests don't cover stderr-only output / an uncached failed --version; a persistent --version failure re-spawns per refresh (bounded by the deadline). Scratch removed.
