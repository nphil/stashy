# Stashy Companion — a Stash plugin

Backend companion plugin for the **Stashy** iOS app. It runs inside a self-hosted
[stashapp/stash](https://github.com/stashapp/stash) server and adds capabilities
vanilla Stash does not have, all aligned with the app's tenets — *fast playback,
direct-play first, minimal server load, privacy*:

| Feature | What it does | Why Stash can't do it today |
|---|---|---|
| **Transcode for iPhone** | Turns one scene into an iPhone-native MP4 — **HEVC via `hevc_nvenc`** (NVIDIA GPU, e.g. Tesla P40), CPU `libx265` fallback, or optional CPU **AV1** (SVT-AV1). Tagged `hvc1` + `+faststart` so AVPlayer direct-plays it. Quality is set by **VMAF perceptual targeting** (below), not a fixed CRF. | Stash's own transcoder is hard-coded to **H.264 / libx264** — no HEVC, no AV1, no per-request quality. |
| **VMAF quality targeting** | Picks the encoder's CRF/CQ by **binary-searching short samples to hit a target VMAF** (Netflix's perceptual metric), measured with the **phone-viewing model** — the smallest file that still looks good to the eye on a phone. Default on; falls back to a fixed preset if libvmaf is missing. | Stash has no perceptual-quality control at all — quality is whatever the server config's H.264 CRF happens to be. |
| **VMAF map (library)** | A scheduled task pre-computes each scene's VMAF-optimal CRF (per resolution) once and caches just the **number + curve** (kilobytes, never the video). Downloads then skip the ~30s live analysis and are instant + VMAF-tuned; one search serves High/Balanced/Small via the curve. | — |
| **Library Codec Report** | ffprobes the library (incremental — only new scenes; hooks keep it current on scan) and writes ONE served report, `cache/playability.json` (codec / pixel format / **HDR transfer** / 10-bit / direct-play tier), that the app fetches for smarter routing and its playability filter, plus an aggregate summary to the job log. **Zero scene writes** — no custom_fields, no Scene.Update hooks, no Sync tasks. | Stash's GraphQL `VideoFile` exposes only codec/res/bitrate — never profile, pix_fmt, or HDR. |
| **Playability filter (app)** | The served report powers the app's Any / Direct-play / Needs-transcode scene filter and smarter playback routing — no tags involved. (Installs that ran plugin ≤0.1.17 — which DID tag scenes — get a one-time **Remove Stashy Tags (cleanup)** task that deletes the `Stashy:*` tag definitions via cascade, no per-scene writes.) | — |
| **Purge Transcode Cache** | Deletes the companion cache, or trims it to a size cap (LRU). | — |

Other tasks: **Delete Cache File** (per-scene; the app invokes it automatically the moment a
server-transcoded download finishes, so served proxies don't accumulate — added v0.1.21); **Rebuild
Codec Report (full)** / **Rebuild VMAF Map (full)** (force re-analysis from scratch — e.g. files changed
in place or targets changed — ignoring the incremental cache); **Install / Switch ffmpeg** and
**Self-Test** (see "Managing ffmpeg" below); **Remove Stashy Tags (cleanup)** (one-time migration for
≤0.1.17 installs, above).

## How the app gets the output (the mechanism)

1. The app calls GraphQL `runPluginTask(plugin_id: "stashy-companion", task_name: "Transcode for iPhone", args_map: { scene_id, codec, resolution, quality })`.
2. The plugin transcodes into its own served folder and reports **real live progress**
   (`Job.progress`, which the app polls via `findJob` / `jobsSubscribe`).
3. On completion it writes the result onto the **source scene's `custom_fields`**
   under key `stashy_transcode`:
   ```json
   { "path": "/plugin/stashy-companion/assets/cache/scene42_hevc_1080p.mp4",
     "size": 734003200, "codec": "hevc", "resolution": 1080,
     "container": "mp4", "source_scene": "42", "status": "ready",
     "cq": 27, "vmaf": 94.3, "vmaf_target": 94 }
   ```
4. The app reads that `path`, prepends its Stash base URL (+ API key), and downloads
   the file. Stash serves `/plugin/stashy-companion/assets/*` through `http.FileServer`
   with **HTTP Range** support, so the app's multi-connection / resumable download
   engine works unchanged. No new scenes, no library pollution.

## Install

**Option A — Plugin source (recommended, gets updates):**
Stash → **Settings → Plugins → Available Plugins → Add Source**

- **Name:** `Stashy`
- **URL:** `https://raw.githubusercontent.com/nphil/stashy/main/stash-plugin/index.yml`

Then find **Stashy Companion** under Available Plugins and click **Install**.

**Option B — Manual:** copy the `stashy-companion/` folder into your Stash
`plugins/` directory (`<stash-config>/plugins/stashy-companion/`), then
Settings → Plugins → **Reload Plugins**.

## Requirements

- **Python 3** available to Stash's plugin runtime. (Zero third-party packages —
  it talks to Stash over GraphQL with the standard library.) If the task errors
  with *"python not found"*, edit `exec:` in `stashy-companion.yml` to use `python3`.
- **ffmpeg with NVENC** for GPU HEVC — the *same* NVENC-enabled ffmpeg your Stash
  already uses for H.264. The plugin auto-detects `hevc_nvenc`; if your Stash
  ffmpeg isn't on `PATH`, set **Settings → Plugins → Stashy Companion → ffmpeg
  directory override** to the folder containing `ffmpeg`/`ffprobe`.
- For **AV1** output, enable *Allow AV1* in settings (CPU-only; Pascal GPUs have
  no AV1 encoder).

## Settings

| Setting | Type | Default | Notes |
|---|---|---|---|
| HEVC encoder | string | `hevc_nvenc` | `hevc_nvenc` (GPU) or `libx265` (CPU). Blank = NVENC. |
| Allow AV1 | bool | off | Permit AV1 output when the app requests it. |
| AV1 speed preset (0–10) | number | `8` | SVT-AV1 preset — the main AV1 speed knob. Higher = much faster / slightly larger. 6 = slower/smaller, 10 = fastest. |
| Preserve HDR (10-bit) | bool | **on** | Keep HDR10/HLG sources as true 10-bit HDR (Main10 + BT.2020) instead of down-converting to 8-bit SDR; Dolby Vision maps to its HDR10/HLG base layer (DV Profile 5 falls back to SDR). |
| Transcode cache cap (GB) | number | `0` | LRU-trim the served cache; 0 = unlimited. |
| Auto codec-report new scenes (on scan) | bool | on | `Scene.Create`/`Scene.Destroy` hooks keep the served playability report current — new scenes auto-ffprobed, deleted ones pruned; no scene writes. |
| VMAF quality targeting | bool | **on** | Encode to a target VMAF (phone model) instead of a fixed CRF. Off = old preset behaviour. Needs libvmaf; falls back safely if absent. |
| VMAF target — High / Balanced / Small | number | `97` / `94` / `91` | Per-preset target VMAF (0–100, phone model). Blank = default. |
| VMAF analysis samples | number | `3` | Windows sampled per candidate (1–4). Fewer = faster analysis, less representative. |
| VMAF map resolutions | string | `1080,720` | Which output resolutions the **Compute VMAF Map** task pre-analyses per scene. More = more one-time GPU compute. |
| VMAF map time budget per run (min) | number | `0` | Cap each map run's runtime so a nightly schedule chips through the library; it's resumable. 0 = run to completion. |
| ffmpeg directory override | string | — | Absolute dir holding an NVENC-enabled ffmpeg/ffprobe. |
| ffmpeg version (software / AV1) | string | `latest` | BtbN tag, `latest`, or `system` — CPU encoders (SVT-AV1, x265) + ffprobe + libvmaf. |
| ffmpeg version (NVENC / hardware) | string | `jellyfin` | `jellyfin`, a BtbN tag, `latest`, or `system` — must match the NVIDIA driver's NVENC API (jellyfin works with driver ≥520; BtbN `latest` needs ≥610). |
| ffmpeg sha256 | string | — | Advanced: verify the download tarball against this hash. |
| ffmpeg download URL | string | — | Advanced: override the exact tarball URL. |

### Managing ffmpeg (dual build: software + NVENC)

NVENC's required driver API and the software encoders' speed pull in opposite directions on older GPUs,
so the plugin keeps **two** ffmpeg builds and uses each where it's best:

- **ffmpeg version (software / AV1)** — CPU encoders (SVT-AV1, x265) + ffprobe. Driver-irrelevant, so
  keep it modern for AV1 speed. Default **`latest`** (BtbN rolling, SVT-AV1 3.x).
- **ffmpeg version (NVENC / hardware)** — GPU `hevc_nvenc` only. Must match your NVIDIA driver's NVENC
  API. Default **`jellyfin`** (jellyfin-ffmpeg, works with driver ≥520 — right for older/EOL cards like
  the **Tesla P40**). `latest` (BtbN) needs driver ≥610.

Set either, then run **Install / Switch ffmpeg** (downloads what's missing; switching between installed
builds is instant). Set a value to `system` to use PATH / Stash's ffmpeg; set both equal to use one build
for everything. **Self-Test** shows both active versions, the GPU + driver, and a live `hevc_nvenc: OK/FAIL`
probe — run it after any Stash or driver change.

AV1 is CPU-only (Pascal has no AV1 encoder), so the **AV1 speed preset** (default 8; higher = faster) is
its main knob. For speed overall, HEVC-on-GPU is far faster than CPU AV1 and plays natively on iPhone.

## Encoder ladder (HEVC)

NVENC is the intended default. Each scene tries, in order, until one succeeds:

1. `-hwaccel cuda` **NVDEC decode** → CPU scale → **`hevc_nvenc` GPU encode**
2. CPU decode → **`hevc_nvenc` GPU encode** (if the GPU-decode pass fails)
3. `libx265` CPU — the last rung: runs when both NVENC attempts fail at runtime, or immediately when
   `hevc_nvenc` is absent from the build (or the **HEVC encoder** setting forces CPU)

Output is always tagged `hvc1` with `+faststart` for AVFoundation direct-play.

## VMAF perceptual quality targeting

Instead of guessing a CRF/CQ, the plugin encodes to a **target VMAF** — the score that reflects how the
video actually looks to the human eye — so every download is the *smallest* file that still looks good:

1. It extracts a few short **sample windows** from the scene.
2. For a candidate quality knob (`-cq` for NVENC, `-crf` for x265/SVT-AV1) it encodes just those samples
   and measures **VMAF** (encoded vs source) with `libvmaf`.
3. It **binary-searches** the knob for the largest value (smallest file) whose VMAF still meets the target,
   then does the full encode at that value. The source bitrate cap stays on as a ceiling.

VMAF is measured with the **phone-viewing model**, which accounts for the small, high-PPI iPhone screen —
artifacts you can't see at phone size don't count, so files come out smaller for the same *perceived*
quality. Presets map to targets: **High 97 / Balanced 94 / Small 91** (tunable in settings).

Details:
- **Default on.** Adds a minute or so of short sample encodes per transcode. Turn off (*VMAF quality
  targeting*) to always use the fixed preset CRF.
- **Needs libvmaf** in an ffmpeg build — the plugin's default **software build (`latest`, BtbN) bundles it**;
  jellyfin-ffmpeg does **not** (it's kept only for NVENC). Measurement is CPU-only, so old NVIDIA drivers
  don't matter here. If libvmaf is missing, or any sample step
  fails, the transcode **safely falls back** to the preset CRF — it never fails because of VMAF. Run
  **Self-Test** to confirm libvmaf is present (it runs a real measurement and prints the score).
- **HDR** sources skip the search (VMAF's model is SDR-trained) and use the preset.
- The achieved VMAF, target, and chosen knob are recorded in the result JSON (`vmaf` / `vmaf_target` / `cq`).

### VMAF map — pre-compute the whole library (optional but recommended)

The per-scene VMAF search takes ~15–30s. Run the **Compute VMAF Map** task once (overnight) and the plugin
stores each scene's optimal CRF — just the *number* plus the sampled curve — in a tiny served
`cache/vmaf-map.json` (kilobytes for the whole library; **never** the transcoded files). After that:

- **Downloads are instant** — they look up the cached CRF and skip the live analysis, still VMAF-tuned.
- **One search serves every preset** — High/Balanced/Small are derived from the stored curve, no re-search.

It's **incremental** (skips scenes already mapped + HDR sources, prunes deleted ones) and **resumable** — set
*VMAF map time budget per run* and schedule it nightly to chip through a big library in chunks. If a scene
isn't mapped yet (or a target isn't covered by its curve), that download simply falls back to a live search.
`libvmaf` must be present (the BtbN `latest` software build has it).

---
*Part of the [Stashy](https://github.com/nphil/stashy) project. App: `ios/`. This plugin: `stash-plugin/`.*
