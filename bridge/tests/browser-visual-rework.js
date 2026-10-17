// Focused presentation checks for the minimal Cowork UI and live response motion.
// Fixtures use an isolated bridge and a manually advanced loopback SSE provider.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const { once } = require('node:events');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const { startBridge } = require('./helpers/bridge');

(async () => {
  const bridge = await startBridge();
  let browser, page, upstream, heartbeat, liveResponse, sequence = 0;
  const auth = { Authorization: 'Bearer ' + bridge.token, 'content-type': 'application/json' };
  const state = {
    protocol: 2, runtime: 'web', imageInput: true, sessionId: 'visual', player: 'David', place: { name: 'Studio garden' },
    agent: { busy: false, status: 'Ready', model: 'Claude Sonnet 4.5', provider: 'Anthropic' },
    threads: [{ id: 'visual', title: 'A quieter corner', active: true, place: 'Studio garden' },
      { id: 'previous', title: 'A little room to create', place: 'Studio garden' }],
    providers: [{ id: 'local', label: 'Anthropic', baseUrl: 'http://localhost:1234/v1', model: 'Claude Sonnet 4.5', models: ['Claude Sonnet 4.5'], enabled: true }],
    activeProvider: 'local', permissions: { mode: 'ask' },
    settings: { ui: { density: 'comfortable', transcriptWidth: 'medium', fontScale: 1, codeTheme: 'light' }, agent: { effort: 'high', maxTurns: 24 } },
    tools: [], todos: [], loops: [], logs: [], requests: [], subagents: [], questions: [], pendingPermissions: [],
    usage: { total: 2480, requests: 3, cost: .004 }, attachments: { inlineLimit: 8000, maxBytes: 10 * 1024 * 1024, available: true },
  };
  const post = async (route, body) => {
    const response = await fetch(bridge.base + route, { method: 'POST', headers: auth, body: JSON.stringify(body) });
    assert.ok(response.ok, route + ': ' + response.status);
    return response.status === 204 ? null : response.json();
  };
  const push = body => post('/api/agent/events', { batchId: 'visual-' + (++sequence), ...body });
  const event = (kind, extra = {}) => ({ kind, sessionId: 'visual', ...extra });
  const screenshot = async (name, moving = false) => {
    if (!process.env.UAI_SCREENSHOTS) return;
    fs.mkdirSync(process.env.UAI_SCREENSHOTS, { recursive: true });
    await page.screenshot({ path: path.join(process.env.UAI_SCREENSHOTS, name + '.png'), animations: moving ? 'allow' : 'disabled' });
  };
  const responseState = value => page.waitForFunction(expected => [...document.querySelectorAll('.message.agent')].at(-1)?.dataset.responseState === expected, value);
  const write = delta => liveResponse.write('data: ' + JSON.stringify({ choices: [{ delta }] }) + '\n\n');
  const assertQuietResponse = async () => {
    const animations = await page.locator('.message.agent, .message.agent *, .thinking, .thinking *').evaluateAll(nodes =>
      nodes.flatMap(node => [null, '::before', '::after'].map(pseudo => getComputedStyle(node, pseudo).animationName)));
    assert.ok(animations.length > 0 && animations.every(name => name === 'none'), 'all live response effects respect reduced motion: ' + animations.join(', '));
  };

  try {
    await push({ state, sessionId: 'visual', snapshot: [] });
    heartbeat = setInterval(() => push({ events: [] }).catch(() => {}), 5000);
    browser = await chromium.launch({ headless: true });
    const context = await browser.newContext({ viewport: { width: 1440, height: 960 }, colorScheme: 'light', reducedMotion: 'no-preference' });
    page = await context.newPage(); page.setDefaultTimeout(12000);
    const errors = [], csp = [];
    page.on('pageerror', error => errors.push(error.message));
    page.on('console', message => { if (/Content Security Policy|violates.*directive/i.test(message.text())) csp.push(message.text()); });
    await page.goto(bridge.base);
    await page.locator('#gate').waitFor({ state: 'visible' });
    await screenshot('rework-gate-light');
    await page.goto(bridge.base + '/#t=' + bridge.token);
    await page.locator('#app').waitFor({ state: 'visible' });
    await page.waitForFunction(() => document.querySelector('#modelLabel').textContent === 'Claude Sonnet 4.5');
    await page.evaluate(() => document.fonts.ready);
    assert.equal(await page.evaluate(() => [...document.fonts].some(face => face.family === 'Inter' && face.status === 'loaded') && document.fonts.check('16px Inter')), true,
      'the bundled conversation font loads successfully');
    assert.equal(await page.locator('#sidebarToggle').getAttribute('aria-expanded'), 'false', 'the reference layout starts with navigation tucked away');
    assert.equal(await page.locator('#sidebar').evaluate(node => node.inert), true);
    assert.equal(await page.locator('.more-nav').evaluate(node => node.open), false);
    await page.locator('#headerMenu summary').click();
    assert.equal(await page.locator('#clear').isVisible(), true, 'conversation actions remain reachable in the header menu');
    await page.keyboard.press('Escape');
    assert.equal(await page.locator('#headerMenu').evaluate(node => node.open), false);
    assert.equal(await page.locator('#headerMenu summary').evaluate(node => node === document.activeElement), true);
    await page.locator('#headerMenu summary').click(); await page.locator('#input').click();
    assert.equal(await page.locator('#headerMenu').evaluate(node => node.open), false, 'clicking outside dismisses workspace actions');

    // Empty composition stays ordered around the composer, including short screens.
    for (const viewport of [{ width: 1440, height: 960 }, { width: 390, height: 844 }, { width: 320, height: 480 }, { width: 844, height: 390 }]) {
      await page.setViewportSize(viewport);
      await page.locator('#suggestions').waitFor({ state: 'visible' });
      const layout = await page.evaluate(() => {
        const rect = selector => {
          const node = document.querySelector(selector), r = node.getBoundingClientRect();
          return { top: r.top, bottom: r.bottom, left: r.left, right: r.right, height: r.height };
        };
        return { chat: document.body.dataset.chat, welcome: rect('.welcome'), composer: rect('#composer'), suggestions: rect('#suggestions'),
          send: rect('#send'), width: innerWidth, height: innerHeight, scroll: document.documentElement.scrollWidth,
          overflow: getComputedStyle(document.querySelector('#chatPage')).overflowY,
          suggestionsInFooter: document.querySelector('#suggestions').parentElement.classList.contains('composer-wrap') };
      });
      assert.equal(layout.chat, 'empty');
      assert.equal(layout.overflow, 'auto');
      assert.equal(layout.suggestionsInFooter, true);
      assert.ok(layout.welcome.bottom <= layout.composer.top + 1, 'the welcome precedes the composer: ' + JSON.stringify(layout));
      assert.ok(layout.composer.bottom <= layout.suggestions.top + 1, 'suggestions follow the composer: ' + JSON.stringify(layout));
      assert.ok(layout.scroll <= layout.width, 'empty layout must not overflow horizontally');
      assert.ok(layout.send.left >= 0 && layout.send.right <= layout.width && layout.send.top >= 0 && layout.send.bottom <= layout.height,
        'the empty composer action must fit: ' + JSON.stringify(layout));
      await screenshot('rework-empty-' + viewport.width);
    }
    await page.setViewportSize({ width: 1440, height: 960 });
    await page.evaluate(() => UAI.theme.set('dark'));
    await screenshot('rework-empty-dark');
    await page.evaluate(() => UAI.theme.set('light'));

    // Repeated game updates keep chip focus; conversation changes update layout.
    await page.locator('.starter').first().focus();
    await page.evaluate(() => { window.focusedStarter = document.activeElement; });
    await push({ state: { ...state, player: 'David updated' } });
    await page.waitForFunction(() => document.querySelector('#transcript .welcome-greeting').textContent.includes('David updated'));
    assert.equal(await page.evaluate(() => document.activeElement === window.focusedStarter && window.focusedStarter.isConnected), true);
    await page.locator('.starter').first().click();
    assert.match(await page.locator('#input').inputValue(), /^Explore this game\./);
    await page.locator('#input').fill('');
    const user = event('user', { text: 'Help me create a quieter corner in this garden.' });
    await push({ state, events: [user, event('turn:start')] });
    await page.locator('.message.user').waitFor({ state: 'visible' });
    assert.equal(await page.locator('body').getAttribute('data-chat'), 'thread');
    assert.equal(await page.locator('#suggestions').isVisible(), false);
    assert.equal(await page.locator('.welcome').count(), 0);
    await page.locator('#stop').waitFor({ state: 'visible' });

    // Each response phase is exercised using actual inference frames.
    upstream = http.createServer((request, response) => {
      liveResponse = response;
      response.writeHead(200, { 'content-type': 'text/event-stream' }); response.flushHeaders();
    });
    upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening');
    const hello = await (await fetch(bridge.base + '/api/hello', { headers: auth })).json();
    const start = async id => {
      liveResponse = null;
      const connection = once(upstream, 'request');
      await post('/api/inference', { id, instance: hello.instance, url: `http://127.0.0.1:${upstream.address().port}/stream`, sessionId: 'visual', body: '{}' });
      await connection;
      await responseState('waiting');
      assert.ok(liveResponse, 'the controlled provider is connected');
    };
    await start('visual-response');
    await screenshot('rework-response-01-waiting', true);
    assert.equal(await page.locator('.stream-indicator').getAttribute('aria-hidden'), 'true');
    assert.notEqual(await page.locator('.stream-indicator i').first().evaluate(node => getComputedStyle(node).animationName), 'none', 'waiting has a visible activity animation');
    write({ reasoning_content: 'I will look at the existing paths, light, and scale before suggesting a small change.' });
    await responseState('thinking');
    await page.locator('.thinking').waitFor({ state: 'visible' });
    await screenshot('rework-response-02-thinking', true);

    await page.evaluate(() => {
      window.responseMotion = [];
      window.responseObserver = new MutationObserver(records => {
        if (!records.some(record => record.addedNodes.length)) return;
        requestAnimationFrame(() => {
          for (const node of document.querySelectorAll('.stream-token, .stream-block-enter')) {
            const name = getComputedStyle(node).animationName;
            if (name !== 'none') window.responseMotion.push({ name, token: node.classList.contains('stream-token') });
          }
        });
      });
      window.responseObserver.observe(document.querySelector('#transcript'), { childList: true, subtree: true });
    });
    let reply = '## A quieter';
    write({ content: reply });
    await responseState('writing');
    await page.waitForFunction(() => document.querySelector('.stream-tail h2')?.textContent === 'A quieter');
    await page.waitForFunction(() => window.responseMotion.length > 0);
    await page.evaluate(() => { window.streamingHeading = document.querySelector('.stream-tail h2'); });
    reply += ' corner'; write({ content: ' corner' });
    await page.waitForFunction(() => document.querySelector('.stream-tail h2')?.textContent === 'A quieter corner');
    await page.waitForFunction(() => window.responseMotion.some(record => record.token));
    assert.equal(await page.evaluate(() => window.streamingHeading === document.querySelector('.stream-tail h2')), true, 'new words animate without replacing the in-progress heading');
    await page.emulateMedia({ reducedMotion: 'reduce' });
    await page.waitForFunction(() => !document.querySelector('.stream-token, .stream-block-enter'));
    await assertQuietResponse();
    await page.emulateMedia({ reducedMotion: 'no-preference' });
    assert.equal(await page.locator('.stream-token, .stream-block-enter').count(), 0, 'restoring motion does not replay already visible text');
    await screenshot('rework-response-03-heading', true);
    const introduction = '\n\nStart with **warm stone**, soft green foliage, and a clear walking path.\n\n';
    reply += introduction; write({ content: introduction });
    await page.waitForFunction(() => document.querySelector('.stream-stable p strong')?.textContent === 'warm stone');
    await page.evaluate(() => {
      window.stableParagraph = document.querySelector('.stream-stable p');
      const range = document.createRange(); range.selectNodeContents(window.stableParagraph);
      const selection = getSelection(); selection.removeAllRanges(); selection.addRange(range);
      window.selectedResponse = selection.toString();
    });
    const detail = '- Keep the center open for movement.\n- Place a low bench beside the planting.\n- Use one warm light as the focal point.\n\n';
    reply += detail; write({ content: detail });
    await page.waitForFunction(() => document.querySelector('.stream-stable ul')?.children.length === 3);
    assert.equal(await page.evaluate(() => window.stableParagraph === document.querySelector('.stream-stable p')), true, 'completed paragraphs stay mounted as the response grows');
    assert.equal(await page.evaluate(() => getSelection().toString() === window.selectedResponse), true, 'new response blocks preserve a text selection');
    await screenshot('rework-response-04-writing', true);
    const code = '```lua\nlocal garden = workspace:FindFirstChild("Garden")\nprint("A little room to create", garden)\n```\n\n';
    reply += code; write({ content: code });
    await page.locator('.stream-stable .copy-code').waitFor({ state: 'visible' });
    await page.evaluate(() => { window.stableCopy = document.querySelector('.stream-stable .copy-code'); });
    const closing = 'The result should feel calm, with enough space for the garden to breathe.';
    reply += closing; write({ content: closing });
    await page.waitForFunction(() => document.querySelector('.stream-tail')?.textContent.includes('garden to breathe.'));
    assert.equal(await page.evaluate(() => window.stableCopy === document.querySelector('.stream-stable .copy-code')), true, 'appending text does not recreate code actions');
    liveResponse.end('data: [DONE]\n\n');
    await responseState('saving');
    await screenshot('rework-response-05-saving');
    await push({ events: [event('assistant:text', { requestId: 'visual-response', text: reply }), event('turn:end')] });
    await responseState('complete');
    assert.equal(await page.locator('.message.agent').count(), 1);
    assert.equal(await page.locator('.stream-status').count(), 0);
    assert.equal(await page.evaluate(() => getSelection().toString() === window.selectedResponse && window.stableParagraph.isConnected), true,
      'committing the saved response preserves the selected live text');
    await page.evaluate(() => { getSelection().removeAllRanges(); window.responseObserver.disconnect(); });
    await page.locator('#input').focus();
    await page.waitForFunction(() => document.querySelector('.message.agent > .body')?.textContent.includes('garden to breathe.'));
    await screenshot('rework-response-06-complete');
    await page.evaluate(() => UAI.theme.set('dark'));
    await screenshot('rework-response-dark');
    await page.setViewportSize({ width: 390, height: 844 });
    await screenshot('rework-response-mobile-dark');
    await page.setViewportSize({ width: 1440, height: 960 });
    await page.evaluate(() => UAI.theme.set('light'));

    // Replayed history stays still; clearing restores the composed empty state.
    const saved = event('assistant:text', { requestId: 'visual-response', text: reply });
    await push({ state, sessionId: 'visual', snapshot: [user, saved] });
    await page.waitForFunction(() => document.querySelectorAll('.message.restored').length === 2);
    assert.equal(await page.locator('.message').evaluateAll(nodes => nodes.every(node => getComputedStyle(node).animationName === 'none')), true,
      'history replay does not animate every old message');
    await push({ events: [event('cleared')] });
    await page.waitForFunction(() => document.body.dataset.chat === 'empty');
    assert.equal(await page.locator('#suggestions').isVisible(), true);
    assert.equal(await page.locator('.starter').count(), 4);

    // Reduced motion applies to the new live response effects, including their pseudo-elements.
    await page.emulateMedia({ reducedMotion: 'reduce' });
    await start('visual-reduced');
    await assertQuietResponse();
    assert.equal(await page.locator('body').getAttribute('data-chat'), 'thread', 'a response arriving first still leaves the welcome');
    write({ content: 'A response with **quiet motion**.\n\nAnother sentence.' });
    await responseState('writing');
    await assertQuietResponse();
    liveResponse.end('data: [DONE]\n\n');
    await responseState('saving');
    await push({ events: [event('assistant:text', { requestId: 'visual-reduced', text: 'A response with **quiet motion**.\n\nAnother sentence.' }), event('turn:end')] });
    await responseState('complete');

    // Provider frames can beat the game's batched user/turn events. Only the
    // response for that new turn may move behind its delayed user message.
    await start('older-failed');
    write({ content: 'An earlier partial response.' });
    await responseState('writing');
    liveResponse.end(); // A stream without [DONE] is a real provider failure.
    await responseState('error');
    await push({ events: [event('turn:end')] });
    await page.evaluate(() => { window.priorResponses = [...document.querySelectorAll('.message.agent')]; });
    await page.evaluate(() => UAI.theme.set('dark'));
    await start('late-greeting');
    const greetingReason = 'A brief greeting is enough. Ask what they would like to work on.';
    const greetingText = 'Hello! What would you like to work on?';
    write({ reasoning_content: greetingReason }); write({ content: greetingText });
    await responseState('writing');
    const delayedUser = event('user', { text: 'hey' });
    await push({ events: [delayedUser, event('turn:start')] });
    await page.waitForFunction(() => [...document.querySelectorAll('.message.user > .body')].some(node => node.textContent === 'hey'));
    const firstRace = await page.evaluate(() => {
      const nodes = [...document.querySelector('#transcript').children];
      const user = nodes.find(node => node.matches('.message.user') && node.querySelector(':scope > .body').textContent === 'hey');
      const response = nodes.find(node => node.dataset.requestId === 'late-greeting');
      return { ordered: nodes.indexOf(user) < nodes.indexOf(response), oldBefore: window.priorResponses.every(node => node.isConnected && nodes.indexOf(node) < nodes.indexOf(user)),
        thoughts: response?.querySelectorAll(':scope > .thinking').length, detachedThoughts: document.querySelectorAll('#transcript > .thinking').length };
    });
    assert.deepEqual(firstRace, { ordered: true, oldBefore: true, thoughts: 1, detachedThoughts: 0 },
      'an early response must follow its delayed user without moving older complete/failed replies');
    await screenshot('rework-greeting-race-dark');
    liveResponse.end('data: [DONE]\n\n'); await responseState('saving');
    const reasoningOne = event('assistant:reasoning', { requestId: 'late-greeting', text: greetingReason });
    const answerOne = event('assistant:text', { requestId: 'late-greeting', text: greetingText });
    const toolCall = event('tool:call', { id: 'garden-inspection', name: 'inspect_workspace', arguments: '{}' });
    const toolResult = event('tool:result', { id: 'garden-inspection', name: 'inspect_workspace', ok: true, text: 'Found a garden, a stone path, and a small planting bed.' });
    await push({ events: [reasoningOne, answerOne, toolCall, toolResult] });
    await start('late-tool-followup');
    const followupReason = 'Use the workspace inspection to suggest a restrained change.';
    const followupText = '## A quieter corner\n\nKeep the stone path clear and use **soft planting** to frame the seating.\n\n- Add a low bench beside the planting bed.\n- Keep the center open for movement.\n- Use one warm light as the focal point.';
    write({ reasoning_content: followupReason }); write({ content: followupText });
    await responseState('writing');
    liveResponse.end('data: [DONE]\n\n'); await responseState('saving');
    const reasoningTwo = event('assistant:reasoning', { requestId: 'late-tool-followup', text: followupReason });
    const answerTwo = event('assistant:text', { requestId: 'late-tool-followup', text: followupText });
    await push({ events: [reasoningTwo, reasoningTwo, answerTwo, event('turn:end')] });
    await responseState('complete');
    assert.equal(await page.locator('[data-request-id="late-tool-followup"] > .thinking').count(), 1, 'replayed reasoning joins its existing response once');
    await screenshot('rework-tool-followup-dark');
    await page.evaluate(() => { window.firstTurnResponses = [...document.querySelectorAll('.message.agent')]; });

    // Repeat the race on a later turn, after a tool-driven multi-response turn.
    await start('late-next-turn');
    const nextReason = 'Place the new bench near the path while preserving room to walk.';
    const nextText = 'Place the bench beside the path, facing the garden. Leave the center open so movement stays easy.';
    write({ reasoning_content: nextReason }); write({ content: nextText });
    await responseState('writing');
    const nextUser = event('user', { text: 'Add a bench near the path.' });
    await push({ events: [nextUser, event('turn:start')] });
    await page.waitForFunction(() => [...document.querySelectorAll('.message.user > .body')].some(node => node.textContent === 'Add a bench near the path.'));
    assert.equal(await page.evaluate(() => {
      const nodes = [...document.querySelector('#transcript').children];
      const user = nodes.find(node => node.matches('.message.user') && node.querySelector(':scope > .body').textContent === 'Add a bench near the path.');
      return window.firstTurnResponses.every(node => node.isConnected && nodes.indexOf(node) < nodes.indexOf(user)) && nodes.indexOf(user) < nodes.findIndex(node => node.dataset.requestId === 'late-next-turn');
    }), true, 'the next delayed user must not take responses from earlier turns');
    liveResponse.end('data: [DONE]\n\n'); await responseState('saving');
    const reasoningThree = event('assistant:reasoning', { requestId: 'late-next-turn', text: nextReason });
    const answerThree = event('assistant:text', { requestId: 'late-next-turn', text: nextText });
    await push({ events: [reasoningThree, answerThree, event('turn:end')] });
    await responseState('complete');

    const raceView = () => page.locator('#transcript > *').evaluateAll(nodes => nodes.flatMap(node => {
      const body = node.querySelector(':scope > .body');
      if (node.matches('.message.user') && ['hey', 'Add a bench near the path.'].includes(body.textContent)) return [{ kind: 'user', text: body.textContent }];
      if (node.dataset.requestId?.startsWith('late-')) return [{ kind: 'assistant', id: node.dataset.requestId, text: body.textContent,
        thoughts: [...node.querySelectorAll(':scope > .thinking > .body')].map(detail => detail.textContent) }];
      if (node.matches('.tool-call') && node.querySelector('summary strong')?.textContent === 'inspect_workspace') return [{ kind: 'tool', text: node.textContent }];
      return [];
    }));
    const liveOrder = await raceView();
    assert.deepEqual(liveOrder.map(item => item.kind === 'assistant' ? item.id : item.kind),
      ['user', 'late-greeting', 'tool', 'late-tool-followup', 'user', 'late-next-turn']);
    await page.reload(); await page.locator('#app').waitFor({ state: 'visible' });
    await page.waitForFunction(() => document.querySelectorAll('[data-request-id^="late-"]').length === 3);
    assert.deepEqual(await raceView(), liveOrder, 'reload preserves the live conversation order, prose and integrated thought disclosures');
    const savedHistory = [delayedUser, event('turn:start'), reasoningOne, answerOne, toolCall, toolResult,
      reasoningTwo, reasoningTwo, answerTwo, event('turn:end'), nextUser, event('turn:start'), reasoningThree, answerThree, event('turn:end')];
    await push({ state, sessionId: 'visual', snapshot: savedHistory });
    await page.waitForFunction(() => document.querySelectorAll('#transcript > .message').length === 5 && document.querySelectorAll('.message.restored[data-request-id^="late-"]').length === 3);
    assert.deepEqual(await raceView(), liveOrder, 'a fresh saved snapshot has the same order and no duplicated reasoning');
    assert.equal(await page.locator('#transcript > .thinking').count(), 0);
    await screenshot('rework-response-order-final-dark');
    await page.setViewportSize({ width: 390, height: 844 }); await screenshot('rework-response-order-mobile-dark');
    assert.deepEqual(errors, []);
    assert.deepEqual(csp, []);
    console.log('Visual rework checks passed: empty layouts, bundled font/CSP, navigation, response phases/Markdown/motion, stable selection, reduced motion, delayed-user races, tool followups, reload/snapshot ordering');
  } finally {
    clearInterval(heartbeat); upstream?.closeAllConnections(); upstream?.close();
    await browser?.close(); await bridge.stop();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
