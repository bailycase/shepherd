import Foundation
import ShepherdProtocol

/// Installs the per-session pi extension that lets an agent open a native
/// diff-review pane and wait for the user's formatted review.
enum ReviewExtension {
    static func installedPath() throws -> String {
        let directory = ShepherdPaths.supportDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("shepherd-review.ts")
        let source = Data(extensionSource.utf8)
        if (try? Data(contentsOf: url)) != source {
            try source.write(to: url, options: .atomic)
        }
        return url.path
    }

    /// Extensions/shepherd-review.ts is canonical; keep this byte-identical.
    static let extensionSource = #"""
// @ts-nocheck -- loaded by pi/jiti; this project intentionally has no Node TS workspace.
// Shepherd diff review extension: readies a native diff review in the side pane's Changes
// tab (the user opens it; nothing opens by itself). The user's review arrives later as a
// normal prompt message, so the tool does not block.
// Inert unless Shepherd's env is present.
import * as net from "node:net";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const REQUEST_TIMEOUT_MS = 15_000;

interface Reply {
  type: string;
  id: number;
  code?: string;
  message?: string;
  text?: string;
}

export default function shepherdReview(pi: ExtensionAPI) {
  const agentID = process.env.SHEPHERD_AGENT_ID ?? "";
  const socketPath = process.env.SHEPHERD_SOCKET ?? "";
  if (!agentID || !socketPath) return;

  // ---- socket client (request/reply, NDJSON) -------------------------------

  let socket: net.Socket | undefined;
  let connecting: Promise<net.Socket> | undefined;
  let stopped = false;
  let nextID = 1;
  const pending = new Map<number, { socket: net.Socket; resolve: (reply: Reply) => void }>();

  function connect(): Promise<net.Socket> {
    if (stopped) return Promise.reject(new Error("Shepherd session ended"));
    if (connecting) return connecting;
    if (socket && !socket.destroyed) return Promise.resolve(socket);
    connecting = new Promise((resolve, reject) => {
      const s = net.createConnection(socketPath);
      socket = s;
      let buffer = "";
      s.setEncoding("utf8");
      s.on("connect", () => {
        socket = s;
        resolve(s);
      });
      s.on("data", (chunk: string) => {
        if (socket !== s) return;
        buffer += chunk;
        let index = buffer.indexOf("\n");
        while (index >= 0) {
          const line = buffer.slice(0, index);
          buffer = buffer.slice(index + 1);
          if (line.trim().length > 0) {
            try {
              const reply = JSON.parse(line) as Reply;
              const resolver = pending.get(reply.id);
              if (resolver) {
                pending.delete(reply.id);
                resolver.resolve(reply);
              }
            } catch {
              // Ignore undecodable lines; the request times out.
            }
          }
          index = buffer.indexOf("\n");
        }
      });
      s.on("error", (error) => { reject(error); });
      s.on("close", () => {
        reject(new Error("Shepherd closed the connection"));
        if (socket === s) socket = undefined;
        // An old socket closing must not fail requests on its replacement.
        for (const [id, resolver] of pending) {
          if (resolver.socket !== s) continue;
          pending.delete(id);
          resolver.resolve({ type: "error", id, code: "disconnected", message: "Shepherd closed the connection" });
        }
      });
      s.unref();
    }).finally(() => { connecting = undefined; });
    return connecting;
  }

  // Throws on failure: pi marks a tool errored only when execute throws.
  async function request(payload: Record<string, unknown>): Promise<Reply> {
    const s = await connect();
    if (stopped || s.destroyed) throw new Error("Shepherd closed the connection");
    const id = nextID++;
    const reply = await new Promise<Reply>((resolve) => {
      const timer = setTimeout(() => {
        pending.delete(id);
        resolve({ type: "error", id, code: "timeout", message: "Shepherd did not reply in time" });
      }, REQUEST_TIMEOUT_MS);
      timer.unref?.();

      pending.set(id, { socket: s, resolve: (received) => {
        clearTimeout(timer);
        resolve(received);
      } });
      s.write(JSON.stringify({ ...payload, id, agentID }) + "\n");
    });

    if (reply.type === "error") {
      throw new Error(
        `${reply.message ?? "review request failed"}${reply.code ? ` (${reply.code})` : ""}`,
      );
    }
    return reply;
  }

  function text(body: string) {
    return { content: [{ type: "text" as const, text: body }] };
  }

  // Deferred (docs/context-budget.md): with SHEPHERD_DEFER_TOOLS=1 pi leaves the tool out of every request until the model loads it
  // with tool_search, and the status extension keeps tool_search reachable and says in the prompt that it exists. A deferred tool
  // has no promptSnippet: that line would only repeat the search result, and loading the tool would send the whole tool list again.
  const DEFER = process.env.SHEPHERD_DEFER_TOOLS === "1";
  // The description is the clause of the one prompt line that says the tool exists; the instructions are words tool_search matches.
  const NAMESPACE = {
    name: "shepherd_review",
    description: "a diff review of the changes, readied in the Changes tab",
    instructions: "Ready a review of the git diff for the user in Shepherd's Changes tab.",
  };

  pi.registerTool({
    name: "review_diff",
    label: "Review Diff",
    description:
      "Ready a native diff review of the git diff in Shepherd's side pane (its Changes tab). Returns immediately; " +
      "the pane does not open by itself: Shepherd marks it, and the user opens it when they choose. " +
      "Their line comments and summary arrive later as a regular message when they submit. " +
      "Use cwd to review another repository or worktree without changing the agent's directory. " +
      "Reuses the agent's review and reloads it. " +
      "Changing cwd discards the previous review comments and summary. Use before finalizing substantial changes.",
    promptSnippet: DEFER ? undefined : "Ready a native diff review in Shepherd's Changes tab; pass cwd to target another repository or worktree",
    ...(DEFER ? { exposure: "deferred" as const, namespace: NAMESPACE } : {}),
    parameters: Type.Object({
      reference: Type.Optional(
        Type.String({
          description:
            "Git commit, range, or branch to diff, such as 'master..HEAD' or a commit hash; " +
            "omit for the working tree versus HEAD",
        }),
      ),
      cwd: Type.Optional(
        Type.String({
          description:
            "Repository or worktree directory to review, such as '~/src/project-worktree'; " +
            "omit to use the agent's directory, including when a review is already open",
        }),
      ),
    }),
    async execute(_toolCallId, params) {
      const reply = await request({ type: "requestReview", cwd: params.cwd, reference: params.reference });
      if (typeof reply.text !== "string") throw new Error("Shepherd review reply did not include text");
      return text(reply.text);
    },
  });

  pi.on("session_shutdown", () => {
    stopped = true;
    try {
      socket?.destroy();
    } catch {
      // Swallow; the process is going away.
    }
  });
}

"""#
}
