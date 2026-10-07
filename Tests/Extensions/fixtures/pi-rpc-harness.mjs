// Real pi in RPC mode, in a temporary home and HOME, against a loopback fake provider (../fake-provider.mjs): the
// way Shepherd runs an agent, minus the app. `withPi(t, options, body)` starts it, hands `body` a handle, and kills it.
//
//   options.settings   the home's settings.json (merged over { retry: { enabled: false } })
//   options.files      (dir, work) => { "<path under the home, or absolute>": object | string } written before pi starts
//   options.project    (dir, work) => void, to lay out the project folder pi runs in
//   options.cwd        (dir, work) => the folder pi runs in, when it is not `work` (lay it out in `project`)
//   options.args       extra command-line arguments
//   options.env        extra environment for pi, or (dir, work) => it (its HOME and PI_* variables are always ours)
//   options.onRequest  the fake provider's script: ({ index, path, body }) => { call | tool | status, text } | void
//
// Needs PI_PACKAGE_DIR, the installed pi package (CI installs the pinned one).
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { spawn } from "node:child_process";
import { startProvider } from "../fake-provider.mjs";

export const pkg = process.env.PI_PACKAGE_DIR;
if (!pkg) throw Error("Set PI_PACKAGE_DIR to the installed Pi package");
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export async function until(what, fn, timeout = 30000) {
  const end = Date.now() + timeout;
  for (;;) {
    const value = await fn();
    if (value) return value;
    if (Date.now() > end) throw Error(`Timed out waiting for ${what}`);
    await sleep(20);
  }
}

const messageText = (m) => (typeof m.content === "string" ? m.content : JSON.stringify(m.content));

/** The provider's script as a list: the nth model call answers steps[n] (see fake-provider.mjs), then plain text. */
export function script(steps) {
  let next = 0;
  return () => steps[next++] ?? {};
}

/**
 * pi's subcommands (`pi mcp list`) run to the end in `home`, with no session. Resolves { status, stdout, stderr }.
 * Asynchronous, so a stand-in server in this same process can answer while it runs.
 */
export function runPiCli(home, args, { env = {}, cwd = home, timeout = 60000 } = {}) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [path.join(pkg, "dist/bundle/cli.js"), ...args], {
      cwd, stdio: ["ignore", "pipe", "pipe"],
      env: { PATH: process.env.PATH, HOME: path.dirname(home), PI_CODING_AGENT_DIR: home, PI_OFFLINE: "1", PI_SKIP_VERSION_CHECK: "1", PI_TELEMETRY: "0", ...env },
    });
    let stdout = "", stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    const timer = setTimeout(() => child.kill("SIGKILL"), timeout);
    child.on("close", (status) => { clearTimeout(timer); resolve({ status, stdout, stderr }); });
  });
}

/**
 * A directory holding the page opener that follows the URL it is given, as a browser would, and records it in
 * `opened.txt`. pi runs `open` on macOS and `xdg-open` elsewhere (dist/utils/open-browser.js), so both are here:
 * CI runs these tests on Linux, where a lone `open` is never called and the sign-in waits for a page nobody opens.
 */
export function fakeBrowserBin(dir) {
  const bin = path.join(dir, "bin");
  fs.mkdirSync(bin, { recursive: true });
  for (const opener of ["open", "xdg-open"]) {
    fs.writeFileSync(path.join(bin, opener), `#!/bin/sh\necho "$1" >> "${dir}/opened.txt"\n(curl -s -L -o /dev/null "$1" &)\n`, { mode: 0o755 });
  }
  return bin;
}

/** What a request to the fake provider carried: the tools declared (names and the JSON sent), the system prompt, the messages. */
export function requestSummary(entry) {
  const body = entry.body ?? {};
  const tools = body.tools ?? [];
  return {
    tools: tools.map((tool) => tool.function.name),
    toolsJSON: JSON.stringify(tools),
    system: (body.messages ?? []).filter((m) => m.role === "system" || m.role === "developer").map(messageText).join("\n"),
    messages: body.messages ?? [],
    body,
  };
}

export async function withPi(t, options, body) {
  const { settings = {}, files = () => ({}), project, args = [], env: extraEnv = {}, onRequest, cwd } = options;
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "pi-rpc-")));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const provider = await startProvider({ onRequest });
  t.after(() => provider.stop());
  const home = path.join(dir, "home");
  const work = path.join(dir, "work");
  fs.mkdirSync(home, { recursive: true });
  fs.mkdirSync(work, { recursive: true });
  fs.writeFileSync(path.join(home, "settings.json"), JSON.stringify({ retry: { enabled: false }, ...settings }));
  fs.writeFileSync(path.join(home, "models.json"), JSON.stringify({ providers: { fixture: {
    baseUrl: `http://127.0.0.1:${provider.port}/v1`, api: "openai-completions", apiKey: "local-fixture-not-secret",
    models: [{ id: "fixture", name: "fixture", reasoning: false, input: ["text"], contextWindow: 64000, maxTokens: 1024, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
  } } }));
  for (const [name, content] of Object.entries(files(dir, work))) {
    const file = name.startsWith("/") ? name : path.join(home, name);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, typeof content === "string" ? content : JSON.stringify(content));
  }
  project?.(dir, work);
  const extra = typeof extraEnv === "function" ? extraEnv(dir, work) : extraEnv;
  const env = { PATH: process.env.PATH, HOME: dir, PI_CODING_AGENT_DIR: home, PI_OFFLINE: "1", PI_SKIP_VERSION_CHECK: "1", PI_TELEMETRY: "0", ...extra };
  const child = spawn(process.execPath, [path.join(pkg, "dist/bundle/cli.js"), "--mode", "rpc", "--session-dir", path.join(dir, "sessions"),
    "--model", "fixture/fixture", ...args], { cwd: cwd?.(dir, work) ?? work, env, stdio: ["pipe", "pipe", "pipe"] });
  t.after(() => child.kill("SIGKILL"));
  const events = [];
  let out = "", err = "", next = 0;
  child.stdout.on("data", (chunk) => {
    out += chunk;
    for (let nl; (nl = out.indexOf("\n")) >= 0; out = out.slice(nl + 1)) { try { events.push(JSON.parse(out.slice(0, nl))); } catch {} }
  });
  child.stderr.on("data", (chunk) => { err += chunk; });
  child.stdin.on("error", () => {});
  const pi = {
    dir, home, work, events, provider, child, get stderr() { return err; },
    async request(command) {
      const id = `r${++next}`;
      child.stdin.write(JSON.stringify({ id, ...command }) + "\n");
      await until(`the answer to ${command.type}`, () => events.some((e) => e.type === "response" && e.id === id));
      return events.find((e) => e.type === "response" && e.id === id);
    },
    async commands() { return (await pi.request({ type: "get_commands" })).data.commands; },
    /** Sends a prompt and waits for the turn to settle; resolves with the provider requests the turn made, summarized. */
    async prompt(message = "hello", timeout = 60000) {
      const from = pi.provider.requests.length;
      const mark = events.length;
      const reply = await pi.request({ type: "prompt", message });
      await until("the turn to settle", () => events.slice(mark).some((e) => e.type === "agent_settled"), timeout);
      return { reply, requests: pi.provider.requests.slice(from).map(requestSummary), events: events.slice(mark) };
    },
    /** What a first model call is sent: the tools declared and the system prompt. */
    async promptSent(message = "hello") {
      const turn = await pi.prompt(message);
      return turn.requests[0];
    },
    /** The tool_execution_* events from `events`, by phase. */
    toolEvents: (list = events) => list.filter((e) => /^tool_execution_/.test(e.type)),
    spawned: (name) => fs.existsSync(path.join(dir, `${name}.pid`)),
  };
  await body(pi);
}
