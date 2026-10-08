#!/usr/bin/env python3
"""Default-branch bootstrap fence; nightly owns the actual Self-hosted implementation."""
import sys


def main():
    print("::error::Registration-only workflow: dispatch release-build.yml on nightly from an active Release parent.",
          file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
