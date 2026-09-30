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
