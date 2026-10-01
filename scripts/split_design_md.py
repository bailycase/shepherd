#!/usr/bin/env python3
"""Split the long DESIGN.md into docs/design/*.md, moving every line and rewriting none.

The old DESIGN.md was one 9,800-line file. The rules a UI change must obey now live in the
short DESIGN.md; its per-surface specs moved here, by heading, into files of a sensible
size. This script is the move, so it can be run again from the old text if DESIGN.md
changed while the split was being reviewed:

    git show origin/nightly:DESIGN.md > /tmp/DESIGN.old.md
    python3 scripts/split_design_md.py --source /tmp/DESIGN.old.md
    python3 scripts/rewrite_doc_refs.py            # points `DESIGN.md › X` at the new files

Run it only from the old text: after the split landed, docs/design/ is edited directly.

What it does, and what it checks:
  * routes every heading's text to a file (ROUTES); a section it does not know fails the
    run, so new content is never dropped silently;
  * keeps each section's text byte for byte, apart from heading levels (a section's heading
    becomes the file's title) and relative links, which are re-pointed from the repo root
    to docs/design/;
  * turns the Board index into docs/design/README.md (board -> files -> status);
  * proves nothing was lost: the multiset of non-heading lines in the old file (minus the
    old preamble and the Board index rows) equals the new files', and every Board index
    row (board, specified in, status) survives.
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
    FENCE,
    HEADING,
    body_counter,
    clean_title,
    counter_diff,
    heading_counter,
    headings,
    rebase_links,
    resolve_entry,
    sections_of,
    split_top,
)

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = "docs/design"

# file -> (title, "Read when" line). The title is used only when a file holds several
# sections; a file of one section takes that section's own heading.
FILES: dict[str, tuple[str, str]] = {
    "principles.md": ("Mental model and principles",
                      "Read when you weigh a UI decision: what the app is for, and the principles in priority order."),
    "departures.md": ("Where Shepherd departs from the boards",
                      "Read when a board and the app disagree. Each row is a decision the user made; a new departure is the user's call, never an agent's."),
    "theme.md": ("Theme model",
                 "Read when you add or change a color, a theme, an AgentState look, or build on ShepherdUI's tokens."),
    "foundations.md": ("Typography, space, elevation and density",
                       "Read when you set type, spacing, radius, row height, elevation, an icon, or the density settings."),
    "motion.md": ("Motion", "Read when something animates, appears, or must not move."),
    "performance.md": ("Performance",
                       "Read when you build or change a list, a row, a scroll view, or anything that redraws often."),
    "window-and-toolbar.md": ("Window, adaptive layout and toolbar",
                              "Read when you change the window, how it adapts to a narrow size, or the toolbar."),
    "sidebar.md": ("Sidebar", "Read when you change the sidebar: its rows, Needs you, Pinned, Recents or Projects."),
    "pages.md": ("Destination pages",
                 "Read when you change New thread, Automations, Hosts, Designs or the Missions page."),
    "thread.md": ("Thread", "Read when you change how a thread draws: turns, activity lines, prose, errors, starting, following."),
    "composer.md": ("Composer, questions, and menus",
                    "Read when you change the composer, its model-settings popover, slash menu, context meter, a question, or the send path."),
    "queue.md": ("Up next (the queue)", "Read when you change the queue above the composer, steering, or Send now."),
    "subagents.md": ("Subagents", "Read when you change the subagent tray, its cards, or its record lines in a thread."),
    "side-pane-changes.md": ("Side pane: Changes and the subagent inspector",
                             "Read when you change the Changes pane, a diff, a review comment, or the subagent inspector."),
    "side-pane-browser.md": ("Side pane: Browser", "Read when you change the Browser tab or how an agent drives it."),
    "side-pane-artifacts.md": ("Side pane: Artifacts, Files (not built yet)",
                               "Read only when asked to build the Artifacts or Files tabs."),
    "terminal.md": ("Terminal and terminal panel",
                    "Read when you change a terminal tab, the panel under a thread, or ⌘J and ⌘D."),
    "dialogs-and-palette.md": ("Command palette, dialogs and sheets",
                               "Read when you change the command palette, a dialog or a sheet."),
    "settings.md": ("Settings", "Read when you change a Settings page other than Pi, Instructions, Skills, MCP servers and Experiments."),
    "settings-pi.md": ("Settings: Pi", "Read when you change Settings ▸ Pi: Sign-in, the CLIProxyAPI connection, or From your pi."),
    "settings-instructions.md": ("Settings: Instructions", "Read when you change Settings ▸ Instructions or its per-host view."),
    "settings-skills.md": ("Settings: Skills", "Read when you change Settings ▸ Skills, Browse skills.sh or Add from repo."),
    "settings-mcp-experiments.md": ("Settings: MCP servers and Experiments",
                                    "Read when you change Settings ▸ MCP servers or Experiments."),
    "components.md": ("Status language and components",
                      "Read when you build a control or a status piece: the shared component inventory and how a status reads."),
    "keyboard-and-accessibility.md": ("Keyboard and accessibility",
                                      "Read when you add a shortcut, a focus behavior, a VoiceOver label, or a Reduce Motion path."),
    "known-gaps.md": ("Known gaps",
                      "Read when you finish a change that leaves the app short of its design: list the place here until it is fixed."),
    "ios-iphone.md": ("iOS and the iPhone",
                      "Read when you change the iPhone client's shell, home, thread, new thread, queue, subagents or review."),
    "ios-iphone-pages.md": ("iPhone: Needs you, Search, More and Settings",
                            "Read when you change the iPhone's Needs you, Search, More, Settings, Instructions, Skills or Experiments."),
    "ios-ipad.md": ("iPad: shell, thread and review",
                    "Read when you change the iPad client's shell, thread, composer, queue, questions, subagents, review or commit."),
    "ios-ipad-pages.md": ("iPad: other screens and Automations",
                          "Read when you change the iPad's overview, Needs you, hosts, palette, Split View, settings or side pane, or Automations on iOS."),
    "notifications.md": ("Notifications and Live Activities",
                         "Read when you send a notification or build a Live Activity, on the Mac or iOS."),
    "missions.md": ("Missions",
                    "Not built yet. Read only when asked to build Missions: the model, getting there, the map and its parts."),
    "missions-screens.md": ("Missions: screens",
                            "Not built yet. Read only when asked to build Missions: the run, review, failure states, templates, iOS and motion."),
    "design-tool.md": ("Design tool", "Read when you work on the Design tool (Settings ▸ Experiments ▸ Design tool): designs, canvas, comments."),
    "design-tool-references.md": ("Design tool: references, Tweak, systems and export",
                                  "Read when you work on design references, Tweak, design systems, export, deletion and import, or the Design tool on iOS."),
    "verifying.md": ("Verifying visuals", "Read when you check a UI change: previews, windows, motion probes, the Component Gallery."),
}

# Section path (cleaned heading titles from the ## heading down) -> file. A section with no
# rule takes its parent's file. The rules are exact; a new top-level section fails the run.
S = "Surfaces"
ROUTES: list[tuple[tuple[str, ...], str]] = [
    (("Mental model: agents, not chats",), "principles.md"),
    (("Principles",), "principles.md"),
    (("Where Shepherd departs from the boards",), "departures.md"),
    (("Theme model",), "theme.md"),
    (("Typography",), "foundations.md"),
    (("Space, radius, height, elevation",), "foundations.md"),
    (("Density and row settings",), "foundations.md"),
    (("Motion",), "motion.md"),
    (("Performance",), "performance.md"),
    (("Window and adaptive layout",), "window-and-toolbar.md"),
    (("Status language",), "components.md"),
    (("Components",), "components.md"),
    (("Keyboard",), "keyboard-and-accessibility.md"),
    (("Accessibility and motion",), "keyboard-and-accessibility.md"),
    (("Known gaps",), "known-gaps.md"),
    (("Notifications and Live Activities",), "notifications.md"),
    (("Verifying visuals",), "verifying.md"),
    (("Board index",), "README.md"),
    # Surfaces
    ((S, "Sidebar"), "sidebar.md"),
    ((S, "Toolbar"), "window-and-toolbar.md"),
    ((S, "Nothing on screen"), "window-and-toolbar.md"),
    ((S, "Destination pages"), "pages.md"),
    ((S, "New thread page"), "pages.md"),
    ((S, "Missions page"), "pages.md"),
    ((S, "Designs page"), "pages.md"),
    ((S, "Automations page"), "pages.md"),
    ((S, "Hosts page"), "pages.md"),
    ((S, "Thread"), "thread.md"),
    ((S, "Composer, questions, and menus"), "composer.md"),
    ((S, "Up next"), "queue.md"),
    ((S, "Subagents"), "subagents.md"),
    ((S, "Mission components"), "missions.md"),
    ((S, "Side pane: Changes and the subagent inspector"), "side-pane-changes.md"),
    ((S, "Side pane: Browser"), "side-pane-browser.md"),
    ((S, "Side pane: Artifacts, Files"), "side-pane-artifacts.md"),
    ((S, "Terminal"), "terminal.md"),
    ((S, "Terminal panel"), "terminal.md"),
    ((S, "Command palette"), "dialogs-and-palette.md"),
    ((S, "Dialogs and sheets"), "dialogs-and-palette.md"),
    ((S, "Settings"), "settings.md"),
    ((S, "Settings", "Pi"), "settings-pi.md"),
    ((S, "Settings", "Pi ▸ Sign-in"), "settings-pi.md"),
    ((S, "Settings", "Optional CLIProxyAPI connection"), "settings-pi.md"),
    ((S, "Settings", "Pi ▸ From your pi"), "settings-pi.md"),
    ((S, "Settings", "Instructions"), "settings-instructions.md"),
    ((S, "Settings", "Instructions per host"), "settings-instructions.md"),
    ((S, "Settings", "Skills"), "settings-skills.md"),
    ((S, "Settings", "Browse skills.sh and Add from repo"), "settings-skills.md"),
    ((S, "Settings", "MCP servers"), "settings-mcp-experiments.md"),
    ((S, "Settings", "Experiments"), "settings-mcp-experiments.md"),
    # iOS
    (("iOS",), "ios-iphone.md"),
    (("iOS", "iPhone: Needs you"), "ios-iphone-pages.md"),
    (("iOS", "iPhone: Search"), "ios-iphone-pages.md"),
    (("iOS", "iPhone: More"), "ios-iphone-pages.md"),
    (("iOS", "iPhone: Settings"), "ios-iphone-pages.md"),
    (("iOS", "iPhone: Instructions"), "ios-iphone-pages.md"),
    (("iOS", "iPhone: Skills"), "ios-iphone-pages.md"),
    (("iOS", "iPhone: Experiments"), "ios-iphone-pages.md"),
    (("iOS", "iOS: iPad"), "ios-ipad.md"),
    (("iOS", "iOS: iPad", "Overview"), "ios-ipad-pages.md"),
    (("iOS", "iOS: iPad", "Needs you"), "ios-ipad-pages.md"),
    (("iOS", "iOS: iPad", "Hosts and More"), "ios-ipad-pages.md"),
    (("iOS", "iOS: iPad", "Command palette"), "ios-ipad-pages.md"),
    (("iOS", "iOS: iPad", "Split View"), "ios-ipad-pages.md"),
    (("iOS", "iOS: iPad", "Settings"), "ios-ipad-pages.md"),
    (("iOS", "iOS: iPad", "Side pane"), "ios-ipad-pages.md"),
    (("iOS", "iOS: Automations"), "ios-ipad-pages.md"),
    # Missions and the Design tool
    (("Missions",), "missions.md"),
    (("Missions", "Missions: map, patches and the run"), "missions-screens.md"),
    (("Missions", "Missions: review, evidence and the merge train"), "missions-screens.md"),
    (("Missions", "Missions: when things go wrong"), "missions-screens.md"),
    (("Missions", "Missions: templates"), "missions-screens.md"),
    (("Missions", "Missions: iPhone and iPad"), "missions-screens.md"),
    (("Missions", "Missions: motion, keyboard and parts to build"), "missions-screens.md"),
    (("Design tool",), "design-tool.md"),
    (("Design tool", "Design references"), "design-tool-references.md"),
    (("Design tool", "Tweak"), "design-tool-references.md"),
    (("Design tool", "Design systems"), "design-tool-references.md"),
    (("Design tool", "Export and share"), "design-tool-references.md"),
    (("Design tool", "Delete and import"), "design-tool-references.md"),
    (("Design tool", "Design components"), "design-tool-references.md"),
    (("Design tool", "On iPhone"), "design-tool-references.md"),
    (("Design tool", "On iPad"), "design-tool-references.md"),
]

# Boards whose "Specified in" cell names no heading.
BOARD_ALIASES = {
    "PiAuthStates": ["Settings › Pi ▸ Sign-in"],
}

README_HEAD = """# Design specs

> Read when you build or change a surface. [DESIGN.md](../../DESIGN.md) holds the rules every UI change obeys; this folder holds each surface's spec.

**Precedence.** The design the user gives in the thread (an image, a board, a design
reference) comes first. Then the board or the canvas. Then these specs. Then the rules in
DESIGN.md. If a design disagrees with a spec here, build the design, update the spec in the
same change, and tell the user every place you could not match it. A departure from a design
is the user's call, never yours.

**Find a spec.** Do not read this index through: find the board with `--boards | grep -i <word>`
and print only its sections.

```sh
python3 scripts/design_section.py --boards | grep -i composer   # which boards touch the composer
python3 scripts/design_section.py ComposerSpeed          # a board: its status and the blocks it names
python3 scripts/design_section.py "Up next"              # a heading
python3 scripts/design_section.py "Composer, questions, and menus › The card"   # a block inside it
python3 scripts/design_section.py ComposerSpeed --full   # every line, not the narrowed block or outline
python3 scripts/design_section.py --list                 # the files and what each is for
```

A block over 250 lines prints as an outline of its parts; read one with a path as above.

**Reading a spec.**

- A rule names its board in parentheses, for example (NWFoundations).
- A spec marked **Not built yet.** is a design for later: build it to that spec when asked,
  and skip it when working on shipped UI.
- The places Shepherd deliberately departs from the boards are in
  [departures.md](departures.md); any other difference between the app and a spec is a gap to
  fix ([known-gaps.md](known-gaps.md)).
- Every value lives in code, and the specs name the code: tokens and shared components in
  `Packages/ShepherdUI` (module `ShepherdUI`), the Mac app's own surface dimensions in
  `AppLayout`, split by domain into `Sources/ShepherdApp/AppLayout+<Domain>.swift`.
- The design canvas, "Shepherd chat UI", has the pages macOS, iOS, iPadOS, Notifications,
  Missions, Design tool and Design system · Night Watch. The last is **Night Watch**,
  Shepherd's design system: Foundations, Controls, Status & feedback, Thread, Composer &
  menus, Navigation, Agents & orchestration, Review, Swift implementation, Missions map,
  Mission screens and Design tool, each drawn dark and light. A UI decision changes the specs
  here and the canvas together.
"""

BOARD_MARK_START = "## Board index"
FILES_HEADING = "## Files"


def read_source(args: argparse.Namespace) -> str:
    if args.source:
        return Path(args.source).read_text(encoding="utf-8")
    out = subprocess.run(["git", "show", f"{args.rev}:DESIGN.md"], cwd=ROOT, check=True,
                         capture_output=True, text=True)
    return out.stdout


class Chunk:
    """A heading and the lines up to the next heading of any level."""

    def __init__(self, start: int, end: int, level: int, title: str, path: tuple[str, ...],
                 dest: str | None, unit_start: int, unit_level: int):
        self.start, self.end, self.level, self.title, self.path = start, end, level, title, path
        self.dest, self.unit_start, self.unit_level = dest, unit_start, unit_level


def route(lines: list[str]) -> tuple[list[Chunk], int]:
    """(chunks, first line of the first ## section). Everything before it is the preamble."""
    hs = headings(lines)
    rules = {path: dest for path, dest in ROUTES}
    chunks: list[Chunk] = []
    stack: list[Chunk] = []
    first = next((h.line for h in hs if h.level == 2), len(lines))
    for i, h in enumerate(hs):
        if h.level < 2:
            continue
        while stack and stack[-1].level >= h.level:
            stack.pop()
        path = tuple(c.title for c in stack) + (clean_title(h.title),)
        end = hs[i + 1].line if i + 1 < len(hs) else len(lines)
        if path in rules:
            dest, unit_start, unit_level = rules[path], h.line, h.level
        elif stack:
            dest, unit_start, unit_level = stack[-1].dest, stack[-1].unit_start, stack[-1].unit_level
        else:
            dest, unit_start, unit_level = None, h.line, h.level
        c = Chunk(h.line, end, h.level, clean_title(h.title), path, dest, unit_start, unit_level)
        c.title = clean_title(h.title)
        chunks.append(c)
        stack.append(c)
    return chunks, first


def has_body(lines: list[str], chunk: Chunk) -> bool:
    return any(l.strip() for l in lines[chunk.start + 1:chunk.end])


def transform(line: str) -> str:
    return rebase_links(line, ".", OUT_DIR)


def build(lines: list[str]):
    """(files: name -> lines, readme_index: lines, containers, preamble line count)."""
    chunks, first = route(lines)
    bad = [c for c in chunks if c.dest is None and has_body(lines, c)]
    if bad:
        names = ", ".join(" > ".join(c.path) for c in bad)
        sys.exit(f"error: no route for text under: {names}\n"
                 "Add the section to ROUTES in scripts/split_design_md.py.")
    unknown = sorted({c.dest for c in chunks if c.dest and c.dest != "README.md" and c.dest not in FILES})
    if unknown:
        sys.exit(f"error: ROUTES names files missing from FILES: {unknown}")
    containers = [c for c in chunks if c.dest is None]

    by_file: dict[str, list[Chunk]] = {}
    for c in chunks:
        if c.dest and c.dest != "README.md":
            by_file.setdefault(c.dest, []).append(c)

    files: dict[str, list[str]] = {}
    for name, cs in by_file.items():
        title, read_when = FILES[name]
        units = {c.unit_start for c in cs}
        base = 1 if len(units) == 1 else 2
        out: list[str] = []
        if base == 2:
            out += [f"# {title}", "", f"> {read_when}", ""]
        for c in cs:
            level = max(1, base + c.level - c.unit_level)
            out.append("#" * level + " " + lines[c.start].split(" ", 1)[1])
            if base == 1 and c.start == c.unit_start:
                out += ["", f"> {read_when}"]
                if lines[c.start + 1].strip():
                    out.append("")
            out += [transform(l) for l in lines[c.start + 1:c.end]]
        while out and not out[-1].strip():
            out.pop()
        files[name] = out

    index_chunks = [c for c in chunks if c.dest == "README.md"]
    index_lines: list[str] = []
    for c in index_chunks:
        index_lines += [transform(l) for l in lines[c.start + 1:c.end]]
    return files, index_lines, containers, first


def board_rows(index_lines: list[str]):
    """Every table row of the Board index as (board, specified, status)."""
    rows = []
    for l in index_lines:
        if not l.startswith("| ") or l.startswith("| Board ") or l.startswith("| ---"):
            continue
        cells = [c.strip() for c in l.strip().strip("|").split(" | ")]
        if len(cells) != 3:
            sys.exit(f"error: a Board index row has {len(cells)} cells, expected 3: {l[:80]}")
        rows.append(tuple(cells))
    return rows


def render_readme(files: dict[str, list[str]], index_lines: list[str]) -> list[str]:
    sections = []
    for name, ls in files.items():
        sections += sections_of(name, ls)
    out = README_HEAD.rstrip("\n").split("\n") + ["", BOARD_MARK_START]
    unresolved = []
    for l in index_lines:
        if l.startswith("| Board | Specified in | Status |"):
            out.append("| Board | Files | Specified in | Status |")
        elif l.startswith("| --- | --- | --- |"):
            out.append("| --- | --- | --- | --- |")
        elif l.startswith("| "):
            board, specified, status = [c.strip() for c in l.strip().strip("|").split(" | ")]
            names: list[str] = []
            entries = split_top(specified, ";") + [e for b in split_top(board.replace(",", ";"), ";")
                                                  for e in BOARD_ALIASES.get(b, [])]
            for entry in entries:
                for r in resolve_entry(entry, sections):
                    if r.section.file not in names:
                        names.append(r.section.file)
            if not names:
                unresolved.append(board)
            cell = ", ".join(f"[{n[:-3]}]({n})" for n in names) or "?"
            out.append(f"| {board} | {cell} | {specified} | {status} |")
        else:
            out.append(l)
    if unresolved:
        sys.exit(f"error: no file found for boards: {unresolved}\n"
                 "Fix their 'Specified in' cell or add BOARD_ALIASES in scripts/split_design_md.py.")
    while out and not out[-1].strip():
        out.pop()
    out += ["", FILES_HEADING, "", "| File | Read when |", "| --- | --- |"]
    for name in sorted(files):
        out.append(f"| [{name[:-3]}]({name}) | {FILES[name][1]} |")
    return out


def check(lines: list[str], first: int, files: dict[str, list[str]], index_lines: list[str],
          readme: list[str]) -> None:
    """Prove the split lost and duplicated nothing."""
    chunks, _ = route(lines)
    old_lines: list[str] = []
    old_headings: list[str] = []
    for c in chunks:
        if c.dest and c.dest != "README.md":
            old_lines += [transform(l) for l in lines[c.start + 1:c.end]]
            old_headings.append(c.title)
    old_lines += [l for l in index_lines if not l.startswith("| ")]
    old = body_counter(old_lines)

    generated = {f"> {FILES[n][1]}" for n in files}
    new_lines: list[str] = []
    for n, ls in files.items():
        new_lines += [l for l in ls if l not in generated]
    mid = readme[readme.index(BOARD_MARK_START) + 1:readme.index(FILES_HEADING)]
    new_lines += [l for l in mid if not l.startswith("| ")]
    new = body_counter(new_lines)

    lost, extra = counter_diff(old, new)
    if lost or extra:
        for l, n in list(lost.items())[:10]:
            print(f"LOST x{n}: {l[:100]}", file=sys.stderr)
        for l, n in list(extra.items())[:10]:
            print(f"EXTRA x{n}: {l[:100]}", file=sys.stderr)
        sys.exit("error: the split did not conserve lines")

    old_rows = Counter(board_rows(index_lines))
    new_rows = Counter()
    for l in mid:
        if l.startswith("| ") and not l.startswith("| Board ") and not l.startswith("| ---"):
            b, _files, spec, status = [c.strip() for c in l.strip().strip("|").split(" | ")]
            new_rows[(b, spec, status)] += 1
    if old_rows != new_rows:
        sys.exit("error: Board index rows changed")

    # Headings: every section title survives.
    new_heads = Counter()
    for ls in files.values():
        new_heads += Counter(clean_title(h.title) for h in headings(ls))
    missing = Counter(old_headings) - new_heads
    if missing:
        sys.exit(f"error: headings lost: {dict(missing)}")

    n_old = sum(old.values())
    print(f"conserved {n_old} body lines across {len(files)} files + README "
          f"({sum(old_rows.values())} Board index rows, {len(old_headings)} headings)")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--source", help="path of the old DESIGN.md")
    ap.add_argument("--rev", help="git revision holding the old DESIGN.md (git show REV:DESIGN.md)")
    ap.add_argument("--out", default=OUT_DIR, help="output folder, relative to the repo root")
    ap.add_argument("--verify", action="store_true",
                    help="check the files already on disk (after rewrite_doc_refs.py) instead of writing")
    args = ap.parse_args()
    if not args.source and not args.rev:
        ap.error("give --source FILE or --rev REV")
    text = read_source(args)
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    files, index_lines, containers, first = build(lines)
    readme = render_readme(files, index_lines)
    if args.verify:
        out = ROOT / args.out

        def on_disk(name: str) -> list[str]:
            ls = (out / name).read_text(encoding="utf-8").split("\n")
            return ls[:-1] if ls and ls[-1] == "" else ls

        check(lines, first, {n: on_disk(n) for n in files}, index_lines, on_disk("README.md"))
        return
    check(lines, first, files, index_lines, readme)

    out = ROOT / args.out
    out.mkdir(parents=True, exist_ok=True)
    for name, ls in files.items():
        (out / name).write_text("\n".join(ls) + "\n", encoding="utf-8")
    (out / "README.md").write_text("\n".join(readme) + "\n", encoding="utf-8")
    stale = sorted(p.name for p in out.glob("*.md") if p.name not in files and p.name != "README.md")
    print(f"wrote {len(files) + 1} files to {args.out}")
    print(f"preamble not moved (replaced by DESIGN.md's precedence rule and README's intro): {first} lines")
    print("container headings with no text of their own: " + ", ".join(c.title for c in containers))
    if stale:
        print(f"note: not generated by this run: {', '.join(stale)}")


if __name__ == "__main__":
    main()
