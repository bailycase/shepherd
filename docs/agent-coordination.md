# Agent coordination

The bundled panes extension (`Extensions/shepherd-panes.ts`, on under Settings ▸ Pi ▸ Bundled
extensions) gives every Shepherd agent tools for the other top-level agents in the app, and the
review extension (`Extensions/shepherd-review.ts`) gives it `review_diff`. Subagents are a
separate runtime ([native-subagents.md](native-subagents.md)); these tools address agents in the
sidebar.

Code: `Extensions/shepherd-panes.ts` (the tools and the recipient side), `SessionServer`
(relaying, tokens, timeouts), `AgentPeers.swift` (list, send, spawn, and the deletion dialog's
decisions), `PeerDeleteDialog` in `AppDialogs.swift`, and `ShepherdViewModel+Review.swift`.

## The tools

- **`agent_list`**: every top-level agent, with its status and directory.
- **`agent_send`**: a message the target receives as a follow-up (`deliverAs: "followUp"`),
  prefixed `[from: <sender name>]`. It wakes an idle agent.
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
- **`review_diff`**: opens the agent's review beside its thread (below).

`agent_send`, `agent_steer`, and `agent_interrupt` report that dispatch was requested, never
that the target accepted or acted on it.

## How a live request travels

`agent_read`, `agent_steer`, `agent_interrupt`, and `agent_wait` are served by the target's own
panes extension, from its live pi context. The status Shepherd saved is never used as an answer.

1. The caller sends `coordinateAgent` with its own request `id`.
2. The server checks that the caller registered as that agent (`helloAgent`), that the target
   exists, and that the caller is not the target (only a read may address itself).
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

The extension socket is same-user IPC, not a security boundary ([SECURITY.md](../SECURITY.md)).
None of this is part of the remote protocol, and there is no task scheduling.

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

`review_diff` opens the agent's review, docked in its right pane beside the agent's layout
([DESIGN.md](../DESIGN.md), Review). It returns at once; the user's review arrives later as a
message.

- `cwd` reviews another repository or worktree, for example `{"cwd":"~/src/project-worktree"}`.
  It never changes the agent's own directory. Without `cwd`, the review shows the agent's
  directory, even when the open review points somewhere else. The review's header, and the
  confirmation for a file's Revert, name the directory it shows.
- `reference` reviews a commit, branch, or range; without it, working-tree changes against
  HEAD.
- An agent has one review. Asking again reloads it and brings it back in front of an inspected
  subagent, without changing what the user has selected.
- Pointing it at a different directory starts the review over: comments, the summary, viewed
  marks, and the pane's folds belonged to the old diff. The same directory keeps them.

## Tests

```bash
PI_PACKAGE_DIR="$(npm root -g)/@earendil-works/pi-coding-agent" \
  node --test Tests/Extensions/agent-coordination.test.mjs   # the recipient side and the tools
swift test --filter ExtensionMessageTests                    # wire shapes
swift test --filter AgentCoordinationTests                   # server relaying and tokens
swift test --filter 'AgentPeerDeletionTests|ReviewFlowTests' # the dialog and review_diff
```
