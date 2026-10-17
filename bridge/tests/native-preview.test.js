'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { once } = require('node:events');
const { createInference } = require('../inference');
const { startBridge, sleep } = require('./helpers/bridge');

test('native polls receive real text before upstream completion and retain the exact final body', async t => {
  let answer;
  const upstream = http.createServer((req, res) => { answer = res; });
  upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening');
  t.after(() => { upstream.closeAllConnections(); upstream.close(); });
  const bridge = await startBridge(t);
  const headers = { Authorization: 'Bearer ' + bridge.token, 'content-type': 'application/json' };
  const hello = await (await fetch(bridge.base + '/api/hello', { headers })).json();
  assert.equal(hello.capabilities.inferencePreview.schema, 1);
  const accepted = once(upstream, 'request');
  const input = { id: 'native_preview_live', instance: hello.instance, sessionId: 'native-preview', body: '{}',
    url: `http://127.0.0.1:${upstream.address().port}/chat/completions` };
  const started = await fetch(bridge.base + '/api/inference', { method: 'POST', headers, body: JSON.stringify(input) });
  assert.equal(started.status, 202); await accepted;
  const raw = 'data: ' + JSON.stringify({ model: 'actual-model', choices: [{ delta: { content: 'Live answer',
    tool_calls: [{ function: { name: 'inspect', arguments: '{"private":"not previewed"}' } }], reasoning_content: 'Checking' } }] }) + '\n\n';
  answer.writeHead(200, { 'content-type': 'text/event-stream' }); answer.write(raw);
  const poll = async after => (await fetch(bridge.base + '/api/inference/' + input.id + (after === undefined ? '' : '?after=' + after), { headers })).json();
  let running;
  for (let i = 0; i < 200; i++) { running = await poll(0); if (running.preview.frames.length === 2) break; await sleep(5); }
  assert.equal(running.state, 'running'); assert.equal(running.body, undefined);
  assert.deepEqual(running.preview.frames.map(frame => [frame.channel, frame.text]), [['text', 'Live answer'], ['reasoning', 'Checking']]);
  assert.equal(running.preview.model, 'actual-model'); assert.equal(running.preview.cursor, 3);
  assert.doesNotMatch(JSON.stringify(running.preview), /private|not previewed/);
  assert.deepEqual((await poll(0)).preview, running.preview, 'repeated cursor is stable after a lost response');
  assert.deepEqual((await poll(3)).preview.frames, []);
  assert.equal((await poll()).preview, undefined, 'old clients retain their existing response shape');
  assert.equal((await fetch(bridge.base + '/api/inference/' + input.id + '?after=-1', { headers })).status, 400);
  answer.end('data: [DONE]\n\n');
  let final;
  for (let i = 0; i < 200; i++) { final = await poll(3); if (final.state !== 'running') break; await sleep(5); }
  assert.equal(final.state, 'completed'); assert.equal(final.body, raw + 'data: [DONE]\n\n');
  assert.equal(final.preview, undefined, 'the authoritative final is not padded with duplicate previews');
});

function projected(t) {
  let emit, complete;
  const events = [];
  const opencode = { capability: () => ({ available: true }), accepts: () => true,
    request: ({ onFrame }) => { emit = onFrame; return new Promise(resolve => { complete = resolve; }); } };
  const relay = createInference({ opencode, publish: event => events.push(event) }); t.after(() => relay.close());
  const id = 'native_preview_limits';
  relay.start({ id, instance: relay.instance, url: 'https://provider.invalid', body: '{}', sessionId: 'preview' });
  return { relay, id, events, emit, complete };
}

test('preview pages bound frames and escaped bytes, detect eviction, and preserve UTF-8 prefixes', t => {
  const { relay, id, emit } = projected(t);
  for (let i = 0; i < 300; i++) emit({ choices: [{ delta: { content: 'x'.repeat(500) } }] });
  const first = relay.get(id, 0).preview;
  assert.ok(first.frames.length > 0 && first.frames.length <= 128 && first.cursor < 300);
  assert.ok(Buffer.byteLength(JSON.stringify(first)) <= 65536);
  assert.equal(relay.get(id, first.cursor).preview.frames[0].seq, first.cursor + 1);
  for (let i = 0; i < 4200; i++) emit({ choices: [{ delta: { content: 'x' } }] });
  const gap = relay.get(id, 0).preview;
  assert.equal(gap.gap, true); assert.deepEqual(gap.frames, []);
  const cursor = gap.cursor;
  emit({ choices: [{ delta: { content: '🙂'.repeat(5000) } }] });
  const limited = relay.get(id, cursor).preview;
  assert.equal(limited.limited, true); assert.equal(limited.frames[0].text, '🙂'.repeat(2048));
  assert.ok(Buffer.byteLength(JSON.stringify(limited)) <= 65536);
  emit({ choices: [{ delta: { content: '\u0000'.repeat(20000) } }] });
  const escaped = relay.get(id, limited.cursor).preview;
  assert.equal(escaped.limited, true); assert.ok(escaped.frames.length === 1 && Buffer.byteLength(JSON.stringify(escaped)) <= 65536);
});

test('OpenCode callback previews are marked streamed and late frames cannot revive cancelled jobs', async t => {
  const { relay, id, emit, complete, events } = projected(t);
  emit({ choices: [{ delta: { content: 'Actual partial' } }] });
  assert.equal(relay.get(id, 0).preview.frames[0].text, 'Actual partial');
  relay.cancel(id); const count = events.length;
  emit({ choices: [{ delta: { content: 'Late text' } }] });
  complete({ status: 200, headers: {}, body: '{}' }); await Promise.resolve();
  assert.equal(relay.get(id, 0).state, 'cancelled'); assert.equal(events.length, count);
  assert.equal(events.find(event => event.kind === 'inference:done').streamed, true);
});
