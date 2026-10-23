// shepherd-mcp-parent.ts (docs/mcp.md › Subprojects): a project inside another project's folder shares the parent's
// `.shepherd/mcp.json` servers. Real pi in RPC mode against the stand-in stdio server, a loopback fake provider and a temporary
// home. pi runs in `work/apps/web`, a subproject of `work`, with SHEPHERD_PARENT_PROJECT naming `work`.
// Run: PI_PACKAGE_DIR=/path/to/pi-coding-agent node --test Tests/Extensions/mcp-parent.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { withPi, sleep, until, script } from "./fixtures/pi-rpc-harness.mjs";
import { startFakeMcpHttp } from "./fixtures/fake-mcp-http.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const stdio = path.join(root, "Tests/Extensions/fixtures/fake-mcp-stdio.mjs");
const extension = path.join(root, "Extensions/shepherd-mcp-parent.ts");
const ARGS = ["-e", "builtin:mcp", "-e", "builtin:tool-search", "-e", extension];
// The stand-in writes `<dir>/<marker>.pid` when it starts, which `pi.spawned(marker)` reads.
const server = (dir, marker) => ({ command: process.execPath, args: [stdio], env: { FAKE_MCP_PIDFILE: path.join(dir, `${marker}.pid`) } });
const mcpFile = (folder, servers) => {
  // The parent extension uses Shepherd paths; native Pi uses its distribution configDir.
  const native = JSON.parse(fs.readFileSync(path.join(process.env.PI_PACKAGE_DIR, "package.json"))).piConfig?.configDir ?? ".pi";
  for (const config of new Set([".shepherd", ".pi", native])) {
    fs.mkdirSync(path.join(folder, config), { recursive: true });
    fs.writeFileSync(path.join(folder, config, "mcp.json"), JSON.stringify({ mcpServers: servers }));
  }
};
const web = (work) => path.join(work, "apps/web");

/** pi in `work/apps/web`; the parent `work` names `shared` and `docs` (the parent's own `docs`). */
function subproject({ trusted = true, deniedChild = false, parent = (work) => work, own } = {}) {
  return {
    args: ARGS,
    cwd: (_dir, work) => web(work),
    env: (_dir, work) => (parent(work) ? { SHEPHERD_PARENT_PROJECT: parent(work) } : {}),
    files: (_dir, work) => {
      const decisions = trusted ? { [fs.realpathSync(work)]: true } : {};
      if (deniedChild) { fs.mkdirSync(web(work), { recursive: true }); decisions[fs.realpathSync(web(work))] = false; }
      return { "trust.json": decisions };
    },
    project: (dir, work) => {
      fs.mkdirSync(web(work), { recursive: true });
      mcpFile(work, { shared: server(dir, "shared"), docs: server(dir, "parent-docs") });
      if (own) mcpFile(web(work), own(dir));
    },
  };
}

const checkout = (work) => path.join(path.dirname(work), "owned-worktree");

function ownedWorktree({ trusted = true, localTrusted = false, own, grant = true, mismatched = false, enabled = true } = {}) {
  return {
    args: enabled ? ARGS : [],
    settings: { extensions: ["-builtin:mcp", "-builtin:tool-search"], defaultProjectTrust: "prompt" },
    cwd: (_dir, work) => checkout(work),
    env: (_dir, work) => grant ? { SHEPHERD_MCP_OWNING_SPACE: work,
      SHEPHERD_MCP_WORKTREE_CWD: mismatched ? work : checkout(work) } : {},
    files: (_dir, work) => ({ "trust.json": { [fs.realpathSync(work)]: trusted,
      ...(localTrusted ? { [checkout(work)]: true } : {}) } }),
    project: (dir, work) => {
      const here = checkout(work);
      fs.mkdirSync(here, { recursive: true });
      mcpFile(work, { shared: { ...server(dir, "shared"), exposure: "deferred" }, docs: server(dir, "parent-docs") });
      // Executable branch resources must remain blocked while the owner's MCP is usable.
      const native = JSON.parse(fs.readFileSync(path.join(process.env.PI_PACKAGE_DIR, "package.json"))).piConfig?.configDir ?? ".pi";
      for (const config of new Set([".shepherd", ".pi", native])) {
        const folder = path.join(here, config);
        fs.mkdirSync(path.join(folder, "extensions"), { recursive: true });
        fs.writeFileSync(path.join(folder, "extensions/mark.ts"), `import fs from 'node:fs'; fs.writeFileSync(${JSON.stringify(path.join(dir, "branch-ran"))}, 'ran'); export default function() {}`);
        fs.writeFileSync(path.join(folder, "settings.json"), JSON.stringify({ defaultProjectTrust: "always" }));
      }
      if (own) mcpFile(here, own(dir));
    },
  };
}

async function status(pi) {
  const mark = pi.events.length;
  await pi.request({ type: "prompt", message: "/mcp" });
  await sleep(100);
  return pi.events.slice(mark).filter((e) => e.type === "extension_ui_request" && e.method === "notify").map((e) => e.message).join("\n");
}

test("a subproject starts its parent's servers next to its own", { timeout: 120000 }, async (t) => {
  await withPi(t, subproject({ own: (dir) => ({ local: server(dir, "local") }) }), async (pi) => {
    await until("the parent's and the subproject's servers to start", () => pi.spawned("shared") && pi.spawned("parent-docs") && pi.spawned("local"));
    await until("all three to connect", async () => {
      const text = await status(pi);
      return ["shared", "docs", "local"].every((name) => new RegExp(`^${name}: connected`, "m").test(text));
    });
  });
});

test("Pi MCP files work in subprojects and owned worktrees with Shepherd winning collisions", { timeout: 120000 }, async t => {
  for (const options of [subproject(), ownedWorktree({ localTrusted: true })]) {
    const original = options.project;
    options.project = (dir, work) => {
      original(dir, work);
      fs.mkdirSync(path.join(work, ".pi"), { recursive: true });
      fs.writeFileSync(path.join(work, ".pi/mcp.json"), JSON.stringify({ mcpServers: {
        pi_parent: server(dir, "pi-parent"), shared: server(dir, "shadowed-pi-shared"),
      } }));
      const here = options.cwd(dir, work);
      fs.mkdirSync(path.join(here, ".pi"), { recursive: true });
      fs.writeFileSync(path.join(here, ".pi/mcp.json"), JSON.stringify({ mcpServers: { pi_local: server(dir, "pi-local") } }));
    };
    await withPi(t, options, async pi => {
      await until("both alias files and inherited servers to start", () => ["pi-parent", "pi-local", "shared", "parent-docs"].every(name => pi.spawned(name)));
      assert.equal(pi.spawned("shadowed-pi-shared"), false);
    });
  }
});

test("the subproject's own server of the same name wins over the parent's", { timeout: 120000 }, async (t) => {
  await withPi(t, subproject({ own: (dir) => ({ docs: server(dir, "own-docs") }) }), async (pi) => {
    await until("the subproject's docs and the parent's shared to start", () => pi.spawned("own-docs") && pi.spawned("shared"));
    await sleep(1500);
    assert.equal(pi.spawned("parent-docs"), false, "the parent's docs is overridden, never started");
  });
});

test("an untrusted subproject shares nothing, and neither does a missing or wrong parent", { timeout: 180000 }, async (t) => {
  for (const [what, options] of [
    ["untrusted", subproject({ trusted: false })],
    ["a trusted parent, but the subproject refused", subproject({ deniedChild: true })],
    ["no parent named", subproject({ parent: () => undefined })],
    ["a parent that does not hold the subproject", subproject({ parent: (work) => path.join(work, "elsewhere") })],
  ]) {
    await withPi(t, options, async (pi) => {
      await pi.commands();
      await sleep(1500);
      assert.equal(pi.spawned("shared"), false, `${what}: the parent's server never starts`);
    });
  }
});

test("an approved owning space's MCP is discoverable and callable in a sibling worktree without trusting branch resources", { timeout: 120000 }, async (t) => {
  const options = ownedWorktree();
  options.onRequest = script([
    { tool: { name: "tool_search", arguments: { query: "echo the text back", server: "shared" } } },
    { tool: { name: "mcp__shared__echo", arguments: { text: "owned sibling" } } },
  ]);
  await withPi(t, options, async (pi) => {
    await until("owning-space MCP to connect", async () => /^shared: connected/m.test(await status(pi)));
    const turn = await pi.prompt("call the owned server");
    const echo = pi.toolEvents(turn.events).find((e) => e.type === "tool_execution_end" && e.toolName === "mcp__shared__echo");
    assert.equal(echo?.isError, false);
    assert.equal(echo.result.content[0].text, "echo: owned sibling");
    assert.equal(fs.existsSync(path.join(pi.dir, "branch-ran")), false, "neither branch extensions nor its always-trust settings execute");
    assert.deepEqual(JSON.parse(fs.readFileSync(path.join(pi.home, "trust.json"))), { [pi.work]: true }, "no worktree approval is saved");
    assert.equal(fs.existsSync(path.join(checkout(pi.work), ".shepherd/mcp.json")), false, "no config is copied into the worktree");
  });
});

test("inherited stdio scripts and relative working folders resolve from the owning space, never branch files", { timeout: 120000 }, async (t) => {
  for (const cwd of [undefined, "services"]) {
    const options = ownedWorktree();
    const project = options.project;
    options.project = (dir, work) => {
      project(dir, work);
      const folder = path.join(work, cwd ?? ".");
      const branchFolder = path.join(checkout(work), cwd ?? ".");
      fs.mkdirSync(folder, { recursive: true });
      fs.mkdirSync(branchFolder, { recursive: true });
      fs.writeFileSync(path.join(folder, "server.mjs"), `import ${JSON.stringify(stdio)};`);
      fs.writeFileSync(path.join(branchFolder, "server.mjs"), `import fs from 'node:fs'; fs.writeFileSync(${JSON.stringify(path.join(dir, "branch-server-ran"))}, 'ran');`);
      mcpFile(work, { shared: { ...server(dir, "shared"), args: ["server.mjs"], cwd, exposure: "direct",
        env: { FAKE_MCP_PIDFILE: path.join(dir, "shared.pid"), FAKE_MCP_ARGVFILE: path.join(dir, "server-cwd.json") } } });
    };
    await withPi(t, options, async (pi) => {
      await until("the owning-space script to connect", async () => /^shared: connected/m.test(await status(pi)));
      assert.equal(JSON.parse(fs.readFileSync(path.join(pi.dir, "server-cwd.json"))).cwd, path.join(pi.work, cwd ?? "."));
      assert.equal(fs.existsSync(path.join(pi.dir, "branch-server-ran")), false);
    });
  }
});

test("owned worktrees reuse OAuth from the host Pi home, never checkout credentials", { timeout: 120000 }, async (t) => {
  const http = await startFakeMcpHttp({ bearer: "scratch-host-token" });
  t.after(() => http.stop());
  const options = ownedWorktree();
  const files = options.files;
  const project = options.project;
  options.files = (dir, work) => ({ ...files(dir, work), "mcp-auth.json": {
    [`mcp__web|${http.url}`]: { tokens: { access_token: "scratch-host-token", token_type: "Bearer" } },
  } });
  options.project = (dir, work) => {
    project(dir, work);
    mcpFile(work, { web: { url: http.url, exposure: "direct" } });
  };
  options.onRequest = script([{ tool: { name: "mcp__web__echo", arguments: { text: "host OAuth" } } }]);
  await withPi(t, options, async (pi) => {
    await until("OAuth-backed inherited server to connect", async () => /^web: connected/m.test(await status(pi)));
    const turn = await pi.prompt("call the signed-in server");
    const echo = pi.toolEvents(turn.events).find((e) => e.type === "tool_execution_end" && e.toolName === "mcp__web__echo");
    assert.equal(echo?.isError, false);
    assert.equal(echo.result.content[0].text, "echo: host OAuth");
    assert.equal(fs.existsSync(path.join(checkout(pi.work), "mcp-auth.json")), false);
    assert.equal(fs.existsSync(path.join(checkout(pi.work), ".shepherd/mcp-auth.json")), false);
  });
});

test("a separately trusted worktree-local server overrides the owning space's same-named server", { timeout: 120000 }, async (t) => {
  await withPi(t, ownedWorktree({ localTrusted: true, own: (dir) => ({ docs: server(dir, "own-docs") }) }), async (pi) => {
    await until("local override and inherited server to connect", async () => {
      const text = await status(pi);
      return pi.spawned("own-docs") && /^shared: connected/m.test(text) && /^docs: connected/m.test(text);
    });
    assert.equal(pi.spawned("parent-docs"), false);
    assert.equal(fs.existsSync(path.join(pi.dir, "branch-ran")), true, "only independent checkout approval permits branch resources");
  });
});

test("untrusted worktree-local MCP cannot override an approved owning-space server", { timeout: 120000 }, async (t) => {
  await withPi(t, ownedWorktree({ own: (dir) => ({ docs: server(dir, "unapproved-docs") }) }), async (pi) => {
    await until("inherited server to connect", async () => /^docs: connected/m.test(await status(pi)));
    assert.equal(pi.spawned("parent-docs"), true);
    assert.equal(pi.spawned("unapproved-docs"), false);
    assert.equal(fs.existsSync(path.join(pi.dir, "branch-ran")), false);
  });
});

const noCommandValues = fs.readFileSync(path.join(process.env.PI_PACKAGE_DIR, "dist/core/resolve-config-value.js"), "utf8")
  .includes("Command configuration values are not supported");
test("the bundled engine rejects command credentials from global, trusted-local and inherited MCP configs", {
  timeout: 120000, skip: !noCommandValues && "requires the patched Shepherd engine; config-command-values.test.mjs checks the pinned patch upstream",
}, async (t) => {
  const options = ownedWorktree({ localTrusted: true });
  const files = options.files;
  const project = options.project;
  const bad = (dir, name) => ({ ...server(dir, name), env: { TOKEN: `!touch '${path.join(dir, "command-ran")}'; printf token` } });
  options.files = (dir, work) => ({ ...files(dir, work), "mcp.json": { mcpServers: { global: bad(dir, "global") } } });
  options.project = (dir, work) => {
    project(dir, work);
    mcpFile(work, { inherited: bad(dir, "inherited") });
    mcpFile(checkout(work), { local: bad(dir, "local") });
  };
  await withPi(t, options, async (pi) => {
    await until("all command-value servers to fail closed", async () => {
      const text = await status(pi);
      return ["global", "local", "inherited"].every((name) => new RegExp(`^${name}: failed`, "m").test(text));
    });
    for (const name of ["global", "local", "inherited"]) assert.equal(pi.spawned(name), false);
    assert.equal(fs.existsSync(path.join(pi.dir, "command-ran")), false);
  });
});

test("revoked space approval, missing or mismatched ownership and disabled MCP grant no inherited access", { timeout: 180000 }, async (t) => {
  for (const [what, options] of [
    ["revoked space approval", ownedWorktree({ trusted: false })],
    ["unrelated sibling", ownedWorktree({ grant: false })],
    ["grant for another checkout", ownedWorktree({ mismatched: true })],
    ["MCP disabled", ownedWorktree({ enabled: false })],
  ]) {
    await withPi(t, options, async (pi) => {
      const sent = await pi.promptSent("which tools are available?");
      assert.equal(pi.spawned("shared"), false, what);
      assert.equal(pi.spawned("parent-docs"), false, what);
      assert.doesNotMatch(sent.system, /mcp__shared/, what);
      assert.equal(fs.existsSync(path.join(pi.dir, "branch-ran")), false, what);
    });
  }
});
