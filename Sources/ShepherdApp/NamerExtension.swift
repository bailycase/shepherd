import Foundation
import ShepherdProtocol

/// Installs the per-session pi extension that proposes a short title for an
/// agent from its opening prompt and reports it over the extension socket.
/// Only passed to agents whose name is still provisional.
enum NamerExtension {
    static func installedPath() throws -> String {
        let directory = ShepherdPaths.supportDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("shepherd-namer.ts")
        let source = Data(extensionSource.utf8)
        if (try? Data(contentsOf: url)) != source {
            try source.write(to: url, options: .atomic)
        }
        return url.path
    }

    /// Extensions/shepherd-namer.ts is canonical; keep this byte-identical.
    static let extensionSource = #"""
        // @ts-nocheck -- loaded by pi/jiti; this project intentionally has no Node TS workspace.
        // Shepherd namer extension: gives an agent a short, human-readable title,
        // reported to the Shepherd extension socket as a newline-delimited JSON
        // setAgentName message. Three sources, cheapest first:
        //   1. pi's own session name (/name here or on another system) — free.
        //   2. For a provisional agent (SHEPHERD_NEEDS_NAME=1), one LLM call on the
        //      opening prompt: a single
        //      tool call (not structured JSON output) on the cheapest authed model,
        //      with the agent's own model as the last resort.
        //   3. On /resume into an unnamed conversation, the same single call on that
        //      conversation's first user message — once per session id, and never on
        //      a plain relaunch (reason "startup"), so app restarts cost nothing.
        // Inert unless SHEPHERD_AGENT_ID and SHEPHERD_SOCKET are set; every failure is
        // swallowed so this extension can never break or slow the pi session.
        import * as net from "node:net";
        import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
        import { Type } from "typebox";

        // Small/fast models tried before the agent's own, cheapest first. Override
        // with SHEPHERD_NAMER_MODELS ("provider/id,provider/id"); an entry without a
        // slash matches any provider offering that model id.
        const DEFAULT_NAMER_MODELS = [
          "anthropic/claude-haiku-4-5",
          "openai/gpt-5.1-codex-mini",
          "google/gemini-2.5-flash",
        ];

        const MAX_TITLE_LENGTH = 60;
        const PROMPT_BUDGET = 4000;

        // Prompt wording is tuned for short sidebar titles that stay accurate for the
        // whole run, rather than describing whatever was typed most recently.
        const SYSTEM_PROMPT = [
          "You name coding-agent workspaces. You are given the task a developer just handed to an agent.",
          "Call the propose_title tool exactly once with a title for that task. Do not reply with text.",
          "",
          "Requirements:",
          "- 2-5 words, verb-noun format, describing the primary deliverable (what will be different when the work is done).",
          '- Be specific about the feature or system being changed. Prefer concrete nouns; avoid vague words ("stuff", "things"),',
          '  self-referential meta phrases ("this chat", "this task", "name this"), and temporal words ("latest", "recent", "now").',
          "- Sentence case, no punctuation, no quotes, no trailing period.",
          '- Examples: "Fix plan mode over SSH", "Add worktree cleanup", "Refactor sidebar layout".',
        ].join("\n");

        export default function shepherdNamer(pi: ExtensionAPI) {
          const agentID = process.env.SHEPHERD_AGENT_ID ?? "";
          const socketPath = process.env.SHEPHERD_SOCKET ?? "";
          if (!agentID || !socketPath) return;

          // Shepherd sets this only for agents whose name is still provisional; it
          // gates the opening-prompt naming, not the resume/session-name paths.
          const wanted = process.env.SHEPHERD_NEEDS_NAME === "1";

          let done = false;
          // Session ids this process already titled (or started titling), so a run of
          // /resume back and forth never repeats an LLM call.
          const namedSessions = new Set<string>();

          // ---- socket (fire-and-forget, one message, then close) -------------------

          function report(name: string) {
            try {
              const socket = net.createConnection(socketPath, () => {
                try {
                  socket.end(JSON.stringify({ type: "setAgentName", agentID, name }) + "\n");
                } catch {
                  // Swallow; a missing title is never worth disturbing the session.
                }
              });
              socket.on("error", () => { });
              socket.unref();
            } catch {
              // Swallow.
            }
          }

          // ---- model selection -----------------------------------------------------

          function candidateSpecs(): string[] {
            const configured = (process.env.SHEPHERD_NAMER_MODELS ?? "")
              .split(",")
              .map((s: string) => s.trim())
              .filter((s: string) => s.length > 0);
            return configured.length > 0 ? configured : DEFAULT_NAMER_MODELS;
          }

          // Resolve "provider/id" or a bare "id" against the authed catalogue, in the
          // caller's order. The agent's own model is appended last so naming still
          // works when none of the cheap models are configured.
          function resolveCandidates(ctx: ExtensionContext) {
            const available = ctx.modelRegistry.getAvailable();
            const resolved: { id: string; model: unknown }[] = [];
            const seen = new Set<string>();

            function push(model) {
              if (!model) return;
              const key = `${model.provider}/${model.id}`;
              if (seen.has(key)) return;
              if (!ctx.modelRegistry.hasConfiguredAuth(model)) return;
              seen.add(key);
              resolved.push({ id: key, model });
            }

            for (const spec of candidateSpecs()) {
              const slash = spec.indexOf("/");
              if (slash > 0) {
                push(ctx.modelRegistry.find(spec.slice(0, slash), spec.slice(slash + 1)));
              } else {
                push(available.find((m) => m.id === spec));
              }
            }
            push(ctx.model);
            return resolved;
          }

          // ---- naming --------------------------------------------------------------

          function sanitize(raw: unknown): string | undefined {
            if (typeof raw !== "string") return undefined;
            const title = raw
              .replace(/\s+/g, " ")
              .replace(/^["'`]+|["'`]+$/g, "")
              .replace(/[.]+$/, "")
              .trim();
            if (title.length < 2) return undefined;
            return title.length > MAX_TITLE_LENGTH ? title.slice(0, MAX_TITLE_LENGTH).trim() : title;
          }

          async function generate(prompt: string, ctx: ExtensionContext) {
            const context = {
              systemPrompt: SYSTEM_PROMPT,
              messages: [
                {
                  role: "user" as const,
                  content: [{ type: "text" as const, text: `Task given to the agent:\n\n${prompt}` }],
                  timestamp: Date.now(),
                },
              ],
              // A tool call is far more reliable across providers than asking for
              // JSON, and needs no fallback parsing of prose.
              tools: [
                {
                  name: "propose_title",
                  description:
                    "Propose the workspace title. You MUST call this tool exactly once and emit no text response.",
                  parameters: Type.Object({
                    title: Type.String({
                      minLength: 2,
                      maxLength: MAX_TITLE_LENGTH,
                      description: "Human-readable title (2-5 words), verb-noun format like 'Fix plan mode'",
                    }),
                  }),
                },
              ],
            };

            for (const candidate of resolveCandidates(ctx)) {
              try {
                // No forced tool choice: it breaks extended-thinking models. The
                // prompt asks for the call and the candidate loop covers a refusal.
                const response = await ctx.modelRegistry.complete(candidate.model, context, {
                  // Naming is a one-shot on a throwaway context; never cache it or
                  // burn reasoning budget on it.
                  reasoningEffort: "low",
                  cacheRetention: "none",
                });
                const call = response.content.find(
                  (c) => c.type === "toolCall" && c.name === "propose_title",
                );
                const title =
                  sanitize(call?.arguments?.title) ??
                  // Some models answer in prose despite the instruction; a single
                  // short line is still a usable title.
                  sanitize(
                    response.content
                      .filter((c) => c.type === "text")
                      .map((c) => c.text)
                      .join(" ")
                      .split("\n")[0],
                  );
                if (title) return title;
              } catch {
                // Auth, quota, capacity, network: try the next candidate.
              }
            }
            return undefined;
          }

          // The first user message is the durable objective of a resumed
          // conversation, exactly like the opening prompt of a fresh one.
          function firstUserMessageText(ctx: ExtensionContext): string | undefined {
            try {
              for (const entry of ctx.sessionManager.getEntries()) {
                if (entry.type !== "message") continue;
                const message = entry.message;
                if (message?.role !== "user") continue;
                const content = message.content;
                const text =
                  typeof content === "string"
                    ? content
                    : Array.isArray(content)
                      ? content
                        .filter((c) => c?.type === "text")
                        .map((c) => c.text)
                        .join("\n")
                      : "";
                const trimmed = text.trim();
                if (trimmed) return trimmed;
              }
            } catch {
              // Swallow; an untitled resume is never worth disturbing the session.
            }
            return undefined;
          }

          // Fires for startup, /new, /resume, and /reload. The free path (pi's own
          // session name, set here or on another system) always wins; the paid path
          // runs only when /resume lands in an unnamed conversation.
          pi.on("session_start", (event, ctx) => {
            let sessionId = "";
            try {
              sessionId = ctx.sessionManager.getSessionId() ?? "";
            } catch {
              // Swallow.
            }

            try {
              const existing = sanitize(ctx.sessionManager.getSessionName());
              if (existing) {
                if (!namedSessions.has(sessionId)) {
                  namedSessions.add(sessionId);
                  report(existing);
                }
                return;
              }
            } catch {
              // Swallow.
            }

            if (event.reason !== "resume") return;
            if (namedSessions.has(sessionId)) return;
            namedSessions.add(sessionId);

            const prompt = firstUserMessageText(ctx);
            if (!prompt) return;

            // Detached on purpose: naming must never delay the resumed session.
            void (async () => {
              try {
                const title = await generate(prompt.slice(0, PROMPT_BUDGET), ctx);
                if (title) report(title);
              } catch {
                // Swallow.
              }
            })();
          });

          // A /name in this very session retitles the agent immediately, for free.
          pi.on("session_info_changed", (event) => {
            const title = sanitize(event.name);
            if (title) report(title);
          });

          // The opening prompt is the durable objective.
          // Fire once per process and never again.
          pi.on("before_agent_start", (event, ctx) => {
            if (!wanted || done) return;
            const prompt = (event.prompt ?? "").trim();
            if (!prompt) return;
            done = true;

            // Detached on purpose: naming must never delay the agent's first turn.
            void (async () => {
              try {
                const title = await generate(prompt.slice(0, PROMPT_BUDGET), ctx);
                if (title) report(title);
              } catch {
                // Swallow.
              }
            })();
          });
        }

        """#
}
