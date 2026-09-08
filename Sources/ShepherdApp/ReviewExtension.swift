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
// Shepherd diff review extension: opens a native diff review pane. The user's
// review arrives later as a normal prompt message, so the tool does not block.
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
  let buffer = "";
  let nextID = 1;
  const pending = new Map<number, (reply: Reply) => void>();

  function connect(): Promise<net.Socket> {
    if (socket && !socket.destroyed) return Promise.resolve(socket);
    return new Promise((resolve, reject) => {
      const s = net.createConnection(socketPath);
      s.setEncoding("utf8");
      s.on("connect", () => {
        socket = s;
        resolve(s);
      });
      s.on("data", (chunk: string) => {
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
                resolver(reply);
              }
            } catch {
              // Ignore undecodable lines; the request times out.
            }
          }
          index = buffer.indexOf("\n");
        }
      });
      s.on("error", (error) => {
        socket = undefined;
        reject(error);
      });
      s.on("close", () => {
        socket = undefined;
        // Fail everything still waiting rather than hanging the agent.
        for (const [id, resolver] of pending) {
          pending.delete(id);
          resolver({ type: "error", id, code: "disconnected", message: "Shepherd closed the connection" });
        }
      });
      s.unref();
    });
  }

  // Throws on failure: pi marks a tool errored only when execute throws.
  async function request(payload: Record<string, unknown>): Promise<Reply> {
    const s = await connect();
    const id = nextID++;
    const reply = await new Promise<Reply>((resolve) => {
      const timer = setTimeout(() => {
        pending.delete(id);
        resolve({ type: "error", id, code: "timeout", message: "Shepherd did not reply in time" });
      }, REQUEST_TIMEOUT_MS);
      timer.unref?.();

      pending.set(id, (received) => {
        clearTimeout(timer);
        resolve(received);
      });
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

  pi.registerTool({
    name: "review_diff",
    label: "Review Diff",
    description:
      "Open a native diff review pane in Shepherd showing the git diff. Returns immediately; " +
      "the user's line comments and summary arrive later as a regular message when they submit. " +
      "Use before finalizing substantial changes.",
    promptSnippet: "Open a native diff review pane for the user",
    parameters: Type.Object({
      reference: Type.Optional(
        Type.String({
          description:
            "Git commit, range, or branch to diff, such as 'master..HEAD' or a commit hash; " +
            "omit for the working tree versus HEAD",
        }),
      ),
      cwd: Type.Optional(
        Type.String({ description: "Repository directory; defaults to the agent's directory" }),
      ),
    }),
    async execute(_toolCallId, params) {
      const reply = await request({ type: "requestReview", cwd: params.cwd, reference: params.reference });
      if (typeof reply.text !== "string") throw new Error("Shepherd review reply did not include text");
      return text(reply.text);
    },
  });

  pi.on("session_shutdown", () => {
    try {
      socket?.end();
    } catch {
      // Swallow; the process is going away.
    }
    socket = undefined;
  });
}

"""#
}
