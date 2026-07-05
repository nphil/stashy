# Stashy — Outstanding / To-Improve (snapshot 2026-07-01, v1.0.101)

> **Shipped since this snapshot (as of v1.0.107):** M3 on-device transcode (AVFoundation, presets,
> card UI — v1.0.105–106); background continuation via single-connection handoff (v1.0.107 — the
> full "move the engine to a background session" M2 approach is now known to be infeasible, see
> `docs/ENGINEERING_NOTES.md` §3); network-loss recovery ("Waiting for network…" + bounded
> auto-retry). Still open from those areas: Live Activity / Dynamic Island, AV1 encode, download
> source choice, re-download at different quality.

A consolidated punch list pulled from the session history, cross-referenced against `ROADMAP.md` and
`DOWNLOADS_PLAN_2026-07-01.md`. Grouped by area; each item is **not yet done** unless marked. Shipped
items from this session are listed at the bottom for context.

## Near-term (active threads, smallest lifts first)
- [x] **Downloaded-only filter + offline sprites** — verified on device (owner daily-drives it).
- [x] **Filter-popover flicker/crash** — verified gone on device (stable-anchor `FilterPopoverAnchor`).
- [x] **Settings popup clipping** — verified resolved after the popover rework.
- [x] **M-A on-device streaming transcode (video + audio)** — verified on device.
- [x] **Seek-by-reinit + loading-donut tuning** (warm per-seek estimate + file-weight-scaled) — verified.
- [ ] **Downloaded thumbnails in the scene grid** — a downloaded scene currently shows the same remote
      thumbnail. Consider a small "downloaded" badge on grid cells so offline availability is visible in
      the normal (non-filtered) scenes grid too.

## Downloads (M2 / M3 — SHIPPED)
- [x] **M2 — background continuation.** Downloads run under a background `URLSession` and survive
      suspension/exit (dual-engine handoff: foreground 8-way ⇄ background single-connection — see
      ENGINEERING_NOTES §3).
- [x] **M2 — Live Activity / Dynamic Island for downloads.** Aggregate %/speed/ETA.
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
- [ ] **Resumable/checkpointed on-device transcode** (fragmented-MP4 append — owner-requested; see ROADMAP).

## FFmpeg iOS XCFrameworks (separate build project — enables M3/AV1/broader transcode)
- [ ] Stand up the dedicated `ffmpeg-ios` repo + `macos-15` GitHub Actions build producing the 6
      XCFrameworks (avformat/avcodec/avutil/avfilter/swscale/swresample), arm64 device + sim, module
      maps, published as checksummed Release assets. (Full brief exists as a standalone plan.) The app's
      on-device transcode/remux features ride on these.

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
- [ ] **Hybrid scrub preview** — show the instant Stash/offline sprite tile while dragging, then refine
      with an on-device decoded frame at the exact position when the user pauses on it.
- [ ] **Watch-heat / "most replayed" overlay** on the scrubber — YouTube-style heat curve built locally
      (per-scene bins of accumulated real-time watch seconds, persisted per server, drawn behind the
      ScrubBar; decay/cap; settings toggle to show/clear). *(User explicitly asked for this.)*
- [ ] **Revive segmented HLS** only if driven by one continuous muxer (per-segment muxing was choppy).
- [ ] **Quality / gear selector** — Auto / Direct / On-device / Server transcode + resolution picker.
- [ ] **Server-side transcode controls** — quality/resolution for the HLS path.

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
- [ ] **Pull-down search** integrated into the library (scroll-to-reveal) instead of a separate tab.
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
- [ ] **App-switcher / background privacy blur** — cover content on `scenePhase != .active` (App
      Switcher, Control Center, calls) so the multitasking snapshot never shows video/thumbnails.
      Independent of the Face ID lock; settings toggle. *(User asked to blur the paused frame on OS
      switch — this is the consistent, lock-independent version.)*
- [ ] **⚠️ REMOVE ALL TELEMETRY before any wider release** — `RemoteLog` → ntfy is off by default but
      present. Deletion checklist in optimization plan §5. The one intentionally-open tech-debt item.

## Big deferred ideas (revisit after core is solid)
- [ ] **XR glasses support** ("phone becomes the remote") — external-display scene + AVPlayer external
      playback; big-screen UI on glasses, phone becomes a gesture trackpad; Live Activity/Dynamic Island
      remote. Needs real hardware. *(User explicitly asked; confirmed feasible on iPhone 15+.)*
- [ ] **AI upscaling** — MetalFX spatial (Phase A) → per-video overfitted Core ML SR model via Stash
      plugin (Phase B). For low-bandwidth/remote viewing.
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
