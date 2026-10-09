"""Structure rules for .github/workflows/ci.yml and the swift-build action.

The workflow is read as text (the repository's tests are stdlib only). Run:
python3 -m unittest discover -s Tests/Release -v
"""
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import ci_plan  # noqa: E402


def read(*parts):
    with open(os.path.join(ROOT, *parts), encoding="utf-8") as f:
        return f.read()


WORKFLOW = read(".github", "workflows", "ci.yml")
ACTION = read(".github", "actions", "swift-build", "action.yml")


def jobs(text):
    """Job name to its text, for the jobs under the top-level `jobs:` key."""
    out, name, lines = {}, None, []
    for line in text.split("\njobs:\n", 1)[1].splitlines():
        m = re.match(r"^  ([a-z][a-z-]*):\s*$", line)
        if m or re.match(r"^  \S", line):
            if name:
                out[name] = "\n".join(lines) + "\n"
            name, lines = (m.group(1) if m else None), []
        elif name:
            lines.append(line)
    if name:
        out[name] = "\n".join(lines) + "\n"
    return out


def needs(job):
    m = re.search(r"^    needs: (?:\[([^\]]*)\]|(\S+))\s*$", job, re.M)
    if not m:
        return []
    return [n.strip() for n in (m.group(1) or m.group(2)).split(",")]


def run_script(job):
    """The script of the first `run: |` step of a job."""
    m = re.search(r"^( +)(?:- )?run: \|\n((?:\1  .*\n?)+)", job, re.M)
    assert m, "no run: | step"
    return "\n".join(line[len(m.group(1)) + 2:] for line in m.group(2).splitlines())


JOBS = jobs(WORKFLOW)


class WorkflowShapeTests(unittest.TestCase):
    def test_the_jobs_are_the_ones_the_docs_describe(self):
        self.assertEqual(set(JOBS), {"plan", "release-rules", "extensions", "tests", "ci"})

    def test_no_path_filter_can_stop_ci_from_reporting(self):
        # A workflow filtered out by paths never reports `CI`, so a pull request would wait for it for ever.
        self.assertNotRegex(WORKFLOW, r"(?m)^\s+paths(-ignore)?:")

    def test_the_triggers_are_master_pushes_pull_requests_the_daily_run_and_manual_runs(self):
        head = WORKFLOW.split("\npermissions:", 1)[0]
        for trigger in ("push:", "pull_request:", "schedule:", "workflow_dispatch:"):
            self.assertIn(f"\n  {trigger}", head)
        self.assertIn("branches: [master]", head)
        self.assertNotIn("nightly", head.split("\non:", 1)[1], "a push to nightly builds a release, it does not test")
        self.assertRegex(head, r'cron: "\d+ \d+ \* \* \*"')

    def test_the_scheduled_run_tests_master(self):
        for name in ("plan", "release-rules", "extensions", "tests"):
            self.assertIn("ref: ${{ github.event_name == 'schedule' && 'master' || '' }}", JOBS[name], name)

    def test_ci_is_the_one_gate_and_it_waits_for_every_job_that_can_fail_a_run(self):
        gate = JOBS["ci"]
        self.assertIn("name: CI", gate)
        self.assertEqual(sorted(needs(gate)), ["extensions", "plan", "release-rules", "tests"])
        self.assertIn("!cancelled()", gate)

    def test_the_gate_passes_for_success_and_skipped_and_fails_for_anything_else(self):
        script = run_script(JOBS["ci"])
        for results, passes in (("success success success success", True),
                                ("success success success skipped", True),
                                ("success failure success success", False),
                                ("success success success cancelled", False),
                                ("failure skipped skipped skipped", False)):
            done = subprocess.run(["bash", "-c", script], env={"RESULTS": results, "PATH": os.environ["PATH"]},
                                  capture_output=True, text=True, timeout=10)
            self.assertEqual(done.returncode == 0, passes, results)

    def test_no_job_may_write_issues_or_contents(self):
        self.assertNotIn("issues: write", WORKFLOW)
        self.assertNotIn("contents: write", WORKFLOW)

    def test_the_swift_job_runs_only_when_the_plan_says_the_change_can_affect_swift(self):
        tests = JOBS["tests"]
        self.assertIn("needs.plan.outputs.swift == 'true'", tests)
        self.assertIn("python3 scripts/ci_plan.py changed.txt", JOBS["plan"])
        self.assertIn("swift: ${{ steps.plan.outputs.swift }}", JOBS["plan"])

    def test_selfhosted_checkout_preserves_build_outputs_without_retaining_git_credentials(self):
        checkout = JOBS["tests"].split("uses: actions/checkout@v4", 1)[1].split("- uses:", 1)[0]
        self.assertIn("clean: ${{ runner.environment != 'self-hosted' }}", checkout)
        self.assertIn("persist-credentials: false", checkout)

    def test_the_swift_job_is_one_incremental_build_and_one_swift_test(self):
        tests = JOBS["tests"]
        self.assertIn("uses: ./.github/actions/swift-build", tests)
        self.assertIn("python3 scripts/pi_engine.py stage", tests)
        self.assertRegex(tests, r"swift test --skip-build \$SWIFTPM_FLAGS")
        self.assertNotIn("--no-parallel", tests, "the app suites gate themselves; the rest runs beside them")
        self.assertNotIn("matrix:", tests)
        self.assertNotIn("shard", tests)
        self.assertIn('CI: "true"', tests)
        self.assertIn("if: ${{ failure() }}", tests, "the log is kept only for a red run")

    def test_the_extension_tests_run_the_pinned_package_without_scripts_or_leniency(self):
        job = JOBS["extensions"]
        self.assertIn("scripts/pi-engine-pin.json", job)
        self.assertIn("--ignore-scripts", job)
        self.assertIn("node --test --test-reporter=spec Tests/Extensions/*.test.mjs", job)
        self.assertNotIn("continue-on-error", job)

    def test_every_script_the_workflow_runs_exists(self):
        for script in set(re.findall(r"scripts/(\w+\.py)", WORKFLOW)):
            self.assertTrue(os.path.exists(os.path.join(ROOT, "scripts", script)), script)

    def test_a_newer_run_cancels_the_running_one(self):
        block = WORKFLOW.split("\nconcurrency:", 1)[1].split("\ndefaults:", 1)[0]
        self.assertRegex(block, r"(?m)^  cancel-in-progress: true$")

    def test_no_job_survives_its_runs_cancellation(self):
        for name, job in JOBS.items():
            self.assertNotRegex(job, r"(?m)^    if: .*always\(\)", name)


class SwiftBuildActionTests(unittest.TestCase):
    def test_a_persistent_build_is_rebuilt_only_when_the_toolchain_changes_or_on_request(self):
        self.assertIn("marker=.build/ci-toolchain", ACTION)
        self.assertIn('[ "$CLEAN" = true ] ||', ACTION)
        self.assertLess(ACTION.index("- name: Restore dependency and build caches"),
                        ACTION.index("- name: Start over when the toolchain changed"))
        self.assertIn('[ "$(cat "$marker" 2>/dev/null)" != "$VERSION" ]', ACTION)
        self.assertIn("! -name pi-engine-cache", ACTION, "the engine's downloads survive a clean build")

    def test_caches_are_restored_only_on_hosted_runners(self):
        cache = ACTION.split("- name: Restore dependency and build caches", 1)[1].split("- name:", 1)[0]
        self.assertIn("if: runner.environment == 'github-hosted'", cache)
        self.assertIn("hashFiles('Package.resolved')", cache)
        self.assertIn("restore-keys:", cache)

    def test_hosted_pull_requests_restore_but_never_save_build_caches(self):
        self.assertIn("uses: actions/cache/restore@v4", ACTION)
        save = ACTION.split("- name: Save the hosted branch build", 1)[1]
        self.assertIn("runner.environment == 'github-hosted' && github.event_name == 'push'", save)
        self.assertIn("uses: actions/cache/save@v4", save)
        self.assertGreater(ACTION.index("- name: Save the hosted branch build"), ACTION.index("swift build --build-tests"))

    def test_clean_or_changed_toolchains_drop_products_but_keep_downloads(self):
        step = ACTION.split("- name: Start over when the toolchain changed", 1)[1].split("- name: Build", 1)[0]
        script = run_script(step)
        for previous, clean, survives in (("current", "false", True), ("old", "false", False),
                                         ("current", "true", False), (None, "false", False)):
            with self.subTest(previous=previous, clean=clean), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                build = root / ".build"
                for name in ("checkouts", "repositories", "artifacts", "pi-engine-cache", "arm64-apple-macosx"):
                    (build / name).mkdir(parents=True)
                    (build / name / "fixture").write_text("keep or rebuild")
                (build / "workspace-state.json").write_text("resolved")
                if previous:
                    (build / "ci-toolchain").write_text(previous + "\n")
                result = subprocess.run(["bash", "-e", "-c", script], cwd=root,
                                        env={**os.environ, "VERSION": "current", "CLEAN": clean},
                                        capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((build / "arm64-apple-macosx").exists(), survives)
                for name in ("checkouts", "repositories", "artifacts", "pi-engine-cache", "workspace-state.json"):
                    self.assertTrue((build / name).exists(), name)
                self.assertEqual((build / "ci-toolchain").read_text(), "current\n")

    def test_the_stale_transitive_module_workaround_runs_before_every_build(self):
        build = ACTION.split("- name: Build\n", 1)[1]
        self.assertLess(build.index("rm -f .build/*/debug/swift-version-*.txt"), build.index("swift build --build-tests"))
        self.assertIn("PackageFrameworks/Sparkle.framework", build)


class PlanTests(unittest.TestCase):
    def test_docs_templates_and_the_files_other_jobs_cover_run_no_swift(self):
        self.assertFalse(ci_plan.affects_swift([
            "docs/testing.md", "README.md", "AGENTS.md", ".github/pull_request_template.md",
            ".github/workflows/release.yml", ".github/CODEOWNERS", "Extensions/shepherd.ts",
            "Tests/Extensions/foo.test.mjs", "Tests/Release/test_release.py", "scripts/release.py",
            "App/iOS/App.swift", "App/Info.plist"]))
        self.assertFalse(ci_plan.affects_swift([]))

    def test_anything_swift_reads_runs_the_swift_job(self):
        for path in ("Sources/ShepherdApp/Thread.swift", "Tests/ShepherdAppUnitTests/X.swift", "Package.swift",
                     "Package.resolved", ".github/workflows/ci.yml", ".github/actions/swift-build/action.yml",
                     "scripts/pi-engine-pin.json", "scripts/pi_engine.py", "scripts/ci_plan.py",
                     "Tests/Extensions/native-thread-wire.json", "Vendor/x", "Shepherd.xcodeproj/project.pbxproj"):
            with self.subTest(path=path):
                self.assertTrue(ci_plan.affects_swift(["docs/x.md", path]))

    def test_the_runner_exit_status_not_printed_fixtures_decides_test_success(self):
        script = run_script(JOBS["tests"])
        fixture = 'swift() { echo "Test run with 5 tests failed after 1 second with 1 issue."; return "$STATUS"; }\n'
        for status in (0, 1, 23, 134):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as directory:
                result = subprocess.run(["bash", "-e", "-c", fixture + script],
                                        env={**os.environ, "RUNNER_TEMP": directory,
                                             "SWIFTPM_FLAGS": "", "STATUS": str(status)},
                                        capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode == 0, status == 0, result.stderr)
                self.assertIn("Test run with 5 tests failed", result.stdout)
                self.assertTrue((Path(directory) / "swift-test.log").exists())


if __name__ == "__main__":
    unittest.main()
