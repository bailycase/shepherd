#!/usr/bin/env python3
"""A stand-in for `pi --mode rpc` that speaks the documented JSONL protocol
(pi docs/rpc.md). stdlib only. Behaviour keyed on the prompt text:

  "ask"    emits a confirm extension_ui_request and waits for the response
  "hang"   never responds (timeout path)
  "die"    exits 3 without responding
  "big"    emits one record over 1 MiB, then a normal event
  "stderr" writes a line to stderr
  "slow"   a streaming turn that pauses twice (mid-deltas, mid-tool) until the
           files `continue-1` / `continue-2` appear in the cwd
  "stream" a reply of 40 text deltas 2 ms apart, as a model streams one
  "toolcall" the model writing a tool call's arguments slowly (a big `write`): a line of text,
           then toolcall_start, toolcall_delta fragments of the arguments' JSON text (each the
           next few characters, not the text so far), toolcall_end, the reply's message_end,
           tool_execution_start, the call's end and a closing reply. It pauses until the files
           `continue-1` (the path half written), `continue-2` (the path known, the content
           streaming) and `continue-3` (the call running) appear in the cwd. An abort at any
           pause ends it as pi ends a stopped request: toolcall_end with the arguments parsed so
           far, an `aborted` message_end that still carries the call, no tool_execution_start,
           then agent_end and agent_settled. Its events are the shapes pi 1.0.0 sends
           (Tests/Extensions/tool-call-stream.test.mjs pins them against the real thing).
  "browser-peer <agentID> <socket>" the browser extension's registration, from this process and
           from a process it starts (as an agent's bash tool would), in one turn: this process says
           helloBrowser as <agentID> on <socket> and asks for a reload (the server's reply line goes
           to the file `browser-self-1.reply` in the cwd), a child process does the same
           (`browser-child.reply`), then it waits for the file `browser-go` and asks again on its
           first connection (`browser-self-2.reply`).
  "speak <label> <mine> <other> <socket>" the extension socket's traffic for two agents (`mine`,
           `other`), from this process and from a process it starts (as an agent's bash tool would):
           the panes hello, a status, a notify and three requests each, and the children hello. What
           each request was answered goes to `speak-<label>.json` in the cwd: {"own": {"self": {
           "listPanes": <reply line>, ...}, "other": ...}, "child": ...}. Its notifies are titled
           "<who>-as-<self|other>", and its status is "working" only from this process as `mine`
           ("blocked" otherwise). Then it waits for the file `speak-<label>-go` and writes
           `speak-<label>-after.json`: the next line its panes connection as `mine` read (a push),
           and whether its children connection as `mine` is still open.
  $STUB_PI_SPEAK "<label> <mine> <other> <socket>" with $STUB_PI_SPEAK_GATE (a file in the cwd):
           the same, from this process only, as soon as the gate file exists, even before the
           pi serves (an extension that connects while the app is still binding the pi to its pane).
           A pi launched the way the app launches it reads `stub-pi-startup.json` instead:
           {"speak": {"label": "app", "other": "<agent id>", "gate": "speak-gate", "socket": "<path>"}},
           speaking as $SHEPHERD_AGENT_ID.
  "widgets"      emits setStatus/setWidget/notify/setTitle (with ANSI colour)
  "widgets-clear" clears the status and widget from "widgets"
  "select" emits a select extension_ui_request (no timeout) and waits
  "ask-choice" a select of three options, the first "(Recommended)" with a line under each
  "ask-input" / "ask-editor" an input (with a placeholder) or an editor (with a prefill)
  "ask-short" / "ask-long" an ask_user tool call (with a `short` reason, or without one) whose
           select extension_ui_request waits; the answer ends the call and the run
  "question" a turn like pi's with an extension's ask tool: the user message, a call to
           `ask_user`, which asks a select (two options, the first "(Recommended)") and waits
           for the answer, the call's result, then "Going with <answer>". Persisted like
           "tools:N" ($STUB_PI_MESSAGES_FILE). "question-timeout" asks with a 150 ms timeout
           and goes on unanswered when it passes, as pi does. Each question has its own id.
  "fill"   appends 120 history messages, then agent_start/agent_end
  "newsession" switches sessionId, then agent_start/agent_end
  "select-newsession" asks a select, then switches sessionId (as "newsession") with the
           question still open
  "refuse" answers the prompt with success: false (pi refusing it)
  "provider-error" a turn whose reply fails ("529 overloaded"), once the file `fail-turn`
           appears in the cwd
  "flaky"  a turn like pi's (stamped user message_start/_end, persisted at its end) whose reply
           fails ("529 overloaded") the first time and answers "Recovered: <text>" after that;
           "flaky-hold" also waits for the file `flaky-go` before replying
  "/shepherd-retry <ms>" Shepherd's Retry, as the status extension runs it in pi: pi answers
           the prompt, then, idle and with a user message stamped <ms> on the branch, drops that
           message and everything after it from the history and sends it again (a "flaky" turn);
           otherwise a notify says why and nothing changes
  "/session-name <word> <text>" the extension command in get_commands, run as pi runs one (at once,
           even while streaming; no turn, no message): "info", "warning" or "error" notify <text> at
           that level before pi answers the prompt, "late" notifies <text> just after the answer,
           "report" sends <text> as a displayed custom message (message events, no turn),
           "fail" ends with an extension_error for the command (pi answers the prompt as accepted),
           anything else answers and says nothing
  "tools:N" a run that behaves like pi's agent loop (below)
  "context"      loads a context worth sizing: pi's structured system prompt (sections with an
                 AGENTS.md, tools), a read and a bash call with large results; stats say 42k
                 of a 200k window
  "fill-context" stats say 178k of 200k (89%)
  "auto-compact" a turn, then a threshold compaction before agent_settled
  "compact-abort" a manual compaction that is stopped (compaction_end aborted)
  other    a full streaming turn with a U+2028 inside a delta

`compact` (with optional customInstructions) compacts like pi: compaction_start (manual),
then compaction_end with a summary that ends "Kept: <instructions>", the last two messages
kept after the summary, and stats' contextUsage tokens and percent null until the next turn.
With "hold" in the instructions it waits for the file `compact-done` first. A session of fewer
than three messages fails ("Nothing to compact (session too small)").

pi's queues, as pi 1.0.0 behaves (docs/rpc-commands.md, and transcripts of the real thing):
  - While a run streams, `prompt` needs `streamingBehavior`, else pi refuses it ("Agent is
    already processing..."). `steer` / `followUp` append to that queue, stamped when queued,
    then pi emits `queue_update` with both queues' text, then answers the prompt.
  - A "tools:N" run: each model call reads the newest user message; while it has asked for N
    tool calls and made fewer, it makes one (a bash call that waits for the file `tool-<k>`
    in the cwd, k counting every call this stub makes), else it replies "Reply to <text>".
    Steering is taken one at a time: at the start of the run and after each tool batch or
    reply. A message leaves the queue (`queue_update`) just before its user message_start.
    Follow-ups are taken one at a time once the run would stop, within the same run.
    "hold-start" holds the first user message until the file `start` appears.
    "hold-settle" in the first prompt holds the run between its last look at the queues and
    agent_end until the file `settle` appears (a steer sent then is stranded, as in pi).
  - `abort` during a "tools:N" run fails the running call ("Command aborted"), delivers the
    next steer, ends with an empty error reply, then agent_end, agent_settled, and only then
    the abort response. Follow-ups stay queued (pi does not clear its queue on abort).
  - `clear_queue` empties both queues, emits an empty `queue_update`, and answers with their
    text. A steer with "raced" in it stays queued and unreported, as when pi reads a steer
    (its tool batch ended) just before a `clear_queue` arrives: it still lands. While the file
    `clear-gate` exists in the cwd, the answer waits for the file `clear-go` (a `clear_queue` on
    its way while the run ends).
  - The file `refuse-abort` in the cwd makes `abort` fail ("refused by the stub").
  - "compact-hold" in a "tools:N" run's first prompt makes the run compact after its last reply:
    compaction_start (threshold), then it waits for the file `compact-done` (or an abort), then
    compaction_end. As in pi, a prompt that is not a command is refused meanwhile ("Cannot submit
    a prompt while compaction is in progress...").
  - Idle, a prompt with a streamingBehavior is a plain prompt.
$STUB_PI_MESSAGES_FILE, when set, loads the history from that file at start and saves it
after every "tools:N" run, like pi resuming its session file.

set_model / set_thinking_level update STATE (unknown provider -> error).
$STUB_PI_MODEL (a JSON object) overrides fields of the starting model (provider, id, api), and
$STUB_PI_MODEL_APIS (a JSON object from "provider/id" to its api) names the non-anthropic models
set_model accepts, each with that api: the model pi's get_state reports is what the host's
service tier support reads. With $STUB_PI_LOG and $SHEPHERD_EXT_SERVICE_TIER set, the stub logs
{"type": "stub-service-tier", "when": "start" | "prompt", "message": ..., "content": ...}: what
the agent's tier file holds at its start and before each prompt, as the extension reads it.
get_available_thinking_levels answers pi's reasoning set (off, minimal, low, medium, high),
or $STUB_PI_THINKING_LEVELS: a comma list for every model, or a JSON object from model id to
its list ("*" for the rest); "unsupported" answers as a pi without the command.
A prompt carrying images also logs {"type": "stub-images", "count": N}.

$STUB_PI_HISTORY_BYTES seeds that many bytes of prior history (see below).

Startup, like a pi that takes a while to boot (or fails to), before stdin is read:
  $STUB_PI_STARTUP_DELAY  seconds to wait
  $STUB_PI_STARTUP_GATE   a file in the cwd to wait for (up to 60 s)
  $STUB_PI_STARTUP_NEW_SESSION  write pi's warning (in chalk's yellow) that it found no session
                          with the `--session-id` it was given and creates one, then go on
  $STUB_PI_STARTUP_EXIT   exit with this code instead of serving
  $STUB_PI_STARTUP_STDERR what it writes to stderr before that exit (default
                          "stub-pi: failed to start"), as pi's own error would be
  $STUB_PI_STARTUP_REQUIRE_AUTH  like pi with nothing to sign in with: exit 1 with "No models
                          available." unless $PI_CODING_AGENT_DIR/auth.json holds a login (it
                          reads only the keys, never a value)
Like pi, it loads the extensions its home's settings.json names ($PI_CODING_AGENT_DIR,
`extensions`, by path; a folder's index.ts or index.js): one whose file has `throw new Error(`
in it fails as pi's loader reports it (a missing file is passed over), `Failed to load extension "<path>": Failed to load
extension: <the error's message>`, and pi exits 1, as it does in every mode. The launch record
lists the extensions settings.json names.
A pi launched the way the app launches it gets no test env, so `stub-pi-startup.json` in the
cwd ({"delay": 1.5, "gate": "release-pi", "newSession": true, "exit": 1, "stderr": "...",
"requireAuth": true, "model": {"provider": "openai", "id": "gpt-6-luna", "api": "openai-responses"}})
sets the same.

Every stdin line is appended to $STUB_PI_LOG when set, so tests can assert
on what the client actually wrote.
"""
import json
import os
import re
import sys
import threading
import time

out = sys.stdout.buffer
out_lock = threading.Lock()
log_path = os.environ.get("STUB_PI_LOG")
tier_path = os.environ.get("SHEPHERD_EXT_SERVICE_TIER")


def log_tier(when, message=None):
    """Logs what the agent's service tier file holds now, as the real extension would read it
    before a model call: `{"type": "stub-service-tier", "when": "start" | "prompt", "content": ...}`
    (content null without a file). Only with $STUB_PI_LOG and $SHEPHERD_EXT_SERVICE_TIER set."""
    if not (log_path and tier_path):
        return
    try:
        with open(tier_path) as f:
            content = f.read()
    except OSError:
        content = None
    with open(log_path, "ab") as f:
        f.write(json.dumps({"type": "stub-service-tier", "when": when, "message": message, "content": content}).encode() + b"\n")


log_tier("start")


def wait_for_file(name, timeout=30.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline and not os.path.exists(name):
        time.sleep(0.02)


def emit(obj, terminator=b"\n"):
    # ensure_ascii=False keeps U+2028 as a raw code point inside the string,
    # the exact case a generic line reader would split on.
    with out_lock:
        out.write(json.dumps(obj, ensure_ascii=False).encode("utf-8") + terminator)
        out.flush()


def respond(cmd, command, success=True, data=None, error=None):
    r = {"type": "response", "command": command, "success": success}
    if "id" in cmd:
        r["id"] = cmd["id"]
    if data is not None:
        r["data"] = data
    if error is not None:
        r["error"] = error
    emit(r)


STATE = {
    # $STUB_PI_MODEL (a JSON object, e.g. {"provider": "openai", "id": "gpt-6-luna", "api": "openai-responses"})
    # overrides these fields of the starting model; set_model then takes any provider whose model
    # the object $STUB_PI_MODEL_APIS ("provider/id" -> api) names, as pi's catalog would.
    "model": dict({"id": "claude-sonnet-4-20250514", "name": "Claude Sonnet 4", "provider": "anthropic",
                   "api": "anthropic-messages", "reasoning": True, "input": ["text", "image"],
                   "contextWindow": 200000, "maxTokens": 16384}, **json.loads(os.environ.get("STUB_PI_MODEL") or "{}")),
    "thinkingLevel": "medium",
    "isStreaming": False,
    "isCompacting": False,
    "steeringMode": "all",
    "followUpMode": "one-at-a-time",
    "sessionFile": "/tmp/stub-session.jsonl",
    "sessionId": "stub-session",
    "autoCompactionEnabled": True,
    "messageCount": 2,
    "pendingMessageCount": 0,
}

MESSAGES = [
    {"role": "user", "content": "Hello!", "timestamp": 1733234567890, "attachments": []},
    {"role": "assistant", "content": [{"type": "text", "text": "Hello! How can I help?"}],
     "api": "anthropic-messages", "provider": "anthropic", "model": "claude-sonnet-4-20250514",
     "stopReason": "stop", "timestamp": 1733234567891},
]

# STUB_PI_HISTORY_BYTES seeds a long session: a user turn, then tool results big enough that
# get_messages answers with one multi-megabyte record, as pi does for long real sessions.
_history_bytes = int(os.environ.get("STUB_PI_HISTORY_BYTES", "0") or 0)
if _history_bytes > 0:
    MESSAGES.append({"role": "user", "content": "seeded long session"})
    chunk = 512 * 1024
    for i in range(max(1, _history_bytes // chunk)):
        MESSAGES.append({"role": "assistant", "stopReason": "toolUse",
                         "content": [{"type": "toolCall", "id": f"seed_{i}", "name": "bash", "arguments": {"command": "cat big"}}]})
        MESSAGES.append({"role": "toolResult", "toolCallId": f"seed_{i}", "toolName": "bash",
                         "content": [{"type": "text", "text": "x" * chunk}], "isError": False})
    MESSAGES.append({"role": "assistant", "content": [{"type": "text", "text": "seeded reply"}], "stopReason": "stop"})


COMMANDS = [
    {"name": "session-name", "description": "Set or clear session name", "source": "extension"},
    {"name": "fix-tests", "description": "Fix failing tests", "source": "prompt", "location": "project"},
]

STATS = {
    "sessionFile": "/tmp/stub-session.jsonl", "sessionId": "stub-session",
    "userMessages": 1, "assistantMessages": 1, "toolCalls": 0, "toolResults": 0, "totalMessages": 2,
    "tokens": {"input": 50000, "output": 10000, "cacheRead": 40000, "cacheWrite": 5000, "total": 105000},
    "cost": 0.45,
    "contextUsage": {"tokens": 60000, "contextWindow": 200000, "percent": 30},
}

USAGE = {"input": 100, "output": 1, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 101,
         "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0}}


def update(delta):
    emit({"type": "message_update", "usage": USAGE, "assistantMessageEvent": delta})


def streaming_turn(prompt, slow=False):
    emit({"type": "agent_start"})
    emit({"type": "turn_start"})
    emit({"type": "message_start", "message": {"role": "assistant", "content": []}})
    update({"type": "text_start", "contentIndex": 0})
    update({"type": "text_delta", "contentIndex": 0, "delta": "Hello"})
    update({"type": "text_delta", "contentIndex": 0, "delta": " line\u2028sep"})
    if slow:
        wait_for_file("continue-1")
    update({"type": "text_delta", "contentIndex": 0, "delta": " world"})
    update({"type": "text_end", "contentIndex": 0, "content": "Hello line\u2028sep world"})
    update({"type": "toolcall_start", "contentIndex": 1, "id": "call_abc123", "toolName": "bash"})
    update({"type": "toolcall_end", "contentIndex": 1,
            "toolCall": {"type": "toolCall", "id": "call_abc123", "name": "bash", "arguments": {"command": "ls"}}})
    final = {"role": "assistant",
             "content": [{"type": "text", "text": "Hello line\u2028sep world"},
                         {"type": "toolCall", "id": "call_abc123", "name": "bash", "arguments": {"command": "ls"}}],
             "stopReason": "toolUse"}
    emit({"type": "message_end", "message": final})
    emit({"type": "tool_execution_start", "toolCallId": "call_abc123", "toolName": "bash", "args": {"command": "ls"}})
    if slow:
        wait_for_file("continue-2")
    emit({"type": "tool_execution_end", "toolCallId": "call_abc123", "toolName": "bash",
          "result": {"content": [{"type": "text", "text": "total 48\n"}], "details": {}}, "isError": False})
    tool_result = {"role": "toolResult", "toolCallId": "call_abc123", "toolName": "bash",
                   "content": [{"type": "text", "text": "total 48\n"}], "isError": False}
    emit({"type": "turn_end", "message": final, "toolResults": [tool_result]})
    # An event type this client does not model; must decode as unknown, not fail.
    emit({"type": "stub_unmodelled_event", "reason": "manual"})
    # Like pi, message_end persisted these; get_messages now returns them.
    MESSAGES.extend([{"role": "user", "content": prompt}, final, tool_result])
    STATE["messageCount"] = len(MESSAGES)
    emit({"type": "agent_end", "messages": [final], "willRetry": False})
    STATS["contextUsage"] = {"tokens": 60000, "contextWindow": 200000, "percent": 30}
    if prompt == "auto-compact":
        compaction("threshold", None)
    # CRLF is tolerated by the reader.
    emit({"type": "agent_settled"}, terminator=b"\r\n")


def compaction(reason, instructions):
    """pi's compaction: the summary replaces all but the last two messages."""
    emit({"type": "compaction_start", "reason": reason})
    if instructions and "hold" in instructions:
        wait_for_file("compact-done")
    conversation = [m for m in MESSAGES if m.get("role") != "system"]
    if len(conversation) < 3:
        emit({"type": "compaction_end", "reason": reason, "aborted": False, "willRetry": False,
              "errorMessage": "Compaction failed: Nothing to compact (session too small)"})
        return None
    before = (STATS.get("contextUsage") or {}).get("tokens") or 184000
    summary = "## Goal\nMake the thread rows match the spec.\n\n## Done\nLabels removed.\n\n## Next\nPush the branch."
    if instructions:
        summary += "\n\nKept: " + instructions
    system = [m for m in MESSAGES if m.get("role") == "system"]
    kept = conversation[-2:]
    MESSAGES[:] = system + [{"role": "compactionSummary", "summary": summary, "tokensBefore": before,
                             "timestamp": now_ms()}] + kept
    STATE["messageCount"] = len(MESSAGES)
    STATS["contextUsage"] = {"tokens": None, "contextWindow": 200000, "percent": None}
    result = {"summary": summary, "firstKeptEntryId": "kept", "tokensBefore": before, "estimatedTokensAfter": 23000,
              "details": {}}
    emit({"type": "compaction_end", "reason": reason, "result": result, "aborted": False, "willRetry": False})
    return result


def context_session():
    """A session whose context has parts to size."""
    agents = "# AGENTS.md\n" + "Follow the house rules. " * 220
    system = {"role": "system", "content": "", "timestamp": 1733234560000,
              "sections": {"preamble": "You are an expert coding assistant. " * 40,
                           "tools": "<tools>\n- read: Read files\n- bash: Run commands\n</tools>",
                           "project_context": "<project_context>\nProject-specific instructions and guidelines:\n\n"
                                              '<project_instructions path="/repo/AGENTS.md">\n' + agents +
                                              "\n</project_instructions>\n</project_context>",
                           "cwd": "<cwd>\n/repo\n</cwd>"},
              "toolsAdded": [{"name": "read", "description": "Read a file", "parameters": {"type": "object"}},
                             {"name": "bash", "description": "Run a command", "parameters": {"type": "object"}}]}
    MESSAGES.insert(0, system)
    MESSAGES.append({"role": "user", "content": "Look at the thread view", "timestamp": 1733234570000})
    MESSAGES.append({"role": "assistant", "stopReason": "toolUse", "timestamp": 1733234570001, "content": [
        {"type": "toolCall", "id": "call_read", "name": "read", "arguments": {"path": "Sources/App/DesktopNativeThreadView.swift"}},
        {"type": "toolCall", "id": "call_test", "name": "bash", "arguments": {"command": "swift test --filter NativePresentationTests"}}]})
    MESSAGES.append({"role": "toolResult", "toolCallId": "call_read", "toolName": "read", "timestamp": 1733234570002,
                     "content": [{"type": "text", "text": "let x = 1\n" * 3200}], "isError": False})
    MESSAGES.append({"role": "toolResult", "toolCallId": "call_test", "toolName": "bash", "timestamp": 1733234570003,
                     "content": [{"type": "text", "text": "Test passed.\n" * 1800}], "isError": False})
    MESSAGES.append({"role": "assistant", "content": [{"type": "text", "text": "The view reads fine."}],
                     "stopReason": "stop", "timestamp": 1733234570004})
    STATE["messageCount"] = len(MESSAGES)
    STATS["contextUsage"] = {"tokens": 42000, "contextWindow": 200000, "percent": 21}


def failed_turn(prompt):
    emit({"type": "agent_start"})
    emit({"type": "turn_start"})
    emit({"type": "message_start", "message": {"role": "assistant", "content": []}})
    wait_for_file("fail-turn")
    final = {"role": "assistant", "content": [], "stopReason": "error", "errorMessage": "529 overloaded",
             "timestamp": now_ms()}
    emit({"type": "message_end", "message": final})
    emit({"type": "turn_end", "message": final, "toolResults": []})
    MESSAGES.extend([{"role": "user", "content": prompt}, final])
    STATE["messageCount"] = len(MESSAGES)
    emit({"type": "agent_end", "messages": [final], "willRetry": False})
    emit({"type": "agent_settled"})


FLAKY = {"failed": False}


def flaky_turn(message):
    """A "flaky" turn: the user message persisted at its message_end, as pi does, then a reply
    that fails the first time any flaky turn runs."""
    emit({"type": "agent_start"})
    emit({"type": "turn_start"})
    emit({"type": "message_start", "message": message})
    emit({"type": "message_end", "message": message})
    MESSAGES.append(message)
    STATE["messageCount"] = len(MESSAGES)
    emit({"type": "message_start", "message": {"role": "assistant", "content": []}})
    text = text_of(message)
    if "flaky-hold" in text:
        wait_for_file("flaky-go")
    if not FLAKY["failed"]:
        FLAKY["failed"] = True
        final = {"role": "assistant", "content": [], "stopReason": "error", "errorMessage": "529 overloaded",
                 "timestamp": now_ms()}
    else:
        final = {"role": "assistant", "content": [{"type": "text", "text": f"Recovered: {text}"}], "stopReason": "stop",
                 "timestamp": now_ms()}
    emit({"type": "message_end", "message": final})
    emit({"type": "turn_end", "message": final, "toolResults": []})
    MESSAGES.append(final)
    STATE["messageCount"] = len(MESSAGES)
    emit({"type": "agent_end", "messages": [final], "willRetry": False})
    emit({"type": "agent_settled"})


def retry_command(at):
    """The status extension's /shepherd-retry: the branch goes back to before the message, which
    goes again (after pi has answered the prompt, as pi does)."""
    for index in range(len(MESSAGES) - 1, -1, -1):
        message = MESSAGES[index]
        if message.get("role") == "user" and int(message.get("timestamp") or -1) == at:
            original = message
            del MESSAGES[index:]
            STATE["messageCount"] = len(MESSAGES)
            return original
    return None


def paced_turn(prompt, deltas=40, interval=0.002):
    emit({"type": "agent_start"})
    emit({"type": "turn_start"})
    emit({"type": "message_start", "message": {"role": "assistant", "content": []}})
    update({"type": "text_start", "contentIndex": 0})
    text = ""
    for i in range(deltas):
        piece = f" word{i}"
        text += piece
        update({"type": "text_delta", "contentIndex": 0, "delta": piece})
        time.sleep(interval)
    update({"type": "text_end", "contentIndex": 0, "content": text})
    final = {"role": "assistant", "content": [{"type": "text", "text": text}], "stopReason": "stop"}
    emit({"type": "message_end", "message": final})
    emit({"type": "turn_end", "message": final, "toolResults": []})
    MESSAGES.extend([{"role": "user", "content": prompt}, final])
    STATE["messageCount"] = len(MESSAGES)
    emit({"type": "agent_end", "messages": [final], "willRetry": False})
    emit({"type": "agent_settled"})


QUEUE_LOCK = threading.Lock()
COMPACTING = threading.Event()
steering = []   # (text, images, timestamp)
follow_up = []
RUN = {"active": False, "thread": None, "abort": threading.Event()}
tool_count = [0]
messages_file = os.environ.get("STUB_PI_MESSAGES_FILE")
if messages_file and os.path.exists(messages_file):
    with open(messages_file) as f:
        MESSAGES[:] = json.load(f)


def now_ms():
    return int(time.time() * 1000)


def queue_update():
    with QUEUE_LOCK:
        emit({"type": "queue_update", "steering": [t for t, _, _ in steering], "followUp": [t for t, _, _ in follow_up]})


def take(queue):
    """One-at-a-time mode: the head, removed (with its queue_update) before it is delivered."""
    with QUEUE_LOCK:
        if not queue:
            return []
        item = queue.pop(0)
    queue_update()
    return [item]


def user_message(text, images, timestamp):
    content = [{"type": "text", "text": text}]
    content += [{"type": "image", "data": i.get("data", ""), "mimeType": i.get("mimeType", "")} for i in images or []]
    return {"role": "user", "content": content, "timestamp": timestamp}


def gate(name):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline and not os.path.exists(name) and not RUN["abort"].is_set():
        time.sleep(0.02)


def text_of(message):
    return "".join(b.get("text", "") for b in message["content"] if b.get("type") == "text")


def agent_run(first):
    new = []
    last = [None]

    def deliver(item):
        message = user_message(*item)
        emit({"type": "message_start", "message": message})
        emit({"type": "message_end", "message": message})
        new.append(message)
        last[0] = message

    def say(message):
        emit({"type": "message_start", "message": dict(message, content=[])})
        emit({"type": "message_end", "message": message})
        new.append(message)

    emit({"type": "agent_start"})
    if "hold-start" in first[0]:
        gate("start")
    emit({"type": "turn_start"})
    deliver(first)
    pending = take(steering)
    done = 0
    aborted = False
    while True:
        more = True
        while more or pending:
            for item in pending:
                deliver(item)
                done = 0
            pending = []
            if RUN["abort"].is_set():
                reply = {"role": "assistant", "content": [], "stopReason": "error", "errorMessage": "Request was aborted",
                         "timestamp": now_ms()}
                say(reply)
                emit({"type": "turn_end", "message": reply, "toolResults": []})
                aborted = True
                break
            text = text_of(last[0])
            wanted = int(m.group(1)) if (m := re.search(r"tools:(\d+)", text)) else 0
            if done < wanted:
                tool_count[0] += 1
                k = tool_count[0]
                call = f"call_q{k}"
                ask = {"role": "assistant", "content": [
                    {"type": "text", "text": f"Step {done + 1} of {wanted}."},
                    {"type": "toolCall", "id": call, "name": "bash", "arguments": {"command": f"step {k}"}}],
                    "stopReason": "toolUse", "timestamp": now_ms()}
                say(ask)
                emit({"type": "tool_execution_start", "toolCallId": call, "toolName": "bash", "args": {"command": f"step {k}"}})
                gate(f"tool-{k}")
                failed = RUN["abort"].is_set()
                output = "Command aborted" if failed else f"step {k} done\n"
                emit({"type": "tool_execution_end", "toolCallId": call, "toolName": "bash",
                      "result": {"content": [{"type": "text", "text": output}], "details": {}}, "isError": failed})
                result = {"role": "toolResult", "toolCallId": call, "toolName": "bash",
                          "content": [{"type": "text", "text": output}], "isError": failed, "timestamp": now_ms()}
                emit({"type": "message_start", "message": result})
                emit({"type": "message_end", "message": result})
                new.append(result)
                emit({"type": "turn_end", "message": ask, "toolResults": [result]})
                done += 1
                more = True
            else:
                reply = {"role": "assistant", "content": [{"type": "text", "text": f"Reply to {text}"}],
                         "stopReason": "stop", "timestamp": now_ms()}
                say(reply)
                emit({"type": "turn_end", "message": reply, "toolResults": []})
                more = False
            pending = take(steering)
            if more or pending:
                emit({"type": "turn_start"})
        if aborted:
            break
        pending = take(follow_up)
        if not pending:
            break
        emit({"type": "turn_start"})
    if not aborted and "compact-hold" in text_of(new[0]):
        emit({"type": "compaction_start", "reason": "threshold"})
        COMPACTING.set()
        gate("compact-done")
        COMPACTING.clear()
        emit({"type": "compaction_end", "reason": "threshold", "aborted": RUN["abort"].is_set(), "willRetry": False,
              "errorMessage": None if RUN["abort"].is_set() else "Compaction failed: stub"})
    if not aborted and "hold-settle" in text_of(new[0]):
        gate("settle")
    MESSAGES.extend(new)
    STATE["messageCount"] = len(MESSAGES)
    if messages_file:
        with open(messages_file, "w") as f:
            json.dump(MESSAGES, f)
    emit({"type": "agent_end", "messages": new, "willRetry": False})
    RUN["active"] = False
    emit({"type": "agent_settled"})


def toolcall_turn(prompt):
    """The model writing a `write` call's arguments slowly, pausing for the test to look at the
    thread (see "toolcall" above). RUN["active"] makes an abort stop it, as it stops a run."""
    words = "Writing the file."
    user = user_message(prompt, [], now_ms())
    call = {"type": "toolCall", "id": "call_write1", "name": "write"}
    complete = {"path": "src/big.txt", "content": "line one\nline two\nline three"}
    emit({"type": "agent_start"})
    emit({"type": "turn_start"})
    emit({"type": "message_start", "message": user})
    emit({"type": "message_end", "message": user})
    emit({"type": "message_start", "message": {"role": "assistant", "content": [], "timestamp": now_ms()}})
    update({"type": "text_start", "contentIndex": 0})
    update({"type": "text_delta", "contentIndex": 0, "delta": words})
    update({"type": "text_end", "contentIndex": 0, "content": words})
    update({"type": "toolcall_start", "contentIndex": 1, "id": call["id"], "toolName": "write"})
    # An OpenAI-style provider opens the call with an empty fragment.
    update({"type": "toolcall_delta", "contentIndex": 1, "delta": ""})
    for fragment in ['{"pa', 'th":"src/']:
        update({"type": "toolcall_delta", "contentIndex": 1, "delta": fragment})
    parsed = {"path": "src/"}
    gate("continue-1")
    if not RUN["abort"].is_set():
        for fragment in ['big.txt","con', 'tent":"line one\\nline ']:
            update({"type": "toolcall_delta", "contentIndex": 1, "delta": fragment})
        parsed = {"path": "src/big.txt", "content": "line one\nline "}
        gate("continue-2")
    reply = {"role": "assistant", "content": [{"type": "text", "text": words}], "timestamp": now_ms()}
    new = [user]
    if RUN["abort"].is_set():
        # What pi parsed of the arguments so far rides toolcall_end, and the aborted message.
        partial = dict(call, arguments=parsed)
        update({"type": "toolcall_end", "contentIndex": 1, "toolCall": partial})
        stopped = dict(reply, content=reply["content"] + [partial], stopReason="aborted", errorMessage="Request was aborted")
        emit({"type": "message_end", "message": stopped})
        emit({"type": "turn_end", "message": stopped, "toolResults": []})
        new.append(stopped)
    else:
        update({"type": "toolcall_delta", "contentIndex": 1, "delta": 'two\\nline three"}'})
        made = dict(call, arguments=complete)
        update({"type": "toolcall_end", "contentIndex": 1, "toolCall": made})
        ask = dict(reply, content=reply["content"] + [made], stopReason="toolUse")
        emit({"type": "message_end", "message": ask})
        emit({"type": "tool_execution_start", "toolCallId": call["id"], "toolName": "write", "args": complete})
        gate("continue-3")
        output = "Successfully wrote to src/big.txt"
        emit({"type": "tool_execution_end", "toolCallId": call["id"], "toolName": "write",
              "result": {"content": [{"type": "text", "text": output}]}, "isError": False})
        result = {"role": "toolResult", "toolCallId": call["id"], "toolName": "write",
                  "content": [{"type": "text", "text": output}], "isError": False, "timestamp": now_ms()}
        emit({"type": "message_start", "message": result})
        emit({"type": "message_end", "message": result})
        emit({"type": "turn_end", "message": ask, "toolResults": [result]})
        closing = {"role": "assistant", "content": [{"type": "text", "text": "Wrote it."}], "stopReason": "stop",
                   "timestamp": now_ms()}
        emit({"type": "turn_start"})
        emit({"type": "message_start", "message": dict(closing, content=[])})
        emit({"type": "message_end", "message": closing})
        emit({"type": "turn_end", "message": closing, "toolResults": []})
        new += [ask, result, closing]
    MESSAGES.extend(new)
    STATE["messageCount"] = len(MESSAGES)
    emit({"type": "agent_end", "messages": new, "willRetry": False})
    RUN["active"] = False
    emit({"type": "agent_settled"})


QUESTION = {"id": None, "answered": threading.Event(), "response": None, "count": 0}


def question_turn(prompt):
    """pi's loop around an extension tool that asks (ctx.ui.select) and waits for the answer."""
    new = []

    def say(message):
        emit({"type": "message_start", "message": dict(message, content=[]) if message["role"] == "assistant" else message})
        emit({"type": "message_end", "message": message})
        new.append(message)

    emit({"type": "agent_start"})
    emit({"type": "turn_start"})
    say({"role": "user", "content": [{"type": "text", "text": prompt}], "timestamp": now_ms()})
    call = f"call_ask{QUESTION['count'] + 1}"
    ask = {"role": "assistant", "content": [
        {"type": "text", "text": "Horizon's checkout isn't clean."},
        {"type": "toolCall", "id": call, "name": "ask_user", "arguments": {"question": "How should I handle it?"}}],
        "stopReason": "toolUse", "timestamp": now_ms()}
    say(ask)
    emit({"type": "tool_execution_start", "toolCallId": call, "toolName": "ask_user", "args": {"question": "How should I handle it?"}})
    QUESTION["count"] += 1
    QUESTION["id"] = f"question-{QUESTION['count']}"
    QUESTION["answered"].clear()
    QUESTION["response"] = None
    request = {"type": "extension_ui_request", "id": QUESTION["id"], "method": "select",
               "title": "How should I handle Horizon's uncommitted edits?",
               "options": ["Compare, keep what's unique, then go through GitHub (Recommended)\nNew branch and PR for anything not merged.",
                           "Leave Horizon alone"]}
    timeout = 0.15 if prompt.startswith("question-timeout") else 30.0
    if prompt.startswith("question-timeout"):
        # Model a host timer delayed behind the history refresh, without blocking test queues.
        request["timeout"] = 1000 if prompt == "question-timeout-late-host" else 150
    emit(request)
    QUESTION["answered"].wait(timeout)
    response = QUESTION["response"] or {}
    QUESTION["id"] = None
    answer = response.get("value") if not response.get("cancelled") else None
    output = answer or "(no answer)"
    emit({"type": "tool_execution_end", "toolCallId": call, "toolName": "ask_user",
          "result": {"content": [{"type": "text", "text": output}], "details": {}}, "isError": False})
    say({"role": "toolResult", "toolCallId": call, "toolName": "ask_user",
         "content": [{"type": "text", "text": output}], "isError": False, "timestamp": now_ms()})
    emit({"type": "turn_end", "message": ask, "toolResults": [new[-1]]})
    emit({"type": "turn_start"})
    time.sleep(0.05)  # the model's next call
    reply = {"role": "assistant", "content": [{"type": "text", "text": f"Going with {output.splitlines()[0]}"}],
             "stopReason": "stop", "timestamp": now_ms()}
    say(reply)
    emit({"type": "turn_end", "message": reply, "toolResults": []})
    MESSAGES.extend(new)
    STATE["messageCount"] = len(MESSAGES)
    if messages_file:
        with open(messages_file, "w") as f:
            json.dump(MESSAGES, f)
    emit({"type": "agent_end", "messages": new, "willRetry": False})
    emit({"type": "agent_settled"})


BROWSER_CHILD = r"""
import json, os, socket, sys
agent, path, out = sys.argv[1:4]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(15)
try:
    s.connect(path)
    s.sendall((json.dumps({"type": "helloBrowser", "agentID": agent}) + "\n").encode())
    s.sendall((json.dumps({"type": "browser", "id": 1, "agentID": agent, "request": {"action": "reload"}}) + "\n").encode())
    line = s.makefile("rb").readline()
except OSError as e:
    line = json.dumps({"type": "stub-error", "message": str(e)}).encode() + b"\n"
with open(out + ".tmp", "wb") as f:
    f.write(line)
os.replace(out + ".tmp", out)
"""


def write_atomic(name, data):
    with open(name + ".tmp", "wb") as f:
        f.write(data)
    os.replace(name + ".tmp", name)


def browser_peer_turn(agent, path):
    import socket
    import subprocess
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(15)
    s.connect(path)
    lines = s.makefile("rb")

    def ask(request_id):
        s.sendall((json.dumps({"type": "browser", "id": request_id, "agentID": agent, "request": {"action": "reload"}}) + "\n").encode())
        return lines.readline()

    s.sendall((json.dumps({"type": "helloBrowser", "agentID": agent}) + "\n").encode())
    write_atomic("browser-self-1.reply", ask(1))
    subprocess.run([sys.executable, "-c", BROWSER_CHILD, agent, path, os.path.join(os.getcwd(), "browser-child.reply")], timeout=60)
    wait_for_file("browser-go")
    write_atomic("browser-self-2.reply", ask(2))
    s.close()
    emit({"type": "agent_settled"})


# The extension traffic of `who` ("own": this process, "child": a process it starts) on the extension
# socket, for two agents: the panes extension's hello, a status, a notify and three requests
# (listPanes, listAgents, coordinateAgent), each answered line read, and the children extension's
# hello. Also run as a child's script (SPEAK_CHILD), so it stands alone.
SPEAK_SOURCE = r"""
import json, socket

def speak(path, who, mine, other, keep=None):
    result = {}
    for label, agent in (("self", mine), ("other", other)):
        cell = result[label] = {}
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(15)
        s.connect(path)
        lines = s.makefile("rb")
        def send(message, s=s):
            s.sendall((json.dumps(message) + "\n").encode())
        send({"type": "helloAgent", "agentID": agent})
        send({"type": "setAgentStatus", "agentID": agent, "status": "working" if who == "own" and label == "self" else "blocked"})
        send({"type": "notify", "agentID": agent, "title": who + "-as-" + label, "body": ""})
        requests = [
            {"type": "listPanes", "agentID": agent},
            {"type": "listAgents", "agentID": agent},
            {"type": "coordinateAgent", "agentID": agent, "targetAgentID": other if label == "self" else mine,
             "request": {"operation": "status"}},
        ]
        for n, request in enumerate(requests, 1):
            send(dict(request, id=n))
            try:
                cell[request["type"]] = lines.readline().decode()
            except OSError as e:
                cell[request["type"]] = "stub-error: " + str(e)
        children = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        children.settimeout(15)
        children.connect(path)
        children.sendall((json.dumps({"type": "helloChildren", "agentID": agent}) + "\n").encode())
        if keep is not None and label == "self":
            keep.update(panes=s, lines=lines, children=children)
    return result
"""

SPEAK_CHILD = SPEAK_SOURCE + r"""
import os, sys
path, mine, other, out = sys.argv[1:5]
with open(out + ".tmp", "w") as f:
    json.dump(speak(path, "child", mine, other), f)
os.replace(out + ".tmp", out)
"""


def speak_turn(label, mine, other, path, with_child=True):
    import subprocess
    namespace = {}
    exec(SPEAK_SOURCE, namespace)
    kept = {}
    result = {"own": namespace["speak"](path, "own", mine, other, kept)}
    if with_child:
        child_out = os.path.join(os.getcwd(), f"speak-{label}-child.json")
        subprocess.run([sys.executable, "-c", SPEAK_CHILD, path, mine, other, child_out], timeout=60)
        with open(child_out) as f:
            result["child"] = json.load(f)
    write_atomic(f"speak-{label}.json", json.dumps(result).encode())
    if not with_child:
        return
    # Nothing the child said displaced the real connections: a push still reaches this process's
    # panes connection, and its children connection is still open.
    wait_for_file(f"speak-{label}-go")
    after = {"push": None, "children": "open"}
    kept["panes"].settimeout(5)
    try:
        after["push"] = kept["lines"].readline().decode() or None
    except OSError:
        pass
    kept["children"].settimeout(0.5)
    try:
        if kept["children"].recv(1) == b"":
            after["children"] = "closed"
    except OSError:
        pass
    write_atomic(f"speak-{label}-after.json", json.dumps(after).encode())


def speak_at_start():
    # A pi that speaks as soon as the test opens its gate, before it serves: an extension connects
    # while the app is still binding the pi to its pane. "<label> <mine> <other> <socket>".
    label, mine, other, path = os.environ["STUB_PI_SPEAK"].split(" ", 3)
    wait_for_file(os.environ["STUB_PI_SPEAK_GATE"], timeout=60.0)
    speak_turn(label, mine, other, path, with_child=False)


def speak_from_config(config):
    # A pi launched the way the app launches it gets no test env: `stub-pi-startup.json` says
    # {"speak": {"label": "app", "other": "<agent id>", "gate": "speak-gate", "socket": "<path>"}}. The
    # agent it speaks for is the one the app launched it for ($SHEPHERD_AGENT_ID); the socket is
    # $SHEPHERD_SOCKET unless the file names another (a test server's is not the app's).
    wait_for_file(config.get("gate", "speak-gate"), timeout=60.0)
    speak_turn(config.get("label", "start"), os.environ.get("SHEPHERD_AGENT_ID", ""), config["other"],
               config.get("socket") or os.environ.get("SHEPHERD_SOCKET", ""), with_child=False)


def ui(method, **fields):
    emit({"type": "extension_ui_request", "id": f"ui-{method}", "method": method, **fields})


# Opt-in goal-controller boundary fixture: real widget events and immediate commands, no
# evaluator or automatic worker turns. Runtime behavior is tested against pinned pi separately.
goal_file = os.environ.get("STUB_PI_GOAL_FILE")
goal = None
goals_enabled = os.environ.get("SHEPHERD_GOALS_ENABLED", "1" if goal_file else "0") == "1"


def publish_goal():
    ui("setWidget", widgetKey="shepherd.goal",
       widgetLines=["SHEPHERD_GOAL:" + json.dumps(goal)] if goals_enabled else None)


def watch_goal():
    global goal
    previous = None
    while True:
        try:
            with open(goal_file) as f:
                text = f.read()
            if text != previous:
                value = json.loads(text)
                previous = text
                goal = value
                publish_goal()
        except (OSError, ValueError):
            pass
        time.sleep(0.02)


if goal_file:
    COMMANDS.extend({"name": name, "source": "extension"} for name in ("goal", "shepherd-goal"))
    threading.Thread(target=watch_goal, daemon=True).start()


def record_launch():
    # The engine wrapper StubPi installs names the file: argv, cwd and environment, one line.
    path = os.environ.get("STUB_PI_LAUNCH_LOG")
    if not path:
        return
    env = {k: v for k, v in os.environ.items() if k != "STUB_PI_LAUNCH_LOG"}
    line = json.dumps({"argv": sys.argv[1:], "cwd": os.getcwd(), "env": env, "extensions": configured_extensions()}) + "\n"
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        os.write(fd, line.encode("utf-8"))
    finally:
        os.close(fd)


def configured_extensions():
    home = os.environ.get("PI_CODING_AGENT_DIR")
    try:
        with open(os.path.join(home, "settings.json")) as f:
            settings = json.load(f)
    except (TypeError, OSError, ValueError):
        return []
    entries = settings.get("extensions") if isinstance(settings, dict) else None
    return [e for e in entries or [] if isinstance(e, str) and e[:1] not in "!+-"]


def load_extensions():
    for path in configured_extensions():
        file = path
        if os.path.isdir(path):
            file = next((os.path.join(path, n) for n in ("index.ts", "index.js") if os.path.isfile(os.path.join(path, n))), path)
        try:
            with open(file) as f:
                text = f.read()
        except OSError:
            continue
        found = re.search(r"throw new Error\((['\"])(.*?)\1\)", text)
        if found:
            failure = found.group(2)
            sys.stderr.write(f'\x1b[31mError: Failed to load extension "{path}": Failed to load extension: {failure}\x1b[39m\n')
            sys.stderr.write("\x1b[33mRun with --no-extensions to start without extensions.\x1b[39m\n")
            sys.stderr.flush()
            sys.exit(1)


def startup():
    try:
        with open("stub-pi-startup.json") as f:
            config = json.load(f)
    except (OSError, ValueError):
        config = {}
    # "model": fields of the starting model, as $STUB_PI_MODEL (for a pi launched the way the app does).
    if isinstance(config.get("model"), dict):
        STATE["model"] = dict(STATE["model"], **config["model"])
    if isinstance(config.get("speak"), dict) and not os.environ.get("STUB_PI_SPEAK"):
        threading.Thread(target=speak_from_config, args=(config["speak"],), daemon=True).start()
    delay = os.environ.get("STUB_PI_STARTUP_DELAY") or config.get("delay")
    gate = os.environ.get("STUB_PI_STARTUP_GATE") or config.get("gate")
    code = os.environ.get("STUB_PI_STARTUP_EXIT") or config.get("exit")
    new_session = os.environ.get("STUB_PI_STARTUP_NEW_SESSION") or config.get("newSession")
    message = os.environ.get("STUB_PI_STARTUP_STDERR") or config.get("stderr") or "stub-pi: failed to start"
    if delay:
        time.sleep(float(delay))
    if gate:
        wait_for_file(gate, timeout=60.0)
    if new_session:
        args = sys.argv[1:]
        session_id = args[args.index("--session-id") + 1] if "--session-id" in args[:-1] else "stub-session"
        sys.stderr.write(f"\x1b[33mWarning: No project session found with id '{session_id}'; "
                         "creating a new session with that id.\x1b[39m\n")
        sys.stderr.flush()
    load_extensions()
    if (os.environ.get("STUB_PI_STARTUP_REQUIRE_AUTH") or config.get("requireAuth")) and not signed_in():
        code, message = 1, "No models available."
    if code is not None:
        sys.stderr.write(message.rstrip("\n") + "\n")
        sys.stderr.flush()
        sys.exit(int(code))


def signed_in():
    home = os.environ.get("PI_CODING_AGENT_DIR")
    try:
        with open(os.path.join(home, "auth.json")) as f:
            auth = json.load(f)
    except (TypeError, OSError, ValueError):
        return False
    return isinstance(auth, dict) and len(auth) > 0


record_launch()
if os.environ.get("STUB_PI_SPEAK"):
    threading.Thread(target=speak_at_start, daemon=True).start()
startup()

pending_ui = None
turn_thread = None
# An abort ends a "slow" turn as far as pi's state goes (its thread still waits for its files).
turn_aborted = False
stale_history = None
held_history_request = None
fail_switched_history = False

for raw in sys.stdin.buffer:
    line = raw.rstrip(b"\n").rstrip(b"\r")
    if not line:
        continue
    if log_path:
        with open(log_path, "ab") as f:
            f.write(line + b"\n")
    try:
        cmd = json.loads(line)
    except ValueError as e:
        emit({"type": "response", "command": "parse", "success": False, "error": f"Failed to parse command: {e}"})
        continue
    if cmd.get("type") == "prompt":
        log_tier("prompt", cmd.get("message"))
    t = cmd.get("type")
    streaming = RUN["active"] or (turn_thread is not None and turn_thread.is_alive() and not turn_aborted)
    if t == "get_state":
        with QUEUE_LOCK:
            pending_count = len(steering) + len(follow_up)
        respond(cmd, t, data=dict(STATE, isStreaming=streaming, pendingMessageCount=pending_count))
        if held_history_request is not None:
            respond(held_history_request, "get_messages", data={"messages": stale_history})
            held_history_request = None
            stale_history = None
    elif t == "get_messages":
        if stale_history is not None:
            held_history_request = cmd
        elif fail_switched_history:
            fail_switched_history = False
            respond(cmd, t, success=False, error="Switched history unavailable")
        else:
            respond(cmd, t, data={"messages": MESSAGES})
    elif t == "get_commands":
        # STUB_PI_PROMPT_TEMPLATE: the file fix-tests came from, as pi reports a template's source.
        template = os.environ.get("STUB_PI_PROMPT_TEMPLATE")
        commands = [dict(c, sourceInfo={"path": template}) if template and c["name"] == "fix-tests" else c for c in COMMANDS]
        respond(cmd, t, data={"commands": commands})
    elif t == "get_session_stats":
        respond(cmd, t, data=STATS)
    elif t == "compact":
        result = compaction("manual", cmd.get("customInstructions"))
        if result is None:
            respond(cmd, t, success=False, error="Nothing to compact (session too small)")
        else:
            respond(cmd, t, data=result)
    elif t == "set_model":
        apis = json.loads(os.environ.get("STUB_PI_MODEL_APIS") or "{}")
        key = f"{cmd.get('provider')}/{cmd.get('modelId')}"
        if cmd.get("provider") != "anthropic" and key not in apis:
            respond(cmd, t, success=False, error=f"Model not found: {key}")
        else:
            STATE["model"] = dict(STATE["model"], id=cmd.get("modelId"), provider=cmd.get("provider"),
                                  api=apis.get(key, STATE["model"].get("api")))
            respond(cmd, t, data=STATE["model"])
    elif t == "get_available_models":
        respond(cmd, t, data={"models": [
            {"provider": "anthropic", "id": "claude-opus-4-5", "api": "anthropic-messages", "contextWindow": 200000, "reasoning": True},
            {"provider": "openai", "id": "gpt-5", "api": "openai-responses", "contextWindow": 400000, "reasoning": True,
             "thinkingLevelMap": {"minimal": None, "xhigh": "xhigh"}},
        ]})
    elif t == "get_available_thinking_levels":
        spec = os.environ.get("STUB_PI_THINKING_LEVELS", "off,minimal,low,medium,high")
        if spec == "unsupported":
            respond(cmd, t, success=False, error=f"Unknown command: {t}")
        else:
            if spec.startswith("{"):
                table = json.loads(spec)
                levels = table.get(STATE["model"]["id"], table.get("*", []))
            else:
                levels = [level for level in spec.split(",") if level]
            respond(cmd, t, data={"levels": levels})
    elif t == "set_thinking_level":
        STATE["thinkingLevel"] = cmd.get("level")
        respond(cmd, t)
    elif t == "abort" and os.path.exists("refuse-abort"):
        respond(cmd, t, success=False, error="refused by the stub")
    elif t == "abort":
        if RUN["active"]:
            RUN["abort"].set()
            RUN["thread"].join(timeout=30)
            RUN["abort"].clear()
            respond(cmd, t)
        else:
            turn_aborted = True
            respond(cmd, t)
            emit({"type": "agent_end", "messages": [], "willRetry": False})
            emit({"type": "agent_settled"})
    elif t == "clear_queue":
        if os.path.exists("clear-gate"):
            wait_for_file("clear-go")
        with QUEUE_LOCK:
            raced = [item for item in steering if "raced" in item[0]]
            cleared = {"steering": [t for t, _, _ in steering if "raced" not in t], "followUp": [t for t, _, _ in follow_up]}
            steering[:] = raced
            follow_up.clear()
        queue_update()
        respond(cmd, t, data=cleared)
    elif t == "extension_ui_response" and QUESTION["id"] is not None and cmd.get("id") == QUESTION["id"]:
        QUESTION["response"] = cmd
        QUESTION["answered"].set()
    elif t == "extension_ui_response":
        if pending_ui is not None and cmd.get("id") == pending_ui:
            if pending_ui == "uuid-4":
                emit({"type": "tool_execution_end", "toolCallId": "call_ask", "toolName": "ask_user",
                      "result": {"content": [{"type": "text", "text": "answered"}]}, "isError": False})
            pending_ui = None
            if "value" in cmd:
                text = cmd["value"]
            elif cmd.get("cancelled"):
                text = "cancelled"
            else:
                text = "confirmed" if cmd.get("confirmed") else "declined"
            emit({"type": "agent_end", "messages": [{"role": "assistant", "content": [
                {"type": "text", "text": text}]}],
                "willRetry": False})
            emit({"type": "agent_settled"})
    elif t == "prompt":
        message = cmd.get("message", "")
        if message == "hang":
            continue
        if message == "die":
            sys.stderr.write("stub-pi: dying\n")
            sys.stderr.flush()
            sys.exit(3)
        if "refuse" in message:
            respond(cmd, t, success=False, error="refused by the stub")
            continue
        if COMPACTING.is_set() and not message.startswith("/"):
            respond(cmd, t, success=False,
                    error="Cannot submit a prompt while compaction is in progress. Wait for compaction to finish and retry.")
            continue
        if (goal_file or os.environ.get("SHEPHERD_EXT_GOAL") == "1") and message.startswith("/shepherd-goal "):
            control = json.loads(message[len("/shepherd-goal "):])
            action = control["action"]
            if action == "configure":
                goals_enabled = control["enabled"]
                if not goals_enabled and goal and goal["state"] in ("working", "checking"):
                    goal = dict(goal, state="paused", revision=goal.get("revision", 1) + 1)
                publish_goal()
            if goal and action in ("pause", "interrupt") and goal["state"] in ("working", "checking"):
                goal = dict(goal, state="paused", revision=goal.get("revision", 1) + 1)
                publish_goal()
            if action == "status":
                publish_goal()
            respond(cmd, t)
            continue
        if message.startswith("/session-name"):
            # An extension command, as pi runs one: at once, even while streaming, with no turn and no
            # message of its own. Its first word says what it answers with (see the header).
            mode, _, what = message[len("/session-name"):].strip().partition(" ")
            if mode == "fail":
                emit({"type": "extension_error", "extensionPath": "command:session-name", "event": "command", "error": what or "boom"})
            elif mode in ("info", "warning", "error"):
                ui("notify", message=what, notifyType=mode)
            elif mode == "report":
                # pi.sendMessage({display: true}, {triggerTurn: false}): persisted at once, announced
                # by message events, and no turn follows.
                MESSAGES.append({"role": "custom", "customType": "stub-report", "display": True, "content": what, "timestamp": now_ms()})
                STATE["messageCount"] = len(MESSAGES)
                emit({"type": "message_start", "message": MESSAGES[-1]})
                emit({"type": "message_end", "message": MESSAGES[-1]})
            respond(cmd, t)
            if mode == "late":
                ui("notify", message=what, notifyType="info")
            continue
        if streaming:
            behavior = cmd.get("streamingBehavior")
            if behavior not in ("steer", "followUp"):
                respond(cmd, t, success=False,
                        error="Agent is already processing. Specify streamingBehavior ('steer' or 'followUp') to queue the message.")
                continue
            with QUEUE_LOCK:
                (steering if behavior == "steer" else follow_up).append((message, cmd.get("images") or [], now_ms()))
            queue_update()
            respond(cmd, t)
            continue
        if message.startswith("/shepherd-retry"):
            # pi runs an extension command at once, even while streaming; the command refuses then.
            respond(cmd, t)
            try:
                at = int(message.split(" ", 1)[1])
            except (IndexError, ValueError):
                at = None
            original = None if streaming or at is None else retry_command(at)
            if original is None:
                ui("notify", message="That message is no longer in this conversation." if not streaming
                   else "Retry once the agent has stopped.", notifyType="warning")
                continue
            again = dict(original, timestamp=max(now_ms(), original["timestamp"] + 1))
            turn_aborted = False
            turn_thread = threading.Thread(target=flaky_turn, args=(again,), daemon=True)
            turn_thread.start()
            continue
        if re.search(r"tools:\d+", message):
            RUN["active"] = True
            respond(cmd, t)
            RUN["thread"] = threading.Thread(target=agent_run, args=((message, cmd.get("images") or [], now_ms()),), daemon=True)
            RUN["thread"].start()
            continue
        if message == "toolcall":
            RUN["active"] = True
            respond(cmd, t)
            RUN["thread"] = threading.Thread(target=toolcall_turn, args=(message,), daemon=True)
            RUN["thread"].start()
            continue
        respond(cmd, t)
        if log_path and cmd.get("images"):
            with open(log_path, "ab") as f:
                f.write(json.dumps({"type": "stub-images", "count": len(cmd["images"]),
                                    "mimeTypes": [i.get("mimeType") for i in cmd["images"]]}).encode() + b"\n")
        if message == "ask":
            pending_ui = "uuid-2"
            emit({"type": "agent_start"})
            emit({"type": "extension_ui_request", "id": "uuid-2", "method": "confirm",
                  "title": "Clear session?", "message": "All messages will be lost.", "timeout": 60000})
        elif message in ("ask-short", "ask-long"):
            pending_ui = "uuid-4"
            args = {"question": "Retention: 30 days or 13 months?", "options": ["30 days", "13 months"]}
            if message == "ask-short":
                args["short"] = "  retention?\n"
            emit({"type": "agent_start"})
            emit({"type": "tool_execution_start", "toolCallId": "call_ask", "toolName": "ask_user", "args": args})
            emit({"type": "extension_ui_request", "id": "uuid-4", "method": "select",
                  "title": "Retention: 30 days or 13 months?", "options": ["30 days", "13 months"]})
        elif message == "select":
            pending_ui = "uuid-3"
            emit({"type": "agent_start"})
            emit({"type": "extension_ui_request", "id": "uuid-3", "method": "select",
                  "title": "Pick one", "options": ["Allow", "Deny"]})
        elif message in ("question", "question-timeout", "question-timeout-late-host"):
            turn_thread = threading.Thread(target=question_turn, args=(message,), daemon=True)
            turn_thread.start()
        elif message == "ask-choice":
            pending_ui = "uuid-7"
            emit({"type": "agent_start"})
            emit({"type": "extension_ui_request", "id": "uuid-7", "method": "select",
                  "title": "How should I handle the uncommitted edits?",
                  "options": ["Compare first (Recommended)\nDiff them against main; nothing is overwritten.",
                              "Leave them alone\nDeploy from a clean checkout beside it.",
                              "Discard them\nReset the checkout to main."]})
        elif message == "ask-input":
            pending_ui = "uuid-5"
            emit({"type": "agent_start"})
            emit({"type": "extension_ui_request", "id": "uuid-5", "method": "input",
                  "title": "Which branch should I deploy?", "placeholder": "main"})
        elif message == "ask-editor":
            pending_ui = "uuid-6"
            emit({"type": "agent_start"})
            emit({"type": "extension_ui_request", "id": "uuid-6", "method": "editor",
                  "title": "Edit the commit message", "prefill": "fix: typo"})
        elif message == "slow":
            # Real pi keeps reading stdin during a turn; the paused turn must too.
            turn_aborted = False
            turn_thread = threading.Thread(target=streaming_turn, args=(message, True), daemon=True)
            turn_thread.start()
        elif message == "stream":
            turn_thread = threading.Thread(target=paced_turn, args=(message,), daemon=True)
            turn_thread.start()
        elif message.startswith("flaky"):
            turn_aborted = False
            turn_thread = threading.Thread(target=flaky_turn, args=(user_message(message, cmd.get("images") or [], now_ms()),),
                                           daemon=True)
            turn_thread.start()
        elif message == "provider-error":
            turn_aborted = False
            turn_thread = threading.Thread(target=failed_turn, args=(message,), daemon=True)
            turn_thread.start()
        elif message == "widgets":
            ui("setStatus", statusKey="build", statusText="\x1b[32mgreen\x1b[0m ok")
            ui("setWidget", widgetKey="w", widgetLines=["\x1b[1mBold\x1b[22m line", "\x1b]8;;http://x\x1b\\link\x1b]8;;\x1b\\"],
               widgetPlacement="aboveEditor")
            ui("notify", message="\x1b[31mred\x1b[0m alert", notifyType="warning")
            ui("setTitle", title="ignored")
            ui("setStatus", statusKey="huge", statusText="x" * 5000)
            ui("setWidget", widgetKey="machine", widgetLines=['PI_SUBAGENT_ASYNC_JSON:{"kind":"snapshot"}'])
            emit({"type": "agent_settled"})
        elif message.startswith("browser-peer "):
            _, browser_agent, browser_socket = message.split(" ", 2)
            threading.Thread(target=browser_peer_turn, args=(browser_agent, browser_socket), daemon=True).start()
        elif message.startswith("speak "):
            _, speak_label, speak_mine, speak_other, speak_socket = message.split(" ", 4)
            threading.Thread(target=speak_turn, args=(speak_label, speak_mine, speak_other, speak_socket), daemon=True).start()
        elif message == "widgets-clear":
            ui("setStatus", statusKey="build")
            ui("setWidget", widgetKey="w")
            emit({"type": "agent_settled"})
        elif message == "subagent-noise":
            # What pi-subagents leaves in the transcript: a tool call, its result, and a
            # model-only custom message with the JSON completion report.
            MESSAGES.append({"role": "user", "content": "spawn one"})
            MESSAGES.append({"role": "assistant", "content": [
                {"type": "text", "text": "Spawning."},
                {"type": "toolCall", "id": "call_1", "name": "subagent", "arguments": {"action": "list"}}],
                "stopReason": "toolUse"})
            MESSAGES.append({"role": "toolResult", "toolCallId": "call_1", "toolName": "subagent",
                             "content": [{"type": "text", "text": "Executable agents: worker"}], "isError": False})
            MESSAGES.append({"role": "custom", "customType": "pi-subagents.completed", "display": False,
                             "content": [{"type": "text", "text": "Background task completed: {\"ok\":true}"}]})
            MESSAGES.append({"role": "custom", "customType": "note", "display": True,
                             "content": [{"type": "text", "text": "A note the user should see"}]})
            # Shepherd's own child report: displayed in the TUI, owned by the cards in RPC threads.
            MESSAGES.append({"role": "custom", "customType": "shepherd-child", "display": True,
                             "content": [{"type": "text", "text": "Child native-1 (worker): complete"}]})
            MESSAGES.append({"role": "assistant", "content": [{"type": "text", "text": "Done."}], "stopReason": "stop"})
            STATE["messageCount"] = len(MESSAGES)
            emit({"type": "agent_start"})
            emit({"type": "agent_end", "messages": [], "willRetry": False})
            emit({"type": "agent_settled"})
        elif message == "context":
            context_session()
            emit({"type": "agent_start"})
            emit({"type": "agent_end", "messages": [], "willRetry": False})
            emit({"type": "agent_settled"})
        elif message == "fill-context":
            STATS["contextUsage"] = {"tokens": 178000, "contextWindow": 200000, "percent": 89}
            emit({"type": "agent_start"})
            emit({"type": "agent_end", "messages": [], "willRetry": False})
            emit({"type": "agent_settled"})
        elif message == "compact-abort":
            emit({"type": "compaction_start", "reason": "manual"})
            emit({"type": "compaction_end", "reason": "manual", "aborted": True, "willRetry": False})
            emit({"type": "agent_settled"})
        elif message == "fill":
            for i in range(120):
                MESSAGES.append({"role": "user", "content": f"filler {i}"})
            STATE["messageCount"] = len(MESSAGES)
            emit({"type": "agent_start"})
            emit({"type": "agent_end", "messages": [], "willRetry": False})
            emit({"type": "agent_settled"})
        elif message == "select-newsession":
            emit({"type": "extension_ui_request", "id": "uuid-8", "method": "select",
                  "title": "Pick one", "options": ["Allow", "Deny"]})
            STATE["sessionId"] = "stub-session-2"
            del MESSAGES[:]
            STATE["messageCount"] = 0
            emit({"type": "agent_start"})
            emit({"type": "agent_end", "messages": [], "willRetry": False})
            emit({"type": "agent_settled"})
        elif message in ("newsession", "resume-nonempty", "resume-stale-history", "resume-history-failure"):
            if message == "resume-history-failure":
                # The agent-end fetch predates get_state. Hold it behind the changed identity,
                # then fail the fresh get_messages issued by the host for that generation.
                fail_switched_history = True
            if message in ("resume-stale-history", "resume-history-failure"):
                stale_history = list(MESSAGES)
            if goal_file:
                goal = None
                publish_goal()
            STATE["sessionId"] = "stub-session-2"
            del MESSAGES[:]
            if message != "newsession":
                MESSAGES.extend([
                    {"role": "user", "content": "resumed question"},
                    {"role": "assistant", "content": [{"type": "text", "text": "resumed answer"}]},
                ])
            STATE["messageCount"] = len(MESSAGES)
            emit({"type": "agent_start"})
            emit({"type": "agent_end", "messages": [], "willRetry": False})
            emit({"type": "agent_settled"})
        elif message == "ask-closed-input":
            os.close(0)
            emit({"type": "extension_ui_request", "id": "closed-input", "method": "confirm", "title": "Keep this question?"})
            time.sleep(60)
        elif message == "big":
            emit({"type": "extension_ui_request", "id": "uuid-9", "method": "set_editor_text",
                  "text": "x" * (1_100_000)})
            emit({"type": "agent_settled"})
        elif message == "stderr":
            sys.stderr.write("stub-pi: warning line\n")
            sys.stderr.flush()
            emit({"type": "agent_settled"})
        else:
            streaming_turn(message)
    else:
        respond(cmd, t or "unknown", success=False, error=f"Unknown command: {t}")
