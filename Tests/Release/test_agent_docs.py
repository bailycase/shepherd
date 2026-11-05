"""Guards that keep AGENTS.md and DESIGN.md short, and the docs they point at in one piece.

AGENTS.md is loaded into every agent thread and DESIGN.md is read before every UI change, so
both are a short sheet of rules and pointers. The few reference docs live in docs/; there are no
per-feature or per-surface docs, since the code is the spec. These tests fail when either file
regrows, or when a link or an anchor in the kept docs breaks.

Run: python3 -m unittest discover -s Tests/Release -v
"""
import os
import re
import unittest
from pathlib import Path

ROOT = Path(os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..")))

AGENTS_MAX_LINES = 130
DESIGN_MAX_LINES = 280

# Reference docs AGENTS.md points at, each with a one-line "Read when" header.
REFERENCE_DOCS = ["build-and-run", "environment", "testing", "remote-protocol", "rules",
                  "releases", "gotchas", "pi-engine", "context-budget"]

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
            if not dest.is_relative_to(ROOT):
                continue  # A GitHub page such as ../../releases, not a file.
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
                             f"DESIGN.md is {n} lines (max {DESIGN_MAX_LINES}). Keep it to rules; the code is the spec.")


class ContentTests(unittest.TestCase):
    def test_design_md_puts_the_users_design_above_its_own_rules(self):
        text = (ROOT / "DESIGN.md").read_text(encoding="utf-8")
        self.assertIn("## Precedence", text)
        self.assertIn("never override a design the user just gave", text)
        self.assertIn("the user's call", text)

    def test_nothing_in_the_repo_claims_that_design_md_wins_over_the_users_design(self):
        for rel in ("AGENTS.md", "DESIGN.md"):
            text = (ROOT / rel).read_text(encoding="utf-8")
            self.assertNotRegex(text, r"(?i)this document wins")
            self.assertNotRegex(text, r"(?i)is the authority on")

    def test_reference_docs_open_with_a_one_line_read_when_header(self):
        for name in REFERENCE_DOCS:
            lines = read_lines(ROOT / "docs" / f"{name}.md")
            self.assertTrue(lines[0].startswith("# "), name)
            self.assertTrue(any(l.startswith("> Read when") for l in lines[:6]), f"docs/{name}.md has no Read when line")


class LinkTests(unittest.TestCase):
    def test_links_in_every_kept_doc_resolve(self):
        files = [ROOT / n for n in ("AGENTS.md", "DESIGN.md", "ARCHITECTURE.md", "README.md", "CONTRIBUTING.md", "SECURITY.md")]
        files += [ROOT / "docs" / f"{n}.md" for n in REFERENCE_DOCS]
        files.append(ROOT / "docs" / "design" / "boards" / "README.md")
        problems = []
        for f in files:
            problems += broken_links(f)
        self.assertEqual(problems, [])

    def test_docs_holds_only_the_reference_docs_and_the_saved_boards(self):
        docs = ROOT / "docs"
        extra = sorted(str(p.relative_to(docs)) for p in docs.rglob("*.md")
                       if p.parent == docs and p.stem not in REFERENCE_DOCS
                       or p.parent != docs and p != docs / "design" / "boards" / "README.md")
        self.assertEqual(extra, [], "docs/ is only the reference docs: put the detail in code and tests")


if __name__ == "__main__":
    unittest.main()
