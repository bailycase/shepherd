"""Release tests must not depend on the environment of whoever runs them."""
import hermetic_env  # noqa: F401  (must stay first: scrubs ambient SHEPHERD_*/PI_*)
from pathlib import Path
import os
import subprocess
import sys
import unittest

HERE = Path(__file__).resolve().parent


class HermeticEnvTests(unittest.TestCase):
    def test_every_test_file_uses_the_helper(self):
        missing = [p.name for p in sorted(HERE.glob("test_*.py"))
                   if "import hermetic_env" not in p.read_text(encoding="utf-8")]
        self.assertEqual(missing, [])

    def test_ambient_shepherd_and_pi_variables_are_removed_except_runner_ones(self):
        code = ("import hermetic_env, os\n"
                "print(sorted(k for k in os.environ if k.startswith(('SHEPHERD_', 'PI_'))))")
        env = {**os.environ, "SHEPHERD_BUILD_WRAPPER": "/usr/bin/env", "PI_PACKAGE_DIR": "/x",
               "SHEPHERD_ENGINE_SMOKE": "kept"}
        out = subprocess.run([sys.executable, "-c", code], cwd=HERE, env=env,
                             capture_output=True, text=True, check=True).stdout
        self.assertEqual(out.strip(), "['SHEPHERD_ENGINE_SMOKE']")
