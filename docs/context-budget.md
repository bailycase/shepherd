# Context budget

> Read when you add or change a tool, a prompt line, an instruction file, or anything else that rides in every request, or when a thread compacts too often.

An agent's context window starts partly full, and then it fills with what the agent does. Before the
user says anything, every request carries pi's system prompt, the instruction files pi loaded, the
skills list, and the definition of every tool the agent has. Each tool call after that adds its
result, and the results stay until a compaction. This page says how that is measured, what the
numbers are, what keeps the start from growing, and what keeps a long run from filling the window.

The start is about 17k tokens, 6% of a 272k window. It is not what makes a thread compact. A long run
is: one user message can start a hundred tool calls, and each call's output, the files it wrote, the
reasoning the provider asks to have sent back and the screenshots it took ride in every later
request. So there are two halves, a guard on the start (below) and clearing for the run (Clearing).

## Measuring it

`python3 scripts/context_budget.py` launches a real pi the way Shepherd launches an agent's
(`Tests/Extensions/context-harness.mjs`): the extensions in `PiLaunch`'s order with the environment
the app gives them, Settings ▸ Instructions' `AGENTS.md` and `APPEND_SYSTEM.md`, this repository's
`AGENTS.md` as the project file, six skills, three MCP servers on pi's own MCP (two on Search, one on Direct; stand-ins from
`Tests/Extensions/fixtures/fake-mcp-stdio.mjs`, connected before the measurement),
all against a fake provider that records the request body. It counts what the first model request
carried, section by section, and prints the table.

```bash
export PI_PACKAGE_DIR="$(npm root -g)/@earendil-works/pi-coding-agent"   # or the staged engine's package
python3 scripts/context_budget.py                       # every scenario
python3 scripts/context_budget.py --scenario thread --tools   # one scenario, every tool's size
python3 scripts/context_budget.py --check               # what CI runs: fail when a section grew
python3 scripts/context_budget.py --update              # after a growth someone decided is right
python3 scripts/context_budget.py --simulate --turns 40 # a long thread, with and without clearing
```

- **Tokens are characters divided by four, rounded up**: pi's own estimate (`estimateTokens`) and
  the one the Context card uses. No tokenizer is vendored. Checked once against OpenAI's `o200k_base`
  on a capture, it counts 1 to 12 percent fewer tokens than that: the prompt 0.96, the tool
  definitions 0.88 (JSON tokenizes denser), an `AGENTS.md` 0.99, Swift source 0.89 (o200k's count
  over ours). So the tables err a little high, and show the shape of the cost, not the bill.
- **A scenario** is one launch: `thread` (an ordinary agent, the one the guard watches),
  `thread-without-mcp-or-skills`, `thread-with-design-reference` (design_get and design_note exist
  only once a thread holds a reference), `automation` (a run's agent has no `automation_*` tools),
  `design` (a design's agent: the design tools instead of panes) and `bare`, pi alone, which is how
  the table tells what pi owns from what Shepherd adds.
- **The numbers move with the machine by a few tokens**: pi's docs paths, the scratch project path and
  each skill's location are in the prompt. The guard's margins (below) are larger than that.

## What an agent starts with

pi 1.0.0 (the pin), an ordinary thread, `openai-responses`, the fixtures above (a thread's own skills,
MCP servers and instruction files are the user's, and are usually bigger). Before is `nightly` as this
change found it; after has no mission tool or parameters (Missions) and the rule line in `AGENTS.md`:

| Section | Before | After | Share of a 272k window |
| --- | ---: | ---: | ---: |
| pi: system prompt (preamble, tool list, rules, docs, cwd) | 766 | 771 | 0.3% |
| pi: built-in tool definitions (read, bash, edit, write) | 696 | 696 | 0.3% |
| Shepherd: tool snippets and rules added to the prompt | 946 | 949 | 0.3% |
| Shepherd tools: terminal_* (panes) | 590 | 590 | 0.2% |
| Shepherd tools: agent_* (panes) | 1,692 | 1,692 | 0.6% |
| Shepherd tools: automation_*, notify (panes) | 904 | 904 | 0.3% |
| Shepherd tools: review_diff | 245 | 245 | 0.1% |
| Shepherd tools: native subagents (shepherd_child_*, workflow) | 2,015 | 1,547 | 0.6% |
| Shepherd tools: browser_* | 2,178 | 2,178 | 0.8% |
| pi's MCP: tool_search and its server list (servers on Search) | 183 | 206 | 0.1% |
| pi's MCP: tools of servers set to Direct | 1,311 | 1,326 | 0.5% |
| Skills list | 441 | 441 | 0.2% |
| Instructions: APPEND_SYSTEM.md | 88 | 88 | 0.0% |
| Instructions: Settings ▸ Instructions' AGENTS.md | 891 | 891 | 0.3% |
| Instructions: the project's AGENTS.md | 4,439 | 4,556 | 1.7% |
| **Total before any work** | **17,384** | **17,080** | **6.3%** |

Two things the table shows besides this change. The agent-to-agent message wording that landed
before it (each tool that reaches another thread now says first that it is only for what the user
asked) put 681 tokens into `agent_*`, 143 into the snippets and 43 into the automation tools, which
this guard first caught as a rise of 867 on the last merge: the ceilings in `context-budget.json` were
raised for it, and those tools are the Phase B candidates below. And the rule line in `AGENTS.md`
(next to Read more) costs 109 tokens in every thread.

A design's agent no longer gets `review_diff` either (a further 245 tokens there), and the table
for every scenario is in the pull request that landed this. What sits beyond the table, in the
user's own instruction files, skills and MCP servers, is theirs: the Context card names each
instruction file and what the system prompt is made of, so a large one shows (The Context card).

## Every tool, audited

`Tests/Extensions/context-tools.json` lists every tool Shepherd registers: where it comes from, the
group the Context card gives it, and a verdict for each kind of agent. **keep** is sent in every
request of that kind of agent. **defer** is still sent today, and is what moves behind pi 1.0's
`tool_search` in Phase B, found by the model when it needs it. **drop** is not registered there at
all, with why. `context-budget.test.mjs` launches each kind of agent on a real pi and fails when a
tool it registers has no row, when a row names a tool nothing registers, and when a dropped tool is
back; a Phase B registry can be this file, read instead of written.

Tokens are the tool definitions' own (the prompt rules some add are in the snippets row above).
Of an ordinary thread's tool definitions, 2.1k are kept and 6.5k deferrable.

| Tools | Tokens | Thread | Automation | Design | Why |
| --- | ---: | :-: | :-: | :-: | --- |
| `read` … `write` (4) | 698 | keep | keep | keep | pi's own: what an agent does with a repository. |
| `terminal_list` … `terminal_close` (6) | 592 | keep | keep | · | The thread's terminal tabs (⌘J) are how an agent runs a dev server or a watcher; six small tools. |
| `agent_list` … `agent_spawn` (7) | 1,363 | defer | · | · | Reaching other threads is something the user asks for, and each description now says so first (agent-to-agent messages): 1.4k tokens in every thread for a rare use. |
| `agent_send` | 331 | defer | keep | · | The same, in a thread. An automation's run reports completion to the thread that made it with it, the only agent tool a run gets. |
| `automation_create` … `automation_stop` (6) | 800 | defer | · | · | Managing automations is rare. A run's own agent never gets them (an automation cannot start automations). |
| `notify` | 105 | keep | keep | · | One small tool an unattended run needs to say it finished. |
| `review_diff` | 245 | defer | defer | **drop** | Readies the side pane's Changes tab. A design's screen has no Changes tab and its folder is no repository, so a design's agent no longer gets it. |
| `shepherd_child_agents` … `shepherd_child_resume` (7) | 1,164 | defer | defer | defer | Delegating to a helper is a choice the model makes now and then (a design's agent relays its tools through them). |
| `shepherd_workflow` | 385 | defer | defer | defer | A scripted run of helpers: one of the heaviest single descriptions for the rarest use. |
| `shepherd_mission` | 0 | **drop** | **drop** | **drop** | Missions are deferred and no screen shows them. The 0 is its size now: it was about 470 tokens with its parameters on the two tools above. |
| `browser_open` … `browser_reload` (13) | 2,182 | defer | defer | · | The thread's own Browser page: 13 tools and 5 prompt rules in every thread, and most threads never open a page. The first Phase B candidate. |
| `tool_search` | 159 | keep | keep | keep | pi's own tool search, which loads the tools of the MCP servers left on Search (docs/mcp.md); with the server list it adds to the prompt, 206 tokens, and only while a server is on Search. A server set to Direct declares its own `mcp__<server>__<tool>` tools instead (the user's, so not rows here); the Context card groups them as MCP. |
| `design_get`, `design_note` | 476 | keep | · | · | Registered only once the thread holds a design reference. |
| `suggest_instruction` | 0 | keep | keep | · | Registered only while Settings ▸ Experiments ▸ Suggested instructions is on for the kind of agent. |
| `design_read` … `markup_propose` (17) | 4,872 | · | · | keep | What a design's agent draws and edits with; no other agent gets them. |

A native subagent's own pi loads only `shepherd_parent_message`, its way to ask its parent, which
the registry lists as the `child` kind.

### Missions

`shepherd_mission`, and the `mission` and `missionId` parameters of `shepherd_child_start` and
`shepherd_workflow`, are not registered unless the environment sets `SHEPHERD_MISSIONS=1`, which the
app never does. Missions are planned (docs/design/missions.md), nothing draws a record, and the model
spent about 470 tokens a request on a tool and two parameters it could not use for anything a user
sees. The tool descriptions drop their mission sentences, and a run writes no mission record. The
code stays, with its tests, which set the variable.

## Clearing

Settings ▸ Agents ▸ Context ▸ **Trim old tool output from the model's context** (on by default,
changeable from a client) loads the bundled `shepherd-context.ts` in the agent's pi. It changes only
the request pi sends: pi calls the `context` event before each model request with a copy of the
conversation. The session file, `get_messages`, the thread, the Changes pane and the search keep
every result in full, and a switch off is byte-identical to no extension (a test).

**What counts as recent.** A user message can start a hundred tool calls, so "recent" is the last few
model calls, not the last user turn. A call is an assistant message with its tool results.

**MCP.** A result of pi's own MCP is a tool result like any other (`mcp__<server>__<tool>`, by its name in
the stub), clipped and cleared the same. So is `tool_search`'s: it lists what it loaded, and a batch
may remove that list from the request. The tools stay: pi loads a deferred tool through its active tool
set (`setActiveTools`, a record of its own in the transcript that survives `/tree`, resume and a
fork), not through the text of the result, so a tool a cleared search loaded is still declared and
callable. `context-mcp.test.mjs` runs it on a real pi (the search cleared, the tool declared in every
later request, and a call to it after the clearing answered).

**What it does:**

1. A single tool result over about 6k tokens is clipped to its head and tail around a line saying how
   much was left out. It is a pure function of that result, so it never changes between requests.
2. When a request passes **55%** of the window, one batch clears the oldest clearable content until
   the estimate is under **33%**, and never anything in the last **8** calls. At most one batch in
   **20** calls, and only when it frees something worth the cache it breaks. These five numbers
   (`SHEPHERD_CONTEXT_CLIP_TOKENS`, `_TRIGGER_PERCENT`, `_TARGET_PERCENT`, `_KEEP_CALLS`,
   `_GAP_CALLS`) are not settings; tests move them.
3. The batch is remembered. Its boundary, a message timestamp, is appended to pi's session as a
   `shepherd.context` custom entry, which pi keeps out of the model's context. Every later request
   clears what the latest boundary on its branch says, so a request is a pure function of the
   session: the same bytes after a restart, `/new` or a resume, and a branch decides from the entry
   on its own path. The entry is written before the batch is applied and read back first, so an
   entry that did not land is not applied.

**What a batch clears,** each into one line that says what it was and about how big:

| Cleared | Left |
| --- | --- |
| A tool result's text and images | The call, its name and path, and that it ran |
| The large strings in an old tool call's arguments (a file a `write` or an `edit` carried) | The call, its name, its path |
| A hidden custom message (a notice the model was sent) | Messages shown in the thread |
| Reasoning payloads, on the OpenAI Responses APIs only | Thinking text, and the call it belonged to |

**Never cleared:** user messages, assistant text, the compaction summary, the newest calls, and the
call's own name and path. A reasoning item the provider re-sends with every call is dropped, and the
item id that paired the call with it (`fc_…`, which pi's Responses converter writes from the call's
id) is stripped from the call and its result together, so a call replayed without its reasoning is a
plain call. A real pi, against a fake provider, sends only the newest call's reasoning, and the
calls that lost theirs carry no item id and pair with their results (`context-trim.test.mjs`). Whether
OpenAI accepts that request has not been run against OpenAI. Other providers' thinking blocks are
left alone.

**Caching.** A provider's prompt cache holds a prefix of the request, so editing an old message
breaks it from that point. Clearing in batches breaks it once per batch (about once in 25 to 35
calls) instead of on every call, and the request in between is a strict extension of the one before.
A 40-turn simulation (below) kept 98% of each request's prefix on average, with four breaks in 160
requests.

**Compaction and everything else.** pi's own compaction still happens when the window is nearly
full, and its summary is built from the full history, not from the trimmed request. A thread whose
context is under 55% is never touched. Every agent the app launches loads it by the same switch, automation
runs and design agents included. The switch is a bundled extension on a client's host settings
(Settings ▸ Agents ▸ Context ▸ Trim old tool output), and a client can change it.

### A long thread, simulated

`--simulate` runs a real pi, a fake provider and 40 turns. Each turn reads about 11.6k tokens of
search output, 3k of a file and runs a small command, then answers. Tokens are those of the turn's
last request (what the ring would show). pi's auto-compaction is off in the harness so that the
growth shows; pi would compact past 255k of the 272k window.

| Turn | Without clearing | With clearing |
| ---: | ---: | ---: |
| 1 | 33,364 | 26,653 |
| 3 | 65,778 | 45,645 |
| 6 | 114,403 | 74,137 |
| 9 | 163,029 | 102,630 |
| 12 | 212,421 | 131,330 |
| 15 | 261,814 (compacts) | 90,158 |
| 18 | 311,206 (compacts) | 118,858 |
| 24 | 409,992 (compacts) | 112,015 |
| 30 | 508,790 (compacts) | 101,865 |
| 40 | 673,457 (compacts) | 133,191 |

| | Without clearing | With clearing |
| --- | ---: | ---: |
| Requests | 160 | 160 |
| Input tokens sent, all requests | 55,610,465 | 16,024,855 |
| Same, a cached token counted at a tenth | 6,167,039 | 2,149,387 |
| Share of a request the next one repeats: mean | 100% | 98% |
| Lowest, and requests below 100% | 100%, 0 | 12%, 4 |
| First turn past the auto-compact mark | 15 | none |

The "without" column never compacts, so its tail is the counterfactual; the fair reading is that a
thread like this compacts about every 15 turns without clearing and never with it. The same holds in
`context-trim.test.mjs`: a run of 150 calls from one user message, on a real pi with its
auto-compaction on, compacts at least three times without clearing and never with it, and a
stand-in conversation of 400 calls batches about every 25 calls and never reaches the mark.

## The Context card

The Context card said "Instructions · AGENTS.md 19.2k" for an instruction file of a few thousand
tokens. The cause was the card, not the file. The host estimated each part from the messages, then
scaled every part up so that they added to the provider's total, so what the estimate could not size
(reasoning payloads the provider re-sends, screenshots, cache bookkeeping, the provider's own
tokenization) was spread across the system prompt and the instructions, the two parts that are never
in the messages.

It now sizes each part itself (four characters a token, a screenshot at 2,100 tokens, reasoning at
the provider's own count) and anchors the fixed part to the provider's usage for the first call after
a start or a compaction. What is left of the total is **Other**, and nothing is ever called "System
prompt and tools" that is not. The card lists what the system prompt is made of (the prompt's
sections, the skills list, the tools by group) and each instruction file by where it is, with rows of
their own for the agent's written files, reasoning and images once they are 500 tokens or more.
docs/design/composer.md › Context meter has the card, docs/native-thread.md › Context and compaction
the estimate and the wire (additive: an older client reads the four parts it always did).

## Compact at

Settings ▸ Agents ▸ Context ▸ **Compact at** (pi's default · 60 · 70 · 80 · 90%) writes pi's
per-model `compaction.modelOverrides[provider/id].reserveTokens` in Shepherd's pi home, under pi's
lock, never `compaction.enabled`: the share of the window where pi compacts on its own. The reserve
is the rest of the window and never below pi's 16,384, so a share never makes pi compact later
than its default. It reaches a new agent at once and a running one at its next launch, and the
Context card's mark follows. docs/native-thread.md › Compact at.

## For agents

A thread's context is shared with everything it reads. `AGENTS.md` carries one rule line, and this is
what stands behind it:

- Ask for what you need: `| head`, `-n`, `--stat`, `--name-only`, a file by range, `wc -l` before `cat`,
  a command that prints a summary. A tool result over about 6k tokens is clipped on its way to the
  model anyway; the part you needed may be in the middle.
- A broad search, a long log or an exploration of unknown code belongs to a helper
  (`shepherd_child_start`): its work stays in its own context and only its answer comes back.
- Write a file once. The contents of a `write` or an `edit` ride in every later request until
  clearing drops them; a script that rewrites a file in place, or a patch, costs less than the file.
- A new tool, prompt line or instruction is paid for in every thread: check the table above, and
  prefer text that is read when needed (a skill, a doc this page's neighbours link) to text that is
  always sent.

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

## Not measured

The simulations are synthetic: a fake provider, awk output and files of a known size. They show the
shape and the mechanism, and the tests prove the request shrinks, the pairing holds and the session
keeps everything. They are not a measurement of a real provider's caching or of a real model's
reasoning items, which a real long session would be (see the pull request).
