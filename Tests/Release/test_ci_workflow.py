"""Structure rules for .github/workflows/ci.yml and the swift-build action, which the CI helpers rely on.

The workflow is read as text (the repository's tests are stdlib only). Run:
python3 -m unittest discover -s Tests/Release -v
"""
import os
import re
import subprocess
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


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
        self.assertEqual(set(JOBS), {"plan", "release-rules", "extensions", "build", "tests", "ci", "report"})

    def test_no_path_filter_can_stop_ci_from_reporting(self):
        # A workflow filtered out by paths never reports `CI`, so a pull request would wait for it for ever.
        self.assertNotRegex(WORKFLOW, r"(?m)^\s+paths(-ignore)?:")

    def test_the_triggers_are_pushes_pull_requests_the_daily_run_and_manual_runs(self):
        head = WORKFLOW.split("\npermissions:", 1)[0]
        for trigger in ("push:", "pull_request:", "schedule:", "workflow_dispatch:"):
            self.assertIn(f"\n  {trigger}", head)
        self.assertIn("branches: [master]", head)
        self.assertNotIn("branches: [master, nightly]", head)
        self.assertRegex(head, r'cron: "\d+ \d+ \* \* \*"')
        self.assertIn("types: [opened, synchronize, reopened, labeled]", head)

    def test_the_manual_run_takes_a_lane_a_base_and_the_build_switches(self):
        for name in ("lane", "base", "clean", "shared_build", "report"):
            self.assertRegex(WORKFLOW, rf"(?m)^      {name}:\n")
        self.assertIn("options: [auto, fast, full, flake-hunt]", WORKFLOW)
        self.assertIn('options: [auto, "true", "false"]', WORKFLOW)

    def test_every_job_but_the_plan_waits_for_the_plan(self):
        for name, job in JOBS.items():
            if name != "plan":
                self.assertIn("plan", needs(job), name)

    def test_ci_is_the_one_gate_and_it_waits_for_every_job_that_can_fail_a_run(self):
        gate = JOBS["ci"]
        self.assertIn("name: CI", gate)
        self.assertEqual(sorted(needs(gate)), ["build", "extensions", "plan", "release-rules", "tests"])
        self.assertIn("!cancelled()", gate)
        self.assertIn("needs.plan.result != 'skipped'", gate)

    def test_the_gate_passes_for_success_and_skipped_and_fails_for_anything_else(self):
        script = run_script(JOBS["ci"])
        for results, passes in (("success success skipped success success", True),
                                ("success success success skipped skipped", True),
                                ("success failure success success success", False),
                                ("success success success success cancelled", False),
                                ("failure skipped skipped skipped skipped", False)):
            done = subprocess.run(["bash", "-c", script], env={"RESULTS": results, "PATH": os.environ["PATH"]},
                                  capture_output=True, text=True, timeout=10)
            self.assertEqual(done.returncode == 0, passes, results)

    def test_the_report_is_not_part_of_the_gate_and_is_the_only_job_that_may_write_issues(self):
        self.assertNotIn("report", needs(JOBS["ci"]))
        for name, job in JOBS.items():
            self.assertEqual("issues: write" in job, name == "report", name)
        self.assertEqual(WORKFLOW.split("\njobs:", 1)[0].count("issues: write"), 0)
        self.assertIn("report == 'true'", JOBS["report"])

    def test_the_shards_come_from_the_plan_and_run_even_when_the_pull_request_has_no_build_job(self):
        tests = JOBS["tests"]
        self.assertIn("fromJSON(needs.plan.outputs.shards)", tests)
        self.assertIn("!cancelled()", tests)
        self.assertIn("needs.build.result == 'skipped'", tests)
        self.assertIn("needs.plan.outputs.swift == 'true'", tests)
        self.assertIn("fail-fast: false", tests)

    def test_the_build_job_runs_only_when_swift_runs_and_the_plan_wants_a_shared_build(self):
        build = JOBS["build"]
        self.assertIn("needs.plan.outputs.swift == 'true'", build)
        self.assertIn("needs.plan.outputs.shared_build == 'true'", build)
        self.assertIn('save: "true"', build)

    def test_a_clean_build_writes_the_days_marker_that_the_plan_looks_up(self):
        self.assertIn("ci-clean-build-$(date -u +%Y%m%d)", JOBS["plan"])
        self.assertIn("lookup-only: true", JOBS["plan"])
        self.assertIn("github.event_name != 'pull_request'", JOBS["plan"])
        build = JOBS["build"]
        self.assertIn("ci-clean-build-$(date -u +%Y%m%d)", build)
        self.assertIn("actions/cache/save@v4", build)
        self.assertIn("--clean-due", JOBS["plan"])

    def test_hosted_shards_save_only_when_named_and_local_shards_always_save(self):
        tests = JOBS["tests"]
        expression = re.search(r"save: \$\{\{ (.*?) \}\}", tests).group(1)
        self.assertEqual(expression, "matrix.shard.save || runner.environment == 'self-hosted'")
        for save in (False, True):
            for environment in ("github-hosted", "self-hosted"):
                with self.subTest(save=save, environment=environment):
                    native = expression.replace("matrix.shard.save", repr(save)).replace("runner.environment", repr(environment))
                    actual = eval(native.replace("||", " or "), {"__builtins__": {}})
                    self.assertEqual(actual, save or environment == "self-hosted")
        self.assertNotIn('save: "true"', tests)
        # Saving is inside the build action, before the shard runs any tests; exact
        # cache hits skip both compilation and another upload.
        self.assertLess(tests.index("uses: ./.github/actions/swift-build"), tests.index("- name: Run tests"))
        self.assertIn("if: inputs.save == 'true' && steps.build.outputs.cache-hit != 'true'", ACTION)

    def test_the_plan_outputs_every_value_the_other_jobs_read(self):
        declared = set(re.findall(r"^      (\w+): \$\{\{ steps\.plan\.outputs\.\w+ \}\}", JOBS["plan"], re.M))
        used = set(re.findall(r"needs\.plan\.outputs\.(\w+)", WORKFLOW))
        self.assertEqual(used - declared, set())
        # and the script writes each of them
        script = read("scripts", "ci_impact.py")
        for name in declared:
            self.assertIn(f'"{name}"', script, name)

    def test_the_shard_job_runs_the_helper_with_the_plans_selection_and_repeat(self):
        step = JOBS["tests"]
        self.assertIn("scripts/ci_run_tests.py swift", step)
        self.assertIn('--shard "${{ matrix.shard.id }}"', step)
        self.assertIn('--selection "$SELECTION"', step)
        self.assertIn('--repeat "${{ needs.plan.outputs.repeat }}"', step)

    def test_the_extension_tests_run_through_the_helper_that_retries_a_failed_test_once(self):
        job = JOBS["extensions"]
        self.assertIn("scripts/pi-engine-pin.json", job)
        self.assertIn("--ignore-scripts", job)
        self.assertIn("python3 scripts/ci_run_tests.py node", job)
        self.assertNotIn("continue-on-error", job)
        self.assertTrue('["node", "--test"' in read("scripts", "ci_run_tests.py"))

    def test_results_are_uploaded_under_the_names_the_report_downloads(self):
        names = re.findall(r"name: (ci-results-[\w${}. -]+)", WORKFLOW)
        self.assertEqual(len(names), 2)
        self.assertIn("pattern: ci-results-*", JOBS["report"])
        self.assertIn("ci-results-swift-${{ matrix.shard.slug }}", WORKFLOW)

    def test_every_script_the_workflow_runs_exists(self):
        for script in set(re.findall(r"scripts/(ci_\w+\.py)", WORKFLOW)):
            self.assertTrue(os.path.exists(os.path.join(ROOT, "scripts", script)), script)

    def test_a_label_other_than_full_ci_cancels_nothing_and_runs_nothing(self):
        self.assertIn("github.event.label.name != 'full-ci'", JOBS["plan"])
        self.assertIn("-label", WORKFLOW.split("\nconcurrency:", 1)[1].split("\ndefaults:", 1)[0])

    def test_the_scheduled_run_tests_master_not_nightly(self):
        self.assertIn("github.event_name == 'schedule' && 'master'", JOBS["plan"])
        self.assertIn("ref: ${{ needs.plan.outputs.checkout_ref }}", JOBS["tests"])

    def test_nightly_release_skips_tests_but_other_releases_keep_them(self):
        with open(os.path.join(ROOT, ".github", "workflows", "release.yml"), encoding="utf-8") as file:
            workflow = file.read()
        step = workflow.split("      - name: Test the release rules\n", 1)[1].split("      - name:", 1)[0]
        self.assertIn("if: github.ref != 'refs/heads/nightly'", step)
        self.assertIn("python3 -m unittest discover -s Tests/Release -v", step)

    def test_no_job_survives_its_runs_cancellation(self):
        # A job-level `always()` runs on after the run is cancelled (macOS shards kept running for a
        # superseded pull request run); `!cancelled()` is the status function that does not.
        for name, job in JOBS.items():
            self.assertNotRegex(job, r"(?m)^    if: .*always\(\)", name)

    def test_a_newer_run_cancels_the_running_one_with_a_literal_true(self):
        # The group cancels what runs in it; the jobs that outlive the cancellation are the ones with
        # `always()` (test_no_job_survives_its_runs_cancellation).
        block = WORKFLOW.split("\nconcurrency:", 1)[1].split("\ndefaults:", 1)[0]
        self.assertRegex(block, r"(?m)^  cancel-in-progress: true$")

    def test_the_old_shards_and_their_regexes_are_gone(self):
        for old in ("W_RE", "R_RE", "A_RE", "matrix.shard == 'C'", "warm:"):
            self.assertNotIn(old, WORKFLOW)


class SwiftBuildActionTests(unittest.TestCase):
    def test_cache_entries_are_named_for_the_commit_built_not_github_sha(self):
        self.assertNotIn("github.sha", ACTION.replace("not github.sha", ""))
        self.assertEqual(ACTION.count("steps.swift.outputs.sha"), 2)
        self.assertIn("git rev-parse HEAD", ACTION)

    def test_a_shard_that_restores_its_own_commits_build_does_not_build_again(self):
        self.assertIn("EXACT: ${{ steps.build.outputs.cache-hit }}", ACTION)
        self.assertIn('if [ "$EXACT" = true ]; then', ACTION)
        self.assertIn('if [ -n "$RESTORED" ] && [ "$EXACT" != true ]; then', ACTION, "the stale-target workaround is for other commits' builds")

    def test_the_stale_link_recovery_is_still_there(self):
        self.assertIn("scripts/ci_stale_link.py", ACTION)
        self.assertIn("rebuilding from scratch", ACTION)
        self.assertIn("swift-version-*.txt", ACTION)


if __name__ == "__main__":
    unittest.main()
