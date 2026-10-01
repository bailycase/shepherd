"""Tests for scripts/design_section.py, which prints one board's or one heading's spec from
docs/design/, and for scripts/docsplit.py, the heading reader and the line-conservation check the
two split scripts share.

Run: python3 -m unittest discover -s Tests/Release -v

The unit tests build a small docs tree in a temporary folder. The last class reads the real
docs/design/ and checks that every board in its index still resolves to a spec.
"""
import contextlib
import importlib.util
import io
import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts"))


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(ROOT, "scripts", name + ".py"))
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


docsplit = load("docsplit")
design_section = load("design_section")

ALPHA = """\
# Alpha

> Read when you change alpha.

## Alpha part one

Intro of part one.

**The card:**

- the card line

**The row:**

- the row line

## Alpha part two (BoardX)

Text of part two.

```sh
# not a heading
## nor this
```

## Shared name

First shared.
"""

BETA = """\
# Beta

> Read when you change beta.

## Shared name

Second shared.

## Beta only

Beta text.
"""

README = """\
# Design specs

## Board index

| Board | Files | Specified in | Status |
| --- | --- | --- | --- |
| BoardX, BoardXLight | [alpha](alpha.md) | Alpha › Alpha part two | Built |
| BoardCard | [alpha](alpha.md) | Alpha › Alpha part one › The card | Partial |
| BoardWhole | [alpha](alpha.md), [beta](beta.md) | Alpha part one; Beta only | Built |
| BoardVague | [beta](beta.md) | The states of all of the above | Built |

## Files

| File | Read when |
| --- | --- |
| [alpha](alpha.md) | alpha |
"""


def run(args, docs):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = design_section.main(["--docs", str(docs)] + args)
    return code, out.getvalue(), err.getvalue()


class DesignSectionTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.docs = Path(self._tmp.name)
        (self.docs / "alpha.md").write_text(ALPHA, encoding="utf-8")
        (self.docs / "beta.md").write_text(BETA, encoding="utf-8")
        (self.docs / "README.md").write_text(README, encoding="utf-8")

    def test_a_board_prints_its_status_its_sections_and_their_line_ranges(self):
        code, out, _ = run(["BoardX"], self.docs)
        self.assertEqual(code, 0)
        self.assertIn("# board: BoardX, BoardXLight  status: Built", out)
        self.assertRegex(out, r"--- .*alpha\.md:\d+-\d+  Alpha part two")
        self.assertIn("Text of part two.", out)
        self.assertNotIn("Intro of part one.", out)

    def test_a_board_is_found_by_any_of_its_names_in_any_case(self):
        for name in ("boardxlight", "BOARDX"):
            code, out, _ = run([name], self.docs)
            self.assertEqual(code, 0, name)
            self.assertIn("Text of part two.", out)

    def test_a_lead_in_named_by_the_board_narrows_the_section_to_that_block(self):
        code, out, _ = run(["BoardCard"], self.docs)
        self.assertEqual(code, 0)
        self.assertIn("the card line", out)
        self.assertNotIn("the row line", out)
        self.assertIn("narrowed from", out)

    def test_full_prints_the_whole_section_a_lead_in_narrowed(self):
        code, out, _ = run(["BoardCard", "--full"], self.docs)
        self.assertEqual(code, 0)
        self.assertIn("the card line", out)
        self.assertIn("the row line", out)

    def test_a_board_naming_two_sections_prints_both_once(self):
        code, out, _ = run(["BoardWhole"], self.docs)
        self.assertEqual(code, 0)
        self.assertEqual(out.count("Intro of part one."), 1)
        self.assertIn("Beta text.", out)

    def test_a_board_that_names_no_heading_falls_back_to_the_outlines_of_its_files(self):
        code, out, _ = run(["BoardVague"], self.docs)
        self.assertEqual(code, 0)
        self.assertIn("outlines of its files", out)
        self.assertIn("beta.md:", out)
        self.assertNotIn("Beta text.", out)

    def test_a_heading_prints_its_section_and_stops_at_the_next_one(self):
        code, out, _ = run(["Alpha part one"], self.docs)
        self.assertEqual(code, 0)
        self.assertIn("Intro of part one.", out)
        self.assertNotIn("Text of part two.", out)

    def test_a_heading_matches_by_a_prefix_or_a_word_run_when_it_is_the_only_match(self):
        for query in ("beta only", "Beta", "part two"):
            code, out, _ = run([query], self.docs)
            self.assertEqual(code, 0, query)

    def test_two_headings_of_the_same_level_with_one_name_are_ambiguous(self):
        code, out, err = run(["Shared name"], self.docs)
        self.assertEqual(code, 2)
        self.assertEqual(out, "")
        self.assertIn("ambiguous", err)
        self.assertIn("alpha.md", err)
        self.assertIn("beta.md", err)

    def test_a_path_chooses_between_two_headings_of_one_name(self):
        for query in ("Alpha › Shared name", "Alpha > Shared name"):
            code, out, _ = run([query], self.docs)
            self.assertEqual(code, 0, query)
            self.assertIn("First shared.", out)
            self.assertNotIn("Second shared.", out)

    def test_a_path_that_ends_in_a_lead_in_prints_only_that_block(self):
        code, out, _ = run(["Alpha part one › The row"], self.docs)
        self.assertEqual(code, 0)
        self.assertIn("the row line", out)
        self.assertNotIn("the card line", out)

    def test_a_path_that_names_nothing_fails(self):
        code, _, err = run(["Nowhere › Else"], self.docs)
        self.assertEqual(code, 2)
        self.assertIn("no heading matches the path", err)

    def test_a_name_that_is_no_heading_finds_a_bold_lead_in_block(self):
        code, out, _ = run(["The row"], self.docs)
        self.assertEqual(code, 0)
        self.assertIn("# block: The row", out)
        self.assertIn("the row line", out)
        self.assertNotIn("the card line", out)

    def test_a_top_level_bullet_with_a_bold_lead_in_is_a_block_inside_its_lead_in(self):
        (self.docs / "menus.md").write_text(
            "# Menus\n\n> Read when menus.\n\n**Menus** float.\n\n"
            "- **Slash menu** (a): opens on slash.\n  more slash text\n"
            "- **Model picker** (b): opens on chord.\n\n**After.** later\n", encoding="utf-8")
        code, out, _ = run(["Slash menu"], self.docs)
        self.assertEqual(code, 0)
        self.assertIn("more slash text", out)
        self.assertNotIn("opens on chord", out)
        code, out, _ = run(["Menus › Model picker"], self.docs)
        self.assertEqual(code, 0)
        self.assertIn("opens on chord", out)
        self.assertNotIn("more slash text", out)

    def test_a_lead_in_name_two_files_share_is_ambiguous(self):
        (self.docs / "gamma.md").write_text("# Gamma\n\n**The row:**\n\nother row\n", encoding="utf-8")
        code, out, err = run(["The row"], self.docs)
        self.assertEqual(code, 2)
        self.assertIn("names several blocks", err)

    def test_a_block_over_the_cap_prints_its_parts_not_its_lines(self):
        body = "".join(f"filler line {n}\n" for n in range(design_section.MAX_BLOCK + 20))
        (self.docs / "big.md").write_text(
            f"# Big\n\n> Read when big.\n\n**First part.**\n\n{body}\n**Second part.**\n\nlast\n", encoding="utf-8")
        code, out, _ = run(["Big"], self.docs)
        self.assertEqual(code, 0)
        self.assertIn("too long to print whole", out)
        self.assertIn("**Second part.**", out)
        self.assertNotIn("filler line 5", out)
        code, out, _ = run(["Big › Second part"], self.docs)
        self.assertIn("last", out)
        self.assertNotIn("too long", out)
        code, out, _ = run(["Big", "--full"], self.docs)
        self.assertIn("filler line 5\n", out)

    def test_an_unknown_name_fails_with_a_suggestion(self):
        code, out, err = run(["Alpha part to"], self.docs)
        self.assertEqual(code, 2)
        self.assertIn("no board or heading matches", err)
        self.assertIn("Did you mean", err)

    def test_a_query_is_required(self):
        code, _, err = run([], self.docs)
        self.assertEqual(code, 2)
        self.assertIn("give a board or heading", err)

    def test_outline_lists_headings_and_lead_ins_with_line_numbers(self):
        code, out, _ = run(["Alpha part one", "--outline"], self.docs)
        self.assertEqual(code, 0)
        self.assertIn("**The card**", out)
        self.assertIn("**The row**", out)
        self.assertNotIn("the card line", out)

    def test_list_names_every_file_with_its_read_when_line(self):
        code, out, _ = run(["--list"], self.docs)
        self.assertEqual(code, 0)
        self.assertIn("alpha.md", out)
        self.assertIn("Read when you change beta.", out)

    def test_a_missing_folder_fails_clearly(self):
        code, _, err = run(["x"], self.docs / "nope")
        self.assertEqual(code, 2)
        self.assertIn("does not exist", err)


class DocsplitTests(unittest.TestCase):
    def test_headings_inside_a_code_fence_are_not_headings(self):
        lines = ALPHA.split("\n")
        titles = [h.title for h in docsplit.headings(lines)]
        self.assertEqual(titles, ["Alpha", "Alpha part one", "Alpha part two (BoardX)", "Shared name"])

    def test_a_section_ends_at_the_next_heading_of_the_same_or_a_higher_level(self):
        lines = "# T\n## A\ntext\n### A1\nmore\n## B\nlast".split("\n")
        hs = docsplit.headings(lines)
        self.assertEqual(docsplit.section_end(hs, 1, len(lines)), 5)
        self.assertEqual(docsplit.section_end(hs, 2, len(lines)), 5)

    def test_relative_links_are_re_pointed_for_the_folder_a_file_moved_to(self):
        text = "[a](docs/ios/README.md) [b](docs/x.md#frag) [c](https://x.org/a.md) [d](#top) `![alt](src)`"
        out = docsplit.rebase_links(text, ".", "docs/design")
        self.assertIn("(../ios/README.md)", out)
        self.assertIn("(../x.md#frag)", out)
        self.assertIn("(https://x.org/a.md)", out)
        self.assertIn("(#top)", out)
        self.assertIn("(src)", out)

    def test_section_references_compare_equal_before_and_after_they_are_re_pointed(self):
        before = "see DESIGN.md › Thread › Can't start"
        after = "see docs/design/thread.md › Thread › Can't start"
        self.assertEqual(docsplit.canon_refs(before), docsplit.canon_refs(after))
        self.assertNotEqual(docsplit.canon_refs(before), "see Thread")

    def test_the_conservation_check_sees_a_lost_and_a_duplicated_line(self):
        old = docsplit.body_counter(["# T", "a", "b", "", "b"])
        lost, extra = docsplit.counter_diff(old, docsplit.body_counter(["# T", "a", "b"]))
        self.assertEqual(dict(lost), {"b": 1})
        self.assertEqual(dict(extra), {})
        lost, extra = docsplit.counter_diff(old, docsplit.body_counter(["a", "b", "b", "a"]))
        self.assertEqual((dict(lost), dict(extra)), ({}, {"a": 1}))

    def test_fenced_hash_lines_count_as_body_lines(self):
        counter = docsplit.body_counter(["```sh", "# comment", "```"])
        self.assertEqual(counter["# comment"], 1)

    def test_resolve_entry_fans_out_over_comma_separated_alternatives(self):
        lines = ["# File", "## Parent", "### One", "x", "### Two", "y", "### Three", "z"]
        sections = docsplit.sections_of("f.md", lines)
        found = docsplit.resolve_entry("Parent › One, Three", sections)
        self.assertEqual([r.section.title for r in found], ["One", "Three"])

    def test_resolve_entry_keeps_words_that_name_no_heading_as_a_focus(self):
        sections = docsplit.sections_of("f.md", ["# File", "## Parent", "text"])
        (found,) = docsplit.resolve_entry("Parent › The card, Speed menu", sections)
        self.assertEqual(found.focus, ("The card", "Speed menu"))

    def test_resolve_entry_prefers_an_equal_title_then_the_shallowest(self):
        lines = ["# Thread", "x", "# Other", "## Thread (deep)", "y"]
        sections = docsplit.sections_of("f.md", lines)
        (found,) = docsplit.resolve_entry("Thread", sections)
        self.assertEqual(found.section.level, 1)


class RealDesignDocsTests(unittest.TestCase):
    """The docs/design/ in this checkout."""

    @classmethod
    def setUpClass(cls):
        cls.dir = Path(ROOT) / "docs" / "design"
        if not cls.dir.is_dir():
            raise unittest.SkipTest("docs/design does not exist")
        cls.docs = design_section.Docs(cls.dir)

    def test_every_board_in_the_index_resolves_to_a_spec(self):
        self.assertGreater(len(self.docs.boards), 150)
        unresolved = []
        for board in self.docs.boards:
            found = []
            for entry in docsplit.split_top(board.specified, ";"):
                found += docsplit.resolve_entry(entry, self.docs.sections)
            if not found and not [f for f in board.files if f in self.docs.lines]:
                unresolved.append(board.names[0])
        self.assertEqual(unresolved, [])

    def test_every_file_a_board_row_links_exists(self):
        missing = sorted({f for b in self.docs.boards for f in b.files if f not in self.docs.lines})
        self.assertEqual(missing, [])

    def test_a_board_names_its_file_and_prints_a_narrowed_block(self):
        code, out, _ = run(["ComposerSpeed"], self.dir)
        self.assertEqual(code, 0)
        self.assertIn("docs/design/composer.md", out)
        self.assertIn("The control row", out)

    def test_a_board_that_two_files_specify_prints_a_section_of_each(self):
        code, out, _ = run(["Main"], self.dir)
        self.assertEqual(code, 0)
        for name in ("thread.md", "composer.md"):
            self.assertIn(name, out)

    def test_a_section_the_split_moved_to_another_file_is_still_found_by_its_path(self):
        code, out, _ = run(["SettingsPiSignIn"], self.dir)
        self.assertEqual(code, 0)
        self.assertIn("settings-pi.md", out)

    def test_the_top_thread_section_wins_over_the_ipad_one_and_says_so(self):
        code, out, _ = run(["Thread"], self.dir)
        self.assertEqual(code, 0)
        self.assertIn("thread.md", out)
        self.assertIn("also matches", out)


if __name__ == "__main__":
    unittest.main()
