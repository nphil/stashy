# Stashy — Roadmap & Deferred Ideas

Working notes so intent survives across sessions. Core tenets: **fast, responsive playback +
scrubbing**, **direct-play first**, on-device FFmpeg as the fallback, minimal server load.

## Playback pipeline

**Current shipping state:** Direct play for H.264-in-mp4/mov (native HW decode, instant seeks); HEVC /
foreign-container H.264 → **on-device linear remux over loopback HLS** (smooth playback, confirmed
on-device); everything Apple can't decode → Stash HLS.

### What works now ✅ (linear-remux baseline — still current as of v1.0.184; seek-by-reinit now layered on top)
- **Linear continuous remux → byte-range HLS over loopback** plays HEVC (incl. hev1→hvc1) smoothly
  on-device. Fast start (~2s), flat memory, no crashes. This is the default for the remux class.
- **4 MB read-ahead** on the source AVIO (one HTTP request per slab, not per 64 KB) — essential; without
  it a 4K file produced far too slowly.
- **Forward-buffer cap (15s)** stops AVPlayer from prefetching the whole VOD over the instant loopback.

### Shelved: on-demand *segmented* HLS (choppy)
The "gold standard" — keyframe-accurate VOD segments produced on demand (`HLSSegmentProducer`,
`LocalHLSStream`) — gave **excellent seeking** (seek anywhere ~1-2s) but **choppy playback across every
file** (4K and 1080p). Root cause: each segment is muxed by an *independent* FFmpeg output context, which
introduces frame-timing / AAC-priming discontinuities at every segment boundary that AVPlayer renders
unevenly (and eventually stalls). Code is kept, disabled (`buildHLS` is no longer called). To revive it,
segments must come from **one continuous muxer** (like ffmpeg's `hls` muxer) rather than per-segment muxing.

### ✅ SHIPPED: fast seeking on the linear path (seek-by-reinit)
Linear remux was forward-only, so a far-forward seek waited for it to reach that point. Fixed without
reintroducing segment choppiness: on a seek before the stream's start or past the produced/seekable point,
`ScenePlayerModel.seek(to:)` **restarts the linear remux/transcode input-seeked (`av_seek_frame`) near the
target keyframe** (`reinitLocal(at:)`, zero-based) and rebuilds the loopback stream from there — playback
stays one continuous mux = smooth. A `timeOffset` maps stream-relative → absolute so the scrubber shows
real time; the `seekTarget`/`seekHoldUntil` hold pins the thumb where the finger releases. The loading
donut was tuned to match (warm per-seek estimate + snappy curve, and a file-weight-scaled expected time —
see LoadEstimator). **Do not disturb the seek-hold logic.** (Reinit debounce still deferred — seek fires
only on drag release, so mid-drag thrash isn't a concern.)

### ✅ SHIPPED (2026-07-04/05) then ❌ M-A REMOVED (`c088325`, 2026-07-05): on-device transcode playback tier (M-A) + manual server-quality menu (M-B)
**Only M-B still ships.** M-A — the on-device streaming transcode tier (`FFmpegStreamTranscoder` +
`LocalTranscodeStream` + `FFmpegAudioReencoder`, HW decode → `h264_videotoolbox` → fragmented MP4, audio
copy-or-AAC-reencode, seek-by-reinit, `armWatchdog` auto-fallback) — was **deleted the day after it
shipped** (`c088325`): flaky, its seek-by-reinit made scrubbing glitchy, and it pulled the whole original
over the network to re-encode locally. The "Apple can't decode at all" bucket now routes straight to
Stash **server** HLS at any resolution (see the routing comment in `Scene.swift`); the deleted code is
git-history-only. M-B = the player gear → force Stash HLS at a chosen resolution (the `?resolution=`
duplicate-param bug fixed; resumes at the exact position) — alive and well. Original design below, kept
as the record. Both built on the **file** transcoder shipped in v1.0.12x (`FFmpegTranscoder`: libavformat
demux → FFmpeg decode → libswscale NV12 → VideoToolbox `h264/hevc_videotoolbox` encode → MP4; audio copy
for AAC/AC3/EAC3/MP3/ALAC). That class survives as the Downloads-flow encode core.

- **M-A — Streaming on-device transcode tier.** Insert **between remux and the Stash server fallback**:
  `direct-play → remux → on-device streaming transcode → Stash server (final fallback)`. Needs a
  *streaming* variant of `FFmpegTranscoder` — transcode-ahead into fragmented MP4 served over the
  loopback with **seek-by-reinit** and pacing, analogous to `LocalRemuxStream` (reuse `LoopbackServer`
  + `FMP4Index`). Only fires for the "Apple can't decode it at all" bucket (VP9, 10-bit 4:2:2/4:4:4
  HEVC, exotic) — everything else already remuxes. **Gate it**: attempt on-device ≤1080p always, ≤4K
  only for lighter codecs; heavy 4K software-decode → skip straight to the server (a server GPU is
  faster and won't thermally throttle the phone). **Auto-fallback**: if the on-device transcode can't
  keep the buffer fed, fall to the server automatically (reuse the `armWatchdog`/`buildFallback`
  machinery). Rationale/tradeoff analysis captured in chat 2026-07-03 (privacy/server-load/offline win;
  server better for heavy-4K/long sessions).
- **M-B — Player-overlay gear button → manual quality menu (server-side transcode).** A gear/settings
  button on the playback overlay opening a menu of manual quality options (resolution/bitrate) that
  **force the Stash server HLS transcode** at the chosen setting — the deliberate escape hatch for
  **cellular/limited-bandwidth streaming** (pick a lower rung to save data). This is the concrete form
  of roadmap items 3 & 4 below. Distinct from M-A: M-A is automatic on-device; M-B is a manual,
  server-side override the user selects. Wire through `ScenePlayerModel` route override + `Player
  ControlsView` overlay.

### ★ Adaptive bitrate streaming (ABR) over flaky / cellular networks (owner-requested 2026-07-10)
**Goal:** robust playback on poor/variable links — auto-adapt the stream up/down with measured bandwidth
so it never stalls on a bad connection and uses full quality on a good one, with **zero manual fiddling**.
This is the automatic sibling of M-B (which is a *manual* server-quality override).

**The gap today.** Every current path is single-rendition: direct-play (no adaptation), remux, or M-B's
manual Stash HLS at one chosen resolution. None adapts mid-stream — a
flaky link means either a stall (rung too high) or a manual downshift. AVPlayer does ABR *natively and
well*, but **only when handed a multi-variant HLS master playlist** (`#EXT-X-STREAM-INF` variants with
`BANDWIDTH`/`RESOLUTION`/`CODECS`). Stash serves only per-resolution single streams, so AVPlayer has
nothing to switch between.

**Options, cheapest → most robust:**
- **A — synthetic master over Stash's existing renditions (cheap, fragile).** App (or a tiny plugin
  endpoint) synthesises a master `.m3u8` listing Stash's LOW/STANDARD/STANDARD_HD/FULL_HD HLS endpoints
  as variants with estimated `BANDWIDTH`. AVPlayer picks by throughput. **Why it's fragile:** each Stash
  rendition is an *independent on-the-fly transcode* → GOP/segment boundaries and PTS are **not aligned**
  across renditions, so a mid-stream switch glitches/seeks (AVPlayer ABR assumes timestamp-aligned
  segments from one packaging), and every probe/switch spins a fresh ffmpeg on the server (thrash, slow
  switches). Okay for coarse up/down, not truly seamless.
- **B — plugin pre-generates a proper aligned HLS ladder (robust; the real answer).** A **Companion
  plugin** task pre-transcodes a scene into a multi-bitrate ladder (e.g. 480p/720p/1080p) with **aligned
  keyframes + identical segment duration** (`-force_key_frames`/fixed GOP, same `hls_time`) + a master
  playlist, written to the plugin's served `cache/` dir (Range-capable — reuses the exact companion
  transcode→`findJob` progress→served-file delivery already shipped). App plays the master; AVPlayer does
  true seamless ABR because segments align. **Cost:** encode time + storage per scene → opt-in per
  scene / favourites, or a background library pass; cheap on the **P40 (NVENC)**, which the plugin
  already drives. This is where "leverage the Stash plugin to make it robust" pays off.
- **C — on-the-fly aligned packager (hard, probably skip).** Plugin endpoint that decodes once and fans
  out to N aligned encodes on a shared keyframe grid, streaming. Basically reimplementing an HLS packager
  — not worth it vs. pre-gen (B) unless storage is the blocker.

**App-side pieces (needed for any option, ties into pending "Cellular data-saver" task):**
- Add an **"Auto" rung** to the M-B quality menu (selects the ABR master); keep the manual rungs as a hard
  override.
- **Data-saver cap:** per-`AVPlayerItem` `preferredPeakBitRate` / `preferredMaximumResolution` to ceiling
  the rung on cellular; persist a "max quality on cellular" setting.
- **Fast start:** bias the first segment to a low rung, then ramp (AVPlayer mostly handles this given a
  good master).
- Honest framing (same as AI-upscaling): on a **LAN/Tailscale** setup direct-play is already pristine →
  ABR earns its keep on **cellular / remote / congested** links, exactly the case the manual M-B menu
  half-covers today.

### ★ PRIORITY — Player UI rework + playback speed / AI slow-motion (owner-requested 2026-07-04)

- **Netflix-style fullscreen player UI + finish the portrait-controls polish (owner-requested; partially
  shipped).** Rework the fullscreen controls layout taking the **Netflix iPhone player as the design
  reference** — the large centred transport cluster (back-10s / play-pause / forward-10s), a clean top bar
  (title + close), a bottom scrubber with elapsed/remaining, and a small cluster of secondary controls
  (speed, audio/quality, episodes) rather than everything crammed on one bar. Reuse the existing gear
  (quality), volume, and status-badge components, re-laid-out for the immersive layout. Owner is exacting
  about native feel — match Apple/Netflix animation physics and spacing.
  - **✅ Shipped in the orientation/controls pass (v1.0.199–200):** sticky fullscreen with **✕-to-inline**
    exit (no auto-exit-on-tilt race — the old landscape/portrait regression); manual fullscreen → landscape
    (portrait for vertical videos), X to leave; **portrait volume slider expands vertically** (no clip);
    **status badges stacked vertically** (resolution over method pill, one-pill-width, no truncation) in
    both orientations; inline back chevron removed (swipe-back leaves). The control layout is orientation-
    driven (`landscape = width > height`), so portrait-fullscreen (vertical videos) shares the portrait
    layout.
  - **⏳ Still to finish (fold into this rework):** the portrait bottom-controls fine layout — scrubber not
    too high, **use the vertical gap between the progress bar and the bottom row**, keep the transport
    cluster centred on the video, and decide **elapsed/duration placement** (keep both in the bottom row vs
    move elapsed left / remaining right of the scrubber). Needs on-device visual iteration.
- **Custom WYSIWYG player-control layout editor (Settings) — owner-requested 2026-07-04.** A Settings
  entry opens a "custom layout" mode where the user hand-places the on-video controls, with **separate
  layouts for landscape (fullscreen) and portrait (inline)**. The default ships as the Netflix-style
  layout above; this lets power users rearrange it (so this item can *supersede / extend* the Netflix
  rework rather than duplicate it).
  - **WYSIWYG canvas:** the editor shows a representative **fullscreen still behind the controls** so
    placement is judged against real framing. Use a **freely-distributable, video-related image** — a
    **Big Buck Bunny** frame (Blender Foundation, **CC-BY 3.0** — free to use *and* redistribute, bundle
    the attribution) is a good fit; alternatively a generated gradient/placeholder to avoid any asset
    licensing entirely.
  - **Drag from a side palette:** a panel listing every available control — play/pause, rewind & forward
    (skip ±10s), exit ✕, settings/gear (quality), volume, scrubber/progress bar, playback-speed, stats,
    and the quality/method status badges. Drag a control onto the canvas to place it; drag an placed one
    to move or back to the palette to remove.
  - **Snap-to-grid:** while dragging, **show the grid slots** the control can drop into so everything
    stays aligned; **button sizes are predetermined per control** (a small set of size classes) so the
    composed layout always looks clean. Enforce sane constraints (no overlaps; keep mandatory controls
    like the scrubber present).
  - **Persistence + render:** store the two per-orientation layouts (e.g. a `PlayerControlLayout` of
    `{controlID, gridSlot, sizeClass}`); `PlayerControlsView` renders from the saved layout, falling back
    to the default. Sizeable feature — spike the drag/grid/drop-target interaction and the layout model
    first; reuse the existing control components as the draggable pieces.
- **✅ SHIPPED — Playback speed control** in the player menu (0.25× / 0.5× / 0.75× / 1× / 1.25× / 1.5× /
  2×). A Podcasts-style **speed pill** on the control row (left of the gear) opens a rate menu; audio is
  **pitch-corrected** (`AVPlayerItem.audioTimePitchAlgorithm = .timeDomain`) so every speed keeps natural
  pitch. Rate is published via `AVPlayer.defaultRate` + a re-invoked `play()` so it applies live while
  keeping `automaticallyWaitsToMinimizeStalling` on (and won't force-start while paused). `PlaybackEngine`
  gained `playbackRate` + `slowMute`; `ScenePlayerModel` re-applies both in `makeEngine`, so a mid-scene
  speed change **survives every engine rebuild** (seek-reinit / quality / fallback).
- **✅ SHIPPED (partial) — slow-motion audio behaviour toggle.** The speed menu carries a persisted
  **"Mute when slowed"** preference: below 1× either mute (default) or hear pitch-corrected slow audio.
  `slowMute` is a separate output-volume gate so it never clobbers the user's chosen volume. **Still
  deferred:** option (b) *normal-(1×)-speed audio under slow video* — that needs a decoupled audio
  timeline (`AVSampleBufferAudioRenderer` / a separate normal-rate pass); the shipped toggle covers
  mute-vs-pitch-corrected, not the fully-decoupled case.
- **★ AI / motion-interpolated slow-mo (on-device) — researched 2026-07-05, ✅ SHIPPED & working
  (Phases 1a/1b/2, v1.0.192–207; adaptive per-rate interpolation factor added `9344e8c` 2026-07-06;
  still opt-in beta via `aiSlowMoEnabled`). Remaining: the standalone 0.25×-won't-play bug, a dedicated
  video output for inline (blur-active) playback, optional Phase 2b (Frame Rate Conversion) / Phase 3
  (export).** Plain
  slow playback (setting `AVPlayer` rate < 1) doesn't create frames — it just holds each real frame on
  screen longer, so a 30fps file at 0.25× shows ~7.5 distinct fps = judder. Fix = **synthesise the
  in-between frames** so slowed footage looks like true high-fps slow motion.
  - **Native tool (chosen): `VTFrameProcessor`** — VideoToolbox's ML/Neural-Engine frame processor, new in
    **iOS 26** (the app's target) and supported on the owner's A19 iPhone 17 Pro. No Core ML model to ship,
    no licensing. Two relevant effects: (a) **Frame Rate Conversion** (quality) — `VTFrameRateConversion
    Parameters` takes an **`interpolationPhase` array of floats in [0,1]** giving *where* to insert frames
    between two source frames, array length = *how many* (so 0.25× → `[0.25,0.5,0.75]` = 3 synthetic frames
    = 4×; **arbitrary factor**); (b) **Low-Latency Frame Interpolation** — a real-time (video-conferencing)
    2× doubler, optional upscale. Both are `async` over `CVPixelBuffer`s.
  - **Key feasibility insight:** slow-mo *relaxes* the real-time budget (0.25× = 4× wall-clock time per
    output frame), so even the "offline"-grade Frame Rate Conversion can plausibly run live *during*
    slow-mo — the opposite of the usual can-the-NPU-keep-up-at-30fps problem.
  - **Architecture:** `AVPlayer` can't have frames injected (it renders its own into `AVPlayerLayer`), so
    slow-mo needs a **dedicated render path that engages only in slow-mo**: pull consecutive decoded frames
    from the **existing `AVPlayerItemVideoOutput` tap** (already feeding the live blur → **engine-agnostic**:
    works for direct / remux-loopback / server-HLS alike, post-decode), run `VTFrameProcessor` between each
    pair, and present the synthesized stream on an **`AVSampleBufferDisplayLayer` paced by `CADisplayLink`**
    at the slow rate with `AVPlayerLayer` hidden. **Audio = muted**, which reuses the **already-shipped
    "Mute when slowed" toggle** and sidesteps the whole audio/video-sync problem.
  - **Rejected/inferior alternatives:** Vision `VNGenerateOpticalFlowRequest`+Metal warp (more code, lower
    quality, only needed for pre-iOS-26); Core ML RIFE/FILM (heavy to convert/ship, marginal A-series
    real-time, redundant vs VTFrameProcessor); frame blending/crossfade (cheap but just ghosts motion — keep
    as a **low-tier fallback** if the NPU can't keep up); offline pre-generate (on-device export or P40
    plugin) = highest quality but not live → future "export smooth slow-mo clip" action.
  - **Guardrails (per the never-stutter rule):** gate on device capability, interpolate **only around the
    playhead**, run the processor **off the render thread**, watch thermals/battery, and **fall back to plain
    slow playback** (or cheap frame-blend) if it can't keep the buffer fed — never starve real playback.
  - **Phasing:** **Phase 1a ✅ SHIPPED (v1.0.192)** — `Services/SlowMoInterpolator.swift`, a self-contained
    wrapper over `VTFrameProcessor` low-latency interpolation (two decoded frames → N synthesised frames;
    `VTLowLatencyFrameInterpolationConfiguration/Parameters`, `VTFrameProcessorFrame(buffer:presentation
    TimeStamp:)`, IOSurface-backed BGRA destination pool). Non-isolated so no non-Sendable value crosses an
    actor boundary internally; returns `[]` on failure. **Verified compiling on the iOS 26 runner SDK** —
    that retires the new-API risk. **API gotchas found (for Phase 2):** `interpolationPhase` is `[Float]`
    (binding refines the `NSNumber` array); `process(parameters:)` is `async throws`; `endSession()` is
    non-throwing. Not yet wired to playback (that's 1b), so it's inert in the shipped build.
    **Phase 1b-A ✅ SHIPPED (v1.0.193)** — the pipeline runs live but doesn't yet render. `Services/
    SlowMoRunner.swift` (a `@MainActor` `CADisplayLink` driver) engages at ≤0.5×: pulls consecutive decoded
    frames from `PlaybackEngine.frameOutput` (the shared `AVPlayerItemVideoOutput`, newly exposed), feeds each
    new pair to the interpolator **single-flight** (drops pairs if the NPU lags → never stalls real playback),
    and reports live telemetry to a **"Slow-mo (AI)" section in the Stats overlay** (Active/Unsupported, source
    vs synthesized frame counts, per-frame ms). Zero render risk — what's on screen is untouched; this is the
    observable proof the pipeline works end-to-end. Concurrency shape: interpolator is `@unchecked Sendable`,
    touched single-flight; frame pairs cross to `Task.detached` via an `@unchecked Sendable` box; results hop
    back via an `await self?.method()` (not `MainActor.run`, which trips "sending self"). *(Also fixed a latent
    strict-concurrency error a broader recompile surfaced: `RemoteLog.enable()` is nonisolated and used
    `UIDevice.current` (now `@MainActor`) → switched to `ProcessInfo.operatingSystemVersionString`.)*
    **⚠️ Fragility found (v1.0.195) — now OPT-IN (default OFF).** `VTLowLatencyFrameInterpolation` **hard-crashes
    inside the framework** (SIGABRT, uncatchable from Swift) on certain decoded frames — reproduced on a 720p
    HEVC 0.9 Mbps file, and it persisted after a server transcode to direct-play H.264 at the same ≤0.5× line,
    so it's the interpolator, not the codec/remux path. Apple's own forums report undocumented dimension/aspect
    restrictions (e.g. 144×144 fails) and reproducible crashes on iOS 26.3, and the config vends its own required
    pixel format via `frameSupportedPixelFormats` that we currently ignore (we force `32BGRA`; ML video models
    usually want biplanar YUV). So slow-mo is now gated behind `aiSlowMoEnabled` (speed-menu "AI slow-mo (beta)"
    toggle, default off) and the "Slow-mo (AI · beta)" Stats section + a pre-`process()` `RemoteLog` line now
    surface the decoded **source W×H + pixel fourcc** to compare a crashing file against a working one.
    **✅ ROOT-CAUSE RESOLVED (v1.0.205–206) — interpolation confirmed producing frames on-device.** The
    `-19730 "Processor is not initialized"` was TWO bugs, both misdiagnosed above: **(1) pixel format** — we
    forced `32BGRA`; the model requires the config's own `sourcePixelBufferAttributes` format, which it reports
    as **`420v`** (biplanar YUV video-range). Fix: build the source/dest `CVPixelBufferPool`s from
    `sourcePixelBufferAttributes`/`destinationPixelBufferAttributes` and convert the player's BGRA frames →
    420v (and to the interp size) with **one CoreImage pass** (dropped the old vImage BGRA scaler). **(2) frame
    dimension** — the model has a **device-specific max (~720p on M1 Pro)** that iOS 26 gives *no API to query*
    (Apple engineer confirmed OS 27 only); exceeding it throws the misleading -19730. Our old workaround scaled
    sub-1080p *UP* to 1920×1080 → guaranteed failure at every size. Fix: **cap** interpolation at **1280×720**
    (downscale larger, preserve aspect, even dims; smaller stays native); the render view upscales for display.
    The earlier "1280×720 hard-crash" was the BGRA bug, not a size crash. Still `aiSlowMoEnabled`-gated (beta).
    **Phase 2 ✅ SHIPPED (v1.0.207)** — **4× interpolation** (3 mids at 0.25/0.5/0.75; `interpolatedFrames=3`,
    phases derived so the count lives in one place) for ~2×-source smoothness at 0.5× and source-fps at 0.25×.
    **Phase 1b-B ✅ SHIPPED (v1.0.201)** — the
    synthesised frames render on screen: `Features/Player/SlowMoRenderView.swift` (a Metal MTKView + CIContext,
    reusing the `LiveBlurBackdrop` path) overlays the player surface while engaged, and `SlowMoRunner` presents
    the **real + synthesised** frames through it paced by a wall-clock display-time FIFO (`startWall +
    (itemTime−anchor)/rate + latency`, 0.15s for the causal mid-frame), single-flight, first frame seeded (no
    black flash). Chose the Metal path over `AVSampleBufferDisplayLayer`/`CMTimebase` (lower blind-API risk,
    proven code). **v1 caveats / next tuning:** shares the blur's `AVPlayerItemVideoOutput` so *inline* (blur
    active) may drop frames while *fullscreen* (blur paused) is clean → give slow-mo its **own** video output;
    zoom during slow-mo not mirrored on the overlay. ✅ Adaptive interpolation count per playback rate shipped
    (`9344e8c`, 2026-07-06 — `SlowMoRunner.desiredMids(forRate:)` scales mids 0.5×→3, 0.25×→7). **Still open:**
    the standalone "0.25× won't play at all" bug. **Phase 2b (optional)** — swap the low-latency effect for Frame
    Rate Conversion (quality path) with a per-rate `interpolationPhase` for arbitrary-factor smoothness.
    **Phase 3 (optional)** — an "export smooth slow-mo clip" action (on-device or P40 plugin) for a max-quality
    result.
- **Mini-player / undock the player (owner-requested 2026-07-04).** Let the player detach from the scene
  screen into a floating, draggable mini-player (à la Apple Podcasts / YouTube PiP) so it keeps playing
  while the user browses performers, links, other scenes, etc. Would make navigation-away seamless (see
  below) and enable true picture-in-picture. Needs the player model + engine to outlive `SceneDetailView`
  — hoist it to an app-level holder (an environment-scoped `NowPlaying` coordinator that owns the single
  `ScenePlayerModel`) rather than per-screen `@State`, and reuse `AVPictureInPictureController` for system
  PiP. **Related:** the current "resume where you were on return from a performer/link" is a *safe reload*
  (teardown + resume-seek), because keeping the engine alive across a `path=[]` pop-to-root would crash on
  dealloc; the mini-player's app-level model is what makes a *zero-cost* pause/hand-off safe.
- **★ Zoom-follow / auto-tracking zoom (owner-requested 2026-07-04) — spike needed.** While zoomed into a
  video, a player tool lets the user **pause, free-draw a region/shape with a finger on the frozen frame,
  confirm it, and then on play the zoom auto-pans/scales to keep that region framed as it moves** — so the
  user doesn't have to keep flicking to follow a subject. This is **on-device visual object tracking**
  driving the existing pinch-zoom pan offset:
  - **Tracking engine:** Vision `VNTrackObjectRequest` / `VNTrackingRequest` (seeded with the drawn
    region's bounding box), or the newer object-tracking APIs, run frame-by-frame (or on a sampled
    cadence) to produce a moving bounding box; smooth it (low-pass / prediction) and map it to the
    `ZoomablePlayerSurface` pan+scale so the subject stays centred. Free-form shape → use its bounding box
    (optionally its centroid) for the tracker.
  - **Sync:** tracking must run against the *displayed* frames (works for every playback mode — direct,
    remux, server HLS) via the player's `AVPlayerItemVideoOutput` pixel buffers
    (already tapped for the live blur), so it's engine-agnostic.
  - **Constraints:** on-device only, gated on device capability, and — per the hard rule — it must **never
    delay/stutter playback**: run tracking off the render path (sampled, with prediction between samples),
    drop to manual pan if it can't keep up, and let the user cancel/redraw. Clarifying Qs to resolve at
    build time: single region only or multiple? re-acquire automatically if the subject leaves frame &
    returns, or stop? keep zoom scale fixed or also auto-zoom to the region size? Heaviest CV item on the
    roadmap — spike Vision tracking accuracy/perf on a real clip first.

1. **Routing brain — capability detection** ✅
   - **Direct play** — H.264 in mp4/mov/m4v → AVPlayer plays the file URL directly.
   - **HLS** — everything else (HEVC, H.264-in-MKV, MPEG4-ASP/VC1/VP9/AV1, 4:2:2/4:4:4 HEVC that Apple
     can't decode at all) → Stash server transcode. Works today.

2. **On-device local playback — on-device HLS, IMPLEMENTED (under on-device verification).** The earlier
   single fragmented-MP4 served *progressively* over loopback does **not** work with AVPlayer: for a
   growing/unknown-length file it re-requests from byte 0 forever, or errors ("operation stopped") on a
   chunked stream — AVPlayer won't progressive-play an open-ended MP4. Confirmed across many iterations.
   The fix delivers the same remux as **HLS** instead, which is the model AVPlayer is built for:
   - **`FMP4Index`** walks the growing fragmented MP4 (init = ftyp+moov, then one moof+mdat per keyframe)
     and emits an **HLS byte-range media playlist** (EVENT type, `EXT-X-MAP` + `EXT-X-BYTERANGE`). A
     fragment is listed only once the next appears, so every advertised range is fully produced. The
     remuxer now uses `frag_keyframe` *only* (no frag_duration) so every moof starts on a keyframe = a
     valid independently-decodable segment; `codec_tag=0` puts hvc1 param sets in the init segment.
   - **Source I/O fixed**: a 4 MB read-ahead cache in the remux read callback replaces one URLSession
     range request per 64 KB read (which made a 4K file produce only ~400 KB before the player gave up).
   - ✅ **Seekable now** (seek-by-reinit shipped — see above): a far/backward seek restarts the mux input-
     seeked near the target keyframe instead of waiting.
   - ❌ **On-device transcode tier (M-A) shipped then REMOVED** (2026-07-04 → `c088325`, 2026-07-05):
     MPEG4-ASP/VC1/VP9, software-AV1, exotic now go to the Stash **server** HLS transcode at any
     resolution — the on-device tier was flaky, made scrubbing glitchy, and pulled the whole original
     over the network to re-encode. On-device REMUX and the Downloads-flow transcode are unaffected.

3. **Quality / gear selector** — Auto / Direct / On-device / Server transcode + resolution; also the
   manual escape hatch. *(Mostly shipped as M-B: gear menu with Auto + server-resolution rungs; an
   explicit Direct / On-device method forcing is the only part still open.)*

4. **Server-side transcoding controls** — quality/resolution options for the HLS path. ✅ Shipped as M-B.

### Notes / facts established
- Apple's HEVC decoder (Safari + iOS, same stack) only handles 4:2:0 (Main/Main 10); **4:2:2 / 4:4:4
  (Rext) HEVC cannot play on Apple at all** — must transcode. (Chrome bundles its own decoder, hence
  "plays in Chrome, not Safari/iOS".)
- HEVC `hev1` (in-band parameter sets) renders black in AVPlayer; `hvc1` is required — a remux retag,
  but only useful once on-device delivery works.

## Scrubbing & seeking (responsiveness)

- ✅ **Seekable remux — SHIPPED** (seek-by-reinit). A seek before the stream start / past the produced
  point re-inits FFmpeg input-seeked (`av_seek_frame`) near the target keyframe and rebuilds the loopback
  from there, instead of waiting; the donut's expected time is warm-per-seek + file-weight-scaled. Works
  on the remux path (the on-device transcode playback tier was removed — `c088325`). (Reinit debounce
  still deferred.)
- **Hybrid scrub preview** — ✅ SHIPPED for downloaded/local files 2026-07-14 (`8a091ac`;
  `Services/ScrubFrameProvider.swift` — sprite tile as the instant placeholder, refined by an exact
  `AVAssetImageGenerator` frame, gated to `file://` URLs). Remaining gap: exact-frame refinement for
  *streaming* sources (arbitrary-frame decode needs the network per frame). Original idea: show the
  (instant) Stash sprite tile while dragging, then refine with an on-device decoded frame at the exact
  position when the user pauses on it.
- **Watch-heat overlay on the scrubber ("most replayed").** ✅ SHIPPED 2026-07-11 (`633e9b8`,
  `Services/WatchHeat.swift`) — smoothed/normalised curve above the ScrubBar track, drawn only while
  scrubbing; Settings → Player toggle (default ON; off also stops tracking) + Clear data. Original
  design (matches what shipped): a YouTube-style heat curve/histogram drawn
  *on top of* the progress bar showing where the user has spent the most time actually watching this
  video. Stash doesn't provide this, so it's **built locally on-device**:
  - **Data model:** bucket each video's timeline into N bins (e.g. ~200 bins, or ~1–2s each, capped).
    Store an array of accumulated watch-seconds per bin, keyed by scene id, in a small persistent store
    (JSON/SQLite/`Application Support`), scoped per server.
  - **Accrual:** from the player's periodic time observer, credit elapsed *continuous playback* time to
    the current bin — only while `isPlaying` and not scrubbing, and only for forward real-time progress
    (ignore the jump when a seek lands, so seeking doesn't inflate a bin). This naturally makes
    rewatched/looped regions accumulate the most.
  - **Render:** an area/curve (smoothed with a light moving average, normalized to the max bin) layered
    behind/over the `ScrubBar` in `PlayerControlsView`, tinted with the accent color, low opacity so it
    doesn't fight the buffered/played fill. Optionally a subtle "peak" marker at the hottest point and a
    "jump to most-watched" affordance.
  - **Niceties:** decay/cap so a single obsessive session doesn't permanently dominate; a settings
    toggle to show/hide and to clear the history; keep the store bounded (evict least-recently-watched
    videos). Purely local + private (fits the no-server-load, on-device tenet). Could later fuse with the
    Vision motion-analysis idea to seed a heat curve even on first watch.

## Comparative study — ideas from 1letzgo/stashy (2026-07-01)
Studied a second, broader Stash iOS/tvOS client (README, CLAUDE.md, GraphQLClient, PaginatedLoader,
VideoAnalysisManager). It leans on **server-side transcode + KSPlayer + a manual quality picker** rather
than on-device remux — so our playback pipeline (direct-play + on-device HEVC/MKV remux over loopback
HLS) is materially more advanced and lighter on the server. Where they're ahead is **feature breadth**.

**Robustness already adopted from the study (done):**
- **DB-lock retry** in `StashClient.query` — Stash is SQLite-backed; a concurrent write can briefly
  return "database is locked". We now back off (500/1000/1500ms) and retry up to 3× instead of failing.
- **Generic `PaginatedLoader<T>`** — replaced three near-identical view models (scenes, performers,
  performer-scenes, tag-scenes) with one loader (keeps our page dedup, which their version lacks).

**Feature ideas worth stealing, roughly in build order:**
1. **Markers** (already planned) — view/seek to Stash scene markers; they ship a full `MarkersView`.
2. **Studios & Galleries & Images browsing** — three Stash content types we don't surface yet
   (`StudiosView`/`StudioDetailView`, `GalleriesView`, `ImagesView`). Studios is the smallest lift.
3. **Configurable Home dashboard** — user-arranged rows (recent scenes, top performers, studios, tags)
   as a landing surface above the tabs.
4. **StashTok / Reels** — a vertical swipeable feed over scenes, markers, and image clips; infinite
   scroll; auto-mute unless headphones are connected. Pairs perfectly with our fast-start playback.
5. **"Hot or Not" swipe-to-rate** — a gamified rating tool that feeds the rating system we just built.
6. **Universal search** across all content types; **tab show/hide/reorder** customization.
7. **Multi-server support** — `ServerConfig` list, Keychain-per-server, switch with an app-state reset.
   (Our `ImageCache` keys should become server-scoped when we do this.)
8. **401 handling** — surface an expired/invalid API key to the user instead of failing silently.

**Standout future idea — on-device Vision content analysis.** Their `VideoAnalysisManager` runs
`VNGeneratePersonSegmentation` + `VNDetectHumanBodyPose` + `VNGenerateOpticalFlow` (plus an
`MTAudioProcessingTap`) in real time to derive motion-intensity signals and classify scenes — to drive
interactive devices without an authored funscript. **We already have the frame tap** (the
`AVPlayerItemVideoOutput` feeding the live blur), so the same signal could power **auto-generated scene
markers, "skip to the action" chaptering, motion-peak scrub thumbnails, and smart previews** — an
on-device, privacy-preserving, genuinely differentiated capability. (Their device-sync category —
TheHandy / Intiface/Buttplug / FunScript — is a separate, optional feature area we haven't scoped.)

## Deferred ideas (revisit once core features + bug-fixing are solid)

### Performer social feed (Twitter/X) in the socials card
On the performer screen, when a performer has a Twitter/X link, use that card to show their latest
tweets, laid out to fit the card. **Feasibility caveats:** (1) X's API is paywalled and hostile to
scraping, and unauthenticated timeline embeds are increasingly locked down — likely needs a syndication
/ oEmbed endpoint, a self-hosted nitter-style proxy, or a lightweight server-side fetch; (2) content is
frequently NSFW, so any embedded webview/images must respect the app's blur toggles and age gating.
Scope as: fetch a few recent posts (text + first media), render compact rows inside the socials card,
tap-through to open the profile. Treat as best-effort/optional given the API constraints.

### AI upscaling — "high quality from low bandwidth"
**Core goal:** usable video quality on **very low-quality / low-reliability networks** (poor cellular,
remote access, congested links) — get a watchable, good-looking stream when bandwidth is too low for
the real bitrate, by reconstructing quality on-device instead of shipping more bytes.

Concept is real & published: **content-aware (overfitted) neural super-resolution** — train a *small*
SR model per video on the server (CUDA/CPU), ship the low-res stream + the tiny model, reconstruct
high quality on-device (refs: NAS / NEMO / LiveNAS). The compact "data" = **per-video model weights**
(~tens of KB–few MB), NOT per-frame residuals.

**BUILT & REVERTED (2026-07-09/10, v1.0.241–244 → reverted)** — the full postmortem, so the next
attempt doesn't re-learn it:
- **What shipped then came out:** zoom-gated live upscaling (MetalFX spatial 2×, later a second crop
  pass ≈4×, + unsharp mask) plus a one-shot `VTLowLatencySuperResolutionScaler` neural 2× of the paused
  crop (tiled past its cap). Owner verdict: still buggy in the field and visually not worth the
  complexity on a 720p source — everything removed; pinch-zoom / AI slow-mo / Lanczos untouched. The
  code lives in git history (`Services/UpscaleRunner.swift`, deleted ~v1.0.245).
- **Hard-won facts (iOS 26):** VT low-latency SR input caps at **960×960 on-device** and needs a fixed
  input size per session (model load > frame time ⇒ a live variable crop = session-rebuild storm; the
  visible rect's aspect changes continuously while panning). `scaleFactor` MUST come from
  `supportedScaleFactors(…)` — unsupported values fail SILENTLY into a green screen. Two
  `copyPixelBuffer` consumers on one `AVPlayerItemVideoOutput` steal frames from each other (slow-mo
  conflict). Never insert/remove an overlay via SwiftUI state at a zoom threshold — it races pinch.
  MetalFX spatial 2× diluted by a residual bilinear stretch reads ≈Lanczos (imperceptible).
- **iOS 27 revisit (the plan):** OS 27 adds the VTFrameProcessor capability-query APIs this generation
  lacks (real max dims, proper support checks). Re-attempt then, with what we now know.

**On-device generative SR — researched 2026-07-10 (the real "wow" path, both platforms):**
Qualcomm ships **Real-ESRGAN pre-optimised for Hexagon NPUs** (AI Hub / HuggingFace `qualcomm/…`),
benchmarked per 128×128→512×512 (4×) tile:
- **iOS (iPhone 17 Pro / A19 Pro), paused-frame enhance — the recommended next attempt:** convert
  Real-ESRGAN (x4plus for stills) to Core ML via coremltools (fixed 128 or 256 input, fp16/int8),
  ANE-dispatch, and drop it into the *tiled pause-enhance architecture from the reverted build* (tiling,
  overlap-composite, geometry latch, haptic — all proven; only the per-tile model call changes).
  Expect a few hundred ms–1 s per zoomed crop = fine for a paused still. True generative detail
  (hallucinated texture/skin), unlike spatial scalers. Ship the `.mlpackage` on-demand (~16–64 MB), not
  in the IPA. Avoids live-video flicker entirely (generative SR has no temporal consistency frame to
  frame — stills first is deliberate, not a compromise).
- **Android (Snapdragon 8 Elite), live generative SR — when the Android app exists:** 8 Elite runs
  compact Real-ESRGAN-General-x4v3 **w8a8 in 0.96 ms/tile** on the NPU (x4plus 12.6 ms/tile; 8 Elite
  Gen 5 is ~30% faster still) via QNN/ONNX-Runtime or LiteRT. A ~480×270 crop ≈ 15 tiles ≈ 15 ms ⇒
  60 fps live generative upscaling is genuinely feasible — stronger than anything iOS 26 can do live.
  Design note: budget for tile-seam blending + temporal shimmer mitigation before calling it shippable.
- **Server-side Real-ESRGAN (P40, companion plugin)** remains the max-quality option (x4 offline,
  ~1.5–3 h per 20-min 720p video): "enhance this scene once, keep forever" for favourites, riding the
  existing Companion transcode→progress→download infra.

Sequencing so nothing is wasted (slots into the existing AVPlayerItemVideoOutput frame-tap that
currently feeds the live blur):
- **Phase A (validates pipeline):** attempted via MetalFX (see revert postmortem above) — the render
  path and thermal envelope ARE proven; the visual payoff at 720p wasn't there for a spatial scaler.
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

### XR glasses support (Viture Pro XR et al.) — "phone becomes the remote"
**Refined vision (Netflix-style handoff).** When XR glasses are connected (they present to iOS as a
standard external DisplayPort display over USB-C), Stashy switches into a big-screen "10-foot" layout on
the glasses, and when a video goes fullscreen the **entire phone screen becomes a gesture remote /
trackpad** — exactly how Netflix on iPhone drives an external screen while the handset turns into a
controller.

**Feasibility: confirmed possible on iPhone 15+ (USB-C, DisplayPort out up to 4K60).** Two building
blocks, both first-class iOS APIs:
- **External-display scene** — `UIWindowSceneSessionRoleExternalDisplayNonInteractive`: declare a second
  scene configuration in Info.plist; when a display connects, iOS creates a scene for it and the app
  renders **separate** SwiftUI content there (not mirroring). This is what lets the glasses show the
  big-screen UI while the phone shows the remote. Detect connect/disconnect via the external-display
  scene lifecycle (or `UIScreen.didConnect/didDisconnectNotification`, though `UIScreen` is being phased
  out in favor of scenes). Audio auto-routes over DP.
- **AVPlayer external playback** — `allowsExternalPlayback` + `usesExternalPlaybackWhileExternalScreen
  IsActive`: the lightest path for the *video* half — video auto-routes to the glasses and the phone is
  freed for controls. (The external-display scene gives more control — full-bleed video + our own
  overlay — so prefer that for the player and keep AVPlayer external playback as the fallback.)

**Proposed behavior:**
- **On connect →** enter "big-screen mode." Render the browsing UI (landscape, large type, focusable
  rows) on the glasses scene. Phone shows the same browsing UI (so it reads as "mirrored" while
  browsing) or a simplified navigator.
- **On fullscreen video →** glasses scene shows the video full-bleed; the **phone window swaps to a
  full-screen remote**: tap = play/pause, horizontal drag = scrub (with the sprite/heat overlay), edge
  swipes = back / next, vertical drag = volume/brightness, double-tap = seek ±10s. Haptics for feedback.
- **On disconnect →** seamlessly fall back to the normal on-phone player at the current timestamp.

**Caveats / unknowns:**
- **No head tracking.** iOS doesn't expose the glasses' IMU, so this is a *flat virtual big screen*, not
  a head-locked 3DoF display (the glasses' own firmware may do smooth-follow). True head-tracked / VR
  180°·360° stays out of reach on iOS; revisit on the (later) Android app.
- The app can't tell "XR glasses" from any HDMI/DP monitor — behavior simply keys off "external display
  connected," which is fine (and also gives free TV/monitor support).
- Requires real hardware to build/test (simulator external-display support is limited); needs its own
  test pass on device.
- Orientation handling: phone remote can stay portrait while the glasses scene is landscape 16:9.

## Downloads & offline

- **★ Resumable (checkpointed) on-device transcode — owner-requested 2026-07-04. ✅ SHIPPED the same day**
  (`f421ecd`/`d3c0108`/`960ac90`: `Services/FFmpegResumableTranscoder.swift`, wired into `DownloadManager`
  and used only for **long re-encodes** — stream-copy cases and files <90 s take the fast single-pass
  paths). **Approach B won**, deliberately chosen over fragmented-MP4 append (see the file header), and
  improves on the write-up below: chunks are video-only and audio is copied in ONE pass at finalize, so
  the "AAC-priming gaps at joins" caveat doesn't apply. Checkpoint state (`plan.json` + `chunk_NNNN.mp4`
  atomic-rename commits + `settings.json`) persists across launches, so even a cold relaunch resumes from
  the last committed chunk. Historical design record:
  - **Approach A — fragmented-MP4 output + append** (NOT chosen). Write the transcode as a *fragmented*
    MP4 (`frag_keyframe+empty_moov+default_base_moof`, as the since-deleted `FFmpegStreamTranscoder` did —
    removed in `c088325`; git history only), so the partial file is valid up to the last complete
    fragment. Caveat that killed it: encoder settings must be identical across sessions, and appending
    via libavformat needs fragile byte-range surgery rather than re-running `write_header`.
  - **Approach B — segment & concat** (CHOSEN). Encode keyframe-aligned standalone chunk MP4s; persist
    which are done; resume from the first missing; finalize via a stream-copy concat remux.
- **Download videos for offline viewing**, with a choice of source:
  - **Original file** (as-is from Stash). ✅
  - **Stash-transcoded version** (ask the server for a smaller/compatible encode). Shipping now as an
    **H.264 server-resolution download** via `/scene/{id}/stream.mp4?resolution=…` (staged on the Downloads
    screen: Original+thread-count vs a server resolution). Confirmed against stashapp/stash source: the
    built-in stream API is **H.264-only, resolution-only, quality fixed by server config** — `libx265` is
    in the code but dead/unwired, and there's no per-request codec/quality param.
  - **✅ SHIPPED — Stashy Companion plugin for server-side HEVC + AV1 transcode-for-download.** Lives in
    its own top-level `stash-plugin/` folder (sibling to `ios/`); a zero-dep Python `interface: raw` plugin,
    installed by adding `raw.githubusercontent.com/nphil/stashy/main/stash-plugin/index.yml` as a Plugin
    Source. Confirmed working end-to-end on the owner's server. What actually shipped (broader than the
    original brief below):
    - **GPU HEVC via NVENC on the EOL Tesla P40.** `hevc_nvenc`, output **iPhone-native `hvc1` MP4** so it
      direct-plays. The P40 is EOL at driver 580 (NVENC API 13.0), and modern BtbN ffmpeg needs driver ≥610
      (API 13.1) → **dual-ffmpeg**: **jellyfin-ffmpeg** (driver ≥520) for NVENC + BtbN `latest` (SVT-AV1 3.x)
      for software/AV1, selected per-build via a `.ffdir` pointer. Pascal HEVC caveats baked in: no B-frames
      (`-bf 0`), Main10 (10-bit) OK, no AV1, no Dolby Vision.
    - **CPU AV1 (SVT-AV1)** as the explicit "small, slow" option, with an `av1Preset` speed knob.
    - **HDR-preserving** transcode: HDR10/HLG kept as true 10-bit (`p010le`, Main10, BT.2020 color tags →
      the MP4 `colr` atom iOS needs); Dolby Vision mapped to its HDR10/HLG base (DV P5 → SDR).
    - **Bitrate-aware quality presets** (High/Balanced/Small cap at a fraction of source bitrate — never
      inflate an 8 Mbps source to 20). Default resolution = Original.
    - **Real progress + robustness**: runs as a Stash **Job** (`runPluginTask` → poll `findJob` for real
      `Job.progress`), and live stats are written to a **served `cache/scene<id>.progress.json`** the app
      polls (survives app switch/exit/crash). App-side cancel calls `stopJob`. Finished file handed to the
      normal Range-capable multi-connection download engine. `.serverProcessing` DownloadState drives a
      determinate bar.
    - **Maintenance/versioning**: **Self-Test** task (nvidia-smi + nvenc smoke probes + GraphQL/serving
      health), **Install / Switch ffmpeg** (pinned versions coexist), and a shown active-version + switch
      control — so a Stash upgrade or driver change is a one-task diagnosis, not a silent break.
    - **✅ SHIPPED — the app consumes the plugin's playability intelligence via a SERVED FILE (no scene
      writes)** (plugin v0.1.18). **Why served-file, not tags:** the first tag/custom_field approach wrote
      every scene via `sceneUpdate`, which on a fresh library = hundreds of `Scene.Update` hooks → hundreds
      of queued "Sync" tasks (owner hit this). The `Library Codec Report` now ffprobes the library and writes
      the whole result to ONE served `cache/playability.json` — **zero `sceneUpdate`, zero hooks, zero Sync
      tasks** — exactly like the transcode-progress file. Two app uses, **no scene-card badges** (owner: the
      cards are crowded enough):
      1. **Smarter routing** — `PlayabilityStore` fetches the served file once and caches it;
         `Scene.playbackRoute(pluginNeedsTranscode:)` is passed `store.needsTranscode(id)` at the one call
         site, and when true skips the direct/remux branches straight to transcode/server. Catches 4:2:2/4:4:4
         HEVC that reads as plain "hevc" and would otherwise render black until the 20s watchdog. Purely
         additive — store empty ⇒ routing unchanged.
      2. **Filter-by-playability** — a "Playability" row in `SceneFilterPanel` (Any / Direct-play /
         Needs-transcode), shown only when the store is loaded; it pages the grid over that bucket's scene
         IDs (`SceneQuery.playability` → `PlayabilityStore.ids` → `findScenesByIDs`), no tags involved.
      Plugin (v0.1.18) writes NOTHING to scenes anymore — the tagging task was removed; a one-time **Remove
      Stashy Tags (cleanup)** task (renamed in v0.1.19) deletes the `Stashy:*` tag definitions left by
      ≤0.1.17 — Stash cascade-removes them from scenes with zero per-scene writes; the residual
      `stashy_probe` custom field is deliberately left in place (clearing it would itself be a per-scene
      `sceneUpdate` storm). Nice-to-have: an "On-device only" filter bucket (direct + remux).
    - **Concurrent-queue server transcoding (P40 throughput) — owner-requested 2026-07-05.** When multiple
      downloads are queued with the Companion transcode source, run **2–3 transcode Jobs at once** instead of
      strictly one at a time, to use the P40's spare encoder capacity. This is the *right* parallelism lever
      — NOT splitting a single file. **Research (2026-07-05, verified):** the P40 is a datacenter card with
      **24 concurrent NVENC sessions** (uncapped) but only **1–2 physical NVENC engines**, and NVIDIA's NVENC
      App Note states *a single encode session cannot exceed one engine's throughput* — so splitting ONE file
      caps at ~1–2× (engine count), not 8×, and the actually-slow path (**CPU SVT-AV1**) is already fully
      multithreaded across the 9900K, so file-splitting there oversubscribes and *hurts*. Running different
      scenes concurrently instead gives a clean ~2× aggregate with no keyframe-split / concat-seam artifacts.
      **Design:** cap concurrency (setting, default 2). Decide where the limiter lives — app-side
      (`DownloadManager` allows N simultaneous `.serverProcessing` items, each its own `runPluginTask`) vs
      plugin-side — and first **verify how Stash schedules concurrent `runPluginTask` invocations** (parallel
      vs serialized in its Task Queue); if Stash serializes plugin tasks, the plugin itself must fork the
      encodes. HEVC (NVENC) benefits; gate/limit CPU-AV1 concurrency to 1 (it already saturates the CPU).
      Pairs with a **Self-Test probe** for NVENC engine count + single-session fps so the concurrency default
      is grounded. (Rejected alternative — single-file segment-and-concat split: feasible via the resumable-
      transcode segment primitive, but ~1–2× ceiling for HEVC only, negative for AV1, plus rate-control seams
      at joins → low ROI. Don't build it unless a Self-Test probe proves HEVC is the bottleneck.)
  - **★ Encode-quality validation (VMAF / SSIM) — owner-requested 2026-07-11.** "Make sure the encoded
    file makes sense" — don't ship a transcode that's collapsed to mush. Two tiers, because the right tool
    differs by where the encode runs:
    - **VMAF CRF MAP — ✅ BUILT + box-verified 2026-07-15 (plugin v0.3.0).** The insight that unlocks VMAF for
      streaming/instant-downloads without terabytes: cache the search's *output* (the optimal CRF number +
      the sampled curve), not the transcoded file — kilobytes for the whole library. New scheduled/manual
      **Compute VMAF Map** task (mirrors Library Codec Report: incremental skip, resumable, `Scene.Create`-
      friendly, per-run time budget, served `vmaf-map.json`, zero scene writes). `run_transcode` now looks up
      the cached CRF (`_cached_crf`) and SKIPS the ~30s live search when present; `_crf_from_curve` derives
      High/Balanced/Small from the ONE stored curve (verified on the box: 720p search → CRF 35@94, and 36@91 /
      29@97 derived without re-searching; unmapped res → live-search fallback; run-2 incremental analysed 0).
      For 1,932 scenes ≈ ~10–15h one-time background P40 grind for one resolution, then incremental. This is
      the data layer for the live-ABR streaming plan (per-video CRF for every scene, ~zero storage).
    - **Server (Stash companion plugin) — ✅ BUILT 2026-07-14 (v0.2.0); deployed + verified live on the
      box as of v0.2.2/v0.2.3 (2026-07-14); plugin now ships v0.3.0.**
      Both levels done: **(2) target** — VMAF-targeted encoding is now DEFAULT ON. Presets map to a target
      VMAF (High 97 / Balanced 94 / Small 91, **phone model** — owner's pick, since these play on an iPhone),
      and the plugin sample-encodes a few short windows + binary-searches the encoder's own quality knob
      (`-cq` for nvenc, `-crf` for x265/SVT-AV1) for the smallest file that still meets target; the source
      bitrate cap stays as a ceiling on the final encode. **(1) measure** — the achieved (sampled) VMAF +
      target are recorded in the result JSON (`vmaf`/`vmaf_target`/`cq`); Swift `TranscodeResult` ignores
      unknown keys, so the app can surface "encoded at VMAF 94" whenever we add the UI. Robustness: HDR
      sources skip the search (VMAF's model is SDR-trained); no-libvmaf / any sample failure falls back to
      the preset cq (a transcode never fails over VMAF); Self-Test probes libvmaf + runs a real measurement.
      Search stays on whichever engine will do the final encode (keeps the P40 fast-path). CPU `libvmaf` for
      now (robust, samples are short); `libvmaf_cuda` is a future speed-up.
      **App UI DONE (plugin v0.2.1):** the analysis phase now streams a live progress fraction to the served
      file (stage `analyzing` + `progress`), and the app shows **"Analyzing quality — X%"** during the search
      and a small **"VMAF 94"** chip in the Downloads specs row (Downloads screen only). v1.0.252 (`f1b008a`):
      on transcode finish the Downloads log box also shows before→after size + % reduction ("Size: 5.24 GB →
      2.67 GB (49% smaller)") and "VMAF: target 94 → achieved 95 · cq 33" (achieved sits at/just above target
      by CRF-step granularity — expected, not a mismatch). In `DownloadManager.swift`.
      **PERF (v0.2.3, measured on the box):** the N sample windows of each candidate now encode+measure
      CONCURRENTLY (threads; subprocess releases the GIL) and `n_subsample`=5 — worst-case search ~45s→~27s
      at 3 samples. Profiling showed VMAF is CPU-bound (~1.5s/5s-window, all cores) and the big-file reads are
      NOT the bottleneck (pre-extracting windows tested *slower*), so parallelism is ~at the CPU floor; further
      speed is fewer/shorter samples. New `vmafSamples` setting (1–4, default 3): 2→~19s, 1→~13s, ~same result.
      **Still TODO:** an optional auto-reject-below-a-floor; consider `libvmaf_cuda`; secant/interpolation to
      cut eval count (biggest remaining lever on worst-case content); persist the badge across
      relaunch (currently in-memory like the Transcoded chip). `libvmaf` is BSD-3 (no GPL); the **BtbN gpl
      builds bundle it, jellyfin-ffmpeg does NOT** (verified on the box 2026-07-14) — measurement is CPU-only
      so the P40 driver ceiling (580.x, last Pascal branch) is irrelevant; jellyfin stays NVENC-only.
      **ESCAPING GOTCHA (cost a round-trip):** in `-lavfi` via argv the libvmaf model arg needs DOUBLE
      escaping — `model=version=vmaf_v0.6.1\\:enable_transform=true` (graph parser strips one `\`, option
      parser needs the survivor); a single `\:` leaks `enable_transform` as a bogus filter option
      ("Option not found"). Fixed + verified live in plugin v0.2.2 (identical clip → 100.0).
    - **On-device — a cheap SANITY GUARD, not full VMAF.** Full VMAF on the phone is a bad fit: it's a
      full-reference metric (needs the source decoded alongside the output) and is often as slow as or
      slower than the encode itself → doubles the work + cooks the battery, defeating the point of local
      transcode; and the corrective lever is weak anyway (VideoToolbox HW encode has only coarse quality
      control, no CRF). So the on-device guard is: **structural checks** (output opens, expected duration/
      frame-count/resolution, bitrate/size ratio in a sane band — catches "garbage" for ~free) **+ optional
      sampled SSIM** (SSIM ≫ cheaper than VMAF, built into FFmpeg, no model/GPL; score ~3–5 short 2s
      segments, not the whole file). **Blocked on a `stash-videoengine` rebuild** — the current lean build
      enables only `scale,format,aresample,anull,null`, so it has NO `ssim`/`psnr`/`libvmaf` filter; adding
      SSIM = enable `--enable-filter=ssim` (built-in, trivial), adding on-device VMAF = cross-compile
      libvmaf + bundle a model (heavier, not worth it vs. SSIM). Failing the guard → warn / offer re-encode
      at a higher quality / fall back to Original.
  - **On-device transcode on the fly** (reuse the FFmpeg engine to produce a smaller/compatible file
    locally). ✅ H.264/HEVC (VideoToolbox) with resolution + quality presets.
- **Downloaded Videos management screen** — list/manage offline videos (size, source, delete, play
  offline, re-download at different quality). ✅ (Downloader screen)
- **Background continuation** — ✅ downloads run under a background `URLSession` and survive suspension
  (dual-engine handoff: foreground 8-way ⇄ background single-connection). **Live Activity / Dynamic
  Island** — ⏳ NOT built: needs a Widget Extension target in `ios/project.yml` (ActivityKit +
  `NSSupportsLiveActivities`) — riskiest remaining downloads item since it changes the IPA structure for
  a sideloaded app (see ENGINEERING_NOTES §3 Follow-ups).
- **Private storage** — ✅ downloaded media + sidecars live in a Stashy-scoped Application Support folder
  (never surfaced in the Files app or to other apps), excluded from iCloud/iTunes backup, migrated from
  the old Documents location.
- **⏳ Encrypt downloads (option).** Add a setting to encrypt offline video at rest so files are unreadable
  even if extracted from the container (beyond iOS's default Data Protection). Options to weigh:
  raise the files' Data Protection class to `.complete` (kernel-encrypted, unreadable while the device is
  locked) as the cheap win; or app-level encryption (per-file AES-GCM via CryptoKit with a Keychain-held
  key, decrypted on the fly through an `AVAssetResourceLoaderDelegate`/local proxy) for
  encrypted-even-while-unlocked, tied to the existing Face ID app-lock. Weigh playback cost (streaming
  decrypt) vs. security; make it opt-in per the privacy tenet.
- **⏳ AV1 encode option (deferred — needs an FFmpeg rebuild).** The current FFmpeg XCFrameworks are
  LGPL-minimal: `h264_videotoolbox` / `hevc_videotoolbox` / `aac` encoders only (AV1 *decode* only). An
  AV1 *encode* preset requires rebuilding FFmpeg with an AV1 encoder (libaom / SVT-AV1) — GPL/heavy,
  CPU-only and slow on a phone. Ship H.264/HEVC hardware transcode now; revisit AV1 encode as a separate
  build effort. (Build brief for the FFmpeg XCFrameworks exists.)

## Library & UX redesign

- **★ PRIORITY — Replace the bottom-nav Search tab with a Downloads tab + universal search.** Two linked
  changes to the tab bar (owner-requested 2026-07-03):
  1. **Remove the Search icon** from the bottom navigation — ✅ SHIPPED 2026-07-08 (`db1263a`; tab bar is
     now Scenes / Performers / Downloads / Settings, with native pull-down search per tab). **Still open:**
     the truly-*universal* search — one query spanning **both performers and scenes** (current pull-down
     search is per-tab).
  2. **Put a Downloads icon where Search was** — ✅ SHIPPED 2026-07-08 (`db1263a`): Downloads is a
     first-class tab opening the Downloads/Transcodes screen directly.
- **Navigation / "back" model cleanup.** Going back and moving between screens doesn't make sense once
  you're deep inside menus — the back affordance and inter-screen navigation need a coherent model.
  Audit every push/cover/sheet path (scenes ⇄ performers ⇄ tags ⇄ studios, the player, downloads reached
  from both a scene menu and Settings, filter popovers) for: a consistent back control (chevron vs.
  swipe vs. close) and label, correct pop-to-root vs. pop-one behavior, no dead-ends or screens you can
  only leave by force-quitting, and predictable state when the same destination is reachable from
  multiple entry points. Likely wants a single navigation source of truth (the existing `AppRouter` /
  per-tab `NavigationStack` paths) rather than ad-hoc `fullScreenCover`/`sheet` stacks.
- **Rework the filter/sort chips UI** (the current chip row needs a cleaner interaction model).
- **Integrate search into the main library UI** via a **pull-down** (scroll-to-reveal search field)
  instead of a separate Search tab/menu. ✅ Done 2026-07-08 (`db1263a` — native `.searchable` drawer on
  the Scenes and Performers lists; the Search tab was removed in the same commit).
- **Filter by favorites.** (Performers done — favorites-only toggle.)
- **Filter performers by country** — a country picker in the performer filter panel (Stash
  `PerformerFilterType.country` is a `StringCriterionInput`), mirroring the existing ethnicity filter.
- **Persist sort across launches (not filters).** ✅ Done — scene/performer sort field + direction are
  remembered between app starts (UserDefaults); filters (tags, favorites, ethnicity/country) still reset.

## Stash feature parity

- **Favorites** — ✅ shipped for **performers and tags** (add/remove via the `LibraryEdits` optimistic
  store; surfaced/filterable — performer favorites-only toggle + tag favorites). Still open: scene-level
  favorites — Stash has no native scene `favorite` boolean, so it would need a convention (tag/rating).
- **Rate scenes** (star rating) — ✅ shipped via `LibraryEdits`/`RatingControls` (`rating100` 0–100 ↔
  5 stars; performer ratings too).
- **O-counter** ("ejaculation counter") support — increment/track per scene, like Stash.
- **Stash markers** support — view/seek to (and ideally create) scene markers.
- **Metadata search / auto-fill** — integrate Stash's scene & performer scraping/identify so missing
  metadata can be searched and filled from the app.

## Integrations (large lifts)

- **Site integrations** — simpcity.cr, empornium, and possibly others (browse/grab content).
- **Multi-threaded downloader that adds directly to the Stash library** — parallel downloads that hand
  finished files to Stash for import. Big effort; sequence carefully.

## Tech debt / cleanup
**✅ Optimization pass complete (2026-07-01, through v1.0.84).** The prioritized plan in
`docs/OPTIMIZATION_PLAN_2026-06-30.md` is done: dead segmented-HLS code removed (~750 lines), remux
**bounded to the playhead** (network/CPU/disk now proportional to watched duration, not file size),
temp-file cleanup, correctness pass (seek-by-reinit / AV1 / seek-to-end / audio session), scene-list
query slimmed + performer images cached at higher quality (evicted last), ImageCache LRU counter, and
`ScenePlayerModel` split out of the view. Remaining items are optional/deferred and not blocking
features: §3.3 (cheaper 4K blur), §6.2 (shared RangeReader tidy), §2.3 (reinit debounce — deferred, seek
latency tradeoff).
- **⚠️ REMOVE ALL TELEMETRY before any wider release.** Debug logging (`RemoteLog` → ntfy) is OFF by
  default and isolated; deletion checklist is in §5 of the optimization plan. Reminder per Nitin. This is
  the one tech-debt item still intentionally open (kept as the live debug channel until release).

## Privacy & security
- **★ PRIORITY — "Blur Media": one blur that covers ALL imagery, app-wide (owner-requested 2026-07-03).**
  Rename the existing **Blur Thumbnails** toggle to **Blur Media** and make it apply the *same* blur
  everywhere a frame/image is shown, with no gaps: scene/performer **thumbnails on every screen**
  (scenes grid, performer page, search, and the **Downloads cards — currently unblurred**), **scrub
  sprites**, the **long-press peek**, and **video playback itself** (inline AND fullscreen). Today
  `blurThumbnails` only hits `SceneCard`, so coverage is patchy.
  - **Approach (performance-safe):** a single global flag (`@AppStorage("blurMedia")`) + one reusable
    `.privacyBlur(_ on:)` modifier applied at every media site so nothing is missed. **Static images**
    (thumbnails/sprites) → SwiftUI `.blur(radius:)` — cheap, they don't animate. **Live video** → do NOT
    per-frame CIFilter (expensive); overlay a **`UIVisualEffectView(UIBlurEffect)`** on the player layer
    — hardware-accelerated, ~free, blurs whatever's behind it. (The player already has the Metal
    `LiveBlurBackdropView` as precedent that blurring video on-device is cheap.)
  - **Open decisions (ask owner):** fixed strong blur vs. an adjustable radius slider; whether to allow a
    temporary **long-press-to-peek** reveal or keep it fully locked; whether to fold the separate **Blur
    Titles** toggle into this or keep it independent; and whether this replaces/relates to the
    app-switcher blur below.
- **App-switcher / background privacy blur.** ✅ SHIPPED 2026-07-11 (`e6bf2d0`):
  `SnapshotPrivacyModifier` in `Services/AppLock.swift`, applied outermost via `.snapshotPrivacy()` in
  `StashyApp.swift` — an unanimated thick-material cover whenever `scenePhase != .active`, so the
  multitasking snapshot iOS captures never shows video/thumbnails. Settings → Privacy toggle
  (default ON); independent of the Face ID app lock and in-app Privacy Mode.
- Done: **Face ID is now immediate** — the "Stashy is Locked" splash was replaced with a minimal privacy
  blur so biometrics fire the instant the app becomes active (tap to retry if the prompt is dismissed).
- Reminder (existing): **remove all telemetry before wider release** (see §5 of the optimization plan).

## Other
- Android app — later.
