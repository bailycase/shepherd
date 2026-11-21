"""The named validation command must not turn missing or failed evidence green."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import validate


def frame(t, first, rows, *callers, hidden=False, height=500, following=False, clip=(200, 100)):
    return {"timestamp": t, "refreshInterval": 0.01, "first": first, "rows": rows, "hidden": hidden,
            "offset": 10, "documentHeight": height, "streamingRowHeight": height - 450,
            "following": following, "distance": 0, "clipSize": clip,
            "events": [{"caller": caller} for caller in callers]}


class ValidateTests(unittest.TestCase):
    def test_scroll_compares_the_same_row_when_the_deck_reveals_it(self):
        frames = [
            frame(0, "a", {"a": -1, "b": 5}),
            frame(0.01, None, {}, "fixture.switchAway", hidden=True),
            frame(0.02, "b", {"a": -9, "b": 8}, "fixture.switchBack", "ThreadView.historyMaterialize", "NSClipView.bounds"),
        ]
        frames[2]["events"][-1]["stack"] = [
            "7 AppKit 0x1 -[NSView _postBoundsChangeNotification] + 96",
            "8 AppKit 0x2 -[NSView setBoundsOrigin:] + 240",
            "9 SwiftUI 0x3 $s7SwiftUI17HostingScrollViewC13updateContext + 5328",
        ]
        [jump] = validate.measure_scroll(frames)["jumps"]
        self.assertEqual((jump["frame"], jump["row"], jump["delta_pt"]), (2, "a", -8))
        self.assertEqual(jump["paths"], ["ThreadView.historyMaterialize", "SwiftUI.HostingScrollView.updateContext"])

    def test_input_does_not_hide_a_jump_and_small_steps_can_add_up_to_drift(self):
        frames = [frame(i / 100, "a", {"a": y}) for i, y in enumerate((0, 15, 16, 17, 18))]
        frames[1]["events"].append({"caller": "fixture.scrollInput", "scrollDelta": -10})
        summary = validate.measure_scroll(frames)
        self.assertEqual([jump["delta_pt"] for jump in summary["jumps"]], [5])
        self.assertEqual([drift["delta_pt"] for drift in summary["drift"]], [3])
        frames[1]["first"], frames[1]["rows"], frames[1]["offset"] = "b", {"b": 0}, -5
        [jump] = validate.measure_scroll(frames[:2])["jumps"]
        self.assertEqual((jump["measured"], jump["delta_pt"]), ("clip offset", 5))

    def test_paging_anchor_swap_counts_once_and_has_no_invented_delta(self):
        frames = [frame(0, "user-60", {"user-60": -1}), frame(0.01, "user-0", {"user-0": -1}),
                  frame(0.02, "user-0", {"user-0": -1}), frame(0.03, "user-60", {"user-60": -1})]
        summary = validate.measure_scroll(frames)
        [loss] = summary["anchor_losses"]
        self.assertEqual((loss["row"], loss["first_after"], loss["restored_frame"]), ("user-60", "user-0", 3))
        self.assertFalse(summary["jumps"])
        self.assertNotIn("delta_pt", loss)

        [jump] = validate.measure_scroll(frames[:-1])["jumps"]
        self.assertEqual((jump["frame"], jump["measured"], jump["delta_pt"]), (1, "unrestored anchor loss", None))

    def test_only_a_matching_sticky_repin_is_separated_from_input_frame_jumps(self):
        before = frame(0, "a", {"a": 0}, following=True)
        before["distance"] = 57
        after = frame(0.01, "a", {"a": -57}, "fixture.streamChunk", following=True)
        after["events"].append({"caller": "fixture.scrollInput", "scrollDelta": -28})
        summary = validate.measure_scroll([before, after])
        [repin] = summary["in_band_inputs"]
        self.assertEqual((repin["delta_pt"], repin["distance_before"], repin["distance"], repin["following"]),
                         (-85, 57, 0, True))
        self.assertFalse(summary["jumps"])

        after["rows"]["a"] = 0  # A cancelled 28 pt input alone is not a 57 pt return to the tail.
        summary = validate.measure_scroll([before, after])
        self.assertFalse(summary["in_band_inputs"])
        self.assertEqual([jump["delta_pt"] for jump in summary["jumps"]], [-28])

    def test_only_growth_while_already_sticky_in_band_is_expected_following(self):
        frames = [frame(0, "a", {"a": 0}, following=True),
                  frame(0.01, "a", {"a": -29}, "fixture.stickyChunk", height=529, following=True),
                  frame(0.02, "a", {"a": -58}, "fixture.streamChunk", height=558)]
        summary = validate.measure_scroll(frames)
        self.assertEqual([motion["frame"] for motion in summary["sticky_follows"]], [1])
        self.assertEqual([jump["frame"] for jump in summary["jumps"]], [2])
        frames[0]["distance"] = 81
        self.assertFalse(validate.measure_scroll(frames)["sticky_follows"])

    def test_markers_without_layout_changes_or_a_settle_window_are_not_evidence(self):
        name = "window-resize"
        required = validate.SCROLL_SCENARIOS[name]
        frames = [frame(0, "a", {"a": 0})]
        frames.extend(frame(i / 10, "a", {"a": 0}, "fixture.windowResize", clip=(200 + i, 100)) for i in range(1, 4))
        frames.append(frame(1.2, "a", {"a": 0}, clip=(203, 100)))
        validate.check_scroll_actions(name, frames, required)
        with self.assertRaisesRegex(ValueError, "settle samples"):
            validate.check_scroll_actions(name, frames[:-1], required)
        frames[2]["clipSize"] = frames[1]["clipSize"]
        with self.assertRaisesRegex(ValueError, "did not change clipSize"):
            validate.check_scroll_actions(name, frames, required)
        with self.assertRaisesRegex(ValueError, "expected all six"):
            validate.scroll_evidence({})

    def test_bare_invocation_fails_loudly(self):
        completed = subprocess.run([sys.executable, str(ROOT / "scripts/validate.py")],
                                   capture_output=True, text=True)
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(completed.stderr.strip(), "selection not implemented")

    def run_case(self, records, swift_exit=0, case="changes-review"):
        test = {"changes-review": "ReviewFlowTests/opensCommitSheetWithoutChangingGit",
                "seeded-thread-rename": "ThreadRenameTests/seededThreadRenameSurvivesHostRestart",
                "c-state": "StateStoreTests/historicalFilesLoadAndRewriteAsRecorded",
                "c-auth": "RefusalCorpusTests/refusalCorpusMatchesGolden",
                "c-settings": "SettingsWritePathTests/everySettingsWritePathMatchesTheGolden"}[case]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            source = {"revision": "test-revision", "dirty_paths": []}
            output = io.StringIO()

            def swift_test(command, *, cwd, env, stdout, stderr):
                self.assertEqual(command, ["swift", "test", "-j", "4", "--filter", test])
                self.assertEqual(cwd, root)
                self.assertNotIn("SHEPHERD_LIVE_MODEL", env)
                self.assertEqual(stderr, subprocess.STDOUT)
                mac = Path(env["SHEPHERD_VALIDATION_DIR"])
                self.assertEqual(mac.parent.parent, root / ".build/validation")
                self.assertEqual(mac.name, "mac")
                stdout.write("swift test fixture output\n")
                steps = mac / "steps"
                steps.mkdir()
                for i, record in enumerate(records):
                    for evidence in record["evidence"]:
                        (mac.parent / evidence).write_bytes(b"fixture screenshot")
                    (steps / f"{i}.json").write_text(json.dumps(record), encoding="utf-8")
                return subprocess.CompletedProcess(command, swift_exit)

            with (patch.object(validate, "ROOT", root), patch.object(validate.sys, "platform", "darwin"),
                  patch.object(validate, "source_identity", return_value=source),
                  patch.object(validate.subprocess, "check_output", return_value=b"Swift version fixture"),
                  patch.object(validate.subprocess, "run", side_effect=swift_test) as swift,
                  patch.dict(os.environ, {"SHEPHERD_LIVE_MODEL": "must-not-reach-swift"}),
                  contextlib.redirect_stdout(output)):
                code = validate.main(["--case", case])
                swift.assert_called_once()
            [report] = (root / ".build/validation").glob("*/result.json")
            result = json.loads(report.read_text(encoding="utf-8"))
            self.assertEqual(result["exit_status"], swift_exit)
            self.assertEqual(result["source"], source)
            self.assertEqual(result["toolchain"], "Swift version fixture")
            self.assertEqual((report.parent / result["log"]).read_text(), "swift test fixture output\n")
            return code, output.getvalue(), result

    def test_failed_step_reports_a_diff_and_evidence_even_with_zero_swift_exit(self):
        record = {"step": "open-commit-sheet", "appearance": "dark", "status": "failed",
                  "expected": "enabled Commit… action", "actual": "no Commit… action in the accessibility tree",
                  "evidence": ["mac/open-commit-sheet-actual-dark.png"]}
        code, output, result = self.run_case([record])
        self.assertNotEqual(code, 0)
        self.assertIn("FAIL mac/changes-review/open-commit-sheet [narrow, dark]", output)
        self.assertIn("- Expected: enabled Commit… action\n+ Actual:   no Commit… action in the accessibility tree", output)
        report_path = next(line.removeprefix("Report: ") for line in output.splitlines() if line.startswith("Report: "))
        run = Path(report_path).parent
        self.assertIn(f"Evidence: {run}/mac/run.log, {run}/mac/open-commit-sheet-actual-dark.png", output)
        self.assertEqual(result["status"], "assertion_failed")
        [step] = result["steps"]
        self.assertEqual(step["actual"], record["actual"])
        self.assertIn("Sources/ShepherdApp/DiffReviewView.swift", step["look_first"])

    def test_zero_exit_without_completion_evidence_fails(self):
        for records in ([], [{"step": "complete", "status": "passed", "evidence": [],
                              "expected": "light and dark scenarios finished", "actual": "light and dark scenarios finished"}]):
            with self.subTest(records=records):
                code, output, result = self.run_case(records)
                self.assertNotEqual(code, 0)
                self.assertEqual(result["status"], "incomplete")
                self.assertIn("no valid completion evidence", output)
                self.assertIn("open-commit-sheet [dark]", output)
                self.assertIn("swift test fixture output", output)
                self.assertIn(["open-commit-sheet", "dark"], result["missing_steps"])
                self.assertEqual(len(result["missing_steps"]), 10 if records else 11)
                self.assertEqual(result["log_diagnostic"], "swift test fixture output")

    def test_all_steps_and_completion_with_zero_exit_pass(self):
        records = [{"step": step, "appearance": appearance, "status": "passed",
                    "expected": "expected", "actual": "actual", "evidence": []}
                   for step, appearance in sorted(validate.CASES["changes-review"].steps)]
        records.append({"step": "complete", "status": "passed", "evidence": [],
                        "expected": "light and dark scenarios finished", "actual": "light and dark scenarios finished"})
        code, output, result = self.run_case(records)
        self.assertEqual(code, 0)
        self.assertEqual(result["status"], "passed")
        self.assertIn("PASS mac/changes-review", output)

    def test_incomplete_reports_invalid_evidence_on_the_terminal(self):
        code, output, result = self.run_case([{"step": "unknown", "evidence": []}])
        self.assertEqual(code, 1)
        self.assertIn("Evidence error: 0.json: invalid or duplicate step record", output)
        self.assertEqual(result["evidence_errors"], ["0.json: invalid or duplicate step record"])

    def test_a_thrown_golden_scenario_is_a_comparison_failure(self):
        record = {"step": "compare-golden", "status": "failed", "evidence": [],
                  "expected": "rename, restart and sidebar matched the golden",
                  "actual": "Scenario threw: socket closed while awaiting reply"}
        code, output, result = self.run_case([record], swift_exit=1, case="seeded-thread-rename")
        self.assertEqual(code, 1)
        self.assertEqual(result["status"], "assertion_failed")
        self.assertIn("FAIL mac/seeded-thread-rename/compare-golden", output)
        self.assertIn("Look first: Tests/Fixtures/seeded-thread-rename.json.", output)

    def test_multiline_diff_and_evidence_errors_are_reported_together(self):
        record = {"step": "compare-golden", "status": "failed", "evidence": [],
                  "expected": "case.loaded = 1\ncase.rewritten = 1",
                  "actual": "case.loaded = 2\ncase.rewritten = 2"}
        code, output, result = self.run_case([record, {"step": "unknown", "evidence": []}], swift_exit=1, case="c-state")
        self.assertEqual(code, 1)
        self.assertEqual(result["status"], "assertion_failed")
        self.assertIn("- Expected: case.loaded = 1\n- case.rewritten = 1\n"
                      "+ Actual:   case.loaded = 2\n+ case.rewritten = 2", output)
        self.assertIn("Look first: Tests/Fixtures/c-state.json.", output)
        self.assertIn("Evidence error: 1.json: invalid or duplicate step record", output)

    def test_seeded_rename_checks_require_the_golden_comparison_and_completion(self):
        matched = "rename, restart and sidebar matched the golden"
        record = {"status": "passed", "expected": matched, "actual": matched, "evidence": []}
        complete = {**record, "step": "complete"}
        code, _, result = self.run_case([complete], case="seeded-thread-rename")
        self.assertEqual(code, 1)
        self.assertEqual(result["missing_steps"], [["compare-golden", None]])
        code, output, result = self.run_case([{**record, "step": "compare-golden"}, complete],
                                             case="seeded-thread-rename")
        self.assertEqual(code, 0)
        self.assertEqual(result["status"], "passed")
        self.assertIn("PASS mac/seeded-thread-rename", output)

    def test_refusal_corpus_requires_the_golden_comparison_and_completion(self):
        matched = "refusal corpus matched the golden"
        record = {"status": "passed", "expected": matched, "actual": matched, "evidence": []}
        complete = {**record, "step": "complete"}
        code, _, result = self.run_case([complete], case="c-auth")
        self.assertEqual(code, 1)
        self.assertEqual(result["missing_steps"], [["compare-golden", None]])
        code, output, result = self.run_case([{**record, "step": "compare-golden"}, complete], case="c-auth")
        self.assertEqual(code, 0)
        self.assertEqual(result["status"], "passed")
        self.assertIn("PASS mac/c-auth", output)

    def test_settings_write_path_checks_require_the_golden_comparison_and_completion(self):
        matched = "every settings write path matched the golden"
        record = {"status": "passed", "expected": matched, "actual": matched, "evidence": []}
        complete = {**record, "step": "complete"}
        code, _, result = self.run_case([complete], case="c-settings")
        self.assertEqual(code, 1)
        self.assertEqual(result["missing_steps"], [["compare-golden", None]])
        failed = {**record, "step": "compare-golden", "status": "failed",
                  "expected": "sync.host.defaultThinking.reply.settings.defaultThinking = \"low\"",
                  "actual": "sync.host.defaultThinking.reply.settings.defaultThinking = \"high\""}
        code, output, result = self.run_case([failed], case="c-settings")
        self.assertEqual(code, 1)
        self.assertIn("FAIL mac/c-settings/compare-golden [local host]", output)
        self.assertIn("Tests/Fixtures/settings-write-paths.json", result["steps"][0]["look_first"])
        code, output, result = self.run_case([{**record, "step": "compare-golden"}, complete], case="c-settings")
        self.assertEqual(code, 0)
        self.assertIn("PASS mac/c-settings", output)
