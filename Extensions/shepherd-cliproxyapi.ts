// Swift owns discovery and settings. This provider only reads its published snapshot.
import fs from "node:fs";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import {
  type Api, type Model, type Provider, type ProviderStreamOptions, type SimpleStreamOptions,
  type TranscriptContext, lazyStream, openAICompletionsApi, openAIResponsesApi,
} from "@earendil-works/pi-ai/compat";
import { getBuiltinModels, getBuiltinProviders } from "@earendil-works/pi-ai/providers/all";

const ID = "cliproxyapi";
type ProxyModel = { id: string; owned_by?: string };
type Config = { enabled: true; baseURL: string; apiKey: string; models: ProxyModel[]; updatedAt: number };

function readConfig(path: string): Config | undefined {
  try {
    const value = JSON.parse(fs.readFileSync(path, "utf8"));
    if (value?.enabled !== true || typeof value.baseURL !== "string" ||
        typeof value.apiKey !== "string" || !value.apiKey.trim() || /\p{Cc}/u.test(value.apiKey) ||
        !Number.isFinite(value.updatedAt) || !Array.isArray(value.models) ||
        value.models.length === 0 || value.models.length > 10000) return;
    const url = new URL(value.baseURL);
    if (!["http:", "https:"].includes(url.protocol) || url.username || url.password || url.search || url.hash) return;
    const ids = new Set<string>();
    for (const model of value.models) {
      if (!model || typeof model.id !== "string" || !model.id.trim() || model.id.length > 1024 || /\p{Cc}/u.test(model.id) ||
          (model.owned_by !== undefined && typeof model.owned_by !== "string") || ids.has(model.id)) return;
      ids.add(model.id);
    }
    return { enabled: true, baseURL: value.baseURL.replace(/\/+$/, ""), apiKey: value.apiKey,
      models: value.models.map(({ id, owned_by }: ProxyModel) => ({ id, owned_by })), updatedAt: value.updatedAt };
  } catch {
    // Parsing/IO errors can contain the key or configuration bytes. Fail closed, silently.
    return;
  }
}

// "gpt-6.1-sol" and "gpt-6-sol" share the family "gpt-#-sol" and differ in version [6, 1] vs [6].
// A release date ("-20250514") is part of the family, never a version: it only matches its kind.
const family = (suffix: string) => suffix.replace(/(?<!\d)\d{8}(?!\d)/g, "D").replace(/\d+(?:\.\d+)*/g, "#");
const version = (suffix: string) => (suffix.match(/\d+/g) ?? []).filter((part) => part.length !== 8).map(Number);
function compareVersions(a: number[], b: number[]) {
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const difference = (a[i] ?? 0) - (b[i] ?? 0);
    if (difference) return difference;
  }
  return 0;
}

function metadataIndex() {
  const exact = new Map<string, Model<Api>>(), suffixes = new Map<string, Model<Api>[]>();
  const families = new Map<string, Model<Api>[]>(), providers = new Set<string>();
  for (const provider of getBuiltinProviders()) {
    providers.add(provider);
    for (const model of getBuiltinModels(provider)) {
      exact.set(`${provider}/${model.id}`, model);
      const suffix = model.id.split("/").at(-1)!;
      const candidates = suffixes.get(suffix) ?? [];
      candidates.push(model);
      suffixes.set(suffix, candidates);
      const key = `${provider}\u0000${family(suffix)}`;
      families.set(key, [...(families.get(key) ?? []), model]);
    }
  }
  return { exact, suffixes, families, providers };
}

// A model newer than pi's catalog (a release after the pinned engine) borrows its capabilities,
// thinking levels among them, from the same owner's nearest earlier version of that family.
function familyMetadata(suffix: string, provider: string | undefined, catalog: ReturnType<typeof metadataIndex>) {
  if (!provider) return;
  const siblings = catalog.families.get(`${provider}\u0000${family(suffix)}`) ?? [];
  const wanted = version(suffix);
  const ranked = siblings.map((model) => ({ model, version: version(model.id.split("/").at(-1)!) }))
    .sort((a, b) => compareVersions(b.version, a.version));
  return (ranked.find((entry) => compareVersions(entry.version, wanted) <= 0) ?? ranked.at(-1))?.model;
}

function metadataFor(proxy: ProxyModel, catalog: ReturnType<typeof metadataIndex>): Model<Api> | undefined {
  const route = proxy.id.replace(/^~/, "");
  const exact = catalog.exact.get(route);
  if (exact) return exact;
  const suffix = route.split("/").at(-1)!;
  const candidates = catalog.suffixes.get(suffix) ?? [];
  if (candidates.length === 1) return candidates[0];
  const aliases: Record<string, string> = { codex: "openai-codex", claude: "anthropic", gemini: "google" };
  const owner = proxy.owned_by?.trim().toLowerCase();
  const routedOwner = route.includes("/") ? route.split("/").at(-2) : undefined;
  const known = candidates.length ? candidates.some((model) => model.provider === routedOwner) : catalog.providers.has(routedOwner ?? "");
  const canonical = (known ? routedOwner : undefined) ||
    (owner && (aliases[owner] ?? owner)) ||
    (suffix.includes("codex") && candidates.some((model) => model.provider === "openai-codex") ? "openai-codex" :
      /^gpt-|^o\d/.test(suffix) ? "openai" : /^claude-/.test(suffix) ? "anthropic" :
      /^gemini-/.test(suffix) ? "google" : undefined);
  if (!candidates.length) return familyMetadata(suffix, canonical, catalog);
  const owned = candidates.filter((model) => model.provider === canonical);
  return owned.length === 1 ? owned[0] : undefined;
}

function buildModels(config: Config, catalog: ReturnType<typeof metadataIndex>): Model<Api>[] {
  return config.models.map((proxy) => {
    const native = metadataFor(proxy, catalog);
    // Never copy an upstream endpoint, headers, cache policy or transport compatibility.
    const responses = native?.api.includes("responses") === true;
    const deepseek = proxy.owned_by?.toLowerCase().split(/[^a-z0-9]+/).includes("deepseek");
    return {
      id: proxy.id, provider: ID, baseUrl: config.baseURL,
      // A borrowed sibling lends its capabilities, never its name.
      name: native && native.id.split("/").at(-1) === proxy.id.split("/").at(-1) ? native.name : proxy.id,
      api: responses ? "openai-responses" : "openai-completions",
      reasoning: native?.reasoning ?? false,
      input: native ? [...native.input] : ["text"],
      ...(native?.thinkingLevelMap ? { thinkingLevelMap: { ...native.thinkingLevelMap } } : {}),
      ...(native?.inputLimits ? { inputLimits: structuredClone(native.inputLimits) } : {}),
      cost: native ? structuredClone(native.cost) : { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: native?.contextWindow ?? 128000, maxTokens: native?.maxTokens ?? 16384,
      compat: {
        supportsStrictMode: false,
        ...(!responses && deepseek ? {
          supportsStore: false, supportsDeveloperRole: false, maxTokensField: "max_tokens" as const,
          requiresReasoningContentOnAssistantMessages: true, thinkingFormat: "deepseek" as const,
        } : {}),
      },
    };
  });
}

export default function (pi: ExtensionAPI) {
  const path = process.env.SHEPHERD_CLIPROXYAPI_CONFIG;
  if (!path) return;
  let config: Config | undefined;
  let models: Model<Api>[] = [];
  let catalog: ReturnType<typeof metadataIndex> | undefined;
  let registered = false;
  let revision: string | undefined;
  let busy = false;
  let session: ExtensionContext | undefined;
  let refresh = Promise.resolve();
  // The CLI can fall back before session_start even on a fresh --model request. Remember
  // the requested identity until an explicit selection; never infer permission from fallback.
  let requested: string | undefined;
  for (let i = 2; i < process.argv.length && process.argv[i] !== "--"; i++) {
    if (process.argv[i] === "--model") requested = process.argv[++i];
    else if (process.argv[i].startsWith("--model=")) requested = process.argv[i].slice(8);
  }
  if (!requested?.startsWith(ID + "/")) requested = undefined;

  function request(model: Model<Api>, context: TranscriptContext,
    options: ProviderStreamOptions | SimpleStreamOptions | undefined, simple: boolean) {
    const snapshot = config;
    const current = models.find((item) => item.id === model.id);
    return lazyStream(model, async () => {
      if (!snapshot) throw new Error("CLIProxyAPI is disabled or its settings are unavailable.");
      if (!current) throw new Error("This CLIProxyAPI model is no longer available. Choose another model.");
      const key = snapshot.apiKey;
      // fetch throws on a header byte above 0xFF before connecting, and pi would only say
      // "Connection error." A pasted curly quote or ellipsis is the usual cause.
      if (!/^[\x20-\x7e]+$/.test(key)) {
        throw new Error("The CLIProxyAPI key in Shepherd's settings has a character a request can't carry, often a curly quote or ellipsis from pasting. Reconnect in Settings ▸ Pi ▸ Sign-in with the plain key.");
      }
      const redact = (text: string) => {
        for (const secret of new Set([key, encodeURIComponent(key), JSON.stringify(key).slice(1, -1)])) {
          if (secret) text = text.split(secret).join("[redacted]");
        }
        return text;
      };
      const streamOptions = {
        ...options,
        // Native auth and dispatch both ignore stored keys and request-level auth overrides.
        apiKey: key,
        headers: { ...Object.fromEntries(Object.entries(options?.headers ?? {})
          .filter(([name]) => name.toLowerCase() !== "authorization")), Authorization: `Bearer ${key}` },
        onPayload: async (payload: unknown, requested: Model<Api>) => {
          const replaced = await options?.onPayload?.(payload, requested);
          const result = (replaced === undefined ? payload : replaced) as { tools?: Record<string, unknown>[] };
          if (current.api === "openai-responses" && Array.isArray(result?.tools)) {
            return { ...result, tools: result.tools.map((tool) =>
              tool.type === "function" ? { ...tool, strict: null } : tool) };
          }
          return result;
        },
      };
      const api = current.api === "openai-responses" ? openAIResponsesApi() : openAICompletionsApi();
      return (async function* () {
        try {
          const stream = simple ? api.streamSimple(current, context, streamOptions) : api.stream(current, context, streamOptions);
          for await (const event of stream) {
            if (event.type === "error" && event.error.errorMessage) {
              event.error.errorMessage = redact(event.error.errorMessage);
            }
            yield event;
          }
        } catch {
          // SDK/setup exceptions may contain headers, unlike structured provider failures.
          throw new Error("CLIProxyAPI request failed.");
        }
      })();
    });
  }

  const provider: Provider = {
    id: ID, name: "CLIProxyAPI",
    auth: { apiKey: {
      name: "Shepherd settings",
      check: async () => config ? { type: "api_key", source: "Shepherd settings" } : undefined,
      resolve: async () => config ? { auth: { apiKey: config.apiKey }, source: "Shepherd settings" } : undefined,
    } },
    getModels: () => models,
    stream: (model, context, options) => request(model, context, options, false),
    streamSimple: (model, context, options) => request(model, context, options, true),
  };

  function reload(ctx?: ExtensionContext): Promise<void> {
    if (ctx && (busy || !ctx.isIdle())) return refresh;
    const next = readConfig(path!);
    const nextRevision = JSON.stringify(next);
    if (nextRevision === revision) return refresh;
    revision = nextRevision;
    config = next;
    if (next) catalog ??= metadataIndex();
    models = next ? buildModels(next, catalog!) : [];
    if (next || registered) {
      // Re-registration re-resolves the selected same-ID model without a transcript entry.
      // Keep an empty, guarded provider on disable: old model objects must not send requests.
      pi.registerProvider(provider);
      registered = true;
      if (ctx) refresh = ctx.modelRegistry.refresh({ providers: [ID], allowNetwork: false }).then(() => {}, () => {});
    }
    return refresh;
  }

  function blocksRestoredModel(ctx: ExtensionContext): boolean {
    // Pi may select another authenticated provider when a saved model is unavailable.
    // Existing conversations keep their branch's model entries, including assistant-only
    // legacy sessions. Explicit set/cycle records a new model_change and clears this guard.
    if (requested && (ctx.model?.provider !== ID || ctx.model.id !== requested.slice(ID.length + 1) ||
      !models.some((model) => model.id === requested!.slice(ID.length + 1)))) return true;
    let saved: { provider: string; id: string } | undefined;
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type === "model_change") saved = { provider: entry.provider, id: entry.modelId };
      else if (entry.type === "message" && entry.message.role === "assistant") {
        saved = { provider: entry.message.provider, id: entry.message.model };
      }
    }
    return saved?.provider === ID && (ctx.model?.provider !== ID || ctx.model.id !== saved.id ||
      !models.some((model) => model.id === saved.id));
  }
  function notifyBlocked(ctx: ExtensionContext) {
    if (ctx.hasUI) ctx.ui.notify("This conversation's CLIProxyAPI model is unavailable. Re-enable it and select it, or explicitly choose another model before sending.", "error");
  }

  // Synchronous registration is required by --list-models and non-session consumers.
  void reload();
  const changed = () => { if (session) void reload(session); };
  pi.on("session_start", async (_event, ctx) => {
    fs.unwatchFile(path, changed);
    session = ctx;
    busy = false;
    await reload(ctx);
    if (blocksRestoredModel(ctx)) notifyBlocked(ctx);
    fs.watchFile(path, { persistent: false, interval: 1000 }, changed);
  });
  pi.on("model_select", (event) => {
    if (event.source === "set" || event.source === "cycle") requested = undefined;
  });
  pi.on("input", async (_event, ctx) => {
    await reload(ctx);
    if (blocksRestoredModel(ctx)) {
      notifyBlocked(ctx);
      return { action: "handled" };
    }
  });
  pi.on("session_before_compact", (_event, ctx) => {
    if (blocksRestoredModel(ctx)) { notifyBlocked(ctx); return { cancel: true }; }
  });
  pi.on("session_before_tree", (event, ctx) => {
    if (event.preparation.userWantsSummary && blocksRestoredModel(ctx)) { notifyBlocked(ctx); return { cancel: true }; }
  });
  pi.on("agent_start", () => { busy = true; });
  pi.on("agent_settled", async (_event, ctx) => { busy = false; await reload(ctx); });
  pi.on("session_shutdown", () => {
    session = undefined;
    fs.unwatchFile(path, changed);
  });
}
