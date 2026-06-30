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

## Deferred ideas (revisit once core features + bug-fixing are solid)

### AI upscaling — "high quality from low bandwidth"
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

### Other
- XR glasses (Viture Pro XR) VR video playback — deprioritized (iOS blocks IMU access).
- Android app — later.
