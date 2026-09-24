// Opt-in real model smoke. Uses existing authentication; does not edit configuration.
// PI_SMOKE_MODEL=anthropic/claude-haiku-4-5 node Tests/Extensions/native-children.smoke.mjs
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { spawn, execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";
if (!process.env.PI_SMOKE_MODEL) throw Error("Set PI_SMOKE_MODEL to opt in to three small model requests");
const source = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../Extensions/shepherd-children.ts");
const pkg = process.env.PI_PACKAGE_DIR || (() => {
  let dir = path.dirname(fs.realpathSync(execFileSync("which", ["pi"], { encoding: "utf8" }).trim()));
  while (!fs.existsSync(path.join(dir, "package.json")) && path.dirname(dir) !== dir) dir = path.dirname(dir);
  return dir;
})();
const dir = fs.mkdtempSync(path.join(os.tmpdir(), "shepherd-smoke-"));
const driver = path.join(dir, "driver.ts");
const require = createRequire(path.join(pkg, "package.json"));
const { createJiti } = require("jiti");
const jiti = createJiti(import.meta.url, { alias: { "@earendil-works/pi-coding-agent": path.join(pkg, "dist/index.js") } });
const { childUserExtensions } = await jiti.import(path.join(path.dirname(source), "shepherd-children-config.ts"));
const userExtensions = await childUserExtensions(dir);
fs.writeFileSync(driver, `import children from ${JSON.stringify(source)};
export default function(pi) { const tools = new Map(); children(new Proxy(pi, { get(target,key) { if(key==='registerTool') return (tool)=>{tools.set(tool.name,tool);target.registerTool(tool);}; if(key==='sendMessage') return (message)=>target.sendMessage(message,{deliverAs:'nextTurn'}); return target[key]; } }));
pi.registerCommand('smoke', {description:'bounded smoke', handler:async (args,ctx)=>{const input=JSON.parse(args);const value=await tools.get('shepherd_child_'+input.action).execute('smoke',input.params,undefined,undefined,ctx);ctx.ui.notify(JSON.stringify({shepherdSmokeReceipt:value.details}));}}); }
`);
const parent = spawn(process.execPath, [path.join(pkg, "dist/cli.js"), "--mode", "rpc", "--no-extensions", "--no-skills", "--no-context-files", "--no-prompt-templates", "--no-themes", "--no-approve", "--session", path.join(dir, "parent.jsonl"), "--model", process.env.PI_SMOKE_MODEL, "-e", driver, ...userExtensions.flatMap((file) => ["-e", file])], {
  cwd: dir, env: { ...process.env, PI_OFFLINE: "1", SHEPHERD_CHILD_SCOPE: "bundled", SHEPHERD_NATIVE_CHILDREN: "1", SHEPHERD_AGENT_ID: "smoke", SHEPHERD_SOCKET: path.join(dir, "shepherd.sock"), SHEPHERD_EXT_CHILDREN: source }, stdio: ["pipe", "pipe", "pipe"],
});
let buffer = "", sequence = 0; const events = []; let stderr = "";
parent.stdout.setEncoding("utf8"); parent.stdout.on("data", (chunk) => { buffer += chunk; for (;;) { const end = buffer.indexOf("\n"); if (end < 0) break; const line = buffer.slice(0,end); buffer=buffer.slice(end+1); try { events.push(JSON.parse(line)); } catch {} } });
parent.stderr.on("data",(d)=>{stderr=(stderr+d).slice(-2048);}); parent.stdin.on("error",()=>{});
async function until(fn) { const end=Date.now()+90000; while(!fn()){if(Date.now()>end)throw Error('smoke timeout: '+stderr);await new Promise(r=>setTimeout(r,30));} }
async function invoke(action, params) {
 const id=String(++sequence), start=events.length; parent.stdin.write(JSON.stringify({id,type:'prompt',message:'/smoke '+JSON.stringify({action,params})})+'\n');
 await until(()=>events.some(e=>e.type==='response'&&e.id===id)); const reply=events.find(e=>e.type==='response'&&e.id===id); assert(reply.success,JSON.stringify(reply));
 const receipt = events.slice(start).filter(e=>e.type==='extension_ui_request'&&e.method==='notify').map(e=>{try{return JSON.parse(e.message);}catch{return null;}}).find(e=>e && Object.hasOwn(e,'shepherdSmokeReceipt'));
 assert(receipt,'missing receipt');return receipt.shepherdSmokeReceipt;
}
try {
 if (process.env.PI_SMOKE_SINGLE === '1') {
  const started = await invoke('start', { task: 'Reply with exactly pong. Do not use tools.', role: 'scout', thinking: 'off' });
  const finished = await invoke('wait', { ids: [started.id], all: true, timeoutSeconds: 60 });
  const run = finished[0];
  assert.equal(run.state, 'complete', JSON.stringify({ state: run.state, error: run.error }));
  assert.equal(run.output.trim().toLowerCase(), 'pong');
  console.log(JSON.stringify({ model: process.env.PI_SMOKE_MODEL, state: run.state, output: run.output, settled: run.settled }));
 } else {
 const a=await invoke('start',{task:'Reply with exactly ALPHA. Do not use tools.',role:'scout',thinking:'off'});
 const b=await invoke('start',{task:'Reply with exactly BETA. Do not use tools.',role:'scout',thinking:'off'});
 const done=await invoke('wait',{ids:[a.id,b.id],all:true,timeoutSeconds:60});
 assert(done.every(r=>r.state==='complete'),JSON.stringify(done));assert.match(done[0].output,/ALPHA/);assert.match(done[1].output,/BETA/);
 await invoke('resume',{id:a.id,message:'What exact word did you reply with last time? Reply with only that word. Do not use tools.'});
 const continuation=await invoke('wait',{ids:[a.id],timeoutSeconds:60});assert.equal(continuation[0].state,'complete');assert.match(continuation[0].output,/ALPHA/);
 console.log(JSON.stringify({model:process.env.PI_SMOKE_MODEL,parallel:done.map(r=>({state:r.state,output:r.output})),continuation:continuation[0].output}));
 }
} finally {
 parent.stdin.end(); await until(()=>parent.exitCode!==null||parent.signalCode!==null).catch(()=>parent.kill('SIGKILL'));
 fs.rmSync(dir,{recursive:true,force:true});
}
