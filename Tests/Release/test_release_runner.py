"""Release package provenance and the release workflow wiring; no tokens, runner, or network."""
import hermetic_env  # noqa: F401  (must stay first: scrubs ambient SHEPHERD_*/PI_*)
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import release
import release_runner as runner
from test_ci_workflow import jobs

SHA = "a" * 40
PLAN = release.plan("refs/heads/nightly", "202610010000")


class PackageTests(unittest.TestCase):
    def test_real_package_producer_preserves_signing_eligibility(self):
        workflow = (ROOT / ".github/workflows/release-build.yml").read_text()
        block = workflow.split("      - name: Record package provenance\n")[1].split("      - name:")[0]
        shell = "set -euo pipefail\n" + "\n".join(
            line[10:] for line in block.split("        run: |\n")[1].splitlines())
        for identity, eligible in (("-", False), ("", False), ("Developer ID Application: Fixture", True)):
            with self.subTest(identity=identity), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "scripts").symlink_to(ROOT / "scripts", target_is_directory=True)
                (root / PLAN["dmg"]).write_bytes(b"fixture")
                result = subprocess.run(["bash", "-c", shell], cwd=root, capture_output=True, text=True,
                    env={**os.environ, "PARENT_RUN": "10",
                         "PARENT_ATTEMPT": "1", "SOURCE_SHA": SHA, "BUILD_NUMBER": "42",
                         "RELEASE_PLAN": json.dumps(PLAN), "SIGNING_IDENTITY": identity, "TAG": PLAN["tag"]}, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads((root / "shepherd-appcast.json").read_text()),
                                 {"version": 1, "tag": PLAN["tag"], "eligible": eligible})
                runner.manifest(directory, 10, 1, SHA, 42, PLAN, verify=True)

    def test_package_is_bound_to_parent_attempt_source_build_and_required_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / PLAN["dmg"]).write_bytes(b"signed archive fixture")
            policy = root / "shepherd-appcast.json"
            policy.write_text(json.dumps({"version": 1, "tag": PLAN["tag"], "eligible": True}))
            runner.manifest(directory, 10, 1, SHA, 42, PLAN)
            runner.manifest(directory, 10, 1, SHA, 42, PLAN, verify=True)
            for parent, attempt, sha, build in ((11, 1, SHA, 42), (10, 2, SHA, 42),
                                              (10, 1, "b" * 40, 42), (10, 1, SHA, 43)):
                with self.assertRaises(runner.RunnerError):
                    runner.manifest(directory, parent, attempt, sha, build, PLAN, verify=True)
            (root / PLAN["dmg"]).write_bytes(b"corrupt archive")
            with self.assertRaises(runner.RunnerError):
                runner.manifest(directory, 10, 1, SHA, 42, PLAN, verify=True)
            policy.write_text(json.dumps({"version": 1, "tag": "wrong", "eligible": True}))
            with self.assertRaises(runner.RunnerError):
                runner.manifest(directory, 10, 1, SHA, 42, PLAN)
            (root / PLAN["dmg"]).unlink()
            with self.assertRaises(runner.RunnerError):
                runner.manifest(directory, 10, 1, SHA, 42, PLAN)


class WorkflowTests(unittest.TestCase):
    def test_release_always_publishes_the_package_its_own_run_built(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        build = (ROOT / ".github/workflows/release-build.yml").read_text()
        release_job = jobs(workflow)["release"]
        self.assertIn("needs: [plan, build]", release_job)
        self.assertNotIn("if:", release_job.split("    runs-on:")[0])
        self.assertIn("uses: ./.github/workflows/release-build.yml", jobs(workflow)["build"])
        self.assertIn("if: fromJSON(needs.plan.outputs.plan).build", jobs(workflow)["build"])
        fetch = release_job.split("      - name: Fetch the selected package\n")[1].split("      - name:")[0]
        self.assertIn("name: release-package-${{ github.run_id }}-${{ github.run_attempt }}", fetch)
        self.assertNotIn("run-id:", fetch)
        self.assertIn("run: python3 scripts/release_runner.py verify", release_job)

    def test_the_build_workflow_is_a_build_only_reusable_workflow(self):
        build = (ROOT / ".github/workflows/release-build.yml").read_text()
        self.assertIn("on:\n  workflow_call:\n", build)
        self.assertNotIn("workflow_dispatch", build)
        self.assertNotIn("run-name:", build)
        for mutation in ("git push", "gh release", "SPARKLE_PRIVATE_KEY", "contents: write", "pull_request:"):
            self.assertNotIn(mutation, build)
        self.assertNotIn("hosted", build.split("jobs:\n")[0])
        self.assertIn("    runs-on: macos-26\n", build)
        self.assertIn('CURRENT_PROJECT_VERSION="$BUILD_NUMBER"', build)
        self.assertIn("ref: ${{ inputs.source_sha }}", build)
        self.assertIn("persist-credentials: false", build)
        self.assertIn("timeout-minutes: 60", build)
        self.assertIn("python3 scripts/release_runner.py manifest", build)

    def test_cleanup_restores_exact_keychain_list_and_removes_credentials_even_on_restore_failure(self):
        build = (ROOT / ".github/workflows/release-build.yml").read_text()
        cleanup = build.split("      - name: Restore keychains and remove signing credentials\n")[1]
        self.assertIn("if: always()", cleanup)
        code = cleanup.split("          python3 - <<'PYTHON'\n")[1].split("          PYTHON")[0]
        code = "\n".join(line[10:] for line in code.splitlines())
        for fail in (False, True):
            with self.subTest(fail=fail), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                for name in ("cert.p12", "notary.p8", "release-build.keychain-db"):
                    (root / name).write_text("fixture")
                old = ['login keychain', '/fixture/other.keychain-db']
                import shlex
                (root / "release-keychains.txt").write_text(shlex.join(old))
                log = root / "log"
                security = root / "security"
                security.write_text('#!/usr/bin/env python3\nimport json,os,sys\nwith open(os.environ["LOG"],"a") as f: f.write(json.dumps(sys.argv[1:])+"\\n")\nif sys.argv[1]=="list-keychains" and os.environ["FAIL"]=="1": sys.exit(23)\n')
                security.chmod(0o700)
                result = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True,
                    env={**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"],
                         "RUNNER_TEMP": directory, "LOG": str(log), "FAIL": str(int(fail))}, timeout=5)
                self.assertEqual(result.returncode == 0, not fail, result.stderr)
                calls = [json.loads(line) for line in log.read_text().splitlines()]
                self.assertEqual(calls[0], ["list-keychains", "-d", "user", "-s", *old])
                self.assertEqual(calls[1], ["delete-keychain", str(root / "release-build.keychain-db")])
                for name in ("cert.p12", "notary.p8", "release-keychains.txt"):
                    self.assertFalse((root / name).exists())


if __name__ == "__main__":
    unittest.main()
