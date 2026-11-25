#!/usr/bin/env python3
"""Records and verifies a release package's provenance between the build and publish jobs."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys


class RunnerError(Exception):
    pass


def manifest(directory, parent, attempt, sha, build, plan, verify=False):
    root = Path(directory)
    archive = root / plan["dmg"]
    if archive.name != plan["dmg"] or not archive.is_file():
        raise RunnerError("required release archive is missing")
    digest = hashlib.sha256()
    with archive.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    digest = digest.hexdigest()
    expected = {"parent_run": parent, "parent_attempt": attempt, "source_sha": sha,
                "build_number": build, "tag": plan["tag"], "version": plan["version"],
                "dmg": plan["dmg"], "sha256": digest}
    record = root / "release-package.json"
    policy = json.loads((root / "shepherd-appcast.json").read_text())
    if (type(policy.get("version")) is not int or policy["version"] != 1
            or policy.get("tag") != plan["tag"] or type(policy.get("eligible")) is not bool):
        raise RunnerError("invalid package eligibility metadata")
    if verify:
        if json.loads(record.read_text()) != expected:
            raise RunnerError("release package provenance or checksum mismatch")
    else:
        record.write_text(json.dumps(expected, sort_keys=True) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("manifest", "verify"))
    parser.add_argument("--directory", default=".")
    args = parser.parse_args()
    env = os.environ
    try:
        parent, attempt, build = (int(env[k]) for k in ("PARENT_RUN", "PARENT_ATTEMPT", "BUILD_NUMBER"))
        sha, plan = env["SOURCE_SHA"], json.loads(env["RELEASE_PLAN"])
        if not re.fullmatch(r"[0-9a-f]{40}", sha) or min(parent, attempt, build) < 1:
            raise RunnerError("invalid build identity")
        manifest(args.directory, parent, attempt, sha, build, plan, args.command == "verify")
        return 0
    except (RunnerError, ValueError, KeyError, OSError) as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
