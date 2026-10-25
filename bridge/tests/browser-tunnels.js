// Real browser/SSE checks with an isolated bridge and synthetic free catalogs.
// The helper disables installed coding CLIs; these checks never use an account.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const { startBridge } = require('./helpers/bridge');
const { navigation } = require('./helpers/browser-ui');

(async () => {
  const bridge = await startBridge();
  let browser, sequence = 0;
  const headers = { Authorization: 'Bearer ' + bridge.token, 'content-type': 'application/json' };
  const longId = 'fixture-provider/' + 'long-free-model-'.repeat(11) + 'free';
  let modelData = { data: [{ id: longId }, { id: 'fixture-model:free' }] };
  let caps = {
    cline: { schema: 1, enabled: true, available: true, state: 'ready', message: 'Fixture Cline is ready.' },
    opencode: { schema: 1, enabled: true, available: true, state: 'ready', message: 'Fixture OpenCode is ready.' },
    kilo: { schema: 1, enabled: true, available: false, state: 'limited', message: 'Fixture exits reached their allowance.' },
  };
  const push = async events => {
    const result = await fetch(bridge.base + '/api/agent/events', { method: 'POST', headers,
      body: JSON.stringify({ batchId: 'tunnels-' + (++sequence), sessionId: 'tunnel-fixture', events }) });
    assert.ok(result.ok, 'Fixture events reach the owned bridge');
  };
  const publishCaps = () => push(Object.entries(caps).map(([name, value]) => ({ kind: name + ':state', [name]: value })));
  try {
    const hello = await (await fetch(bridge.base + '/api/hello', { headers })).json();
    assert.equal(hello.capabilities.cline.state, 'disabled', 'The actual Cline adapter remains disabled throughout this test');
    browser = await chromium.launch({ headless: true });
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, reducedMotion: 'reduce',
      permissions: ['clipboard-read', 'clipboard-write'] });
    const page = await context.newPage(); page.setDefaultTimeout(12000);
    const errors = []; page.on('pageerror', error => errors.push(error.message));
    await page.route('**/api/hello', async route => {
      const response = await route.fetch(), body = await response.json();
      await route.fulfill({ json: { ...body, capabilities: { ...body.capabilities, ...caps } } });
    });
    await page.route('**/api/tunnels/cline/models', route => route.fulfill({ json: modelData }));
    await page.route('**/api/opencode/models', route => route.fulfill({ json: modelData }));
    await page.goto(bridge.base + '/#t=' + bridge.token);
    await page.locator('#app').waitFor({ state: 'visible' });
    await page.waitForFunction(() => document.body.dataset.link === 'online');
    await navigation(page).navigate('tunnels');
    await publishCaps();
    const cline = page.locator('[data-tunnel="cline"]');
    await page.waitForFunction(() => document.querySelector('[data-tunnel="cline"] .pill')?.textContent === 'Ready');
    assert.equal(await page.locator('[data-tunnel]').count(), 3);
    assert.equal(await page.locator('[data-tunnel="kilo"] .pill').textContent(), 'Quota reached');
    const screenshot = async name => {
      if (!process.env.UAI_SCREENSHOTS) return;
      fs.mkdirSync(process.env.UAI_SCREENSHOTS, { recursive: true });
      await page.screenshot({ path: path.join(process.env.UAI_SCREENSHOTS, name + '.png'), animations: 'disabled' });
    };
    const bounds = async (dialog, body) => page.locator(dialog).evaluate((node, bodyId) => {
      const r = node.getBoundingClientRect(), content = document.querySelector(bodyId);
      return { left: r.left, right: r.right, top: r.top, bottom: r.bottom,
        width: content.clientWidth, scrollWidth: content.scrollWidth };
    }, body);
    for (const size of [{ width: 320, height: 480 }, { width: 390, height: 844 }, { width: 1440, height: 960 }]) {
      await page.setViewportSize(size);
      const panel = await bounds('#workspaceModal', '#panel');
      assert.ok(panel.left >= 0 && panel.right <= size.width && panel.top >= 0 && panel.bottom <= size.height, JSON.stringify(panel));
      assert.ok(panel.scrollWidth <= panel.width + 1, 'Tunnel cards fit: ' + JSON.stringify(panel));
      await screenshot('tunnels-' + size.width);
      await cline.getByRole('button', { name: 'Free models', exact: true }).click();
      await page.locator('#modal').waitFor({ state: 'visible' });
      assert.equal(await page.locator('#modalTitle').textContent(), 'Cline free models');
      await page.locator('#modalBody code').first().waitFor();
      assert.equal(await page.locator('#modalBody code').count(), 2);
      const models = await bounds('#modal', '#modalBody');
      assert.ok(models.left >= 0 && models.right <= size.width && models.top >= 0 && models.bottom <= size.height, JSON.stringify(models));
      assert.ok(models.scrollWidth <= models.width + 1, 'Long model IDs fit: ' + JSON.stringify(models));
      await page.locator('#modalBody').getByRole('button', { name: 'Copy ID', exact: true }).first().click();
      assert.equal(await page.evaluate(() => navigator.clipboard.readText()), longId);
      await screenshot('tunnels-models-' + size.width);
      await page.locator('#modalClose').click(); await page.locator('#modal').waitFor({ state: 'hidden' });
    }
    modelData = { data: [null, {}, { id: 42 }, { id: '' }, { id: ' ' }, { id: 'valid-fixture:free' }] };
    await cline.getByRole('button', { name: 'Free models', exact: true }).click();
    await page.locator('#modal').waitFor({ state: 'visible' });
    assert.equal(await page.locator('#modalBody code').textContent(), 'valid-fixture:free');
    await page.locator('#modalClose').click(); await page.locator('#modal').waitFor({ state: 'hidden' });
    modelData = { data: { unexpected: true } };
    await cline.getByRole('button', { name: 'Free models', exact: true }).click();
    await page.locator('#modal').waitFor({ state: 'visible' });
    await page.locator('#modalBody').getByText('No free models are currently available.', { exact: true }).waitFor();
    assert.equal(await page.locator('#modalBody code').count(), 0);
    assert.equal(await page.locator('#modalBody').getByText('No free models are currently available.', { exact: true }).count(), 1);
    await page.locator('#modalClose').click(); await page.locator('#modal').waitFor({ state: 'hidden' });
    for (const [state, label] of [['auth-required', 'Sign in required'], ['starting', 'Connecting'], ['failed', 'Needs attention'], ['disabled', 'Off']]) {
      caps.cline = { schema: 1, enabled: state !== 'disabled', available: false, state, message: 'Fixture ' + state };
      await publishCaps();
      await page.waitForFunction(expected => document.querySelector('[data-tunnel="cline"] .pill')?.textContent === expected, label);
      assert.equal(await cline.getByRole('button', { name: 'Free models', exact: true }).isDisabled(), state === 'disabled');
    }
    caps.cline = { schema: 1, enabled: true, available: true, state: 'ready', message: 'Fixture refreshed.' };
    await page.getByRole('button', { name: 'Refresh status', exact: true }).click();
    await page.waitForFunction(() => document.querySelector('[data-tunnel="cline"] .pill')?.textContent === 'Ready');
    // Close the live SSE socket. Network emulation alone can leave an already
    // established loopback EventSource open in Chromium.
    await bridge.stop();
    await page.waitForFunction(() => document.body.dataset.link === 'offline');
    await page.waitForFunction(() => [...document.querySelectorAll('[data-tunnel] .pill')].every(node => node.textContent === 'Disconnected'));
    assert.equal(await cline.getByRole('button', { name: 'Free models', exact: true }).isDisabled(), true);
    assert.deepEqual(errors, []);
    console.log('Tunnels browser checks passed: real SSE status, refresh, free catalogs, exact copy, long IDs at 320/390/1440 px, malformed catalogs, disconnect.');
  } finally { await browser?.close(); await bridge.stop(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
