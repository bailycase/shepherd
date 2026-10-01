"""Tests for scripts/ci_report.py: the one tracking issue for the full lane's health.

The GitHub calls go through a fake, so the whole flow (create, comment once per run, reopen,
recover, count flaky tests across runs) is checked without a network. Run:
python3 -m unittest discover -s Tests/Release -v
"""
import json
import os
import shutil
import sys
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import ci_report  # noqa: E402


class FakeGh:
    """An issue tracker with at most one issue, behind the calls ci_report makes."""

    def __init__(self, issue=None, comments=()):
        self.issue = issue
        self.comments = list(comments)
        self.calls = []

    def __call__(self, *args, stdin=None):
        self.calls.append((args, stdin))
        verb = args[:2]
        if verb == ("issue", "list"):
            return json.dumps([self.issue] if self.issue else [])
        if verb == ("label", "create"):
            return ""
        if verb == ("issue", "create"):
            self.issue = {"number": 7, "state": "OPEN", "title": ci_report.TITLE, "body": stdin}
            return "https://github.com/o/r/issues/7\n"
        if verb == ("issue", "edit"):
            self.issue["body"] = stdin
            return ""
        if verb == ("issue", "reopen"):
            self.issue["state"] = "OPEN"
            return ""
        if verb == ("issue", "view"):
            return "\n".join(self.comments)
        if verb == ("issue", "comment"):
            self.comments.append(stdin)
            return ""
        raise AssertionError(f"unexpected call {args}")

    def verbs(self):
        return [" ".join(a[:2]) for a, _ in self.calls]


def write_results(folder, shard, failures=(), flaky=(), errors=()):
    path = os.path.join(folder, f"ci-results-swift-{shard}")
    os.makedirs(path, exist_ok=True)
    with open(os.path.join(path, "failures.json"), "w", encoding="utf-8") as f:
        json.dump({"kind": "swift", "shard": shard, "tests": list(failures), "errors": list(errors)}, f)
    with open(os.path.join(path, "flaky.json"), "w", encoding="utf-8") as f:
        json.dump({"kind": "swift", "shard": shard, "tests": list(flaky)}, f)


FAILURE = {"id": "M.S/t()", "file": "Tests/M/S.swift", "line": 12, "message": "Expectation failed: a | b"}
FLAKY = {"id": "M.S/u()", "file": "Tests/M/S.swift", "line": 30, "message": "timed out", "failed": 1, "passes": 2}


class ReportTests(unittest.TestCase):
    def setUp(self):
        self.results = tempfile.mkdtemp()
        self.addCleanup(lambda: shutil.rmtree(self.results, ignore_errors=True))

    def report(self, fake, result, run="100", sha="a" * 40, ref="nightly", today="2026-10-01"):
        return ci_report.report(results=self.results, result=result, repo="o/r", run_id=run, sha=sha, ref=ref,
                                event="push", today=today, call=fake)

    def test_a_green_run_with_nothing_flaky_and_no_issue_touches_nothing(self):
        write_results(self.results, "1of4")
        fake = FakeGh()
        self.report(fake, "success")
        self.assertEqual(fake.verbs(), ["issue list"])

    def test_a_red_run_creates_the_issue_once_with_a_comment_listing_the_failures(self):
        write_results(self.results, "1of4", failures=[FAILURE])
        write_results(self.results, "2of4", errors=["the shard ran no tests"])
        fake = FakeGh()
        self.report(fake, "failure")
        self.assertEqual(fake.verbs(), ["issue list", "label create", "issue create", "issue view", "issue comment"])
        self.assertIn("`M.S/t()`", fake.comments[0])
        self.assertIn("Tests/M/S.swift:12", fake.comments[0])
        self.assertIn("a \\| b", fake.comments[0])
        self.assertIn("swift 2of4: the shard ran no tests", fake.comments[0])
        self.assertIn("Last red run", fake.issue["body"])
        self.assertIn("/actions/runs/100", fake.comments[0])

    def test_the_same_run_is_never_commented_twice(self):
        write_results(self.results, "1of4", failures=[FAILURE])
        fake = FakeGh()
        self.report(fake, "failure")
        self.report(fake, "failure")
        self.assertEqual(len(fake.comments), 1)

    def test_a_new_red_run_adds_a_comment_to_the_same_issue_and_reopens_it_if_closed(self):
        write_results(self.results, "1of4", failures=[FAILURE])
        fake = FakeGh()
        self.report(fake, "failure", run="100")
        fake.issue["state"] = "CLOSED"
        self.report(fake, "failure", run="101")
        self.assertEqual(len(fake.comments), 2)
        self.assertEqual(fake.issue["state"], "OPEN")
        self.assertEqual(fake.verbs().count("issue create"), 1, "never a second issue")

    def test_a_green_run_after_a_red_one_says_so_once_and_leaves_the_issue_open(self):
        write_results(self.results, "1of4", failures=[FAILURE])
        fake = FakeGh()
        self.report(fake, "failure", run="100")
        for shard in ("1of4",):
            write_results(self.results, shard)
        self.report(fake, "success", run="101", sha="b" * 40)
        self.assertIn("green** again", fake.comments[-1])
        self.report(fake, "success", run="102", sha="c" * 40)
        self.assertEqual(len(fake.comments), 2, "a second green run is quiet")
        self.assertEqual(fake.issue["state"], "OPEN")
        self.assertNotIn("issue close", fake.verbs())

    def test_flaky_tests_are_counted_across_runs_in_the_body(self):
        write_results(self.results, "1of4", flaky=[FLAKY])
        fake = FakeGh()
        self.report(fake, "success", run="100", today="2026-10-01")
        self.report(fake, "success", run="101", today="2026-10-02")
        state = ci_report.parse_state(fake.issue["body"])
        entry = state["flaky"]["M.S/u()"]
        self.assertEqual((entry["failed"], entry["passes"], entry["runs"]), (2, 4, 2))
        self.assertEqual((entry["first"], entry["last"]), ("2026-10-01", "2026-10-02"))
        self.assertIn("| `M.S/u()` | 2 / 4 | 2 | 2026-10-02 | Tests/M/S.swift:30 | timed out |", fake.issue["body"])
        self.assertEqual(fake.comments, [], "flaky tests alone do not comment")

    def test_the_flake_hunt_counts_failed_passes_of_three(self):
        hunted = dict(FLAKY, failed=1, passes=3)
        write_results(self.results, "3of4", flaky=[hunted])
        fake = FakeGh()
        self.report(fake, "success")
        entry = ci_report.parse_state(fake.issue["body"])["flaky"]["M.S/u()"]
        self.assertEqual((entry["failed"], entry["passes"]), (1, 3))

    def test_a_cancelled_run_reports_nothing(self):
        fake = FakeGh()
        self.report(fake, "cancelled")
        self.assertEqual(fake.calls, [])

    def test_a_red_run_without_a_failing_test_still_says_a_job_failed(self):
        write_results(self.results, "1of4")
        fake = FakeGh()
        self.report(fake, "failure")
        self.assertIn("a job failed before or after the tests", fake.comments[0])

    def test_the_state_survives_a_body_with_no_block_or_a_broken_one(self):
        self.assertEqual(ci_report.parse_state("hello"), {"flaky": {}, "last_red": None})
        self.assertEqual(ci_report.parse_state("<!-- ci-health-state {oops -->"), {"flaky": {}, "last_red": None})

    def test_a_long_flaky_list_shows_the_worst_in_the_table_and_keeps_all_in_the_state(self):
        state = {"flaky": {f"M.S/t{i}()": {"failed": i, "passes": 10, "runs": 1, "first": "d", "last": "d", "file": "f",
                                           "line": 1, "message": ""} for i in range(60)}, "last_red": None}
        body = ci_report.render_body(state, "o/r")
        self.assertIn("`M.S/t59()`", body)
        self.assertNotIn("| `M.S/t3()` |", body)
        self.assertIn("and 20 more", body)
        self.assertEqual(len(ci_report.parse_state(body)["flaky"]), 60)


if __name__ == "__main__":
    unittest.main()
