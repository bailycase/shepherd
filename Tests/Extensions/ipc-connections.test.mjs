// Actual extension tools over a scratch Unix socket; no pi session or provider.
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as net from "node:net";
import * as os from "node:os";
import * as path from "node:path";
import { once } from "node:events";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const pkg = process.env.PI_PACKAGE_DIR;
if (!pkg) throw Error("Set PI_PACKAGE_DIR");
const { createJiti } = createRequire(path.join(pkg, "package.json"))("jiti");
const jiti = createJiti(import.meta.url, { alias: { typebox: path.join(pkg, "node_modules/typebox/build/index.mjs") } });

for (const [extension, tool, params, answer] of [
  ["review", "review_diff", {}, (id) => ({ type: "ok", text: `answer-${id}` })],
  ["design-refs", "design_get", { ref: "shepherd-design-ref://local/d1/A.dc.html", what: "summary" },
    (id) => ({ type: "designReference", answer: { text: `answer-${id}`, files: [] } })],
  ["design", "design_read", { path: "A.dc.html" },
    (id) => ({ type: "designBoard", board: { path: "A.dc.html", revision: 1, source: `answer-${id}`, sha256: "fixture" } })],
]) {
  test(`${extension}: parallel first calls share a connection and reconnect drops partial old frames`, { timeout: 5000 }, async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sh-ipc-"));
    const socketPath = path.join(dir, "s");
    const sockets = [], frames = [];
    let received;
    const server = net.createServer((s) => {
      sockets.push(s);
      let buffer = "";
      s.setEncoding("utf8");
      s.on("data", (chunk) => {
        buffer += chunk;
        while (buffer.includes("\n")) {
          const end = buffer.indexOf("\n");
          frames.push({ socket: s, frame: JSON.parse(buffer.slice(0, end)) });
          buffer = buffer.slice(end + 1);
          received?.();
        }
      });
      s.on("error", () => {});
    });
    await new Promise((resolve) => server.listen(socketPath, resolve));
    const handlers = new Map(), tools = new Map();
    const env = { SHEPHERD_AGENT_ID: "fixture", SHEPHERD_SOCKET: socketPath,
      SHEPHERD_DESIGN_ID: extension === "design" ? "d1" : undefined, SHEPHERD_DESIGN_REFS: "granted" };
    const saved = Object.fromEntries(Object.keys(env).map((key) => [key, process.env[key]]));
    const set = (values) => { for (const [key, value] of Object.entries(values)) value === undefined ? delete process.env[key] : process.env[key] = value; };
    set(env);
    try {
      const { default: install } = await jiti.import(path.join(root, `Extensions/shepherd-${extension}.ts`));
      install({ on: (name, fn) => handlers.set(name, fn), registerTool: (t) => tools.set(t.name, t) });
    } finally { set(saved); }
    const waitFrames = async (count) => { while (frames.length < count) await new Promise((resolve) => { received = resolve; }); };
    const call = () => tools.get(tool).execute("fixture", params);
    const reply = async ({ socket, frame }) => {
      const line = JSON.stringify({ id: frame.id, ...answer(frame.id) }) + "\n";
      socket.write(line.slice(0, 8));
      await new Promise((resolve) => setImmediate(resolve));
      socket.write(line.slice(8));
    };
    try {
      const first = call(), second = call();
      const replies = Promise.all([first, second]);
      replies.catch(() => {}); // Cleanup also rejects them when a connection assertion fails.
      await waitFrames(2);
      assert.equal(sockets.length, 1);
      await reply(frames[1]); await reply(frames[0]);
      const results = await replies;
      results.forEach((r, i) => assert.match(r.content[0].text, new RegExp(`answer-${frames[i].frame.id}`)));
      const interrupted = call();
      const rejected = assert.rejects(interrupted, /closed|disconnected/);
      await waitFrames(3);
      sockets[0].write('{"id":');
      sockets[0].end();
      await rejected;
      const reconnected = call();
      await waitFrames(4);
      assert.equal(sockets.length, 2);
      await reply(frames[3]);
      assert.match((await reconnected).content[0].text, /answer-/);
      const closed = once(sockets[1], "close");
      handlers.get("session_shutdown")();
      await closed;
    } finally {
      handlers.get("session_shutdown")?.();
      for (const socket of sockets) socket.destroy();
      await new Promise((resolve) => server.close(resolve));
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
}
