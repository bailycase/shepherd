// Loopback-only scripted model for MissionSpecKitEngineTests. It reads only request bodies.
// Every turn must arrive as pi's expansion of the project's stock Spec Kit prompt (never a literal
// "/speckit.*" line). Pi's real bash tool runs the official `.specify/scripts/bash/*.sh --json`
// helpers; their JSON is validated here and logged for the Swift test.
import * as http from "node:http";
import { appendFileSync, existsSync, readFileSync } from "node:fs";
import assert from "node:assert/strict";

// `hold`/`release`: optional files. While `hold` exists, implement waits before its edit (bounded) so a
// test can steer the working turn; it continues once `release` exists.
const { launcher, log, goal, hold, release, holdCommand = "implement", holdStep = 2 } = JSON.parse(readFileSync(process.argv[2], "utf8"));
const MAX_REQUESTS = 40;
const textOf = (message) => typeof message?.content === "string" ? message.content
  : (message?.content ?? []).map(part => part.text ?? "").join("\n");
const record = (entry) => appendFileSync(log, JSON.stringify(entry) + "\n");
const jsonLine = (text) => {
  const line = text.split("\n").map(value => value.trim()).find(value => value.startsWith("{") && value.endsWith("}"));
  assert.ok(line, `no JSON line in script output: ${text.slice(0, 400)}`);
  return JSON.parse(line);
};

// Markers from the v1.2.3 command templates after upstream's own pi processing.
const commands = [
  ["converge", p => p.includes("APPEND-ONLY, NEVER REWRITE")],
  ["clarify", p => p.includes("Detect and reduce ambiguity or missing decision points")],
  ["implement", p => p.includes("make sure to mark the task off as [X]")],
  ["tasks", p => p.includes(".specify/scripts/bash/setup-tasks.sh --json")],
  ["plan", p => p.includes(".specify/scripts/bash/setup-plan.sh --json")],
  ["specify", p => p.includes("Generate a concise short name")],
];
const prereq = ".specify/scripts/bash/check-prerequisites.sh";
const steps = {
  // Upstream clarify asks one question per turn and waits for the answer.
  clarify: [{ text: "Q1: Which authentication method should FR-006 use? (a) email (b) SSO" }],
  // The owner's answer inside clarify: encode it into spec.md, which resolves the marked questions.
  answer: [
    { bash: "sed -i '' '/NEEDS CLARIFICATION/d' specs/001-result/spec.md && echo RESOLVED", check: out => assert.match(out, /RESOLVED/) },
    { text: "Encoded the answer in spec.md." },
  ],
  // Owner feedback with no question: acknowledged, no files changed.
  feedback: [{ text: "Noted. Nothing in the spec needs to change." }],
  specify: [
    { bash: "mkdir -p specs/001-result/checklists && cp .specify/templates/spec-template.md specs/001-result/spec.md"
        + " && printf '%s\\n' '- **FR-001**: result.txt MUST contain after followed by a newline' >> specs/001-result/spec.md"
        + " && printf '{\"feature_directory\":\"specs/001-result\"}' > .specify/feature.json && echo SPEC_WRITTEN",
      check: out => assert.match(out, /SPEC_WRITTEN/) },
    { text: "Created specs/001-result/spec.md from the stock spec template." },
  ],
  plan: [
    { bash: ".specify/scripts/bash/setup-plan.sh --json", check: out => {
      const json = jsonLine(out);
      for (const key of ["FEATURE_SPEC", "IMPL_PLAN", "FEATURE_DIR", "BRANCH"]) assert.ok(key in json, `setup-plan JSON lacks ${key}`);
      assert.match(json.FEATURE_DIR, /specs\/001-result$/);
      assert.match(json.IMPL_PLAN, /specs\/001-result\/plan\.md$/);
      return json;
    } },
    { text: "Plan created from the stock plan template." },
  ],
  tasks: [
    { bash: ".specify/scripts/bash/setup-tasks.sh --json", check: out => {
      const json = jsonLine(out);
      assert.match(json.FEATURE_DIR, /specs\/001-result$/);
      assert.ok(Array.isArray(json.AVAILABLE_DOCS));
      assert.ok(json.TASKS_TEMPLATE_CONTENT.length > 0, "stock tasks template resolved");
      return json;
    } },
    { bash: "printf '# Tasks: Result\\n\\n## Phase 1: Core\\n\\n- [ ] T001 Write after to result.txt\\n' > specs/001-result/tasks.md && echo TASKS_WRITTEN",
      check: out => assert.match(out, /TASKS_WRITTEN/) },
    { text: "Generated specs/001-result/tasks.md." },
  ],
  implement: [
    { bash: `${prereq} --json --require-tasks --include-tasks`, check: out => {
      const json = jsonLine(out);
      assert.match(json.FEATURE_DIR, /specs\/001-result$/);
      assert.ok(json.AVAILABLE_DOCS.includes("tasks.md"), "check-prerequisites lists tasks.md");
      return json;
    } },
    // Known compatibility blocker, recorded rather than bypassed: nested print-mode pi is refused.
    { bash: `'${launcher.replaceAll("'", "'\\''")}' -p hello; echo "exit=$?"`, check: out => {
      assert.match(out, /Nested Pi subprocesses are not allowed/);
      assert.match(out, /exit=1/);
      return { delegation: "refused" };
    } },
    // Implement also fills in a design artifact, as live runs do; approval must treat it as output.
    { bash: "printf 'after\\n' > result.txt && sed -i '' 's/- \\[ \\] T001/- [X] T001/' specs/001-result/tasks.md"
        + " && mkdir -p specs/001-result/contracts && printf '%s\\n' '# CLI contract' '- result.txt holds after' >> specs/001-result/contracts/cli.md && echo IMPLEMENTED",
      check: out => assert.match(out, /IMPLEMENTED/) },
    { text: "Implemented T001 and marked it [X]." },
  ],
  converge: [
    { bash: `${prereq} --json --require-spec --require-tasks --include-tasks`, check: out => {
      const json = jsonLine(out);
      assert.ok(json.AVAILABLE_DOCS.includes("tasks.md"));
      return json;
    } },
    { text: "✅ Converged — the implementation satisfies the spec, plan, and tasks." },
  ],
};

let requests = 0;
const stream = (res, body, delta) => {
  const chunk = (value, finish = null, usage) => `data: ${JSON.stringify({ id: `speckit-${requests}`,
    object: "chat.completion.chunk", created: 1, model: body.model,
    choices: [{ index: 0, delta: value, finish_reason: finish }], ...(usage ? { usage } : {}) })}\n\n`;
  res.writeHead(200, { "content-type": "text/event-stream" });
  res.write(chunk(delta));
  res.end(chunk({}, delta.tool_calls ? "tool_calls" : "stop", { prompt_tokens: 100, completion_tokens: 10, total_tokens: 110 }) + "data: [DONE]\n\n");
};
const server = http.createServer(async (req, res) => {
  try {
    assert.ok(++requests <= MAX_REQUESTS, "provider request bound exceeded");
    assert.equal(req.method, "POST");
    assert.equal(req.url, "/v1/chat/completions");
    let raw = "";
    for await (const chunk of req) {
      raw += chunk;
      assert.ok(Buffer.byteLength(raw) <= 1024 * 1024, "oversized request");
    }
    const body = JSON.parse(raw);
    record({ request: requests });
    const offered = (body.tools ?? []).map(t => t.function?.name);
    if (offered.length === 1 && offered[0] === "propose_title") {
      // Shepherd's thread namer, not a mission turn: answer with a plain title.
      record({ namer: true });
      return stream(res, body, { content: "Spec Kit mission" });
    }
    const users = body.messages.map((m, i) => [m, i]).filter(([m]) => m.role === "user");
    for (const [m] of users) assert.ok(!textOf(m).trimStart().startsWith("/speckit."), "a stock command reached the model unexpanded");
    // The turn's own expanded command; later user messages in it are owner steers.
    const turn = [...users].reverse().find(([m]) => commands.some(([, match]) => match(textOf(m))));
    assert.ok(turn, `turn is not an expanded stock Spec Kit command: ${textOf(users.at(-1)?.[0]).slice(0, 200)}`);
    let [user, index] = turn;
    const prompt = textOf(user);
    let command = commands.find(([, match]) => match(prompt))[0];
    // An owner message after a settled turn (the message before it is a final reply, not a tool result) is its own
    // turn: an answer inside clarify, else feedback. User messages after tool results are steers.
    const [lastUser, lastIndex] = users.at(-1);
    const before = body.messages[lastIndex - 1];
    if (lastIndex > index && before?.role === "assistant" && !(before.tool_calls?.length)) {
      record({ owner: textOf(lastUser), after: command });
      command = command === "clarify" ? "answer" : "feedback";
      user = lastUser; index = lastIndex;
    }
    for (const [m, i] of users) if (i > index) record({ command, steer: textOf(m) });
    if (command === "specify") assert.ok(prompt.includes(goal), "specify's $ARGUMENTS carried the goal");
    const results = body.messages.slice(index + 1).filter(m => m.role === "tool");
    const step = steps[command][results.length];
    assert.ok(step, `${command} has no step ${results.length}`);
    if (results.length > 0) {
      const previous = steps[command][results.length - 1];
      const output = previous.check(textOf(results.at(-1)));
      record({ command, step: results.length - 1, expanded: true, output: output ?? null });
    }
    if (command === holdCommand && results.length === holdStep && hold && existsSync(hold)) {
      record({ command, held: holdStep });
      const deadline = Date.now() + 60_000;
      while (!(release && existsSync(release)) && Date.now() < deadline) await new Promise(r => setTimeout(r, 50));
      assert.ok(release && existsSync(release), "implement hold was never released");
    }
    let content, tool;
    if (step.bash) {
      assert.ok(body.tools?.some(t => t.function?.name === "bash"), `pi must offer its bash tool; offered: ${(body.tools ?? []).map(t => t.function?.name).join(",")}`);
      tool = { name: "bash", arguments: JSON.stringify({ command: step.bash }) };
    } else {
      content = step.text;
      record({ command, done: true });
    }
    stream(res, body, tool ? { tool_calls: [{ index: 0, id: `call_${requests}`, type: "function", function: tool }] } : { content });
  } catch (error) {
    console.error(error);
    record({ error: String(error?.message ?? error) });
    res.writeHead(400, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: { message: String(error), type: "fixture_error" } }));
  }
});
server.requestTimeout = 10_000;
const lifetime = setTimeout(() => { console.error("speckit provider lifetime exceeded"); process.exit(1); }, 300_000);
lifetime.unref();
server.listen(0, "127.0.0.1", () => console.log(JSON.stringify({ port: server.address().port })));
process.stdin.on("end", () => process.exit(0));
process.stdin.resume();
