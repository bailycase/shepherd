#!/usr/bin/env python3
"""Tell a stale incremental build's link failure from a real build failure.

A restored build cache can hold objects compiled against an older module: the
link then fails with undefined symbols although every source compiles. The
swift-build action rebuilds from scratch once when the log says exactly that,
and fails at once on anything else (a compile error, a crash, a failure with no
undefined symbols).

    ci_stale_link.py <build log>

Exits 0 and prints the objects that referenced missing symbols when the log is
a stale link failure; exits 1 otherwise.
"""
import re
import sys

# A diagnostic starts at column 0 (`File.swift:3:4: error:`, `error:`,
# `clang: error:`); source excerpts under a diagnostic are indented.
ERROR = re.compile(r"^(?:\S.*?: )?(?:fatal )?error: ")
# What SwiftPM and the linker print for a failed link, and nothing else.
LINK_ERRORS = (
    re.compile(r"^error: link command failed\b"),
    re.compile(r"^clang: error: linker command failed\b"),
)
UNDEFINED = re.compile(r"^Undefined symbols for architecture \S+:")
REFERENCED_IN = re.compile(r" in (\S+\.o)$")


def stale_objects(log):
    """The objects that referenced missing symbols, or None if `log` shows any other failure."""
    lines = log.splitlines()
    if not any(UNDEFINED.match(line) for line in lines):
        return None
    errors = [line for line in lines if ERROR.match(line)]
    if not errors or any(not any(p.match(line) for p in LINK_ERRORS) for line in errors):
        return None
    objects = []
    for line in lines:
        m = REFERENCED_IN.search(line)
        if m and m[1] not in objects:
            objects.append(m[1])
    return objects


def main(argv):
    if len(argv) != 2:
        sys.exit(__doc__)
    with open(argv[1], encoding="utf-8", errors="replace") as f:
        objects = stale_objects(f.read())
    if objects is None:
        return 1
    print(", ".join(objects) or "unknown objects")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
