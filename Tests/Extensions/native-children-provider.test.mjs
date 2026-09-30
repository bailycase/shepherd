// What a native helper is launched with (the exact `-e` and `SHEPHERD_*`, the managed CLIProxyAPI provider among
// them) and what it says when a role, profile or model can't be used. Real pi processes against a local fake
// provider: no model call. A real helper on the managed provider is in native-children.test.mjs.
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { children, childrenSource, harness, installManagedProvider, providerServer, scratchHome, tempDir, withEnv } from "./fixtures/children-harness.mjs";

const PARENT = (dir, home) => ({
  HOME: dir, PI_CODING_AGENT_DIR: home, PI_OFFLINE: "1", PI_SUBAGENT_EXTRA_AGENT_DIRS: undefined, SHEPHERD_CLIPROXYAPI_CONFIG: undefined,
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
      SHEPHERD_CLIPROXYAPI_CONFIG: path.join(home, "shepherd-cliproxyapi.json"),
    };
    const launch = children.childLaunch({ run: run(dir), bridge, inherited: [userExtension, path.join(home, "shepherd-cliproxyapi.ts")], parentEnv });

    const loaded = launch.args.flatMap((arg, index) => arg === "-e" ? [launch.args[index + 1]] : []);
    assert.deepEqual(loaded, [bridge, path.join(home, "shepherd-cliproxyapi.ts"), userExtension],
      "the bridge, the managed provider, then the user's extensions, each once (the provider is not repeated from `inherited`)");
    assert(launch.args.includes("--no-extensions"), "everything else stays opt-in");
    const shepherd = Object.keys(launch.env).filter((key) => key.startsWith("SHEPHERD_")).sort();
    assert.deepEqual(shepherd, ["SHEPHERD_CHILD", "SHEPHERD_CHILD_TOOLS", "SHEPHERD_CLIPROXYAPI_CONFIG"],
      "no agent id, socket, design, extension path, model or default reaches a helper");
    assert.equal(launch.env.SHEPHERD_CLIPROXYAPI_CONFIG, path.join(home, "shepherd-cliproxyapi.json"), "the parent's pinned file, kept past the filter");
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
    // No pin, a relative one, or one into a folder that isn't there names no file.
    assert.equal(children.managedProvider({}), undefined);
    assert.equal(children.managedProvider({ SHEPHERD_CLIPROXYAPI_CONFIG: "relative/shepherd-cliproxyapi.json" }), undefined);
    assert.equal(children.managedProvider({ SHEPHERD_CLIPROXYAPI_CONFIG: path.join(dir, "gone", "shepherd-cliproxyapi.json") }), undefined);
    // Both files: it is the provider.
    put(path.join(home, "shepherd-cliproxyapi.ts"), "");
    assert.deepEqual(children.managedProvider(parentEnv), { extension: path.join(home, "shepherd-cliproxyapi.ts"), config: path.join(home, "shepherd-cliproxyapi.json") });
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test("a helper whose home has no connection exits on a cliproxyapi model, and the message carries why", { timeout: 120000 }, async () => {
  const dir = tempDir("unmanaged");
  const fixture = providerServer(() => ({ text: "never asked" }));
  const port = await fixture.listen();
  try {
    const home = scratchHome(dir, { port });
    // The parent's registry lists the proxy's model (its launcher loaded the provider); the helper's own pi,
    // with no connection file in the home, has only the fixture provider and refuses the --model.
    await withEnv(PARENT(dir, home), async () => {
      const h = await harness(dir, { models: [{ provider: "fixture", id: "fixture" }, { provider: "cliproxyapi", id: "fixture-model" }] });
      try {
        await assert.rejects(h.call("start", { task: "x", role: "scout", model: "cliproxyapi/fixture-model", mission: false }), (error) => {
          assert.match(error.message, /^Child exited before clean settlement \(1\): Error: Model "cliproxyapi\/fixture-model" not found\./);
          assert.match(error.message, /cliproxyapi\/fixture-model resolves in this Pi, so its provider is one the helper doesn't load/);
          return true;
        });
        const [failed] = await h.call("result", {});
        assert.equal(failed.state, "failed");
        assert.equal(fixture.requests.length, 0, "no model request was made");
      } finally { await h.shutdown(); }
    });
  } finally { await fixture.close(); fs.rmSync(dir, { recursive: true, force: true }); }
});

test("a model the helper's own catalog lacks names the providers the helper has", { timeout: 120000 }, async () => {
  const dir = tempDir("catalog");
  const fixture = providerServer(() => ({ text: "never asked" }));
  const port = await fixture.listen();
  try {
    const home = scratchHome(dir, { port });
    await withEnv(PARENT(dir, home), async () => {
      const h = await harness(dir, { models: [{ provider: "fixture", id: "fixture" }, { provider: "fixture", id: "parent-only-model" }] });
      try {
        // Pi takes the id as a custom model and starts; its catalog never lists it.
        await assert.rejects(h.call("start", { task: "x", role: "scout", model: "fixture/parent-only-model", mission: false }),
          /unavailable in isolated Pi\. Provider "fixture" has no model "parent-only-model" in the helper's Pi\..*Providers the helper's Pi has: fixture\./);
        assert.equal(fixture.requests.length, 0);
      } finally { await h.shutdown(); }
    });
  } finally { await fixture.close(); fs.rmSync(dir, { recursive: true, force: true }); }
});

// ---- D: errors that say what to do ----

test("agent and role together are refused, naming what to pass", async () => {
  const dir = tempDir("both");
  try {
    const home = scratchHome(dir);
    await withEnv(PARENT(dir, home), async () => {
      const h = await harness(dir);
      try {
        await assert.rejects(h.call("start", { task: "x", agent: "scout", role: "worker" }),
          /Pass either an agent profile or a role, not both.*role is an alias for agent.*scout, reviewer, planner, worker/);
        assert.deepEqual(await h.call("result", {}), [], "nothing was started");
      } finally { await h.shutdown(); }
    });
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test("an unknown role lists the roles and the discovered profiles, and suggests the nearest", async () => {
  const dir = tempDir("unknown");
  try {
    const home = scratchHome(dir);
    put(path.join(home, "agents", "design-composer-editor.md"), "---\nname: design-composer-editor\ndescription: edits boards\ntools: [read]\n---\nEdit boards.\n");
    put(path.join(home, "agents", "notes.md"), "---\nname: notes\ndescription: takes notes\ntools: [read]\n---\nTake notes.\n");
    await withEnv(PARENT(dir, home), async () => {
      const h = await harness(dir);
      try {
        await assert.rejects(h.call("start", { task: "x", role: "design-editor" }), (error) => {
          assert.match(error.message, /^Unknown agent "design-editor"\. Roles: scout, reviewer, planner, worker\. Profiles: design-composer-editor, notes\./);
          assert.match(error.message, /Did you mean design-composer-editor\?/);
          assert.match(error.message, /Pass one of them as agent \(role is an alias\)/);
          return true;
        });
        await assert.rejects(h.call("start", { task: "x", agent: "zzz" }), (error) => !/Did you mean/.test(error.message) && /Unknown agent "zzz"/.test(error.message));
      } finally { await h.shutdown(); }
    });
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test("a model whose provider isn't loaded fails at the start, says which providers are, and suggests cliproxyapi for a cpa model", async () => {
  const dir = tempDir("model");
  try {
    const home = scratchHome(dir);
    put(path.join(home, "agents", "design-composer-editor.md"), "---\nname: design-composer-editor\ndescription: edits boards\nmodel: cpa/gpt-6-astra\ntools: [read]\n---\nEdit boards.\n");
    const models = [{ provider: "fixture", id: "fixture" }, { provider: "cliproxyapi", id: "gpt-6-astra" }, { provider: "cliproxyapi", id: "claude-sonnet-5" }];
    await withEnv(PARENT(dir, home), async () => {
      const h = await harness(dir, { models });
      try {
        // A profile names it: the message names the profile, once, before anything launches.
        await assert.rejects(h.call("start", { task: "x", agent: "design-composer-editor" }), (error) => {
          assert.match(error.message, /^Agent profile design-composer-editor names cpa\/gpt-6-astra, but provider "cpa" isn't loaded in this Pi\./);
          assert.match(error.message, /Did you mean cliproxyapi\/gpt-6-astra\?/);
          assert.match(error.message, /"cpa" was the provider of the old pi-cliproxyapi-provider package/);
          assert.match(error.message, /Providers this Pi has: cliproxyapi, fixture\.$/);
          return true;
        });
        // A call names it.
        await assert.rejects(h.call("start", { task: "x", role: "scout", model: "cpa/gpt-6-astra:high" }), /The model argument names cpa\/gpt-6-astra:high, but provider "cpa" isn't loaded.*Did you mean cliproxyapi\/gpt-6-astra\?/);
        // A loaded provider without that id (Pi would take it as a custom model, which a helper never lists).
        await assert.rejects(h.call("start", { task: "x", role: "scout", model: "cliproxyapi/claude-sonnet-5-5" }), (error) => {
          assert.match(error.message, /provider "cliproxyapi" has no model "claude-sonnet-5-5" in this Pi\./);
          assert.match(error.message, /Its models that look like it: claude-sonnet-5\./);
          return true;
        });
        // No provider at all.
        await assert.rejects(h.call("start", { task: "x", role: "scout", model: "nonsense" }), /no provider of this Pi lists "nonsense"; name a model as provider\/id/);
        assert.deepEqual(await h.call("result", {}), [], "no run was made for any of them");
      } finally { await h.shutdown(); }
    });
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test("the message helpers are pure, and cap a long provider list", () => {
  const many = Array.from({ length: 30 }, (_, i) => ({ provider: `p${String(i).padStart(2, "0")}`, id: "m" }));
  assert.match(children.modelNotFound("x/y", many), /Providers this Pi has: p00, .*, p23 and 6 more\.$/);
  assert.equal(children.modelNotFound("cpa/m", [{ provider: "cliproxyapi", id: "m" }, { provider: "other", id: "m" }], { origin: "Profile a" }).includes("cliproxyapi/m or other/m"), true);
  assert.match(children.unknownAgentMessage("a", [{ name: "a", source: "user", filePath: "/x/a.md" }, { name: "a", source: "project", filePath: "/p/a.md" }], [{ name: "a", source: "user", filePath: "/x/a.md" }, { name: "a", source: "project", filePath: "/p/a.md" }]),
    /^Ambiguous agent "a": it names a \(user, \/x\/a\.md\) and a \(project, \/p\/a\.md\)\./);
  assert.match(children.unknownAgentMessage("q", [{ name: "scout", source: "bundled" }]), /Profiles: none discovered/);
  assert.match(children.unknownAgentMessage("q", []), /none \(Shepherd's bundled roles are disabled\)/);
});
