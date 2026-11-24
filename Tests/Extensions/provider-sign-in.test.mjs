// The native sign-in sheet discovers installed providers without running an agent or trusting project code.
// PI_PACKAGE_DIR=<isolated pinned package> node --test Tests/Extensions/provider-sign-in.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { pkg, until } from "./fixtures/pi-rpc-harness.mjs";

const script = fileURLToPath(new URL("../../Extensions/shepherd-sign-in.mjs", import.meta.url));
function provider({ id = "fixture-login", name = "Fixture login", login = `
  const code = await interaction.prompt({ type: "manual_code", message: "Fixture code" });
  if (code !== "fixture-code") throw Error("Wrong fixture code");
` } = {}) {
  return `
import * as fs from "node:fs";
import { join } from "node:path";
export default pi => {
  pi.on("session_start", () => fs.writeFileSync(join(process.env.HOME, "session-started"), "unexpected"));
  const fixture = {
    id: ${JSON.stringify(id)}, name: ${JSON.stringify(name)},
    auth: { oauth: {
      name: "Fixture account",
      async login(interaction) {
        ${login}
        return { type: "oauth", access: "fixture-access-not-a-secret", refresh: "fixture-refresh-not-a-secret", expires: Date.now() + 3600000 };
      },
      async refresh(credential) { return credential; },
      async toAuth(credential) { return { apiKey: credential.access }; },
    } },
    getModels() { return []; },
    stream() { throw Error("Sign-in must not request a completion"); },
    streamSimple() { throw Error("Sign-in must not request a completion"); },
  };
  pi.registerProvider(fixture);
  pi.registerProvider({ ...fixture, id: "fixture-ambient", name: "Fixture ambient", auth: {
    apiKey: { name: "Ambient credentials", async resolve() { return undefined; } },
  } });
};`;
}

async function bridge(t, sdk, { source = provider(), disabled = false, auth = {}, added = false } = {}) {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "pi-signin-")));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const home = path.join(dir, "home"), workspace = path.join(dir, "workspace");
  fs.mkdirSync(path.join(home, "extensions"), { recursive: true });
  fs.mkdirSync(path.join(workspace, ".pi", "extensions"), { recursive: true });
  // `added`: where Settings ▸ Tools ▸ Extensions puts an extension, loaded by its absolute path in settings.
  const addedPath = path.join(home, "your-extensions", "added", "fixture.ts");
  if (added) {
    fs.mkdirSync(path.dirname(addedPath), { recursive: true });
    fs.writeFileSync(addedPath, source);
  } else {
    fs.writeFileSync(path.join(home, "extensions", "fixture.ts"), source);
  }
  fs.writeFileSync(path.join(workspace, ".pi", "extensions", "untrusted.ts"), `throw Error("Workspace extension must not load");`);
  fs.writeFileSync(path.join(home, "settings.json"), JSON.stringify({ extensions: added ? [addedPath] : disabled ? ["-extensions/fixture.ts"] : [] }));
  fs.writeFileSync(path.join(home, "auth.json"), JSON.stringify(auth));
  const child = spawn(process.execPath, [script, path.join(pkg, sdk), home], {
    cwd: workspace, stdio: ["pipe", "pipe", "pipe"],
    env: { PATH: process.env.PATH, HOME: dir, PI_CODING_AGENT_DIR: home, PI_OFFLINE: "1", PI_SKIP_VERSION_CHECK: "1", PI_TELEMETRY: "0" },
  });
  t.after(() => child.kill("SIGKILL"));
  let output = "", stderr = "", pending = "";
  const replies = [];
  child.stdout.setEncoding("utf8").on("data", chunk => {
    output += chunk;
    pending += chunk;
    for (let nl; (nl = pending.indexOf("\n")) >= 0; pending = pending.slice(nl + 1)) replies.push(JSON.parse(pending.slice(0, nl)));
  });
  child.stderr.setEncoding("utf8").on("data", chunk => { stderr += chunk; });
  const send = message => child.stdin.write(JSON.stringify(message) + "\n");
  const reply = (type, matches = () => true) => until(`bridge ${type}: ${stderr}`, () => replies.find(message => message.type === type && matches(message)), 15000);
  await reply("ready");
  return {
    home, send, reply,
    auth: () => JSON.parse(fs.readFileSync(path.join(home, "auth.json"), "utf8")),
    output: () => output + stderr,
    async close() {
      assert.equal(fs.existsSync(path.join(dir, "session-started")), false);
      assert.equal(fs.existsSync(path.join(home, "sessions")), false);
      const exited = new Promise(resolve => child.once("exit", resolve));
      child.stdin.end();
      assert.equal(await exited, 0, stderr);
    },
  };
}

for (const sdk of ["dist/index.js", "dist/bundle/index.js"]) {
  for (const disabled of [false, true]) {
    test(`${sdk}: discovery and sign-in ${disabled ? "respect disabled resources" : "persist credentials without starting a session"}`, { timeout: 30000 }, async t => {
      const b = await bridge(t, sdk, { disabled });
      b.send({ type: "providers" });
      const { providers } = await b.reply("providers");
      const fixture = providers.find(p => p.id === "fixture-login");
      assert.deepEqual(fixture, disabled ? undefined : { id: "fixture-login", name: "Fixture login", oauth: "Fixture account", keyForm: false });
      // Catalog replies must never contain provider configuration or credentials.
      assert.ok(providers.every(p => Object.keys(p).every(key => ["id", "name", "oauth", "apiKey", "keyForm"].includes(key))));
      assert.equal(providers.find(p => p.id === "fixture-ambient"), undefined, "ambient-only auth has no sign-in button");
      b.send({ type: "login", provider: "fixture-login", method: "oauth", flow: "paste" });
      if (disabled) {
        assert.equal((await b.reply("failed")).code, "unknownProvider");
        assert.deepEqual(b.auth(), {});
      } else {
        const prompt = await b.reply("prompt");
        assert.equal(prompt.message, "Fixture code");
        b.send({ type: "answer", id: prompt.id, value: "fixture-code" });
        assert.equal((await b.reply("done")).credential, "oauth");
        assert.equal(b.auth()["fixture-login"].access, "fixture-access-not-a-secret");
        assert.doesNotMatch(b.output(), /fixture-access-not-a-secret|fixture-refresh-not-a-secret/);
        b.send({ type: "logout", provider: "fixture-login" });
        await b.reply("loggedOut");
        assert.equal(b.auth()["fixture-login"], undefined);
      }
      await b.close();
    });
  }

  test(`${sdk}: a same-ID override supplies the effective methods and login`, { timeout: 30000 }, async t => {
    const b = await bridge(t, sdk, { source: provider({ id: "anthropic", name: "Fixture override" }) });
    b.send({ type: "providers" });
    const entries = (await b.reply("providers")).providers.filter(p => p.id === "anthropic");
    assert.deepEqual(entries, [{ id: "anthropic", name: "Fixture override", oauth: "Fixture account", keyForm: false }]);
    b.send({ type: "login", provider: "anthropic", method: "oauth", flow: "paste" });
    const prompt = await b.reply("prompt");
    b.send({ type: "answer", id: prompt.id, value: "fixture-code" });
    await b.reply("done");
    assert.equal(b.auth().anthropic.access, "fixture-access-not-a-secret");
    await b.close();
  });

  test(`${sdk}: a built-in multi-step key login keeps its provider-specific questions`, { timeout: 30000 }, async t => {
    const b = await bridge(t, sdk);
    b.send({ type: "providers" });
    assert.equal((await b.reply("providers")).providers.find(p => p.id === "cloudflare-workers-ai").keyForm, false);
    b.send({ type: "login", provider: "cloudflare-workers-ai", method: "api_key", flow: "paste" });
    const key = await b.reply("prompt");
    assert.equal(key.kind, "secret");
    assert.notEqual(key.keyForm, true);
    b.send({ type: "answer", id: key.id, value: "fixture-cloudflare-key" });
    const account = await b.reply("prompt", p => p.id !== key.id);
    assert.equal(account.kind, "text");
    b.send({ type: "answer", id: account.id, value: "acme" });
    await b.reply("done");
    assert.equal(b.auth()["cloudflare-workers-ai"].env.CLOUDFLARE_ACCOUNT_ID, "acme");
    assert.doesNotMatch(b.output(), /fixture-cloudflare-key/);
    await b.close();
  });

  test(`${sdk}: a broken extension blocks neither other providers nor sign-out`, { timeout: 30000 }, async t => {
    const b = await bridge(t, sdk, {
      source: `throw Error("fixture-extension-private-detail");`,
      auth: { "fixture-login": { type: "api_key", key: "fixture-old-key" }, unrelated: { type: "api_key", key: "fixture-other-key" } },
    });
    b.send({ type: "providers" });
    // The broken extension is named by path and skipped; pi's own providers still list.
    assert.match((await b.reply("extensionFailed")).path, /fixture\.ts$/);
    const { providers } = await b.reply("providers");
    assert.equal(providers.find(p => p.id === "fixture-login"), undefined);
    assert.ok(providers.some(p => p.id === "anthropic"));
    b.send({ type: "logout", provider: "fixture-login" });
    await b.reply("loggedOut");
    assert.deepEqual(b.auth(), { unrelated: { type: "api_key", key: "fixture-other-key" } });
    assert.doesNotMatch(b.output(), /fixture-extension-private-detail/);
    await b.close();
  });

  test(`${sdk}: an extension added in Shepherd, loaded by its path in settings, offers its sign-in`, { timeout: 30000 }, async t => {
    const b = await bridge(t, sdk, { added: true });
    b.send({ type: "providers" });
    const { providers } = await b.reply("providers");
    assert.equal(providers.find(p => p.id === "fixture-login")?.oauth, "Fixture account");
    b.send({ type: "login", provider: "fixture-login", method: "oauth", flow: "paste" });
    const prompt = await b.reply("prompt");
    b.send({ type: "answer", id: prompt.id, value: "fixture-code" });
    assert.equal((await b.reply("done")).credential, "oauth");
    await b.close();
  });

  test(`${sdk}: cancelling a custom prompt does not require the provider to pass a signal`, { timeout: 30000 }, async t => {
    const b = await bridge(t, sdk);
    b.send({ type: "login", provider: "fixture-login", method: "oauth", flow: "paste" });
    await b.reply("prompt");
    b.send({ type: "cancel" });
    assert.equal((await b.reply("failed")).code, "cancelled");
    assert.deepEqual(b.auth(), {});
    await b.close();
  });

  test(`${sdk}: an empty selection fails rather than leaving a dead sign-in form`, { timeout: 30000 }, async t => {
    const b = await bridge(t, sdk, { source: provider({ login: `await interaction.prompt({ type: "select", message: "Choose", options: [] });` }) });
    b.send({ type: "login", provider: "fixture-login", method: "oauth", flow: "paste" });
    assert.equal((await b.reply("failed")).reason, "The provider offered no sign-in choices.");
    assert.deepEqual(b.auth(), {});
    await b.close();
  });

  test(`${sdk}: provider questions are forwarded, not mistaken for built-in login choices`, { timeout: 30000 }, async t => {
    const b = await bridge(t, sdk, { source: provider({ id: "openai-codex", login: `
      const choice = await interaction.prompt({ type: "select", message: "Choose region", options: [{ id: "browser", label: "Browser region" }, { id: "other", label: "Other region" }] });
      if (choice !== "other") throw Error("Unexpected choice");
      const tenant = await interaction.prompt({ type: "text", message: "Enterprise tenant" });
      if (tenant !== "acme") throw Error("Unexpected tenant");
      const secret = await interaction.prompt({ type: "secret", message: "Account password" });
      if (secret !== " fixture-password ") throw Error("Unexpected secret");
    ` }) });
    b.send({ type: "login", provider: "openai-codex", method: "oauth", flow: "browser" });
    const select = await b.reply("prompt");
    assert.equal(select.kind, "select");
    b.send({ type: "answer", id: select.id, value: "other" });
    const text = await b.reply("prompt", p => p.id !== select.id);
    assert.equal(text.kind, "text");
    b.send({ type: "answer", id: text.id, value: "acme" });
    const secret = await b.reply("prompt", p => p.id !== select.id && p.id !== text.id);
    assert.equal(secret.kind, "secret");
    b.send({ type: "answer", id: secret.id, value: " fixture-password " });
    await b.reply("done");
    assert.doesNotMatch(b.output(), /fixture-password|fixture-access-not-a-secret|fixture-refresh-not-a-secret/);
    await b.close();
  });
}
