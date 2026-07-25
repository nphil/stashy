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
- **-3000 "Cannot create file" is the system's HAND-OVER step failing, not Range and not disk space
  (device-verified 2026-07-24/25, iOS 26.5.2, dl-trace).** A background `URLSessionDownloadTask`
  transfers into ITS OWN staging file and only moves that into our container at the end; that final move
  is the one part of the transfer the app doesn't control, and on the owner's device a WHOLE-FILE
  transfer fails it **every single time**: 98% of a 560 MB file (8.1 GB strict free), 99% of a 1.45 GB
  one (6.5 GB free), 100% of a 1.6 GB one — and `dl-err-detail` proves iOS supplies **no underlying
  error, no path, no failure reason**. Earlier conclusions here were WRONG twice over: not "8 parallel
  range tasks" (that was this same bug ×8) and not "bg sessions can't deliver 206" (plain 200 full-file
  downloads fail identically). **Do not "fix" this by retrying the same whole-file transport**: the bytes
  all arrived, so a retry just repeats it and costs another full file.
  **Current design (v1.0.325) = durable RANGE SLICES**: the background session runs one 64 MB range task
  at a time, each appended into our own part file, so a hand-over moves 64 MB rather than gigabytes and
  every landed slice is permanent. If the hand-over is broken at any size it now shows up after ONE slice
  instead of at 99% of a multi-GB file, and the item escalates to `startForegroundFallback` (an
  in-process data task with no hand-over step at all) having lost almost nothing — and keeping its part.
  The fallback only advances while the app is open, hence fallback-only. (§3)
- **A discarded resume blob LEAKS the partial file into "System Data" (owner hit 71.85 GB).** The blob
  is a pointer to a partially-downloaded file the daemon holds in ITS cache, outside the app sandbox —
  invisible to Stashy's storage listing and unreachable by it. Setting `resumeData[id] = nil` orphans
  that file forever. To release it you must materialise a task from the blob and `cancel()` it WITHOUT
  requesting new resume data (`releaseResumeBlob`). This fed a vicious cycle: stranded partials ate the
  REAL free space, which caused the next download's hand-over to fail, which stranded another. Settings
  → Diagnostics → **Reclaim Download Storage** does the sweep on demand. (§3)
- **Test free space with `volumeAvailableCapacity`, NEVER `…ForImportantUsage`.** The latter counts
  purgeable caches iOS may never reclaim in time: it read **40 GB** on a device with **4.1 GB** genuinely
  free, which is how a 5.5 GB download was waved through a preflight check and then died at 99%. A
  WHOLE-FILE background download costs **2× the file** (the system streams into its own container, then
  needs a second copy's worth to hand it over); a **sliced** one costs file + one slice, and the
  in-process fallback costs 1× — so an item that fits one copy but not two is routed to the fallback up
  front. (§3)
- **iOS hands you resume data for a FAILED download in the error's `userInfo`**
  (`NSURLSessionDownloadTaskResumeData`) — `cancel(byProducingResumeData:)` does nothing for a task
  that already ended. Not reading it meant every dropped connection restarted a multi-GB file from
  byte 0. Bank the blob BEFORE any recovery branch, and never let a reset path wipe it (shipped that
  bug for one build). Blobs are epoch-guarded: one from a superseded task must never be handed back,
  and `cancel(byProducingResumeData:)` delivers a hop late, so Resume waits for it. (§3)
- **Multi-threaded downloading is GONE (v1.0.313) — do not reintroduce it.** Benchmarked on the
  owner's own server: one connection sustained ~32 MB/s vs ~14 for 8-way, and the single background
  transfer runs at **85–100 MB/s**. Parallelism only pays where one TCP stream can't fill the pipe
  (high RTT, loss, per-flow shaping); on a LAN it just makes an array seek. `TransferBenchmark`
  (scene ••• → Benchmark Transfer) re-measures it, counterbalanced A B C C B A. (§3)
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
  convert via CoreImage); (2) the model has a **device-specific max dimension (~720p)** that iOS 26 can't
  query (OS 27 only) — so **cap interpolation at 1280×720**, never scale up. `SlowMoInterpolator`.
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
- **A background `URLSessionDownloadTask` commits NOTHING until it completes** (streams into URLSession's
  private temp, lands in our file only at `didFinishDownloadingTo`). That is WHY the engine slices: the
  unit of loss on any failure is exactly one in-flight task, so make that unit small (64 MB) and append
  it to our own part the instant it lands. **Never derive displayed progress from bytes the daemon is
  still holding** — a retry then re-reads a smaller durable size and the island % goes BACKWARDS (owner:
  15→12→8). `connectionFailed` snaps a ranged connection's `received` back to the part's real size and
  refuses to bank an iOS resume blob for a slice, for exactly this reason. (An earlier 16 MB-slice build,
  v1.0.307–308, was removed for the wrong reason — the conclusion "bg tasks can never complete a range
  request" was later disproved. Its actual defect was in-flight bytes counted as progress.) (§3)
- **Part files must NOT live in `Caches`** (they did until v1.0.307): iOS purges Caches under disk
  pressure and preferentially while the app is NOT running — exactly a big download left minimized. Every
  progress number derives from part FILE SIZES, so a reaped part reads as silent progress loss then a
  restart. They live in Application Support beside the downloads now. (§3)
- **Never destroy durable bytes on a recoverable error.** Three shipped paths did: a mid-transfer range
  refusal (`badServerResponse` → `launch(reset: true)`, now gated on zero bytes — a server that can't do
  ranges refuses the FIRST request, so a later refusal is a proxy/416/transient), `retry()` (called
  `launch(reset: true)` unconditionally, destroying the very parts that merge-failure and the -3000 hold
  preserve *for* it — now resumes, and re-merges when all parts are complete), and the geometry rebuild
  in `startConnections` (now requires `receivedBytes == 0`). (§3)
- **The foreground-drain barrier must be retired by EVERY terminal callback, not just cancellation.**
  `pendingForegroundStops` was a count decremented only on `NSURLErrorCancelled`; a cancelled writer that
  finished cleanly, errored, or went through the delegate's `fail()` never retired it, so the barrier
  stuck forever — and `startConnections` refuses to start ANY engine while it's set, so the item made
  zero progress for the rest of the process (surviving even a foreground return). It's a `Set<Int>` of
  conns now, retired from finished/failed/stopped alike, plus a 4 s watchdog (`dl-drain-timeout`). (§3)
- **A cold background relaunch restores items as `.paused`** and `reconnectTasks` can't flip them (the
  app was relaunched *because* the task went terminal, so `getAllTasks` no longer returns it) — while
  every continue-branch is gated on `.downloading`. Result: one slice committed per relaunch, then dead,
  and the Live Activity ends itself. A background callback for a paused item now adopts it (a user pause
  cancels its tasks → `connectionStopped`, so the two stay distinguishable). (§3)
- **Download diagnostics:** Settings → Diagnostics → **Trace downloads** (off by default, separate gate
  from log streaming) emits `dl-slice`/`dl-slice-done`, `dl-parts` (per-part size census — the line that
  makes progress loss obvious), `dl-err`, `dl-wipe`, `dl-drain*`, `dl-restore`, `dl-la` (what the Live
  Activity was handed; a DECREASE is always logged). RemoteLog's flush timer is frozen while suspended,
  so the engine calls `flushNow()` on both lifecycle transitions.
- **Stash's `jobQueue` returns `null`, not `[]`, for an EMPTY queue** (nullable list + Go nil slice) —
  decode it optionally. The non-optional decode broke the jobs panel's scan bar (frozen snapshot, poll
  loop silently self-killed; fixed v1.0.296). General rule: a poll loop behind visible UI must never
  self-terminate — clear stale state, show a reconnecting line, back off, keep trying. (§6)

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
- **`docs/OPTIMIZATION_PLAN_2026-06-30.md`** — completed perf pass; §5 = the (reference-only —
  RemoteLog is kept) telemetry-removal checklist; plus playback engineering learnings.
- **`docs/PERF_STABILITY_REVIEW_2026-07-01.md`** — 31 adversarially-verified perf/stability findings
  with per-item status (most shipped; #25 reverted — do not re-apply; a few deferred lows). Check before
  re-analyzing perf or touching the flagged code paths.

## Current state (update as you go; keep this section short)
- Latest release: **v1.0.327** (`4055b9f`). Slicing shipped in v1.0.325 and **did not avoid the -3000**
  — device traces proved the hand-over fails at EVERY size (the first 64 MB slice, nothing durable yet,
  fails exactly like a 1.6 GB whole file, 4.9 GB strict free, no underlying error). Measured cost: strict
  free fell **472 MB across 5 failed slices** (~70 MB each, stranded, never returned) for zero bytes
  delivered — that IS the "System Data" growth. So v1.0.327 stops retrying: one -3000 with nothing
  durable condemns the transport, the verdict persists (OS-version-stamped, so an iOS update re-tests),
  and every later download goes in-process. The in-process path also holds a background assertion now.
- **The next build is INSTRUMENTATION ONLY — do not ship another fix for a theory.** An earlier comment
  in `connectionFailed` claimed device-proof that "the daemon stages OUTSIDE our container". **That was
  wrong**: it rested on `dl-staging` reading `files=0 bytes=0` from a census that counted only non-empty
  regular FILES, so an absent delivery directory and an empty one read identically. `stagingCensus` now
  counts dirs + zero-byte entries, and **`probeDeliveryPath`** (`dl-probe`) walks
  `Caches/com.apple.nsurlsessiond/Downloads/<bundle-id>`, then tries the two operations the daemon must
  perform — `createDirectory` and a 1-byte write — and logs the errno of whichever fails.
  **Read from ntfy, in this order:** `dl-identity` (host bundle id + whether the appex is nested under
  it — if the signer rewrote either, that one line explains BOTH the -3000 and the ActivityKit
  `.denied`); then `dl-probe` — `mkdir`/`write` failing = a permission/identity problem; both `ok` with
  `mine=0` beforehand = the daemon's own directory is missing and pre-creating it may be the whole fix;
  both `ok`, directory present, still -3000 = the app is not at fault and the work is making the
  in-process path survive backgrounding.
  Earlier: v1.0.319 fixed the resume-blob storage leak + Reclaim Download Storage; v1.0.317 = strict
  free-space accounting; **v1.0.313** removed multi-threading.
- Next candidates: **the VMAF map fix (plugin v0.3.1) is DONE — shipped, deployed, and live-verified**
  2026-07-16 (job 56 ran clean past the previous ~2h40m/20.7% death point, zero 401s; v0.3.2 settings-
  persistence also deployed to the box; ROADMAP §encode-quality has the full evidence — no further
  action needed here). **Netflix fullscreen player UI** (next-biggest ★ player item); Blur-Media app-wide / WYSIWYG layout
  editor / mini-player-PiP / AI zoom-follow (all in ROADMAP); **concurrent-queue server transcode**
  (needs a Stash-scheduling spike first). (Resumable/checkpointed transcode already shipped 2026-07-04
  as `FFmpegResumableTranscoder` — don't re-plan it. RemoteLog telemetry is a kept feature — the old
  remove-before-release blocker is withdrawn.)
