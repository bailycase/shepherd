"""Keep trusted build caches reusable without deleting active work or release artifacts."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("ci_cache", ROOT / "scripts/ci_cache.py")
ci_cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci_cache)


def cache(number, ref="refs/heads/nightly", kind="spm"):
    key = {"spm": f"spm-macOS-{'a' * 12}-{'b' * 64}-{number:040x}",
           "xcode": f"xcode-macOS-Nightly-{'a' * 12}-{'b' * 12}-{number:040x}",
           "pi": f"pi-tests-{number:064x}"}.get(kind, kind)
    return dict(id=number, ref=ref, key=key, created_at=f"2026-10-{number:02d}T00:00:00Z", size_in_bytes=100)


class CacheRetentionTests(unittest.TestCase):
    def test_only_closed_pr_caches_and_replaced_trusted_baselines_are_selected(self):
        rows = [cache(n) for n in (1, 2, 3)] + [cache(n, kind="xcode") for n in (4, 5, 6)]
        rows += [cache(7, "refs/pull/40/merge"), cache(8, "refs/pull/41/merge"),
                 cache(9, "refs/pull/40/merge", "pi"), cache(10, "refs/heads/experiment"),
                 cache(11, "refs/tags/v1.0.0"), cache(12, kind="unrelated-data"),
                 cache(13, "refs/pull/42/merge")]
        calls = []
        def state(number):
            calls.append(number)
            return {40: "closed", 41: "open", 42: "unknown"}[number]
        self.assertEqual({row["id"] for row in ci_cache.candidates(rows, state)}, {1, 4, 7, 9})
        self.assertEqual(calls.count(40), 1)
        self.assertEqual({row["id"] for row in ci_cache.candidates(rows, state, closed_only=True)}, {7, 9})

    def test_retention_stops_at_the_deletion_bound(self):
        rows = [cache(n, "refs/pull/40/merge") for n in range(1, 31)]
        selected = ci_cache.candidates(rows, lambda _: "closed")
        self.assertEqual(len(selected), 20)
        self.assertEqual([row["id"] for row in selected], list(range(30, 10, -1)))

    def test_newest_baselines_for_each_configuration_survive(self):
        rows = [cache(n, kind=kind) for kind in ("spm", "xcode", "pi") for n in (1, 2, 3, 4)]
        release = cache(5, kind="xcode")
        release["key"] = release["key"].replace("-Nightly-", "-Release-")
        rows.append(release)
        selected = ci_cache.candidates(rows, lambda _: self.fail("not a PR"))
        self.assertEqual(len(selected), 6)
        self.assertTrue(all(row["id"] <= 2 for row in selected))
        self.assertNotIn(release, selected)

    def test_live_deletion_requires_nightly_and_never_prints_credential_payloads(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "calls.jsonl"
            gh = root / "gh"
            gh.write_text("#!/usr/bin/env python3\nimport json, os, sys\n"
                          "with open(os.environ['CALLS'], 'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')\n"
                          "route = sys.argv[2]\n"
                          "if 'actions/caches?' in route: print(json.dumps([{'actions_caches': json.loads(os.environ['ROWS'])}]))\n"
                          "elif '/pulls/' in route: print(json.dumps({'state': 'closed'}))\n"
                          "elif '--method' in sys.argv: pass\n")
            gh.chmod(0o755)
            env = dict(os.environ, GITHUB_REPOSITORY="owner/repo", GITHUB_REF="refs/heads/feature",
                       PATH=f"{root}{os.pathsep}{os.environ['PATH']}", CALLS=str(log),
                       ROWS=json.dumps([cache(1, "refs/pull/40/merge")]))
            command = [sys.executable, str(ROOT / "scripts/ci_cache.py")]
            refused = subprocess.run([*command, "--delete"], env=env, capture_output=True, text=True)
            self.assertNotEqual(refused.returncode, 0)
            self.assertFalse(log.exists())
            plan = subprocess.run(command, env=env, capture_output=True, text=True)
            self.assertEqual(plan.returncode, 0, plan.stderr)
            self.assertNotIn("DELETE", log.read_text())
            env["GITHUB_REF"] = "refs/heads/nightly"
            done = subprocess.run([*command, "--delete"], env=env, capture_output=True, text=True)
            self.assertEqual(done.returncode, 0, done.stderr)
            deletes = [json.loads(line) for line in log.read_text().splitlines() if 'DELETE' in line]
            self.assertEqual(deletes, [["api", "repos/owner/repo/actions/caches/1", "--method", "DELETE"]])
            gh.write_text("#!/bin/sh\nprintf 'token-secret-fixture' >&2\nexit 1\n")
            failed = subprocess.run([*command, "--delete"], env=env, capture_output=True, text=True)
            self.assertNotEqual(failed.returncode, 0)
            self.assertNotIn("token-secret-fixture", failed.stdout + failed.stderr)

    def test_a_failed_inventory_does_not_partly_delete_and_processes_have_deadlines(self):
        source = (ROOT / "scripts/ci_cache.py").read_text()
        self.assertIn("time.monotonic() + 180", source)
        self.assertIn("timeout=min(30, remaining)", source)
        self.assertIn("len(caches) > 500", source)
        with self.assertRaises(RuntimeError):
            ci_cache.candidates([cache(1, "refs/pull/40/merge")],
                                lambda _: (_ for _ in ()).throw(RuntimeError("API unavailable")))
        with patch.object(sys, "argv", ["ci_cache.py"]), \
             patch.dict(os.environ, {"GITHUB_REPOSITORY": "owner/repo"}), \
             patch.object(ci_cache.time, "monotonic", side_effect=[0, 181]), \
             patch.object(ci_cache.subprocess, "run") as run:
            with self.assertRaises(TimeoutError):
                ci_cache.main()
            run.assert_not_called()
        response = subprocess.CompletedProcess([], 0, json.dumps([{"actions_caches": [cache(1)] * 501}]), "")
        with patch.object(sys, "argv", ["ci_cache.py", "--delete"]), \
             patch.dict(os.environ, {"GITHUB_REPOSITORY": "owner/repo", "GITHUB_REF": "refs/heads/nightly"}), \
             patch.object(ci_cache.subprocess, "run", return_value=response) as run:
            with self.assertRaises(RuntimeError):
                ci_cache.main()
            self.assertEqual(run.call_count, 1)
            self.assertNotIn("DELETE", run.call_args.args[0])


class BuildCacheWorkflowTests(unittest.TestCase):
    def test_a_separate_trusted_hosted_job_builds_without_tests_or_release_dependencies(self):
        workflow = (ROOT / ".github/workflows/build-cache.yml").read_text()
        release = (ROOT / ".github/workflows/release.yml").read_text()
        ci = (ROOT / ".github/workflows/ci.yml").read_text()
        for token in ("branches: [nightly]", "github.ref == 'refs/heads/nightly'", "runs-on: macos-26",
                      "timeout-minutes: 25", "cancel-in-progress: true", "persist-credentials: false",
                      "uses: ./.github/actions/swift-build", "--delete --closed-only",
                      "actions: write", "pull-requests: read"):
            self.assertIn(token, workflow)
        self.assertNotIn("pull_request:", workflow)
        self.assertNotIn("pull_request_target", workflow)
        self.assertNotIn("swift test", workflow)
        self.assertNotIn("pi_engine.py stage", workflow)
        self.assertNotIn("secrets.", workflow)
        self.assertNotIn("self-hosted", workflow)
        self.assertNotIn("contents: write", workflow)
        self.assertNotIn("nightly-build-cache", ci + release)
        self.assertLess(workflow.index("--closed-only"), workflow.index("uses: ./.github/actions/swift-build"))
        self.assertLess(workflow.index("uses: ./.github/actions/swift-build"), workflow.index("name: Retain current trusted baselines"))


if __name__ == "__main__":
    unittest.main()
