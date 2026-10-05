// What the slash menu lists in a Shepherd thread, against pi's real RPC runtime: every command a
// bundled extension registers there must show something in the thread, which in RPC mode is a
// message (pi's `notify` reaches the host as an `extension_ui_request` the thread never draws).
// Run: PI_PACKAGE_DIR=/path/to/pi-coding-agent node --test Tests/Extensions/native-commands.test.mjs
// Everything runs in a temporary HOME; no model is called.
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const pkg = process.env.PI_PACKAGE_DIR;
if (!pkg) throw Error("Set PI_PACKAGE_DIR to the installed Pi package");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(what, fn, timeout = 30000) {
  const end = Date.now() + timeout;
  while (!fn()) { if (Date.now() > end) throw Error(`Timed out waiting for ${what}`); await sleep(20); }
}

// pi in RPC mode the way Shepherd starts an agent's: the status and children extensions, the
// agent's environment (an absent socket: the commands never need it).
async function startPi(dir) {
  const config = path.join(dir, "config");
  fs.mkdirSync(config);
  fs.writeFileSync(path.join(config, "settings.json"), JSON.stringify({}));
  fs.writeFileSync(path.join(config, "models.json"), JSON.stringify({ providers: { fixture: {
    baseUrl: "http://127.0.0.1:9/v1", api: "openai-completions", apiKey: "local-fixture-not-secret",
    models: [{ id: "fixture", name: "fixture", reasoning: false, input: ["text"], contextWindow: 64000, maxTokens: 1024, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
  } } }));
  const children = path.join(root, "Extensions/shepherd-children.ts");
  const env = { PATH: process.env.PATH, HOME: dir, PI_CODING_AGENT_DIR: config, PI_OFFLINE: "1",
    SHEPHERD_AGENT_ID: "fixture", SHEPHERD_NATIVE_CHILDREN: "1", SHEPHERD_SOCKET: path.join(dir, "absent.sock"), SHEPHERD_EXT_CHILDREN: children };
  const child = spawn(process.execPath, [path.join(pkg, "dist/bundle/cli.js"), "--mode", "rpc", "--session-dir", path.join(dir, "sessions"),
    "-ne", "-ns", "-np", "--model", "fixture/fixture", "-e", children, "-e", path.join(root, "Extensions/shepherd-status.ts")],
  { cwd: dir, env, stdio: ["pipe", "pipe", "pipe"] });
  const events = [];
  let out = "", err = "", next = 0;
  child.stdout.on("data", (chunk) => {
    out += chunk;
    for (let nl; (nl = out.indexOf("\n")) >= 0; out = out.slice(nl + 1)) {
      try { events.push(JSON.parse(out.slice(0, nl))); } catch {}
    }
  });
  child.stderr.on("data", (chunk) => { err += chunk; });
  const pi = {
    events,
    get stderr() { return err; },
    async request(command) {
      const id = `r${++next}`;
      child.stdin.write(JSON.stringify({ id, ...command }) + "\n");
      await until(`the answer to ${command.type}`, () => events.some((e) => e.type === "response" && e.id === id));
      return events.find((e) => e.type === "response" && e.id === id);
    },
    async stop() {
      child.kill();
      await new Promise((r) => child.once("exit", r));
    },
  };
  return pi;
}

const textOf = (message) => typeof message.content === "string" ? message.content : message.content.map((p) => p.text ?? "").join("");

test("real Pi RPC: every bundled command the menu lists answers in the thread, and the two the thread covers are not listed", { timeout: 120000 }, async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sh-commands-"));
  const pi = await startPi(dir);
  try {
    const listed = (await pi.request({ type: "get_commands" })).data.commands.filter((c) => c.source === "extension");
    const bundled = listed.filter((c) => c.sourceInfo?.path?.startsWith(root)).map((c) => c.name).sort();
    // /shepherd-retry is the host's own (it leaves it out of the menu); the other six are the native subagents' reports.
    assert.deepEqual(bundled, ["missions", "run", "shepherd-retry", "subagents", "subagents-doctor", "subagents-models", "workflows"]);
    assert(!listed.some((c) => c.name === "subagents-fleet" || c.name === "subagents-stop"), "the tray, the inspector and Stop cover these");

    for (const name of bundled.filter((n) => n !== "shepherd-retry")) {
      const mark = pi.events.length;
      const messagesBefore = (await pi.request({ type: "get_messages" })).data.messages.length;
      assert.equal((await pi.request({ type: "prompt", message: `/${name}` })).success, true);
      await sleep(100);
      const seen = pi.events.slice(mark);
      assert(!seen.some((e) => e.type === "extension_ui_request" && e.method === "notify"), `/${name} must not rely on a notify, which the thread never draws`);
      const messages = (await pi.request({ type: "get_messages" })).data.messages;
      assert.equal(messages.length, messagesBefore + 1, `/${name} leaves one message in the thread`);
      const report = messages.at(-1);
      assert.equal(report.role, "custom");
      assert.equal(report.customType, "shepherd-native-report");
      assert.equal(report.display, true, `/${name}'s report is drawn`);
      assert(textOf(report).length > 0);
    }

    const all = (await pi.request({ type: "get_messages" })).data.messages.map(textOf);
    assert(all.some((t) => t.startsWith("NATIVE SUBAGENTS") && !t.includes("/subagents-fleet") && !t.includes("/subagents-stop")), "doctor lists what exists");
    assert(all.some((t) => t.includes("Usage: /run")), "a command that fails says so in the thread");
    assert(all.some((t) => t.split("\n").some((line) => line.startsWith("scout · shepherd · "))), "the profile list names the owned-file agents /run takes");
    assert(!pi.events.some((e) => e.type === "extension_error"));
  } catch (error) {
    error.message += `\npi stderr:\n${pi.stderr}`;
    throw error;
  } finally {
    await pi.stop();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
