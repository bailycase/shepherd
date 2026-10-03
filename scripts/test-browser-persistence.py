#!/usr/bin/env python3
"""Run WebKit persistence tests with a shared scratch home, including exit-test children."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="sb-", dir="/tmp") as scratch:
        home = Path(scratch).resolve()
        tmp = home / "tmp"
        tmp.mkdir()
        environment = os.environ | {
            "HOME": str(home),
            "CFFIXED_USER_HOME": str(home),
            "TMPDIR": str(tmp) + "/",
            "SHEPHERD_BROWSER_TEST_HOME": str(home),
        }
        result = subprocess.run(
            ["swift", "test", "--no-parallel"] + (sys.argv[1:] or ["--filter", "ShepherdApp.*Browser"]),
            cwd=Path(__file__).resolve().parent.parent,
            env=environment,
            timeout=300,
        )
        raise SystemExit(result.returncode)
