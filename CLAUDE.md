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
- **Build step now fails FAST on compile errors** (since v1.0.233-era): it tees raw xcodebuild output
  and, after the tolerated framework-validation exit, greps for `file:line:col: error:` diagnostics —
  printing them up front + emitting GitHub inline annotations, then `exit 1` at the **Build** step. So
  a red Build step with annotated errors = compile failure (no more digging logs / waiting for Package).
  The old `| xcpretty || true` swallow-the-exit-code trap is gone for compile errors. Still true: a
  green *run* only fully proves out once a release publishes; on failure no release publishes, so the
  installed IPA keeps working (broken push = low blast radius). Recurring failure class = Swift 6
  strict-concurrency (deinit touching non-Sendable, sending non-Sendable into @Sendable/assumeIsolated
  closures, @ViewBuilder on multi-branch bodies) — self-review every diff for these before pushing.
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
- **Telemetry (`Services/RemoteLog.swift` → ntfy) is a KEPT feature — do NOT remove** (owner decision
  2026-07-16, reversing the old remove-before-wider-release rule). It stays opt-in: off by default,
  server URL + topic configurable/self-hostable in Settings → Diagnostics. The deletion checklist in
  `docs/OPTIMIZATION_PLAN_2026-06-30.md` §5 is retained as reference only.
- **The foreground download path and basic playback are load-bearing** — the owner daily-drives this
  app. Don't refactor them casually.
- **NEVER delete a scene from Stash while keeping its disk file.** The delete dialog offers only
  "Delete Download from Phone" (local copy, scene stays) and "Delete from Stash & Disk" — do not
  re-add a keep-the-file option (v1.0.300).
- The owner is exacting about UI feel: native animation physics/inertia, glass chips that still look
  native, Apple-Photos gesture parity, precise sizing. Ship polished, expect iteration.
- **No scrollbars anywhere** (owner standing preference): indicators are globally off
  (`UIScrollView.appearance()...showsVertical/HorizontalScrollIndicator = false` in `StashyApp.init()`
  + `.scrollIndicators(.hidden)` in `ContentView`, which propagates via environment). Never reintroduce
  a visible indicator; add `.scrollIndicators(.hidden)` as reinforcement on any new `ScrollView`/`List`.

## Landmines (one-liners — full stories in ENGINEERING_NOTES)
- **The -3000 download saga is CLOSED — do NOT reinvestigate it.** The system's background hand-over is
  simply unavailable to this app on this device. A probe run in the same millisecond as the refusal
  showed the daemon's delivery directory PRESENT inside our container and writable by our own process,
  on an intact bundle id, with 4.9 GB free — failing on a 64 MB slice exactly as on a 1.6 GB file. Not
  space, size, Range, path, permissions, identity, or our code (audited: nothing here can emit -3000). A
  brand-new session identifier changed nothing (v1.0.332) — **never bump the suffix again**. One -3000
  with nothing durable condemns the transport (~1.5 s, ~52 MB) and everything runs in-process after;
  the verdict is OS-version-stamped so an iOS update re-tests for free. Evidence + decision table in §3.
- **Download durability invariants — every one of these was a shipped bug.** A byte that reached disk is
  never thrown away by a recoverable error. Parts live in Application Support, NEVER `Caches` (iOS reaps
  those while the app is closed). Progress derives ONLY from part-file size, never from bytes a daemon
  still holds — that was the island counting 15→12→8. A resume blob is banked from the FAILED task's
  `userInfo` (`cancel(byProducingResumeData:)` does nothing for an ended task), never wiped by a reset
  path; a discarded one strands its partial file forever in "System Data" (`releaseResumeBlob`). A cold
  background relaunch restores items `.paused`, so every continue-branch must adopt them. The space
  preflight sizes on `totalBytes − partSize` — charging for bytes already on disk refused a download
  that fitted. (§3)
- **A `beginBackgroundTask` window is ~26 s and cannot be EXTENDED — but it can be REPLACED, forever.**
  This corrects the "no API lifts it" verdict this file carried for one day. Measured twice at 25.57 s
  and 26.32 s, and that stands. What was wrong is the conclusion: an app declaring the **`audio`**
  background mode and holding an **active `AVAudioSession`** can end its assertion and be granted a
  fresh one indefinitely. Ending BEFORE re-taking is the whole trick — iOS's window is per-**app**, not
  per-assertion, so the clock only resets when nothing is outstanding (which is why anything else
  holding one must stand down). Shipped v1.0.339 as `Services/DownloadKeepAlive.swift`.
  **DEVICE-PROVEN 2026-07-26 on the first run: 290 s unbroken, 725 MB transferred while backgrounded,
  29/29 ticks, zero refusals** — no evidence of any remaining limit. `UIBackgroundModes` is a plist
  declaration policed at App Store review, not a signed capability, which is exactly why it isn't
  gated like the two below. **A portable step-by-step recipe for other apps is in ENGINEERING_NOTES
  §3 ("PORTABLE RECIPE").** The failure mode that makes it look broken: anything else in the app
  holding a `beginBackgroundTask` pins the window open and you still die at 26 s.
- **The two mechanisms that genuinely decline here.** `BGProcessingTask` (shipped) runs ONLY while the
  device is idle and iOS kills it the moment the user picks the phone up — a catch-up path, never an
  unattended-now one; "needs wifi + charging" is folklore (both are opt-in predicates). Honest caveat:
  `dl-bg-sched` has **never actually been observed firing**, so "converges it overnight" is the design,
  not a measurement. `BGContinuedProcessingTask` submitted `ok=1` four times and **never fired** here —
  suspect the iPhone 17 Pro reports and/or a sideloaded app having no entitlements; **REMOVED in
  v1.0.340** now the keep-alive delivers more, recoverable from git history, do not rewrite it. Both are
  OS-service handshakes that can refuse an app they cannot vouch for, like -3000. **Live Activities grant ZERO
  runtime** — display only, and iTorrent's `pushType: .none` card proves the point: their Dynamic Island
  stays live because their PROCESS does. Registration is `didFinishLaunchingWithOptions` ONLY and
  exactly once (a second one KILLS the app); both plist keys are runtime-only requirements CI cannot
  check, so `dl-bg-register ok=` is the proof. (§3)
- **Test free space with `volumeAvailableCapacity`, NEVER `…ForImportantUsage`** — the latter counts
  purgeable caches and read **40 GB** on a phone with **4.1 GB** genuinely free. (§3)
- **Download diagnostics:** Settings → Diagnostics → **Trace downloads** (off by default) emits the
  `dl-*` family — `dl-parts` (per-part size census) is the line that makes progress loss obvious.
  RemoteLog buffers pre-`enable()` lines and replays them, so launch-time events survive. (§3)
- **Multi-threaded downloading is GONE (v1.0.313) — do not reintroduce it.** Benchmarked on the
  owner's own server: one connection sustained ~32 MB/s vs ~14 for 8-way, and the single background
  transfer runs at **85–100 MB/s**. Parallelism only pays where one TCP stream can't fill the pipe
  (high RTT, loss, per-flow shaping); on a LAN it just makes an array seek. The `TransferBenchmark`
  harness that measured this (counterbalanced A B C C B A) was **removed once the verdict was in** —
  recover it from git history if a future link type ever makes the question live again. (§3)
- **`Double.isFinite` does NOT guard `Int(_:)` — `greatestFiniteMagnitude` IS finite.** Only `.infinity`
  and `.nan` fail `isFinite`, so `x.isFinite ? Int(x) : nil` still traps ("outside the representable
  range") on the sentinel value. This crashed the app the instant it was backgrounded with a download
  running (v1.0.332, fixed v1.0.333): `UIApplication.backgroundTimeRemaining` returns
  `.greatestFiniteMagnitude` whenever no real value is available, and the crash happened BEFORE the
  `dl-phase to=background` log, so the trace went silent with no clue — it read exactly like an iOS
  suspension. **Clamp by magnitude, never by `isFinite`, before any Double→Int conversion.** (§2)
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
- **Verify Apple API signatures BEFORE pushing** — CI is the only compiler and each guess costs a
  ~6–8 min cycle. Fetch the exact Swift declaration from the doc-JSON endpoint (`curl
  developer.apple.com/tutorials/data/documentation/<framework>/<symbol>.json`, parse `fragments`).
  This session that caught: MetalFX (`MTLFXSpatialScalerDescriptor`), `AVAssetImageGenerator`, and the
  VT super-res inits. Gotcha class: **failable vs non-failable inits differ across sibling APIs** — VT
  *frame-interpolation* config init is optional (`guard let`), but *super-res scaler* config+params
  inits are **non**-optional, and `maximumDimensions` is `CMVideoDimensions?`. (§1)
- **SwiftUI View arg order:** adding a property (esp. a `@Binding`) to a `View` struct means the call
  site's labelled args must be in the **same order as declaration** — Swift won't reorder them, and the
  error is cryptic. Cost a CI cycle this session (`ScrubBar.speedTier`). Match them. (§6)
- **Glass reads flat over flat `Material` or over another glass surface** — Liquid Glass only shows
  character over vibrant/varied content (the mesh, media). So the floating **filter panel** is glass but
  its **chips are solid `filterPill`s**, not glass (v1.0.262 glassed chips over a material panel →
  invisible; v1.0.264 flipped it: glass panel + solid chips; v1.0.265 active chips fill accent). (§6)
- **`VTFrameProcessor` (AI slow-mo):** `-19730 "Processor is not initialized"` is a **misleading** error —
  it means the input is unsupported, NOT that startSession failed. Two real causes, both bit us: (1) feed
  buffers in the config's own `sourcePixelBufferAttributes` format (**420v biplanar YUV**, NOT BGRA —
  convert via CoreImage); (2) the model has a **device-specific max dimension** that iOS 26 can't query
  (`maximumDimensions` is nil; OS 27 only). The old hardcoded 1280×720 was a third party's M1 Pro figure —
  since v1.0.344 `probeMaxSizeIfNeeded()` MEASURES it once per device+OS (ladder 4K→1440p→1080p→720p, real
  session + synthetic pair per rung). **Measured on the owner's iPhone 17 Pro / iOS 26, 2026-07-27:
  `max=1280×720 trusted=1` — 4K/1440p/1080p all rejected, so the M1 Pro figure was right and the A19 buys
  nothing. The limit is the shipped model, not the silicon.** (Confidence: the three big rungs were refused
  in <20 ms combined vs ~60 ms for 720p, i.e. declined at session creation rather than marginally inside
  `process`, and 720p really did produce a frame — so the synthetic-buffer method is sound.) Keep the probe
  anyway: it is OS-stamped, so a future iOS that raises the limit is picked up for free. **Don't "simplify" it back to a
  constant** — real frames display at native res while synthesised ones are made at the cap and upscaled,
  so every rung below the true ceiling is visible as sharp/soft pulsing on HD sources. A probe that fails
  even at 720p indicts the probe, not the device (`trusted=0`), and must never shrink the shipped default.
  `SlowMoInterpolator`.
- **iOS 26 zoom-transition source-card freeze (Apple bug FB21961572; fine on iOS 18):** scrolling right
  after a `.navigationTransition(.zoom)` zoom-back freezes the SOURCE grid card ~1s (the transition holds
  it out of the scroll layout during its settle). `geometryGroup()` and the
  `matchedTransitionSource(configuration:)` variant do NOT fix it (both verified). Workaround =
  `DesignSystem/ZoomReturnScrollGate.swift` (`.zoomReturnScrollGate(depth:)` = 600 ms `scrollDisabled`
  after a pop). **Remove once iOS 27 / a 26.x point release fixes it** (ROADMAP Tech debt); don't
  re-attempt a geometry/config fix. (§6)
- **`onGeometryChange` on a per-frame value is a scroll-perf TRAP:** tracking `.frame(in: .global)` (which
  changes every scroll frame) and writing it to `@State` re-renders EVERY visible cell at 120 Hz — a
  self-inflicted browse-grid judder we shipped then fixed. If you only need the value later (e.g. a
  long-press source rect), store it in a reference box, NOT `@State` (since v1.0.285 `ScenePreview`
  tracks size-only and derives the origin from the touch point). (§6)
- **Stash's `jobQueue` returns `null`, not `[]`, for an EMPTY queue** (nullable list + Go nil slice) —
  decode it optionally. The non-optional decode broke the jobs panel's scan bar (frozen snapshot, poll
  loop silently self-killed; fixed v1.0.296). General rule: a poll loop behind visible UI must never
  self-terminate — clear stale state, show a reconnecting line, back off, keep trying. (§6)
  **This rule was broken AGAIN in v1.0.345** by `scheduleSlowMoReengage`: after a seek it polled 6 s for
  the player to stabilise, then gave up silently with nothing re-arming it, so AI slow-mo stayed dead
  until the user toggled it by hand — and there was no log line for the give-up, so the trace showed only
  healthy session starts. Two compounding traps worth generalising: (a) abandon on loss of INTENT (toggle
  off, rate raised), never on a transient readiness flag; (b) if the poll's gate is a SUBSET of the
  conditions the action itself checks, the action can silently reject and burn the retry — here
  `canSlowForward` was checked only inside `updateSlowMo`, not in the poll. Gate on the full set.

## Docs map — what to read when
- **`docs/ENGINEERING_NOTES.md`** — deep reference: CI detail, Swift 6 concurrency patterns,
  downloads internals + handoff mechanics, transcoder, playback pipeline, UI patterns, misc gotchas,
  release history, XR glasses (§9: pipe recipe, hosting rules, remote gesture map). Read before
  touching a subsystem.
- **`docs/ROADMAP.md`** — master roadmap + owner wishlist (watch-heat overlay, XR-glasses remote
  mode, nav/"back" cleanup, encrypt-downloads, 1letzgo comparative features…).
- **`docs/OUTSTANDING_2026-07-01.md`** — prioritized punch list (snapshot @ v1.0.101; see its header
  note for what has shipped since).
- **`docs/DOWNLOADS_PLAN_2026-07-01.md`** — original downloads design (two claims corrected since;
  see its header note).
- **`docs/OPTIMIZATION_PLAN_2026-06-30.md`** — completed perf pass; §5 = the (reference-only —
  RemoteLog is kept) telemetry-removal checklist; plus playback engineering learnings.
- **`docs/PERF_STABILITY_REVIEW_2026-07-01.md`** — 31 adversarially-verified perf/stability findings
  with per-item status (most shipped; #25 reverted — do not re-apply; a few deferred lows). Check before
  re-analyzing perf or touching the flagged code paths.

## Current state (update as you go; keep this section short)
- Latest release: **v1.0.352** (`f786b8d`, glasses v2 + review polish). The -3000 investigation is
  closed and must not be reopened.
- **What works:** app open → ~100 MB/s, resumes byte-exact through crashes, relaunches and suspension.
  Backgrounded → keeps going indefinitely (keep-alive, ON by default since v1.0.340). Downloads run
  **one at a time** with Start All / Pause Queue in the Downloads toolbar; a queued card's play button
  force-starts that one alongside the current transfer. The scene ••• row reads *Download Video* /
  *Add to Download Queue* / *Show in Downloads* and only navigates when nothing else is pending. Live
  Activity carries name / bytes / speed / ETA on a continuous bar (title suppressed under Privacy Mode).
- **Queue invariants are in ENGINEERING_NOTES §3 ("The download queue manager") — read before touching
  it.** Five were shipped bugs found in one review pass, including a data-loss one: a `.queued` item
  without a `markActive` marker is DELETED on the next launch, sidecar and all. Fix device-verified
  2026-07-27 (force-quit with a batch queued: all cards back, bytes retained, order preserved).
- **The background problem is SOLVED (2026-07-26).** `DownloadKeepAlive` was device-proven on its first
  run: 290 s unbroken background runtime, 18.9 MB → 744 MB while backgrounded, 29/29 ticks, zero
  refusals, Live Activity live throughout. Long unattended downloads now work. Do not re-open the
  question of whether iOS permits this — it does, and the recipe is in ENGINEERING_NOTES §3.
- **XR glasses (Viture Pro): pipe device-proven (v1.0.348), glasses-first v2+v3 SHIPPED (wall
  geometry/centred 1.5× focus + View More grid v1.0.353–357; owner-feedback pass 2026-08-04). THE
  deep reference is ENGINEERING_NOTES §9** (pipe recipe — static `UISceneConfigurations` entry is
  mandatory, `configurationForConnecting` never consulted; hosting rules; gesture map; 10-foot design
  tokens). Current remote vocabulary (owner-pruned): drag/flick focus + tap play + two-finger tap =
  back (grid) in browse; tap play/pause, double-tap-half ±10 s, H-drag scrub, V-drag speed ladder,
  pinch zoom 1–4× + drag-pan + double-tap reset in playback; **HARDWARE volume buttons are the ONE
  volume control** (glasses model gain pinned 1.0 — a stored 40% model volume multiplying UNDER
  system volume made the buttons feel dead; read-only `outputVolume` KVO pulses the glasses volume
  pill — never write the audio session). **The analog JOYSTICK, two-finger MUTE and hold-2× were
  REMOVED 2026-08-04 (owner: not intuitive)** — recover from git history, do not rewrite, do not
  re-add. Remote draws a CALayer glow trail under the finger (raw touches; recognizers run
  `cancelsTouchesInView=false`). **ALL glasses OSD pills are transient (~1 s, coordinator-owned
  cancellable expiry tasks — never `.task + .id(pulse)` in the view: `try? await Task.sleep` swallows
  CancellationError and a re-keyed task cleared the pulse anyway); nothing may persist over the
  video** (the always-on mode chips are gone). AI slow-mo hosts ON the glasses (ONE-superview rule,
  §9). Hard rules: **no `beginBackgroundTask`, no audio-session writes in glasses code**; teardown
  clears the overlay UNCONDITIONALLY; `ScreenAwake` arbiters the idle timer; scene pickers filter
  `.windowApplication`; glasses posters deliberately unblurred under Privacy Mode; the PHONE remote
  shows NO scene identity (posters/titles), not even gated on Privacy Mode. Interim, deliberate: v1
  EXIT routing retained; end-countdown card not built; iOS 27 `UISceneAccessory` migration when
  available.
- Diagnostics built for the saga were removed once they answered (`TransferBenchmark`, the -3000
  probe/census, `dl-identity`, the retest button) — recover from git history, don't rewrite them.
- Next candidates: **the VMAF map fix (plugin v0.3.1) is DONE — shipped, deployed, and live-verified**
  2026-07-16 (job 56 ran clean past the previous ~2h40m/20.7% death point, zero 401s; v0.3.2 settings-
  persistence also deployed to the box; ROADMAP §encode-quality has the full evidence — no further
  action needed here). **Netflix fullscreen player UI** (next-biggest ★ player item); WYSIWYG layout
  editor / mini-player-PiP / AI zoom-follow / filmstrip timeline (all in ROADMAP); **concurrent-queue
  server transcode** (needs a Stash-scheduling spike first). (Resumable/checkpointed transcode already shipped 2026-07-04
  as `FFmpegResumableTranscoder` — don't re-plan it. **Blur Media shipped 2026-07-25** as Privacy Mode,
  gaps closed and blur strength adjustable — don't re-plan that either. RemoteLog telemetry is a kept
  feature; the old remove-before-release blocker is withdrawn.)
