"""A restored cache may reuse timestamps, never stale source or outside files."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("ci_mtimes", ROOT / "scripts/ci_mtimes.py")
mtimes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mtimes)
OLD = 1_600_000_000_000_000_000
FRESH = OLD + 10_000_000_000


class InputTimesTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)

    def source(self, name, content="old"):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        os.utime(path, ns=(OLD, OLD))
        subprocess.run(["git", "-C", str(self.root), "add", name], check=True)
        return path

    def run_command(self, command):
        with contextlib.redirect_stdout(io.StringIO()):
            command(self.root)

    def test_only_identical_inputs_reuse_timestamps_including_unstaged_edits(self):
        same, staged, dirty = [self.source(name) for name in ("same.swift", "staged.swift", "dirty.swift")]
        self.run_command(mtimes.save)
        staged.write_text("new")
        dirty.write_text("new")
        subprocess.run(["git", "-C", str(self.root), "add", "staged.swift"], check=True)
        added = self.source("added.swift")
        for path in (same, staged, dirty, added):
            os.utime(path, ns=(FRESH, FRESH))
        self.run_command(mtimes.restore)
        self.assertEqual(same.stat().st_mtime_ns, OLD)
        for path in (staged, dirty, added):
            self.assertEqual(path.stat().st_mtime_ns, FRESH, path.name)
        self.assertEqual(dirty.read_text(), "new")

    def test_cached_paths_and_symlinked_parents_cannot_touch_an_outside_file(self):
        path = self.source("linked/source.swift")
        self.run_command(mtimes.save)
        with tempfile.TemporaryDirectory() as outside:
            external = Path(outside) / "source.swift"
            external.write_text("old")
            os.utime(external, ns=(FRESH, FRESH))
            path.unlink()
            path.parent.rmdir()
            path.parent.symlink_to(outside, target_is_directory=True)
            manifest = self.root / mtimes.MANIFEST
            entries = json.loads(manifest.read_text())
            entries[str(external)] = entries["linked/source.swift"]
            entries[os.path.relpath(external, self.root)] = entries["linked/source.swift"]
            manifest.write_text(json.dumps(entries))
            self.run_command(mtimes.restore)
            self.assertEqual(external.stat().st_mtime_ns, FRESH)

    def test_missing_invalid_and_future_metadata_leave_normal_invalidation(self):
        path = self.source("input.swift")
        self.run_command(mtimes.restore)
        self.run_command(mtimes.save)
        manifest = self.root / mtimes.MANIFEST
        original = json.loads(manifest.read_text())
        digest = original["input.swift"][0]
        for content in ("not json", "[]", json.dumps({"input.swift": [digest, 10**30]}),
                        json.dumps({"input.swift": [digest, -1]})):
            with self.subTest(content=content):
                manifest.write_text(content)
                os.utime(path, ns=(FRESH, FRESH))
                self.run_command(mtimes.restore)
                self.assertEqual(path.stat().st_mtime_ns, FRESH)

    def test_the_manifest_itself_must_not_be_a_link(self):
        outside = self.source("outside.json", "{}")
        manifest = self.root / mtimes.MANIFEST
        manifest.parent.mkdir()
        manifest.symlink_to(outside)
        self.run_command(mtimes.restore)
        with self.assertRaises(ValueError):
            self.run_command(mtimes.save)
        self.assertEqual(outside.read_text(), "{}")


if __name__ == "__main__":
    unittest.main()
