"""Auto-merge stays author-scoped, bounded, and uses a release-capable token."""
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = (ROOT / ".github/workflows/auto-merge.yml").read_text()
SCRIPT = textwrap.dedent(WORKFLOW.split("        run: |\n", 1)[1])


class AutoMergeTests(unittest.TestCase):
    def test_scope_and_credentials(self):
        for required in (
            "pull_request_target:", "branches: [nightly]",
            "github.event.pull_request.state == 'open'",
            "!github.event.pull_request.draft",
            "(github.event.pull_request.user.id == 19316389 ||\n"
            "       github.event.pull_request.user.id == 3370624)",
            "timeout-minutes: 2", "permissions: {}",
            "GH_TOKEN: ${{ secrets.AUTO_MERGE_TOKEN }}",
        ):
            self.assertIn(required, WORKFLOW)
        self.assertNotIn("uses:", WORKFLOW)
        self.assertNotIn("github.token", WORKFLOW)
        self.assertNotIn("--admin", WORKFLOW)

    def test_missing_token_fails_and_valid_token_only_enables_squash(self):
        with tempfile.TemporaryDirectory() as directory:
            gh = Path(directory) / "gh"
            gh.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
            gh.chmod(0o755)
            for token in ("", "test-token"):
                env = {
                    "PATH": directory + os.pathsep + os.defpath,
                    "GH_TOKEN": token, "GH_REPO": "owner/repo",
                    "PR_NUMBER": "42", "HEAD_SHA": "abc123",
                }
                result = subprocess.run(
                    ["/bin/bash", "-e", "-c", SCRIPT], env=env,
                    capture_output=True, text=True, timeout=5,
                )
                if not token:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("::error::Set AUTO_MERGE_TOKEN", result.stdout)
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.splitlines(), [
                        "pr", "merge", "42", "--repo", "owner/repo",
                        "--auto", "--squash", "--match-head-commit", "abc123",
                    ])


if __name__ == "__main__":
    unittest.main()
