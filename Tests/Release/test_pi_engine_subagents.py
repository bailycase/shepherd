"""Optional end-to-end check against pi-subagents 0.76.1, unpacked with its dependencies.

SHEPHERD_ENGINE_SMOKE=.build/pi-engine PI_SUBAGENTS_PACKAGE_DIR=<scratch package> \
  python3 -m unittest discover -s Tests/Release -p test_pi_engine_subagents.py

No downloads, credentials or external model calls. Parent and children use a loopback provider.
"""
import http.server
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import threading
import time
import unittest


@unittest.skipUnless(os.environ.get("SHEPHERD_ENGINE_SMOKE") and os.environ.get("PI_SUBAGENTS_PACKAGE_DIR"),
                     "requires a staged engine and an isolated pi-subagents 0.76.1 install")
class EngineSubagentsTests(unittest.TestCase):
    def test_two_background_children_finish_with_transcripts(self):
        root = Path(os.environ["SHEPHERD_ENGINE_SMOKE"]).resolve()
        if (root / "Contents").is_dir():
            root /= "Contents"
        engine = root / "Resources/pi-engine"
        extension = Path(os.environ["PI_SUBAGENTS_PACKAGE_DIR"]).resolve()
        self.assertEqual(json.loads((extension / "package.json").read_text())["version"], "0.76.1")
        requests = []

        class Provider(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["content-length"])))
                requests.append(body)
                users = [m.get("content", "") for m in body["messages"] if m["role"] == "user"]
                used = [t["function"]["name"] for m in body["messages"] for t in m.get("tool_calls", [])]
                delta, finish = {"content": "CHILD_OK"}, "stop"
                if "START-SUBAGENT-SMOKE" in json.dumps(users) and "subagent" not in used:
                    delta = {"tool_calls": [{"index": 0, "id": "call_smoke", "type": "function", "function": {
                        "name": "subagent", "arguments": json.dumps({
                            "workflow": "./workflow.js", "async": True, "mission": False})}}]}
                    finish = "tool_calls"

                def chunk(value, reason=None):
                    return "data: " + json.dumps({"id": "smoke", "object": "chat.completion.chunk",
                        "created": 1, "model": body["model"], "choices": [
                            {"index": 0, "delta": value, "finish_reason": reason}]}) + "\n\n"

                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                self.wfile.write((chunk(delta) + chunk({}, finish) + "data: [DONE]\n\n").encode())

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory(prefix="shepherd-subagent-smoke-") as scratch:
                home = Path(scratch)
                agent = home / "pi"
                (agent / "agents").mkdir(parents=True)
                (home / "tmp").mkdir()
                (agent / "agents/smoke.md").write_text(
                    "---\nname: smoke\ndescription: Offline packaging check\nmodel: fixture/smoke\n"
                    "tools: read\ninheritProjectContext: false\ninheritGlobalContext: false\n"
                    "inheritSkills: false\n---\nReturn CHILD_OK.\n")
                (home / "workflow.js").write_text('return runs.all(['
                    '{key:"a",label:"Check first child",agent:"smoke",task:"CHILD-SMOKE-A",'
                    'acceptance:{level:"none",reason:"Fixture checks the transcript"}},'
                    '{key:"b",label:"Check second child",agent:"smoke",task:"CHILD-SMOKE-B",'
                    'acceptance:{level:"none",reason:"Fixture checks the transcript"}}]);')
                (agent / "models.json").write_text(json.dumps({"providers": {"fixture": {
                    "api": "openai-completions", "baseUrl": f"http://127.0.0.1:{server.server_port}/v1",
                    "apiKey": "test", "models": [{"id": "smoke", "name": "Smoke", "reasoning": False,
                        "input": ["text"], "contextWindow": 32768, "maxTokens": 1024,
                        "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}}]}}}))
                (agent / "settings.json").write_text(json.dumps({"extensions": [
                    "-builtin:mcp", "-builtin:codemode", "-builtin:tool-search"]}))
                env = {"PATH": str(root / "Helpers") + ":/usr/bin:/bin", "HOME": scratch,
                       "TMPDIR": str(home / "tmp"), "PI_CODING_AGENT_DIR": str(agent),
                       "PI_PACKAGE_DIR": str(engine), "PI_OFFLINE": "1",
                       "PI_SUBAGENTS_TEMP_ROOT": str(home / "runs")}
                with (home / "events.log").open("w") as stdout, (home / "stderr.log").open("w") as stderr:
                    parent = subprocess.Popen([str(root / "Helpers/node"), str(engine / "dist/bundle/cli.js"),
                        "--mode", "rpc", "--no-extensions", "--no-skills", "--no-prompt-templates",
                        "-e", str(extension / "index.js"), "--provider", "fixture", "--model", "smoke"],
                        cwd=home, env=env, stdin=subprocess.PIPE, stdout=stdout, stderr=stderr,
                        text=True, start_new_session=True)
                    try:
                        parent.stdin.write(json.dumps({"type": "prompt", "message": "START-SUBAGENT-SMOKE"}) + "\n")
                        parent.stdin.flush()
                        deadline = time.monotonic() + 30
                        children = []
                        while time.monotonic() < deadline:
                            children = []
                            for path in (home / "runs").rglob("status.json"):
                                try:
                                    status = json.loads(path.read_text())
                                except json.JSONDecodeError:
                                    continue
                                if status.get("mode") != "workflow":
                                    children.append(status)
                            if len(children) == 2 and all(c.get("processTerminal", {}).get("state") == "observed" for c in children):
                                break
                            if parent.poll() is not None:
                                break
                            time.sleep(0.05)
                        diagnostic = json.dumps(children) + (home / "stderr.log").read_text()
                        self.assertEqual(len(children), 2, diagnostic)
                        for child in children:
                            self.assertEqual(child["state"], "complete", diagnostic)
                            self.assertEqual(child["steps"][0]["exitCode"], 0, diagnostic)
                            self.assertEqual(child["steps"][0]["recentOutput"], ["CHILD_OK"])
                            self.assertIn("CHILD_OK", Path(child["sessionFile"]).read_text())
                            self.assertEqual(child["processTerminal"]["instances"][0]["exitCode"], 0)
                        self.assertGreaterEqual(len(requests), 4, "parent launch, parent reply, two child turns")
                    finally:
                        # Only this test's process group. The runner may detach its own group;
                        # shutdown goes through Pi first, which owns those children.
                        if parent.poll() is None:
                            os.killpg(parent.pid, signal.SIGTERM)
                            try:
                                parent.wait(timeout=5)
                            except subprocess.TimeoutExpired:
                                os.killpg(parent.pid, signal.SIGKILL)
                                parent.wait(timeout=5)
                        parent.stdin.close()
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
