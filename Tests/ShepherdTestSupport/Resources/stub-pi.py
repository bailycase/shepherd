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
  "widgets"      emits setStatus/setWidget/notify/setTitle (with ANSI colour)
  "widgets-clear" clears the status and widget from "widgets"
  "select" emits a select extension_ui_request (no timeout) and waits
  "fill"   appends 120 history messages, then agent_start/agent_end
  "newsession" switches sessionId, then agent_start/agent_end
  "refuse" answers the prompt with success: false (pi refusing it)
  "provider-error" a turn whose reply fails ("529 overloaded"), once the file `fail-turn`
           appears in the cwd
  "tools:N" a run that behaves like pi's agent loop (below)
  other    a full streaming turn with a U+2028 inside a delta

pi's queues, as pi 0.87.1 behaves (docs/rpc-commands.md, and transcripts of the real thing):
  - While a run streams, `prompt` needs `streamingBehavior`, else pi refuses it ("Agent is
    already processing..."). `steer` / `followUp` append to that queue, stamped when queued,
    then pi emits `queue_update` with both queues' text, then answers the prompt.
  - A "tools:N" run: each model call reads the newest user message; while it has asked for N
    tool calls and made fewer, it makes one (a bash call that waits for the file `tool-<k>`
    in the cwd, k counting every call this stub makes), else it replies "Reply to <text>".
    Steering is taken one at a time: at the start of the run and after each tool batch or
    reply. A message leaves the queue (`queue_update`) just before its user message_start.
    Follow-ups are taken one at a time once the run would stop, within the same run.
    "hold-settle" in the first prompt holds the run between its last look at the queues and
    agent_end until the file `settle` appears (a steer sent then is stranded, as in pi).
  - `abort` during a "tools:N" run fails the running call ("Command aborted"), delivers the
    next steer, ends with an empty error reply, then agent_end, agent_settled, and only then
    the abort response. Follow-ups stay queued (pi does not clear its queue on abort).
  - `clear_queue` empties both queues, emits an empty `queue_update`, and answers with their
    text. A steer with "raced" in it stays queued and unreported, as when pi reads a steer
    (its tool batch ended) just before a `clear_queue` arrives: it still lands.
  - Idle, a prompt with a streamingBehavior is a plain prompt.
$STUB_PI_MESSAGES_FILE, when set, loads the history from that file at start and saves it
after every "tools:N" run, like pi resuming its session file.

set_model / set_thinking_level update STATE (unknown provider -> error).
get_available_thinking_levels answers pi's reasoning set (off, minimal, low, medium, high),
or $STUB_PI_THINKING_LEVELS: a comma list for every model, or a JSON object from model id to
its list ("*" for the rest); "unsupported" answers as a pi without the command.
A prompt carrying images also logs {"type": "stub-images", "count": N}.

$STUB_PI_HISTORY_BYTES seeds that many bytes of prior history (see below).

Startup, like a pi that takes a while to boot (or fails to), before stdin is read:
  $STUB_PI_STARTUP_DELAY  seconds to wait
  $STUB_PI_STARTUP_GATE   a file in the cwd to wait for (up to 60 s)
  $STUB_PI_STARTUP_EXIT   exit with this code instead of serving
A pi launched the way the app launches it gets no test env, so `stub-pi-startup.json` in the
cwd ({"delay": 1.5, "gate": "release-pi", "exit": 127}) sets the same.

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
    "model": {"id": "claude-sonnet-4-20250514", "name": "Claude Sonnet 4", "provider": "anthropic",
              "api": "anthropic-messages", "reasoning": True, "input": ["text", "image"],
              "contextWindow": 200000, "maxTokens": 16384},
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
    emit({"type": "compaction_start", "reason": "manual"})
    # Like pi, message_end persisted these; get_messages now returns them.
    MESSAGES.extend([{"role": "user", "content": prompt}, final, tool_result])
    STATE["messageCount"] = len(MESSAGES)
    emit({"type": "agent_end", "messages": [final], "willRetry": False})
    # CRLF is tolerated by the reader.
    emit({"type": "agent_settled"}, terminator=b"\r\n")


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


def ui(method, **fields):
    emit({"type": "extension_ui_request", "id": f"ui-{method}", "method": method, **fields})


def startup():
    try:
        with open("stub-pi-startup.json") as f:
            config = json.load(f)
    except (OSError, ValueError):
        config = {}
    delay = os.environ.get("STUB_PI_STARTUP_DELAY") or config.get("delay")
    gate = os.environ.get("STUB_PI_STARTUP_GATE") or config.get("gate")
    code = os.environ.get("STUB_PI_STARTUP_EXIT") or config.get("exit")
    if delay:
        time.sleep(float(delay))
    if gate:
        wait_for_file(gate, timeout=60.0)
    if code is not None:
        sys.stderr.write("stub-pi: failed to start\n")
        sys.stderr.flush()
        sys.exit(int(code))


startup()

pending_ui = None
turn_thread = None
# An abort ends a "slow" turn as far as pi's state goes (its thread still waits for its files).
turn_aborted = False

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
    t = cmd.get("type")
    streaming = RUN["active"] or (turn_thread is not None and turn_thread.is_alive() and not turn_aborted)
    if t == "get_state":
        with QUEUE_LOCK:
            pending_count = len(steering) + len(follow_up)
        respond(cmd, t, data=dict(STATE, isStreaming=streaming, pendingMessageCount=pending_count))
    elif t == "get_messages":
        respond(cmd, t, data={"messages": MESSAGES})
    elif t == "get_commands":
        respond(cmd, t, data={"commands": COMMANDS})
    elif t == "get_session_stats":
        respond(cmd, t, data=STATS)
    elif t == "set_model":
        if cmd.get("provider") != "anthropic":
            respond(cmd, t, success=False, error=f"Model not found: {cmd.get('provider')}/{cmd.get('modelId')}")
        else:
            STATE["model"] = dict(STATE["model"], id=cmd.get("modelId"), provider=cmd.get("provider"))
            respond(cmd, t, data=STATE["model"])
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
        with QUEUE_LOCK:
            raced = [item for item in steering if "raced" in item[0]]
            cleared = {"steering": [t for t, _, _ in steering if "raced" not in t], "followUp": [t for t, _, _ in follow_up]}
            steering[:] = raced
            follow_up.clear()
        queue_update()
        respond(cmd, t, data=cleared)
    elif t == "extension_ui_response":
        if pending_ui is not None and cmd.get("id") == pending_ui:
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
        if re.search(r"tools:\d+", message):
            RUN["active"] = True
            respond(cmd, t)
            RUN["thread"] = threading.Thread(target=agent_run, args=((message, cmd.get("images") or [], now_ms()),), daemon=True)
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
        elif message == "select":
            pending_ui = "uuid-3"
            emit({"type": "agent_start"})
            emit({"type": "extension_ui_request", "id": "uuid-3", "method": "select",
                  "title": "Pick one", "options": ["Allow", "Deny"]})
        elif message == "slow":
            # Real pi keeps reading stdin during a turn; the paused turn must too.
            turn_aborted = False
            turn_thread = threading.Thread(target=streaming_turn, args=(message, True), daemon=True)
            turn_thread.start()
        elif message == "stream":
            turn_thread = threading.Thread(target=paced_turn, args=(message,), daemon=True)
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
        elif message == "fill":
            for i in range(120):
                MESSAGES.append({"role": "user", "content": f"filler {i}"})
            STATE["messageCount"] = len(MESSAGES)
            emit({"type": "agent_start"})
            emit({"type": "agent_end", "messages": [], "willRetry": False})
            emit({"type": "agent_settled"})
        elif message == "newsession":
            STATE["sessionId"] = "stub-session-2"
            del MESSAGES[:]
            STATE["messageCount"] = 0
            emit({"type": "agent_start"})
            emit({"type": "agent_end", "messages": [], "willRetry": False})
            emit({"type": "agent_settled"})
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
