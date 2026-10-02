// A scripted OpenAI chat-completions provider for the opt-in real-engine thread tests
// (Tests/ShepherdSessionsIntegrationTests/EngineThreadTests.swift): no network, no model.
// Prints {"port":N} once listening and exits when stdin closes. What it answers depends on the
// last user message, so one pi can be driven through every turn shape:
//
//   "tool …"    one bash call (`echo hi`); the turn ends with "tool done" once the result is back
//   "slow …"    sixty words, fifty milliseconds apart, so a Stop or a queued message lands mid-turn
//   "think …"   a reasoning block (`reasoning_content`) before "thought about it"
//   compaction  pi's summarization request (its prompt wraps the conversation in <conversation>)
//               is answered with a fixed summary
//   otherwise   "ok"
import * as http from "node:http";

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const textOf = (message) => (typeof message?.content === "string" ? message.content : (message?.content ?? []).map((part) => part.text ?? "").join("\n"));
const usage = { prompt_tokens: 100, completion_tokens: 10, total_tokens: 110 };

const server = http.createServer(async (req, res) => {
  let raw = "";
  for await (const chunk of req) raw += chunk;
  const body = JSON.parse(raw);
  const last = body.messages.at(-1);
  const text = textOf(body.messages.filter((message) => message.role === "user").at(-1));
  const chunk = (delta, finish, extra) => `data: ${JSON.stringify({ id: "engine", object: "chat.completion.chunk", created: 1, model: body.model,
    choices: [{ index: 0, delta, finish_reason: finish ?? null }], ...(extra ? { usage: extra } : {}) })}\n\n`;
  let closed = false;
  res.on("close", () => { closed = true; });
  res.writeHead(200, { "content-type": "text/event-stream" });
  const finish = (reason) => { if (!closed) res.end(chunk({}, reason, usage) + "data: [DONE]\n\n"); };

  if (last.role === "tool") {
    res.write(chunk({ content: "tool done" }));
    return finish("stop");
  }
  if (/^tool/.test(text)) {
    res.write(chunk({ tool_calls: [{ index: 0, id: "call_1", type: "function", function: { name: "bash", arguments: "" } }] }));
    res.write(chunk({ tool_calls: [{ index: 0, function: { arguments: JSON.stringify({ command: "echo hi" }) } }] }));
    return finish("tool_calls");
  }
  if (/^slow/.test(text)) {
    for (let i = 0; i < 60 && !closed; i++) {
      res.write(chunk({ content: `word${i} ` }));
      await sleep(50);
    }
    return finish("stop");
  }
  if (/^think/.test(text)) {
    res.write(chunk({ reasoning_content: "weighing it" }));
    res.write(chunk({ content: "thought about it" }));
    return finish("stop");
  }
  if (text.includes("<conversation>")) {
    res.write(chunk({ content: "## Summary\nthe conversation so far" }));
    return finish("stop");
  }
  res.write(chunk({ content: "ok" }));
  finish("stop");
});

server.listen(0, "127.0.0.1", () => process.stdout.write(JSON.stringify({ port: server.address().port }) + "\n"));
process.stdin.on("end", () => process.exit(0));
process.stdin.resume();
