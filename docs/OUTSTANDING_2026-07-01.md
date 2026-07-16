# Stashy — Outstanding / To-Improve (snapshot 2026-07-01, v1.0.101)

> **Shipped since this snapshot (as of v1.0.107):** M3 on-device transcode (AVFoundation, presets,
> card UI — v1.0.105–106); background continuation via single-connection handoff (v1.0.107 — the
> full "move the engine to a background session" M2 approach is now known to be infeasible, see
> `docs/ENGINEERING_NOTES.md` §3); network-loss recovery ("Waiting for network…" + bounded
> auto-retry). Still open from those areas: Live Activity / Dynamic Island, AV1 encode, download
> source choice, re-download at different quality.
>
> **Re-audited 2026-07-14 (v1.0.249) and 2026-07-16:** body checkboxes are current through 2026-07-16.
> [Of the note above's "still open" list, **download source choice** has since shipped (Original /
> server-transcode Companion staging on the Downloads screen); Live Activity / Dynamic Island,
> **on-device** AV1 encode, and re-download-at-different-quality remain open.] Shipped since the first
> re-audit: the **VMAF arc** (v1.0.250–252 + Companion v0.2.2/v0.3.0) — perceptual-quality (VMAF)
> targeting for Companion transcodes with a live "Analyzing quality — %" status, a VMAF badge and
> before→after size/reduction in Downloads, and a library-wide VMAF CRF-map plugin task. See CLAUDE.md
> Current state.

A consolidated punch list pulled from the session history, cross-referenced against `ROADMAP.md` and
`DOWNLOADS_PLAN_2026-07-01.md`. Grouped by area; each item is **not yet done** unless marked. Shipped
items from this session are listed at the bottom for context.

## Near-term (active threads, smallest lifts first)
- [x] **Downloaded-only filter + offline sprites** — verified on device (owner daily-drives it).
- [x] **Filter-popover flicker/crash** — verified gone on device (stable-anchor `FilterPopoverAnchor`).
- [x] **Settings popup clipping** — verified resolved after the popover rework.
- [x] **M-A on-device streaming transcode (video + audio)** — verified on device… then **REMOVED**
      (`c088325`, 2026-07-05: flaky + glitchy scrubbing; exotic codecs now go to server HLS).
- [x] **Seek-by-reinit + loading-donut tuning** (warm per-seek estimate + file-weight-scaled) — verified.
- [x] **Downloaded badge on grid cells** — SHIPPED 2026-07-03 (`4f55d0a`): green `arrow.down.circle.fill`
      (+ `wand.and.stars` if transcoded) under the duration capsule in `ScenesView`. Remaining sliver (if
      still wanted): the grid card still loads the *remote* thumbnail URL — have `SceneCard` prefer the
      local sidecar thumbnail DownloadManager already saves (`<sceneID>-thumb.jpg`).

## Downloads (M2 / M3 — SHIPPED)
- [x] **M2 — background continuation.** Downloads run under a background `URLSession` and survive
      suspension/exit (dual-engine handoff: foreground 8-way ⇄ background single-connection — see
      ENGINEERING_NOTES §3).
- [ ] **M2 — Live Activity / Dynamic Island for downloads.** Aggregate %/speed/ETA. **NOT built** (the
      [x] here was an error) — needs a Widget Extension target in `ios/project.yml` (ActivityKit +
      `NSSupportsLiveActivities`); riskiest remaining downloads item for a sideloaded IPA (see
      ENGINEERING_NOTES §3 Follow-ups). Background continuation itself shipped (v1.0.107, above).
- [x] **M3 — on-device transcode.** FFmpeg → `h264/hevc_videotoolbox` (+aac), encoding card, resolution +
      bitrate-capped quality presets, HEVC default.
- [x] **Server-side HEVC/AV1 transcode-for-download** — the Stashy Companion plugin (GPU HEVC on the EOL
      P40 via dual-ffmpeg, CPU AV1, HDR-preserve, real `Job.progress`, app-cancel). See ROADMAP Downloads §.
- [x] **Download source choice** — Original / server-transcode (companion HEVC/AV1) staged on the Downloads
      screen.
- [ ] **On-device AV1 encode option** — still **blocked** on an FFmpeg XCFramework rebuild (LGPL-minimal
      build ships VideoToolbox H.264/HEVC + AAC only; AV1 *decode* only). Note: server-side AV1 via the
      companion plugin already covers this need; on-device AV1 encode remains deferred.
- [ ] **Re-download at different quality** from the management screen.
- [x] **Resumable/checkpointed on-device transcode** — SHIPPED 2026-07-04 (`f421ecd`/`d3c0108`/`960ac90`):
      `FFmpegResumableTranscoder`, keyframe-aligned chunk engine (ROADMAP Approach B — chosen over
      fragmented-MP4 append), persistent work dir (`plan.json` + `chunk_NNNN.mp4` + `settings.json`) so
      even a cold relaunch resumes; used for long re-encodes only (stream-copy and <90 s files take the
      fast paths).

## FFmpeg iOS XCFrameworks (separate build project — enables M3/AV1/broader transcode)
- [x] **DONE** (pre-dates this snapshot's re-audit) — shipped as the SPM package
      **`nphil/stashy-videoengine`** (LGPL-minimal build: VideoToolbox H.264/HEVC + native `aac` encoders
      only; AV1 decode but **no AV1 encode**). The app's on-device transcode/remux features
      (FFmpegRemuxer/Transcoder/ResumableTranscoder/Probe) ride on it; capability changes = rebuild +
      republish that package and bump the pin in `ios/project.yml`, not this repo (ENGINEERING_NOTES §5).
      The remaining open slice — rebuilding with SVT-AV1/libaom for on-device AV1 encode — is tracked in
      the Downloads section above.

## Playback & scrubbing
- [x] **Seekable remux (seek-by-reinit)** — SHIPPED. `ScenePlayerModel.seek(to:)` reinits the local remux/
      transcode stream from a keyframe near the target (`reinitLocal(at:)`, zero-based) whenever the target
      is before this stream's start or past the seekable end; in-range seeks stay a plain frame-accurate
      engine seek. The scrub thumb is pinned at the released position by the `seekTarget`/`seekHoldUntil`
      hold (ticks reporting the pre-seek position are suppressed until the player lands) — do not disturb
      that logic. The loading donut during a seek fills on a **warm per-seek estimate + snappy curve**
      (`LoadEstimator.expectedSeek`/`recordSeek`, `LoadCurveParams.seek`, gated by `loadIsSeek`) so a
      re-seek's ring races to near-full instead of crawling on the cold-start estimate, and seek times no
      longer pollute the first-load learning. (Note: reinit debounce still deferred — seek fires only on
      drag release, so mid-drag thrash isn't a concern.)
- [x] **Hybrid scrub preview** — SHIPPED v1.0.248 (`Services/ScrubFrameProvider.swift`): exact decoded
      frame under the finger for local downloads, sprite tile as placeholder. Plus **variable-speed
      scrubbing** (bar + video hold-scrub) with a speed label. (ENGINEERING_NOTES §6.)
- [x] **Watch-heat / "most replayed" overlay** — SHIPPED v1.0.246 (`Services/WatchHeat.swift`): per-scene
      100-bin watched-seconds curve, host-scoped, drawn above the ScrubBar while scrubbing; Settings →
      Player toggle + Clear.
- [ ] **Revive segmented HLS** only if driven by one continuous muxer (per-segment muxing was choppy).
- [x] **Quality / gear selector** — mostly shipped as M-B (gear menu, Auto + server-resolution rungs;
      routing is otherwise automatic via `playbackRoute`). Only an explicit Direct / On-device method
      forcing remains unbuilt.
- [x] **Server-side transcode controls** — SHIPPED as M-B: player gear → `ServerQuality` menu forcing
      Stash HLS at a chosen resolution (duplicate `?resolution=` param bug fixed; exact-position resume
      on switch). `PlayerControlsView` + `Scene.serverQualityRoute`.

## Stash feature parity
- [ ] **O-counter** — increment/track per scene.
- [ ] **Markers** — view/seek to (and ideally create) scene markers.
- [ ] **Metadata search / auto-fill** — Stash scrape/identify from the app.
- [ ] **Delete: scenes/performers** — confirm coverage/undo. (Delete plumbing exists via LibraryEdits;
      verify all surfaces + confirmations.)

## Library & UX
- [ ] **Filter performers by country** — country picker mirroring the ethnicity filter
      (`PerformerFilterType.country`).
- [ ] **Rework the filter/sort chips UI** — cleaner interaction model (ongoing; popover stability was one
      slice of this).
- [x] **Pull-down search** — SHIPPED 2026-07-08 (`db1263a`): native `.searchable` drawer on the Scenes
      and Performers lists (collapsed until pull-down or the magnifier button, 350 ms debounce);
      `SearchView.swift` deleted, Search tab replaced by a Downloads tab.
- [ ] **Universal search** across content types; **tab show/hide/reorder**.
- [ ] **Filter scenes by favorites/rating** (downloaded-only just added; extend the "Show" row).

## Comparative-study features (from 1letzgo/stashy)
- [ ] **Studios / Galleries / Images browsing** (Studios = smallest lift).
- [ ] **Configurable Home dashboard** (user-arranged rows).
- [ ] **StashTok / Reels** vertical feed (auto-mute unless headphones).
- [ ] **"Hot or Not" swipe-to-rate.**
- [ ] **Multi-server support** — `ServerConfig` list, Keychain-per-server, server-scoped `ImageCache`.
- [ ] **401 handling** — surface expired/invalid API key instead of silent failure.
- [ ] **On-device Vision content analysis** (reuse the existing frame tap) → auto markers, "skip to the
      action" chaptering, motion-peak scrub thumbnails, smart previews.

## Privacy & security
- [x] **App-switcher / background privacy blur** — SHIPPED v1.0.246 (`SnapshotPrivacyModifier` in
      `Services/AppLock.swift`): thick-material cover on `scenePhase != .active`, Settings → Privacy
      toggle (default ON), independent of Face ID lock. Deliberately unanimated (snapshotted frame).
- [x] **Telemetry decision RESOLVED — RemoteLog stays** (owner, 2026-07-16). The old "remove all
      telemetry before wider release" blocker is withdrawn: `RemoteLog` remains an opt-in diagnostics
      feature (off by default; configurable/self-hostable ntfy server + topic). Optimization-plan §5
      checklist = reference only.

## Big deferred ideas (revisit after core is solid)
- [ ] **XR glasses support** ("phone becomes the remote") — external-display scene + AVPlayer external
      playback; big-screen UI on glasses, phone becomes a gesture trackpad; Live Activity/Dynamic Island
      remote. Needs real hardware. *(User explicitly asked; confirmed feasible on iPhone 15+.)*
- [ ] **AI upscaling** — **ATTEMPTED & REVERTED**: the live-upscaling path shipped v1.0.239–244 (VT
      zoom-crop, then MetalFX 2×/4× + neural pause-stills) and was removed 2026-07-10
      (`Services/UpscaleRunner.swift` deleted) — owner called it buggy and not worth it on 720p sources.
      **Do NOT retry cold — read ROADMAP §AI upscaling postmortem first.** Current revival plan:
      Real-ESRGAN Core ML paused-frame enhance (A19 Pro), iOS 27 VT capability-query APIs for a live
      re-attempt, server-side SR as max-quality offline. The Phase B idea (per-video overfitted SR model
      via Stash plugin) remains untried.
- [ ] **Instant-start preview preloader** — Stash plugin pre-generates ~3s opening clips; app plays the
      preview instantly then hands off to the real stream.
- [ ] **Performer social feed** (X/Twitter) in the socials card — API-constrained, best-effort.
- [ ] **Site integrations** (simpcity, empornium, …) + **multi-threaded downloader that imports into the
      Stash library**.
- [ ] **Android app** — later.

## Shipped this session (for context)
Scene rating + performer/tag favorites (with LibraryEdits optimistic store); favorite status on
performer portraits; Apple-Photos-style image viewer; tag-favorites in the filter picker; portrait
fullscreen tab-bar bug fixed; native popover filter with custom chips + **stability fix (stable anchor)**;
Face ID immediate (splash removed); videos start muted unless on AirPods; replay-after-end + time-over-
total fixes; **Downloads M1** (multi-connection engine, Downloader screen, 3-dot action, Settings entry);
download card polish (thumbnail + performer + tap-to-play + delete confirmation, offline sprite/thumb
sidecar); **downloaded-only scenes filter + offline scrub sprites** (v1.0.101).
