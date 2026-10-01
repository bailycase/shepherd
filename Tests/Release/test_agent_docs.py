"""Guards that keep AGENTS.md and DESIGN.md short, and the docs they point at in one piece.

AGENTS.md is loaded into every agent thread and DESIGN.md is read before every UI change, so
both are a short sheet of rules and pointers; the long reference sections live in docs/ and
the per-surface design specs in docs/design/. These tests fail when either file regrows, when
a link or an anchor in them breaks, or when a file in docs/design/ is not in its index.

Run: python3 -m unittest discover -s Tests/Release -v
"""
import os
import re
import unittest
from pathlib import Path

ROOT = Path(os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..")))

AGENTS_MAX_LINES = 250
DESIGN_MAX_LINES = 300

# Reference sections that moved out of AGENTS.md, each with a one-line "Read when" header.
MOVED_FROM_AGENTS = ["overview", "build-and-run", "environment", "testing", "source-map", "data-flow",
                     "remote-protocol", "rules", "releases", "gotchas"]

LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
FENCE = re.compile(r"^\s*(`{3,}|~{3,})")


def read_lines(path):
    return path.read_text(encoding="utf-8").split("\n")


def prose_lines(path):
    """The file's lines outside code fences."""
    out, fenced = [], False
    for line in read_lines(path):
        if FENCE.match(line):
            fenced = not fenced
            continue
        if not fenced:
            out.append(line)
    return out


def slug(title):
    """GitHub's anchor for a heading."""
    t = title.strip().lower().replace("`", "")
    t = re.sub(r"[^\w\- ]", "", t)
    return t.replace(" ", "-")


def anchors(path):
    return {slug(m.group(2)) for m in (re.match(r"^(#{1,6})\s+(.*?)\s*$", l) for l in prose_lines(path)) if m}


def broken_links(path):
    """Relative links in `path` whose file, or whose #anchor in a Markdown file, does not exist."""
    problems = []
    for n, line in enumerate(prose_lines(path), 1):
        for target in LINK.findall(re.sub(r"`[^`]*`", "", line)):
            if re.match(r"^(?:[a-z][a-z0-9+.-]*:|#|/)", target, re.I):
                continue
            file_part, _, frag = target.partition("#")
            dest = (path.parent / file_part).resolve()
            if not dest.exists():
                problems.append(f"{path.relative_to(ROOT)}:{n}: {target} (no such file)")
            elif frag and dest.suffix == ".md" and slug(frag) not in anchors(dest):
                problems.append(f"{path.relative_to(ROOT)}:{n}: {target} (no such heading)")
    return problems


class SizeTests(unittest.TestCase):
    def test_agents_md_stays_short_enough_to_load_in_every_thread(self):
        n = len(read_lines(ROOT / "AGENTS.md"))
        self.assertLessEqual(n, AGENTS_MAX_LINES,
                             f"AGENTS.md is {n} lines (max {AGENTS_MAX_LINES}). Move the detail to docs/ and link it.")

    def test_design_md_stays_a_small_set_of_rules(self):
        n = len(read_lines(ROOT / "DESIGN.md"))
        self.assertLessEqual(n, DESIGN_MAX_LINES,
                             f"DESIGN.md is {n} lines (max {DESIGN_MAX_LINES}). Per-surface specs go in docs/design/.")


class ContentTests(unittest.TestCase):
    def test_the_design_procedure_is_at_the_top_of_agents_md(self):
        head = "\n".join(read_lines(ROOT / "AGENTS.md")[:30])
        self.assertIn("## Implementing a design", head)
        self.assertIn("the user's design wins", head)
        self.assertIn("design_section.py", head)

    def test_design_md_puts_the_users_design_above_its_own_rules(self):
        text = (ROOT / "DESIGN.md").read_text(encoding="utf-8")
        self.assertIn("## Precedence", text)
        self.assertIn("never override a design the user just gave", text)
        self.assertIn("the user's call", text)

    def test_nothing_in_the_repo_claims_that_design_md_wins_over_the_users_design(self):
        for rel in ("AGENTS.md", "DESIGN.md", "docs/design/README.md"):
            text = (ROOT / rel).read_text(encoding="utf-8")
            self.assertNotRegex(text, r"(?i)this document wins")
            self.assertNotRegex(text, r"(?i)is the authority on")

    def test_moved_reference_files_open_with_a_one_line_read_when_header(self):
        for name in MOVED_FROM_AGENTS:
            lines = read_lines(ROOT / "docs" / f"{name}.md")
            self.assertTrue(lines[0].startswith("# "), name)
            self.assertTrue(any(l.startswith("> Read when") for l in lines[:6]), f"docs/{name}.md has no Read when line")


class LinkTests(unittest.TestCase):
    def test_links_in_agents_md_design_md_and_the_design_index_resolve(self):
        problems = []
        for rel in ("AGENTS.md", "DESIGN.md", "docs/design/README.md"):
            problems += broken_links(ROOT / rel)
        self.assertEqual(problems, [])

    def test_links_in_every_moved_doc_and_design_spec_resolve(self):
        files = [ROOT / "docs" / f"{n}.md" for n in MOVED_FROM_AGENTS]
        files += sorted((ROOT / "docs" / "design").glob("*.md"))
        problems = []
        for f in files:
            problems += broken_links(f)
        self.assertEqual(problems, [])

    def test_agents_md_links_every_doc_it_moved_the_rules_to(self):
        text = (ROOT / "AGENTS.md").read_text(encoding="utf-8")
        for name in MOVED_FROM_AGENTS:
            if name == "overview":
                continue
            self.assertIn(f"docs/{name}.md", text, f"AGENTS.md never points at docs/{name}.md")


class DesignIndexTests(unittest.TestCase):
    def test_the_design_index_lists_every_file_in_docs_design(self):
        folder = ROOT / "docs" / "design"
        index = (folder / "README.md").read_text(encoding="utf-8")
        listed = set(re.findall(r"\]\(([\w-]+\.md)\)", index))
        on_disk = {p.name for p in folder.glob("*.md") if p.name != "README.md"}
        self.assertEqual(sorted(on_disk - listed), [], "files missing from docs/design/README.md")
        self.assertEqual(sorted(listed - on_disk), [], "README.md links files that do not exist")

    def test_every_design_spec_opens_with_a_title_and_a_one_line_read_when_header(self):
        for p in sorted((ROOT / "docs" / "design").glob("*.md")):
            lines = read_lines(p)
            self.assertTrue(lines[0].startswith("# "), p.name)
            self.assertTrue(any(l.startswith("> ") and "Read" in l for l in lines[:6]), f"{p.name} has no Read when line")

    def test_design_md_points_every_section_of_the_rules_at_a_real_file(self):
        text = (ROOT / "DESIGN.md").read_text(encoding="utf-8")
        for rel in sorted(set(re.findall(r"\]\((docs/design/[\w-]+\.md)", text))):
            self.assertTrue((ROOT / rel).is_file(), rel)


if __name__ == "__main__":
    unittest.main()
