// Provider/model snapshots and read-only catalog requests stay tied to the
// visible dialog. Uses synthetic catalogs and never starts a coding CLI.
'use strict';
const assert = require('node:assert/strict');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const { startBridge } = require('./helpers/bridge');
const { navigation } = require('./helpers/browser-ui');

(async () => {
  const bridge = await startBridge(); let browser, sequence = 0;
  const headers = { Authorization: 'Bearer ' + bridge.token, 'content-type': 'application/json' };
  const ids = Array.from({ length: 800 }, (_, index) => 'fixture-model-' + String(index).padStart(4, '0'));
  let state = { protocol: 2, runtime: 'web', sessionId: 'models-fixture', player: 'Fixture',
    agent: { status: 'Ready', busy: false, model: ids[0], provider: 'Fixture provider' },
    providers: [{ id: 'first', label: 'First provider', model: ids[0], models: [...ids, ids[0], null, {}, 42, '', ' '] }],
    activeProvider: 'first', threads: [], usage: { total: 0 }, settings: { agent: {}, ui: {} },
    permissions: { mode: 'ask' }, pendingPermissions: [], questions: [], tools: [], logs: [], requests: [] };
  const publish = async events => {
    const response = await fetch(bridge.base + '/api/agent/events', { method: 'POST', headers,
      body: JSON.stringify({ batchId: 'model-lifecycle-' + (++sequence), sessionId: state.sessionId, state, events: events || [] }) });
    assert.ok(response.ok);
  };
  try {
    await publish();
    browser = await chromium.launch({ headless: true });
    const context = await browser.newContext({ viewport: { width: 1280, height: 900 }, reducedMotion: 'reduce' });
    const page = await context.newPage(); page.setDefaultTimeout(12000);
    const errors = []; page.on('pageerror', error => errors.push(error.message));
    await page.goto(bridge.base + '/#t=' + bridge.token);
    await page.locator('#app').waitFor({ state: 'visible' });
    await page.waitForFunction(() => document.querySelector('#modelLabel').textContent === 'fixture-model-0000');
    await page.locator('#modelButton').click();
    const list = page.locator('.model-list'), provider = page.locator('.model-provider select');
    assert.equal(await list.locator('button').count(), 800, 'Malformed and duplicate model IDs do not break the picker');
    await page.locator('.model-search input').fill('fixture-model-07');
    assert.equal(await list.locator('button').count(), 100);
    await page.locator('.model-search input').fill('');
    await page.evaluate(() => {
      const list = document.querySelector('.model-list');
      window.modelListChanges = 0;
      window.modelListObserver = new MutationObserver(records => window.modelListChanges += records.length);
      window.modelListObserver.observe(list, { childList: true, subtree: true, attributes: true, characterData: true });
      window.retainedModelRow = list.children[400]; window.retainedModelRow.focus();
      window.retainedModelScroll = document.querySelector('.model-results').scrollTop;
    });
    for (let index = 1; index <= 5; index++) {
      state = { ...state, player: 'Snapshot ' + index, usage: { total: index } };
      await publish();
      await page.waitForFunction(expected => document.querySelector('#playerName').textContent === expected, state.player);
    }
    assert.deepEqual(await page.evaluate(() => ({ changes: window.modelListChanges,
      retained: document.activeElement === window.retainedModelRow,
      scroll: document.querySelector('.model-results').scrollTop === window.retainedModelScroll })),
      { changes: 0, retained: true, scroll: true }, 'Unrelated snapshots preserve model rows, focus and scroll');
    state.providers.push({ id: 'second', label: 'Second provider', model: 'second-model', models: ['second-model'],
      modelInfo: { 'second-model': { contextWindow: 200000, reasoning: true } } });
    await publish();
    await page.waitForFunction(() => document.querySelector('.model-provider select').options.length === 2);
    assert.equal(await provider.inputValue(), 'first', 'An added provider preserves the current browsing selection');
    await provider.selectOption('second');
    assert.equal(await list.locator('button').count(), 1);
    assert.match(await list.textContent(), /200K context/);
    state.providers[1].label = 'Renamed provider';
    await publish();
    await page.waitForFunction(() => document.querySelector('.model-detail-provider').textContent === 'Renamed provider');
    assert.equal(await provider.locator('option:checked').textContent(), 'Renamed provider');
    state.providers[1].modelInfo['second-model'] = { contextWindow: 262144, reasoning: false, free: true };
    await publish();
    await page.waitForFunction(() => document.querySelector('.model-list button').getAttribute('aria-label') === 'second-model, free');
    assert.equal(await list.locator('.model-row-meta').textContent(), '262.1K context', 'Relevant metadata still refreshes cached rows');
    state.providers = [{ id: 'replacement', label: 'Replacement provider', model: 'replacement-model', models: ['replacement-model'] }];
    state.activeProvider = 'replacement';
    await publish();
    await page.waitForFunction(() => document.querySelector('.model-provider select').value === 'replacement');
    assert.equal(await provider.locator('option').count(), 1);
    assert.match(await list.textContent(), /replacement-model/);
    await page.locator('#modalClose').click(); await page.locator('#modal').waitFor({ state: 'hidden' });

    const pending = [], failures = [];
    const waitForCatalog = async count => {
      const deadline = Date.now() + 5000;
      while (pending.length < count && Date.now() < deadline) await page.waitForTimeout(10);
      assert.equal(pending.length, count, 'Catalog request reached the fixture');
    };
    page.on('requestfailed', request => { if (request.url().endsWith('/api/tunnels/cline/models')) failures.push(request.failure()?.errorText); });
    await page.route('**/api/tunnels/cline/models', route => new Promise(resolve => pending.push(async (body, status = 200) => {
      try { await route.fulfill({ status, json: body }); } catch { /* The closed dialog may already have aborted this route. */ }
      resolve();
    })));
    const cline = { schema: 1, enabled: true, available: true, state: 'ready', message: 'Fixture ready' };
    await publish([{ kind: 'cline:state', cline }]);
    await navigation(page).navigate('tunnels');
    const catalog = page.locator('[data-tunnel="cline"]').getByRole('button', { name: 'Free models', exact: true });
    await catalog.click();
    await page.locator('#modalBody').getByText('Loading current free models...', { exact: true }).waitFor();
    await page.waitForFunction(() => document.querySelector('#modal').open);
    await waitForCatalog(1);
    await publish([{ kind: 'cline:state', cline: { ...cline, message: 'Status changed while loading' } }]);
    assert.equal(pending.length, 1, 'Status refresh does not create another catalog request');
    await page.locator('#modalClose').click(); await page.locator('#modal').waitFor({ state: 'hidden' });
    await navigation(page).navigate('providers');
    await pending[0]({ data: [{ id: 'stale-model:free' }] });
    await page.waitForTimeout(100);
    assert.equal(await page.locator('#modal').isVisible(), false, 'A late catalog does not reopen over a different page');
    assert.ok(failures.length >= 1, 'Closing the catalog aborts its browser request');
    await navigation(page).navigate('tunnels'); await catalog.click();
    await page.locator('#modalBody').getByText('Loading current free models...', { exact: true }).waitFor();
    await waitForCatalog(2);
    await pending[1]({ data: [{ id: 'current-model:free' }] });
    await page.locator('#modalBody code').waitFor();
    assert.equal(await page.locator('#modalBody code').textContent(), 'current-model:free');
    await page.locator('#modalClose').click(); await page.locator('#modal').waitFor({ state: 'hidden' });
    await catalog.click(); await waitForCatalog(3);
    await pending[2]({ error: 'Fixture catalog is unavailable' }, 503);
    await page.locator('#modalBody').getByText('Fixture catalog is unavailable', { exact: true }).waitFor();
    await page.locator('#modalBody').getByRole('button', { name: 'Try again', exact: true }).click();
    await waitForCatalog(4); await pending[3]({ data: [{ id: 'retried-model:free' }] });
    await page.locator('#modalBody code').waitFor();
    assert.equal(await page.locator('#modalBody code').textContent(), 'retried-model:free');
    await page.locator('#modalClose').click(); await page.locator('#modal').waitFor({ state: 'hidden' });
    state.usage = { total: 200, requests: 2, cost: 0, unpriced: 2 };
    await publish(); await navigation(page).navigate('cowork');
    const cost = page.locator('.metrics > div').last();
    assert.equal(await cost.locator('strong').textContent(), 'Unknown', 'Unpriced requests are never displayed as a free invoice');
    assert.match(await page.locator('.cost-coverage').textContent(), /2 requests have unknown cost/);
    state.usage = { total: 300, requests: 3, cost: 0.125, unpriced: 2 };
    await publish();
    await page.waitForFunction(() => document.querySelector('.metrics > div:last-child strong').textContent === '$0.1250');
    assert.equal(await cost.locator('small').textContent(), 'Known estimated cost');
    state.usage = { total: 300, requests: 3, cost: 0, unpriced: 0 };
    await publish();
    await page.waitForFunction(() => !document.querySelector('.cost-coverage'));
    assert.equal(await cost.locator('strong').textContent(), '$0.0000', 'Known zero-cost usage remains distinguishable');
    assert.equal(await cost.locator('small').textContent(), 'Estimated cost');
    assert.deepEqual(errors, []);
    console.log('Model lifecycle browser checks passed: 800 models, zero row mutations for unrelated snapshots, live provider changes, malformed IDs, catalog cancellation/retry, and unknown/mixed/free cost coverage.');
  } finally { await browser?.close(); await bridge.stop(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
