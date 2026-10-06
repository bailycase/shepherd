import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const sdk = process.env.PI_PACKAGE_DIR
  ? path.join(process.env.PI_PACKAGE_DIR, "dist/index.js")
  : path.join(root, ".build/pi-engine/Resources/pi-engine/dist/bundle/index.js");
const node = process.env.PI_PACKAGE_DIR ? process.execPath : path.join(root, ".build/pi-engine/Helpers/node");

for (const shared of [false, true]) test(`project OAuth uses host credentials without global config, shared=${shared}`, { timeout: 30000 }, async (t) => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "shepherd-project-oauth-"));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  const fixture = spawn("python3", [path.join(root, "Tests/Extensions/fixtures/fake-mcp-oauth.py")], { stdio: ["pipe", "pipe", "pipe"] });
  t.after(() => fixture.stdin.end());
  const port = await new Promise((resolve) => createInterface({ input: fixture.stdout }).once("line", resolve));
  const url = `http://127.0.0.1:${port}/mcp`;
  fs.writeFileSync(path.join(home, "mcp.json"), '{"mcpServers":{"untouched":{"command":"never-run"}}}');
  const before = fs.readFileSync(path.join(home, "mcp.json"), "utf8");
  async function run(command, invalidState = false, oauth) {
    const proc = spawn(node, [path.join(root, "Extensions/shepherd-project-mcp-sign-in.mjs"), sdk, home], {
      env: { ...process.env, PI_CODING_AGENT_DIR: home }, stdio: ["pipe", "pipe", "pipe"],
    });
    t.after(() => { if (proc.exitCode == null) proc.kill(); });
    const events = [];
    const completed = new Promise((resolve, reject) => {
      proc.once("error", reject);
      proc.once("exit", (status) => status === 0 ? resolve() : reject(new Error(`bridge exited ${status}`)));
    });
    const browser = [];
    createInterface({ input: proc.stdout }).on("line", (line) => {
      const event = JSON.parse(line); events.push(event);
      if (event.type === "event" && event.event.type === "auth_url") browser.push((async () => {
        const authorization = new URL(event.event.url);
        assert.equal(authorization.hostname, "127.0.0.1");
        const response = await fetch(authorization, { redirect: "manual" });
        const redirect = new URL(response.headers.get("location"));
        if (invalidState) redirect.searchParams.set("state", "not-the-state");
        // Remote path: return the full redirect through the bridge rather than contacting host loopback.
        proc.stdin.write(JSON.stringify({ type: "answer", id: "redirect", value: redirect.href }) + "\n");
      })());
    });
    proc.stdin.write(JSON.stringify({ type: "answer", id: "config", value: JSON.stringify({ server: "issues", config: { url, ...(oauth ? { oauth } : {}) }, shared, directory: home, command }) }) + "\n");
    await completed; await Promise.all(browser);
    return events;
  }
  const signed = await run("login");
  assert.ok(signed.some((event) => event.type === "done"), JSON.stringify(signed));
  assert.ok(!JSON.stringify(signed).includes("access_token"));
  const auth = JSON.parse(fs.readFileSync(path.join(home, "mcp-auth.json"), "utf8"));
  assert.ok(auth[`mcp__issues|${url}`].tokens.access_token);
  assert.equal(fs.readFileSync(path.join(home, "mcp.json"), "utf8"), before);
  const loggedOut = await run("logout");
  assert.ok(loggedOut.some((event) => event.type === "done"));
  assert.equal(JSON.parse(fs.readFileSync(path.join(home, "mcp-auth.json"), "utf8"))[`mcp__issues|${url}`], undefined);
  const invalid = await run("login", true);
  assert.ok(invalid.some((event) => event.type === "failed"));
  assert.ok(!JSON.stringify(invalid).includes("code-"));
  assert.equal(JSON.parse(fs.readFileSync(path.join(home, "mcp-auth.json"), "utf8"))[`mcp__issues|${url}`]?.tokens, undefined);
  if (!shared) {
    for (const oauth of [{ callbackUrl: "http://0.0.0.0:18080/callback" }, { callbackPort: 99999 }, { authServerMetadataUrl: "http://example.invalid/metadata" }, { clientSecret: "!touch should-never-run" }]) {
      const events = await run("login", false, oauth);
      assert.ok(events.some((event) => event.type === "failed"));
      assert.ok(!events.some((event) => event.type === "event" && event.event.type === "auth_url"));
    }
  }
});
