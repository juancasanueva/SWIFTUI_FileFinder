# Updates and Homebrew

Objective: Check for Updates through Sparkle, a notarized tag-driven release pipeline with an appcast feed, and a Homebrew cask, as in youtubedownload. Branch `feat/updates-and-brew`; delivery `ask-on-risk`; tests: `xcodebuild test -scheme FileFinder -destination 'platform=macOS' -only-testing:FileFinderTests`.

## Specs

- **S1** "I want to implement the Check for updates and brew like we did here /Users/juancasanueva/programming/swiftUI/youtubedownload". The reference is that repo's feature (odd/tasks/updates-and-brew.md, RELEASING.md, `.github/workflows/release.yml`, `scripts/`, `Updates/`).
- **S2** Project format: the project moves from `FileFinder.xcodeproj/project.xcproj` to a classic `project.pbxproj` (the reference's reason: the xcproj format reads package references without linking them). Every target's build settings stay as they were (checked with `-showBuildSettings` before and after).
- **S3** Check for Updates, as in the reference: Sparkle 2.9.6 by SPM behind an `AppUpdating` protocol, one Sparkle adapter, "Check for Updates…" in the app menu and in Settings, an automatic-checks toggle (off by default) and "Last checked" text; tests never start Sparkle. Info.plist: `SUFeedURL` `https://juancasanueva.github.io/SWIFTUI_FileFinder/appcast.xml`, `SUScheduledCheckInterval` 86400, the shared `SUPublicEDKey`.
- **S4** Release pipeline, as in the reference: a `v*` tag builds, signs, notarizes and publishes `FileFinder-<version>.zip` to GitHub Releases and the appcast to GitHub Pages, with the same seven secrets. Assumption: it runs on the `xcode-27` runner with Xcode 27.2, since the app targets macOS 27.2 and the reference's Xcode 26.6 can't build it.
- **S5** Homebrew: a `filefinder` cask in `juancasanueva/homebrew-tap` (token checked free on formulae.brew.sh), with its bump and CI entries; README install and RELEASING.md documented.

## Tasks

- [x] T1 S2 project format move — inline; settings identical for 3 targets × 2 configs; 367/367 tests
- [x] T2 S3 Check for Updates — inline; RED (no AppUpdating) then 383/383 tests; Sparkle 2.9.6 linked, keys in the built Info.plist
- [x] T3 S4 release pipeline, RELEASING.md, pipeline tests — inline; 30 pipeline tests pass; local archive/export/package/smoke pass
- [ ] T4 S5 cask in the tap repo (separate repo; needs the user's go-ahead to push) — inline
- [ ] T5 S4 one-time setup (secrets, Pages) and an rc rehearsal — needs the user

Forecast: ~1,500 authored lines (project file ~600 generated-like, pipeline ~600, Swift ~300). Risk: items 5 (CI, release, dependency) and 2 (signing secrets): independent verifier after T3.

## Log

- **L1** (2026-11-05) "I want to implement the Check for updates and brew like we did here /Users/juancasanueva/programming/swiftUI/youtubedownload"
- **L2** Mapped the reference with one explorer. Repo is public; `filefinder`, `file-finder` and `file_finder` casks are free (404). GitHub's `xcode-27` image has Xcode 27.2 (public preview), so the 27.2 deployment target stays.
- **L3** T1: generated `project.pbxproj` from the old file's settings (same target and product IDs). `-showBuildSettings` for all three targets in Debug and Release is identical to before; 367 tests pass.
- **L4** T2: ported `Updates/` (AppUpdating, AutomaticUpdateChecks, SparkleUpdateChecker, UpdateCheckPresentation, UpdatePolicy, UpdatesSection) and the tests; added `AppUpdater.shared` (nil in the test host), "Check for Updates…" after About in the app menu, and the Updates section in Settings ▸ General. Project regenerated with Sparkle and the partial `FileFinder/Resources/FileFinder-Info.plist` (excluded from resources). Not checked by eye yet: the menu item and Settings section in the running app.
- **L5** T3: ported `release.yml`, `scripts/release.sh`, `scripts/appcast.sh`, `scripts/ExportOptions.plist`, RELEASING.md and the pipeline tests with FileFinder's names; `runs-on: xcode-27`, Xcode 27.2 pin, `MINIMUM_SYSTEM_VERSION` 27.2; dropped the reference's menu-bar (LSUIElement) test and the CFBundleDisplayName gate (FileFinder sets none). `.github/actionlint.yaml` names the preview label. Evidence: `bash -n`, shellcheck and actionlint clean; full suite 413 with only the known TransferQueue cancel flake failing; local `release.sh archive/export/package` with VERSION 0.0.1, BUILD_NUMBER 7 gave a Developer ID (Z3S5JK8E38), hardened-runtime, arm64 app that passes `codesign --verify --deep --strict` and a 6 s smoke. Not run: notarize, staple, verify (need the App Store Connect key; CI only).
- **L7** Independent verifier: S2, S3, S4 PASS, no blockers, 486/486 tests. Advisories: the runner's `Xcode_27.2.app` is the 27.2 RC (27B48) while local is 27B52 (now said in `release.yml`); the deployment-target test reads every `MACOSX_DEPLOYMENT_TARGET`, not only the app's; RELEASING.md's cask step reads as done before T4; the menu and Settings section are still unchecked by eye.
- **L6** T4 plan: the cask needs a published release's version and sha256, so it follows T5's first stable release. Template `Casks/yt_downloader.rb` from the tap: `depends_on macos: :golden_gate` (Homebrew's name for 27), `app "FileFinder.app"`, zap the bundle-id paths plus `~/.config/filefinder`; a `filefinder` entry in `bump.yml` (`repo: SWIFTUI_FileFinder`, `asset: FileFinder`) and `ci.yml`. The local tap clone is 14 behind origin; work from a fresh worktree of origin/main.
- **L8** Native review `review-af4d0750664db9f0` (risk, resilience, reliability) over be067ea..2d1975e: approved and acknowledged. Seven non-blocking notes, all in code ported unchanged from the reference: the Sparkle adapter is untested (`SparkleUpdateChecker.swift:33-44`); a version note in `RELEASING.md:73-74`; the last-check KVO (`SparkleUpdateChecker.swift:58-63`); the Pages gate's `curl` lacks `-f` and a time bound (`release.yml:79-83`); a third queued tag cancels the pending run (`release.yml:21-23`); a stale CDN feed could be merged (`release.yml:196-201`). Left as follow-ups. Next: T5 needs the user (secrets, Pages, rc tag).
