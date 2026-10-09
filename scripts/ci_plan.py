#!/usr/bin/env python3
"""CI's two small decisions (.github/workflows/ci.yml).

    ci_plan.py <changed-files>    prints `true` when a change can affect Swift, else `false`
    ci_plan.py --quiet            reads `swift test` output on stdin, prints failures and the
                                  summary line, and exits 1 when the run failed

A pull request that changes only docs, templates, the iOS client or the files Tests/Release and
the node tests already cover runs no Swift. Anything else runs everything: there is one job, so
there is nothing to pick.
"""
from __future__ import annotations

import fnmatch
import re
import sys

# Paths no Swift test reads. A path matching none of these runs the Swift job.
NO_SWIFT = (
    "docs/*", "*.md", "LICENSE",
    ".github/ISSUE_TEMPLATE/*", ".github/pull_request_template.md",
    ".github/workflows/release.yml", ".github/workflows/release-build.yml", ".github/workflows/pr-body.yml",
    ".github/CODEOWNERS",
    "App/iOS/*", "Tests/ShepherdIOSChecks/*", "App/Info.plist", "App/*.icon/*", "App/*.entitlements",
    "App/ShepherdLauncher.swift",
    "Extensions/*", "Tests/Extensions/*.mjs", "Tests/Extensions/fixtures/*", "Tests/Release/*",
    "scripts/release*.py", "scripts/sign-*.sh", "scripts/check_pr_body.py", "scripts/design_section.py",
    "scripts/context-budget.json", "scripts/sync-embedded-extension.py", "scripts/test-browser-persistence.py",
)


def affects_swift(paths: list[str]) -> bool:
    """`*` crosses folders here: these globs name whole trees and extensions."""
    for path in paths:
        if not any(fnmatch.fnmatchcase(path, pattern) for pattern in NO_SWIFT):
            return True
    return False


SUMMARY = re.compile(r"Test run with \d+ tests? in \d+ suites? (passed|failed) after")
ISSUE = re.compile(r"(recorded an issue|Expectation failed|failed after .* with \d+ issues?|Time limit was exceeded|Caught error)")


def summarize(lines, out=sys.stdout) -> int:
    """Only what someone reading a failure needs: lines that record issues, and the run's summary."""
    verdict = None
    tests = 0
    for line in lines:
        if ISSUE.search(line):
            out.write(line if line.endswith("\n") else line + "\n")
        summary = SUMMARY.search(line)
        if summary:
            verdict = summary.group(1)
            tests += int(re.search(r"with (\d+) test", line).group(1))
            out.write(line if line.endswith("\n") else line + "\n")
    if verdict is None:
        out.write("::error::swift test printed no summary (did it crash?)\n")
        return 1
    if tests == 0:
        out.write("::error::swift test ran no tests\n")
        return 1
    return 0 if verdict == "passed" else 1


def main(argv: list[str]) -> int:
    if argv[1:] == ["--quiet"]:
        return summarize(sys.stdin)
    if len(argv) != 2:
        sys.stderr.write(__doc__)
        return 2
    with open(argv[1], encoding="utf-8") as f:
        paths = [line.strip() for line in f if line.strip()]
    print("true" if affects_swift(paths) else "false")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
