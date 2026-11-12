// The vision extension with in-memory model completions, then a real pi on the fake provider:
// a text-only thread model is sent words, the session keeps the image. No network.
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { spawn } from "node:child_process";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { startProvider } from "./fake-provider.mjs";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const pkg = process.env.PI_PACKAGE_DIR;
if (!pkg) throw Error("Set PI_PACKAGE_DIR");
const { createJiti } = createRequire(path.join(pkg, "package.json"))("jiti");
const jiti = createJiti(import.meta.url, { alias: { typebox: path.join(pkg, "node_modules/typebox/build/index.mjs") } });
const { default: install, modelLacksImages, visionCandidates, describeImages } =
  await jiti.import(path.join(root, "Extensions/shepherd-vision.ts"));

const blind = { provider: "muse", id: "blind", input: ["text"], cost: { input: 1, output: 1 } };
const cheap = { provider: "cheap", id: "sees", input: ["text", "image"], cost: { input: 0.1, output: 0.4 } };
const pricey = { provider: "pricey", id: "sees", input: ["text", "image"], cost: { input: 3, output: 15 } };
const unauthed = { provider: "locked", id: "sees", input: ["text", "image"], cost: { input: 0, output: 0 } };
const image = { type: "image", data: "aGVsbG8=", mimeType: "image/png" };

test("only known input kinds without image count as blind", () => {
  assert.equal(modelLacksImages(blind), true);
  assert.equal(modelLacksImages(cheap), false);
  assert.equal(modelLacksImages({ provider: "x", id: "y" }), false);
  assert.equal(modelLacksImages(undefined), false);
});

test("automatic candidates are the cheapest signed-in models that take images", () => {
  const hasAuth = (m) => m !== unauthed;
  assert.deepEqual(visionCandidates([pricey, blind, unauthed, cheap], [], hasAuth), [cheap, pricey]);
  // A pick is the whole list, and only where it takes images.
  assert.deepEqual(visionCandidates([blind, cheap], ["muse/blind"], hasAuth), []);
  assert.deepEqual(visionCandidates([blind, cheap], ["cheap/sees"], hasAuth), [cheap]);
  assert.deepEqual(visionCandidates([blind, cheap], ["sees"], hasAuth), [cheap]);
});

test("describeImages swaps each image for words and hands over the nearby text", async () => {
  const hints = [];
  const messages = [
    { role: "user", content: [{ type: "text", text: "What does the button say?" }, image] },
    { role: "assistant", content: [{ type: "text", text: "Looking." }] },
    { role: "toolResult", toolName: "board_render", content: [{ type: "text", text: "Rendered." }, image] },
  ];
  const converted = await describeImages(messages, async (_image, hint) => { hints.push(hint); return "WORDS"; });
  assert.equal(converted[0].content[1].text, "WORDS");
  assert.equal(converted[1], messages[1]);
  assert.equal(converted[2].content[1].text, "WORDS");
  assert.match(hints[0], /What does the button say\?/);
  assert.match(hints[1], /board_render/);
  const plain = [{ role: "user", content: "hello" }];
  assert.equal(await describeImages(plain, async () => "WORDS"), plain);
});

function rigged(complete) {
  const handlers = new Map(), entries = [], completions = [];
  const saved = process.env.SHEPHERD_EXT_VISION;
  process.env.SHEPHERD_EXT_VISION = "1";
  try {
    install({
      on: (event, handler) => handlers.set(event, handler),
      appendEntry: (customType, data) => entries.push({ type: "custom", customType, data }),
    });
  } finally {
    saved === undefined ? delete process.env.SHEPHERD_EXT_VISION : process.env.SHEPHERD_EXT_VISION = saved;
  }
  const ctx = (model) => ({
    model,
    sessionManager: { getBranch: () => entries },
    modelRegistry: {
      getAvailable: () => [blind, pricey, unauthed, cheap],
      hasConfiguredAuth: (m) => m !== unauthed,
      complete: async (model, context, options) => { completions.push(model); return complete(model, context, options); },
    },
  });
  return { context: handlers.get("context"), entries, completions, ctx };
}

test("a blind model is sent a description once per image, remembered in the session", async () => {
  const { context, entries, completions, ctx } = rigged(async () => ({ content: [{ type: "text", text: "A red Delete button." }] }));
  const event = () => ({ messages: [{ role: "user", content: [{ type: "text", text: "See this?" }, image] }] });
  const first = await context(event(), ctx(blind));
  assert.match(first.messages[0].content[1].text, /Image description by cheap\/sees/);
  assert.match(first.messages[0].content[1].text, /A red Delete button\./);
  assert.deepEqual(completions, [cheap], "the cheapest candidate describes, not the catalog's first");
  assert.equal(entries.length, 1);
  const second = await context(event(), ctx(blind));
  assert.equal(second.messages[0].content[1].text, first.messages[0].content[1].text);
  assert.equal(completions.length, 1, "the same image is described once");
  // A model that takes images is sent the conversation untouched.
  assert.equal(await context(event(), ctx(cheap)), undefined);
  assert.equal(completions.length, 1);
});

// A 16x16 red PNG (pi resizes attachments on the way in, and a 1x1 fails that).
const PNG = "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAF0lEQVR4nGP4z8BAEiJN9aiGUQ1DSgMAkPn/Afnh+ngAAAAASUVORK5CYII=";

test("a real pi: the blind model is sent the description, the session keeps the image", { timeout: 90000 }, async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sh-vision-"));
  const config = path.join(dir, "pi"), project = path.join(dir, "project");
  fs.mkdirSync(config, { recursive: true });
  fs.mkdirSync(project, { recursive: true });
  const fake = await startProvider({ onRequest: (entry) => entry.body?.model === "sees" ? { outputText: "A red Delete button." } : {} });
  const model = (id, input, price) => ({ id, name: id, reasoning: false, input, contextWindow: 128000, maxTokens: 4096,
    cost: { input: price, output: price, cacheRead: 0, cacheWrite: 0 } });
  fs.writeFileSync(path.join(config, "models.json"), JSON.stringify({ providers: { fake: {
    baseUrl: `http://127.0.0.1:${fake.port}/v1`, apiKey: "fixture-not-secret", api: "openai-completions",
    models: [model("blind", ["text"], 5), model("sees", ["text", "image"], 1)] } } }));
  fs.writeFileSync(path.join(config, "settings.json"), JSON.stringify({ retry: { enabled: false }, compaction: { enabled: false } }));
  const vision = path.join(root, "Extensions/shepherd-vision.ts");
  const child = spawn(process.execPath,
    [path.join(pkg, "dist/bundle/cli.js"), "--mode", "rpc", "--session-dir", path.join(dir, "sessions"),
     "--session-id", "7f1d2c3a-0000-4000-8000-000000000001", "--model", "fake/blind", "-e", vision],
    { cwd: project, stdio: ["pipe", "pipe", "pipe"],
      env: { PATH: process.env.PATH, HOME: dir, PI_CODING_AGENT_DIR: config, PI_OFFLINE: "1", PI_SKIP_VERSION_CHECK: "1", SHEPHERD_EXT_VISION: vision } });
  const events = [];
  let out = "", err = "";
  child.stdout.on("data", (chunk) => { out += chunk; for (let nl; (nl = out.indexOf("\n")) >= 0; out = out.slice(nl + 1)) { try { events.push(JSON.parse(out.slice(0, nl))); } catch {} } });
  child.stderr.on("data", (chunk) => { err += chunk; });
  child.stdin.on("error", () => {});
  const until = async (what, fn) => { const end = Date.now() + 60000; while (!fn()) { if (Date.now() > end) throw Error(`Timed out waiting for ${what}: ${err.slice(0, 400)}`); await new Promise((r) => setTimeout(r, 15)); } };
  let next = 0;
  const turn = async (command) => {
    const settled = events.filter((e) => e.type === "agent_settled").length;
    const id = `r${++next}`;
    child.stdin.write(JSON.stringify({ id, type: "prompt", ...command }) + "\n");
    await until("the prompt's answer", () => events.some((e) => e.type === "response" && e.id === id));
    const reply = events.find((e) => e.type === "response" && e.id === id);
    assert.ok(reply.success, JSON.stringify(reply));
    await until("the turn to settle", () => events.filter((e) => e.type === "agent_settled").length === settled + 1);
  };
  try {
    await turn({ message: "What is in the picture?", images: [{ type: "image", data: PNG, mimeType: "image/png" }] });
    await turn({ message: "And now?" });
    const byModel = (id) => fake.requests.filter((r) => r.body?.model === id);
    assert.equal(byModel("sees").length, 1, "described once, on the cheapest image-capable model");
    assert.match(JSON.stringify(byModel("sees")[0].body), /image_url/, "the describer got the picture");
    assert.equal(byModel("blind").length, 2);
    for (const request of byModel("blind")) {
      const body = JSON.stringify(request.body);
      assert.match(body, /A red Delete button\./, "the thread's model is sent the words, on the next turn too");
      assert.doesNotMatch(body, /image_url/, "and never the picture");
    }
    const folder = path.join(dir, "sessions");
    const walk = (d) => fs.readdirSync(d, { withFileTypes: true }).flatMap((e) => e.isDirectory() ? walk(path.join(d, e.name)) : [path.join(d, e.name)]);
    const session = fs.readFileSync(walk(folder).find((f) => f.endsWith(".jsonl")), "utf8");
    assert.match(session, /"type":"image"/, "the session keeps the real image");
    assert.match(session, /shepherd\.vision/, "and remembers the description");
  } finally {
    child.kill();
    await fake.stop();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("when no candidate can describe, the image is omitted once and not retried per request", async () => {
  const { context, completions, ctx } = rigged(async () => { throw Error("quota"); });
  const event = () => ({ messages: [{ role: "user", content: [image] }] });
  const first = await context(event(), ctx(blind));
  assert.match(first.messages[0].content[0].text, /omitted/);
  const tried = completions.length;
  assert.ok(tried >= 1 && tried <= 3);
  await context(event(), ctx(blind));
  assert.equal(completions.length, tried);
});
