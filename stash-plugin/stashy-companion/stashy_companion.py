#!/usr/bin/env python3
"""Stashy Companion — a backend plugin for the Stashy iOS app.

Runs *inside* a self-hosted stashapp/stash server (interface: raw). It adds
capabilities vanilla Stash does not have, all aligned with the app's tenets
(fast playback, direct-play first, minimal server load, privacy):

  * Transcode for iPhone  — turn one scene into an iPhone-native MP4
    (HEVC via hevc_nvenc on an NVIDIA GPU, or libx265 on CPU; optional AV1 via
    SVT-AV1). Quality is chosen by VMAF PERCEPTUAL TARGETING (default on): sample
    windows are encoded + scored with libvmaf's phone model, and the encoder's
    CRF/CQ is binary-searched to hit a target VMAF — so each file is the smallest
    that still looks good to the eye on a phone, instead of a guessed bitrate
    fraction. Output is written into this plugin's own served `cache/` dir and
    the download path is recorded on the SOURCE scene's `custom_fields`, so the
    app can pull it back over Stash's own HTTP (Range-capable, resumable).
    Vanilla Stash only live-transcodes to H.264 — HEVC/AV1 is new here.

  * Library Codec Report  — ffprobe every scene and record codec / profile /
    pixel format / HDR / direct-play info into each scene's `custom_fields`
    (fields the Stash GraphQL VideoFile type never exposes), plus an aggregate
    summary to the job log.

  * Tag iPhone-Ready Scenes — auto-tag scenes Stashy:Direct-Play /
    Stashy:Needs-Transcode / Stashy:HDR / Stashy:10-bit / Stashy:HEVC /
    Stashy:AV1 so the app (and the Stash UI) can filter by playability.

  * Purge Transcode Cache — delete the companion cache, or trim it to the cap.

Zero third-party dependencies: talks to Stash over GraphQL with the stdlib
`urllib`, so it installs and runs anywhere Stash's bundled Python does.

Invocation contract (Stash → plugin):
  stdin = JSON {"server_connection": {...}, "args": {...}}
  server_connection carries Scheme/Host/Port + SessionCookie or ApiKey so the
  plugin can call back into GraphQL. `args` merges the task's defaultArgs with
  whatever `runPluginTask(..., args_map:{...})` passed (the app supplies
  scene_id / codec / resolution / quality for the transcode task).
Progress + logs are emitted on stderr in Stash's control format and surface as
live `Job.progress` / log lines the app reads via findJob / loggingSubscribe.
"""

import base64
import contextlib
import json
import math
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
import urllib.parse

try:
    import fcntl   # POSIX advisory file lock (the plugin runs on the Linux Stash host)
except ImportError:
    fcntl = None

PLUGIN_ID = "stashy-companion"
PLUGIN_DIR = os.path.dirname(os.path.abspath(__file__))
CACHE_DIR = os.path.join(PLUGIN_DIR, "cache")
BIN_DIR = os.path.join(PLUGIN_DIR, "bin")   # optional self-downloaded modern ffmpeg/ffprobe live here
# Served at /plugin/{PLUGIN_ID}/assets/cache/<file> (see ui.assets in the .yml).
CACHE_URL_PREFIX = f"/plugin/{PLUGIN_ID}/assets/cache"
CUSTOM_FIELD_KEY = "stashy_transcode"  # where we record the app-facing result

# DUAL ffmpeg builds — because the NVENC driver requirement and the software-encoder speed both matter,
# but pull in opposite directions on an EOL GPU:
#   • "software/main" build (ffmpegVersion, default BtbN `latest`) — used for libsvtav1 (SVT-AV1 3.x
#     speedups) + libx265 + ffprobe. Driver-irrelevant.
#   • "hardware" build (ffmpegHwVersion, default `jellyfin`) — used ONLY for hevc_nvenc. jellyfin-ffmpeg
#     targets a broad, OLDER NVENC API (driver ≥520) so it works on EOL cards (e.g. Tesla P40 @ 580),
#     whereas BtbN git-master needs driver ≥610.
# Multiple versions coexist under bin/<tag>/ (each with a .ffdir pointer to where its ffmpeg actually is,
# since builds differ: BtbN = single static binary, jellyfin = binary + bundled lib/). bin/active and
# bin/active_hw name the selected ones.
FFMPEG_ASSET = "ffmpeg-master-latest-linux64-gpl.tar.xz"
DEFAULT_FFMPEG_TAG = "latest"       # software/main build (BtbN rolling — never 404s)
DEFAULT_HW_TAG = "jellyfin"         # NVENC build (jellyfin-ffmpeg, driver ≥520 — works on EOL GPUs)
JELLYFIN_VERSION = "7.1.4-3"        # pinned stable jellyfin-ffmpeg (durable; not pruned)
DEFAULT_AV1_PRESET = 8   # SVT-AV1 preset (0 slow/best … 10 fast). 8 ≈ x265 medium; 6 ≈ x265 slow.


def _ffmpeg_url(tag):
    if tag == "jellyfin":
        return ("https://github.com/jellyfin/jellyfin-ffmpeg/releases/download/v{v}/"
                "jellyfin-ffmpeg_{v}_portable_linux64-gpl.tar.xz").format(v=JELLYFIN_VERSION)
    # Any other tag → BtbN (rolling `latest` or a specific autobuild-YYYY-... tag).
    return "https://github.com/BtbN/FFmpeg-Builds/releases/download/{}/{}".format(tag, FFMPEG_ASSET)


def _version_dir(tag):
    return os.path.join(BIN_DIR, tag)


def _active_file(hw):
    return os.path.join(BIN_DIR, "active_hw" if hw else "active")


def _active_tag(hw=False):
    try:
        with open(_active_file(hw)) as f:
            return f.read().strip()
    except OSError:
        return ""


def _set_active(tag, hw=False):
    os.makedirs(BIN_DIR, exist_ok=True)
    with open(_active_file(hw), "w") as f:
        f.write(tag)


def _tag_ffdir(tag):
    """Directory holding a tag's ffmpeg/ffprobe (recorded at install time), or None. System/absent → None."""
    if not tag or tag in ("system", "none", "path"):
        return None
    try:
        with open(os.path.join(_version_dir(tag), ".ffdir")) as f:
            d = f.read().strip()
    except OSError:
        return None
    return d if os.path.isfile(os.path.join(d, "ffmpeg")) else None

# ----------------------------------------------------------------------------
# Stash control-protocol logging (stderr). Each line: \x01 <level> \x02 <msg>.
# level p = progress (message is a float 0..1 → Job.progress).
# ----------------------------------------------------------------------------
def _emit(level, msg):
    sys.stderr.write("\x01{}\x02{}\n".format(level, msg))
    sys.stderr.flush()


def log_trace(m): _emit("t", m)
def log_debug(m): _emit("d", m)
def log_info(m): _emit("i", m)
def log_warn(m): _emit("w", m)
def log_error(m): _emit("e", m)


def log_progress(fraction):
    try:
        f = float(fraction)
    except (TypeError, ValueError):
        return
    f = 0.0 if f < 0 else 1.0 if f > 1 else f
    _emit("p", "{:.4f}".format(f))


# ----------------------------------------------------------------------------
# Minimal GraphQL client (no external deps).
# ----------------------------------------------------------------------------
class Stash:
    def __init__(self, conn):
        scheme = conn.get("Scheme") or "http"
        host = conn.get("Host") or "localhost"
        if host in ("0.0.0.0", "::", ""):
            host = "localhost"
        port = conn.get("Port") or 9999
        self.url = "{}://{}:{}/graphql".format(scheme, host, port)
        self.headers = {"Content-Type": "application/json", "Accept": "application/json"}
        api_key = conn.get("ApiKey")
        if api_key:
            self.headers["ApiKey"] = api_key
        cookie = conn.get("SessionCookie")
        if isinstance(cookie, dict) and cookie.get("Value"):
            self.headers["Cookie"] = "{}={}".format(cookie.get("Name", "session"), cookie["Value"])

    def call(self, query, variables=None, _retry=True):
        payload = json.dumps({"query": query, "variables": variables or {}}).encode("utf-8")
        req = urllib.request.Request(self.url, data=payload, headers=self.headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                body = json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            if e.code == 401 and _retry:
                time.sleep(2)   # transient session rotation — one retry (an adopted ApiKey never 401s)
                return self.call(query, variables, _retry=False)
            raise RuntimeError("GraphQL HTTP {}: {}".format(e.code, e.read().decode("utf-8", "replace")))
        if body.get("errors"):
            raise RuntimeError("GraphQL errors: {}".format(json.dumps(body["errors"])))
        return body.get("data") or {}

    def adopt_api_key(self):
        """Swap session-cookie auth for the server's API key. Stash hands plugin jobs a SessionCookie that
        EXPIRES mid-run on multi-hour tasks (confirmed on the box: the VMAF map task died with GraphQL 401
        after ~2h40m) — so at task start, while the cookie still authenticates, fetch the configured API
        key and use its header (never expires) for every later call. No-op when the connection already
        carries an ApiKey, or when the instance has none configured (open instance — auth doesn't matter
        then), or on any fetch error (we just stay on the cookie)."""
        if self.headers.get("ApiKey"):
            return
        try:
            data = self.call("query { configuration { general { apiKey } } }")
            key = ((data.get("configuration") or {}).get("general") or {}).get("apiKey") or ""
        except Exception as e:
            log_debug("could not fetch API key (staying on session cookie): {}".format(e))
            return
        if key:
            self.headers["ApiKey"] = key
            self.headers.pop("Cookie", None)


# ----------------------------------------------------------------------------
# ffmpeg / ffprobe helpers.
# ----------------------------------------------------------------------------
def _bin(name, override_dir, hw=False):
    # 1) the active installed build (hw = NVENC build, else software/main), via its .ffdir pointer.
    d = _tag_ffdir(_active_tag(hw))
    if d:
        cand = os.path.join(d, name)
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    # 1b) a hardware lookup with no hw build set → fall back to the main build.
    if hw:
        d = _tag_ffdir(_active_tag(False))
        if d:
            cand = os.path.join(d, name)
            if os.path.isfile(cand) and os.access(cand, os.X_OK):
                return cand
    # 2) a legacy flat bin/<name> from an earlier plugin version.
    flat = os.path.join(BIN_DIR, name)
    if os.path.isfile(flat) and os.access(flat, os.X_OK):
        return flat
    # 3) a user-provided directory (Settings → ffmpeg directory override).
    if override_dir:
        cand = os.path.join(override_dir, name)
        if os.path.isfile(cand) or os.path.isfile(cand + ".exe"):
            return cand
    # 4) fall back to PATH / Stash's bundled ffmpeg.
    return name


def ffprobe_streams(path, ffprobe):
    cmd = [ffprobe, "-v", "quiet", "-print_format", "json",
           "-show_format", "-show_streams", path]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        if out.returncode != 0:
            return None
        return json.loads(out.stdout)
    except (subprocess.SubprocessError, ValueError, OSError):
        return None


def encoder_available(ffmpeg, encoder):
    try:
        out = subprocess.run([ffmpeg, "-hide_banner", "-encoders"],
                             capture_output=True, text=True, timeout=30)
        return encoder in out.stdout
    except (subprocess.SubprocessError, OSError):
        return False


# ----------------------------------------------------------------------------
# GraphQL fragments.
# ----------------------------------------------------------------------------
SCENE_FIELDS = """
  id
  title
  tags { id }
  custom_fields
  files { path duration width height video_codec audio_codec format bit_rate frame_rate size }
"""


def find_scene(stash, scene_id):
    data = stash.call(
        "query($id: ID!) { findScene(id: $id) { %s } }" % SCENE_FIELDS,
        {"id": str(scene_id)},
    )
    return data.get("findScene")


def set_custom_field(stash, scene_id, key, value):
    """Set one custom field via a partial update (never clobbers other keys)."""
    stash.call(
        "mutation($id: ID!, $cf: CustomFieldsInput!) {"
        " sceneUpdate(input: {id: $id, custom_fields: $cf}) { id } }",
        {"id": str(scene_id), "cf": {"partial": {key: value}}},
    )


# ----------------------------------------------------------------------------
# Transcode task.
# ----------------------------------------------------------------------------
RES_HEIGHTS = {"2160": 2160, "1080": 1080, "720": 720, "480": 480, "240": 240,
               "p2160": 2160, "p1080": 1080, "p720": 720, "p480": 480, "p240": 240}
# preset → (cq/crf, bitrate-cap fraction of SOURCE). HEVC/AV1 are more efficient than most sources
# (usually H.264), so CQ already lands well under source; the cap GUARANTEES the output never exceeds
# a source-relative ceiling — "High" ≤ source, Balanced/Small progressively smaller.
QUALITY_PRESETS = {
    "high": (24, 1.00), "medium": (28, 0.60), "med": (28, 0.60), "standard": (28, 0.60),
    "balanced": (28, 0.60), "low": (32, 0.35), "small": (32, 0.35),
}

# --- VMAF perceptual quality targeting (default on) ---------------------------------------------------
# Instead of GUESSING a CRF/CQ (the presets above), we encode a few short SAMPLE windows, measure VMAF
# (Netflix's perceptual metric — quality as the human eye actually sees it) on each, and binary-search the
# encoder's own quality knob (-cq for nvenc, -crf for x265/SVT-AV1) for the SMALLEST file whose VMAF still
# meets the target. So "High/Balanced/Small" become perceptual targets, not fixed numbers. The source
# bitrate cap still applies to the FINAL encode as a ceiling. See run_transcode + _vmaf_search.
#
# Targets are tuned for VMAF's PHONE model (see VMAF_PHONE_MODEL): these files play on an iPhone, whose
# small high-PPI screen hides artifacts the default 1080p/HDTV model would penalize, so the same PERCEIVED
# quality lands at a smaller file. Phone-model scores run a few points higher than the default model, so
# these numbers are higher than the usual "93 = Netflix sweet spot" (default-model equivalents ≈ 93/90/87).
VMAF_TARGETS = {
    "high": 97.0, "medium": 94.0, "med": 94.0, "standard": 94.0, "balanced": 94.0,
    "low": 91.0, "small": 91.0,
}
VMAF_PHONE_MODEL = True   # measure with the phone-viewing model (enable_transform / phone_model=1)
# Per-engine search bounds for the quality knob (lower = higher quality + bigger; higher = smaller). HEVC
# -cq/-crf and AV1 -crf live on different scales, so bound each. We never go below/above these regardless
# of target (a safety clamp on file size + a floor on quality).
VMAF_Q_BOUNDS = {
    "hevc_nvenc": (19, 40),   # NVENC -cq
    "libx265":    (18, 38),   # x265 -crf
    "libsvtav1":  (24, 50),   # SVT-AV1 -crf (higher scale than HEVC)
}
VMAF_SAMPLES = 3          # short windows sampled across the scene (more = more representative, slower).
                          # The windows of one candidate are measured CONCURRENTLY (see _vmaf_search), so on a
                          # multi-core box the wall-time is bounded by the CPU-bound VMAF work, not 3× a window.
VMAF_SAMPLE_SECS = 5      # seconds per sample window
VMAF_SUBSAMPLE = 5        # score every Nth frame (libvmaf n_subsample) — cheaper, negligible accuracy loss
VMAF_TOLERANCE = 0.5      # "meets target" slack, in VMAF points
VMAF_MAP_SEARCH_TIMEOUT = 1800  # hard wall-clock cap (s) on ONE (scene, resolution) map search — one
                                # pathological/hanging file must not stall the library task; the run logs
                                # it, moves on, and retries it next run (each ffmpeg child is also capped)


def _src_bitrate(sprobe, sv, scene_file):
    """Best source VIDEO bitrate (bps): stream bit_rate → container bit_rate → Stash's stored bit_rate."""
    candidates = [sv.get("bit_rate"), (sprobe or {}).get("format", {}).get("bit_rate"),
                  (scene_file or {}).get("bit_rate")]
    for v in candidates:
        try:
            b = int(v)
        except (TypeError, ValueError):
            continue
        if b > 0:
            return b
    return 0


def _out_name(scene_id, codec, height):
    return "scene{}_{}_{}p.mp4".format(scene_id, codec, height)


def _clean_fps(sv):
    """A sane constant frame rate (as an ffmpeg rational string) from ffprobe stream info, for the NVENC
    `fps` filter. Prefers avg_frame_rate, then r_frame_rate; rejects 0/degenerate/absurd; default 30."""
    for key in ("avg_frame_rate", "r_frame_rate"):
        val = sv.get(key) or ""
        if "/" in val:
            try:
                n, d = val.split("/")
                n, d = int(n), int(d)
            except ValueError:
                continue
            if n > 0 and d > 0 and 1.0 <= (n / d) <= 1000.0:
                return val   # keep the exact rational (e.g. 30000/1001 for 29.97)
    return "30"


def _detect_hdr(sv, preserve):
    """Decide the HDR-preserving mode for a source video stream (ffprobe dict):
      'pq'  → HDR10 (SMPTE ST 2084)   'hlg' → Hybrid Log-Gamma   None → SDR / can't preserve.
    hevc_nvenc can't emit Dolby Vision, so DV is mapped to its base layer's compatibility (HDR10/HLG),
    or SDR when there's no usable base (Profile 5). Verified fields (NVIDIA matrix + Apple HDR spec)."""
    if not preserve:
        return None
    for sd in (sv.get("side_data_list") or []):
        is_dovi = "dovi" in (sd.get("side_data_type") or "").lower() or sd.get("dv_profile") is not None
        if is_dovi:
            compat = sd.get("dv_bl_signal_compatibility_id")
            if compat == 4:
                return "hlg"   # iPhone-default DV 8.4 → HLG-compatible base layer
            if compat == 1:
                return "pq"    # DV 7 / 8.1 → HDR10-compatible base layer
            return None        # Profile 5 / SDR-compat base → no recoverable HDR on NVENC
    pix = (sv.get("pix_fmt") or "").lower()
    ten_bit = any(t in pix for t in ("10", "12", "p010", "p016"))
    transfer = (sv.get("color_transfer") or "").lower()
    if not ten_bit:
        return None
    if transfer == "smpte2084":
        return "pq"
    if transfer == "arib-std-b67":
        return "hlg"
    return None


def _source_is_hdr(sv):
    """True if the SOURCE stream is HDR (PQ/HLG transfer) or Dolby Vision — cases where VMAF's SDR-trained
    model would misjudge quality, so VMAF targeting must skip them. Deliberately independent of the
    `preserveHDR` OUTPUT setting (that only affects how we ENCODE, not how the source scores): even when the
    user chooses to down-convert HDR→SDR, the SOURCE is still HDR and its VMAF score is unreliable."""
    for sd in (sv.get("side_data_list") or []):
        if "dovi" in (sd.get("side_data_type") or "").lower() or sd.get("dv_profile") is not None:
            return True
    return (sv.get("color_transfer") or "").lower() in HDR_TRANSFERS


def _video_chain(engine, cq, target_h, av1_preset, cfr_fps, hdr, maxrate):
    """The `-vf … -c:v …` portion of an encode (video filters + encoder + quality knob + VBV cap + HDR
    color tags), SHARED by the full transcode and the short VMAF sample encodes so the two stay identical
    (the sample encodes must mirror the final encoder settings for the measured VMAF to be valid).

    engine ∈ {"hevc_nvenc","libx265","libsvtav1"}. hdr ∈ {None,"pq","hlg"}. `target_h` is the already-
    resolved (downscaled, even) output height, so the `-vf` is a plain `scale=-2:<int>`. `maxrate`>0 adds a
    VBV peak-bitrate cap (the search passes 0 so the quality knob → VMAF curve stays monotonic).

    HDR (hdr != None): keep 10-bit and carry BT.2020 + PQ/HLG color tags so the output displays as HDR
    (verified: NVENC Main10 emits these into the HEVC VUI + MP4 colr atom; mastering SEI auto-passes on
    SDK 13.0). SDR (hdr None): force 8-bit yuv420p.
    """
    ten_bit = hdr in ("pq", "hlg")
    trc = {"pq": "smpte2084", "hlg": "arib-std-b67"}.get(hdr)
    # Capped quality: keep CQ/CRF for quality but bound the peak bitrate (VBV) at the source ceiling.
    cap = (["-maxrate", str(int(maxrate)), "-bufsize", str(int(maxrate) * 2)] if maxrate and maxrate > 0
           else [])
    # nvenc's native 10-bit pixel format is p010le; the software encoders want planar yuv420p10le.
    pix = ("p010le" if engine == "hevc_nvenc" else "yuv420p10le") if ten_bit else "yuv420p"
    fmt_f = "format={0}".format(pix)
    color_args = (["-color_primaries", "bt2020", "-color_trc", trc,
                   "-colorspace", "bt2020nc", "-color_range", "tv"] if ten_bit else [])
    main10 = ["-profile:v", "main10"] if (ten_bit and engine in ("hevc_nvenc", "libx265")) else []

    scale_f = "scale=-2:{0}".format(int(target_h)) if int(target_h) > 0 else None

    def vf(*filters):
        chain = [f for f in filters if f]
        return ["-vf", ",".join(chain)] if chain else []

    if engine == "libsvtav1":
        return vf(scale_f, fmt_f) + ["-c:v", "libsvtav1", "-preset", str(av1_preset),
                                     "-crf", str(cq), "-pix_fmt", pix] + cap + color_args
    if engine == "hevc_nvenc":
        fps_f = "fps={0}".format(cfr_fps) if cfr_fps else None
        # -bf 0: Pascal (Tesla P40) NVENC has no HEVC B-frame support; forcing 0 avoids a config reject.
        return vf(fps_f, scale_f, fmt_f) + ["-c:v", "hevc_nvenc", "-preset", "p5",
                                            "-rc", "vbr", "-cq", str(cq), "-b:v", "0", "-bf", "0"] \
            + cap + main10 + ["-tag:v", "hvc1", "-pix_fmt", pix] + color_args
    # libx265 — CPU HEVC, last-resort fallback only
    return vf(scale_f, fmt_f) + ["-c:v", "libx265", "-preset", "medium", "-crf", str(cq)] \
        + cap + main10 + ["-tag:v", "hvc1", "-pix_fmt", pix] + color_args


def build_transcode_cmd(src, dst, codec, target_h, cq, ffmpeg, engine, gpu_decode,
                        av1_preset=DEFAULT_AV1_PRESET, cfr_fps=None, hdr=None, maxrate=0):
    """Full transcode command. gpu_decode adds NVDEC (NVENC path). See `_video_chain` for the encoder args."""
    pre = [ffmpeg, "-y", "-hide_banner"]
    if engine == "hevc_nvenc" and gpu_decode:
        pre += ["-hwaccel", "cuda"]  # NVDEC decode; frames land in system mem for the CPU scale/format
    cmd = pre + ["-i", src]
    cmd += _video_chain(engine, cq, target_h, av1_preset, cfr_fps, hdr, maxrate)
    cmd += ["-c:a", "aac", "-b:a", "160k", "-ac", "2",
            "-movflags", "+faststart",
            # Force the MP4 muxer: the output is written to a `.part` temp name, and ffmpeg can't infer
            # a format from that extension ("Error opening output files: Invalid argument"). -f mp4 makes
            # the container explicit regardless of the temp filename.
            "-f", "mp4",
            "-progress", "pipe:1", "-nostats", dst]
    return cmd


def _sample_encode_cmd(src, dst, engine, cq, ffmpeg, gpu_decode, target_h, av1_preset, cfr_fps, hdr, ss, t):
    """A SHORT, video-only encode of one [ss, ss+t] window at quality knob `cq` — the same encoder/filters
    as the full transcode (via `_video_chain`) but with NO bitrate cap (so the knob → VMAF curve stays
    monotonic for the search) and no audio. Input-side `-ss/-t` keep the decode bounded to the window."""
    pre = [ffmpeg, "-y", "-hide_banner"]
    if engine == "hevc_nvenc" and gpu_decode:
        pre += ["-hwaccel", "cuda"]
    return (pre + ["-ss", str(ss), "-t", str(t), "-i", src]
            + _video_chain(engine, cq, target_h, av1_preset, cfr_fps, hdr, 0)
            + ["-an", "-f", "mp4", dst])


# ----------------------------------------------------------------------------
# VMAF perceptual quality targeting (see the VMAF_* constants above).
# ----------------------------------------------------------------------------
def _truthy(val, default=False):
    """Interpret a plugin setting (may be a bool, number, or free-typed string) as a boolean."""
    if val is None:
        return default
    if isinstance(val, bool):
        return val
    return str(val).strip().lower() not in ("false", "0", "no", "off", "")


def _filter_available(ffmpeg, name):
    """True if this ffmpeg build lists filter `name` (e.g. libvmaf / libvmaf_cuda)."""
    try:
        out = subprocess.run([ffmpeg, "-hide_banner", "-filters"],
                             capture_output=True, text=True, timeout=30)
        return name in out.stdout
    except (subprocess.SubprocessError, OSError):
        return False


def _vmaf_ffmpeg(ff_sw, ff_hw):
    """The first ffmpeg binary that has the libvmaf filter, or None. Measurement is CPU decode-only (no
    NVENC/driver involvement), so build age doesn't matter. VERIFIED on the box 2026-07-14: the BtbN gpl
    builds (the plugin's default 'latest' software build) ship libvmaf; jellyfin-ffmpeg does NOT (it only
    has vmafmotion) — so prefer the software build and keep hw only as a just-in-case fallback."""
    for ff in (ff_sw, ff_hw):
        if ff and _filter_available(ff, "libvmaf"):
            return ff
    return None


def _libvmaf_new_api(ffmpeg):
    """The libvmaf ffmpeg filter changed its model API. Newer builds take `model=version=…`; older ones
    expose a boolean `phone_model` option. Detect which by inspecting the filter help. Assume new on error."""
    try:
        out = subprocess.run([ffmpeg, "-hide_banner", "-h", "filter=libvmaf"],
                             capture_output=True, text=True, timeout=30).stdout.lower()
    except (subprocess.SubprocessError, OSError):
        return True
    if "phone_model" in out:   # only the OLD API exposes this option
        return False
    return True


def _vmaf_model_arg(ffmpeg):
    """The libvmaf `model` clause selecting the PHONE model, matched to this build's API. New API: the
    model value's inner `:` needs DOUBLE escaping (`\\\\:` in the argv string) — the -lavfi graph parser
    strips one `\\` when extracting the filter's option string, and the option parser needs a remaining
    `\\:` to keep the `:` inside the model value (a single `\\:` leaks `enable_transform` out as a bogus
    filter option → "Option not found"; VERIFIED live on the box 2026-07-14, identical clip → 100.0).
    Old API: the `phone_model=1` flag."""
    new_api = _libvmaf_new_api(ffmpeg)
    if VMAF_PHONE_MODEL:
        return "model=version=vmaf_v0.6.1\\\\:enable_transform=true" if new_api else "phone_model=1"
    return "model=version=vmaf_v0.6.1" if new_api else ""


def _parse_vmaf_json(path):
    """Pull the pooled mean VMAF out of libvmaf's JSON log (schema varies by version), or None."""
    try:
        with open(path) as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    pooled = ((data.get("pooled_metrics") or {}).get("vmaf")) or {}
    for k in ("mean", "harmonic_mean"):
        v = pooled.get(k)
        if isinstance(v, (int, float)):
            return float(v)
    vals = []   # fall back to averaging the per-frame scores
    for fr in (data.get("frames") or []):
        mv = (fr.get("metrics") or {}).get("vmaf")
        if isinstance(mv, (int, float)):
            vals.append(mv)
    if vals:
        return sum(vals) / len(vals)
    v = data.get("vmaf") or data.get("VMAF score")
    return float(v) if isinstance(v, (int, float)) else None


def _vmaf_sample_windows(duration, n, secs):
    """`n` short [ss, t] windows spread across the INTERIOR of the video (skipping the very start/end),
    so the search sees representative content, not just the opening. Short clips → a single window."""
    secs = float(min(secs, max(1.0, duration))) if duration > 0 else float(secs)
    if duration <= 0 or duration <= secs * 1.5:
        return [(0.0, secs if duration <= 0 else float(min(secs, duration)))]
    wins = []
    for i in range(n):
        frac = (i + 1.0) / (n + 1.0)                 # e.g. n=3 → 0.25, 0.50, 0.75
        ss = max(0.0, min(duration - secs, frac * duration - secs / 2.0))
        wins.append((round(ss, 2), secs))
    return wins


_VMAF_LAST_ERR = {"msg": ""}   # last measurement failure detail (stderr tail) — for self-test/log diagnosis


def _measure_vmaf(ffmpeg, src, dist, ss, t, src_w, src_h, cfr_fps, model_arg, log_json, n_threads=None):
    """Measure mean VMAF of one distorted sample (`dist`, already just the [ss,ss+t] window) vs the matching
    source excerpt. The distorted is upscaled to the SOURCE resolution and BOTH sides are conformed to a
    common frame grid (fps=`cfr_fps`) so libvmaf pairs frames correctly regardless of source VFR/resolution.
    On failure records the real ffmpeg stderr tail in _VMAF_LAST_ERR (a swallowed stderr cost us a debugging
    round-trip once — the "Option not found" escaping bug was invisible in the job log)."""
    _safe_unlink(log_json)
    if n_threads is None:
        n_threads = max(1, (os.cpu_count() or 4))
    fps_pre = "fps={0},".format(cfr_fps) if cfr_fps else ""
    # Force BOTH branches to a single pixel format: VMAF only runs on SDR sources (HDR is skipped upstream)
    # and the distorted output is 8-bit yuv420p, but the source reference may be 4:2:2 / 4:4:4 / 10-bit —
    # libvmaf needs its two inputs in one negotiated format, so conform the reference down to match (else the
    # filtergraph either fails to configure → None, or an unspecified swscale conversion decides the compare).
    lavfi = ("[0:v]{fps}scale={w}:{h}:flags=bicubic,format=yuv420p,setpts=PTS-STARTPTS[dist];"
             "[1:v]{fps}scale={w}:{h}:flags=bicubic,format=yuv420p,setpts=PTS-STARTPTS[ref];"
             "[dist][ref]libvmaf={model}:n_subsample={sub}:n_threads={nt}:log_fmt=json:log_path={log}"
             ).format(fps=fps_pre, w=int(src_w), h=int(src_h), model=model_arg,
                      sub=VMAF_SUBSAMPLE, nt=n_threads, log=log_json)
    cmd = [ffmpeg, "-y", "-hide_banner",
           "-i", dist,                                   # input 0 = distorted (the encoded window)
           "-ss", str(ss), "-t", str(t), "-i", src,      # input 1 = source reference excerpt
           "-lavfi", lavfi, "-f", "null", "-"]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=1800)
    except (subprocess.SubprocessError, OSError) as e:
        _VMAF_LAST_ERR["msg"] = "launch: {}".format(e)
        return None
    if r.returncode != 0:
        tail = [ln.strip() for ln in (r.stderr or "").splitlines() if ln.strip()][-3:]
        _VMAF_LAST_ERR["msg"] = "rc {}: {}".format(r.returncode, " / ".join(tail))
        log_debug("libvmaf measure failed — " + _VMAF_LAST_ERR["msg"])
        return None
    score = _parse_vmaf_json(log_json)
    if score is None:
        _VMAF_LAST_ERR["msg"] = "rc 0 but no score in {}".format(os.path.basename(log_json))
    return score


def _search_quality_knob(lo, hi, target, tol, score_fn, on_stage=None):
    """Binary-search integer knobs in [lo, hi] for the LARGEST value whose `score_fn(q)` still meets
    `target` (within `tol`), assuming score decreases as q rises (higher knob = lower quality). Returns
    (q, score) for the chosen knob, or None if the highest-quality end (`lo`) can't even be scored.

    `score_fn(q)` returns a float, or None for a FAILED evaluation. A None at `lo` → give up (None). A None
    at an interior knob is treated as 'below target' → search the higher-quality (lower-knob) half; this is
    safe because a knob we can't score can't be trusted to meet the target. Pure/deterministic: the only
    I/O is inside `score_fn`, so this is unit-tested with a synthetic score function."""
    s_lo = score_fn(lo)
    if s_lo is None:
        return None
    if s_lo < target - tol:            # even max quality misses the target — best effort = lo
        if on_stage:
            on_stage("VMAF {0:.1f} at max quality (cq {1}) < target {2} — using max quality".format(
                s_lo, lo, target))
        return lo, s_lo
    best_q, best_v = lo, s_lo
    a, b = lo, hi
    while a <= b:
        mid = (a + b) // 2
        if mid == lo:                  # already evaluated the lo bound above
            a = mid + 1
            continue
        v = score_fn(mid)
        if v is None:                  # can't score this knob → don't trust it; search higher quality
            b = mid - 1
            continue
        if on_stage:
            on_stage("VMAF search cq {0} → {1:.1f} (target {2})".format(mid, v, target))
        if v >= target - tol:
            best_q, best_v = mid, v     # meets target — try for a smaller file (higher knob)
            a = mid + 1
        else:
            b = mid - 1
    return best_q, best_v


def _vmaf_search(src, engine, gpu_decode, ff_encode, ff_measure, target_h, av1_preset, cfr_fps, hdr,
                 duration, src_w, src_h, target_vmaf, model_arg, workdir, on_stage, on_progress=None,
                 samples=None, out_curve=None, out_bitrate_curve=None, deadline=None):
    """Binary-search the encoder's quality knob (`-cq`/`-crf`) for the LARGEST value (smallest file) whose
    sample VMAF still meets `target_vmaf`. Returns (chosen_q, measured_vmaf), or None if VMAF couldn't be
    measured at max quality (any sample encode / measurement failure → the caller keeps the preset CQ).
    Bounded to a few evaluations; assumes VMAF decreases monotonically as the knob rises.

    `on_progress(frac)` (optional) is called after each sample step with an estimated 0..1 fraction of the
    analysis, so the app can show a live "Analyzing quality — X%". The estimate is generous (bounded by the
    binary-search depth), clamped to 0.99, and monotonic — it may finish below 1.0 if the search converges
    early; the encode phase then drives its own progress.

    `deadline` (optional, epoch seconds) is a hard wall-clock cap: checked before EACH candidate
    evaluation; past it the search raises TimeoutError (a running evaluation still finishes — each ffmpeg
    child has its own subprocess timeout — so the true bound is deadline + one evaluation). The VMAF map
    task uses it so one pathological file can't stall the whole library pass; run_transcode passes None."""
    import concurrent.futures
    import threading

    lo, hi = VMAF_Q_BOUNDS.get(engine, (18, 40))
    windows = _vmaf_sample_windows(duration, samples or VMAF_SAMPLES, VMAF_SAMPLE_SECS)
    cache = {}
    bcache = {}                                  # {q: mean sample bits/sec} — the bitrate at each measured knob
    ncpu = os.cpu_count() or 4
    # The windows of one candidate run CONCURRENTLY, so split the CPU cores across the (possibly) overlapping
    # libvmaf measures to avoid oversubscription (encode is on the NVENC/GPU side and overlaps for free).
    meas_threads = max(1, ncpu // max(1, len(windows)))
    # Estimated total sample steps = (lo probe + ~log2(range) search evals) × windows. bit_length() avoids
    # importing math; a generous estimate keeps the reported % monotonic and clamped, never overshooting.
    est_evals = 1 + max(1, hi - lo).bit_length()
    total_steps = max(1, est_evals * len(windows))
    prog = {"done": 0}
    plock = threading.Lock()

    def _tick():
        with plock:
            prog["done"] += 1
            frac = min(0.99, prog["done"] / float(total_steps))
        if on_progress:
            try:
                on_progress(frac)
            except Exception:
                pass

    def _do_window(q, i, ss, t):
        """Encode + VMAF-measure ONE window. Returns the score, or None on any failure. Runs on a worker
        thread; subprocess.run releases the GIL, so the real work (ffmpeg children) genuinely parallelizes."""
        sample = os.path.join(workdir, "s{0}_{1}.mp4".format(q, i))
        enc = _sample_encode_cmd(src, sample, engine, q, ff_encode, gpu_decode,
                                 target_h, av1_preset, cfr_fps, hdr, ss, t)
        try:
            r = subprocess.run(enc, capture_output=True, text=True, timeout=1800)
        except (subprocess.SubprocessError, OSError):
            r = None
        v = bps = None
        if r and r.returncode == 0 and os.path.isfile(sample) and os.path.getsize(sample) > 0:
            if t > 0:
                bps = os.path.getsize(sample) * 8.0 / t   # this sample's bitrate at knob q (byproduct → bitrate map)
            v = _measure_vmaf(ff_measure, src, sample, ss, t, src_w, src_h, cfr_fps, model_arg,
                              os.path.join(workdir, "vmaf_{0}_{1}.json".format(q, i)), n_threads=meas_threads)
        _safe_unlink(sample)
        _tick()
        return (v, bps)

    def score_at(q):
        if q in cache:
            return cache[q]
        if deadline is not None and time.time() > deadline:
            raise TimeoutError("VMAF search exceeded its per-file time cap")
        results = [None] * len(windows)
        with concurrent.futures.ThreadPoolExecutor(max_workers=len(windows)) as ex:
            futs = {ex.submit(_do_window, q, i, ss, t): i for i, (ss, t) in enumerate(windows)}
            for fut in concurrent.futures.as_completed(futs):
                results[futs[fut]] = fut.result()
        if any(r is None or r[0] is None for r in results):
            cache[q] = None
            return None
        cache[q] = sum(r[0] for r in results) / len(results)
        bps = [r[1] for r in results if r[1] is not None]
        if bps:
            bcache[q] = sum(bps) / len(bps)      # mean sample bitrate at this knob
        return cache[q]

    result = _search_quality_knob(lo, hi, target_vmaf, VMAF_TOLERANCE, score_at, on_stage)
    if out_curve is not None:                    # hand back the measured {cq: vmaf} points (for the CRF map)
        for q, v in cache.items():
            if v is not None:
                out_curve[q] = round(float(v), 2)
    if out_bitrate_curve is not None:            # measured {cq: bits/sec} at the same points (for the bitrate map)
        for q, b in bcache.items():
            out_bitrate_curve[q] = int(b)
    return result


# Map the app's quality preset → a target VMAF, overridable per-preset via plugin settings.
_VMAF_SETTING_KEY = {"high": "vmafHigh", "medium": "vmafBalanced", "med": "vmafBalanced",
                     "standard": "vmafBalanced", "balanced": "vmafBalanced",
                     "low": "vmafSmall", "small": "vmafSmall"}


def _target_vmaf(settings, quality):
    default = VMAF_TARGETS.get(quality, 94.0)
    key = _VMAF_SETTING_KEY.get(quality)
    if key is not None:
        try:
            v = float(settings.get(key))
            if 60.0 <= v <= 100.0:   # ignore nonsense; VMAF is 0..100 and <60 is meaningless as a target
                return v
        except (TypeError, ValueError):
            pass
    return default


def _rmtree(path):
    import shutil
    shutil.rmtree(path, ignore_errors=True)


def _run_ffmpeg(cmd, duration, on_status=None):
    """Run one ffmpeg pass, streaming out_time_us → Job.progress. Returns (rc, stderr_tail).

    `on_status(prog_dict, out_seconds)` is called once per -progress block (roughly 1×/sec) with the
    parsed frame/fps/total_size/speed/out_time_us fields — the caller throttles it into a rich
    custom_fields side-channel the app reads for live size/ETA/fps (no log spam).

    ffmpeg's real error goes to stderr; we capture it to a temp file (rather than DEVNULL, which hid
    the cause of the first failures) and return its last meaningful line so the job log explains WHY.
    """
    import tempfile
    err = tempfile.TemporaryFile(mode="w+", encoding="utf-8", errors="replace")
    prog = {}
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=err, text=True)
        try:
            # ffmpeg -progress emits key=value lines in blocks terminated by a `progress=` line.
            for line in proc.stdout:
                line = line.strip()
                key, sep, val = line.partition("=")
                if not sep:
                    continue
                prog[key] = val
                if key == "progress":  # end of a block → update % and the rich side-channel
                    secs = 0.0
                    try:
                        secs = int(prog.get("out_time_us") or 0) / 1_000_000.0
                    except ValueError:
                        pass
                    if duration > 0 and secs > 0:
                        log_progress(secs / duration)
                    if on_status is not None:
                        try:
                            on_status(prog, secs)
                        except Exception:
                            pass
                    if val == "end":
                        log_progress(1.0)
        finally:
            proc.wait()
        tail = ""
        if proc.returncode != 0:
            err.seek(0)
            # The REAL cause (e.g. "[hevc_nvenc @ …] InitializeEncoder failed: invalid param (8)") prints
            # ABOVE ffmpeg's generic trailer lines (Terminating thread / Nothing was written / Conversion
            # failed!), which would displace it from a plain tail. Capture encoder/init error lines
            # explicitly, then append the tail for context.
            lines = [ln.strip() for ln in err.read().splitlines()
                     if ln.strip() and not ln.lstrip().startswith(("frame=", "size=", "video:"))]
            markers = ("nvenc", "initializeencoder", "invalid param", "opensession",
                       "no capable devices", "driver does not support", "hwaccel", "impossible to convert")
            keyed = [ln for ln in lines if any(m in ln.lower() for m in markers)
                     and "terminating thread" not in ln.lower()]
            picked = keyed[-3:] + [ln for ln in lines[-3:] if ln not in keyed[-3:]]
            tail = " / ".join(picked)
        return proc.returncode, tail
    except OSError as e:
        return 127, "could not launch ffmpeg ({}): {}".format(cmd[0], e)
    finally:
        err.close()


def run_transcode(stash, args, settings):
    scene_id = str(args.get("scene_id") or args.get("sceneId") or "").strip()
    if not scene_id:
        raise RuntimeError("transcode: missing scene_id in args")
    # Mark running ASAP so a re-transcode's poll can't briefly read a STALE "ready" from a previous run
    # (and grab the old file). This is the 1st of exactly two custom_fields writes per transcode.
    _write_status(stash, scene_id, {"status": "running"})
    codec = (args.get("codec") or "hevc").lower()
    resolution_arg = str(args.get("resolution") or "1080").lower()
    is_original = resolution_arg in ("original", "orig", "source", "0")
    height = RES_HEIGHTS.get(resolution_arg, 1080)
    cq, cap_frac = QUALITY_PRESETS.get(str(args.get("quality") or "medium").lower(), (28, 0.60))
    # SVT-AV1 preset (speed↔size). Configurable; higher = much faster. AV1-only.
    try:
        av1_preset = int(float(settings.get("av1Preset") or DEFAULT_AV1_PRESET))
    except (TypeError, ValueError):
        av1_preset = DEFAULT_AV1_PRESET
    av1_preset = max(0, min(10, av1_preset))

    ffmpeg = _bin("ffmpeg", settings.get("ffmpegPath"), hw=False)     # software: libsvtav1 / libx265
    ffmpeg_hw = _bin("ffmpeg", settings.get("ffmpegPath"), hw=True)   # hardware: hevc_nvenc (driver-safe)
    ffprobe = _bin("ffprobe", settings.get("ffmpegPath"), hw=False)

    if codec == "av1" and not settings.get("allowAV1", False):
        raise RuntimeError("AV1 requested but disabled in plugin settings")

    scene = find_scene(stash, scene_id)
    if not scene or not scene.get("files"):
        raise RuntimeError("transcode: scene {} has no files".format(scene_id))
    src = scene["files"][0]["path"]
    if not os.path.isfile(src):
        raise RuntimeError("transcode: source file not readable on server: {}".format(src))
    duration = float(scene["files"][0].get("duration") or 0)

    # Probe the source ONCE (no spam) — its pix_fmt / HDR transfer explains NVENC init failures on
    # 10-bit HDR iPhone footage, and is logged so we can see exactly what we're feeding the encoder.
    sprobe = ffprobe_streams(src, ffprobe)
    sv = {}
    if sprobe:
        sv = next((s for s in sprobe.get("streams", []) if s.get("codec_type") == "video"), {})
    src_pix = (sv.get("pix_fmt") or "").lower()
    src_transfer = (sv.get("color_transfer") or "").lower()
    src_ten_bit = "10" in src_pix or "p010" in src_pix or "12" in src_pix
    # fps metadata matters: NVENC validates frameRateNum/Den at init and rejects garbage (0/0, 90k/1,
    # 1000fps VFR web rips) with INVALID_PARAM, while libx265/SVT-AV1 don't care — log both rates.
    log_info("Source: {} {}x{} {} transfer={}{} r_fps={} avg_fps={} range={}".format(
        sv.get("codec_name", "?"), sv.get("width", "?"), sv.get("height", "?"),
        src_pix or "?", src_transfer or "-", " 10-bit" if src_ten_bit else "",
        sv.get("r_frame_rate", "?"), sv.get("avg_frame_rate", "?"), sv.get("color_range", "-")))
    # NVENC hard-validates frame rate at encoder init; ffmpeg opens the encoder lazily from the first
    # filtered frame, whose framerate can resolve to 0/0 → a PTS time_base (e.g. 1/90000 → absurd fps) →
    # NV_ENC_ERR_INVALID_PARAM (-22). Software encoders don't check. Fix: pin a clean CFR rate via the
    # `fps` filter. Use the source's real rate when sane, else a safe default.
    cfr_fps = _clean_fps(sv)

    # HDR preservation: keep HDR10/HLG sources as true 10-bit HDR (Main10 + BT.2020) instead of an 8-bit
    # down-convert, so they display as HDR on iPhone. Only for HEVC/AV1 (not h264); default on.
    preserve = settings.get("preserveHDR")
    preserve = True if preserve is None else bool(preserve)
    hdr = _detect_hdr(sv, preserve) if codec in ("hevc", "av1") else None
    if hdr:
        log_info("HDR: preserving {} (10-bit Main10, BT.2020)".format(hdr.upper()))

    # Bitrate ceiling from the SOURCE so a preset never inflates bitrate (e.g. an 8 Mbps source must not
    # become 20 Mbps). CQ still drives quality; -maxrate just caps the peak at a source-relative ceiling.
    src_vbr = _src_bitrate(sprobe, sv, scene["files"][0])
    maxrate = int(src_vbr * cap_frac) if src_vbr > 0 else 0
    if maxrate:
        log_info("Bitrate cap {:.1f} Mbps ({}% of source {:.1f} Mbps)".format(
            maxrate / 1e6, int(cap_frac * 100), src_vbr / 1e6))

    # Resolve the actual scale height in Python (downscale only, kept even for yuv420p) so the ffmpeg
    # `-vf` is a plain `scale=-2:<int>` — no quotes / no `min(,)` comma to escape. Passing a quoted
    # expression like scale=-2:'min(1080,ih)' via argv (no shell) makes ffmpeg see the literal quotes
    # and fail the filtergraph on EVERY encoder.
    src_h = int(scene["files"][0].get("height") or 0)
    if is_original:
        target_h = 0                     # 0 → no scaling filter: keep source resolution (portrait-safe)
        res_label = src_h or "orig"
    else:
        target_h = min(height, src_h) if src_h > 0 else height
        target_h -= target_h % 2
        if target_h < 2:
            target_h = height
        res_label = target_h

    # --- Engine selection: NVENC is the intended default (the user confirmed
    # Stash drives the NVIDIA GPU for H.264, so hevc_nvenc is available). Build
    # a fallback ladder rather than silently degrading; each attempt still keeps
    # the encode on the GPU until nvenc is genuinely missing. ---
    want = (settings.get("encoder") or "hevc_nvenc").strip().lower()
    force_cpu = want in ("libx265", "x265", "cpu")
    if codec == "av1":
        attempts = [("libsvtav1", False)]
    elif force_cpu:
        attempts = [("libx265", False)]
    elif encoder_available(ffmpeg_hw, "hevc_nvenc"):
        # 1) GPU decode + GPU encode  2) CPU decode + GPU encode  3) CPU x265.
        attempts = [("hevc_nvenc", True), ("hevc_nvenc", False), ("libx265", False)]
    else:
        log_warn("hevc_nvenc NOT found in this ffmpeg build — using libx265 (CPU). "
                 "Point the 'ffmpeg directory override' setting at your NVENC-enabled "
                 "ffmpeg (the same one Stash uses for H.264) to get GPU HEVC.")
        attempts = [("libx265", False)]

    os.makedirs(CACHE_DIR, exist_ok=True)
    out_name = _out_name(scene_id, codec, res_label)
    dst = os.path.join(CACHE_DIR, out_name)
    tmp = dst + ".part"

    # --- VMAF perceptual quality targeting (default on) ----------------------------------------------
    # Replace the preset's fixed CQ/CRF with a value CHOSEN to hit a target VMAF (quality as the eye sees
    # it) by sample-encoding + measuring on the PRIMARY engine. Skipped (→ preset cq) for HDR/DoVi SOURCES
    # (VMAF's model is SDR-trained, so the score would mislead the search — keyed off the source itself, NOT
    # the preserveHDR output setting), when no ffmpeg build has libvmaf, or when probe dims are missing — and
    # any failure mid-search also falls back. The transcode NEVER fails because of VMAF. The chosen knob is
    # calibrated for the PRIMARY engine only; if the encode ladder later falls back to a DIFFERENT engine
    # (whose -cq/-crf scale differs), that attempt uses the engine's own preset cq and we don't report a VMAF
    # we never measured. The FINAL encode still applies the source bitrate cap; the search runs uncapped.
    primary_engine = attempts[0][0]
    chosen_cq = cq
    vmaf_score = None
    vmaf_target = None
    vmaf_engine = None                       # engine chosen_cq/vmaf_score were calibrated for (None = search off/failed)
    crf_source = "preset"                    # how the knob was decided — "map" / "live" / "preset"; published
    map_res = None                           # to the app (progress file + result) so its log shows WHICH
                                             # vmaf-map entry was read (owner: map usage was invisible client-side)
    src_w = int(sv.get("width") or 0)
    src_h_probe = int(sv.get("height") or src_h or 0)
    if _truthy(settings.get("vmafTargeting"), True) and not _source_is_hdr(sv) and duration > 0 \
            and src_w > 0 and src_h_probe > 0:
        target = _target_vmaf(settings, str(args.get("quality") or "medium").lower())
        map_h = _map_lookup_height(target_h, src_h or src_h_probe)
        cached = _cached_crf(scene_id, map_h, target)
        if cached is not None:
            # Precomputed by the scheduled "Compute VMAF Map" task → skip the live analysis entirely.
            chosen_cq, vmaf_score = cached
            vmaf_target = target
            vmaf_engine = primary_engine
            crf_source = "map"
            map_res = _res_key(map_h)
            log_info("VMAF: using precomputed CRF {} (~VMAF {:.1f}, target {}) for scene {} @ {} — "
                     "skipping live analysis".format(chosen_cq, vmaf_score, target, scene_id, _res_key(map_h)))
        else:
            try:                                 # fewer samples = faster analysis, slightly less representative
                vmaf_samples = max(1, min(4, int(float(settings.get("vmafSamples") or VMAF_SAMPLES))))
            except (TypeError, ValueError):
                vmaf_samples = VMAF_SAMPLES
            ff_measure = _vmaf_ffmpeg(ffmpeg, ffmpeg_hw)
            if not ff_measure:
                log_warn("VMAF targeting is on but no ffmpeg build here has libvmaf — using preset cq {}. "
                         "Set the software ffmpeg version to 'latest' (BtbN — bundles libvmaf; jellyfin does "
                         "NOT) and run Install / Switch ffmpeg.".format(cq))
            else:
                ff_encode = ffmpeg_hw if primary_engine == "hevc_nvenc" else ffmpeg
                model_arg = _vmaf_model_arg(ff_measure)
                # PID-scoped workdir so concurrent transcodes of the SAME scene never share sample files.
                work = os.path.join(CACHE_DIR, ".vmaf-{}-{}".format(scene_id, os.getpid()))

                # Live analysis feedback → the served progress file (stage "analyzing" + a 0..1 progress the
                # app shows as "Analyzing quality — X%"). NOTE: we deliberately DON'T call log_progress here,
                # so the Stash Job.progress stays 0 during analysis and the app can tell analyze from encoding.
                vmaf_state = {"note": "", "progress": 0.0}

                def _vmaf_write():
                    _write_progress_file(scene_id, {
                        "status": "running", "stage": "analyzing", "codec": codec,
                        "resolution": res_label, "engine": primary_engine,
                        "note": vmaf_state["note"], "progress": round(vmaf_state["progress"], 4),
                        "vmaf_target": target})

                def _vmaf_stage(msg):
                    log_info(msg)
                    vmaf_state["note"] = msg
                    _vmaf_write()

                def _vmaf_progress(frac):
                    vmaf_state["progress"] = frac
                    _vmaf_write()

                res = None
                try:                             # the WHOLE setup is guarded — a workdir/makedirs hiccup must
                    _rmtree(work)                # not fail an otherwise-fine transcode (never fail over VMAF).
                    os.makedirs(work, exist_ok=True)
                    _vmaf_stage("Analyzing quality — targeting VMAF {} ({} model)…".format(
                        target, "phone" if VMAF_PHONE_MODEL else "default"))
                    res = _vmaf_search(src, primary_engine, attempts[0][1], ff_encode, ff_measure,
                                       target_h, av1_preset, cfr_fps, hdr, duration,
                                       src_w, src_h_probe, target, model_arg, work, _vmaf_stage,
                                       on_progress=_vmaf_progress, samples=vmaf_samples)
                except Exception as e:
                    log_warn("VMAF search errored ({}) — using preset cq {}".format(e, cq))
                finally:
                    _rmtree(work)
                if res:
                    chosen_cq, vmaf_score = res
                    vmaf_target = target
                    vmaf_engine = primary_engine
                    crf_source = "live"
                    log_info("VMAF targeting: chose cq {} → ~VMAF {:.1f} (target {}) for {}".format(
                        chosen_cq, vmaf_score, target, primary_engine))
                else:
                    log_warn("VMAF targeting couldn't measure quality — using preset cq {}.".format(cq))

    # Live rich stats (size/ETA/fps/speed) go to a SERVED FILE the app polls over HTTP — NOT to
    # custom_fields — so a running transcode never fires sceneUpdate/Scene.Update hooks (which were
    # queuing "sync" tasks). custom_fields is written exactly TWICE per transcode: the early "running"
    # marker above, and the terminal result at the end.
    status_state = {"last": 0.0, "label": attempts[0][0], "quality": None}

    def _on_status(prog, secs):
        now = time.time()
        if now - status_state["last"] < 2.0:   # file writes are cheap (no GraphQL) → refresh often
            return
        status_state["last"] = now
        try:
            speed = float((prog.get("speed") or "0x").rstrip("x").strip() or 0)
        except ValueError:
            speed = 0.0
        try:
            fps = float(prog.get("fps") or 0)
        except ValueError:
            fps = 0.0
        try:
            cur_size = int(prog.get("total_size") or 0)
        except ValueError:
            cur_size = 0
        pct = (secs / duration) if duration > 0 else 0.0
        eta = int((duration - secs) / speed) if speed > 0 and duration > secs else None
        size_est = int(cur_size / pct) if pct > 0.02 and cur_size > 0 else None
        blob = {
            "status": "running", "stage": "encoding", "codec": codec, "resolution": res_label,
            "engine": status_state["label"], "progress": round(pct, 4),
            "out_time": round(secs, 1), "duration": round(duration, 1),
            "speed": round(speed, 2), "fps": round(fps, 1),
            "size": cur_size, "size_estimate": size_est, "eta": eta,
        }
        blob.update(status_state.get("quality") or {})   # cq + crf_source (map/live/preset) + map_res
        _write_progress_file(scene_id, blob)

    rc = -1
    eng = attempts[0][0]
    used_cq = chosen_cq
    for idx, (engine, gpu_decode) in enumerate(attempts):
        eng = engine
        # The VMAF-searched cq is calibrated for ONE engine's scale; a fallback to a different engine uses
        # that engine's own preset cq instead (nvenc -cq and x265/av1 -crf are not the same scale).
        used_cq = chosen_cq if engine == vmaf_engine else cq
        is_vmaf = engine == vmaf_engine and vmaf_target is not None
        label = "{}{}".format(engine, " +NVDEC" if gpu_decode else "")
        status_state["label"] = label
        status_state["last"] = 0.0   # let the first block of a new attempt publish immediately
        # Quality provenance for THIS attempt, published with every status write. Honest across engine
        # fallbacks: a non-VMAF engine runs on its own preset cq, so its provenance is "preset".
        status_state["quality"] = {
            "cq": used_cq,
            "crf_source": crf_source if is_vmaf else "preset",
            "map_res": map_res if (is_vmaf and crf_source == "map") else None,
            "vmaf_target": vmaf_target if is_vmaf else None,
            "vmaf_expected": round(vmaf_score, 2) if (is_vmaf and vmaf_score is not None) else None,
        }
        log_info("Transcoding scene {} → {} {}p (cq {}{}, {})".format(
            scene_id, codec, res_label, used_cq,
            " for VMAF {}".format(vmaf_target) if is_vmaf else "", label))
        start_blob = {"status": "running", "stage": "starting",
                      "codec": codec, "resolution": res_label, "engine": label}
        start_blob.update(status_state["quality"])
        _write_progress_file(scene_id, start_blob)
        ff = ffmpeg_hw if engine == "hevc_nvenc" else ffmpeg   # NVENC → driver-safe build; SW → main
        cmd = build_transcode_cmd(src, tmp, codec, target_h, used_cq, ff, engine, gpu_decode,
                                  av1_preset, cfr_fps, hdr, maxrate)
        log_debug("ffmpeg: " + " ".join(cmd))
        rc, err_tail = _run_ffmpeg(cmd, duration, on_status=_on_status)
        if rc == 0 and os.path.isfile(tmp) and os.path.getsize(tmp) > 0:
            break
        _safe_unlink(tmp)
        if err_tail:
            log_warn("ffmpeg ({}) error: {}".format(label, err_tail))
        if idx + 1 < len(attempts):
            log_warn("{} attempt failed (rc {}) — retrying with {}".format(
                label, rc, attempts[idx + 1][0]))
    last_err = err_tail if rc != 0 else ""
    if rc != 0 or not os.path.isfile(tmp):
        _record_status(stash, scene_id, "failed", codec, height, eng, 0, None)  # terminal write
        _clear_progress_file(scene_id)
        detail = " — {}".format(last_err) if last_err else ""
        raise RuntimeError("all transcode attempts failed for scene {} (last rc {}){}".format(
            scene_id, rc, detail))

    os.replace(tmp, dst)  # atomic — never serve a half-written file
    size = os.path.getsize(dst)

    # If the encode fell back to an engine other than the one VMAF was searched on, the measured VMAF/target
    # don't describe the file we actually shipped — don't report them as achieved (the cq scales differ),
    # and the provenance reverts to the fallback engine's preset.
    if eng != vmaf_engine:
        vmaf_score = None
        vmaf_target = None
        crf_source = "preset"
        map_res = None

    # Probe the ACTUAL output once (not a spam loop) so we report — and hand the app — the real codec /
    # dimensions / bitrate of the file we produced, rather than what was requested. This also makes it
    # obvious in the log whether NVENC actually emitted HEVC.
    out_codec, out_audio, out_w, out_h, out_bitrate = codec, None, None, height, None
    probe = ffprobe_streams(dst, ffprobe)
    if probe:
        v = next((s for s in probe.get("streams", []) if s.get("codec_type") == "video"), {})
        a = next((s for s in probe.get("streams", []) if s.get("codec_type") == "audio"), {})
        out_codec = (v.get("codec_name") or codec).lower()
        out_audio = (a.get("codec_name") or None)
        out_w = int(v.get("width") or 0) or None
        out_h = int(v.get("height") or 0) or target_h
        try:
            out_bitrate = int(probe.get("format", {}).get("bit_rate") or 0) or None
        except (TypeError, ValueError):
            out_bitrate = None
    if not out_bitrate and duration > 0:
        out_bitrate = int(size * 8 / duration)
    log_info("Done: {} — {} {}x{} @ {} ({:.0f} MB)".format(
        out_name, out_codec, out_w or "?", out_h or "?",
        "{:.1f} Mbps".format(out_bitrate / 1e6) if out_bitrate else "?", size / 1e6))

    result = {
        "path": "{}/{}".format(CACHE_URL_PREFIX, out_name),
        "size": size,
        "codec": out_codec,           # ACTUAL codec (hevc/av1/h264) from ffprobe, not the request
        "container": "mp4",
        "resolution": out_h or height,
        "video_codec": out_codec,
        "audio_codec": out_audio,
        "width": out_w,
        "height": out_h or height,
        "bitrate": out_bitrate,
        "engine": eng,                          # encoder that actually produced this file
        "cq": used_cq,                          # the quality knob actually used (VMAF-chosen or preset)
        "vmaf": round(vmaf_score, 2) if vmaf_score is not None else None,   # achieved (sampled) VMAF, or null
        "vmaf_target": vmaf_target,             # the target it aimed for, or null when VMAF wasn't applied
        "crf_source": crf_source,               # "map" (vmaf-map entry) / "live" (sampled search) / "preset"
        "map_res": map_res,                     # the vmaf-map res key consumed (e.g. "1080p"), map hits only
        "source_scene": scene_id,
        "created": int(time.time()),
        "status": "ready",
    }
    _write_sidecar(out_name, result)
    set_custom_field(stash, scene_id, CUSTOM_FIELD_KEY, json.dumps(result))  # terminal write (2nd of 2)
    _clear_progress_file(scene_id)
    enforce_cache_cap(settings)
    log_progress(1.0)
    return result


def _record_status(stash, scene_id, status, codec, height, eng, size, path):
    _write_status(stash, scene_id, {
        "status": status, "codec": codec, "resolution": height,
        "engine": eng, "size": size, "path": path,
    })


def _write_status(stash, scene_id, blob):
    """Best-effort write of a status blob to the source scene's custom_fields (the app's live
    side-channel). Always stamps `updated`; never raises — status must not fail the job."""
    try:
        blob = dict(blob)
        blob.setdefault("updated", int(time.time()))
        set_custom_field(stash, scene_id, CUSTOM_FIELD_KEY, json.dumps(blob))
    except Exception as e:
        log_debug("status write failed: {}".format(e))


def _write_sidecar(out_name, result):
    try:
        with open(os.path.join(CACHE_DIR, out_name + ".json"), "w") as fh:
            json.dump(result, fh)
    except OSError:
        pass


def _progress_path(scene_id):
    return os.path.join(CACHE_DIR, "scene{}.progress.json".format(scene_id))


def _write_progress_file(scene_id, blob):
    """Write live transcode stats to a SERVED file (/plugin/.../assets/cache/scene<id>.progress.json) the
    app polls over HTTP. Filesystem-only → no sceneUpdate, no Scene.Update hooks, no queued tasks. Atomic."""
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        blob = dict(blob)
        blob.setdefault("updated", int(time.time()))
        tmp = _progress_path(scene_id) + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(blob, fh)
        os.replace(tmp, _progress_path(scene_id))
    except OSError:
        pass


def _clear_progress_file(scene_id):
    _safe_unlink(_progress_path(scene_id))


def _safe_unlink(path):
    try:
        os.remove(path)
    except OSError:
        pass


# ----------------------------------------------------------------------------
# Cache cap (LRU purge).
# ----------------------------------------------------------------------------
def enforce_cache_cap(settings):
    cap_gb = settings.get("cacheCapGB") or 0
    try:
        cap = float(cap_gb) * (1024 ** 3)
    except (TypeError, ValueError):
        cap = 0
    if cap <= 0 or not os.path.isdir(CACHE_DIR):
        return
    files = []
    for n in os.listdir(CACHE_DIR):
        if not n.endswith(".mp4"):
            continue
        p = os.path.join(CACHE_DIR, n)
        try:
            st = os.stat(p)
            files.append((st.st_atime, st.st_size, p))
        except OSError:
            pass
    total = sum(f[1] for f in files)
    if total <= cap:
        return
    for _, sz, p in sorted(files):  # oldest access first
        if total <= cap:
            break
        _safe_unlink(p)
        _safe_unlink(p + ".json")
        total -= sz
        log_info("cache purge: removed {}".format(os.path.basename(p)))


def run_purge(settings):
    if not os.path.isdir(CACHE_DIR):
        log_info("cache empty")
        return
    cap_gb = settings.get("cacheCapGB") or 0
    if cap_gb and float(cap_gb) > 0:
        enforce_cache_cap(settings)
        log_info("cache trimmed to {} GB cap".format(cap_gb))
        return
    removed = 0
    for n in os.listdir(CACHE_DIR):
        p = os.path.join(CACHE_DIR, n)
        try:
            if os.path.isdir(p):
                _rmtree(p)   # e.g. an orphaned .vmaf-<scene>-<pid> workdir left by a killed transcode
            else:
                os.remove(p)
            removed += 1
        except OSError:
            pass
    log_info("cache purged ({} entries)".format(removed))


def run_delete(args):
    """Delete the cached transcode(s) for ONE scene — the app calls this after it finishes downloading a
    server-transcoded file, so proxies don't accumulate. Output is named scene<id>_<codec>_<h>p.mp4 (plus a
    .json sidecar); the live progress file is scene<id>.progress.json. Match by the scene<id>_ prefix."""
    scene_id = str(args.get("scene_id") or "").strip()
    if not scene_id:
        log_error("delete: missing scene_id")
        return
    removed = 0
    if os.path.isdir(CACHE_DIR):
        prefix = "scene{}_".format(scene_id)
        for n in os.listdir(CACHE_DIR):
            if n.startswith(prefix) and n.endswith(".mp4"):
                p = os.path.join(CACHE_DIR, n)
                _safe_unlink(p)
                _safe_unlink(p + ".json")
                removed += 1
    _safe_unlink(_progress_path(scene_id))
    log_info("deleted cache for scene {} ({} file(s))".format(scene_id, removed))


# ----------------------------------------------------------------------------
# ffmpeg version management: download + PIN + switch between BtbN static builds
# (SVT-AV1 3.x + nvenc + libx265), self-contained. Builds coexist under bin/<tag>/;
# switching is instant when a version is already present. Opt-in; stdlib only.
# ----------------------------------------------------------------------------
def _ffmpeg_summary(ff):
    """(first `-version` line, {encoder: bool}) for a given ffmpeg binary, or (error, {})."""
    try:
        ver = subprocess.run([ff, "-hide_banner", "-version"], capture_output=True, text=True, timeout=30)
        first = (ver.stdout.splitlines() or ["?"])[0]
        enc = subprocess.run([ff, "-hide_banner", "-encoders"], capture_output=True, text=True, timeout=30).stdout
        return first, {"hevc_nvenc": "hevc_nvenc" in enc, "libsvtav1": "libsvtav1" in enc,
                       "libx265": "libx265" in enc}
    except (subprocess.SubprocessError, OSError) as e:
        return "won't run: {}".format(e), {}


def _download_and_extract(tag, url, sha_expect):
    """Download `url`, extract the WHOLE tree into bin/<tag>/x, locate ffmpeg+ffprobe wherever they are
    (BtbN = single static binary in bin/; jellyfin = binary + bundled lib/ beside it), and record the
    directory in bin/<tag>/.ffdir. Returns (version_line, encoders_dict). Raises on any failure."""
    import hashlib
    import shutil
    import tarfile

    vdir = _version_dir(tag)
    os.makedirs(vdir, exist_ok=True)
    archive = os.path.join(vdir, "_dl.tar.xz")
    log_info("Downloading {} from {}".format(tag, url))
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "stashy-companion"})
        with urllib.request.urlopen(req, timeout=600) as r:
            total = int(r.headers.get("Content-Length") or 0)
            got, hasher = 0, hashlib.sha256()
            with open(archive, "wb") as f:
                while True:
                    chunk = r.read(1 << 20)
                    if not chunk:
                        break
                    f.write(chunk)
                    hasher.update(chunk)
                    got += len(chunk)
                    if total > 0:
                        log_progress(0.9 * got / total)
    except (urllib.error.URLError, OSError) as e:
        _safe_unlink(archive)
        raise RuntimeError("download failed for {} ({}): {}".format(tag, url, e))

    if sha_expect and hasher.hexdigest() != sha_expect:
        _safe_unlink(archive)
        raise RuntimeError("sha256 mismatch for {}: expected {} got {}".format(tag, sha_expect, hasher.hexdigest()))

    extract_dir = os.path.join(vdir, "x")
    shutil.rmtree(extract_dir, ignore_errors=True)
    os.makedirs(extract_dir)
    try:
        with tarfile.open(archive, "r:xz") as tar:
            try:
                tar.extractall(extract_dir, filter="data")   # 3.12+ safe extraction
            except TypeError:
                tar.extractall(extract_dir)                   # older Python (no filter arg)
    except (tarfile.TarError, OSError) as e:
        raise RuntimeError("could not extract {}: {}".format(tag, e))
    finally:
        _safe_unlink(archive)

    ff = ffp = None
    for root, _dirs, files in os.walk(extract_dir):
        if not ff and "ffmpeg" in files:
            ff = os.path.join(root, "ffmpeg")
        if not ffp and "ffprobe" in files:
            ffp = os.path.join(root, "ffprobe")
    if not ff or not ffp:
        raise RuntimeError("{} archive did not contain both ffmpeg and ffprobe".format(tag))
    os.chmod(ff, 0o755)
    os.chmod(ffp, 0o755)
    ffdir = os.path.dirname(ff)
    if os.path.dirname(ffp) != ffdir:   # keep ffprobe beside ffmpeg (both builds ship them together)
        try:
            os.symlink(ffp, os.path.join(ffdir, "ffprobe"))
        except OSError:
            shutil.copy2(ffp, os.path.join(ffdir, "ffprobe"))
    with open(os.path.join(vdir, ".ffdir"), "w") as f:
        f.write(ffdir)

    first, enc = _ffmpeg_summary(ff)
    if not enc:
        raise RuntimeError("{} won't run (missing libs?): {}".format(tag, first))
    return first, enc


def _install_or_switch(tag, hw, label, url_override="", sha_expect=""):
    """Activate `tag` for the main (hw=False) or NVENC (hw=True) slot — instant if already installed, else
    download+extract. `system` clears the slot to fall back to PATH / override / Stash's ffmpeg."""
    if tag in ("system", "none", "path", ""):
        _set_active("system", hw)
        log_info("{}: SYSTEM ffmpeg (PATH / override / Stash bundled)".format(label))
        return
    if _tag_ffdir(tag):   # already installed → instant switch
        _set_active(tag, hw)
        first, enc = _ffmpeg_summary(os.path.join(_tag_ffdir(tag), "ffmpeg"))
        log_info("{}: switched to {} — {} · nvenc={} svtav1={}".format(
            label, tag, first, enc.get("hevc_nvenc"), enc.get("libsvtav1")))
        return
    first, enc = _download_and_extract(tag, url_override or _ffmpeg_url(tag), sha_expect)
    _set_active(tag, hw)
    log_progress(1.0)
    log_info("{}: installed + active {} — {} · nvenc={} svtav1={} x265={}".format(
        label, tag, first, enc.get("hevc_nvenc"), enc.get("libsvtav1"), enc.get("libx265")))


def run_update_ffmpeg(settings):
    main_tag = (settings.get("ffmpegVersion") or DEFAULT_FFMPEG_TAG).strip()
    hw_tag = (settings.get("ffmpegHwVersion") or DEFAULT_HW_TAG).strip()
    # Main/software build (AV1 + x265 + ffprobe): honours the advanced URL/sha overrides.
    _install_or_switch(main_tag, hw=False, label="software",
                       url_override=(settings.get("ffmpegDownloadURL") or "").strip(),
                       sha_expect=(settings.get("ffmpegSha256") or "").strip().lower())
    # NVENC build: same as main unless a distinct hw version is set (default jellyfin for old drivers).
    if hw_tag and hw_tag != main_tag:
        _install_or_switch(hw_tag, hw=True, label="hardware (NVENC)")
    else:
        _set_active(main_tag if main_tag not in ("system", "none", "path", "") else "system", hw=True)


def _nvenc_probe(ffmpeg, encoder, extra_args):
    """Try to OPEN an NVENC encoder on a short synthetic source (no real file). Returns (ok, reason).
    Surfaces the REAL nvenc/driver reason by filtering OUT ffmpeg's generic wrapper lines."""
    cmd = ([ffmpeg, "-hide_banner", "-loglevel", "verbose", "-f", "lavfi",
            "-i", "color=c=black:s=1280x720:r=30", "-frames:v", "5", "-c:v", encoder]
           + extra_args + ["-f", "null", "-"])
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    except (subprocess.SubprocessError, OSError) as e:
        return False, str(e)
    if r.returncode == 0:
        return True, ""
    generic = ("task finished with error", "received eof", "could not open encoder before eof",
               "nothing was written", "conversion failed", "error while opening encoder",
               "terminating thread")
    lines = [ln.strip() for ln in r.stderr.splitlines() if ln.strip()]
    real = [ln for ln in lines if not any(g in ln.lower() for g in generic)
            and any(m in ln.lower() for m in
                    ("nvenc", "driver", "device", "cuda", "api", "capab", "not support",
                     "version", "openencodesession", "initializeencoder", "session", "unsupported"))]
    return False, (" / ".join(real[-3:]) if real else " / ".join(lines[-2:]) or "rc {}".format(r.returncode))


def _nvidia_smi():
    """GPU name + driver version via nvidia-smi, or None if unavailable."""
    try:
        r = subprocess.run(["nvidia-smi", "--query-gpu=name,driver_version", "--format=csv,noheader"],
                           capture_output=True, text=True, timeout=15)
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip().replace("\n", " · ")
    except (subprocess.SubprocessError, OSError):
        pass
    return None


def run_selftest(stash, settings):
    """One-shot health check after a Stash upgrade / config change. Reports the ACTIVE ffmpeg version and
    everything the transcode pipeline depends on, then a PASS/FAIL line. A few lines — deliberately no spam."""
    ok = True
    log_info("── Stashy Companion self-test ──")
    log_info("Python {}".format(sys.version.split()[0]))

    try:
        v = stash.call("query { version { version } }")
        log_info("GraphQL OK — Stash {}".format((v.get("version") or {}).get("version", "?")))
    except Exception as e:
        ok = False
        log_error("GraphQL FAIL — {}".format(e))

    override = settings.get("ffmpegPath")
    ffmpeg = _bin("ffmpeg", override, hw=False)
    ffmpeg_hw = _bin("ffmpeg", override, hw=True)
    first, enc = _ffmpeg_summary(ffmpeg)
    if enc:
        log_info("ffmpeg (software) [{}] {}".format(_active_tag(False) or "system", first))
        log_info("  encoders: libsvtav1={} libx265={}".format(enc.get("libsvtav1"), enc.get("libx265")))
        if not enc.get("libx265"):
            log_warn("  software HEVC (libx265) missing — the CPU fallback won't work")
    else:
        ok = False
        log_error("ffmpeg (software) FAIL — {} ({})".format(first, ffmpeg))

    # Hardware build + NVENC capability. h264_nvenc is a control (Stash uses it); comparing the two + the
    # driver version pinpoints a driver-vs-API mismatch. Probe runs on the HARDWARE build actually used.
    smi = _nvidia_smi()
    if smi:
        log_info("GPU: {}".format(smi))
    hw_first, hw_enc = _ffmpeg_summary(ffmpeg_hw)
    if hw_enc:
        log_info("ffmpeg (NVENC) [{}] {}".format(_active_tag(True) or "system", hw_first))
        if hw_enc.get("hevc_nvenc"):
            h264_ok, h264_why = _nvenc_probe(ffmpeg_hw, "h264_nvenc", ["-pix_fmt", "yuv420p"])
            hevc_ok, hevc_why = _nvenc_probe(ffmpeg_hw, "hevc_nvenc", ["-pix_fmt", "yuv420p"])
            log_info("  h264_nvenc (control): {}".format("OK" if h264_ok else "FAIL — " + h264_why))
            log_info("  hevc_nvenc: {}".format("OK" if hevc_ok else "FAIL — " + hevc_why))
            if hevc_ok:
                log_info("  → GPU HEVC works")
            elif h264_ok:
                log_warn("  → h264_nvenc opens but hevc_nvenc doesn't: HEVC/driver limit on this GPU.")
            else:
                log_warn("  → NVENC won't open on this build/driver. Set ffmpegHwVersion=jellyfin (built "
                         "for driver ≥520) and run Install / Switch ffmpeg.")
        else:
            log_info("  (this build has no hevc_nvenc; CPU encoders will be used)")
    else:
        log_warn("NVENC build FAIL — {}".format(hw_first))

    installed = []
    if os.path.isfile(os.path.join(BIN_DIR, "ffmpeg")):
        installed.append("legacy-flat")
    if os.path.isdir(BIN_DIR):
        for n in sorted(os.listdir(BIN_DIR)):
            if _tag_ffdir(n):
                marks = "".join(m for m, on in ((" *sw", n == _active_tag(False)),
                                                (" *hw", n == _active_tag(True))) if on)
                installed.append(n + marks)
    log_info("installed builds: {}".format(", ".join(installed) or "(none — using system ffmpeg)"))

    # VMAF perceptual quality targeting — is libvmaf present, and does a real measurement actually run?
    # (Non-fatal: if it's missing/broken, transcodes just fall back to the preset cq — so it only warns.)
    vff = _vmaf_ffmpeg(ffmpeg, ffmpeg_hw)
    if not vff:
        log_warn("VMAF: no libvmaf filter in either ffmpeg build → VMAF quality targeting will fall back "
                 "to the preset cq. Set the software ffmpeg version to 'latest' (BtbN — bundles libvmaf; "
                 "jellyfin does NOT) and run Install / Switch ffmpeg.")
    else:
        model_arg = _vmaf_model_arg(vff)
        api = "new model= API" if _libvmaf_new_api(vff) else "old phone_model= API"
        log_info("VMAF: libvmaf present [{}], {} model → {}".format(
            api, "phone" if VMAF_PHONE_MODEL else "default", model_arg or "(default)"))
        try:
            import tempfile
            tmpd = tempfile.mkdtemp(prefix="vmaf-selftest-", dir=CACHE_DIR)
            testfile = os.path.join(tmpd, "t.mp4")
            gen = subprocess.run([vff, "-y", "-hide_banner", "-f", "lavfi",
                                  "-i", "testsrc2=size=320x240:rate=30", "-t", "1",
                                  "-c:v", "mpeg4", "-pix_fmt", "yuv420p", testfile],
                                 capture_output=True, text=True, timeout=60)
            score = None
            if gen.returncode == 0 and os.path.isfile(testfile):
                # Measure the clip against itself — proves the model loads + the filtergraph parses.
                score = _measure_vmaf(vff, testfile, testfile, 0, 1, 320, 240, "30",
                                      model_arg, os.path.join(tmpd, "v.json"))
            _rmtree(tmpd)
            if score is not None:
                log_info("  VMAF self-measure OK — identical clip scored {:.1f}".format(score))
            else:
                log_warn("  VMAF self-measure FAILED — targeting will fall back to the preset cq. "
                         "Detail: {}".format(_VMAF_LAST_ERR["msg"] or "no score produced"))
        except (subprocess.SubprocessError, OSError) as e:
            log_warn("  VMAF self-measure error: {}".format(e))

    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        probe = os.path.join(CACHE_DIR, ".selftest")
        with open(probe, "w") as f:
            f.write("ok")
        os.remove(probe)
        log_info("cache dir writable — served at {}".format(CACHE_URL_PREFIX))
    except OSError as e:
        ok = False
        log_error("cache dir FAIL — {}".format(e))

    log_progress(1.0)
    log_info("── self-test {} ──".format("PASSED" if ok else "FAILED (see above)"))


# ----------------------------------------------------------------------------
# Stats + tagging (ffprobe-derived, iterates the whole library).
# ----------------------------------------------------------------------------
HDR_TRANSFERS = {"smpte2084", "arib-std-b67", "smpte2086", "bt2020-10", "bt2020-12"}
# Truly zero-conversion (direct play) video: H.264 or AV1 in an Apple-native container, 8-bit SDR 4:2:0.
# HEVC is deliberately EXCLUDED — the app remuxes hev1→hvc1 first (an on-device remux, not direct play),
# so tagging HEVC as "Direct-Play" would be a lie. Mirrors StashScene.directPlayCodecs on the app side.
DIRECT_PLAY_VIDEO = {"h264", "avc", "avc1", "av1", "av01"}
DIRECT_PLAY_CONTAINER = ("mp4", "mov", "m4v", "quicktime")
# Codecs Apple can decode at all (natively, or via the app's on-device remux/transcode of a 4:2:0 stream).
APPLE_DECODABLE_CODECS = ("h264", "avc", "hevc", "h265", "hvc", "av1", "av01")
# Pixel formats Apple's H.264/HEVC decoders cannot handle → must transcode (server or on-device re-encode).
# Mirrors ScenePlayerModel.needsTranscode(pixFmt:) so the app's routing can trust this verdict.
UNDECODABLE_PIX = ("422", "444", "12le", "12be", "gbr")


def _analyze(probe):
    v = next((s for s in probe.get("streams", []) if s.get("codec_type") == "video"), {})
    fmt = (probe.get("format", {}).get("format_name") or "").lower()
    pix = (v.get("pix_fmt") or "").lower()
    transfer = (v.get("color_transfer") or "").lower()
    codec = (v.get("codec_name") or "").lower()
    ten_bit = "10" in pix or "p010" in pix or (v.get("bits_per_raw_sample") in ("10", 10))
    hdr = transfer in HDR_TRANSFERS
    # Apple can't decode this stream at all (exotic pixel format, or a codec outside its decoders) → the
    # app's server / on-device *transcode* tier. This is the verdict routing most wants: it's the case the
    # app otherwise only discovers after a doomed remux attempt.
    undecodable = (any(t in pix for t in UNDECODABLE_PIX)
                   or (codec != "" and not any(c in codec for c in APPLE_DECODABLE_CODECS)))
    direct = (any(c == codec or c in codec for c in DIRECT_PLAY_VIDEO)
              and any(c in fmt for c in DIRECT_PLAY_CONTAINER)
              and not undecodable and not ten_bit and not hdr)
    tier = "transcode" if undecodable else ("direct" if direct else "remux")
    return {
        "codec": codec,
        "profile": v.get("profile"),
        "pix_fmt": pix,
        "color_transfer": transfer or None,
        "hdr": hdr,
        "ten_bit": bool(ten_bit),
        "direct_play": bool(direct),
        "needs_transcode": bool(undecodable),
        # direct | remux | transcode — matches the app's routing tiers so filter + routing agree.
        "tier": tier,
    }


# Codec efficiency vs H.264 (HEVC/AV1 reach the same quality at ~half the bitrate). Used to normalize
# bits-per-pixel into an H.264-equivalent quality score.
CODEC_EFF = {
    "h264": 1.0, "avc": 1.0, "avc1": 1.0, "x264": 1.0,
    "hevc": 0.55, "h265": 0.55, "hvc1": 0.55, "hev1": 0.55, "x265": 0.55,
    "av1": 0.5, "av01": 0.5,
    "vp9": 0.6, "vp09": 0.6, "vp8": 1.1,
    "mpeg4": 1.4, "mpeg2video": 1.6, "msmpeg4v3": 1.6, "wmv3": 1.5, "vc1": 1.2,
}


def _num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return 0.0


def _quality(scene_file):
    """Resolution (height), fps and a codec-normalized quality tier from Stash's stored file metadata.
    quality = bits-per-pixel-per-frame (bitrate / (w*h*fps)) ÷ codec efficiency, bucketed against
    H.264-equivalent thresholds (web-rip ~0.04, Netflix 1080p ~0.10, Blu-ray ~0.12, YouTube ~0.16).
    'unknown' when metadata is missing → excluded from the quality filter."""
    w = int(_num(scene_file.get("width")))
    h = int(_num(scene_file.get("height")))
    br = int(_num(scene_file.get("bit_rate")))
    fps = _num(scene_file.get("frame_rate"))
    if not (1 <= fps <= 240):
        fps = 30.0
    codec = (scene_file.get("video_codec") or "").lower()
    quality = "unknown"
    adj = 0.0
    if w > 0 and h > 0 and br > 0:
        adj = (br / float(w * h * fps)) / CODEC_EFF.get(codec, 1.0)
        if adj >= 0.15:
            quality = "ultra"
        elif adj >= 0.08:
            quality = "high"
        elif adj >= 0.04:
            quality = "standard"
        else:
            quality = "low"
    return {
        "height": h or None,
        "fps": round(fps, 3) if fps else None,
        "bitrate": br or None,
        "quality": quality,
        "qscore": round(adj, 5),   # continuous score for the Quality sort
    }


def _iter_scenes(stash, page_size=100):
    page = 1
    while True:
        data = stash.call(
            "query($f: FindFilterType!) { findScenes(filter: $f) { count scenes { %s } } }" % SCENE_FIELDS,
            {"f": {"per_page": page_size, "page": page, "sort": "id", "direction": "ASC"}},
        )
        block = data.get("findScenes") or {}
        scenes = block.get("scenes") or []
        if not scenes:
            break
        yield block.get("count", 0), scenes
        if len(scenes) < page_size:
            break
        page += 1


def run_stats(stash, settings, rebuild=False):
    """ffprobe scenes and write the whole library's playability to ONE served file
    (cache/playability.json) the app reads over HTTP. **Incremental by default**: scenes already in the
    report are skipped (the slow ffprobe is avoided), scenes that no longer exist are pruned — so re-running
    after a Stash scan only analyzes the NEW files. `rebuild=True` re-analyzes everything. Makes **zero**
    sceneUpdate calls, so it fires no Scene.Update hooks and queues no "Sync" tasks, however large the
    library. (The Scene.Create.Post hook keeps this current automatically; this task is the manual catch-up
    / first build.)"""
    ffprobe = _bin("ffprobe", settings.get("ffmpegPath"))
    report = {} if rebuild else _load_playability()
    agg = {"total": 0, "new": 0, "direct": 0, "remux": 0, "transcode": 0, "hdr": 0}
    seen = set()

    total_count = 0
    for count, _ in _iter_scenes(stash, page_size=1):
        total_count = count
        break

    processed = 0
    for count, scenes in _iter_scenes(stash):
        total_count = count or total_count
        for scene in scenes:
            processed += 1
            if total_count:
                log_progress(processed / float(total_count))
            sid = str(scene["id"])
            seen.add(sid)
            agg["total"] += 1
            if sid in report and not rebuild:
                continue   # already analyzed — incremental skip
            files = scene.get("files") or []
            if not files:
                continue
            probe = ffprobe_streams(files[0]["path"], ffprobe)
            if not probe:
                continue
            info = _analyze(probe)
            entry = _entry(info)
            entry.update(_quality(files[0]))   # resolution + fps + quality tier (from Stash file metadata)
            report[sid] = entry
            agg["new"] += 1
            agg[info["tier"]] = agg.get(info["tier"], 0) + 1
            if info["hdr"]:
                agg["hdr"] += 1

    pruned = [sid for sid in report if sid not in seen]   # scenes deleted from Stash since last run
    for sid in pruned:
        del report[sid]

    _write_playability_file(report)
    log_info("Library codec report ({}) — {} scenes total, {} newly analyzed, {} pruned. New this run: "
             "{} direct-play, {} remux, {} transcode, {} HDR. Served playability.json — no scene writes."
             .format("rebuild" if rebuild else "incremental", agg["total"], agg["new"], len(pruned),
                     agg["direct"], agg["remux"], agg["transcode"], agg["hdr"]))
    log_progress(1.0)
    return agg


def _playability_path():
    return os.path.join(CACHE_DIR, "playability.json")


def _entry(info):
    return {k: info[k] for k in ("tier", "needs_transcode", "direct_play", "hdr", "ten_bit", "codec", "pix_fmt")}


def _load_playability():
    """The current served report as {scene_id: entry}, or {} if none / unreadable."""
    try:
        with open(_playability_path()) as fh:
            scenes = (json.load(fh) or {}).get("scenes")
        return scenes if isinstance(scenes, dict) else {}
    except (OSError, ValueError):
        return {}


@contextlib.contextmanager
def _playability_lock():
    """Serialize concurrent writers of playability.json — the manual report and any number of concurrent
    Scene.Create.Post hook processes during a scan — so appends never clobber each other."""
    os.makedirs(CACHE_DIR, exist_ok=True)
    lockf = open(_playability_path() + ".lock", "w")
    try:
        if fcntl:
            try:
                fcntl.flock(lockf, fcntl.LOCK_EX)
            except OSError:
                pass
        yield
    finally:
        try:
            if fcntl:
                fcntl.flock(lockf, fcntl.LOCK_UN)
        finally:
            lockf.close()


def _write_playability_raw(report):
    blob = {"generated": int(time.time()), "count": len(report), "scenes": report}
    tmp = _playability_path() + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(blob, fh)
    os.replace(tmp, _playability_path())


def _write_playability_file(report):
    """Whole-library playability map → the served file, under the write lock. Filesystem-only: no
    sceneUpdate, no Scene.Update hooks, no queued Sync tasks. Atomic."""
    with _playability_lock():
        _write_playability_raw(report)


def _report_scene_append(stash, settings, scene_id):
    """ffprobe ONE scene and merge it into the served report (under the lock). The Scene.Create.Post hook
    calls this so a newly-scanned file flows into the report automatically. Zero scene writes."""
    scene = find_scene(stash, scene_id)
    files = (scene or {}).get("files") or []
    if not files:
        return
    ffprobe = _bin("ffprobe", settings.get("ffmpegPath"))
    probe = ffprobe_streams(files[0]["path"], ffprobe)
    if not probe:
        return
    info = _analyze(probe)
    with _playability_lock():
        data = _load_playability()
        data[str(scene_id)] = _entry(info)
        _write_playability_raw(data)
    log_info("Auto codec-reported scene {} → {} (served file, no scene writes).".format(scene_id, info["tier"]))


def _report_scene_remove(scene_id):
    with _playability_lock():
        data = _load_playability()
        if str(scene_id) in data:
            del data[str(scene_id)]
            _write_playability_raw(data)


# ----------------------------------------------------------------------------
# VMAF CRF map: a scheduled/manual LIBRARY task runs the VMAF search per scene per output
# resolution and stores just the tiny result (the chosen CRF + the sampled curve) in a served
# file. Downloads/streams then look up the per-video VMAF-optimal CRF and SKIP the ~30s live
# analysis — the search's expensive part (sample encodes) is transient; only the CRF number is
# kept, so the whole library costs kilobytes, not terabytes.
# ----------------------------------------------------------------------------
DEFAULT_MAP_RESOLUTIONS = "1080,720"


def _res_key(target_h):
    """Map key for one output resolution = the resolved output height ('720', '1080'), or 'orig' for the
    source resolution. So a '1080' request on a 720p source and a '720' request key the same (both 720p)."""
    th = int(target_h or 0)
    return str(th) if th > 0 else "orig"


def _out_height(res_key_req, src_h):
    """Resolve a requested resolution token ('1080'/'720'/'original') to an even output height for THIS
    source (downscale only), matching run_transcode. 0 = keep source resolution."""
    if str(res_key_req).lower() in ("original", "orig", "source", "0"):
        return 0
    h = RES_HEIGHTS.get(str(res_key_req), 0)
    if not h and str(res_key_req).isdigit():
        h = int(res_key_req)
    th = min(h, src_h) if (h and src_h > 0) else h
    return (th - th % 2) if th else 0


def _crf_from_curve(curve, target, tol=VMAF_TOLERANCE):
    """Derive (crf, vmaf) for ANY target VMAF from a stored {cq: vmaf} curve without re-searching: the
    LARGEST cq whose measured VMAF still meets target-tol (the same rule the live search uses). Returns None
    when the target isn't covered by the measured points → the caller falls back to a live search (we never
    extrapolate past what was actually measured)."""
    pts = []
    for k, v in (curve or {}).items():
        try:
            pts.append((int(k), float(v)))
        except (TypeError, ValueError):
            continue
    if not pts:
        return None
    pts.sort()                                    # by cq ascending (VMAF decreases as cq rises)
    best = None
    for cq, v in pts:
        if v >= target - tol:
            best = (cq, v)
    return best                                   # None if even the highest-quality measured point misses


def _bitrates_from_curves(vmaf_curve, bitrate_curve, targets):
    """Resolve {preset: bits/sec} from a measured VMAF curve + bitrate curve. For each preset's target
    VMAF, pick the CQ the live search would (largest CQ still meeting target, via _crf_from_curve) and read
    that CQ's measured bitrate. Presets whose CQ has no measured bitrate are omitted (the app then falls back
    to its own preset ladder for that one). Keys tolerate int or str CQ (stored curves use str)."""
    out = {}
    for name, tv in (targets or {}).items():
        pick = _crf_from_curve(vmaf_curve, float(tv))
        if not pick:
            continue
        cq = pick[0]
        bps = bitrate_curve.get(cq)
        if bps is None:
            bps = bitrate_curve.get(str(cq))
        if bps:
            out[name] = int(bps)
    return out


def _backfill_bitrates(src, engine, gpu_decode, ff_encode, target_h, cfr_fps, duration, entry_res,
                       targets, workdir):
    """Cheap bitrate fill for a res entry mapped BEFORE bitrate capture (has a VMAF curve, no bitrates):
    encode ONE short sample at each distinct preset-derived CQ — NO VMAF measurement (the expensive part is
    skipped) — and read its bitrate. Returns {preset: bps}, or {} on any failure (best-effort; on failure the
    caller leaves the entry unchanged and simply retries next run)."""
    vmaf_curve = entry_res.get("curve") or {}
    cqs = set()
    for tv in (targets or {}).values():
        pick = _crf_from_curve(vmaf_curve, float(tv))
        if pick:
            cqs.add(pick[0])
    if not cqs:
        return {}
    windows = _vmaf_sample_windows(duration, 1, VMAF_SAMPLE_SECS)   # one window is plenty to estimate bitrate
    if not windows:
        return {}
    ss, t = windows[0]
    bitrate_curve = {}
    for cq in cqs:
        sample = os.path.join(workdir, "bf_{}.mp4".format(cq))
        enc = _sample_encode_cmd(src, sample, engine, cq, ff_encode, gpu_decode, target_h,
                                 DEFAULT_AV1_PRESET, cfr_fps, None, ss, t)
        try:
            r = subprocess.run(enc, capture_output=True, text=True, timeout=1800)
            if r.returncode == 0 and os.path.isfile(sample) and os.path.getsize(sample) > 0 and t > 0:
                bitrate_curve[cq] = int(os.path.getsize(sample) * 8 / t)
        except (subprocess.SubprocessError, OSError):
            pass
        _safe_unlink(sample)
    return _bitrates_from_curves(vmaf_curve, bitrate_curve, targets)


def _vmaf_map_path():
    return os.path.join(CACHE_DIR, "vmaf-map.json")


@contextlib.contextmanager
def _vmaf_map_lock():
    os.makedirs(CACHE_DIR, exist_ok=True)
    lockf = open(_vmaf_map_path() + ".lock", "w")
    try:
        if fcntl:
            try:
                fcntl.flock(lockf, fcntl.LOCK_EX)
            except OSError:
                pass
        yield
    finally:
        try:
            if fcntl:
                fcntl.flock(lockf, fcntl.LOCK_UN)
        finally:
            lockf.close()


def _load_vmaf_map():
    """The served CRF map as {scene_id: {file, hdr?, res: {reskey: {...}}}}, or {} if none/unreadable."""
    try:
        with open(_vmaf_map_path()) as fh:
            scenes = (json.load(fh) or {}).get("scenes")
        return scenes if isinstance(scenes, dict) else {}
    except (OSError, ValueError):
        return {}


def _write_vmaf_map_raw(report):
    blob = {"generated": int(time.time()), "count": len(report), "scenes": report}
    tmp = _vmaf_map_path() + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(blob, fh)
    os.replace(tmp, _vmaf_map_path())


def _file_fingerprint(scene_file):
    return "{}|{}".format(scene_file.get("size") or 0, os.path.basename(scene_file.get("path") or ""))


def _map_lookup_height(target_h, src_h):
    """The output height to look up in the VMAF map for a transcode request. For a downscale
    (target_h > 0) that's the target height itself. For an **Original** download (target_h == 0 → keep the
    source resolution — the app's default) the map has no 'orig' key: it keys every entry by a NUMERIC
    output height, and the identical source-resolution encode is stored under the source-height key. So
    resolve Original to the (even) source height — matching how run_vmaf_map keyed it from file metadata —
    instead of missing 'orig' and re-running the ~30s live search on data the map already holds."""
    if int(target_h or 0) > 0:
        return int(target_h)
    sh = int(src_h or 0)
    return sh - (sh % 2)


def _cached_crf(scene_id, target_h, target):
    """A precomputed (crf, vmaf) for (scene, output height, target VMAF) from the map, or None. Best-effort:
    ANY problem returns None so run_transcode simply runs the live search."""
    try:
        entry = (_load_vmaf_map().get(str(scene_id)) or {}).get("res", {}).get(_res_key(target_h))
        if not entry:
            return None
        return _crf_from_curve(entry.get("curve") or {}, float(target))
    except Exception:
        return None


def _settings_backup_path():
    return os.path.join(CACHE_DIR, "settings-backup.json")


def _sync_settings(stash, settings):
    """Self-heal the plugin settings across plugin updates. Stash WIPES plugins.settings.<id> from its
    config.yml on EVERY package update (verified on the box), but the update replaces only the
    zip-shipped files — extra dirs (cache/, bin/) survive — so cache/ is a durable home for a backup:

      * live map NON-EMPTY → refresh the backup (atomic, pid-suffixed tmp so concurrent hook processes
        can't interleave; last writer wins with identical content).
      * live map completely EMPTY + backup exists → write it back via configurePlugin (which REPLACES
        the whole map — exactly right here) and use the restored values for this run.
      * a PARTIAL map is user intent — never merged over, only backed up.

    Best-effort: any error returns `settings` unchanged. Returns the settings the run should use."""
    try:
        if settings:
            os.makedirs(CACHE_DIR, exist_ok=True)
            tmp = "{}.tmp{}".format(_settings_backup_path(), os.getpid())
            with open(tmp, "w") as fh:
                json.dump(settings, fh)
            os.replace(tmp, _settings_backup_path())
            return settings
        try:
            with open(_settings_backup_path()) as fh:
                saved = json.load(fh)
        except (OSError, ValueError):
            return settings
        if not (isinstance(saved, dict) and saved):
            return settings
        try:
            stash.call(
                "mutation($id: ID!, $input: Map!) { configurePlugin(plugin_id: $id, input: $input) }",
                {"id": PLUGIN_ID, "input": saved},
            )
            log_info("Restored {} saved settings from backup (Stash dropped them on plugin update)."
                     .format(len(saved)))
        except Exception as e:
            log_warn("Settings backup found but could not be written back to Stash ({}) — using it for "
                     "this run only.".format(e))
        return saved
    except Exception as e:
        log_debug("settings backup/restore skipped: {}".format(e))
        return settings


def _prune_missing(report, seen):
    """Drop mapped scenes that no longer exist in Stash. ONLY safe after a complete pass over the library:
    `seen` must hold EVERY scene id Stash currently has — pruning against a partial `seen` (an exception or
    a time-budget stop mid-run) would wrongly erase every mapped scene the run never reached."""
    gone = [s for s in report if s not in seen]
    for s in gone:
        del report[s]
    return gone


def run_vmaf_map(stash, settings, rebuild=False):
    """Scheduled/manual LIBRARY task: run the VMAF search per scene per configured output resolution and store
    the tiny result (chosen CRF + the sampled curve) in the served cache/vmaf-map.json. Downloads then look up
    the per-video VMAF-optimal CRF and skip the ~30s live analysis. Incremental (skips scenes already mapped
    for the wanted resolutions + known HDR sources), resumable, and honours an optional per-run time budget so
    it can chip away on a schedule. Only kilobytes stored — never the transcoded files. Zero scene writes."""
    ffmpeg = _bin("ffmpeg", settings.get("ffmpegPath"), hw=False)
    ffmpeg_hw = _bin("ffmpeg", settings.get("ffmpegPath"), hw=True)
    ffprobe = _bin("ffprobe", settings.get("ffmpegPath"), hw=False)
    ff_measure = _vmaf_ffmpeg(ffmpeg, ffmpeg_hw)
    if not ff_measure:
        log_error("VMAF map: no ffmpeg build here has libvmaf — set the software ffmpeg version to 'latest' "
                  "(BtbN bundles it; jellyfin does NOT) and run Install / Switch ffmpeg. Aborting.")
        return
    model_arg = _vmaf_model_arg(ff_measure)
    target = _target_vmaf(settings, "balanced")   # map targets the Balanced VMAF; other presets derive from the curve
    targets = {"high": _target_vmaf(settings, "high"), "balanced": target,
               "small": _target_vmaf(settings, "small")}   # per-preset target VMAF → per-preset bitrate
    try:
        samples = max(1, min(4, int(float(settings.get("vmafSamples") or VMAF_SAMPLES))))
    except (TypeError, ValueError):
        samples = VMAF_SAMPLES
    resolutions = [t.strip() for t in str(settings.get("vmafMapResolutions")
                   or DEFAULT_MAP_RESOLUTIONS).split(",") if t.strip()]
    try:
        budget_min = float(settings.get("vmafMapBudgetMin") or 0)
    except (TypeError, ValueError):
        budget_min = 0
    deadline = (time.time() + budget_min * 60) if budget_min > 0 else None

    if encoder_available(ffmpeg_hw, "hevc_nvenc"):
        engine, gpu_decode, ff_encode = "hevc_nvenc", True, ffmpeg_hw
    else:
        engine, gpu_decode, ff_encode = "libx265", False, ffmpeg

    report = {} if rebuild else _load_vmaf_map()
    work = os.path.join(CACHE_DIR, ".vmafmap-{}".format(os.getpid()))
    _rmtree(work)
    os.makedirs(work, exist_ok=True)

    total_count = 0
    for count, _ in _iter_scenes(stash, page_size=1):
        total_count = count
        break

    processed = analyzed = skipped = failed = since_ckpt = 0
    seen = set()
    stopped = False
    full_pass = False   # True ONLY when the scene loop finished without an exception (see prune below)
    try:
        for count, scenes in _iter_scenes(stash):
            total_count = count or total_count
            for scene in scenes:
                processed += 1
                if total_count:
                    log_progress(processed / float(total_count))
                sid = str(scene["id"])
                seen.add(sid)
                # ONE bad scene (corrupt file, ffprobe crash, weird metadata, a hung search…) must never
                # kill the whole library run: log it at INFO with the scene id and move on — it stays
                # unmapped and is simply retried next run.
                try:
                    files = scene.get("files") or []
                    if not files:
                        continue
                    sf = files[0]
                    src = sf.get("path")
                    if not src or not os.path.isfile(src):
                        continue
                    src_h_meta = int(_num(sf.get("height")))
                    fp = _file_fingerprint(sf)
                    e = report.get(sid)
                    if not e or e.get("file") != fp or not isinstance(e.get("res"), dict):
                        e = {"file": fp, "res": {}}   # new scene, changed file, or malformed entry → restart
                        report[sid] = e
                    if e.get("hdr") and not rebuild:
                        skipped += 1
                        continue                      # known HDR/DoVi source — VMAF's SDR model can't judge it
                    wanted = []
                    for tok in resolutions:
                        k = _res_key(_out_height(tok, src_h_meta))
                        if k not in wanted:
                            wanted.append(k)
                    todo = [k for k in wanted if rebuild or k not in e["res"]]
                    # Cheap backfill: entries mapped before bitrate capture (have a curve but no bitrates) get
                    # their bitrates filled by encode-only samples — no re-run of the expensive VMAF search.
                    backfill = [] if rebuild else [k for k in wanted if k in e["res"]
                                and e["res"][k].get("curve") and "bitrates" not in e["res"][k]]
                    if not todo and not backfill:
                        skipped += 1
                        continue
                    if deadline and time.time() > deadline:
                        stopped = True
                        break
                    probe = ffprobe_streams(src, ffprobe)
                    if not probe:
                        continue
                    sv = next((s for s in probe.get("streams", []) if s.get("codec_type") == "video"), {})
                    if _source_is_hdr(sv):
                        e["hdr"] = True               # remember so we don't re-probe it every run
                        continue
                    src_w = int(sv.get("width") or 0)
                    src_h = int(sv.get("height") or src_h_meta or 0)
                    if src_w <= 0 or src_h <= 0:
                        continue
                    duration = float((probe.get("format") or {}).get("duration") or 0)
                    cfr_fps = _clean_fps(sv)
                    for k in todo:
                        if deadline and time.time() > deadline:
                            stopped = True
                            break
                        target_h = 0 if k == "orig" else int(k)
                        curve, bcurve = {}, {}
                        try:
                            res = _vmaf_search(src, engine, gpu_decode, ff_encode, ff_measure, target_h,
                                               DEFAULT_AV1_PRESET, cfr_fps, None, duration, src_w, src_h,
                                               target, model_arg, work, lambda m: None, samples=samples,
                                               out_curve=curve, out_bitrate_curve=bcurve,
                                               deadline=time.time() + VMAF_MAP_SEARCH_TIMEOUT)
                        except Exception as ex:
                            failed += 1
                            log_info("VMAF map: scene {} @ {} failed ({}: {}) — skipped, retried next run"
                                     .format(sid, k, type(ex).__name__, ex))
                            res = None
                        if not res:
                            continue
                        crf, vmaf = res
                        entry = {"crf": crf, "vmaf": round(vmaf, 2), "target": target, "engine": engine,
                                 "curve": {str(q): v for q, v in curve.items()}, "ts": int(time.time())}
                        bitrates = _bitrates_from_curves(curve, bcurve, targets)
                        if bitrates:
                            entry["bitrates"] = bitrates   # {preset: bps} for VMAF-calibrated on-device encodes
                        e["res"][k] = entry
                        analyzed += 1
                        since_ckpt += 1
                        log_info("VMAF map: scene {} @ {} → CRF {} (~VMAF {:.1f}){}".format(
                            sid, k, crf, vmaf, " · bitrates=" + str(bitrates) if bitrates else ""))
                    for k in backfill:
                        if deadline and time.time() > deadline:
                            stopped = True
                            break
                        target_h = 0 if k == "orig" else int(k)
                        try:
                            bitrates = _backfill_bitrates(src, engine, gpu_decode, ff_encode, target_h,
                                                          cfr_fps, duration, e["res"][k], targets, work)
                        except Exception as ex:
                            log_info("VMAF map: scene {} @ {} bitrate-backfill error ({}: {})"
                                     .format(sid, k, type(ex).__name__, ex))
                            bitrates = None
                        if bitrates:
                            e["res"][k]["bitrates"] = bitrates
                            since_ckpt += 1
                            log_info("VMAF map: scene {} @ {} bitrates backfilled {}".format(sid, k, bitrates))
                except Exception as ex:
                    failed += 1
                    log_info("VMAF map: scene {} skipped after {}: {}".format(sid, type(ex).__name__, ex))
                if since_ckpt >= 10:                  # checkpoint so an interrupted long job keeps its progress
                    since_ckpt = 0
                    with _vmaf_map_lock():
                        _write_vmaf_map_raw(report)
                if stopped:
                    break
            if stopped:
                break
        full_pass = not stopped
    finally:
        _rmtree(work)
        # Prune deleted scenes ONLY after a clean COMPLETE pass. On an exception (or a time-budget stop)
        # `seen` is partial, and pruning against it would erase every mapped scene the run never reached —
        # this exact bug once gutted the persisted map on any mid-run failure.
        if full_pass and not rebuild:
            _prune_missing(report, seen)
        with _vmaf_map_lock():
            _write_vmaf_map_raw(report)
    log_info("VMAF CRF map ({}) — {} scenes seen, {} (scene,res) analyzed this run, {} already done/skipped, "
             "{} failed{}. Served vmaf-map.json ({} scenes mapped). Zero scene writes.".format(
                 "rebuild" if rebuild else "incremental", processed, analyzed, skipped, failed,
                 " — hit the time budget; run again to continue" if stopped else "", len(report)))
    log_progress(1.0)


# ----------------------------------------------------------------------------
# ThumbHash placeholder map: a scheduled/manual LIBRARY task computes a compact ~25-byte ThumbHash
# (evanw/thumbhash, MIT) for every scene's cover and stores it (base64) in the served
# cache/thumbhashes.json. The app fetches this once and shows an INSTANT blurry placeholder for a scene
# it has never opened — so a fast flick never flashes blank cards before the real thumbnail loads.
# Kilobytes for the whole library; zero scene writes; incremental + resumable like the VMAF/codec maps.
#
# The encoder is a pure-stdlib port of ios/Stashy/Services/ThumbHash.swift (rgbaToThumbHash) — same byte
# format, so the app's Swift decoder renders these hashes. Validated by round-trip in tests/.
# ----------------------------------------------------------------------------
THUMBHASH_EDGE = 100   # long-edge cap fed to the encoder (encoding above 100px is slow with no benefit)


def _th_round(x):
    # Ports thumbhash's round() (round-half-AWAY-from-zero). Every call-site arg below is >= 0, so
    # floor(x + 0.5) matches it exactly. Python's built-in round() is banker's rounding — do NOT use it.
    return int(math.floor(x + 0.5))


def rgba_to_thumbhash(w, h, rgba):
    """Pure-stdlib port of evanw/thumbhash rgbaToThumbHash (MIT). Returns the ~25-byte hash as bytes.
    `rgba` is w*h*4 bytes, RGBA8 straight-alpha. Byte-format-identical to ThumbHash.swift."""
    assert w <= 100 and h <= 100
    assert len(rgba) == w * h * 4
    n = w * h

    # Average color (alpha-weighted).
    avg_r = avg_g = avg_b = avg_a = 0.0
    for i in range(n):
        j = i * 4
        alpha = rgba[j + 3] / 255.0
        avg_r += alpha / 255.0 * rgba[j + 0]
        avg_g += alpha / 255.0 * rgba[j + 1]
        avg_b += alpha / 255.0 * rgba[j + 2]
        avg_a += alpha
    if avg_a > 0:
        avg_r /= avg_a
        avg_g /= avg_a
        avg_b /= avg_a

    has_alpha = avg_a < float(w * h)
    l_limit = 5 if has_alpha else 7
    max_wh = max(w, h)
    lx = max(1, _th_round(float(l_limit * w) / float(max_wh)))
    ly = max(1, _th_round(float(l_limit * h) / float(max_wh)))

    # RGBA -> LPQA (composited atop the average color), de-interleaved into 4 flat channels.
    ch_l = [0.0] * n
    ch_p = [0.0] * n
    ch_q = [0.0] * n
    ch_a = [0.0] * n
    for i in range(n):
        j = i * 4
        alpha = rgba[j + 3] / 255.0
        r = avg_r * (1 - alpha) + alpha / 255.0 * rgba[j + 0]
        g = avg_g * (1 - alpha) + alpha / 255.0 * rgba[j + 1]
        b = avg_b * (1 - alpha) + alpha / 255.0 * rgba[j + 2]
        ch_l[i] = (r + g + b) / 3.0
        ch_p[i] = (r + g) / 2.0 - b
        ch_q[i] = r - g
        ch_a[i] = alpha

    def encode_channel(channel, nx, ny):
        dc = 0.0
        ac = []
        scale = 0.0
        # Cosine bases — identical values to the reference's inline cos, computed once (no numeric change).
        cos_x = [[math.cos(math.pi / w * cx * (x + 0.5)) for x in range(w)] for cx in range(nx)]
        cos_y = [[math.cos(math.pi / h * cy * (y + 0.5)) for y in range(h)] for cy in range(ny)]
        cy = 0
        while cy < ny:
            cx = 0
            while cx * ny < nx * (ny - cy):
                f = 0.0
                cxr = cos_x[cx]
                cyr = cos_y[cy]
                y = 0
                while y < h:
                    fyv = cyr[y]
                    row = y * w
                    x = 0
                    while x < w:
                        f += channel[row + x] * cxr[x] * fyv
                        x += 1
                    y += 1
                f /= float(w * h)
                if cx > 0 or cy > 0:
                    ac.append(f)
                    scale = max(scale, abs(f))
                else:
                    dc = f
                cx += 1
            cy += 1
        if scale > 0:
            for i in range(len(ac)):
                ac[i] = 0.5 + 0.5 / scale * ac[i]
        return dc, ac, scale

    l_dc, l_ac, l_scale = encode_channel(ch_l, max(3, lx), max(3, ly))
    p_dc, p_ac, p_scale = encode_channel(ch_p, 3, 3)
    q_dc, q_ac, q_scale = encode_channel(ch_q, 3, 3)
    if has_alpha:
        a_dc, a_ac, a_scale = encode_channel(ch_a, 5, 5)
    else:
        a_dc, a_ac, a_scale = 1.0, [], 1.0

    # Write the constants (masks are belt-and-braces; the maths already keeps each field in range).
    is_landscape = w > h
    il_dc = _th_round(63.0 * l_dc) & 63
    ip_dc = _th_round(31.5 + 31.5 * p_dc) & 63
    iq_dc = _th_round(31.5 + 31.5 * q_dc) & 63
    il_scale = _th_round(31.0 * l_scale) & 31
    ihas_alpha = 1 if has_alpha else 0
    header24 = il_dc | (ip_dc << 6) | (iq_dc << 12) | (il_scale << 18) | (ihas_alpha << 23)
    ip_scale = _th_round(63.0 * p_scale) & 63
    iq_scale = _th_round(63.0 * q_scale) & 63
    ilxy = (ly if is_landscape else lx) & 7
    iis_landscape = 1 if is_landscape else 0
    header16 = ilxy | (ip_scale << 3) | (iq_scale << 9) | (iis_landscape << 15)

    out = bytearray()
    out.append(header24 & 255)
    out.append((header24 >> 8) & 255)
    out.append((header24 >> 16) & 255)
    out.append(header16 & 255)
    out.append((header16 >> 8) & 255)
    is_odd = [False]
    if has_alpha:
        ia_dc = _th_round(15.0 * a_dc) & 15
        ia_scale = _th_round(15.0 * a_scale) & 15
        out.append(ia_dc | (ia_scale << 4))

    def emit_ac(ac):
        for fv in ac:
            i15 = _th_round(15.0 * fv)
            if i15 < 0:
                i15 = 0
            elif i15 > 15:
                i15 = 15
            if is_odd[0]:
                out[-1] |= i15 << 4
            else:
                out.append(i15)
            is_odd[0] = not is_odd[0]

    emit_ac(l_ac)
    emit_ac(p_ac)
    emit_ac(q_ac)
    if has_alpha:
        emit_ac(a_ac)
    return bytes(out)


def _ppm_to_rgba(data):
    """Parse a binary PPM (P6) -> (w, h, rgba bytes) with alpha forced to 255. Robust to the whitespace/
    comment variations in the netpbm header. Returns None if malformed / truncated."""
    if data[:2] != b"P6":
        return None
    idx = 2
    vals = []
    while len(vals) < 3 and idx < len(data):
        while idx < len(data) and data[idx:idx + 1].isspace():
            idx += 1
        if idx < len(data) and data[idx:idx + 1] == b"#":       # comment to end of line
            while idx < len(data) and data[idx:idx + 1] not in (b"\n", b"\r"):
                idx += 1
            continue
        start = idx
        while idx < len(data) and not data[idx:idx + 1].isspace():
            idx += 1
        try:
            vals.append(int(data[start:idx]))
        except ValueError:
            return None
    if len(vals) < 3:
        return None
    w, h, maxval = vals
    idx += 1   # exactly one whitespace byte separates the header from the binary pixel data
    if w <= 0 or h <= 0 or maxval != 255:
        return None
    rgb = data[idx:idx + w * h * 3]
    if len(rgb) < w * h * 3:
        return None
    rgba = bytearray(w * h * 4)
    rgba[0::4] = rgb[0::3]
    rgba[1::4] = rgb[1::3]
    rgba[2::4] = rgb[2::3]
    rgba[3::4] = b"\xff" * (w * h)
    return w, h, rgba


def _cover_rgba(url, ffmpeg):
    """Fetch a scene cover over HTTP and decode+downscale it to (w, h, rgba) with the long edge
    <= THUMBHASH_EDGE, preserving aspect. One ffmpeg call emits a PPM whose ASCII header carries the scaled
    dimensions and whose body is RGB (widened to opaque RGBA). Returns None on any failure."""
    # Fit inside THUMBHASH_EDGE x THUMBHASH_EDGE preserving aspect (both output dims end up <= the cap, which
    # is all the encoder requires). A plain `scale=w=N:h=N:...` — no quotes / no `min(,)` comma to escape (a
    # quoted expression passed via argv, no shell, makes ffmpeg see literal quotes; same reason as line ~910).
    scale = "scale=w={e}:h={e}:force_original_aspect_ratio=decrease".format(e=THUMBHASH_EDGE)
    # -pix_fmt rgb24 forces 8-bit output so the PPM is always maxval 255 (a 10-bit source would otherwise
    # emit a 16-bit P6 that _ppm_to_rgba rejects); covers are JPEG/8-bit anyway, this is just insurance.
    cmd = [ffmpeg, "-v", "error", "-nostdin", "-i", url, "-vf", scale, "-pix_fmt", "rgb24",
           "-frames:v", "1", "-f", "image2pipe", "-c:v", "ppm", "-"]
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0 or not proc.stdout:
        return None
    return _ppm_to_rgba(proc.stdout)


def _cover_fetch_url(stash, screenshot):
    """Build a reachable, authenticated cover URL: keep the path + query Stash gave us but force the netloc
    to the plugin's OWN Stash base (from server_connection) so it resolves from inside the host, and
    (re)apply the api key — mirrors how the app fetches the same image. Returns None if no path."""
    if not screenshot:
        return None
    base = urllib.parse.urlsplit(stash.url)                 # scheme://host:port/graphql
    parts = urllib.parse.urlsplit(screenshot)
    if not parts.path:
        return None
    q = [(k, v) for (k, v) in urllib.parse.parse_qsl(parts.query) if k.lower() != "apikey"]
    key = stash.headers.get("ApiKey")
    if key:
        q.append(("apikey", key))
    return urllib.parse.urlunsplit((base.scheme, base.netloc, parts.path, urllib.parse.urlencode(q), ""))


THUMBHASH_SCENE_FIELDS = "id paths { screenshot }"


def _iter_scene_covers(stash, page_size=100):
    page = 1
    while True:
        data = stash.call(
            "query($f: FindFilterType!) { findScenes(filter: $f) { count scenes { %s } } }" % THUMBHASH_SCENE_FIELDS,
            {"f": {"per_page": page_size, "page": page, "sort": "id", "direction": "ASC"}},
        )
        block = data.get("findScenes") or {}
        scenes = block.get("scenes") or []
        if not scenes:
            break
        yield block.get("count", 0), scenes
        if len(scenes) < page_size:
            break
        page += 1


def _thumbhash_path():
    return os.path.join(CACHE_DIR, "thumbhashes.json")


@contextlib.contextmanager
def _thumbhash_lock():
    os.makedirs(CACHE_DIR, exist_ok=True)
    lockf = open(_thumbhash_path() + ".lock", "w")
    try:
        if fcntl:
            try:
                fcntl.flock(lockf, fcntl.LOCK_EX)
            except OSError:
                pass
        yield
    finally:
        try:
            if fcntl:
                fcntl.flock(lockf, fcntl.LOCK_UN)
        finally:
            lockf.close()


def _load_thumbhash():
    """The served map as {scene_id: base64_hash}, or {} if none/unreadable."""
    try:
        with open(_thumbhash_path()) as fh:
            scenes = (json.load(fh) or {}).get("scenes")
        return scenes if isinstance(scenes, dict) else {}
    except (OSError, ValueError):
        return {}


def _write_thumbhash_raw(report):
    blob = {"generated": int(time.time()), "count": len(report), "scenes": report}
    tmp = _thumbhash_path() + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(blob, fh)
    os.replace(tmp, _thumbhash_path())


def run_thumbhash_map(stash, settings, rebuild=False):
    """Scheduled/manual LIBRARY task: compute a ThumbHash placeholder for every scene's cover and store it
    (base64) in the served cache/thumbhashes.json. The app fetches this once and shows an instant blurry
    placeholder for scenes it has never opened. Incremental (skips scenes already hashed), resumable, and
    honours an optional per-run time budget. Kilobytes total; zero scene writes."""
    ffmpeg = _bin("ffmpeg", settings.get("ffmpegPath"), hw=False)
    try:
        budget_min = float(settings.get("thumbhashBudgetMin") or 0)
    except (TypeError, ValueError):
        budget_min = 0
    deadline = (time.time() + budget_min * 60) if budget_min > 0 else None

    report = _load_thumbhash()   # always load: a budget-stopped run keeps prior entries for unreached scenes
    processed = hashed = skipped = failed = since_ckpt = 0
    seen = set()
    stopped = False
    full_pass = False   # True ONLY when the scene loop finished without a break — see the prune guard below
    try:
        for count, scenes in _iter_scene_covers(stash):
            total = count or 0
            for scene in scenes:
                processed += 1
                if total:
                    log_progress(processed / float(total))
                sid = str(scene["id"])
                seen.add(sid)
                if sid in report and not rebuild:
                    skipped += 1
                    continue
                if deadline and time.time() > deadline:
                    stopped = True
                    break
                # One bad cover (missing screenshot, ffmpeg failure, weird image) must never kill the whole
                # library run: count it and move on — it stays unhashed and is retried next run.
                try:
                    url = _cover_fetch_url(stash, (scene.get("paths") or {}).get("screenshot"))
                    if not url:
                        continue
                    decoded = _cover_rgba(url, ffmpeg)
                    if not decoded:
                        failed += 1
                        continue
                    cw, ch, rgba = decoded
                    hsh = rgba_to_thumbhash(cw, ch, rgba)
                    report[sid] = base64.b64encode(hsh).decode("ascii")
                    hashed += 1
                    since_ckpt += 1
                except Exception as ex:
                    failed += 1
                    log_info("ThumbHash: scene {} skipped after {}: {}".format(sid, type(ex).__name__, ex))
                if since_ckpt >= 50:                  # checkpoint so an interrupted run keeps its progress
                    since_ckpt = 0
                    with _thumbhash_lock():
                        _write_thumbhash_raw(report)
            if stopped:
                break
        full_pass = not stopped
    finally:
        # Prune deleted scenes ONLY after a clean COMPLETE pass. On a break (time budget) `seen` is partial,
        # and pruning against it would erase every hash the run never reached (the VMAF-map data-loss bug).
        if full_pass:
            for sid in [s for s in report if s not in seen]:
                del report[sid]
        with _thumbhash_lock():
            _write_thumbhash_raw(report)
    log_info("ThumbHash map ({}) — {} scenes seen, {} newly hashed, {} already done, {} failed{}. "
             "Served thumbhashes.json ({} scenes). Zero scene writes.".format(
                 "rebuild" if rebuild else "incremental", processed, hashed, skipped, failed,
                 " — hit the time budget; run again to continue" if stopped else "", len(report)))
    log_progress(1.0)


# ----------------------------------------------------------------------------
# Loudness map: measure each scene's integrated loudness (EBU R128, via ffmpeg loudnorm's analysis pass)
# once and store it in served cache/loudness.json. The app folds a per-scene gain into playback volume so
# scene-to-scene loudness is consistent — no re-encode, nothing baked into the file. Audio-only decode
# (fast); incremental + resumable; zero scene writes.
# ----------------------------------------------------------------------------
def _loudness_path():
    return os.path.join(CACHE_DIR, "loudness.json")


@contextlib.contextmanager
def _loudness_lock():
    os.makedirs(CACHE_DIR, exist_ok=True)
    lockf = open(_loudness_path() + ".lock", "w")
    try:
        if fcntl:
            try:
                fcntl.flock(lockf, fcntl.LOCK_EX)
            except OSError:
                pass
        yield
    finally:
        try:
            if fcntl:
                fcntl.flock(lockf, fcntl.LOCK_UN)
        finally:
            lockf.close()


def _load_loudness():
    try:
        with open(_loudness_path()) as fh:
            scenes = (json.load(fh) or {}).get("scenes")
        return scenes if isinstance(scenes, dict) else {}
    except (OSError, ValueError):
        return {}


def _write_loudness_raw(report):
    blob = {"generated": int(time.time()), "count": len(report), "scenes": report}
    tmp = _loudness_path() + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(blob, fh)
    os.replace(tmp, _loudness_path())


def _parse_loudnorm(err):
    """Extract (integrated_LUFS, true_peak_dBTP) from ffmpeg loudnorm's JSON summary (printed on stderr), or
    None. The JSON is the LAST {...} block in the output."""
    start = err.rfind("{")
    end = err.rfind("}")
    if start < 0 or end <= start:
        return None
    try:
        data = json.loads(err[start:end + 1])
        i = float(data.get("input_i"))
        tp = float(data.get("input_tp"))
    except (ValueError, TypeError):
        return None
    if i != i or i <= -70:   # NaN, or silent / no real audio
        return None
    return i, tp


def _measure_loudness(src, ffmpeg):
    """Integrated loudness + true peak via ffmpeg loudnorm's JSON analysis pass, audio-only (`-vn` → no video
    decode, fast). Returns (i, tp) or None."""
    cmd = [ffmpeg, "-nostdin", "-hide_banner", "-i", src, "-vn",
           "-af", "loudnorm=print_format=json", "-f", "null", "-"]
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=1800)
    except (OSError, subprocess.SubprocessError):
        return None
    return _parse_loudnorm(proc.stderr.decode("utf-8", "replace"))


def run_loudness(stash, settings, rebuild=False):
    """LIBRARY task: measure each scene's integrated loudness once → served cache/loudness.json, so the app can
    keep loudness consistent scene-to-scene. Incremental (skips scenes already measured), resumable, zero
    scene writes."""
    ffmpeg = _bin("ffmpeg", settings.get("ffmpegPath"), hw=False)
    report = _load_loudness()
    processed = measured = skipped = failed = since_ckpt = 0
    seen = set()
    full_pass = False   # prune deleted scenes only after a clean complete pass (partial `seen` would gut it)
    try:
        for count, scenes in _iter_scenes(stash):
            total = count or 0
            for scene in scenes:
                processed += 1
                if total:
                    log_progress(processed / float(total))
                sid = str(scene["id"])
                seen.add(sid)
                if sid in report and not rebuild:
                    skipped += 1
                    continue
                try:
                    files = scene.get("files") or []
                    src = files[0].get("path") if files else None
                    if not src or not os.path.isfile(src):
                        continue
                    res = _measure_loudness(src, ffmpeg)
                    if not res:
                        failed += 1
                        continue
                    i, tp = res
                    report[sid] = {"i": round(i, 2), "tp": round(tp, 2)}
                    measured += 1
                    since_ckpt += 1
                except Exception as ex:
                    failed += 1
                    log_info("Loudness: scene {} skipped after {}: {}".format(sid, type(ex).__name__, ex))
                if since_ckpt >= 25:
                    since_ckpt = 0
                    with _loudness_lock():
                        _write_loudness_raw(report)
        full_pass = True
    finally:
        if full_pass:
            for sid in [s for s in report if s not in seen]:
                del report[sid]
        with _loudness_lock():
            _write_loudness_raw(report)
    log_info("Loudness map ({}) — {} scenes seen, {} newly measured, {} already done, {} failed. Served "
             "loudness.json ({} scenes). Zero scene writes.".format(
                 "rebuild" if rebuild else "incremental", processed, measured, skipped, failed, len(report)))
    log_progress(1.0)


def _scene_cover(stash, scene_id):
    """Fetch just one scene's cover URL field (a lighter query than SCENE_FIELDS — no files/ffprobe data)."""
    data = stash.call("query($id: ID!) { findScene(id: $id) { id paths { screenshot } } }",
                      {"id": str(scene_id)})
    return data.get("findScene")


def _thumbhash_scene_append(stash, settings, scene_id):
    """Compute a ThumbHash for ONE scene's cover and merge it into the served map (under the lock). The
    Scene.Create.Post hook calls this so a newly-scanned scene gets an instant blur placeholder without a
    manual task run. Zero scene writes. Best-effort: a cover that won't fetch/decode is simply skipped."""
    scene = _scene_cover(stash, scene_id)
    url = _cover_fetch_url(stash, ((scene or {}).get("paths") or {}).get("screenshot"))
    if not url:
        return
    ffmpeg = _bin("ffmpeg", settings.get("ffmpegPath"), hw=False)
    decoded = _cover_rgba(url, ffmpeg)
    if not decoded:
        return
    cw, ch, rgba = decoded
    b64 = base64.b64encode(rgba_to_thumbhash(cw, ch, rgba)).decode("ascii")
    with _thumbhash_lock():
        data = _load_thumbhash()
        data[str(scene_id)] = b64
        _write_thumbhash_raw(data)
    log_info("ThumbHash: auto-hashed new scene {} (served file, no scene writes).".format(scene_id))


def _thumbhash_scene_remove(scene_id):
    with _thumbhash_lock():
        data = _load_thumbhash()
        if str(scene_id) in data:
            del data[str(scene_id)]
            _write_thumbhash_raw(data)


def _hook_enabled(settings, key):
    return str(settings.get(key, True)).strip().lower() not in ("false", "0", "no", "off")


def run_hook(stash, settings, hook_ctx):
    """Dispatch a Stash plugin hook. Scene.Create.Post appends the new scene to the served maps; Scene.
    Destroy.Post drops it. The playability report and the ThumbHash map are maintained INDEPENDENTLY, each
    gated by its own setting ('autoReportNewScenes' / 'autoThumbhashNewScenes'). Both write only served
    files — zero scene writes, so no Scene.Update hooks / Sync-task storms even on a big scan."""
    typ = str(hook_ctx.get("type") or "")
    sid = hook_ctx.get("id")
    if sid is None:
        return
    sid = str(sid)
    report_on = _hook_enabled(settings, "autoReportNewScenes")
    thumb_on = _hook_enabled(settings, "autoThumbhashNewScenes")
    if typ.startswith("Scene.Create"):
        if report_on:
            _report_scene_append(stash, settings, sid)
        if thumb_on:
            _thumbhash_scene_append(stash, settings, sid)
    elif typ.startswith("Scene.Destroy"):
        if report_on:
            _report_scene_remove(sid)
        if thumb_on:
            _thumbhash_scene_remove(sid)


# Legacy Stashy:* tag names created by v0.1.16/0.1.17 (before playability moved to a served file). Kept
# ONLY so the cleanup task below can find and remove them — the plugin no longer creates or writes tags.
TAG_NAMES = {
    "direct_play": "Stashy:Direct-Play",
    "needs_transcode": "Stashy:Needs-Transcode",
    "hdr": "Stashy:HDR",
    "ten_bit": "Stashy:10-bit",
    "hevc": "Stashy:HEVC",
    "av1": "Stashy:AV1",
}


def run_untag(stash):
    """Delete the Stashy:* tag DEFINITIONS that older plugin versions (≤0.1.17) created. Destroying a tag
    makes Stash remove it from every scene via its own cascade — with **no per-scene sceneUpdate**, so this
    fires no Scene.Update hooks and queues no "Sync" tasks (6 tagDestroy calls total, not hundreds of scene
    writes). The user's own tags are untouched.

    NOTE: a residual `stashy_probe` custom field (if a ≤0.1.17 Library Codec Report wrote one) is left in
    place on purpose — it's harmless dead data nothing reads, and clearing a custom field is per-scene
    sceneUpdate = exactly the Sync-task storm we're avoiding. On a clean/current library this does nothing."""
    destroyed = 0
    for name in TAG_NAMES.values():
        data = stash.call(
            "query($t: TagFilterType) { findTags(tag_filter: $t) { tags { id } } }",
            {"t": {"name": {"value": name, "modifier": "EQUALS"}}},
        )
        for t in ((data.get("findTags") or {}).get("tags") or []):
            try:
                # tagDestroy → cascade-removes the tag from all scenes; no Scene.Update hook fires.
                stash.call("mutation($id: ID!) { tagDestroy(input: {id: $id}) }", {"id": str(t["id"])})
                destroyed += 1
            except Exception as e:
                log_debug("tag destroy failed for {}: {}".format(t["id"], e))
    log_info("Removed {} Stashy:* tag definition(s) via cascade — no scene writes, no Sync tasks. "
             "(Any residual stashy_probe custom field is harmless and left in place.)".format(destroyed))
    log_progress(1.0)


# ----------------------------------------------------------------------------
# Entry point.
# ----------------------------------------------------------------------------
def load_settings(conn):
    """Plugin settings arrive on server_connection or must be fetched. Fetch the
    saved values via GraphQL configuration so free-typed dirs/toggles apply."""
    return {}


def main():
    try:
        raw = sys.stdin.read()
        payload = json.loads(raw) if raw.strip() else {}
    except ValueError:
        log_error("could not parse stdin JSON")
        sys.exit(1)

    conn = payload.get("server_connection") or {}
    args = payload.get("args") or {}
    stash = Stash(conn)
    # Long tasks (VMAF map, a first full codec report, big AV1 transcodes) outlive Stash's session
    # cookie — switch to the API key NOW, while the cookie still works (fixes mid-run GraphQL-401 deaths).
    stash.adopt_api_key()

    # Pull saved plugin settings (typed config the user set in the Stash UI).
    settings = {}
    settings_read_ok = False
    try:
        data = stash.call("query { configuration { plugins } }")
        settings = ((data.get("configuration") or {}).get("plugins") or {}).get(PLUGIN_ID) or {}
        settings_read_ok = True
    except Exception as e:
        log_debug("could not read plugin settings: {}".format(e))
    if settings_read_ok:
        # Stash wipes plugin settings on every package update — back them up / restore from cache/
        # (which updates preserve). Only acts on a GENUINE read: a failed read must not trigger a restore.
        settings = _sync_settings(stash, settings)

    mode = (args.get("mode") or "transcode").lower()
    log_debug("mode={} args={}".format(mode, {k: v for k, v in args.items() if k != "mode"}))

    # A Stash plugin hook invocation carries a `hookContext` (Scene.Create.Post etc.) and usually no mode.
    # Handle it first so it isn't mistaken for the default "transcode" mode.
    hook_ctx = args.get("hookContext")

    try:
        if hook_ctx:
            run_hook(stash, settings, hook_ctx)
        elif mode == "transcode":
            run_transcode(stash, args, settings)
        elif mode == "stats":
            run_stats(stash, settings, rebuild=bool(args.get("rebuild")))
        elif mode == "vmafmap":
            run_vmaf_map(stash, settings, rebuild=bool(args.get("rebuild")))
        elif mode == "thumbhash":
            run_thumbhash_map(stash, settings, rebuild=bool(args.get("rebuild")))
        elif mode == "loudness":
            run_loudness(stash, settings, rebuild=bool(args.get("rebuild")))
        elif mode == "tag":
            # Legacy task id (≤0.1.17 tagged scenes). Now a no-tag alias for the report — it writes the
            # served playability.json and makes zero scene writes, so an old invocation can't storm hooks.
            run_stats(stash, settings)
        elif mode == "untag":
            run_untag(stash)
        elif mode == "purge":
            run_purge(settings)
        elif mode == "delete":
            run_delete(args)
        elif mode == "update_ffmpeg":
            run_update_ffmpeg(settings)
        elif mode == "selftest":
            run_selftest(stash, settings)
        else:
            raise RuntimeError("unknown mode: {}".format(mode))
    except Exception as e:
        log_error(str(e))
        sys.exit(1)


if __name__ == "__main__":
    main()
