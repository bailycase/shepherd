// Native Pi codemode under Shepherd's global/project settings, using only a loopback fake provider.
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";
import { withPi, script, until } from "./fixtures/pi-rpc-harness.mjs";

const status = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../Extensions/shepherd-status.ts");
const setting = (on) => ({
  extensions: ["-builtin:mcp", "-builtin:tool-search", "-builtin:codemode"],
  codemode: { enabled: on },
});
const hosted = {
  args: ["-e", status],
  env: { SHEPHERD_AGENT_ID: "codemode-test", SHEPHERD_SOCKET: "/tmp/shepherd-codemode-test-missing.sock" },
};
const tool = (code) => ({ tool: { name: "codemode", arguments: { code } } });
const require = createRequire(path.join(process.env.PI_PACKAGE_DIR, "package.json"));
const { createJiti } = require("jiti");
const sdk = ["dist/index.js", "dist/bundle/index.js"].map((p) => path.join(process.env.PI_PACKAGE_DIR, p)).find(fs.existsSync);
const jiti = createJiti(import.meta.url, { alias: { "@earendil-works/pi-coding-agent": sdk } });
const { boundedCodemodeSource } = await jiti.import(status);

test("native codemode in global defaults does not change implicit child capabilities", async () => {
  const config = await jiti.import(path.join(path.dirname(status), "shepherd-children-config.ts"));
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "shepherd-child-codemode-"));
  const previous = process.env.PI_CODING_AGENT_DIR;
  process.env.PI_CODING_AGENT_DIR = path.join(dir, "pi");
  fs.mkdirSync(process.env.PI_CODING_AGENT_DIR);
  try {
    const file = path.join(process.env.PI_CODING_AGENT_DIR, "settings.json");
    fs.writeFileSync(file, JSON.stringify(setting(true)));
    assert.deepEqual(config.defaultChildTools(dir), ["read", "bash", "edit", "write"]);
    fs.writeFileSync(file, JSON.stringify({ ...setting(true), defaultTools: ["read"] }));
    assert.deepEqual(config.defaultChildTools(dir), ["read"]);
  } finally {
    if (previous === undefined) delete process.env.PI_CODING_AGENT_DIR; else process.env.PI_CODING_AGENT_DIR = previous;
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

for (const defaultTools of [["read"], ["codemode", "+grep"], []]) {
  test(`codemode preserves a restricted tool selection ${JSON.stringify(defaultTools)}`, async (t) => {
    await withPi(t, {
      ...hosted, settings: { ...setting(true), defaultTools },
      onRequest: script([tool('return {read:"read" in tools,bash:"bash" in tools,grep:"grep" in tools}')]),
    }, async (pi) => {
      const turn = await pi.prompt();
      const end = pi.toolEvents(turn.events).find((e) => e.type === "tool_execution_end" && e.toolName === "codemode");
      const expected = { read: defaultTools.includes("read"), bash: false, grep: defaultTools.includes("+grep") };
      assert.equal(end?.isError, false, JSON.stringify(end));
      assert.deepEqual(JSON.parse(end.result.content.at(-1).text), expected);
      assert.deepEqual(JSON.parse(fs.readFileSync(path.join(pi.home, "settings.json"))).defaultTools, defaultTools);
    });
  });
}

test("every script has a deadline and a model cannot raise or remove it", () => {
  assert.equal(boundedCodemodeSource("return 1"), '// @options: {"timeout_ms":300000}\nreturn 1');
  assert.equal(boundedCodemodeSource('// @options: {"timeout_ms":900000,"max_output_tokens":100}\nreturn 1'), '// @options: {"timeout_ms":300000,"max_output_tokens":100}\nreturn 1');
  assert.equal(boundedCodemodeSource('// @options: {"timeout_ms":10}\nreturn 1'), '// @options: {"timeout_ms":10}\nreturn 1');
  for (const timeout of [0, -1, "100", 1.5]) assert.throws(() => boundedCodemodeSource(`// @options: ${JSON.stringify({timeout_ms: timeout})}\nreturn 1`));
});

for (const [code, expected] of [
  ['// @options: {"timeout_ms":20}\nwhile (true) {}', /timed out/],
  ['return models.generateImages({provider:"another-provider",id:"image"}, {input: []})', /models.*not defined/],
]) {
  test(`native sandbox rejects ${code.split("\n").at(-1)}`, { timeout: 60000 }, async (t) => {
    await withPi(t, { ...hosted, settings: setting(true), onRequest: script([tool(code)]) }, async (pi) => {
      const turn = await pi.prompt();
      const end = pi.toolEvents(turn.events).find((e) => e.type === "tool_execution_end" && e.toolName === "codemode");
      assert.equal(end?.isError, true);
      assert.match(JSON.stringify(end?.result?.content), expected);
    });
  });
}

test("the native script stops at 128 tool calls and still honors blocking hooks", { timeout: 60000 }, async (t) => {
  const extension = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "fixtures/codemode-tools.ts");
  await withPi(t, {
    ...hosted, args: [...hosted.args, "-e", extension], settings: setting(true),
    onRequest: script([tool('for (let i=0;i<129;i++) await tools.ping({});'), tool('await tools.blocked({});')]),
  }, async (pi) => {
    const turn = await pi.prompt();
    const calls = pi.toolEvents(turn.events).filter((e) => e.type === "tool_execution_start" && e.toolName === "ping");
    assert.equal(calls.length, 128);
    const ends = pi.toolEvents(turn.events).filter((e) => e.type === "tool_execution_end" && e.toolName === "codemode");
    assert.equal(ends.length, 2);
    assert.match(JSON.stringify(ends[0].result), /128 tool calls/);
    assert.match(JSON.stringify(ends[1].result), /approval denied/);
    assert.doesNotMatch(JSON.stringify(ends[1].result.content), /EXECUTED BLOCKED TOOL/);
  });
});

for (const [global, project, trusted, expected] of [
  [true, undefined, true, true], [false, undefined, true, false],
  [true, false, true, false], [false, true, true, true],
  [true, false, false, true], [false, true, false, false],
]) {
  test(`codemode global=${global}, project=${project}, trusted=${trusted} exposes ${expected}`, { timeout: 60000 }, async (t) => {
    await withPi(t, {
      ...hosted,
      settings: setting(global), args: [...hosted.args, trusted ? "--approve" : "--no-approve"],
      project: (_, work) => {
        if (project === undefined) return;
        fs.mkdirSync(path.join(work, ".pi"));
        fs.writeFileSync(path.join(work, ".pi/settings.json"), JSON.stringify(setting(project)));
      },
    }, async (pi) => {
      const sent = await pi.promptSent();
      assert.equal(sent.tools.includes("codemode"), expected);
      for (const name of ["read", "bash", "edit", "write"]) assert.ok(sent.tools.includes(name), `${name} stays directly callable`);
    });
  });
}

for (const enabled of [false, true]) {
  test(`a manually enabled bare built-in cannot bypass the hosted setting or model restrictions: ${enabled}`, { timeout: 60000 }, async (t) => {
    await withPi(t, {
      ...hosted, args: [...hosted.args, "--approve"], settings: setting(enabled),
      files: (_, work) => ({[path.join(work, ".pi/settings.json")]: JSON.stringify({extensions: ["+builtin:codemode"], defaultTools: ["+codemode"]})}),
      onRequest: script([tool('return await models.list({})')]),
    }, async (pi) => {
      const turn = await pi.prompt();
      assert.equal(turn.requests[0].tools.includes("codemode"), enabled);
      const end = turn.events.find((e) => e.type === "tool_execution_end" && e.toolName === "codemode");
      assert.ok(end.isError);
      assert.match(JSON.stringify(end.result), enabled ? /models.*(not defined|undefined)/ : /Tool codemode not found/);
    });
  });
}

test("native scripts call tools, preserve bounded nested metadata, and return only selected output", { timeout: 60000 }, async (t) => {
  await withPi(t, {
    ...hosted,
    settings: setting(true),
    files: (_, work) => ({ [path.join(work, "example.txt")]: "first\nintermediate-result-not-returned\n" }),
    onRequest: script([tool('const text = await tools.read({path: "example.txt"}); return text.split("\\n")[0];')]),
  }, async (pi) => {
    const turn = await pi.prompt();
    const end = pi.toolEvents(turn.events).find((e) => e.type === "tool_execution_end" && e.toolName === "codemode");
    assert.equal(end?.isError, false, JSON.stringify(end));
    assert.ok(pi.toolEvents(turn.events).some((e) => e.toolName === "read" && e.parentToolCallId));
    const reply = await pi.request({ type: "get_messages" });
    const result = reply.data.messages.find((m) => m.role === "toolResult" && m.toolName === "codemode");
    assert.deepEqual(result.nestedCalls.calls.map(({id,name,status,arguments:args}) => ({id,name,status,args})),
      [{id: "call_1/1", name: "read", status: "ok", args: {path: "example.txt"}}]);
    const excerpt = result.details.calls[0];
    assert.equal(excerpt.output, "first\nintermediate-result-not-returned\n");
    assert.equal(excerpt.outputTruncated, false);
    assert.ok(excerpt.timestamp >= excerpt.startedAt);
    assert.doesNotMatch(JSON.stringify(turn.requests.at(-1).messages), /intermediate-result-not-returned/);
    assert.match(JSON.stringify(result.content), /first/);
    assert.doesNotMatch(JSON.stringify(result.content), /intermediate-result-not-returned/);
  });
});

test("nested output is persisted as display-only bounded excerpts", { timeout: 60000 }, async (t) => {
  await withPi(t, {
    ...hosted, settings: setting(true),
    files: (_, work) => ({ [path.join(work, "large.txt")]: "🐑".repeat(3000) }),
    onRequest: script([tool('for(let i=0;i<6;i++) await tools.read({path:"large.txt"}); return "done";')]),
  }, async (pi) => {
    const turn = await pi.prompt();
    const reply = await pi.request({ type: "get_messages" });
    const result = reply.data.messages.find((m) => m.role === "toolResult" && m.toolName === "codemode");
    assert.equal(result.nestedCalls.calls.length, 6);
    const excerpts = result.details.calls;
    assert.ok(excerpts.every((c) => Buffer.byteLength(c.output) <= 8192 && c.outputTruncated),
      JSON.stringify(excerpts.map((c) => ({ id: c.id, bytes: Buffer.byteLength(c.output), truncated: c.outputTruncated }))));
    assert.ok(excerpts.reduce((n,c) => n + Buffer.byteLength(c.output),0) <= 32768);
    assert.ok(excerpts.every((c) => !c.output.includes("\uFFFD")));
    assert.doesNotMatch(JSON.stringify(turn.requests.at(-1).messages), /🐑/);
    const sessions = fs.readdirSync(path.join(pi.dir, "sessions")).filter((p) => p.endsWith(".jsonl"));
    assert.ok(sessions.length > 0);
    const saved = sessions.flatMap((p) => fs.readFileSync(path.join(pi.dir,"sessions",p),"utf8").trim().split("\n").map(JSON.parse));
    const persisted = saved.find((entry) => entry.message?.toolCallId === result.toolCallId)?.message;
    assert.deepEqual(persisted?.details?.calls?.map((call) => call.output), excerpts.map((call) => call.output));
  });
});

test("Stop aborts an active native script and its nested tool without continuing it", { timeout: 60000 }, async (t) => {
  await withPi(t, {
    ...hosted,
    settings: setting(true),
    onRequest: script([tool('await tools.bash({command: "sleep 60"}); return "should not finish";')]),
  }, async (pi) => {
    await pi.request({ type: "prompt", message: "run" });
    await until("nested bash starts", () => pi.events.some((e) => e.type === "tool_execution_start" && e.toolName === "bash" && e.parentToolCallId));
    await pi.request({ type: "abort" });
    await until("script settles", () => pi.events.some((e) => e.type === "agent_settled"));
    const end = pi.events.find((e) => e.type === "tool_execution_end" && e.toolName === "codemode");
    assert.equal(end?.isError, true);
    assert.doesNotMatch(JSON.stringify(end?.result?.content), /should not finish/);
  });
});
