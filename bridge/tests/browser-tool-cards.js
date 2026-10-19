// The activity drawer keeps tool details optional and preserves exact inputs/results.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const { startBridge } = require('./helpers/bridge');

(async () => {
  const bridge = await startBridge();
  let browser, heartbeat, sequence = 0;
  const state = {
    protocol: 2, runtime: 'web', sessionId: 'tool-cards', player: 'David', place: { name: 'Studio garden' },
    agent: { busy: false, status: 'Ready', model: 'fixture-model', provider: 'Fixture' },
    threads: [{ id: 'tool-cards', title: 'Inspect the garden', active: true }],
    providers: [{ id: 'fixture', label: 'Fixture', model: 'fixture-model', enabled: true, models: ['fixture-model'] }],
    activeProvider: 'fixture', permissions: { mode: 'ask' }, tools: [], todos: [], loops: [], logs: [], requests: [],
    subagents: [], questions: [], pendingPermissions: [], settings: { ui: { fontScale: 1, transcriptWidth: 'medium' }, agent: {} },
  };
  const push = async extra => {
    const response = await fetch(bridge.base + '/api/agent/events', { method: 'POST',
      headers: { Authorization: 'Bearer ' + bridge.token, 'content-type': 'application/json' },
      body: JSON.stringify({ batchId: 'cards-' + (++sequence), state, ...extra }) });
    assert.ok(response.ok, 'fixture events are accepted');
  };
  const event = data => ({ sessionId: 'tool-cards', ...data });
  try {
    await push({ sessionId: 'tool-cards', snapshot: [] });
    heartbeat = setInterval(() => push().catch(() => {}), 5000);
    browser = await chromium.launch({ headless: true });
    const context = await browser.newContext({ viewport: { width: 1440, height: 960 },
      permissions: ['clipboard-read', 'clipboard-write'], reducedMotion: 'reduce' });
    const page = await context.newPage(); page.setDefaultTimeout(12000);
    const errors = []; page.on('pageerror', error => errors.push(error.message));
    const screenshot = async name => {
      if (!process.env.UAI_SCREENSHOTS) return;
      fs.mkdirSync(process.env.UAI_SCREENSHOTS, { recursive: true });
      await page.screenshot({ path: path.join(process.env.UAI_SCREENSHOTS, name + '.png'), animations: 'disabled' });
    };
    const clipboard = async () => (await page.evaluate(() => navigator.clipboard.readText())).replace(/\r\n/g, '\n');
    const cards = page.locator('.tool-call > .tool');
    await page.goto(bridge.base + '/#t=' + bridge.token); await page.locator('#app').waitFor({ state: 'visible' });
    await page.evaluate(() => UAI.theme.set('dark'));

    const code = 'local garden = workspace:FindFirstChild("Garden")\nreturn garden and garden:GetFullName()';
    const rawArguments = JSON.stringify({ code });
    await push({ events: [
      event({ kind: 'tool:call', id: 'shared', name: 'run_luau', arguments: rawArguments }),
      event({ kind: 'subagent:tool', id: 'child', callId: 'shared', name: 'run_luau', arguments: '{}' }),
    ] });
    await cards.nth(1).waitFor({ state: 'attached' });
    assert.equal(await page.locator('.response-activity').count(), 1, 'main and delegated calls share one activity drawer');
    assert.equal(await cards.first().isVisible(), false, 'individual tool calls stay out of the answer by default');
    assert.equal(await page.locator('.activity-meta').textContent(), '2 steps');
    await page.locator('.activity-summary').click();
    assert.equal(await cards.first().getAttribute('open'), null, 'running call starts compact');
    assert.equal(await cards.first().locator('.arguments').textContent(), '2 lines of Luau');
    assert.equal(await cards.first().locator('.tool-head > strong').textContent(), 'Run Luau', 'human-readable title retains the exact tool identity in details');
    assert.equal(await cards.first().locator('.tool-code-input').isVisible(), false, 'source waits behind Input');
    assert.equal(await cards.first().locator('.tool-status').evaluate(node => getComputedStyle(node, '::before').animationName), 'none', 'reduced motion disables running animation');
    await push({ events: [
      event({ kind: 'tool:progress', id: 'shared', name: 'run_luau', text: 'Reading the Garden model' }),
      event({ kind: 'subagent:tool:done', id: 'child', callId: 'shared', name: 'run_luau', summary: 'Child inspected four lights.', ok: true, ms: 320 }),
    ] });
    await page.waitForFunction(() => document.querySelectorAll('.tool-status')[1].textContent === 'Done');
    assert.equal(await cards.first().locator('.tool-progress').textContent(), 'Reading the Garden model');
    assert.equal(await cards.first().locator('.arguments').textContent(), '2 lines of Luau', 'progress preserves the original input summary');
    assert.equal(await cards.first().locator('.tool-status').textContent(), 'Running', 'child result cannot complete the main call');
    assert.equal(await cards.nth(1).locator('.tool-outcome').textContent(), 'Child inspected four lights.');

    await cards.first().locator(':scope > summary').click();
    await cards.first().locator(':scope > .tool-body > .tool-detail').first().locator(':scope > summary').click();
    await cards.first().getByRole('button', { name: 'Copy Luau', exact: true }).click();
    assert.equal(await clipboard(), code, 'source Copy preserves exact text');
    await cards.first().locator('.tool-detail > summary').filter({ hasText: /^Raw arguments$/ }).click();
    await cards.first().getByRole('button', { name: 'Copy Arguments', exact: true }).click();
    assert.equal(await clipboard(), rawArguments, 'pretty input retains original JSON for Copy');
    const result = 'Found **Garden**.\n\n```lua\nprint("Garden is ready")\n```\n\n[Roblox documentation](https://create.roblox.com/docs)';
    await push({ events: [event({ kind: 'tool:result', id: 'shared', name: 'run_luau', ok: true, text: result, ms: 1460 })] });
    await page.waitForFunction(() => document.querySelector('.tool-status').textContent === 'Done');
    assert.equal(await cards.first().getAttribute('open'), '', 'completion preserves user expansion');
    assert.equal(await cards.first().locator('.tool-duration').textContent(), '1.5 s');
    assert.equal(await cards.first().locator('.tool-progress').isVisible(), false, 'finished calls clear transient progress');
    assert.equal(await cards.first().locator('.tool-outcome').textContent(), 'Found Garden.', 'collapsed outcome shows prose without Markdown payload noise');
    assert.equal(await cards.first().locator('.tool-result-content strong').textContent(), 'Garden', 'successful text renders Markdown');
    assert.equal(await cards.first().getByRole('link', { name: 'Roblox documentation' }).getAttribute('href'), 'https://create.roblox.com/docs', 'result links use the safe shared Markdown renderer');
    await cards.first().getByRole('button', { name: 'Copy Result', exact: true }).click();
    assert.equal(await clipboard(), result, 'rendered result Copy retains original Markdown');
    await cards.first().locator('.tool-result-content .copy-code').click();
    assert.equal((await clipboard()).trimEnd(), 'print("Garden is ready")', 'fenced code Copy remains available');
    await screenshot('tool-cards-expanded-result-dark');
    await cards.first().locator(':scope > summary').click();

    const errorMessage = 'Cannot read Garden.Fountain: the instance no longer exists. Refresh the workspace and try again.';
    const fullError = JSON.stringify({ error: { message: errorMessage, code: 'INSTANCE_REMOVED', stack: 'at inspect_workspace\n'.repeat(30) }, request: 'fixture-request' });
    const resultData = { status: 'failed', error: { message: errorMessage }, retryable: true, inspected: 23 };
    await push({ events: [
      event({ kind: 'tool:call', id: 'failed', name: 'inspect_workspace', arguments: JSON.stringify({ path: 'workspace.Garden.Fountain' }) }),
      event({ kind: 'tool:error', id: 'failed', name: 'inspect_workspace', ok: false, text: fullError, data: resultData, ms: 870, truncated: true }),
    ] });
    const failed = cards.nth(2); await failed.locator('.tool-outcome').waitFor();
    assert.equal(await failed.getAttribute('data-status'), 'failed');
    assert.equal(await failed.getAttribute('open'), null, 'failure does not force open raw details');
    assert.equal(await failed.locator('.tool-outcome').textContent(), errorMessage, 'collapsed error explains the failure');
    assert.equal(await failed.locator('.tool-outcome').isVisible(), true);
    assert.equal(await failed.locator('.tool-listing').first().isVisible(), false, 'raw payload stays out of the collapsed card');
    assert.equal(await failed.locator('.deadline-help').count(), 0, 'ordinary tool errors do not repeat support links');
    await failed.locator(':scope > summary').click();
    assert.equal(await failed.locator('.error-title').textContent(), 'This step could not finish');
    assert.equal(await failed.locator('.error-details').getAttribute('open'), null, 'full diagnostics stay optional inside the readable error');
    await failed.locator('.error-details > summary').click();
    await failed.getByRole('button', { name: 'Copy Full error', exact: true }).click();
    assert.equal(await clipboard(), fullError, 'pretty error retains the exact original payload for Copy');
    const metadata = failed.locator('summary').filter({ hasText: /^Result data$/ }).locator('..');
    await metadata.locator(':scope > summary').click();
    assert.deepEqual(JSON.parse(await metadata.locator('pre code').textContent()), resultData, 'structured result metadata is retained');
    assert.equal(await failed.locator('.tool-retention-note').isVisible(), true);
    await screenshot('tool-cards-expanded-error-dark');
    await failed.locator(':scope > summary').click();

    await push({ events: [
      event({ kind: 'tool:call', id: 'stopped', name: 'run_luau', arguments: '{"code":"task.wait(10)"}' }),
      event({ kind: 'tool:result', id: 'stopped', name: 'run_luau', error: 'aborted', text: 'Stopped by you.', data: { status: 'aborted' } }),
      event({ kind: 'tool:call', id: 'timeout', name: 'file_read', arguments: '{"path":"workspace/large-file.lua"}' }),
      event({ kind: 'tool:result', id: 'timeout', name: 'file_read', error: 'timeout', text: 'Reading the file took longer than the allowed time.', ms: 30000 }),
      event({ kind: 'tool:call', id: 'declined', name: 'file_write', arguments: '{"path":"workspace/garden.lua"}' }),
      event({ kind: 'tool:result', id: 'declined', name: 'file_write', denied: true, text: 'Permission was declined.' }),
    ] });
    await cards.nth(5).waitFor();
    assert.deepEqual(await cards.evaluateAll(nodes => nodes.slice(3).map(node => node.dataset.status)), ['stopped', 'timeout', 'declined']);
    assert.deepEqual(await cards.locator('.tool-status').allTextContents(), ['Done', 'Done', 'Failed', 'Stopped', 'Timed out', 'Declined']);
    assert.equal(await cards.nth(3).locator('.arguments').textContent(), '1 line of Luau');
    assert.equal(await cards.nth(4).locator('.deadline-help').count(), 1, 'timeout help remains inside details');
    for (const theme of ['dark', 'light']) {
      await page.evaluate(value => UAI.theme.set(value), theme);
      await page.locator('#transcript').evaluate(node => { node.scrollTop = 0; });
      await screenshot('tool-cards-states-' + theme);
    }

    const longPath = 'workspace.' + 'LongGardenModelName'.repeat(30);
    const longMessage = 'Unable to inspect ' + longPath + ': the model was removed before the tool completed.';
    const narrowEvents = [
      event({ kind: 'tool:call', id: 'narrow', name: 'inspect_workspace', arguments: JSON.stringify({ path: longPath }) }),
      event({ kind: 'tool:error', id: 'narrow', name: 'inspect_workspace', text: longMessage + '\nstack trace:\n' + 'at garden.lua:12\n'.repeat(30) }),
      event({ kind: 'tool:call', id: 'unknown', name: 'file_read', arguments: '{"path":"workspace/garden.lua"}' }),
    ];
    await push({ sessionId: 'tool-cards', snapshot: narrowEvents });
    await page.waitForFunction(() => document.querySelectorAll('.tool-status')[1]?.textContent === 'No saved result');
    assert.equal(await page.locator('.response-activity').getAttribute('open'), null, 'replayed tool activity starts collapsed');
    assert.match(await page.locator('.activity-meta').textContent(), /1 failed.*1 without a saved result/);
    await page.locator('.activity-summary').click();
    assert.equal(await cards.nth(1).getAttribute('data-status'), 'unknown', 'restored idle call never invents an outcome');
    assert.equal(await cards.nth(1).locator('.tool-outcome').textContent(), 'No result was kept in this transcript.');
    for (const width of [390, 320]) {
      await page.setViewportSize({ width, height: 844 });
      const geometry = await cards.evaluateAll(nodes => nodes.map(node => {
        const box = node.getBoundingClientRect(), name = node.querySelector('.tool-head > strong').getBoundingClientRect(), status = node.querySelector('.tool-status').getBoundingClientRect();
        return { left: box.left, right: box.right, width: box.width, scroll: node.scrollWidth, nameWidth: name.width, statusRight: status.right };
      }));
      assert.ok(geometry.every(row => row.left >= 0 && row.right <= width && row.scroll <= row.width + 1 && row.nameWidth >= 60 && row.statusRight <= row.right), 'card content fits at ' + width + ': ' + JSON.stringify(geometry));
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
      assert.equal(await cards.first().locator('.arguments').isVisible(), true, 'narrow cards retain the input preview');
      for (const theme of ['dark', 'light']) {
        await page.evaluate(value => UAI.theme.set(value), theme);
        await screenshot('tool-cards-narrow-' + width + '-' + theme);
      }
      await cards.first().locator(':scope > summary').click();
      assert.equal(await cards.first().locator('.tool-wrap pre').last().evaluate(node => getComputedStyle(node).whiteSpace), 'pre-wrap');
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false, 'expanded long error does not widen the page');
      await screenshot('tool-cards-error-details-' + width);
      await cards.first().locator(':scope > summary').click();
    }
    await push({ events: [event({ kind: 'tool:result', id: 'unknown', name: 'file_read', text: '{"message":{"nested":true}}', ok: true })] });
    await page.waitForFunction(() => document.querySelectorAll('.tool-status')[1]?.textContent === 'Done');
    assert.equal(await cards.nth(1).locator('.tool-outcome').textContent(), 'Result available', 'late result clears unknown state without stringifying malformed summary objects');
    assert.deepEqual(errors, []);
    console.log('Tool card browser checks passed: compact states, scoped progress, readable errors, exact Copy, Markdown/code, replay, and 320px/390px layouts.');
  } finally { clearInterval(heartbeat); await browser?.close(); await bridge.stop(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
