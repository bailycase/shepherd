#!/usr/bin/env python3
"""Print one board's or one heading's spec from docs/design/, never the whole design.

    python3 scripts/design_section.py ComposerSpeed         # a board from docs/design/README.md's index
    python3 scripts/design_section.py "Up next"             # a heading, fuzzy-matched
    python3 scripts/design_section.py "iOS: iPad › Thread"  # a path, to choose between two headings
    python3 scripts/design_section.py ComposerSpeed --full  # the whole section, not the narrowed block
    python3 scripts/design_section.py ComposerSpeed --outline
    python3 scripts/design_section.py --list                # the files, what each is for
    python3 scripts/design_section.py --boards | --headings

Every printed block starts with its file and 1-based line range, so you can read more with
`sed -n 'A,Bp' <file>`. An ambiguous or unknown name fails with the candidates and exit
status 2. Standard library only.
"""
from __future__ import annotations

import argparse
import difflib
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from docsplit import (  # noqa: E402
    Section,
    headings,
    lead_in_blocks,
    resolve_entry,
    sections_of,
    split_top,
    tokens,
)

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_DOCS = ROOT / "docs" / "design"


class Fail(Exception):
    pass


class Board:
    def __init__(self, names: list[str], files: list[str], specified: str, status: str):
        self.names, self.files, self.specified, self.status = names, files, specified, status


class Docs:
    def __init__(self, docs: Path):
        self.dir = docs
        self.lines: dict[str, list[str]] = {}
        self.sections: list[Section] = []
        for p in sorted(docs.glob("*.md")):
            if p.name == "README.md":
                continue
            self.lines[p.name] = p.read_text(encoding="utf-8").split("\n")
            self.sections += sections_of(p.name, self.lines[p.name])
        self.boards = self._boards(docs / "README.md")

    @staticmethod
    def _boards(readme: Path) -> list[Board]:
        if not readme.exists():
            return []
        out: list[Board] = []
        on = False
        for line in readme.read_text(encoding="utf-8").split("\n"):
            if line.startswith("## "):
                on = line.strip() == "## Board index"
                continue
            if not on or not line.startswith("| ") or line.startswith("| Board ") or line.startswith("| ---"):
                continue
            cells = [c.strip() for c in line.strip().strip("|").split(" | ")]
            if len(cells) != 4:
                continue
            files = re.findall(r"\]\(([^)]+\.md)\)", cells[1])
            out.append(Board([n.strip() for n in cells[0].split(",") if n.strip()], files, cells[2], cells[3]))
        return out

    def shown(self, name: str) -> str:
        p = self.dir / name
        try:
            return str(p.relative_to(ROOT))
        except ValueError:
            return str(p)


def pick_heading(query: str, sections: list[Section]) -> tuple[Section, list[Section]]:
    """The section a heading query names, plus other equally good candidates."""
    wanted = tokens(query)
    if not wanted:
        raise Fail("empty query")
    equal = [s for s in sections if tokens(s.title) == wanted]
    if equal:
        low = min(s.level for s in equal)
        top = [s for s in equal if s.level == low]
        if len(top) == 1:
            return top[0], [s for s in equal if s is not top[0]]
        raise Fail(ambiguous(query, top))
    n = len(wanted)

    def contains(s: Section) -> bool:
        have = tokens(s.title)
        return any(have[i:i + n] == wanted for i in range(len(have) - n + 1))

    near = [s for s in sections if contains(s)]
    if not near:
        raise Fail("")
    starts = [s for s in near if tokens(s.title)[:n] == wanted]
    pool = starts or near
    low = min(s.level for s in pool)
    top = [s for s in pool if s.level == low]
    if len(top) == 1:
        return top[0], [s for s in near if s is not top[0]]
    raise Fail(ambiguous(query, top))


def ambiguous(query: str, candidates: list[Section]) -> str:
    rows = "\n".join(f"  {s.file}:{s.start + 1}-{s.end}  {'#' * s.level} {s.title}" for s in candidates[:12])
    return (f"'{query}' is ambiguous; name one with a path such as \"<parent> › <heading>\", or "
            f"copy its full title:\n{rows}")


def find_board(query: str, boards: list[Board]) -> Board | None:
    q = query.strip().lower()
    for b in boards:
        if q in (n.lower() for n in b.names):
            return b
    return None


def fuzzy_boards(query: str, boards: list[Board]) -> list[Board]:
    q = query.strip().lower()
    return [b for b in boards if any(q in n.lower() for n in b.names)]


class Block:
    def __init__(self, file: str, start: int, end: int, label: str, note: str = ""):
        self.file, self.start, self.end, self.label, self.note = file, start, end, label, note


def blocks_for(docs: Docs, entry: str, full: bool) -> list[Block]:
    out: list[Block] = []
    for r in resolve_entry(entry, docs.sections):
        s = r.section
        if not full and r.focus:
            found: list[Block] = []
            have = docs.lines[s.file]
            leads = lead_in_blocks(have, s.start, s.end)
            for term in r.focus:
                want = tokens(term)
                if not want:
                    continue
                for first, end, text in leads:
                    t = tokens(text)
                    if any(t[i:i + len(want)] == want for i in range(len(t) - len(want) + 1)):
                        found.append(Block(s.file, first, end, f"{s.title} \u203a {text}",
                                           f"narrowed from {s.file}:{s.start + 1}-{s.end}; --full prints the section"))
                        break
            if found:
                out += found
                continue
        out.append(Block(s.file, s.start, s.end, s.title))
    return out


def collapse(found: list[Block]) -> list[Block]:
    """Drop blocks inside another printed block, and repeats."""
    out: list[Block] = []
    for b in found:
        if any(o.file == b.file and o.start <= b.start and b.end <= o.end for o in out):
            continue
        out = [o for o in out if not (o.file == b.file and b.start <= o.start and o.end <= b.end)]
        out.append(b)
    return out


def outline(docs: Docs, b: Block) -> list[str]:
    lines = docs.lines[b.file]
    out = []
    for h in headings(lines[b.start:b.end]):
        out.append(f"  {b.file}:{b.start + h.line + 1}  {'#' * h.level} {h.title}")
    for first, _end, text in lead_in_blocks(lines, b.start, b.end):
        out.append(f"  {b.file}:{first + 1}  **{text}**")
    return sorted(out, key=lambda r: int(r.split(":")[1].split()[0]))


def emit(docs: Docs, blocks: list[Block], mode: str, out) -> None:
    for b in blocks:
        head = f"--- {docs.shown(b.file)}:{b.start + 1}-{b.end}  {b.label}"
        if b.note:
            head += f"  ({b.note})"
        print(head, file=out)
        if mode == "outline":
            print("\n".join(outline(docs, b)), file=out)
        else:
            print("\n".join(docs.lines[b.file][b.start:b.end]).rstrip("\n"), file=out)
        print(file=out)


def run(query: str, docs: Docs, full: bool = False, outline_only: bool = False, out=None) -> int:
    out = out or sys.stdout
    mode = "outline" if outline_only else "text"
    query = query.replace(" > ", " › ")
    if "›" in query:  # a path: "Thread › Activity lines", "iOS: iPad › Thread"
        found = collapse(blocks_for(docs, query, full))
        if not found:
            raise Fail(f"no heading matches the path '{query}'. Try --headings, or a shorter name.")
        print(f"# path: {query}\n", file=out)
        emit(docs, found, mode, out)
        return 0
    board = find_board(query, docs.boards)
    if board is None:
        try:
            section, others = pick_heading(query, docs.sections)
        except Fail as e:
            if str(e):
                raise
            near = fuzzy_boards(query, docs.boards)
            if len(near) == 1:
                board = near[0]
            elif len(near) > 1:
                raise Fail(f"'{query}' matches several boards: " + ", ".join(n for b in near for n in b.names[:1]))
            else:
                names = [n for b in docs.boards for n in b.names] + [s.title for s in docs.sections]
                close = difflib.get_close_matches(query, names, n=5, cutoff=0.5)
                hint = f" Did you mean: {', '.join(close)}?" if close else ""
                raise Fail(f"no board or heading matches '{query}'.{hint} "
                           "Try --boards, --headings or --list.")
        else:
            print(f"# heading: {section.title}", file=out)
            if others:
                print("# also matches: " + "; ".join(f"{o.file}:{o.start + 1} {o.title}" for o in others[:5]), file=out)
            print(file=out)
            emit(docs, [Block(section.file, section.start, section.end, section.title)], mode, out)
            return 0
    print(f"# board: {', '.join(board.names)}  status: {board.status}", file=out)
    print(f"# specified in: {board.specified}", file=out)
    print(file=out)
    found: list[Block] = []
    for entry in split_top(board.specified, ";"):
        found += blocks_for(docs, entry, full)
    if not found:
        for name in board.files:
            if name in docs.lines:
                top = docs.sections and next(s for s in docs.sections if s.file == name)
                found.append(Block(name, top.start, top.end, top.title))
        mode = "outline"
        print("# no section of its Specified in cell names a heading; outlines of its files:\n", file=out)
    emit(docs, collapse(found), mode, out)
    return 0


def listing(docs: Docs, what: str, out) -> None:
    if what == "files":
        for name, lines in docs.lines.items():
            title = next((l[2:] for l in lines if l.startswith("# ")), name)
            read = next((l[2:] for l in lines if l.startswith("> ")), "")
            print(f"{docs.shown(name)}  {len(lines)} lines\n    {title}\n    {read}", file=out)
    elif what == "boards":
        for b in docs.boards:
            print(f"{', '.join(b.names)}  [{b.status[:40]}]  {', '.join(b.files)}", file=out)
    else:
        for s in docs.sections:
            print(f"{s.file}:{s.start + 1}-{s.end}  {'#' * s.level} {s.title}", file=out)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("query", nargs="*", help="a board name or a heading")
    ap.add_argument("--full", action="store_true", help="print the whole section, not the block a Specified-in entry names")
    ap.add_argument("--outline", action="store_true", help="print only the headings and bold lead-ins, with line numbers")
    ap.add_argument("--list", action="store_true", help="the files in docs/design and what each is for")
    ap.add_argument("--boards", action="store_true", help="every board with its status and files")
    ap.add_argument("--headings", action="store_true", help="every heading with its file and lines")
    ap.add_argument("--docs", default=str(DEFAULT_DOCS), help="the folder to read (default docs/design)")
    args = ap.parse_args(argv)
    docs_dir = Path(args.docs)
    if not docs_dir.is_dir():
        print(f"error: {docs_dir} does not exist", file=sys.stderr)
        return 2
    docs = Docs(docs_dir)
    for flag, what in ((args.list, "files"), (args.boards, "boards"), (args.headings, "headings")):
        if flag:
            listing(docs, what, sys.stdout)
            return 0
    if not args.query:
        ap.print_usage(sys.stderr)
        print("error: give a board or heading, or --list", file=sys.stderr)
        return 2
    try:
        return run(" ".join(args.query), docs, full=args.full, outline_only=args.outline)
    except Fail as e:
        print(f"error: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
