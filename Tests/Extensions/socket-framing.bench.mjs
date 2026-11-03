// Run serially, outside builds: node Tests/Extensions/socket-framing.bench.mjs
// Same payloads/sampling as the F10 baseline, executing the actual browser handler and helper.
import fs from "node:fs";
import assert from "node:assert/strict";
import { textLines } from "../../Extensions/shepherd-lines.mjs";
const source = fs.readFileSync(new URL("../../Extensions/shepherd-browser.ts", import.meta.url), "utf8");
const start = source.indexOf("      const read = textLines(");
const end = source.indexOf('      s.on("error"', start);
assert(start >= 0 && end > start);
const body = source.slice(start, end).replaceAll(": string", "").replace(" as Reply", "");
const create = new Function("textLines", "s", "pending", "MAX_REPLY_CHARS", `let socket = s; ${body}`);
for (const bytes of [2 * 1024 * 1024, 8 * 1024 * 1024]) {
  const line = JSON.stringify({ id: 1, type: "browserResult", data: "a".repeat(bytes - 100) }) + "\n";
  for (const chunkSize of [1024, 65536, line.length]) {
    const chunks = [];
    for (let i = 0; i < line.length; i += chunkSize) chunks.push(line.slice(i, i + chunkSize));
    const samples = [];
    for (let i = 0; i < 4; i++) {
      let received = 0, handler;
      const pending = new Map([[1, { resolve: reply => { assert.equal(reply.data.length, bytes - 100); received++; } }]]);
      create(textLines, { destroy: error => { throw error; }, on: (event, fn) => { assert.equal(event, "data"); handler = fn; } }, pending, 16 * 1024 * 1024);
      const start = performance.now();
      for (const chunk of chunks) handler(chunk);
      const elapsed = performance.now() - start;
      assert.equal(received, 1); assert.equal(pending.size, 0);
      if (i) samples.push(elapsed);
    }
    console.log(JSON.stringify({ bytes: line.length, chunkSize, samplesMS: samples, medianMS: [...samples].sort((a, b) => a - b)[1], node: process.version }));
  }
}
