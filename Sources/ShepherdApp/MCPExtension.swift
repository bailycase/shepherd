import Foundation
import ShepherdProtocol

/// Installs the MCP extension (Settings ▸ Pi ▸ Bundled extensions ▸ MCP servers): the pi side,
/// `shepherd-mcp.ts`, and the dependency-free client beside it, `shepherd-mcp-client.mjs`, which
/// the extension imports and the app runs with node to list a server's tools for Settings.
enum MCPExtension {
    /// Writes both files to the support directory (idempotent) and returns the extension's path.
    static func installedPath() throws -> String {
        let directory = ShepherdPaths.supportDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, text) in sources {
            let url = directory.appendingPathComponent(name)
            let source = Data(text.utf8)
            if (try? Data(contentsOf: url)) != source {
                try source.write(to: url, options: .atomic)
            }
        }
        return directory.appendingPathComponent("shepherd-mcp.ts").path
    }

    /// The installed client, for `node <client> probe`.
    static func clientPath() throws -> String {
        try install().clientPath
    }

    /// Writes both files and returns both paths.
    static func install() throws -> (extensionPath: String, clientPath: String) {
        let extensionPath = try installedPath()
        return (extensionPath, ShepherdPaths.supportDirectory().appendingPathComponent("shepherd-mcp-client.mjs").path)
    }

    static var sources: [(String, String)] {
        [("shepherd-mcp.ts", extensionSource), ("shepherd-mcp-client.mjs", clientSource)]
    }

    /// Extensions/shepherd-mcp.ts is canonical; keep this byte-identical.
    static let extensionSource = #"""
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

        """#

    /// Extensions/shepherd-mcp-client.mjs is canonical; keep this byte-identical.
    static let clientSource = #"""
        // Shepherd's MCP client: JSON-RPC 2.0 over stdio, Streamable HTTP (with the legacy HTTP+SSE
        // fallback) and legacy SSE, with no dependencies. The pi extension (shepherd-mcp.ts) imports it,
        // and the app runs it as `node shepherd-mcp-client.mjs probe` to list a server's tools for
        // Settings, so there is one MCP client. Every socket, pipe and timer is unref'd: a connection
        // never keeps pi alive, and every stdio server's process group is killed when pi exits.
        import { spawn } from "node:child_process";
        import * as http from "node:http";
        import * as https from "node:https";
        import { realpathSync } from "node:fs";
        import { fileURLToPath } from "node:url";

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
              // Never echo the URL: a resolved one can carry a secret in its query.
              reject(new MCPError("the server's url isn't a valid URL", { kind: "start" }));
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
                  // Requests carry the server's headers (its token), so they only go back to its origin.
                  let endpoint;
                  try {
                    endpoint = new URL(data.trim(), this.url);
                  } catch {
                    return;
                  }
                  if (endpoint.origin !== new URL(this.url).origin) {
                    clearTimeout(timer);
                    req.destroy();
                    reject(new MCPError(`${this.host} sent a message endpoint on another origin`, { kind: "start" }));
                    return;
                  }
                  this.endpoint = endpoint.href;
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

        // node names its main module by its real path, but argv keeps the path it was given: compare real
        // paths, or a support folder reached through a symlink (/var → /private/var) would never probe.
        try {
          if (process.argv[2] === "probe" && process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) main();
        } catch {}

        """#
}
