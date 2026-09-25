// @ts-nocheck -- loaded by pi/jiti; this project intentionally has no Node TS workspace.
// Shepherd instructions extension: hands pi the root instructions Shepherd keeps in its support
// directory (Settings ▸ Instructions), so the user's own ~/.pi/agent is never written.
// AGENTS.md joins pi's context files right after pi's own root AGENTS.md, before the parent
// folders' and the repo's, so the more specific files still win; APPEND_SYSTEM.md is added to
// pi's system prompt after pi's own. Both are read when a session starts: a running session
// keeps the version it started with. Inert without SHEPHERD_INSTRUCTIONS_DIR; every failure is
// swallowed so instructions can never break a turn.
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

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

export default function shepherdInstructions(pi: ExtensionAPI) {
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
