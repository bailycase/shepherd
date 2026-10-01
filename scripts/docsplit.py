#!/usr/bin/env python3
"""Shared parts of split_design_md.py, split_agents_md.py, rewrite_doc_refs.py and
design_section.py: reading Markdown headings (never inside a code fence), resolving a
section name such as "Composer, questions, and menus › The control row" against them, and
the line-conservation check that proves a split moved every line.

Standard library only.
"""
from __future__ import annotations

import re
from collections import Counter
from dataclasses import dataclass
from typing import Iterable, Sequence

FENCE = re.compile(r"^\s*(`{3,}|~{3,})")
HEADING = re.compile(r"^(#{1,6})\s+(\S.*?)\s*$")
LEAD_IN = re.compile(r"^\*\*([^*]+?)\*\*")


@dataclass(frozen=True)
class Heading:
    line: int  # 0-based index into the file's lines
    level: int
    title: str


def headings(lines: Sequence[str]) -> list[Heading]:
    """Every ATX heading outside a code fence."""
    out: list[Heading] = []
    fence: str | None = None
    for i, line in enumerate(lines):
        m = FENCE.match(line)
        if m:
            marker = m.group(1)[0]
            if fence is None:
                fence = marker
            elif fence == marker:
                fence = None
            continue
        if fence:
            continue
        h = HEADING.match(line)
        if h:
            out.append(Heading(i, len(h.group(1)), h.group(2)))
    return out


def section_end(hs: Sequence[Heading], index: int, total: int) -> int:
    """First line after heading `index` and everything nested under it."""
    level = hs[index].level
    for j in range(index + 1, len(hs)):
        if hs[j].level <= level:
            return hs[j].line
    return total


def clean_title(title: str) -> str:
    """A heading without its code ticks and its parenthetical board names."""
    t = title.replace("`", "")
    t = re.sub(r"\s*\([^()]*\)\s*", " ", t)
    return re.sub(r"\s+", " ", t).strip()


def tokens(text: str) -> list[str]:
    t = clean_title(text).lower().replace("'", "").replace("’", "")
    return re.findall(r"[\w▸-]+", t)


def split_top(text: str, sep: str) -> list[str]:
    """Split on `sep` outside parentheses."""
    parts, depth, cur = [], 0, ""
    for ch in text:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth = max(0, depth - 1)
        if ch == sep and depth == 0:
            parts.append(cur)
            cur = ""
        else:
            cur += ch
    parts.append(cur)
    return [p.strip() for p in parts if p.strip()]


@dataclass(frozen=True)
class Section:
    file: str  # path as the caller names it
    start: int  # 0-based first line (the heading)
    end: int  # 0-based, exclusive
    level: int
    title: str
    path: tuple[str, ...]  # cleaned titles from the file's top heading down


def sections_of(file: str, lines: Sequence[str]) -> list[Section]:
    hs = headings(lines)
    out: list[Section] = []
    stack: list[Heading] = []
    for i, h in enumerate(hs):
        while stack and stack[-1].level >= h.level:
            stack.pop()
        stack.append(h)
        out.append(Section(file, h.line, section_end(hs, i, len(lines)), h.level, h.title,
                           tuple(clean_title(x.title) for x in stack)))
    return out


def _matches(section_title: str, wanted: Sequence[str]) -> int:
    """2 for an equal title, 1 when the wanted words start the title, 0 otherwise."""
    have = tokens(section_title)
    if not wanted or not have:
        return 0
    if have == list(wanted):
        return 2
    if have[: len(wanted)] == list(wanted):
        return 1
    return 0


def _best(candidates: Iterable[Section], wanted: Sequence[str]) -> Section | None:
    """Equal titles beat prefixes, then the shallowest heading, then the first in reading order."""
    best: tuple[int, int, int] | None = None
    pick: Section | None = None
    for order, s in enumerate(candidates):
        score = _matches(s.title, wanted)
        if not score:
            continue
        key = (-score, s.level, order)
        if best is None or key < best:
            best, pick = key, s
    return pick


@dataclass(frozen=True)
class Resolved:
    section: Section
    focus: tuple[str, ...]  # leftover parts to look for as a bold lead-in inside the section


def _pools(current: Section, sections: Sequence[Section]) -> tuple[list[Section], list[Section]]:
    inside = [s for s in sections
              if s.file == current.file and s.start > current.start and s.end <= current.end]
    # A subsection a split moved to another file is that file's top section.
    moved = [s for s in sections if s.file != current.file and s.level <= 2]
    return inside, moved


def _find(part: str, pools: Sequence[Sequence[Section]]) -> Section | None:
    for pool in pools:
        hit = _best(pool, tokens(part))
        if hit is not None:
            return hit
    return None


def _alts(part: str) -> list[str]:
    return [a.strip() for a in part.split(",") if a.strip()]


def resolve_entry(entry: str, sections: Sequence[Section]) -> list[Resolved]:
    """Resolve "Composer, questions, and menus \u203a The control row, Speed menu" to the
    sections it names, each with the leftover words to look for as a lead-in. Commas list
    alternatives after the first part ("Shell and sidebar, Thread" names both). Empty when
    the first part names no heading."""
    parts = [p.strip() for p in entry.split("\u203a") if p.strip()]
    if not parts:
        return []
    first = _best(sections, tokens(parts[0]))
    if first:
        heads = [first]
    else:  # "Thread, Thinking" names both only when every alternative is a heading
        each = [_best(sections, tokens(a)) for a in _alts(parts[0])]
        heads = [h for h in each if h] if each and all(each) else []
    frontier: list[tuple[Section, tuple[str, ...]]] = [(h, ()) for h in heads]
    for part in parts[1:]:
        nxt: list[tuple[Section, tuple[str, ...]]] = []
        for sec, focus in frontier:
            pools = _pools(sec, sections)
            whole = _find(part, pools)
            if whole is not None:
                nxt.append((whole, focus))
                continue
            found, unfound = [], []
            for alt in _alts(part):
                hit = _find(alt, pools)
                (found if hit else unfound).append(hit or clean_title(alt))
            if found:
                nxt += [(h, focus) for h in found]
            else:
                nxt.append((sec, focus + tuple(f for f in unfound if f)))
        frontier = nxt
    return [Resolved(s, f) for s, f in frontier]


def lead_in_blocks(lines: Sequence[str], start: int, end: int) -> list[tuple[int, int, str]]:
    """Blocks of a section that open with a bold lead-in in column 0 ("**The card:**"):
    (first line, end line, lead-in text). A block ends at the next lead-in or heading."""
    hs = {h.line for h in headings(lines[start:end])}
    marks: list[tuple[int, str]] = []
    fence = False
    for i in range(start, end):
        line = lines[i]
        if FENCE.match(line):
            fence = not fence
            continue
        if fence:
            continue
        m = LEAD_IN.match(line)
        if m:
            marks.append((i, m.group(1).strip().rstrip(":").strip()))
    heads = [start + h for h in hs]
    out = []
    for n, (i, text) in enumerate(marks):
        stops = [m[0] for m in marks[n + 1:n + 2]] + [h for h in heads if h > i] + [end]
        out.append((i, min(stops), text))
    return out


# ---------------------------------------------------------------------------------------
# The check that a split lost nothing.

REF = re.compile(r"(?:docs/design/[\w-]+\.md|DESIGN\.md|AGENTS\.md|docs/[\w-]+\.md) ›")


def canon_refs(line: str) -> str:
    """A line with every `<file> › Section` reference reduced to `<REF> ›`, so a split's
    verbatim lines and the same lines after references were pointed at their new files
    compare equal."""
    return REF.sub("<REF> ›", line)


def body_counter(lines: Iterable[str], skip: Iterable[str] = ()) -> Counter:
    """Multiset of the non-blank, non-heading lines (outside fences headings do not count
    inside fences either way: a `# comment` in a code block is a body line)."""
    skipped = set(skip)
    out: Counter = Counter()
    fence: str | None = None
    for line in lines:
        m = FENCE.match(line)
        if m:
            marker = m.group(1)[0]
            if fence is None:
                fence = marker
            elif fence == marker:
                fence = None
            out[canon_refs(line.rstrip())] += 1
            continue
        if not fence and HEADING.match(line):
            continue
        s = line.rstrip()
        if not s.strip() or s in skipped:
            continue
        out[canon_refs(s)] += 1
    return out


def heading_counter(lines: Iterable[str]) -> Counter:
    return Counter(canon_refs(h.title) for h in headings(list(lines)))


def counter_diff(old: Counter, new: Counter) -> tuple[Counter, Counter]:
    """(lines only in old, lines only in new)."""
    return old - new, new - old


def rebase_links(text: str, from_dir: str, to_dir: str) -> str:
    """Re-point relative Markdown links `](path)` written for a file in `from_dir` so they
    resolve from `to_dir` (both repo-relative, "." for the root)."""
    import posixpath

    def fix(m: re.Match) -> str:
        target = m.group(1)
        if re.match(r"^(?:[a-z][a-z0-9+.-]*:|#|/)", target, re.I):
            return m.group(0)
        path, sep, frag = target.partition("#")
        if not path or not (re.search(r"\.[A-Za-z0-9]+$", path) or path.endswith("/")):
            return m.group(0)
        abs_path = posixpath.normpath(posixpath.join(from_dir, path))
        if abs_path.startswith(".."):
            return m.group(0)
        new = posixpath.relpath(abs_path, to_dir)
        return "](" + new + (sep + frag if sep else "") + ")"

    return re.sub(r"\]\(([^)\s]+)\)", fix, text)
