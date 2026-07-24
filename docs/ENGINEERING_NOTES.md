# Stashy engineering notes — deep reference

Companion to the root `CLAUDE.md` (the lean entry point). This file holds the hard-won detail:
**read the relevant section before touching that subsystem**, and update it as you learn. Everything
here was verified against the repo on 2026-07-01; full re-audit against code + git history 2026-07-16.

---

## 1. Build / CI detail

Workflow: `.github/workflows/ios-build.yml`, runs on `macos-15`, triggered on every push to `main`.
`paths-ignore` skips `**/*.md`, `android/**`, `stash-plugin/**`, and `.github/workflows/android.yml` —
doc-only AND plugin-only commits do **not** trigger an app build.

### Fail-fast compile errors (since `f243d30`, 2026-07-08)
The "Build (unsigned)" step tees raw xcodebuild output to `xcodebuild.log` (xcpretty is cosmetic only)
and deliberately tolerates the pipeline's exit code (a framework-validation false-positive). It then
greps the log for the precise `<path>:<line>:<col>: error:` diagnostic pattern — on any hit it prints
the deduped errors up front, emits GitHub `::error file=…,line=…,col=…` inline annotations for `.swift`
diagnostics, and exits 1 **at the Build step**. A red Build step with annotations = compile failure,
already surfaced — no log digging. (The old `| xcpretty || true` swallowed-exit-code trap, where a
compile error showed green until the Package step, is gone.)

Still true:
- On a failed run **no release is published**, so the previously-installed IPA keeps working — a broken
  push is low-blast-radius; only a published release fully proves a push out.
- A pure **linker** error (no `line:col` diagnostic — rare) still passes the grep; it's caught by the
  Package step's executable-present check + ~1 MB IPA-size floor. For those, read logs the old way:
  `get_job_logs` (`return_content:true`, `tail_lines: ~230`), look for `** BUILD FAILED **`.

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

### Companion (server-side) transcode source + VMAF
- `Services/StashCompanion.swift` is the one typed app↔plugin gateway (`runPluginTask` / `findJob` /
  `custom_fields` / `TranscodeResult`). Downloads staging has a third source **Companion** (server GPU
  HEVC / CPU AV1 + resolution + quality): a **`.serverProcessing`** DownloadState drives a *determinate*
  bar from polled `Job.progress`, then hands the finished served file to the normal (Range-capable,
  8-way) byte engine — the load-bearing transfer path is untouched. One combined poll reads `findJob` +
  the scene's `custom_fields.stashy_transcode`, so completion survives an app kill or Stash GC'ing the Job.
- **VMAF quality targeting (plugin v0.2.x, 2026-07-14):** the plugin binary-searches the encoder quality
  knob on short sample windows to hit a phone-model VMAF target (High 97 / Balanced 94 / Small 91).
  During the search it writes a progress fraction to its served progress file (stage `analyzing`) — the
  app shows **"Analyzing quality — X%"** via `item.analyzing` and **skips the Job.progress clobber while
  analyzing** (Job.progress reads 0 during analysis; writing it made the bar visibly bounce — `ba7c65a`).
- Result fields `cq`/`vmaf`/`vmaf_target` come back in `custom_fields` (`TranscodeResult`); `item.vmaf`
  renders a "VMAF NN" chip in `DownloadsView`, and the finish log appends before→after size + % reduction
  and `VMAF: target → achieved · cq` (`f1b008a`, v1.0.252). Achieved sits at/just above target by
  CRF-step granularity — expected, not a mismatch.
- **v0.3.0 VMAF CRF map:** "Compute VMAF Map" / "Rebuild VMAF Map (full)" plugin tasks pre-compute
  per-scene optimal CRF (+ the sampled curve) per resolution into served `cache/vmaf-map.json` —
  incremental, resumable (per-run `vmafMapBudgetMin` time budget), zero scene writes. `run_transcode`
  looks up the cached CRF and skips the ~30 s live analysis; `_crf_from_curve` derives all presets from
  the one stored curve. Full detail: `stash-plugin/README.md` + ROADMAP §encode-quality.

### Follow-ups
- **Encryption (roadmap, not built):** opt-in "encrypt downloads" — Data Protection `.complete`, or
  app-level AES-GCM (CryptoKit + Keychain) decrypted via `AVAssetResourceLoaderDelegate`. See ROADMAP.
- **Live Activity / Dynamic Island** needs a **Widget Extension target** in `ios/project.yml`
  (ActivityKit + `NSSupportsLiveActivities`). **Riskiest remaining downloads item** — it changes the
  IPA structure for a *sideloaded* app; isolate in its own commit so it's revertable.

---

## 4. On-device download transcode — three engines, FFmpeg-first

`DownloadManager.transcode()` (~line 987–1029) routes each job across three engines (all conform to
`OnDeviceTranscoder`, declared in `VideoTranscoder.swift`):

- **Lossless stream copy** — same codec + same-or-smaller target size → `FFmpegTranscoder` remux-only
  fast path (incl. hev1→hvc1 retag). Near-instant.
- **Short clips (< 90 s)** — `VideoTranscoder` (`AVAssetReader` → `AVAssetWriter`, hardware
  VideoToolbox) when the container is AV-native AND the codec is H.264; otherwise `FFmpegTranscoder`
  (universal FFmpeg decode → VideoToolbox encode, commit `151e707`). **MKV/WebM/VP9/AV1 no longer throw
  `.unreadable`** — the old AVFoundation-only limitation is gone.
- **Long re-encodes (everything else)** → `FFmpegResumableTranscoder(workDir:)`
  (`f421ecd`/`d3c0108`/`960ac90`, 2026-07-04): checkpointed keyframe-aligned standalone chunk MP4s
  (`chunk_NNNN.mp4`, atomic-rename commit, `plan.json` + `settings.json` so even a cold relaunch
  resumes from the last committed chunk), finalized by a stream-copy concat remux with single-pass
  audio. **Deliberately chosen over single-file fragmented-MP4 append** (see the file header).
- Presets: resolution (Original/2160/1080/720/480) × quality (Low/Med/High bitrate ladder) × codec
  (HEVC default / H.264). Produces a faststart MP4, **replaces the offline file in place**, updates the
  item's spec chips.
- **AV1 encode is impossible on-device** (LGPL-minimal FFmpeg: videotoolbox H.264/HEVC + AAC encoders
  only — §5). AV1-encoded *downloads* DO exist via the server path: the Companion plugin's SVT-AV1 (§3).
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

### The popover saga (bit us FIVE times)
**SwiftUI `.popover` is torn down & re-presented whenever its host view's structural identity
churns.** History on the filter/sort panel:
1. Hosted on a `.toolbar` ToolbarItem → rebuilt on every `isActive` change → flicker.
2. Moved to `.overlay` on the list `content` — but `content` is a `@ViewBuilder` that flips
   `_ConditionalContent` branches (grid ⇄ spinner ⇄ empty). A branch flip tears down the overlay's
   host → popover closes & reopens. (`PaginatedLoader.reload()` now keeps the old page visible and
   atomically replaces it, but the host still must not depend on list state.)
3. **Stable-host fix:** host from a **stable `ZStack` sibling** of `content` —
   `LibraryDropdownPanel` in `DesignSystem`, used in `ScenesView` and `PerformersView`. **Reuse this
   pattern for any new filtered list; never host a popover/dropdown on a conditional/churning view.**
4. **Tap-through + navigation race (v1.0.284):** the old `simultaneousGesture(TapGesture)` dismissed
   the dropdown while the card beneath handled the *same tap*. After a tag change, that could push an
   old card just before the debounced reload replaced the grid, occasionally stranding the detail
   screen's hidden navigation-bar preference on the root.
   `dismissesPopover` now installs a high-priority tap only while open (first outside tap dismisses
   only; drags still scroll+dismiss). `ScenesView` also gates `openScene` until the current query reload
   completes, and explicitly owns a visible system navigation bar plus a real `navigationTitle`.
5. **Whole-grid identity flicker (2026-07-20 perf pass):** `PopoverDismissalModifier.body` used an
   `if isPresented` around `content`, changing the structural type that wrapped the entire grid every
   time a dropdown opened or closed. Keep the modifier chain **unconditional**; disable its tap with
   `GestureMask.none` while closed. Scroll dismissal uses a transaction with animations disabled so the
   glass sheet is gone in the first moving frame. `InlineTagEditor` also renders its synchronous ranking
   cache on frame one and uses solid chips — no delayed panel resize and no nested glass samplers.
- **Scenes/Performers title parity:** both interactive jobs titles live in `.topBarLeading` and drive the
   same stable top-leading `LibraryDropdownPanel` spring. Scenes retains its real
   `.navigationTitle("Scenes")` for navigation-bar ownership, but a stable zero-size `.principal` item
   suppresses duplicate centered title chrome. Do not move the trigger back into `.principal`; it makes
   Scenes feel unlike Performers. This is toolbar-only and does not wrap or invalidate the grid.

### Jobs panel (`JobsPanel` + `JobMonitor`) — the scan-progress bug (fixed v1.0.296)
- **Stash's `jobQueue` is a nullable list (`[Job!]`) and its Go resolver returns a nil slice for an
  EMPTY queue — the wire value for "no jobs" is `null`, NOT `[]`.** `StashClient.jobQueue()` decodes the
  field optionally and maps nil → `[]`. The original non-optional decode made every idle-queue poll a
  decode failure: the panel froze its last snapshot on screen (a scan "stuck" at its last %) and after
  ~60 s of failures the monitor silently killed its own poll loop (tapping Scan then painted the bar
  once via `refreshNow` and it never moved again). On the `Job` type only `id`/`status`/`description`/
  `addTime` are non-null — keep any newly-queried field optional in `JobInfo`.
- `JobMonitor.attach()/detach()` is **refcounted**: a rapid dropdown close→reopen can deliver the dying
  panel instance's `onDisappear` AFTER the replacement's `onAppear`, and a plain start/stop pair let
  that late stop kill polling for the panel still on screen. The poll loop also **never self-stops**:
  ≥3 consecutive failures clear the stale snapshot (a frozen bar reads as a stuck job), flip
  `pollFailing` (panel shows "Can't reach Stash — retrying…"), and slow the cadence 1.5 s → 4 s until
  the last panel detaches. A cancellation mid-request (detach) is not counted as a failure, so the
  kept-for-instant-reopen snapshot survives.
- Queue actions surface `actionError` inline (plugin missing / auth / network) and show an optimistic
  "Starting …" line with a 3-poll grace instead of `try?`-swallowing failures.
- The four task buttons are compact caption2 icon+name chips in a `FlowLayout` (two short rows) under a
  "Library tasks" caption — solid fills on the glass panel, matching the filter panel's tag chips.

### Metadata scrape/edit suite (v1.0.298)
- **`Services/StashScraper.swift` is the ONE typed gateway** for scraping + metadata editing (wraps
  StashClient like StashCompanion does). Contracts verified against stashapp/stash master — do NOT
  guess: `ScraperSourceInput` takes **exactly one** of `scraper_id` / `stash_box_endpoint`;
  `scrapeSingle*` return non-null lists (`[]` = no match); ALL `Scraped*` fields are nullable except
  `ScrapedStudio.name`/`ScrapedTag.name`; `stored_id` = the matched LOCAL entity (nil = not in the
  library); scraped `image`/`images[]` are **base64 data URLs** (the server already fetched them) and
  the `cover_image`/`image` mutation fields accept "URL or base64 data URL" — pass through unchanged;
  update inputs are **omit-to-keep** (nil optionals encode away) while list fields (`performer_ids` /
  `tag_ids` / `urls` / `stash_ids`) REPLACE wholesale; classic performer scrapers are **two-step**
  (query → re-scrape the picked result as `performer_input`, which accepts no images/tags) while
  stash-box results arrive complete; gender strings normalize case-insensitively to GenderEnum or are
  DROPPED (an invalid enum literal fails GraphQL validation).
- **Sheets** (`SceneMetadataSheet`, `PerformerMetadataSheet`, `PerformerCreateSheet`; shared pieces in
  `Features/Shared/ScrapeUI.swift` + `Features/Performers/PerformerForm.swift`): medium-detent system
  sheets (`presentationDetents([.medium, .large])` +
  `presentationBackgroundInteraction(.enabled(upThrough: .medium))`) — the iOS 26 glass "mini window"
  over the still-playing video. System-composited, so the custom-glass-over-scroll landmine doesn't
  apply. Merge rules mirror Stash's web UI: non-empty scalars win, entities join by `stored_id`,
  unmatched ones render as dashed "+" chips (tap → `tagCreate`/`studioCreate`/`performerCreate` with
  the full scraped profile, created id swapped in); anything left dashed is dropped on Save and a
  caption says so. **Empty dates are OMITTED, never sent** ("" is an invalid Stash date; clearing a
  date isn't supported in-app). Refresh-in-place after Save: SceneDetailView reads `shown =
  fullScene ?? scene`, PerformerDetailView reads `current = refreshed ?? performer`, and the portrait
  task keys on `image_path` (not id) so a changed photo reloads.

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
  performer portraits (kept longest). Cache keys strip the `apikey` query param. Ahead-of-scroll work
  goes through a **48-request deduplicated queue with two workers**; never restore the former
  task-per-URL fan-out from every appearing cell. The persistent tier is 800 MB. The decoded-memory
  budget adapts to physical RAM (128–256 MB), and the decoded ThumbHash cache holds up to 20,000 entries
  under a separate 64 MB cost cap.
- Settings measures "Cached previews & images" when it opens and once on
  `ThumbnailPrefetcher.completionRevision`. That revision advances only after a Cache All Thumbnails run
  has fully unwound (success or cancellation), so the displayed bytes include the final settled image
  write without polling progress or scanning cache directories during the job. Cancellation keeps
  `isRunning` true until that terminal point, preventing an old cancelled run from clobbering a new one.
- Companion served-map stores (`PlayabilityStore`, `VmafMapStore`, `LoudnessStore`, `ThumbHashStore`)
  fetch on their main-actor owners but decode JSON/base64 in utility detached tasks, then publish the
  completed Sendable value on main. A large library map must never parse during a scrolling frame.

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

### UI/UX overhaul (v1.0.253–265) — design system, mesh background, motion, glass discipline
A cohesive iOS-26 pass over the **browse** surfaces (the fullscreen player rework is deferred). **Read this
before touching theme, backgrounds, chips, or grid→detail transitions.** Owner asks (all shipped): lean on
Liquid Glass where functional; Apple-Music/Photos-grade motion; a themed background gradient with depth
that is **not biased toward black**; **fluid scrolling above all**.

- **`DesignSystem/` folder** (XcodeGen globs `Stashy/` → just add files, never touch a `.pbxproj`):
  - `ThemedBackground.swift` — a per-theme **static** `MeshGradient` (3×3 regular-grid `points`,
    `.perceptual` colour space) exposed as `.themedBackground()`. Wired behind every browse screen
    (Login, Scenes, Performers, Downloads ×2, Scene/Performer detail, Settings) replacing the old flat
    `backgroundColor.ignoresSafeArea()`. **One static layer, never per-cell** — recomputed only on theme /
    slider change, so it is free while scrolling (the scroll-perf rule). Its explicit `RenderIdentity`
    includes only palette/vibrancy/lift: this forces iOS 26 to replace a retained off-screen tab's stale
    mesh layer after a theme change (Scenes once restored an old dark Synthwave mesh over light Meadow)
    without adding any scroll-time invalidation.
  - `CardStyle.swift` — `CornerRadius` (card 12 / small 10 / large 18) +
    `cardContour(isDark:)` (a sub-point edge stroke). The former blurred grid-card elevation was removed
    in the inertial-scroll pass: even with a vector source, a blur still consumes compositor fill-rate for
    every visible card at 120 Hz.
  - `FilterPill.swift` — `filterPill(active:tint:foreground:)`, the one filter-chip style. Active = solid
    `tint` fill + white label; inactive = `foreground.opacity(0.12)` capsule. **Solid, never glass** (see
    glass discipline). Panel control chips use it; the smaller inline-tag chips use the same solid fills
    with their compact padding.
- **Theme.swift** — 14 distinct palettes (dark: nocturne/aurora/synthwave/ember/verdant/ruby/slate/mocha;
  light: daybreak/blossom/meadow/citrus/periwinkle/seabreeze — synthwave & mocha kept by owner request).
  `meshColors(vibrancy:lift:)` builds the 9 mesh colours from the palette tokens, blending toward
  `foreground`/`primary`/`accent` — **never toward black** ("don't bias the gradient toward dark").
  **`MeshTuning`** = slider ranges + defaults (vibrancy 0.50, lift 0.32). `ThemeManager` persists **four**
  values — vibrancy & lift, **separately for light & dark** (`stashy.mesh.{vib,lift}.{dark,light}`);
  `currentMeshVibrancy/currentMeshLift` select by `current.variant`. Settings → "Background depth" hosts the
  4 sliders (`meshSliderRow`).
- **Motion** (system springs → reduce-motion-safe): Scenes and Performers use the native navigation
  push/pop. The earlier grid→detail `.navigationTransition(.zoom)` was removed in the 2026-07-20
  performance pass: iOS 26 FB21961572 retained the matched source after pop, forcing a 600 ms scroll lock
  or showing a frozen card. Owner chose immediate, consistently fluid scrolling over that hero. The
  long-press scene preview keeps its own fake hero. `.tabBarMinimizeBehavior(.onScrollDown)` remains on the
  `TabView` (iOS 26, iPhone). `.contentTransition(.numericText())` + `.animation(.snappy, value:)` remains on
  the selection-count button (rolling digits).
- **Glass discipline (cost a CI cycle):** Liquid Glass only shows character over **vibrant/varied content**
  (the mesh, media) — NOT over flat `Material` or over another glass surface. So the floating filter **panel**
  (`LibraryDropdownPanel`) is `.glassEffect(.regular)` because it sits over the mesh/grid, but the **chips
  inside it are solid `filterPill`s**. History: v1.0.262 glassed the chips over the then-material panel →
  invisible; v1.0.264 flipped it (glass panel, solid chips); v1.0.265 made active chips fill accent.
- **No scrollbars anywhere** (owner standing pref): `UIScrollView.appearance()` indicator flags off in
  `StashyApp.init()` + `.scrollIndicators(.hidden)` in `ContentView` (propagates via environment). Reinforce
  on any new scroll view; never reintroduce an indicator (incl. `UIScrollView`-backed views).
- **Scroll-perf rule (strengthened 2026-07-20):** `ScenePreview` does **no global frame conversion while
  scrolling**. It tracks only the cell's stable `CGSize`; on long-press,
  `UIGestureRecognizerRepresentable.Context.converter` supplies the global + local locations and the
  source rect is reconstructed once. The long-press fake hero is preserved. Keep global
  `frame(in: .global)` / preference writes, unbounded task creation, JSON decoding, animated glass, and
  matched-transition source state out of visible grid cells and scroll-time main-actor work.
- **Inertial scroll keeps content flowing:** `BrowseScrollCoordinator` is driven by
  `onScrollPhaseChange` on Scenes, downloaded Scenes, Performers, and performer-detail scene grids.
  DownloadManager skips only its 120 ms **UI progress poll** while moving (transfer engines continue
  untouched). v1.0.286's image freeze was a failed tradeoff: it made cards blank and did not materially
  improve device scrolling. ThumbHashes render during motion, memory hits publish immediately, and
  disk/network loads publish on completion. The later idle-gated pagination was also wrong: device
  telemetry showed 119.67–119.92 FPS / 8.33 ms p95 while the visible "stop" was the fling reaching the
  physical end of a 25-item page. `PaginatedLoader` now starts the next request one quarter into the newest
  page, appends immediately without showing a layout-changing next-page footer, and exposes a cheap
  `contentRevision`; each grid uses that revision to enqueue the newest page's images once. This removes
  the former per-appearing-card index/suffix scan while giving thumbnails maximum lead time. Scene
  download/transcode badges remain one array walk. The coordinator is deliberately **not Observable**.
- **Browse scroll telemetry (opt-in RemoteLog):** `BrowseScrollPerformanceMonitor` attaches a 120 Hz
  `CADisplayLink` only while a tracked grid is moving and Settings → Diagnostics → Stream debug logs is
  enabled. It records callback intervals and phase with no per-frame observation writes, then does all
  sorting/string/log work after `.idle`. ntfy receives separate `scroll-segment` lines for interaction
  and deceleration plus `scroll-end`: effective FPS, target Hz, avg/p95/p99/max frame time, hitch %, severe
  ≥50 ms gaps, missed maximum-Hz intervals, coefficient-of-variation "judder", a cadence histogram, and
  real-thumbnail publication/memory-hit/load-latency counts. Pagination adds page-append count/item count/
  p95 request latency so any append hitch is directly correlated. It diagnoses main-run-loop cadence; it
  cannot directly prove a compositor-only missed presentation. Normal use with logging off has no display
  link.

### Minimized search (v1.0.268) — no scroll-top drawer, tap-to-expand button
Owner ask: search must NOT appear when the list scrolls to the top; it should pop up only when the
magnifier is tapped. Applied to Scenes & Performers.
- **Why the old setup revealed it:** `.searchable(..., placement: .navigationBarDrawer(displayMode:))`
  puts search in the nav-bar drawer, shown at the top and hidden on scroll-down — BOTH displayMode cases
  (`.automatic`, `.always`) show it at scroll-top. The `isPresented:` binding governs only the
  ACTIVE/focused state, NOT whether the collapsed drawer chrome renders. No drawer mode hides it at top.
- **Fix (iOS 26):** `.searchToolbarBehavior(.minimize)` (spelling is `.minimize`, NOT `.minimized`)
  renders the searchable as a **button** that expands into the field on tap — nothing at scroll-top. Drop
  the `.navigationBarDrawer` placement (default `.automatic`). Pin the button top-left with
  `DefaultToolbarItem(kind: .search, placement: .topBarLeading)` inside `.toolbar { }` (it's
  `ToolbarContent`, iOS 26.0+); without it the button lands in the iOS 26 default (bottom) slot. Remove the
  custom magnifier `Button` — the system provides one. Keep `isPresented: $searchPresented` (optional; the
  system drives it) + the debounced `.task(id: searchText)` → `query.search`.
- **Toolbar landmine respected:** the search `DefaultToolbarItem` is UNCONDITIONAL (always present) and the
  top-leading `ToolbarItem` keeps stable identity with only its CONTENT conditional (`if selectionMode {
  Cancel }`). Do NOT gate the whole search item behind `if !selectionMode` — a conditional whole toolbar
  item risks the "vanishing button" drop bug. Accepted consequence: the magnifier shows during Scenes
  multi-select next to Cancel.
- **All iOS 26.0+** (`searchToolbarBehavior`, `SearchToolbarBehavior.minimize`, `DefaultToolbarItem`,
  `ToolbarDefaultItemKind.search`); deploy target is 26.0 so no `#available` gate. Signatures were
  doc-JSON verified before push.

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
- **Telemetry:** `RemoteLog` → ntfy (`Services/RemoteLog.swift`), OFF by default; server URL + topic
  configurable in Settings → Diagnostics (self-hostable). **KEPT feature — owner decision 2026-07-16
  reversed the old remove-before-wider-release rule**; the §5 checklist in
  `docs/OPTIMIZATION_PLAN_2026-06-30.md` is reference only. Privacy note: on the default public
  `ntfy.sh`, anyone with the topic name can read the stream — the topic is a random burner ("New topic"
  rotates it); point at a self-hosted ntfy for full privacy.

---

## 8. Release history quick-reference

- `ef9e591` background-session switch → -3000 regression → reverted in `22f6740`.
- v1.0.101: Downloads M1 (8-connection engine + screen), downloaded-only filter, offline sprites.
- v1.0.105–106: on-device transcode (AVFoundation, presets, card UI).
- v1.0.107: single-connection background continuation with foreground handoff (`b8ea21d`).
- 2026-07-03/04: downloads transcode goes FFmpeg-first (`151e707` universal engine;
  `f421ecd`/`d3c0108`/`960ac90` checkpointed resumable engine — §4).
- 2026-07-04/05: M-A on-device *streaming* transcode playback tier shipped… then **removed** in
  `c088325` (flaky + glitchy scrubbing; exotic codecs → server HLS). M-B (server-quality menu) stays.
- Also shipped in the big handoff session: scene ratings + performer/tag favorites (`LibraryEdits`),
  Apple-Photos-style image viewer, portrait-fullscreen tab-bar fix, popover stable-anchor fix,
  private Application Support storage migration, network-loss recovery ("Waiting for network…" +
  bounded auto-retry), replay-after-end + time-over-duration fixes.
- **v1.0.253–265 — UI/UX overhaul** (browse surfaces; player deferred): new `DesignSystem/` (mesh
  `ThemedBackground`, `CardStyle`, `FilterPill`), Theme.swift rewrite (14 palettes + `meshColors` + 4
  background-depth sliders), hero **zoom** grid→detail transitions, tab-bar minimize-on-scroll,
  `numericText` selection count, Liquid-Glass filter panel with **accent-fill active chips**, no-scrollbars
  enforcement, and the `ScenePreview` `onGeometryChange` scroll-perf fix. Full detail in §6.
- **v1.0.266–268 — Phase-4 consolidation + minimized search**: DesignSystem primitives
  `LabeledSegment`/`overlayBadge`/`capsuleField` + `SceneFilterBar` → `filterPill`; and search reworked to
  an iOS 26 minimized toolbar button (no scroll-top drawer — `.searchToolbarBehavior(.minimize)` +
  `DefaultToolbarItem(kind: .search)`, §6).
- **2026-07-20 library performance pass:** fixed dropdown whole-grid identity flicker; immediate
  no-animation glass removal on scroll; removed nested tag-chip glass; eliminated scroll-time global
  geometry conversion; bounded thumbnail prefetch to two deduplicating workers; decoded companion maps
  off-main; removed iOS 26 zoom-navigation sources and their 600 ms return scroll lock. §6 is the guardrail
  for future browse fixes.
- **2026-07-20 inertial-frame follow-up:** initially deferred pagination mutations and the transfer UI poll;
  replaced blurred grid elevation with a contour stroke. The attempted thumbnail publication/prefetch/
  ThumbHash freeze was reverted after device feedback (blank cards, no meaningful FPS gain). Real images
  and ThumbHashes now remain live during motion, memory/decoded-placeholder caches are larger, and opt-in
  ntfy scroll frame telemetry supplies evidence for the next isolation pass. The pagination part was later
  superseded by the telemetry-driven fix below; the transfer UI poll remains protected. Actual downloads
  and their foreground eight-way engine are unchanged.
- **2026-07-20 telemetry-driven pagination follow-up:** 42 sessions / ~80 seconds measured Scenes at
  119.67 FPS and Performers at 119.92 FPS, both with worst p95 8.33 ms and no ≥50 ms severe hitch, even
  across 4,137 thumbnail publications. The perceived hard stops were 25/30-item content boundaries caused
  by `loadNextIfNeeded` waiting for `.idle`. Pagination now fetches early during motion, hides next-page
  loading state, appends atomically, and prefetches every new page's images once via `contentRevision`.
- **v1.0.296 — jobs-panel scan-progress fix + compact task chips:** the null-vs-empty `jobQueue` decode
  bug (see §6 "Jobs panel") froze/hid the scan progress bar since the panel shipped; JobMonitor gained
  refcounted attach/detach, a never-self-stopping poll loop with a visible reconnecting state, inline
  action errors, and an optimistic "Starting …" line. The four task buttons shrank to caption2 flow
  chips under a "Library tasks" caption.
- **v1.0.297 — multiThread download default restored ON** (owner decision; the v1.0.284–295 rework had
  defaulted it OFF). Staging still offers Background per download; the bad-server-response and -3000
  fallbacks still demote an item permanently; pre-field sidecars restore as multi-thread.
- **v1.0.298 — metadata scrape/edit suite:** scene + performer ••• menus gained Scrape/Edit Metadata
  (medium-detent glass sheets over the playing video), and Performers gained a + add-performer flow
  (scraper search → pick match → pick photo → create). New `StashScraper` gateway; contracts + sheet
  patterns in §6 "Metadata scrape/edit suite".
