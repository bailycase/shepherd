#!/usr/bin/env python3
"""Optional release symbol upload. No source bundles, credentials or app data are uploaded."""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import urllib.request

CLI_URL = "https://github.com/getsentry/sentry-cli/releases/download/3.8.0/sentry-cli-Darwin-universal"
CLI_SHA256 = "2c26914636c47ab9bf9e710484ad7b44d371cbec8bd29cafb36b3cf877bf4285"


def upload(products, environment):
    required = ("SHEPHERD_SENTRY_DSN", "SENTRY_ORG", "SENTRY_PROJECT", "SENTRY_AUTH_TOKEN")
    if not all(environment.get(key, "").strip() for key in required):
        print("::notice::Sentry symbol upload is not configured; retaining release dSYM archives.")
        return
    symbols = sorted(Path(products).glob("*.dSYM"))
    if not symbols:
        raise RuntimeError("No release dSYMs found")
    with tempfile.TemporaryDirectory(prefix="shepherd-sentry-") as temporary:
        binary = Path(temporary) / "sentry-cli"
        with urllib.request.urlopen(CLI_URL, timeout=30) as response:
            data = response.read(32 * 1024 * 1024 + 1)
        if hashlib.sha256(data).hexdigest() != CLI_SHA256:
            raise RuntimeError("Sentry CLI checksum mismatch")
        binary.write_bytes(data)
        binary.chmod(0o700)
        # Keep credentials in the environment, never argv or output. Do not upload source files.
        subprocess.run(
            [str(binary), "debug-files", "upload", "--wait", *map(str, symbols)],
            env=dict(environment), check=True, timeout=180,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
    print("Sentry release symbols uploaded.")


if __name__ == "__main__":
    try:
        upload(sys.argv[1], os.environ)
    except Exception:
        print("::warning::Sentry symbol upload failed; use the release dSYM archive to retry.")
        sys.exit(1)
