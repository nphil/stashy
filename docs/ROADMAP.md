# Stashy — Roadmap & Deferred Ideas

Working notes so intent survives across sessions. Core tenets: **fast, responsive playback +
scrubbing**, **direct-play first**, on-device FFmpeg as the fallback, minimal server load.

## Playback pipeline

**Current shipping state:** Direct play for H.264-in-mp4/mov (native HW decode, instant seeks); HEVC /
foreign-container H.264 → **on-device linear remux over loopback HLS** (smooth playback, confirmed
on-device); everything Apple can't decode → Stash HLS.

### What works now ✅ (linear-remux baseline — still current as of v1.0.184; seek-by-reinit + on-device transcode now layered on top)
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

### ✅ SHIPPED (2026-07-04/05): on-device transcode playback tier (M-A) + manual server-quality menu (M-B)
Both pieces shipped and on device. M-A = the on-device streaming transcode tier (`FFmpegStreamTranscoder`
+ `LocalTranscodeStream`, HW decode → `h264_videotoolbox` → fragmented MP4, audio copy-or-AAC-reencode,
seek-by-reinit, `armWatchdog` auto-fallback to Stash HLS). M-B = the player gear → force Stash HLS at a
chosen resolution (the `?resolution=` duplicate-param bug fixed; resumes at the exact position). Original
design below, kept as the record. They build on the **file** transcoder shipped in
v1.0.12x (`FFmpegTranscoder`: libavformat demux → FFmpeg decode → libswscale NV12 → VideoToolbox
`h264/hevc_videotoolbox` encode → MP4; audio copy for AAC/AC3/EAC3/MP3/ALAC). That class is the encode
core both items reuse.

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

### ★ PRIORITY — Player UI rework + playback speed / AI slow-motion (owner-requested 2026-07-04)

- **Netflix-style fullscreen player UI.** Rework the fullscreen controls layout taking the **Netflix
  iPhone player as the design reference** — the large centred transport cluster (back-10s / play-pause /
  forward-10s), a clean top bar (title + close), a bottom scrubber with elapsed/remaining, and a small
  cluster of secondary controls (speed, audio/quality, episodes) rather than everything crammed on one
  bar. Applies to **fullscreen only**; the inline compact bar stays as-is. Reuse the existing gear
  (quality), volume, and status-badge components, re-laid-out for the immersive layout. Owner is exacting
  about native feel — match Apple/Netflix animation physics and spacing.
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
- **Playback speed control** in the player menu (e.g. 0.25× / 0.5× / 0.75× / 1× / 1.25× / 1.5× / 2×).
  Drive via `AVPlayer.rate` / `AVPlayerItem.audioTimePitchAlgorithm`. Add it to the overlay controls
  (alongside the quality gear).
- **Slow-motion mode with two audio behaviours:** when playing below 1×, either (a) **mute audio**, or
  (b) **keep audio at normal (1×) speed/pitch** while the video runs slow — an explicit toggle, since
  pitch-corrected slowed audio is usually undesirable. (Implementation note: AVFoundation slows audio
  with the video; "normal-speed audio under slow video" needs decoupling the audio timeline — investigate
  `AVSampleBufferAudioRenderer` / a separate normal-rate audio pass, or simply mute below a threshold.)
- **AI / motion-interpolated slow-mo (on-device).** When the source frame rate is too low for smooth
  slow motion (e.g. slowing 24–30 fps to 0.25× looks choppy/blurry from frame duplication), **synthesise
  intermediate frames on-device** so the slowed footage looks smooth. Candidate approaches to research:
  Apple's **Vision / optical-flow** APIs (`VNGenerateOpticalFlowRequest`) to warp between frames, a
  **Core ML frame-interpolation model** (RIFE/FILM-class, converted to Core ML), or `AVFoundation`'s
  scaled-edit / `VTFrameProcessor` (iOS 18+ has a motion-interpolation/optical-flow API worth checking).
  Must stay on-device, respect thermal/battery limits (interpolate only around the current playhead, not
  the whole file), and gate on device capability. Heaviest item here — spike the API options first.
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
    remux, on-device transcode, server HLS) via the player's `AVPlayerItemVideoOutput` pixel buffers
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
   - ✅ **On-device transcode shipped** (M-A): MPEG4-ASP/VC1/VP9, software-AV1, exotic ≤1080p ride the same
     HLS delivery, decoding via FFmpeg → `h264_videotoolbox`; heavy 4K → server.

3. **Quality / gear selector** — Auto / Direct / On-device / Server transcode + resolution; also the
   manual escape hatch.

4. **Server-side transcoding controls** — quality/resolution options for the HLS path.

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
  across both remux and on-device transcode. (Reinit debounce still deferred.)
- **Hybrid scrub preview** — show the (instant) Stash sprite tile while dragging, then refine with an
  on-device decoded frame at the exact position when the user pauses on it. Sprites are coarse on long
  videos (fixed tile count ÷ duration); on-device extraction is exact but has decode latency, so layer
  it as a refinement, not a replacement.
- **Watch-heat overlay on the scrubber ("most replayed").** A YouTube-style heat curve/histogram drawn
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

- **★ Resumable (checkpointed) on-device transcode — owner-requested 2026-07-04.** Today a transcode is a
  single-pass whole-file encode whose MP4 index (`moov`) is only written by `av_write_trailer` at the very
  end, so an interruption leaves an unusable partial and the restart re-runs from 0%. (VideoToolbox is also
  foreground-only, so backgrounding must stop it regardless — but the *restart-from-0* is the real pain.)
  Make it resume from where it stopped:
  - **Approach A (preferred) — fragmented-MP4 output + append.** Write the transcode as a *fragmented* MP4
    (`frag_keyframe+empty_moov+default_base_moof`, exactly like `FFmpegStreamTranscoder`), so the partial
    file is valid up to the last complete fragment. Persist a checkpoint = last-muxed media timestamp. On
    resume, reopen/append, `av_seek_frame` the input to that keyframe, re-init decoder+encoder, and keep
    muxing fragments with continuous timestamps. Reuses the M-A fragmented-mux code; the final file is a
    fragmented MP4 (AVPlayer plays it fine). Caveat: encoder settings must be identical across sessions,
    and appending via libavformat needs care (likely concatenate fragment byte-ranges rather than
    re-running `write_header`).
  - **Approach B — segment & concat.** Encode fixed media chunks (e.g. 15–30s) as complete standalone
    MP4s into a temp dir; persist which segments are done; resume from the next; concat all via the
    `concat` demuxer / stream-copy remux at the end. Each segment is GOP-aligned (independent encode), so
    stitching is clean; minor AAC-priming gaps at joins are acceptable for a download.
  - Either way: persist the checkpoint + settings across launches (so an accidental app-kill resumes too),
    show a "Resume" affordance, and keep it off the main thread. Pairs with the transcode auto-resume that
    already re-kicks on foreground — that hook would resume from the checkpoint instead of 0%.
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
      Stashy Library Data** cleanup strips tags/custom_fields left by ≤0.1.17. Nice-to-have: an "On-device
      only" filter bucket (direct + remux).
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
  - **On-device transcode on the fly** (reuse the FFmpeg engine to produce a smaller/compatible file
    locally). ✅ H.264/HEVC (VideoToolbox) with resolution + quality presets.
- **Downloaded Videos management screen** — list/manage offline videos (size, source, delete, play
  offline, re-download at different quality). ✅ (Downloader screen)
- **Background continuation + Live Activity / Dynamic Island** — ✅ downloads run under a background
  `URLSession` and survive suspension; a Live Activity shows aggregate progress.
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
  1. **Remove the Search icon** from the bottom navigation. Fold its function into a **universal search**
     that spans **both performers and scenes** (one query → results across content types), surfaced from
     within the library rather than as its own tab (pairs with the pull-down search-field idea below).
  2. **Put a Downloads icon where Search was**, opening the Downloads/Transcodes screen directly (today
     it's only reachable from a scene's ••• menu and Settings — see Downloads section). This makes the
     daily-driven downloads/transcode flow a first-class destination.
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
  instead of a separate Search tab/menu.
- **Filter by favorites.** (Performers done — favorites-only toggle.)
- **Filter performers by country** — a country picker in the performer filter panel (Stash
  `PerformerFilterType.country` is a `StringCriterionInput`), mirroring the existing ethnicity filter.
- **Persist sort across launches (not filters).** ✅ Done — scene/performer sort field + direction are
  remembered between app starts (UserDefaults); filters (tags, favorites, ethnicity/country) still reset.

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
- **App-switcher / background privacy blur.** Blur (or cover) the app's content the moment it resigns
  active — going to the App Switcher, Control Center, a call, etc. — so the multitasking snapshot iOS
  captures never shows video/thumbnails. Implement by adding a heavy blur overlay on
  `scenePhase != .active` (or a `UIWindow`-level cover on `willResignActive`/`didBecomeActive`),
  **independent of the Face ID app lock**. *Note:* today the only blur-on-return is the app-lock cover,
  which is why it looks irregular — it appears only when app lock is enabled and only on return, not in
  the switcher snapshot. This feature makes it consistent and lock-independent. A settings toggle to
  enable/disable it.
- Done: **Face ID is now immediate** — the "Stashy is Locked" splash was replaced with a minimal privacy
  blur so biometrics fire the instant the app becomes active (tap to retry if the prompt is dismissed).
- Reminder (existing): **remove all telemetry before wider release** (see §5 of the optimization plan).

## Other
- Android app — later.
