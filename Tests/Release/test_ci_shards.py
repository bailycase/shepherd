"""Tests for scripts/ci_shards.py, which splits the test suites into equal shards from recorded times.

Run: python3 -m unittest discover -s Tests/Release -v
"""
import json
import os
import re
import sys
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import ci_shards  # noqa: E402
import ci_testlog  # noqa: E402

TIMES = {
    "M.Big": 100.0, "M.Medium": 50.0, "M.Small": 20.0, "M.Tiny": 5.0, "N.Other": 60.0, "N.Quick": 1.0,
}
SUITES = sorted(TIMES)


class AssignTests(unittest.TestCase):
    def test_every_suite_lands_in_exactly_one_shard(self):
        for shards in (1, 2, 3, 6, 9):
            groups = ci_shards.assign(SUITES, TIMES, shards)
            self.assertEqual(len(groups), shards)
            ci_shards.check_partition(groups, SUITES)

    def test_the_longest_suites_are_spread_before_the_short_ones_fill_in(self):
        groups = ci_shards.assign(SUITES, TIMES, 3)
        loads = sorted(ci_shards.shard_seconds(g, TIMES) for g in groups)
        self.assertLessEqual(loads[-1] - loads[0], max(TIMES.values()))
        self.assertEqual([g for g in groups if "M.Big" in g][0], ["M.Big"])

    def test_the_split_is_the_same_every_time_it_is_asked(self):
        first = ci_shards.assign(list(reversed(SUITES)), TIMES, 3)
        self.assertEqual(first, ci_shards.assign(SUITES, TIMES, 3))

    def test_suites_the_times_do_not_know_fill_the_lightest_shards_and_never_the_longest(self):
        new = [f"New.Suite{i}" for i in range(6)]
        before = ci_shards.assign(SUITES, TIMES, 3)
        groups = ci_shards.assign(SUITES + new, TIMES, 3)
        ci_shards.check_partition(groups, SUITES + new)
        weights = dict(TIMES, **{n: ci_shards.UNKNOWN_SECONDS for n in new})
        before_loads = sorted(ci_shards.shard_seconds(g, TIMES) for g in before)
        after_loads = sorted(ci_shards.shard_seconds(g, weights) for g in groups)
        self.assertEqual(after_loads[-1], before_loads[-1], "the longest shard gained nothing")
        self.assertGreaterEqual(after_loads[0], before_loads[0])
        longest = max(range(3), key=lambda i: ci_shards.shard_seconds([s for s in groups[i] if s in TIMES], TIMES))
        self.assertEqual([s for s in groups[longest] if s in new], [])

    def test_one_new_suite_joins_the_lightest_shard(self):
        groups = ci_shards.assign(SUITES + ["New.Only"], TIMES, 3)
        base = ci_shards.assign(SUITES, TIMES, 3)
        lightest = min(range(3), key=lambda i: (ci_shards.shard_seconds(base[i], TIMES), i))
        self.assertIn("New.Only", groups[lightest])

    def test_a_shard_count_below_one_is_refused(self):
        with self.assertRaises(ValueError):
            ci_shards.assign(SUITES, TIMES, 0)


class PartitionCheckTests(unittest.TestCase):
    def test_a_suite_in_two_shards_is_caught(self):
        with self.assertRaisesRegex(ValueError, "is in shards 1 and 2"):
            ci_shards.check_partition([["a"], ["a", "b"]], ["a", "b"])

    def test_a_suite_in_no_shard_is_caught(self):
        with self.assertRaisesRegex(ValueError, "miss"):
            ci_shards.check_partition([["a"], []], ["a", "b"])

    def test_a_suite_nobody_listed_is_caught(self):
        with self.assertRaisesRegex(ValueError, "add"):
            ci_shards.check_partition([["a", "z"], []], ["a"])


class FilterTests(unittest.TestCase):
    IDS = [
        "M.Thread/a()", "M.ThreadExtra/a()", "N.Thread/a()", "M.Thread/b(_:)/File.swift:4:3",
        "M.Dotted/c()", "MxDotted.Dotted/c()",
    ]

    def matched(self, group):
        patterns = [re.compile(p) for p in ci_shards.filters(group)]
        return [i for i in self.IDS if any(p.search(i) for p in patterns)]

    def test_a_shard_selects_its_suites_and_not_a_longer_name_or_another_module(self):
        self.assertEqual(self.matched(["M.Thread"]), ["M.Thread/a()", "M.Thread/b(_:)/File.swift:4:3"])
        self.assertEqual(self.matched(["N.Thread", "M.ThreadExtra"]), ["M.ThreadExtra/a()", "N.Thread/a()"])

    def test_the_module_prefix_is_not_a_regular_expression(self):
        self.assertEqual(self.matched(["M.Dotted"]), ["M.Dotted/c()"])

    def test_one_pattern_per_module(self):
        self.assertEqual(len(ci_shards.filters(["A.x", "A.y", "B.z"])), 2)


class SelectionTests(unittest.TestCase):
    ALL = ["CoreUnitTests.A", "AppUnitTests.B", "AppIntegrationTests.Thread1", "AppIntegrationTests.Browser1",
           "SessionsIntegrationTests.Start", "SessionsIntegrationTests.Other"]

    def test_all_selects_everything(self):
        self.assertEqual(ci_shards.select(self.ALL, {"all": True}), self.ALL)

    def test_a_subset_is_the_unit_tier_the_patterns_and_the_exact_suites(self):
        chosen = ci_shards.select(self.ALL, {
            "all": False, "unit": True, "regexes": [r"^AppIntegrationTests\.Thread"],
            "smoke": ["SessionsIntegrationTests.Start"], "suites": ["SessionsIntegrationTests.Gone"],
        })
        self.assertEqual(chosen, ["AppIntegrationTests.Thread1", "AppUnitTests.B", "CoreUnitTests.A", "SessionsIntegrationTests.Start"])

    def test_without_the_unit_flag_the_unit_tier_is_not_added(self):
        chosen = ci_shards.select(self.ALL, {"all": False, "unit": False, "regexes": [], "smoke": [], "suites": []})
        self.assertEqual(chosen, [])


class TimesFileTests(unittest.TestCase):
    def test_new_measurements_move_a_time_halfway_and_never_below_a_hundredth(self):
        merged = ci_shards.merge_times({"a": 10.0, "b": 4.0}, [{"a": 20.0, "c": 3.0}, {"a": 40.0, "z": 0.0}])
        self.assertAlmostEqual(merged["a"], 20.0)      # 0.5 * 10 + 0.5 * mean(20, 40)
        self.assertEqual(merged["b"], 4.0)
        self.assertEqual(merged["c"], 3.0)
        self.assertEqual(merged["z"], 0.01)

    def test_suites_no_longer_in_the_list_are_dropped(self):
        self.assertEqual(ci_shards.merge_times({"a": 1.0, "gone": 2.0}, [], known={"a"}), {"a": 1.0})

    def test_the_file_round_trips_sorted(self):
        path = os.path.join(tempfile.mkdtemp(), "times.json")
        ci_shards.write_times(path, {"b": 2.0, "a": 1.234}, "a note")
        with open(path, encoding="utf-8") as f:
            self.assertEqual(list(json.load(f)["suites"]), ["a", "b"])
        self.assertEqual(ci_shards.read_times(path), {"a": 1.23, "b": 2.0})

    def test_a_missing_file_reads_as_no_times(self):
        self.assertEqual(ci_shards.read_times("/nonexistent/times.json"), {})


class CommittedTimesTests(unittest.TestCase):
    def test_the_committed_times_are_positive_and_name_real_test_targets(self):
        times = ci_shards.read_times(os.path.join(ROOT, ci_shards.DEFAULT_TIMES))
        self.assertGreater(len(times), 300)
        targets = {name for name in os.listdir(os.path.join(ROOT, "Tests")) if name.endswith(("Tests", "Check"))}
        for suite, seconds in times.items():
            self.assertGreater(seconds, 0, suite)
            self.assertIn(suite.split(".", 1)[0], targets, suite)

    def test_every_suite_the_tests_declare_is_in_the_times_or_lands_on_the_lightest_shard(self):
        # The file may lag the tests (a new suite is placed by the lightest-shard rule), but the
        # lag is visible: this fails when more than a tenth of the suites are unknown.
        times = ci_shards.read_times(os.path.join(ROOT, ci_shards.DEFAULT_TIMES))
        declared = {s for s in ci_testlog.suite_names(ROOT)
                    if s.split(".", 1)[0] in {t.split(".", 1)[0] for t in times}}
        unknown = sorted(declared - set(times))
        self.assertLess(len(unknown), len(declared) // 10, f"regenerate Tests/ci-suite-times.json: {unknown[:10]}")


if __name__ == "__main__":
    unittest.main()
