// A real pi, launched the way Shepherd launches an agent's, on a fake provider that records every request.
// It is what the context budget (scripts/context_budget.py, docs/context-budget.md) measures and what the
// context-trimming tests drive: the extensions in PiLaunch's order with the environment the app gives them,
// Settings ▸ Instructions' files, the project's AGENTS.md, some skills, MCP servers, a socket standing in for
// the app. Nothing here touches the network, the user's pi or the app's support directory: one temporary HOME.
//
// As a library: `const thread = await startThread({ pkg })`; `await thread.turn("hi")`; `thread.mainRequests()`.
// As a program (what scripts/context_budget.py runs):
//   node context-harness.mjs --pi <pi package dir> [--api openai-responses] [--scenario thread|bare|...]
// prints one JSON document with what each scenario's first model request carried.
import * as fs from "node:fs";
import * as net from "node:net";
import * as os from "node:os";
import * as path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { startProvider } from "./fake-provider.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
export const root = path.resolve(here, "../..");
const fixtures = path.join(here, "fixtures", "context-budget");
const extension = (name) => path.join(root, "Extensions", name);

// The agent's extensions in the order the app loads them (PiLaunch.agent, after the launcher's own
// shepherd-cliproxyapi.ts), each with the settings switch that turns it off. "mcp" is no file: an agent's launch
// passes `-e builtin:mcp -e builtin:tool-search` (docs/mcp.md), which switches pi's own MCP on.
export const THREAD_EXTENSIONS = [
  ["cliproxyapi", "shepherd-cliproxyapi.ts"], ["status", "shepherd-status.ts"], ["service-tier", "shepherd-service-tier.ts"],
  ["instructions", "shepherd-instructions.ts"], ["panes", "shepherd-panes.ts"], ["review", "shepherd-review.ts"],
  ["subagents", "shepherd-subagents.ts"], ["children", "shepherd-children.ts"], ["goal", "shepherd-goal.ts"], ["namer", "shepherd-namer.ts"],
  ["design", "shepherd-design.ts"], ["design-refs", "shepherd-design-refs.ts"],
  ["browser", "shepherd-browser.ts"], ["mcp", null], ["context", "shepherd-context.ts"],
];

// Skills as a user's pi home might hold: a name and a one-sentence description each.
const SKILLS = [
  ["swiftui-specialist", "Authoritative SwiftUI best practices and performance guidance from Apple; consult for any SwiftUI code, animation, Environment, Observable, lists and localization."],
  ["frontend-design", "Guidance for distinctive, intentional visual design when building new UI or reshaping an existing one. Helps with aesthetic direction, typography and layout."],
  ["pdf", "Use this skill whenever the user wants to do anything with PDF files: read or extract text and tables, merge, split, rotate, watermark, fill forms, OCR."],
  ["code-review", "Review the current diff or a pull request for correctness bugs at a given effort level; can post findings as inline comments or apply fixes."],
  ["claude-api", "Reference for the Claude API and Anthropic SDK: model ids, pricing, parameters, streaming, tool use, MCP, caching, token counting and model migration."],
  ["modernize-tests", "Modernize test suites to use modern Swift Testing features or migrate from XCTest."],
];

// A GitHub-shaped MCP server's tools, the way a server describes them: what a server on Direct puts in the prompt.
export const MCP_TOOLS = [
  ["create_issue", "Create a new issue in a GitHub repository", { owner: "Repository owner", repo: "Repository name", title: "Issue title", body: "Issue body", labels: "Labels to apply", assignees: "Usernames to assign" }],
  ["get_issue", "Get the contents of an issue within a repository", { owner: "Repository owner", repo: "Repository name", issue_number: "Issue number" }],
  ["list_issues", "List issues in a GitHub repository with filtering and pagination", { owner: "Repository owner", repo: "Repository name", state: "open, closed or all", labels: "Labels to filter by", sort: "created, updated or comments", direction: "asc or desc", since: "ISO 8601 timestamp", page: "Page number", per_page: "Results per page" }],
  ["update_issue", "Update an existing issue in a GitHub repository", { owner: "Repository owner", repo: "Repository name", issue_number: "Issue number to update", title: "New title", body: "New description", state: "New state", labels: "New labels", assignees: "New assignees" }],
  ["create_pull_request", "Create a new pull request in a GitHub repository", { owner: "Repository owner", repo: "Repository name", title: "PR title", body: "PR description", head: "The name of the branch where your changes are implemented", base: "The name of the branch you want the changes pulled into", draft: "Create as draft PR", maintainer_can_modify: "Allow maintainers to modify the PR" }],
  ["get_pull_request", "Get details of a specific pull request", { owner: "Repository owner", repo: "Repository name", pull_number: "Pull request number" }],
  ["get_pull_request_files", "Get the list of files changed in a pull request", { owner: "Repository owner", repo: "Repository name", pull_number: "Pull request number" }],
  ["search_code", "Search for code across GitHub repositories", { q: "Search query using GitHub code search syntax", sort: "Sort field", order: "Sort order", page: "Page number", per_page: "Results per page" }],
  ["get_file_contents", "Get the contents of a file or directory from a GitHub repository", { owner: "Repository owner", repo: "Repository name", path: "Path to the file or directory", branch: "Branch to get contents from" }],
  ["push_files", "Push multiple files to a GitHub repository in a single commit", { owner: "Repository owner", repo: "Repository name", branch: "Branch to push to", files: "Array of files to push", message: "Commit message" }],
];

// Three stdio stand-ins (fixtures/fake-mcp-stdio.mjs) in the file the app derives into the pi home (`<home>/mcp.json`, pi's
// format): two on Search (pi's `deferred`) and one on Direct serving the tools above, so the budget measures pi's own
// `tool_search`, its `<mcp_servers>` section and the tools of a Direct server on a real pi.
export const MCP_SERVERS = ["docs", "notes", "github"];
function mcpFixture(dir, home) {
  const stdio = path.join(here, "fixtures", "fake-mcp-stdio.mjs");
  const catalog = path.join(dir, "github-tools.json");
  fs.writeFileSync(catalog, JSON.stringify(MCP_TOOLS.map(([name, description, props]) => ({
    name, description,
    inputSchema: { type: "object", properties: Object.fromEntries(Object.entries(props).map(([key, text]) => [key, { type: "string", description: text }])), required: Object.keys(props).slice(0, 2) },
  }))));
  const server = (extra) => ({ command: process.execPath, args: [stdio], ...extra });
  fs.writeFileSync(path.join(home, "mcp.json"), JSON.stringify({ mcpServers: {
    docs: server({ exposure: "deferred" }),
    notes: server({ exposure: "deferred" }),
    github: server({ exposure: "direct", env: { FAKE_MCP_CATALOG_FILE: catalog } }),
  } }));
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(what, fn, timeout = 60000) {
  const end = Date.now() + timeout;
  while (!fn()) { if (Date.now() > end) throw Error(`Timed out waiting for ${what}`); await sleep(15); }
}

/**
 * Starts pi in RPC mode as an agent's pi.
 *
 * - `extensions`: "shepherd" (an ordinary thread's, the default), "none" (pi alone), or a list of the names above.
 * - `instructions`: Settings ▸ Instructions' files (the default), or false for none.
 * - `project`: the project's AGENTS.md text (default: the repository's own), or false for none.
 * - `skills`, `mcp`: the fixtures above, on by default for a thread.
 * - `designRefs`: SHEPHERD_DESIGN_REFS ("on" or "granted"); `automation`: SHEPHERD_AUTOMATION=1.
 * - `defer`: Settings ▸ Agents ▸ Context ▸ Defer rarely used tools (on for a thread and an automation, never for a design's agent):
 *   SHEPHERD_DEFER_TOOLS=1, and pi's tool_search in the launch even when MCP is off. `defer: false` is every tool direct.
 * - `helper`: a native subagent's pi, launched as childLaunch (shepherd-children.ts) does: no extension but the bridge, a tool allowlist
 *   (pi's four and shepherd_parent_message), the project's context files, none of the app's variables.
 * - `toolSearch: false`: no pi tool_search in the launch (the Defer switch on with MCP off is the only way the app starts one without MCP).
 * - `dir`, `keepDir`: the temporary folder to use, and not to remove it on stop: a second launch in it resumes the first's session.
 * - `compat`: the fake model's `compat` (pi's per-model switches, such as `supportsAdditionalTools`).
 * - `onFrame(frame, reply)`: the app's side of the extension socket, which answers a tool's request (`thread.frames` keeps them all).
 * - `trim`: the context-trimming extension's switch (SHEPHERD_EXT_CONTEXT): on, `false` (off: not loaded), or "inert"
 *   (loaded without its variable).
 * - `settings`: keys for the pi home's settings.json; `env`: extra environment; `onRequest`/`usage`: the provider's hooks.
 */
export async function startThread(options = {}) {
  const pkg = options.pkg ?? process.env.PI_PACKAGE_DIR;
  if (!pkg) throw Error("Set PI_PACKAGE_DIR to the installed pi package");
  const api = options.api ?? "openai-responses";
  // A design's agent has the design tools instead of panes, and never the browser, a diff review or design references.
  const designAgent = !!options.design;
  const helper = !!options.helper;
  const deferOn = options.defer ?? !(designAgent || helper);
  const notForDesign = ["panes", "review", "browser", "design-refs"];
  const names = helper ? ["children"] : options.extensions === "none" ? [] : (Array.isArray(options.extensions) ? options.extensions : THREAD_EXTENSIONS.map(([name]) => name))
    .filter((name) => (name === "design" ? designAgent : !(designAgent && notForDesign.includes(name))));
  const wants = (name) => names.includes(name);
  const dir = options.dir ?? fs.mkdtempSync(path.join(os.tmpdir(), "sh-ctx-"));
  const config = path.join(dir, "pi");
  const support = path.join(dir, "support");
  const project = path.join(dir, "project");
  const instructions = path.join(support, "instructions");
  for (const folder of [config, instructions, project, path.join(config, "skills")]) fs.mkdirSync(folder, { recursive: true });

  const projectText = options.project === undefined ? fs.readFileSync(path.join(root, "AGENTS.md"), "utf8") : options.project;
  if (projectText) fs.writeFileSync(path.join(project, "AGENTS.md"), projectText);
  if (options.instructions !== false) {
    fs.copyFileSync(path.join(fixtures, "global-AGENTS.md"), path.join(instructions, "AGENTS.md"));
    fs.copyFileSync(path.join(fixtures, "APPEND_SYSTEM.md"), path.join(instructions, "APPEND_SYSTEM.md"));
  }
  if (options.skills !== false) {
    for (const [name, description] of SKILLS) {
      fs.mkdirSync(path.join(config, "skills", name), { recursive: true });
      fs.writeFileSync(path.join(config, "skills", name, "SKILL.md"), `---\nname: ${name}\ndescription: ${description}\n---\n\n# ${name}\n\nSteps.\n`);
    }
  }
  fs.writeFileSync(path.join(config, "settings.json"), JSON.stringify({ retry: { enabled: false }, compaction: { enabled: false }, transport: "sse", ...options.settings }));

  const fake = await startProvider({ onRequest: options.onRequest, usage: options.usage, uniqueIds: true });
  const model = { id: "gpt-6-sol", name: "gpt-6-sol", reasoning: false, input: ["text"], contextWindow: options.contextWindow ?? 272000, maxTokens: 8192,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, ...(options.compat ? { compat: options.compat } : {}) };
  const baseUrl = `http://127.0.0.1:${fake.port}${api === "anthropic-messages" ? "" : "/v1"}`;
  fs.writeFileSync(path.join(config, "models.json"), JSON.stringify({ providers: { openai: { baseUrl, apiKey: "fixture-not-secret", api, models: [model] } } }));

  // The app's extension socket: connections are accepted and, unless `onFrame` answers, never answered. `frames` is every
  // frame the extensions sent, in order.
  const socketPath = path.join(dir, "s");
  const sockets = new Set();
  const frames = [];
  const app = net.createServer((socket) => {
    sockets.add(socket);
    let buffered = "";
    socket.on("data", (chunk) => {
      buffered += chunk;
      for (let nl; (nl = buffered.indexOf("\n")) >= 0; buffered = buffered.slice(nl + 1)) {
        try {
          const frame = JSON.parse(buffered.slice(0, nl));
          frames.push(frame);
          options.onFrame?.(frame, (reply) => socket.write(JSON.stringify(reply) + "\n"));
        } catch {}
      }
    });
    socket.on("error", () => {});
    socket.on("close", () => sockets.delete(socket));
  });
  await new Promise((resolve) => app.listen(socketPath, resolve));

  // What every extension registered, and where from: written once before the first request.
  const probeOut = path.join(dir, "tools.json");
  const probe = path.join(dir, "probe.ts");
  fs.writeFileSync(probe, `export default function (pi) {
    pi.on("before_agent_start", () => {
      try { require("node:fs").writeFileSync(${JSON.stringify(probeOut)}, JSON.stringify({ all: pi.getAllTools().map((t) => ({ name: t.name, source: t.sourceInfo?.path })), active: pi.getActiveTools() })); } catch {}
    });
  }`);

  const env = { PATH: process.env.PATH, HOME: dir, PI_CODING_AGENT_DIR: config, PI_OFFLINE: "1", PI_SKIP_VERSION_CHECK: "1", PI_TELEMETRY: "0",
    PI_PACKAGE_DIR: pkg, SHEPHERD_MODEL: "openai/gpt-6-sol" };
  const args = [path.join(pkg, "dist/bundle/cli.js"), "--mode", "rpc", "--session-dir", path.join(dir, "sessions"), "--session-id", options.sessionID ?? "7f1d2c3a-0000-4000-8000-000000000001",
    "--model", "openai/gpt-6-sol"];
  // -ne keeps pi from discovering extensions of its own (and, in pi 1.0, loading its built-in ones); each -e still loads.
  args.push("-ne");
  if (names.length === 0) args.push("-ns", "-np", "--no-context-files");
  if (options.skills === false && names.length > 0) args.push("-ns");
  const HELPER_TOOLS = ["read", "bash", "edit", "write", "shepherd_parent_message"];
  if (helper) args.push("-ns", "-np", "--no-themes", "--no-approve", "--tools", HELPER_TOOLS.join(","));
  for (const [name, file] of THREAD_EXTENSIONS) {
    if (!wants(name)) continue;
    if (name === "design-refs" && !options.designRefs) continue;
    if (name === "mcp") {
      const toolSearch = options.toolSearch !== false;
      if (options.mcp !== false) args.push("-e", "builtin:mcp", ...(toolSearch ? ["-e", "builtin:tool-search"] : []));
      else if (deferOn && toolSearch) args.push("-e", "builtin:tool-search");
      continue;
    }
    if (name === "context" && options.trim === false) continue;
    if (!fs.existsSync(extension(file))) continue;
    args.push("-e", extension(file));
  }
  if (helper) {
    Object.assign(env, { SHEPHERD_CHILD: "1", SHEPHERD_CHILD_TOOLS: JSON.stringify(HELPER_TOOLS) });
  } else if (names.length > 0) {
    Object.assign(env, { SHEPHERD_AGENT_ID: "agent-fixture", SHEPHERD_SOCKET: socketPath, SHEPHERD_EXT_STATUS: extension("shepherd-status.ts") });
    if (wants("panes")) env.SHEPHERD_EXT_PANES = extension("shepherd-panes.ts");
    if (wants("browser")) env.SHEPHERD_EXT_BROWSER = extension("shepherd-browser.ts");
    if (designAgent) Object.assign(env, { SHEPHERD_DESIGN_ID: "design-fixture", SHEPHERD_DESIGN_SKILL_DIR: path.join(root, "Extensions", "design-skill") });
    if (options.instructions !== false) env.SHEPHERD_INSTRUCTIONS_DIR = instructions;
    if (wants("children")) Object.assign(env, { SHEPHERD_NATIVE_CHILDREN: "1", SHEPHERD_EXT_CHILDREN: extension("shepherd-children.ts"), SHEPHERD_CHILD_CONCURRENCY: "4",
      SHEPHERD_CHILD_MODEL: "", SHEPHERD_CHILD_THINKING: "", SHEPHERD_CHILD_CONTEXT: "fresh", SHEPHERD_CHILD_SCOPE: "both" });
    // The goal controller is loaded in every agent and does nothing until a goal is set (the experiment is off here).
    if (wants("goal")) Object.assign(env, { SHEPHERD_EXT_GOAL: "1", SHEPHERD_GOALS_ENABLED: "0", SHEPHERD_GOAL_MODELS: "" });
    if (options.needsName !== false) env.SHEPHERD_NEEDS_NAME = "1";
    if (options.automation) env.SHEPHERD_AUTOMATION = "1";
    if (deferOn) env.SHEPHERD_DEFER_TOOLS = "1";
    if (options.designRefs) env.SHEPHERD_DESIGN_REFS = options.designRefs === "granted" ? "granted" : "on";
    const tier = path.join(dir, "tier.json");
    fs.writeFileSync(tier, JSON.stringify({ tier: "standard" }));
    env.SHEPHERD_EXT_SERVICE_TIER = tier;
    if (wants("mcp") && options.mcp !== false) mcpFixture(support, config);
    // trim: false is the switch off (the app passes no -e and no variable); "inert" loads the file without its variable.
    if (wants("context") && options.trim !== false && options.trim !== "inert") env.SHEPHERD_EXT_CONTEXT = extension("shepherd-context.ts");
  }
  Object.assign(env, options.env);
  for (const file of options.extra ?? []) args.push("-e", file);
  args.push("-e", probe);

  const child = spawn(process.execPath, args, { cwd: project, stdio: ["pipe", "pipe", "pipe"], env });
  const events = [];
  let out = "", err = "", next = 0;
  child.stdout.on("data", (chunk) => {
    out += chunk;
    for (let nl; (nl = out.indexOf("\n")) >= 0; out = out.slice(nl + 1)) { try { events.push(JSON.parse(out.slice(0, nl))); } catch {} }
  });
  child.stderr.on("data", (chunk) => { err += chunk; });
  child.stdin.on("error", () => {});
  const exited = new Promise((resolve) => child.once("exit", resolve));

  const thread = {
    dir, project, config, fake, events, env, frames, extensionsLoaded: names,
    get stderr() { return err; },
    settled: () => events.filter((e) => e.type === "agent_settled").length,
    async request(command) {
      const id = `r${++next}`;
      child.stdin.write(JSON.stringify({ id, ...command }) + "\n");
      await until(`the answer to ${command.type}`, () => events.some((e) => e.type === "response" && e.id === id));
      return events.find((e) => e.type === "response" && e.id === id);
    },
    // Sends a prompt and waits for the turn to settle.
    async turn(message = "hi", timeout = 60000) {
      const before = thread.settled();
      const reply = await thread.request({ type: "prompt", message });
      if (!reply.success) throw Error(`prompt refused: ${JSON.stringify(reply)}`);
      await until("the turn to settle", () => thread.settled() === before + 1, timeout);
    },
    async messages() { return (await thread.request({ type: "get_messages" })).data.messages; },
    // pi connects its MCP servers in the background after it starts, and a first request waits only for a server on
    // Direct: the prompt lists a server on Search once it is connected, so a measurement waits for all of them (`/mcp`
    // is answered by pi itself and reaches no model).
    async waitForMcpServers(timeout = 30000) {
      const end = Date.now() + timeout;
      for (;;) {
        const mark = events.length;
        await thread.request({ type: "prompt", message: "/mcp" });
        await sleep(40);
        const notice = events.slice(mark).filter((e) => e.type === "extension_ui_request" && e.method === "notify").map((e) => e.message).join("\n");
        if (MCP_SERVERS.every((name) => new RegExp(`^${name}: connected`, "m").test(notice))) return;
        if (Date.now() > end) throw Error(`the MCP servers never connected: ${notice}`);
      }
    },
    // The requests the thread's own model calls made, not the namer's side request.
    mainRequests() { return fake.requests.filter((r) => (r.body?.tools ?? r.body?.messages) && !isNamer(r)); },
    tools() { try { return JSON.parse(fs.readFileSync(probeOut, "utf8")); } catch { return { all: [], active: [] }; } },
    sessionFile() {
      const folder = path.join(dir, "sessions");
      const walk = (d) => fs.readdirSync(d, { withFileTypes: true }).flatMap((e) => e.isDirectory() ? walk(path.join(d, e.name)) : [path.join(d, e.name)]);
      return walk(folder).find((f) => f.endsWith(".jsonl"));
    },
    async stop() {
      child.kill();
      await exited;
      for (const socket of sockets) socket.destroy();
      app.close();
      await fake.stop();
      if (!options.keepDir) fs.rmSync(dir, { recursive: true, force: true });
    },
  };
  if (wants("mcp") && options.mcp !== false && names.length > 0) await thread.waitForMcpServers();
  return thread;
}

// The namer's call (Settings ▸ Agents ▸ Name threads automatically) is a separate one-tool request, never the thread's.
function isNamer(request) {
  const tools = request.body?.tools ?? [];
  return tools.length === 1 && (tools[0].name ?? tools[0].function?.name) === "propose_title";
}

/** What a scenario's first model request carried, as plain data for scripts/context_budget.py. */
export async function capture(scenario, options = {}) {
  const spec = SCENARIOS[scenario];
  if (!spec) throw Error(`unknown scenario ${scenario}`);
  const thread = await startThread({ ...spec, ...options });
  try {
    await thread.turn("Hello");
    const [request] = thread.mainRequests();
    if (!request) throw Error(`no model request was recorded (${thread.stderr.slice(0, 500)})`);
    const seen = thread.tools();
    // A built-in's source is "<builtin:read>" (pi 1.0: "builtin:read"); an extension's is a path, kept relative to the repository.
    const sourceOf = (source) => !source ? "" : source.startsWith("<") ? source : source.startsWith("builtin:") ? `<${source}>`
      : path.relative(root, source).replaceAll(path.sep, "/");
    const sources = Object.fromEntries(seen.all.map((tool) => [tool.name, sourceOf(tool.source)]));
    return { scenario, path: request.path, body: request.body, toolSources: sources, activeTools: seen.active, projectFile: path.join(thread.project, "AGENTS.md"),
      loaded: thread.extensionsLoaded };
  } finally {
    await thread.stop();
  }
}

// The launches the budget measures. `bare` is pi alone; `thread` an ordinary agent; the others change one switch of it.
export const SCENARIOS = {
  bare: { extensions: "none", instructions: false, skills: false, mcp: false, project: false },
  thread: {},
  "thread-defer-off": { defer: false },
  "thread-without-mcp-or-skills": { mcp: false, skills: false },
  "thread-with-design-reference": { designRefs: "granted" },
  automation: { automation: true },
  "automation-defer-off": { automation: true, defer: false },
  design: { design: true },
  subagent: { helper: true, instructions: false, skills: false, mcp: false },
};

/**
 * A fake provider's script for a Responses-API thread: in the turn the user's Nth message opens (counting from
 * zero), the model makes the tool calls `plan[N]` lists, one command each in order (a string, or `{ command,
 * reasoning }` with that many characters of reasoning payload before the call, or `{ tool: { name, arguments } }`
 * for a call to any other tool), then answers with text.
 * Only the thread's own requests call tools: a compaction's summary request and the namer's carry no bash.
 */
export function scriptedBashCalls(plan) {
  // The script follows the user's messages, not what is left in the request: a compaction takes earlier calls out of it.
  let lastText, turn = -1, issued = 0;
  return (entry) => {
    const input = entry.body?.input;
    if (!Array.isArray(input) || !(entry.body.tools ?? []).some((tool) => tool.name === "bash")) return {};
    const lastUser = input.findLast((item) => item.role === "user");
    const text = lastUser ? JSON.stringify(lastUser.content) : undefined;
    if (text !== undefined && text !== lastText) { lastText = text; turn++; issued = 0; }
    const steps = (typeof plan === "function" ? plan : (n) => plan[n] ?? [])(Math.max(turn, 0));
    const step = steps[issued];
    if (step === undefined) return {};
    issued++;
    if (typeof step === "string") return { call: step };
    return step.tool ? { tool: step.tool, reasoning: step.reasoning } : { call: step.command, reasoning: step.reasoning };
  };
}

const chars4 = (value) => Math.ceil(JSON.stringify(value).length / 4);

/**
 * A long thread, as numbers: each turn the model reads a big search result (about 11,600 tokens, pi's bash tool
 * returns up to 50 KB), a file (about 3,000) and runs a small command, then answers. Returns, for every turn, the
 * tokens of the last request it sent, and how much of each request repeated the one before it (what a provider's
 * prompt cache can reuse). `trim` is the context-trimming switch; `extraSteps(turn)` are tool calls a turn makes first
 * (a search that loads a deferred tool, and a call to it), and the rest of `options` goes to `startThread`.
 */
export async function simulate({ turns = 24, trim = true, pkg, extraSteps, ...options } = {}) {
  const row = (turn, call, count, width) =>
    `awk 'BEGIN{for(i=1;i<=${count};i++) printf "%d.${call}.%d ${"x".repeat(width)} %d\\n", ${turn}, i, i}'`;
  const plan = (turn) => [...(extraSteps?.(turn + 1) ?? []), row(turn + 1, 1, 800, 50), row(turn + 1, 2, 220, 45), "git status --short | head -5"];
  const thread = await startThread({ pkg, trim, needsName: false, onRequest: scriptedBashCalls(plan), usage: (entry) => ({ input: chars4(entry.body), output: 40 }), ...options });
  try {
    const perTurn = [];
    const requests = [];
    for (let turn = 1; turn <= turns; turn++) {
      const before = thread.mainRequests().length;
      await thread.turn(`turn ${turn}: look into the next part of the code`);
      const sent = thread.mainRequests();
      requests.push(...sent.slice(before));
      perTurn.push({ turn, tokens: chars4(sent.at(-1).body), requests: sent.length - before });
    }
    // What a prefix cache can reuse: the leading tool definitions and messages a request repeats from the one before.
    const prompt = (request) => [...(request.body.tools ?? []).map((t) => JSON.stringify(t)), ...request.body.input.map((item) => JSON.stringify(item))];
    const reuse = [];
    let sent = 0, billed = 0;
    const CACHED_PRICE = 0.1; // a cached input token costs a tenth of a new one (Anthropic's cache read; OpenAI's newer models are close)
    requests.forEach((request, i) => {
      const next = prompt(request);
      const total = next.reduce((sum, item) => sum + item.length, 0);
      let repeated = 0;
      if (i > 0) {
        const previous = prompt(requests[i - 1]);
        let same = 0;
        while (same < previous.length && previous[same] === next[same]) repeated += previous[same++].length;
        reuse.push(repeated / previous.reduce((sum, item) => sum + item.length, 0));
      }
      sent += total / 4;
      billed += (total - repeated) / 4 + (repeated / 4) * CACHED_PRICE;
    });
    return { perTurn, requests: requests.length, sentTokens: Math.round(sent), billedTokens: Math.round(billed),
      reuse: { mean: reuse.reduce((a, b) => a + b, 0) / Math.max(1, reuse.length), min: Math.min(...reuse), below: reuse.filter((r) => r < 0.999).length, of: reuse.length } };
  } finally {
    await thread.stop();
  }
}

/**
 * The same long thread with Shepherd's rarely used tools direct, and deferred: never loaded, and loaded by a search in
 * the turn `loadAt` (the model searches for the browser and opens a page), on a model whose provider cannot take a tool
 * in mid-conversation (pi sends the new tool list from the top of the request) and on one that can (`compat`, as the
 * newest OpenAI and Claude models do). Each is `simulate`'s result: what a request repeats from the one before it is what
 * a provider's prompt cache can reuse.
 */
export async function simulateDeferral({ turns = 24, loadAt = 6, pkg } = {}) {
  const load = (turn) => turn === loadAt
    ? [{ tool: { name: "tool_search", arguments: { query: "open a web page" } } }, { tool: { name: "browser_open", arguments: { url: "https://example.com/" } } }]
    : [];
  const onFrame = (frame, reply) => { if (frame.type === "browser") reply({ type: "browserResult", id: frame.id, text: "Page: Example" }); };
  const anchored = { supportsAdditionalTools: true, supportsMidConvoSystemMessages: true };
  return {
    turns, loadAt,
    direct: await simulate({ turns, pkg, defer: false, extraSteps: load, onFrame }),
    deferred: await simulate({ turns, pkg, onFrame }),
    loaded: await simulate({ turns, pkg, extraSteps: load, onFrame }),
    loadedAnchored: await simulate({ turns, pkg, extraSteps: load, onFrame, compat: anchored }),
    directAnchored: await simulate({ turns, pkg, defer: false, extraSteps: load, onFrame, compat: anchored }),
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const flag = (name, fallback) => { const i = process.argv.indexOf(`--${name}`); return i >= 0 ? process.argv[i + 1] : fallback; };
  const pkg = flag("pi", process.env.PI_PACKAGE_DIR);
  const api = flag("api", "openai-responses");
  const piVersion = JSON.parse(fs.readFileSync(path.join(pkg, "package.json"), "utf8")).version;
  if (process.argv.includes("--simulate-defer")) {
    const turns = Number(flag("turns", "24"));
    const result = { piVersion, ...(await simulateDeferral({ turns, loadAt: Number(flag("load-at", "6")), pkg })) };
    process.stdout.write(JSON.stringify(result) + "\n", () => process.exit(0));
  } else if (process.argv.includes("--simulate")) {
    const turns = Number(flag("turns", "24"));
    const result = { piVersion, turns, without: await simulate({ turns, trim: false, pkg }), with: await simulate({ turns, trim: true, pkg }) };
    process.stdout.write(JSON.stringify(result) + "\n", () => process.exit(0));
  } else {
    const wanted = (flag("scenario", Object.keys(SCENARIOS).join(","))).split(",");
    const result = { api, piVersion, scenarios: {} };
    for (const name of wanted) result.scenarios[name] = await capture(name, { pkg, api });
    process.stdout.write(JSON.stringify(result) + "\n", () => process.exit(0));
  }
}
