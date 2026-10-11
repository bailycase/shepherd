#!/usr/bin/env python3
"""Bounded retention for Shepherd's reproducible Actions caches, never release assets."""
import argparse
import json
import os
import re
import subprocess
import time

# Unknown keys and non-PR/non-nightly refs belong to their owners, not this cleanup.
FAMILIES = (
    (r"spm-macOS-[0-9a-f]{12}-[0-9a-f]{64}-[0-9a-f]{40}", "spm"),
    (r"xcode-macOS-(Nightly|Release)-[0-9a-f]{12}-[0-9a-f]{12}-[0-9a-f]{40}", "xcode"),
    (r"pi-(engine|tests)-[0-9a-f]{64}", "pi"),
)
MAX_DELETIONS = 20
KEEP_BASELINES = 2


def family(key):
    for pattern, name in FAMILIES:
        match = re.fullmatch(pattern, key)
        if match:
            return name + ("-" + match[1] if match.lastindex else "")
    return None


def candidates(caches, pull_state, *, closed_only=False):
    """Keep the two newest trusted baselines and every open/unknown PR's caches."""
    kept = {}
    states = {}
    result = []
    for cache in sorted(caches, key=lambda row: row["created_at"], reverse=True):
        group = family(cache["key"])
        if not group:
            continue
        ref = cache["ref"]
        pull = re.fullmatch(r"refs/pull/([1-9][0-9]*)/merge", ref)
        if pull:
            number = int(pull[1])
            if number not in states:
                states[number] = pull_state(number)
            remove = states[number] == "closed"
        elif ref == "refs/heads/nightly" and not closed_only:
            kept[group] = kept.get(group, 0) + 1
            remove = kept[group] > KEEP_BASELINES
        else:
            remove = False
        if remove:
            result.append(cache)
            if len(result) == MAX_DELETIONS:
                break
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--delete", action="store_true", help="default is a read-only plan")
    parser.add_argument("--closed-only", action="store_true", help="do not rotate nightly baselines before building")
    args = parser.parse_args()
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        parser.error("GITHUB_REPOSITORY must name one repository")
    if args.delete and os.environ.get("GITHUB_REF") != "refs/heads/nightly":
        parser.error("cache deletion runs only from the trusted nightly branch")
    deadline = time.monotonic() + 180

    def api(path, *flags):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("cache retention reached its three-minute limit")
        # Never print gh stderr, tokens, full cache keys, or API payloads.
        response = subprocess.run(["gh", "api", f"repos/{repo}/{path}", *flags],
                                  capture_output=True, text=True, timeout=min(30, remaining))
        if response.returncode:
            raise RuntimeError("cache retention API request failed; no further deletions")
        return json.loads(response.stdout) if response.stdout.strip() else None

    pages = api("actions/caches?per_page=100&sort=created_at&direction=desc", "--paginate", "--slurp")
    caches = [row for page in pages for row in page["actions_caches"]]
    if len(caches) > 500:
        raise RuntimeError("cache inventory exceeds 500 entries; review it manually")
    selected = candidates(caches, lambda number: api(f"pulls/{number}")["state"], closed_only=args.closed_only)
    print(f"Cache retention: {len(selected)} selected, {sum(row['size_in_bytes'] for row in selected)} bytes; "
          f"delete={args.delete}, maximum={MAX_DELETIONS}")
    for cache in selected:
        if args.delete:
            api(f"actions/caches/{int(cache['id'])}", "--method", "DELETE")
            print(f"Deleted cache ID {int(cache['id'])}")


if __name__ == "__main__":
    try:
        main()
    except (KeyError, ValueError, OSError, TimeoutError, RuntimeError, subprocess.TimeoutExpired) as error:
        raise SystemExit(f"Cache retention stopped: {type(error).__name__}") from None
