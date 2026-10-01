#!/usr/bin/env python3
"""Point `DESIGN.md › <Section>` and `AGENTS.md › <Section>` references at the files the
sections moved to.

DESIGN.md's specs moved to docs/design/ and AGENTS.md's reference sections to docs/, so a
comment in source that says `DESIGN.md › Thread › Can't start` now reads
`docs/design/thread.md › Thread › Can't start`. The section name stays, so the reference is
still searchable. Run it after split_design_md.py and split_agents_md.py; it changes only
the `DESIGN.md` or `AGENTS.md` token before ` ›` and does nothing the second time.

    python3 scripts/rewrite_doc_refs.py --dry-run   # list what would change
    python3 scripts/rewrite_doc_refs.py             # rewrite in place

References that name no section (`DESIGN.md` alone, a Markdown link) are not touched: they
stay pointing at the rules files, which still exist.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from docsplit import Section, clean_title, lead_in_blocks, resolve_entry, sections_of, tokens  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
DESIGN_DIR = ROOT / "docs" / "design"
AGENT_DOCS = ["rules.md", "testing.md", "gotchas.md", "source-map.md", "data-flow.md",
              "remote-protocol.md", "releases.md", "build-and-run.md", "environment.md", "overview.md"]
EXTENSIONS = {".swift", ".md", ".ts", ".mjs", ".py", ".yml", ".yaml", ".c", ".h", ".sh"}
# Not edited: the hand-written rule files, and this tool's own text.
SKIP = {"DESIGN.md", "AGENTS.md", "scripts/rewrite_doc_refs.py", "scripts/split_design_md.py",
        "scripts/split_agents_md.py", "scripts/docsplit.py", "Tests/Release/test_agent_docs.py",
        "Tests/Release/test_design_section.py"}

# Names an old reference used that are not headings today.
DESIGN_ALIASES = {
    "side pane": "Side pane: Changes and the subagent inspector",
    "right pane": "Side pane: Changes and the subagent inspector",
    "review": "Side pane: Changes and the subagent inspector",
    "terminal panes": "Terminal panel",
    "questions": "Composer, questions, and menus",
    "welcome": "Dialogs and sheets",
}

REF = re.compile(r"(?P<doc>DESIGN|AGENTS)\.md ›")


class Index:
    def __init__(self, files: dict[str, list[str]], aliases: dict[str, str] | None = None):
        self.aliases = aliases or {}
        self.lines = files
        self.sections: list[Section] = []
        for name, lines in files.items():
            self.sections += sections_of(name, lines)
        self.leads: list[tuple[list[str], str]] = []
        for name, lines in files.items():
            for first, _end, text, _level in lead_in_blocks(lines, 0, len(lines), bullets=True):
                self.leads.append((tokens(text), name))

    def resolve(self, name: str) -> str | None:
        words = name.split()
        while words:
            cand = " ".join(words)
            alias = self.aliases.get(" ".join(tokens(cand)))
            found = resolve_entry(alias or cand, self.sections)
            if found:
                return found[0].section.file
            want = tokens(cand)
            if want:
                for t, f in self.leads:
                    if t[: len(want)] == want:
                        return f
            words.pop()
        return None


def load(paths: list[Path], aliases: dict[str, str] | None = None) -> Index:
    return Index({p.name: p.read_text(encoding="utf-8").split("\n") for p in paths if p.exists()}, aliases)


def name_after(lines: list[str], i: int, m: re.Match) -> str:
    """The section name after `DESIGN.md ›`, which may wrap onto the next line of a comment."""
    rest = lines[i][m.end():].strip()
    if not re.search(r"[);(\u203a]", rest) and i + 1 < len(lines):
        more = re.sub(r"^\s*(?:///?|\*|#)?\s*", "", lines[i + 1])
        rest = (rest + " " + more).strip()
    return re.split(r" \u203a|\)|;|\(", rest)[0].strip()


def tracked_files() -> list[str]:
    out = subprocess.run(["git", "ls-files", "--cached", "--others", "--exclude-standard"], cwd=ROOT,
                         check=True, capture_output=True, text=True)
    return [f for f in out.stdout.split("\n") if f and Path(f).suffix in EXTENSIONS and f not in SKIP]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    design = load(sorted(p for p in DESIGN_DIR.glob("*.md") if p.name != "README.md"), DESIGN_ALIASES)
    agents = load([ROOT / "docs" / n for n in AGENT_DOCS])
    changed = 0
    per_file: Counter = Counter()
    unresolved: list[tuple[str, int, str]] = []
    report: Counter = Counter()
    for rel in tracked_files():
        path = ROOT / rel
        try:
            lines = path.read_text(encoding="utf-8").split("\n")
        except (UnicodeDecodeError, FileNotFoundError):
            continue
        if not any("md ›" in l for l in lines):
            continue
        edited = False
        for i, line in enumerate(lines):
            def sub(m: re.Match) -> str:
                nonlocal edited
                name = name_after(lines, i, m)
                if m.group("doc") == "DESIGN":
                    target = design.resolve(name)
                    prefix = "docs/design/"
                else:
                    target = agents.resolve(name)
                    prefix = "docs/"
                if target is None:
                    unresolved.append((rel, i + 1, f"{m.group('doc')}.md › {name}"))
                    return m.group(0)
                edited = True
                report[(m.group("doc"), name, prefix + target)] += 1
                return f"{prefix}{target} ›"

            lines[i] = REF.sub(sub, line)
        if edited:
            changed += 1
            per_file[rel] += 1
            if not args.dry_run:
                path.write_text("\n".join(lines), encoding="utf-8")
    for (doc, name, target), n in sorted(report.items(), key=lambda kv: (kv[0][2], kv[0][1])):
        print(f"{n:3d}  {doc}.md › {name}  ->  {target}")
    print(f"{'would rewrite' if args.dry_run else 'rewrote'} {sum(report.values())} references in {changed} files")
    if unresolved:
        print("\nUNRESOLVED (name no heading; fix by hand or add an alias):", file=sys.stderr)
        for rel, ln, text in unresolved:
            print(f"  {rel}:{ln}: {text}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
