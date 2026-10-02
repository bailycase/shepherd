import Foundation
import ShepherdProtocol

/// Installs the per-session pi extension that keeps the old, bulky parts of a long run out of what
/// the model is sent (`shepherd-context.ts`: clips any one tool result, and in batches clears the
/// oldest tool output, tool-call contents, reasoning payloads, screenshots and hidden notices
/// before the context fills; docs/context-budget.md) from its embedded literal into the support
/// directory. It is inert without `SHEPHERD_EXT_CONTEXT`, which the app sets while Settings ▸
/// Agents ▸ Trim old tool output is on, and it changes only the request: the thread, the session
/// file and every result in them stay whole.
enum ContextExtension {
    static func installedPath() throws -> String {
        let directory = ShepherdPaths.supportDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("shepherd-context.ts")
        let source = Data(extensionSource.utf8)
        if (try? Data(contentsOf: url)) != source {
            try source.write(to: url, options: .atomic)
        }
        return url.path
    }

    /// Extensions/shepherd-context.ts is canonical; keep this byte-identical
    /// (scripts/sync-embedded-extension.py).
    static let extensionSource = #"""
        // @ts-nocheck -- loaded by pi/jiti; this project intentionally has no Node TS workspace.
        // Shepherd's context clearing: keeps the old, bulky parts of a long run out of what the model is sent, and
        // leaves all of it in the thread. An agent's context fills with what it did, not what was said: tool output,
        // the contents of the files it wrote, the reasoning payloads the provider asks to have sent back, screenshots.
        // One user message can start a hundred tool calls, so "recent" cannot mean recent user turns; it means the last
        // few model calls. pi calls the `context` event before every model request with a copy of the conversation:
        //
        //   1. Any single tool result over a ceiling (about 6k tokens) is clipped to its head and tail around a line
        //      saying how much was left out. A pure function of that result, so it never changes between requests.
        //   2. When the request has grown past a share of the model's window (55%), one batch clears the OLDEST
        //      clearable content until the estimate is back under a lower share (33%), and never anything in the last
        //      8 model calls (and their results). At most one batch per 20 calls, and only when it frees something
        //      worth the cache it breaks. Cleared: tool result text and images, the large strings in old tool calls'
        //      arguments (a file a `write` or `edit` carried; the call, its name and its path stay), reasoning payloads
        //      (OpenAI Responses only: the provider needs a reasoning item only for the call it just made, and a call
        //      replayed without one is sent without its item id), and hidden custom messages. Each becomes one line
        //      saying what it was and about how big.
        //   3. The batch is remembered: its boundary (a message timestamp) goes into the session as an append-only
        //      `shepherd.context` custom entry, which pi keeps out of the model's context. Every later request clears
        //      exactly what that boundary says, so the request is a pure function of the session: the same bytes after
        //      a restart, on another branch only where the entry is, and across a compaction. A provider's prompt cache
        //      is therefore broken once per batch (about once in 25 to 35 calls), not on every call.
        //
        // Never cleared: user messages, assistant text, thinking text, the compaction summary, the newest calls, and
        // the call's own name and path. The transcript, the session file and the thread keep every result in full: only
        // the request changes.
        //
        // Inert without SHEPHERD_EXT_CONTEXT (the app sets it while Settings ▸ Agents ▸ Trim old tool output is on). The
        // numbers move with SHEPHERD_CONTEXT_CLIP_TOKENS, _TRIGGER_PERCENT, _TARGET_PERCENT, _KEEP_CALLS and _GAP_CALLS
        // (tests do). Dependency-free; nothing here throws into pi or keeps it alive.
        import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

        export const ENTRY = "shepherd.context";
        export const DEFAULTS = { clipTokens: 6000, triggerPercent: 55, targetPercent: 33, keepCalls: 8, gapCalls: 20 };
        const CHARS_PER_TOKEN = 4;
        // What a screenshot costs, measured on real threads, and how many characters of a reasoning payload make a token.
        const IMAGE_TOKENS = 2100;
        const REASONING_CHARS_PER_TOKEN = 12.4;
        // A line standing in for something cleared, and the least that is worth clearing.
        const STUB_TOKENS = 40;
        const MIN_ITEM_TOKENS = 100;
        // A string in a tool call's arguments shorter than this stays (a path, a command, a short edit).
        const ARGUMENT_STRING_CHARS = 300;
        // The marker a clip leaves is part of the budget so a clipped result never ends up over the ceiling.
        const CLIP_MARKER_ROOM = 220;
        // pi's APIs that send a reasoning item back, and need its call ids to go with it.
        const REASONING_APIS = new Set(["openai-responses", "openai-codex-responses", "azure-openai-responses"]);

        export interface Limits {
          clipTokens: number;
          triggerPercent: number;
          targetPercent: number;
          keepCalls: number;
          gapCalls: number;
        }

        export const tokensOf = (chars: number) => Math.ceil(chars / CHARS_PER_TOKEN);

        function numberFrom(value: string | undefined, fallback: number, min: number, max: number): number {
          const parsed = Number(value);
          return Number.isFinite(parsed) && parsed >= min && parsed <= max ? Math.floor(parsed) : fallback;
        }

        export function limitsFrom(env: Record<string, string | undefined>): Limits {
          const limits = {
            clipTokens: numberFrom(env.SHEPHERD_CONTEXT_CLIP_TOKENS, DEFAULTS.clipTokens, 500, 200_000),
            triggerPercent: numberFrom(env.SHEPHERD_CONTEXT_TRIGGER_PERCENT, DEFAULTS.triggerPercent, 10, 95),
            targetPercent: numberFrom(env.SHEPHERD_CONTEXT_TARGET_PERCENT, DEFAULTS.targetPercent, 5, 90),
            keepCalls: numberFrom(env.SHEPHERD_CONTEXT_KEEP_CALLS, DEFAULTS.keepCalls, 1, 1000),
            gapCalls: numberFrom(env.SHEPHERD_CONTEXT_GAP_CALLS, DEFAULTS.gapCalls, 1, 10_000),
          };
          // A batch has to leave room below where it starts.
          return limits.targetPercent < limits.triggerPercent ? limits : { ...limits, triggerPercent: DEFAULTS.triggerPercent, targetPercent: DEFAULTS.targetPercent };
        }

        // MARK: reading messages

        /** The text of a tool result's or custom message's content, a list of blocks (or, defensively, a string). */
        function textOf(content: unknown): string {
          if (typeof content === "string") return content;
          if (!Array.isArray(content)) return "";
          return content.map((block) => (block && block.type === "text" && typeof block.text === "string" ? block.text : "")).join("");
        }

        const imagesIn = (content: unknown): number => (Array.isArray(content) ? content.filter((block) => block && block.type === "image").length : 0);

        const isNumber = (value: unknown): value is number => typeof value === "number" && Number.isFinite(value);

        const kilo = (tokens: number) => (tokens >= 1000 ? `${(tokens / 1000).toFixed(1).replace(/\.0$/, "")}k` : String(tokens));

        // What a tool call was about, in a few words: the file it read or wrote, the command it ran.
        function aboutCall(call: any): string {
          const args = call?.args;
          if (!args || typeof args !== "object") return "";
          for (const key of ["path", "file_path", "command", "pattern", "url", "query"]) {
            const value = args[key];
            if (typeof value === "string" && value.trim()) {
              const line = value.trim().split("\n")[0].replace(/`/g, "'");
              return line.length > 70 ? `${line.slice(0, 67)}...` : line;
            }
          }
          return "";
        }

        // MARK: the clip

        // The head of `text` in at most `budget` characters, ending on a line break when one is close.
        function head(text: string, budget: number): string {
          if (text.length <= budget) return text;
          const cut = text.lastIndexOf("\n", budget);
          return text.slice(0, cut >= budget / 2 ? cut + 1 : budget);
        }

        // The tail of `text` in at most `budget` characters, starting on a line when one is close.
        function tail(text: string, budget: number): string {
          if (text.length <= budget) return text;
          const start = text.length - budget;
          const cut = text.indexOf("\n", start);
          return text.slice(cut >= 0 && cut - start <= budget / 2 ? cut + 1 : start);
        }

        export const clipMarker = (omitted: string) => `[output trimmed in context: ${omitted}. Re-run with a narrower command, or read the part you need.]`;

        /** `text` unchanged when it fits `limitChars`, else its head and its tail around the marker. */
        export function clip(text: string, limitChars: number): string {
          if (text.length <= limitChars) return text;
          const budget = Math.max(200, limitChars - CLIP_MARKER_ROOM);
          const first = head(text, Math.ceil(budget * 0.6));
          const last = tail(text.slice(first.length), Math.floor(budget * 0.4));
          const hidden = text.slice(first.length, text.length - last.length);
          const lines = hidden.split("\n").length - (hidden.endsWith("\n") ? 1 : 0);
          const omitted = lines >= 2 ? `${lines} lines` : `${hidden.length} characters`;
          return `${first}${first.endsWith("\n") ? "" : "\n"}${clipMarker(omitted)}\n${last}`;
        }

        // Replaces the text blocks of a result's content with `text` (the first block's place), keeping every other block.
        function withText(content: unknown, text: string): unknown {
          if (typeof content === "string") return text;
          const out: unknown[] = [];
          let placed = false;
          for (const block of Array.isArray(content) ? content : []) {
            if (block && block.type === "text") {
              if (!placed) out.push({ ...block, text });
              placed = true;
            } else {
              out.push(block);
            }
          }
          if (!placed) out.unshift({ type: "text", text });
          return out;
        }

        // MARK: the stubs

        export const resultStub = (tool: string, about: string, tokens: number) =>
          `[${tool || "tool"}${about ? ` ${about}` : ""} output removed from context: about ${kilo(tokens)} tokens. It was shown earlier in this conversation; run it again if you need it.]`;

        export const imageStub = (count: number) => `[${count === 1 ? "image" : `${count} images`} removed from context. It was shown earlier in this conversation.]`;

        export const customStub = (type: string, tokens: number) => `[${type || "custom"} message removed from context: about ${kilo(tokens)} tokens. It was shown earlier in this conversation.]`;

        export const argumentStub = (chars: number) => `[${chars} characters removed from context]`;

        // MARK: clearing what is old

        interface Environment {
          /** A message with an earlier timestamp is old. */
          boundary: number;
          clipTokens: number;
          /** Tool calls by id, for naming what a cleared result was. */
          calls: Map<string, { name: string; args: unknown }>;
          /** Call ids rewritten because their reasoning went, by the id they had. */
          ids: Map<string, string>;
        }

        const old = (message: any, env: Environment) => isNumber(message?.timestamp) && message.timestamp < env.boundary;

        // Strings in `value` over the limit become a marker; null when nothing needed it.
        function clearStrings(value: unknown): { value: unknown; saved: number } | null {
          if (typeof value === "string") {
            return value.length > ARGUMENT_STRING_CHARS ? { value: argumentStub(value.length), saved: tokensOf(value.length) - tokensOf(argumentStub(value.length).length) } : null;
          }
          if (Array.isArray(value)) {
            let changed = false, saved = 0;
            const out = value.map((item) => {
              const cleared = clearStrings(item);
              if (!cleared) return item;
              changed = true;
              saved += cleared.saved;
              return cleared.value;
            });
            return changed ? { value: out, saved } : null;
          }
          if (value && typeof value === "object") {
            let changed = false, saved = 0;
            const out: Record<string, unknown> = {};
            for (const [key, item] of Object.entries(value)) {
              const cleared = clearStrings(item);
              out[key] = cleared ? cleared.value : item;
              if (cleared) {
                changed = true;
                saved += cleared.saved;
              }
            }
            return changed ? { value: out, saved } : null;
          }
          return null;
        }

        // `callId` is the id the call had when it was made (a result's own may have been rewritten since).
        function clearToolResult(message: any, env: Environment, callId: string = message.toolCallId): { message: any; saved: number } | null {
          const text = textOf(message.content);
          const images = imagesIn(message.content);
          const textTokens = tokensOf(text.length);
          const clearText = textTokens > MIN_ITEM_TOKENS;
          if (!clearText && images === 0) return null;
          let content: unknown = message.content;
          let saved = 0;
          if (clearText) {
            const call = env.calls.get(callId);
            content = withText(content, resultStub(message.toolName ?? call?.name, aboutCall(call), textTokens));
            saved += Math.min(textTokens, env.clipTokens) - STUB_TOKENS;
          }
          if (images > 0) {
            content = (Array.isArray(content) ? content : []).filter((block) => !(block && block.type === "image"));
            (content as unknown[]).push({ type: "text", text: imageStub(images) });
            saved += images * IMAGE_TOKENS - STUB_TOKENS;
          }
          return { message: { ...message, content }, saved };
        }

        function clearAssistant(message: any, env: Environment): { message: any; saved: number } | null {
          if (!Array.isArray(message.content)) return null;
          const reasoning = REASONING_APIS.has(message.api);
          let changed = false, saved = 0, dropped = false;
          const out: any[] = [];
          for (const block of message.content) {
            if (reasoning && block && block.type === "thinking" && typeof block.thinkingSignature === "string" && block.thinkingSignature) {
              saved += Math.ceil(block.thinkingSignature.length / REASONING_CHARS_PER_TOKEN);
              changed = dropped = true;
              continue;
            }
            if (block && block.type === "toolCall") {
              const cleared = clearStrings(block.arguments);
              if (cleared && cleared.saved > 0) {
                out.push({ ...block, arguments: cleared.value });
                saved += cleared.saved;
                changed = true;
                continue;
              }
            }
            out.push(block);
          }
          if (!changed) return null;
          if (dropped) {
            // The provider pairs a call's item id with the reasoning item that came before it. Without the reasoning, the id
            // goes too (pi does the same for a call another model made), in the call and in the result that answers it.
            for (let i = 0; i < out.length; i++) {
              const block = out[i];
              if (block && block.type === "toolCall" && typeof block.id === "string" && block.id.includes("|")) {
                const id = block.id.split("|")[0];
                env.ids.set(block.id, id);
                out[i] = { ...block, id };
              }
            }
          }
          return { message: { ...message, content: out }, saved };
        }

        function clearCustom(message: any): { message: any; saved: number } | null {
          const tokens = tokensOf(textOf(message.content).length);
          if (tokens <= MIN_ITEM_TOKENS) return null;
          return { message: { ...message, content: customStub(message.customType, tokens) }, saved: tokens - STUB_TOKENS };
        }

        function callsOf(messages: any[]): Map<string, { name: string; args: unknown }> {
          const calls = new Map();
          for (const message of messages) {
            if (message?.role !== "assistant" || !Array.isArray(message.content)) continue;
            for (const block of message.content) if (block && block.type === "toolCall" && typeof block.id === "string") calls.set(block.id, { name: block.name, args: block.arguments });
          }
          return calls;
        }

        /**
         * The conversation as the model should be sent it: every result clipped to the ceiling, and everything with an
         * earlier timestamp than `boundary` (0: nothing) cleared as the header says. Returns `messages` itself when nothing
         * changes; otherwise a new list in which only the changed messages are new objects. Never mutates its input.
         */
        export function trimContext(messages: any[], boundary = 0, limits: Limits = DEFAULTS): any[] {
          if (!Array.isArray(messages)) return messages;
          const env: Environment = { boundary, clipTokens: limits.clipTokens, calls: callsOf(messages), ids: new Map() };
          const clipChars = limits.clipTokens * CHARS_PER_TOKEN;
          let changed = false;
          const out = messages.map((message) => {
            let next = message;
            if (message?.role === "assistant" && old(message, env)) next = clearAssistant(message, env)?.message ?? message;
            else if (message?.role === "custom" && old(message, env)) next = clearCustom(message)?.message ?? message;
            else if (message?.role === "toolResult") {
              if (typeof message.toolCallId === "string" && env.ids.has(message.toolCallId)) next = { ...message, toolCallId: env.ids.get(message.toolCallId) };
              const cleared = old(message, env) ? clearToolResult(next, env, message.toolCallId) : null;
              if (cleared) next = cleared.message;
              else if (textOf(next.content).length > clipChars) next = { ...next, content: withText(next.content, clip(textOf(next.content), clipChars)) };
            }
            if (next !== message) changed = true;
            return next;
          });
          return changed ? out : messages;
        }

        // MARK: deciding on a batch

        /** Where the last batch left off, from its `shepherd.context` entry. */
        export interface State {
          before: number;
          /** The timestamp of the newest call when it ran, to count the calls since. */
          at: number;
        }

        const assistants = (messages: any[]) => messages.filter((message) => message?.role === "assistant" && isNumber(message.timestamp));

        export function callsSince(messages: any[], state?: State): number {
          return assistants(messages).filter((message) => !state || message.timestamp > state.at).length;
        }

        /**
         * The boundary of the next batch: the oldest messages whose clearing brings `used` tokens down to the target share
         * of `window`, never reaching into the last `keepCalls` calls. `from` is where the last batch left off: what is
         * older is cleared already, and `used` has it gone. Undefined when nothing is clearable, or when what is would free
         * too little to be worth breaking the provider's cache for.
         */
        export function planBatch(messages: any[], used: number, window: number, limits: Limits = DEFAULTS, from = 0): { before: number; saved: number } | undefined {
          const need = used - (window * limits.targetPercent) / 100;
          const calls = assistants(messages);
          if (need <= 0 || calls.length <= limits.keepCalls) return undefined;
          const reach = calls[calls.length - limits.keepCalls].timestamp;
          const env: Environment = { boundary: reach, clipTokens: limits.clipTokens, calls: callsOf(messages), ids: new Map() };
          let saved = 0;
          let before = reach;
          for (const message of messages) {
            if (!old(message, env) || message.timestamp < from) continue;
            const cleared = message.role === "toolResult" ? clearToolResult(message, env) : message.role === "assistant" ? clearAssistant(message, env)
              : message.role === "custom" ? clearCustom(message) : null;
            if (!cleared) continue;
            saved += cleared.saved;
            if (saved >= need) {
              before = Math.min(message.timestamp + 1, reach);
              break;
            }
          }
          return saved >= Math.max(2000, window / 100) ? { before, saved } : undefined;
        }

        function readState(ctx: any): State | undefined {
          try {
            const branch = ctx?.sessionManager?.getBranch?.() ?? [];
            for (let i = branch.length - 1; i >= 0; i--) {
              const entry = branch[i];
              if (entry?.type === "custom" && entry.customType === ENTRY && isNumber(entry.data?.before)) return { before: entry.data.before, at: isNumber(entry.data.at) ? entry.data.at : 0 };
            }
          } catch {
            // No state: nothing was cleared before.
          }
          return undefined;
        }

        export default function shepherdContext(pi: ExtensionAPI) {
          if (!process.env.SHEPHERD_EXT_CONTEXT) return;
          const limits = limitsFrom(process.env);
          pi.on("context", (event, ctx) => {
            try {
              const messages = event?.messages;
              if (!Array.isArray(messages)) return undefined;
              let state = readState(ctx);
              const usage = ctx?.getContextUsage?.();
              if (usage && isNumber(usage.tokens) && isNumber(usage.contextWindow) && usage.contextWindow > 0
                && usage.tokens >= (usage.contextWindow * limits.triggerPercent) / 100 && callsSince(messages, state) >= limits.gapCalls) {
                const plan = planBatch(messages, usage.tokens, usage.contextWindow, limits, state?.before ?? 0);
                if (plan && plan.before > (state?.before ?? 0)) {
                  const calls = assistants(messages);
                  const at = calls.length ? calls[calls.length - 1].timestamp : 0;
                  try {
                    pi.appendEntry(ENTRY, { v: 1, before: plan.before, at, from: Math.round(usage.tokens), freed: Math.round(plan.saved) });
                    // Only what the session can be read back to say is cleared: a batch it cannot hold would change the request on every call.
                    const written = readState(ctx);
                    if (written && written.before === plan.before) state = written;
                  } catch {
                    // Not remembered means not cleared.
                  }
                }
              }
              const trimmed = trimContext(messages, state?.before ?? 0, limits);
              return trimmed === messages ? undefined : { messages: trimmed };
            } catch {
              // The model is better off with the full conversation than with a failed request.
              return undefined;
            }
          });
        }

        """#
}
