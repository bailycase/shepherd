#!/usr/bin/env python3
"""Move AGENTS.md's long reference sections into docs/, moving every line and rewriting none.

AGENTS.md is loaded into every agent thread, so it is now a short file of rules and pointers.
Its reference sections (testing, the source map, data flow, the remote protocol, releases,
the rules that are easy to break, gotchas, the environment variables) moved here, by
heading. This script is the move, so it can be run again from the old text:

    git show origin/nightly:AGENTS.md > /tmp/AGENTS.old.md
    python3 scripts/split_agents_md.py --source /tmp/AGENTS.old.md
    python3 scripts/rewrite_doc_refs.py

Run it only from the old text: after the split landed, docs/*.md are edited directly. It
keeps each section's text byte for byte (headings become each file's title; relative links
are re-pointed from the repo root to docs/), fails on a section it has no route for, and
proves that the multiset of non-heading lines is the same before and after, apart from the
one paragraph that told agents DESIGN.md "is the authority" (replaced by AGENTS.md's design
procedure).
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from docsplit import (  # noqa: E402
    body_counter,
    clean_title,
    counter_diff,
    headings,
    rebase_links,
)

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = "docs"

# file -> (title, "Read when" line). The title is used when a file holds several sections or
# has none of its own.
FILES: dict[str, tuple[str, str]] = {
    "overview.md": ("Shepherd in brief",
                    "Read when you need the product model on one page: agents, terminals, spaces, lifetime and remote."),
    "build-and-run.md": ("Build, run, test",
                         "Read when you build, run or test Shepherd: the schemes, the pi engine and the exact commands."),
    "environment.md": ("Environment variables",
                       "Read when you set, read or debug an environment variable: Shepherd's, pi's, or the test isolation's."),
    "testing.md": ("Testing",
                   "Read when you write or change a test, pick a test tier, touch CI, or need the coverage that must not be dropped."),
    "source-map.md": ("Source map",
                      "Read when you look for where something lives or add a file: every module and source file, in one map."),
    "data-flow.md": ("Data flow",
                     "Read when you change how an agent launches, how status is reported, how automations run, or what the server owns."),
    "remote-protocol.md": ("Remote",
                           "Read when you change the remote listener, its protocol, its auth, or a client's connection."),
    "rules.md": ("Rules that are easy to break",
                 "Read when your change touches a contract, an extension, the server's queue, terminals, the browser, layouts or repository mutation."),
    "releases.md": ("Branches, commits and releases",
                    "Read when you branch, commit, open a PR, cut a release, or touch the release workflow, signing or the appcasts."),
    "gotchas.md": ("Gotchas",
                   "Read when something odd happens with sockets, frame sizes, replay, skills, pi's folders, quitting or xcodebuild."),
}

ROUTES: dict[str, str] = {
    "Build, run, test": "build-and-run.md",
    "Testing": "testing.md",
    "Source map": "source-map.md",
    "Data flow": "data-flow.md",
    "Remote": "remote-protocol.md",
    "Rules that are easy to break": "rules.md",
    "Git": "releases.md",
    "Releases": "releases.md",
    "Gotchas": "gotchas.md",
}

# Within a section, the line that starts a second file.
CUTS = {"Build, run, test": ("**Environment variables:**", "environment.md")}

# A paragraph that is replaced, not moved: it called DESIGN.md "the authority".
REPLACED = re.compile(r"^\*\*Read \[DESIGN\.md\]")


def read_source(args: argparse.Namespace) -> str:
    if args.source:
        return Path(args.source).read_text(encoding="utf-8")
    out = subprocess.run(["git", "show", f"{args.rev}:AGENTS.md"], cwd=ROOT, check=True,
                         capture_output=True, text=True)
    return out.stdout


def transform(line: str) -> str:
    return rebase_links(line, ".", OUT_DIR)


def paragraph_end(lines: list[str], start: int) -> int:
    i = start
    while i < len(lines) and lines[i].strip():
        i += 1
    return i


def build(lines: list[str]):
    hs = headings(lines)
    h2 = [h for h in hs if h.level == 2]
    if not h2:
        sys.exit("error: no ## sections found")
    pre_end = h2[0].line
    missing = [clean_title(h.title) for h in h2 if clean_title(h.title) not in ROUTES]
    if missing:
        sys.exit(f"error: no route for sections {missing}; add them to ROUTES in scripts/split_agents_md.py")

    # The preamble (before the first ##): the title and the product summary, minus the
    # replaced paragraph.
    pre: list[str] = []
    dropped: list[str] = []
    i = 1  # line 0 is the "# AGENTS.md" title
    while i < pre_end:
        if REPLACED.match(lines[i]):
            j = paragraph_end(lines, i)
            dropped = lines[i:j]
            i = j
            continue
        pre.append(lines[i])
        i += 1
    if not dropped:
        print("warning: the 'Read DESIGN.md' paragraph was not found; nothing replaced", file=sys.stderr)

    parts: dict[str, list[list[str]]] = {"overview.md": [pre]}
    for n, h in enumerate(h2):
        end = h2[n + 1].line if n + 1 < len(h2) else len(lines)
        name = clean_title(h.title)
        body = lines[h.line:end]
        dest = ROUTES[name]
        cut = CUTS.get(name)
        if cut:
            marker, other = cut
            at = next((k for k, l in enumerate(body) if l.strip() == marker), None)
            if at is None:
                sys.exit(f"error: marker {marker!r} not found in section {name}")
            parts.setdefault(other, []).append(body[at:])
            body = body[:at]
        parts.setdefault(dest, []).append(body)

    files: dict[str, list[str]] = {}
    for name, chunks in parts.items():
        title, read_when = FILES[name]
        sections = [c for c in chunks if c and c[0].startswith("## ")]
        out: list[str] = []
        if len(sections) == 1 and len(chunks) == 1:
            c = chunks[0]
            out += ["# " + c[0][3:], "", f"> {read_when}"]
            if c[1].strip():
                out.append("")
            out += [transform(l) for l in c[1:]]
        else:
            out += [f"# {title}", "", f"> {read_when}", ""]
            for c in chunks:
                if c and c[0].startswith("## "):
                    out += [c[0]] + [transform(l) for l in c[1:]]
                else:
                    body = list(c)
                    while body and not body[0].strip():
                        body.pop(0)
                    out += [transform(l) for l in body]
        while out and not out[-1].strip():
            out.pop()
        files[name] = out
    return files, dropped, pre_end


def check(lines: list[str], files: dict[str, list[str]], dropped: list[str]) -> None:
    drop = {l.rstrip() for l in dropped}
    old_lines = [transform(l) for l in lines[1:] if l.rstrip() not in drop]
    old = body_counter(old_lines)
    generated = {f"> {FILES[n][1]}" for n in files}
    new_lines: list[str] = []
    for ls in files.values():
        new_lines += [l for l in ls if l not in generated]
    new = body_counter(new_lines)
    lost, extra = counter_diff(old, new)
    if lost or extra:
        for l, n in list(lost.items())[:10]:
            print(f"LOST x{n}: {l[:100]}", file=sys.stderr)
        for l, n in list(extra.items())[:10]:
            print(f"EXTRA x{n}: {l[:100]}", file=sys.stderr)
        sys.exit("error: the split did not conserve lines")
    print(f"conserved {sum(old.values())} body lines across {len(files)} files "
          f"({len(dropped)} replaced lines not moved)")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--source", help="path of the old AGENTS.md")
    ap.add_argument("--rev", help="git revision holding the old AGENTS.md (git show REV:AGENTS.md)")
    ap.add_argument("--out", default=OUT_DIR, help="output folder, relative to the repo root")
    ap.add_argument("--verify", action="store_true",
                    help="check the files already on disk (after rewrite_doc_refs.py) instead of writing")
    args = ap.parse_args()
    if not args.source and not args.rev:
        ap.error("give --source FILE or --rev REV")
    lines = read_source(args).split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    files, dropped, _pre_end = build(lines)
    out = ROOT / args.out
    if args.verify:
        def on_disk(name: str) -> list[str]:
            ls = (out / name).read_text(encoding="utf-8").split("\n")
            return ls[:-1] if ls and ls[-1] == "" else ls

        check(lines, {n: on_disk(n) for n in files}, dropped)
        return
    check(lines, files, dropped)
    out.mkdir(parents=True, exist_ok=True)
    for name, ls in files.items():
        (out / name).write_text("\n".join(ls) + "\n", encoding="utf-8")
    print(f"wrote {len(files)} files to {args.out}: " + ", ".join(sorted(files)))


if __name__ == "__main__":
    main()
