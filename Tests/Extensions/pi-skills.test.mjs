// Settings ▸ Skills' outside skills: shepherd-pi-skills.mjs, run as Shepherd runs it (node, source
// on stdin), lists exactly the skills pi's own resource loader gives a session outside any
// repository, marks the ones a same-named skill shadows, and writes nothing. Fixture folders in a
// temporary home and pi agent directory; the installed pi package.
import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const pkg = process.env.PI_PACKAGE_DIR;
if (!pkg) throw Error("Set PI_PACKAGE_DIR to the installed Pi package");
const script = fs.readFileSync(path.join(root, "Extensions/shepherd-pi-skills.mjs"), "utf8");
const { DefaultResourceLoader, SettingsManager } = await import(path.join(pkg, "dist/index.js"));

function skill(dir, name, description, extra = "") {
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, "SKILL.md"), `---\nname: ${name}\ndescription: ${description}\n${extra}---\n# ${name}\n`);
}

/** A home with ~/.agents/skills, a pi agent directory with skills, a settings path and a local package. */
function fixture() {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "shepherd-pi-skills-")));
  const home = path.join(dir, "home");
  const agentDir = path.join(dir, "agent");
  skill(path.join(home, ".agents/skills/alpha"), "alpha", "Installed alpha.");
  skill(path.join(home, ".agents/skills/delta"), "delta", "Installed delta.");
  skill(path.join(agentDir, "skills/alpha"), "alpha", "pi's alpha.");
  skill(path.join(agentDir, "skills/beta"), "beta", "pi's beta.", "disable-model-invocation: true\n");
  skill(path.join(dir, "extra/gamma"), "gamma", "From pi's settings.");
  skill(path.join(dir, "vendor/team/skills/delta"), "delta", "The package's delta.");
  skill(path.join(dir, "vendor/team/skills/epsilon"), "epsilon", "The package's epsilon.");
  fs.writeFileSync(path.join(dir, "vendor/team/package.json"), JSON.stringify({ name: "@acme/team-skills", pi: { skills: ["./skills"] } }));
  fs.writeFileSync(path.join(agentDir, "settings.json"), JSON.stringify({ skills: [path.join(dir, "extra")], packages: [path.join(dir, "vendor/team")] }));
  return { dir, home, agentDir };
}

function run({ home, agentDir }, { executable = "", packageDir = pkg } = {}) {
  const env = { ...process.env, HOME: home, SHEPHERD_PI_SKILLS_AGENT_DIR: agentDir, PI_CODING_AGENT_DIR: agentDir };
  if (packageDir) env.SHEPHERD_PI_SKILLS_PACKAGE = packageDir; else delete env.SHEPHERD_PI_SKILLS_PACKAGE;
  const result = spawnSync(process.execPath, ["--input-type=module", "-", executable], { input: script, env, cwd: home, encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  return JSON.parse(result.stdout);
}

function files(dir) {
  return fs.readdirSync(dir, { recursive: true }).sort();
}

test("the script lists the skills pi's own loader gives a session", async () => {
  const f = fixture();
  try {
    const before = files(f.agentDir);
    const answer = run(f);
    assert.equal(answer.problem, undefined);
    assert.equal(answer.agentDir, f.agentDir);

    const savedHome = process.env.HOME;
    process.env.HOME = f.home;
    try {
      const settingsManager = SettingsManager.create(f.home, f.agentDir, { projectTrusted: false });
      const loader = new DefaultResourceLoader({ cwd: f.home, agentDir: f.agentDir, settingsManager, noExtensions: true });
      await loader.reload();
      const pi = loader.getSkills().skills.map((s) => [s.name, s.filePath]).sort();
      assert.deepEqual(answer.skills.map((s) => [s.name, s.path]).sort(), pi);
    } finally {
      process.env.HOME = savedHome;
    }

    const byName = Object.fromEntries(answer.skills.map((s) => [s.name, s]));
    assert.deepEqual(Object.keys(byName).sort(), ["alpha", "beta", "delta", "epsilon", "gamma"]);
    assert.equal(byName.alpha.path, path.join(f.agentDir, "skills/alpha/SKILL.md"));
    assert.equal(byName.alpha.source, "auto");
    assert.equal(byName.beta.slashOnly, true);
    assert.equal(byName.gamma.source, "local");
    assert.equal(byName.delta.path, path.join(f.home, ".agents/skills/delta/SKILL.md"));
    assert.equal(byName.epsilon.origin, "package");
    assert.equal(byName.epsilon.packageName, "@acme/team-skills");

    const shadowed = Object.fromEntries(answer.shadowed.map((s) => [s.path, s]));
    assert.equal(shadowed[path.join(f.home, ".agents/skills/alpha/SKILL.md")].winner, byName.alpha.path);
    assert.equal(shadowed[path.join(f.dir, "vendor/team/skills/delta/SKILL.md")].winner, byName.delta.path);
    assert.equal(shadowed[path.join(f.dir, "vendor/team/skills/delta/SKILL.md")].origin, "package");
    assert.equal(answer.shadowed.length, 2);

    // Reading writes nothing into pi's directory (no settings lock, no migration).
    assert.deepEqual(files(f.agentDir), before);
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

test("pi's package is found from its executable", () => {
  const f = fixture();
  try {
    const manifest = JSON.parse(fs.readFileSync(path.join(pkg, "package.json"), "utf8"));
    const bin = typeof manifest.bin === "string" ? manifest.bin : manifest.bin.pi;
    const link = path.join(f.dir, "pi");
    fs.symlinkSync(path.join(pkg, bin), link);
    const answer = run(f, { executable: link, packageDir: null });
    assert.equal(answer.problem, undefined);
    assert.ok(answer.skills.some((s) => s.name === "epsilon"));
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

test("without pi the script says so", () => {
  const f = fixture();
  try {
    assert.equal(run(f, { packageDir: path.join(f.dir, "nowhere") }).problem, "pi_not_found");
    assert.equal(run(f, { executable: path.join(f.dir, "missing-pi"), packageDir: null }).problem, "pi_not_found");
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});
