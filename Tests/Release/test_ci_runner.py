"""Evaluate the native CI runner fence without GitHub or a YAML dependency."""
import re
import unittest

from test_ci_workflow import JOBS


def runner_expression(job):
    return re.search(r"    runs-on: >-\n\s+\$\{\{(.*?)\}\}", job, re.S).group(1).strip()


def select(expression, metadata):
    # GitHub's && / || return operands, just like Python's and / or.
    expression = re.sub(r"github\.[\w.]+", lambda m: repr(metadata.get(m[0])), expression)
    expression = expression.replace("&&", " and ").replace("||", " or ")
    return eval(" ".join(expression.split()), {"__builtins__": {}, "format": str.format})


def metadata(event="pull_request", actor="19316389", author=19316389):
    ref = "refs/pull/236/merge" if event == "pull_request" else "refs/heads/nightly"
    return {
        "github.event_name": event,
        "github.actor_id": actor,
        "github.actor": "maintainer",
        "github.triggering_actor": "maintainer",
        "github.repository": "owner/Shepherd",
        "github.ref": ref,
        "github.ref_type": "branch",
        "github.event.inputs.diagnostics": "none",
        "github.workflow_ref": f"owner/Shepherd/.github/workflows/ci.yml@{ref}",
        "github.event.pull_request.number": 236,
        "github.event.pull_request.head.repo.full_name": "owner/Shepherd",
        "github.event.pull_request.user.id": author,
    }


class CIRunnerTests(unittest.TestCase):
    def test_the_mac_job_uses_the_native_fence_and_masks_before_checkout(self):
        job = JOBS["tests"]
        self.assertRegex(job, r"(?m)^    env:\n(?:      .*\n)*      SELFHOSTED_LOG_MASK: \$\{\{ secrets.SELFHOSTED_HOSTNAME \}\}")
        self.assertLess(job.index("SELFHOSTED_LOG_MASK:"), job.index("    steps:"))
        self.assertNotIn("needs.plan.outputs", runner_expression(job))
        self.assertNotIn("labels", runner_expression(job))
        self.assertIn("timeout-minutes: 60", job)
        for name, job in JOBS.items():
            if name != "tests":
                self.assertIn("runs-on: ubuntu-latest", job)

    def test_only_same_repo_maintainer_pull_requests_select_local(self):
        expression = runner_expression(JOBS["tests"])
        for actor in ("19316389", "3370624"):
            for author in (19316389, 3370624):
                self.assertEqual(select(expression, metadata(actor=actor, author=author)), "shepherd-release")
        # Usernames confer no trust; an ID-preserving rename works, a reused name does not.
        renamed = metadata()
        renamed.update({"github.actor": "renamed", "github.triggering_actor": "renamed"})
        self.assertEqual(select(expression, renamed), "shepherd-release")

    def test_only_explicit_maintainer_branch_diagnostics_select_local_on_dispatch(self):
        expression = runner_expression(JOBS["tests"])
        for actor in ("19316389", "3370624"):
            data = metadata(event="workflow_dispatch", actor=actor)
            self.assertEqual(select(expression, data), "macos-26")
            data["github.event.inputs.diagnostics"] = "ui"
            self.assertEqual(select(expression, data), "shepherd-release")
            for change in ({"github.actor_id": "999"}, {"github.triggering_actor": "other"},
                           {"github.ref_type": "tag"}, {"github.event.inputs.diagnostics": "arbitrary"},
                           {"github.workflow_ref": "fork/Shepherd/.github/workflows/ci.yml@refs/heads/nightly"},
                           {"github.workflow_ref": "owner/Shepherd/.github/workflows/other.yml@refs/heads/nightly"}):
                with self.subTest(actor=actor, change=change):
                    rejected = dict(data, **change)
                    self.assertEqual(select(expression, rejected), "macos-26")

    def test_each_failed_trust_boundary_stays_hosted(self):
        expression = runner_expression(JOBS["tests"])
        changes = [
            {"github.actor_id": "999"},
            {"github.actor_id": None},
            {"github.triggering_actor": "other-maintainer"},
            {"github.triggering_actor": "unknown"},
            {"github.workflow_ref": "fork/Shepherd/.github/workflows/ci.yml@refs/pull/236/merge"},
            {"github.workflow_ref": "owner/Shepherd/.github/workflows/other.yml@refs/pull/236/merge"},
            {"github.workflow_ref": "owner/Shepherd/.github/workflows/ci.yml@refs/heads/feature"},
            {"github.event_name": "workflow_dispatch"},
            {"github.event_name": "schedule"},
            {"github.event_name": "pull_request_target"},
            {"github.event_name": "push", "github.ref": "refs/heads/nightly",
             "github.workflow_ref": "owner/Shepherd/.github/workflows/ci.yml@refs/heads/nightly"},
            {"github.event_name": "push", "github.ref": "refs/heads/master",
             "github.workflow_ref": "owner/Shepherd/.github/workflows/ci.yml@refs/heads/master"},
            {"github.event.pull_request.head.repo.full_name": "fork/Shepherd"},
            {"github.event.pull_request.head.repo.full_name": None},
            {"github.event.pull_request.user.id": 999},
            {"github.event.pull_request.user.id": None},
            {"github.ref": "refs/heads/feature", "github.workflow_ref": "owner/Shepherd/.github/workflows/ci.yml@refs/heads/feature"},
        ]
        for change in changes:
            with self.subTest(change=change):
                data = metadata()
                data.update(change)
                self.assertEqual(select(expression, data), "macos-26")


if __name__ == "__main__":
    unittest.main()
