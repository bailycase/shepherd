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
  "widgets"      emits setStatus/setWidget/notify/setTitle (with ANSI colour)
  "widgets-clear" clears the status and widget from "widgets"
  "select" emits a select extension_ui_request (no timeout) and waits
  "fill"   appends 120 history messages, then agent_start/agent_end
  "newsession" switches sessionId, then agent_start/agent_end
  other    a full streaming turn with a U+2028 inside a delta

set_model / set_thinking_level update STATE (unknown provider -> error).
A prompt carrying images also logs {"type": "stub-images", "count": N}.

Every stdin line is appended to $STUB_PI_LOG when set, so tests can assert
on what the client actually wrote.
"""
import json
import os
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


def ui(method, **fields):
    emit({"type": "extension_ui_request", "id": f"ui-{method}", "method": method, **fields})


pending_ui = None
turn_thread = None

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
    if t == "get_state":
        respond(cmd, t, data=STATE)
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
    elif t == "set_thinking_level":
        STATE["thinkingLevel"] = cmd.get("level")
        respond(cmd, t)
    elif t == "abort":
        respond(cmd, t)
        emit({"type": "agent_end", "messages": [], "willRetry": False})
        emit({"type": "agent_settled"})
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
        respond(cmd, t)
        if log_path and cmd.get("images"):
            with open(log_path, "ab") as f:
                f.write(json.dumps({"type": "stub-images", "count": len(cmd["images"]),
                                    "mimeTypes": [i.get("mimeType") for i in cmd["images"]]}).encode() + b"\n")
        if turn_thread is not None and turn_thread.is_alive():
            # A steer/followUp during a running turn is accepted and queued; the
            # stub simply drops it after acknowledging, like a queue that never drains.
            continue
        if message == "ask":
            pending_ui = "uuid-2"
            emit({"type": "agent_start"})
            emit({"type": "extension_ui_request", "id": "uuid-2", "method": "confirm",
                  "title": "Clear session?", "message": "All messages will be lost.", "timeout": 5000})
        elif message == "select":
            pending_ui = "uuid-3"
            emit({"type": "agent_start"})
            emit({"type": "extension_ui_request", "id": "uuid-3", "method": "select",
                  "title": "Pick one", "options": ["Allow", "Deny"]})
        elif message == "slow":
            # Real pi keeps reading stdin during a turn; the paused turn must too.
            turn_thread = threading.Thread(target=streaming_turn, args=(message, True), daemon=True)
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
