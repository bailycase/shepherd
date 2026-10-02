#!/usr/bin/env node
// A scripted MCP server on stdio for the extension tests: newline-delimited JSON-RPC,
// tools/list in pages of two, and tools that echo, fail, wait, read the environment, and change
// the tool list. FAKE_MCP_CRASH makes it die at start with a message on stderr; FAKE_MCP_PIDFILE
// gets its pid; FAKE_MCP_LOG gets every message it received; FAKE_MCP_TOOLS=<n> adds n tools shaped
// like a real server's catalog (fake-mcp-catalog.mjs).
import * as fs from "node:fs";
import { spawn } from "node:child_process";
import * as catalog from "./fake-mcp-catalog.mjs";

if (process.env.FAKE_MCP_IGNORE_TERM) process.on("SIGTERM", () => {});
if (process.env.FAKE_MCP_DESCENDANT) {
  spawn(process.execPath, ["-e", `process.on('SIGTERM', () => {}); require('node:fs').writeFileSync(process.argv[1], String(process.pid)); setInterval(() => {}, 1000);`, process.env.FAKE_MCP_DESCENDANT], { stdio: "ignore" });
  while (!fs.existsSync(process.env.FAKE_MCP_DESCENDANT)) await new Promise((resolve) => setTimeout(resolve, 5));
}

if (process.env.FAKE_MCP_PIDFILE) fs.writeFileSync(process.env.FAKE_MCP_PIDFILE, String(process.pid));
// FAKE_MCP_ENVFILE gets the environment it was started with, as JSON.
if (process.env.FAKE_MCP_ENVFILE) fs.writeFileSync(process.env.FAKE_MCP_ENVFILE, JSON.stringify(process.env));
// FAKE_MCP_ARGVFILE gets what it was started with: its arguments and working directory.
if (process.env.FAKE_MCP_ARGVFILE) fs.writeFileSync(process.env.FAKE_MCP_ARGVFILE, JSON.stringify({ argv: process.argv.slice(2), cwd: process.cwd() }));
if (process.env.FAKE_MCP_CRASH) {
  process.stderr.write("fake-mcp: can't read its config\n");
  process.exit(3);
}
const tools = [...catalog.base(), ...catalog.forge(Number(process.env.FAKE_MCP_TOOLS ?? 0))];
const pendingSlow = new Map();

function send(message) {
  process.stdout.write(JSON.stringify(message) + "\n");
}

function result(id, value) {
  send({ jsonrpc: "2.0", id, result: value });
}

const text = catalog.text;

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
    if (!tools.some((tool) => tool.name === params.name) && params.name !== "grown") {
      return send({ jsonrpc: "2.0", id, error: { code: -32602, message: `Unknown tool: ${params.name}` } });
    }
    switch (params.name) {
      case "slow": {
        pendingSlow.set(id, setTimeout(() => { pendingSlow.delete(id); result(id, text("finally")); }, args.ms ?? 10_000));
        return;
      }
      case "grow": {
        if (!tools.some((tool) => tool.name === "grown")) tools.push({ name: "grown", description: "Appeared later.", inputSchema: { type: "object" } });
        result(id, text("grew"));
        return send({ jsonrpc: "2.0", method: "notifications/tools/list_changed" });
      }
      default: return result(id, catalog.call(params.name, args));
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
