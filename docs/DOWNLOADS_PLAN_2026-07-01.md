# Downloads & on-device transcode — design & milestones (2026-07-01)

Goal: download Stash videos to the device (fast, resilient, resumable), manage them on a clean
Downloader screen, and optionally transcode them for iPhone-native playback. Reachable from the scene
3-dot menu ("Download Video") and from Settings.

## Hard iOS constraints (decide architecture around these)
- **Background continuation (app suspended/exited) requires `URLSessionConfiguration.background`.** A
  foreground engine is paused the moment iOS suspends the app. Background sessions only support
  `URLSessionDownloadTask`/`uploadTask` (no `dataTask`), are delegate-only, and relaunch the app on
  completion (`application(_:handleEventsForBackgroundURLSession:)`). Progress callbacks fire only while
  the app is running; while suspended, downloads continue but progress is frozen until the next wake.
- **Multithreaded (8 connections) + background**: do 8 `URLSessionDownloadTask`s, each with a
  `Range: bytes=start-end` header, in the background session. They run in parallel *and* survive
  suspension. Merge the 8 parts when all finish. (Source supports Range — the on-device remux already
  does ranged reads against `scene.directFileURL`.)
- **Network loss/restore**: background sessions with `waitsForConnectivity = true` handle this largely
  automatically; add `NWPathMonitor` for the "Waiting for network…" UI state.
- **AV1 encode is NOT available in the current FFmpeg build.** Our XCFrameworks are LGPL-minimal with
  `h264_videotoolbox`/`hevc_videotoolbox`/`aac` encoders only — no libaom/SVT-AV1. AV1 *decode* works;
  AV1 *encode* would require rebuilding FFmpeg with an AV1 encoder (GPL/heavy, CPU-only, slow on phone).
  So: ship H.264/HEVC hardware transcode now; AV1 encode is a later, separate build effort.
- **Live Activity / Dynamic Island requires a Widget Extension target** (ActivityKit +
  `NSSupportsLiveActivities`), added to `project.yml`. Compact/minimal presentation so it doesn't take
  the whole status bar. Reuses ActivityKit's own background running — that's what keeps the download
  alive without the full app.

## Milestones
**M1 — Foundation (in progress).** `DownloadItem` model + `DownloadManager` engine (multi-connection
range downloads, pause/resume/stop/retry, `NWPathMonitor` resilience), the Downloader screen (cards with
file name/ext/codec/resolution/bitrate + per-connection colored progress + status + speed/ETA + merge
phase), the scene 3-dot "Download Video" action, a Settings entry, and navigation. Engine on a
background-capable session so M2 is incremental, not a rewrite.

**M2 — True background + Live Activity.** App-delegate `handleEventsForBackgroundURLSession`, verify
suspension survival, and the Widget Extension with a Dynamic Island Live Activity (thumbnail + aggregate
%/speed/ETA, compact leading/trailing + minimal). Start/update/end the activity from `DownloadManager`.

**M3 — On-device transcode.** Reuse the FFmpeg engine → `h264_videotoolbox`/`hevc_videotoolbox` (+aac).
Encoding-progress UI mirroring the download card (details + errors). Presets tuned for iPhone playback:
- **Resolution target**: Original / 2160p / 1080p / 720p / 480p.
- **Quality Low/Med/High** → bitrate ladders (research-based; e.g. 1080p ≈ 4/8/12 Mbps H.264, less for
  HEVC). HEVC default (smaller at equal quality, hardware-decoded on-device).
- AV1 encode option = deferred (see constraint above).

## UX rules (from the request)
- Download entry = clean rounded card, big enough for file name + ext + codec + resolution + bitrate +
  live stats. Multi-connection shown as differently-colored segments; a status line shows % and the
  "Merging parts…" phase, then "Downloaded".
- Controls: **pause / resume / stop**. **Stop** cancels + removes the row *once you navigate away and
  back*; while still on screen, the stop button becomes **retry** (re-download). Completed items get a
  **delete** button (+ later: transcode).
- Downloader screen has a native top-left back button; downloads keep running in the background (M2).
