'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { Readable } = require('node:stream');
const { createKilo, eligible } = require('../kilo');
const { createInference } = require('../inference');
const url = new URL('https://api.kilo.ai/api/gateway/chat/completions');
const body = JSON.stringify({ model: 'kilo-auto/free', messages: [{ role: 'user', content: 'fixture' }] });
const limit = { status: 429, body: JSON.stringify({ error: { code: 'PROMOTION_MODEL_LIMIT_REACHED' } }) };
function fixture(t, replies, extra = {}) {
  const calls = [], rotations = [];
  const tor = { generation: 0, ensure: async () => ({ port: 1234 }),
    rotate: async expected => { rotations.push(expected); tor.generation++; }, close: async () => {} };
  const proxy = { fixture: true, destroy() {} };
  const kilo = createKilo({ enabled: true, warm: false, torFactory: ({ onState }) => {
    tor.ensure = async () => { onState('ready', 'Fixture tunnel ready.'); return { port: 1234 }; };
    return tor;
  }, agentFactory: () => proxy,
    request(target, opts, callback) {
      const request = new EventEmitter(); let destroyed = false;
      request.setTimeout = () => request;
      request.destroy = () => { destroyed = true; return request; };
      request.end = payload => {
        calls.push({ target: target.href, opts, payload });
        const reply = replies.shift();
        queueMicrotask(() => {
          if (destroyed) return;
          request.emit('finish');
          if (!reply) { request.emit('error', Error('Unexpected extra send')); return; }
          if (reply.error) { request.emit('error', Error(reply.error)); return; }
          const response = reply.interrupted ? new Readable({ read() { this.push(Buffer.from(reply.body)); this.destroy(); } })
            : Readable.from([Buffer.from(reply.body || '{}')]);
          response.statusCode = reply.status; response.headers = reply.headers || { 'content-type': 'application/json' };
          callback(response);
        });
      };
      return request;
    }, ...extra });
  t.after(() => kilo.close());
  async function send() {
    return new Promise((resolve, reject) => {
      const request = kilo.request(url, { method: 'POST', headers: { 'content-type': 'application/json' } }, response => {
        const chunks = []; response.on('data', chunk => chunks.push(chunk));
        response.on('error', reject); response.on('end', () => resolve({ status: response.statusCode, headers: response.headers, body: Buffer.concat(chunks).toString() }));
      });
      request.on('error', reject); request.end(body);
    });
  }
  return { kilo, calls, rotations, tor, proxy, send };
}
test('only exact anonymous Kilo free routes qualify', () => {
  assert.equal(eligible(url, {}, body), true);
  for (const headers of [{ Authorization: 'Bearer private' }, { Cookie: 'session=private' }, { 'x-api-key': 'private' }]) assert.equal(eligible(url, headers, body), false);
  for (const other of ['https://api.kilo.ai.evil.test/api/gateway/chat/completions', 'http://api.kilo.ai/api/gateway/chat/completions',
    'https://api.kilo.ai/api/gateway/chat/completions?key=private', 'https://api.kilo.ai:444/api/gateway/chat/completions',
    'https://api.kilo.ai/api/gateway/models', 'https://example.com/api/gateway/chat/completions']) assert.equal(eligible(new URL(other), {}, body), false);
  assert.equal(eligible(url, {}, '{broken'), false);
  assert.equal(eligible(url, {}, JSON.stringify({ model: 'paid-model' })), false);
  // Kilo spells free routes ":free", "/free" and "-free" (October 25 catalog:
  // reflection/beam-free is the only dash-spelled free route; openrouter/free
  // and kilo-auto/free use the slash).
  for (const model of ['reflection/beam-free', 'openrouter/free', 'kilo-auto/free'])
    assert.equal(eligible(url, {}, JSON.stringify({ model })), true);
  for (const model of ['paid-model', 'free', 'carefree', 'kilo-auto/free-tier'])
    assert.equal(eligible(url, {}, JSON.stringify({ model })), false);
});
test('a confirmed quota refusal retries through the tunnel with the same payload', async t => {
  const f = fixture(t, [limit, { status: 200, body: 'data: {"ok":true}\n\ndata: [DONE]\n\n', headers: { 'content-type': 'text/event-stream' } }]);
  const result = await f.send();
  assert.equal(result.status, 200); assert.match(result.body, /\[DONE\]/);
  assert.equal(f.calls.length, 2); assert.equal(f.calls[0].opts.agent, undefined); assert.equal(f.calls[1].opts.agent, f.proxy);
  assert.equal(f.calls[0].payload, f.calls[1].payload); assert.deepEqual(f.rotations, []);
});
test('a limited tunnel rotates once, then returns a terminal quota and suppresses immediate repeats', async t => {
  let time = 1000;
  const f = fixture(t, [limit, limit, limit, { status: 200 }], { now: () => time });
  const result = await f.send();
  assert.equal(result.status, 429); assert.equal(result.headers['x-should-retry'], 'false');
  assert.equal(f.calls.length, 3); assert.deepEqual(f.rotations, [0]);
  assert.equal((await f.send()).status, 429); assert.equal(f.calls.length, 3);
  time += 61000;
  assert.equal((await f.send()).status, 200); assert.equal(f.calls.length, 4); assert.equal(f.calls[3].opts.agent, f.proxy);
});
test('ordinary errors and uncertain transport failures never switch or repeat requests', async t => {
  for (const reply of [{ status: 429, body: '{"error":"busy"}' }, { status: 500 }, { status: 401 }, { error: 'connection reset' }]) {
    const f = fixture(t, [reply]);
    if (reply.error) await assert.rejects(f.send(), /Could not complete/); else assert.equal((await f.send()).status, reply.status);
    assert.equal(f.calls.length, 1); assert.deepEqual(f.rotations, []);
  }
});
test('cancellation while tunnel setup is pending cannot dispatch another request', async t => {
  let ready;
  const f = fixture(t, [limit]);
  f.tor.ensure = () => new Promise(resolve => { ready = resolve; });
  const request = f.kilo.request(url, {}, () => assert.fail('cancelled response delivered'));
  request.on('error', () => assert.fail('cancelled request emitted failure')); request.end(body);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(typeof ready, 'function'); request.destroy(); ready({ port: 1234 });
  await new Promise(resolve => setImmediate(resolve)); assert.equal(f.calls.length, 1);
});
test('disabled tunnel never qualifies and does not start a helper', async t => {
  const kilo = createKilo({ enabled: false, torFactory: () => assert.fail('unexpected Tor') }); t.after(() => kilo.close());
  assert.equal(kilo.accepts(url, {}, body), false); assert.equal(kilo.capability().state, 'disabled');
});

test('an interrupted quota body fails without replaying the request', async t => {
  const f = fixture(t, [{ ...limit, interrupted: true }]);
  await assert.rejects(f.send(), /response connection closed/);
  assert.equal(f.calls.length, 1); assert.deepEqual(f.rotations, []);
});

test('shutdown during setup stays disabled after the pending setup rejects', async t => {
  const states = []; let rejectSetup;
  const f = fixture(t, [limit], { onChange: value => states.push(value.state) });
  f.tor.ensure = () => new Promise((resolve, reject) => { rejectSetup = reject; });
  const request = f.kilo.request(url, {}, () => assert.fail('stopped request delivered'));
  request.on('error', () => assert.fail('stopped request emitted failure')); request.end(body);
  await new Promise(resolve => setImmediate(resolve));
  await f.kilo.close(); rejectSetup(Error('setup stopped'));
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.kilo.capability().state, 'disabled');
  assert.equal(f.calls.length, 1); assert.equal(states.includes('failed'), false);
});

test('cancellation during circuit rotation cannot dispatch another request', async t => {
  let rotated;
  const f = fixture(t, [limit, limit]);
  f.tor.rotate = () => new Promise(resolve => { rotated = resolve; });
  const request = f.kilo.request(url, {}, () => assert.fail('cancelled request delivered'));
  request.on('error', () => assert.fail('cancelled request emitted failure')); request.end(body);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(typeof rotated, 'function'); request.destroy(); rotated();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.calls.length, 2);
});

test('quota cooldown advertises limited and broadcasts recovery when the timer expires', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  let time = 1000; const states = [];
  const f = fixture(t, [limit, limit, limit, { status: 200 }], {
    now: () => time, onChange: value => states.push(value.state)
  });
  assert.equal((await f.send()).status, 429);
  assert.equal(f.kilo.capability().state, 'limited');
  assert.equal(f.kilo.capability().available, false); assert.equal(states.at(-1), 'limited');
  time += 60000; t.mock.timers.tick(60000);
  assert.equal(f.kilo.capability().state, 'ready'); assert.equal(states.at(-1), 'ready');
  assert.equal((await f.send()).status, 200); assert.equal(f.calls.length, 4);
});

test('finish is emitted once after the replay payload is released', async t => {
  let ready, finishes = 0;
  const f = fixture(t, [limit, limit, { status: 200 }]);
  f.tor.ensure = () => new Promise(resolve => { ready = resolve; });
  let request;
  const result = new Promise((resolve, reject) => {
    request = f.kilo.request(url, {}, response => {
      response.resume(); response.on('end', resolve); response.on('error', reject);
    });
    request.on('finish', () => { finishes++; }); request.on('error', reject); request.end(body);
  });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.calls.length, 1); assert.equal(finishes, 0);
  ready({ port: 1234 }); await result;
  assert.equal(f.calls.length, 3); assert.equal(finishes, 1);
  request.destroy(); assert.equal(finishes, 1);
});

test('inference keeps the request-memory budget reserved while Kilo awaits recovery', async t => {
  let ready;
  const f = fixture(t, [limit, { status: 200 }, { status: 200 }]);
  f.tor.ensure = () => new Promise(resolve => { ready = resolve; });
  const inference = createInference({ kilo: f.kilo, maxActiveRequestBytes: Buffer.byteLength(body) });
  t.after(() => inference.close());
  const input = { instance: inference.instance, url: url.href, headers: {}, body };
  inference.start({ ...input, id: 'memory-first' });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.calls.length, 1);
  assert.throws(() => inference.start({ ...input, id: 'memory-second' }), error => error.status === 413);
  ready({ port: 1234 });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(inference.get('memory-first').state, 'completed');
  assert.doesNotThrow(() => inference.start({ ...input, id: 'memory-second' }));
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(inference.get('memory-second').state, 'completed');
});
