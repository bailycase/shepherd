import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";

// A remote client's MCP sign-in on the host (Extensions/shepherd-mcp-login.mjs): pi's own
// `mcp login`, finished through the loopback redirect, without opening the host's browser.
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const pkg = process.env.PI_PACKAGE_DIR ?? path.join(root, ".build/pi-engine/Resources/pi-engine");
const cli = path.join(pkg, "dist/extensions/mcp/cli.js");
const node = process.env.PI_PACKAGE_DIR ? process.execPath : path.join(root, ".build/pi-engine/Helpers/node");

async function signIn(t, args) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "shepherd-mcp-login-"));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  const fixture = spawn("python3", [path.join(root, "Tests/Extensions/fixtures/fake-mcp-oauth.py")], { stdio: ["pipe", "pipe", "pipe"] });
  t.after(() => fixture.stdin.end());
  const port = await new Promise((resolve) => createInterface({ input: fixture.stdout }).once("line", resolve));
  const url = `http://127.0.0.1:${port}/mcp`;
  fs.writeFileSync(path.join(home, "mcp.json"), JSON.stringify({ mcpServers: { issues: { url } } }));
  // Every way pi opens a page on macOS and Linux goes through these: a call leaves a marker.
  const shims = fs.mkdtempSync(path.join(os.tmpdir(), "shepherd-mcp-open-"));
  t.after(() => fs.rmSync(shims, { recursive: true, force: true }));
  const opened = path.join(shims, "opened");
  for (const name of ["open", "xdg-open"]) {
    fs.writeFileSync(path.join(shims, name), `#!/bin/sh\necho "$@" >> '${opened}'\n`, { mode: 0o755 });
  }
  const proc = spawn(node, args(home), {
    env: { ...process.env, PATH: `${shims}:${process.env.PATH}`, PI_CODING_AGENT_DIR: home, PI_OFFLINE: "1" },
    stdio: ["pipe", "pipe", "pipe"],
  });
  t.after(() => { if (proc.exitCode == null) proc.kill(); });
  const exited = new Promise((resolve) => proc.once("exit", resolve));
  let browser;
  createInterface({ input: proc.stdout }).on("line", (line) => {
    const text = line.trim();
    if (browser || !text.startsWith("http")) return;
    browser = (async () => {
      // The client's browser: approve, then the address it ends on, requested on the host.
      const response = await fetch(new URL(text), { redirect: "manual" });
      await fetch(new URL(response.headers.get("location")));
    })();
  });
  const status = await exited;
  await browser;
  assert.equal(status, 0);
  assert.ok(browser, "pi printed the sign-in page");
  const auth = JSON.parse(fs.readFileSync(path.join(home, "mcp-auth.json"), "utf8"));
  assert.ok(Object.values(auth).some((entry) => entry?.tokens?.access_token));
  // pi starts the opener detached and doesn't wait: give it a moment to leave its mark.
  for (let i = 0; i < 40 && !fs.existsSync(opened); i++) await new Promise((resolve) => setTimeout(resolve, 50));
  return fs.existsSync(opened);
}

test("a remote MCP sign-in prints the page, opens no browser, and signs in through the redirect", { timeout: 60000 }, async (t) => {
  const opened = await signIn(t, (home) => [path.join(root, "Extensions/shepherd-mcp-login.mjs"), cli, home, "issues", "30"]);
  assert.equal(opened, false, "nothing opened a browser on the host");
});

// The control: pi's command without the option opens the page, so the check above can fail.
test("pi's own login opens the host's browser", { timeout: 60000 }, async (t) => {
  const opened = await signIn(t, (home) => ["--input-type=module", "-e",
    `const m = await import(${JSON.stringify(new URL(`file://${cli}`).href)}); process.exitCode = await m.runMcpCommand(["login", "issues", "--timeout", "30"], { cwd: ${JSON.stringify(home)}, agentDir: ${JSON.stringify(home)} });`]);
  assert.equal(opened, true);
});

test("the login script refuses a server name pi would not take", async () => {
  const proc = spawn(node, [path.join(root, "Extensions/shepherd-mcp-login.mjs"), cli, os.tmpdir(), "bad name"], { stdio: "ignore" });
  assert.equal(await new Promise((resolve) => proc.once("exit", resolve)), 2);
});
