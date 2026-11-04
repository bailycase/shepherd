// The hooks runtime (docs/hooks.md) against a stand-in for pi's extension API: shared hash vectors,
// parsing (JSON and the Codex TOML subset), matchers, the off switch, exit codes, decision merging,
// updatedInput, the Stop send-back cap, additionalContext, and a proposal's write.
// Run: PI_PACKAGE_DIR=/path/to/pi-coding-agent node --test Tests/Extensions/shepherd-hooks.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const pkg = process.env.PI_PACKAGE_DIR;
if (!pkg) throw Error("Set PI_PACKAGE_DIR to the installed Pi package");
const { createJiti } = createRequire(path.join(pkg, "package.json"))("jiti");
const sdk = fs.existsSync(path.join(pkg, "dist/index.js")) ? path.join(pkg, "dist/index.js") : path.join(pkg, "dist/bundle/index.js");
const jiti = createJiti(import.meta.url, { alias: { "@earendil-works/pi-coding-agent": sdk, typebox: path.join(pkg, "node_modules/typebox/build/index.mjs") } });
const hooks = await jiti.import(path.join(root, "Extensions/shepherd-hooks.ts"));

// Every test runs with a scratch home and pi home: never the person's ~/.shepherd, ~/.claude or ~/.pi.
const scratch = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "sh-hooks-")));
process.env.HOME = path.join(scratch, "home");
process.env.PI_CODING_AGENT_DIR = path.join(scratch, "pi");
process.on("exit", () => fs.rmSync(scratch, { recursive: true, force: true }));
let counter = 0;

function fixture() {
  const dir = path.join(scratch, `t${counter++}`);
  const project = path.join(dir, "project"), hooksDir = path.join(dir, "hooks");
  fs.mkdirSync(project, { recursive: true });
  fs.mkdirSync(hooksDir, { recursive: true });
  fs.rmSync(process.env.HOME, { recursive: true, force: true });
  fs.mkdirSync(process.env.HOME, { recursive: true });
  return { dir, project, hooksDir, macFile: path.join(process.env.HOME, ".shepherd/hooks.json") };
}
const writeJSON = (file, value) => { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, JSON.stringify(value)); };
/** Writes settings.json: every handler of each `off` file switched off, and the readers. */
function settings(hooksDir, { off = [], readers } = {}) {
  const hashes = off.flatMap((file) => hooks.entriesOf(file, hooks.parseHookFile(file, fs.readFileSync(file, "utf8")).hooks).map((e) => e.hash));
  const file = path.join(hooksDir, "settings.json");
  writeJSON(file, { version: 1, off: hashes, ...(readers ? { readers } : {}) });
  // A distinct mtime so the runtime's mtime cache sees the change.
  const later = new Date(Date.now() + 1000 * ++counter);
  fs.utimesSync(file, later, later);
}

function load(hooksDir, env = {}) {
  const saved = { ...process.env };
  // The runner may itself be a Shepherd agent: start from none of the flags the extension reads.
  for (const key of ["SHEPHERD_DEFER_TOOLS", "SHEPHERD_AUTOMATION", "SHEPHERD_PROJECT_CONTEXT", "SHEPHERD_PROJECT_COORDINATOR", "SHEPHERD_DESIGN_ID"]) delete process.env[key];
  Object.assign(process.env, { SHEPHERD_HOOKS_DIR: hooksDir ?? "" }, env);
  if (hooksDir === undefined) delete process.env.SHEPHERD_HOOKS_DIR;
  const handlers = {}, tools = new Map(), sent = [], listeners = {};
  try {
    hooks.default({
      on: (name, fn) => (handlers[name] ??= []).push(fn),
      registerTool: (tool) => tools.set(tool.name, tool),
      sendMessage: (message, options) => sent.push({ ...message, options }),
      events: { on: (name, fn) => (listeners[name] ??= []).push(fn), emit: (name, data) => (listeners[name] ?? []).forEach((fn) => fn(data)) },
    });
  } finally {
    for (const key of Object.keys(process.env)) if (!(key in saved)) delete process.env[key];
    Object.assign(process.env, saved);
  }
  const emit = async (name, event, ctx) => { let result; for (const fn of handlers[name] ?? []) result = (await fn(event, ctx)) ?? result; return result; };
  return { handlers, tools, sent, emit, events: listeners };
}

function context(cwd, select = async () => undefined) {
  const prompts = [];
  return {
    prompts, cwd, hasUI: true, aborted: false,
    ui: { select: async (title, options) => { prompts.push({ title, options }); return select(title, options); }, setWorkingMessage() {}, setStatus() {} },
    sessionManager: { getSessionId: () => "session-1", getSessionFile: () => "/tmp/session-1.jsonl" },
    abort() { this.aborted = true; },
  };
}
const editCall = (p = "/tmp/a.txt") => ({ type: "tool_call", toolName: "edit", toolCallId: "c1", input: { path: p, edits: [] } });

test("canonical JSON and hashes match the shared vectors", () => {
  const vectors = JSON.parse(fs.readFileSync(path.join(root, "Tests/Fixtures/hooks/hash-vectors.json"), "utf8"));
  assert.ok(vectors.length >= 6);
  for (const v of vectors) {
    assert.equal(hooks.canonical(v.handler), v.canonical);
    assert.equal(hooks.hookHash(v.file, v.event, v.matcher, v.handler), v.hash);
  }
});

test("files parse into one shape with slots; the Codex TOML subset maps to it; bad files report a line", () => {
  const json = hooks.parseHookFile("/x/settings.json", JSON.stringify({ model: "x", hooks: { PreToolUse: [{ matcher: "Bash", hooks: [{ type: "command", command: "a" }, { type: "command", command: "b" }] }], Stop: [{ hooks: [{ type: "command", command: "c" }] }], Bogus: [] } }));
  const entries = hooks.entriesOf("/x/settings.json", json.hooks);
  assert.deepEqual(entries.map((e) => [e.slot, e.matcher]), [["/x/settings.json#PreToolUse/0/0", "Bash"], ["/x/settings.json#PreToolUse/0/1", "Bash"], ["/x/settings.json#Stop/0/0", ""]]);

  const toml = hooks.parseHookFile("/x/config.toml", [
    'model = "gpt-5"  # not a hook',
    "[mcp_servers.docs]",
    'args = ["--a", "--b"]',
    "[[hooks.PreToolUse]]",
    "matcher = 'Edit|Write' # literal",
    "[[hooks.PreToolUse.hooks]]",
    'type = "command"',
    'command = "echo \\"hi\\" # not a comment"',
    "timeout = 1_0",
    "async = false",
    "[[hooks.PreToolUse.hooks]]",
    "type = 'command'",
    "command = 'C:\\path'",
    "[[hooks.Stop]]",
    "[[hooks.Stop.hooks]]",
    'type = "command"',
    'command = "npm test"',
    "statusMessage = \"Testing\"",
    "[profile]",
    "x = [1, 2]",
  ].join("\n"));
  assert.equal(toml.error, undefined);
  assert.deepEqual(toml.hooks, {
    PreToolUse: [{ matcher: "Edit|Write", hooks: [{ type: "command", command: 'echo "hi" # not a comment', timeout: 10, async: false }, { type: "command", command: "C:\\path" }] }],
    Stop: [{ hooks: [{ type: "command", command: "npm test", statusMessage: "Testing" }] }],
  });
  assert.match(hooks.parseHookFile("/x/config.toml", "[[hooks.Stop]]\n[[hooks.Stop.hooks]]\ninput = { a = 1 }").error, /^Couldn't read: line 3, /);
  assert.match(hooks.parseHookFile("/x/hooks.json", '{\n  "hooks": {\n    oops\n}').error, /^Couldn't read: line 3, /);
});

test("files read as the catalog reads them: the shared parse cases", () => {
  const { cases } = JSON.parse(fs.readFileSync(path.join(root, "Tests/Fixtures/hooks/parse-cases.json"), "utf8"));
  assert.ok(cases.length >= 20);
  const dir = path.join(scratch, "parse-cases");
  fs.mkdirSync(dir, { recursive: true });
  for (const c of cases) {
    let bytes = c.hex ? Buffer.from(c.hex, "hex") : Buffer.from(c.text, "utf8");
    if (c.padTo) bytes = Buffer.concat([bytes, Buffer.alloc(c.padTo - bytes.length, " ")]);
    const file = path.join(dir, c.file);
    fs.writeFileSync(file, bytes);
    const parsed = hooks.parseHookBytes(file, fs.readFileSync(file));
    if (c.unreadable) {
      assert.ok(parsed.error, `${c.name}: unreadable`);
      assert.equal(Number(/^Couldn't read: line (\d+),/.exec(parsed.error)?.[1] ?? NaN) || null, c.unreadable.line, `${c.name}: ${parsed.error}`);
      assert.equal(hooks.entriesOf(file, parsed.hooks).length, 0, `${c.name}: contributes nothing`);
    } else {
      assert.equal(parsed.error, undefined, `${c.name}: ${parsed.error}`);
      assert.equal(hooks.entriesOf(file, parsed.hooks).length, c.entries, c.name);
    }
  }
});

test("matchers are anchored regexes that also match Claude Code tool names", () => {
  const m = hooks.matcherMatches;
  assert.ok(m("Edit|Write", "edit") && m("Edit|Write", "write") && !m("Edit|Write", "read"));
  assert.ok(m("MultiEdit", "edit") && m("Glob", "find") && m("LS", "ls") && m("Bash", "bash") && m("bash", "bash"));
  assert.ok(!m("Bas", "bash") && !m("ash", "bash"));
  assert.ok(m("", "anything") && m("*", "anything") && m(undefined, "x"));
  assert.ok(m("mcp__docs__.*", "mcp__docs__search") && !m("mcp__docs", "mcp__docs__search"));
  assert.ok(!m("(", "bash"), "an invalid regex matches nothing");
  assert.ok(m("startup|resume", "resume") && !m("startup", "compact"));
});

test("every configured hook runs unless switched off; settings apply on the next event; space files need no approval", async () => {
  const { project, hooksDir, macFile } = fixture();
  const marker = path.join(project, "ran.txt");
  const ran = () => (fs.existsSync(marker) ? fs.readFileSync(marker, "utf8").trim().split("\n") : []);
  writeJSON(macFile, { hooks: { PreToolUse: [{ matcher: "Edit", hooks: [{ type: "command", command: "echo mac >> ran.txt" }] }] } });
  const pi = load(hooksDir);
  const ctx = context(project);
  await pi.emit("tool_call", editCall(), ctx);
  assert.deepEqual(ran(), ["mac"], "no settings.json: it runs");
  settings(hooksDir, { off: [macFile] });
  await pi.emit("tool_call", editCall(), ctx);
  assert.deepEqual(ran(), ["mac"], "off: doesn't run");
  // Edited outside Shepherd: another hash, so it runs again.
  writeJSON(macFile, { hooks: { PreToolUse: [{ matcher: "Edit", hooks: [{ type: "command", command: "echo changed >> ran.txt" }] }] } });
  await pi.emit("tool_call", editCall(), ctx);
  assert.deepEqual(ran(), ["mac", "changed"]);
  fs.rmSync(marker);
  writeJSON(macFile, { hooks: {} });
  // A reader that is off hides its files.
  const claude = path.join(process.env.HOME, ".claude/settings.json");
  writeJSON(claude, { hooks: { PreToolUse: [{ hooks: [{ type: "command", command: "echo claude >> ran.txt" }] }] } });
  settings(hooksDir, { readers: { claude: false, codex: true } });
  await pi.emit("tool_call", editCall(), ctx);
  assert.deepEqual(ran(), []);
  settings(hooksDir, { readers: { claude: true, codex: true } });
  await pi.emit("tool_call", editCall(), ctx);
  assert.deepEqual(ran(), ["claude"]);
  // Space: the thread's root, with no approval anywhere.
  const space = path.join(project, ".shepherd/hooks.json");
  writeJSON(space, { hooks: { PreToolUse: [{ hooks: [{ type: "command", command: "echo space >> ran.txt" }] }] } });
  fs.rmSync(claude);
  await pi.emit("tool_call", editCall(), ctx);
  assert.deepEqual(ran(), ["claude", "space"]);
});

test("the home folder is never a space", async () => {
  const { hooksDir } = fixture();
  const home = process.env.HOME;
  const file = path.join(home, ".claude/settings.local.json");
  writeJSON(file, { hooks: { PreToolUse: [{ hooks: [{ type: "command", command: "echo home >> ran.txt" }] }] } });
  await load(hooksDir).emit("tool_call", editCall(), context(home));
  assert.equal(fs.existsSync(path.join(home, "ran.txt")), false);
});

test("a hook gets the event on stdin, runs in the root with its variables; exit 0, 2, other and a timeout", async () => {
  const { project, hooksDir, macFile } = fixture();
  writeJSON(macFile, { hooks: { PreToolUse: [
    { matcher: "Edit", hooks: [{ type: "command", command: 'cat > stdin.json; printf "%s %s" "$SHEPHERD_HOOK_EVENT" "$CLAUDE_PROJECT_DIR" > env.txt; pwd > pwd.txt' }] },
    { matcher: "Write", hooks: [{ type: "command", command: "echo 'no .env files' >&2; exit 2" }] },
    { matcher: "Read", hooks: [{ type: "command", command: "echo oops >&2; exit 1" }] },
    { matcher: "Grep", hooks: [{ type: "command", command: "sleep 5", timeout: 1, statusMessage: "Slow check" }] },
  ] } });
  const pi = load(hooksDir);
  const ctx = context(project);
  assert.equal(await pi.emit("tool_call", editCall("/tmp/a.txt"), ctx), undefined, "exit 0 goes ahead");
  const stdin = JSON.parse(fs.readFileSync(path.join(project, "stdin.json"), "utf8"));
  assert.deepEqual({ ...stdin, tool_input: undefined }, { session_id: "session-1", transcript_path: "/tmp/session-1.jsonl", cwd: project, hook_event_name: "PreToolUse", tool_name: "Edit", tool_use_id: "c1", tool_input: undefined });
  assert.deepEqual(stdin.tool_input, { path: "/tmp/a.txt", edits: [], file_path: "/tmp/a.txt" });
  assert.equal(fs.readFileSync(path.join(project, "env.txt"), "utf8"), `PreToolUse ${project}`);
  assert.equal(fs.realpathSync(fs.readFileSync(path.join(project, "pwd.txt"), "utf8").trim()), project);
  assert.equal(pi.sent.at(-1).details.kind, "ran");

  const blocked = await pi.emit("tool_call", { type: "tool_call", toolName: "write", toolCallId: "c2", input: { path: ".env", content: "" } }, ctx);
  assert.deepEqual(blocked, { block: true, reason: "no .env files" });
  assert.equal(pi.sent.at(-1).details.kind, "denied");
  assert.equal(pi.sent.at(-1).details.event, "PreToolUse");
  assert.match(pi.sent.at(-1).details.meta, /exit 2 · \d+ ms$/);

  assert.equal(await pi.emit("tool_call", { type: "tool_call", toolName: "read", toolCallId: "c3", input: { path: "x" } }, ctx), undefined, "another exit goes ahead");
  assert.equal(pi.sent.at(-1).details.kind, "failed");
  assert.deepEqual(pi.sent.at(-1).details.lines, ["oops"]);

  const started = Date.now();
  assert.equal(await pi.emit("tool_call", { type: "tool_call", toolName: "grep", toolCallId: "c4", input: { pattern: "x" } }, ctx), undefined);
  assert.ok(Date.now() - started < 4000, "the timeout ends it");
  assert.equal(pi.sent.at(-1).details.kind, "failed");
  assert.equal(pi.sent.at(-1).details.name, "Slow check");
  assert.match(pi.sent.at(-1).details.meta, /timed out/);
});

test("a hook never inherits the agent's socket, identity, secrets or Shepherd's pi", async () => {
  const { project, hooksDir, macFile } = fixture();
  writeJSON(macFile, { hooks: { Stop: [{ hooks: [{ type: "command", command: 'printf "%s|%s|%s|%s|%s" "${SHEPHERD_SOCKET-unset}" "${SHEPHERD_AGENT_ID-unset}" "${SHEPHERD_MCP_SECRET_GITHUB-unset}" "${PI_CODING_AGENT_DIR-unset}" "$KEEP_ME" > env.txt' }] }] } });
  const pi = load(hooksDir);
  const secrets = { SHEPHERD_SOCKET: "/tmp/s.sock", SHEPHERD_AGENT_ID: "a1", SHEPHERD_MCP_SECRET_GITHUB: "ghp_x", KEEP_ME: "kept" };
  const saved = process.env.PI_CODING_AGENT_DIR;
  Object.assign(process.env, secrets);
  try { await pi.emit("agent_before_settle", { outcome: "completed", entries: [] }, context(project)); }
  finally { for (const key of Object.keys(secrets)) delete process.env[key]; process.env.PI_CODING_AGENT_DIR = saved; }
  assert.equal(fs.readFileSync(path.join(project, "env.txt"), "utf8"), "unset|unset|unset|unset|kept");
});

test("an aborted turn kills the hooks it waits on", async () => {
  const { project, hooksDir, macFile } = fixture();
  writeJSON(macFile, { hooks: { PreToolUse: [{ hooks: [{ type: "command", command: "sleep 30 & echo $! > child.pid; wait" }] }] } });
  const pi = load(hooksDir);
  const controller = new AbortController();
  const ctx = { ...context(project), signal: controller.signal };
  const started = Date.now();
  const run = pi.emit("tool_call", editCall(), ctx);
  const pidFile = path.join(project, "child.pid");
  while (!fs.existsSync(pidFile) || !fs.readFileSync(pidFile, "utf8").trim()) await new Promise((r) => setTimeout(r, 20));
  controller.abort();
  await run;
  assert.ok(Date.now() - started < 10_000, "the turn didn't wait out the hook");
  const pid = Number(fs.readFileSync(pidFile, "utf8"));
  let alive = true;
  for (let i = 0; i < 50 && alive; i++) { try { process.kill(pid, 0); await new Promise((r) => setTimeout(r, 20)); } catch { alive = false; } }
  assert.equal(alive, false, "its whole process group is gone");
});

test("decisions merge: deny over ask over allow; ask asks the person; updatedInput changes the call", async () => {
  assert.equal(hooks.mergePermission(["allow", "ask", "deny"]), "deny");
  assert.equal(hooks.mergePermission(["allow", "ask"]), "ask");
  assert.equal(hooks.mergePermission(["allow"]), "allow");
  assert.equal(hooks.mergePermission([]), undefined);
  const { project, hooksDir, macFile } = fixture();
  const out = (decision, extra = {}) => `echo '${JSON.stringify({ hookSpecificOutput: { permissionDecision: decision, permissionDecisionReason: `said ${decision}`, ...extra } })}'`;
  writeJSON(macFile, { hooks: { PreToolUse: [
    { matcher: "Bash", hooks: [{ type: "command", command: out("allow") }, { type: "command", command: out("deny") }, { type: "command", command: out("ask") }] },
    { matcher: "Edit", hooks: [{ type: "command", command: out("allow") }, { type: "command", command: out("ask") }] },
    { matcher: "Write", hooks: [{ type: "command", command: out("allow", { updatedInput: { file_path: "/tmp/safe.txt" } }) }] },
  ] } });
  const pi = load(hooksDir);
  const bash = await pi.emit("tool_call", { type: "tool_call", toolName: "bash", toolCallId: "b", input: { command: "rm -rf /" } }, context(project));
  assert.deepEqual(bash, { block: true, reason: "said deny" });

  const allow = context(project, async () => "Allow once");
  assert.equal(await pi.emit("tool_call", editCall("/tmp/x.txt"), allow), undefined);
  assert.deepEqual(allow.prompts, [{ title: `A hook asks before this runs\n\nedit /tmp/x.txt\n\nsaid ask\n\n${macFile}`, options: ["Deny", "Allow once"] }]);
  assert.equal(pi.sent.at(-1).details.kind, "asked");
  const long = `/tmp/${"deep/".repeat(30)}x.txt`;
  const whole = context(project, async () => "Deny");
  await pi.emit("tool_call", editCall(long), whole);
  assert.equal(whole.prompts[0].title.split("\n\n")[1], `edit ${long}`, "the ask shows the whole call, never clipped");
  const deny = context(project, async () => "Deny");
  assert.equal((await pi.emit("tool_call", editCall(), deny)).block, true);
  const nobody = { ...context(project), hasUI: false };
  assert.equal((await pi.emit("tool_call", editCall(), nobody)).block, true, "no one to ask: denied");
  const worker = load(hooksDir, { SHEPHERD_PROJECT_CONTEXT: "{}" });
  const relayed = context(project, async () => "Allow once");
  assert.equal((await worker.emit("tool_call", editCall(), relayed)).block, true, "a project worker's ask is a deny");
  assert.deepEqual(relayed.prompts, [], "never asked: the coordinator would answer it");

  const call = { type: "tool_call", toolName: "write", toolCallId: "w", input: { path: "/tmp/.env", content: "x" } };
  assert.equal(await pi.emit("tool_call", call, context(project)), undefined);
  assert.deepEqual(call.input, { path: "/tmp/safe.txt", content: "x" });
});

test("Stop sends the agent back at most three times in a row", async () => {
  const { project, hooksDir, macFile } = fixture();
  writeJSON(macFile, { hooks: { Stop: [{ hooks: [{ type: "command", command: "cat > stop.json; echo 'tests fail' >&2; exit 2" }] }] } });
  const pi = load(hooksDir);
  const ctx = context(project);
  const settle = () => pi.emit("agent_before_settle", { type: "agent_before_settle", entries: [], continue: false, outcome: "completed", context: { canContinue: true } }, ctx);
  for (let i = 0; i < 3; i++) {
    const r = await settle();
    assert.equal(r.continue, true);
    assert.equal(r.entries.at(-1).details.kind, "sentBack");
    assert.match(r.entries.at(-1).content, /tests fail/);
    assert.equal(JSON.parse(fs.readFileSync(path.join(project, "stop.json"), "utf8")).stop_hook_active, i > 0);
  }
  const capped = await settle();
  assert.equal(capped.continue, undefined);
  assert.equal(capped.entries.at(-1).details.kind, "systemMessage");
  assert.equal((await settle()).continue, true, "the streak starts over after the cap");
  // A person's message resets the streak, and an aborted run never runs Stop.
  await pi.emit("input", { type: "input", text: "hi", source: "rpc" }, ctx);
  assert.equal(await pi.emit("agent_before_settle", { entries: [], continue: false, outcome: "aborted", context: { canContinue: true } }, ctx), undefined);
});

test("additionalContext and plain SessionStart output reach the agent; long context goes to a file; rows the agent shouldn't read are filtered", async () => {
  const { project, hooksDir, macFile } = fixture();
  writeJSON(macFile, { hooks: {
    SessionStart: [{ matcher: "startup", hooks: [{ type: "command", command: "echo 'branch: main'" }] }],
    UserPromptSubmit: [{ hooks: [
      { type: "command", command: `echo '${JSON.stringify({ hookSpecificOutput: { additionalContext: "ticket ABC-1" }, systemMessage: "For you only" })}'` },
      { type: "command", command: `node -e 'process.stdout.write(JSON.stringify({additionalContext: "x".repeat(10001)}))'` },
    ] }],
  } });
  const pi = load(hooksDir);
  const ctx = context(project);
  await pi.emit("session_start", { type: "session_start", reason: "startup" }, ctx);
  assert.equal(pi.sent.at(-1).details.kind, "context");
  assert.match(pi.sent.at(-1).content, /branch: main/);
  await pi.emit("session_start", { type: "session_start", reason: "reload" }, ctx);
  assert.equal(pi.sent.length, 1, "a reload is not a SessionStart");

  assert.equal(await pi.emit("input", { type: "input", text: "fix it", source: "rpc" }, ctx), undefined);
  const rows = pi.sent.slice(1);
  assert.deepEqual(rows.map((r) => r.details.kind).sort(), ["context", "context", "systemMessage"]);
  assert.match(rows.find((r) => /ABC-1/.test(r.content)).content, /ticket ABC-1/);
  const long = rows.find((r) => /saved to/.test(r.content));
  const file = /saved to (\S+)\. Read it\./.exec(long.content)[1];
  assert.equal(fs.readFileSync(file, "utf8").length, 10001);
  fs.rmSync(file);
  assert.ok(rows.every((r) => r.options.triggerTurn === false && r.customType === "shepherd.hook" && r.display === true));

  const messages = [{ role: "user", content: "hi" }, ...rows.map((r) => ({ role: "custom", ...r }))];
  const { messages: kept } = await pi.emit("context", { type: "context", messages }, ctx);
  assert.deepEqual(kept.map((m) => m.details?.kind ?? m.role), ["user", "context", "context"]);
});

test("UserPromptSubmit exit 2 blocks the message; silent runs collapse to one ran row per event and run", async () => {
  const { project, hooksDir, macFile } = fixture();
  writeJSON(macFile, { hooks: {
    UserPromptSubmit: [{ hooks: [{ type: "command", command: "grep -q secret && { echo 'no secrets' >&2; exit 2; } || true" }] }],
    PostToolUse: [{ hooks: [{ type: "command", command: "true" }] }],
  } });
  const pi = load(hooksDir);
  const ctx = context(project);
  assert.deepEqual(await pi.emit("input", { type: "input", text: "the secret is 42", source: "rpc" }, ctx), { action: "handled" });
  assert.equal(pi.sent.at(-1).details.kind, "denied");
  assert.equal(await pi.emit("input", { type: "input", text: "goal continuation", source: "extension" }, ctx), undefined);
  const before = pi.sent.length;
  await pi.emit("agent_start", {}, ctx);
  const result = { type: "tool_result", toolName: "bash", toolCallId: "r", input: { command: "ls" }, content: [{ type: "text", text: "a" }], isError: false };
  for (let i = 0; i < 3; i++) await pi.emit("tool_result", result, ctx);
  assert.deepEqual(pi.sent.slice(before).map((r) => r.details.kind), ["ran"]);
  await pi.emit("agent_start", {}, ctx);
  await pi.emit("tool_result", result, ctx);
  assert.equal(pi.sent.length, before + 2, "the next run gets its own row");
});

test("hook_propose tests the command, asks with the proposal marker, then writes the file", async () => {
  const { project, hooksDir } = fixture();
  const spaceFile = path.join(project, ".shepherd/hooks.json");
  writeJSON(spaceFile, { note: "keep me", hooks: { Stop: [{ hooks: [{ type: "command", command: "npm test" }] }] } });
  fs.writeFileSync(path.join(project, "notes.md"), "original");
  const pi = load(hooksDir);
  const tool = pi.tools.get("hook_propose");
  assert.ok(tool);
  assert.ok(tool.description.length < 300, "a short description: it costs tokens in every thread");
  const params = { name: "Format", event: "PostToolUse", matcher: "Edit|Write", command: "f=$(node -e 'let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>console.log(JSON.parse(s).tool_input.file_path))'); echo changed > \"$f\"; echo formatted", statusMessage: "Formatting", scope: "space", sample: { tool_name: "Edit", tool_input: { file_path: path.join(project, "notes.md") } } };

  const declined = context(project, async () => "Not now");
  const no = await tool.execute("p0", params, undefined, undefined, declined);
  assert.match(no.content[0].text, /didn't add/);
  assert.equal(fs.readFileSync(path.join(project, "notes.md"), "utf8"), "original", "the test ran on a scratch copy");
  const [marker, json] = declined.prompts[0].title.split(/\n(.*)/s);
  assert.equal(marker, "shepherd.hook.proposal");
  const card = JSON.parse(json);
  assert.deepEqual(declined.prompts[0].options, ["Add to this space", "Add to this Mac", "Not now", "Added in Settings"]);
  assert.deepEqual({ ...card, test: undefined }, { name: "Format", event: "PostToolUse", matcher: "Edit|Write", command: params.command, statusMessage: "Formatting", timeout: null,
    scopes: { space: spaceFile, mac: path.join(process.env.HOME, ".shepherd/hooks.json") }, scope: "space", test: undefined });
  assert.equal(card.test.ok, true);
  assert.equal(card.test.exit, 0);
  assert.match(card.test.summary, /formatted/);

  const accepted = context(project, async () => "Add to this space");
  const yes = await tool.execute("p1", params, undefined, undefined, accepted);
  assert.match(yes.content[0].text, /^Added/);
  const doc = JSON.parse(fs.readFileSync(spaceFile, "utf8"));
  assert.equal(doc.note, "keep me");
  assert.deepEqual(doc.hooks.Stop, [{ hooks: [{ type: "command", command: "npm test" }] }]);
  const handler = { type: "command", command: params.command, statusMessage: "Formatting" };
  assert.deepEqual(doc.hooks.PostToolUse, [{ matcher: "Edit|Write", hooks: [handler] }]);
  const hash = hooks.hookHash(spaceFile, "PostToolUse", "Edit|Write", handler);
  assert.equal(fs.existsSync(path.join(hooksDir, "settings.json")), false, "adding writes only the hooks file");
  assert.deepEqual(pi.sent.at(-1).details, { kind: "added", event: "PostToolUse", name: "Formatting", detail: "Edit|Write", meta: pi.sent.at(-1).details.meta, hash, file: spaceFile });
  assert.equal(fs.readdirSync(path.dirname(spaceFile)).filter((f) => f.endsWith(".tmp")).length, 0, "written by rename");

  // Saved from Edit…: the app wrote it; the runtime writes nothing and says so.
  const before = fs.readFileSync(spaceFile, "utf8");
  const edited = await tool.execute("p2", params, undefined, undefined, context(project, async () => "Added in Settings"));
  assert.match(edited.content[0].text, /edited version .* in Settings; it may differ/);
  assert.equal(fs.readFileSync(spaceFile, "utf8"), before, "nothing written");
  assert.deepEqual(pi.sent.at(-1).details, { kind: "added", event: "PostToolUse", name: "Formatting", detail: "edited in Settings", meta: pi.sent.at(-1).details.meta });
});

test("hook_propose's test run is the agent's bash call: the person's PreToolUse Bash hooks can deny or ask first", async () => {
  const { project, hooksDir, macFile } = fixture();
  writeJSON(macFile, { hooks: { PreToolUse: [
    { matcher: "Bash", hooks: [{ type: "command", command: "grep -q 'touch denied' && { echo 'not that' >&2; exit 2; }; exit 0" }] },
    { matcher: "Bash", hooks: [{ type: "command", command: `grep -q 'touch asked' && echo '{"hookSpecificOutput":{"permissionDecision":"ask","permissionDecisionReason":"sure?"}}'; exit 0` }] },
  ] } });
  const tool = load(hooksDir).tools.get("hook_propose");
  const propose = async (command, answer) => {
    const ctx = context(project, async (title) => (title.startsWith("shepherd.hook.proposal") ? "Not now" : answer));
    await tool.execute("p", { name: "T", event: "Stop", command, scope: "mac" }, undefined, undefined, ctx);
    return { ctx, card: JSON.parse(ctx.prompts.at(-1).title.split(/\n(.*)/s)[1]) };
  };
  const denied = await propose("touch denied");
  assert.equal(fs.existsSync(path.join(project, "denied")), false, "a deny skips the test");
  assert.equal(denied.card.test.ok, false);
  assert.equal(denied.card.test.blocked, true);
  assert.match(denied.card.test.summary, /PreToolUse hook: not that/);

  const asked = await propose("touch asked", "Deny");
  assert.match(asked.ctx.prompts[0].title, /^A hook asks before this runs\n\nbash touch asked\n\nsure\?/);
  assert.equal(fs.existsSync(path.join(project, "asked")), false, "an ask the person denies skips the test");
  assert.equal(asked.card.test.blocked, true);

  await propose("touch asked", "Allow once");
  assert.ok(fs.existsSync(path.join(project, "asked")), "allowed once: the test runs in the space root");
  const plain = await propose("touch plain");
  assert.ok(fs.existsSync(path.join(project, "plain")) && plain.card.test.ok);
});

test("inert without SHEPHERD_HOOKS_DIR; no proposals in automations; the tool is deferred when tools are", () => {
  const none = load(undefined);
  assert.equal(Object.keys(none.handlers).length + none.tools.size, 0);
  const { hooksDir } = fixture();
  assert.equal(load(hooksDir, { SHEPHERD_AUTOMATION: "1" }).tools.size, 0);
  assert.equal(load(hooksDir, { SHEPHERD_PROJECT_CONTEXT: "{}", SHEPHERD_PROJECT_COORDINATOR: "0" }).tools.size, 0, "no proposals in project workers");
  assert.ok(load(hooksDir, { SHEPHERD_PROJECT_CONTEXT: "{}", SHEPHERD_PROJECT_COORDINATOR: "1" }).tools.has("hook_propose"), "the coordinator's thread is the person's");
  assert.equal(load(hooksDir, { SHEPHERD_DEFER_TOOLS: "1" }).tools.get("hook_propose").exposure, "deferred");
  assert.equal(load(hooksDir).tools.get("hook_propose").exposure, undefined);
});

test("mcp_tool input placeholders expand from the event", () => {
  assert.deepEqual(hooks.expandPlaceholders({ patch: "${tool_input.command}", n: 3, note: "file ${tool_input.file_path}!", list: ["${missing.x}"] },
    { tool_input: { command: { a: 1 }, file_path: "/a" } }), { patch: { a: 1 }, n: 3, note: "file /a!", list: [""] });
});

test("SubagentStart and SubagentStop fire once per native subagent run, matched by its profile", async () => {
  const { project, hooksDir, macFile } = fixture();
  writeJSON(macFile, { hooks: {
    SubagentStart: [{ matcher: "worker", hooks: [{ type: "command", command: "cat > start.json" }] }],
    SubagentStop: [{ matcher: "worker", hooks: [{ type: "command", command: "cat > stop.json; echo 'check the diff' >&2; exit 2" }] }],
  } });
  const pi = load(hooksDir);
  const ctx = context(project);
  await pi.emit("session_start", { type: "session_start", reason: "reload" }, ctx);
  const publish = (state) => pi.events["shepherd:children:v1"].forEach((fn) => fn({ owner: "session-1", children: [{ runID: "r1", role: "worker", task: "t", state }] }));
  publish("running"); publish("running");
  const readJSON = async (file) => {
    for (let i = 0; i < 200; i++) { try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch {} await new Promise((r) => setTimeout(r, 10)); }
  };
  assert.equal((await readJSON(path.join(project, "start.json")))?.agent_type, "worker");
  publish("complete");
  for (let i = 0; i < 200 && !pi.sent.some((r) => r.details.kind === "sentBack"); i++) await new Promise((r) => setTimeout(r, 10));
  assert.equal(JSON.parse(fs.readFileSync(path.join(project, "stop.json"), "utf8")).state, "complete");
  assert.match(pi.sent.find((r) => r.details.kind === "sentBack").content, /check the diff/);
});

test("the space root is the nearest .git folder below the home folder, else the cwd; the home folder never counts", async () => {
  const { project, hooksDir } = fixture();
  const sub = path.join(project, "a/b");
  fs.mkdirSync(path.join(project, ".git"), { recursive: true });
  fs.mkdirSync(sub, { recursive: true });
  assert.equal(hooks.spaceRoot(sub), project);
  const file = path.join(project, ".shepherd/hooks.json");
  assert.equal(hooks.spaceFile(sub, ".x"), path.join(sub, ".x"));
  writeJSON(file, { hooks: { PreToolUse: [{ hooks: [{ type: "command", command: "echo root > ran.txt" }] }] } });
  await load(hooksDir).emit("tool_call", editCall(), context(sub));
  assert.equal(fs.readFileSync(path.join(project, "ran.txt"), "utf8").trim(), "root", "runs in the root with the root's file");
  // A repository at the home folder is not a space: a folder under it falls back to itself.
  const home = process.env.HOME, inHome = path.join(home, "notes");
  fs.mkdirSync(path.join(home, ".git"), { recursive: true });
  fs.mkdirSync(inHome, { recursive: true });
  assert.equal(hooks.spaceRoot(inHome), inHome);
  assert.equal(hooks.spaceRoot(home), home);
  assert.equal(hooks.macFile(".shepherd/hooks.json"), `${home}/.shepherd/hooks.json`);
});

test("a proposal's built-in file sample uses pi's input names with file_path mirrored", () => {
  const dir = fs.mkdtempSync(path.join(scratch, "sample-"));
  const edit = hooks.sampleEvent("PreToolUse", "Edit", undefined, dir);
  assert.deepEqual(edit.tool_input, { path: path.join(dir, "sample.txt"), edits: [{ oldText: "hello", newText: "hello, world" }], file_path: path.join(dir, "sample.txt") });
  const given = hooks.sampleEvent("PostToolUse", "", { tool_name: "Write", tool_input: { file_path: "/nonexistent/x.env", content: "" } }, dir);
  assert.equal(given.tool_input.path, path.join(dir, "x.env"));
  assert.equal(given.tool_input.file_path, path.join(dir, "x.env"));
});
