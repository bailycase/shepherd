# Context budget

> Read when you add or change a tool, a prompt line or an instruction file, or when a thread compacts too often.

Every request an agent sends carries pi's system prompt, the instruction files, the skills list and
the definition of every tool the agent has, before the user says anything. That start is about 8k
tokens for an ordinary thread. What fills a window is the run: each tool result, each file written
and each screenshot rides in every later request until a compaction.

## The guard

`scripts/context-budget.json` holds the token count of each section of a thread's first request,
measured when someone last decided the numbers were right. `Tests/Extensions/context-budget.test.mjs`
runs `python3 scripts/context_budget.py --check` against a real pi in the extension CI job: a row
may grow by 5% or 60 tokens and the total by 2% or 150 tokens; past that the check names the row and
fails until `--update` rewrites the file. That is the moment to say in the pull request what the
tokens buy, or to shorten or defer the tool instead. The project's own `AGENTS.md` is not in the
guard; it has a line cap in `Tests/Release/test_agent_docs.py`.

```bash
export PI_PACKAGE_DIR="$(npm root -g)/@earendil-works/pi-coding-agent"   # or the staged engine's package
python3 scripts/context_budget.py                              # every scenario, section by section
python3 scripts/context_budget.py --scenario thread --tools    # one scenario, every tool's size
python3 scripts/context_budget.py --check                      # what CI runs
python3 scripts/context_budget.py --update                     # after a growth someone decided is right
```

Tokens are characters divided by four, rounded up (pi's own estimate and the Context card's).
The scenarios are `thread`, `thread-defer-off`, `thread-without-mcp-or-skills`,
`thread-with-design-reference`, `automation`, `design`, `subagent` and `bare` (pi alone, which
tells what pi owns from what Shepherd adds).

## Deferred tools

A tool the model rarely needs is registered `deferred`: pi's `tool_search` finds it by name or
description and loads it for the rest of the thread, so its definition is not sent until then.
Settings ▸ Agents ▸ Context ▸ Defer rarely used tools turns this off (every tool direct). The
registry and each tool's verdict are in `Tests/Extensions/context-tools.json`; the test fails a
deferred tool that is sent anyway, and a kept one that is not.

## Clearing

Old tool results are cleared from later requests once they are far enough behind the newest turn
and the window is past a share; the session file keeps everything. Compaction summary requests
use the same clipping and recorded clearing boundary, so they do not resend cleared tool contents. The Context card on a thread shows the split (system prompt and tools, instructions,
messages, tool results) and where Compact at sits. Settings ▸ Agents ▸ Context ▸ Compact at
writes pi's per-model `compaction.modelOverrides[…].reserveTokens`, never below pi's 16,384.

## For agents

- Ask for what you need: `| head`, `--stat`, a file by range, a command that prints a summary. A
  tool result over about 6k tokens is clipped on its way to the model anyway.
- A broad search, a long log or an exploration of unknown code belongs to a helper
  (`shepherd_child_start`): only its answer comes back.
- Write a file once; the contents of a `write` or `edit` ride in every later request until cleared.
- A new tool, prompt line or instruction is paid for in every thread. Prefer text that is read when
  needed (a skill, a doc) to text that is always sent, and a `deferred` tool to one always declared.
