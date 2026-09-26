#!/usr/bin/env node
// A scripted MCP server on stdio for Tests/Extensions/mcp.test.mjs: newline-delimited JSON-RPC,
// tools/list in pages of two, and tools that echo, fail, wait, read the environment, and change
// the tool list. FAKE_MCP_CRASH makes it die at start with a message on stderr; FAKE_MCP_PIDFILE
// gets its pid; FAKE_MCP_LOG gets every message it received.
import * as fs from "node:fs";

if (process.env.FAKE_MCP_PIDFILE) fs.writeFileSync(process.env.FAKE_MCP_PIDFILE, String(process.pid));
if (process.env.FAKE_MCP_CRASH) {
  process.stderr.write("fake-mcp: can't read its config\n");
  process.exit(3);
}
const tools = [
  { name: "echo", title: "Echo", description: "Echo the text back. Handy for tests.", inputSchema: { $schema: "http://json-schema.org/draft-07/schema#", type: "object", properties: { text: { type: "string" } }, required: ["text"] } },
  { name: "add", description: "Add two numbers.", inputSchema: { type: "object", properties: { a: { type: "number" }, b: { type: "number" } } } },
  { name: "fail", description: "Always fails with an error result.", inputSchema: { type: "object" } },
  { name: "slow", description: "Waits before answering.", inputSchema: { type: "object", properties: { ms: { type: "number" } } } },
  { name: "env", description: "Reads one environment variable.", inputSchema: { type: "object", properties: { name: { type: "string" } } } },
  { name: "grow", description: "Adds a tool and says the list changed.", inputSchema: { type: "object" } },
];
const pendingSlow = new Map();

function send(message) {
  process.stdout.write(JSON.stringify(message) + "\n");
}

function result(id, value) {
  send({ jsonrpc: "2.0", id, result: value });
}

function text(value) {
  return { content: [{ type: "text", text: value }] };
}

function handle(message) {
  if (process.env.FAKE_MCP_LOG) fs.appendFileSync(process.env.FAKE_MCP_LOG, JSON.stringify(message) + "\n");
  const { id, method, params } = message;
  if (method === "initialize") {
    // Some servers log to stdout: the client must skip lines that aren't JSON.
    process.stdout.write("fake-mcp starting up\n");
    return result(id, { protocolVersion: params.protocolVersion, capabilities: { tools: { listChanged: true } }, serverInfo: { name: "fake-mcp", title: "Fake MCP", version: "1.0.0" } });
  }
  if (method === "notifications/cancelled") {
    const pending = pendingSlow.get(params.requestId);
    if (pending) {
      clearTimeout(pending);
      pendingSlow.delete(params.requestId);
      fs.appendFileSync(process.env.FAKE_MCP_LOG ?? "/dev/null", JSON.stringify({ cancelled: params.requestId }) + "\n");
    }
    return;
  }
  if (id === undefined) return;
  if (method === "ping") return result(id, {});
  if (method === "tools/list") {
    const start = params?.cursor ? Number(params.cursor) : 0;
    const page = tools.slice(start, start + 2);
    return result(id, { tools: page, ...(start + 2 < tools.length ? { nextCursor: String(start + 2) } : {}) });
  }
  if (method === "tools/call") {
    const args = params.arguments ?? {};
    switch (params.name) {
      case "echo": return result(id, text(`echo: ${args.text}`));
      case "add": return result(id, { content: [], structuredContent: { sum: args.a + args.b } });
      case "fail": return result(id, { isError: true, content: [{ type: "text", text: "the database is down" }] });
      case "slow": {
        pendingSlow.set(id, setTimeout(() => { pendingSlow.delete(id); result(id, text("finally")); }, args.ms ?? 10_000));
        return;
      }
      case "env": return result(id, text(`${args.name}=${process.env[args.name] ?? ""}`));
      case "grow": {
        if (!tools.some((tool) => tool.name === "grown")) tools.push({ name: "grown", description: "Appeared later.", inputSchema: { type: "object" } });
        result(id, text("grew"));
        return send({ jsonrpc: "2.0", method: "notifications/tools/list_changed" });
      }
      case "grown": return result(id, text("hello from grown"));
      default: return send({ jsonrpc: "2.0", id, error: { code: -32602, message: `Unknown tool: ${params.name}` } });
    }
  }
  send({ jsonrpc: "2.0", id, error: { code: -32601, message: `Method not found: ${method}` } });
}

let buffer = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buffer += chunk;
  let index;
  while ((index = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, index);
    buffer = buffer.slice(index + 1);
    if (line.trim()) handle(JSON.parse(line));
  }
});
// FAKE_MCP_LINGER keeps it running after stdin closes, so only a signal stops it.
process.stdin.on("end", () => {
  if (process.env.FAKE_MCP_LINGER) setInterval(() => {}, 1000);
  else process.exit(0);
});
