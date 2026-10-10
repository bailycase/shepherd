import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { withPi } from './fixtures/pi-rpc-harness.mjs';

const fixture = JSON.parse(readFileSync(new URL('./project-plan-results.json', import.meta.url), 'utf8'))[0];

test('pinned Pi exposes worker plan on its first turn and restores the actual tool result', { timeout: 60000 }, async t => {
  let requests = 0;
  await withPi(t, {
    args: ['--no-extensions', '--no-skills', '--no-prompt-templates', '--no-themes', '--no-approve', '-e', path.resolve('Extensions/shepherd-project-context.ts')],
    env: { SHEPHERD_PROJECT_CONTEXT: '{"projectID":"fixture-project"}', SHEPHERD_PROJECT_COORDINATOR: '0', SHEPHERD_AGENT_ID: 'fixture-worker', SHEPHERD_SOCKET: '/no-plan-socket' },
    onRequest: () => requests++ === 0 ? { tool: { name: 'project_plan', arguments: fixture.arguments } } : { text: 'Plan reported, no work inferred.' },
  }, async pi => {
    const turn = await pi.prompt('Report the current turn plan.');
    assert.ok(turn.requests[0].tools.includes('project_plan'), pi.stderr);
    assert.ok(!turn.requests[0].tools.includes('project_assign'));
    const result = turn.events.find(event => event.type === 'tool_execution_end' && event.toolName === 'project_plan');
    assert.ok(result, pi.stderr);
    assert.equal(result.isError, false);
    assert.deepEqual(result.result.content, fixture.result.content);
    const messages = (await pi.request({ type: 'get_messages' })).data.messages;
    const saved = messages.find(message => message.role === 'toolResult' && message.toolName === 'project_plan');
    assert.deepEqual(saved.content, fixture.result.content);
    const sessions = path.join(pi.dir, 'sessions');
    const sessionPath = path.join(sessions, readdirSync(sessions).find(name => name.endsWith('.jsonl')));
    const persisted = readFileSync(sessionPath, 'utf8').trim().split('\n').map(line => JSON.parse(line));
    assert.deepEqual(persisted.find(entry => entry.message?.toolName === 'project_plan').message.content, saved.content);
    assert.equal((await pi.request({ type: 'new_session' })).success, true);
    assert.equal((await pi.request({ type: 'switch_session', sessionPath })).success, true);
    const restored = (await pi.request({ type: 'get_messages' })).data.messages;
    assert.deepEqual(restored.find(message => message.role === 'toolResult' && message.toolName === 'project_plan'), saved);
    assert.equal(requests, 2, 'reload never resumes work or calls a model');
  });
});
