// Shepherd: image references in RPC history. A long design thread saves hundreds of rendered
// boards; `get_messages` with every image's base64 inline ran past a quarter gigabyte in one
// JSONL record. With `images: "refs"` each image block carries its SHA-256, size and pixel
// dimensions instead of its bytes, and `get_image` returns one image's bytes by that hash.
import { createHash } from "node:crypto";

// Image block → its description. Saved history reuses the same block objects between calls, so
// each image is decoded and hashed once per session load, not on every history read.
const described = new WeakMap();

function dimensions(mimeType, b) {
    try {
        if (mimeType === "image/png" && b.length >= 24 && b.readUInt32BE(0) === 0x89504e47 && b.toString("latin1", 12, 16) === "IHDR")
            return { width: b.readUInt32BE(16), height: b.readUInt32BE(20) };
        if (mimeType === "image/gif" && b.length >= 10 && b.toString("latin1", 0, 4) === "GIF8")
            return { width: b.readUInt16LE(6), height: b.readUInt16LE(8) };
        if (mimeType === "image/webp" && b.length >= 30 && b.toString("latin1", 0, 4) === "RIFF" && b.toString("latin1", 8, 12) === "WEBP") {
            const chunk = b.toString("latin1", 12, 16);
            if (chunk === "VP8 ") return { width: b.readUInt16LE(26) & 0x3fff, height: b.readUInt16LE(28) & 0x3fff };
            if (chunk === "VP8L") return { width: 1 + (((b[22] & 0x3f) << 8) | b[21]), height: 1 + (((b[24] & 0x0f) << 10) | (b[23] << 2) | (b[22] >> 6)) };
            if (chunk === "VP8X") return { width: 1 + b.readUIntLE(24, 3), height: 1 + b.readUIntLE(27, 3) };
            return undefined;
        }
        if (mimeType === "image/jpeg" && b.length >= 4 && b[0] === 0xff && b[1] === 0xd8) {
            for (let i = 2; i + 9 < b.length;) {
                if (b[i] !== 0xff) return undefined;
                const marker = b[i + 1];
                if (marker === 0xff) { i++; continue; }
                if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) { i += 2; continue; }
                // SOF0-SOF15, less DHT (C4), JPG (C8) and DAC (CC).
                if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc)
                    return { width: b.readUInt16BE(i + 7), height: b.readUInt16BE(i + 5) };
                i += 2 + b.readUInt16BE(i + 2);
            }
        }
    } catch { /* a truncated header has no dimensions */ }
    return undefined;
}

function describe(block) {
    let meta = described.get(block);
    if (!meta) {
        const bytes = Buffer.from(block.data, "base64");
        const size = dimensions(block.mimeType, bytes);
        meta = { sha256: createHash("sha256").update(bytes).digest("hex"), byteCount: bytes.length, width: size?.width ?? 0, height: size?.height ?? 0 };
        described.set(block, meta);
    }
    return meta;
}

const isImage = block => block?.type === "image" && typeof block.data === "string";

/** `messages` with every image's bytes replaced by `{ sha256, byteCount, width, height }`. Width and height are 0 when the
 * header is not one of `mimeType`'s. Messages without images are returned as they are. */
export function historyImageRefs(messages) {
    return messages.map(message => {
        if (!Array.isArray(message?.content) || !message.content.some(isImage)) return message;
        return { ...message, content: message.content.map(block => {
            if (!isImage(block)) return block;
            const { data, ...rest } = block;
            return { ...rest, ...describe(block) };
        }) };
    });
}

/** The first image in `messages` whose bytes hash to `sha256`, as `{ mimeType, data }`. */
export function findHistoryImage(messages, sha256) {
    for (const message of messages) {
        if (!Array.isArray(message?.content)) continue;
        for (const block of message.content) {
            if (isImage(block) && describe(block).sha256 === sha256) return { mimeType: block.mimeType, data: block.data };
        }
    }
    return undefined;
}
