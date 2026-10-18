'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { once } = require('node:events');
const { performance } = require('node:perf_hooks');
const { createFixture } = require('./delay_fixture');

async function setup(t, delayMs) {
  const fixture = createFixture({ delayMs });
  fixture.server.listen(0, '127.0.0.1');
  await once(fixture.server, 'listening');
  t.after(() => fixture.close());
  return 'http://127.0.0.1:' + fixture.server.address().port;
}
function post(base, id, options = {}) {
  return fetch(base + '/probe', { method: 'POST', body: JSON.stringify({ probeId: id }),
    headers: { 'content-type': 'application/json' }, ...options });
}

test('fixture returns the nonce after a real 35-second silent response', { timeout: 45000 }, async t => {
  const base = await setup(t, 35000);
  const started = performance.now();
  const response = await post(base, 'uai_probe_long0001');
  const value = await response.json();
  assert.equal(response.status, 200);
  assert.equal(value.fixture, 'uai-relay-delay-v1');
  assert.equal(value.probeId, 'uai_probe_long0001');
  assert.equal(value.dispatches, 1);
  assert.ok(value.elapsedMs >= 35000);
  assert.ok(performance.now() - started >= 35000);
});

test('duplicate upstream calls are observable and credentials are rejected', async t => {
  const base = await setup(t, 500);
  const responses = await Promise.all([post(base, 'uai_probe_duplicate'), post(base, 'uai_probe_duplicate')]);
  for (const response of responses) assert.equal((await response.json()).dispatches, 2);
  const refused = await post(base, 'uai_probe_keycheck', { headers: { Authorization: 'Bearer fixture-secret' } });
  assert.equal(refused.status, 400);
  assert.equal((await refused.json()).error, 'credentials_not_expected');
});

test('cancelled HTTP work is released and invalid fixture input is bounded', async t => {
  const base = await setup(t, 10000);
  const controller = new AbortController();
  const request = post(base, 'uai_probe_cancelled', { signal: controller.signal }).catch(() => null);
  let health;
  for (let i = 0; i < 30; i++) {
    health = await (await fetch(base + '/health')).json();
    if (health.active === 1) break;
    await new Promise(resolve => setTimeout(resolve, 10));
  }
  assert.equal(health.active, 1);
  controller.abort();
  await request;
  for (let i = 0; i < 30; i++) {
    health = await (await fetch(base + '/health')).json();
    if (health.active === 0) break;
    await new Promise(resolve => setTimeout(resolve, 10));
  }
  assert.equal(health.active, 0);
  assert.equal((await post(base, 'not-a-probe')).status, 400);
  const oversized = await fetch(base + '/probe', { method: 'POST', body: 'x'.repeat(2048) });
  assert.equal(oversized.status, 413);
  assert.equal((await fetch(base + '/elsewhere')).status, 404);
});
