// A fake model provider for tests that run pi for real: OpenAI Responses (also the Codex backend's
// shape, which pi sends zstd-compressed), OpenAI Chat Completions and Anthropic Messages, each
// answering "ok" as a server-sent-event stream. It records every request body (decompressed) so a
// test can see exactly what reached the wire, and echoes `service_tier` the way OpenAI reports the
// tier it used.
//
// As a library: `const provider = await startProvider({ onRequest })`.
// As a program: `node fake-provider.mjs <log.jsonl>` prints {"port":N} and appends one JSON line
// per request ({index, path, headers, body}) to the log, until stdin closes.
import * as http from "node:http";
import * as fs from "node:fs";
import * as zlib from "node:zlib";
import { pathToFileURL } from "node:url";

const sse = (events) => events.map(([name, data]) => `${name ? `event: ${name}\n` : ""}data: ${typeof data === "string" ? data : JSON.stringify(data)}\n\n`).join("");

// `call` makes the reply a bash tool call instead of text. `used` is { input, output } in tokens: a million each
// way by default, so a test reads the price pi worked out from the model's rates. `serial` makes the ids unique
// to this reply (call_N, fc_N, rs_N, msg_N; without it every reply uses call_1, fc_1 and msg_1), and `reasoning`
// puts a reasoning item with that many characters of encrypted content ahead of the reply, as a reasoning model's.
const MILLION = { input: 1_000_000, output: 1_000_000 };
function responses(model, tier, call, used = MILLION, serial, reasoning = 0) {
  const n = serial ?? 1;
  const message = { type: "message", id: `msg_${n}`, status: "completed", role: "assistant", content: [{ type: "output_text", text: "ok", annotations: [] }] };
  const fn = call && { type: "function_call", id: `fc_${n}`, call_id: `call_${n}`, name: "bash", arguments: JSON.stringify({ command: call }), status: "completed" };
  const thought = reasoning > 0 && { type: "reasoning", id: `rs_${n}`, summary: [], encrypted_content: "e".repeat(reasoning) };
  const item = fn ?? message;
  const outputs = thought ? [thought, item] : [item];
  const events = [["response.created", { type: "response.created", response: { id: "resp_1", object: "response", status: "in_progress", model, output: [] } }]];
  outputs.forEach((output, index) => {
    if (output === thought) {
      events.push(["response.output_item.added", { type: "response.output_item.added", output_index: index, item: { ...output, encrypted_content: undefined } }]);
    } else if (fn) {
      events.push(["response.output_item.added", { type: "response.output_item.added", output_index: index, item: { ...fn, arguments: "", status: "in_progress" } }],
        ["response.function_call_arguments.delta", { type: "response.function_call_arguments.delta", item_id: fn.id, output_index: index, delta: fn.arguments }],
        ["response.function_call_arguments.done", { type: "response.function_call_arguments.done", item_id: fn.id, output_index: index, arguments: fn.arguments }]);
    } else {
      events.push(["response.output_item.added", { type: "response.output_item.added", output_index: index, item: { ...message, status: "in_progress", content: [] } }],
        ["response.content_part.added", { type: "response.content_part.added", item_id: message.id, output_index: index, content_index: 0, part: { type: "output_text", text: "", annotations: [] } }],
        ["response.output_text.delta", { type: "response.output_text.delta", item_id: message.id, output_index: index, content_index: 0, delta: "ok" }],
        ["response.output_text.done", { type: "response.output_text.done", item_id: message.id, output_index: index, content_index: 0, text: "ok" }],
        ["response.content_part.done", { type: "response.content_part.done", item_id: message.id, output_index: index, content_index: 0, part: message.content[0] }]);
    }
    events.push(["response.output_item.done", { type: "response.output_item.done", output_index: index, item: output }]);
  });
  events.push(["response.completed", { type: "response.completed", response: { id: "resp_1", object: "response", status: "completed", model, ...(tier ? { service_tier: tier } : {}), output: outputs,
      usage: { input_tokens: used.input, output_tokens: used.output, total_tokens: used.input + used.output, input_tokens_details: { cached_tokens: 0 }, output_tokens_details: { reasoning_tokens: 0 } } } }]);
  return sse(events);
}

function completions(model, tier, call, used = MILLION) {
  const chunk = (delta, finish, extra = {}) => ({ id: "c1", object: "chat.completion.chunk", created: 1, model, ...(tier ? { service_tier: tier } : {}),
    choices: [{ index: 0, delta, finish_reason: finish ?? null }], ...extra });
  const usage = { prompt_tokens: used.input, completion_tokens: used.output, total_tokens: used.input + used.output };
  if (call) {
    return sse([[null, chunk({ tool_calls: [{ index: 0, id: "call_1", type: "function", function: { name: "bash", arguments: JSON.stringify({ command: call }) } }] })],
      [null, chunk({}, "tool_calls", { usage })], [null, "[DONE]"]]);
  }
  return sse([[null, chunk({ content: "ok" })], [null, chunk({}, "stop", { usage })], [null, "[DONE]"]]);
}

function anthropic(model) {
  return sse([
    ["message_start", { type: "message_start", message: { id: "m1", type: "message", role: "assistant", content: [], model, stop_reason: null, usage: { input_tokens: 5, output_tokens: 1 } } }],
    ["content_block_start", { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } }],
    ["content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "ok" } }],
    ["content_block_stop", { type: "content_block_stop", index: 0 }],
    ["message_delta", { type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 2 } }],
    ["message_stop", { type: "message_stop" }],
  ]);
}

// `onRequest({ index, path, body })` runs before the reply and may return { call: "shell command" } to make it a
// tool call, or { status, text } to fail the request; `reasoning: N` adds a reasoning item of N characters to a Responses
// reply. `usage(entry)` says how many tokens the reply reports ({ input, output }); without it a million each way.
// `uniqueIds` gives every Responses reply ids of its own (see `responses`).
export async function startProvider({ onRequest, usage, uniqueIds = false } = {}) {
  const requests = [];
  const server = http.createServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    let buffer = Buffer.concat(chunks);
    if (req.headers["content-encoding"] === "zstd") buffer = zlib.zstdDecompressSync(buffer);
    let body;
    try { body = JSON.parse(buffer.toString("utf8")); } catch { body = undefined; }
    const entry = { index: requests.length, path: req.url, headers: req.headers, body };
    requests.push(entry);
    const decision = (await onRequest?.(entry)) ?? {};
    if (decision.status) {
      res.writeHead(decision.status, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: { message: decision.text ?? "failed", type: "invalid_request_error" } }));
      return;
    }
    res.writeHead(200, { "content-type": "text/event-stream" });
    const path = String(req.url).split("?")[0];
    const tier = body?.service_tier;
    const used = usage?.(entry);
    if (path.endsWith("/chat/completions")) res.end(completions(body?.model, tier, decision.call, used));
    else if (path.endsWith("/messages")) res.end(anthropic(body?.model));
    else res.end(responses(body?.model, tier, decision.call, used, uniqueIds ? entry.index + 1 : undefined, decision.reasoning));
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return {
    port: server.address().port,
    requests,
    async stop() {
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
    },
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const log = process.argv[2];
  const provider = await startProvider({
    onRequest: (entry) => {
      if (log) fs.appendFileSync(log, JSON.stringify({ index: entry.index, path: entry.path, headers: entry.headers, body: entry.body }) + "\n");
    },
  });
  process.stdout.write(JSON.stringify({ port: provider.port }) + "\n");
  process.stdin.on("end", () => process.exit(0));
  process.stdin.resume();
}
