// @ts-nocheck -- loaded by pi/jiti; this project intentionally has no Node TS workspace.
// Shepherd design references extension: design_get(ref, what) reads a piece of a design (a board,
// or one element of it) that the user handed this thread with a message (docs/designs.md ›
// Design references). Shepherd answers only for pieces this thread was handed, read only, and
// fences everything the design's files say as data. Images and pages come back as files in the
// drop folder, never megabytes over the socket.
//
// The tool is registered only once the thread holds a reference, so a thread without one carries
// nothing of it in its prompt: at load when SHEPHERD_DESIGN_REFS is "granted" (the thread held one
// when pi started), else the first time a message arrives with a design-ref fence. Inert without
// SHEPHERD_DESIGN_REFS, and in a design's own agent (SHEPHERD_DESIGN_ID). Nothing here throws into
// pi except a tool's own failure, and the socket never keeps pi alive.
import * as fs from "node:fs";
import * as net from "node:net";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const REQUEST_TIMEOUT_MS = 60_000;
// What pi is handed inline as an image; a larger PNG is left as its file.
const MAX_INLINE_IMAGE_BYTES = 4_500_000;
const ASPECTS = ["summary", "image", "html", "element", "tokens", "changes"];
// The fence Shepherd puts ahead of a message that hands this thread design references.
const FENCE = /(^|\n)<design-ref nonce="[0-9a-f]{12}">\n/;

interface Answer {
  text: string;
  files?: string[];
  image?: string;
}

interface Reply {
  type: string;
  id: number;
  code?: string;
  message?: string;
  answer?: Answer;
}

/** Whether a message carries design references. */
export function carriesReferences(text: unknown): boolean {
  return typeof text === "string" && text.startsWith("The text between the design-ref markers") && FENCE.test(text);
}

export default function shepherdDesignRefs(pi: ExtensionAPI) {
  const agentID = process.env.SHEPHERD_AGENT_ID ?? "";
  const socketPath = process.env.SHEPHERD_SOCKET ?? "";
  const mode = process.env.SHEPHERD_DESIGN_REFS ?? "";
  if (!agentID || !socketPath || !mode || process.env.SHEPHERD_DESIGN_ID) return;

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
      throw new Error(`${reply.message ?? "design_get failed"}${reply.code ? ` (${reply.code})` : ""}`);
    }
    return reply;
  }

  // ---- the tool --------------------------------------------------------------

  let registered = false;

  function register() {
    if (registered) return;
    registered = true;
    pi.registerTool({
      name: "design_get",
      label: "Design Get",
      description:
        "Read a design piece the user handed you in this thread (a design-ref record's ref). " +
        "what: summary (label, size, revision, whether it changed since the reference), image (a PNG at twice its size), " +
        "html (the board as a standalone page), element (the element's markup as drawn and its computed styles), " +
        "tokens (the design system tokens it uses, with the source file and line of each in the project), " +
        "changes (what changed since the pinned revision). Read only; works for the references in this thread's messages.",
      promptSnippet: "Read a design piece handed to this thread: summary, image, html, element, tokens or changes",
      parameters: Type.Object({
        ref: Type.String({ description: "The ref of a design-ref record in this thread, e.g. shepherd-design-ref://local/…" }),
        what: Type.Union(ASPECTS.map((aspect) => Type.Literal(aspect)), { description: "What to read" }),
      }),
      async execute(_toolCallId, params) {
        const reply = await request({ type: "designGet", reference: String(params.ref ?? ""), what: String(params.what ?? "") });
        const answer = reply.answer;
        if (!answer || typeof answer.text !== "string") throw new Error("Shepherd's design_get reply had no answer");
        const content: Record<string, unknown>[] = [{ type: "text", text: answer.text }];
        if (typeof answer.image === "string") {
          try {
            const size = fs.statSync(answer.image).size;
            if (size <= MAX_INLINE_IMAGE_BYTES) {
              content.push({ type: "image", data: fs.readFileSync(answer.image).toString("base64"), mimeType: "image/png" });
            }
          } catch {
            // The path in the text still says where it is.
          }
        }
        return { content, details: { files: answer.files ?? [] } };
      },
    });
  }

  if (mode === "granted") register();

  pi.on("input", (event) => {
    try {
      if (!registered && carriesReferences(event?.text)) register();
    } catch {
      // Never into pi.
    }
    return undefined;
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
