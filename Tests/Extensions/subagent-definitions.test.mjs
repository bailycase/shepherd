import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const pkg = process.env.PI_PACKAGE_DIR;
if (!pkg) throw Error('Set PI_PACKAGE_DIR to the pinned pi package');
const require = createRequire(path.join(pkg, 'package.json'));
const {createJiti} = require('jiti');
const sdk = fs.existsSync(path.join(pkg,'dist/index.js')) ? path.join(pkg,'dist/index.js') : path.join(pkg,'dist/bundle/index.js');
const jiti = createJiti(import.meta.url, {alias:{'@earendil-works/pi-coding-agent':sdk}});
const config = await jiti.import(path.join(root,'Extensions/shepherd-children-config.ts'));
const profile = (name, options='') => `---\nname: ${name}\ndescription: Real fixture definition\ntools: [read]\n${options}---\nInstructions from disk.\n`;
const put = (file,text) => {fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,text);};

function fixture(run) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(),'sh-owned-agents-'));
  const old = process.env.PI_CODING_AGENT_DIR;
  process.env.PI_CODING_AGENT_DIR = path.join(dir,'pi');
  try {run(dir, path.join(dir,'pi/agents'));}
  finally {
    if(old === undefined) delete process.env.PI_CODING_AGENT_DIR; else process.env.PI_CODING_AGENT_DIR = old;
    fs.rmSync(dir,{recursive:true,force:true});
  }
}

test('only owned files load and deleting defaults survives discovery', () => fixture((dir, owned) => {
  const cwd = path.join(dir,'project');
  put(path.join(cwd,'.pi/agents/scout.md'),profile('scout','runner: forbidden\n'));
  put(path.join(cwd,'.agents/outside.md'),profile('outside'));
  put(path.join(dir,'extra/extra.md'),profile('extra'));
  let catalog = config.discoverChildAgents({cwd,isProjectTrusted:()=>true},'both');
  assert.deepEqual(catalog.agents.map(a=>a.name).sort(),['planner','reviewer','scout','worker']);
  assert(catalog.agents.every(a=>a.source==='shepherd' && a.filePath.startsWith(owned + path.sep)));
  assert.equal(catalog.diagnostics.length,0);
  fs.unlinkSync(path.join(owned,'scout.md'));
  catalog = config.discoverChildAgents({cwd,isProjectTrusted:()=>false},'bundled');
  assert(!catalog.agents.some(a=>a.name==='scout'), 'an in-memory builtin must not resurrect a deleted file');
  put(path.join(owned,'reviewer.md'),profile('reviewer','runner: forbidden\n'));
  catalog = config.discoverChildAgents({cwd},'user');
  assert.match(catalog.agents.find(a=>a.name==='reviewer').error,/Unsupported agent fields: runner/);
  assert.equal(config.childDefaults({SHEPHERD_CHILD_SCOPE:'project'}).scope,'shepherd');
}));

test('the shared parser reports invalid fields, empty instructions and inherited tools', () => {
  assert.throws(()=>config.parseChildAgent(profile('bad','runner: other\n'),'/scratch/bad.md'),/Unsupported agent fields: runner/);
  assert.throws(()=>config.parseChildAgent('---\nname: empty\ndescription: Empty\n---\n','/scratch/empty.md'),/empty prompt/);
  assert.throws(()=>config.parseChildAgent(profile('bad').replace('tools: [read]','tools: inherit'),'/scratch/bad.md'),/tools: inherit/);
  const parsed = config.parseChildAgent(profile('review','defaultContext: fork\nthinking: high\n'),'/scratch/review.md');
  assert.equal(parsed.context,'fork'); assert.equal(parsed.thinking,'high'); assert.deepEqual(parsed.tools,['read']);
  assert.equal(parsed.prompt,'Instructions from disk.');

});

test('supported resource paths resolve tilde inside the isolated home',()=>fixture((dir,owned)=>{
  const oldHome=process.env.HOME; process.env.HOME=dir;
  try {
    put(path.join(dir,'owned-extension.ts'),'export default ()=>{};');
    fs.mkdirSync(path.join(dir,'owned-skills'));
    const parsed=config.parseChildAgent(profile('paths','extensions: [~/owned-extension.ts]\nskillPath: [~/owned-skills]\n'),path.join(owned,'paths.md'));
    assert.equal(parsed.extensions[0],fs.realpathSync(path.join(dir,'owned-extension.ts')));
    assert.equal(parsed.skillPaths[0],fs.realpathSync(path.join(dir,'owned-skills')));
  } finally { if(oldHome===undefined) delete process.env.HOME; else process.env.HOME=oldHome; }
}));

test('unsafe and duplicate files fail closed and no unsafe file is overwritten', () => fixture((dir,owned)=>{
  config.ensureChildAgents();
  put(path.join(dir,'outside.md'),profile('outside'));
  fs.symlinkSync(path.join(dir,'outside.md'),path.join(owned,'unsafe.md'));
  put(path.join(owned,'same-a.md'),profile('same'));
  put(path.join(owned,'same-b.md'),profile('same'));
  const catalog = config.discoverChildAgents({cwd:dir},'shepherd');
  assert(catalog.agents.find(a=>a.name==='unsafe').error);
  assert(catalog.agents.filter(a=>a.name==='same').every(a=>/Duplicate subagent name/.test(a.error)));
  assert.equal(fs.readFileSync(path.join(dir,'outside.md'),'utf8'),profile('outside'));
  assert.throws(()=>config.parseChildAgent(profile('missing').replace('description: Real fixture definition','description: ""'),'/scratch/missing.md'),/name and description/);
}));

test('discovery refuses its file bound rather than running a partial catalog', () => fixture((dir,owned)=>{
  config.ensureChildAgents();
  for(let i=0;i<509;i++) put(path.join(owned,`helper-${i}.md`),profile(`helper-${i}`));
  const catalog=config.discoverChildAgents({cwd:dir},'shepherd');
  assert.equal(catalog.agents.length,0);
  assert(catalog.diagnostics.some(d=>d.error.includes('512 subagent files')));
}));

test('a symlinked owned folder is rejected rather than reading another folder', () => fixture((dir,owned)=>{
  fs.mkdirSync(path.dirname(owned),{recursive:true});
  const outside = path.join(dir,'outside'); fs.mkdirSync(outside);
  put(path.join(outside,'agent.md'),profile('outside'));
  fs.symlinkSync(outside,owned);
  const catalog = config.discoverChildAgents({cwd:dir},'shepherd');
  assert.deepEqual(catalog.agents,[]); assert.match(catalog.diagnostics[0].error,/symbolic link/);
  assert.deepEqual(fs.readdirSync(outside),['agent.md']);
}));
