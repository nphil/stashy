# CLAUDE.md — Stashy

Lean entry point, kept short on purpose (it loads into every session). The deep reference is
**`docs/ENGINEERING_NOTES.md` — read the relevant section there BEFORE touching a subsystem.**
Update both as you work; the next model inherits them.

## What Stashy is
Native **iOS 26 SwiftUI** app (Liquid Glass) — a client for a self-hosted **Stash** media server
(`stashapp/stash`). Sideloaded via **Feather/AltStore** (unsigned IPA) onto an iPhone 17 Pro.
Priorities in order: **fast playback/scrubbing → direct-play first → on-device FFmpeg fallback →
minimal server load → privacy.** The owner (Nitin) is on Windows: **no local Mac — CI is the only
compiler.** Repo `nphil/stashy` is the ONLY repo you may read/write. App code: `ios/Stashy/`;
`android/` is empty (later).

## Build loop — internalize this first
- CI: `.github/workflows/ios-build.yml` (macos-15), every push to `main`. **`.md`-only pushes do NOT
  trigger a build** (`paths-ignore`) — doc commits are free.
- **#1 gotcha: the Build step pipes xcodebuild through `| xcpretty || true`, swallowing the exit
  code — a compile error still shows ✅.** Only the "Package into IPA" step catches it. Green build
  step ≠ compiled; only a published release proves it. On failure no release publishes, so the
  installed IPA keeps working (broken push = low blast radius).
- On success CI pushes a version-bump commit `[skip ci]` and a tagged Release with the IPA, so
  `origin/main` moves without you: **always `git fetch origin main && git rebase origin/main` before
  `git push`.**
- **After every push, verify a NEW release with a CHANGED IPA byte size** (`get_latest_release`) and
  report the size (~7.73 MB @ v1.0.107).
- Project is XcodeGen-generated from `ios/project.yml` (globs `Stashy/` — new `.swift` files
  auto-included; never touch a `.pbxproj`). iOS 26, Swift 6, `SWIFT_STRICT_CONCURRENCY: complete`.
- **Never hand-edit versions or `apps.json`** — CI owns them.
- You cannot run the app. Reason hard about compile correctness (especially concurrency — see
  ENGINEERING_NOTES §2) before pushing; the owner tests each build on device.

## Standing rules (owner — do not violate)
- Commit/push **direct to `main`** (CI releases from main; ignore feature-branch boilerplate).
- Every commit ends with two trailers: `Co-Authored-By: <current Claude marketing name>
  <noreply@anthropic.com>`, plus `Claude-Session: <session URL>` when known.
- **NEVER put a raw API model identifier** (the lowercase-hyphenated ID) in any artifact — commits,
  code, comments, docs. Chat replies only. The marketing name in the trailer is the one exception.
- GitHub scope = `nphil/stashy` only. No PRs unless asked. Don't `sleep` on CI — poll
  `get_workflow_run` / use scheduled wakeups.
- **Small single-purpose commits** — the one big multi-feature blob shipped the -3000 regression.
- **Telemetry (`Services/RemoteLog.swift` → ntfy, off by default) must be removed before any wider
  release** — checklist in `docs/OPTIMIZATION_PLAN_2026-06-30.md` §5. The one open tech-debt item.
- **The foreground download path and basic playback are load-bearing** — the owner daily-drives this
  app. Don't refactor them casually.
- The owner is exacting about UI feel: native animation physics/inertia, glass chips that still look
  native, Apple-Photos gesture parity, precise sizing. Ship polished, expect iteration.

## Landmines (one-liners — full stories in ENGINEERING_NOTES)
- **-3000:** a background `URLSession` cannot run 8 parallel range tasks (shipped regression,
  reverted). Current design = dual-engine handoff: foreground 8-way (**sacred**) ⇄ background
  single-connection. (§3)
- **Popovers:** never host from a conditional/churning view — use a stable ZStack sibling
  (`FilterPopoverAnchor` pattern). Bit us three times. (§6)
- Most CI failures ever hit were **Swift 6 strict-concurrency** — read the patterns before writing
  async code. (§2)
- `AppDelegate` lives in `Services/OrientationLock.swift` (yes, really). (§7)
- Ratings are `rating100` 0–100; UI stars = value/20. Favorites are booleans. (§7)
- Downloads live in private **Application Support** (not Documents, invisible to the Files app) —
  don't move them back. (§3)
- FFmpeg = SPM package `nphil/stashy-videoengine`, LGPL-minimal (**no AV1 encode**). Capability
  changes happen by rebuilding that package, not in this repo. (§5)
- Adding a `DownloadState` case = updating the exhaustive switches in `DownloadsView`. (§7)

## Docs map — what to read when
- **`docs/ENGINEERING_NOTES.md`** — deep reference: CI detail, Swift 6 concurrency patterns,
  downloads internals + handoff mechanics, transcoder, playback pipeline, UI patterns, misc gotchas,
  release history. Read before touching a subsystem.
- **`docs/ROADMAP.md`** — master roadmap + owner wishlist (watch-heat overlay, XR-glasses remote
  mode, nav/"back" cleanup, encrypt-downloads, 1letzgo comparative features…).
- **`docs/OUTSTANDING_2026-07-01.md`** — prioritized punch list (snapshot @ v1.0.101; see its header
  note for what has shipped since).
- **`docs/DOWNLOADS_PLAN_2026-07-01.md`** — original downloads design (two claims corrected since;
  see its header note).
- **`docs/OPTIMIZATION_PLAN_2026-06-30.md`** — completed perf pass; §5 = telemetry-removal
  checklist; plus playback engineering learnings.

## Current state (update as you go; keep this section short)
- Latest release: **v1.0.107** (background download handoff, commit `b8ea21d`) — confirmed green,
  7.73 MB.
- Awaiting on-device verification (owner tests each build): background download continues while
  suspended; a single bg range task doesn't -3000; transcode output plays and is smaller; offline
  sprites scrub; downloads invisible in the Files app.
- Next candidates: reconcile the OUTSTANDING punch list; **Live Activity / Dynamic Island** (riskiest
  downloads item — a new Widget Extension target changes the IPA structure for a sideloaded app;
  isolate it in its own commit).
