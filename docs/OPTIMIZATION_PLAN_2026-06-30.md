# Stashy — Optimization, Cleanup & Bug-Fix Plan
**Created:** 2026-06-30 (UTC) · **Baseline build:** v1.0.77 (`0cf21ee`)
**Mandate:** optimize performance, fix bugs, and remove spaghetti/leftover code from the long
playback-debugging session — *before* adding new features.

Items are ordered so the safest, highest-leverage work comes first. Each item notes **why**, **files**,
**risk**, and **impact**.

**Status (2026-07-01):** ✅ §1 (dead code) · §2.1 (remux pacing) · §2.2 (temp sweep) · §3.2 (ImageCache
counter) · §4.1–4.4 (correctness) · §6.1 (split ScenePlayerModel) · LoopbackServer `dataHandler` removed.
⏸ §2.3 (reinit debounce — deferred, latency tradeoff) · §5 (telemetry removal — kept until wider release).
🔲 Remaining: §3.1 (slim list query — has a UX tradeoff) · §3.3 (blur, optional) · §6.2 (RangeReader, optional).

---

## 0. Current state (what's good — don't break it)
- **Playback works:** H.264/AV1-in-MP4 → direct play; HEVC (+ AV1/H.264 in MKV/WebM) → **on-device
  linear remux** over a loopback byte-range HLS (smooth, ~2s start, flat memory); 4:2:2/4:4:4/12-bit and
  non-hardware codecs → Stash HLS transcode.
- **Seeking:** in-buffer seeks instant; far seeks restart the remux at the target (seek-by-reinit) using
  AVPlayer's real `seekableEnd`.
- Codebase hygiene is otherwise good: no TODOs, no force-casts, no stray `print`s, Swift 6 strict
  concurrency throughout, solid ImageCache/PreviewCache/StashClient/pagination.

The mess is concentrated in the **playback services** (lots of churn) and a couple of **efficiency**
problems that were never the focus while we chased "does it play at all."

---

## 1. Dead-code removal (do first — low risk, big readability win)
The on-demand **segmented** HLS experiment is fully shelved and unreferenced. Removing it deletes ~750
lines of the most complex C-interop in the app and eliminates duplicated box-parsing / AVIO code.

1.1 **Delete `HLSSegmentProducer.swift`** (566 lines) — orphaned (`buildHLS` is its only caller, and
    `buildHLS` is never called). Duplicates FMP4Index's box parsing + FFmpegRemuxer's read-ahead AVIO.
1.2 **Delete `LocalHLSStream.swift`** (92 lines) — only used by `buildHLS`.
1.3 **Remove `buildHLS(producer:)`** from `ScenePlayerView.swift` (dead method).
1.4 **Simplify `LoopbackServer.swift`**: with segmented HLS gone, the `dataHandler` mode + `serveData` +
    `produceQueue` are dead. The **plain-file mode + `LoopbackProbe`** are only used by the Stats
    self-test (debug; goes with telemetry — see §5). What remains and is *active* is the
    `playlist` + `serveMedia` (byte-range EVENT) path used by `LocalRemuxStream`. Strip the rest.
1.5 **Remove now-unused `producedSeconds()`** from the `LocalPlaybackStream` protocol, `LocalRemuxStream`,
    and `FMP4Index` (the seek decision moved to `engine.seekableEnd`). If `LocalHLSStream` is deleted,
    consider collapsing the `LocalPlaybackStream` protocol entirely — `LocalRemuxStream` would be the
    only conformer.
1.6 **`FFmpegRemuxer` in-memory path:** the `produced: Data` branch (when `fileURL == nil`) exists only
    for `LoopbackProbe`. After §5 it's dead — drop it; the remuxer always streams to the temp file.

**Risk:** low (deletions of unreferenced code). **Impact:** ~750+ fewer lines, one box-parser, one AVIO
reader. Verify with a CI build (must stay green + IPA ~7.3 MB).

---

## 2. Performance — the big one: bound the remux (highest impact)
**Problem:** `FFmpegRemuxer` runs `while bytesWritten < produceCap` with `cap = .max` on a detached
task — it downloads and remuxes the **entire** source file at copy speed regardless of how much the user
watches. Watch 1 minute of a 3.9 GB 4K file and the app still pulls **all 3.9 GB** over the network,
pegs CPU, loads the Stash server, burns battery/data, and writes a **full-size temp file to disk**. This
directly violates the project's "minimal server load / efficient" tenet and is the worst remaining
inefficiency.

2.1 **Pace production to the playhead.** Keep the remux ~30–60s ahead of playback, then *suspend* it;
    resume as the playhead advances. Mechanics:
    - The model already knows playback time; expose a "produced-ahead target" to `LocalRemuxStream`.
    - In the remux loop, when `producedSeconds - currentPlayheadSeconds > lead`, sleep/yield and
      re-check (respecting the interrupt deadline) instead of charging to EOF.
    - On pause, stop producing beyond the lead; on play/seek, resume.
    - **Impact:** network/disk/CPU/battery/server-load roughly proportional to *watched* duration, not
      file size. Temp file stays bounded (tens of MB, not GBs).
    - **Risk:** medium — must not starve AVPlayer (keep lead comfortably > forward-buffer 15s). Verify
      with telemetry (`mem`, `av buf=`, no stalls) on a long 4K file.
2.2 **Bound/clean the temp file.** With pacing, the temp stays small. Also ensure temp files are removed
    on every teardown/reinit path (audit `LocalRemuxStream.stop()` + reinit churn for leaks; consider a
    sweep of stale `stashy-stream-*.mp4` on launch).
2.3 **Debounce reinit churn.** Rapid scrubbing fires a fresh full remux per release. Debounce
    `reinitLocal` (e.g., coalesce seeks within ~250ms) and ensure the previous remux/loopback is fully
    torn down before the next starts.

---

## 3. Performance — browsing & rendering (medium impact)
3.1 **Slim the scene-list query.** `StashClient.sceneFields` fetches **full** performer records
    (`image_path`, `tags`, `birthdate`, `urls`, `rating100`, …) for *every* scene in list pages. For a
    25-scene page that's a lot of redundant payload + JSON decode. Use a minimal performer projection
    (`id name`) for list queries and fetch full performer data only on the detail screen.
    **Impact:** smaller responses, faster decode, snappier scroll. **Risk:** low (verify detail view
    still has what it needs).
3.2 **ImageCache LRU scan.** `enforceLimit()` / `totalSize()` scan the whole Thumbnails directory on
    every *new* image write — O(n) per fetch during fast scroll/prefetch. Track total bytes
    incrementally (in-actor counter) and only do a full scan occasionally (or when over a soft cap).
    **Impact:** less main-thread-adjacent disk churn while scrolling. **Risk:** low.
3.3 **Live blur cost at 4K (optional).** `LiveBlurBackdropView` copies a full-res (~33 MB at 4K)
    pixel buffer per tick at 20fps for the inline backdrop. Consider: skip the blur for >1080p sources,
    or render the backdrop from a downscaled output. Only matters inline (paused in fullscreen). Leave
    at 20fps for now (user prefers the look); revisit if inline 4K shows thermal/scroll cost.

---

## 4. Bug fixes & correctness (verify with telemetry before declaring done)
4.1 **Seek-by-reinit edge cases.** The zero-basing in `FFmpegRemuxer` (input-seek + subtract first
    DTS) is new and lightly tested. Cover: first packet with `AV_NOPTS_VALUE`; audio pre-roll before the
    video keyframe (currently dropped); seeking very near EOF; back-to-back far seeks. Confirm the
    `↻ reinit` path lands and plays via telemetry.
4.2 **AV1 direct-play fallback.** AV1-in-MP4 now direct-plays with an HLS `fallbackURL`, but the
    pixel-format gate only runs on the *remux* path. Verify a 4:2:2/10-bit-HDR AV1 MP4 that AVPlayer
    can't render actually triggers `onFailed → fallbackToHLS` (no silent black).
4.3 **Seek-to-end "waiting to minimize stalls".** Seeking to the very end previously hung
    (AVPlayer waiting for forward buffer that doesn't exist past EOF). Re-test on the linear path; if it
    persists, special-case near-EOF seeks (clamp slightly before end, or `automaticallyWaitsToMinimize
    Stalling = false` near the end).
4.4 **Audio-session churn.** Each `AVPlaybackEngine.init` calls `setCategory/​setActive(true)`; reinit
    creates a new engine → repeated activations. Harmless but worth setting the session once at app
    launch instead.

---

## 5. Telemetry removal (planned — currently kept, isolated & toggle-gated)
Telemetry is **debug-only and OFF by default** (Settings → Diagnostics → "Stream debug logs", and the
fullscreen Stats "DEBUG LOG" toggle). Transport is **ntfy.sh** (topic `stashy-dbg-n7x2k9q`) because it
was the only HTTPS/443 endpoint readable back from the agent sandbox — public MQTT brokers' `wss` ports
and `kvdb.io` weren't reachable/usable. It's deliberately isolated for a clean delete.

> **REMINDER (per Nitin): remove ALL telemetry before any public/wider release.** Deletion checklist:
> - Delete `Services/RemoteLog.swift`.
> - `OrientationLock.swift` (AppDelegate): remove the `RemoteLog.shared.enable()` launch call.
> - `ScenePlayerView.swift`: remove `RemoteLog.shared.log(...)` in `start()`, `fallbackToHLS`,
>   `reinitLocal`, `seek`.
> - `AVPlaybackEngine.swift`: remove the throttled `av …` telemetry block in the time observer + the
>   `stallObserver` log.
> - `SettingsView.swift`: remove the Diagnostics section.
> - `StatsOverlayView.swift`: remove the DEBUG LOG toggle (and, with §1.4, the demux/loopback
>   self-tests — `FFmpegSource.probeSummary` and `LoopbackProbe` are debug-only too).
> - Grep `RemoteLog` to confirm zero references remain.

If telemetry is wanted longer-term, swap the one `endpoint` constant in `RemoteLog` (everything else is
transport-agnostic).

---

## 6. Architecture tidy (optional, after 1–4)
6.1 Split `ScenePlayerModel` out of `ScenePlayerView.swift` into its own file — it carries routing
    dispatch, the engine facade, reinit, watchdog, time-offset mapping, and stats. The view file is 572
    lines; separating model/view aids readability.
6.2 Consider extracting a small shared `RangeReader` (URLSession range + read-ahead cache) used by both
    `FFmpegRemuxer` and `FFmpegSource` (after §1 removes the third copy).

---

## Suggested execution order
1. **§1 dead-code removal** → CI green, IPA verified. (Safe, immediate clarity.)
2. **§5 nothing now** (kept), but keep it isolated as §1.4 touches the probes.
3. **§2.1 remux pacing** — the single biggest performance/efficiency win. Verify with telemetry.
4. **§2.2/2.3 temp cleanup + reinit debounce.**
5. **§3.1 slim list query**, **§3.2 ImageCache counter.**
6. **§4 bug-fix pass** with telemetry on.
7. **§6 tidy** if time permits.
Then resume features (codec filter chip, favorites, downloads, etc. — see ROADMAP.md).

---

## Engineering learnings (so they survive context compaction)
- **AVPlayer + on-device remux:** AVPlayer will **not** progressive-play a single open-ended growing
  MP4 (re-requests from 0 / "operation stopped"). It **will** play a **byte-range EVENT HLS** over a
  loopback served from a growing fragmented-MP4 file. That linear-continuous-mux path plays **smoothly**.
- **Per-segment muxing is the enemy of smooth playback.** On-demand segments produced by *independent*
  FFmpeg output contexts gave great seeking but **choppy** playback on every file (frame-timing /
  AAC-priming discontinuities at each boundary). If segmented HLS is ever revived, segments must come
  from **one continuous muxer** (like ffmpeg's `hls` muxer), not per-segment muxing.
- **HEVC `hev1` renders black** in AVPlayer → must remux to `hvc1` (codec_tag=0 lets the mp4 muxer
  assign it). This is why HEVC always remuxes even from MP4. **AV1 has no such issue** (`av01`,
  out-of-band config) → AV1 direct-plays from MP4; remux only for MKV/WebM containers.
- **Apple hardware decode limits:** H.264/HEVC/AV1 = 4:2:0 8/10-bit only. 4:2:2 / 4:4:4 / 12-bit must
  transcode (server HLS). AV1 hardware decode requires A17 Pro+ (`VTIsHardwareDecodeSupported(av01)`).
- **Source I/O:** one HTTP range request per 64 KB AVIO read is catastrophically slow over the network;
  a **read-ahead slab (4 MB)** is essential.
- **Seek decision must use `AVPlayer.seekableTimeRanges`, not the remux's produced position** — for a
  growing EVENT playlist AVPlayer's seekable range trails the remux (it re-fetches the playlist only
  periodically), so "produced" over-reports what a seek can reach.
- **Crash that smelled like a bug was resource exhaustion:** the loopback served blocking segment
  production on a *concurrent* queue → GCD thread explosion + large Datas → jetsam. Serial production
  queue + no big-Data copy fixed it. Flat `mem` in telemetry ruled out a logic bug.
- **AVPlayer over-buffers an instant (loopback) source** — it prefetched the whole VOD. Cap with
  `preferredForwardBufferDuration` (15s).
- **CI is the only build path** (macOS runner). Always verify the **published IPA byte size** (~7.3 MB),
  not just a green check — `|| true` once masked 60 KB stub IPAs.
- **ntfy.sh free rate-limits per device IP** (~1 req / 5s sustained); batch + flush ≥6s or it 429s and
  the stream goes dark.
