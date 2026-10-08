"""The master bootstrap registers dispatch without installing Nightly release machinery."""
import ast
import os
from pathlib import Path
import re
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]


class BootstrapTests(unittest.TestCase):
    def test_dispatch_accepts_the_exact_nightly_parent_identity_schema(self):
        workflow = (ROOT / ".github/workflows/release-build.yml").read_text()
        inputs = workflow.split("    inputs:\n", 1)[1].split("\npermissions:", 1)[0]
        rows = re.findall(r"^      (\w+):\n        type: string\n        required: true$", inputs, re.M)
        self.assertEqual(rows, ["parent_run", "parent_attempt", "source_sha", "build_number", "plan"])
        self.assertIn("run-name: Horizon release ${{ inputs.parent_run }}-${{ inputs.parent_attempt }}", workflow)
        self.assertIn("  workflow_dispatch:", workflow)
        self.assertNotIn("  push:", workflow)
        self.assertNotIn("  pull_request:", workflow)
        self.assertNotIn("  workflow_call:", workflow)

    def test_bootstrap_has_no_self_hosted_credentials_build_or_publication_path(self):
        workflow = (ROOT / ".github/workflows/release-build.yml").read_text()
        self.assertEqual(re.findall(r"^    runs-on: (.+)$", workflow, re.M), ["ubuntu-latest"])
        self.assertIn("timeout-minutes: 3", workflow)
        self.assertIn("permissions:\n  contents: read", workflow)
        self.assertIn("persist-credentials: false", workflow)
        self.assertEqual(re.findall(r"^      - run: (.+)$", workflow, re.M),
                         ["python3 scripts/release_runner.py"])
        for forbidden in ("secrets.", "contents: write", "actions: write", "shepherd-release",
                          "xcodebuild", "codesign", "gh release", "git push"):
            self.assertNotIn(forbidden, workflow)
        script = (ROOT / "scripts/release_runner.py").read_text()
        imports = [node.names[0].name for node in ast.walk(ast.parse(script)) if isinstance(node, ast.Import)]
        self.assertEqual(imports, ["sys"])
        self.assertFalse(any(isinstance(node, ast.ImportFrom) for node in ast.walk(ast.parse(script))))

    def test_running_the_bootstrap_refuses_even_a_supplied_nightly_identity(self):
        result = subprocess.run([sys.executable, str(ROOT / "scripts/release_runner.py")],
            cwd=ROOT, env={**os.environ, "GITHUB_REF": "refs/heads/nightly", "PARENT_RUN": "10",
                           "PARENT_ATTEMPT": "1", "SOURCE_SHA": "a" * 40, "BUILD_NUMBER": "42",
                           "RELEASE_PLAN": "{}"}, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertIn("Registration-only workflow", result.stderr)


if __name__ == "__main__":
    unittest.main()
