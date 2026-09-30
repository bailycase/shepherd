import Darwin
import Foundation
import ShepherdCore

/// The service tier extension: installed in Shepherd's pi home with its other files
/// (`PiHome.install`, outside extensions/ so pi never discovers a second copy) and loaded by an
/// agent's own pi only (`StatusExtension.command`), which is also the only pi started with
/// `SHEPHERD_EXT_SERVICE_TIER`. It reads the file `ServiceTierFile` keeps for the agent on every
/// provider request. A native subagent is another pi process started without any `SHEPHERD_`
/// variable (the children extension removes them), so it runs on Standard whatever its parent's
/// tier is.
public enum ServiceTierExtension {
    static let fileName = "shepherd-service-tier.ts"
    /// The environment variable that names an agent's tier file.
    public static let environmentKey = "SHEPHERD_EXT_SERVICE_TIER"

    /// Where `PiHome.install` writes the extension: what an agent's pi loads with `-e`.
    public static func path(in home: PiHome) -> String {
        home.directory.appendingPathComponent(fileName).path
    }

    /// The variable that turns the extension on for one agent's pi, naming the agent's file.
    public static func environment(for agentID: AgentID, in home: PiHome) -> [String: String] {
        ServiceTierFile.url(for: agentID, in: home).map { [environmentKey: $0.path] } ?? [:]
    }

    @discardableResult
    static func install(in home: PiHome) throws -> URL {
        let path = home.directory.appendingPathComponent(fileName)
        try PiHome.write(Data(extensionSource.utf8), to: path, mode: 0o600)
        return path
    }

    /// Embedded copy of Extensions/shepherd-service-tier.ts, which is canonical; keep this literal
    /// byte-identical to it (scripts/sync-embedded-extension.py).
    static let extensionSource = #"""
        // Shepherd's service tier (the composer's Speed control): adds `service_tier` to this agent's
        // own provider requests while its thread is on Fast. Inert unless SHEPHERD_EXT_SERVICE_TIER
        // names the file Shepherd keeps for the agent; every failure leaves the request as it was.
        //
        // The file is `{"tier":"standard"|"fast"}`, written atomically by the host whenever the tier
        // changes and before pi starts, and read here on every request, so a change applies to the next
        // model call of a running agent and a restarted pi needs no handshake. No file, or one that
        // can't be read, is Standard.
        //
        // The table below is ServiceTierSupport (Sources/ShepherdCore/ServiceTier.swift): both are tested
        // against Tests/Extensions/service-tier-support.json. A request to a provider and API the table
        // doesn't list is never touched, whatever the file says.
        import * as fs from "node:fs";
        import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

        type Tier = "standard" | "fast";
        type Model = { provider: string; id: string; api?: string | null; ownedBy?: string | null };
        type Rule = { provider: string; apis: string[]; wire: Partial<Record<Tier, string>>; owners?: string[] };

        export const RULES: Rule[] = [
          { provider: "openai", apis: ["openai-responses", "openai-completions"], wire: { fast: "priority" } },
          { provider: "openai-codex", apis: ["openai-codex-responses"], wire: { fast: "priority" } },
          { provider: "cliproxyapi", apis: ["openai-responses"], wire: { fast: "priority" }, owners: ["openai", "codex", "openai-codex"] },
        ];

        // Models that are not chat models, whatever their owner.
        const EXCLUDED = ["image", "realtime", "audio", "tts", "transcribe", "whisper", "embedding", "moderation", "dall-e"];

        const normalized = (text: string) => text.toLowerCase().trim();
        const baseName = (id: string) => {
          const last = id.split("/").filter(Boolean).at(-1) ?? id;
          return normalized(last.startsWith("~") ? last.slice(1) : last);
        };
        // An ownerless model's id reads as OpenAI's: routed through `openai/`, or named like one.
        function impliesOwner(id: string, owners: string[]) {
          const parts = id.split("/").filter(Boolean).map(normalized);
          const route = parts.length > 1 ? parts[parts.length - 2] : undefined;
          if (route && owners.includes(route.startsWith("~") ? route.slice(1) : route)) return true;
          const name = baseName(id);
          return name.startsWith("gpt-") || name.startsWith("codex-") || /^o\d/.test(name);
        }

        export function ruleFor(model: Model): Rule | undefined {
          const rule = RULES.find((item) => item.provider === model.provider);
          if (!rule) return;
          if (model.api) {
            if (!rule.apis.includes(model.api)) return;
          } else if (rule.owners) {
            return;
          }
          const name = baseName(model.id);
          if (EXCLUDED.some((word) => name.includes(word))) return;
          if (rule.owners) {
            const owner = normalized(model.ownedBy ?? "");
            if (owner ? !rule.owners.includes(owner) : !impliesOwner(model.id, rule.owners)) return;
          }
          return rule;
        }

        export function tiersFor(model: Model): Tier[] {
          const rule = ruleFor(model);
          return rule ? ["standard", ...(Object.keys(rule.wire) as Tier[])] : [];
        }

        export function wireValue(tier: Tier, model: Model): string | undefined {
          return ruleFor(model)?.wire[tier];
        }

        function readTier(path: string): Tier {
          try {
            const value = JSON.parse(fs.readFileSync(path, "utf8"));
            return value?.tier === "fast" ? "fast" : "standard";
          } catch {
            return "standard";
          }
        }

        // CLIProxyAPI's own listing says who owns a model; the launcher points this at Shepherd's
        // connection file, which also holds its key, so only `owned_by` is read and nothing is kept.
        let owners: { stamp: string; byID: Map<string, string | undefined> } | undefined;
        function ownerOf(id: string): string | undefined {
          const path = process.env.SHEPHERD_CLIPROXYAPI_CONFIG;
          if (!path) return;
          try {
            const info = fs.statSync(path);
            const stamp = `${info.mtimeMs}:${info.size}`;
            if (owners?.stamp !== stamp) {
              const models = JSON.parse(fs.readFileSync(path, "utf8"))?.models;
              const byID = new Map<string, string | undefined>();
              if (Array.isArray(models)) {
                for (const model of models) {
                  if (typeof model?.id === "string") byID.set(model.id, typeof model.owned_by === "string" ? model.owned_by : undefined);
                }
              }
              owners = { stamp, byID };
            }
            return owners.byID.get(id);
          } catch {
            return;
          }
        }

        export default function shepherdServiceTier(pi: ExtensionAPI) {
          const file = process.env.SHEPHERD_EXT_SERVICE_TIER ?? "";
          if (!file) return;

          pi.on("before_provider_request", (event: { payload?: unknown }, ctx: { model?: { provider: string; id: string; api?: string } }) => {
            try {
              const tier = readTier(file);
              if (tier === "standard") return;
              const current = ctx.model;
              if (!current) return;
              const model: Model = { provider: current.provider, id: current.id, api: current.api,
                ownedBy: current.provider === "cliproxyapi" ? ownerOf(current.id) : undefined };
              const value = wireValue(tier, model);
              if (!value) return;
              const payload = event.payload as Record<string, unknown> | undefined;
              if (!payload || typeof payload !== "object" || Array.isArray(payload)) return;
              // The request is the current model's, in the shape its API takes the field in.
              if (payload.model !== current.id || "service_tier" in payload) return;
              if (current.api === "openai-completions" ? !Array.isArray(payload.messages) : !Array.isArray(payload.input)) return;
              return { ...payload, service_tier: value };
            } catch {
              // Swallow: a request without the field is an ordinary request.
            }
          });
        }

        """#
}

/// What the host keeps for an agent's pi to read: `<home>/service-tier/<agent>.json`, the agent's
/// tier, rewritten atomically whenever it changes and before its pi starts. A file rather than a
/// message because the extension reads it synchronously on each request (a change applies to the
/// next model call of a running agent), it needs no connection (a pi started by Retry or a
/// relaunch, or one whose socket is down, still reads the current tier), and a torn read cannot
/// happen: the file is replaced by rename.
public enum ServiceTierFile {
    public static func directory(in home: PiHome) -> URL {
        home.directory.appendingPathComponent("service-tier", isDirectory: true)
    }

    /// The agent's file. The id is a UUID string, but a path is built from it, so anything else
    /// is refused.
    public static func url(for agentID: AgentID, in home: PiHome) -> URL? {
        let id = agentID.rawValue
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        return directory(in: home).appendingPathComponent("\(id).json")
    }

    /// Writes `tier` for the agent. Throws when the home can't be written; the agent then runs
    /// on whatever the file last held.
    public static func write(_ tier: ServiceTier, for agentID: AgentID, in home: PiHome) throws {
        guard let file = url(for: agentID, in: home) else { throw PiHomeError("Not a valid agent id: \(agentID.rawValue)") }
        let folder = directory(in: home)
        // A link in the home would carry the file somewhere else, such as the user's own pi.
        guard home.contains(file.path) else {
            throw PiHomeError("\(folder.path) leads outside Shepherd's pi home, so Shepherd won't write a service tier there")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try PiHome.write(Data(#"{"tier":"\#(tier.rawValue)"}"#.utf8), to: file, mode: 0o600)
    }

    /// The tier the agent's file holds; Standard when there is none or it can't be read.
    public static func read(for agentID: AgentID, in home: PiHome) -> ServiceTier {
        guard let file = url(for: agentID, in: home), let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["tier"] as? String, let tier = ServiceTier(rawValue: raw) else { return .standard }
        return tier
    }

    public static func remove(for agentID: AgentID, in home: PiHome) {
        guard let file = url(for: agentID, in: home) else { return }
        try? FileManager.default.removeItem(at: file)
    }
}
