"""Tests for scripts/ci_testlog.py, which reads what the Swift and node test runs printed.

The Swift fixtures are lines CI really printed (Swift 6.3.3 on macos-26), trimmed. Run:
python3 -m unittest discover -s Tests/Release -v
"""
import os
import sys
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import ci_testlog as tl  # noqa: E402

# A thread test that timed out, a known issue, a test that prints lines which look like results
# (the app's own tests of its test-output reader do), and the closing summary.
FAILED_RUN = """\
◇ Suite "Thread tail in the app's layout" started.
◇ Test aLongThreadOpensOnItsTail(_:) started.
✘ Test aLongThreadOpensOnItsTail(_:) recorded an issue with 1 argument c → 1400x1100, rows of 9,000 pt, following by scrolling at ThreadTailFlowTests.swift:454:6: Caught error: timed out waiting for opening: the thread to draw and keep its tail (60388 px drawn)
◇ Test case passing 1 argument c → 1400x1100, rows of 9,000 pt, anchored to aLongThreadOpensOnItsTail(_:) started.
✘ Test aLongThreadOpensOnItsTail(_:) with 8 test cases failed after 17.001 seconds with 1 issue.
↳ /// A long thread opens on its tail, whether or not the scroll view anchors itself there.
━ Test aSendThenAStreamingTurnThenItsFinishNeverLeavesTheThreadBlank(size:) recorded a known issue with 1 argument size → (900.0, 600.0) at ThreadBlankScreenTests.swift:220:33: Caught error: timed out
✘ Suite "Thread tail in the app's layout" failed after 120.564 seconds with 1 issue.
◇ Test case passing 3 arguments output → "✘ Test a() failed after 0.1 seconds with 1 issue.
✘ Test b() failed after 0.1 seconds with 1 issue.
✘ Test run with 20 tests in 3 suites failed after 8.4 seconds with 2 issues.", passed → 18, failed → 2 to testCountsComeFromTheRunnersSummary(output:passed:failed:) started.
✔ Suite "Queue stack" passed after 20.3 seconds.
━ Suite "Browser agent tools" passed after 63.7 seconds with 3 known issues.
✘ Test run with 4694 tests in 521 suites failed after 697.362 seconds with 10 issues (including 9 known issues).
"""

PASSED_RUN = """\
✔ Suite RemoteDesignTransportTests passed after 0.5 seconds.
━ Test run with 166 tests in 10 suites passed after 176.228 seconds with 3 known issues.
"""

EXPECTATION = """\
✘ Test aQueueKeepsItsOrder() recorded an issue at QueueTests.swift:88:9: Expectation failed: (rows.count → 2) == 3
↳ rows: ["a", "b"]
↳ expected: 3
✘ Test aQueueKeepsItsOrder() failed after 0.3 seconds with 1 issue.
✘ Test run with 5 tests in 1 suite failed after 1.2 seconds with 1 issue.
"""


class SwiftLogTests(unittest.TestCase):
    def test_a_failing_test_is_read_with_its_file_line_and_message(self):
        failure = tl.parse_swift_log(FAILED_RUN).failures[0]
        self.assertEqual(failure.name, "aLongThreadOpensOnItsTail(_:)")
        self.assertEqual((failure.file, failure.line, failure.col), ("ThreadTailFlowTests.swift", 454, 6))
        self.assertTrue(failure.message.startswith("Caught error: timed out waiting for opening"))
        self.assertEqual(failure.count, 1)

    def test_known_issues_are_not_failures(self):
        names = [f.name for f in tl.parse_swift_log(FAILED_RUN).failures]
        self.assertNotIn("aSendThenAStreamingTurnThenItsFinishNeverLeavesTheThreadBlank(size:)", names)

    def test_the_closing_summary_wins_over_lines_a_test_printed(self):
        summary = tl.parse_swift_log(FAILED_RUN).summary
        self.assertEqual((summary.tests, summary.suites, summary.passed), (4694, 521, False))
        self.assertEqual((summary.issues, summary.known, summary.unexpected), (10, 9, 1))

    def test_a_run_with_only_known_issues_reads_them_as_its_issues(self):
        summary = tl.parse_swift_log(PASSED_RUN).summary
        self.assertEqual((summary.tests, summary.passed, summary.issues, summary.known, summary.unexpected), (166, True, 3, 3, 0))

    def test_lines_a_test_quoted_are_read_but_name_no_real_test(self):
        names = [f.name for f in tl.parse_swift_log(FAILED_RUN).failures]
        self.assertNotIn("a()", names)         # led by `◇ Test case …`, so not a result line
        self.assertIn("b()", names)            # a continuation line: read as written; resolve_ids drops it
        self.assertIn("run with 20 tests in 3 suites", names)

    def test_expectation_details_join_the_message(self):
        failure = tl.parse_swift_log(EXPECTATION).failures[0]
        self.assertEqual(failure.count, 1)
        self.assertIn("Expectation failed: (rows.count → 2) == 3", failure.message)
        self.assertIn('rows: ["a", "b"]', failure.message)

    def test_several_issues_in_one_place_are_counted(self):
        log = "\n".join(
            f"✘ Test sized(_:) recorded an issue with 1 argument s → {n} at A.swift:5:3: bad" for n in range(3))
        failure = tl.parse_swift_log(log).failures[0]
        self.assertEqual(failure.count, 3)

    def test_suite_times_come_from_quoted_and_bare_names_and_every_result_symbol(self):
        parsed = tl.parse_swift_log(FAILED_RUN + PASSED_RUN)
        self.assertIn(("Queue stack", 20.3, True), parsed.suite_times)
        self.assertIn(("Browser agent tools", 63.7, True), parsed.suite_times)
        self.assertIn(("Thread tail in the app's layout", 120.564, False), parsed.suite_times)
        self.assertIn(("RemoteDesignTransportTests", 0.5, True), parsed.suite_times)

    def test_a_log_with_no_summary_has_none(self):
        self.assertIsNone(tl.parse_swift_log("◇ Test a() started.\nFatal error: boom\n").summary)


IDS = [
    "ShepherdAppIntegrationTests.ThreadTailFlowTests/aLongThreadOpensOnItsTail(_:)",
    "ShepherdAppIntegrationTests.ThreadTailFlowTests/historyArrivingAfterTheThreadMountedLandsOnItsTail(size:)",
    "ShepherdAppIntegrationTests.QueueStackIntegrationTests/aQueueKeepsItsOrder()",
    "ShepherdAppUnitTests.QueueStackTests/aQueueKeepsItsOrder()",
    "ShepherdSessionsIntegrationTests.QueueTests/other()",
]


class ResolveTests(unittest.TestCase):
    def tree(self, files):
        folder = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(folder, ignore_errors=True))
        for path, text in files.items():
            full = os.path.join(folder, path)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "w", encoding="utf-8") as f:
                f.write(text)
        return folder

    def test_a_failure_gets_the_id_of_the_test_it_names(self):
        resolved, unresolved = tl.resolve_ids(tl.parse_swift_log(FAILED_RUN).failures, IDS, self.tree({}))
        self.assertEqual([f.id for f in resolved], [IDS[0]])
        self.assertEqual(sorted(f.name for f in unresolved), ["b()", "run with 20 tests in 3 suites"])

    def test_a_name_two_suites_share_is_narrowed_by_the_failing_file(self):
        root = self.tree({
            "Tests/ShepherdAppIntegrationTests/QueueStackTests.swift": "struct QueueStackIntegrationTests {}\n",
        })
        failures = tl.parse_swift_log(EXPECTATION).failures
        resolved, _ = tl.resolve_ids(failures, IDS, root)
        self.assertEqual(resolved[0].id, IDS[2])

    def test_a_name_two_suites_in_one_module_share_is_narrowed_by_the_types_the_file_declares(self):
        ids = ["M.AlphaTests/shared()", "M.BetaTests/shared()"]
        root = self.tree({"Tests/M/BetaTests.swift": "@Suite struct BetaTests {\n}\n"})
        failure = tl.Failure("shared()", "BetaTests.swift", 3, 1)
        resolved, _ = tl.resolve_ids([failure], ids, root)
        self.assertEqual(resolved[0].id, "M.BetaTests/shared()")

    def test_the_retry_filter_selects_one_test_and_matches_ids_with_a_location_suffix(self):
        import re
        pattern = tl.filter_for_test("ShepherdAppIntegrationTests.ThreadTailFlowTests/aLongThreadOpensOnItsTail(_:)")
        self.assertTrue(re.search(pattern, "ShepherdAppIntegrationTests.ThreadTailFlowTests/aLongThreadOpensOnItsTail(_:)/ThreadTailFlowTests.swift:446:6"))
        self.assertFalse(re.search(pattern, "ShepherdAppIntegrationTests.ThreadTailFlowTests/aLongThreadOpensOnItsTail(size:)"))
        self.assertFalse(re.search(pattern, "XShepherdAppIntegrationTests.ThreadTailFlowTests/aLongThreadOpensOnItsTail(_:)"))


class SuiteNameTests(unittest.TestCase):
    def test_the_real_tree_names_a_suite_by_its_display_name_or_its_type(self):
        names = tl.suite_names(ROOT)
        self.assertEqual(names["ShepherdAppIntegrationTests.ThreadTailFlowTests"], ["Thread tail in the app's layout"])
        self.assertEqual(names["ShepherdRemoteUnitTests.RemoteDesignTransportTests"], ["RemoteDesignTransportTests"])
        # a type with @Test methods and no @Suite
        self.assertEqual(names["DesignSurfaceKitUnitTests.DesignRenderLimitsTests"], ["DesignRenderLimitsTests"])

    def test_times_go_to_the_suite_a_name_belongs_to_and_shared_names_split_slowest_first(self):
        ids = [
            "ShepherdAppIntegrationTests.QueueStackIntegrationTests/a()",
            "ShepherdAppIntegrationTests.QueueStackIntegrationTests/b()",
            "ShepherdAppUnitTests.QueueStackTests/a()",
            "ShepherdAppUnitTests.Other/a()",
        ]
        names = {
            "ShepherdAppIntegrationTests.QueueStackIntegrationTests": ["Queue stack"],
            "ShepherdAppUnitTests.QueueStackTests": ["Queue stack"],
        }
        observed = [("Queue stack", 0.01, True), ("Queue stack", 20.3, True), ("Other", 0.2, True), ("Unknown", 9.0, True)]
        times = tl.attribute_suite_times(observed, ids, names)
        self.assertEqual(times, {
            "ShepherdAppIntegrationTests.QueueStackIntegrationTests": 20.3,
            "ShepherdAppUnitTests.QueueStackTests": 0.01,
            "ShepherdAppUnitTests.Other": 0.2,
        })


NODE_FAILED = """\
✔ a fine test (3.2ms)
✖ real Pi RPC lifecycle: parallel, role tools (20401.97ms)
ℹ tests 254
ℹ suites 0
ℹ pass 253
ℹ fail 1
ℹ cancelled 0
ℹ skipped 0
✖ failing tests:

test at Tests/Extensions/native-children.test.mjs:312:1
✖ real Pi RPC lifecycle: parallel, role tools (20401.97ms)
  AssertionError [ERR_ASSERTION]: Expected values to be strictly equal:

  '' !== '::1'

      at TestContext.<anonymous> (file:///home/runner/work/shepherd/shepherd/Tests/Extensions/native-children.test.mjs:589:69)
"""


class NodeLogTests(unittest.TestCase):
    def test_the_failing_tests_section_gives_each_failure_its_file_line_and_error(self):
        counts, failures = tl.parse_node_log(NODE_FAILED)
        self.assertEqual((counts["tests"], counts["pass"], counts["fail"]), (254, 253, 1))
        self.assertEqual(len(failures), 1)
        failure = failures[0]
        self.assertEqual(failure.name, "real Pi RPC lifecycle: parallel, role tools")
        self.assertEqual((failure.file, failure.line), ("Tests/Extensions/native-children.test.mjs", 312))
        self.assertIn("AssertionError [ERR_ASSERTION]", failure.message)

    def test_a_pattern_matches_exactly_the_names_it_is_given(self):
        import re
        pattern = tl.js_pattern(["a (b) [c]: d.e", "other"])
        self.assertTrue(re.search(pattern, "a (b) [c]: d.e"))
        self.assertTrue(re.search(pattern, "other"))
        self.assertFalse(re.search(pattern, "a (b) [c]: dxe"))
        self.assertFalse(re.search(pattern, "other thing"))


class AnnotationTests(unittest.TestCase):
    def test_a_workflow_command_escapes_what_would_end_it(self):
        text = tl.annotation("error", "50% bad\nsecond line", "Tests/A.swift", 12, 3, "Test: failed, really")
        self.assertEqual(
            text, "::error file=Tests/A.swift,line=12,col=3,title=Test%3A failed%2C really::50%25 bad%0Asecond line")

    def test_a_failure_in_a_bare_file_name_is_found_under_tests(self):
        files = {"ThreadTailFlowTests.swift": ["Tests/ShepherdAppIntegrationTests/ThreadTailFlowTests.swift"]}
        failure = tl.Failure("x()", "ThreadTailFlowTests.swift", 4)
        self.assertEqual(tl.repo_path(failure, files), "Tests/ShepherdAppIntegrationTests/ThreadTailFlowTests.swift")

    def test_the_table_escapes_pipes_and_keeps_one_line_per_failure(self):
        table = tl.failures_table([tl.Failure("t()", "A.swift", 3, 1, "a | b\nsecond", id="M.S/t()")])
        self.assertIn("| `M.S/t()` | A.swift:3 | a \\| b |", table)


if __name__ == "__main__":
    unittest.main()
