"""Tests for scripts/check_pr_body.py, the pr-body workflow's rules: a pull request that changes UI
says its Departures, what it Rendered and the Controls it used, and one with a "Features that act
on their own" section fills in its Bounds, Data, Restart and stop and Decisions. A pull request that
touches no UI and has no such section is never failed.

Run: python3 -m unittest discover -s Tests/Release -v
"""
import importlib.util
import io
import os
import re
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..")))
SPEC = importlib.util.spec_from_file_location("check_pr_body", ROOT / "scripts" / "check_pr_body.py")
check = importlib.util.module_from_spec(SPEC)
sys.modules["check_pr_body"] = check
SPEC.loader.exec_module(check)

UI_FILE = "Sources/ShepherdApp/Thread/Composer.swift"
UI_BODY = """## Summary
A card.

## UI changes

- **Design:** docs/design/boards/GoalCard.png
- **Departures:** none
- **Rendered:** idle, running, empty, long text, light and dark, scale 1.5, from the store: /tmp/previews
- **Controls used:** Pause, Resume, Edit and Clear, pressed with ControlPress in each state
"""
AUTONOMOUS_BODY = """## Features that act on their own

- **Bounds:** 20 turns, 30 minutes, 500k tokens; hit in GoalBoundsTests
- **Data:** the thread's own provider only; nothing else leaves the machine
- **Restart and stop:** a restart pauses it; Stop ends it
- **Decisions:** the cap is mine
"""


class UIRules(unittest.TestCase):
    def test_a_body_that_answers_every_ui_line_passes(self):
        self.assertEqual(check.problems(UI_BODY, [UI_FILE]), [])

    def test_a_pull_request_that_touches_no_ui_is_never_failed(self):
        for files in ([], ["docs/testing.md"], ["Sources/ShepherdSessions/SessionServer.swift", "Tests/Release/test_release.py"],
                      ["Sources/ShepherdApp/README.md"]):
            self.assertEqual(check.problems("", files), [], files)
            self.assertEqual(check.problems(None, files), [], files)

    def test_each_folder_of_ui_files_asks_for_the_lines(self):
        for path in ("Sources/ShepherdApp/Thread/Composer.swift", "Packages/ShepherdUI/Sources/ShepherdUI/Components/Composer/Menus.swift",
                     "App/iOS/Composer/ComposerControls.swift", "Packages/ShepherdUI/Package.swift"):
            self.assertEqual(len(check.problems("", [path])), 3, path)

    def test_each_missing_line_is_named(self):
        for label in ("Departures", "Rendered", "Controls used"):
            body = re.sub(rf"^- \*\*{label}:\*\*.*\n", "", UI_BODY, flags=re.MULTILINE)
            found = check.problems(body, [UI_FILE])
            self.assertEqual(len(found), 1, label)
            self.assertIn(f"'{label}:'", found[0])
            self.assertIn(UI_FILE, found[0])

    def test_none_counts_as_an_answer_for_departures(self):
        self.assertEqual(check.problems(UI_BODY.replace("**Departures:** none", "Departures: None."), [UI_FILE]), [])

    def test_a_template_placeholder_is_not_an_answer(self):
        body = UI_BODY.replace("none\n", "<!-- every difference from the design you kept -->\n", 1)
        found = check.problems(body, [UI_FILE])
        self.assertEqual(len(found), 1)
        self.assertIn("'Departures:'", found[0])

    def test_filler_is_not_an_answer(self):
        for filler in ("", "TODO", "tbd", "...", "…", "-", "?"):
            body = UI_BODY.replace("**Rendered:**", f"**Rendered:** {filler}\nRendered_gone:", 1)
            body = re.sub(r"Rendered_gone:.*\n", "", body)
            found = check.problems(body, [UI_FILE])
            self.assertTrue(any("'Rendered:'" in f for f in found), repr(filler))

    def test_the_spellings_a_template_edit_produces_all_count(self):
        for line in ("- **Rendered:** states", "- **Rendered**: states", "**Rendered:** states", "* Rendered: states",
                     "  - rendered: states", "- __Rendered:__ states"):
            self.assertEqual(check.fields(line)["Rendered"], "states", line)

    def test_an_answer_may_run_over_the_lines_after_the_label(self):
        body = UI_BODY.replace("- **Rendered:** idle", "- **Rendered:**\n  - idle").replace("- **Departures:** none", "- **Departures:**\n  - the pill is 1px taller")
        self.assertEqual(check.problems(body, [UI_FILE]), [])
        self.assertEqual(check.fields(body)["Departures"], "- the pill is 1px taller")

    def test_a_value_stops_at_the_next_label_or_heading(self):
        body = "- **Departures:**\n- **Rendered:** x\n\n## Next\nnot part of rendered\n"
        said = check.fields(body)
        self.assertEqual(said["Departures"], "")
        self.assertEqual(said["Rendered"], "x")

    def test_the_next_item_of_the_list_is_not_part_of_an_empty_answer(self):
        body = "- **Controls used:** <!-- placeholder -->\n- **Not verified:** the iPad\n"
        self.assertEqual(check.fields(body)["Controls used"], "")
        self.assertTrue(any("'Controls used:'" in f for f in check.problems(UI_BODY.replace(
            "- **Controls used:** Pause, Resume, Edit and Clear, pressed with ControlPress in each state", body.rstrip()), [UI_FILE])))

    def test_a_long_list_of_ui_files_is_summarized(self):
        files = [f"Sources/ShepherdApp/File{i}.swift" for i in range(5)]
        self.assertIn("and 2 more", check.problems("", files)[0])


class AutonomousRules(unittest.TestCase):
    def test_a_filled_section_passes(self):
        self.assertEqual(check.problems(AUTONOMOUS_BODY, []), [])

    def test_a_body_without_the_section_is_not_asked_for_it(self):
        self.assertEqual(check.problems("A background worker.\nBounds: none yet\n", []), [])

    def test_each_empty_line_of_the_section_is_named(self):
        for label in ("Bounds", "Data", "Restart and stop", "Decisions"):
            body = re.sub(rf"^- \*\*{label}:\*\*.*\n", f"- **{label}:** <!-- placeholder -->\n", AUTONOMOUS_BODY, flags=re.MULTILINE)
            found = check.problems(body, [])
            self.assertEqual(len(found), 1, label)
            self.assertIn(f"'{label}:'", found[0])
            self.assertIn("delete the whole section", found[0])

    def test_the_heading_is_found_at_any_level_and_in_any_case(self):
        for heading in ("# Features that act on their own", "### features that ACT on their own", "## Features that act on their own (delete if none)"):
            self.assertEqual(len(check.problems(f"{heading}\n", [])), 4, heading)

    def test_a_heading_inside_a_comment_does_not_count(self):
        self.assertEqual(check.problems("<!--\n## Features that act on their own\n-->\n", []), [])

    def test_both_rules_apply_to_a_pull_request_that_has_both(self):
        self.assertEqual(check.problems(UI_BODY + AUTONOMOUS_BODY, [UI_FILE]), [])
        self.assertEqual(len(check.problems("## Features that act on their own\n", [UI_FILE])), 3 + 4)


class Template(unittest.TestCase):
    """The pull request template and the check agree."""

    template = (ROOT / ".github" / "pull_request_template.md").read_text(encoding="utf-8")

    def test_the_template_carries_every_line_the_check_reads(self):
        for label in list(check.UI_FIELDS) + list(check.AUTONOMOUS_FIELDS):
            self.assertRegex(self.template, rf"(?m)^- \*\*{label}:\*\*", label)
        self.assertTrue(check.has_autonomous_section(self.template))

    def test_an_untouched_template_fails_a_ui_change_and_names_each_line(self):
        found = check.problems(self.template, [UI_FILE])
        self.assertEqual(len(found), 3 + 4, found)

    def test_a_template_with_both_sections_deleted_passes_a_change_that_has_no_ui(self):
        body = re.split(r"(?m)^## UI changes", self.template)[0] + "## Notes for reviewers\n\nnothing\n"
        self.assertEqual(check.problems(body, ["Sources/ShepherdSessions/SessionServer.swift"]), [])

    def test_a_filled_template_passes(self):
        body = re.sub(r"(- \*\*[A-Za-z ]+:\*\*) <!--.*?-->", r"\1 answered", self.template)
        self.assertEqual(check.problems(body, [UI_FILE]), [])


class Command(unittest.TestCase):
    def run_main(self, body, files, env=None):
        with tempfile.TemporaryDirectory() as scratch:
            list_path = Path(scratch) / "files.txt"
            list_path.write_text("\n".join(files) + "\n", encoding="utf-8")
            args = ["--files-file", str(list_path)]
            if body is not None:
                body_path = Path(scratch) / "body.md"
                body_path.write_text(body, encoding="utf-8")
                args += ["--body-file", str(body_path)]
            out = io.StringIO()
            saved = dict(os.environ)
            try:
                os.environ.pop("GITHUB_ACTIONS", None)
                os.environ.update(env or {})
                with redirect_stdout(out):
                    status = check.main(args)
            finally:
                os.environ.clear()
                os.environ.update(saved)
            return status, out.getvalue()

    def test_a_good_body_exits_zero(self):
        status, out = self.run_main(UI_BODY, [UI_FILE])
        self.assertEqual(status, 0, out)

    def test_a_bad_body_exits_one_and_says_what_to_add(self):
        status, out = self.run_main("", [UI_FILE])
        self.assertEqual(status, 1)
        self.assertIn("error: UI files changed", out)
        self.assertIn("Departures", out)
        self.assertIn(".github/pull_request_template.md", out)

    def test_the_body_may_come_from_the_environment(self):
        status, _ = self.run_main(None, [UI_FILE], env={"PR_BODY": UI_BODY})
        self.assertEqual(status, 0)
        status, _ = self.run_main(None, [UI_FILE], env={"PR_BODY": ""})
        self.assertEqual(status, 1)

    def test_github_actions_gets_an_error_annotation(self):
        _, out = self.run_main("", [UI_FILE], env={"GITHUB_ACTIONS": "true"})
        self.assertIn("::error title=Pull request body::", out)


class Workflow(unittest.TestCase):
    workflow = (ROOT / ".github" / "workflows" / "pr-body.yml").read_text(encoding="utf-8")

    def test_it_runs_when_the_body_is_edited_and_when_files_change(self):
        self.assertRegex(self.workflow, r"types: \[opened, edited, synchronize, reopened\]")

    def test_it_runs_the_script_and_reads_the_changed_files_through_the_api(self):
        self.assertIn("scripts/check_pr_body.py", self.workflow)
        self.assertIn("pulls/$PR_NUMBER/files", self.workflow)

    def test_the_body_reaches_the_script_only_through_the_environment(self):
        lines = [l for l in self.workflow.splitlines() if "pull_request.body" in l and not l.lstrip().startswith("#")]
        self.assertEqual([l.strip() for l in lines], ["PR_BODY: ${{ github.event.pull_request.body }}"])

    def test_it_asks_for_no_more_than_reading(self):
        self.assertIn("contents: read", self.workflow)
        self.assertIn("pull-requests: read", self.workflow)
        self.assertNotRegex(self.workflow, r"(?m)^\s+(contents|pull-requests|issues|checks): write")


if __name__ == "__main__":
    unittest.main()
