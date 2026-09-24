// Scripted OpenAI-compatible provider for the opt-in live end-to-end UI test
// (Tests/ShepherdAppTests/LiveEndToEndTests.swift). No network, no real model: it plays a
// parent that spawns three native children and children that work, ask, and finish.
// Prints {"port":N} once listening; logs one JSON line per request to stderr.
import * as http from "node:http";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const textOf = (m) => typeof m?.content === "string" ? m.content : (m?.content ?? []).map((p) => p.text ?? "").join("\n");

const server = http.createServer(async (req, res) => {
  let raw = ""; for await (const chunk of req) raw += chunk;
  const body = JSON.parse(raw);
  const messages = body.messages ?? [];
  const system = messages.filter((m) => m.role === "system" || m.role === "developer").map(textOf).join("\n");
  const users = messages.filter((m) => m.role === "user").map(textOf);
  const task = users[0] ?? "";
  const last = messages.at(-1) ?? {};
  const toolNames = (body.tools ?? []).map((t) => t.function?.name);
  const toolResults = messages.filter((m) => m.role === "tool").length;
  const child = system.includes("You are a Shepherd child");
  const say = (delta, finish = "stop") => {
    res.writeHead(200, { "content-type": "text/event-stream" });
    res.write(`data: ${JSON.stringify({ id: "e2e", object: "chat.completion.chunk", created: 1, model: body.model, choices: [{ index: 0, delta, finish_reason: null }] })}\n\n`);
    res.end(`data: ${JSON.stringify({ id: "e2e", object: "chat.completion.chunk", choices: [{ index: 0, delta: {}, finish_reason: finish }], usage: { prompt_tokens: 1200, completion_tokens: 40, total_tokens: 1240 } })}\n\ndata: [DONE]\n\n`);
  };
  const call = (calls) => say({ tool_calls: calls.map(([name, args], index) => ({ index, id: `call-${Date.now()}-${index}`, type: "function", function: { name, arguments: JSON.stringify(args) } })) }, "tool_calls");
  process.stderr.write(JSON.stringify({ child, task: task.slice(0, 40), last: last.role, toolResults }) + "\n");

  if (!child) {
    if (last.role === "user" && textOf(last).includes("E2E_START") && toolNames.includes("shepherd_child_start")) {
      return call([
        ["shepherd_child_start", { role: "worker", task: "WORK_SLOW: restyle the native thread view to the spec" }],
        ["shepherd_child_start", { role: "reviewer", task: "ASK_PARENT: review token names against the spec" }],
        ["shepherd_child_start", { role: "scout", task: "QUICK: find where tool rows are rendered" }],
      ]);
    }
    if (last.role === "tool") return say({ content: "Splitting into three: a **worker** for the restyle, a **reviewer** checking tokens against the spec, and a quick **scout**. I'll integrate when they report back." });
    if (last.role === "user" && textOf(last).includes("E2E_FOLLOWUP")) return say({ content: "All three reported. The restyle is integrated and the reviewer's decision is applied." });
    const note = textOf(last);
    if (note.includes("Needs reply")) return say({ content: "The reviewer needs a decision on token names; answer on its card." });
    if (note.includes("Child ")) return say({ content: "A child reported back; integrating its result." });
    return say({ content: "Noted." });
  }

  // Children.
  if (task.includes("WORK_SLOW")) {
    if (toolResults < 5) {
      await sleep(400);
      return call([["bash", { command: `sleep 1.5 && echo "restyle step ${toolResults + 1} of 5"` }]]);
    }
    return say({ content: "Restyled the thread, composer and tool rows. Five focused steps, all checks green." });
  }
  if (task.includes("ASK_PARENT")) {
    if (users.length > 1) return say({ content: `Applied: ${users.at(-1)}. Everything else matches the spec.` });
    if (toolResults === 0) return call([["shepherd_parent_message", { message: "Two token names collide with existing Tokens.textSecondary. Rename the new ones, or replace the old ones everywhere?", needsReply: true, options: ["Replace everywhere", "Rename new ones"] }]]);
    return say({ content: "Waiting for your decision on the token names." });
  }
  if (task.includes("QUICK")) {
    if (toolResults === 0) return call([["ls", { path: "." }]]);
    return say({ content: "Tool rows render in DesktopNativeThreadView.swift (NativeToolRowView)." });
  }
  return say({ content: "ok" });
});

server.listen(0, "127.0.0.1", () => { process.stdout.write(JSON.stringify({ port: server.address().port }) + "\n"); });
process.stdin.on("end", () => process.exit(0)); process.stdin.resume();
