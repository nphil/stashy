#!/usr/bin/env python3
"""Unit tests for stashy_companion helpers — pure stdlib (unittest), no Stash server, no ffmpeg.

Run from the repo root (or anywhere):  python -m unittest discover stash-plugin/tests -v

Focus: the VMAF-map crash-safety guarantees added in v0.3.1 —
  * _prune_missing only ever removes scenes absent from `seen`;
  * a mid-run exception (e.g. a GraphQL error during pagination) must NOT prune the persisted map
    (the v0.3.0 bug: the finally-block prune ran with a partial `seen` and gutted the map);
  * a clean full pass still prunes scenes deleted from Stash;
  * one bad scene is logged + skipped, and the run completes;
  * _vmaf_search honours its `deadline` cap by raising TimeoutError.
"""
import io
import json
import os
import sys
import tempfile
import time
import unittest
import urllib.error
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "stashy-companion"))
import stashy_companion as sc  # noqa: E402


class FakeStash:
    """Stub for the GraphQL client: serves findScenes pages from a script.

    `pages` is a list where each element is either a list of scene dicts (one full page of the
    per_page=100 pagination) or an Exception instance to raise when that page is requested.
    The separate per_page=1 count probe always succeeds.
    """

    def __init__(self, pages, count=None):
        self.pages = pages
        self.count = count if count is not None else sum(
            len(p) for p in pages if isinstance(p, list))

    def call(self, query, variables=None):
        f = (variables or {}).get("f", {})
        if f.get("per_page") == 1:   # the cheap total-count probe
            return {"findScenes": {"count": self.count, "scenes": [{"id": -1}]}}
        page = f.get("page", 1)
        if page > len(self.pages):
            return {"findScenes": {"count": self.count, "scenes": []}}
        item = self.pages[page - 1]
        if isinstance(item, Exception):
            raise item
        return {"findScenes": {"count": self.count, "scenes": item}}


class VmafMapHarness(unittest.TestCase):
    """Shared harness: CACHE_DIR → a temp dir; all ffmpeg/ffprobe touchpoints stubbed out."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        patches = [
            mock.patch.object(sc, "CACHE_DIR", self.tmp.name),
            mock.patch.object(sc, "_bin", lambda name, override, hw=False: name),
            mock.patch.object(sc, "_vmaf_ffmpeg", lambda ff, ffhw: "ffmpeg"),
            mock.patch.object(sc, "_vmaf_model_arg", lambda ff: "model"),
            mock.patch.object(sc, "encoder_available", lambda ff, enc: False),
            mock.patch.object(sc, "ffprobe_streams", lambda path, ffprobe: None),
        ]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)
        self.addCleanup(self.tmp.cleanup)

    def seed_map(self, scene_ids):
        entry = {"file": "1|x.mp4", "res": {"720": {"crf": 30, "vmaf": 94.0, "curve": {"30": 94.0}}}}
        sc._write_vmaf_map_raw({sid: dict(entry) for sid in scene_ids})


class TestPruneMissing(unittest.TestCase):
    def test_removes_only_unseen(self):
        report = {"1": {}, "2": {}, "3": {}}
        gone = sc._prune_missing(report, seen={"1", "3"})
        self.assertEqual(gone, ["2"])
        self.assertEqual(set(report), {"1", "3"})

    def test_full_seen_prunes_nothing(self):
        report = {"1": {}, "2": {}}
        self.assertEqual(sc._prune_missing(report, seen={"1", "2", "99"}), [])
        self.assertEqual(set(report), {"1", "2"})


class TestVmafMapCrashSafety(VmafMapHarness):
    def test_mid_run_exception_does_not_prune_map(self):
        """Regression for the v0.3.0 data-loss bug: a pagination failure mid-run must leave every
        previously-mapped scene in the persisted map (the old finally-block prune ran on ANY
        non-time-budget exit and deleted everything a partial `seen` hadn't reached)."""
        self.seed_map(["1", "2", "300"])
        # Page 1 = exactly 100 scenes (so pagination continues), page 2 explodes like a GraphQL blip.
        page1 = [{"id": i, "files": []} for i in range(1, 101)]
        stash = FakeStash([page1, RuntimeError("GraphQL errors: connection reset")], count=150)
        with self.assertRaises(RuntimeError):
            sc.run_vmaf_map(stash, settings={})
        kept = sc._load_vmaf_map()
        self.assertEqual(set(kept), {"1", "2", "300"},
                         "a mid-run failure must never prune the persisted VMAF map")

    def test_clean_full_pass_prunes_deleted_scenes(self):
        self.seed_map(["1", "300"])
        stash = FakeStash([[{"id": 1, "files": []}]])   # scene 300 no longer exists in Stash
        sc.run_vmaf_map(stash, settings={})
        self.assertEqual(set(sc._load_vmaf_map()), {"1"})

    def test_bad_scene_is_skipped_and_run_completes(self):
        """One scene whose per-scene work raises must be logged + skipped; the pass still completes
        cleanly (so pruning still happens) and the bad scene keeps its existing map entry."""
        self.seed_map(["300"])
        bad = os.path.join(self.tmp.name, "bad.mp4")
        with open(bad, "wb") as fh:
            fh.write(b"x")

        def boom(path, ffprobe):
            raise RuntimeError("ffprobe segfault stand-in")
        p = mock.patch.object(sc, "ffprobe_streams", boom)
        p.start()
        self.addCleanup(p.stop)
        stash = FakeStash([[{"id": 1, "files": [{"path": bad, "height": 720}]},
                            {"id": 2, "files": []}]])
        sc.run_vmaf_map(stash, settings={})           # must not raise
        kept = sc._load_vmaf_map()
        self.assertIn("1", kept, "the failed scene stays (it still exists in Stash)")
        self.assertNotIn("300", kept, "the clean pass still prunes genuinely deleted scenes")

    def test_malformed_map_entry_is_restarted_not_fatal(self):
        """A map entry without a 'res' dict (hand-edited / older format) used to KeyError at
        `e[\"res\"]`; it must now be reset to a fresh entry instead."""
        src = os.path.join(self.tmp.name, "v.mp4")
        with open(src, "wb") as fh:
            fh.write(b"x")
        fp = sc._file_fingerprint({"size": 1, "path": src})
        sc._write_vmaf_map_raw({"1": {"file": fp}})   # matching fingerprint, no "res"
        stash = FakeStash([[{"id": 1, "files": [{"path": src, "size": 1, "height": 720}]}]])
        sc.run_vmaf_map(stash, settings={})           # ffprobe stub → None → scene skipped after reset
        self.assertEqual(sc._load_vmaf_map()["1"], {"file": fp, "res": {}})


class FakeResponse:
    """Context-manager stand-in for urllib.request.urlopen's return value."""

    def __init__(self, body):
        self._body = json.dumps(body).encode("utf-8")

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class TestStashAuth(unittest.TestCase):
    """The v0.3.1 fix for the CONFIRMED root cause of the mid-run VMAF-map deaths: Stash's session
    cookie expires during multi-hour jobs (GraphQL 401 after ~2h40m on the box), so the client must
    adopt the never-expiring API key at task start."""

    def _stash(self):
        return sc.Stash({"Scheme": "http", "Host": "localhost", "Port": 9999,
                         "SessionCookie": {"Name": "session", "Value": "abc"}})

    def test_adopt_api_key_swaps_cookie_for_key(self):
        st = self._stash()
        self.assertIn("Cookie", st.headers)
        resp = FakeResponse({"data": {"configuration": {"general": {"apiKey": "K123"}}}})
        with mock.patch.object(sc.urllib.request, "urlopen", return_value=resp):
            st.adopt_api_key()
        self.assertEqual(st.headers.get("ApiKey"), "K123")
        self.assertNotIn("Cookie", st.headers, "the expiring cookie must be dropped once the key is adopted")

    def test_adopt_api_key_noop_on_open_instance(self):
        st = self._stash()
        resp = FakeResponse({"data": {"configuration": {"general": {"apiKey": ""}}}})
        with mock.patch.object(sc.urllib.request, "urlopen", return_value=resp):
            st.adopt_api_key()
        self.assertNotIn("ApiKey", st.headers)
        self.assertIn("Cookie", st.headers)

    def test_adopt_api_key_survives_fetch_error(self):
        st = self._stash()
        with mock.patch.object(sc.urllib.request, "urlopen",
                               side_effect=OSError("connection refused")):
            st.adopt_api_key()   # must not raise
        self.assertNotIn("ApiKey", st.headers)

    def test_call_retries_once_on_401(self):
        st = self._stash()
        calls = []

        def fake_urlopen(req, timeout=None):
            calls.append(req)
            raise urllib.error.HTTPError("http://x/graphql", 401, "Unauthorized",
                                         None, io.BytesIO(b"unauthorized"))
        with mock.patch.object(sc.urllib.request, "urlopen", side_effect=fake_urlopen), \
             mock.patch.object(sc.time, "sleep", lambda s: None):
            with self.assertRaises(RuntimeError):
                st.call("query { version { version } }")
        self.assertEqual(len(calls), 2, "a 401 gets exactly one retry")


class RecordingStash:
    """Records every GraphQL call; returns {}."""

    def __init__(self):
        self.calls = []

    def call(self, query, variables=None):
        self.calls.append((query, variables))
        return {}


class TestSettingsBackupRestore(unittest.TestCase):
    """Stash wipes plugins.settings.<id> on every package update; the plugin self-heals from a backup
    in cache/ (which updates preserve)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        p = mock.patch.object(sc, "CACHE_DIR", self.tmp.name)
        p.start()
        self.addCleanup(p.stop)
        self.addCleanup(self.tmp.cleanup)

    def test_non_empty_settings_refresh_the_backup(self):
        stash = RecordingStash()
        out = sc._sync_settings(stash, {"encoder": "hevc_nvenc", "vmafSamples": 2})
        self.assertEqual(out, {"encoder": "hevc_nvenc", "vmafSamples": 2})
        with open(sc._settings_backup_path()) as fh:
            self.assertEqual(json.load(fh), {"encoder": "hevc_nvenc", "vmafSamples": 2})
        self.assertEqual(stash.calls, [], "backing up must not touch GraphQL")

    def test_empty_settings_restore_from_backup(self):
        with open(sc._settings_backup_path(), "w") as fh:
            json.dump({"preserveHDR": True, "vmafMapBudgetMin": 90}, fh)
        stash = RecordingStash()
        out = sc._sync_settings(stash, {})
        self.assertEqual(out, {"preserveHDR": True, "vmafMapBudgetMin": 90},
                         "the run must use the restored values")
        self.assertEqual(len(stash.calls), 1)
        query, variables = stash.calls[0]
        self.assertIn("configurePlugin", query)
        self.assertEqual(variables, {"id": sc.PLUGIN_ID,
                                     "input": {"preserveHDR": True, "vmafMapBudgetMin": 90}})

    def test_empty_settings_without_backup_stay_empty(self):
        stash = RecordingStash()
        self.assertEqual(sc._sync_settings(stash, {}), {})
        self.assertEqual(stash.calls, [])

    def test_partial_settings_never_trigger_restore(self):
        """A partial map is user intent — it must be backed up, not merged over."""
        with open(sc._settings_backup_path(), "w") as fh:
            json.dump({"a": 1, "b": 2, "c": 3}, fh)
        stash = RecordingStash()
        out = sc._sync_settings(stash, {"a": 9})
        self.assertEqual(out, {"a": 9})
        self.assertEqual(stash.calls, [], "no configurePlugin on a partial map")
        with open(sc._settings_backup_path()) as fh:
            self.assertEqual(json.load(fh), {"a": 9}, "backup refreshed to the live map")

    def test_restore_survives_configure_plugin_failure(self):
        with open(sc._settings_backup_path(), "w") as fh:
            json.dump({"x": 1}, fh)

        class FailingStash:
            def call(self, query, variables=None):
                raise RuntimeError("configurePlugin unsupported")
        out = sc._sync_settings(FailingStash(), {})
        self.assertEqual(out, {"x": 1}, "the backup is still used for this run")


class TestOriginalMapLookup(unittest.TestCase):
    """Regression for v0.3.3: an Original download (target_h == 0) must reuse the numeric source-height
    map entry instead of missing the nonexistent 'orig' key and re-running the live analysis."""

    def test_map_lookup_height_resolves_original_to_source(self):
        self.assertEqual(sc._map_lookup_height(720, 1080), 720)        # downscale → target height
        self.assertEqual(sc._map_lookup_height(0, 1080), 1080)         # Original → source height
        self.assertEqual(sc._map_lookup_height(0, 1079), 1078)         # kept even
        self.assertEqual(sc._map_lookup_height(0, 0), 0)               # unknown source → 0 (still misses, safely)

    def test_cached_crf_hits_via_source_height_for_original(self):
        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch.object(sc, "CACHE_DIR", tmp):
                sc._write_vmaf_map_raw({"42": {"file": "1|x.mp4",
                    "res": {"1080": {"crf": 40, "vmaf": 97.2, "curve": {"38": 98.7, "40": 97.2}}}}})
                # The old behaviour: looking up target_h=0 keys 'orig', which the map never stores → miss.
                self.assertEqual(sc._res_key(0), "orig")
                self.assertIsNone(sc._cached_crf("42", 0, 94.0))
                # The fix: Original resolves to the source height (1080) and hits the stored entry.
                self.assertEqual(sc._cached_crf("42", sc._map_lookup_height(0, 1080), 94.0), (40, 97.2))


class TestBitrateMap(unittest.TestCase):
    """v0.3.4: per-preset target bitrates resolved from the measured VMAF + bitrate curves, for
    VMAF-calibrated on-device transcodes."""

    def test_bitrates_from_curves_picks_per_preset(self):
        vmaf = {"30": 99.0, "38": 95.0, "42": 92.0}      # stored curves use str CQ keys
        bps = {30: 8_000_000, 38: 4_000_000, 42: 2_000_000}
        out = sc._bitrates_from_curves(vmaf, bps, {"high": 97, "balanced": 94, "small": 91})
        self.assertEqual(out, {"high": 8_000_000, "balanced": 4_000_000, "small": 2_000_000})

    def test_bitrates_tolerate_str_bitrate_keys_and_omit_uncovered(self):
        vmaf = {"30": 96.0, "40": 93.0}
        bps = {"30": 6_000_000, "40": 3_000_000}         # str keys too
        out = sc._bitrates_from_curves(vmaf, bps, {"high": 99, "balanced": 94, "small": 91})
        self.assertNotIn("high", out)                    # target 99 not covered by any measured point → omitted
        self.assertEqual(out["balanced"], 6_000_000)     # largest CQ with VMAF≥93.5 is 30
        self.assertEqual(out["small"], 3_000_000)        # largest CQ with VMAF≥90.5 is 40

    def test_empty_when_no_curve(self):
        self.assertEqual(sc._bitrates_from_curves({}, {}, {"balanced": 94}), {})


class TestVmafSearchDeadline(unittest.TestCase):
    def test_expired_deadline_raises_timeout(self):
        with tempfile.TemporaryDirectory() as work:
            with self.assertRaises(TimeoutError):
                sc._vmaf_search("src.mp4", "libx265", False, "ffmpeg", "ffmpeg", 720,
                                sc.DEFAULT_AV1_PRESET, "30", None, 60.0, 1280, 720,
                                94.0, "model", work, lambda m: None,
                                deadline=time.time() - 1)


if __name__ == "__main__":
    unittest.main()
