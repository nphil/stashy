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
- CI: `.github/workflows/ios-build.yml` (macos-15), every push to `main`. **`.md`-only AND
  `stash-plugin/**`-only pushes do NOT trigger a build** (`paths-ignore`) — those commits are free.
- **The Build step fails FAST on compile errors**: it greps the raw xcodebuild output for
  `file:line:col: error:`, prints them + GitHub annotations, then `exit 1`. A red Build step with
  annotated errors = compile failure. On failure NO release publishes, so the installed IPA keeps
  working (broken push = low blast radius). Recurring failure class = **Swift 6 strict-concurrency** —
  self-review every diff before pushing (§2).
- **A red run ≠ a compile error — check WHICH step died.** "Resolve Swift packages" times out fetching
  the six FFmpeg xcframework zips (retries 3× since v1.0.367); that's infra, re-run, don't "fix" code
  that never reached the compiler. §1.
- On success CI pushes a version-bump `[skip ci]` commit + a tagged Release with the IPA, so
  `origin/main` moves without you: **always `git fetch origin main && git rebase origin/main` before
  `git push`.**
- **After every push, verify a NEW release with a CHANGED IPA byte size** (`get_latest_release`).
- XcodeGen-generated from `ios/project.yml` (globs `Stashy/` — new `.swift` auto-included; never touch
  a `.pbxproj`). iOS 26, Swift 6, `SWIFT_STRICT_CONCURRENCY: complete`.
- **Never hand-edit versions or `apps.json`** — CI owns them.
- You cannot run the app. Reason hard about compile correctness (especially concurrency) before
  pushing; the owner tests each build on device.

## Standing rules (owner — do not violate)
- Commit/push **direct to `main`** (CI releases from main; ignore feature-branch boilerplate).
- Every commit ends with two trailers: `Co-Authored-By: <current Claude marketing name>
  <noreply@anthropic.com>`, plus `Claude-Session: <session URL>` when known. Committer email must be
  `noreply@anthropic.com` (a stop hook enforces it; `git commit --amend --no-edit --reset-author`).
- **NEVER put a raw API model identifier** (the lowercase-hyphenated ID) in any artifact — commits,
  code, comments, docs. Chat replies only. The marketing name in the trailer is the one exception.
- GitHub scope = `nphil/stashy` only. No PRs unless asked. Don't `sleep` on CI — poll
  `get_workflow_run` / use scheduled wakeups.
- **Small single-purpose commits** — the one big multi-feature blob shipped the -3000 regression.
- **Telemetry (`Services/RemoteLog.swift` → ntfy) is a KEPT feature — do NOT remove** (owner decision
  2026-07-16). Opt-in: off by default, server URL + topic configurable in Settings → Diagnostics.
- **The foreground download path and basic playback are load-bearing** — the owner daily-drives this
  app. Don't refactor them casually.
- **NEVER delete a scene from Stash while keeping its disk file.** The delete dialog offers only
  "Delete Download from Phone" (local copy, scene stays) and "Delete from Stash & Disk" (v1.0.300).
- The owner is exacting about UI feel: native animation physics/inertia, glass that still looks
  native, Apple-Photos gesture parity, precise sizing. Ship polished, expect iteration.
- **No scrollbars anywhere** (indicators globally off in `StashyApp.init()` + `.scrollIndicators(.hidden)`
  in `ContentView`). Add `.scrollIndicators(.hidden)` on any new `ScrollView`/`List`.

## Landmines (one-liners — full stories in ENGINEERING_NOTES)
- **The -3000 download saga is CLOSED — do NOT reinvestigate, and NEVER bump the background-session
  suffix again (v1.0.332).** iOS's background hand-over is simply unavailable to this app on this
  device; everything runs in-process. Evidence + decision table §3.
- **Download durability invariants (every one was a shipped bug):** a byte on disk is never dropped by
  a recoverable error; parts live in **Application Support**, NEVER `Caches`; progress derives ONLY from
  part-file size; a resume blob is banked from the FAILED task's `userInfo` and never wiped; a cold
  relaunch restores items `.paused` (every continue-branch must adopt them); the space preflight sizes
  on `totalBytes − partSize`. §3.
- **Background runtime is SOLVED** (`DownloadKeepAlive`, v1.0.339; device-proven 290 s / 725 MB): a
  `beginBackgroundTask` window is ~26 s and can't be extended but CAN be replaced forever *if* the app
  holds an active `AVAudioSession` + `audio` background mode — end the assertion BEFORE re-taking (the
  window is per-**app**). Anything else holding a `beginBackgroundTask` pins it and you die at 26 s.
  Portable recipe §3.
- **These grant no unattended runtime:** `BGProcessingTask` (idle-only catch-up, never seen firing),
  `BGContinuedProcessingTask` (never fired here — REMOVED v1.0.340), Live Activities (display only). Push
  registration is `didFinishLaunchingWithOptions` ONCE — a second call KILLS the app. §3.
- **Free space: `volumeAvailableCapacity`, NEVER `…ForImportantUsage`** (the latter counts purgeable
  caches — read 40 GB on a 4.1 GB-free phone). §3.
- **Multi-threaded downloading is GONE (v1.0.313) — do not reintroduce:** one connection sustains
  ~85–100 MB/s on the LAN; parallelism only pays on high-RTT/lossy links. §3.
- **`Double.isFinite` does NOT guard `Int(_:)` — `greatestFiniteMagnitude` IS finite** (only `.infinity`
  /`.nan` fail). `backgroundTimeRemaining` returns it; clamp by MAGNITUDE before any Double→Int or you
  trap (crashed on background, v1.0.332→333). §2.
- **Poll loops behind visible UI must NEVER self-terminate** (broke v1.0.296 jobs panel, again v1.0.345
  slow-mo): abandon only on loss of INTENT, and gate the poll on the FULL set of conditions the action
  itself checks. Stash's `jobQueue` returns `null` (not `[]`) for an empty queue — decode optionally. §6.
- **Fetch URL→server (plugin ≥0.5.0):** DRM streams (SAMPLE-AES/FairPlay/Widevine) CANNOT be downloaded
  — not a bug, don't build a bypass; clear HLS/MP4 works. Resolver replays Origin + a cookie jar
  (`--cookies`). Submit sheet = one field + one button whose verb comes from `LinkProbe` (HEADERS decide
  file vs page, never the extension; never reads a body) — no instruction text, keep it that way. Plugin
  zip + `index.yml` sha256 MUST be rebuilt together; `stash-plugin/**` pushes don't trigger CI. §8.
- **Verify Apple API signatures BEFORE pushing** (CI is the only compiler, ~6–8 min/guess): fetch the
  exact decl from `developer.apple.com/tutorials/data/documentation/<framework>/<symbol>.json`. Failable
  vs non-failable inits differ across sibling APIs. §1.
- **SwiftUI View arg order:** adding a property (esp. a `@Binding`) means call-site labelled args must
  match declaration order — Swift won't reorder, and the error is cryptic. §6.
- **Glass reads flat over flat `Material`/another glass** — it only shows character over vibrant/varied
  content. The floating filter panel is glass; its chips are solid `filterPill`s. §6.
- **`VTFrameProcessor` (AI slow-mo):** `-19730 "not initialized"` really means UNSUPPORTED INPUT — feed
  420v biplanar YUV (not BGRA) and respect the device max dimension. `probeMaxSizeIfNeeded()` measures it
  once/device+OS (1280×720 on iPhone 17 Pro/iOS 26); don't simplify it to a constant. `SlowMoInterpolator`.
- **iOS 26 zoom-transition source-card freeze** (Apple FB21961572): workaround `.zoomReturnScrollGate(depth:)`
  (600 ms `scrollDisabled` after a pop); geometry/config fixes don't work — remove when iOS 27 fixes it. §6.
- **`onGeometryChange` on a per-frame value is a scroll-perf trap** (tracking `.frame(in:.global)` →
  `@State` re-renders every cell at 120 Hz); store it in a reference box if you only need it later. §6.
- **Popovers:** host from a stable ZStack sibling (`FilterPopoverAnchor`), never a conditional/churning
  view. Bit us three times. §6.
- Most CI failures were **Swift 6 strict-concurrency** — read the patterns before writing async code. §2.
- **Scene names render through `StashScene.displayTitle`** (title → file basename → "Untitled"), never
  `scene.title ?? "Untitled"`; file-name fallbacks truncate in the MIDDLE (the tail holds the extension). §6.
- `AppDelegate` lives in `Services/OrientationLock.swift`. Ratings are `rating100` 0–100 (UI stars =
  value/20); favorites are booleans. Adding a `DownloadState` case = update the exhaustive switches in
  `DownloadsView`. FFmpeg = SPM package `nphil/stashy-videoengine` (LGPL-minimal, **no AV1 encode**;
  rebuild the package to change capability). §7.

## Docs map — what to read when
- **`docs/ENGINEERING_NOTES.md`** — deep reference: §1 CI, §2 Swift 6 concurrency, §3 downloads +
  background mechanics, §4 transcode, §5 playback, §6 UI/library patterns, §7 misc gotchas, §8 release
  history + **fetch-URL pipeline** + shipped-feature log, §9 XR glasses. Read before touching a subsystem.
- **`docs/ROADMAP.md`** — master roadmap + owner wishlist.
- **`docs/OUTSTANDING_2026-07-01.md`** — prioritized punch list (snapshot @ v1.0.101; see its header note).
- **`docs/DOWNLOADS_PLAN_2026-07-01.md`** — original downloads design (two claims corrected since).
- **`docs/OPTIMIZATION_PLAN_2026-06-30.md`** — completed perf pass; §5 = reference-only telemetry-removal
  checklist (RemoteLog is KEPT); playback learnings.
- **`docs/PERF_STABILITY_REVIEW_2026-07-01.md`** — 31 perf/stability findings with status (#25 reverted —
  do not re-apply). Check before re-analyzing perf.

## Current state (keep short — current release + work queue only)
- **Latest release: v1.0.365** (plugin **0.5.3**). CI green. The -3000 investigation is closed.
- **Downloads** work end-to-end: app-open ~100 MB/s, byte-exact resume through crashes / relaunch /
  suspension; **background runtime is solved** (`DownloadKeepAlive`, on by default). One-at-a-time queue
  with Start All / Pause Queue. Queue invariants in §3 — read before touching the queue manager.
- **Fetch URL → server SHIPPED** (v1.0.359–365 + plugin 0.5.0–0.5.3): paste or resolve a link → the
  server (yt-dlp) downloads into the library + scans it; live "On Server" cards (speed/size/ETA,
  pause/resume/cancel/queue). In-app immersive WKWebView resolver captures button-gated + streaming links
  (Origin + cookie-jar replay); **DRM streams are out of scope** (§8 fetch entry).
- **XR glasses (Viture Pro) SHIPPED** (v1.0.348–357): glasses-first browse + playback, transient OSD
  pills, hardware-volume-only. §9 is the deep reference. Joystick / two-finger-mute / hold-2× were
  removed — don't re-add.
- **Metadata scrape/edit** refreshes the detail + lists in place (no pagination reset).
- **Next candidates (see ROADMAP):** Netflix fullscreen player UI (biggest ★ player item); concurrent-
  queue server transcode (needs a Stash-scheduling spike); WYSIWYG layout editor / mini-player-PiP /
  AI zoom-follow / filmstrip timeline. Resumable transcode, Blur Media (Privacy Mode) and RemoteLog
  telemetry are DONE/kept — don't re-plan them.
