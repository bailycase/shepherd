"""Tests for scripts/ci_run_tests.py: running a shard, retrying failed tests once, the watchdog.

A fake runner stands in for `swift test` and node and writes the logs a run would print, so every
branch of the retry rules runs in milliseconds. Run: python3 -m unittest discover -s Tests/Release -v
"""
import contextlib
import io
import json
import os
import shutil
import sys
import tempfile
import time
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import ci_run_tests as rt  # noqa: E402
import ci_shards  # noqa: E402

MODULE = "ShepherdAppIntegrationTests"
IDS = [f"{MODULE}.ThreadTailFlowTests/tail{i}()" for i in range(4)] + [
    f"{MODULE}.QueueStackIntegrationTests/order{i}()" for i in range(3)] + [
    "ShepherdCoreUnitTests.AgentStatusTests/raw()"]
SUITES = ci_shards.suites_of(IDS)


def swift_log(tests, failing=(), known=0, suites=3):
    """What `swift test` prints for a run of `tests` tests in which these (name, file, line) tests fail."""
    lines = ['✔ Suite "Thread tail in the app\'s layout" passed after 4.5 seconds.',
             '✔ Suite "Queue stack" passed after 2.0 seconds.']
    for name, file, line in failing:
        lines.append(f"✘ Test {name} recorded an issue at {file}:{line}:9: Expectation failed: (a → 1) == (b → 2)")
        lines.append(f"✘ Test {name} failed after 0.1 seconds with 1 issue.")
    issues = len(failing) + known
    if failing:
        extra = f" with {issues} issues" + (f" (including {known} known issues)" if known else "")
        lines.append(f"✘ Test run with {tests} tests in {suites} suites failed after 7.0 seconds{extra}.")
    else:
        lines.append(f"✔ Test run with {tests} tests in {suites} suites passed after 7.0 seconds.")
    return "\n".join(lines) + "\n"


class FakeRunner(rt.Runner):
    def __init__(self, ids, runs):
        self.ids, self.runs, self.commands = ids, list(runs), []

    def capture(self, cmd, env=None):
        self.commands.append(cmd)
        return 0, "\n".join(self.ids) + "\nwarning: /Users/runner/work/.build/x is missing\n/usr/bin/foo bar\n"

    def stream(self, cmd, log_path, budget, env=None):
        self.commands.append(cmd)
        self.budgets = getattr(self, "budgets", []) + [budget]
        code, text, fired = self.runs.pop(0)
        with open(log_path, "w", encoding="utf-8") as f:
            f.write(text)
        return code, fired


class ShardCase(unittest.TestCase):
    """Helpers for running a fake shard; holds no tests of its own."""

    def setUp(self):
        self.out = tempfile.mkdtemp()
        self.addCleanup(lambda: shutil.rmtree(self.out, ignore_errors=True))
        self.times = os.path.join(self.out, "times.json")
        ci_shards.write_times(self.times, {s: 5.0 for s in SUITES})
        self.env = {"SWIFTPM_FLAGS": "--force-resolved-versions --disable-index-store"}

    def run_shard(self, runs, shard="1/1", repeat=1, selection='{"all":true}', ids=IDS):
        runner = FakeRunner(ids, runs)
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            code = rt.main(["swift", "--shard", shard, "--selection", selection, "--repeat", str(repeat),
                            "--out", self.out, "--times", self.times, "--root", ROOT], runner=runner, env=self.env)
        return code, runner, stdout.getvalue()

    def read(self, name):
        with open(os.path.join(self.out, name), encoding="utf-8") as f:
            return json.load(f)



class SwiftShardTests(ShardCase):
    def test_a_passing_shard_runs_its_suites_serially_with_the_package_flags(self):
        code, runner, out = self.run_shard([(0, swift_log(len(IDS)), False)])
        self.assertEqual(code, 0)
        test_run = runner.commands[1]
        self.assertEqual(test_run[:3], ["swift", "test", "--skip-build"])
        self.assertIn("--no-parallel", test_run)
        self.assertIn("--force-resolved-versions", test_run)
        self.assertEqual(test_run[test_run.index("--filter") + 1].split("\\.")[0], "^ShepherdAppIntegrationTests")
        self.assertEqual(self.read("failures.json")["tests"], [])
        self.assertEqual(self.read("flaky.json")["tests"], [])
        times = self.read("suite-times.json")["suites"]
        self.assertEqual(times[f"{MODULE}.ThreadTailFlowTests"], 4.5)

    def test_each_shard_runs_only_its_own_suites_and_the_counts_must_match(self):
        groups = ci_shards.assign(list(SUITES), ci_shards.read_times(self.times), 2)
        mine = groups[1]
        count = sum(SUITES[s] for s in mine)
        code, runner, _ = self.run_shard([(0, swift_log(count), False)], shard="2/2")
        self.assertEqual(code, 0)
        filters = [runner.commands[1][i + 1] for i, a in enumerate(runner.commands[1]) if a == "--filter"]
        for suite in mine:
            self.assertTrue(any(suite.split(".", 1)[1] in f for f in filters), suite)

    def test_a_shard_that_ran_a_different_number_of_tests_fails_loudly(self):
        code, _, out = self.run_shard([(0, swift_log(len(IDS) - 1), False)])
        self.assertEqual(code, 1)
        self.assertIn(f"ran {len(IDS) - 1} tests but was given {len(IDS)}", out)
        self.assertIn("::error", out)

    def test_a_shard_that_ran_nothing_fails(self):
        code, _, out = self.run_shard([(0, "◇ nothing\n✔ Test run with 0 tests in 0 suites passed after 0.1 seconds.\n", False)],
                                      selection='{"all":true}')
        self.assertEqual(code, 1)
        self.assertIn("given", out)

    def test_a_selection_that_matches_no_suite_fails(self):
        code, _, out = self.run_shard([], selection='{"all":false,"unit":false,"regexes":["^Nope"],"smoke":[],"suites":[]}')
        self.assertEqual(code, 1)
        self.assertIn("matches no suite", out)

    def test_a_shard_with_no_suites_fails(self):
        code, _, out = self.run_shard([], shard="9/9")
        self.assertEqual(code, 1)
        self.assertIn("was given no suites", out)

    def test_a_failed_test_that_passes_on_retry_is_flaky_and_the_shard_passes(self):
        failing = [("tail1()", "ThreadTailFlowTests.swift", 454)]
        code, runner, out = self.run_shard([
            (1, swift_log(len(IDS), failing), False),
            (0, swift_log(1), False),
        ])
        self.assertEqual(code, 0)
        retry = runner.commands[2]
        self.assertEqual(retry[retry.index("--filter") + 1], "^" + f"{MODULE}.ThreadTailFlowTests/tail1()".replace(".", "\\.").replace("(", "\\(").replace(")", "\\)"))
        self.assertIn("--no-parallel", retry)
        flaky = self.read("flaky.json")["tests"]
        self.assertEqual([t["id"] for t in flaky], [f"{MODULE}.ThreadTailFlowTests/tail1()"])
        self.assertEqual(flaky[0]["file"], "Tests/ShepherdAppIntegrationTests/ThreadTailFlowTests.swift")
        self.assertEqual(self.read("failures.json")["tests"], [])
        self.assertIn("::warning file=Tests/ShepherdAppIntegrationTests/ThreadTailFlowTests.swift,line=454", out)
        self.assertIn("Flaky test", out)

    def test_a_failed_test_that_fails_again_fails_the_shard(self):
        failing = [("tail1()", "ThreadTailFlowTests.swift", 454)]
        code, _, out = self.run_shard([
            (1, swift_log(len(IDS), failing), False),
            (1, swift_log(1, failing), False),
        ])
        self.assertEqual(code, 1)
        failures = self.read("failures.json")["tests"]
        self.assertEqual([t["id"] for t in failures], [f"{MODULE}.ThreadTailFlowTests/tail1()"])
        self.assertEqual(self.read("flaky.json")["tests"], [])
        self.assertIn("::error file=Tests/ShepherdAppIntegrationTests/ThreadTailFlowTests.swift,line=454,col=9,title=Test failed", out)

    def test_of_two_failures_the_one_that_passes_on_retry_is_flaky_and_the_other_fails(self):
        failing = [("tail1()", "ThreadTailFlowTests.swift", 454), ("order2()", "QueueStackTests.swift", 88)]
        code, _, _ = self.run_shard([
            (1, swift_log(len(IDS), failing), False),
            (1, swift_log(2, failing[:1]), False),
        ])
        self.assertEqual(code, 1)
        self.assertEqual([t["id"] for t in self.read("failures.json")["tests"]], [f"{MODULE}.ThreadTailFlowTests/tail1()"])
        self.assertEqual([t["id"] for t in self.read("flaky.json")["tests"]], [f"{MODULE}.QueueStackIntegrationTests/order2()"])

    def test_more_than_a_handful_of_failures_is_not_a_flake_and_is_not_retried(self):
        ids = [f"{MODULE}.ManyTests/t{i}()" for i in range(9)]
        failing = [(f"t{i}()", "ManyTests.swift", 10 + i) for i in range(9)]
        ci_shards.write_times(self.times, {f"{MODULE}.ManyTests": 5.0})
        code, runner, out = self.run_shard([(1, swift_log(9, failing, suites=1), False)], ids=ids)
        self.assertEqual(code, 1)
        self.assertEqual(len([c for c in runner.commands if c[:2] == ["swift", "test"] and "list" not in c]), 1)
        self.assertIn("not a flake", out)

    def test_a_crash_with_no_summary_is_not_retried(self):
        code, runner, out = self.run_shard([(139, "◇ Test tail1() started.\nFatal error: boom\n", False)])
        self.assertEqual(code, 1)
        self.assertEqual(len(runner.runs), 0)
        self.assertEqual(len([c for c in runner.commands if "--filter" in c]), 1)
        self.assertIn("without a summary line", out)

    def test_a_hung_run_ended_by_the_watchdog_is_not_retried(self):
        code, runner, out = self.run_shard([(137, "◇ Test tail1() started.\n", True)])
        self.assertEqual(code, 1)
        self.assertIn("watchdog", out)
        self.assertEqual(runner.runs, [])

    def test_a_failure_the_list_does_not_hold_is_not_retried_because_something_else_failed(self):
        failing = [("customDisplayName", "ThreadTailFlowTests.swift", 454)]
        code, runner, out = self.run_shard([(1, swift_log(len(IDS), failing), False)])
        self.assertEqual(code, 1)
        self.assertIn("attributed", out)
        self.assertEqual(len([c for c in runner.commands if "--filter" in c]), 1)

    def test_a_retry_that_crashes_fails_the_shard_and_keeps_the_first_failures(self):
        failing = [("tail1()", "ThreadTailFlowTests.swift", 454)]
        code, _, out = self.run_shard([(1, swift_log(len(IDS), failing), False), (139, "Fatal error\n", False)])
        self.assertEqual(code, 1)
        self.assertEqual(len(self.read("failures.json")["tests"]), 1)
        self.assertIn("the retry did not finish", out)

    def test_known_issues_alone_do_not_fail_a_run_that_exits_zero(self):
        log = swift_log(len(IDS)).replace("passed after 7.0 seconds.", "passed after 7.0 seconds with 3 known issues.")
        code, _, _ = self.run_shard([(0, log, False)])
        self.assertEqual(code, 0)

    def test_the_summary_lists_failures_flaky_tests_and_suite_times(self):
        target = os.path.join(self.out, "summary.md")
        self.env["GITHUB_STEP_SUMMARY"] = target
        os.environ["GITHUB_STEP_SUMMARY"] = target
        self.addCleanup(lambda: os.environ.pop("GITHUB_STEP_SUMMARY", None))
        failing = [("tail1()", "ThreadTailFlowTests.swift", 454)]
        self.run_shard([(1, swift_log(len(IDS), failing), False), (1, swift_log(1, failing), False)])
        with open(target, encoding="utf-8") as f:
            text = f.read()
        self.assertIn("Swift tests, shard 1/1: FAILED", text)
        self.assertIn("**Failed tests**", text)
        self.assertIn("Tests/ShepherdAppIntegrationTests/ThreadTailFlowTests.swift:454", text)
        self.assertIn("Expectation failed", text)

    def test_the_budget_is_two_and_a_half_times_the_shard_with_a_floor(self):
        self.assertEqual(rt.budget_for(["a"], {"a": 100.0}), 8 * 60)
        self.assertEqual(rt.budget_for(["a"], {"a": 400.0}), 1000.0)
        self.assertEqual(rt.budget_for(["a"], {"a": 400.0}, passes=3), 3000.0)
        code, runner, _ = self.run_shard([(0, swift_log(len(IDS)), False)])
        self.assertEqual(runner.budgets[0], 8 * 60)

    def test_the_sharding_check_runs_against_the_selected_suites_of_the_fast_lane(self):
        selection = json.dumps({"all": False, "unit": True, "regexes": [], "smoke": [f"{MODULE}.QueueStackIntegrationTests"], "suites": []})
        count = SUITES["ShepherdCoreUnitTests.AgentStatusTests"] + SUITES[f"{MODULE}.QueueStackIntegrationTests"]
        code, runner, _ = self.run_shard([(0, swift_log(count), False)], selection=selection)
        self.assertEqual(code, 0)


class FlakeHuntTests(ShardCase):
    def test_a_test_that_fails_in_some_passes_is_flaky_and_the_shard_passes(self):
        failing = [("tail1()", "ThreadTailFlowTests.swift", 454)]
        code, runner, out = self.run_shard([
            (0, swift_log(len(IDS)), False),
            (1, swift_log(len(IDS), failing), False),
            (0, swift_log(len(IDS)), False),
        ], repeat=3)
        self.assertEqual(code, 0)
        flaky = self.read("flaky.json")["tests"]
        self.assertEqual([(t["id"], t["failed"], t["passes"]) for t in flaky], [(f"{MODULE}.ThreadTailFlowTests/tail1()", 1, 3)])
        self.assertEqual(len([c for c in runner.commands if "--filter" in c]), 3)
        self.assertTrue(os.path.exists(os.path.join(self.out, "swift-test-pass3.log")))
        self.assertIn("failed 1 of 3 passes", out)

    def test_a_test_that_fails_in_every_pass_fails_the_shard(self):
        failing = [("tail1()", "ThreadTailFlowTests.swift", 454)]
        code, _, _ = self.run_shard([(1, swift_log(len(IDS), failing), False)] * 3, repeat=3)
        self.assertEqual(code, 1)
        self.assertEqual(len(self.read("failures.json")["tests"]), 1)

    def test_a_pass_that_crashes_fails_the_shard_even_when_the_others_pass(self):
        code, _, out = self.run_shard([
            (0, swift_log(len(IDS)), False), (139, "Fatal error\n", False), (0, swift_log(len(IDS)), False)], repeat=3)
        self.assertEqual(code, 1)
        self.assertIn("pass 2:", out)


NODE_FAILED = """\
✖ lifecycle: parallel (20401.97ms)
ℹ tests 254
ℹ pass 253
ℹ fail 1
✖ failing tests:

test at Tests/Extensions/native-children.test.mjs:312:1
✖ lifecycle: parallel (20401.97ms)
  AssertionError [ERR_ASSERTION]: boom
"""
NODE_PASSED = "✔ lifecycle: parallel (400.97ms)\nℹ tests 1\nℹ pass 1\nℹ fail 0\n"


class NodeTests(unittest.TestCase):
    def setUp(self):
        self.out = tempfile.mkdtemp()
        self.addCleanup(lambda: shutil.rmtree(self.out, ignore_errors=True))

    def run_node(self, runs):
        runner = FakeRunner([], runs)
        with contextlib.redirect_stdout(io.StringIO()) as stdout:
            code = rt.main(["node", "--out", self.out, "--root", ROOT], runner=runner, env={})
        return code, runner, stdout.getvalue()

    def test_a_passing_run_passes(self):
        code, runner, _ = self.run_node([(0, "ℹ tests 10\nℹ pass 10\nℹ fail 0\n", False)])
        self.assertEqual(code, 0)
        self.assertEqual(runner.commands[0][:3], ["node", "--test", "--test-reporter=spec"])
        self.assertTrue(runner.commands[0][-1].endswith(".test.mjs"))

    def test_a_failing_test_is_retried_by_name_in_its_file_and_is_flaky_when_it_passes(self):
        code, runner, out = self.run_node([(1, NODE_FAILED, False), (0, NODE_PASSED, False)])
        self.assertEqual(code, 0)
        retry = runner.commands[1]
        self.assertIn("--test-name-pattern=^(?:lifecycle: parallel)$", retry)
        self.assertEqual(retry[-1], "Tests/Extensions/native-children.test.mjs")
        self.assertIn("::warning file=Tests/Extensions/native-children.test.mjs,line=312", out)
        with open(os.path.join(self.out, "flaky.json"), encoding="utf-8") as f:
            self.assertEqual(json.load(f)["tests"][0]["id"], "lifecycle: parallel")

    def test_a_failing_test_that_fails_again_fails(self):
        code, _, out = self.run_node([(1, NODE_FAILED, False), (1, NODE_FAILED, False)])
        self.assertEqual(code, 1)
        self.assertIn("::error file=Tests/Extensions/native-children.test.mjs,line=312", out)

    def test_a_crash_with_unparsed_failures_is_not_retried(self):
        code, runner, _ = self.run_node([(1, "ℹ tests 10\nℹ pass 5\nℹ fail 5\n", False)])
        self.assertEqual(code, 1)
        self.assertEqual(runner.runs, [])


class WatchdogTests(unittest.TestCase):
    def test_the_descendants_of_a_process_come_from_the_process_table(self):
        table = "  1     0 /sbin/launchd\n 10     1 swift test\n 11    10 swiftpm-testing-helper --foo\n 12    11 /bin/sh -c x\n 99     1 other\n"
        self.assertEqual(rt.descendants(table, 10), [(11, "swiftpm-testing-helper --foo"), (12, "/bin/sh -c x")])

    def test_a_run_streams_its_output_to_the_log_and_reports_its_exit_code(self):
        log = os.path.join(tempfile.mkdtemp(), "run.log")
        with contextlib.redirect_stdout(io.StringIO()) as stdout:
            code, fired = rt.Runner().stream([sys.executable, "-c", "print('hello'); raise SystemExit(3)"], log, 30)
        self.assertEqual((code, fired), (3, False))
        with open(log, encoding="utf-8") as f:
            self.assertEqual(f.read(), "hello\n")
        self.assertEqual(stdout.getvalue(), "hello\n")

    def test_a_run_that_outlives_its_budget_is_killed_with_everything_it_started(self):
        log = os.path.join(tempfile.mkdtemp(), "run.log")
        script = "import subprocess,sys,time; subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)']); time.sleep(60)"
        started = time.time()
        with contextlib.redirect_stdout(io.StringIO()) as stdout:
            code, fired = rt.Runner().stream([sys.executable, "-c", script], log, 1)
        self.assertTrue(fired)
        self.assertNotEqual(code, 0)
        self.assertLess(time.time() - started, 20)
        self.assertIn("watchdog: test run stalled", stdout.getvalue())


if __name__ == "__main__":
    unittest.main()
