import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { withPi, until } from "./fixtures/pi-rpc-harness.mjs";

const extension = fileURLToPath(new URL("../../Extensions/shepherd-status.ts", import.meta.url));
const checkout = work => work + "-checkout";
function resources(root, config, marker) {
  const base = path.join(root, config);
  fs.mkdirSync(path.join(base, "prompts"), { recursive: true });
  fs.mkdirSync(path.join(base, "skills/owner-skill"), { recursive: true });
  fs.writeFileSync(path.join(base, "prompts/nightly-pr.md"), `---\ndescription: ${marker}\n---\n${marker}\n`);
  fs.writeFileSync(path.join(base, "skills/owner-skill/SKILL.md"), `---\nname: owner-skill\ndescription: ${marker}\n---\n${marker}\n`);
}
function options({ trusted = true, grant = true, mismatch = false, localTrusted = false, emptyOwner = false, extraEnv = {} } = {}) {
  return {
    args: ["-e", extension],
    settings: { extensions: ["-builtin:mcp", "-builtin:tool-search"] },
    cwd: (_dir, work) => checkout(work),
    env: (dir, work) => ({ SHEPHERD_AGENT_ID: "fixture", SHEPHERD_SOCKET: path.join(dir, "absent.sock"),
      ...(grant ? { SHEPHERD_RESOURCE_OWNING_SPACE: work,
        SHEPHERD_RESOURCE_WORKTREE_CWD: mismatch ? work : checkout(work) } : {}), ...extraEnv }),
    files: (_dir, work) => ({ "trust.json": { [work]: trusted, ...(localTrusted ? { [checkout(work)]: true } : {}) } }),
    project: (dir, work) => {
      if (!emptyOwner) {
        resources(work, ".pi", "PI_OWNER");
        resources(work, ".shepherd", "SHEPHERD_OWNER");
      }
      resources(checkout(work), ".shepherd", "BRANCH_LOCAL");
      fs.mkdirSync(path.join(checkout(work), ".shepherd/extensions"), { recursive: true });
      fs.writeFileSync(path.join(checkout(work), ".shepherd/extensions/mark.ts"),
        `import fs from 'node:fs'; fs.writeFileSync(${JSON.stringify(path.join(dir, "branch-ran"))}, 'ran'); export default function() {}`);
      fs.writeFileSync(path.join(checkout(work), ".shepherd/settings.json"), JSON.stringify({ defaultProjectTrust: "always" }));
    },
  };
}

test("a trusted owning Space supplies callable slash prompts and skills without approving branch resources or enabling MCP", { timeout: 60000 }, async t => {
  await withPi(t, options(), async pi => {
    const commands = await pi.commands();
    assert.equal(commands.find(c => c.name === "nightly-pr")?.description, "SHEPHERD_OWNER");
    assert.equal(commands.find(c => c.name === "skill:owner-skill")?.description, "SHEPHERD_OWNER");
    const turn = await pi.prompt("/nightly-pr");
    assert.match(JSON.stringify(turn.requests), /SHEPHERD_OWNER/);
    assert.doesNotMatch(JSON.stringify(turn.requests), /BRANCH_LOCAL/);
    assert.equal(fs.existsSync(path.join(pi.dir, "branch-ran")), false);
    assert.deepEqual(JSON.parse(fs.readFileSync(path.join(pi.home, "trust.json"))), { [pi.work]: true });
    assert.equal(fs.existsSync(path.join(checkout(pi.work), ".pi")), false, "no configuration is copied");
  });
});

test("an untrusted owner, missing or mismatched worktree grant, coordinator and native child inherit no resources", { timeout: 120000 }, async t => {
  for (const variant of [{ trusted: false }, { grant: false }, { mismatch: true },
    { extraEnv: { SHEPHERD_PROJECT_COORDINATOR: "1" } }, { extraEnv: { SHEPHERD_CHILD: "1" } }]) {
    await withPi(t, options(variant), async pi => {
      const names = (await pi.commands()).map(c => c.name);
      assert.ok(!names.includes("nightly-pr") && !names.includes("skill:owner-skill"), JSON.stringify(variant));
      assert.equal(fs.existsSync(path.join(pi.dir, "branch-ran")), false);
    });
  }
});

test("separately trusted worktree resources override inherited owner resources", { timeout: 60000 }, async t => {
  await withPi(t, options({ localTrusted: true }), async pi => {
    const commands = await pi.commands();
    assert.equal(commands.find(c => c.name === "nightly-pr")?.description, "BRANCH_LOCAL");
    assert.equal(commands.find(c => c.name === "skill:owner-skill")?.description, "BRANCH_LOCAL");
  });
});

test("inherited prompt and skill folders created later update the slash catalog in an idle live thread", { timeout: 60000 }, async t => {
  await withPi(t, options({ emptyOwner: true }), async pi => {
    await pi.commands();
    const mark = pi.events.length;
    resources(pi.work, ".shepherd", "UPDATED_OWNER");
    resources(pi.work, ".pi", "PI_OWNER");
    fs.writeFileSync(path.join(pi.work, ".pi/prompts/pi-only.md"), "---\ndescription: Pi only\n---\nPI_ONLY\n");
    await until("inherited resources invalidate", () => pi.events.slice(mark).some(e => e.type === "skills_changed"));
    assert.equal((await pi.request({ type: "refresh_skills" })).success, true);
    await until("inherited resources refresh", async () => {
      const commands = await pi.commands();
      return commands.find(c => c.name === "nightly-pr")?.description === "UPDATED_OWNER"
        && commands.find(c => c.name === "skill:owner-skill")?.description === "UPDATED_OWNER"
        && commands.some(c => c.name === "pi-only");
    });
    const removed = pi.events.length;
    fs.unlinkSync(path.join(pi.work, ".shepherd/prompts/nightly-pr.md"));
    await until("inherited removal invalidates", () => pi.events.slice(removed).some(e => e.type === "skills_changed"));
    assert.equal((await pi.request({ type: "refresh_skills" })).success, true);
    await until("the Pi alias is used after Shepherd template removal", async () =>
      (await pi.commands()).find(c => c.name === "nightly-pr")?.description === "PI_OWNER");
  });
});
