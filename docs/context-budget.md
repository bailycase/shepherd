# Context budget

> Read when you add or change a tool, a prompt line, an instruction file, or anything else that rides in every request, or when a thread compacts too often.

An agent's context window starts partly full. Before the user says anything, every request carries
pi's system prompt, the instruction files pi loaded, the skills list, and the definition of every
tool the agent has. Each tool call after that adds its result, and the results stay until a
compaction. This page says how that is measured, what the numbers are, and what keeps them from
growing.

## Measuring it

`python3 scripts/context_budget.py` launches a real pi the way Shepherd launches an agent's
(`Tests/Extensions/context-harness.mjs`): the extensions in `PiLaunch`'s order with the environment
the app gives them, Settings ▸ Instructions' `AGENTS.md` and `APPEND_SYSTEM.md`, this repository's
`AGENTS.md` as the project file, six skills, three MCP servers (one set to Each tool on its own),
all against a fake provider that records the request body. It counts what the first model request
carried, section by section, and prints the table.

```bash
export PI_PACKAGE_DIR="$(npm root -g)/@earendil-works/pi-coding-agent"   # or the staged engine's package
python3 scripts/context_budget.py                       # every scenario
python3 scripts/context_budget.py --scenario thread --tools   # one scenario, every tool's size
python3 scripts/context_budget.py --check               # what CI runs: fail when a section grew
python3 scripts/context_budget.py --update              # after a growth someone decided is right
```

- **Tokens are characters divided by four, rounded up**: pi's own estimate (`estimateTokens`) and
  the one the Context card uses. No tokenizer is vendored. Checked once against OpenAI's `o200k_base`
  on a capture, it counts 1 to 12 percent fewer tokens than that: the prompt 0.96, the tool
  definitions 0.88 (JSON tokenizes denser), an `AGENTS.md` 0.99, Swift source 0.89. So the tables err
  a little high, and show the shape of the cost, not the bill.
- **A scenario** is one launch: `thread` (an ordinary agent, the one the guard watches),
  `thread-without-mcp-or-skills`, `thread-with-design-reference` (design_get and design_note exist
  only once a thread holds a reference), `automation` (a run's agent has no `automation_*` tools),
  `design` (a design's agent: the design tools instead of panes) and `bare`, pi alone, which is how
  the table tells what pi owns from what Shepherd adds.
- **The numbers move with the machine by a few tokens**: pi's docs paths, the scratch project path and
  each skill's location are in the prompt. The guard's margins (below) are larger than that.

## What an agent starts with

pi 0.87.1, an ordinary thread, `openai-responses`, the fixtures above (a thread's own skills, MCP
servers and instruction files are the user's, and are usually bigger):

| Section | Tokens | Share of a 272k window |
| --- | ---: | ---: |
| pi: system prompt (preamble, tool list, rules, docs, cwd) | 675 | 0.2% |
| pi: built-in tool definitions (read, bash, edit, write) | 696 | 0.3% |
| Shepherd: tool snippets and rules added to the prompt | 803 | 0.3% |
| Shepherd tools: terminal_* (panes) | 590 | 0.2% |
| Shepherd tools: agent_* (panes) | 1,011 | 0.4% |
| Shepherd tools: automation_*, notify (panes) | 861 | 0.3% |
| Shepherd tools: review_diff | 245 | 0.1% |
| Shepherd tools: native subagents (shepherd_child_*, workflow) | 2,015 | 0.7% |
| Shepherd tools: browser_* | 2,178 | 0.8% |
| Shepherd tools: mcp (one proxy tool) | 183 | 0.1% |
| Shepherd tools: MCP servers set to Each tool on its own | 1,311 | 0.5% |
| Skills list | 441 | 0.2% |
| Instructions: APPEND_SYSTEM.md | 88 | 0.0% |
| Instructions: Settings ▸ Instructions' AGENTS.md | 891 | 0.3% |
| Instructions: the project's AGENTS.md | 4,372 | 1.6% |
| **Total before any work** | **16,360** | **6.0%** |

## The guard

`scripts/context-budget.json` holds the numbers someone last decided were right: a ceiling per row
and one for the total. `Tests/Extensions/context-budget.test.mjs` runs `--check` on a real pi in the
extension job, which every pull request runs (`.github/workflows/ci.yml`, `extensions`): a row may
grow by 5% or 60 tokens, the total by 2% or 150 tokens, and past that the check names the row that
grew and fails until the file is updated. That is the moment to say in the pull request what the
tokens buy, or to defer or shorten the tool or text instead. A new pi gets 25% room on pi's own
rows and none on Shepherd's. The project's own `AGENTS.md` is not guarded: it has a line cap
(`Tests/Release/test_agent_docs.py`).

`Tests/Release/test_context_budget.py` tests the counting on synthetic captures, with no pi and no
Node.
