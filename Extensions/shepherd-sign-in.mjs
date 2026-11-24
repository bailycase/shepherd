// Shepherd's sign-in bridge. Not an extension: the app runs it with the engine's node, in a login
// shell, as `node shepherd-sign-in.mjs <pi sdk> <pi home>`, for Settings ▸ Pi ▸ Sign-in's sheet.
//
// `node shepherd-sign-in.mjs <pi sdk> <pi home> [extension…]`: extensions after the home are Shepherd's
// own it loads beside the home's (shepherd-usage.mjs).
//
// It runs pi's own login (`ModelRuntime.login`) against Shepherd's pi home, never the user's, and
// passes pi's prompts and events to the app as JSON lines. The credential goes from pi straight
// into the home's auth.json: nothing of it is written to stdout or stderr. One process per sheet.
//
// stdin, one JSON object a line:
//   {"type":"login","provider":"anthropic","method":"oauth"|"api_key","flow":"browser"|"device"|"paste"}
//   ("paste" is the browser flow without the callback port's check: a code pasted from the page)
//   {"type":"answer","id":"p1","value":"…"}      a prompt's answer (a key, a pasted code)
//   {"type":"cancel"}                            ends the login under way
//   {"type":"providers"}                         lists interactive provider auth methods
//   {"type":"usage","accounts"?:[{"provider":…,"id":…,"credential":{…}}]}
//                                                asks each provider extension that reports usage (see below), for
//                                                the signed-in account and each saved account listed
//   {"type":"logout","provider":"anthropic"}     removes Shepherd's credential for it
//   {"type":"check","id":"c1","provider":"deepseek","key":"…"} or {…,"variable":"DEEPSEEK_API_KEY"}
//   ({"type":"check","id":"c2","provider":"anthropic"} alone checks the home's stored login for it)
// stdout:
//   {"type":"ready"}
//   {"type":"providers","providers":[{"id":…, "name":…, "oauth"?:…, "apiKey"?:…}]}
//   {"type":"extensionFailed","path":…}         an installed extension that didn't load (before the first reply that loads them)
//   {"type":"extensions","extensions":[{"path":…, "providers":[…], "tools":[…], "commands":[…], "events":[…],
//     "shortcuts":[…], "flags":[…], "renderers":n}]}   what each loaded extension registered, before "providers"
//   {"type":"event","event":{"type":"auth_url"|"device_code"|"info"|"progress",…}}
//   {"type":"prompt","id":"p1","kind":"manual_code"|"secret"|"text"|"select","message":…,"placeholder"?,"options"?}
//   {"type":"promptClosed","id":"p1"}           pi no longer needs that answer (the browser won)
//   {"type":"done","provider":…,"credential":"oauth"|"api_key"}
//   {"type":"failed","code":"cancelled"|"portBusy"|"unknownProvider"|"other","reason":…,"port"?}
//   {"type":"checked","id":…,"result":"works"|"rejected"|"unreachable"|"unset","reason"?,"models"?}
//   {"type":"loggedOut","provider":…}
//   {"type":"usage","usage":[{"provider":…, "account"?:id, "windows":[{"name":…,"usedPercent":0–100,"resetsAt"?:ms}],
//     "balance"?:{"amount":n,"currency":…,"label"?:…}, "email"?:…}]}
//
// Usage, a Shepherd convention pi itself doesn't read: a provider an extension registers may have
// `usage(auth)`, or an extension may report for a provider it doesn't own (a built-in's key) with
// `pi.events.emit("shepherd:usage", { provider: "deepseek", usage(auth) {…} })`. `auth` is pi's
// resolved request auth for the provider ({ apiKey, headers }, refreshed as a request would be) and
// the stored `credential`; for a saved account that isn't active, its stored credential as it is
// (never refreshed) with `apiKey` its token or key. It returns { windows?: [{ name, usedPercent,
// resetsAt? }], balance?: { amount, currency, label? }, email? }.
// Only those numbers and short words leave this process; a hook that throws or takes over
// USAGE_TIMEOUT_MS reports nothing.
//
// It exits when stdin closes, and never throws: every failure is a line.
import * as fs from "node:fs";
import * as net from "node:net";
import * as path from "node:path";
import * as readline from "node:readline";
import { pathToFileURL } from "node:url";

const [sdkPath, home, ...shepherdExtensions] = process.argv.slice(2);

/** The callback ports pi's browser sign-ins listen on, checked before the browser opens. */
const CALLBACK_PORTS = { anthropic: 53692, "openai-codex": 1455, radius: 1456 };
// Verified single-field key logins in pinned Pi. Everything else uses the provider's questions.
const KEY_FORMS = new Set([
  "anthropic", "ant-ling", "azure", "baseten", "cerebras", "deepseek", "fireworks", "github-copilot", "google", "groq",
  "huggingface", "kimi-coding", "meta", "minimax", "minimax-cn", "mistral", "moonshotai", "moonshotai-cn", "nvidia",
  "openai", "opencode", "opencode-go", "openrouter", "qwen-token-plan", "qwen-token-plan-cn", "qwen-token-plan-individual",
  "qwen-token-plan-individual-cn", "together", "typesafe", "vercel-ai-gateway", "xai", "xiaomi", "xiaomi-token-plan-ams",
  "xiaomi-token-plan-cn", "xiaomi-token-plan-sgp", "zai", "zai-coding-cn",
]);
const nativeLogins = new Map();

function send(message) {
  process.stdout.write(JSON.stringify(message) + "\n");
}

/** A reason without a stack, a response body, or anything that looks like a token. */
export function clean(reason, secrets = []) {
  let text = String(reason instanceof Error ? reason.message : reason ?? "");
  for (const secret of secrets) {
    if (secret) text = text.split(secret).join("••••");
  }
  text = text.split(/\r?\n/)[0];
  text = text.replace(/\s*;?\s*body=.*$/s, "").replace(/\s*;?\s*details=.*$/s, "");
  text = text.replace(/[A-Za-z0-9_\-.~+/]{32,}={0,2}/g, "••••");
  return text.trim().slice(0, 240);
}

async function storedRuntime() {
  const sdk = await import(pathToFileURL(sdkPath).href);
  return sdk.ModelRuntime.create({
    authPath: path.join(home, "auth.json"),
    modelsPath: path.join(home, "models.json"),
    refreshOnCreate: false,
  });
}

let runtime;
/** What each installed extension registered (`extensions` reply): sent with every provider list. */
let inventory = [];
/** Usage hooks by provider id: a provider's own `usage`, or one reported on the "shepherd:usage" event. */
const usageHooks = new Map();
const USAGE_TIMEOUT_MS = 10000;
async function modelRuntime() {
  return runtime ??= (async () => {
    const sdk = await import(pathToFileURL(sdkPath).href);
    const models = await storedRuntime();
    for (const provider of models.getProviders()) nativeLogins.set(provider.id, {
      oauth: provider.auth.oauth?.login, apiKey: provider.auth.apiKey?.login,
    });
    // Sign-in uses the same installed providers as agents, but never starts a conversation,
    // runs session handlers, or loads a workspace's code into the global credential store. Pi's
    // own loader, registered here as `createAgentSessionServices` does, so each provider keeps
    // the extension that registered it (pi clears that record once it has registered them).
    const eventBus = sdk.createEventBus?.();
    // Before loading, so a hook reported while an extension loads is heard.
    eventBus?.on("shepherd:usage", data => {
      if (data && typeof data.provider === "string" && typeof data.usage === "function") usageHooks.set(data.provider, data.usage);
    });
    const loader = new sdk.DefaultResourceLoader({
      cwd: home, agentDir: home, settingsManager: sdk.SettingsManager.create(home, home, { projectTrusted: false }), eventBus,
      noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
      additionalExtensionPaths: shepherdExtensions,
    });
    await loader.reload();
    const loaded = loader.getExtensions();
    const failed = new Set(loaded.errors.map(error => String(error.path)));
    const owners = new Map();
    const register = (extensionPath, id, apply) => {
      try {
        apply();
        owners.set(id, String(extensionPath));
      } catch {
        failed.add(String(extensionPath));
      }
    };
    for (const { name, config, extensionPath } of loaded.runtime.pendingProviderRegistrations)
      register(extensionPath, name, () => models.registerProvider(name, config));
    for (const { provider, extensionPath } of loaded.runtime.pendingNativeProviderRegistrations) {
      register(extensionPath, provider.id, () => models.registerNativeProvider(provider));
      if (typeof provider.usage === "function") usageHooks.set(provider.id, provider.usage.bind(provider));
    }
    loaded.runtime.pendingProviderRegistrations = [];
    loaded.runtime.pendingNativeProviderRegistrations = [];
    await models.refresh({ allowNetwork: false });
    // One extension that fails leaves the others' providers usable: the app learns its path (never
    // its error, which may quote its code) and leaves it out of launches, as pi's own failure does.
    for (const extensionPath of failed) send({ type: "extensionFailed", path: extensionPath });
    const keys = map => [...(map?.keys() ?? [])].map(String);
    inventory = loaded.extensions.filter(extension => !failed.has(String(extension.path))).map(extension => ({
      path: String(extension.path),
      providers: [...owners].filter(([, owner]) => owner === String(extension.path)).map(([id]) => id),
      tools: keys(extension.tools),
      commands: keys(extension.commands),
      events: keys(extension.handlers),
      shortcuts: keys(extension.shortcuts),
      flags: keys(extension.flags),
      renderers: (extension.messageRenderers?.size ?? 0) + (extension.entryRenderers?.size ?? 0)
        + (extension.toolRenderers?.length ?? 0) + (extension.markdownTransformer ? 1 : 0),
    }));
    return models;
  })();
}

/** One hook's answer, reduced to numbers and short words; undefined when it gave nothing usable. */
export function usageReport(provider, answer, secrets = [], account) {
  if (!answer || typeof answer !== "object") return undefined;
  const word = (value, max) => clean(String(value ?? ""), secrets).slice(0, max);
  const windows = (Array.isArray(answer.windows) ? answer.windows : []).slice(0, 4).flatMap(window => {
    const used = Number(window?.usedPercent);
    const name = word(window?.name, 40);
    if (!name || !Number.isFinite(used)) return [];
    const resets = typeof window.resetsAt === "string" ? Date.parse(window.resetsAt) : Number(window?.resetsAt);
    return [{ name, usedPercent: Math.min(100, Math.max(0, used)), ...(Number.isFinite(resets) && resets > 0 ? { resetsAt: resets } : {}) }];
  });
  let balance;
  const amount = Number(answer.balance?.amount);
  const currency = word(answer.balance?.currency, 12);
  if (Number.isFinite(amount) && currency) {
    const label = word(answer.balance.label, 40);
    balance = { amount, currency, ...(label ? { label } : {}) };
  }
  const email = typeof answer.email === "string" && /^[^\s@]+@[^\s@]+$/.test(answer.email) && answer.email.length <= 120
    ? answer.email : undefined;
  if (!windows.length && !balance) return undefined;
  return { provider, ...(account ? { account } : {}), windows, ...(balance ? { balance } : {}), ...(email ? { email } : {}) };
}

/** A hook's answer within USAGE_TIMEOUT_MS, reduced by `usageReport`; undefined on any failure. */
async function askHook(hook, provider, auth, account) {
  const secrets = [auth.apiKey, auth.credential?.access, auth.credential?.refresh, auth.credential?.key,
    ...Object.values(auth.headers ?? {})].filter(value => typeof value === "string" && value.length >= 4);
  let timer;
  const timeout = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("timed out")), USAGE_TIMEOUT_MS); });
  try {
    return usageReport(provider, await Promise.race([hook(auth), timeout]), secrets, account);
  } catch {
    return undefined;
  } finally {
    clearTimeout(timer);
  }
}

function storedCredential(provider) {
  try {
    return JSON.parse(fs.readFileSync(path.join(home, "auth.json"), "utf8"))[provider];
  } catch {
    return undefined;
  }
}

async function reportUsage(message) {
  let models;
  try {
    models = await modelRuntime();
  } catch {
    send({ type: "usage", usage: [] });
    return;
  }
  const active = [...usageHooks].map(async ([provider, hook]) => {
    try {
      const resolved = await models.getAuth(provider);
      if (!resolved?.auth) return undefined;
      // Read after getAuth, which refreshes an expired sign-in into auth.json.
      return await askHook(hook, provider, { ...resolved.auth, credential: storedCredential(provider) });
    } catch {
      return undefined;
    }
  });
  const saved = (Array.isArray(message.accounts) ? message.accounts : []).map(account => {
    const hook = usageHooks.get(account?.provider);
    const credential = account?.credential;
    if (!hook || typeof account.id !== "string" || !credential || typeof credential !== "object") return undefined;
    return askHook(hook, account.provider, { apiKey: credential.access ?? credential.key, headers: {}, credential }, account.id);
  });
  const reports = await Promise.all([...active, ...saved]);
  // A refreshed sign-in is saved before the answer, so it is never lost when the bridge exits.
  await Promise.resolve(models.settleCredentialWrites?.()).catch(() => {});
  send({ type: "usage", usage: reports.filter(Boolean) });
}

function portFree(port) {
  return new Promise((resolve) => {
    const server = net.createServer();
    server.unref();
    server.once("error", (error) => resolve(error && error.code === "EADDRINUSE" ? false : true));
    server.listen(port, "127.0.0.1", () => server.close(() => resolve(true)));
  });
}

let login;
let promptCount = 0;
const prompts = new Map();
/** What the user typed for this login (a key, a code): kept out of every reason sent back. */
let typed = [];

function answerAutomatically(prompt, flow, provider) {
  if (prompt.type === "select" && ["openai-codex", "radius"].includes(provider)) {
    const want = flow === "device" ? /device/i : /browser/i;
    const option = prompt.options.find((o) => want.test(o.id) || want.test(o.label));
    return option ? option.id : undefined;
  }
  // GitHub Copilot asks for an Enterprise domain first: blank is github.com.
  if (provider === "github-copilot" && prompt.type === "text" && /enterprise/i.test(prompt.message)) return "";
  return undefined;
}

function interaction(controller, flow, provider, { nativeOAuth = false, keyForm = false } = {}) {
  return {
    signal: controller.signal,
    notify(event) {
      if (!event || typeof event !== "object") return;
      const { type } = event;
      if (type === "auth_url") send({ type: "event", event: { type, url: event.url, instructions: event.instructions } });
      else if (type === "device_code")
        send({
          type: "event",
          event: {
            type,
            userCode: event.userCode,
            verificationUri: event.verificationUri,
            expiresInSeconds: event.expiresInSeconds,
          },
        });
      else if (type === "info" || type === "progress") send({ type: "event", event: { type, message: String(event.message ?? "") } });
    },
    prompt(prompt) {
      if (!["manual_code", "secret", "text", "select"].includes(prompt.type))
        return Promise.reject(new Error("The provider asked an unsupported sign-in question."));
      if (prompt.type === "select" && (!Array.isArray(prompt.options) || !prompt.options.length))
        return Promise.reject(new Error("The provider offered no sign-in choices."));
      const automatic = nativeOAuth ? answerAutomatically(prompt, flow, provider) : undefined;
      if (automatic !== undefined) return Promise.resolve(automatic);
      const id = `p${++promptCount}`;
      return new Promise((resolve, reject) => {
        const signal = prompt.signal ? AbortSignal.any([controller.signal, prompt.signal]) : controller.signal;
        const close = () => {
          const pending = prompts.get(id);
          if (!pending) return;
          prompts.delete(id);
          send({ type: "promptClosed", id });
          pending.reject(new Error("Login cancelled"));
        };
        prompts.set(id, {
          resolve(value) { signal.removeEventListener("abort", close); resolve(value); },
          reject(error) { signal.removeEventListener("abort", close); reject(error); },
        });
        if (signal.aborted) return close();
        signal.addEventListener("abort", close, { once: true });
        send({
          type: "prompt",
          id,
          kind: prompt.type,
          keyForm: prompt.type === "secret" && keyForm ? true : undefined,
          message: String(prompt.message ?? ""),
          placeholder: prompt.placeholder,
          options: prompt.type === "select" ? prompt.options.map((o) => ({ id: o.id, label: o.label })) : undefined,
        });
      });
    },
  };
}

async function startLogin(message) {
  if (login) return send({ type: "failed", code: "other", reason: "A sign-in is already under way." });
  const { provider, method = "oauth", flow = "browser" } = message;
  const controller = new AbortController();
  login = controller;
  typed = [];
  let callbackPort;
  try {
    const models = await modelRuntime();
    const effective = models.getProvider(provider);
    if (!effective) {
      return send({ type: "failed", code: "unknownProvider", reason: `Shepherd’s pi doesn’t know ${provider}.` });
    }
    const native = nativeLogins.get(provider);
    const nativeOAuth = !!native?.oauth && native.oauth === effective.auth.oauth?.login;
    const keyForm = KEY_FORMS.has(provider) && !!native?.apiKey && native.apiKey === effective.auth.apiKey?.login;
    const port = callbackPort = nativeOAuth ? CALLBACK_PORTS[provider] : undefined;
    if (method === "oauth" && flow === "browser" && port && !(await portFree(port))) {
      return send({ type: "failed", code: "portBusy", port, reason: `Another sign-in is using localhost:${port}.` });
    }
    const credential = await models.login(provider, method, interaction(controller, flow, provider, { nativeOAuth, keyForm }));
    send({ type: "done", provider, credential: credential && credential.type === "oauth" ? "oauth" : "api_key" });
  } catch (error) {
    if (controller.signal.aborted || /Login cancelled/.test(String(error && error.message))) {
      send({ type: "failed", code: "cancelled", reason: "Cancelled." });
    } else if (error && error.code === "EADDRINUSE") {
      send({ type: "failed", code: "portBusy", port: error.port ?? callbackPort, reason: clean(error, typed) });
    } else {
      send({ type: "failed", code: "other", reason: clean(error, typed) });
    }
  } finally {
    login = undefined;
    for (const [id, pending] of prompts) {
      prompts.delete(id);
      pending.reject(new Error("Login cancelled"));
    }
  }
}

async function listProviders() {
  try {
    const models = await modelRuntime();
    const providers = models.getProviders().map(provider => ({
      id: provider.id,
      name: provider.name,
      oauth: provider.auth.oauth?.name,
      apiKey: provider.auth.apiKey?.login ? provider.auth.apiKey.name : undefined,
      keyForm: KEY_FORMS.has(provider.id) && !!nativeLogins.get(provider.id)?.apiKey
        && nativeLogins.get(provider.id).apiKey === provider.auth.apiKey?.login,
    })).filter(provider => provider.oauth || provider.apiKey);
    send({ type: "extensions", extensions: inventory });
    send({ type: "providers", providers });
  } catch (error) {
    send({ type: "failed", code: "other", reason: clean(error) });
  }
}

async function logout(message) {
  try {
    // Removing a credential must work even if an installed extension cannot load.
    const models = await storedRuntime();
    await models.logout(message.provider);
    send({ type: "loggedOut", provider: message.provider });
  } catch (error) {
    send({ type: "failed", code: "other", reason: clean(error) });
  }
}

/**
 * Whether a key works: the smallest request pi can make with it, on the provider's first model.
 * With neither key nor variable, the home's stored login is used (and a stale OAuth token refreshed
 * on the way; one whose refresh token rotated elsewhere comes back `invalid_grant`, a rejection).
 */
async function check(message) {
  const { id, provider } = message;
  let key = message.key;
  if (message.variable) {
    key = process.env[message.variable];
    if (!key) return send({ type: "checked", id, result: "unset", reason: `$${message.variable} isn’t set in your login shell.` });
  }
  try {
    const models = await modelRuntime();
    const list = models.getModels(provider);
    if (!list.length) return send({ type: "checked", id, result: "unreachable", reason: `Shepherd’s pi has no models for ${provider}.` });
    const model = list.find((m) => !m.reasoning) ?? list[0];
    const reply = await models.completeSimple(
      model,
      { messages: [{ role: "user", content: "Reply with OK.", timestamp: Date.now() }] },
      { apiKey: key, maxTokens: 16, signal: AbortSignal.timeout(20_000) },
    );
    if (reply && reply.stopReason === "error") throw new Error(reply.errorMessage || "The provider refused the request.");
    send({ type: "checked", id, result: "works", models: list.slice(0, 3).map((m) => m.id) });
  } catch (error) {
    const reason = clean(error, [key]);
    const rejected = /\b(401|403)\b|unauthori[sz]ed|invalid.{0,20}(api.?key|key|token|grant)|incorrect api key|authentication|permission/i.test(reason);
    send({ type: "checked", id, result: rejected ? "rejected" : "unreachable", reason });
  }
}

function handle(line) {
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    return;
  }
  if (!message || typeof message !== "object") return;
  switch (message.type) {
    case "login":
      void startLogin(message);
      break;
    case "answer": {
      const pending = prompts.get(message.id);
      if (!pending) return;
      prompts.delete(message.id);
      typed.push(String(message.value ?? ""));
      pending.resolve(String(message.value ?? ""));
      break;
    }
    case "providers":
      void listProviders();
      break;
    case "usage":
      void reportUsage(message);
      break;
    case "cancel":
      login?.abort();
      break;
    case "logout":
      void logout(message);
      break;
    case "check":
      void check(message);
      break;
  }
}

if (sdkPath && home) {
  process.on("uncaughtException", (error) => send({ type: "failed", code: "other", reason: clean(error, typed) }));
  process.on("unhandledRejection", (error) => send({ type: "failed", code: "other", reason: clean(error, typed) }));
  const lines = readline.createInterface({ input: process.stdin });
  lines.on("line", handle);
  lines.on("close", () => {
    login?.abort();
    setTimeout(() => process.exit(0), 200);
  });
  send({ type: "ready" });
}
