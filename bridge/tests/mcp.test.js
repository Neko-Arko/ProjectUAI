'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const { startBridge, sleep, root } = require('./helpers/bridge');
const { consume, options, discoverDesktop } = require('../mcp-stdio');

const tool = { name: 'inspect_instance', description: 'Inspect a Roblox instance', risk: 'read',
  parameters: { type: 'object', properties: { path: { type: 'string' } }, required: ['path'] }, available: true, enabled: true };

async function fixture(t) {
  const bridge = await startBridge(t);
  const auth = { Authorization: 'Bearer ' + bridge.token, 'content-type': 'application/json' };
  const game = async (route, body) => {
    const response = await fetch(bridge.base + route, { method: 'POST', headers: auth, body: JSON.stringify(body) });
    assert.ok(response.ok, route + ': ' + response.status);
    return response;
  };
  const state = async (tools = [tool]) => game('/api/agent/events', { state: { sessionId: 'browser-thread', mcp: { schema: 1 }, tools } });
  await state();
  const inbox = async (client = 'game-one') => (await (await fetch(bridge.base + '/api/agent/inbox', {
    headers: { ...auth, 'X-UAI-Client': client, 'X-UAI-Poll-Wait-Ms': '0' } })).json()).commands;
  const rpc = (message, session, extra = {}) => fetch(bridge.base + '/mcp', { method: 'POST',
    headers: { ...auth, Accept: 'application/json, text/event-stream', ...(session ? { 'Mcp-Session-Id': session } : {}), ...extra },
    body: JSON.stringify(message) });
  async function initialize(name = 'test harness', protocolVersion = '2025-11-25') {
    const response = await rpc({ jsonrpc: '2.0', id: 'init', method: 'initialize',
      params: { protocolVersion, clientInfo: { name, version: '1.0' }, capabilities: {} } });
    assert.equal(response.status, 200);
    const result = await response.json();
    const session = response.headers.get('mcp-session-id');
    assert.match(session, /^[a-f0-9-]{36}$/);
    assert.equal((await rpc({ jsonrpc: '2.0', method: 'notifications/initialized' }, session)).status, 202);
    return { session, result };
  }
  async function answer(response) {
    const values = [];
    await consume(response, value => values.push(value));
    return values.findLast(value => value.id !== undefined);
  }
  return { ...bridge, auth, game, state, inbox, rpc, initialize, answer };
}

test('MCP negotiates lifecycle, enforces auth/host/origin and exposes private-free configuration', async t => {
  const f = await fixture(t);
  assert.equal((await fetch(f.base + '/mcp')).status, 401);
  assert.equal((await fetch(f.base + '/mcp?token=' + f.token)).status, 401);
  const ping = { jsonrpc: '2.0', id: 1, method: 'ping' };
  assert.equal((await f.rpc(ping, null, { Origin: 'https://evil.example' })).status, 403);
  const hostStatus = await new Promise((resolve, reject) => {
    const request = http.request(f.base + '/mcp', { method: 'POST', headers: { ...f.auth, Host: 'evil.example' } }, response => {
      response.resume(); response.on('end', () => resolve(response.statusCode));
    });
    request.on('error', reject); request.end(JSON.stringify(ping));
  });
  assert.equal(hostStatus, 403);
  assert.equal((await f.rpc(ping)).status, 400);
  assert.equal((await f.rpc([], null)).status, 400);
  assert.equal((await f.rpc(ping, null, { 'content-type': 'text/plain' })).status, 415);
  const { session, result } = await f.initialize('Claude Code', '2099-01-01');
  assert.equal(result.result.protocolVersion, '2025-11-25');
  assert.deepEqual(result.result.capabilities, { tools: { listChanged: true } });
  assert.deepEqual((await (await f.rpc(ping, session)).json()).result, {});
  assert.equal((await f.rpc(ping, session, { 'MCP-Protocol-Version': 'bogus' })).status, 400);
  const unknown = await (await f.rpc({ ...ping, method: 'sampling/createMessage' }, session)).json();
  assert.equal(unknown.error.code, -32601);
  const config = await (await fetch(f.base + '/api/mcp/config', { headers: f.auth })).json();
  assert.equal(config.endpoint, f.base + '/mcp'); assert.equal(config.available, true);
  assert.equal(config.tools, 1); assert.equal(config.sessions[0].clientName, 'Claude Code');
  assert.ok(config.stdio.args.includes('--mcp-stdio'));
  assert.ok(!JSON.stringify(config).includes(f.token));
  const hello = await (await fetch(f.base + '/api/hello', { headers: f.auth })).json();
  assert.deepEqual(hello.capabilities.mcp.transports, ['streamable-http', 'stdio']);
  assert.equal((await fetch(f.base + '/mcp', { method: 'DELETE', headers: { ...f.auth, 'Mcp-Session-Id': session } })).status, 200);
  assert.equal((await f.rpc(ping, session)).status, 404);
});

test('MCP uses game schemas and receipts, forwards semantic errors and prevents duplicate execution', async t => {
  const f = await fixture(t), { session } = await f.initialize('Cursor');
  await f.state([tool, { ...tool, name: 'denied', effectiveRule: 'deny' }, { ...tool, name: 'disabled', enabled: false },
    { ...tool, name: 'unavailable', available: false }, { ...tool, name: 'empty', parameters: { type: 'object', properties: [] } }]);
  const list = await (await f.rpc({ jsonrpc: '2.0', id: 1, method: 'tools/list' }, session)).json();
  assert.deepEqual(list.result.tools.map(item => item.name), ['inspect_instance', 'empty']);
  assert.deepEqual(list.result.tools[0].inputSchema, tool.parameters);
  assert.deepEqual(list.result.tools[1].inputSchema.properties, {});
  const message = { jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: tool.name, arguments: { path: 'Workspace' } } };
  const response = await f.rpc(message, session), duplicate = await f.rpc(message, session);
  const commands = await f.inbox();
  assert.equal(commands.length, 1);
  const command = commands[0];
  assert.equal(command.type, 'mcp:call'); assert.equal(command.name, tool.name);
  assert.equal(command.mcpSessionId, session); assert.equal(command.clientName, 'Cursor');
  assert.equal(command.sessionId, undefined, 'must not target the active browser conversation');
  await f.game('/api/agent/ack', { results: [{ id: command.commandId, pending: true }] });
  assert.equal((await f.inbox()).length, 0);
  await f.game('/api/agent/ack', { results: [{ id: command.commandId, ok: true, data: { ok: true, text: 'Workspace found', data: { className: 'Workspace' } } }] });
  const value = await f.answer(response);
  assert.equal(value.result.content[0].text, 'Workspace found'); assert.equal(value.result.isError, undefined);
  assert.deepEqual(value.result.structuredContent, { className: 'Workspace' });
  assert.deepEqual(await f.answer(duplicate), value);
  assert.deepEqual(await (await f.rpc(message, session)).json(), value);
  assert.equal((await f.inbox()).length, 0);
  const conflict = await (await f.rpc({ ...message, params: { ...message.params, arguments: { path: 'Players' } } }, session)).json();
  assert.equal(conflict.error.code, -32600);
  const failed = await f.rpc({ ...message, id: 3 }, session);
  const [next] = await f.inbox();
  await f.game('/api/agent/ack', { results: [{ id: next.commandId, ok: true, data: { ok: false, text: 'Instance is missing', error: 'tool reported a failure' } }] });
  assert.deepEqual((await f.answer(failed)).result, { content: [{ type: 'text', text: 'Instance is missing' }], isError: true });
  const denied = await (await f.rpc({ ...message, id: 4, params: { name: 'denied', arguments: {} } }, session)).json();
  assert.equal(denied.error.code, -32602);
});

test('MCP cancellation is scoped and disconnecting a response can reattach to the original call', async t => {
  const f = await fixture(t), first = await f.initialize('Codex'), second = await f.initialize('OpenCode');
  const message = { jsonrpc: '2.0', id: 7, method: 'tools/call', params: { name: tool.name, arguments: { path: 'Workspace' } } };
  const a = await f.rpc(message, first.session), b = await f.rpc(message, second.session);
  const commands = await f.inbox(); assert.equal(commands.length, 2);
  const ca = commands.find(item => item.mcpSessionId === first.session), cb = commands.find(item => item.mcpSessionId === second.session);
  await f.game('/api/agent/ack', { results: commands.map(item => ({ id: item.commandId, pending: true })) });
  assert.equal((await f.rpc({ jsonrpc: '2.0', method: 'notifications/cancelled', params: { requestId: 7 } }, first.session)).status, 202);
  assert.equal((await f.answer(a)).error.code, -32800);
  const cancellation = (await f.inbox()).find(item => item.type === 'mcp:cancel');
  assert.equal(cancellation.mcpSessionId, first.session); assert.equal(cancellation.callId, ca.callId);
  await f.game('/api/agent/ack', { results: [{ id: cb.commandId, ok: true, data: { ok: true, text: 'Second harness completed' } }] });
  assert.equal((await f.answer(b)).result.content[0].text, 'Second harness completed');
  const controller = new AbortController();
  const nextMessage = { ...message, id: 8 };
  const detached = await fetch(f.base + '/mcp', { method: 'POST', headers: { ...f.auth, Accept: 'application/json, text/event-stream', 'Mcp-Session-Id': second.session }, body: JSON.stringify(nextMessage), signal: controller.signal });
  assert.equal(detached.status, 200); controller.abort();
  await sleep(40);
  const original = (await f.inbox()).find(item => item.type === 'mcp:call');
  const reattached = await f.rpc(nextMessage, second.session);
  assert.equal((await f.inbox()).filter(item => item.type === 'mcp:call').length, 1);
  await f.game('/api/agent/ack', { results: [{ id: original.commandId, ok: true, data: { ok: true, text: 'Retained result' } }] });
  assert.equal((await f.answer(reattached)).result.content[0].text, 'Retained result');
});

test('MCP close removes undelivered calls and game restart returns uncertainty without replay', async t => {
  const f = await fixture(t), { session } = await f.initialize();
  const message = { jsonrpc: '2.0', id: 10, method: 'tools/call', params: { name: tool.name, arguments: { path: 'Workspace' } } };
  const pending = await f.rpc(message, session);
  await fetch(f.base + '/mcp', { method: 'DELETE', headers: { ...f.auth, 'Mcp-Session-Id': session } });
  assert.equal((await f.answer(pending)).error.code, -32800);
  assert.equal((await f.inbox()).filter(item => item.type === 'mcp:call').length, 0);
  const next = await f.initialize(), running = await f.rpc(message, next.session);
  const command = (await f.inbox()).find(item => item.type === 'mcp:call');
  assert.ok(command);
  await f.inbox('replacement-game');
  const result = await f.answer(running);
  assert.equal(result.result.isError, true); assert.match(result.result.content[0].text, /uncertain/);
  assert.equal((await f.inbox('replacement-game')).filter(item => item.type === 'mcp:call').length, 0);
});

test('MCP publishes catalogue change notifications over a standard GET event stream', async t => {
  const f = await fixture(t), { session } = await f.initialize();
  const controller = new AbortController(); t.after(() => controller.abort());
  const stream = await fetch(f.base + '/mcp', { headers: { ...f.auth, Accept: 'text/event-stream', 'Mcp-Session-Id': session }, signal: controller.signal });
  assert.equal(stream.status, 200);
  const received = [];
  const reading = consume(stream, value => received.push(value), controller.signal).catch(error => { if (!controller.signal.aborted) throw error; });
  await f.state([{ ...tool, enabled: false }]);
  for (let i = 0; i < 30 && !received.length; i++) await sleep(100);
  assert.equal(received[0]?.method, 'notifications/tools/list_changed');
  controller.abort(); await reading;
});

test('stdio adapter works through the server entry point and keeps diagnostics off stdout', async t => {
  const f = await fixture(t);
  const child = spawn(process.execPath, ['bridge/server.js', '--mcp-stdio', '--url', f.base], {
    cwd: root, env: { ...process.env, UAI_BRIDGE_TOKEN: f.token }, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'],
  });
  t.after(async () => { if (child.exitCode === null && child.signalCode === null) { const done = once(child, 'exit'); child.kill(); await done; } });
  let buffer = '', stderr = ''; const received = [];
  child.stdout.on('data', chunk => {
    buffer += chunk;
    let at;
    while ((at = buffer.indexOf('\n')) >= 0) { received.push(JSON.parse(buffer.slice(0, at))); buffer = buffer.slice(at + 1); }
  });
  child.stderr.on('data', chunk => { stderr += chunk; });
  const send = message => child.stdin.write(JSON.stringify({ jsonrpc: '2.0', ...message }) + '\n');
  async function waitFor(id) {
    for (let i = 0; i < 100; i++) {
      const found = received.find(item => item.id === id); if (found) return found;
      await sleep(30);
    }
    assert.fail('Missing stdio response ' + id + ': ' + stderr);
  }
  send({ id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'stdio harness', version: '1' } } });
  send({ method: 'notifications/initialized' });
  assert.equal((await waitFor(1)).result.protocolVersion, '2025-06-18');
  send({ id: 2, method: 'tools/list' });
  assert.equal((await waitFor(2)).result.tools[0].name, tool.name);
  send({ id: 3, method: 'tools/call', params: { name: tool.name, arguments: { path: 'Workspace' } } });
  let command;
  for (let i = 0; i < 40 && !command; i++) { command = (await f.inbox()).find(item => item.type === 'mcp:call'); if (!command) await sleep(30); }
  assert.ok(command);
  await f.game('/api/agent/ack', { results: [{ id: command.commandId, ok: true, data: { ok: true, text: 'Stdio executed' } }] });
  assert.equal((await waitFor(3)).result.content[0].text, 'Stdio executed');
  const active = await (await fetch(f.base + '/api/mcp/config', { headers: f.auth })).json();
  await fetch(f.base + '/mcp', { method: 'DELETE', headers: { ...f.auth, 'Mcp-Session-Id': active.sessions[0].id } });
  send({ id: 4, method: 'tools/list' });
  assert.match((await waitFor(4)).error.message, /session expired/);
  send({ id: 5, method: 'tools/call', params: { name: tool.name, arguments: {} } });
  assert.match((await waitFor(5)).error.message, /Reconnect/);
  send({ id: 6, method: 'initialize', params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'stdio reconnect', version: '1' } } });
  assert.equal((await waitFor(6)).result.serverInfo.name, 'Project UAI');
  send({ method: 'notifications/initialized' });
  send({ id: 7, method: 'tools/list' });
  assert.equal((await waitFor(7)).result.tools[0].name, tool.name);
  const exited = once(child, 'exit'); child.stdin.end(); await exited;
  assert.equal(child.exitCode, 0); assert.equal(stderr, '');
  assert.ok(!JSON.stringify(received).includes(f.token));
  const config = await (await fetch(f.base + '/api/mcp/config', { headers: f.auth })).json();
  assert.equal(config.sessions.length, 0, 'stdin closure ends the owned MCP session');
});

test('stdio options restrict credential routing to the local bridge', () => {
  assert.equal(options([], {}).endpoint, 'http://127.0.0.1:28791/mcp');
  assert.equal(options(['--url', 'http://localhost:8790/mcp'], {}).endpoint, 'http://127.0.0.1:8790/mcp');
  for (const url of ['https://example.com', 'http://127.0.0.1:8790/mcp?token=secret', 'http://secret@localhost:8790', 'http://127.0.0.1/path']) {
    assert.throws(() => options(['--url', url], {}), /loopback HTTP/);
  }
  assert.throws(() => options([], { UAI_BRIDGE_TOKEN: 'invalid' }), /pairing token/);
});

test('stdio reopens disconnected notification streams without replaying requests', async t => {
  let streams = 0, posts = 0, deleted = false;
  const server = http.createServer((req, res) => {
    if (req.method === 'GET') {
      streams++;
      res.writeHead(200, { 'content-type': 'text/event-stream' });
      if (streams === 1) res.end(': disconnected\n\n');
      else res.write('data: {"jsonrpc":"2.0","method":"notifications/tools/list_changed"}\n\n');
      return;
    }
    if (req.method === 'DELETE') { deleted = true; res.writeHead(204); res.end(); return; }
    let data = ''; req.on('data', chunk => { data += chunk; });
    req.on('end', () => {
      posts++;
      const message = JSON.parse(data);
      if (message.id === undefined) { res.writeHead(202); res.end(); return; }
      res.writeHead(200, { 'content-type': 'application/json', 'mcp-session-id': 'fixture-session' });
      res.end(JSON.stringify({ jsonrpc: '2.0', id: message.id, result: {
        protocolVersion: '2025-06-18', capabilities: { tools: { listChanged: true } },
        serverInfo: { name: 'fixture', version: '1' },
      } }));
    });
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(() => { server.closeAllConnections(); server.close(); });
  const child = spawn(process.execPath, ['bridge/server.js', '--mcp-stdio', '--url', 'http://127.0.0.1:' + server.address().port], {
    cwd: root, env: { ...process.env, UAI_BRIDGE_TOKEN: 'a'.repeat(64) }, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'],
  });
  t.after(async () => { if (child.exitCode === null && child.signalCode === null) { const done = once(child, 'exit'); child.kill(); await done; } });
  let output = '', errors = '';
  child.stdout.on('data', chunk => { output += chunk; }); child.stderr.on('data', chunk => { errors += chunk; });
  child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} }) + '\n');
  child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
  for (let i = 0; i < 100 && !output.includes('notifications/tools/list_changed'); i++) await sleep(30);
  assert.ok(output.includes('notifications/tools/list_changed'), 'notification delivered after a read-only reconnect');
  assert.equal(streams, 2); assert.equal(posts, 2, 'no initialization or tool POST was retried');
  const exit = once(child, 'exit'); child.stdin.end(); await exit;
  assert.equal(child.exitCode, 0); assert.equal(errors, ''); assert.ok(deleted);
  const stoppedStreams = streams; await sleep(650);
  assert.equal(streams, stoppedStreams, 'EOF cancels notification reconnects');
});

test('native stdio discovery omits browser headers and verifies desktop identity without redirects', async t => {
  let response = {}, status = 200;
  const server = http.createServer((req, res) => {
    assert.equal(req.method, 'POST'); assert.equal(req.url, '/api/desktop/discover');
    assert.equal(req.headers['x-uai-discovery'], '1');
    assert.equal(req.headers.origin, undefined);
    assert.ok(!Object.keys(req.headers).some(name => name.startsWith('sec-fetch-')));
    res.writeHead(status, { 'content-type': 'application/json', Location: 'http://example.invalid' }); res.end(JSON.stringify(response));
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(() => { server.closeAllConnections(); server.close(); });
  const port = server.address().port, origin = 'http://127.0.0.1:' + port;
  const valid = { product: 'project-uai-desktop', protocol: 1, port, instance: 'test-instance', token: 'a'.repeat(64) };
  response = valid; assert.equal(await discoverDesktop(origin), valid.token);
  for (const wrong of [{ port: port + 1 }, { protocol: 2 }, { product: 'another-app' }, { instance: '' }, { token: 'bad' }]) {
    response = { ...valid, ...wrong };
    await assert.rejects(discoverDesktop(origin), /discovery unavailable/);
  }
  response = valid; status = 302;
  await assert.rejects(discoverDesktop(origin), /discovery unavailable/);
});
