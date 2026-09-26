// @ts-nocheck -- loaded by pi/jiti; this project intentionally has no Node TS workspace.
// Shepherd instructions extension: hands pi the root instructions Shepherd keeps in its support
// directory (Settings ▸ Instructions), so the user's own ~/.pi/agent is never written.
// AGENTS.md joins pi's context files right after pi's own root AGENTS.md, before the parent
// folders' and the repo's, so the more specific files still win; APPEND_SYSTEM.md is added to
// pi's system prompt after pi's own. Both are read when a session starts: a running session
// keeps the version it started with. Inert without SHEPHERD_INSTRUCTIONS_DIR; every failure is
// swallowed so instructions can never break a turn.
//
// While Settings ▸ Experiments ▸ Suggested instructions is on for this agent,
// SHEPHERD_SUGGEST_FILES names the files it may suggest for, and suggest_instruction drafts one
// line for one of them over the Shepherd socket. The line waits for the user; nothing is written
// until they add it.
import * as fs from "node:fs";
import * as net from "node:net";
import * as os from "node:os";
import * as path from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const ROOT_FILES = ["AGENTS.md", "APPEND_SYSTEM.md"];
const REQUEST_TIMEOUT_MS = 10_000;

function readText(file: string): string {
  try {
    return fs.readFileSync(file, "utf8").trim();
  } catch {
    return "";
  }
}

// pi's agent directory, where its own root AGENTS.md lives.
function piAgentDirectory(): string {
  const configured = process.env.PI_CODING_AGENT_DIR ?? "";
  if (!configured) return path.join(os.homedir(), ".pi", "agent");
  return path.resolve(configured.replace(/^~(?=$|\/)/, os.homedir()));
}

// One request over its own connection, answered by one reply line. Never rejects: a failure is
// an error reply.
function request(socketPath: string, payload: Record<string, unknown>): Promise<Record<string, unknown>> {
  return new Promise((resolve) => {
    let buffer = "";
    let settled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const socket = net.createConnection(socketPath);
    const finish = (reply: Record<string, unknown>) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      socket.destroy();
      resolve(reply);
    };
    timer = setTimeout(() => finish({ type: "error", code: "timeout", message: "Shepherd did not reply in time" }), REQUEST_TIMEOUT_MS);
    timer.unref?.();
    socket.setEncoding("utf8");
    socket.on("connect", () => socket.write(JSON.stringify({ ...payload, id: 1 }) + "\n"));
    socket.on("data", (chunk: string) => {
      buffer += chunk;
      const index = buffer.indexOf("\n");
      if (index < 0) return;
      try {
        finish(JSON.parse(buffer.slice(0, index)));
      } catch {
        finish({ type: "error", code: "protocol", message: "Shepherd sent a reply it could not read" });
      }
    });
    socket.on("error", (error) => finish({ type: "error", code: "unavailable", message: `Shepherd is not reachable: ${error.message}` }));
    socket.on("close", () => finish({ type: "error", code: "disconnected", message: "Shepherd closed the connection" }));
    socket.unref();
  });
}

function registerSuggestions(pi: ExtensionAPI) {
  const agentID = process.env.SHEPHERD_AGENT_ID ?? "";
  const socketPath = process.env.SHEPHERD_SOCKET ?? "";
  const files = (process.env.SHEPHERD_SUGGEST_FILES ?? "").split(",").map((name) => name.trim())
    .filter((name) => ROOT_FILES.includes(name));
  if (!agentID || !socketPath || files.length === 0 || typeof pi.registerTool !== "function") return;

  const outcomes: Record<string, (file: string) => string> = {
    waiting: (file) => `Suggested for ${file}. The user decides whether to add it; nothing is written until they do.`,
    alreadyWaiting: () => "That line is already waiting for the user.",
    dismissed: () => "The user dismissed that line before, so it is not suggested again.",
    inFile: (file) => `${file} already has that line.`,
  };
  const parameters: Record<string, unknown> = {
    line: Type.String({
      description: "The one line to add, a short imperative Markdown list item, such as '- Ask for join keys before adding an event.'",
    }),
    reason: Type.String({ description: "What happened that taught it, in one sentence the user reads before deciding" }),
  };
  if (files.length > 1) {
    parameters.file = Type.Optional(Type.Union(files.map((name) => Type.Literal(name)), {
      description: "AGENTS.md for how to work (the default); APPEND_SYSTEM.md only for a rule that must override everything else",
    }));
  }

  pi.registerTool({
    name: "suggest_instruction",
    label: "Suggest Instruction",
    description:
      `Suggest one line for the user's root instructions (${files.join(" or ")}) after learning something the hard way: ` +
      "a re-run, a failed check, or the user correcting you. The line must hold in every repository, not only this one " +
      "(a repository's own lessons belong in its AGENTS.md). Nothing is written: the user reads the line and your reason, " +
      "then adds it, edits it first, or dismisses it. Suggest rarely, one line at a time.",
    promptSnippet: "Suggest one line for the user's root instructions after learning something the hard way",
    parameters: Type.Object(parameters),
    async execute(_toolCallId, params) {
      const file = files.includes(params.file) ? params.file : files[0];
      const reply = await request(socketPath, {
        type: "suggestInstruction", agentID, line: String(params.line ?? ""), reason: String(params.reason ?? ""), file,
      });
      const text = reply.type === "suggestion" ? outcomes[String(reply.outcome)]?.(file) : undefined;
      if (text === undefined) {
        const code = typeof reply.code === "string" ? ` (${reply.code})` : "";
        throw new Error(`${typeof reply.message === "string" ? reply.message : "Shepherd did not take the suggestion"}${code}`);
      }
      return { content: [{ type: "text" as const, text }] };
    },
  });
}

export default function shepherdInstructions(pi: ExtensionAPI) {
  registerSuggestions(pi);
  const directory = process.env.SHEPHERD_INSTRUCTIONS_DIR ?? "";
  if (!directory) return;
  const agentsPath = path.join(directory, "AGENTS.md");
  let agents = "";
  let append = "";

  pi.on("session_start", () => {
    agents = readText(agentsPath);
    append = readText(path.join(directory, "APPEND_SYSTEM.md"));
  });

  pi.on("before_agent_start", (event) => {
    try {
      const options = event?.systemPromptOptions;
      if (!options) return;
      const files = options.contextFiles;
      if (agents && Array.isArray(files) && !files.some((file) => file?.path === agentsPath)) {
        const root = piAgentDirectory();
        const piRoot = files.findIndex((file) => typeof file?.path === "string" && path.dirname(file.path) === root);
        files.splice(piRoot + 1, 0, { path: agentsPath, content: agents });
      }
      if (append) {
        options.appendSystemPrompt = options.appendSystemPrompt ? `${options.appendSystemPrompt}\n\n${append}` : append;
      }
    } catch {
      // Instructions are never worth a failed turn.
    }
  });
}
