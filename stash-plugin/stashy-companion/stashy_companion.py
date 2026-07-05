#!/usr/bin/env python3
"""Stashy Companion — a backend plugin for the Stashy iOS app.

Runs *inside* a self-hosted stashapp/stash server (interface: raw). It adds
capabilities vanilla Stash does not have, all aligned with the app's tenets
(fast playback, direct-play first, minimal server load, privacy):

  * Transcode for iPhone  — turn one scene into an iPhone-native MP4
    (HEVC via hevc_nvenc on an NVIDIA GPU, or libx265 on CPU; optional AV1 via
    SVT-AV1). Output is written into this plugin's own served `cache/` dir and
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

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

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

    def call(self, query, variables=None):
        payload = json.dumps({"query": query, "variables": variables or {}}).encode("utf-8")
        req = urllib.request.Request(self.url, data=payload, headers=self.headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                body = json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            raise RuntimeError("GraphQL HTTP {}: {}".format(e.code, e.read().decode("utf-8", "replace")))
        if body.get("errors"):
            raise RuntimeError("GraphQL errors: {}".format(json.dumps(body["errors"])))
        return body.get("data") or {}


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


def build_transcode_cmd(src, dst, codec, target_h, cq, ffmpeg, engine, gpu_decode,
                        av1_preset=DEFAULT_AV1_PRESET, cfr_fps=None, hdr=None, maxrate=0):
    """engine ∈ {"hevc_nvenc","libx265","libsvtav1"}. gpu_decode adds NVDEC. hdr ∈ {None,"pq","hlg"}.

    `target_h` is the already-resolved (downscaled, even) output height, so the `-vf` is a plain
    `scale=-2:<int>`. For the NVENC path we NVDEC-decode on the GPU (`-hwaccel cuda`) but scale/format on
    the CPU (frames land in system memory) before NVENC re-encodes.

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

    pre = [ffmpeg, "-y", "-hide_banner"]
    if engine == "hevc_nvenc" and gpu_decode:
        pre += ["-hwaccel", "cuda"]  # NVDEC decode; frames land in system mem for the CPU scale/format
    cmd = pre + ["-i", src]
    if engine == "libsvtav1":
        cmd += vf(scale_f, fmt_f) + ["-c:v", "libsvtav1", "-preset", str(av1_preset),
                                     "-crf", str(cq), "-pix_fmt", pix] + cap + color_args
    elif engine == "hevc_nvenc":
        fps_f = "fps={0}".format(cfr_fps) if cfr_fps else None
        # -bf 0: Pascal (Tesla P40) NVENC has no HEVC B-frame support; forcing 0 avoids a config reject.
        cmd += vf(fps_f, scale_f, fmt_f) + ["-c:v", "hevc_nvenc", "-preset", "p5",
                                            "-rc", "vbr", "-cq", str(cq), "-b:v", "0", "-bf", "0"] \
            + cap + main10 + ["-tag:v", "hvc1", "-pix_fmt", pix] + color_args
    else:  # libx265 — CPU HEVC, last-resort fallback only
        cmd += vf(scale_f, fmt_f) + ["-c:v", "libx265", "-preset", "medium", "-crf", str(cq)] \
            + cap + main10 + ["-tag:v", "hvc1", "-pix_fmt", pix] + color_args
    cmd += ["-c:a", "aac", "-b:a", "160k", "-ac", "2",
            "-movflags", "+faststart",
            # Force the MP4 muxer: the output is written to a `.part` temp name, and ffmpeg can't infer
            # a format from that extension ("Error opening output files: Invalid argument"). -f mp4 makes
            # the container explicit regardless of the temp filename.
            "-f", "mp4",
            "-progress", "pipe:1", "-nostats", dst]
    return cmd


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

    # Live rich stats (size/ETA/fps/speed) go to a SERVED FILE the app polls over HTTP — NOT to
    # custom_fields — so a running transcode never fires sceneUpdate/Scene.Update hooks (which were
    # queuing "sync" tasks). custom_fields is written exactly TWICE per transcode: the early "running"
    # marker above, and the terminal result at the end.
    status_state = {"last": 0.0, "label": attempts[0][0]}

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
        _write_progress_file(scene_id, {
            "status": "running", "stage": "encoding", "codec": codec, "resolution": res_label,
            "engine": status_state["label"], "progress": round(pct, 4),
            "out_time": round(secs, 1), "duration": round(duration, 1),
            "speed": round(speed, 2), "fps": round(fps, 1),
            "size": cur_size, "size_estimate": size_est, "eta": eta,
        })

    rc = -1
    eng = attempts[0][0]
    for idx, (engine, gpu_decode) in enumerate(attempts):
        eng = engine
        label = "{}{}".format(engine, " +NVDEC" if gpu_decode else "")
        status_state["label"] = label
        status_state["last"] = 0.0   # let the first block of a new attempt publish immediately
        log_info("Transcoding scene {} → {} {}p (cq {}, {})".format(scene_id, codec, res_label, cq, label))
        _write_progress_file(scene_id, {"status": "running", "stage": "starting",
                                        "codec": codec, "resolution": res_label, "engine": label})
        ff = ffmpeg_hw if engine == "hevc_nvenc" else ffmpeg   # NVENC → driver-safe build; SW → main
        cmd = build_transcode_cmd(src, tmp, codec, target_h, cq, ff, engine, gpu_decode,
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
            os.remove(p)
            removed += 1
        except OSError:
            pass
    log_info("cache purged ({} files)".format(removed))


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


def run_stats(stash, settings):
    """ffprobe every scene and write the whole library's playability to ONE served file
    (cache/playability.json) that the app reads over HTTP. Makes **zero** sceneUpdate calls — so it fires
    no Scene.Update hooks and queues no "Sync" tasks, no matter how large the library. (The previous
    version wrote each scene's custom_fields / tags, which on a fresh library meant hundreds of
    sceneUpdates → hundreds of hooked Sync tasks. Never write per-scene for a bulk operation.)"""
    ffprobe = _bin("ffprobe", settings.get("ffmpegPath"))
    agg = {"total": 0, "direct": 0, "remux": 0, "transcode": 0, "hdr": 0, "ten_bit": 0, "codecs": {}}
    report = {}

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
            files = scene.get("files") or []
            if not files:
                continue
            probe = ffprobe_streams(files[0]["path"], ffprobe)
            if not probe:
                continue
            info = _analyze(probe)
            agg["total"] += 1
            agg["codecs"][info["codec"]] = agg["codecs"].get(info["codec"], 0) + 1
            agg[info["tier"]] = agg.get(info["tier"], 0) + 1
            if info["hdr"]:
                agg["hdr"] += 1
            if info["ten_bit"]:
                agg["ten_bit"] += 1
            report[str(scene["id"])] = {
                "tier": info["tier"],
                "needs_transcode": info["needs_transcode"],
                "direct_play": info["direct_play"],
                "hdr": info["hdr"],
                "ten_bit": info["ten_bit"],
                "codec": info["codec"],
                "pix_fmt": info["pix_fmt"],
            }

    _write_playability_file(report)
    log_info("Library codec report — {} scenes: {} direct-play, {} on-device remux, {} need transcode, "
             "{} HDR, {} 10-bit. Codecs: {}. Wrote served playability.json (no scene writes / no Sync tasks)."
             .format(agg["total"], agg["direct"], agg["remux"], agg["transcode"], agg["hdr"], agg["ten_bit"],
                     ", ".join("{} {}".format(k or "?", v) for k, v in sorted(agg["codecs"].items()))))
    log_progress(1.0)
    return agg


def _playability_path():
    return os.path.join(CACHE_DIR, "playability.json")


def _write_playability_file(report):
    """Whole-library playability map → a served file the app reads over HTTP. Filesystem-only: no
    sceneUpdate, no Scene.Update hooks, no queued Sync tasks. Atomic."""
    os.makedirs(CACHE_DIR, exist_ok=True)
    blob = {"generated": int(time.time()), "count": len(report), "scenes": report}
    tmp = _playability_path() + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(blob, fh)
    os.replace(tmp, _playability_path())


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
    """Reverse the per-scene writes older plugin versions (≤0.1.17) made: strip every Stashy:* tag from
    every scene, clear the `stashy_probe` custom field, then delete the now-unused Stashy:* tag definitions
    — leaving the user's own tags and custom fields untouched. The current plugin writes NONE of these
    (playability lives in a served file now), so this is purely a one-time cleanup for earlier installs.
    Only scenes that actually carry Stashy data are updated, so on a clean library it makes no writes."""
    tag_ids = {}
    for key, name in TAG_NAMES.items():   # resolve only tags that already exist — don't create to delete
        data = stash.call(
            "query($t: TagFilterType) { findTags(tag_filter: $t) { tags { id } } }",
            {"t": {"name": {"value": name, "modifier": "EQUALS"}}},
        )
        tags = (data.get("findTags") or {}).get("tags") or []
        if tags:
            tag_ids[key] = str(tags[0]["id"])
    ours = set(tag_ids.values())

    removed, cleared, total_count, processed = 0, 0, 0, 0
    for count, _ in _iter_scenes(stash, page_size=1):
        total_count = count
        break
    for count, scenes in _iter_scenes(stash):
        total_count = count or total_count
        for scene in scenes:
            processed += 1
            if total_count:
                log_progress(processed / float(total_count))
            existing = {str(t["id"]) for t in (scene.get("tags") or [])}
            keep = existing - ours
            if ours and keep != existing:
                stash.call(
                    "mutation($id: ID!, $ids: [ID!]) { sceneUpdate(input: {id: $id, tag_ids: $ids}) { id } }",
                    {"id": str(scene["id"]), "ids": sorted(keep)},
                )
                removed += 1
            if "stashy_probe" in (scene.get("custom_fields") or {}):
                try:  # partial update with a null value clears just this key (never the user's fields)
                    stash.call(
                        "mutation($id: ID!, $cf: CustomFieldsInput!) {"
                        " sceneUpdate(input: {id: $id, custom_fields: $cf}) { id } }",
                        {"id": str(scene["id"]), "cf": {"partial": {"stashy_probe": None}}},
                    )
                    cleared += 1
                except Exception as e:
                    log_debug("probe clear failed for {}: {}".format(scene["id"], e))
    for tid in ours:                      # remove the empty Stashy:* tag definitions so the tag list is clean
        try:
            stash.call("mutation($id: ID!) { tagDestroy(input: {id: $id}) }", {"id": tid})
        except Exception as e:
            log_debug("tag destroy failed for {}: {}".format(tid, e))
    log_info("Removed Stashy tags from {} scenes, cleared probe on {} scenes, deleted {} tag definitions."
             .format(removed, cleared, len(ours)))
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

    # Pull saved plugin settings (typed config the user set in the Stash UI).
    settings = {}
    try:
        data = stash.call("query { configuration { plugins } }")
        settings = ((data.get("configuration") or {}).get("plugins") or {}).get(PLUGIN_ID) or {}
    except Exception as e:
        log_debug("could not read plugin settings: {}".format(e))

    mode = (args.get("mode") or "transcode").lower()
    log_debug("mode={} args={}".format(mode, {k: v for k, v in args.items() if k != "mode"}))

    try:
        if mode == "transcode":
            run_transcode(stash, args, settings)
        elif mode == "stats":
            run_stats(stash, settings)
        elif mode == "tag":
            # Legacy task id (≤0.1.17 tagged scenes). Now a no-tag alias for the report — it writes the
            # served playability.json and makes zero scene writes, so an old invocation can't storm hooks.
            run_stats(stash, settings)
        elif mode == "untag":
            run_untag(stash)
        elif mode == "purge":
            run_purge(settings)
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
