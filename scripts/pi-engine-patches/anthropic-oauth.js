// OAuth request compatibility adapted from pi-anthropic-oauth v0.3.4:
// https://github.com/leohenon/pi-anthropic-oauth/tree/44efe694a3e81a62742cdb3e7ba9da858e191a81
// MIT License
// Copyright (c) 2026 Leo Henon
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
import { randomUUID } from "node:crypto";

const preamble = "You are an expert coding assistant operating inside pi, a coding agent harness. You help users by reading files, executing commands, editing code, and writing new files.";
const docsHeader = "<docs>\nPi documentation (read only when the user asks about pi itself, its SDK, extensions, themes, skills, or TUI):";

function shapeSystemText(text) {
    // Only the pinned engine's generated introduction/docs prose. Never rewrite
    // pi in paths, project instructions, skills, user prompts or tool arguments.
    if (!text.startsWith(preamble)) return text;
    text = "You are an expert coding assistant. You help users by reading files, executing commands, editing code, and writing new files." + text.slice(preamble.length);
    const start = text.indexOf(docsHeader);
    const end = text.indexOf("\n</docs>", start);
    if (start < 0 || end < 0) return text;
    const docs = text.slice(start, end)
        .replace(docsHeader, "<docs>\nAgent harness documentation (read only when the user asks about the harness itself, its SDK, extensions, themes, skills, or TUI):")
        .replace("\n- When reading pi docs or examples,", "\n- When reading harness docs or examples,")
        .replace("\n- When working on pi topics,", "\n- When working on harness topics,")
        .replace("\n- Always read pi .md files completely", "\n- Always read harness .md files completely");
    return text.slice(0, start) + docs + text.slice(end);
}

export function buildOAuthSystemBlocks(text, cacheControl, version) {
    // The changing billing block and identity are deliberately uncached. Keep
    // Pi's existing cache policy on the real instructions and conversation.
    const blocks = [
        { type: "text", text: `x-anthropic-billing-header: cc_version=${version}; cc_entrypoint=cli; cch=00000; cc_prompt_id=${randomUUID()}` },
        { type: "text", text: "You are a Claude agent, built on Anthropic's Claude Agent SDK." },
    ];
    if (text) blocks.push({ type: "text", text: shapeSystemText(text), ...(cacheControl ? { cache_control: cacheControl } : {}) });
    return blocks;
}
