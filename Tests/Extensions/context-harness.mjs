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
// shepherd-cliproxyapi.ts), each with the settings switch that turns it off.
export const THREAD_EXTENSIONS = [
  ["cliproxyapi", "shepherd-cliproxyapi.ts"], ["status", "shepherd-status.ts"], ["service-tier", "shepherd-service-tier.ts"],
  ["instructions", "shepherd-instructions.ts"], ["panes", "shepherd-panes.ts"], ["review", "shepherd-review.ts"],
  ["subagents", "shepherd-subagents.ts"], ["children", "shepherd-children.ts"], ["namer", "shepherd-namer.ts"],
  ["design", "shepherd-design.ts"], ["design-refs", "shepherd-design-refs.ts"], ["mcp", "shepherd-mcp.ts"],
  ["browser", "shepherd-browser.ts"], ["context", "shepherd-context.ts"],
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

// A GitHub-shaped MCP server's tools, the way a server describes them: what "Each tool on its own" puts in the prompt.
const MCP_TOOLS = [
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

function mcpFixture(dir) {
  const stdio = (name) => ({ command: "node", args: [path.join(dir, `${name}.mjs`)] });
  const entries = {
    docs: { ...stdio("docs") },
    notes: { ...stdio("notes") },
    github: { ...stdio("github"), shepherd: { exposure: "direct" } },
  };
  const bare = (entry) => { const { shepherd: _shepherd, ...rest } = entry; return rest; };
  const tools = MCP_TOOLS.map(([name, description, props]) => ({
    name, description,
    inputSchema: { type: "object", properties: Object.fromEntries(Object.entries(props).map(([key, text]) => [key, { type: "string", description: text }])), required: Object.keys(props).slice(0, 2) },
  }));
  const config = path.join(dir, "mcp.json");
  fs.writeFileSync(config, JSON.stringify({ mcpServers: entries }));
  const cache = path.join(dir, "tools.json");
  fs.writeFileSync(cache, JSON.stringify({ github: { entry: bare(entries.github), tools } }));
  return { config, cache };
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
 * - `trim`: the context-trimming extension's switch (SHEPHERD_EXT_CONTEXT), on unless false.
 * - `settings`: keys for the pi home's settings.json; `env`: extra environment; `onRequest`/`usage`: the provider's hooks.
 */
export async function startThread(options = {}) {
  const pkg = options.pkg ?? process.env.PI_PACKAGE_DIR;
  if (!pkg) throw Error("Set PI_PACKAGE_DIR to the installed pi package");
  const api = options.api ?? "openai-responses";
  // A design's agent has the design tools instead of panes, and never the browser or design references.
  const designAgent = !!options.design;
  const notForDesign = ["panes", "browser", "design-refs"];
  const names = options.extensions === "none" ? [] : (Array.isArray(options.extensions) ? options.extensions : THREAD_EXTENSIONS.map(([name]) => name))
    .filter((name) => (name === "design" ? designAgent : !(designAgent && notForDesign.includes(name))));
  const wants = (name) => names.includes(name);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sh-ctx-"));
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

  const fake = await startProvider({ onRequest: options.onRequest, usage: options.usage });
  const model = { id: "gpt-6-sol", name: "gpt-6-sol", reasoning: false, input: ["text"], contextWindow: options.contextWindow ?? 272000, maxTokens: 8192,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } };
  const baseUrl = `http://127.0.0.1:${fake.port}${api === "anthropic-messages" ? "" : "/v1"}`;
  fs.writeFileSync(path.join(config, "models.json"), JSON.stringify({ providers: { openai: { baseUrl, apiKey: "fixture-not-secret", api, models: [model] } } }));

  // The app's extension socket: connections are accepted and never answered.
  const socketPath = path.join(dir, "s");
  const sockets = new Set();
  const app = net.createServer((socket) => { sockets.add(socket); socket.on("data", () => {}); socket.on("error", () => {}); socket.on("close", () => sockets.delete(socket)); });
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
  if (names.length === 0) args.push("-ne", "-ns", "-np", "--no-context-files");
  if (options.skills === false && names.length > 0) args.push("-ns");
  for (const [name, file] of THREAD_EXTENSIONS) {
    if (!wants(name)) continue;
    if (name === "design-refs" && !options.designRefs) continue;
    if (name === "mcp" && options.mcp === false) continue;
    if (name === "context" && options.trim === false) continue;
    if (!fs.existsSync(extension(file))) continue;
    args.push("-e", extension(file));
  }
  if (names.length > 0) {
    Object.assign(env, { SHEPHERD_AGENT_ID: "agent-fixture", SHEPHERD_SOCKET: socketPath, SHEPHERD_EXT_STATUS: extension("shepherd-status.ts") });
    if (wants("panes")) env.SHEPHERD_EXT_PANES = extension("shepherd-panes.ts");
    if (wants("browser")) env.SHEPHERD_EXT_BROWSER = extension("shepherd-browser.ts");
    if (designAgent) Object.assign(env, { SHEPHERD_DESIGN_ID: "design-fixture", SHEPHERD_DESIGN_SKILL_DIR: path.join(root, "Extensions", "design-skill") });
    if (options.instructions !== false) env.SHEPHERD_INSTRUCTIONS_DIR = instructions;
    if (wants("children")) Object.assign(env, { SHEPHERD_NATIVE_CHILDREN: "1", SHEPHERD_EXT_CHILDREN: extension("shepherd-children.ts"), SHEPHERD_CHILD_CONCURRENCY: "4",
      SHEPHERD_CHILD_MODEL: "", SHEPHERD_CHILD_THINKING: "", SHEPHERD_CHILD_CONTEXT: "fresh", SHEPHERD_CHILD_SCOPE: "both" });
    if (options.needsName !== false) env.SHEPHERD_NEEDS_NAME = "1";
    if (options.automation) env.SHEPHERD_AUTOMATION = "1";
    if (options.designRefs) env.SHEPHERD_DESIGN_REFS = options.designRefs === "granted" ? "granted" : "on";
    const tier = path.join(dir, "tier.json");
    fs.writeFileSync(tier, JSON.stringify({ tier: "standard" }));
    env.SHEPHERD_EXT_SERVICE_TIER = tier;
    if (options.mcp !== false) {
      const mcp = mcpFixture(support);
      Object.assign(env, { SHEPHERD_EXT_MCP: extension("shepherd-mcp.ts"), SHEPHERD_EXT_MCP_CLIENT: extension("shepherd-mcp-client.mjs"), SHEPHERD_EXT_MCP_CONFIG: mcp.config, SHEPHERD_EXT_MCP_CACHE: mcp.cache });
    }
    if (wants("context") && options.trim !== false) env.SHEPHERD_EXT_CONTEXT = extension("shepherd-context.ts");
  }
  Object.assign(env, options.env);
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
    dir, project, config, fake, events, env, extensionsLoaded: names,
    get stderr() { return err; },
    settled: () => events.filter((e) => e.type === "agent_settled").length,
    async request(command) {
      const id = `r${++next}`;
      child.stdin.write(JSON.stringify({ id, ...command }) + "\n");
      await until(`the answer to ${command.type}`, () => events.some((e) => e.type === "response" && e.id === id));
      return events.find((e) => e.type === "response" && e.id === id);
    },
    // Sends a prompt and waits for the turn to settle.
    async turn(message = "hi") {
      const before = thread.settled();
      const reply = await thread.request({ type: "prompt", message });
      if (!reply.success) throw Error(`prompt refused: ${JSON.stringify(reply)}`);
      await until("the turn to settle", () => thread.settled() === before + 1);
    },
    async messages() { return (await thread.request({ type: "get_messages" })).data.messages; },
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
      fs.rmSync(dir, { recursive: true, force: true });
    },
  };
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
    // A built-in's source is "<builtin:read>"; an extension's is a path, kept relative to the repository.
    const sources = Object.fromEntries(seen.all.map((tool) => [tool.name,
      !tool.source ? "" : tool.source.startsWith("<") ? tool.source : path.relative(root, tool.source).replaceAll(path.sep, "/")]));
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
  "thread-without-mcp-or-skills": { mcp: false, skills: false },
  "thread-with-design-reference": { designRefs: "granted" },
  automation: { automation: true },
  design: { design: true },
};

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const flag = (name, fallback) => { const i = process.argv.indexOf(`--${name}`); return i >= 0 ? process.argv[i + 1] : fallback; };
  const pkg = flag("pi", process.env.PI_PACKAGE_DIR);
  const api = flag("api", "openai-responses");
  const wanted = (flag("scenario", Object.keys(SCENARIOS).join(","))).split(",");
  const result = { api, scenarios: {} };
  for (const name of wanted) result.scenarios[name] = await capture(name, { pkg, api });
  result.piVersion = JSON.parse(fs.readFileSync(path.join(pkg, "package.json"), "utf8")).version;
  process.stdout.write(JSON.stringify(result) + "\n", () => process.exit(0));
}
