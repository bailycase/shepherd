// The pinned engine's image references: `get_messages` with `images: "refs"` names each saved image by its
// SHA-256, size and pixel dimensions instead of carrying its bytes, and `get_image` returns the bytes by hash.
// Run: PI_PACKAGE_DIR=.build/pi-engine/Resources/pi-engine node --test Tests/Extensions/history-images.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { withPi } from "./fixtures/pi-rpc-harness.mjs";

// Headers are all the engine reads; it never decodes pixels.
const png = Buffer.concat([Buffer.from("89504e470d0a1a0a0000000d49484452", "hex"), Buffer.from([0, 0, 1, 44, 0, 0, 0, 200]), Buffer.alloc(16)]);
const gif = Buffer.concat([Buffer.from("GIF89a", "latin1"), Buffer.from([7, 0, 9, 0]), Buffer.alloc(8)]);
const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 4, 0, 0, 0xff, 0xc0, 0, 11, 8, 0, 48, 0, 64, 1, 1, 0x11, 0, 0, 0, 0]);
const webp = Buffer.concat([Buffer.from("RIFF\0\0\0\0WEBPVP8X", "latin1"), Buffer.alloc(8), Buffer.from([99, 0, 0, 49, 0, 0]), Buffer.alloc(4)]);
const images = [
  { mimeType: "image/png", bytes: png, width: 300, height: 200 },
  { mimeType: "image/gif", bytes: gif, width: 7, height: 9 },
  { mimeType: "image/jpeg", bytes: jpeg, width: 64, height: 48 },
  { mimeType: "image/webp", bytes: webp, width: 100, height: 50 },
  // Bytes that are not the type the block says have no dimensions.
  { mimeType: "image/jpeg", bytes: png, width: 0, height: 0 },
];
const sha = bytes => createHash("sha256").update(bytes).digest("hex");

test("history names saved images by hash and get_image returns their bytes", { timeout: 60000 }, async t => {
  await withPi(t, {}, async pi => {
    // A saved session, as a long design thread's renders are: pi keeps tool images byte for byte.
    const timestamp = new Date().toISOString(), sessionPath = path.join(pi.dir, "sessions", "images.jsonl");
    const rows = [
      { type: "session", version: 3, id: "images", timestamp, cwd: pi.work },
      { type: "message", id: "u", parentId: null, timestamp, message: { role: "user", content: [{ type: "text", text: "look" }], timestamp: 1 } },
      { type: "message", id: "r", parentId: "u", timestamp, message: { role: "toolResult", toolCallId: "c", toolName: "render", isError: false, timestamp: 2,
        content: [{ type: "text", text: "rendered" }, ...images.map(i => ({ type: "image", mimeType: i.mimeType, data: i.bytes.toString("base64") }))] } },
    ];
    fs.mkdirSync(path.dirname(sessionPath), { recursive: true });
    fs.writeFileSync(sessionPath, rows.map(r => JSON.stringify(r)).join("\n") + "\n");
    assert.equal((await pi.request({ type: "switch_session", sessionPath })).success, true);

    const inline = (await pi.request({ type: "get_messages", history: true })).data.messages;
    const saved = inline.findIndex(m => m.role === "toolResult");
    assert.equal(inline[saved].content.filter(b => b.type === "image" && b.data).length, images.length, "without refs the bytes stay inline");

    const reply = await pi.request({ type: "get_messages", history: true, images: "refs" });
    const blocks = reply.data.messages[saved].content.filter(b => b.type === "image");
    assert.deepEqual(blocks, images.map(i => ({ type: "image", mimeType: i.mimeType, sha256: sha(i.bytes), byteCount: i.bytes.length, width: i.width, height: i.height })));
    assert.deepEqual(reply.data.messages.filter((_, i) => i !== saved), inline.filter((_, i) => i !== saved), "messages without images are unchanged");

    const found = await pi.request({ type: "get_image", sha256: sha(jpeg) });
    assert.deepEqual(found.data, { mimeType: "image/jpeg", data: jpeg.toString("base64") });
    const missing = await pi.request({ type: "get_image", sha256: "0".repeat(64) });
    assert.equal(missing.success, false);
    assert.equal(missing.error, "image_not_found");
  });
});
