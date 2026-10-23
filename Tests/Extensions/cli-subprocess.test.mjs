import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as net from "node:net";
import * as path from "node:path";
import { spawnSync } from "node:child_process";
import { withPi, until } from "./fixtures/pi-rpc-harness.mjs";
import { jiti, root, installTestCliLauncher } from "./fixtures/children-harness.mjs";
import { parseCliArgs } from "../../Extensions/shepherd-cli-client.mjs";
const { cliBudget, cliLimits, cliRelayAllowed } = await jiti.import(path.join(root, "Extensions/shepherd-cli.ts"));
const write = (file, text) => { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, text); };

test("ordinary Pi print arguments cannot borrow parent orchestration/browser tools", () => {
  assert.deepEqual(parseCliArgs(["/speckit.tasks quoted args", "-p", "--mode", "json"]), { mode: "json", prompt: "/speckit.tasks quoted args" });
  assert.deepEqual(parseCliArgs(["-p", "ordinary prompt"]), { mode: "text", prompt: "ordinary prompt" });
  for (const args of [["-p"], ["-p", "/speckit.tasks", "-e", "bad.ts"], ["-p", "/speckit.tasks", "--mode", "rpc"]]) assert.throws(() => parseCliArgs(args));
  for (const name of ["shepherd_workflow", "shepherd_child_start", "browser_read", "agent_send", "automation_create", "codemode", "tool_search"]) assert.equal(cliRelayAllowed(name), false, name);
  assert.equal(cliRelayAllowed("github_issue_write"), true);
});

test("default shared bounds stop admission, turns, tokens, reported spend and time", t => {
  for (const key of ["children", "turns", "tokens", "cost"]) {
    const budget = cliBudget();
    const amount = cliLimits[key];
    assert.throws(() => budget.add({ [key]: key === "children" ? amount + 1 : amount }), new RegExp(key));
    assert.equal(budget.signal.aborted, true);
    budget.close();
  }
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const budget = cliBudget();
  t.mock.timers.tick(cliLimits.milliseconds);
  assert.equal(budget.signal.aborted, true);
  assert.match(budget.signal.reason.message, /time limit/);
  budget.close();
});

async function socketHost(t) {
  const dir = fs.mkdtempSync("/tmp/sk-host-");
  const socket = path.join(dir, "s"), connections = new Set();
  const server = net.createServer(connection => {
    connections.add(connection); let buffer = "";
    connection.setEncoding("utf8"); connection.on("error", () => {});
    connection.on("data", text => {
      buffer += text;
      for (let at; (at = buffer.indexOf("\n")) >= 0; buffer = buffer.slice(at + 1)) {
        const frame = JSON.parse(buffer.slice(0, at));
        if (frame.type === "prepareProjectConfiguration") connection.write(JSON.stringify({ type: "ok", id: frame.id }) + "\n");
      }
    });
  });
  await new Promise(resolve => server.listen(socket, resolve));
  t.after(async () => { for (const c of connections) c.destroy(); await new Promise(resolve => server.close(resolve)); fs.rmSync(dir, { recursive: true, force: true }); });
  return socket;
}

const python = process.env.SHEPHERD_TEST_SPECKIT_PYTHON;
for (const upstream of [false, true]) test(`owned Spec Kit children relay credentialed tools without shell secrets (${upstream ? "upstream Python dispatch" : "direct command"})`, { skip: upstream && !python, timeout: 60000 }, async t => {
  const socket = await socketHost(t);
  const bridge = path.join(root, "Extensions/shepherd-children.ts");
  let workDir;
  await withPi(t, {
    launcher: process.env.SHEPHERD_TEST_PI_LAUNCHER, agentDir: process.env.SHEPHERD_TEST_PI_HOME,
    files: (_dir, work) => ({ "trust.json": { [work]: true }, "mcp.json": { mcpServers: { fixture: {
      command: process.execPath, args: [path.join(root, "Tests/Extensions/fixtures/fake-mcp-stdio.mjs")],
      env: { PRIVATE_TOKEN: "${SHEPHERD_MCP_SECRET_FIXTURE}", FAKE_MCP_ENVFILE: path.join(work, "mcp-env"), FAKE_MCP_LOG: path.join(work, "mcp-log") },
    } } } }),
    // Stand in for PiHome.restoreEnvScript, installed by the real launcher.
    settings: { shellCommandPrefix: "unset SHEPHERD_MCP_SECRET_FIXTURE SHEPHERD_MCP_SECRETS" },
    args: ["--extension", bridge, "-e", "builtin:mcp"], usage: () => ({ input: 10, output: 10 }),
    env: { SHEPHERD_NATIVE_CHILDREN: "0", SHEPHERD_AGENT_ID: "parent", SHEPHERD_SOCKET: socket, SHEPHERD_EXT_CHILDREN: bridge,
      SHEPHERD_MCP_SECRETS: "SHEPHERD_MCP_SECRET_FIXTURE", SHEPHERD_MCP_SECRET_FIXTURE: "private-test-token" },
    project(dir, work) {
      const home = process.env.SHEPHERD_TEST_PI_HOME ?? path.join(dir, "home");
      installTestCliLauncher(home);
      workDir = work;
      if (upstream) {
        const setup = spawnSync(python, [path.join(root, "Tests/Extensions/fixtures/speckit-contract.py"), "setup", work], { env: { PATH: "/usr/bin:/bin", HOME: dir }, encoding: "utf8", timeout: 30000 });
        assert.equal(setup.status, 0, setup.stdout + setup.stderr);
      }
      write(path.join(work, ".pi/prompts/speckit.fixture.md"), "SHADOWED_PI_PROMPT $ARGUMENTS");
      write(path.join(work, ".shepherd/prompts/speckit.fixture.md"), "---\ndescription: Fixture hook\n---\nHOOK_BODY $ARGUMENTS");
      write(path.join(home, "extensions/private-mcp.ts"), `import fs from "node:fs"; export default pi => {
        pi.on("tool_call", event => { if (event.toolName === "github_issue_write") fs.appendFileSync(${JSON.stringify(path.join(work, "pipeline"))}, "checked\\n"); });
        pi.registerTool({ name: "github_issue_write", label: "private MCP", description: "Authenticated fixture action", parameters: { type: "object", properties: {}, additionalProperties: false },
          async execute() { if (process.env.SHEPHERD_MCP_SECRET_FIXTURE !== "private-test-token") throw Error("missing credential"); fs.writeFileSync(${JSON.stringify(path.join(work, "mcp-used"))}, "authenticated"); return { content: [{type:"text",text:"MCP_OK"}], structuredContent: { ok: true }, details: {} }; } });
      }`);
    },
    onRequest({ body }) {
      const text = JSON.stringify(body.messages);
      const isChild = (body.tools ?? []).some(tool => tool.function.name === "shepherd_parent_message");
      if (!isChild) {
        const after = body.messages.slice(body.messages.map(m => m.role).lastIndexOf("user") + 1);
        if (!after.some(m => m.role === "tool")) return { tool: { name: "bash", arguments: { command: upstream ? `${JSON.stringify(python)} ${JSON.stringify(path.join(root, "Tests/Extensions/fixtures/speckit-contract.py"))} verify ${JSON.stringify(workDir)}` : "pi --print '/speckit.fixture the arguments'", timeout: 30 } } };
        return { outputText: "parent finished" };
      }
      if (!body.messages.some(m => m.role === "tool")) return { tool: { name: "github_issue_write", arguments: {} } };
      if (!text.includes("echo: MCP_TRANSPORT_OK")) return { tool: { name: "mcp__fixture__echo", arguments: { text: "MCP_TRANSPORT_OK" } } };
      if (!text.includes("shell-safe")) return { call: `test -z "$SHEPHERD_MCP_SECRET_FIXTURE$SHEPHERD_SOCKET$SHEPHERD_AGENT_ID" && echo shell-safe` };
      return { outputText: "HOOK_COMPLETE" };
    },
  }, async pi => {
    const mark = pi.events.length;
    await pi.request({ type: "prompt", message: "Run the Spec Kit fixture" });
    await until("Spec Kit runner settled", () => pi.events.slice(mark).some(e => e.type === "agent_settled"), 45000);
    const events = pi.events.slice(mark);
    const execution = events.find(e => e.type === "tool_execution_end" && e.toolName === "bash" && e.toolCallId === "call_1");
    assert.ok(execution, JSON.stringify(events));
    const parent = pi.provider.requests[0].body.tools.map(tool => tool.function.name);
    assert.ok(!parent.some(name => name.startsWith("shepherd_child_") || name === "shepherd_workflow" || name === "shepherd_speckit"), "No opt-in helper tools or Spec Kit tool required");
    assert.equal(execution.isError, false, JSON.stringify(execution));
    assert.ok(JSON.stringify(execution.result).includes(upstream ? 'completed' : "HOOK_COMPLETE"));
    assert.equal(fs.readFileSync(path.join(workDir, "mcp-used"), "utf8"), "authenticated");
    assert.equal(fs.readFileSync(path.join(workDir, "pipeline"), "utf8"), upstream ? "checked\nchecked\n" : "checked\n");
    assert.ok(pi.provider.requests.some(r => JSON.stringify(r.body.messages).includes(upstream ? "SPECKIT_REGISTERED_HOOK" : "HOOK_BODY the arguments")));
    assert.equal(JSON.parse(fs.readFileSync(path.join(workDir, "mcp-env"), "utf8")).PRIVATE_TOKEN, "private-test-token");
    const calls = fs.readFileSync(path.join(workDir, "mcp-log"), "utf8").trim().split("\n").map(JSON.parse).filter(frame => frame.method === "tools/call");
    assert.equal(calls.filter(call => call.params.name === "echo").length, upstream ? 2 : 1);
    assert.ok(!pi.provider.requests.some(r => JSON.stringify(r.body.messages).includes("SHADOWED_PI_PROMPT")));
    assert.ok(!JSON.stringify(events).includes("private-test-token"));
  });
});
