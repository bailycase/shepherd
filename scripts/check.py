#!/usr/bin/env python3
"""Build one Swift test target and run it without taking over the Mac.

    scripts/check.py <TestTarget> [filter] [--build-only] [--verbose] [-- <testing-helper args>]

`swift test --filter` still builds every test target; this builds only <TestTarget> and its
dependencies. Builds from every worktree take one lock, so a second agent waits instead of
competing for cores and memory. Output keeps errors, failing tests and the summary.
"""

import argparse
import fcntl
import itertools
import os
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / ".build"
LOCK = Path(f"/tmp/shepherd-swift-build-{os.getuid()}.lock")
ANSI = re.compile(r"\x1b\[[0-9;]*m")
# Swift Testing starts each event with an SF Symbol (Private Use plane); arguments can span lines.
EVENT_START = re.compile("^[\U000F0000-\U0010FFFF]|^\\d{4}-\\d\\d-\\d\\dT")  # or an app log line
TEST_NOISE = re.compile(r"^\d{4}-\d\d-\d\dT.*\[(DEBUG|INFO)\]|(started|passed after [0-9.]+ seconds?|skipped.*)\.?\s*$|Testing Library Version|Target Platform")
SOURCE_FRAME = re.compile(r"^ *\d* \| ")


def build(target, verbose):
    jobs = max(2, (os.cpu_count() or 8) - 4)
    command = ["nice", "-n", "10", "swift", "build", "--target", target,
               "--disable-index-store", "-j", str(jobs)]
    started = time.monotonic()
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    lines = ANSI.sub("", result.stdout + result.stderr).splitlines()
    if verbose:
        print("\n".join(lines))
    elif result.returncode:
        # Located diagnostics and their source excerpts, not command lines or progress.
        kept, framing = [], False
        for line in lines:
            framing = bool(re.search(r":\d+:\d+: error:", line)) or (framing and bool(SOURCE_FRAME.match(line)))
            if framing:
                kept.append(line)
        print("\n".join(kept or [line[:300] for line in lines[-40:]]))
    seconds = time.monotonic() - started
    print(f"Build {'failed' if result.returncode else 'complete'}: {target} ({seconds:.0f}s)")
    return result.returncode


def run(target, test_filter, extra, verbose):
    toolchain = Path(subprocess.run(["xcrun", "--find", "swift"], capture_output=True, text=True,
                                    check=True).stdout.strip()).parents[1]
    platform = Path(subprocess.run(["xcrun", "--show-sdk-platform-path"], capture_output=True,
                                   text=True, check=True).stdout.strip()) / "Developer"
    # The same helper and framework paths `swift test` uses on macOS.
    command = [str(toolchain / "libexec/swift/pm/swiftpm-testing-helper"),
               "--test-bundle-path", str(BUILD / f"debug/{target}.xctest/Contents/MacOS/{target}"),
               "--testing-library", "swift-testing"]
    command += ["--filter", test_filter] if test_filter else []
    env = dict(os.environ, DYLD_FRAMEWORK_PATH=str(platform / "Library/Frameworks"),
               DYLD_LIBRARY_PATH=str(platform / "usr/lib"))
    process = subprocess.Popen(command + extra, cwd=ROOT, env=env, text=True,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    event = ""
    for line in itertools.chain(process.stdout, ["\U000F0000\n"]):  # sentinel flushes the last event
        line = ANSI.sub("", line)
        if event and EVENT_START.match(line):
            if verbose or "Test run with" in event or not TEST_NOISE.search(event):
                print(event, end="", flush=True)
            event = ""
        event += line
    return process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("target", help="a test target, e.g. ShepherdCoreUnitTests")
    parser.add_argument("filter", nargs="?", help="Swift Testing filter, e.g. PaneNodeTests")
    parser.add_argument("--build-only", action="store_true")
    parser.add_argument("--verbose", action="store_true", help="print every build and test line")
    args, extra = parser.parse_known_args()
    extra = [arg for arg in extra if arg != "--"]

    with LOCK.open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("Waiting for another Shepherd build to finish...", flush=True)
            fcntl.flock(lock, fcntl.LOCK_EX)
        status = build(args.target, args.verbose)
    if status or args.build_only:
        return status
    return run(args.target, args.filter, extra, args.verbose)


if __name__ == "__main__":
    sys.exit(main())
