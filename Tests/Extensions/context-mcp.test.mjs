// Context clearing (Extensions/shepherd-context.ts) on a thread that uses pi's own MCP (docs/mcp.md, docs/context-budget.md):
// an MCP tool's result is cleared like any other tool's, and a tool_search result that went out of the request does not take
// the tools it loaded with it. Real pi in RPC mode, three stand-in MCP servers, a fake provider that records every request.
// Run: PI_PACKAGE_DIR=/path/to/pi-coding-agent node --test Tests/Extensions/context-mcp.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { startThread } from "./context-harness.mjs";

const pkg = process.env.PI_PACKAGE_DIR;
if (!pkg) throw Error("Set PI_PACKAGE_DIR to the installed Pi package");

const LINE = "lorem ipsum dolor sit amet consectetur adipiscing elit";
// About 3,000 tokens of output: a run of calls that fills a small window.
const bulk = (tag) => `awk 'BEGIN{for(i=1;i<=200;i++) printf "%d ${LINE} ${tag}%d\\n", i, i}'`;
const outputs = (request) => request.body.input.filter((item) => item.type === "function_call_output").map((item) => String(item.output));
const toolNames = (request) => request.body.tools.map((tool) => tool.name);

test("a tool_search result cleared from the request keeps its tools declared and callable, and an MCP result is cleared like any other", { timeout: 240000 }, async (t) => {
  let step = 0, echo;
  const BULK_CALLS = 24;
  const thread = await startThread({
    extensions: ["status", "mcp", "context"], skills: false, instructions: false, project: false, needsName: false,
    // Catalogs shaped like a real server's (the stand-ins inherit pi's environment), so a search loads about 300 tokens of descriptions.
    env: { FAKE_MCP_TOOLS: "20" }, contextWindow: 60_000, usage: (entry) => ({ input: Math.ceil(JSON.stringify(entry.body).length / 4), output: 40 }),
    onRequest: (entry) => {
      const n = step++;
      if (n === 0) return { tool: { name: "tool_search", arguments: { query: "echo the text back" } } };
      if (n === 1) {
        // What the search loaded: the echo tool of whichever server ranked first.
        echo = /mcp__[A-Za-z0-9_]+__echo/.exec(outputs(entry)[0])?.[0];
        return { tool: { name: echo ?? "mcp__docs__echo", arguments: { text: "z".repeat(12_000) } } };
      }
      if (n <= BULK_CALLS + 1) return { call: bulk(n) };
      if (n === BULK_CALLS + 2) return { tool: { name: echo, arguments: { text: "after clearing" } } };
      return {};
    },
  });
  t.after(() => thread.stop());
  await thread.turn("search the tools, use one, then read a lot", 240000);

  assert.ok(echo, "tool_search loaded an echo tool");
  const requests = thread.mainRequests();
  const last = requests.at(-1), beforeLast = requests.at(-2);

  // The search's result is the oldest thing in the conversation: the batch cleared it, as it would any tool's.
  const [searchOutput, firstEchoOutput] = outputs(last);
  assert.match(searchOutput, /^\[tool_search .*output removed from context: about /, "the search result was cleared");
  assert.match(firstEchoOutput, /^\[mcp__\w+__echo .*output removed from context: about /, "a big MCP result is cleared like any other tool's");

  // What the search loaded is declared in every request after it, with or without its result in the conversation.
  for (const request of requests.slice(2)) assert.ok(toolNames(request).includes(echo), `${echo} is declared in request ${request.index}`);
  assert.ok(toolNames(beforeLast).includes(echo));

  // And the call made after the clearing works: its result reached the model.
  assert.equal(outputs(last).at(-1), "echo: after clearing", "a tool loaded by a search that is out of the request is still called");
  assert.ok(!thread.events.some((e) => e.type === "extension_error"), JSON.stringify(thread.events.filter((e) => e.type === "extension_error")));
});
