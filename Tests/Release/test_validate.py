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


class ValidateTests(unittest.TestCase):
    def test_bare_invocation_fails_loudly(self):
        completed = subprocess.run([sys.executable, str(ROOT / "scripts/validate.py")],
                                   capture_output=True, text=True)
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(completed.stderr.strip(), "selection not implemented")

    def run_case(self, records, swift_exit=0):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            source = {"revision": "test-revision", "dirty_paths": []}
            output = io.StringIO()

            def swift_test(command, *, cwd, env, stdout, stderr):
                self.assertEqual(command, ["swift", "test", "-j", "4", "--filter",
                                           "ReviewFlowTests/opensCommitSheetWithoutChangingGit"])
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
                code = validate.main(["--case", "changes-review"])
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
                self.assertEqual(len(result["missing_steps"]), 10)
                self.assertEqual(result["log_diagnostic"], "swift test fixture output")

    def test_all_steps_and_completion_with_zero_exit_pass(self):
        records = [{"step": step, "appearance": appearance, "status": "passed",
                    "expected": "expected", "actual": "actual", "evidence": []}
                   for step in sorted(validate.STEPS) for appearance in validate.APPEARANCES]
        records.append({"step": "complete", "status": "passed", "evidence": [],
                        "expected": "light and dark scenarios finished", "actual": "light and dark scenarios finished"})
        code, output, result = self.run_case(records)
        self.assertEqual(code, 0)
        self.assertEqual(result["status"], "passed")
        self.assertIn("PASS mac/changes-review", output)
