// PI_PACKAGE_DIR must name a staged pinned SDK, never the user's pi command/home.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import net from 'node:net';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { once } from 'node:events';

const pkg = process.env.PI_PACKAGE_DIR;
test('first assigned Pi provider turn sees publisher before consuming the tool; execution uses native user evidence', { skip: !pkg, timeout: 30000 }, async () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'pub-engine-'));
  const home = path.join(dir, 'home'); mkdirSync(home);
  const projectID = 'ed8e0c41-0cbe-48cd-b9bb-92200dd013b5';
  const worker = 'f551aa10-1aee-4d89-a918-99e48d8946e3';
  let consumed = false, child, stderr = '', firstTools, firstConsumed, published = false;
  const eligibility = [];
  const socket = net.createServer(peer => {
    let buffer = '';
    peer.on('data', data => {
      buffer += data;
      if (!buffer.includes('\n')) return;
      const request = JSON.parse(buffer.split('\n')[0]);
      let reply;
      if (request.type === 'projectRuntime') reply = { type: 'projectRuntime', id: request.id,
        project: { id: projectID, revision: 1, goal: '', settings: { instructions: '' }, memory: [], tasks: [{ workerAgentID: worker, phase: 'running' }] } };
      else if (request.request.eligibility) {
        eligibility.push(consumed);
        reply = { type: 'projectPublish', id: request.id, result: { active: consumed } };
      } else {
        assert.equal(request.agentID, worker);
        assert.equal(request.projectID, undefined);
        assert.equal(consumed, true, 'tool call must follow actual native user consumption');
        published = true;
        reply = { type: 'projectPublish', id: request.id, result: { active: true, artifact: { id: request.request.publish.publicationID, state: 'ready', relativePath: 'report.txt' } } };
      }
      peer.end(JSON.stringify(reply) + '\n');
    });
  });
  await new Promise(resolve => socket.listen(path.join(dir, 's'), resolve));
  const provider = http.createServer(async (request, response) => {
    let raw = ''; for await (const bytes of request) raw += bytes;
    const body = JSON.parse(raw);
    if (!firstTools) { firstTools = (body.tools ?? []).map(t => t.function.name); firstConsumed = consumed; }
    const call = !published && firstTools.includes('project_publish');
    const delta = call ? { tool_calls: [{ index: 0, id: 'publish-first', type: 'function', function: { name: 'project_publish', arguments: '{"sourcePath":"source.txt","artifactName":"report.txt"}' } }] } : { content: 'done' };
    response.writeHead(200, { 'content-type': 'text/event-stream' });
    response.write(`data: ${JSON.stringify({ id: 'fixture', object: 'chat.completion.chunk', model: 'fixture', choices: [{ index: 0, delta, finish_reason: null }] })}\n\n`);
    response.end(`data: ${JSON.stringify({ id: 'fixture', object: 'chat.completion.chunk', choices: [{ index: 0, delta: {}, finish_reason: call ? 'tool_calls' : 'stop' }], usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 } })}\n\ndata: [DONE]\n\n`);
  });
  await new Promise(resolve => provider.listen(0, '127.0.0.1', resolve));
  writeFileSync(path.join(home, 'models.json'), JSON.stringify({ providers: { fixture: {
    baseUrl: `http://127.0.0.1:${provider.address().port}/v1`, api: 'openai-completions', apiKey: 'local-fixture-only',
    models: [{ id: 'fixture', name: 'fixture', reasoning: false, input: ['text'], contextWindow: 64000, maxTokens: 1024, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
  } } }));
  try {
    child = spawn(process.execPath, [path.join(pkg, 'dist/cli.js'), '--mode', 'rpc', '--no-extensions', '--no-skills', '--no-prompt-templates', '--no-themes', '--no-approve', '-e', path.resolve('Extensions/shepherd-project-context.ts'), '--model', 'fixture/fixture', '--session', path.join(dir, 'session.jsonl')], {
      cwd: dir, env: { PATH: process.env.PATH, TMPDIR: dir, HOME: dir, PI_CODING_AGENT_DIR: home, PI_OFFLINE: '1', SHEPHERD_PROJECT_CONTEXT: JSON.stringify({ projectID }), SHEPHERD_PROJECT_COORDINATOR: '0', SHEPHERD_AGENT_ID: worker, SHEPHERD_SOCKET: path.join(dir, 's') }, stdio: ['pipe', 'pipe', 'pipe'],
    });
    child.stderr.on('data', data => { stderr += data; });
    const settled = new Promise((resolve, reject) => {
      let buffer = '';
      child.stdout.on('data', data => {
        buffer += data;
        while (buffer.includes('\n')) {
          const end = buffer.indexOf('\n'), line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
          let event; try { event = JSON.parse(line); } catch { continue; }
          if (event.type === 'message_start' && event.message?.role === 'user') consumed = true;
          if (event.type === 'agent_end') resolve();
        }
      });
      child.on('error', reject); child.on('exit', code => { if (code) reject(new Error(`Pi exited ${code}: ${stderr}`)); });
    });
    child.stdin.write(JSON.stringify({ type: 'prompt', message: 'Produce the assigned report.' }) + '\n');
    await settled;
    assert.ok(firstTools?.includes('project_publish'), `first provider tools lacked publisher; eligibility-before-consumption=${JSON.stringify(eligibility)}, native-user-consumed=${firstConsumed}; ${stderr}`);
    assert.equal(published, true);
  } finally {
    if (child && child.exitCode === null) { const exited = once(child, 'exit'); child.kill('SIGTERM'); await exited; }
    provider.closeAllConnections(); await new Promise(resolve => provider.close(resolve));
    await new Promise(resolve => socket.close(resolve)); rmSync(dir, { recursive: true, force: true });
  }
});
