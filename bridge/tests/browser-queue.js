// Queue management preserves draft ownership, disclosure state and exact identities.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const { startBridge } = require('./helpers/bridge');

(async () => {
  const bridge = await startBridge();
  let browser, heartbeat, sequence = 0, commandError = '';
  const commands = [], state = {
    protocol: 2, runtime: 'web', sessionId: 'queue-ui', player: 'David', place: { name: 'Studio garden' },
    agent: { busy: true, status: 'Working', model: 'fixture-model', provider: 'Fixture' },
    threads: [{ id: 'queue-ui', title: 'Bring the garden to life', active: true }],
    providers: [{ id: 'fixture', label: 'Fixture', model: 'fixture-model', enabled: true, models: ['fixture-model'] }],
    activeProvider: 'fixture', permissions: { mode: 'ask' }, tools: [], todos: [], loops: [], logs: [], requests: [],
    subagents: [], questions: [], pendingPermissions: [], settings: { ui: { fontScale: 1 }, agent: {} },
    queue: { count: 2, limit: 16, held: false, operations: { edit: true, move: true, clear: true }, items: [
      { id: 'lighting', state: 'queued', text: 'Soften the lighting near the fountain.\nKeep the warm afternoon colors.', files: [], images: [] },
      { id: 'paths', state: 'queued', text: 'Then inspect the paths and describe any gaps.', files: [], images: [] },
    ] },
  };
  const push = async extra => {
    const response = await fetch(bridge.base + '/api/agent/events', { method: 'POST',
      headers: { Authorization: 'Bearer ' + bridge.token, 'content-type': 'application/json' },
      body: JSON.stringify({ batchId: 'queue-ui-' + (++sequence), state, ...extra }) });
    assert.ok(response.ok);
  };
  try {
    await push({ sessionId: state.sessionId, snapshot: [
      { kind: 'user', text: 'Help me make this garden feel more welcoming.', sessionId: state.sessionId },
      { kind: 'assistant:text', text: 'I found the garden and checked its lighting. I’m adjusting the fountain area next.', sessionId: state.sessionId },
      { kind: 'tool:call', id: 'find', name: 'instance_find', arguments: '{"query":"Garden"}', sessionId: state.sessionId },
      { kind: 'tool:result', id: 'find', name: 'instance_find', text: 'Found Garden, Fountain, and three connected paths.', ms: 185, sessionId: state.sessionId },
      { kind: 'tool:call', id: 'lighting', name: 'instance_properties', arguments: '{"path":"workspace.Garden.Fountain","properties":["Brightness","Color"]}', sessionId: state.sessionId },
      { kind: 'tool:progress', id: 'lighting', name: 'instance_properties', text: 'Reading the current light settings', sessionId: state.sessionId },
    ] });
    heartbeat = setInterval(() => push().catch(() => {}), 5000);
    browser = await chromium.launch({ headless: true });
    const page = await browser.newPage({ viewport: { width: 1440, height: 960 }, reducedMotion: 'reduce' });
    page.setDefaultTimeout(12000);
    const errors = []; page.on('pageerror', error => errors.push(error.message));
    await page.route('**/api/command', route => { const command = route.request().postDataJSON(); commands.push(command); return route.fulfill({ json: { id: command.commandId } }); });
    await page.route('**/api/commands/*', route => route.fulfill({ json: { state: 'completed', result: commandError ? { ok: false, error: commandError } : { ok: true } } }));
    const request = type => page.waitForRequest(value => value.url().endsWith('/api/command') && value.postDataJSON().type === type);
    const screenshot = async name => {
      if (!process.env.UAI_SCREENSHOTS) return;
      fs.mkdirSync(process.env.UAI_SCREENSHOTS, { recursive: true });
      await page.screenshot({ path: path.join(process.env.UAI_SCREENSHOTS, name + '.png'), animations: 'disabled' });
    };
    await page.goto(bridge.base + '/?settings=mcp#t=' + bridge.token); await page.locator('.queued-item').first().waitFor();
    await page.locator('#settings-tab-mcp[aria-current="true"]').waitFor();
    assert.equal(await page.evaluate(() => location.search + location.hash), '', 'desktop setup route consumes its query and private token');
    await page.locator('#modalClose').click(); await page.locator('#modal').waitFor({ state: 'hidden' });
    await push();
    assert.equal(await page.locator('#modal').evaluate(node => node.open), false, 'later state updates do not reopen the setup dialog');
    const first = page.locator('[data-message-id="lighting"]');
    await page.locator('#input').fill('My separate, unfinished thought');
    assert.equal(await first.locator('.queue-order').textContent(), '1');
    await first.locator('summary').focus(); await page.keyboard.press('Enter');
    assert.equal(await first.locator('.queued-full').textContent(), state.queue.items[0].text, 'disclosure retains every line');
    await first.locator('.queue-edit').click();
    const field = page.locator('#modal textarea');
    await field.fill('Make the lighting softer, with amber highlights.');
    await push();
    assert.equal(await field.inputValue(), 'Make the lighting softer, with amber highlights.', 'state refresh retains an edit in progress');
    commandError = 'This follow-up changed. Review its latest text before editing again';
    let pending = request('queue:edit');
    await page.getByRole('button', { name: 'Save changes', exact: true }).click();
    const edit = (await pending).postDataJSON();
    await page.locator('#modalNotice[data-state="error"]').waitFor();
    assert.equal(await field.inputValue(), edit.text, 'failed edit retains all typed text');
    assert.equal(edit.expectedText, state.queue.items[0].text);
    assert.equal(edit.sessionId, state.sessionId);
    commandError = ''; pending = request('queue:edit');
    await page.getByRole('button', { name: 'Save changes', exact: true }).click(); await pending;
    await page.locator('#modal').waitFor({ state: 'hidden' });
    state.queue.items[0].text = edit.text; await push();
    await page.waitForFunction(() => document.querySelector('[data-message-id="lighting"] .queued-full').textContent.startsWith('Make the lighting'));
    assert.equal(await page.locator('#input').inputValue(), 'My separate, unfinished thought');
    assert.equal(await first.locator('details').getAttribute('open'), '', 'editing preserves disclosure state');

    pending = request('queue:move'); await first.locator('.queue-down').click();
    const move = (await pending).postDataJSON();
    assert.deepEqual([move.messageId, move.neighborId, move.direction], ['lighting', 'paths', 1]);
    await first.evaluate(node => { window.queueRow = node; });
    state.queue.items.reverse(); await push();
    await page.waitForFunction(() => document.querySelector('.queued-item').dataset.messageId === 'paths');
    assert.equal(await first.evaluate(node => node === window.queueRow), true, 'reordering reuses the same DOM row');
    assert.equal(await first.locator('details').getAttribute('open'), '');

    for (const theme of ['dark', 'light']) {
      await page.evaluate(value => UAI.theme.set(value), theme);
      await screenshot('queue-and-tool-activity-' + theme);
    }
    state.agent.busy = false; state.queue.held = true; state.queue.reason = 'Stopped by you'; await push();
    await page.getByRole('button', { name: 'Resume queue', exact: true }).waitFor();
    await page.locator('.queue-clear').click();
    state.queue.items.push({ id: 'later', text: 'A follow-up added from Roblox', state: 'queued', files: [], images: [] }); state.queue.count = 3; await push();
    pending = request('queue:clear'); await page.getByRole('button', { name: 'Clear queued', exact: true }).click();
    const clear = (await pending).postDataJSON();
    assert.deepEqual(clear.messageIds, ['paths', 'lighting'], 'confirmation only clears the reviewed identities');
    await page.locator('#modal').waitFor({ state: 'hidden' });
    state.queue.items = state.queue.items.filter(item => item.id === 'later'); state.queue.count = 1; await push();
    await page.waitForFunction(() => document.querySelectorAll('.queued-item').length === 1);
    assert.equal(await page.locator('#input').inputValue(), 'My separate, unfinished thought');

    state.queue.items[0].text = 'A very long follow-up '.repeat(90) + '<script>window.bad = true</script>';
    state.queue.items[0].files = [{ path: 'pastes/original.lua', bytes: 123 }]; await push();
    await page.locator('.queued-copy summary small').filter({ hasText: '1 file' }).waitFor();
    await page.locator('.queued-copy summary').click();
    assert.equal(await page.locator('.queue-edit').isVisible(), false, 'verified file-backed messages cannot lose their references through editing');
    assert.equal(await page.evaluate(() => window.bad), undefined, 'queued text is rendered as text');
    for (const viewport of [{ width: 390, height: 844 }, { width: 320, height: 480 }, { width: 844, height: 390 }]) {
      await page.setViewportSize(viewport);
      const send = await page.locator('#send').boundingBox();
      assert.ok(send.x >= 0 && send.y >= 0 && send.x + send.width <= viewport.width && send.y + send.height <= viewport.height, 'queue leaves the composer controls reachable');
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false, 'long queue text fits ' + viewport.width);
      await page.locator('.queue-remove').click({ trial: true });
      await screenshot('queue-bounds-' + viewport.width);
    }
    await page.setViewportSize({ width: 1440, height: 960 });
    state.queue.operations = undefined; state.queue.items[0].files = []; await push();
    await page.waitForFunction(() => document.querySelector('.queue-clear').hidden);
    assert.equal(await page.locator('.queue-edit').isVisible(), false, 'older clients keep their supported queue controls');
    assert.equal(await page.locator('.queue-clear').isVisible(), false);
    await page.locator('.queue-remove').focus();
    pending = request('queue:remove'); await page.keyboard.press('Enter'); await pending;
    state.queue.items = []; state.queue.count = 0; await push();
    await page.locator('#queuedMessages').waitFor({ state: 'hidden' });
    assert.equal(await page.locator('#input').evaluate(node => node === document.activeElement), true, 'last removal restores typing focus');
    assert.equal(await page.locator('#input').inputValue(), 'My separate, unfinished thought');
    assert.deepEqual(errors, []);
    console.log('Queue browser checks passed: edit conflicts, draft retention, stable reorder, reviewed clear, legacy controls, escaping and responsive bounds.');
  } finally { clearInterval(heartbeat); await browser?.close(); await bridge.stop(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
