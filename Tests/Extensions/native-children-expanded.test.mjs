// Deterministic checks use only temporary files and restricted workers, never a model provider.
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const pkg = process.env.PI_PACKAGE_DIR;
if (!pkg) throw Error("Set PI_PACKAGE_DIR to the installed Pi package");
const require = createRequire(path.join(pkg, "package.json"));
const { createJiti } = require("jiti");
const jiti = createJiti(import.meta.url, { alias: {
  "@earendil-works/pi-coding-agent": path.join(pkg, "dist/index.js"),
  "@earendil-works/pi-tui": path.join(pkg, "node_modules/@earendil-works/pi-tui/dist/index.js"),
  "@earendil-works/pi-ai": path.join(pkg, "node_modules/@earendil-works/pi-ai/dist/index.js"),
  typebox: path.join(pkg, "node_modules/typebox/build/index.mjs"),
} });
const config = await jiti.import(path.join(root, "Extensions/shepherd-children-config.ts"));
const { executeWorkflow } = await jiti.import(path.join(root, "Extensions/shepherd-workflow.ts"));
const { missionStore } = await jiti.import(path.join(root, "Extensions/shepherd-missions.ts"));
const { ProjectTrustStore } = await import(path.join(pkg, "dist/index.js"));
const put = (file, text) => { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, text); };

test("child user extensions respect Pi filters and exclude project resources", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "shepherd-extension-inheritance-"));
  const old = process.env.PI_CODING_AGENT_DIR;
  const agentDir = path.join(dir, "pi"), cwd = path.join(dir, "project"), packageDir = path.join(dir, "package");
  process.env.PI_CODING_AGENT_DIR = agentDir;
  fs.mkdirSync(cwd);
  const provider = path.join(packageDir, "provider.ts"), disabled = path.join(packageDir, "disabled.ts");
  put(path.join(packageDir, "package.json"), JSON.stringify({ name: "arbitrary-user-package", pi: { extensions: ["*.ts"] } }));
  put(provider, 'throw Error("resolution must not execute code")');
  put(disabled, 'throw Error("disabled extension executed")');
  put(path.join(cwd, ".pi/extensions/project.ts"), 'throw Error("project extension executed")');
  put(path.join(agentDir, "settings.json"), JSON.stringify({ packages: [{source: packageDir, extensions: ["provider.ts"]}] }));
  try {
    assert.deepEqual(await config.childUserExtensions(cwd), [fs.realpathSync(provider)]);
    put(path.join(agentDir, "settings.json"), JSON.stringify({ packages: [{source: packageDir, extensions: []}] }));
    assert.deepEqual(await config.childUserExtensions(cwd), []);
  } finally {
    if (old === undefined) delete process.env.PI_CODING_AGENT_DIR; else process.env.PI_CODING_AGENT_DIR = old;
    fs.rmSync(dir, {recursive: true, force: true});
  }
});

test("discovery honors configured Pi dir, project precedence, trust, YAML lists, diagnostics and source files", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "shepherd-profiles-")), old = process.env.PI_CODING_AGENT_DIR, oldHome = process.env.HOME, oldExtra = process.env.PI_SUBAGENT_EXTRA_AGENT_DIRS;
  process.env.HOME = dir; delete process.env.PI_SUBAGENT_EXTRA_AGENT_DIRS;
  process.env.PI_CODING_AGENT_DIR = path.join(dir, "pi");
  try {
    const cwd = path.join(dir, "project"); fs.mkdirSync(cwd);
    const profile = (name, prompt, extra = "") => `---\nname: ${name}\ndescription: fixture\ntools: [read, grep]\n${extra}---\n${prompt}\n`;
    const user = path.join(process.env.PI_CODING_AGENT_DIR, "agents", "worker.md");
    put(user, profile("worker", "user worker"));
    put(path.join(cwd, ".agents", "worker.md"), profile("worker", "legacy project"));
    const canonical = path.join(cwd, ".pi", "agents", "worker.md");
    put(canonical, profile("worker", "preferred project", "model: fixture/fixture\nthinking: high\ndefaultContext: fork\n"));
    put(path.join(cwd, ".pi", "agents", "nested", "custom.md"), profile("custom", "custom prompt", "tools: inherit\n" ).replace("tools: [read, grep]\n", ""));
    put(path.join(cwd, ".agents", "skills", "skip.md"), profile("not-an-agent", "skip"));
    const ctx = { cwd, isProjectTrusted: () => true };
    const selected = config.discoverChildAgents(ctx, "both");
    const worker = selected.agents.find((a) => a.name === "worker");
    assert.equal(worker.prompt, "preferred project"); assert.equal(worker.context, "fork"); assert.equal(worker.thinking, "high");
    assert.deepEqual(worker.tools, ["read", "grep"]);
    assert.equal(selected.agents.find((a) => a.name === "custom").tools, "inherit");
    assert(!selected.agents.some((a) => a.name === "not-an-agent"));
    assert.equal(config.discoverChildAgents({ ...ctx, isProjectTrusted: () => false }, "both").agents.find((a) => a.name === "worker").prompt, "user worker");
    assert.equal(config.discoverChildAgents(ctx, "user").agents.find((a) => a.name === "worker").prompt, "user worker");
    assert.equal(config.discoverChildAgents(ctx, "bundled").agents.find((a) => a.name === "worker").source, "bundled");
    put(canonical, profile("worker", "must not fall back", "permissions: {bash: deny}\n"));
    assert.match(config.discoverChildAgents(ctx, "both").agents.find((a) => a.name === "worker").error, /Unsupported agent fields: permissions/);
    const outside = path.join(dir, "outside.md"); put(outside, profile("outside", "escape"));
    fs.symlinkSync(outside, path.join(cwd, ".pi", "agents", "outside.md"));
    assert(config.discoverChildAgents(ctx, "both").diagnostics.some((d) => d.error.includes("symlink escapes")));
    assert.equal(fs.readFileSync(user, "utf8"), profile("worker", "user worker"));
    put(path.join(cwd, ".pi", "agents", "vendor", ".agents", "nested.md"), profile("nested-leak", "must not discover"));
    assert(!config.discoverChildAgents(ctx, "both").agents.some((a) => a.name === "nested-leak"));
    put(path.join(process.env.PI_CODING_AGENT_DIR, "settings.json"), JSON.stringify({ subagents: { agentOverrides: { custom: { disabled: true, tools: ["read"] }, reviewer: { disabled: true } } } }));
    const overridden = config.discoverChildAgents(ctx, "both");
    assert.equal(overridden.agents.find((a) => a.name === "custom").disabled, true);
    assert.match(overridden.agents.find((a) => a.name === "reviewer").error, /Settings override/);
    const packageDir = path.join(dir, "package");
    put(path.join(packageDir, "package.json"), JSON.stringify({ name: "fixture", "pi-subagents": { agents: ["agents"] } }));
    put(path.join(packageDir, "agents", "packaged.md"), profile("packaged", "package prompt", "package: analysis\n"));
    put(path.join(process.env.PI_CODING_AGENT_DIR, "settings.json"), JSON.stringify({ packages: [packageDir] }));
    assert.equal(config.discoverChildAgents(ctx, "both").agents.find((a) => a.name === "analysis.packaged").source, "package");
    const other = path.join(dir, "other"); fs.mkdirSync(other);
    assert.equal(config.childTargetContext(ctx, fs.realpathSync(other)).isProjectTrusted(), false);
    new ProjectTrustStore(process.env.PI_CODING_AGENT_DIR).set(other, true);
    assert.equal(config.childTargetContext(ctx, fs.realpathSync(other)).isProjectTrusted(), true);
    assert.equal(config.childTargetContext({ ...ctx, isProjectTrusted: () => false }, fs.realpathSync(cwd)).isProjectTrusted(), false);
    assert.deepEqual(config.childDefaults({}), { concurrency: 4, thinking: undefined, model: undefined, context: "fresh", scope: "both" });
    assert.equal(config.childDefaults({ SHEPHERD_CHILD_CONCURRENCY: "9", SHEPHERD_CHILD_MODEL: "x/y", SHEPHERD_CHILD_CONTEXT: "fork" }).concurrency, 9);
    assert.throws(() => config.childDefaults({ SHEPHERD_CHILD_CONCURRENCY: "99" }), /1..16/);
  } finally { process.env.HOME = oldHome; if (oldExtra === undefined) delete process.env.PI_SUBAGENT_EXTRA_AGENT_DIRS; else process.env.PI_SUBAGENT_EXTRA_AGENT_DIRS = oldExtra; if (old === undefined) delete process.env.PI_CODING_AGENT_DIR; else process.env.PI_CODING_AGENT_DIR = old; fs.rmSync(dir, { recursive: true, force: true }); }
});

test("mission records persist privately, isolate projects, bound writes and keep failed updates atomic", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "shepherd-missions-"));
  try {
    const a = path.join(dir, "a"), b = path.join(dir, "b"); fs.mkdirSync(a); fs.mkdirSync(b);
    const store = missionStore(dir, a), mission = store.create("../../not-a-path", "objective");
    store.update(mission.id, (m) => { m.status = "active"; m.state.answer = 42; });
    assert.equal(missionStore(dir, a).read(mission.id).state.answer, 42);
    assert.throws(() => missionStore(dir, b).read(mission.id), /ENOENT/);
    assert.throws(() => store.read("../outside"), /Invalid mission id/);
    assert.throws(() => store.update(mission.id, (m) => { m.summary = "x".repeat(256 * 1024); }), /exceeds/);
    assert.equal(store.read(mission.id).summary, undefined);
    const projectDir = path.join(dir, "missions", fs.readdirSync(path.join(dir, "missions"))[0]);
    assert.equal(fs.statSync(path.join(projectDir, `${mission.id}.json`)).mode & 0o777, 0o600);
    assert.equal(fs.statSync(projectDir).mode & 0o777, 0o700);
    const before = fs.readFileSync(path.join(projectDir, `${mission.id}.json`));
    fs.mkdirSync(path.join(projectDir, `${mission.id}.json.lock`));
    assert.throws(() => store.update(mission.id, () => {}), /locked/);
    assert.deepEqual(fs.readFileSync(path.join(projectDir, `${mission.id}.json`)), before);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test("workflow JSON boundary rejects host constructors, imports, thenables and host errors", async () => {
  const call = async (method) => { if (method === "cancel") throw Error("host failure"); return { nested: { value: 7 } }; };
  const output = await executeWorkflow(`
    const probes = [runs.run, runs, runs.run("x", { task:"x" })];
    const response = await probes[2]; probes.push(response.nested);
    try { await runs.cancel("x"); } catch (error) { probes.push(error); }
    const escaped = probes.map(value => { try { return value.constructor.constructor("return process")().pid; } catch { return false; } });
    let imported = false; try { await import("node:fs"); imported = true; } catch {}
    return { escaped, imported, globals: [typeof process, typeof require, typeof fetch] };
  `, call, { timeoutMs: 2000 });
  assert(output.escaped.every((p) => p === false)); assert.equal(output.imported, false);
  assert.deepEqual(output.globals, ["undefined", "undefined", "undefined"]);
  await assert.rejects(executeWorkflow('return runs.cancel("x");', call, { timeoutMs: 2000 }), /host failure/);
  const thenable = await executeWorkflow('return { then(resolve) { try { resolve(resolve.constructor("return process")().pid); } catch { resolve("blocked"); } } };', call, { timeoutMs: 2000 });
  assert.equal(thenable, "blocked");
  await assert.rejects(executeWorkflow('return { get value() { while(true) {} } };', call, { timeoutMs: 200 }), /deadline|synchronous/);
  await assert.rejects(executeWorkflow('throw { get message() { while(true) {} } };', call, { timeoutMs: 200 }), /deadline|synchronous/);
});

test("worker deadlines cover synchronous, async and microtask loops and stalled dispatch; admission is bounded", async () => {
  for (const script of ['while(true) {}', 'await Promise.resolve(); while(true) {}', 'await new Promise(() => {});', 'await new Promise(() => { function spin() { Promise.resolve().then(spin); } spin(); });']) {
    const start = Date.now();
    await assert.rejects(executeWorkflow(script, () => {}, { timeoutMs: 200 }), /deadline|synchronous/);
    assert(Date.now() - start < 3000);
  }
  let count = 0;
  await assert.rejects(executeWorkflow('for(let i=0;i<10000;i++) runs.run("x"+i,{task:"x"}).catch(()=>{}); return 1;', () => { count++; return new Promise(() => {}); }, { timeoutMs: 200 }), /pending|deadline|synchronous/);
  assert(count <= 64);
  const controller = new AbortController();
  const pending = executeWorkflow('return runs.run("x",{task:"x"});', () => new Promise(() => {}), { signal: controller.signal, timeoutMs: 5000 });
  setTimeout(() => controller.abort(), 100);
  await assert.rejects(pending, /cancelled/);
});

const ui = await jiti.import(path.join(root, "Extensions/shepherd-children-ui.ts"));
const inspector = await import(path.join(root, "Extensions/shepherd-inspect.mjs"));
const { visibleWidth } = await import(path.join(pkg, "node_modules/@earendil-works/pi-tui/dist/index.js"));

test("native slash parsing strips trailing flags only, quotes scripts safely, rejects unsupported config, and names collisions", () => {
  const plain = ui.parseRunCommand('worker fix --bg in task --fork --bg --fork');
  assert.equal(plain.async, true);
  assert.equal(plain.task, 'fix --bg in task');
  assert.match(plain.workflowScript, /"context":"fork"/);
  assert.equal(ui.parseRunCommand('scout inspect').async, false);
  assert(!ui.parseRunCommand('scout inspect').workflowScript.includes('context'));
  assert.throws(() => ui.parseRunCommand('worker[model=x] inspect'), /unsupported/);
  assert.throws(() => ui.parseRunCommand('worker [model=x] inspect'), /unsupported/);
  assert.throws(() => ui.parseRunCommand('worker --bg --fork'), /Usage/);
  assert.throws(() => ui.parseRunCommand('--bg worker inspect'), /agent before/);
  const hostile = 'worker "); throw Error("escape"); //';
  const parsed = ui.parseRunCommand(hostile);
  assert.equal(JSON.parse(parsed.workflowScript.slice(parsed.workflowScript.indexOf('{'), -2)).task, hostile.slice(7));
  assert.equal(ui.nativeCommandNames([], []).run, 'run');
  assert.equal(ui.nativeCommandNames([{name:'run:1'}], []).run, 'shepherd-run');
  assert.equal(ui.nativeCommandNames([], [{name:'subagent'}]).subagents, 'shepherd-subagents');
  assert.equal(ui.nativeCommandNames([{name:'run'}, {name:'shepherd-run'}], []).run, 'shepherd-shepherd-run');
});

test("fleet ordering, frozen age, narrow Unicode rendering and stable paused transcript anchors", () => {
  const rows = [
    {id:'done',state:'complete',task:'completed',startedAt:1000,endedAt:61000},
    {id:'live',state:'running',task:'working',startedAt:2000},
    {id:'fail',state:'failed',task:'failed',startedAt:3000,endedAt:5000},
    {id:'ask',state:'complete',needsReply:true,task:'needs input',startedAt:4000,endedAt:5000},
  ];
  assert.deepEqual(ui.orderedFleet(rows).map((r) => r.id), ['ask','live','fail','done']);
  assert.equal(ui.fleetRow(rows[0],100,false,100000), ui.fleetRow(rows[0],100,false,200000));
  assert.equal(inspector.duration(1000, null, 9000), 'duration unavailable');
  for (const width of [1, 8, 24, 80]) {
    const line = ui.fleetRow({...rows[0],task:'界🙂e\u0301'.repeat(40)},width,true);
    assert(visibleWidth(line) <= width, `${width}: ${line}`);
  }
  const view = new inspector.TranscriptViewport();
  const lines = Array.from({length:10}, (_,i) => ({key:String(i),text:`line ${i}`}));
  view.update(lines,3); view.scroll(-3);
  assert.deepEqual(view.update(lines,3), ['line 4','line 5','line 6']);
  const appended = [...lines, {key:'10',text:'new output'}];
  assert.deepEqual(view.update(appended,3), ['line 4','line 5','line 6']);
  assert.equal(view.label, 'paused · 1 new');
  view.update(appended,3); assert.equal(view.label, 'paused · 1 new');
  view.follow(); assert.equal(view.label,'following');
});

test("standalone status dots resolve all four theme roles as true color and fall back without a file", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'shepherd-theme-'));
  try {
    const file = path.join(dir, 'theme.json');
    fs.writeFileSync(file, JSON.stringify({ colors: { success:'#123456', accent:'#AbCdEf', mdLink:'#654321', dim:'#987654' } }));
    const colors = inspector.readThemeColors(file);
    for (const [run, rgb, fallback] of [
      [{state:'running'}, '18;52;86', 107], [{state:'complete',needsReply:true}, '171;205;239', 173],
      [{state:'complete'}, '101;67;33', 103], [{state:'idle'}, '152;118;84', 240],
    ]) {
      assert.equal(inspector.ansiStatusDot(run, colors), `\x1b[38;2;${rgb}m●\x1b[0m`);
      assert.equal(inspector.ansiStatusDot(run, inspector.readThemeColors(path.join(dir,'missing'))), `\x1b[38;5;${fallback}m●\x1b[0m`);
    }
  } finally { fs.rmSync(dir,{recursive:true,force:true}); }
});

test("transcript error expansion and bounded evidence notices are explicit and terminal escapes are inert", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'shepherd-view-'));
  try {
    const file = path.join(dir,'session.jsonl');
    const messages = [
      {role:'user',content:'user\n'.repeat(10)},
      {role:'assistant',content:[{type:'text',text:'**bold** `code` [link](https://example.test)'},{type:'toolCall',name:'bash',arguments:{command:'test'}}]},
      {role:'toolResult',toolName:'bash',isError:true,content:[{type:'text',text:'failed first\nfull evidence\n\x1b[2Junsafe'}]},
    ];
    fs.writeFileSync(file,messages.map((message,i) => JSON.stringify({type:'message',id:String(i),message})).join('\n')+'\n');
    const collapsed = inspector.readTranscript(file,80);
    assert(collapsed.lines.some((l) => l.text === 'bold code link'));
    assert(collapsed.lines.some((l) => l.text.includes('error · bash · collapsed')));
    assert(!collapsed.lines.some((l) => l.text === 'full evidence'));
    const expanded = inspector.readTranscript(file,80,true);
    assert(expanded.lines.some((l) => l.text === 'full evidence'));
    assert(!expanded.lines.some((l) => l.text.includes('\x1b')));
    assert.equal(expanded.lines.filter((l) => l.text === 'user').length,11);
    assert.match(inspector.readTranscript(file,80,true,100000,3).omitted, /older lines omitted/);
    assert.match(inspector.readTranscript(file,80,true,250).omitted, /older bytes omitted/);
  } finally { fs.rmSync(dir,{recursive:true,force:true}); }
});

test("fleet component preserves identity/drafts, refreshes lifecycle while paused, and confirms explicit stop target", async () => {
  const rows = [{id:'a',role:'scout',task:'first',state:'running',startedAt:1000},{id:'b',role:'worker',task:'second',state:'running',startedAt:2000}];
  const stopped = [], sent = [];
  const keys = {matches:(data,id) => data === ({'tui.select.cancel':'\x1b','tui.select.up':'up','tui.select.down':'down','tui.input.tab':'\t'}[id]),getKeys:(id)=>[id.split('.').at(-1)]};
  const runtime = {list:()=>rows,stop:async(id)=>{stopped.push(id);return{id,state:'stopped'};},send:async(id,message,mode)=>{sent.push({id,message,mode});return{delivery:'accepted or queued',mode};}};
  const view = new ui.FleetView(runtime,{terminal:{rows:36},requestRender(){}},{fg:(_c,s)=>s},keys,()=>{},'a');
  view.focused = true;
  view.render(100); rows[1].state='failed'; view.render(100); assert.equal(view.selectedID,'a');
  view.handleInput('s'); view.input.setValue('draft a'); view.handleInput('\t'); view.handleInput('\x1b');
  view.handleInput('down'); assert.equal(view.selectedID,'b');
  view.handleInput('s'); view.input.setValue('draft b'); view.handleInput('\x1b'); view.handleInput('up'); view.handleInput('s');
  assert.equal(view.input.getValue(),'draft a'); assert.equal(view.mode,'followUp'); assert(view.input.focused);
  await view.submit(); assert.deepEqual(sent,[{id:'a',message:'draft a',mode:'followUp'}]);
  assert.match(view.notice,/accepted or queued/);
  view.handleInput('x'); assert.deepEqual(stopped,[]); assert.equal(view.confirming,'a');
  rows[1].startedAt=9999; view.render(100); view.handleInput('y'); await new Promise((r)=>setImmediate(r)); assert.deepEqual(stopped,['a']);
  view.view().scroll(-1); rows[0].state='failed'; rows[0].error='failed while paused';
  const frame = view.render(100); assert(frame.some((l)=>l.includes('failed while paused')));
  for (const width of [20,40,100]) assert(view.render(width).every((line)=>visibleWidth(line)<=width));
  view.tui.terminal.rows=10; view.handleInput('s'); assert(view.render(100).some((l)=>l.includes('reply · resumes a · to scout')));
  view.handleInput('\x1b'); view.tui.terminal.rows=36;
  view.handleInput('p'); assert(view.render(100).some((l)=>l.includes('full transcript:')));
});

test("native command handlers use direct operations, gate overlays by mode, and require stop confirmation", async () => {
  const commands = new Map(), entries = [], messages = [], calls = [];
  const pi = {getCommands:()=>[{name:'run'}],getAllTools:()=>[],registerCommand:(n,c)=>commands.set(n,c),registerEntryRenderer(){},appendEntry:(_t,e)=>entries.push(e),sendMessage:(m,o)=>messages.push({m,o})};
  const run = {id:'native-a',role:'scout',task:'task',state:'running'};
  const runtime = {defaults:{scope:'bundled',context:'fresh'},catalog:()=>({agents:[],diagnostics:[]}),doctor:()=>['supported'],list:()=>[run],get:()=>run,
    workflow:async(p)=>{calls.push(p);return{id:'w',state:'complete',output:'ok'};},stop:async(id)=>{calls.push(id);return{id,state:'stopped'};},missions:()=>[],workflows:()=>[]};
  ui.registerNativeCommands(pi,runtime);
  const ctx = {mode:'rpc',hasUI:true,ui:{custom:()=>assert.fail('RPC must not open a custom overlay'),notify(){},confirm:async()=>false,select:async()=>undefined}};
  await commands.get('shepherd-run').handler('scout inspect --fork',ctx); assert.equal(calls[0].async,false);
  await commands.get('shepherd-run').handler('scout inspect --bg',ctx); assert.equal(calls[1].async,true);
  await commands.get('shepherd-subagents-fleet').handler('',ctx);
  await commands.get('shepherd-subagents-stop').handler('native-a',ctx); assert.equal(calls.length,2);
  ctx.ui.confirm=async()=>true; await commands.get('shepherd-subagents-stop').handler('native-a',ctx); assert.equal(calls.at(-1),'native-a');
  await commands.get('shepherd-subagents-doctor').handler('',ctx); assert(entries.at(-1).text.includes('/shepherd-run'));
  await commands.get('shepherd-subagents-fleet').handler('',{mode:'print',hasUI:false});
  assert(messages.every(({o})=>o.triggerTurn===false && o.deliverAs !== 'nextTurn'));
  assert(entries.some((e)=>e.text.includes('native-a')));
});

test("standalone inspector refreshes lifecycle while paused, distinguishes literal stop, confirms run-wide stop and exits on ctrl+c", async () => {
  const { spawn } = await import('node:child_process');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(),'shepherd-inspector-'));
  const file = path.join(dir,'session.jsonl'), statusFile = path.join(dir,'status.json');
  fs.writeFileSync(file, JSON.stringify({type:'message',id:'m1',message:{role:'assistant',content:[{type:'text',text:Array.from({length:70},(_,i)=>`line ${i}`).join('\n')}]}})+'\n');
  const status = {runId:'fixture',state:'running',startedAt:1000,steps:[{agent:'scout',label:'task',status:'running',sessionFile:file},{agent:'reviewer',status:'running'}]};
  fs.writeFileSync(statusFile,JSON.stringify(status));
  const themeFile = path.join(dir,'active theme.json');
  fs.writeFileSync(themeFile,JSON.stringify({colors:{success:'#123456',accent:'#abcdef'}}));
  const proc = spawn(process.execPath,[path.join(root,'Extensions/shepherd-inspect.mjs'),'--async-dir',dir,'--run-id','fixture','--index','0','--theme-path',themeFile],{stdio:['pipe','pipe','pipe']});
  let output = '', stderr=''; proc.stdout.on('data',(d)=>output+=d); proc.stderr.on('data',(d)=>stderr+=d);
  const until = async (fn) => { const end=Date.now()+6000; while(!fn()) { if(Date.now()>end) throw Error(`inspector timeout: ${stderr}`); await new Promise((r)=>setTimeout(r,20)); } };
  const input = async (text) => { const before=output.length; proc.stdin.write(text); await until(()=>output.length>before); };
  try {
    await until(()=>output.includes('following'));
    assert(output.includes('\x1b[38;2;18;52;86m●\x1b[0m'));
    fs.writeFileSync(themeFile,JSON.stringify({colors:{success:'#654321',accent:'#abcdef'}}));
    await until(()=>output.slice(output.lastIndexOf('\x1b[H')).includes('\x1b[38;2;101;67;33m●\x1b[0m'));
    await input('\x1b[5~'); assert(output.includes('paused'));
    status.state='failed'; status.steps[0].status='failed'; status.endedAt=61000; status.controlNotice='control failed: fixture error';
    fs.writeFileSync(statusFile,JSON.stringify(status));
    await until(()=>output.includes('control failed: fixture error'));
    assert(inspector.cleanText(output).includes('failed · 1m 0s · task'));
    const lastFrame = output.slice(output.lastIndexOf('\x1b[H')); assert(lastFrame.includes('paused'));
    await input('stop\r');
    const inbox=path.join(dir,'control','steer-requests');
    await until(()=>fs.existsSync(inbox)&&fs.readdirSync(inbox).length===1);
    const request=JSON.parse(fs.readFileSync(path.join(inbox,fs.readdirSync(inbox)[0]))); assert.equal(request.message,'stop'); assert.equal(request.targetIndex,0);
    status.controlNotice='message accepted or queued'; status.controlRequestID=request.id;
    fs.writeFileSync(statusFile,JSON.stringify(status));
    await until(()=>output.slice(output.lastIndexOf('\x1b[H')).includes('message accepted or queued'));
    await input('second\r');
    assert(output.slice(output.lastIndexOf('\x1b[H')).includes('awaiting runtime'));
    assert(!output.slice(output.lastIndexOf('\x1b[H')).includes('message accepted or queued'));
    const second = fs.readdirSync(inbox).map((name)=>JSON.parse(fs.readFileSync(path.join(inbox,name)))).find((r)=>r.message==='second');
    status.controlRequestID=second.id; status.controlNotice='control failed: second request rejected';
    fs.writeFileSync(statusFile,JSON.stringify(status));
    await until(()=>output.slice(output.lastIndexOf('\x1b[H')).includes('control failed: second request rejected'));
    assert(!output.slice(output.lastIndexOf('\x1b[H')).includes('awaiting runtime'));
    fs.rmSync(inbox,{recursive:true}); fs.writeFileSync(inbox,'not a directory');
    await input('failed write\r');
    assert(output.slice(output.lastIndexOf('\x1b[H')).includes('control failed:'));
    assert(!output.slice(output.lastIndexOf('\x1b[H')).includes('message accepted or queued'));
    assert(!fs.existsSync(path.join(dir,'control','stop.json')));
    await input(':stop'); await input('\r'); assert(output.includes('all 2 lanes'));
    await input('\x1b[200~y\x1b[201~'); assert(!fs.existsSync(path.join(dir,'control','stop.json')));
    assert(!fs.existsSync(path.join(dir,'control','stop.json')));
    await input('\x1b'); assert(!fs.existsSync(path.join(dir,'control','stop.json')));
    await input(':stop'); await input('\r'); await input('y'); assert(fs.existsSync(path.join(dir,'control','stop.json')));
    const stopRequest=JSON.parse(fs.readFileSync(path.join(dir,'control','stop.json')));
    assert(output.slice(output.lastIndexOf('\x1b[H')).includes('stop request written · awaiting runtime'));
    status.controlRequestID=stopRequest.id; status.controlNotice='stop accepted · stopped';
    fs.writeFileSync(statusFile,JSON.stringify(status));
    await until(()=>output.slice(output.lastIndexOf('\x1b[H')).includes('stop accepted · stopped'));
    assert(!output.slice(output.lastIndexOf('\x1b[H')).includes('awaiting runtime'));
    proc.stdin.write('coalesced\x03tail'); await until(()=>proc.exitCode!==null); assert.equal(proc.exitCode,0);
    console.log('sample inspector header:\n'+lastFrame.split('\n').slice(0,6).map(inspector.cleanText).join('\n'));
  } finally { if(proc.exitCode===null) proc.kill('SIGKILL'); fs.rmSync(dir,{recursive:true,force:true}); }
});


test("sample fleet frame stays flat with attention, work and history", () => {
  const runs = [
    {id:'native-ask',role:'reviewer',model:'fixture/fixture',task:'review API changes',state:'complete',needsReply:true,output:'Which API version should remain compatible?',startedAt:1000,endedAt:83000,latestTool:'read'},
    {id:'native-live',role:'worker',task:'update contract tests',state:'running',startedAt:30000,currentTool:'bash'},
    {id:'native-done',role:'scout',task:'locate API callers',state:'complete',startedAt:2000,endedAt:20000,latestTool:'grep'},
  ];
  const frame = ['NATIVE SUBAGENTS · 3 retained', ...ui.orderedFleet(runs).map((r)=>ui.fleetRow(r,80,r.id==='native-ask',91000)),
    '─'.repeat(80),'reviewer · fixture/fixture · native-ask','needs parent reply · Which API version should remain compatible?',
    '▸ read Sources/API.swift','  result · read · collapsed · e expands','','Which API version should remain compatible?',
    'following · p saved file path','up/down select · pgup/pgdn scroll · end follow · e tools · s message · x stop'];
  assert(frame.every((line)=>visibleWidth(line)<=80));
  console.log('sample fleet frame:\n'+frame.join('\n'));
});

test("inspector input decodes coalesced keys, split UTF-8/CSI, paste and embedded ctrl+c", () => {
  const events = [], input = new inspector.InspectorInput((key)=>events.push(['key',key]),(text)=>events.push(['text',text]));
  const unicode = Buffer.from('界'); input.feed(unicode.subarray(0,1)); input.feed(unicode.subarray(1));
  input.feed('hello\r\x1b['); input.feed('Aafter\x03tail');
  input.feed('\x1b[20'); input.feed('0~:stop\r\n\x1b[A pasted\x1b[201'); input.feed('~\r');
  input.feed('\x1b'); input.flushEscape();
  assert.deepEqual(events.filter(([kind])=>kind==='key').map(([,key])=>key), ['\r','\x1b[A','\x03','\r','\x1b']);
  assert.equal(events.filter(([kind])=>kind==='text').map(([,text])=>text).join(''),'界helloaftertail:stop   pasted');
});

test("80/120 frames retain status, identity, hints, reply mode, workflow warning and draft tail", () => {
  const run = {id:'native-12345678-1234-1234-1234-123456789012',role:'very-long-profile-'.repeat(8), model:'vendor/model'.repeat(8),task:'very long task '.repeat(40),state:'complete',needsReply:true,output:'Which version?',error:'launch failed',startedAt:1000,endedAt:61000,workflowId:'workflow-fixture'};
  const keys = {matches:()=>false,getKeys:(id)=>[({'tui.select.up':'↑','tui.select.down':'↓','tui.select.cancel':'esc','tui.input.submit':'enter','tui.input.tab':'tab'})[id]]};
  for (const width of [80,120]) {
    const colors = [], theme = {fg:(color,text)=>{colors.push({color,text});return text;}};
    const view = new ui.FleetView({list:()=>[run]}, {terminal:{rows:36},requestRender(){}}, theme, keys, ()=>{},run.id);
    let frame = view.render(width).join('\n');
    for (const hint of ['x stop','esc close','s message','pgup/pgdn scroll']) assert(frame.includes(hint));
    assert(frame.includes('native-12345678'));
    assert(colors.some(({color,text})=>color==='accent'&&text==='●'));
    view.handleInput('s'); assert(view.render(width).join('\n').includes('reply · resumes native-12345678'));
    view.composing=false; view.handleInput('x'); frame=view.render(width).join('\n');
    assert(frame.includes('workflow-fixture')); assert(frame.includes('may cancel workflow siblings')); assert(frame.includes('y confirm'));
    const standalone = inspector.inspectorFrame({...run,runId:run.id,steps:[{label:run.task,agent:run.role,model:run.model,status:run.state}]}, {id:run.id,width,height:36,view:new inspector.TranscriptViewport(),prompt:'draft '.repeat(100)+'INSERTION'});
    assert(standalone.every((line)=>visibleWidth(line)<=width));
    const text = inspector.cleanText(standalone.join('\n'));
    for (const value of ['needs reply · 1m 0s','native-12345678','Which version?','launch failed','ctrl+c close','reply · resumes','INSERTION_']) assert(text.includes(value),value);
  }
  const ascii = ui.fleetRow({...run,task:'plain'},80,true), unicode = ui.fleetRow({...run,task:'界🙂e\u0301'},80,true);
  assert.equal(visibleWidth(ascii.split('|').slice(0,2).join('|')), visibleWidth(unicode.split('|').slice(0,2).join('|')));
  assert.deepEqual(inspector.wrapColumns('one two Sources/Legacy',15),['one two','Sources/Legacy']);
  assert.deepEqual(inspector.wrapColumns('abcdefghij',4),['abcd','efgh','ij']);
  assert.equal(inspector.inlineText('**bold** `code` [link](https://example.test)'), 'bold code link');
});

test("fleet reply failure keeps the answer draft and displays the runtime reason", async () => {
  const run={id:'native-ask',state:'complete',needsReply:true,role:'reviewer'}, sent=[];
  const view = new ui.FleetView({list:()=>[run],send:async(...args)=>{sent.push(args);throw Error('Four children are already active; wait or cancel first');}}, {terminal:{rows:36},requestRender(){}},{fg:(_c,s)=>s},{matches:()=>false,getKeys:()=>['esc']},()=>{},run.id);
  view.handleInput('s'); view.input.setValue('keep v1'); await view.submit();
  assert.deepEqual(sent,[['native-ask','keep v1','steer']]);
  assert.equal(view.input.getValue(),'keep v1'); assert(view.composing);
  assert(view.render(80).join('\n').includes('Four children are already active; wait or cancel first'));
});
