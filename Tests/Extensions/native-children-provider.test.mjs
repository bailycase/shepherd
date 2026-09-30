// A native helper gets the managed CLIProxyAPI provider from its parent's home. Real pi processes against a
// local fake provider: no model call.
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { children, childrenSource, harness, installManagedProvider, modelEntry, providerServer, scratchHome, tempDir, until, withEnv } from "./fixtures/children-harness.mjs";

const PARENT = (dir, home) => ({
  HOME: dir, PI_CODING_AGENT_DIR: home, PI_OFFLINE: "1", PI_SUBAGENT_EXTRA_AGENT_DIRS: undefined,
  SHEPHERD_NATIVE_CHILDREN: "1", SHEPHERD_AGENT_ID: "fixture", SHEPHERD_SOCKET: path.join(dir, "shepherd.sock"), SHEPHERD_EXT_CHILDREN: childrenSource,
});
const put = (file, text) => { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, text); };
const run = (dir, extra = {}) => ({ id: "native-x", dir, sessionFile: path.join(dir, "session.jsonl"), model: "cliproxyapi/m", thinking: "off",
  tools: ["read", "grep"], systemPromptMode: "append", inheritProjectContext: true, skills: [], extensions: [], ...extra });

// ---- A: what a helper is launched with ----

test("a helper from a home with a connection gets the managed provider and only the SHEPHERD_* it needs", () => {
  const dir = tempDir("launch");
  try {
    const home = path.join(dir, "home");
    fs.mkdirSync(home);
    installManagedProvider(home, { baseURL: "http://127.0.0.1:1/v1", models: ["m"] });
    const bridge = path.join(dir, "bridge.ts"), userExtension = path.join(dir, "user.ts");
    put(bridge, ""); put(userExtension, "");
    const parentEnv = {
      PATH: "/usr/bin", HOME: dir, PI_CODING_AGENT_DIR: home, PI_PACKAGE_DIR: "/engine/package", PI_OFFLINE: "0", PI_SKIP_VERSION_CHECK: "1",
      PI_TELEMETRY: "0", PI_SUBAGENTS_TEMP_ROOT: "/tmp/pi-subagents", PI_MODEL: "parent/model", PI_SESSION_ID: "parent-session",
      NODE_EXTRA_CA_CERTS: "/certs/keychain-certificates.pem", _SHEPHERD_STASH_NAMES: "NODE_OPTIONS", _SHEPHERD_STASH_NODE_OPTIONS: "--require /user/hook.js",
      SHEPHERD_AGENT_ID: "parent-agent", SHEPHERD_SOCKET: "/run/shepherd.sock", SHEPHERD_DESIGN_ID: "d1", SHEPHERD_EXT_PANES: "/ext/panes.ts",
      SHEPHERD_EXT_CHILDREN: bridge, SHEPHERD_NATIVE_CHILDREN: "1", SHEPHERD_MODEL: "parent/model", SHEPHERD_CHILD_CONCURRENCY: "4",
      SHEPHERD_CLIPROXYAPI_CONFIG: "/elsewhere/config.json",
    };
    const launch = children.childLaunch({ run: run(dir), bridge, inherited: [userExtension, path.join(home, "shepherd-cliproxyapi.ts")], parentEnv });

    const loaded = launch.args.flatMap((arg, index) => arg === "-e" ? [launch.args[index + 1]] : []);
    assert.deepEqual(loaded, [bridge, path.join(home, "shepherd-cliproxyapi.ts"), userExtension],
      "the bridge, the managed provider, then the user's extensions, each once (the provider is not repeated from `inherited`)");
    assert(launch.args.includes("--no-extensions"), "everything else stays opt-in");
    const shepherd = Object.keys(launch.env).filter((key) => key.startsWith("SHEPHERD_")).sort();
    assert.deepEqual(shepherd, ["SHEPHERD_CHILD", "SHEPHERD_CHILD_TOOLS", "SHEPHERD_CLIPROXYAPI_CONFIG"],
      "no agent id, socket, design, extension path, model or default reaches a helper");
    assert.equal(launch.env.SHEPHERD_CLIPROXYAPI_CONFIG, path.join(home, "shepherd-cliproxyapi.json"), "the home's own file, set after the filter");
    assert.equal(launch.env.SHEPHERD_CHILD, "1");
    assert.deepEqual(JSON.parse(launch.env.SHEPHERD_CHILD_TOOLS), ["read", "grep", "shepherd_parent_message"]);

    // What the launcher pinned that a helper still needs.
    assert.equal(launch.env.PI_CODING_AGENT_DIR, home, "its home: settings, auth, models");
    assert.equal(launch.env.PI_PACKAGE_DIR, "/engine/package");
    assert.equal(launch.env.PI_OFFLINE, "1", "offline, whatever the parent had");
    assert.equal(launch.env.PI_SKIP_VERSION_CHECK, "1");
    assert.equal(launch.env.PI_TELEMETRY, "0");
    assert.equal(launch.env.NODE_EXTRA_CA_CERTS, "/certs/keychain-certificates.pem", "a private CA reaches the helper's requests");
    assert.equal(launch.env._SHEPHERD_STASH_NODE_OPTIONS, "--require /user/hook.js", "the user's environment is still there for a helper's shell commands (restore-env.sh)");
    // What the filter removes on purpose.
    for (const key of ["PI_SUBAGENTS_TEMP_ROOT", "PI_MODEL", "PI_SESSION_ID"]) assert.equal(launch.env[key], undefined, key);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test("without a connection file, a helper is launched exactly as before", () => {
  const dir = tempDir("launch-plain");
  try {
    const home = path.join(dir, "home");
    fs.mkdirSync(home);
    const bridge = path.join(dir, "bridge.ts");
    put(bridge, "");
    const parentEnv = { HOME: dir, PI_CODING_AGENT_DIR: home, SHEPHERD_AGENT_ID: "parent-agent", SHEPHERD_SOCKET: "/s", SHEPHERD_CLIPROXYAPI_CONFIG: path.join(home, "shepherd-cliproxyapi.json") };
    const expected = (args) => ["--mode", "rpc", "--no-extensions", "--no-skills", "--no-prompt-templates", "--no-themes", "--no-approve",
      "-e", bridge, "--session", path.join(dir, "session.jsonl"), "--model", "cliproxyapi/m", "--thinking", "off", "--tools", "read,grep,shepherd_parent_message",
      "--append-system-prompt", path.join(dir, "prompt.md"), ...args];
    // Neither file: the launch is what it was.
    let launch = children.childLaunch({ run: run(dir), bridge, parentEnv });
    assert.deepEqual(launch.args, expected([]));
    assert.deepEqual(Object.keys(launch.env).filter((key) => key.startsWith("SHEPHERD_")).sort(), ["SHEPHERD_CHILD", "SHEPHERD_CHILD_TOOLS"]);
    // The extension without its connection, and a connection without the extension, are neither a provider.
    put(path.join(home, "shepherd-cliproxyapi.ts"), "");
    assert.deepEqual(children.childLaunch({ run: run(dir), bridge, parentEnv }).args, expected([]));
    fs.unlinkSync(path.join(home, "shepherd-cliproxyapi.ts"));
    put(path.join(home, "shepherd-cliproxyapi.json"), "{}");
    launch = children.childLaunch({ run: run(dir), bridge, parentEnv });
    assert.deepEqual(launch.args, expected([]));
    assert.equal(launch.env.SHEPHERD_CLIPROXYAPI_CONFIG, undefined, "the parent's own pin is filtered like every SHEPHERD_*");
    // No home, or a relative one, names no file.
    assert.equal(children.managedProvider({}), undefined);
    assert.equal(children.managedProvider({ PI_CODING_AGENT_DIR: "relative/home" }), undefined);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

// ---- A: a real helper on the managed provider ----

test("a helper started on a cliproxyapi model registers the provider, reaches the proxy with its key, and completes", { timeout: 120000 }, async () => {
  const dir = tempDir("managed");
  const proxy = providerServer(() => ({ text: "proxy answered" }));
  const port = await proxy.listen();
  try {
    const home = scratchHome(dir);
    installManagedProvider(home, { baseURL: `http://127.0.0.1:${port}/v1`, models: ["fixture-model"], apiKey: "proxy-key-1" });
    await withEnv(PARENT(dir, home), async () => {
      // The parent holds the provider too (Shepherd's launcher loaded it), so its registry lists the model.
      const h = await harness(dir, { models: [{ provider: "cliproxyapi", id: "fixture-model" }] });
      try {
        const started = await h.call("start", { task: "hello proxy", role: "scout", model: "cliproxyapi/fixture-model", mission: false });
        const [done] = await h.call("wait", { ids: [started.id], all: true, timeoutSeconds: 60 });
        assert.equal(done.state, "complete", JSON.stringify(done));
        assert.match(done.output, /proxy answered/);
        assert.equal(done.model, "cliproxyapi/fixture-model");
        const sent = proxy.requests.filter((request) => request.url === "/v1/chat/completions");
        assert(sent.length > 0, "the helper's request reached the proxy");
        assert.equal(sent[0].body.model, "fixture-model");
        assert.equal(sent[0].headers.authorization, "Bearer proxy-key-1", "with the key the connection file holds");
        // The helper's environment carried no key and no host variable: the file is all it read.
        const childEnv = fs.readFileSync(path.join(path.dirname(done.sessionFile), "status.json"), "utf8");
        assert(!childEnv.includes("proxy-key-1"));
      } finally { await h.shutdown(); }
    });
  } finally { await proxy.close(); fs.rmSync(dir, { recursive: true, force: true }); }
});
