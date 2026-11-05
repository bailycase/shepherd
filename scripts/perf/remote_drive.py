#!/usr/bin/env python3
"""Drive a Shepherd app over its remote listener: add a space, create N agents with a prompt.
Usage: remote_drive.py <port> <remote-token file> <space path> <count>. Used by stress.sh."""
import json, socket, sys, time
port, token_path, space_path, count = int(sys.argv[1]), sys.argv[2], sys.argv[3], int(sys.argv[4])
token = open(token_path).read().strip()
s = socket.create_connection(("127.0.0.1", port)); f = s.makefile("rwb")
rid = [0]
def send(obj):
    rid[0] += 1; obj["id"] = rid[0]
    f.write((json.dumps(obj) + "\n").encode()); f.flush(); return rid[0]
def wait(pred, timeout=30):
    end = time.time() + timeout
    while time.time() < end:
        line = f.readline()
        if not line: raise SystemExit("closed")
        m = json.loads(line)
        if m.get("type") == "error": print("error:", m, file=sys.stderr)
        r = pred(m)
        if r is not None: return r
    raise SystemExit("timeout")
send({"type": "hello", "token": token, "clientName": "stress-driver", "protocolVersion": 1, "capabilities": []})
wait(lambda m: True if m.get("type") == "helloOk" else None)
send({"type": "stateFetch"})
state = wait(lambda m: m.get("state") if m.get("type") in ("stateChanged", "state") else None)
space = next((sp["id"] for sp in state["spaces"] if sp["path"] == space_path), None)
if space is None:
    send({"type": "addSpace", "path": space_path})
    space = wait(lambda m: next((sp["id"] for sp in m.get("state", {}).get("spaces", []) if sp["path"] == space_path), None) if m.get("type") == "stateChanged" else None)
print("space", space)
ids = []
for i in range(count):
    r = send({"type": "createAgent", "spaceID": space, "initialPrompt": f"stress agent {i}"})
    ids.append(wait(lambda m: m.get("agentID") if m.get("type") == "agentCreated" and m.get("id") == r else None))
    print("agent", i, ids[-1]); time.sleep(0.5)
