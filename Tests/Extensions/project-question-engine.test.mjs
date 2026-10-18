// Canonical worker tool, real pinned pi RPC and a scripted loopback provider; no StubPi or user extensions/auth.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { withPi, until } from './fixtures/pi-rpc-harness.mjs';

const args = ['--no-extensions', '--no-skills', '--no-prompt-templates', '--no-themes', '--no-approve', '-e', path.resolve('Extensions/shepherd-project-context.ts')];
const worker = { SHEPHERD_PROJECT_CONTEXT: '{"projectID":"fixture-project"}', SHEPHERD_PROJECT_COORDINATOR: '0', SHEPHERD_AGENT_ID: 'fixture-worker', SHEPHERD_SOCKET: '/no-question-socket' };
const questionResult = turn => turn.events.find(event => event.type === 'tool_execution_end' && event.toolName === 'project_question');

test('pinned worker emits native select/input, receives exact human answers, and cancels without permission', { timeout: 60000 }, async t => {
  let parameters, issueCall = false;
  await withPi(t, { args, env: worker, settings: { compaction: { enabled: false } }, onRequest: () => {
    if (!issueCall) return {};
    issueCall = false;
    return { tool: { name: 'project_question', arguments: parameters } };
  } }, async pi => {
    for (const row of [
      { parameters: { question: 'Deploy where?', options: ['Staging', 'Production'] }, response: { value: 'Staging' } },
      { parameters: { question: 'Deploy elsewhere?', options: ['Staging', 'Production'] }, response: { value: 'Say anything' }, input: { value: 'Use a preview environment instead.' } },
      { parameters: { question: 'Describe the alternative?', options: ['Say anything', 'Staging'] }, response: { value: 'Say anything' }, input: { cancelled: true } },
      { parameters: { question: 'Stop the alternative?', options: ['Staging', 'Production'] }, response: { value: 'Say anything' }, abortInput: true },
      { parameters: { question: 'What retention period?' }, response: { value: '30 days — no secrets' } },
      { parameters: { question: 'An intentionally empty answer?' }, response: { value: '' } },
      { parameters: { question: 'Choose?', options: ['Yes', 'No'] }, response: { cancelled: true } },
      { parameters: { question: 'Describe?' }, response: { cancelled: true } },
      { parameters: { question: 'Stop this pending question?' }, abort: true },
      { parameters: { question: 'Stop this choice?', options: ['Yes', 'No'] }, abort: true },
      { parameters: { question: '界'.repeat(666) + 'ab', options: Array.from({ length: 16 }, (_, i) => `${i}`.padEnd(256, 'x')) }, response: { cancelled: true } },
    ]) {
      parameters = row.parameters; issueCall = true;
      const mark = pi.events.length, requestMark = pi.provider.requests.length;
      const pendingTurn = pi.prompt('Ask the required Project question.');
      const dialog = await until('the real worker native dialog', () => pi.events.slice(mark).find(event => event.type === 'extension_ui_request'));
      assert.equal(dialog.method, parameters.options ? 'select' : 'input');
      assert.equal(dialog.title, parameters.question);
      assert.deepEqual(dialog.options, parameters.options?.filter(option => option !== 'Say anything').concat('Say anything'));
      assert.equal(pi.provider.requests.length, requestMark + 1, 'waiting for the human starts no evaluator or extra model request');
      assert.ok(!pi.events.slice(mark).some(event => event.type === 'tool_execution_end'), 'question suspends the real tool');
      if (row.abort) assert.equal((await pi.request({ type: 'abort' })).success, true);
      else pi.child.stdin.write(JSON.stringify({ type: 'extension_ui_response', id: dialog.id, ...row.response }) + '\n');
      if (row.input || row.abortInput) {
        const input = await until('Say anything opens a supported native input', () => pi.events.slice(mark).find(event => event.type === 'extension_ui_request' && event.id !== dialog.id));
        assert.equal(input.method, 'input');
        assert.equal(input.title, parameters.question);
        assert.equal(pi.provider.requests.length, requestMark + 1, 'choosing free text starts no extra model request');
        assert.ok(!pi.events.slice(mark).some(event => event.type === 'tool_execution_end'), 'the choice itself is not the worker answer');
        if (row.abortInput) assert.equal((await pi.request({ type: 'abort' })).success, true);
        else pi.child.stdin.write(JSON.stringify({ type: 'extension_ui_response', id: input.id, ...row.input }) + '\n');
      }
      const turn = await pendingTurn;
      assert.ok(turn.requests[0].tools.includes('project_question'), pi.stderr);
      assert.ok(!turn.requests[0].tools.includes('project_answer'));
      const result = questionResult(turn);
      assert.ok(result, pi.stderr);
      assert.equal(result.isError, false);
      const response = row.input ?? row.response;
      const expected = row.abort || row.abortInput || response.cancelled ? { cancelled: true } : { answer: response.value };
      assert.equal(turn.events.filter(event => event.type === 'tool_execution_end' && event.toolName === 'project_question').length, 1);
      assert.deepEqual(JSON.parse(result.result.content[0].text), expected);
      if (!row.abort && !row.abortInput) {
        assert.equal(turn.requests.length, 2, 'only the normal worker follow-up runs');
        const delivered = turn.requests[1].messages.filter(message => message.role === 'tool').at(-1);
        assert.deepEqual(JSON.parse(delivered.content), expected, 'the worker model receives the actual native reply');
      }
      const saved = (await pi.request({ type: 'get_messages' })).data.messages.filter(message => message.role === 'toolResult' && message.toolName === 'project_question').at(-1);
      assert.deepEqual(saved.content, result.result.content, 'native result is in the worker conversation');
    }
  });
});

test('pinned worker rejects invalid and oversized questions before emitting UI', { timeout: 60000 }, async t => {
  let parameters, issueCall = false;
  await withPi(t, { args, env: worker, settings: { compaction: { enabled: false } }, onRequest: () => {
    if (!issueCall) return {};
    issueCall = false;
    return { tool: { name: 'project_question', arguments: parameters } };
  } }, async pi => {
    for (parameters of [{}, { question: '' }, { question: ' \n' }, { question: 'x'.repeat(2001) },
      { question: '界'.repeat(667) }, { question: 'Choose', options: [] }, { question: 'Choose', options: Array.from({ length: 17 }, (_, i) => String(i)) },
      { question: 'Choose', options: ['same', 'same'] }, { question: 'Choose', options: [' '] },
      { question: 'Choose', options: ['x'.repeat(257)] }, { question: 'Choose', options: ['界'.repeat(86)] }]) {
      issueCall = true;
      const mark = pi.events.length;
      const pending = pi.prompt('Ask the required Project question.');
      const boundary = await until('rejection or unexpected UI', () => pi.events.slice(mark).find(event => event.type === 'extension_ui_request' || event.type === 'agent_settled'));
      if (boundary.type === 'extension_ui_request') pi.child.stdin.write(JSON.stringify({ type: 'extension_ui_response', id: boundary.id, cancelled: true }) + '\n');
      const turn = await pending;
      assert.ok(!turn.events.some(event => event.type === 'extension_ui_request'), JSON.stringify(parameters));
      assert.equal(questionResult(turn)?.isError, true, pi.stderr);
      assert.equal(turn.requests.length, 2);
    }
  });
});

for (const [role, env] of [['ordinary', {}], ['coordinator', { ...worker, SHEPHERD_PROJECT_COORDINATOR: '1' }], ['child', { ...worker, SHEPHERD_CHILD: '1' }]]) {
  test(`pinned ${role} never exposes or executes project_question`, { timeout: 60000 }, async t => {
    let call = true;
    await withPi(t, { args, env, onRequest: () => {
      if (!call) return {};
      call = false;
      return { tool: { name: 'project_question', arguments: { question: 'Must not appear' } } };
    } }, async pi => {
      const turn = await pi.prompt('Report available tools.');
      assert.ok(!turn.requests[0].tools.includes('project_question'));
      assert.ok(!turn.requests[0].tools.includes('ask_user'), 'the pinned engine has no built-in ask_user');
      assert.ok(!turn.events.some(event => event.type === 'extension_ui_request'));
      assert.equal(questionResult(turn)?.isError, true);
    });
  });
}
