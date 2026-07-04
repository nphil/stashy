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

# BtbN static builds: modern ffmpeg with libsvtav1 (SVT-AV1 3.x) + nvenc + libx265, self-contained.
# Versions are PINNED by release tag (not the rolling `latest`) so an upstream regression can't reach the
# server until you choose to switch. Multiple versions coexist under bin/<tag>/; `bin/active` names the one
# in use. Switch via the `ffmpegVersion` setting + the Install/Switch task (re-download only if missing).
FFMPEG_ASSET = "ffmpeg-master-latest-linux64-gpl.tar.xz"
# Default to BtbN's rolling `latest` tag — it NEVER 404s (dated autobuild tags are pruned within days).
# To pin: set ffmpegVersion to a specific tag and install it while it's still published; the local copy
# under bin/<tag>/ is kept forever, so it stays available even after BtbN prunes the remote tag.
DEFAULT_FFMPEG_TAG = "latest"
ACTIVE_FILE = os.path.join(BIN_DIR, "active")      # text file: the active tag (or "system")
DEFAULT_AV1_PRESET = 8   # SVT-AV1 preset (0 slow/best … 10 fast). 8 ≈ x265 medium; 6 ≈ x265 slow.


def _ffmpeg_url(tag):
    return "https://github.com/BtbN/FFmpeg-Builds/releases/download/{}/{}".format(tag, FFMPEG_ASSET)


def _version_dir(tag):
    return os.path.join(BIN_DIR, tag)


def _active_tag():
    try:
        with open(ACTIVE_FILE) as f:
            return f.read().strip()
    except OSError:
        return ""


def _set_active(tag):
    os.makedirs(BIN_DIR, exist_ok=True)
    with open(ACTIVE_FILE, "w") as f:
        f.write(tag)

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
def _bin(name, override_dir):
    # 1) the active pinned build the plugin downloaded into bin/<tag>/ (unless set to "system").
    tag = _active_tag()
    if tag and tag not in ("system", "none", "path"):
        cand = os.path.join(_version_dir(tag), name)
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
QUALITY_CQ = {"high": 24, "medium": 28, "med": 28, "standard": 28, "low": 32}


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


def build_transcode_cmd(src, dst, codec, target_h, cq, ffmpeg, engine, gpu_decode,
                        av1_preset=DEFAULT_AV1_PRESET, cfr_fps=None):
    """engine ∈ {"hevc_nvenc","libx265","libsvtav1"}. gpu_decode adds NVDEC.

    `target_h` is the already-resolved (downscaled, even) output height, so the `-vf` is a plain
    `scale=-2:<int>` — no quotes / no `min(,)` (those only work in a shell; passed via argv they'd be
    literal characters ffmpeg rejects). For the NVENC path we NVDEC-decode on the GPU (`-hwaccel cuda`)
    but scale on the CPU (frames land in system memory) before NVENC re-encodes — both heavy codec ops
    stay on the Tesla P40 while dodging the pix_fmt fragility of the fully-on-card scale_cuda filter.
    """
    # Video filter chain. For NVENC it is: [fps=<clean CFR>], [scale], format=yuv420p.
    #  - fps: pins a valid constant frame rate so NVENC's init-time rate validation can't be handed a
    #    0/0 or absurd value from a re-muxed source (the real cause of the -22 "invalid param" open fail).
    #  - format=yuv420p: explicit 8-bit 4:2:0, so 10-bit sources don't reach the 8-bit encoder.
    # target_h <= 0 keeps the source resolution (Original — portrait-safe, no re-scale).
    scale_f = "scale=-2:{0}".format(int(target_h)) if int(target_h) > 0 else None

    def vf(*filters):
        chain = [f for f in filters if f]
        return ["-vf", ",".join(chain)] if chain else []

    pre = [ffmpeg, "-y", "-hide_banner"]
    if engine == "hevc_nvenc" and gpu_decode:
        pre += ["-hwaccel", "cuda"]  # NVDEC decode; frames land in system mem for the CPU scale/format
    cmd = pre + ["-i", src]
    if engine == "libsvtav1":
        cmd += vf(scale_f, "format=yuv420p") + ["-c:v", "libsvtav1", "-preset", str(av1_preset),
                                                "-crf", str(cq), "-pix_fmt", "yuv420p"]
    elif engine == "hevc_nvenc":
        fps_f = "fps={0}".format(cfr_fps) if cfr_fps else None
        # -bf 0: Pascal (Tesla P40) NVENC has no HEVC B-frame support; forcing 0 avoids a config reject.
        cmd += vf(fps_f, scale_f, "format=yuv420p") + ["-c:v", "hevc_nvenc", "-preset", "p5",
                                                       "-rc", "vbr", "-cq", str(cq), "-b:v", "0", "-bf", "0",
                                                       "-tag:v", "hvc1", "-pix_fmt", "yuv420p"]
    else:  # libx265 — CPU HEVC, last-resort fallback only
        cmd += vf(scale_f, "format=yuv420p") + ["-c:v", "libx265", "-preset", "medium",
                                                "-crf", str(cq), "-tag:v", "hvc1", "-pix_fmt", "yuv420p"]
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
    codec = (args.get("codec") or "hevc").lower()
    resolution_arg = str(args.get("resolution") or "1080").lower()
    is_original = resolution_arg in ("original", "orig", "source", "0")
    height = RES_HEIGHTS.get(resolution_arg, 1080)
    cq = QUALITY_CQ.get(str(args.get("quality") or "medium").lower(), 28)
    # SVT-AV1 preset (speed↔size). Configurable; higher = much faster. AV1-only.
    try:
        av1_preset = int(float(settings.get("av1Preset") or DEFAULT_AV1_PRESET))
    except (TypeError, ValueError):
        av1_preset = DEFAULT_AV1_PRESET
    av1_preset = max(0, min(10, av1_preset))

    ffmpeg = _bin("ffmpeg", settings.get("ffmpegPath"))
    ffprobe = _bin("ffprobe", settings.get("ffmpegPath"))

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
    elif encoder_available(ffmpeg, "hevc_nvenc"):
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

    # Throttled rich-status side-channel: the app reads custom_fields for live size/ETA/fps/speed while
    # the job runs (findJob only carries a bare 0..1). Written at most every ~3s → not spam.
    status_state = {"last": 0.0, "label": attempts[0][0]}

    def _on_status(prog, secs):
        now = time.time()
        # ~12s throttle (was 3s): each write is a sceneUpdate, and any Scene.Update.Post hook the user
        # has installed queues a task per write — a long transcode was flooding the job queue. The app's
        # live % still comes from Job.progress every ~2s; this side-channel only refreshes the rich stats.
        if now - status_state["last"] < 12.0:
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
        _write_status(stash, scene_id, {
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
        _record_status(stash, scene_id, "running", codec, res_label, label, 0, None)
        cmd = build_transcode_cmd(src, tmp, codec, target_h, cq, ffmpeg, engine, gpu_decode,
                                  av1_preset, cfr_fps)
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
        _record_status(stash, scene_id, "failed", codec, height, eng, 0, None)
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
    set_custom_field(stash, scene_id, CUSTOM_FIELD_KEY, json.dumps(result))
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


def run_update_ffmpeg(settings):
    import hashlib
    import tarfile

    tag = (settings.get("ffmpegVersion") or DEFAULT_FFMPEG_TAG).strip()
    if tag in ("system", "none", "path", ""):
        _set_active("system")
        log_info("ffmpeg set to SYSTEM (override dir / PATH / Stash bundled). Active pinned build cleared.")
        return

    vdir = _version_dir(tag)
    ff = os.path.join(vdir, "ffmpeg")

    # Already downloaded → just switch to it (instant, no re-download).
    if os.path.isfile(ff) and os.access(ff, os.X_OK):
        _set_active(tag)
        first, enc = _ffmpeg_summary(ff)
        log_progress(1.0)
        log_info("Switched to ffmpeg {} — {} · nvenc={} svtav1={}".format(
            tag, first, enc.get("hevc_nvenc"), enc.get("libsvtav1")))
        return

    url = (settings.get("ffmpegDownloadURL") or _ffmpeg_url(tag)).strip()
    sha_expect = (settings.get("ffmpegSha256") or "").strip().lower()
    os.makedirs(vdir, exist_ok=True)
    archive = os.path.join(vdir, "_download.tar.xz")
    log_info("Downloading ffmpeg {} from {}".format(tag, url))

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
                        log_progress(0.9 * got / total)   # reserve last 10% for extract+verify
    except (urllib.error.URLError, OSError) as e:
        _safe_unlink(archive)
        raise RuntimeError("ffmpeg download failed (tag {} may have been pruned — try 'latest' or a newer "
                           "tag): {}".format(tag, e))

    digest = hasher.hexdigest()
    if sha_expect and digest != sha_expect:
        _safe_unlink(archive)
        raise RuntimeError("sha256 mismatch: expected {} got {}".format(sha_expect, digest))
    log_info("Downloaded {} bytes (sha256 {})".format(got, digest[:16]))

    log_info("Extracting ffmpeg + ffprobe…")
    extracted = 0
    try:
        with tarfile.open(archive, "r:xz") as tar:
            for m in tar.getmembers():
                base = os.path.basename(m.name)
                if m.isfile() and base in ("ffmpeg", "ffprobe"):
                    m.name = base   # flatten into vdir (also neutralises any path traversal)
                    tar.extract(m, vdir)
                    os.chmod(os.path.join(vdir, base), 0o755)
                    extracted += 1
    except (tarfile.TarError, OSError) as e:
        raise RuntimeError("could not extract ffmpeg archive: {}".format(e))
    finally:
        _safe_unlink(archive)

    if extracted < 2:
        raise RuntimeError("archive did not contain both ffmpeg and ffprobe")

    first, enc = _ffmpeg_summary(ff)
    if not enc:
        raise RuntimeError("downloaded ffmpeg {} won't run: {}".format(tag, first))
    _set_active(tag)
    log_progress(1.0)
    log_info("ffmpeg {} installed + active — {} · nvenc={} svtav1={} x265={}".format(
        tag, first, enc.get("hevc_nvenc"), enc.get("libsvtav1"), enc.get("libx265")))


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

    ffmpeg = _bin("ffmpeg", settings.get("ffmpegPath"))
    active = _active_tag() or "(system)"
    first, enc = _ffmpeg_summary(ffmpeg)
    if enc:
        log_info("ffmpeg [{}] {}".format(active, first))
        log_info("  path {}".format(ffmpeg))
        log_info("  encoders: hevc_nvenc={} libsvtav1={} libx265={}".format(
            enc.get("hevc_nvenc"), enc.get("libsvtav1"), enc.get("libx265")))
        if not (enc.get("hevc_nvenc") or enc.get("libx265")):
            ok = False
            log_warn("  no HEVC encoder available (neither hevc_nvenc nor libx265)")
        # Isolate WHY nvenc won't open: test h264_nvenc (control — Stash uses it) vs hevc_nvenc on a
        # synthetic source. h264 OK + hevc FAIL ⇒ HEVC-encode/driver limitation on this GPU; both FAIL
        # ⇒ this ffmpeg build's nvenc is incompatible with the installed driver.
        smi = _nvidia_smi()
        if smi:
            log_info("GPU: {}".format(smi))
        if enc.get("hevc_nvenc"):
            h264_ok, h264_why = _nvenc_probe(ffmpeg, "h264_nvenc", ["-pix_fmt", "yuv420p"])
            hevc_ok, hevc_why = _nvenc_probe(ffmpeg, "hevc_nvenc", ["-pix_fmt", "yuv420p"])
            log_info("  h264_nvenc (control): {}".format("OK" if h264_ok else "FAIL — " + h264_why))
            log_info("  hevc_nvenc: {}".format("OK" if hevc_ok else "FAIL — " + hevc_why))
            if hevc_ok:
                log_info("  → GPU HEVC works")
            elif h264_ok:
                log_warn("  → h264_nvenc opens but hevc_nvenc doesn't: HEVC-encode/driver limit on this "
                         "GPU. Options: update the NVIDIA driver, or use H.264 on GPU.")
            else:
                log_warn("  → NO nvenc opens in this ffmpeg build. Its NVENC likely needs a newer driver "
                         "than installed. Try ffmpegVersion=system (Stash's own ffmpeg does H.264 nvenc), "
                         "or an older BtbN build matching your driver.")
    else:
        ok = False
        log_error("ffmpeg FAIL — {} ({})".format(first, ffmpeg))

    installed = []
    if os.path.isfile(os.path.join(BIN_DIR, "ffmpeg")):
        installed.append("bin/ffmpeg (legacy flat build)")
    if os.path.isdir(BIN_DIR):
        for n in sorted(os.listdir(BIN_DIR)):
            if os.path.isfile(os.path.join(BIN_DIR, n, "ffmpeg")):
                installed.append(n + (" *active" if n == _active_tag() else ""))
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
DIRECT_PLAY_VIDEO = {"h264", "hevc", "h265"}
DIRECT_PLAY_CONTAINER = ("mp4", "mov", "m4v", "quicktime")


def _analyze(probe):
    v = next((s for s in probe.get("streams", []) if s.get("codec_type") == "video"), {})
    fmt = (probe.get("format", {}).get("format_name") or "").lower()
    pix = (v.get("pix_fmt") or "").lower()
    transfer = (v.get("color_transfer") or "").lower()
    codec = (v.get("codec_name") or "").lower()
    ten_bit = "10" in pix or "p010" in pix or (v.get("bits_per_raw_sample") in ("10", 10))
    hdr = transfer in HDR_TRANSFERS
    direct = (codec in DIRECT_PLAY_VIDEO
              and any(c in fmt for c in DIRECT_PLAY_CONTAINER)
              and not ten_bit and not hdr)
    return {
        "codec": codec,
        "profile": v.get("profile"),
        "pix_fmt": pix,
        "color_transfer": transfer or None,
        "hdr": hdr,
        "ten_bit": bool(ten_bit),
        "direct_play": bool(direct),
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


def run_stats(stash, settings, do_tag):
    ffprobe = _bin("ffprobe", settings.get("ffmpegPath"))
    agg = {"total": 0, "direct_play": 0, "needs_transcode": 0, "hdr": 0,
           "ten_bit": 0, "codecs": {}}
    tag_ids = _ensure_tags(stash) if do_tag else {}

    # First pass count (for progress) via a cheap query.
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
            if info["direct_play"]:
                agg["direct_play"] += 1
            else:
                agg["needs_transcode"] += 1
            if info["hdr"]:
                agg["hdr"] += 1
            if info["ten_bit"]:
                agg["ten_bit"] += 1
            try:
                set_custom_field(stash, scene["id"], "stashy_probe", json.dumps(info))
            except Exception as e:
                log_debug("probe write failed for {}: {}".format(scene["id"], e))
            if do_tag:
                _tag_scene(stash, scene["id"], info, tag_ids)

    log_info("Library codec report — {} scenes: {} direct-play, {} need transcode, "
             "{} HDR, {} 10-bit. Codecs: {}".format(
                 agg["total"], agg["direct_play"], agg["needs_transcode"],
                 agg["hdr"], agg["ten_bit"],
                 ", ".join("{} {}".format(k or "?", v) for k, v in sorted(agg["codecs"].items()))))
    log_progress(1.0)
    return agg


TAG_NAMES = {
    "direct_play": "Stashy:Direct-Play",
    "needs_transcode": "Stashy:Needs-Transcode",
    "hdr": "Stashy:HDR",
    "ten_bit": "Stashy:10-bit",
    "hevc": "Stashy:HEVC",
    "av1": "Stashy:AV1",
}


def _ensure_tags(stash):
    ids = {}
    for key, name in TAG_NAMES.items():
        data = stash.call(
            "query($f: FindFilterType, $t: TagFilterType) { findTags(filter: $f, tag_filter: $t) { tags { id name } } }",
            {"f": {"per_page": 1}, "t": {"name": {"value": name, "modifier": "EQUALS"}}},
        )
        tags = (data.get("findTags") or {}).get("tags") or []
        if tags:
            ids[key] = tags[0]["id"]
        else:
            created = stash.call("mutation($n: String!) { tagCreate(input: {name: $n}) { id } }", {"n": name})
            ids[key] = created["tagCreate"]["id"]
    return ids


def _tag_scene(stash, scene_id, info, tag_ids):
    want = set()
    want.add(tag_ids["direct_play"] if info["direct_play"] else tag_ids["needs_transcode"])
    if info["hdr"]:
        want.add(tag_ids["hdr"])
    if info["ten_bit"]:
        want.add(tag_ids["ten_bit"])
    if info["codec"] in ("hevc", "h265"):
        want.add(tag_ids["hevc"])
    if info["codec"] == "av1":
        want.add(tag_ids["av1"])
    # Merge with existing tags (don't drop unrelated ones).
    data = stash.call("query($id: ID!) { findScene(id: $id) { tags { id } } }", {"id": str(scene_id)})
    existing = {t["id"] for t in ((data.get("findScene") or {}).get("tags") or [])}
    # Drop any of OUR tags the scene shouldn't have, keep everything else.
    ours = set(tag_ids.values())
    final = (existing - ours) | want
    stash.call(
        "mutation($id: ID!, $ids: [ID!]) { sceneUpdate(input: {id: $id, tag_ids: $ids}) { id } }",
        {"id": str(scene_id), "ids": sorted(final)},
    )


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
            run_stats(stash, settings, do_tag=False)
        elif mode == "tag":
            run_stats(stash, settings, do_tag=True)
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
