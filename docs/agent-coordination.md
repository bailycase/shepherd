# Agent coordination

The bundled panes extension (`Extensions/shepherd-panes.ts`, on under Settings ▸ Pi ▸ Bundled
extensions as "Terminals and agent tools") gives every Shepherd agent the `terminal_*` tools for
its own terminals ([below](#terminals)) and tools for the other top-level agents in the app, and
the review extension (`Extensions/shepherd-review.ts`) gives it `review_diff`. Subagents are a
separate runtime ([native-subagents.md](native-subagents.md)); these tools address agents in the
sidebar. A design's agent is none of them: it gets no panes extension, and the server refuses
every request from or to it with `not_a_thread` ([designs.md](designs.md) › Design agents and
ordinary threads).

Code: `Extensions/shepherd-panes.ts` (the tools and the recipient side), `SessionServer`
(relaying, tokens, timeouts, and the approval gate), `AgentApprovals.swift` (what the setting
decides, "Allow for this thread"), `AgentPeers.swift` (list, send, spawn, the approval queue and
the deletion dialog's decisions), `PeerApprovalDialog` and `PeerApproval.swift` (the approval
dialog and its words), `PeerDeleteDialog` in `AppDialogs.swift`, and `ShepherdViewModel+Review.swift`.

## Project registration and refresh

The same bundled extension exposes two local project tools, deferred through `tool_search`
by default. Use them when the user requests registration or refresh. They are not installed
in automation or design agents and do not use the peer-thread approval setting.

| Tool | Arguments | Successful text result, JSON |
| --- | --- | --- |
| `project_register` | `path: string`, `name: string` | `{ "space": { "id": "…", "name": "…", "path": "…", … }, "created": true }` |
| `project_refresh` | `{}` | `{ "refreshed": true }` |

`project_register` accepts an existing readable directory on the local Mac. `path` must be
absolute or start with `~/`. The host resolves symlinks and dot segments. `name` is trimmed,
must contain 1–256 characters, and cannot contain control characters. No Git repository is
required. Registration uses the same state mutation and notifications as Add Project, inserts
a new space at the top, and persists it in `state.json`. A matching canonical path returns the
existing space with `created: false`, preserving its name, position, ID, and hidden flags.
Settings' Add Project uses the same validated registration path.

`project_refresh` adopts the live server state into the sidebar and forces the existing
Projects settings list to reload. Neither tool selects a project, starts a thread, creates
folders, grants project trust, or replaces an unsaved editor draft. A successful reply follows
live UI adoption and list reload. `projects.json` is cached directory history, not sidebar
registration. Refresh neither imports it into spaces nor rereads `state.json` over live state.

The extension socket verifies the caller's agent identity. Invalid input, an unavailable app,
a failed state write, or a failed reload returns a tool error, not success. A reload can fail
after registration has committed. Retrying registration is safe. `refresh_superseded` means a
newer UI reload interrupted this one; retry `project_refresh`. Calls use the extension's
15-second request timeout. A timeout does not roll back a registration already committed.

These tools require a build containing this feature and the **Terminals and agent tools**
bundled extension enabled. They are not added to an already installed Nightly by this PR.
After merge and release, install/update Nightly and relaunch it once, then start or restart
an agent so it loads the updated extension. Alternatively, build the updated app locally and
launch that build. Subsequent registrations and refreshes need no app restart. Do not copy
just the extension into an older app: that host cannot serve the new requests.

## The tools

- **`agent_list`**: every top-level thread, with its status and directory.
- **`agent_send`**: a message under a `[from: <sender name>, an agent, not the user. …]` header
  ([What the other thread reads](#what-the-other-thread-reads)), with optional `delivery`:
  - `task` (default, including older callers): a user follow-up (`deliverAs: "followUp"`).
    Starts an idle agent or queues another turn while busy. Use it to request work.
  - `report`: hidden custom context (`shepherd-peer-report`, `display: false`,
    `triggerTurn: false`). Never starts an idle agent or queues another turn. While busy, pi
    appends it at the next safe turn boundary, after in-flight tool results. Use it for results
    or FYI; it is not a user message and is omitted by `agent_read`.
- **`agent_spawn`**: a new agent in a directory with an opening prompt. It never takes the
  user's selection.
- **`agent_read`**: finalized visible messages on the target's current pi branch, read live
  from its `ctx.sessionManager.getBranch()`, not from a transcript file.
  - The latest 20 entries by default; `limit` takes 1–100, and `after` (an entry ID, exclusive)
    pages forward.
  - The JSON reply carries `nextCursor`, `hasMore`, `omittedEarlier`, and a per-message
    `truncated` flag.
  - Text is capped at 4,000 characters per entry and about 48 KiB per reply.
  - Thinking, image data, tool arguments, and hidden extension entries are never copied.
  - A cursor that is not on the current branch fails; read again without `after`.
- **`agent_steer`**: `pi.sendUserMessage` with `deliverAs: "steer"`, prefixed like
  `agent_send`. It lands before the target's next turn, or starts an idle one.
- **`agent_interrupt`**: best-effort cancellation of the current turn (`ctx.abort()`). Tools
  must cooperate. Under `pi --mode rpc` it also cancels a pending retry or compaction; messages
  already queued stay queued.
- **`agent_wait`**: polls the target until it is idle with nothing queued (`ctx.isIdle()` and
  `hasPendingMessages()`). 30 seconds by default, at most 120. Settled activity is not proof
  that a message was consumed or a task succeeded. The wait fails if the caller disconnects, or
  if the target's pi session or connection changes between polls (each status carries a
  per-connection ID, so a reconnect under the same session still fails). Cancelling it stops
  the polling, not the target.
- **`agent_delete`**: asks you, in Shepherd, to delete another agent (below).
- **`review_diff`**: readies the agent's review in its side pane's Changes tab (below).

`agent_send`, `agent_steer`, and `agent_interrupt` report that dispatch was requested, never
that the target accepted or acted on it. A missing connection, oversized message or failed
socket dispatch is a failure, not a delivery claim. Pi's extension `sendMessage` API is
fire-and-forget: a report's dispatch is not an acknowledgment that pi stored or read it.

## What the model is told

Agents used to message, steer or start unrelated threads on their own. What reached the model
invited it: the system prompt listed `agent_send` and `agent_spawn` like any other capability, a
description said "use delivery report for results or FYI" and "ask it to agent_send … when it should
report", and none of the eight `agent_*` descriptions said when *not* to use it. The tools now say
so first (`Tests/Extensions/agent-tool-words.test.mjs` reads them, and the system prompt, from a
real pi):

- **Every tool that touches another thread leads with the rule:** "Only when the user explicitly
  asks you to, in this conversation. Never on your own initiative: not to report status, ask for
  help, hand off work, share findings or coordinate. If unsure, don't.", then one wrong use and one
  right use, and that Shepherd may ask the user to approve the call and a refusal is final.
  `agent_wait` and `agent_delete` lead with their own version; `agent_list` says it only reads.
- **The system prompt** carries the two rules once (pi writes a repeated `promptGuidelines` line
  once): use these tools only when asked, and a message that begins `[from: <name>]` is another
  agent's, to be answered with `agent_send` only when it asks for a reply. The tools' prompt lines
  carry the condition too ("Message another agent thread, only when the user explicitly asked you
  to").
- **In a thread the tools are deferred** (Settings ▸ Agents ▸ Defer rarely used tools, on by default;
  docs/context-budget.md › Deferred tools): `agent_*` and `automation_*` are in no request until the model
  loads them with `tool_search`, one prompt line says they exist ("agent_* (other agent threads, only when the
  user explicitly asks you to)"), and a search that finds one loads all eight. The rule about a message from another
  agent is in every thread's prompt whether or not they are loaded, since a thread receives one without loading
  anything; the rule about using the tools joins when they load, and every description leads with the same
  "Only when the user explicitly asks you to" the search result shows. Calls, the approval gate and the recipient
  side (reading, steering, interrupting a live thread) are not exposure's business: they work the same, and a
  thread that loaded nothing still receives and answers `agent_read`, `agent_steer` and the like. A watch agent's
  `agent_send` stays direct.
- **`agent_list`'s answer ends with a reminder** not to message, steer, interrupt, read or start
  the threads it lists unless asked.
- **`agent_spawn`'s `prompt` no longer tells the new thread to report back** ("how to report
  back" is gone), and `automation_create`'s `replyToCreator` says to set it only when the user
  asked to hear the result in this thread.
- **A watch agent (an automation run) gets `agent_send` and no other `agent_*` tool**: it
  reports to its creator and nothing more. A native subagent loads no Shepherd extension at all,
  and a design's agent gets no panes extension.

### What the other thread reads

A message from `agent_send` or `agent_steer` arrives as a user message, so its header says who
wrote it: `[from: <sender>, an agent, not the user. Reply with agent_send only if this asks for a
reply.] <text>` (`AgentMessageFraming`). The sender's name is one short line without brackets, since
an agent's name comes from its first prompt. A `report` is hidden context under the same header.

## Approving what agents do to other threads

Settings ▸ Pi ▸ Agent-to-agent messages (`AgentMessagePolicy`) decides what an agent's call on
another thread does. **The host enforces it** (`SessionServer.gateAgentAction`, before anything is
sent, relayed or started): the extension only asks, so a modified one cannot get around it, and
every message that reaches the gate has already passed the identity rule (a connection speaks only
for the agent whose pi opened it).

| Call | Gated |
| --- | --- |
| `agent_send`, `agent_steer`, `agent_interrupt` | yes: they act on another thread |
| `agent_spawn` | yes: it starts a thread, with a prompt, in a folder the agent chose |
| `agent_read` of another thread | yes: its conversation enters the caller's context, and a thread's text is the user's to share. Reading your own thread is not |
| `agent_list`, `agent_wait` | no: `agent_list` names threads, and `agent_wait` returns only whether one is idle |
| `agent_delete` | its own dialog asks every time, whatever the setting; Never refuses it first |

- **Ask me** (the default, also what a bare `SessionServer` does): the call parks on the server. The
  app opens `PeerApprovalDialog` for it ([dialogs-and-palette](design/dialogs-and-palette.md)),
  and the caller waits. **Allow once** does that call. **Allow for this thread** does it and every
  later gated call from the same agent, to any thread, until the app quits or that agent's pi
  restarts (an allowance is tied to the pi's session and is never written to disk), and it
  allows what the agent already has waiting. **Deny** answers the caller `not_approved`: "The user
  did not approve. Don't message other agents unless the user asks you to." Nothing is done.
- **Always allow**: gated calls go through as they always did; no dialog.
- **Never**: every gated call, and `agent_delete`, is refused `not_allowed` at once, without a
  dialog ("The user has turned agent-to-agent messages off. …"). Switching to Never also refuses
  what is waiting. Any change of the setting forgets every "Allow for this thread".
- **An automation run** (a watch agent) cannot be asked, so under Ask it is refused
  (`not_allowed`: "An automation run can't ask the user … unless the user set Agent-to-agent
  messages to Always allow. Use notify instead."). Only Always allow lets it message. That includes
  a `replyToCreator` report: its `agent_send` to the creator needs Always allow, and otherwise the
  watcher's notification is the only report.
- **A call that waits ends** when the user answers, the caller cancels it (Stop cancels the tool
  call, and the dialog closes), the caller's connection closes, the setting becomes Never, or two
  minutes pass (`not_approved`: "The user did not approve in time. …"). A late answer finds nothing
  waiting and does nothing. An answer claims the call's token on the server queue, so a call is done
  at most once.
- **Several may wait**, one dialog each, shown one at a time: up to 8 per agent and 24 in all,
  then `busy`. A duplicate request id is `busy`.
- Calls that could not be done anyway (an unknown or own thread, a folder that is not one, a
  target with no running pi, empty text) are refused as before, without asking.
- **Remote.** The dialog opens on the host's own window, as the Delete agent dialog does; nothing
  on the wire changes. A thread on a host nobody is sitting at gets no answer, so its call times
  out after two minutes with `not_approved`. A host that serves threads to another Mac should set
  Always allow or Never in its own Settings ▸ Pi.
- **What the user sends is never gated**: a message typed in a thread (from any client), `/`
  commands, a review sent back, an automation's own prompt.

## How a live request travels

`agent_read`, `agent_steer`, `agent_interrupt`, and `agent_wait` are served by the target's own
panes extension, from its live pi context. The status Shepherd saved is never used as an answer.

1. The caller sends `coordinateAgent` with its own request `id`.
2. The server checks that the caller's connection is the one pi process the app started for that
   agent (every message names its sender, and only that agent's own pi may say it), that the
   caller registered as that agent (`helloAgent`), that the target exists, and that the caller is
   not the target (only a read may address itself). Anything else, a process the agent started
   included, is answered `wrong_process`.
3. It relays `agentRequest` to the target's registered connection under a token of its own, and
   accepts `agentResponse` for that token only from that connection, under the target's
   identity.
4. The answer returns to the caller as `agentResult`, correlated by the caller's `id`. A `code`
   marks a failure.

Limits:

- A target without a live panes extension answers `not_running`: its pi is not running, or the
  extension is off under Settings ▸ Pi ▸ Bundled extensions. Agents restart with the app and load
  the copy it installs, so none runs an older extension.
- A live request times out after 5 seconds. A reply over 64 KiB is refused, and steering text
  must be 1 to 32,768 bytes.
- A caller may have 16 requests in flight, each with a distinct `id`.
- If either side disconnects, its pending requests fail with `disconnected`.
- `cancelAgentRequest` (a cancelled tool call) answers `cancelled`. It cannot undo a steer or an
  interrupt already dispatched.

The extension socket is same-user IPC with no token: what stops one agent from acting as another
is that a connection speaks only for the agent whose pi opened it (ARCHITECTURE.md › Who a
connection speaks for; [SECURITY.md](../SECURITY.md)). None of this is part of the remote
protocol, and there is no task scheduling.

## Deleting another agent

`agent_delete` never reaches the target. The server hands it to the app, which opens the Delete
agent dialog (`PeerDeleteDialog`): it names the agent, its space, and the agent that asked, and
warns that the agent's pi session and every process it started will stop.

- **Only the dialog's destructive button approves it.** The request has no approval field, and a
  stray one is ignored.
- **Cancel, dismissing the dialog, the caller cancelling or disconnecting, or 120 seconds without
  an answer** keep the agent. The dialog closes when its request lapses, and its buttons do
  nothing afterward.
- **One at a time:** a second request while the dialog is up answers `busy`.
- **Approving** claims the request on the server first, so a request that lapsed a moment
  earlier cannot delete. It then deletes through Delete Agent, like the sidebar's: the agent's
  processes stop and its layout goes. A worktree agent keeps its checkout and branch, as with
  "Delete agent only"; this never runs Delete Worktree Agent.
- An agent cannot delete itself.

## Reviews an agent opens

`review_diff` readies the agent's review in the Changes tab of its side pane, docked beside the
agent's layout ([side-pane-changes](design/side-pane-changes.md)). The pane never opens by itself: the tab
takes a dot, and with the pane closed so does the header's side-pane button; the user opens it
(⇧⌘B, ⌃1). A request while a subagent is inspected leaves the inspector in front. It returns at
once; the user's review arrives later as a message.

- `cwd` reviews another repository or worktree, for example `{"cwd":"~/src/project-worktree"}`.
  It never changes the agent's own directory. Without `cwd`, the review shows the agent's
  directory, even when the open review points somewhere else. The Changes tab's bar, and the
  confirmation for a file's Revert, name the directory it shows.
- `reference` reviews a commit, branch, or range; without it, working-tree changes against
  HEAD.
- An agent has one review. Asking again reloads it in place, without opening the pane, taking it
  from an inspected subagent, or changing what the user has selected.
- Pointing it at a different directory starts the review over: comments, the summary, viewed
  marks, and the pane's folds belonged to the old diff. The same directory keeps them.

## Terminals

The same extension gives an agent the `terminal_*` tools for the terminals under its own thread.
A terminal is a tab of the terminal panel; there are no splits, and the agent's own thread is
never a terminal.

- **`terminal_open`**: a new terminal as a new tab, in the thread's folder (its worktree) unless
  `cwd` is given, optionally running `command`. The panel opens on it and the keyboard stays
  where it was. It returns the terminal's id. There is no axis or anchor to name.
- **`terminal_list`**: the agent's terminals, oldest first. Its own thread is never listed.
- **`terminal_run`**, **`terminal_read`**, **`terminal_focus`** (shows the panel on that tab and
  moves the keyboard there) and **`terminal_close`** name a terminal by `terminalID`, the id
  `terminal_open` and `terminal_list` return (`paneID` on the wire).
- **Scope.** An agent touches only terminals in its own layout: any other id, and a focus or read
  of its own thread, is `no_such_terminal`. It cannot type into or close its own thread
  (`not_writable`, `not_closable`). Closing the last terminal closes the panel.
- The host that runs the agent serves them (`PaneControl.swift`, `onPaneRequest`). The tools were
  `pane_*` before, with no aliases: the extension and the host are always the same build, so the
  rename has no compatibility question. Only the wire between a client and a host does, below.

## Terminals and compatibility

Terminals are tabs only, and a host never makes a split. The wire did not change (no new
capability, the same `RemoteProtocol` version and requests), so builds from before and after
terminals became tabs meet like this:

- **Current client, current host.** +, ⌘D and ⌘J (with no terminal) send the same `openPane`
  request they always did for a new tab, naming the thread as `relativeTo` with axis horizontal
  (`TerminalPanel.newTabAnchor`). The host ignores both `axis` and `relativeTo` and opens a new
  tab in the thread's folder (or the request's `cwd`), answering `paneOpened`. There is no split
  request anywhere.
- **Older client, current host.** An older client's Split right or Split down is an `openPane`
  naming a terminal and an axis. The host opens a new tab instead (never a split) and answers
  normally; the older client then sees the flattened layout, every tab one terminal. An older
  client's `resizePaneSplit` (a divider drag) is answered with an `unsupported` error
  ("Terminals are tabs and have no splits to resize.") without reaching the GUI handler, and the
  connection stays (the older client ignores the failure). An older client asking to split or
  resize a host's utility (inspector) terminal gets an error too ("Terminals have no splits").
  `closePane` of the thread still answers `not_closable`.
- **Current client, older host.** The client never offers Split. +, ⌘D and ⌘J send the same
  `openPane` naming the thread, which the older host handles as it always did: it splits the
  thread, which is a new tab. The client draws any split tab of that host (made by its own older
  UI or another client) as one tab per terminal (`TerminalPanel.tabs`). A host without the
  `pane.control.v1` capability fails the request `unsupported`, and the client beeps (iOS shows
  "Update Shepherd on the host...").
- **Older client, older host.** Unchanged.

A host flattens its own saved layouts when it starts (`SessionServer.flattenSplitTerminals`,
ARCHITECTURE.md › Terminal layouts), so a current host never holds a split tab for long; the
older-host row is the only place a client meets one.

## Automation completion reports

`automation_create(replyToCreator: true, …)` appends instructions to the saved watch prompt
asking it to call `agent_send` with `delivery: "report"` and the creating agent's exact ID when it succeeds, fails, or
is blocked, as well as `notify`. Automation agents have `agent_send` and no other `agent_*` tool;
they cannot create further automations. The default remains notification-only unless the prompt
asks otherwise, and the model is told to set `replyToCreator` only when the user asked to hear the
result in that thread. **The report is an agent message, so it needs Settings ▸ Pi ▸ Agent-to-agent
messages set to Always allow**: an automation run cannot be asked, and under Ask me or Never the
host refuses it (`not_allowed`), leaving the watcher's `notify` as the report.

This is an instruction to the watch agent, not a guaranteed completion callback. Dispatch
adds context without waking the creator; while busy it waits for pi's safe boundary, not a
follow-up turn. The saved target survives a restart, but a deleted
creator cannot receive it: the watcher reports the delivery failure in its notification and
stops rather than choosing a different thread. Editing the automation's prompt replaces
these instructions too, so retain them if completion reporting is still wanted.

## Tests

```bash
PI_PACKAGE_DIR="$(npm root -g)/@earendil-works/pi-coding-agent" \
  node --test Tests/Extensions/agent-coordination.test.mjs   # the recipient side and the tools
PI_PACKAGE_DIR="$(npm root -g)/@earendil-works/pi-coding-agent" \
  node --test Tests/Extensions/agent-tool-words.test.mjs     # what the model is told (a real pi's request)
swift test --filter 'ExtensionMessageTests|ExtensionReplyTests|ExtensionSocketTests' # wire shapes and peer routing
swift test --filter AgentCoordinationTests                   # server relaying and tokens
swift test --filter 'AgentPeerDeletionTests|ReviewFlowTests' # the dialog and review_diff
swift test --filter 'AgentApprovalRulesTests|AgentApprovalTests'  # the gate: every setting, every gated call, every way a wait ends
swift test --filter 'PeerApprovalPresentationTests|PeerApprovalFlowTests' # the dialog's words, and its buttons pressed (ControlPress)
```
