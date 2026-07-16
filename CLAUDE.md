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
- **`VTFrameProcessor` (AI slow-mo):** `-19730 "Processor is not initialized"` is a **misleading** error —
  it means the input is unsupported, NOT that startSession failed. Two real causes, both bit us: (1) feed
  buffers in the config's own `sourcePixelBufferAttributes` format (**420v biplanar YUV**, NOT BGRA —
  convert via CoreImage); (2) the model has a **device-specific max dimension (~720p)** that iOS 26 can't
  query (OS 27 only) — so **cap interpolation at 1280×720**, never scale up. `SlowMoInterpolator`.

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
- Latest release: **v1.0.252** (Downloads before→after size + VMAF line on transcode finish, commit
  `f1b008a`, ~8.60 MB — built green). Companion commits are newer on main but plugin+docs-only
  (no app build). Verify the newest release/IPA size each push.
- **VMAF quality-targeted transcodes shipped** (Companion v0.2.0→v0.3.1 + app v1.0.250–252): the plugin
  binary-searches the encoder quality knob on short sample windows to hit a target VMAF (phone model;
  presets are now perceptual targets High 97 / Balanced 94 / Small 91; default ON; needs libvmaf — in the
  BtbN software ffmpeg build, NOT jellyfin-ffmpeg; HDR/DoVi or any measure failure falls back safely to
  the preset CRF). v0.2.2 fixed the `-lavfi` double-escaped-colon bug that silently broke EVERY
  measurement; v0.2.3 parallelized sample windows (~45s→~27s) + `vmafSamples` setting. Result JSON carries
  `cq/vmaf/vmaf_target` → Downloads shows a live **"Analyzing quality — %"** phase (served-file progress;
  the Job.progress clobber is skipped while analyzing or the bar bounces), a **"VMAF NN" chip**, and
  **before→after size + reduction** on finish. **v0.3.0 VMAF CRF map**: "Compute VMAF Map" / "Rebuild VMAF
  Map (full)" tasks pre-compute per-video optimal CRF (+ the measured curve) per resolution into served
  `cache/vmaf-map.json` (kilobytes for the whole library, zero scene writes, incremental + resumable via
  `vmafMapBudgetMin`); `run_transcode` uses the cached CRF and skips the ~30 s live analysis;
  `_crf_from_curve` derives all three presets from the one stored curve.
- **Companion v0.3.1 — the mid-run map FAILURE (~20.7%, GraphQL 401) is FIXED**, both the cause and the
  damage: (1) **auth** — Stash's session cookie expires during multi-hour jobs, so `main()` now swaps to
  the server's API key at task start (`Stash.adopt_api_key`, fetched while the cookie still works; Cookie
  header dropped; one retry on 401); (2) **data loss** — the finally-block deleted-scene prune ran on ANY
  exception with a partial `seen`, erasing every mapped scene the run hadn't reached and persisting the
  gutted map — now prunes only after a clean full pass (`_prune_missing`); (3) hardening — whole per-scene
  body try-wrapped (INFO log + `failed` count, run continues), malformed entries reset, 30-min per-
  (scene,res) `deadline` in `_vmaf_search` (map task only). Unit tests: `stash-plugin/tests/` (stdlib-only;
  the prune regression test fails on v0.3.0). Full story in ROADMAP §encode-quality.
- **Scrubbing upgrades shipped this session** (all in `Features/Player/PlayerControlsView.swift` +
  `ZoomablePlayerSurface.swift` + new `Services/ScrubFrameProvider.swift`): (1) **exact-frame preview**
  on downloaded (local) files — `AVAssetImageGenerator` (zero tolerance, `cancelAllCGImageGeneration`
  coalesce-to-latest, capped `maximumSize`), gated to `route.url.isFileURL`; sprite tile is the instant
  placeholder. Release seek was already frame-exact for local (`seekPrecise`). (2) **Variable-speed
  scrubbing** — shared `ScrubSpeed` enum (Hi/Half/Quarter/Fine by vertical finger distance), incremental
  accumulator (never read the `scrubTime` binding back), on BOTH the bar drag and the **video hold-scrub**
  (`ZoomablePlayerSurface.handleLongPress` — changed ONLY the time-math, gestures untouched). `speedTier`
  is a shared `@Binding` owned by `ScenePlayerView`, driving one subtle speed label. See ENGINEERING_NOTES §6.
- **Settings connection is edit-locked** (v1.0.247): a saved server shows greyed read-only URL + masked
  key with a standard header **Edit** button (Cancel discards, Update & Reconnect commits); not-connected
  stays editable for first setup. `isEditing` @State in `SettingsView`.
- **App-switcher privacy blur shipped** (`SnapshotPrivacyModifier` in `Services/AppLock.swift`, outermost
  in `StashyApp`): thick-material cover whenever `scenePhase != .active` so the multitasking snapshot
  never shows media. Deliberately unanimated (cover must be drawn in the snapshotted frame). Settings →
  Privacy toggle, default ON. Independent of Face ID lock and in-app Privacy Mode.
- **Watch-heat shipped** (`Services/WatchHeat.swift`): per-scene 100-bin watched-seconds accumulation
  (host-scoped keys, JSON in App Support, debounced off-main writes), fed from `ScenePlayerModel`'s time
  tick (model now takes `sceneID`; delta window rejects seeks). `ScrubBar` draws the outlier-capped,
  smoothed, normalised curve above the track **only while scrubbing**. Settings → Player: toggle
  (default ON; off = stops tracking too) + Clear data.
- **AI upscaling REVERTED (2026-07-10)** after two shipped iterations (VT zoom-crop v1.0.241, MetalFX
  2×/4× + neural pause-stills v1.0.242–244): owner called it buggy + not visually worth it on 720p
  sources. `UpscaleRunner.swift` deleted; gear toggle/stats/overlay/geometry-provider removed. Pinch-zoom,
  AI slow-mo and the slow-mo Lanczos pass are untouched. **Read ROADMAP §AI-upscaling before any new
  attempt** — full postmortem (960×960 VT input cap, silent green-screen on unqueried scale factors,
  session-rebuild storms on variable crops, frame-tap competition, SwiftUI-overlay-races-pinch) plus the
  researched revival plan: iOS 27 VT query APIs; **Real-ESRGAN Core ML paused-frame enhance** on A19 Pro
  (reuses the proven tiling design); **Snapdragon 8 Elite live NPU SR** (0.96 ms/tile) for the future
  Android app; server P40 Real-ESRGAN as max-quality offline option.
- **Tilt-to-fullscreen made reliable**: `suppressReentry` now re-arms on ANY recognised non-landscape
  orientation (faceUp used to eat the next tilt), and opening the player while already held landscape
  enters fullscreen from `onAppear` (no orientation-change notification fires in that case).
- **AI slow-mo shipped & working** (`Services/SlowMoInterpolator.swift` + `SlowMoRunner.swift` +
  `Features/Player/SlowMoRenderView.swift`): on-device Neural-Engine frame interpolation via `VTFrameProcessor`
  (`VTLowLatencyFrameInterpolation`, iOS 26). While playback ≤0.5× (gated, `aiSlowMoEnabled` off by default),
  a `CADisplayLink` pulls decoded frames from the player's `AVPlayerItemVideoOutput`, synthesises **3 mid
  frames (4×)** per pair, and paces real+synth onto a Metal overlay (`SlowMoRenderView`) via a display-time
  FIFO (single-flight, `latency`=0.15s). **The -19730 saga (see Landmines):** feed the config's required
  **420v** format (not BGRA) AND **cap at 1280×720** (device max the model won't exceed). Confirmed producing
  synthesised frames on-device. Deferred: adaptive frame count per rate; the standalone 0.25×-won't-play bug.
- **Stashy Companion plugin shipped** (`stash-plugin/` — its OWN top-level folder, sibling to `ios/`):
  a stashapp/stash plugin (`interface: raw`, zero-dep Python) that adds what vanilla Stash can't — **GPU
  HEVC (hevc_nvenc, Tesla P40) / CPU AV1 (SVT-AV1) transcode**, ffprobe codec+HDR stats, and a served
  playability report (no scene writes). Delivery mechanism (researched from real Stash source): plugin writes the iPhone-native
  MP4 into its served `cache/` dir (`/plugin/stashy-companion/assets/…`, Range-capable) and records the
  download path on the SOURCE scene's `custom_fields.stashy_transcode`; the app polls `findJob` for real
  `Job.progress`. Encoder ladder: NVDEC+NVENC → CPU-decode+NVENC → libx265. Install = add
  `raw.githubusercontent.com/nphil/stashy/main/stash-plugin/index.yml` as a Plugin Source (zip+sha256
  committed). CI `paths-ignore` now skips `stash-plugin/**` so plugin-only commits don't build the app.
- **App↔plugin foundation shipped** (extensible — more plugin features will hang off this): `Services/
  StashCompanion.swift` = the one typed gateway (`runPluginTask` / `findJob` / `custom_fields`); Downloads
  staging gained a 3rd source **Companion** (HEVC/AV1 + resolution + quality) → new `.serverProcessing`
  DownloadState drives a *determinate* bar from live `Job.progress`, then hands the finished file to the
  normal (Range-capable, multi-connection) byte-download engine. Load-bearing transfer path untouched.
- **Debug logging system shipped** (`Services/RemoteLog.swift` + `Services/DebugOverlay.swift`): ntfy
  server URL + topic are now **configurable** (Settings → Diagnostics; point at a self-hosted Unraid ntfy
  for privacy, default public `ntfy.sh`). `RemoteLog.event(tag, fields)` = compact structured one-liners.
  Transcode/remux/playback paths now stream stage diagnostics (`⚙︎ transcode-in/frame1/out`,
  `⚙︎ remux-header-FAIL/out`, `▶︎ video size=…`) to debug the HEVC-won't-play-native +
  video-disappeared-after-transcode bugs. **App-wide floating camera button** (own passthrough UIWindow,
  excluded from its own shot) → `RemoteLog.uploadImage` PUTs a screenshot as an ntfy attachment; assistant
  fetches the hosted URL (public server only). **ntfy has NO delete API** — "New topic" rotates to a burner
  channel; auto-expiry (public ~12h msgs / ~3h attachments) or short self-hosted retention is the cleanup.
  Still off by default; **kept permanently** (owner decision 2026-07-16 — see Standing rules).
- **M-B shipped**: player gear → custom quality menu forcing Stash HLS at a resolution. The `?resolution=`
  bug is fixed — Stash's HLS URL already carries `resolution=ORIGINAL`, so `serverQualityRoute` now
  *replaces* it (a duplicate param made Stash read the first = ORIGINAL). Enum values LOW/STANDARD/
  STANDARD_HD/FULL_HD/ORIGINAL verified against stashapp/stash source. Quality switch resumes at the exact
  position (client-side seek; `start=` doesn't work on the HLS manifest).
- **M-A (on-device *streaming* transcode playback tier) shipped then was REMOVED** (`c088325`,
  2026-07-05): flaky, seek-by-reinit made scrubbing glitchy, and it pulled the whole original over the
  network to re-encode locally. `FFmpegStreamTranscoder`/`LocalTranscodeStream`/`FFmpegAudioReencoder` are
  **deleted** — don't go looking for them (git history only). The "Apple can't decode at all" bucket
  (VP9/software-AV1/exotic) now routes straight to Stash **server** HLS at any resolution. On-device FFmpeg
  transcode survives in the **Downloads** flow only: `FFmpegTranscoder` (universal single-pass + lossless
  stream-copy fast path) and `FFmpegResumableTranscoder` (checkpointed keyframe-aligned chunks, shipped
  2026-07-04 — deliberately chosen over fragmented-MP4 append; used for long re-encodes) beside the
  AVFoundation `VideoTranscoder` (short native H.264 only). See ENGINEERING_NOTES §4.
- **Player UX this session** (all shipped): intelligent loading donut (per-mode `LoadEstimator` rolling
  average + saturating curve, % inside ring); inline expanding **volume slider** 0–100 (starts muted);
  quality+method **status badges** on one control row; gear moved right; resume-from-position on return
  from performer/link (safe reload, not a live pause — pop-to-root would crash a kept-alive engine);
  transcode box rich live line + **auto-pause/resume on background/foreground**; **keep-screen-awake** on
  Downloads/active work; social-links overlap bug fixed (ScrollView) + unified `SocialLink.list`; performer
  ••• menu vertical.
- **Seek-donut tuning shipped**: a seek-by-reinit re-buffer now fills the loading ring on a **warm per-seek
  estimate + snappy curve** (`LoadEstimator.expectedSeek`/`recordSeek`, `LoadCurveParams.seek`, gated by
  `loadIsSeek` in `ScenePlayerModel`) instead of the slower cold-start estimate — and seek times stop
  polluting the first-load learning. Untouched (load-bearing): the `seekTarget`/`seekHoldUntil` hold that
  pins the scrub thumb where the finger releases — verified the change is bookkeeping-only, no regression.
- **File-aware load estimate shipped**: the loading donut's expected time (load AND seek) now scales by a
  cheap `resolution × bitrate × codec` **weight** (`LoadProfile` in LoadEstimator.swift; `Scene.loadProfile`),
  so a 4K HEVC file and a 720p H.264 file no longer share one estimate. `LoadEstimator` now learns
  seconds-*per-weight* per tier (defaults bumped to `.v2`, old raw samples discarded) and multiplies by the
  current file's weight — threaded via `ScenePlayerModel(loadProfile:)` from `ScenePlayerView`. **Plugin-
  independent**: every input comes free from Stash's scene metadata (the companion plugin gives the *player*
  donut nothing — it's a Downloads-flow tool; its server-transcode download bar is already determinate off
  live `Job.progress`).
- **RESOLVED**: the HEVC-won't-play-native + video-disappeared-after-transcode bug is no longer open (owner
  confirmed). Diagnostics (`⚙︎ transcode-in/frame1/out`, `remux-header-FAIL/out`, `▶︎ video`, `color=HDR-…`)
  stay wired but the hunt is closed.
- **Playability intelligence shipped (served-file, NO scene writes)**: plugin `Library Codec Report`
  (v0.1.18) ffprobes the library → one served `cache/playability.json`; **zero `sceneUpdate`** (the old
  per-scene tag/custom_field writes caused a hundreds-of-Sync-tasks storm — never write per-scene in bulk;
  use served files, like the transcode-progress file). App: `PlayabilityStore` fetches+caches it →
  (1) **smarter routing** (`playbackRoute(pluginNeedsTranscode:)` skips a doomed remux on Apple-undecodable
  4:2:2/4:4:4 HEVC), (2) **playability filter** (`SceneFilterPanel` Any/Direct-play/Needs-transcode, pages
  via `findScenesByIDs`). No scene-card badges (owner). Plugin writes nothing to scenes; the **Remove Stashy
  Tags (cleanup)** task deletes the `Stashy:*` tag definitions left by ≤0.1.17 (tag-definitions only —
  the residual `stashy_probe` custom field is deliberately left as dead data; clearing it would be a
  per-scene write = Sync storm).
- **Playback speed shipped**: Podcasts-style speed pill on the player control row (left of the gear) →
  0.25×–2× menu, **pitch-corrected** audio (`AVPlayerItem.audioTimePitchAlgorithm = .timeDomain`). Rate is
  published via `AVPlayer.defaultRate` + a re-invoked `play()` (applies live, keeps
  `automaticallyWaitsToMinimizeStalling` on, won't force-start while paused). `PlaybackEngine` gained
  `playbackRate` + `slowMute`; the model re-applies both in `makeEngine` so speed survives every engine
  rebuild (seek-reinit / quality / fallback). Persisted **"Mute when slowed"** toggle in the same menu
  (mute vs. pitch-corrected audio below 1×; `slowMute` is a separate output-volume gate so it never
  clobbers the user's volume). Fully-decoupled *normal-speed audio under slow video* stays deferred.
- Next candidates: **① ship + verify the VMAF map fix (plugin v0.3.1)** — root cause confirmed
  2026-07-16 (session-cookie expiry → GraphQL 401 on long runs) + the prune data-loss bug; a fix
  session is in flight (ROADMAP §encode-quality has the full evidence);
  **Netflix fullscreen player UI** (next-biggest ★ player item); Blur-Media app-wide / WYSIWYG layout
  editor / mini-player-PiP / AI zoom-follow (all in ROADMAP); **concurrent-queue server transcode**
  (needs a Stash-scheduling spike first). (Resumable/checkpointed transcode already shipped 2026-07-04
  as `FFmpegResumableTranscoder` — don't re-plan it. RemoteLog telemetry is a kept feature — the old
  remove-before-release blocker is withdrawn.)
