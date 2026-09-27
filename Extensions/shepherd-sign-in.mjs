// Shepherd's sign-in bridge. Not an extension: the app runs it with the engine's node, in a login
// shell, as `node shepherd-sign-in.mjs <pi sdk> <pi home>`, for Settings ▸ Pi ▸ Sign-in's sheet.
//
// It runs pi's own login (`ModelRuntime.login`) against Shepherd's pi home, never the user's, and
// passes pi's prompts and events to the app as JSON lines. The credential goes from pi straight
// into the home's auth.json: nothing of it is written to stdout or stderr. One process per sheet.
//
// stdin, one JSON object a line:
//   {"type":"login","provider":"anthropic","method":"oauth"|"api_key","flow":"browser"|"device"}
//   {"type":"answer","id":"p1","value":"…"}      a prompt's answer (a key, a pasted code)
//   {"type":"cancel"}                            ends the login under way
//   {"type":"logout","provider":"anthropic"}     removes Shepherd's credential for it
//   {"type":"check","id":"c1","provider":"deepseek","key":"…"} or {…,"variable":"DEEPSEEK_API_KEY"}
// stdout:
//   {"type":"ready"}
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

function send(message) {
  process.stdout.write(JSON.stringify(message) + "\n");
}

/** A reason without a stack, a response body, or anything that looks like a token. */
export function clean(reason, secrets = []) {
  let text = String(reason instanceof Error ? reason.message : reason ?? "");
  for (const secret of secrets) {
    if (secret && secret.length >= 8) text = text.split(secret).join("••••");
  }
  text = text.split(/\r?\n/)[0];
  text = text.replace(/\s*;?\s*body=.*$/s, "").replace(/\s*;?\s*details=.*$/s, "");
  text = text.replace(/[A-Za-z0-9_\-.~+/]{32,}={0,2}/g, "••••");
  return text.trim().slice(0, 240);
}

let runtime;
async function modelRuntime() {
  if (!runtime) {
    const sdk = await import(pathToFileURL(sdkPath).href);
    runtime = await sdk.ModelRuntime.create({
      authPath: path.join(home, "auth.json"),
      modelsPath: path.join(home, "models.json"),
      refreshOnCreate: false,
    });
  }
  return runtime;
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

function answerAutomatically(prompt, flow) {
  if (prompt.type === "select") {
    const want = flow === "device" ? /device/i : /browser/i;
    const option = prompt.options.find((o) => want.test(o.id) || want.test(o.label));
    return option ? option.id : undefined;
  }
  // GitHub Copilot asks for an Enterprise domain first: blank is github.com.
  if (prompt.type === "text" && /enterprise/i.test(prompt.message)) return "";
  return undefined;
}

function interaction(controller, flow) {
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
      const automatic = answerAutomatically(prompt, flow);
      if (automatic !== undefined) return Promise.resolve(automatic);
      const id = `p${++promptCount}`;
      return new Promise((resolve, reject) => {
        const close = () => {
          if (!prompts.delete(id)) return;
          send({ type: "promptClosed", id });
          reject(new Error("Login cancelled"));
        };
        prompts.set(id, { resolve, reject });
        if (prompt.signal) {
          if (prompt.signal.aborted) return close();
          prompt.signal.addEventListener("abort", close, { once: true });
        }
        send({
          type: "prompt",
          id,
          kind: prompt.type,
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
  try {
    const models = await modelRuntime();
    if (!models.getProvider(provider)) {
      return send({ type: "failed", code: "unknownProvider", reason: `Shepherd’s pi doesn’t know ${provider}.` });
    }
    const port = CALLBACK_PORTS[provider];
    if (method === "oauth" && flow === "browser" && port && !(await portFree(port))) {
      return send({ type: "failed", code: "portBusy", port, reason: `Another sign-in is using localhost:${port}.` });
    }
    const credential = await models.login(provider, method, interaction(controller, flow));
    send({ type: "done", provider, credential: credential && credential.type === "oauth" ? "oauth" : "api_key" });
  } catch (error) {
    if (controller.signal.aborted || /Login cancelled/.test(String(error && error.message))) {
      send({ type: "failed", code: "cancelled", reason: "Cancelled." });
    } else if (error && error.code === "EADDRINUSE") {
      send({ type: "failed", code: "portBusy", port: CALLBACK_PORTS[provider], reason: clean(error) });
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

async function logout(message) {
  try {
    const models = await modelRuntime();
    await models.logout(message.provider);
    send({ type: "loggedOut", provider: message.provider });
  } catch (error) {
    send({ type: "failed", code: "other", reason: clean(error) });
  }
}

/** Whether a key works: the smallest request pi can make with it, on the provider's first model. */
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
    const rejected = /\b(401|403)\b|unauthori[sz]ed|invalid.{0,20}(api.?key|key|token)|incorrect api key|authentication|permission/i.test(reason);
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
  process.on("uncaughtException", (error) => send({ type: "failed", code: "other", reason: clean(error) }));
  process.on("unhandledRejection", (error) => send({ type: "failed", code: "other", reason: clean(error) }));
  const lines = readline.createInterface({ input: process.stdin });
  lines.on("line", handle);
  lines.on("close", () => {
    login?.abort();
    setTimeout(() => process.exit(0), 200);
  });
  send({ type: "ready" });
}
