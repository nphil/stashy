# Stashy Companion — a Stash plugin

Backend companion plugin for the **Stashy** iOS app. It runs inside a self-hosted
[stashapp/stash](https://github.com/stashapp/stash) server and adds capabilities
vanilla Stash does not have, all aligned with the app's tenets — *fast playback,
direct-play first, minimal server load, privacy*:

| Feature | What it does | Why Stash can't do it today |
|---|---|---|
| **Transcode for iPhone** | Turns one scene into an iPhone-native MP4 — **HEVC via `hevc_nvenc`** (NVIDIA GPU, e.g. Tesla P40), CPU `libx265` fallback, or optional CPU **AV1** (SVT-AV1). Tagged `hvc1` + `+faststart` so AVPlayer direct-plays it. | Stash's own transcoder is hard-coded to **H.264 / libx264** — no HEVC, no AV1, no per-request quality. |
| **Library Codec Report** | ffprobes every scene and records codec / profile / **pixel format** / **HDR transfer** / 10-bit / direct-play into each scene's `custom_fields`, plus an aggregate summary to the job log. | Stash's GraphQL `VideoFile` exposes only codec/res/bitrate — never profile, pix_fmt, or HDR. |
| **Tag iPhone-Ready Scenes** | Auto-tags `Stashy:Direct-Play`, `Stashy:Needs-Transcode`, `Stashy:HDR`, `Stashy:10-bit`, `Stashy:HEVC`, `Stashy:AV1` so the app and the Stash UI can filter by playability. | — |
| **Purge Transcode Cache** | Deletes the companion cache, or trims it to a size cap (LRU). | — |

## How the app gets the output (the mechanism)

1. The app calls GraphQL `runPluginTask(plugin_id: "stashy-companion", task_name: "Transcode for iPhone", args_map: { scene_id, codec, resolution, quality })`.
2. The plugin transcodes into its own served folder and reports **real live progress**
   (`Job.progress`, which the app polls via `findJob` / `jobsSubscribe`).
3. On completion it writes the result onto the **source scene's `custom_fields`**
   under key `stashy_transcode`:
   ```json
   { "path": "/plugin/stashy-companion/assets/cache/scene42_hevc_1080p.mp4",
     "size": 734003200, "codec": "hevc", "resolution": 1080,
     "container": "mp4", "source_scene": "42", "status": "ready" }
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
| Transcode cache cap (GB) | number | `0` | LRU-trim the served cache; 0 = unlimited. |
| ffmpeg directory override | string | — | Absolute dir holding an NVENC-enabled ffmpeg/ffprobe. |
| ffmpeg version | string | pinned tag | Which pinned build to use: a BtbN tag, `latest`, or `system`. |
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
3. `libx265` CPU (only if `hevc_nvenc` is absent from the ffmpeg build)

Output is always tagged `hvc1` with `+faststart` for AVFoundation direct-play.

---
*Part of the [Stashy](https://github.com/nphil/stashy) project. App: `ios/`. This plugin: `stash-plugin/`.*
