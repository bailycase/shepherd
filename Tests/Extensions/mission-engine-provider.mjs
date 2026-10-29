// Loopback-only scripted model for MissionEngineTests. Reads fixture metadata, never worktrees.
// Only Pi's actual write/read tools perform the implementation and independent inspection.
import * as http from "node:http";
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";

const { lanes } = JSON.parse(readFileSync(process.argv[2], "utf8"));
assert.equal(lanes.length, 2);
assert.equal(new Set(lanes).size, 2);
const textOf = (message) => typeof message?.content === "string" ? message.content
  : (message?.content ?? []).map(part => part.text ?? "").join("\n");
const stations = [], dependencies = [];
for (const [index, lane] of lanes.entries()) {
  const worker = `worker-${index}`, check = `check-${index}`, validator = `validator-${index}`;
  for (const [id, kind, goal] of [
    [worker, "worker", "Write after followed by a newline to result.txt"],
    [check, "check", "Check actual file bytes"],
    [validator, "validator", "Independently read result.txt and inspect the host check"],
  ]) {
    stations.push({ id, kind, lane, title: id, goal, doneWhen: ["result.txt contains after followed by a newline"],
      ...(kind === "check" ? { command: "python3 -c 'from pathlib import Path; assert Path(\"result.txt\").read_bytes() == b\"after\\n\"; print(\"HOST_CHECK_OK\")'" } : {}) });
  }
  dependencies.push({ source: worker, target: check, kind: "data", artifact: "implementation" },
    { source: check, target: validator, kind: "data", artifact: "tested implementation" });
}
const plan = { summary: "Two isolated edits, real host checks and independent tool reads.", title: "Update both repositories",
  requirements: ["Both result.txt files contain exactly after followed by a newline"], stations, dependencies };

let requests = 0;
const server = http.createServer(async (req, res) => {
  try {
    assert.ok(++requests <= 32, "provider request bound exceeded");
    assert.equal(req.method, "POST");
    assert.equal(req.url, "/v1/chat/completions");
    let raw = "";
    for await (const chunk of req) {
      raw += chunk;
      assert.ok(Buffer.byteLength(raw) <= 512 * 1024, "oversized fixture request");
    }
    const body = JSON.parse(raw);
    assert.equal(body.model, "model");
    assert.equal(body.stream, true);
    const prompt = textOf(body.messages.filter(message => message.role === "user").at(-1));
    const last = body.messages.at(-1);
    let content, tool;
    if (prompt.startsWith("SHEPHERD MISSION PLANNER")) {
      assert.ok(lanes.every(lane => prompt.includes(lane)));
      content = JSON.stringify(plan);
    } else {
      const worker = prompt.startsWith("SHEPHERD MISSION STATION: worker");
      assert.ok(worker || prompt.startsWith("SHEPHERD MISSION STATION: validator"), "unexpected mission turn");
      const name = worker ? "write" : "read";
      if (last.role !== "tool") {
        assert.ok(body.tools.some(tool => tool.function?.name === name), `Pi must offer ${name}`);
        tool = { name, arguments: JSON.stringify(worker ? { path: "result.txt", content: "after\n" } : { path: "result.txt" }) };
      } else {
        const call = body.messages.filter(message => message.role === "assistant").at(-1)?.tool_calls?.at(-1);
        assert.equal(call?.function.name, name);
        assert.equal(last.tool_call_id, call.id);
        const result = textOf(last);
        if (worker) {
          assert.match(result, /wrote/i);
          assert.match(result, /result\.txt/);
          content = "Pi's write tool changed this lane's result.txt to after followed by a newline; left uncommitted.";
        } else {
          const passed = result.includes("after") && prompt.includes("HOST_CHECK_OK");
          content = JSON.stringify({ passed, evidence: `Read actual result.txt with Pi's read tool: ${result}; host check ${passed ? "HOST_CHECK_OK" : "not verified"}.` });
        }
      }
    }
    const chunk = (delta, finish = null, usage) => `data: ${JSON.stringify({ id: `mission-${requests}`,
      object: "chat.completion.chunk", created: 1, model: body.model,
      choices: [{ index: 0, delta, finish_reason: finish }], ...(usage ? { usage } : {}) })}\n\n`;
    res.writeHead(200, { "content-type": "text/event-stream" });
    res.write(chunk(tool ? { tool_calls: [{ index: 0, id: `call_${requests}`, type: "function", function: tool }] } : { content }));
    res.end(chunk({}, tool ? "tool_calls" : "stop", { prompt_tokens: 100, completion_tokens: 10, total_tokens: 110 }) + "data: [DONE]\n\n");
  } catch (error) {
    console.error(error);
    res.writeHead(400, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: { message: String(error), type: "fixture_error" } }));
    if (requests > 32) setImmediate(() => process.exit(1));
  }
});
server.requestTimeout = 10_000;
const lifetime = setTimeout(() => { console.error("mission provider lifetime exceeded"); process.exit(1); }, 120_000);
lifetime.unref();
server.listen(0, "127.0.0.1", () => console.log(JSON.stringify({ port: server.address().port })));
process.stdin.on("end", () => process.exit(0));
process.stdin.resume();
