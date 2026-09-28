// @ts-nocheck -- loaded by pi/jiti; this project intentionally has no Node TS workspace.
// Shepherd design references extension (docs/designs.md › Design references):
// - design_get(ref, what) reads the copy of a design piece (a whole design, a board, or one
//   element of it) that Shepherd kept when the user sent it to this thread. It answers only from
//   those copies, never the design as it is now: a newer version reaches the thread only when the
//   user sends it. Everything the design's files say comes back fenced as data; pictures and
//   pages come back as the copy's files, never megabytes over the socket.
// - design_note(ref, text) leaves a short note on a board or element this thread was sent
//   ("Implemented in #142 on agent/checkout-funnel."), shown on the canvas as the thread's pin.
//
// The tools are registered only once the thread holds a reference, so a thread without one
// carries nothing of them in its prompt: at load when SHEPHERD_DESIGN_REFS is "granted" (the
// thread held one when pi started), else the first time a message arrives with a design-ref
// fence. Inert without SHEPHERD_DESIGN_REFS, and in a design's own agent (SHEPHERD_DESIGN_ID).
// Nothing here throws into pi except a tool's own failure, and the socket never keeps pi alive.
import * as fs from "node:fs";
import * as net from "node:net";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const REQUEST_TIMEOUT_MS = 60_000;
// What pi is handed inline as an image; a larger PNG is left as its file.
const MAX_INLINE_IMAGE_BYTES = 4_500_000;
// A note is one short paragraph; Shepherd refuses a longer one.
const MAX_NOTE_LENGTH = 500;
const ASPECTS = ["summary", "image", "html", "element", "tokens", "changes"];
// The fence Shepherd puts ahead of a message that hands this thread design references.
const FENCE = /(^|\n)<design-ref nonce="[0-9a-f]{12}">\n/;

interface Answer {
  text: string;
  files?: string[];
  image?: string;
  lookedAt?: unknown;
}

interface Note {
  id: string;
  board: string;
  element?: string;
  revision: number;
  text: string;
}

interface Reply {
  type: string;
  id: number;
  code?: string;
  message?: string;
  answer?: Answer;
  note?: Note;
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
        "Read the copy of a design piece the user sent you in this thread (a design-ref record's ref): what it was when sent, " +
        "never the design as it is now. what: summary (label, size, the revision it was sent at, other versions sent here), " +
        "image (a PNG at twice its size; a whole design's: each board's), html (the board as a standalone page), " +
        "element (the element's markup as drawn and its computed styles), " +
        "tokens (the design system tokens it uses, with the source file and line of each in the project), " +
        "changes (what changed from the previous version of the piece sent to this thread). " +
        "Read only; a newer version reaches you only when the user sends it.",
      promptSnippet: "Read a design piece sent to this thread: summary, image, html, element, tokens or changes",
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
        return { content, details: { files: answer.files ?? [], lookedAt: answer.lookedAt } };
      },
    });
    pi.registerTool({
      name: "design_note",
      label: "Design Note",
      description:
        "Leave a short note on a board or element of a design the user sent you in this thread (a design-ref record's ref), " +
        "shown to the user on the design's canvas as this thread's pin: say what you did with it, e.g. " +
        "\"Implemented in #142 on agent/checkout-funnel.\" Plain text, one short paragraph (at most 500 characters). " +
        "A new note on the same piece replaces your last. Leave one when the work is done, not as you go.",
      promptSnippet: "Leave a short note on a design piece sent to this thread, shown on its canvas",
      parameters: Type.Object({
        ref: Type.String({ description: "The ref of a board or element design-ref record in this thread" }),
        text: Type.String({ description: "The note: plain text, at most 500 characters", maxLength: MAX_NOTE_LENGTH }),
      }),
      async execute(_toolCallId, params) {
        const reply = await request({ type: "designNote", reference: String(params.ref ?? ""), text: String(params.text ?? "") });
        const note = reply.note;
        if (!note || typeof note.text !== "string") throw new Error("Shepherd's design_note reply had no note");
        return {
          content: [{ type: "text", text: `Left a note on ${String(params.ref ?? "")}: ${note.text}` }],
          details: { note: note.id },
        };
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
    stopped = true;
    try {
      socket?.destroy();
    } catch {
      // Swallow; the process is going away.
    }
  });
}
