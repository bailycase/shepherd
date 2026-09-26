// @ts-nocheck -- loaded by pi/jiti; this project intentionally has no Node TS workspace.
// Shepherd MCP extension: lets an agent use the MCP servers in Settings ▸ MCP servers
// (~/.config/mcp/mcp.json, the path the app passes in SHEPHERD_EXT_MCP_CONFIG). One `mcp` tool
// searches, describes and calls any server's tools; a server set to "Each tool on its own" also
// gets a direct tool per MCP tool (<server>_<tool>), built from the tools cache the app writes.
//
// Connections live in this pi: a server starts when first used (or with the session), stops
// after it idles, and every stdio server's process group dies with pi. Secrets and OAuth tokens
// never sit in the config file: the app hands them over on the Shepherd socket when a server
// needs them (mcpCredentials), and hears every state change (mcpReport) for its Settings page.
//
// Inert without SHEPHERD_EXT_MCP, SHEPHERD_AGENT_ID and SHEPHERD_SOCKET. Nothing throws into pi
// outside a tool's own failure, and every socket and timer is unref'd.
import * as crypto from "node:crypto";
import * as fs from "node:fs";
import * as net from "node:net";
import * as path from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { StringEnum } from "@earendil-works/pi-ai";
import { Type } from "typebox";
import {
  MCPClient,
  MCPError,
  challengeScopes,
  failureStatus,
  keychainReferences,
  killAllServers,
  resolveEntry,
  transportKind,
} from "./shepherd-mcp-client.mjs";

const REQUEST_TIMEOUT_MS = 30_000;
const TEXT_LIMIT = 50_000;
const DESCRIPTION_LIMIT = 1_000;
const REPORT_LIMIT = 900_000;
const SEARCH_LIMIT = 20;
const NAME_LIMIT = 64;
const RECONNECT_MAX_MS = 30_000;
const REFRESH_MARGIN_MS = 60_000;
const PROXY_NAME = Symbol.for("shepherd.mcp.proxyName");

type Start = "whenUsed" | "withSession" | "alwaysOn";
type Exposure = "proxy" | "direct";
type State = "starting" | "connected" | "idle" | "needsSignIn" | "expired" | "needsScopes" | "error" | "off";

interface Settings {
  enabled: boolean;
  start: Start;
  idleMinutes: number;
  exposure: Exposure;
  tools?: string[];
  timeoutSeconds: number;
}

interface Tool {
  name: string;
  title?: string;
  description: string;
  inputSchema: Record<string, unknown>;
}

interface Server {
  name: string;
  entry: Record<string, unknown>;
  bare: Record<string, unknown>;
  settings: Settings;
  project: boolean;
  client?: MCPClient;
  connecting?: Promise<MCPClient>;
  tools?: Tool[];
  state: State;
  message?: string;
  scopes: string[];
  credentials?: { bearer?: string; headers?: Record<string, string>; env?: Record<string, string>; expiresAtMs?: number };
  usesOAuth: boolean;
  challenge?: string;
  idleTimer?: ReturnType<typeof setTimeout>;
  reconnectTimer?: ReturnType<typeof setTimeout>;
  reconnectDelay: number;
  skipped: number;
  removed: boolean;
}

/** A failure the app answered, carried to the agent as its message. */
class AppError extends Error {
  code: string;
  constructor(code: string, message: string) {
    super(message);
    this.code = code;
  }
}

// ---- config -----------------------------------------------------------------------------------

function isObject(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

/** Shepherd's own fields under `entry.shepherd`, each with its default. */
export function parseSettings(entry: Record<string, unknown>): Settings {
  const raw = isObject(entry.shepherd) ? entry.shepherd : {};
  const start: Start = raw.start === "withSession" || raw.start === "alwaysOn" ? raw.start : "whenUsed";
  const idle = Number(raw.idleMinutes);
  const timeout = Number(raw.timeoutSeconds);
  return {
    enabled: raw.enabled !== false,
    start,
    idleMinutes: Number.isFinite(idle) && idle > 0 ? idle : 10,
    exposure: raw.exposure === "direct" ? "direct" : "proxy",
    tools: Array.isArray(raw.tools) ? raw.tools.filter((tool) => typeof tool === "string") : undefined,
    timeoutSeconds: Number.isFinite(timeout) && timeout > 0 ? timeout : 30,
  };
}

function withoutShepherd(entry: Record<string, unknown>): Record<string, unknown> {
  const { shepherd: _shepherd, ...rest } = entry;
  return rest;
}

/** `{name: entry}` from `mcpServers` (or VS Code's `servers`); anything unreadable is no servers. */
export function readServers(file: string): Record<string, Record<string, unknown>> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return {};
  }
  if (!isObject(parsed)) return {};
  const block = isObject(parsed.mcpServers) ? parsed.mcpServers : isObject(parsed.servers) ? parsed.servers : {};
  const out: Record<string, Record<string, unknown>> = {};
  for (const [name, entry] of Object.entries(block)) {
    if (isObject(entry) && transportKind(entry)) out[name] = entry;
  }
  return out;
}

/** The repo's `.mcp.json`: at `cwd`, or at the nearest ancestor holding `.git`, where the search stops. */
export function projectConfigPath(cwd: string): string | undefined {
  let dir = path.resolve(cwd);
  for (;;) {
    const candidate = path.join(dir, ".mcp.json");
    if (fs.existsSync(candidate)) return candidate;
    if (fs.existsSync(path.join(dir, ".git"))) return undefined;
    const parent = path.dirname(dir);
    if (parent === dir) return undefined;
    dir = parent;
  }
}

function deepEqual(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (Array.isArray(a) || Array.isArray(b)) {
    return Array.isArray(a) && Array.isArray(b) && a.length === b.length && a.every((item, index) => deepEqual(item, b[index]));
  }
  if (!isObject(a) || !isObject(b)) return false;
  const keys = Object.keys(a);
  return keys.length === Object.keys(b).length && keys.every((key) => key in b && deepEqual(a[key], b[key]));
}

function mtime(file: string | undefined): number {
  if (!file) return 0;
  try {
    return fs.statSync(file).mtimeMs;
  } catch {
    return 0;
  }
}

// ---- tool names -------------------------------------------------------------------------------

/** `<server>_<tool>`: lowercase, `[^a-z0-9_]` as `_`, and past 64 characters a hashed tail. */
export function directToolName(server: string, tool: string): string {
  const prefix = server.toLowerCase().replace(/[^a-z0-9_]/g, "_");
  const full = `${prefix}_${tool.replace(/[^A-Za-z0-9_-]/g, "_")}`;
  if (full.length <= NAME_LIMIT) return full;
  const hash = crypto.createHash("sha1").update(full).digest("hex").slice(0, 8);
  return `${full.slice(0, 55)}_${hash}`;
}

function directSchema(schema: unknown): Record<string, unknown> {
  if (!isObject(schema) || (schema.type !== undefined && schema.type !== "object")) {
    return { type: "object", additionalProperties: true };
  }
  const { $schema: _schema, ...rest } = schema;
  return { type: "object", ...rest };
}

function firstSentence(text: string): string {
  const line = text.trim().split(/\n/)[0] ?? "";
  const match = /^(.+?[.!?])(\s|$)/.exec(line);
  const sentence = match ? match[1] : line;
  return sentence.length > 160 ? `${sentence.slice(0, 157)}…` : sentence;
}

// ---- results ----------------------------------------------------------------------------------

/** MCP content as pi content: text and images carry over, resources become their text. */
export function toolContent(result: Record<string, unknown>) {
  const content: Array<{ type: "text"; text: string } | { type: "image"; data: string; mimeType: string }> = [];
  for (const item of Array.isArray(result?.content) ? result.content : []) {
    if (!isObject(item)) continue;
    if (item.type === "text" && typeof item.text === "string") content.push({ type: "text", text: item.text });
    else if (item.type === "image" && typeof item.data === "string") {
      content.push({ type: "image", data: item.data, mimeType: typeof item.mimeType === "string" ? item.mimeType : "image/png" });
    } else if (item.type === "resource" && isObject(item.resource)) {
      const resource = item.resource;
      if (typeof resource.text === "string") content.push({ type: "text", text: resource.text });
      else content.push({ type: "text", text: `[resource ${resource.uri ?? ""}${resource.mimeType ? ` (${resource.mimeType})` : ""}: binary, not shown]` });
    } else if (item.type === "resource_link") {
      content.push({ type: "text", text: `${item.name ?? "resource"}: ${item.uri ?? ""}` });
    } else if (item.type === "audio") {
      content.push({ type: "text", text: `[audio${item.mimeType ? ` (${item.mimeType})` : ""}: not shown]` });
    }
  }
  if (!content.some((item) => item.type === "text") && result?.structuredContent !== undefined) {
    content.push({ type: "text", text: JSON.stringify(result.structuredContent, null, 2) });
  }
  let budget = TEXT_LIMIT;
  let clipped = false;
  for (const item of content) {
    if (item.type !== "text") continue;
    if (item.text.length > budget) {
      item.text = item.text.slice(0, budget);
      clipped = true;
    }
    budget = Math.max(0, budget - item.text.length);
  }
  if (clipped) content.push({ type: "text", text: `[clipped at ${TEXT_LIMIT / 1000} KB: ask the tool for less]` });
  if (!content.length) content.push({ type: "text", text: "(no output)" });
  return content;
}

// ---- the Shepherd socket ------------------------------------------------------------------------

/** One persistent connection: fire-and-forget reports and id-correlated credential requests. */
class AppLink {
  socketPath: string;
  socket?: net.Socket;
  connected = false;
  queue: string[] = [];
  pending = new Map<number, (reply: Record<string, unknown>) => void>();
  nextID = 0;
  buffer = "";

  constructor(socketPath: string) {
    this.socketPath = socketPath;
  }

  ensure() {
    if (this.socket) return;
    try {
      const socket = net.createConnection(this.socketPath);
      this.socket = socket;
      socket.setEncoding("utf8");
      socket.on("connect", () => {
        this.connected = true;
        for (const line of this.queue.splice(0)) socket.write(line);
      });
      socket.on("data", (chunk: string) => {
        this.buffer += chunk;
        let index;
        while ((index = this.buffer.indexOf("\n")) >= 0) {
          const line = this.buffer.slice(0, index);
          this.buffer = this.buffer.slice(index + 1);
          let reply: Record<string, unknown>;
          try {
            reply = JSON.parse(line);
          } catch {
            continue;
          }
          const resolve = typeof reply.id === "number" ? this.pending.get(reply.id) : undefined;
          if (resolve) {
            this.pending.delete(reply.id as number);
            resolve(reply);
          }
        }
      });
      socket.on("error", () => {});
      socket.on("close", () => {
        this.connected = false;
        this.socket = undefined;
        this.buffer = "";
        this.queue = [];
        for (const resolve of [...this.pending.values()]) {
          resolve({ type: "error", code: "mcp_unavailable", message: "Shepherd isn't reachable" });
        }
        this.pending.clear();
      });
      socket.unref();
    } catch {
      this.socket = undefined;
    }
  }

  send(message: Record<string, unknown>) {
    try {
      this.ensure();
      const line = JSON.stringify(message) + "\n";
      if (this.connected && this.socket) this.socket.write(line);
      else if (this.queue.length < 200) this.queue.push(line);
    } catch {}
  }

  request(message: Record<string, unknown>, timeoutMs = REQUEST_TIMEOUT_MS): Promise<Record<string, unknown>> {
    return new Promise((resolve) => {
      const id = ++this.nextID;
      const timer = setTimeout(() => {
        if (!this.pending.delete(id)) return;
        resolve({ type: "error", code: "mcp_unavailable", message: "Shepherd didn't answer in time" });
      }, timeoutMs);
      timer.unref?.();
      this.pending.set(id, (reply) => {
        clearTimeout(timer);
        resolve(reply);
      });
      this.send({ ...message, id });
      if (!this.socket) {
        this.pending.delete(id);
        clearTimeout(timer);
        resolve({ type: "error", code: "mcp_unavailable", message: "Shepherd isn't reachable" });
      }
    });
  }

  close() {
    try {
      this.socket?.end();
    } catch {}
  }
}

// ---- the extension ------------------------------------------------------------------------------

export default function shepherdMCP(pi: ExtensionAPI) {
  const env = process.env;
  const extensionPath = env.SHEPHERD_EXT_MCP ?? "";
  const agentID = env.SHEPHERD_AGENT_ID ?? "";
  const socketPath = env.SHEPHERD_SOCKET ?? "";
  if (!extensionPath || !agentID || !socketPath) return;

  const configPath = env.SHEPHERD_EXT_MCP_CONFIG ?? "";
  const cachePath = env.SHEPHERD_EXT_MCP_CACHE ?? "";
  const useProject = env.SHEPHERD_EXT_MCP_PROJECT === "1";
  const link = new AppLink(socketPath);

  const servers = new Map<string, Server>();
  let cwd = process.cwd();
  let projectPath: string | undefined;
  let configStamp = "";
  let cache: Record<string, unknown> = {};
  let cacheStamp = -1;

  // The proxy's name is decided once per process, at the first session_start, when every
  // extension has loaded; /new, /resume and /reload build a new instance that keeps it.
  let proxyName: string | undefined;
  let decided = false;
  let started = false;
  const ours = new Set<string>();
  const direct = new Map<string, { server: string; tool: string }>();
  const failures = new Map<string, Record<string, unknown>>();

  // ---- reports

  function report(server: Server, tools = false) {
    if (server.project) return;
    const status: Record<string, unknown> = { state: server.state };
    if (server.state === "needsScopes" && server.scopes.length) status.scopes = server.scopes;
    const messages = [server.message, server.skipped ? `skipped ${server.skipped} tools whose names are taken` : undefined].filter(Boolean);
    if (messages.length) status.message = messages.join("; ");
    const body: Record<string, unknown> = { server: server.name, status };
    if (server.client?.transportKind) body.transport = server.client.transportKind;
    if (server.client?.serverName) body.serverName = server.client.serverName;
    if (tools && server.tools) {
      body.tools = server.tools.map((tool) => ({
        name: tool.name,
        ...(tool.title ? { title: tool.title } : {}),
        description: tool.description.slice(0, DESCRIPTION_LIMIT),
        inputSchema: tool.inputSchema,
      }));
      if (JSON.stringify(body).length > REPORT_LIMIT) {
        body.tools = (body.tools as Tool[]).map((tool) => ({ ...tool, inputSchema: {} }));
      }
    }
    link.send({ type: "mcpReport", agentID, report: body });
  }

  function setState(server: Server, state: State, message?: string, scopes: string[] = []) {
    const changed = server.state !== state || server.message !== message || scopes.join(" ") !== server.scopes.join(" ");
    server.state = state;
    server.message = message;
    server.scopes = scopes;
    if (changed) report(server);
  }

  // ---- config and cache

  function readCache() {
    const stamp = mtime(cachePath);
    if (stamp === cacheStamp) return;
    cacheStamp = stamp;
    try {
      const parsed = JSON.parse(fs.readFileSync(cachePath, "utf8"));
      cache = isObject(parsed) ? parsed : {};
    } catch {
      cache = {};
    }
  }

  function cachedTools(server: Server): Tool[] | undefined {
    readCache();
    const hit = cache[server.name];
    if (!isObject(hit) || !deepEqual(hit.entry, server.bare) || !Array.isArray(hit.tools)) return undefined;
    return hit.tools.filter((tool) => isObject(tool) && typeof tool.name === "string") as Tool[];
  }

  function visibleTools(server: Server, tools: Tool[] | undefined): Tool[] | undefined {
    if (!tools || !server.settings.tools) return tools;
    const allowed = new Set(server.settings.tools);
    return tools.filter((tool) => allowed.has(tool.name));
  }

  function knownTools(server: Server): Tool[] | undefined {
    return visibleTools(server, server.tools ?? cachedTools(server));
  }

  function stopServer(server: Server, state: State = "idle") {
    clearTimeout(server.idleTimer);
    clearTimeout(server.reconnectTimer);
    server.idleTimer = undefined;
    server.reconnectTimer = undefined;
    const client = server.client;
    server.client = undefined;
    server.connecting = undefined;
    try {
      client?.close();
    } catch {}
    if (client) setState(server, state);
  }

  /** Loads the config (and the repo's, when allowed); true when anything changed. */
  function loadConfig(): boolean {
    const nextProject = useProject ? projectConfigPath(cwd) : undefined;
    const stamp = `${mtime(configPath)}|${nextProject ?? ""}|${mtime(nextProject)}`;
    if (stamp === configStamp) return false;
    configStamp = stamp;
    projectPath = nextProject;
    const next = new Map<string, { entry: Record<string, unknown>; project: boolean }>();
    if (projectPath) for (const [name, entry] of Object.entries(readServers(projectPath))) next.set(name, { entry, project: true });
    if (configPath) for (const [name, entry] of Object.entries(readServers(configPath))) next.set(name, { entry, project: false });
    for (const [name, server] of servers) {
      const incoming = next.get(name);
      if (incoming && deepEqual(incoming.entry, server.entry) && incoming.project === server.project) continue;
      server.removed = true;
      stopServer(server);
      servers.delete(name);
    }
    for (const [name, { entry, project }] of next) {
      if (servers.has(name)) continue;
      const settings = parseSettings(entry);
      if (!settings.enabled) continue;
      servers.set(name, {
        name,
        entry,
        bare: withoutShepherd(entry),
        settings,
        project,
        state: "idle",
        scopes: [],
        usesOAuth: false,
        reconnectDelay: 1_000,
        skipped: 0,
        removed: false,
      });
    }
    return true;
  }

  // ---- credentials

  function stateForCode(code: string): State {
    if (code === "needs_sign_in") return "needsSignIn";
    if (code === "expired") return "expired";
    if (code === "needs_scopes") return "needsScopes";
    return "error";
  }

  async function askCredentials(server: Server, reason: "connect" | "unauthorized" | "forbidden", challenge?: string) {
    if (server.project) {
      throw new AppError("needs_sign_in", `${server.name} (from the repo's .mcp.json) needs sign-in, which a repo's servers can't use: add it in Settings ▸ MCP servers instead.`);
    }
    const reply = await link.request({ type: "mcpCredentials", agentID, server: server.name, reason, ...(challenge ? { challenge } : {}) });
    if (reply.type === "mcpCredentials" && isObject(reply.credentials)) {
      const credentials = reply.credentials as Server["credentials"];
      server.credentials = credentials;
      if (credentials?.bearer) server.usesOAuth = true;
      return;
    }
    const code = typeof reply.code === "string" ? reply.code : "mcp_unavailable";
    const message = typeof reply.message === "string" && reply.message
      ? reply.message
      : `Shepherd couldn't hand over ${server.name}'s sign-in.`;
    throw new AppError(code, message);
  }

  function needsCredentialsAtConnect(server: Server): boolean {
    if (server.project) return false;
    return server.usesOAuth || keychainReferences(server.entry).length > 0;
  }

  function credentialsExpiring(server: Server): boolean {
    const expires = server.credentials?.expiresAtMs;
    return typeof expires === "number" && Date.now() > expires - REFRESH_MARGIN_MS;
  }

  function headersFor(server: Server) {
    return () => resolveEntry(server.name, server.entry, env, server.credentials).headers ?? {};
  }

  // ---- connections

  function failureMessage(server: Server, error: unknown): { state: State; message: string; scopes: string[] } {
    if (error instanceof AppError) {
      const scopes = error.code === "needs_scopes" ? challengeScopes(server.challenge ?? "") : [];
      return { state: stateForCode(error.code), message: error.message, scopes };
    }
    const { status } = failureStatus(error);
    if (status.state === "needsSignIn") {
      return { state: "needsSignIn", message: `${server.name} needs you to sign in: Settings ▸ MCP servers.`, scopes: [] };
    }
    if (status.state === "needsScopes") {
      return {
        state: "needsScopes",
        message: `${server.name} needs more access (${status.scopes.join(", ")}): sign in again in Settings ▸ MCP servers.`,
        scopes: status.scopes,
      };
    }
    return { state: "error", message: `${server.name}: ${status.message}`, scopes: [] };
  }

  function armIdle(server: Server) {
    clearTimeout(server.idleTimer);
    server.idleTimer = undefined;
    if (server.settings.start !== "whenUsed" || !server.client) return;
    server.idleTimer = setTimeout(() => {
      server.idleTimer = undefined;
      stopServer(server, "idle");
    }, server.settings.idleMinutes * 60_000);
    server.idleTimer.unref?.();
  }

  function scheduleReconnect(server: Server) {
    if (server.settings.start !== "alwaysOn" || server.removed || server.reconnectTimer) return;
    server.reconnectTimer = setTimeout(() => {
      server.reconnectTimer = undefined;
      connect(server).catch(() => {});
    }, server.reconnectDelay);
    server.reconnectTimer.unref?.();
    server.reconnectDelay = Math.min(server.reconnectDelay * 2, RECONNECT_MAX_MS);
  }

  async function openClient(server: Server): Promise<MCPClient> {
    if (needsCredentialsAtConnect(server) && (!server.credentials || credentialsExpiring(server))) {
      await askCredentials(server, "connect");
    }
    let lastChallenge: string | undefined;
    for (let attempt = 0; ; attempt++) {
      const spec = resolveEntry(server.name, server.entry, env, server.credentials);
      if (spec.missingSecrets.length) {
        if (attempt === 0 && !server.project) {
          await askCredentials(server, "connect");
          continue;
        }
        throw new AppError("missing_secret", `${server.name}'s ${spec.missingSecrets[0]} isn't set: add it in Settings ▸ MCP servers.`);
      }
      const client = new MCPClient({
        name: server.name,
        spec,
        env,
        headers: headersFor(server),
        timeoutMs: server.settings.timeoutSeconds * 1000,
        onNotification: (method: string) => {
          if (method === "notifications/tools/list_changed" && server.client === client) refreshTools(server).catch(() => {});
        },
        onClose: (error: unknown) => {
          if (server.client !== client) return;
          server.client = undefined;
          clearTimeout(server.idleTimer);
          setState(server, "error", `${server.name}: ${String((error as Error)?.message ?? error)}`);
          scheduleReconnect(server);
        },
      });
      try {
        await client.connect();
        return client;
      } catch (error) {
        client.close(true);
        const auth = error instanceof MCPError && error.kind === "auth";
        if (auth && attempt === 0 && error.challenge !== lastChallenge) {
          lastChallenge = error.challenge;
          const forbidden = error.status === 403;
          server.challenge = error.challenge;
          await askCredentials(server, forbidden ? "forbidden" : "unauthorized", error.challenge);
          continue;
        }
        throw error;
      }
    }
  }

  function connect(server: Server): Promise<MCPClient> {
    if (server.client?.ready) return Promise.resolve(server.client);
    if (server.connecting) return server.connecting;
    const attempt = (async () => {
      setState(server, "starting");
      try {
        const client = await openClient(server);
        if (server.removed || server.connecting !== attempt) {
          client.close();
          throw new MCPError(`${server.name} was removed or changed`, { kind: "closed" });
        }
        server.client = client;
        server.reconnectDelay = 1_000;
        server.tools = await client.listTools();
        server.connecting = undefined;
        server.state = "connected";
        server.message = undefined;
        server.scopes = [];
        report(server, true);
        syncTools();
        armIdle(server);
        return client;
      } catch (error) {
        if (server.connecting === attempt) {
          server.connecting = undefined;
          if (server.client) {
            server.client.close();
            server.client = undefined;
          }
          const failure = failureMessage(server, error);
          setState(server, failure.state, failure.message, failure.scopes);
          scheduleReconnect(server);
        }
        throw error;
      }
    })();
    server.connecting = attempt;
    return attempt;
  }

  async function refreshTools(server: Server) {
    const client = server.client;
    if (!client) return;
    try {
      server.tools = await client.listTools();
      report(server, true);
      syncTools();
    } catch {}
  }

  /** Runs one MCP request, refreshing credentials before it when they expire and once on a 401 or 403. */
  async function withServer<T>(server: Server, body: (client: MCPClient) => Promise<T>): Promise<T> {
    let client = await connect(server);
    if (server.usesOAuth && credentialsExpiring(server)) await askCredentials(server, "connect");
    clearTimeout(server.idleTimer);
    try {
      for (let attempt = 0; ; attempt++) {
        try {
          return await body(client);
        } catch (error) {
          if (!(error instanceof MCPError) || error.kind !== "auth" || attempt > 0) throw error;
          const forbidden = error.status === 403;
          server.challenge = error.challenge;
          await askCredentials(server, forbidden ? "forbidden" : "unauthorized", error.challenge);
          if (client.spec.kind === "stdio") {
            stopServer(server);
            client = await connect(server);
          }
        }
      }
    } catch (error) {
      if (error instanceof AppError || (error instanceof MCPError && error.kind === "auth")) {
        const failure = failureMessage(server, error);
        setState(server, failure.state, failure.message, failure.scopes);
      }
      throw error;
    } finally {
      armIdle(server);
    }
  }

  // ---- tools

  function proxyServers(): Server[] {
    return [...servers.values()].filter((server) => server.settings.exposure === "proxy");
  }

  function takenByOthers(): Set<string> {
    const taken = new Set<string>();
    try {
      for (const tool of pi.getAllTools()) {
        if (ours.has(tool.name)) continue;
        if (tool.sourceInfo?.path && samePath(tool.sourceInfo.path, extensionPath)) continue;
        taken.add(tool.name);
      }
    } catch {}
    return taken;
  }

  function samePath(a: string, b: string): boolean {
    try {
      return fs.realpathSync(a) === fs.realpathSync(b);
    } catch {
      return a === b;
    }
  }

  function describeProxy(): string {
    const names = proxyServers().map((server) => server.name).join(", ");
    return (
      `Use the user's MCP servers (${names}). action "search" finds tools by keyword (empty query lists servers), ` +
      `"describe" shows a tool's parameters, "call" runs it with arguments.`
    );
  }

  function registerProxy() {
    if (!proxyName) return;
    pi.registerTool({
      name: proxyName,
      label: "MCP",
      description: describeProxy(),
      promptSnippet: "Search, describe and call tools on the user's MCP servers",
      parameters: Type.Object({
        action: StringEnum(["search", "describe", "call"]),
        query: Type.Optional(Type.String({ description: "search: words to find in tool names and descriptions" })),
        server: Type.Optional(Type.String({ description: "describe, call: the server's name" })),
        tool: Type.Optional(Type.String({ description: "describe, call: the tool's name on that server" })),
        arguments: Type.Optional(Type.Record(Type.String(), Type.Unknown(), { description: "call: the tool's arguments" })),
      }),
      execute: (toolCallId, params, signal) => runProxy(toolCallId, params, signal),
    });
    ours.add(proxyName);
  }

  function registerDirect(name: string, server: Server, tool: Tool) {
    pi.registerTool({
      name,
      label: `${server.name} ${tool.title ?? tool.name}`,
      description: (tool.description || `${tool.name} on the ${server.name} MCP server.`).slice(0, DESCRIPTION_LIMIT),
      parameters: directSchema(tool.inputSchema),
      execute: (toolCallId, params, signal) => runCall(toolCallId, server.name, tool.name, params ?? {}, signal),
    });
    ours.add(name);
  }

  let proxyRegistered = "";
  const directRegistered = new Map<string, string>();

  /** Registers, updates and (through the active set) removes the proxy and direct tools. */
  function syncTools() {
    if (!decided) return;
    try {
      const taken = takenByOthers();
      const wanted = new Set<string>();
      if (proxyName && proxyServers().length) {
        const description = describeProxy();
        if (proxyRegistered !== description) {
          registerProxy();
          proxyRegistered = description;
        }
        wanted.add(proxyName);
      }
      direct.clear();
      for (const server of servers.values()) {
        server.skipped = 0;
        if (server.settings.exposure !== "direct") continue;
        const tools = knownTools(server);
        if (!tools) continue;
        for (const tool of tools) {
          const name = directToolName(server.name, tool.name);
          if (taken.has(name) || wanted.has(name)) {
            server.skipped++;
            continue;
          }
          const signature = JSON.stringify([server.name, tool.name, tool.description, tool.inputSchema]);
          if (directRegistered.get(name) !== signature) {
            registerDirect(name, server, tool);
            directRegistered.set(name, signature);
          }
          direct.set(name, { server: server.name, tool: tool.name });
          wanted.add(name);
        }
      }
      const active = new Set(pi.getActiveTools());
      let changed = false;
      for (const name of ours) {
        if (wanted.has(name) && !active.has(name)) {
          active.add(name);
          changed = true;
        } else if (!wanted.has(name) && active.has(name)) {
          active.delete(name);
          changed = true;
        }
      }
      if (changed) pi.setActiveTools([...active]);
    } catch {
      // A tool that can't be registered is a tool the agent doesn't get; pi goes on.
    }
  }

  function server(name: unknown): Server {
    const found = typeof name === "string" ? servers.get(name) : undefined;
    if (found) return found;
    const names = [...servers.keys()].join(", ") || "none";
    throw new Error(`There's no MCP server named "${String(name ?? "")}". Servers: ${names}.`);
  }

  async function listOf(target: Server): Promise<Tool[]> {
    const known = knownTools(target);
    if (known) return known;
    await withServer(target, async () => undefined);
    return knownTools(target) ?? [];
  }

  function done(content: unknown, details: Record<string, unknown>) {
    return { content, details: { mcp: details } };
  }

  function fail(toolCallId: string, error: unknown, details: Record<string, unknown>): never {
    const auth = error instanceof AppError && ["needs_sign_in", "expired", "needs_scopes"].includes(error.code);
    failures.set(toolCallId, { mcp: { ...details, outcome: auth ? "needsSignIn" : "failed" } });
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(message);
  }

  async function runCall(toolCallId: string, name: string, tool: string, args: Record<string, unknown>, signal?: AbortSignal) {
    const details = { server: name, tool };
    try {
      maybeReload();
      const target = server(name);
      const visible = target.settings.tools;
      if (visible && !visible.includes(tool)) throw new Error(`${tool} on ${name} is turned off in Settings ▸ MCP servers.`);
      const result = await withServer(target, (client) =>
        client.callTool(tool, args, { signal, timeoutMs: target.settings.timeoutSeconds * 1000 }),
      );
      const content = toolContent(result);
      if (result?.isError) {
        const text = content.filter((item) => item.type === "text").map((item) => item.text).join("\n");
        throw new Error(text || `${tool} on ${name} failed.`);
      }
      return done(content, { ...details, outcome: "done" });
    } catch (error) {
      fail(toolCallId, error, details);
    }
  }

  async function search(query: string) {
    const targets = proxyServers();
    if (!query.trim()) {
      const lines = targets.map((target) => {
        const tools = knownTools(target);
        const count = tools ? `${tools.length} tools` : "tools not listed yet";
        return `${target.name} — ${target.state}, ${count}`;
      });
      return lines.length ? `MCP servers:\n${lines.join("\n")}` : "No MCP servers are set up for the mcp tool.";
    }
    const words = query.toLowerCase().split(/\s+/).filter(Boolean);
    const problems: string[] = [];
    await Promise.all(targets.map(async (target) => {
      if (knownTools(target)) return;
      try {
        await listOf(target);
      } catch (error) {
        problems.push(`${target.name}: ${error instanceof Error ? error.message : String(error)}`);
      }
    }));
    const hits: Array<{ score: number; line: string }> = [];
    for (const target of targets) {
      for (const tool of knownTools(target) ?? []) {
        const haystack = `${tool.name} ${tool.title ?? ""} ${tool.description}`.toLowerCase();
        const score = words.filter((word) => haystack.includes(word)).length;
        if (score) hits.push({ score, line: `${target.name}/${tool.name} — ${firstSentence(tool.description)}` });
      }
    }
    hits.sort((a, b) => b.score - a.score);
    const lines = hits.slice(0, SEARCH_LIMIT).map((hit) => hit.line);
    const more = hits.length > SEARCH_LIMIT ? [`(${hits.length - SEARCH_LIMIT} more: narrow the query)`] : [];
    const head = lines.length ? lines : [`No tools match "${query}".`];
    return [...head, ...more, ...problems].join("\n");
  }

  async function runProxy(toolCallId: string, params: Record<string, unknown>, signal?: AbortSignal) {
    const action = params?.action;
    const details = { server: typeof params?.server === "string" ? params.server : "", tool: typeof params?.tool === "string" ? params.tool : "" };
    if (action === "call") {
      if (!details.server || !details.tool) fail(toolCallId, new Error('call needs "server" and "tool": search first.'), details);
      return runCall(toolCallId, details.server, details.tool, isObject(params.arguments) ? params.arguments : {}, signal);
    }
    try {
      maybeReload();
      if (action === "search") {
        const text = await search(typeof params.query === "string" ? params.query : "");
        return done([{ type: "text", text }], { ...details, outcome: "done" });
      }
      if (action === "describe") {
        if (!details.server || !details.tool) throw new Error('describe needs "server" and "tool": search first.');
        const target = server(details.server);
        const tool = (await listOf(target)).find((candidate) => candidate.name === details.tool);
        if (!tool) throw new Error(`${details.server} has no tool named "${details.tool}": search first.`);
        const text = [
          `${target.name}/${tool.name}${tool.title ? ` (${tool.title})` : ""}`,
          tool.description,
          `Arguments (JSON Schema):\n${JSON.stringify(tool.inputSchema ?? {}, null, 2)}`,
        ].filter(Boolean).join("\n\n");
        return done([{ type: "text", text }], { ...details, outcome: "done" });
      }
      throw new Error('action must be "search", "describe" or "call".');
    } catch (error) {
      fail(toolCallId, error, details);
    }
  }

  // ---- lifecycle

  function maybeReload() {
    if (!loadConfig()) return;
    syncTools();
    if (started) startEager();
  }

  /** withSession and alwaysOn servers, and direct servers with no cached list, connect now. */
  function startEager() {
    for (const target of servers.values()) {
      if (target.client || target.connecting) continue;
      const eager = target.settings.start !== "whenUsed";
      const needsList = target.settings.exposure === "direct" && !knownTools(target);
      if (eager || needsList) connect(target).catch(() => {});
    }
  }

  function decideProxyName() {
    if (decided) return;
    decided = true;
    const stored = (globalThis as Record<symbol, unknown>)[PROXY_NAME];
    if (typeof stored === "string") {
      proxyName = stored || undefined;
      return;
    }
    const taken = takenByOthers();
    if (!taken.has("mcp")) proxyName = "mcp";
    else if (!taken.has("shepherd_mcp")) proxyName = "shepherd_mcp";
    (globalThis as Record<symbol, unknown>)[PROXY_NAME] = proxyName ?? "";
  }

  function shutdown() {
    for (const target of servers.values()) {
      clearTimeout(target.idleTimer);
      clearTimeout(target.reconnectTimer);
      target.removed = true;
      try {
        target.client?.close(true);
      } catch {}
      target.client = undefined;
    }
    servers.clear();
    configStamp = "";
    killAllServers();
  }

  pi.on("session_start", (_event, ctx) => {
    try {
      if (typeof ctx?.cwd === "string" && ctx.cwd) cwd = ctx.cwd;
      decideProxyName();
      loadConfig();
      syncTools();
      started = true;
      startEager();
    } catch {}
  });

  pi.on("agent_start", () => {
    try {
      maybeReload();
    } catch {}
  });

  pi.on("tool_result", (event) => {
    try {
      const details = failures.get(event?.toolCallId);
      if (!details) return undefined;
      failures.delete(event.toolCallId);
      return { details };
    } catch {
      return undefined;
    }
  });

  pi.on("session_shutdown", () => {
    try {
      shutdown();
      started = false;
    } catch {}
  });
}
