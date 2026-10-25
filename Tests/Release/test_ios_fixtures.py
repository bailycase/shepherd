"""Duo-only regressions must not break the generic simulator run."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class IOSFixtureSelectionTests(unittest.TestCase):
    def test_fold_check_requires_its_pose_and_window_support(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stub = root / "environment.sh"
            # Stop at simulator lookup, before compiling, installing, or launching anything.
            stub.write_text('xcrun() { printf \'{"devices":{}}\\n\'; }\n')
            cases = [
                ([], "all", 66),
                (["-w", "-f", "closed"], "all", 66),
                ([], "windows-fold", 64),
                (["-w", "-f", "open"], "windows-fold", 66),
                (["-w", "-f", "open", "-r", "landscape"], "windows-fold", 64),
            ]
            for flags, screen, expected in cases:
                with self.subTest(flags=flags, screen=screen):
                    result = subprocess.run(
                        ["bash", "Tests/ShepherdIOSChecks/run-simulator.sh", "-d", "absent", "-o", str(root / "shots"), *flags, screen],
                        cwd=ROOT, env={**os.environ, "BASH_ENV": str(stub)},
                        text=True, capture_output=True, timeout=5,
                    )
                    self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
