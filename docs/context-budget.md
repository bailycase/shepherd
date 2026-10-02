# Context budget

> Read when you add or change a tool, a prompt line, an instruction file, or anything else that rides in every request, or when a thread compacts too often.

An agent's context window starts partly full, and then it fills with what the agent does. Before the
user says anything, every request carries pi's system prompt, the instruction files pi loaded, the
skills list, and the definition of every tool the agent has. Each tool call after that adds its
result, and the results stay until a compaction. This page says how that is measured, what the
numbers are, what keeps the start from growing, and what keeps a long run from filling the window.

The start is about 11.6k tokens, 4% of a 272k window (17.1k, 6%, before Deferred tools). It is not what
makes a thread compact. A long run is: one user message can start a hundred tool calls, and each call's
output, the files it wrote, the reasoning the provider asks to have sent back and the screenshots it took
ride in every later request. So there are three parts: a guard on the start (The guard), the tools a
thread rarely uses kept out of it until the model asks for them (Deferred tools), and clearing for the
run (Clearing).

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
python3 scripts/context_budget.py --simulate-defer --turns 40   # the same with every tool direct, deferred, and one load
```

- **Tokens are characters divided by four, rounded up**: pi's own estimate (`estimateTokens`) and
  the one the Context card uses. No tokenizer is vendored. Checked once against OpenAI's `o200k_base`
  on a capture, it counts 1 to 12 percent fewer tokens than that: the prompt 0.96, the tool
  definitions 0.88 (JSON tokenizes denser), an `AGENTS.md` 0.99, Swift source 0.89 (o200k's count
  over ours). So the tables err a little high, and show the shape of the cost, not the bill.
- **A scenario** is one launch: `thread` (an ordinary agent, the one the guard watches),
  `thread-defer-off` (the same with Settings ▸ Agents ▸ Context ▸ Defer rarely used tools off: every
  tool direct), `thread-without-mcp-or-skills`, `thread-with-design-reference` (design_get and design_note
  exist only once a thread holds a reference), `automation` (a run's agent has no `automation_*` tools; and
  `automation-defer-off`), `design` (a design's agent: the design tools instead of panes), `subagent` (a
  native helper's pi: pi's four tools and `shepherd_parent_message`, the project's context files, no
  Shepherd extension but the bridge) and `bare`, pi alone, which is how the table tells what pi owns from
  what Shepherd adds.
- **The numbers move with the machine by a few tokens**: pi's docs paths, the scratch project path and
  each skill's location are in the prompt. The guard's margins (below) are larger than that.

## What an agent starts with

pi 1.0.0 (the pin), `openai-responses`, the fixtures above (a thread's own skills, MCP servers and
instruction files are the user's, and are usually bigger). Before is `nightly` as this change found it
(every tool direct, measured with this harness on that tree); after defers the browser, other-thread,
automation and review tools (Deferred tools):

| Section | Before | After | Share of a 272k window |
| --- | ---: | ---: | ---: |
| pi: system prompt (preamble, tool list, rules, docs, cwd) | 768 | 768 | 0.3% |
| pi: built-in tool definitions (read, bash, edit, write) | 696 | 696 | 0.3% |
| Shepherd: tool snippets and rules added to the prompt | 949 | 351 | 0.1% |
| Shepherd tools: terminal_* (panes) | 590 | 590 | 0.2% |
| Shepherd tools: agent_* (panes) | 1,692 | 0 | 0.0% |
| Shepherd tools: automation_*, notify (panes) | 904 | 105 | 0.0% |
| Shepherd tools: review_diff | 245 | 0 | 0.0% |
| Shepherd tools: native subagents (shepherd_child_*, workflow) | 1,547 | 1,547 | 0.6% |
| Shepherd tools: browser_* | 2,178 | 0 | 0.0% |
| pi's MCP: tool_search and its server list (servers on Search) | 206 | 206 | 0.1% |
| pi's MCP: tools of servers set to Direct | 1,326 | 1,326 | 0.5% |
| Skills list | 441 | 441 | 0.2% |
| Instructions: APPEND_SYSTEM.md | 88 | 88 | 0.0% |
| Instructions: Settings ▸ Instructions' AGENTS.md | 891 | 891 | 0.3% |
| Instructions: the project's AGENTS.md | 4,556 | 4,556 | 1.7% |
| **Total before any work** | **17,077** | **11,565** | **4.3%** |

The `shepherd.prompt` row is the tool-list lines and rules the extensions add to pi's prompt. 598 of its
tokens net: the 414 tokens of tool-list lines of the agent, automation, review and browser tools and the
rules that came with them left, and the one rule line that says those tools exist (87) joined the rule about
a message from another agent (59), which stays in whether or not the agent tools are loaded.

For each kind of agent, the whole start (the project's AGENTS.md included) before and after:

| Agent | Before | After | Saved | What it keeps direct |
| --- | ---: | ---: | ---: | --- |
| Thread | 17,077 | 11,565 | 5,512 | terminals, notify, native subagents, MCP tools of servers on Direct, `tool_search` |
| Thread without MCP servers or skills | 15,084 | 9,750 | 5,334 | the same, with `tool_search` added (the Defer switch starts it without MCP) |
| Thread holding a design reference | 17,602 | 12,090 | 5,512 | the same and design_get, design_note |
| Automation (a watch agent) | 14,800 | 11,945 | 2,855 | terminals, `agent_send` (its report to its creator), notify, native subagents |
| Design agent | 16,752 | 16,752 | 0 | all of its own tools: nothing is deferred for it |
| Native subagent (a helper's pi) | 6,441 | 6,441 | 0 | pi's four tools and `shepherd_parent_message`; it loads no Shepherd extension but the bridge |

The guard's own total (the project's AGENTS.md left out) went from 12,521 to 7,009, and its ceilings with
it (The guard). The agent-to-agent message wording that landed before Phase A (each tool that reaches
another thread says first that it is only for what the user asked) put 681 tokens into `agent_*`, 143
into the snippets and 43 into the automation tools: those are the tools deferred here. The rule line in
`AGENTS.md` (next to Read more) costs 109 tokens in every thread.

A design's agent no longer gets `review_diff` either, and what sits beyond the table, in the user's own
instruction files, skills and MCP servers, is theirs: the Context card names each instruction file and
what the system prompt is made of, so a large one shows (The Context card).

## Every tool, audited

`Tests/Extensions/context-tools.json` lists every tool Shepherd registers: where it comes from, the
group the Context card gives it, and a verdict for each kind of agent. **keep** is sent in every
request of that kind of agent. **defer** is registered `deferred` and not sent: the model finds it with
pi 1.0's `tool_search` when it needs it (Deferred tools). **drop** is not registered there at all, with
why. `context-budget.test.mjs` launches each kind of agent on a real pi and fails when a tool it
registers has no row, when a kept tool is not sent, when a deferred one is sent or not registered, and
when a dropped tool is back.

Tokens are the tool definitions' own (the prompt lines and rules some add are in the snippets row above).
Of an ordinary thread's tool definitions, 4.4k are kept and 4.9k deferred.

| Tools | Tokens | Thread | Automation | Design | Why |
| --- | ---: | :-: | :-: | :-: | --- |
| `read` … `write` (4) | 698 | keep | keep | keep | pi's own: what an agent does with a repository. |
| `terminal_list` … `terminal_close` (6) | 592 | keep | keep | · | The thread's terminal tabs (⌘J) are how an agent runs a dev server or a watcher; six small tools. |
| `agent_list` … `agent_spawn` (7) | 1,363 | defer | · | · | Reaching other threads is something the user asks for, and each description says so first (agent-to-agent messages): 1.4k tokens in every thread for a rare use. |
| `agent_send` | 331 | defer | keep | · | The same, in a thread. An automation's run reports completion to the thread that made it with it, the only agent tool a run gets. |
| `automation_create` … `automation_stop` (6) | 800 | defer | · | · | Managing automations is rare. A run's own agent never gets them (an automation cannot start automations). |
| `notify` | 105 | keep | keep | · | One small tool an unattended run needs to say it finished; deferred it would save a thread 118 tokens and cost a search in every run. |
| `review_diff` | 245 | defer | defer | **drop** | Readies the side pane's Changes tab. A design's screen has no Changes tab and its folder is no repository, so a design's agent no longer gets it. |
| `shepherd_child_agents` … `shepherd_child_resume` (7) | 1,164 | keep | keep | keep | Delegating to a helper is how a thread keeps a big search out of its own context (For agents), so these stay direct (the user's call); a design's agent relays its tools through them. |
| `shepherd_workflow` | 385 | keep | keep | keep | A scripted run of helpers: the heaviest single description for the rarest use. Kept with the other native subagent tools; the first to defer if the budget needs it. |
| `shepherd_mission` | 0 | **drop** | **drop** | **drop** | Missions are deferred and no screen shows them. The 0 is its size now: it was about 470 tokens with its parameters on the two tools above. |
| `browser_open` … `browser_reload` (13) | 2,182 | defer | defer | · | The thread's own Browser page: 13 tools, 233 tokens of tool-list lines and 5 prompt rules in every thread, and most threads never open a page. |
| `tool_search` | 159 | keep | keep | keep | pi's own tool search: it loads the tools of the MCP servers left on Search (docs/mcp.md) and the deferred Shepherd tools above. With the server list it adds to the prompt, 206 tokens while a server is on Search. A server set to Direct declares its own `mcp__<server>__<tool>` tools instead (the user's, so not rows here); the Context card groups them as MCP. |
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

## Deferred tools

Settings ▸ Agents ▸ Context ▸ **Defer rarely used tools** (on by default; a client lists it among a host's
switches, id `deferTools`) keeps the tools marked **defer** above out of every request until the model loads
them: the browser's 13, the 8 that reach other threads, the 6 automation tools and `review_diff`, 4.9k
tokens of definitions and 0.4k of tool-list lines. While it is on, the app starts a thread's or an
automation's pi (never a design's agent's) with `SHEPHERD_DEFER_TOOLS=1` and pi's `-e builtin:tool-search`,
even with MCP off; the extensions then register those tools `deferred`. Off, every tool registers direct as
before. A running agent follows at its next launch.

**What pi 1.0 does** (its source and `docs/extensions.md` › Tool exposure, checked on a real pi by
`Tests/Extensions/defer-tools.test.mjs`):

- **A `deferred` tool is registered but not active, so no request declares it.** What the model sees of it
  before a search is nothing: no name, no line. `tool_search`'s own text is generic and pi's `mcp_servers`
  section names MCP servers only, so Shepherd adds one rule line (87 tokens, from the tools' namespaces):
  "Shepherd tools you load with tool_search when you need them: agent_\* (other agent threads, only when the
  user explicitly asks you to); automation_\* (…); review_diff (…); browser_\* (…)". It names only what the
  launch registered.
- **`tool_search` is registered inactive** (pi's MCP activates it only for a server on Search), so the status
  extension activates it at session start; in a launch without it the deferred tools are declared like any
  other. It ranks the tools that are not active with BM25 over the name, the description, the schema's
  property names and descriptions and the tool's namespace text, then **loads every match with a positive
  score, at most `limit` (8 unless the model says another number)**. The answer is `Loaded N tools.` and one
  line per tool: its name and the first line of its description, which for Shepherd's tools is the whole of it.
- **A call needs the tool loaded.** A call to a deferred tool nobody loaded answers `Tool browser_open not
  found`, and nothing reaches Shepherd.
- **A load is recorded in the transcript**, and clearing the search result out of a request does not unload
  it, nor does a compaction (`defer-tools.test.mjs`, as `context-mcp.test.mjs` for an MCP tool). pi 1.0 does not bring a load back
  when it starts again on a session in the RPC mode Shepherd runs (checked on an MCP tool too: the resumed
  request declares only the launch's set), so the status extension reads it off the transcript, the tools
  later system messages added, and re-activates the Shepherd ones; a thread that began with every tool
  direct has none and resumes deferred.
- **A tool's tool-list line and rules join the prompt while it is active.** A deferred tool therefore has no
  line (it would repeat the search result and send the whole tool list again when it loads), and carries only
  the rules no description says.

**What Shepherd adds.** A search whose best match is one of these tools loads its whole family (the browser's
thirteen are used together, `tool_search` loads eight, and each load is a change the provider's cache
notices); the loaded list is in rank order, so only the first match counts, and a search for an MCP tool that
also loads weaker matches (11 of 17 GitHub-shaped queries such as "create an issue" also load Shepherd
tools that share a word, 34 in all, a few hundred tokens a query) does not bring their families. The answer lists the
extras and keeps its count true, which the thread's "13 loaded" reads. The rule about a message that begins
`[from: <name>]` (another agent's, answered with `agent_send` only when it asks for a reply) is in every
thread's prompt, loaded or not, since a thread receives such a message without loading anything; the rest
of the agent-to-agent wording is untouched and travels with the tools (each leads with "Only when the user
explicitly asks you to", and the search result shows the same words). The browser's rules that only
repeated a tool description (the page is the thread's and shared, prefer `browser_read` to a screenshot,
refs go stale, `browser_eval` is a last resort) are gone: 128 tokens less once it loads; the untrusted-page
and takeover rules stay as written, and so does the notice every browser result starts with.

**Finding them.** "open a web page", "message another agent", "create an automation" and "show me the diff"
each find their family first on a real pi, and `defer-tools.test.mjs` calls what they loaded; pi's ranking
over the registered tools puts the right family first for 26 of 27 phrasings (the miss: "check the app in the
browser"). The namespace's words are written for it, and its `instructions` are words only the search reads.

**The cache.** A prompt cache holds a prefix: tools, system prompt, messages. pi puts a load in one of two
ways: appended where it was loaded, with the earlier request untouched (a model with
`compat.supportsAdditionalTools`: 11 of 44 OpenAI models, the Codex ones, 6 of 16 Anthropic's), or, for every
other model and any custom provider, as a new tool list from the head. And when an extension has changed the
conversation, which Clearing does as soon as one result is clipped, pi replaces the system messages with one
leading message and **every load rewrites the head**. So a load is one cache miss, like a clearing batch, and
a family loaded at once is one. The 40-turn thread below, with the browser loaded by one search in turn 6:

| 40 turns | Every tool direct | Deferred, none loaded | Deferred, the browser loaded in turn 6 |
| --- | ---: | ---: | ---: |
| Requests | 162 | 160 | 162 |
| Input tokens sent, all requests | 16,158,308 | 15,844,835 | 15,958,724 |
| Same, a cached token counted at a tenth | 2,162,864 | 2,146,906 | 2,201,350 |
| Share of a request the next one repeats: mean | 98% | 98% | 97% |
| Lowest, and requests below 100% | 12%, 4 | 8%, 4 | 7%, 5 |
| Tokens in the first request, and in the last | 26,588, 133,232 | 21,191, 121,730 | 21,191, 133,354 |

(`python3 scripts/context_budget.py --simulate-defer --turns 40`. The direct column makes the same search and
call, which find nothing to load, so that its request count matches.)

Never loading makes the cache no worse (the four breaks are clearing's). One load adds a break: the first
request after it pays for the whole conversation, so the thread that loaded the browser at turn 6 ends about
2% dearer in cost-weighted tokens than one that had every tool all along, while it carried 3k fewer tokens
in every request. A load early in a thread costs almost nothing; a late one, deep in a long conversation,
costs most. Deferral buys window, not cost.

**What could go wrong.**

- **A model that never searches never uses a deferred tool.** Only the rule line says they exist, so a thread
  whose model does not act on it has no browser, other-thread or automation tools and reads as a thread
  that has none. Whether a real model follows the line is untested here (only fake providers ran); Defer
  rarely used tools off puts every tool back.
- **A weak match or a missed first search** costs tokens or a round trip: pi's ranking is lexical.
- **A load costs more than direct while it lasts**: the definitions, plus the search result (full
  descriptions, about 1.3k tokens for the browser), plus, on a model that anchors, the rules section again.
  Clearing removes the result once it is old.
- **The Context card** reads the tools from pi's system messages, so a deferred tool shows once it is
  loaded. The thread draws the search as the quiet "Searched tools “open a web page”" line (its expanded row
  says "13 loaded"), then the browser's own lines, on the Mac and in the iOS client alike.
- **Remote clients** change nothing: the host's agent searches and loads.

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
  always sent, and a tool the model rarely needs to one registered `deferred` (Deferred tools) to one
  that is always declared.

## The guard

`scripts/context-budget.json` holds the numbers someone last decided were right: a ceiling per row
and one for the total. `Tests/Extensions/context-budget.test.mjs` runs `--check` on a real pi in the
extension job, which every pull request runs (`.github/workflows/ci.yml`, `extensions`): a row may
grow by 5% or 60 tokens, the total by 2% or 150 tokens, and past that the check names the row that
grew and fails until the file is updated. That is the moment to say in the pull request what the
tokens buy, or to defer or shorten the tool or text instead. A new pi gets 25% room on pi's own
rows and none on Shepherd's. The project's own `AGENTS.md` is not guarded: it has a line cap
(`Tests/Release/test_agent_docs.py`). The ceilings are the deferred set's (7,012 for the thread, from
12,524): the deferred families have no row, and a section the file does not list may hold 60 tokens at most, so
a deferred tool that is sent again fails the check; `context-budget.test.mjs` fails it too, from the
registry (a deferred tool must be registered and not sent, and a kept one sent).

`Tests/Release/test_context_budget.py` tests the counting on synthetic captures, with no pi and no
Node.

## Not measured

The simulations are synthetic: a fake provider, awk output and files of a known size. They show the
shape and the mechanism, and the tests prove the request shrinks, the pairing holds and the session
keeps everything. They are not a measurement of a real provider's caching or of a real model's
reasoning items, which a real long session would be (see the pull request). Deferral has the same limit,
and one more: no real model has been run, so whether a model searches for a deferred tool when it needs
one, and how often a search loads one it should not, are known only from pi's ranking over stand-in tools.
