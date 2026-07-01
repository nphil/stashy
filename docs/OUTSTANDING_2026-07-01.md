# Stashy — Outstanding / To-Improve (snapshot 2026-07-01, v1.0.101)

A consolidated punch list pulled from the session history, cross-referenced against `ROADMAP.md` and
`DOWNLOADS_PLAN_2026-07-01.md`. Grouped by area; each item is **not yet done** unless marked. Shipped
items from this session are listed at the bottom for context.

## Near-term (active threads, smallest lifts first)
- [ ] **Verify the downloaded-only filter + offline sprites on device** (shipped in v1.0.101 but untested
      on hardware): downloaded grid populates, tapping plays the local file, scrubbing a downloaded scene
      uses the offline sprite sheet, and the funnel highlights when the toggle is on.
- [ ] **Confirm the filter-popover flicker/crash is actually gone on device.** Root-caused to the popover
      being hosted from a toolbar item (torn down/re-presented on every query change) and moved to a
      stable content anchor. Needs the "mash lots of tags + sorts" stress test the user used to reproduce
      it — verify no pop-down/up and no crash.
- [ ] **Settings popup clipping** — earlier report: the settings popup was clipped *behind the links
      card*. Re-verify after the popover rework; fix z-order/presentation if it still clips.
- [ ] **Downloaded thumbnails in the scene grid** — a downloaded scene currently shows the same remote
      thumbnail. Consider a small "downloaded" badge on grid cells so offline availability is visible in
      the normal (non-filtered) scenes grid too.

## Downloads (M2 / M3 — planned, not started)
- [ ] **M2 — true background continuation.** Move the engine to `URLSessionConfiguration.background`,
      wire `application(_:handleEventsForBackgroundURLSession:)`, verify downloads survive app
      suspension/exit. (Current engine uses `.default` = foreground; pauses when suspended.)
- [ ] **M2 — Live Activity / Dynamic Island for downloads.** Requires a **Widget Extension target** in
      `project.yml` (ActivityKit + `NSSupportsLiveActivities`): thumbnail + aggregate %/speed/ETA,
      compact leading/trailing + minimal, with pause/resume/stop. Start/update/end from `DownloadManager`.
- [ ] **M3 — on-device transcode.** FFmpeg → `h264_videotoolbox`/`hevc_videotoolbox` (+aac). Encoding
      card mirroring the download card. Presets: resolution target (Original/2160/1080/720/480) + quality
      Low/Med/High bitrate ladders; HEVC default. **The transcode button already exists on completed
      cards, disabled (`wand.and.stars`).**
- [ ] **AV1 encode option** — **blocked**: current FFmpeg XCFrameworks are LGPL-minimal (VideoToolbox
      H.264/HEVC + AAC only; AV1 *decode* only). Needs a separate FFmpeg rebuild with an AV1 encoder
      (see the FFmpeg-iOS build brief) — GPL/heavy, CPU-only, slow on phone. Deferred.
- [ ] **Download source choice** (roadmap): Original file / Stash-transcoded / on-device transcode.
- [ ] **Re-download at different quality** from the management screen.

## FFmpeg iOS XCFrameworks (separate build project — enables M3/AV1/broader transcode)
- [ ] Stand up the dedicated `ffmpeg-ios` repo + `macos-15` GitHub Actions build producing the 6
      XCFrameworks (avformat/avcodec/avutil/avfilter/swscale/swresample), arm64 device + sim, module
      maps, published as checksummed Release assets. (Full brief exists as a standalone plan.) The app's
      on-device transcode/remux features ride on these.

## Playback & scrubbing
- [ ] **Seekable remux (seek-by-reinit)** — the linear remux is forward-only; a far-forward seek waits.
      Re-init FFmpeg from an input seek near the target keyframe and rebuild the loopback stream. Biggest
      lever for responsive scrubbing. (Note: reinit debounce deferred — seek-latency tradeoff.)
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
