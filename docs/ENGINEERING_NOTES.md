# Stashy engineering notes — deep reference

Companion to the root `CLAUDE.md` (the lean entry point). This file holds the hard-won detail:
**read the relevant section before touching that subsystem**, and update it as you learn. Everything
here was verified against the repo on 2026-07-01.

---

## 1. Build / CI detail

Workflow: `.github/workflows/ios-build.yml`, runs on `macos-15`, triggered on every push to `main`.
`paths-ignore` skips `**/*.md` and `android/**` — doc-only commits do **not** trigger a build.

### The swallowed exit code
The "Build (unsigned)" step pipes xcodebuild through `| xcpretty || true`, which **swallows the exit
code** — a compile or link error still shows ✅ green. The failure is only caught by the later
**"Package into IPA"** step, which checks the `.app` contains a non-empty executable (exits 1 with
`"App executable '<name>' missing/empty — the build failed"`) and enforces a ~1 MB minimum IPA size.

Consequences:
- "Build step green" ≠ "it compiled." Only the Package step passing / a published release proves it.
- On a compile failure **no release is published**, so the previously-installed IPA keeps working — a
  broken push is low-blast-radius.
- To read a real compile error: `get_job_logs` (GitHub MCP) with `return_content:true`,
  `tail_lines: ~230`. Swift `error:` lines appear just before the Package-step echo. Look for
  `❌ .../File.swift:LINE:COL: <message>` and `** BUILD FAILED **`.

### Verify Apple API signatures BEFORE you push (CI is the only compiler)
Every unverified API guess is a ~6–8 min round trip. Before using an unfamiliar Apple symbol, fetch its
exact Swift declaration from the **doc-JSON endpoint** (works from the sandbox; HTML doc pages are
JS-rendered and return only the title):
```
curl -sL "https://developer.apple.com/tutorials/data/documentation/<framework>/<symbol>.json" \
  | python3 -c "import json,sys; d=json.load(sys.stdin);
[print(''.join(f['text'] for f in v['fragments'])) for v in d['references'].values()
 if v.get('kind')=='symbol' and v.get('fragments')]"
```
(objc-only detail sometimes only appears on the child page `.../<symbol>/<member>.json`.) This session it
pinned down MetalFX (`MTLFXSpatialScalerDescriptor.makeSpatialScaler`, `colorProcessingMode`),
`AVAssetImageGenerator.generateCGImageAsynchronously(for:completionHandler:)`, and the VT super-res inits.
**Sharpest gotcha — failable-vs-not differs across sibling APIs:** `VTLowLatencyFrameInterpolation`
config init is *optional* (`guard let`), but `VTLowLatencySuperResolutionScaler` config **and** params
inits are **non-optional** (plain `let`), and `maximumDimensions` imports as `CMVideoDimensions?`
(unwrap it). Guessing these cost three separate red builds before the doc-JSON habit stuck.

### Auto-versioning and the push sequence
On success, CI commits a version bump to `main` with `[skip ci]` (bumps `MARKETING_VERSION` /
`CURRENT_PROJECT_VERSION` / `CFBundleShortVersionString` in `ios/project.yml` + `Info.plist`, and
patches root `apps.json`, the Feather/AltStore source manifest) and publishes a tagged Release with
the IPA asset. So `origin/main` moves without you — always rebase before pushing:

```
git add <specific files>
git commit -F - <<'EOF' ... EOF
git fetch origin main -q && git rebase origin/main && git push -u origin main
```

**Verify every push** via `get_latest_release`: a *changed* IPA byte size confirms your code actually
shipped. Calibration: v1.0.100 ≈ 7.63 MB, v1.0.107 = 7,733,141 B ≈ 7.73 MB (FFmpeg is statically
linked + dead-stripped, so size creeps up as more of it gets called).

### XcodeGen
The Xcode project is generated in CI from `ios/project.yml`, which **globs `Stashy/`** — new `.swift`
files are auto-included; never hand-edit a `.pbxproj`. Deployment target iOS 26, Swift 6,
`SWIFT_STRICT_CONCURRENCY: complete`, `VALIDATE_PRODUCT: NO` (unsigned IPA; the FFmpeg frameworks have
underscored bundle ids that a CI script patches).

### GitHub MCP quirks
`actions_list` / `list_workflow_runs` returns JSON exceeding the tool token cap — it gets saved to a
file; parse with a short `python3 -c` reading the saved path (`workflow_runs[i]` →
`id,status,conclusion,head_sha,display_title`). `get_workflow_run` for one run is fine. The MCP token
can **expire mid-session** ("requires re-authorization"); `git push` still works (separate proxy) —
keep committing and ask the owner to re-auth to read CI again.

---

## 2. Swift 6 strict concurrency — the patterns that actually compile

`SWIFT_STRICT_CONCURRENCY: complete` is on. Most CI failures this project ever hit were concurrency,
not logic:

- **`@Observable @MainActor final class` is implicitly `Sendable`.** You can capture such instances
  (incl. `self`, and model objects like `DownloadItem`) into `@Sendable` closures.
- **`"reference to captured var 'self' in concurrently-executing code"`** — the classic. Happens when
  you `[weak self]` (an optional *var* binding) and a *nested* `@Sendable`/concurrent closure
  references `self` again. **Fix:** don't re-capture `self` in the inner closure — capture the
  specific Sendable object directly. Real example: a transcode progress callback doing
  `Task { @MainActor [weak self] in self?.items.first... }` inside another `[weak self]` Task errored;
  fixed as `{ p in Task { @MainActor in item.transcodeProgress = p } }`.
- **Non-Sendable Apple objects across a boundary** (`URLSessionTask`, `AVAssetWriterInput`,
  `AVAssetReaderTrackOutput`): wrap in a tiny `@unchecked Sendable` box struct when handing them to
  `@Sendable` closures (e.g. `getAllTasks`'s completion, `requestMediaDataWhenReady`).
  `DownloadManager` has `UncheckedSendableBox`, `VideoTranscoder` has `UncheckedTranscodeBox`.
- **`Task { @MainActor in … }` created inside a `@MainActor` method:** calls to other `@MainActor`
  methods inside are same-actor → **no `await`** (adding one warns "no async operations occur within
  await"). But you still need explicit `self.` for escaping-closure captures.
- **`try?` flattens nested optionals (SE-0230).** `try? url.resourceValues(forKeys:).fileSize` is
  `Int?`, NOT `Int??`. Don't write `?? 0 ?? 0`.
- **`NotificationCenter.addObserver(forName:…, queue: .main, using:)`** block is `@Sendable`. To call
  a `@MainActor` method from it synchronously, use `MainActor.assumeIsolated { self?.foo() }` (safe
  because `queue: .main` runs on the main thread). `Task { @MainActor in }` also works but defers a
  runloop tick — use `assumeIsolated` when you must act *before* suspension (app-phase handoff).

---

## 3. Downloads subsystem (`Services/DownloadManager.swift`) — sharpest edges in the app

### Architecture
- `DownloadManager` (`@Observable @MainActor`) owns `[DownloadItem]`. Each download = **8 parallel
  HTTP range requests** (`Range: bytes=lo-hi`) via `URLSessionDownloadTask`, each writing a **part
  file**; parts are concatenated (`merge`) on completion. Single connection if the server didn't
  report a size.
- **`DownloadDelegate` is a SEPARATE `NSObject` class**, not the manager, because `@Observable` +
  `NSObject` conflict. It runs on a background delegate queue, does the synchronous part-file move
  there, and forwards structural events to the `@MainActor` manager via `@Sendable` closures.
  High-frequency byte progress goes to a lock-guarded `TransferStore` (never hops the actor per
  byte); a **120 ms MainActor poll loop** reads the store and updates the observable UI.

### THE -3000 LANDMINE (shipped regression — do not repeat)
A **background `URLSession` (`URLSessionConfiguration.background`) cannot run 8 PARALLEL range (206
partial-content) tasks** — the out-of-process `nsurlsessiond` daemon returns
**`NSURLErrorCannotCreateFile` (-3000)** on every connection. Commit `ef9e591` switched the whole
engine to a background session, broke ALL downloads, and was reverted in `22f6740`. A **single**
background range task at a time is the normal supported case. (Note: `docs/DOWNLOADS_PLAN_2026-07-01.md`
predates this discovery and asserts the opposite — this file is the correction.)

### Current design (v1.0.107): dual-engine handoff
- **Foreground:** 8-way parallel on `session` (`.default`). Fast. **Sacred — do not break this path;**
  it's the fallback for everything.
- **Background:** on `UIApplication.didEnterBackgroundNotification`, active downloads **hand off** to
  `bgSession` (background config, `sessionSendsLaunchEvents = true`) running **one connection at a
  time**; `connectionFinished` chains the next unfinished part. On `willEnterForegroundNotification`
  it hands back to 8-way parallel.
- **Handoff mechanics:** cancel in-flight tasks with `cancel(byProducingResumeData:)`; resume data
  arrives *asynchronously*, so a per-item `pendingHandoff` counter waits for all blobs before starting
  on the target engine. Part files + per-connection resume data are preserved both directions → no
  progress lost. A short `beginBackgroundTask` assertion covers the handoff so the bg task starts
  before suspension.
- **`inBackground`** is initialized from `UIApplication.shared.applicationState` (so a cold background
  relaunch behaves), then flipped by the two notifications.
- **`taskDescription`** on every task encodes `"<itemID>\u{1}<conn>\u{1}<partPath>"` so after a cold
  background relaunch (empty in-memory store) the delegate can still route a finished file.
  `reconnectTasks` queries **both** sessions' `getAllTasks` on launch.
- **`.active` marker files** (in the meta dir) distinguish an active/resumable download from a stopped
  one, so `loadInterrupted` only resurrects the right ones after relaunch.
- ⚠️ **UNVERIFIED ON DEVICE:** that a *single* bg range task doesn't also -3000 (very likely fine),
  and the whole suspend→continue→relaunch flow. If single-bg -3000s, fall back to leaving downloads
  paused-on-background (foreground still works).

### Storage & privacy
- Video + sidecars live in **`Application Support/Stashy/{Downloads,DownloadsMeta}`** — private to
  the app (NOT visible in the Files app, unlike `Documents`), **excluded from backup**, migrated from
  the old `Documents` location. **Part files are in `Caches/DownloadParts`** (transient). Do not move
  downloads back to Documents.
- Sidecars per download: `<id>.json` (full `StashScene` + apiKey, `Codable`), `<id>-thumb.jpg`,
  `<id>-sprite.jpg`, `<id>.vtt` — these power the offline card, offline playback, and offline scrub
  sprites. **`StashScene` and all nested types are fully `Codable` — keep them that way.**
- Accessors the rest of the app relies on: `localFile(sceneID:)`, `localSprite(sceneID:)`,
  `localVTT(sceneID:)`, `hasDownload(sceneID:)`.

### Follow-ups
- **Encryption (roadmap, not built):** opt-in "encrypt downloads" — Data Protection `.complete`, or
  app-level AES-GCM (CryptoKit + Keychain) decrypted via `AVAssetResourceLoaderDelegate`. See ROADMAP.
- **Live Activity / Dynamic Island** needs a **Widget Extension target** in `ios/project.yml`
  (ActivityKit + `NSSupportsLiveActivities`). **Riskiest remaining downloads item** — it changes the
  IPA structure for a *sideloaded* app; isolate in its own commit so it's revertable.

---

## 4. On-device transcode (`Services/VideoTranscoder.swift`)

- **`AVAssetReader` → `AVAssetWriter`** (hardware VideoToolbox), **NOT FFmpeg** — chosen for
  robustness (handles audio re-encode, no untestable C interop, can't crash the app).
  (`DOWNLOADS_PLAN` M3 said "reuse the FFmpeg engine" — this is what actually shipped.) Presets:
  resolution (Original/2160/1080/720/480) × quality (Low/Med/High bitrate ladder) × codec (HEVC
  default / H.264). Produces a faststart MP4, **replaces the offline file in place**, updates the
  item's spec chips.
- **Limitation:** only inputs AVFoundation can decode (H.264/HEVC in mp4/mov). **MKV/WebM/VP9/AV1
  throw `.unreadable`.** FFmpeg-based transcode for exotic containers is a documented follow-up (the
  FFmpeg remux path already exists for playback — §5).
- **AV1 encode is impossible with the current FFmpeg build** (LGPL-minimal: videotoolbox H.264/HEVC +
  AAC only). Would need rebuilding the FFmpeg XCFrameworks with libaom/SVT-AV1 — a separate project
  (build brief lives with the owner; see §5 on `stashy-videoengine`).
- UI: `wand.and.stars` button on a completed download card → `TranscodePresetSheet` →
  `downloads.transcode`. Progress on the card (accent bar + "Transcoding… NN%") with cancel.
  Progress deliberately rides on `item.transcoding`/`transcodeProgress` bools instead of a new
  `DownloadState` case, to avoid touching the download state machine.

---

## 5. Playback pipeline (full detail in `docs/ROADMAP.md`)

- **Routing:** direct-play H.264-in-mp4/mov/m4v (native HW decode, instant seeks) → **on-device
  linear remux over loopback HLS** for HEVC / foreign-container H.264 (MKV etc.) → Stash server HLS
  for anything Apple can't decode.
- **FFmpeg** comes from the SPM package **`nphil/stashy-videoengine`** (product `FFmpeg`; Swift
  modules `Libavformat`, `Libavcodec`, `Libavutil`, …), pinned in `ios/project.yml` (`from: "1.0.0"`,
  resolving ~1.2.0). **LGPL-minimal + VideoToolbox**: broad decoders (h264/hevc/vp9/av1/…), demuxers
  (matroska/mov/…), but **encoders only h264_videotoolbox / hevc_videotoolbox / aac**. The app **only
  links** it; CI never compiles FFmpeg. To change FFmpeg capabilities, rebuild and publish a new
  `stashy-videoengine` release, then bump the version constraint — a separate macOS-CI project.
- Key files: `FFmpegRemuxer.swift` (custom AVIO read/write, demux→fMP4 stream-copy,
  `frag_keyframe+empty_moov`, 4 MB read-ahead, playhead pacing, seek-by-reinit), `FMP4Index.swift`
  (walks growing fMP4 → HLS byte-range playlist), `LoopbackServer.swift`, `LocalRemuxStream.swift`,
  `FFmpegSource.swift`.
- Player: `PlaybackEngine` protocol; `AVPlaybackEngine` (`onEnded` via
  `.AVPlayerItemDidPlayToEndTime`, route-based mute default); `ScenePlayerModel` (facade;
  `reachedEnd`/replay-from-0, time clamped to duration); `ScenePlayerView` (sprite `.task` prefers
  local downloaded sprite/VTT); `PlayerControlsView`; `ZoomablePlayerSurface`; live Metal blur
  backdrop.
- **Sprite scrubbing:** `SpriteThumbnails` parses WebVTT + crops a sprite sheet (no decode =
  instant). It accepts `file://` URLs (URLSession + ImageCache handle them) — that's how offline
  sprites work.

---

## 6. UI / library patterns

### The popover saga (bit us THREE times)
**SwiftUI `.popover` is torn down & re-presented whenever its host view's structural identity
churns.** History on the filter/sort panel:
1. Hosted on a `.toolbar` ToolbarItem → rebuilt on every `isActive` change → flicker.
2. Moved to `.overlay` on the list `content` — but `content` is a `@ViewBuilder` that flips
   `_ConditionalContent` branches (grid ⇄ spinner ⇄ empty) every time `PaginatedLoader.reload()`
   clears `items` (it sets `items=[]` + `isLoading=true` synchronously). A branch flip tears down the
   overlay's host → popover closes & reopens.
3. **FIX (final):** host from a **stable `ZStack` sibling** of `content` — `FilterPopoverAnchor` in
   `Features/Library/ImmersiveFilter.swift`, used in `ScenesView` and `PerformersView`. **Reuse this
   pattern for any new filtered list; never host a popover on a conditional/churning view.**

### Stores and loaders
- **`PaginatedLoader<T>`** (generic, `@Observable @MainActor`): dedups pages by id,
  infinite-scrolls, and has a **generation token** so a superseded in-flight load discards its
  results (prevents a crash under the open popover from rapid filter changes). A view-level 250 ms
  debounce on query changes sits on top.
- **`LibraryEdits`** (`@Observable @MainActor`, app-wide via environment): optimistic overrides for
  rating/favorite/delete keyed by id (`Int??` for nullable ratings), `visible()` filters deleted.
  **Read ratings/favorites THROUGH this store** so edits reflect instantly across screens.
- **`StashClient`** has DB-lock retry (Stash is SQLite; "database is locked" → back off
  500/1000/1500 ms). `SceneQuery.downloadedOnly` is served locally from `downloads.items`, bypassing
  the network.
- `ImageCache` (actor): 2-tier (NSCache + downsampled JPEG on disk), LRU-evicted, priority tier for
  performer portraits (kept longest). Cache keys strip the `apikey` query param.

### Behavior defaults
Filters reset on launch; **sort field+direction persist** (UserDefaults). Blur toggles for
thumbnails/titles. Face ID is immediate (minimal privacy blur, no splash). Videos start muted unless
on AirPods/private audio route.

### Scrubbing (two gestures, one model) — v1.0.248-era
There are **two** scrub gestures and they must feel identical:
1. **Bar drag** — `ScrubBar.body` `DragGesture` in `PlayerControlsView.swift`. Touch anywhere on the
   full-width, 22 pt-tall track (not just the thumb); first touch jumps to position (tap-to-seek).
2. **Video hold-scrub** — `ZoomablePlayerSurface.Coordinator.handleLongPress`. **This lives in the
   pinch/zoom gesture file — a landmine.** Only ever touch the *time-math* inside `.changed`; leave the
   gesture setup, delegates, `scroll.isScrollEnabled` toggling, and lifecycle alone, or you risk pinch/pan.
- **Variable speed:** shared `ScrubSpeed` enum (module-level in `PlayerControlsView.swift`) →
  `tier(verticalDistance:)` returns (rate, tier 0–3): full speed near the reference line (bar centre, or
  the press-start Y), easing to Fine (0.1×) as the finger moves vertically away. Both gestures are
  **incremental** (accumulate Δx·rate onto the position); the video path keeps its **own accumulator**
  (`scrubAccumTime`) rather than reading the `scrubTime` binding back (avoids propagation-timing bugs).
- **`speedTier` is a shared `@Binding`** owned by `ScenePlayerView`, passed to both the surface and
  `PlayerControlsView`→`ScrubBar`, so the one subtle speed label (opacity-driven, scoped so it never
  animates the thumb) reads the same regardless of which gesture is active.
- **Exact-frame preview** (`Services/ScrubFrameProvider.swift`, `@Observable @MainActor`): decodes the
  real frame under the finger for **local downloads only** (`ScenePlayerModel.scrubFrameURL` =
  `route.url` when `isFileURL`). `AVAssetImageGenerator` with zero tolerance; coalesce by calling
  `cancelAllCGImageGeneration()` before each request so only the latest completes; capped `maximumSize`;
  carry the decoded `UIImage` back to the main actor in an `@unchecked Sendable` box. `PlayerControlsView`
  feeds it from `.onChange(of: scrubTime)` (covers both gestures) and `ScrubBar` prefers it over the
  sprite tile. Release seek is already frame-exact for local media (`ScenePlayerModel.seekPrecise`).
- **Pitfall that cost a build:** adding `speedTier`/`exactFrame` to `ScrubBar` — a SwiftUI `View`'s
  synthesized init requires call-site args in **declaration order** (Swift won't reorder labelled args).

---

## 7. Smaller facts that will still trip you up

- **`AppDelegate` lives in `Services/OrientationLock.swift`** (surprising location). It handles: the
  interface-orientation lock (whole app portrait; only fullscreen video allows landscape via
  `OrientationController.lock`), the **background-URLSession completion handler**
  (`handleEventsForBackgroundURLSession` → `BackgroundDownloadSession.completionHandler`, called by
  `DownloadDelegate.urlSessionDidFinishEvents`), the audio-session category, `RemoteLog` enable, and
  a stale-temp-file sweep. Wired via `@UIApplicationDelegateAdaptor` in `StashyApp.swift`.
- **Rating scale:** Stash stores **0–100 (`rating100`)**; UI shows **0–5 stars = value/20**.
  Favorites are plain booleans. Don't confuse the scales.
- **Stash auth:** append **`?apikey=<key>`** to media/image/sprite/vtt URLs; GraphQL uses the
  `ApiKey` header. `StashClient` holds `serverURL` + `apiKey`, both in the **Keychain**
  (`KeychainService`); `AppState` (in `StashyApp.swift`) owns the client and drives login/logout.
  URL helpers on `StashScene`/`Performer` (`directFileURL`, `thumbnailURL`, `spriteURL`, `vttURL`,
  `imageURL`) all take `apiKey:`.
- **`DownloadState` is switched exhaustively** in `DownloadsView`'s
  `controls`/`statusText`/`statusColor` — adding a case means updating those switches.
- **`FlowLayout`** (custom `Layout`) for chip rows; **`PopupMenu`**/native `Menu` for 3-dot actions;
  **`glassEffect(...)`** for Liquid-Glass chips. `ThemeManager` (`@Observable`, env-injected)
  exposes `accentColor/foregroundColor/backgroundColor/surfaceColor/preferredColorScheme`.
- **Navigation:** per-tab `NavigationStack` with a `[Route]` path + `AppRouter` (`Route` enum,
  `RouteDestination` switch, `.downloads` route). Cross-screen jumps (e.g. tag tap → filtered
  scenes) go through `router`. `fullScreenCover`/`sheet`/push usage is currently a bit ad hoc — the
  owner wants this rationalized (ROADMAP nav-cleanup item); tread carefully here.
- **Telemetry:** `RemoteLog` → ntfy (`Services/RemoteLog.swift`), OFF by default, isolated as a live
  debug channel. **Must be deleted before any wider release** — checklist in
  `docs/OPTIMIZATION_PLAN_2026-06-30.md` §5.

---

## 8. Release history quick-reference

- `ef9e591` background-session switch → -3000 regression → reverted in `22f6740`.
- v1.0.101: Downloads M1 (8-connection engine + screen), downloaded-only filter, offline sprites.
- v1.0.105–106: on-device transcode (AVFoundation, presets, card UI).
- v1.0.107: single-connection background continuation with foreground handoff (`b8ea21d`).
- Also shipped in the big handoff session: scene ratings + performer/tag favorites (`LibraryEdits`),
  Apple-Photos-style image viewer, portrait-fullscreen tab-bar fix, popover stable-anchor fix,
  private Application Support storage migration, network-loss recovery ("Waiting for network…" +
  bounded auto-retry), replay-after-end + time-over-duration fixes.
