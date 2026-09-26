// Shepherd's MCP client: JSON-RPC 2.0 over stdio, Streamable HTTP (with the legacy HTTP+SSE
// fallback) and legacy SSE, with no dependencies. The pi extension (shepherd-mcp.ts) imports it,
// and the app runs it as `node shepherd-mcp-client.mjs probe` to list a server's tools for
// Settings, so there is one MCP client. Every socket, pipe and timer is unref'd: a connection
// never keeps pi alive, and every stdio server's process group is killed when pi exits.
import { spawn } from "node:child_process";
import * as http from "node:http";
import * as https from "node:https";
import { pathToFileURL } from "node:url";

export const PROTOCOL_VERSION = "2025-06-18";
const CLIENT_INFO = { name: "shepherd", title: "Shepherd", version: "1" };
const STDERR_TAIL = 4096;
const MAX_TOOL_PAGES = 100;

/** A failure with a kind the caller maps to a status: auth, timeout, start, closed, http, rpc, cancelled. */
export class MCPError extends Error {
  constructor(message, { kind = "error", status, challenge } = {}) {
    super(message);
    this.name = "MCPError";
    this.kind = kind;
    this.status = status;
    this.challenge = challenge;
  }
}

// ---- configuration --------------------------------------------------------------------------

/** `stdio`, `http` (Streamable, falling back to SSE) or `sse`, from an entry's `type`, `command` and `url`. */
export function transportKind(entry) {
  if (!entry || typeof entry !== "object") return undefined;
  const type = typeof entry.type === "string" ? entry.type.toLowerCase() : "";
  if (type === "stdio" || (typeof entry.command === "string" && typeof entry.url !== "string")) {
    return typeof entry.command === "string" ? "stdio" : undefined;
  }
  if (typeof entry.url !== "string") return undefined;
  return type === "sse" ? "sse" : "http";
}

const ENV_REF = /\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}/g;
const KEYCHAIN_REF = /\$\{keychain:([^}/]+)\/([^}]+)\}/g;

/** `${VAR}` and `${VAR:-default}` from `env`; `${keychain:…}` is left for the app. */
export function expandVariables(value, env, missing = []) {
  if (typeof value !== "string") return value;
  return value.replace(ENV_REF, (_match, name, fallback) => {
    const found = env[name];
    if (found !== undefined && found !== "") return found;
    if (fallback !== undefined) return fallback;
    if (!missing.includes(name)) missing.push(name);
    return "";
  });
}

/** Every `${keychain:<server>/<NAME>}` reference anywhere in an entry. */
export function keychainReferences(entry) {
  const found = [];
  const visit = (value) => {
    if (typeof value === "string") {
      for (const match of value.matchAll(KEYCHAIN_REF)) found.push(`${match[1]}/${match[2]}`);
    } else if (Array.isArray(value)) value.forEach(visit);
    else if (value && typeof value === "object") Object.values(value).forEach(visit);
  };
  visit({ command: entry?.command, args: entry?.args, env: entry?.env, url: entry?.url, headers: entry?.headers });
  return [...new Set(found)];
}

/** Replaces this server's `${keychain:<server>/<NAME>}` with `secrets[NAME]` (or `secrets["<server>/<NAME>"]`). */
function resolveKeychain(value, server, secrets, missing) {
  if (typeof value !== "string") return value;
  return value.replace(KEYCHAIN_REF, (match, owner, name) => {
    const secret = secrets?.[`${owner}/${name}`] ?? (owner === server ? secrets?.[name] : undefined);
    if (typeof secret === "string") return secret;
    if (!missing.includes(name)) missing.push(name);
    return match;
  });
}

function stringMap(value) {
  const out = {};
  if (!value || typeof value !== "object" || Array.isArray(value)) return out;
  for (const [key, item] of Object.entries(value)) {
    if (typeof item === "string") out[key] = item;
    else if (typeof item === "number" || typeof item === "boolean") out[key] = String(item);
  }
  return out;
}

/**
 * What to connect to: the entry with `${VAR}` expanded from `env` and `${keychain:…}` from the
 * credentials the app handed over (`env` holds the secrets by name, `headers` extra headers,
 * `bearer` an OAuth access token). `missingSecrets` names the keychain items still unresolved and
 * `missingVariables` the environment variables that were empty.
 */
export function resolveEntry(server, entry, env = process.env, credentials = undefined) {
  const kind = transportKind(entry);
  const missingVariables = [];
  const missingSecrets = [];
  const secrets = credentials?.env ?? {};
  const expand = (value) => resolveKeychain(expandVariables(value, env, missingVariables), server, secrets, missingSecrets);
  if (kind === "stdio") {
    const childEnv = {};
    for (const [key, value] of Object.entries(stringMap(entry.env))) childEnv[key] = expand(value);
    return {
      kind,
      command: expand(entry.command),
      args: Array.isArray(entry.args) ? entry.args.map((arg) => expand(String(arg))) : [],
      env: childEnv,
      missingVariables,
      missingSecrets,
    };
  }
  if (kind === "http" || kind === "sse") {
    const headers = {};
    for (const [key, value] of Object.entries(stringMap(entry.headers))) headers[key] = expand(value);
    for (const [key, value] of Object.entries(stringMap(credentials?.headers))) headers[key] = value;
    if (typeof credentials?.bearer === "string" && credentials.bearer) {
      for (const key of Object.keys(headers)) if (key.toLowerCase() === "authorization") delete headers[key];
      headers.Authorization = `Bearer ${credentials.bearer}`;
    }
    // A header whose variable was empty ("Bearer ") would only earn a 401: send none instead.
    for (const [key, value] of Object.entries(headers)) {
      if (/^\s*(bearer|token|basic)?\s*$/i.test(value)) delete headers[key];
    }
    return { kind, url: expand(entry.url), headers, missingVariables, missingSecrets };
  }
  return { kind: undefined, missingVariables, missingSecrets };
}

/** The scopes a `WWW-Authenticate` challenge names (`scope="a b"`). */
export function challengeScopes(challenge) {
  if (typeof challenge !== "string") return [];
  const match = /(?:^|[\s,])scope\s*=\s*(?:"([^"]*)"|([^\s,]+))/i.exec(challenge);
  return (match?.[1] ?? match?.[2] ?? "").split(/\s+/).filter(Boolean);
}

export function isInsufficientScope(challenge) {
  return typeof challenge === "string" && /error\s*=\s*"?insufficient_scope/i.test(challenge);
}

// ---- JSON-RPC ---------------------------------------------------------------------------------

class RPC {
  constructor(send, { onNotification, onClose } = {}) {
    this.send = send;
    this.onNotification = onNotification;
    this.onClose = onClose;
    this.nextID = 1;
    this.pending = new Map();
    this.closed = false;
  }

  request(method, params, { timeoutMs = 30_000, signal } = {}) {
    if (this.closed) return Promise.reject(new MCPError("the connection is closed", { kind: "closed" }));
    const id = this.nextID++;
    return new Promise((resolve, reject) => {
      const controller = new AbortController();
      const entry = { resolve, reject, controller, method };
      const finish = () => {
        this.pending.delete(id);
        clearTimeout(entry.timer);
        signal?.removeEventListener?.("abort", onAbort);
      };
      entry.finish = finish;
      const onAbort = () => {
        if (!this.pending.has(id)) return;
        finish();
        controller.abort();
        this.notify("notifications/cancelled", { requestId: id, reason: "The user stopped the tool call" });
        reject(new MCPError(`${method} was cancelled`, { kind: "cancelled" }));
      };
      entry.timer = setTimeout(() => {
        if (!this.pending.has(id)) return;
        finish();
        controller.abort();
        this.notify("notifications/cancelled", { requestId: id, reason: "timed out" });
        reject(new MCPError(`${method} got no answer in ${Math.round(timeoutMs / 1000)} s`, { kind: "timeout" }));
      }, timeoutMs);
      entry.timer.unref?.();
      this.pending.set(id, entry);
      if (signal?.aborted) return onAbort();
      signal?.addEventListener?.("abort", onAbort, { once: true });
      Promise.resolve()
        .then(() => this.send({ jsonrpc: "2.0", id, method, ...(params === undefined ? {} : { params }) }, controller.signal, id))
        .catch((error) => {
          if (!this.pending.has(id)) return;
          finish();
          reject(error instanceof MCPError ? error : new MCPError(String(error?.message ?? error), { kind: "closed" }));
        });
    });
  }

  notify(method, params) {
    if (this.closed) return;
    Promise.resolve()
      .then(() => this.send({ jsonrpc: "2.0", method, ...(params === undefined ? {} : { params }) }))
      .catch(() => {});
  }

  receive(message) {
    if (Array.isArray(message)) return message.forEach((item) => this.receive(item));
    if (!message || typeof message !== "object") return;
    if ("id" in message && ("result" in message || "error" in message) && !("method" in message)) {
      const entry = this.pending.get(message.id);
      if (!entry) return;
      entry.finish();
      if (message.error) {
        const text = typeof message.error.message === "string" ? message.error.message : JSON.stringify(message.error);
        entry.reject(new MCPError(text, { kind: "rpc", status: message.error.code }));
      } else entry.resolve(message.result ?? {});
      return;
    }
    if (typeof message.method !== "string") return;
    if ("id" in message) {
      // The client declares no capabilities: it answers ping and refuses anything else.
      const reply = message.method === "ping"
        ? { jsonrpc: "2.0", id: message.id, result: {} }
        : { jsonrpc: "2.0", id: message.id, error: { code: -32601, message: `Method not found: ${message.method}` } };
      Promise.resolve().then(() => this.send(reply)).catch(() => {});
      return;
    }
    try {
      this.onNotification?.(message.method, message.params);
    } catch {}
  }

  hasPending(id) {
    return this.pending.has(id);
  }

  fail(error, silent = false) {
    if (this.closed) return;
    this.closed = true;
    for (const entry of [...this.pending.values()]) {
      entry.finish();
      entry.reject(error);
    }
    if (silent) return;
    try {
      this.onClose?.(error);
    } catch {}
  }
}

// ---- stdio ------------------------------------------------------------------------------------

const GROUPS = Symbol.for("shepherd.mcp.liveGroups");
function liveGroups() {
  if (!globalThis[GROUPS]) {
    globalThis[GROUPS] = new Set();
    process.once("exit", killAllServers);
  }
  return globalThis[GROUPS];
}

function signalGroup(pid, signal) {
  try {
    process.kill(-pid, signal);
    return;
  } catch {}
  try {
    process.kill(pid, signal);
  } catch {}
}

/** SIGTERMs every live stdio server's process group, synchronously (pi exiting, session_shutdown). */
export function killAllServers() {
  const groups = globalThis[GROUPS];
  if (!groups) return;
  for (const pid of groups) signalGroup(pid, "SIGTERM");
  groups.clear();
}

class StdioTransport {
  constructor(spec, env, onMessage) {
    this.spec = spec;
    this.env = env;
    this.onMessage = onMessage;
    this.stderr = "";
    this.stopping = false;
  }

  start(onExit) {
    return new Promise((resolve, reject) => {
      let child;
      try {
        child = spawn(this.spec.command, this.spec.args, {
          detached: true,
          env: this.env,
          stdio: ["pipe", "pipe", "pipe"],
        });
      } catch (error) {
        reject(new MCPError(`couldn't start ${this.spec.command}: ${error?.message ?? error}`, { kind: "start" }));
        return;
      }
      this.child = child;
      let started = false;
      child.on("error", (error) => {
        const message = error?.code === "ENOENT"
          ? `${this.spec.command} isn't installed (not found on PATH)`
          : `couldn't start ${this.spec.command}: ${error?.message ?? error}`;
        if (!started) reject(new MCPError(message, { kind: "start" }));
        else onExit(new MCPError(message, { kind: "closed" }));
      });
      child.on("spawn", () => {
        started = true;
        if (child.pid) liveGroups().add(child.pid);
        resolve();
      });
      child.on("exit", () => {
        if (child.pid) liveGroups().delete(child.pid);
      });
      // "close" waits for stdio to drain, so the stderr tail is whole.
      child.on("close", (code, signal) => {
        clearTimeout(this.termTimer);
        clearTimeout(this.killTimer);
        const tail = this.stderr.trim().split("\n").slice(-6).join("\n");
        const how = signal ? `was stopped (${signal})` : `exited with code ${code}`;
        onExit(new MCPError(`${this.spec.command} ${how}${tail ? `: ${tail}` : ""}`, { kind: "closed" }));
      });
      let buffer = "";
      child.stdout.setEncoding("utf8");
      child.stdout.on("data", (chunk) => {
        buffer += chunk;
        let index;
        while ((index = buffer.indexOf("\n")) >= 0) {
          const line = buffer.slice(0, index).trim();
          buffer = buffer.slice(index + 1);
          if (!line) continue;
          let message;
          try {
            message = JSON.parse(line);
          } catch {
            continue; // Servers that log to stdout: not ours to parse.
          }
          this.onMessage(message);
        }
      });
      child.stderr.setEncoding("utf8");
      child.stderr.on("data", (chunk) => {
        this.stderr = (this.stderr + chunk).slice(-STDERR_TAIL);
      });
      child.stdin.on("error", () => {});
      child.stdout.on("error", () => {});
      child.stderr.on("error", () => {});
      child.unref();
      child.stdin.unref?.();
      child.stdout.unref?.();
      child.stderr.unref?.();
    });
  }

  send(message) {
    const child = this.child;
    if (!child || child.exitCode !== null || !child.stdin.writable) {
      throw new MCPError(`${this.spec.command} isn't running`, { kind: "closed" });
    }
    child.stdin.write(JSON.stringify(message) + "\n");
  }

  /** Close stdin, SIGTERM the group after 2 s and SIGKILL it after 5 s; `now` signals at once. */
  close(now = false) {
    const child = this.child;
    if (!child || child.exitCode !== null || child.signalCode !== null || this.stopping) return;
    this.stopping = true;
    try {
      child.stdin.end();
    } catch {}
    const pid = child.pid;
    if (!pid) return;
    if (now) {
      signalGroup(pid, "SIGTERM");
      liveGroups().delete(pid);
      return;
    }
    this.termTimer = setTimeout(() => signalGroup(pid, "SIGTERM"), 2_000);
    this.killTimer = setTimeout(() => {
      signalGroup(pid, "SIGKILL");
      liveGroups().delete(pid);
    }, 5_000);
    this.termTimer.unref?.();
    this.killTimer.unref?.();
  }
}

// ---- SSE --------------------------------------------------------------------------------------

/** Feeds text chunks, calls `onEvent({event, data, id})` per complete event. */
export function sseParser(onEvent) {
  let buffer = "";
  let event = "";
  let data = [];
  let id;
  return (chunk) => {
    buffer += chunk;
    let index;
    while ((index = buffer.search(/\r?\n/)) >= 0) {
      const line = buffer.slice(0, index);
      buffer = buffer.slice(index + (buffer[index] === "\r" ? 2 : 1));
      if (line === "") {
        if (data.length) onEvent({ event: event || "message", data: data.join("\n"), id });
        event = "";
        data = [];
        continue;
      }
      if (line.startsWith(":")) continue;
      const colon = line.indexOf(":");
      const field = colon < 0 ? line : line.slice(0, colon);
      let value = colon < 0 ? "" : line.slice(colon + 1);
      if (value.startsWith(" ")) value = value.slice(1);
      if (field === "event") event = value;
      else if (field === "data") data.push(value);
      else if (field === "id") id = value;
    }
  };
}

/** A long-lived GET event stream on node:http(s) with an unref'd socket. Resolves once headers arrive. */
function openEventStream(url, headers, timeoutMs) {
  return new Promise((resolve, reject) => {
    let target;
    try {
      target = new URL(url);
    } catch {
      reject(new MCPError(`${url} isn't a valid URL`, { kind: "start" }));
      return;
    }
    const client = target.protocol === "https:" ? https : http;
    const req = client.request(target, {
      method: "GET",
      headers: { Accept: "text/event-stream", "Cache-Control": "no-cache", ...headers },
    });
    const timer = setTimeout(() => {
      req.destroy();
      reject(new MCPError(`${target.host} didn't answer in ${Math.round(timeoutMs / 1000)} s`, { kind: "timeout" }));
    }, timeoutMs);
    timer.unref?.();
    req.on("socket", (socket) => socket.unref?.());
    req.on("error", (error) => {
      clearTimeout(timer);
      reject(new MCPError(`couldn't reach ${target.host}: ${error?.message ?? error}`, { kind: "start" }));
    });
    req.on("response", (res) => {
      clearTimeout(timer);
      resolve({ req, res });
    });
    req.end();
  });
}

function readBody(res, limit = 4096) {
  return new Promise((resolve) => {
    let text = "";
    res.setEncoding("utf8");
    res.on("data", (chunk) => {
      if (text.length < limit) text += chunk;
    });
    res.on("end", () => resolve(text.slice(0, limit)));
    res.on("error", () => resolve(text.slice(0, limit)));
  });
}

function httpFailure(status, challenge, what, body) {
  if (status === 401) return new MCPError(`${what} needs sign-in (401)`, { kind: "auth", status, challenge });
  if (status === 403) return new MCPError(`${what} refused access (403)`, { kind: "auth", status, challenge });
  const detail = (body ?? "").trim().split("\n")[0].slice(0, 200);
  return new MCPError(`${what} answered ${status}${detail ? `: ${detail}` : ""}`, { kind: "http", status });
}

// ---- Streamable HTTP ----------------------------------------------------------------------------

class StreamableHTTPTransport {
  constructor(url, headers, onMessage, hasPending) {
    this.url = url;
    this.headers = headers;
    this.onMessage = onMessage;
    this.hasPending = hasPending;
    this.sessionID = undefined;
    this.protocolVersion = undefined;
    this.host = (() => {
      try {
        return new URL(url).host;
      } catch {
        return url;
      }
    })();
  }

  requestHeaders() {
    const headers = { "Content-Type": "application/json", Accept: "application/json, text/event-stream", ...this.headers() };
    if (this.sessionID) headers["Mcp-Session-Id"] = this.sessionID;
    if (this.protocolVersion) headers["MCP-Protocol-Version"] = this.protocolVersion;
    return headers;
  }

  async send(message, signal, requestID) {
    let res;
    try {
      res = await fetch(this.url, { method: "POST", headers: this.requestHeaders(), body: JSON.stringify(message), signal });
    } catch (error) {
      if (signal?.aborted) throw new MCPError("the request was cancelled", { kind: "cancelled" });
      throw new MCPError(`couldn't reach ${this.host}: ${error?.cause?.message ?? error?.message ?? error}`, { kind: "start" });
    }
    const session = res.headers.get("mcp-session-id");
    if (session) this.sessionID = session;
    if (!res.ok) {
      const body = await res.text().catch(() => "");
      throw httpFailure(res.status, res.headers.get("www-authenticate") ?? undefined, this.host, body);
    }
    if (res.status === 202 || res.status === 204) {
      await res.body?.cancel?.().catch?.(() => {});
      return;
    }
    const type = (res.headers.get("content-type") ?? "").toLowerCase();
    if (type.includes("text/event-stream")) {
      await this.readStream(res, requestID);
      return;
    }
    const text = await res.text();
    if (!text.trim()) return;
    let parsed;
    try {
      parsed = JSON.parse(text);
    } catch {
      throw new MCPError(`${this.host} answered with something that isn't JSON`, { kind: "http", status: res.status });
    }
    this.onMessage(parsed);
  }

  async readStream(res, requestID) {
    const reader = res.body?.getReader?.();
    if (!reader) return;
    const decoder = new TextDecoder();
    const feed = sseParser(({ data }) => {
      try {
        this.onMessage(JSON.parse(data));
      } catch {}
    });
    try {
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        feed(decoder.decode(value, { stream: true }));
        if (requestID !== undefined && !this.hasPending(requestID)) break;
      }
    } catch {
      // The stream ended early (cancelled or dropped); a pending request times out or fails.
    } finally {
      reader.cancel().catch(() => {});
    }
  }

  /** The optional GET stream for the server's own notifications (tools/list_changed). */
  async listen(timeoutMs) {
    try {
      const { req, res } = await openEventStream(this.url, this.requestHeaders(), timeoutMs);
      if (res.statusCode !== 200 || !(res.headers["content-type"] ?? "").includes("text/event-stream")) {
        req.destroy();
        return;
      }
      this.stream = req;
      res.setEncoding("utf8");
      const feed = sseParser(({ data }) => {
        try {
          this.onMessage(JSON.parse(data));
        } catch {}
      });
      res.on("data", feed);
      res.on("error", () => {});
    } catch {}
  }

  close() {
    try {
      this.stream?.destroy();
    } catch {}
    if (!this.sessionID) return;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 2_000);
    timer.unref?.();
    fetch(this.url, { method: "DELETE", headers: this.requestHeaders(), signal: controller.signal })
      .then((res) => res.body?.cancel?.())
      .catch(() => {})
      .finally(() => clearTimeout(timer));
  }
}

// ---- legacy HTTP+SSE ----------------------------------------------------------------------------

class LegacySSETransport {
  constructor(url, headers, onMessage) {
    this.url = url;
    this.headers = headers;
    this.onMessage = onMessage;
    this.host = (() => {
      try {
        return new URL(url).host;
      } catch {
        return url;
      }
    })();
  }

  async start(timeoutMs, onClose) {
    const { req, res } = await openEventStream(this.url, this.headers(), timeoutMs);
    this.stream = req;
    if (res.statusCode !== 200) {
      const body = await readBody(res);
      req.destroy();
      throw httpFailure(res.statusCode ?? 0, res.headers["www-authenticate"], this.host, body);
    }
    res.setEncoding("utf8");
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        req.destroy();
        reject(new MCPError(`${this.host} never sent its message endpoint`, { kind: "timeout" }));
      }, timeoutMs);
      timer.unref?.();
      const feed = sseParser(({ event, data }) => {
        if (event === "endpoint") {
          try {
            this.endpoint = new URL(data.trim(), this.url).href;
          } catch {
            return;
          }
          clearTimeout(timer);
          resolve();
          return;
        }
        try {
          this.onMessage(JSON.parse(data));
        } catch {}
      });
      res.on("data", feed);
      res.on("error", () => {});
      res.on("close", () => {
        clearTimeout(timer);
        if (!this.endpoint) reject(new MCPError(`${this.host} closed the event stream`, { kind: "closed" }));
        else if (!this.closing) onClose(new MCPError(`${this.host} closed the event stream`, { kind: "closed" }));
      });
    });
  }

  async send(message, signal) {
    if (!this.endpoint) throw new MCPError(`${this.host} isn't connected`, { kind: "closed" });
    let res;
    try {
      res = await fetch(this.endpoint, {
        method: "POST",
        headers: { "Content-Type": "application/json", ...this.headers() },
        body: JSON.stringify(message),
        signal,
      });
    } catch (error) {
      if (signal?.aborted) throw new MCPError("the request was cancelled", { kind: "cancelled" });
      throw new MCPError(`couldn't reach ${this.host}: ${error?.cause?.message ?? error?.message ?? error}`, { kind: "start" });
    }
    const body = await res.text().catch(() => "");
    if (!res.ok) throw httpFailure(res.status, res.headers.get("www-authenticate") ?? undefined, this.host, body);
  }

  close() {
    this.closing = true;
    try {
      this.stream?.destroy();
    } catch {}
  }
}

// ---- client -----------------------------------------------------------------------------------

/**
 * One connection to one server. `spec` comes from `resolveEntry`; `headers()` is read before
 * every HTTP request, so refreshed credentials apply without reconnecting.
 */
export class MCPClient {
  constructor({ name, spec, env = process.env, headers, timeoutMs = 30_000, onNotification, onClose }) {
    this.name = name;
    this.spec = spec;
    this.env = env;
    this.headers = headers ?? (() => spec.headers ?? {});
    this.timeoutMs = timeoutMs;
    this.onNotification = onNotification;
    this.onClose = onClose;
    this.transportKind = undefined;
    this.serverName = undefined;
    this.ready = false;
    this.closed = false;
  }

  makeRPC(send) {
    const rpc = new RPC(send, {
      onNotification: (method, params) => this.onNotification?.(method, params),
      onClose: (error) => {
        this.ready = false;
        if (!this.closed) {
          this.closed = true;
          this.onClose?.(error);
        }
      },
    });
    this.rpc = rpc;
    return rpc;
  }

  async connect() {
    const kind = this.spec.kind;
    if (kind === "stdio") return this.connectStdio();
    if (kind === "sse") return this.connectSSE();
    if (kind === "http") {
      try {
        return await this.connectStreamable();
      } catch (error) {
        // A server that predates Streamable HTTP refuses the POST: try the legacy SSE transport.
        if (error instanceof MCPError && error.kind === "http" && [400, 404, 405].includes(error.status)) {
          this.rpc?.fail(new MCPError("falling back to SSE", { kind: "closed" }), true);
          return this.connectSSE();
        }
        throw error;
      }
    }
    throw new MCPError("the entry has neither a command nor a url", { kind: "start" });
  }

  async connectStdio() {
    const env = {};
    for (const [key, value] of Object.entries(this.env)) {
      if (typeof value === "string" && !key.startsWith("SHEPHERD_")) env[key] = value;
    }
    Object.assign(env, this.spec.env);
    const transport = new StdioTransport(this.spec, env, (message) => this.rpc.receive(message));
    this.transport = transport;
    const rpc = this.makeRPC((message) => transport.send(message));
    await transport.start((error) => rpc.fail(error));
    this.transportKind = "stdio";
    await this.initialize();
  }

  async connectStreamable() {
    let transport;
    const rpc = this.makeRPC((message, signal, id) => transport.send(message, signal, id));
    transport = new StreamableHTTPTransport(this.spec.url, this.headers, (message) => rpc.receive(message), (id) => rpc.hasPending(id));
    this.transport = transport;
    this.transportKind = "streamableHTTP";
    const result = await this.initialize();
    transport.protocolVersion = typeof result?.protocolVersion === "string" ? result.protocolVersion : PROTOCOL_VERSION;
    transport.listen(this.timeoutMs);
  }

  async connectSSE() {
    let transport;
    const rpc = this.makeRPC((message, signal) => transport.send(message, signal));
    transport = new LegacySSETransport(this.spec.url, this.headers, (message) => rpc.receive(message));
    this.transport = transport;
    this.transportKind = "sse";
    await transport.start(this.timeoutMs, (error) => rpc.fail(error));
    await this.initialize();
  }

  async initialize() {
    const result = await this.rpc.request(
      "initialize",
      { protocolVersion: PROTOCOL_VERSION, capabilities: {}, clientInfo: CLIENT_INFO },
      { timeoutMs: this.timeoutMs },
    );
    const info = result?.serverInfo ?? {};
    this.serverName = typeof info.title === "string" && info.title ? info.title : typeof info.name === "string" ? info.name : undefined;
    this.capabilities = result?.capabilities ?? {};
    this.instructions = typeof result?.instructions === "string" ? result.instructions : undefined;
    this.rpc.notify("notifications/initialized");
    this.ready = true;
    return result;
  }

  async listTools() {
    const tools = [];
    let cursor;
    for (let page = 0; page < MAX_TOOL_PAGES; page++) {
      const result = await this.rpc.request("tools/list", cursor ? { cursor } : {}, { timeoutMs: this.timeoutMs });
      for (const tool of Array.isArray(result?.tools) ? result.tools : []) {
        if (!tool || typeof tool.name !== "string") continue;
        tools.push({
          name: tool.name,
          ...(typeof tool.title === "string" ? { title: tool.title } : typeof tool.annotations?.title === "string" ? { title: tool.annotations.title } : {}),
          description: typeof tool.description === "string" ? tool.description : "",
          inputSchema: tool.inputSchema && typeof tool.inputSchema === "object" ? tool.inputSchema : { type: "object" },
        });
      }
      cursor = typeof result?.nextCursor === "string" && result.nextCursor ? result.nextCursor : undefined;
      if (!cursor) break;
    }
    return tools;
  }

  callTool(name, args, { signal, timeoutMs } = {}) {
    return this.rpc.request("tools/call", { name, arguments: args ?? {} }, { signal, timeoutMs: timeoutMs ?? this.timeoutMs });
  }

  ping() {
    return this.rpc.request("ping", undefined, { timeoutMs: this.timeoutMs });
  }

  close(now = false) {
    if (this.closed) {
      this.transport?.close?.(now);
      return;
    }
    this.closed = true;
    this.ready = false;
    try {
      this.rpc?.fail(new MCPError("the connection was closed", { kind: "closed" }));
    } catch {}
    try {
      this.transport?.close?.(now);
    } catch {}
  }
}

// ---- probe (the app's Settings page) ------------------------------------------------------------

/** A failed connection as a status: `{state, scopes, message}` and the challenge, if any. */
export function failureStatus(error) {
  const message = String(error?.message ?? error);
  if (error instanceof MCPError && error.kind === "auth") {
    if (error.status === 403 && isInsufficientScope(error.challenge)) {
      return { status: { state: "needsScopes", scopes: challengeScopes(error.challenge), message }, challenge: error.challenge };
    }
    return { status: { state: "needsSignIn", scopes: [], message }, challenge: error.challenge };
  }
  return { status: { state: "error", scopes: [], message } };
}

async function readStdin() {
  let text = "";
  process.stdin.setEncoding("utf8");
  for await (const chunk of process.stdin) text += chunk;
  return text;
}

/** stdin: `{name?, entry, timeoutSeconds?}`; stdout: one JSON line. */
export async function probe(input) {
  const timeoutMs = Math.max(1, Number(input?.timeoutSeconds) || 30) * 1000;
  const name = typeof input?.name === "string" ? input.name : "server";
  const spec = resolveEntry(name, input?.entry ?? {}, process.env, input?.credentials);
  if (!spec.kind) return { ok: false, status: { state: "error", scopes: [], message: "the entry has neither a command nor a url" } };
  const client = new MCPClient({ name, spec, timeoutMs });
  try {
    await client.connect();
    const tools = await client.listTools();
    return { ok: true, transport: client.transportKind, serverName: client.serverName ?? null, tools };
  } catch (error) {
    return { ok: false, ...failureStatus(error) };
  } finally {
    client.close(true);
  }
}

async function main() {
  // The app kills the whole probe at timeoutSeconds + 5; this ref'd timer also keeps node alive
  // while every socket is unref'd.
  const keepAlive = setTimeout(() => process.exit(3), 10 * 60_000);
  let output;
  try {
    output = await probe(JSON.parse(await readStdin()));
  } catch (error) {
    output = { ok: false, status: { state: "error", scopes: [], message: `probe failed: ${error?.message ?? error}` } };
  }
  process.stdout.write(JSON.stringify(output) + "\n", () => {
    clearTimeout(keepAlive);
    killAllServers();
    process.exit(0);
  });
}

try {
  if (process.argv[2] === "probe" && process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main();
} catch {}
