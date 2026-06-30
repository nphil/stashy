# Stashy — Roadmap & Deferred Ideas

Working notes so intent survives across sessions. Core tenets: **fast, responsive playback +
scrubbing**, **direct-play first**, on-device FFmpeg as the fallback, minimal server load.

## Playback pipeline (active work)

1. **Routing brain — capability detection** ✅ *(in progress)*
   Classify each file and pick the cheapest correct path:
   - **Direct play** — H.264/HEVC in mp4/mov/m4v → AVPlayer plays the file URL (native HW decode,
     instant seeks). *This is the fast path; maximize it.*
   - **Remux** — H.264/HEVC in a wrong container (MKV/TS/etc.) → repackage to fragmented MP4, no
     re-encode → AVPlayer.
   - **Transcode** — codec AVPlayer can't decode (MPEG4-ASP, VC1, VP9/AV1 on older devices) →
     FFmpeg decode → `h264_videotoolbox`. Last resort.
   - HLS (Stash server transcode) is the temporary fallback until remux/transcode land.

2. **Remux → AVPlayer via `AVAssetResourceLoaderDelegate`** (no loopback server). Probe already
   proved the muxing works on-device. Scrubbing needs keyframe-aware re-feed from the source.

3. **On-device transcode path** (the exotic set, incl. MPEG4-in-AVI — AVPlayer can't decode
   MPEG4-ASP even repackaged). Needs better I/O than per-read range requests for end-indexed
   containers (AVI): a streaming pull / larger read-ahead.

4. **Quality / gear selector** — Auto / Direct / On-device FFmpeg / (later) Server transcode +
   resolution. Also the manual escape hatch if a file mis-direct-plays.

5. **Server-side transcoding** (later) — for poor-network / weak-client cases. Bones kept for it.

## Scrubbing & seeking (responsiveness)

- **Seekable remux** — the current remux is forward-only, so a far-forward seek waits for the remux to
  produce everything in between. Fix: on a seek past the produced point, re-init FFmpeg from an input
  seek near the target timestamp and emit a fresh fragment, instead of waiting. This is the single
  biggest lever for responsive scrubbing across both remux and (future) on-device transcode.
- **Hybrid scrub preview** — show the (instant) Stash sprite tile while dragging, then refine with an
  on-device decoded frame at the exact position when the user pauses on it. Sprites are coarse on long
  videos (fixed tile count ÷ duration); on-device extraction is exact but has decode latency, so layer
  it as a refinement, not a replacement.

## Deferred ideas (revisit once core features + bug-fixing are solid)

### AI upscaling — "high quality from low bandwidth"
**Core goal:** usable video quality on **very low-quality / low-reliability networks** (poor cellular,
remote access, congested links) — get a watchable, good-looking stream when bandwidth is too low for
the real bitrate, by reconstructing quality on-device instead of shipping more bytes.

Concept is real & published: **content-aware (overfitted) neural super-resolution** — train a *small*
SR model per video on the server (CUDA/CPU), ship the low-res stream + the tiny model, reconstruct
high quality on-device (refs: NAS / NEMO / LiveNAS). The compact "data" = **per-video model weights**
(~tens of KB–few MB), NOT per-frame residuals.

Sequencing so nothing is wasted (slots into the existing AVPlayerItemVideoOutput frame-tap that
currently feeds the live blur):
- **Phase A (cheap, validates pipeline):** optional **MetalFX spatial upscale** toggle — generic,
  hardware, no server/training. Proves the real-time render path + thermal/battery envelope.
- **Phase B (the full idea):** a **Stash plugin** trains tiny per-video SR models; the app swaps that
  model into the *same* Core ML inference slot from Phase A. Identical render path, only the model
  source changes.

Honest constraints / pushback:
- Real-time per-frame NN inference is the binding limit (battery/thermals). Budget for ~1080p target
  on recent devices, not 4K/60.
- Per-video training is real server compute (minutes–hours each) → opt-in per video, not whole library.
- For a self-hosted LAN/Tailscale setup, direct play of the original is often already pristine →
  upscaling mainly pays off for remote/cellular viewing.
- Apple has no "upscale with my vectors" API; MetalFX = generic, Core ML = run our own model.

### Instant-start preview preloader (Stash plugin + app)
Make every video *feel* like it loads instantly. A Stash plugin pre-generates, for every file, a short
(~3 s) opening clip encoded for maximum streaming compatibility + decent quality (e.g. H.264/AAC
faststart MP4), stored on fast storage. On playback the app starts that tiny preview **immediately**,
then silently swaps to the real file (seeking to the matching position) once it's ready — so the user
never sees a spinner.
- App side: play preview → preload/remux the real stream in the background → seamless hand-off
  (crossfade or frame-matched switch at ~3 s). Pairs naturally with the loopback remux feed.
- Plugin side: batch-generate previews (CUDA/CPU), keep them tiny, index them so the app can fetch the
  preview URL per scene.
- Open questions: exact-frame switch vs. small overlap; audio continuity; storage/cleanup policy.

### XR glasses support (Viture Pro XR et al.)
Develop the capability to play video on XR/AR glasses — including VR/180°/360° and big-virtual-screen
viewing — with a clean handoff (no duplicated video mirrored on the phone screen).
- Known constraint: iOS restricts head-tracking IMU access from the glasses, which limits true
  head-locked virtual-display behavior vs. what the Steam Deck / decky-XRGaming achieves. Plan around
  what iOS *does* allow (external-display / AirPlay-style output, flat big-screen, side-by-side for
  VR videos) and revisit IMU as the platform evolves.
- Revisit alongside / after core playback; the Android app (later) may be the better home for full
  head-tracked virtual displays.

## Downloads & offline

- **Download videos for offline viewing**, with a choice of source:
  - **Original file** (as-is from Stash).
  - **Stash-transcoded version** (ask the server for a smaller/compatible encode).
  - **On-device transcode on the fly** (reuse the FFmpeg engine to produce a smaller/compatible file
    locally).
- **Downloaded Videos management screen** — list/manage offline videos (size, source, delete, play
  offline, re-download at different quality).

## Library & UX redesign

- **Rework the filter/sort chips UI** (the current chip row needs a cleaner interaction model).
- **Integrate search into the main library UI** via a **pull-down** (scroll-to-reveal search field)
  instead of a separate Search tab/menu.
- **Filter by favorites.**

## Stash feature parity

- **Favorites** — add/remove **performers, tags, and scenes** to favorites (and surface/filter by them).
- **Rate scenes** (star rating).
- **O-counter** ("ejaculation counter") support — increment/track per scene, like Stash.
- **Stash markers** support — view/seek to (and ideally create) scene markers.
- **Metadata search / auto-fill** — integrate Stash's scene & performer scraping/identify so missing
  metadata can be searched and filled from the app.

## Integrations (large lifts)

- **Site integrations** — simpcity.cr, empornium, and possibly others (browse/grab content).
- **Multi-threaded downloader that adds directly to the Stash library** — parallel downloads that hand
  finished files to Stash for import. Big effort; sequence carefully.

## Other
- Android app — later.
