// Load explicitly with pi -e /absolute/path/to/native-ui-widgets.ts.
// This example is not installed by Shepherd and never changes pi configuration.
import { randomUUID } from "node:crypto";

function nativeRequest(pi, payload): Promise<any> {
  if (typeof pi.events?.on !== "function" || typeof pi.events?.emit !== "function") return Promise.resolve(undefined);
  return new Promise((resolve) => {
    const requestID = randomUUID();
    let off, timer, settled = false;
    const finish = (reply) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { off?.(); } catch {}
      resolve(reply);
    };
    try {
      off = pi.events.on("shepherd:native-ui:response", (reply) => {
        if (reply?.version === 1 && reply.requestID === requestID) finish(reply);
      });
      timer = setTimeout(() => finish(undefined), 500);
      timer.unref?.();
      pi.events.emit("shepherd:native-ui:request", { version: 1, requestID, ...payload });
    } catch { finish(undefined); }
  });
}

export default function nativeWidgetExample(pi) {
  pi.registerCommand("native-widget-demo", {
    description: "Show display-only native widgets, with terminal fallback",
    handler: async (_, ctx) => {
      const status = "Focused checks passed";
      const notes = "Plain text only: **not bold**\nNo callbacks or controls.";
      // Keep Terminal useful even when Shepherd is displaying Native on another device.
      // Publish each fallback once, not again if the event bus rejects or times out.
      ctx.ui.setStatus("example.build", status);
      ctx.ui.setWidget("example.notes", notes.split("\n"));
      for (const item of [
        { key: "build", kind: "status", title: "Build status", text: status },
        { key: "notes", kind: "text", title: "Review notes", text: notes },
      ]) {
        const reply = await nativeRequest(pi, { type: "set", namespace: "example.checks", ...item });
        if (reply?.ok === false) ctx.ui.notify(`Native display rejected: ${reply.error.message}`, "warning");
        // Missing bridge or unknown outcome: leave Terminal intact. Do not retry or append.
      }
    },
  });
}
