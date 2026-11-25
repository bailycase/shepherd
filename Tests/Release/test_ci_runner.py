"""Evaluate the native CI runner fence without GitHub or a YAML dependency."""
import hermetic_env  # noqa: F401  (must stay first: scrubs ambient SHEPHERD_*/PI_*)
from pathlib import Path
import re
import unittest

from test_ci_workflow import ACTION, JOBS

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github/workflows"
CI = (WORKFLOWS / "ci.yml").read_text()
RELEASE = (WORKFLOWS / "release.yml").read_text()
RELEASE_BUILD = (WORKFLOWS / "release-build.yml").read_text()


def select(expression, metadata):
    # These fences compare strings and return lowercase labels. GitHub ignores case in
    # string comparisons; normalize their operands, including values used by format().
    expression = re.sub(r"'(?:''|[^'])*'", lambda m: m[0].casefold(), expression)
    expression = re.sub(r"(?:github|vars|inputs|runner|steps|matrix)\.[\w.-]+", lambda m: repr(
        metadata[m[0]].casefold() if isinstance(metadata.get(m[0]), str) else metadata.get(m[0])), expression)
    expression = expression.replace("&&", " and ").replace("||", " or ")
    return eval(" ".join(expression.split()), {"__builtins__": {}, "format": str.format})


def metadata(event="pull_request"):
    ref = "refs/pull/236/merge" if event == "pull_request" else "refs/heads/nightly"
    return {
        "inputs.save-cache": "true",
        "github.event_name": event,
        "github.ref": ref,
        "github.ref_type": "branch",
        "github.event.pull_request.number": 236,
        "github.event.pull_request.head.repo.full_name": "owner/Shepherd",
    }


class CIRunnerTests(unittest.TestCase):
    def test_every_job_runs_on_a_github_hosted_runner_with_no_persistent_runner_path(self):
        job = JOBS["tests"]
        self.assertIn("    runs-on: macos-26\n", job)
        self.assertIn("timeout-minutes: 60", job)
        for name, job in JOBS.items():
            if name != "tests":
                self.assertIn("runs-on: ubuntu-24.04", job)
        for text in (CI, ACTION, RELEASE, RELEASE_BUILD):
            self.assertNotIn("runner.environment", text)
            self.assertNotIn("shepherd-release", text)
            self.assertNotRegex(text, r"(?i)self-?hosted")
            labels = re.findall(r"(?m)^\s+runs-on: (\S+)$", text)
            self.assertTrue(labels or text is ACTION)
            for label in labels:
                self.assertRegex(label, r"^(ubuntu-24\.04|macos-26|xcode-27)$")

    def test_cache_writes_are_pr_scoped_or_trusted_branch_events_only(self):
        save = ACTION.split("- name: Save the hosted build", 1)[1]
        expression = save.split("if: >-\n", 1)[1].split("uses:", 1)[0].strip()
        for hit in ("true", "false", ""):
            for event in ("pull_request", "push", "workflow_dispatch", "schedule",
                          "pull_request_target", "workflow_run", "issue_comment", "repository_dispatch"):
                for ref_type in ("branch", "tag"):
                    with self.subTest(hit=hit, event=event, ref_type=ref_type):
                        data = metadata(event=event)
                        data.update({"steps.cache.outputs.cache-hit": hit, "github.ref_type": ref_type})
                        allowed = hit != "true" and (
                            event == "pull_request" or event in ("push", "workflow_dispatch") and ref_type == "branch")
                        self.assertEqual(bool(select(expression, data)), allowed)
        data = metadata()
        data.update({"steps.cache.outputs.cache-hit": "false", "github.ref": "refs/heads/nightly"})
        self.assertFalse(select(expression, data), "a PR must never write the base branch scope")
        # Fork PRs are safe to save only because GitHub isolates their merge-ref cache.
        data = metadata()
        data.update({"steps.cache.outputs.cache-hit": "false",
                     "github.event.pull_request.head.repo.full_name": "fork/Shepherd"})
        self.assertTrue(select(expression, data))

    def test_only_one_parallel_lane_saves_the_shared_build(self):
        expression = re.search(r"save-cache: \$\{\{(.*?)\}\}", JOBS["tests"]).group(1)
        for lanes in (("selected",), ("thread", "features", "app", "other")):
            writers = [lane for lane in lanes if select(expression, {"matrix.lane": lane})]
            self.assertEqual(len(writers), 1)
        save = ACTION.split("- name: Save the hosted build", 1)[1]
        fence = save.split("if: >-\n", 1)[1].split("uses:", 1)[0].strip()
        data = metadata()
        data.update({"steps.cache.outputs.cache-hit": "false", "inputs.save-cache": "false"})
        self.assertFalse(select(fence, data))


if __name__ == "__main__":
    unittest.main()
