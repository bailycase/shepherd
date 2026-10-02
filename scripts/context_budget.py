#!/usr/bin/env python3
"""What an agent's context carries before the user has said anything, measured on a real pi.

    context_budget.py [--pi DIR] [--api openai-responses] [--markdown | --json] [--tools]
    context_budget.py --check      # fail when a section grew past its committed ceiling
    context_budget.py --update     # write what was measured as the new ceilings

It runs Tests/Extensions/context-harness.mjs: a real `pi --mode rpc` launched the way Shepherd launches
an agent's (the extensions in PiLaunch's order with the app's environment, Settings ▸ Instructions' files,
the repository's AGENTS.md as the project file, some skills, MCP servers) on a fake provider that records
the request body, and counts what that request carried. docs/context-budget.md explains the table.

Tokens are characters divided by four, rounded up: pi's own estimate (`estimateTokens`) and the one the
Context card uses. No tokenizer is vendored, and the aim is the shape of the cost, not the bill. Checked
once against OpenAI's o200k_base on a capture: it counts 1 to 12 percent fewer tokens than characters / 4
(the prompt 0.96, tool definitions 0.88, an AGENTS.md 0.99), so the table errs high, a little more for JSON.

The ceilings (scripts/context-budget.json) are what the tree measured when someone last decided the
numbers were right. A section may grow by its margin without a new commit; past that the check fails
until the file is updated, which is the moment to say in the pull request why the prompt got bigger.
Standard library only; the harness needs Node and a pi package (PI_PACKAGE_DIR).
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
HARNESS = os.path.join(ROOT, "Tests", "Extensions", "context-harness.mjs")
CEILINGS = os.path.join(ROOT, "scripts", "context-budget.json")

# The window the shares are quoted against: the one in the Context card's example (a 272k model).
WINDOW = 272_000
# How much a section may grow before --check fails: a share of its ceiling, and never less than a floor
# (the capture's paths, such as pi's docs folder and the scratch project, change by a few characters).
MARGIN_PERCENT = 5
MARGIN_FLOOR = 60
TOTAL_PERCENT = 2
TOTAL_FLOOR = 150
# A pi that is not the one the ceilings came from has its own sections move; they get this much room.
PI_MOVES_PERCENT = 25

# Rows the check does not guard: the repository's own AGENTS.md has its own size cap (Tests/Release/test_agent_docs.py).
UNGUARDED = {"ctx.project_agents"}

PRESENTED = [
    # key, label, kind
    ("pi.prompt", "pi: system prompt (preamble, tool list, rules, docs, cwd)", "pi"),
    ("pi.builtin_tools", "pi: built-in tool definitions (read, bash, edit, write)", "pi"),
    ("shepherd.prompt", "Shepherd: tool snippets and rules added to the prompt", "shepherd"),
    ("tools.terminal", "Shepherd tools: terminal_* (panes)", "shepherd"),
    ("tools.agent", "Shepherd tools: agent_* (panes)", "shepherd"),
    ("tools.automation", "Shepherd tools: automation_*, notify (panes)", "shepherd"),
    ("tools.review", "Shepherd tools: review_diff", "shepherd"),
    ("tools.children", "Shepherd tools: native subagents (shepherd_child_*, workflow)", "shepherd"),
    ("tools.browser", "Shepherd tools: browser_*", "shepherd"),
    ("tools.mcp", "Shepherd tools: mcp (one proxy tool)", "shepherd"),
    ("tools.mcp_direct", "Shepherd tools: MCP servers set to Each tool on its own", "shepherd"),
    ("tools.design", "Shepherd tools: design_get, design_note", "shepherd"),
    ("tools.design_agent", "Shepherd tools: a design agent's (design_read, board_write, ...)", "shepherd"),
    ("tools.other", "Other tools", "shepherd"),
    ("skills", "Skills list", "skills"),
    ("ctx.append_system", "Instructions: APPEND_SYSTEM.md", "context"),
    ("ctx.global_agents", "Instructions: Settings ▸ Instructions' AGENTS.md", "context"),
    ("ctx.pi_home_agents", "Instructions: the pi home's AGENTS.md", "context"),
    ("ctx.project_agents", "Instructions: the project's AGENTS.md", "context"),
]
LABELS = {key: label for key, label, _ in PRESENTED}
KINDS = {key: kind for key, _, kind in PRESENTED}


def tokens(chars: int) -> int:
    """pi's estimate: four characters a token, rounded up."""
    return (chars + 3) // 4


def compact(value) -> str:
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False)


# MARK: reading a request

def text_of(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(part.get("text", "") for part in content if isinstance(part, dict))
    return ""


def split_request(path: str, body: dict) -> tuple[str, list[dict]]:
    """The system prompt's text and the tool definitions as the provider received them, for each API pi speaks."""
    if "instructions" in body and isinstance(body["instructions"], str):
        system = body["instructions"]
    elif "system" in body:
        system = text_of(body["system"])
    else:
        system = ""
        for item in body.get("input", body.get("messages", [])):
            if item.get("role") in ("system", "developer"):
                system += text_of(item.get("content"))
            else:
                break
    tools = []
    for tool in body.get("tools", []):
        name = tool.get("name") or (tool.get("function") or {}).get("name") or ""
        tools.append({"name": name, "json": compact(tool), "tool": tool})
    return system, tools



SECTION_OPEN = re.compile(r"<([a-z][a-z0-9_-]*)>\n")
PI_OWNED = ("preamble", "tools", "rules", "docs", "cwd")


def prompt_sections(system: str) -> dict[str, str]:
    """pi's structured prompt as rendered: an untagged preamble, then `<name>` … `</name>` sections in
    order, each with its tags and the blank line after it, so the spans add up to the whole prompt."""
    first = re.search(r"\n\n(?=<[a-z][a-z0-9_-]*>\n)", system)
    if not first:
        return {"preamble": system}
    sections = {"preamble": system[:first.end()]}
    position = first.end()
    while position < len(system):
        opened = SECTION_OPEN.match(system, position)
        if not opened:
            sections["trailing"] = system[position:]
            break
        name = opened.group(1)
        close = system.find(f"\n</{name}>", opened.end())
        end = len(system) if close < 0 else close + len(f"\n</{name}>")
        if system.startswith("\n\n", end):
            end += 2
        sections[name] = system[position:end]
        position = end
    return sections


def context_files(section: str) -> list[tuple[str, str]]:
    """(path, text) of each file in `project_context`."""
    return [(m.group(1), m.group(2)) for m in re.finditer(r'<project_instructions path="([^"]*)">\n(.*?)\n</project_instructions>', section, re.S)]


# MARK: counting

BUILT_IN = ("read", "bash", "edit", "write", "grep", "find", "ls", "powershell")


def tool_group(name: str, source: str) -> str:
    base = os.path.basename(source)
    if source.startswith("<builtin:") or (not source and name in BUILT_IN):
        return "pi.builtin_tools"
    if base == "shepherd-panes.ts":
        if name.startswith("terminal_"):
            return "tools.terminal"
        if name.startswith("agent_"):
            return "tools.agent"
        return "tools.automation"
    if base == "shepherd-mcp.ts":
        return "tools.mcp" if name == "mcp" else "tools.mcp_direct"
    return {"shepherd-review.ts": "tools.review", "shepherd-children.ts": "tools.children", "shepherd-browser.ts": "tools.browser",
            "shepherd-design-refs.ts": "tools.design", "shepherd-design.ts": "tools.design_agent"}.get(base, "tools.other")


def context_row(path: str, project_path: str) -> str:
    """Which instruction file a `<project_instructions path>` is: the project's, Settings ▸ Instructions' (the
    support directory's `instructions/`) or the pi home's own."""
    normal = path.replace("\\", "/")
    if project_path and os.path.realpath(path) == os.path.realpath(project_path):
        return "ctx.project_agents"
    if "/instructions/" in normal:
        return "ctx.global_agents"
    return "ctx.pi_home_agents"


def section_chars(system: str) -> dict[str, int]:
    return {name: len(text) for name, text in prompt_sections(system).items()}


def count_scenario(captured: dict, bare: dict | None = None) -> dict:
    """Characters per row and per tool for one captured request; `bare` is pi alone, which is what pi owns."""
    system, tools = split_request(captured["path"], captured["body"])
    sections = prompt_sections(system)
    chars: dict[str, int] = {}

    def add(key: str, n: int) -> None:
        chars[key] = chars.get(key, 0) + n

    owned = sum(len(text) for name, text in sections.items() if name in PI_OWNED)
    if bare:
        pi = sum(section_chars(split_request(bare["path"], bare["body"])[0]).get(name, 0) for name in PI_OWNED)
        add("pi.prompt", pi)
        add("shepherd.prompt", max(0, owned - pi))
    else:
        add("pi.prompt", owned)

    for name, text in sections.items():
        if name == "addendum":
            add("ctx.append_system", len(text))
        elif name == "skills":
            add("skills", len(text))
        elif name == "project_context":
            files = context_files(text)
            inner = sum(len(content) for _, content in files)
            for path, content in files:
                add(context_row(path, captured.get("projectFile", "")), len(content))
            if files:
                # the lead-in and each file's wrapper go to the first file
                add(context_row(files[0][0], captured.get("projectFile", "")), len(text) - inner)
        elif name not in PI_OWNED:
            add(f"other.{name}", len(text))

    sources = captured.get("toolSources", {})
    per_tool: list[dict] = []
    for tool in tools:
        name = tool["name"]
        group = tool_group(name, sources.get(name, "") or "")
        size = len(tool["json"])
        add(group, size)
        per_tool.append({"name": name, "group": group, "chars": size, "tokens": tokens(size), "source": sources.get(name, "")})
    return {"chars": chars, "tools": per_tool, "skills": len(re.findall(r"<skill>", sections.get("skills", ""))),
            "system_chars": len(system), "tools_chars": sum(len(t["json"]) for t in tools)}


def rows_of(counted: dict) -> dict[str, int]:
    return {key: tokens(chars) for key, chars in counted["chars"].items()}


def total(rows: dict[str, int], guarded_only: bool = False) -> int:
    return sum(n for key, n in rows.items() if not (guarded_only and key in UNGUARDED))

# MARK: the capture

def find_pi(explicit: str | None) -> str:
    candidates = [explicit, os.environ.get("PI_PACKAGE_DIR"),
                  os.path.join(ROOT, ".build", "pi-engine", "Resources", "pi-engine")]
    for candidate in candidates:
        if candidate and os.path.exists(os.path.join(candidate, "dist", "bundle", "cli.js")):
            return candidate
    raise SystemExit("context_budget: no pi package found; pass --pi or set PI_PACKAGE_DIR "
                     "(the harness runs pi's dist/bundle/cli.js)")


def run_capture(pi: str, api: str, scenarios: list[str] | None = None) -> dict:
    command = ["node", HARNESS, "--pi", pi, "--api", api]
    if scenarios:
        command += ["--scenario", ",".join(scenarios)]
    proc = subprocess.run(command, capture_output=True, text=True, timeout=600)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr[-4000:])
        raise SystemExit(f"context_budget: the capture failed (exit {proc.returncode})")
    return json.loads(proc.stdout.strip().splitlines()[-1])


def measure(capture: dict) -> dict:
    scenarios = capture["scenarios"]
    bare = scenarios.get("bare")
    out = {"pi": capture["piVersion"], "api": capture["api"], "scenarios": {}}
    for name, captured in scenarios.items():
        if name == "bare":
            continue
        counted = count_scenario(captured, bare)
        out["scenarios"][name] = {"rows": rows_of(counted), "tools": counted["tools"], "skills": counted["skills"],
                                  "system_chars": counted["system_chars"], "tools_chars": counted["tools_chars"]}
    return out


# MARK: the table

def table(measured: dict, scenario: str = "thread") -> str:
    data = measured["scenarios"][scenario]
    rows = data["rows"]
    grand = total(rows)
    lines = [f"Context before the first message: scenario `{scenario}`, pi {measured['pi']}, {measured['api']}, tokens = chars / 4",
             "", "| Section | Tokens | Share of a %dk window |" % (WINDOW // 1000), "| --- | ---: | ---: |"]
    for key, label, _ in PRESENTED:
        if key in rows and rows[key]:
            lines.append(f"| {label} | {rows[key]:,} | {rows[key] / WINDOW * 100:.1f}% |")
    for key in sorted(k for k in rows if k.startswith("other.")):
        lines.append(f"| Prompt section `{key[6:]}` | {rows[key]:,} | {rows[key] / WINDOW * 100:.1f}% |")
    lines.append(f"| **Total before any work** | **{grand:,}** | **{grand / WINDOW * 100:.1f}%** |")
    return "\n".join(lines)


def tools_table(measured: dict, scenario: str | None = None, limit: int = 0) -> str:
    scenario = scenario or next(iter(measured["scenarios"]))
    tools = sorted(measured["scenarios"][scenario]["tools"], key=lambda t: -t["chars"])
    if limit:
        tools = tools[:limit]
    lines = ["| Tool | Group | Tokens |", "| --- | --- | ---: |"]
    for tool in tools:
        lines.append(f"| `{tool['name']}` | {LABELS.get(tool['group'], tool['group'])} | {tool['tokens']:,} |")
    return "\n".join(lines)


def scenarios_table(measured: dict) -> str:
    names = list(measured["scenarios"])
    lines = ["| Scenario | Tools | Tool definitions | Total |", "| --- | ---: | ---: | ---: |"]
    for name in names:
        data = measured["scenarios"][name]
        lines.append(f"| `{name}` | {len(data['tools'])} | {tokens(data['tools_chars']):,} | {total(data['rows']):,} |")
    return "\n".join(lines)


# MARK: the ceilings

# MARK: a long thread

AUTO_COMPACT_AT = WINDOW - 16_384


def run_simulation(pi: str, turns: int) -> dict:
    proc = subprocess.run(["node", HARNESS, "--pi", pi, "--simulate", "--turns", str(turns)], capture_output=True, text=True, timeout=1800)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr[-4000:])
        raise SystemExit(f"context_budget: the simulation failed (exit {proc.returncode})")
    return json.loads(proc.stdout.strip().splitlines()[-1])


def simulation_table(result: dict) -> str:
    """Tokens of the last request of each turn, with and without trimming, for a thread whose every turn reads a
    big search result (about 11.6k tokens), a file (about 3k) and runs a small command."""
    without, trimmed = result["without"], result["with"]
    lines = [f"A {result['turns']}-turn thread on pi {result['piVersion']}: each turn reads about 11.6k tokens of search output, 3k of a file and a small "
             f"command. Tokens in the last request of the turn (the ring's number); pi compacts past {AUTO_COMPACT_AT // 1000}k of a {WINDOW // 1000}k window.",
             "", "| Turn | Without trimming | With trimming |", "| ---: | ---: | ---: |"]
    for a, b in zip(without["perTurn"], trimmed["perTurn"]):
        if a["turn"] in (1, 3, 5, 6, 9, 12, 15, 18, 21, 24, result["turns"]) or a["turn"] % 6 == 0:
            note = " (compacts)" if a["tokens"] > AUTO_COMPACT_AT else ""
            lines.append(f"| {a['turn']} | {a['tokens']:,}{note} | {b['tokens']:,} |")
    first_over = next((a["turn"] for a in without["perTurn"] if a["tokens"] > AUTO_COMPACT_AT), None)
    lines += ["", "| | Without trimming | With trimming |", "| --- | ---: | ---: |",
              f"| Requests | {without['requests']} | {trimmed['requests']} |",
              f"| Input tokens sent, all requests | {without['sentTokens']:,} | {trimmed['sentTokens']:,} |",
              f"| Same, a cached token counted at a tenth | {without['billedTokens']:,} | {trimmed['billedTokens']:,} |",
              f"| Share of a request the next one repeats (a cache can reuse it): mean | {without['reuse']['mean'] * 100:.0f}% | {trimmed['reuse']['mean'] * 100:.0f}% |",
              f"| Same: lowest, and requests below 100% | {without['reuse']['min'] * 100:.0f}%, {without['reuse']['below']} | {trimmed['reuse']['min'] * 100:.0f}%, {trimmed['reuse']['below']} |",
              f"| First turn past the auto-compact mark | {first_over or 'none'} | {next((b['turn'] for b in trimmed['perTurn'] if b['tokens'] > AUTO_COMPACT_AT), 'none')} |"]
    return "\n".join(lines)


def ceilings_document(measured: dict) -> dict:
    rows = measured["scenarios"]["thread"]["rows"]
    return {
        "_about": "What `python3 scripts/context_budget.py` measured for an ordinary thread when someone last decided the numbers were right "
                  "(tokens, characters / 4). `--check` fails when a row grows past its margin; `--update` rewrites this file. docs/context-budget.md.",
        "pi": measured["pi"],
        "api": measured["api"],
        "margin": {"percent": MARGIN_PERCENT, "floor": MARGIN_FLOOR, "totalPercent": TOTAL_PERCENT, "totalFloor": TOTAL_FLOOR},
        "tokens": {key: rows[key] for key, _, _ in PRESENTED if key in rows and key not in UNGUARDED},
        "total": total(rows, guarded_only=True),
        "toolCount": len(measured["scenarios"]["thread"]["tools"]),
    }


def allowed(ceiling: int, percent: float, floor: int) -> int:
    return ceiling + max(floor, math.ceil(ceiling * percent / 100))


def check(measured: dict, ceilings: dict) -> list[str]:
    """What grew past its margin, as lines to print; empty when the tree is within the committed numbers."""
    problems: list[str] = []
    rows = measured["scenarios"]["thread"]["rows"]
    margin = ceilings.get("margin", {})
    pi_moved = ceilings.get("pi") != measured["pi"]
    for key, ceiling in ceilings["tokens"].items():
        now = rows.get(key, 0)
        percent = margin.get("percent", MARGIN_PERCENT)
        if pi_moved and key.startswith("pi."):
            percent = PI_MOVES_PERCENT
        if now > allowed(ceiling, percent, margin.get("floor", MARGIN_FLOOR)):
            problems.append(f"{LABELS.get(key, key)}: {now:,} tokens, ceiling {ceiling:,} (+{now - ceiling:,})")
    for key, now in rows.items():
        if key not in ceilings["tokens"] and key not in UNGUARDED and now > margin.get("floor", MARGIN_FLOOR):
            problems.append(f"{LABELS.get(key, key)}: {now:,} tokens in a section the ceilings file does not list")
    grand = total(rows, guarded_only=True)
    limit = allowed(ceilings["total"], margin.get("totalPercent", TOTAL_PERCENT), margin.get("totalFloor", TOTAL_FLOOR))
    if grand > limit:
        problems.append(f"Total before any work: {grand:,} tokens, ceiling {ceilings['total']:,} (allowed {limit:,})")
    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--pi", help="a pi package directory (default: PI_PACKAGE_DIR, then the staged engine)")
    parser.add_argument("--api", default="openai-responses", choices=["openai-responses", "openai-completions", "anthropic-messages"])
    parser.add_argument("--capture", help="read a capture the harness wrote instead of running it")
    parser.add_argument("--scenario", help="measure only these scenarios, comma separated (default: all)")
    parser.add_argument("--json", action="store_true", help="print the measurements as JSON")
    parser.add_argument("--tools", action="store_true", help="also print every tool's size")
    parser.add_argument("--check", action="store_true", help="compare with scripts/context-budget.json; exit 1 when a section grew")
    parser.add_argument("--update", action="store_true", help="write what was measured as the new ceilings")
    parser.add_argument("--ceilings", default=CEILINGS, help="the ceilings file (default: scripts/context-budget.json)")
    parser.add_argument("--simulate", action="store_true", help="run a long thread with and without context trimming and print the table")
    parser.add_argument("--turns", type=int, default=24, help="turns for --simulate")
    args = parser.parse_args(argv)

    if args.simulate:
        print(simulation_table(run_simulation(find_pi(args.pi), args.turns)))
        return 0

    if args.capture:
        with open(args.capture, encoding="utf-8") as f:
            capture = json.load(f)
    else:
        wanted = ["bare", "thread"] if args.check or args.update else (args.scenario.split(",") if args.scenario else None)
        if wanted and "bare" not in wanted:
            wanted = ["bare"] + wanted  # what pi owns is what pi alone sends
        capture = run_capture(find_pi(args.pi), args.api, wanted)
    measured = measure(capture)

    if args.update:
        with open(args.ceilings, "w", encoding="utf-8") as f:
            json.dump(ceilings_document(measured), f, indent=2)
            f.write("\n")
        print(f"wrote {os.path.relpath(args.ceilings, ROOT)}: total {total(measured['scenarios']['thread']['rows'], True):,} tokens")
        return 0
    if args.check:
        with open(args.ceilings, encoding="utf-8") as f:
            ceilings = json.load(f)
        problems = check(measured, ceilings)
        if ceilings.get("pi") != measured["pi"]:
            print(f"note: measured on pi {measured['pi']}; the ceilings came from pi {ceilings.get('pi')} (pi's own rows get {PI_MOVES_PERCENT}% room)")
        if problems:
            print("The prompt an agent starts with grew past what scripts/context-budget.json allows:\n")
            print("\n".join(f"  - {line}" for line in problems))
            print("\nIf the growth is deliberate, run `python3 scripts/context_budget.py --update`, commit the file, and say in the pull request "
                  "what the tokens buy. If it is not, defer or shorten the tool or text that grew (docs/context-budget.md).\n")
            print(table(measured))
            return 1
        print(f"context budget ok: {total(measured['scenarios']['thread']['rows'], True):,} tokens (ceiling {ceilings['total']:,})")
        return 0
    if args.json:
        print(json.dumps(measured, indent=1))
        return 0
    for scenario in measured["scenarios"]:
        print(table(measured, scenario))
        print()
    print(scenarios_table(measured))
    if args.tools:
        for scenario in measured["scenarios"]:
            print(f"\nTools in `{scenario}`\n")
            print(tools_table(measured, scenario))
    return 0


if __name__ == "__main__":
    sys.exit(main())
