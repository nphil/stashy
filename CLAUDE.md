# CLAUDE.md — Stashy engineering handoff

You are Claude, continuing work on **Stashy**. This file is the durable brain-dump from the previous
model's sessions: hard-won facts, non-obvious decisions, and the traps that already bit us. Read it fully
before touching code. Then skim the companion docs referenced in **§10**.

---

## 1. What Stashy is
A native **iOS 26 SwiftUI** app (Liquid Glass aesthetic) that is a client for a self-hosted **Stash**
media server (`https://github.com/stashapp/stash`). Sideloaded via **Feather/AltStore** onto an iPhone
17 Pro (no App Store, unsigned IPA). Core tenets, in priority order: **fast, responsive playback +
scrubbing → direct-play first → on-device FFmpeg only as a fallback → minimal load on the server →
privacy.** The owner (Nitin) is on Windows, so **there is no local Mac** — every build runs in CI.

Repo: `nphil/stashy` (this is the ONLY repo you may read/write — GitHub access is scoped to it).
The iOS app lives under `ios/Stashy/`. There's an empty `android/` (later).

---

## 2. The build/release loop — READ THIS, it will save you hours

**CI is the only compiler.** You cannot build locally (no Mac, FFmpeg only links in CI). The workflow is
`.github/workflows/ios-build.yml`, runs on `macos-15`, triggered on every push to `main`.

### The single most important gotcha
The **"Build (unsigned)" step pipes xcodebuild through `| xcpretty || true`, which SWALLOWS the exit
code.** A compile or link error does **NOT** fail that step — it shows ✅ green. The failure is only
caught by the later **"Package into IPA"** step, which checks the `.app` actually contains a non-empty
executable and exits 1 if not (`"App executable 'Stashy' missing/empty — the build failed"`).

**Consequences you must internalize:**
- "Build step green" ≠ "it compiled." Only a **published release** (or the Package step passing) proves
  a successful compile.
- On a compile failure, **no release is published**, so the previously-installed IPA keeps working. A
  broken push is low-blast-radius: it just means no new build until you fix it.
- To read a real compile error: `get_job_logs` (GitHub MCP) with `return_content:true`,
  `tail_lines: ~230`. The Swift `error:` lines appear just before the "Package into IPA" script echo. Look
  for `❌ .../File.swift:LINE:COL: <message>` and `** BUILD FAILED **`.

### Verifying a build (standing rule from the owner)
After every push, **verify the actual published IPA byte size** via `get_latest_release` on `nphil/stashy`.
A byte-size *change* confirms your new code actually shipped (not a cached/no-op build). Report the size.
Recent sizes for calibration: v1.0.100 ≈ 7.63 MB, v1.0.106 ≈ 7.73 MB (grows as features land; FFmpeg is
statically linked and dead-stripped to what's called, so size creeps up with usage).

### CI auto-versioning — you MUST rebase before pushing
On a successful build, CI **commits a version bump to `main` with `[skip ci]`** and publishes a tagged
GitHub Release with the IPA asset. This means `origin/main` moves without you. **Always
`git fetch origin main && git rebase origin/main` before `git push`**, or the push is rejected. The
established push sequence (works reliably):
```
git add <specific files>
git commit -F - <<'EOF' ... EOF
git fetch origin main -q && git rebase origin/main && git push -u origin main
```

### XcodeGen
The Xcode project is generated in CI from `ios/project.yml` (XcodeGen), which **globs the `Stashy/`
directory**. New `.swift` files are auto-included — never hand-edit a `.pbxproj`. Deployment target iOS
26, Swift 6, `SWIFT_STRICT_CONCURRENCY: complete`, `VALIDATE_PRODUCT: NO` (unsigned IPA, FFmpeg
frameworks have underscored bundle ids the CI script patches).

### Checking CI from here
GitHub MCP tools (`mcp__github__*`). `actions_list`/`list_workflow_runs` returns huge JSON that exceeds
the tool token cap — it gets saved to a file; parse it with a short `python3 -c` reading the saved path
(`workflow_runs[i]` → `id,status,conclusion,head_sha,display_title`). `get_workflow_run` for one run is
fine. The GitHub MCP **token can expire mid-session** ("requires re-authorization"); `git push` still
works (separate proxy), so keep committing and ask the owner to re-auth the connector to read CI again.

---

## 3. Standing rules from the owner (do not violate)
- **Commit/push to `main`.** (There's boilerplate elsewhere about a `claude/…` feature branch; the
  owner's actual workflow this whole project has been direct-to-`main`, because CI builds/releases from
  `main`. The release `target_commitish` may show that branch name — ignore it; builds come from `main`
  HEAD.)
- **Every commit ends with these two trailers:**
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_019GbW6mvDp5D1A3xeyLYF4U
  ```
- **NEVER put a raw model identifier (the lowercase-hyphenated API model ID, e.g. `claude-<family>-<ver>`)
  in any artifact** — commits, PR text, code, comments, or these docs. Chat replies only. (The
  `Co-Authored-By: Claude Opus 4.8` trailer uses the marketing name and is the one sanctioned exception.)
- **GitHub scope = `nphil/stashy` only.** Don't read/search other repos.
- **Telemetry must be removed before any wider release.** `RemoteLog` → ntfy (`Services/RemoteLog.swift`)
  is OFF by default and isolated, kept as a live debug channel. Deletion checklist is in
  `docs/OPTIMIZATION_PLAN_2026-06-30.md` §5. This is the one intentionally-open tech-debt item.
- Don't open PRs unless asked. Don't `sleep` to wait on CI — use `get_workflow_run` polling / scheduled
  wakeups.

---

## 4. Swift 6 strict-concurrency — the patterns that actually compile
`SWIFT_STRICT_CONCURRENCY: complete` is on. Most build failures this project hit were concurrency, not
logic. Hard-learned rules:

- **`@Observable @MainActor final class` is implicitly `Sendable`.** You can capture such instances
  (incl. `self`, and model objects like `DownloadItem`) into `@Sendable` closures. Good.
- **`"reference to captured var 'self' in concurrently-executing code"`** — the classic. Happens when you
  `[weak self]` (which makes `self` an optional *var* binding) and then a *nested* `@Sendable`/concurrent
  closure references `self` again. **Fix:** don't re-capture `self` in the inner closure — capture the
  specific Sendable object you need directly. Example that bit us: a transcode progress callback did
  `Task { @MainActor [weak self] in self?.items.first... }` inside another `[weak self]` Task → error.
  Fixed by capturing the `DownloadItem` directly: `{ p in Task { @MainActor in item.transcodeProgress = p } }`.
- **Non-Sendable Apple objects across a boundary** (`URLSessionTask`, `AVAssetWriterInput`,
  `AVAssetReaderTrackOutput`): wrap in a tiny `struct Box<T>: @unchecked Sendable { let value: T }` when you
  must hand them to `@Sendable` closures (e.g. `getAllTasks`'s completion, `requestMediaDataWhenReady`).
  Both `DownloadManager` and `VideoTranscoder` define such a box.
- **`Task { @MainActor in … }`** created inside a `@MainActor` method: calls to other `@MainActor` methods
  from inside are same-actor → **no `await`** (and you'll get a "no async operations occur within await"
  warning if you add one). But you still need explicit `self.` for escaping-closure captures.
- **`try?` flattens nested optionals (SE-0230).** `try? url.resourceValues(forKeys:).fileSize` is `Int?`,
  NOT `Int??`. Don't write `?? 0 ?? 0`.
- **`NotificationCenter.addObserver(forName:…, queue: .main, using:)`** block is `@Sendable`. To call a
  `@MainActor` method from it synchronously, use `MainActor.assumeIsolated { self?.foo() }` (safe because
  `queue: .main` runs on the main thread). `Task { @MainActor in }` also works but defers a runloop tick —
  use `assumeIsolated` when you need to act *before* suspension (app-phase handoff).

---

## 5. Downloads subsystem — the most intricate part (`Services/DownloadManager.swift`)
This is where the sharpest edges are. It went through a shipped regression; understand it before editing.

### Architecture
- `DownloadManager` (`@Observable @MainActor`) owns `[DownloadItem]`. Each download is **8 parallel HTTP
  range requests** (`Range: bytes=lo-hi`) via `URLSessionDownloadTask`, each writing a **part file**;
  parts are concatenated (`merge`) on completion. Single connection if the server didn't report a size.
- **`DownloadDelegate` is a SEPARATE `NSObject` class**, not the manager, because `@Observable` +
  `NSObject` conflict. It runs on a background delegate queue, does the synchronous part-file move there,
  and forwards structural events to the `@MainActor` manager via `@Sendable` closures. High-frequency
  byte progress goes to a lock-guarded `TransferStore` (never hops the actor per byte); a **120 ms
  MainActor poll loop** reads the store and updates the observable UI.

### THE -3000 LANDMINE (a shipped regression — do not repeat)
A **background `URLSession` (`URLSessionConfiguration.background`) cannot run 8 PARALLEL range (206
partial-content) tasks** — the out-of-process `nsurlsessiond` daemon returns
**`NSURLErrorCannotCreateFile` (-3000)** on every connection ("cannot create file" on the card). A commit
that switched the whole engine to a background session broke all downloads and had to be reverted. **A
single background range task at a time is fine** (that's the normal supported case).

### Current design (as of v1.0.10x, commit b8ea21d): dual-engine handoff
- **Foreground:** 8-way parallel on `session` (`URLSessionConfiguration.default`). Fast. **Sacred — do
  not break this path.** If you touch downloads, keep the foreground path working; it's the fallback for
  everything.
- **Background:** when the app backgrounds (`UIApplication.didEnterBackgroundNotification`), active
  downloads **hand off** to `bgSession` (a background `URLSession`, `sessionSendsLaunchEvents = true`)
  running **one connection at a time**. `connectionFinished` chains the next unfinished part. On
  `willEnterForegroundNotification` it hands back to 8-way parallel.
- **Handoff mechanics:** cancel in-flight tasks with `cancel(byProducingResumeData:)`; because resume
  data arrives *asynchronously*, a per-item `pendingHandoff` counter waits for all blobs before starting
  on the target engine. Part files + per-connection resume data are preserved both directions → **no
  progress lost**. A short `beginBackgroundTask` assertion covers the handoff so the bg task starts before
  suspension.
- **`inBackground` flag** is initialized from `UIApplication.shared.applicationState` (so a cold
  background relaunch behaves), and flipped by the two notifications.
- **`taskDescription`** on every task encodes `"<itemID>\u{1}<conn>\u{1}<partPath>"` so that after a cold
  background relaunch (empty in-memory store) the delegate can still route a finished file. `reconnectTasks`
  queries **both** sessions' `getAllTasks` on launch.
- **`.active` marker files** (in the meta dir) distinguish an active/resumable download from a stopped one
  so `loadInterrupted` only resurrects the right ones after relaunch.
- ⚠️ **UNVERIFIED ON DEVICE:** that a *single* bg range task doesn't also -3000 (very likely fine), and the
  whole suspend→continue→relaunch flow. The owner tests each build on device. If single-bg -3000s, fall
  back to leaving downloads paused-on-background (foreground still works).

### Storage & privacy
- Downloaded video + sidecars live in **`Application Support/Stashy/{Downloads,DownloadsMeta}`** — private
  to the app (NOT visible in the Files app / other apps, unlike `Documents` which file-sharing can
  expose), **excluded from iCloud/iTunes backup**, migrated from the old `Documents` location. **Part
  files are in Caches** (transient). Do not move downloads back to Documents.
- Each download writes a **sidecar**: `<id>.json` (the full `StashScene` + apiKey, `Codable`), plus
  `<id>-thumb.jpg`, `<id>-sprite.jpg`, `<id>.vtt`. These power the offline card, offline playback, and
  **offline scrub sprites**. `StashScene` and all its nested types are fully `Codable` — keep them that way.
- Accessors the rest of the app relies on: `localFile(sceneID:)`, `localSprite(sceneID:)`,
  `localVTT(sceneID:)`, `hasDownload(sceneID:)`.

### Encryption (roadmap, not built)
Owner wants an opt-in "encrypt downloads." Options in `ROADMAP.md` Downloads section: raise Data
Protection class to `.complete`, or app-level AES-GCM (CryptoKit + Keychain key) decrypted via an
`AVAssetResourceLoaderDelegate`. Not started.

---

## 6. On-device transcode (`Services/VideoTranscoder.swift`)
- Uses **`AVAssetReader` → `AVAssetWriter`** (native, hardware VideoToolbox), **NOT FFmpeg** — chosen for
  robustness (handles audio re-encode, no untestable C interop, can't crash the app). Presets:
  resolution (Original/2160/1080/720/480), quality (Low/Med/High bitrate ladder), codec (HEVC default /
  H.264). Produces a faststart MP4, **replaces the offline file in place**, updates the item's spec chips.
- **Limitation:** only works on inputs AVFoundation can decode (H.264/HEVC in mp4/mov). **MKV/WebM/VP9/AV1
  will throw `.unreadable`.** FFmpeg-based transcode for those exotic containers is a documented
  follow-up (the FFmpeg remux path already exists for playback — see §7).
- **AV1 encode is impossible with the current FFmpeg build** (LGPL-minimal: videotoolbox H.264/HEVC + AAC
  only). Deferred; would need rebuilding the FFmpeg XCFrameworks with libaom/SVT-AV1. See the standalone
  FFmpeg build brief (owner has it; it's about the `stashy-videoengine` package).
- UI: wand-and-stars button on a completed download card → `TranscodePresetSheet` → `downloads.transcode`.
  Progress shows on the card (accent bar + "Transcoding… NN%") with cancel.

---

## 7. Playback pipeline (see `docs/ROADMAP.md` for full detail)
- **Routing:** direct-play H.264-in-mp4/mov/m4v (native HW decode, instant seeks) → **on-device linear
  remux over loopback HLS** for HEVC / foreign-container H.264 (MKV etc.) → Stash server HLS for anything
  Apple can't decode.
- **FFmpeg** comes from the SPM package **`nphil/stashy-videoengine`** (product `FFmpeg`; Swift modules
  `Libavformat`, `Libavcodec`, `Libavutil`, …). It's **LGPL-minimal + VideoToolbox**: broad decoders
  (h264/hevc/vp9/av1/…), demuxers (matroska/mov/…), but **encoders only h264_videotoolbox /
  hevc_videotoolbox / aac**. The app **only links** it; CI never compiles FFmpeg. It's pinned in
  `ios/project.yml` via SPM (`from: "1.0.0"`, currently resolving ~1.2.0). **To change FFmpeg
  capabilities** (add AV1 encode via libaom/SVT-AV1, add libdav1d for faster AV1 decode, etc.) you rebuild
  and publish a new `stashy-videoengine` release, then bump the version constraint — the app side is just
  a link. That's a separate macOS-CI project (build brief lives with the owner).
- Key files: `FFmpegRemuxer.swift` (custom AVIO read/write, demux→fMP4 stream-copy, `frag_keyframe+
  empty_moov`, 4 MB read-ahead, playhead pacing, seek-by-reinit), `FMP4Index.swift` (walks growing fMP4 →
  HLS byte-range playlist), `LoopbackServer.swift`, `LocalRemuxStream.swift`, `FFmpegSource.swift`.
- Player: `PlaybackEngine` protocol, `AVPlaybackEngine` (has `onEnded` via
  `.AVPlayerItemDidPlayToEndTime`, route-based mute default), `ScenePlayerModel` (facade;
  `reachedEnd`/replay-from-0, time clamped to duration), `ScenePlayerView` (sprite `.task` prefers local
  downloaded sprite/VTT), `PlayerControlsView`, `ZoomablePlayerSurface`, live Metal blur backdrop.
- **Sprite scrubbing:** `SpriteThumbnails` parses WebVTT + crops a sprite sheet (no decode = instant). It
  accepts `file://` URLs (URLSession + ImageCache handle them), which is how offline sprites work.

---

## 8. UI / library patterns & the popover saga
- **SwiftUI `.popover` gets torn down & re-presented whenever its host view's structural identity
  churns.** This bit us THREE times on the filter/sort panel:
  1. Hosted on a `.toolbar` ToolbarItem → rebuilt on every `isActive` change → flicker.
  2. Moved to `.overlay` on the list `content` — but `content` is a `@ViewBuilder` that flips
     `_ConditionalContent` branches (grid ⇄ full-screen spinner ⇄ empty state) every time
     `PaginatedLoader.reload()` clears `items` (it sets `items=[]` + `isLoading=true` synchronously). A
     branch flip tears down the overlay's host → popover closes & reopens ("tap a tag → window
     closes/reopens").
  3. **FIX (final):** host the popover from a **stable `ZStack` sibling** of `content`
     (`FilterPopoverAnchor` in `Features/Library/ImmersiveFilter.swift`), a peer whose identity is
     independent of `content`'s branch. Used in both `ScenesView` and `PerformersView`. **If you add
     another filtered list, reuse this pattern; never host a popover on a conditional/churning view.**
- **`PaginatedLoader<T>`** (generic, `@Observable @MainActor`): dedups pages by id, infinite-scrolls, and
  has a **generation token** so a superseded in-flight load discards its results (prevents a crash under
  the open popover from rapid filter changes). View-level 250 ms debounce on query changes on top.
- **`LibraryEdits`** (`@Observable @MainActor`, app-wide via environment): optimistic overrides for
  rating/favorite/delete keyed by id (`Int??` for nullable ratings), `visible()` filters deleted. Read
  ratings/favorites THROUGH this store so edits reflect instantly across screens.
- **`StashClient`** has DB-lock retry (Stash is SQLite; "database is locked" → back off 500/1000/1500ms).
  `SceneQuery` gained `downloadedOnly` (served from `downloads.items` locally, bypassing the network).
- Filters reset on launch; **sort field+direction persist** (UserDefaults). Blur toggles for
  thumbnails/titles. Face ID is immediate (minimal privacy blur, no splash). Videos start muted unless on
  AirPods/private audio route.
- `ImageCache` (actor): 2-tier (NSCache + downsampled JPEG on disk), LRU-evicted, priority tier for
  performer portraits (kept longest). Keys strip the `apikey` query param.

---

## 9. Current state (end of the handoff session)
- Latest green release: **v1.0.106** (transcode). Commit **b8ea21d** (background download handoff) was
  pushed and compiling at handoff — **verify it went green** (`get_latest_release`; a byte bump past
  v1.0.106 ≈ 7.73 MB means it shipped). If it failed, `get_job_logs` and fix.
- **Shipped this session:** Stash parity (scene ratings, performer/tag favorites via LibraryEdits);
  Apple-Photos-style image viewer; portrait-fullscreen tab-bar fix; **native popover filter + the stable
  ZStack anchor fix**; downloaded-only scenes filter; **Downloads** M1 (engine + screen) → card redesign
  (performer name + 36pt thumb, centered scene thumb) → offline sprites → private Application Support
  storage → **on-device transcode** → **single-connection background continuation**; network-loss recovery
  (transient errors → "Waiting for network…" + bounded auto-retry, no truncated NSError); replay-after-end
  + time-over-duration fixes.
- **Things to verify on device** (owner tests each build): background download actually continues while
  suspended and finishes; single bg range task doesn't -3000; transcode output plays and is smaller;
  offline sprites scrub; downloads don't appear in the Files app.

---

## 10. Companion docs — read these next
- **`docs/ROADMAP.md`** — the master roadmap: playback pipeline detail, scrubbing/seeking plans,
  **watch-heat "most replayed" overlay** (owner wants this), **XR-glasses "phone becomes the remote"**
  (owner wants this; feasible iPhone 15+), AI upscaling, instant-start preview, comparative-study features
  from `1letzgo/stashy` (Studios/Galleries/Images, StashTok/Reels, multi-server, 401 handling, on-device
  Vision analysis), library/UX redesign incl. **navigation/"back" model cleanup** (owner flagged it's
  confusing deep in menus), Stash parity (O-counter, markers, metadata scrape), privacy (app-switcher blur),
  downloads/offline incl. **encrypt-downloads**.
- **`docs/OUTSTANDING_2026-07-01.md`** — a consolidated, prioritized punch list snapshot (near-term →
  deferred). Good "what should I do next" starting point; reconcile it with what's since shipped.
- **`docs/DOWNLOADS_PLAN_2026-07-01.md`** — the downloads design + M1/M2/M3 milestones and the iOS
  constraints (background session limits, Live Activity needs a Widget Extension target, AV1 constraint).
- **`docs/OPTIMIZATION_PLAN_2026-06-30.md`** — the (completed) perf pass, and **§5 = the telemetry
  removal checklist** for release.

### Not yet built that the owner has explicitly asked about
- **Live Activity / Dynamic Island for downloads** — needs a **new Widget Extension target** in
  `ios/project.yml` (ActivityKit + `NSSupportsLiveActivities`). This is the riskiest remaining downloads
  item because it changes the IPA structure for a *sideloaded* app; isolate it in its own commit so it's
  revertable if it breaks packaging/install.
- **Encrypt downloads**, **watch-heat overlay**, **XR-glasses mode**, **navigation/back cleanup** — all in
  ROADMAP.

---

## 11. How to work here (meta)
- **Keep commits small and single-purpose.** The one time a big multi-feature blob went in, it shipped the
  -3000 download regression. Small commits = the byte-size/Package gate isolates failures.
- **The foreground download path and basic playback are load-bearing.** Don't refactor them casually; the
  owner uses this app daily.
- You cannot run the app. Reason hard about compile correctness (esp. concurrency, §4) before pushing —
  each CI round-trip is ~1–2 min and a swallowed-exit-code failure is easy to miss. After pushing: confirm
  the run's **conclusion** AND that a **new release with a changed byte size** appeared.
- Update these docs as you go so the *next* model inherits the same context. This file is the entry point;
  the owner will point the new model at it.

---

## 12. Smaller facts that will still trip you up
- **`AppDelegate` lives in `Services/OrientationLock.swift`** (surprising location). It handles: the
  interface-orientation lock (whole app is portrait; only fullscreen video allows landscape via
  `OrientationController.lock`), the **background-URLSession completion handler**
  (`handleEventsForBackgroundURLSession` → stores into `BackgroundDownloadSession.completionHandler`, which
  `DownloadDelegate.urlSessionDidFinishEvents` calls), the audio-session category, `RemoteLog` enable, and
  a stale-temp-file sweep. Wired via `@UIApplicationDelegateAdaptor` in `StashyApp.swift`.
- **Rating scale:** Stash stores ratings as **0–100 (`rating100`)**. The UI shows **0–5 stars = value/20**.
  Favorites are plain booleans. Don't confuse the two scales.
- **Stash auth:** append **`?apikey=<key>`** to media/image/sprite/vtt URLs; GraphQL uses the `ApiKey`
  header. `StashClient` holds `serverURL` + `apiKey`; both persist in the **Keychain**
  (`KeychainService`); `AppState` (in `StashyApp.swift`) owns the client and drives login/logout. URL
  helpers on `StashScene`/`Performer` (`directFileURL`, `thumbnailURL`, `spriteURL`, `vttURL`, `imageURL`)
  all take `apiKey:`.
- **Never hand-edit versions or `apps.json`.** CI's "Update version in source files" step bumps
  `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`/`CFBundleShortVersionString` in `ios/project.yml`, and
  updates root **`apps.json`** (the Feather/AltStore source manifest the owner's sideloader reads). These
  are CI-owned.
- **`DownloadState` is switched exhaustively** in `DownloadsView`'s `controls`/`statusText`/`statusColor`.
  Adding a case means updating those switches. (Transcode progress deliberately rides on
  `item.transcoding`/`transcodeProgress` bools instead of a new state, to avoid touching the download
  state machine.)
- **The owner is exacting about UI feel.** Repeated asks this project: native iOS animation *physics/
  inertia* (not approximations), custom **glass** filter chips that still look native, Apple-Photos-app
  gesture/zoom parity, "don't make the card >20% bigger," "center it vertically." When building UI, match
  that bar and expect iteration — ship something responsive and polished, not just functional.
- **`FlowLayout`** (custom `Layout`) is used for chip rows; **`PopupMenu`**/native `Menu` for the 3-dot
  actions; **`glassEffect(...)`** for Liquid-Glass chips. `ThemeManager` (`@Observable`, env-injected)
  exposes `accentColor/foregroundColor/backgroundColor/surfaceColor/preferredColorScheme`.
- **Navigation** is per-tab `NavigationStack` with a `[Route]` path + `AppRouter` (`Route` enum,
  `RouteDestination` switch, `.downloads` route). Cross-screen jumps (e.g. tag tap → filter scenes) go
  through `router`. The owner wants this model rationalized (see the nav-cleanup roadmap item) — a good
  place to be careful, since `fullScreenCover`/`sheet`/push are currently a bit ad hoc.
