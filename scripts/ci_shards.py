#!/usr/bin/env python3
"""Split the test suites into equal shards from recorded times, and keep those times current.

    ci_shards.py show   --list tests.txt [--times Tests/ci-suite-times.json] --shards 4
    ci_shards.py record --times Tests/ci-suite-times.json [--list tests.txt] suite-times.json …

`Tests/ci-suite-times.json` holds each suite's last measured seconds, keyed by `Module.Suite`,
the unit of sharding (a shard runs whole suites: `--filter '^Module\\.(A|B)/'`). Suites go to
shards greedily, longest first, each to the lightest shard so far. A suite the file has never
seen is placed last, each on the lightest shard at that point, so a new suite can never pile
up anywhere. Every shard computes the same split from the same `swift test list`, so the shards
are a partition by construction; `check_partition` proves it each time.

Standard library only; the logic is tested in Tests/Release/test_ci_shards.py.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ci_testlog import suite_of  # noqa: E402

DEFAULT_TIMES = os.path.join("Tests", "ci-suite-times.json")
# What a suite the times file has not seen is assumed to cost, in seconds.
UNKNOWN_SECONDS = 2.0
# The blend of an old time and a new measurement when the file is regenerated.
KEEP = 0.5


def read_times(path: str) -> dict[str, float]:
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        return {}
    return {k: float(v) for k, v in data.get("suites", {}).items()}


def write_times(path: str, suites: dict[str, float], note: str = "") -> None:
    body = {
        "version": 1,
        "about": "Seconds each test suite took on a CI runner, from scripts/ci_shards.py record. "
                 "The shards and the fast lane's shard count are balanced from it (the Testing docs).",
        "suites": {k: round(suites[k], 2) for k in sorted(suites)},
    }
    if note:
        body["measured"] = note
    with open(path, "w", encoding="utf-8") as f:
        json.dump(body, f, indent=1, ensure_ascii=False)
        f.write("\n")


def suites_of(ids: list[str]) -> dict[str, int]:
    """Suite id to its number of tests, in order of first appearance."""
    counts: dict[str, int] = {}
    for test_id in ids:
        counts[suite_of(test_id)] = counts.get(suite_of(test_id), 0) + 1
    return counts


def assign(suites: list[str], times: dict[str, float], shards: int) -> list[list[str]]:
    """Shard `i` (0-based) gets `result[i]`: the suites in a stable order."""
    if shards < 1:
        raise ValueError("a run has at least one shard")
    load = [0.0] * shards
    result: list[list[str]] = [[] for _ in range(shards)]
    known = sorted((s for s in suites if s in times), key=lambda s: (-times[s], s))
    unknown = sorted(s for s in suites if s not in times)
    for suite in known + unknown:
        weight = times.get(suite, UNKNOWN_SECONDS)
        lightest = min(range(shards), key=lambda i: (load[i], i))
        result[lightest].append(suite)
        load[lightest] += weight
    return [sorted(group) for group in result]


def check_partition(assignment: list[list[str]], suites: list[str]) -> None:
    """Raise unless every suite is in exactly one shard and nothing else is."""
    seen: dict[str, int] = {}
    for index, group in enumerate(assignment):
        for suite in group:
            if suite in seen:
                raise ValueError(f"suite {suite} is in shards {seen[suite] + 1} and {index + 1}")
            seen[suite] = index
    missing = sorted(set(suites) - set(seen))
    extra = sorted(set(seen) - set(suites))
    if missing or extra:
        raise ValueError(f"shards miss {missing[:5]} and add {extra[:5]}")


def shard_seconds(group: list[str], times: dict[str, float]) -> float:
    return sum(times.get(s, UNKNOWN_SECONDS) for s in group)


def filters(group: list[str]) -> list[str]:
    """`--filter` regexes that select exactly these suites: one per module, an alternation of suites."""
    by_module: dict[str, list[str]] = {}
    for suite in group:
        module, _, name = suite.partition(".")
        by_module.setdefault(module, []).append(name)
    out = []
    for module in sorted(by_module):
        names = "|".join(re.escape(n) for n in sorted(by_module[module]))
        out.append(f"^{re.escape(module)}\\.({names})/")
    return out


def select(suites: list[str], selection: dict) -> list[str]:
    """The suites a run covers. `{"all": true}`, or the union of the unit tier and the named parts.

    `selection` is the plan's JSON: `unit` (every `*UnitTests` suite), `regexes` (matched against
    `Module.Suite`), `smoke` and `suites` (exact ids).
    """
    if selection.get("all"):
        return list(suites)
    chosen = set()
    patterns = [re.compile(r) for r in selection.get("regexes", [])]
    exact = set(selection.get("smoke", [])) | set(selection.get("suites", []))
    for suite in suites:
        if selection.get("unit") and suite.split(".", 1)[0].endswith("UnitTests"):
            chosen.add(suite)
        elif suite in exact or any(p.search(suite) for p in patterns):
            chosen.add(suite)
    return sorted(chosen)


def merge_times(
    old: dict[str, float], observations: list[dict[str, float]], known: set[str] | None = None
) -> dict[str, float]:
    """The times file after new measurements: each suite's old time blended halfway toward
    the mean of what was observed, never below 0.01 s; suites no longer in `known` dropped."""
    seen: dict[str, list[float]] = {}
    for obs in observations:
        for suite, seconds in obs.items():
            seen.setdefault(suite, []).append(seconds)
    merged = dict(old)
    for suite, values in seen.items():
        mean = sum(values) / len(values)
        merged[suite] = max(0.01, mean if suite not in old else KEEP * old[suite] + (1 - KEEP) * mean)
    if known is not None:
        merged = {k: v for k, v in merged.items() if k in known}
    return merged


def read_list(path: str) -> list[str]:
    with open(path, encoding="utf-8") as f:
        return [line.strip() for line in f if "/" in line]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    show = sub.add_parser("show", help="print the split of a `swift test list` into shards")
    show.add_argument("--list", required=True)
    show.add_argument("--times", default=DEFAULT_TIMES)
    show.add_argument("--shards", type=int, default=4)
    record = sub.add_parser("record", help="blend new suite-times.json files into the times file")
    record.add_argument("--times", default=DEFAULT_TIMES)
    record.add_argument("--list", help="drop suites that are not in this `swift test list`")
    record.add_argument("--measured", default="", help="a note on where the numbers came from")
    record.add_argument("files", nargs="+")
    args = parser.parse_args(argv)

    if args.command == "show":
        ids = read_list(args.list)
        counts = suites_of(ids)
        times = read_times(args.times)
        groups = assign(list(counts), times, args.shards)
        check_partition(groups, list(counts))
        for i, group in enumerate(groups, 1):
            print(f"shard {i}/{args.shards}: {len(group)} suites, {shard_seconds(group, times):.0f} s, "
                  f"{sum(counts[s] for s in group)} tests")
        new = sorted(s for s in counts if s not in times)
        if new:
            print(f"{len(new)} suites are not in {args.times}: {', '.join(new[:8])}{' …' if len(new) > 8 else ''}")
        return 0

    observations = []
    for path in args.files:
        with open(path, encoding="utf-8") as f:
            observations.append({k: float(v) for k, v in json.load(f).get("suites", {}).items()})
    known = set(suites_of(read_list(args.list))) if args.list else None
    merged = merge_times(read_times(args.times), observations, known)
    write_times(args.times, merged, args.measured)
    print(f"{args.times}: {len(merged)} suites, {sum(merged.values()):.0f} s in all")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
