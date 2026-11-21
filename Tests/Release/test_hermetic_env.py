"""Release tests must not depend on the environment of whoever runs them."""
import hermetic_env  # noqa: F401  (must stay first: scrubs ambient SHEPHERD_*/PI_*)
from pathlib import Path
import ast
import os
import subprocess
import sys
import unittest

HERE = Path(__file__).resolve().parent


def helper_import_is_first(source):
    """True if `import hermetic_env` is the first statement, after an optional docstring
    and `from __future__` imports (no test file has one today; allowed so one can be added)."""
    body = ast.parse(source).body
    if body and isinstance(body[0], ast.Expr) and isinstance(getattr(body[0], "value", None), ast.Constant) \
            and isinstance(body[0].value.value, str):
        body = body[1:]
    while body and isinstance(body[0], ast.ImportFrom) and body[0].module == "__future__":
        body = body[1:]
    return bool(body) and isinstance(body[0], ast.Import) \
        and [a.name for a in body[0].names] == ["hermetic_env"]


class HermeticEnvTests(unittest.TestCase):
    def test_every_test_file_imports_the_helper_first(self):
        files = sorted(HERE.glob("test_*.py"))
        self.assertTrue(files)
        bad = [p.name for p in files if not helper_import_is_first(p.read_text(encoding="utf-8"))]
        self.assertEqual(bad, [])

    def test_first_import_check_accepts_and_rejects(self):
        self.assertTrue(helper_import_is_first('"""doc"""\nimport hermetic_env\nimport os\n'))
        self.assertTrue(helper_import_is_first('"""doc"""\nfrom __future__ import annotations\nimport hermetic_env\n'))
        self.assertFalse(helper_import_is_first('import os\nimport hermetic_env\n'))
        self.assertFalse(helper_import_is_first('import os\nx = os.environ.get("A")\nimport hermetic_env\n'))
        self.assertFalse(helper_import_is_first('x = os.environ\nimport hermetic_env\n'))
        self.assertFalse(helper_import_is_first('"""import hermetic_env"""\nimport os\n'))
        self.assertFalse(helper_import_is_first('x = "import hermetic_env"\n'))

    def test_runner_allow_list_is_exactly_the_seeded_name(self):
        self.assertEqual(hermetic_env.RUNNER_ALLOWED, {"SHEPHERD_ENGINE_SMOKE"})

    def test_ambient_shepherd_and_pi_variables_are_removed_except_runner_ones(self):
        code = ("import hermetic_env, os\n"
                "print(sorted(k for k in os.environ if k.startswith(('SHEPHERD_', 'PI_'))))")
        env = {**os.environ, "SHEPHERD_BUILD_WRAPPER": "/usr/bin/env", "PI_PACKAGE_DIR": "/x",
               "SHEPHERD_ENGINE_SMOKE": "kept"}
        out = subprocess.run([sys.executable, "-c", code], cwd=HERE, env=env,
                             capture_output=True, text=True, check=True).stdout
        self.assertEqual(out.strip(), "['SHEPHERD_ENGINE_SMOKE']")
