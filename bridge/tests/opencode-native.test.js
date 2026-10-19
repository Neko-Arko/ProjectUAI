'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { createOpenCode, official, findBinary, responseBody, promptInput, toolDefinitions } = require('../opencode');
const { createInference } = require('../inference');
const { sleep } = require('./helpers/bridge');

function native(t, environment = {}) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'uai-native-fixture-'));
  const log = path.join(directory, 'events.jsonl');
  const backend = createOpenCode({ binary: process.execPath, binaryArgs: [path.join(__dirname, 'fixtures', 'opencode-cli.js')],
    env: { ...process.env, UAI_OPENCODE_DISABLED: '0', UAI_OPENCODE_FIXTURE_LOG: log, ...environment }, startupMs: 5000, pollMs: 10 });
  t.after(async () => { await backend.close(); fs.rmSync(directory, { recursive: true, force: true }); });
  return { backend, events: () => fs.readFileSync(log, 'utf8').trim().split('\n').map(JSON.parse) };
}
const input = text => ({ model: 'fixture-free', messages: [{ role: 'user', content: text }] });
const url = 'https://opencode.ai/zen/v1/chat/completions';

test('native server discovery confines process, Basic auth and temporary files', async t => {
  const { backend, events } = native(t);
  assert.equal(backend.capability().state, 'starting');
  const models = await backend.models(); assert.equal(models.data[0].id, 'fixture-free');
  assert.equal(models.data.length, 1, 'only verified zero-price models use the public native connection');
  assert.equal(backend.accepts(url, JSON.stringify({ model: 'fixture-paid' })), false);
  for (const base of ['https://opencode.ai/inference/go/v1', 'https://opencode.ai/zen/go/v1']) {
    for (const route of ['/chat/completions', '/responses']) {
      assert.equal(backend.accepts(base + route, JSON.stringify(input('Go subscription request'))), false,
        'Go retains its keyed endpoint even when a model id also exists in the free catalog');
    }
  }
  assert.equal(backend.capability().state, 'ready');
  assert.equal(backend.capability().version, '2.0.32');
  assert.equal(backend.capability().binary, path.basename(process.execPath));
  assert.doesNotMatch(JSON.stringify(backend.capability()), /password|pid|directory|127\.0\.0\.1/);
  const ready = events().find(e => e.type === 'ready');
  assert.equal(ready.passwordLength, 64); assert.equal(ready.isolated, true);
  assert.equal((await fetch('http://127.0.0.1:' + ready.port + '/api/model')).status, 401);
  await backend.close(); assert.equal(backend.capability().available, false);
  assert.equal(fs.existsSync(ready.directory), false);
  await assert.rejects(fetch('http://127.0.0.1:' + ready.port + '/api/model'));
});

test('disabled native tunnel never starts even with a configured binary', async t => {
  const backend = createOpenCode({ binary: process.execPath, env: { UAI_OPENCODE_DISABLED: '1' } });
  t.after(() => backend.close());
  assert.equal(backend.capability().enabled, false);
  assert.equal(backend.capability().state, 'disabled');
  assert.equal(backend.capability().available, false);
  assert.match(backend.capability().message, /turned off/);
  await assert.rejects(backend.models(), /turned off/);
  assert.equal(backend.accepts(url, JSON.stringify(input('ignored'))), false);
});

test('incompatible installed API fails before creating a session', async t => {
  const { backend, events } = native(t, { UAI_OPENCODE_FIXTURE_OLD_API: '1', UAI_OPENCODE_FIXTURE_VERSION: '1.19.3' });
  await assert.rejects(backend.start(), /incompatible server API/);
  assert.equal(backend.capability().state, 'failed');
  assert.equal(backend.capability().available, false);
  assert.match(backend.capability().message, /incompatible server API/);
  assert.equal(backend.capability().version, '1.19.3');
  assert.match(backend.capability().message, /1\.19\.3.*@opencode\/cli/);
  assert.ok(!events().some(event => event.type === 'session'));
});

test('an incompatible PATH CLI cannot hide the compatible installed npm CLI', async t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'uai-native-discovery-'));
  let backend;
  t.after(async () => { await backend?.close(); fs.rmSync(directory, { recursive: true, force: true }); });
  const windows = process.platform === 'win32', name = windows ? 'opencode.exe' : 'opencode';
  const direct = path.join(directory, 'bin');
  const modules = path.join(directory, windows ? 'bin' : 'lib', 'node_modules');
  const legacy = path.join(direct, name), compatible = path.join(modules, '@opencode', 'cli', 'bin', name);
  for (const file of [legacy, compatible]) {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    try { fs.linkSync(process.execPath, file); } catch { fs.copyFileSync(process.execPath, file); }
  }
  const log = path.join(directory, 'events.jsonl'), absent = path.join(directory, 'absent');
  const env = { ...process.env, PATH: direct, LOCALAPPDATA: absent, APPDATA: absent, USERPROFILE: absent, HOME: absent,
    ProgramFiles: absent, 'ProgramFiles(x86)': absent, BUN_INSTALL: absent, NVM_SYMLINK: absent, NVM_BIN: absent,
    NPM_CONFIG_PREFIX: absent, PNPM_HOME: absent, UAI_OPENCODE_BINARY: '', UAI_OPENCODE_DISABLED: '0',
    UAI_OPENCODE_FIXTURE_LOG: log, UAI_OPENCODE_FIXTURE_OLD_BINARY: fs.realpathSync(legacy) };
  assert.equal(findBinary(env), fs.realpathSync(legacy), 'the legacy executable is the first discovery candidate');
  backend = createOpenCode({ env, binaryArgs: [path.join(__dirname, 'fixtures', 'opencode-cli.js')], startupMs: 5000, pollMs: 10 });
  const models = await backend.models();
  assert.equal(models.data[0].id, 'fixture-free');
  assert.equal(backend.capability().state, 'ready');
  assert.equal(backend.capability().version, '2.0.32');
  const events = fs.readFileSync(log, 'utf8').trim().split('\n').map(JSON.parse);
  const ready = events.filter(event => event.type === 'ready');
  assert.deepEqual(ready.map(event => event.legacy), [true, false]);
  assert.throws(() => process.kill(ready[0].pid, 0), { code: 'ESRCH' }, 'the rejected server is stopped before replacement');
  assert.equal(events.filter(event => event.type === 'session' || event.type === 'prompt').length, 0,
    'candidate selection never submits inference');
});

test('native inference retains one job, translates tool handoff and cleans sessions', async t => {
  const { backend, events } = native(t), frames = [];
  await backend.start();
  const relay = createInference({ opencode: backend, publish: frame => frames.push(frame) }); t.after(() => relay.close());
  const body = { ...input('USE_TOOL'), tools: [{ type: 'function', function: { name: 'lookup', parameters: { type: 'object', properties: { value: { type: 'string' } } } } }] };
  const request = { id: 'native_tool_handoff', instance: relay.instance, url, sessionId: 'roblox_fixture', body: JSON.stringify(body), headers: { authorization: 'Bearer should-not-reach-native' } };
  relay.start(request); relay.start(request);
  for (let i = 0; i < 300 && relay.get(request.id).state === 'running'; i++) await sleep(10);
  const result = relay.get(request.id); assert.equal(result.state, 'completed', result.error);
  const response = JSON.parse(result.body), tool = response.choices[0].message.tool_calls[0];
  assert.equal(tool.function.name, 'lookup'); assert.deepEqual(JSON.parse(tool.function.arguments), { value: 'fixture' });
  assert.equal(response.choices[0].finish_reason, 'tool_calls');
  relay.start(request);
  assert.equal(events().filter(e => e.type === 'prompt').length, 1);
  assert.equal(events().filter(e => e.type === 'delete').length, 1);
  const rules = events().find(e => e.type === 'session').permissions;
  assert.deepEqual(rules, [{ action: '*', resource: '*', effect: 'ask' }, { action: 'uai_lookup', resource: '*', effect: 'allow' }]);
  assert.ok(frames.some(e => e.kind === 'inference:delta' && e.text === 'Checking Roblox.'));
  assert.doesNotMatch(JSON.stringify(events()), /should-not-reach-native|Bearer|Basic/);
});

test('native stop interrupts the owned session and never dispatches again', async t => {
  const { backend, events } = native(t); await backend.start();
  const controller = new AbortController();
  const pending = backend.request({ body: JSON.stringify(input('WAIT_FOREVER')), url, signal: controller.signal });
  const rejected = assert.rejects(pending, /Stopped|aborted/i);
  for (let i = 0; i < 200 && !events().some(e => e.type === 'prompt'); i++) await sleep(10);
  controller.abort(); await rejected;
  assert.equal(events().filter(e => e.type === 'prompt').length, 1);
  assert.ok(events().some(e => e.type === 'interrupt')); assert.ok(events().some(e => e.type === 'delete'));
});

test('native host actions are never approved and Responses text stays compatible', async t => {
  const { backend, events } = native(t);
  await assert.rejects(backend.request({ body: JSON.stringify(input('HOST_ACTION')), url }), /not approved/);
  assert.equal(events().filter(e => e.type === 'prompt').length, 1);
  assert.ok(events().some(e => e.type === 'delete'));
  const reply = await backend.request({ body: JSON.stringify({ model: 'fixture-free', input: 'Reply PONG' }), url: 'https://opencode.ai/inference/v1/responses' });
  const response = JSON.parse(reply.body);
  assert.equal(response.status, 'completed'); assert.equal(response.output[1].content[0].text, 'PONG');
});

test('native handoff waits for every streamed tool, indexes previews, and fails impossible handoffs', { timeout: 5000 }, async t => {
  const { backend, events } = native(t), frames = [];
  const tools = [{ type: 'function', function: { name: 'lookup' } }];
  const reply = await backend.request({ body: JSON.stringify({ ...input('USE_TOOL PARALLEL'), tools }), url, onFrame: frame => frames.push(frame) });
  const calls = JSON.parse(reply.body).choices[0].message.tool_calls;
  assert.equal(calls.length, 2); assert.notEqual(calls[0].id, calls[1].id);
  assert.deepEqual(frames.flatMap(frame => frame.choices?.[0]?.delta?.tool_calls || []).map(call => call.index), [0, 1]);
  assert.ok(events().filter(e => e.type === 'tools').every(e => !fs.existsSync(e.location)), 'request location released before completion');
  await assert.rejects(backend.request({ body: JSON.stringify({ ...input('BROKEN_TOOL'), tools }), url }), /could not hand off/);
  await assert.rejects(backend.request({ body: JSON.stringify({ ...input('USE_TOOL OVERSIZED'), tools }), url }), /oversized tool arguments/);
});

test('only official routes and external native binaries qualify', async () => {
  for (const route of [url, 'https://opencode.ai/inference/v1/responses', 'https://opencode.ai/inference/openai/v1/chat/completions']) assert.equal(official(route), true);
  for (const route of ['https://opencode.ai.evil.invalid/zen/v1/chat/completions', 'http://opencode.ai/zen/v1/chat/completions', 'https://opencode.ai/other/chat/completions', 'https://user:secret@opencode.ai/zen/v1/chat/completions', 'https://puai-proxy.davidzk.tech/opencode/v1/chat/completions', 'https://opencode.ai/inference/go/v1/chat/completions', 'https://opencode.ai/zen/go/v1/responses']) assert.equal(official(route), false);
  assert.equal(findBinary({ UAI_OPENCODE_DISABLED: '1', UAI_OPENCODE_BINARY: process.execPath }), null);
  assert.equal(findBinary({ UAI_OPENCODE_BINARY: 'relative.exe' }), null);
  const unavailable = createOpenCode({ binary: null });
  await unavailable.close();
  assert.equal(unavailable.capability().available, false); assert.match(unavailable.capability().message, /discord\.gg/);
  await assert.rejects(unavailable.models(), /stopped/);
  const response = responseBody('fixture', { content: [{ type: 'text', text: 'Done' }], finish: 'length' }, [], true);
  assert.equal(response.status, 'incomplete'); assert.equal(response.output[0].content[0].text, 'Done');
});

test('image bytes use native attachments and legacy desktop declarations do not become UAI tools', () => {
  const uri = 'data:image/png;base64,aGVsbG8=';
  for (const content of [[{ type: 'image_url', image_url: { url: uri } }], [{ type: 'input_image', image_url: uri }]]) {
    const prompt = promptInput({ messages: [{ role: 'user', content }] });
    assert.equal(prompt.files[0].uri, uri); assert.match(prompt.text, /Attached image 1/); assert.ok(!prompt.text.includes(uri));
  }
  assert.throws(() => promptInput({ messages: [{ content: [{ type: 'input_image', image_url: 'file:///secret.txt' }] }] }), /reattach/);
  const declared = toolDefinitions({ tools: [{ type: 'function', function: { name: 'bash' } }, { type: 'function', function: { name: 'file_read' } }] });
  assert.deepEqual(declared.map(tool => tool.name), ['file_read']);
});

test('native usage includes cache and reasoning in both wire totals', () => {
  const message = { tokens: { input: 34, output: 3, reasoning: 29, cache: { read: 5632, write: 128 } } };
  const chat = responseBody('fixture', message, [], false).usage;
  assert.deepEqual(chat, { prompt_tokens: 5794, completion_tokens: 32, total_tokens: 5826,
    cache_creation_input_tokens: 128, prompt_tokens_details: { cached_tokens: 5632 },
    completion_tokens_details: { reasoning_tokens: 29 } });
  const responses = responseBody('fixture', message, [], true).usage;
  assert.deepEqual(responses, { input_tokens: 5794, output_tokens: 32, total_tokens: 5826,
    cache_creation_input_tokens: 128, input_tokens_details: { cached_tokens: 5632 },
    output_tokens_details: { reasoning_tokens: 29 } });
  assert.equal(responseBody('fixture', {}, [], false).usage, undefined);
});
