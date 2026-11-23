#!/usr/bin/env python3
"""Unit tests for the re-attach feature (converted file -> the scene it replaced). Pure stdlib, no Stash.

Run:  python -m unittest discover stash-plugin/tests -v
"""
import os
import shutil
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "stashy-companion"))
import stashy_companion as sc  # noqa: E402

MERGE_STEPS = ["sceneMerge", "sceneUpdate", "destroyFiles", "metadataGenerate"]
NEWER = "2026-11-23T12:00:00-05:00"


class FakeStash:
    """Answers the handful of queries re-attach makes and records every mutation in order."""

    def __init__(self, scenes, roots=("/lib",)):
        self.scenes = {str(s["id"]): s for s in scenes}
        self.roots = list(roots)
        self.mutations = []

    def call(self, query, variables=None):
        variables = variables or {}
        if "mutation" in query:
            self.mutations.append((query.split("{")[1].split("(")[0].strip(), variables))
            return {"metadataScan": "job-1"} if "metadataScan" in query else {}
        if "stashes" in query:
            return {"configuration": {"general": {"stashes": [{"path": r, "excludeVideo": False} for r in self.roots]}}}
        if "generate {" in query:
            return {"configuration": {"defaults": {"generate": {"covers": True, "sprites": True, "previews": True,
                                                                  "markers": False, "phashes": True}}}}
        if "defaults" in query:
            return {"configuration": {"defaults": {"scan": {"scanGenerateCovers": True, "scanGenerateSprites": True}}}}
        if "findScene(" in query:
            return {"findScene": self.scenes.get(variables["id"])}
        if "$s: SceneFilterType" in query:
            needle = variables["s"]["path"]["value"].strip('"').lower()
            hits = [s for s in self.scenes.values() if any(needle in f["path"].lower() for f in s["files"])]
            return {"findScenes": {"scenes": hits}}
        return {"findScenes": {"scenes": list(self.scenes.values())}}


def scene(sid, paths, duration=100.0, created="2026-05-10T10:00:00-04:00"):
    return {"id": str(sid), "created_at": created,
            "files": [{"id": str(sid * 10 + i), "path": p, "duration": duration} for i, p in enumerate(paths)]}


class ReattachTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        # The served maps live in the plugin's cache dir — never touch the real one from a test.
        for name in ("_report_scene_append", "_report_scene_remove", "_thumbhash_scene_append", "_thumbhash_scene_remove"):
            patcher = mock.patch.object(sc, name)
            setattr(self, name.strip("_"), patcher.start())
            self.addCleanup(patcher.stop)

    def live(self, name):
        path = os.path.join(self.dir, name)
        with open(path, "wb") as f:
            f.write(b"x")
        return path

    # ---- naming -------------------------------------------------------------------------------------------
    def test_name_key_ignores_case_punctuation_and_extensions(self):
        self.assertEqual(sc._name_key("/a/Foo Bar - 1080p.MP4"), sc._name_key("/b/foo_bar-1080P.mkv"))
        self.assertEqual(sc._name_key("/a/clip.mp4.mkv"), "clip")
        self.assertNotEqual(sc._name_key("/a/clip 2.mp4"), sc._name_key("/a/clip.mp4"))

    # ---- matching -----------------------------------------------------------------------------------------
    def test_picks_the_single_older_stale_scene_with_same_name_and_length(self):
        old = scene(1, ["/lib/Torrent Dir/Clip One.mkv"], 100.0)
        new = scene(2, [self.live("clip one.mp4")], 100.03, created=NEWER)
        self.assertEqual(sc._pick_stale(new, [old])[0], old)

    def test_rejects_length_mismatch_and_newer_stale_scene_and_other_names(self):
        new = scene(2, [self.live("clip one.mp4")], 100.0, created=NEWER)
        self.assertIsNone(sc._pick_stale(new, [scene(1, ["/lib/clip one.mkv"], 102.5)])[0])
        self.assertIsNone(sc._pick_stale(new, [scene(1, ["/lib/clip one.mkv"], 100.0, created="2027-01-01T00:00:00-05:00")])[0])
        self.assertIsNone(sc._pick_stale(new, [scene(1, ["/lib/clip two.mkv"], 100.0)])[0])

    def test_two_equally_good_stale_scenes_is_ambiguous_not_a_guess(self):
        new = scene(3, [self.live("clip.mp4")], 100.0, created=NEWER)
        old, why = sc._pick_stale(new, [scene(1, ["/lib/a/clip.mp4"]), scene(2, ["/lib/b/clip.mp4"])])
        self.assertIsNone(old)
        self.assertTrue(why.startswith("ambiguous"))

    # ---- merging ------------------------------------------------------------------------------------------
    def test_merge_order_and_only_dead_file_record_is_destroyed(self):
        old = scene(1, ["/lib/gone.mkv"])
        new = scene(2, [self.live("gone.mp4")], created=NEWER)
        st = FakeStash([old, new])
        sc._merge_into(st, {}, old, new)
        self.assertEqual([m[0] for m in st.mutations], MERGE_STEPS)
        merge, update, destroy, gen = (m[1] for m in st.mutations)
        self.assertEqual(merge["i"]["source"], ["2"])
        self.assertEqual(merge["i"]["destination"], "1")
        self.assertNotIn("values", merge["i"])               # nothing on the old scene is overwritten
        self.assertEqual(update["i"], {"id": "1", "primary_file_id": "20"})
        self.assertEqual(destroy["ids"], ["10"])               # the dead record of the OLD scene, never the new file
        # merging deletes the destroyed scene's generated files, so the survivor's are rebuilt (missing ones only)
        self.assertEqual(gen["i"]["sceneIDs"], ["1"])
        self.assertFalse(gen["i"]["overwrite"])
        self.assertTrue(gen["i"]["previews"] and gen["i"]["sprites"])
        self.assertFalse(gen["i"]["markers"])                  # a flag the server has switched off stays off
        # sceneMerge fires no Scene.Destroy.Post, so the merged-away id is dropped from the served maps by hand
        self.report_scene_remove.assert_called_once_with("2")
        self.thumbhash_scene_remove.assert_called_once_with("2")
        self.report_scene_append.assert_called_once_with(st, {}, "1")
        self.thumbhash_scene_append.assert_called_once_with(st, {}, "1")

    # ---- the scan hook ------------------------------------------------------------------------------------
    def test_hook_merges_new_scene_into_lost_scene(self):
        old = scene(1, ["/lib/Show/Clip.mkv"])
        new = scene(2, [self.live("clip.mp4")], created=NEWER)
        st = FakeStash([old, new])
        sc.run_hook(st, {}, {"type": "Scene.Create.Post", "id": 2})
        self.assertEqual([m[0] for m in st.mutations], MERGE_STEPS)
        self.report_scene_append.assert_called_once_with(st, {}, "1")   # only the survivor is ever reported

    def test_hook_switch_off_leaves_scenes_alone(self):
        old = scene(1, ["/lib/Clip.mkv"])
        new = scene(2, [self.live("clip.mp4")], created=NEWER)
        st = FakeStash([old, new])
        off = {"autoReattachConverted": "false"}
        sc.run_hook(st, off, {"type": "Scene.Create.Post", "id": 2})
        self.assertEqual(st.mutations, [])
        self.report_scene_append.assert_called_once_with(st, off, "2")
        self.thumbhash_scene_append.assert_called_once_with(st, off, "2")

    def test_hook_ordinary_new_scene_is_not_merged(self):
        new = scene(2, [self.live("fresh.mp4")], created=NEWER)
        st = FakeStash([scene(1, ["/lib/other.mkv"]), new])
        sc.run_hook(st, {}, {"type": "Scene.Create.Post", "id": 2})
        self.assertEqual(st.mutations, [])
        self.report_scene_append.assert_called_once_with(st, {}, "2")

    # ---- the scheduled task -------------------------------------------------------------------------------
    def test_task_dry_run_changes_nothing_and_real_run_merges(self):
        old = scene(1, [os.path.join(self.dir, "gone", "Clip.mkv")])
        new = scene(2, [self.live("clip.mp4")], created=NEWER)
        st = FakeStash([old, new], roots=[self.dir])
        sc.run_reattach(st, {}, {"dry_run": True})
        self.assertEqual(st.mutations, [])
        sc.run_reattach(st, {}, {})
        self.assertEqual([m[0] for m in st.mutations], MERGE_STEPS)

    def test_task_scans_a_converted_file_stash_has_not_seen_after_it_stops_growing(self):
        old = scene(1, [os.path.join(self.dir, "gone", "Clip.mkv")])
        unseen = self.live("clip.mp4")
        st = FakeStash([old, scene(9, [self.live("unrelated.mp4")])], roots=[self.dir])
        with mock.patch.object(sc.time, "sleep"):
            sc.run_reattach(st, {}, {"auto": True})
        self.assertEqual([m[0] for m in st.mutations], ["metadataScan"])
        scan = st.mutations[0][1]["input"]
        self.assertEqual(scan["paths"], [unseen])
        self.assertTrue(scan["scanGenerateCovers"])           # saved generation defaults ride along (a bare scan generates nothing)

    def test_task_obeys_the_switch_only_when_scheduled(self):
        old = scene(1, [os.path.join(self.dir, "gone", "Clip.mkv")])
        st = FakeStash([old], roots=[self.dir])
        self.live("clip.mp4")
        with mock.patch.object(sc.time, "sleep"):
            sc.run_reattach(st, {"autoReattachConverted": "false"}, {"auto": True})
        self.assertEqual(st.mutations, [])

    def test_unmounted_library_does_not_make_scenes_look_lost(self):
        old = scene(1, ["/nonexistent-root/Clip.mkv"])
        stale, live, _ = sc._classify_scenes(FakeStash([old], roots=["/nonexistent-root"]), ["/nonexistent-root"])
        self.assertEqual((stale, live), ([], []))


if __name__ == "__main__":
    unittest.main()
