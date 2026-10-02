"""Tests for scripts/context_budget.py, which counts what an agent's context carries before any work.

The counting runs on small synthetic captures (no pi, no Node), so these tests are exact about what
each section is made of. The real capture is Tests/Extensions/context-budget.test.mjs, which runs the
script's `--check` against a real pi. Run: python3 -m unittest discover -s Tests/Release -v
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import context_budget as cb  # noqa: E402

SCRIPT = os.path.join(ROOT, "scripts", "context_budget.py")


def system_prompt(rules="- Be concise", tools="- read: Read files", docs="Docs", extra=None, addendum=None, files=None, skills=None):
    parts = ["You are a coding agent.", f"<tools>\n{tools}\n</tools>", f"<rules>\n{rules}\n</rules>", f"<docs>\n{docs}\n</docs>"]
    if addendum:
        parts.append(f"<addendum>\n{addendum}\n</addendum>")
    if files:
        body = "Project-specific instructions and guidelines:\n\n" + "\n\n".join(
            f'<project_instructions path="{path}">\n{text}\n</project_instructions>' for path, text in files)
        parts.append(f"<project_context>\n{body}\n</project_context>")
    if skills:
        parts.append(f"<skills>\n{skills}\n</skills>")
    parts.append("<cwd>\n/work\n</cwd>")
    for name, text in (extra or {}).items():
        parts.append(f"<{name}>\n{text}\n</{name}>")
    return "\n\n".join(parts)


def tool(name, description="d", **props):
    return {"type": "function", "name": name, "description": description,
            "parameters": {"type": "object", "properties": {key: {"type": "string"} for key in props}}}


def capture(system, tools=(), sources=None, project="/work/AGENTS.md"):
    return {"path": "/v1/responses", "body": {"model": "m", "input": [{"role": "system", "content": system}, {"role": "user", "content": "hi"}],
                                             "tools": list(tools)}, "toolSources": sources or {}, "projectFile": project}


BARE = capture(system_prompt(), [tool("read"), tool("bash")], {"read": "<builtin:read>", "bash": "<builtin:bash>"}, project="")


class CountingTests(unittest.TestCase):
    def test_tokens_are_four_characters_rounded_up(self):
        self.assertEqual([cb.tokens(n) for n in (0, 1, 4, 5, 8, 9)], [0, 1, 1, 2, 2, 3])

    def test_a_prompts_sections_add_up_to_the_whole_prompt(self):
        text = system_prompt(addendum="Append", files=[("/work/AGENTS.md", "Rules")], skills="<skill>a</skill>")
        sections = cb.prompt_sections(text)
        self.assertEqual(list(sections), ["preamble", "tools", "rules", "docs", "addendum", "project_context", "skills", "cwd"])
        self.assertEqual("".join(sections.values()), text)

    def test_a_context_file_that_mentions_a_tag_stays_inside_its_section(self):
        text = system_prompt(files=[("/work/AGENTS.md", "Use <docs> and <rules> tags like this.\n</tools>")])
        sections = cb.prompt_sections(text)
        self.assertEqual(list(sections), ["preamble", "tools", "rules", "docs", "project_context", "cwd"])
        self.assertEqual("".join(sections.values()), text)

    def test_what_pi_owns_is_what_pi_alone_sends_and_the_rest_of_the_prompt_is_shepherds(self):
        thread = capture(system_prompt(tools="- read: Read files\n- terminal_open: Open a terminal " + "x" * 400,
                                       rules="- Be concise\n- " + "y" * 200), [tool("read"), tool("bash")],
                         {"read": "<builtin:read>", "bash": "<builtin:bash>"})
        counted = cb.count_scenario(thread, BARE)
        owned = sum(len(v) for k, v in cb.prompt_sections(cb.split_request(BARE["path"], BARE["body"])[0]).items() if k in cb.PI_OWNED)
        self.assertEqual(counted["chars"]["pi.prompt"], owned)
        self.assertGreaterEqual(counted["chars"]["shepherd.prompt"], 600)

    def test_each_instruction_file_is_its_own_row_with_the_wrappers_on_the_first(self):
        files = [("/support/pi/AGENTS.md", "A" * 100), ("/support/instructions/AGENTS.md", "B" * 200), ("/work/AGENTS.md", "C" * 400)]
        counted = cb.count_scenario(capture(system_prompt(addendum="D" * 50, files=files)), BARE)
        chars = counted["chars"]
        self.assertEqual((chars["ctx.global_agents"], chars["ctx.project_agents"]), (200, 400))
        self.assertGreater(chars["ctx.pi_home_agents"], 100)
        span = cb.prompt_sections(system_prompt(addendum="D" * 50, files=files))["project_context"]
        self.assertEqual(chars["ctx.pi_home_agents"] + chars["ctx.global_agents"] + chars["ctx.project_agents"], len(span))
        self.assertGreaterEqual(chars["ctx.append_system"], 50)

    def test_tools_are_grouped_by_the_extension_that_registered_them(self):
        names = {"read": "<builtin:read>", "terminal_open": "Extensions/shepherd-panes.ts", "agent_send": "Extensions/shepherd-panes.ts",
                 "notify": "Extensions/shepherd-panes.ts", "browser_open": "Extensions/shepherd-browser.ts", "mcp": "Extensions/shepherd-mcp.ts",
                 "github_get_issue": "Extensions/shepherd-mcp.ts", "shepherd_child_start": "Extensions/shepherd-children.ts",
                 "review_diff": "Extensions/shepherd-review.ts", "design_get": "Extensions/shepherd-design-refs.ts", "mine": "/elsewhere/own.ts"}
        counted = cb.count_scenario(capture(system_prompt(), [tool(n) for n in names], names), BARE)
        groups = {t["name"]: t["group"] for t in counted["tools"]}
        self.assertEqual(groups, {"read": "pi.builtin_tools", "terminal_open": "tools.terminal", "agent_send": "tools.agent", "notify": "tools.automation",
                                  "browser_open": "tools.browser", "mcp": "tools.mcp", "github_get_issue": "tools.mcp_direct",
                                  "shepherd_child_start": "tools.children", "review_diff": "tools.review", "design_get": "tools.design", "mine": "tools.other"})

    def test_a_tool_costs_its_definition_as_the_provider_received_it(self):
        counted = cb.count_scenario(capture(system_prompt(), [tool("terminal_open", "d" * 80, cwd="x")], {"terminal_open": "Extensions/shepherd-panes.ts"}), BARE)
        size = len(json.dumps(tool("terminal_open", "d" * 80, cwd="x"), separators=(",", ":")))
        self.assertEqual(counted["tools"][0]["chars"], size)
        self.assertEqual(counted["chars"]["tools.terminal"], size)

    def test_every_api_pi_speaks_is_read(self):
        text = system_prompt()
        responses = {"input": [{"role": "developer", "content": [{"type": "input_text", "text": text}]}], "tools": [tool("read")]}
        completions = {"messages": [{"role": "system", "content": text}], "tools": [{"type": "function", "function": {"name": "read", "parameters": {}}}]}
        anthropic = {"system": [{"type": "text", "text": text}], "tools": [{"name": "read", "input_schema": {}}]}
        for body in (responses, completions, anthropic):
            system, tools = cb.split_request("/x", body)
            self.assertEqual(system, text)
            self.assertEqual([t["name"] for t in tools], ["read"])


class CeilingTests(unittest.TestCase):
    def measured(self, **changes):
        files = [("/support/instructions/AGENTS.md", "B" * 400), ("/work/AGENTS.md", "C" * 4000)]
        tools = [tool("read"), tool("terminal_open", "d" * 200)]
        sources = {"read": "<builtin:read>", "terminal_open": "Extensions/shepherd-panes.ts"}
        scenario = capture(system_prompt(addendum="D" * 100, files=files), tools + [tool(n, "d" * changes.get("size", 400)) for n in changes.get("more", [])],
                           {**sources, **{n: "Extensions/shepherd-panes.ts" for n in changes.get("more", [])}})
        return cb.measure({"piVersion": changes.get("pi", "1.0.0"), "api": "openai-responses", "scenarios": {"bare": BARE, "thread": scenario}})

    def test_what_was_measured_passes_its_own_ceilings(self):
        measured = self.measured()
        self.assertEqual(cb.check(measured, cb.ceilings_document(measured)), [])

    def test_a_tool_added_past_the_margin_fails_and_names_the_section(self):
        ceilings = cb.ceilings_document(self.measured())
        problems = cb.check(self.measured(more=["terminal_extra_one", "terminal_extra_two", "terminal_extra_three"]), ceilings)
        self.assertTrue(any("terminal_*" in line for line in problems), problems)
        self.assertTrue(any(line.startswith("Total before any work") for line in problems), problems)

    def test_growth_inside_the_margin_passes(self):
        ceilings = cb.ceilings_document(self.measured())
        self.assertEqual(cb.check(self.measured(more=["terminal_small"], size=20), ceilings), [])

    def test_the_projects_own_agents_md_is_not_guarded(self):
        measured = self.measured()
        ceilings = cb.ceilings_document(measured)
        self.assertNotIn("ctx.project_agents", ceilings["tokens"])
        measured["scenarios"]["thread"]["rows"]["ctx.project_agents"] += 5000
        self.assertEqual(cb.check(measured, ceilings), [])

    def test_a_section_the_ceilings_do_not_list_fails(self):
        measured = self.measured()
        ceilings = cb.ceilings_document(measured)
        del ceilings["tokens"]["tools.terminal"]
        self.assertTrue(any("does not list" in line for line in cb.check(measured, ceilings)))

    def test_a_new_pi_gets_room_on_its_own_sections_and_none_on_shepherds(self):
        old = self.measured(pi="0.87.1")
        ceilings = cb.ceilings_document(old)
        newer = self.measured(pi="1.0.0")
        newer["scenarios"]["thread"]["rows"]["pi.prompt"] += int(ceilings["tokens"]["pi.prompt"] * 0.2) + 1
        self.assertEqual(cb.check(newer, ceilings), [], "a pi that moved its own prompt by 20% is allowed")
        newer["scenarios"]["thread"]["rows"]["tools.terminal"] += 500
        self.assertTrue(any("terminal_*" in line for line in cb.check(newer, ceilings)))

    def test_the_committed_ceilings_file_lists_only_rows_the_script_presents(self):
        with open(cb.CEILINGS, encoding="utf-8") as f:
            ceilings = json.load(f)
        self.assertEqual(sorted(set(ceilings["tokens"]) - set(cb.LABELS)), [])
        self.assertEqual(ceilings["total"], sum(ceilings["tokens"].values()), "the total is the sum of the guarded rows")
        self.assertGreater(ceilings["toolCount"], 30)


class CommandLineTests(unittest.TestCase):
    def run_script(self, *args):
        return subprocess.run([sys.executable, SCRIPT, *args], capture_output=True, text=True, cwd=ROOT)

    def test_check_exits_one_with_the_table_when_a_section_grew(self):
        with tempfile.TemporaryDirectory() as folder:
            measured = CeilingTests().measured()
            ceilings = os.path.join(folder, "ceilings.json")
            small = cb.ceilings_document(measured)
            small["tokens"]["tools.terminal"] = 1
            small["total"] = 1
            with open(ceilings, "w", encoding="utf-8") as f:
                json.dump(small, f)
            captured = os.path.join(folder, "capture.json")
            files = [("/support/instructions/AGENTS.md", "B" * 400), ("/work/AGENTS.md", "C" * 4000)]
            with open(captured, "w", encoding="utf-8") as f:
                json.dump({"piVersion": "1.0.0", "api": "openai-responses", "scenarios": {"bare": BARE, "thread": capture(
                    system_prompt(files=files), [tool("terminal_open", "d" * 4000)], {"terminal_open": "Extensions/shepherd-panes.ts"})}}, f)
            result = self.run_script("--capture", captured, "--ceilings", ceilings, "--check")
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn("grew past", result.stdout)
            self.assertIn("scripts/context_budget.py --update", result.stdout)
            self.assertIn("| Section | Tokens |", result.stdout)

    def test_check_passes_and_says_so_when_nothing_grew(self):
        with tempfile.TemporaryDirectory() as folder:
            files = [("/work/AGENTS.md", "C" * 400)]
            document = {"piVersion": "1.0.0", "api": "openai-responses", "scenarios": {"bare": BARE, "thread": capture(
                system_prompt(files=files), [tool("terminal_open")], {"terminal_open": "Extensions/shepherd-panes.ts"})}}
            captured = os.path.join(folder, "capture.json")
            with open(captured, "w", encoding="utf-8") as f:
                json.dump(document, f)
            ceilings = os.path.join(folder, "ceilings.json")
            self.assertEqual(self.run_script("--capture", captured, "--ceilings", ceilings, "--update").returncode, 0)
            result = self.run_script("--capture", captured, "--ceilings", ceilings, "--check")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("context budget ok", result.stdout)


if __name__ == "__main__":
    unittest.main()
