// Shepherd's sign-in bridge. Not an extension: the app runs it with the engine's node, in a login
// shell, as `node shepherd-sign-in.mjs <pi sdk> <pi home>`, for Settings ▸ Pi ▸ Sign-in's sheet.
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
//   {"type":"logout","provider":"anthropic"}     removes Shepherd's credential for it
//   {"type":"check","id":"c1","provider":"deepseek","key":"…"} or {…,"variable":"DEEPSEEK_API_KEY"}
//   ({"type":"check","id":"c2","provider":"anthropic"} alone checks the home's stored login for it)
// stdout:
//   {"type":"ready"}
//   {"type":"providers","providers":[{"id":…, "name":…, "oauth"?:…, "apiKey"?:…}]}
//   {"type":"extensionFailed","path":…}         an installed extension that didn't load (before the first reply that loads them)
//   {"type":"event","event":{"type":"auth_url"|"device_code"|"info"|"progress",…}}
//   {"type":"prompt","id":"p1","kind":"manual_code"|"secret"|"text"|"select","message":…,"placeholder"?,"options"?}
//   {"type":"promptClosed","id":"p1"}           pi no longer needs that answer (the browser won)
//   {"type":"done","provider":…,"credential":"oauth"|"api_key"}
//   {"type":"failed","code":"cancelled"|"portBusy"|"unknownProvider"|"other","reason":…,"port"?}
//   {"type":"checked","id":…,"result":"works"|"rejected"|"unreachable"|"unset","reason"?,"models"?}
//   {"type":"loggedOut","provider":…}
//
// It exits when stdin closes, and never throws: every failure is a line.
import * as net from "node:net";
import * as path from "node:path";
import * as readline from "node:readline";
import { pathToFileURL } from "node:url";

const [sdkPath, home] = process.argv.slice(2);

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
async function modelRuntime() {
  return runtime ??= (async () => {
    const sdk = await import(pathToFileURL(sdkPath).href);
    const models = await storedRuntime();
    for (const provider of models.getProviders()) nativeLogins.set(provider.id, {
      oauth: provider.auth.oauth?.login, apiKey: provider.auth.apiKey?.login,
    });
    // Sign-in uses the same installed providers as agents, but never starts a conversation,
    // runs session handlers, or loads a workspace's code into the global credential store.
    const services = await sdk.createAgentSessionServices({
      cwd: home, agentDir: home, modelRuntime: models,
      settingsManager: sdk.SettingsManager.create(home, home, { projectTrusted: false }),
      resourceLoaderOptions: { noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true },
    });
    if (services.diagnostics.some(d => d.type === "error")) throw new Error("Could not load installed provider extensions.");
    // One extension that fails leaves the others' providers usable: the app learns its path (never
    // its error, which may quote its code) and leaves it out of launches, as pi's own failure does.
    for (const { path: failed } of services.resourceLoader.getExtensions().errors) send({ type: "extensionFailed", path: String(failed) });
    return services.modelRuntime;
  })();
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
