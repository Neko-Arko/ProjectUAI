'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const { root, startBridge } = require('./helpers/bridge');
const PORT = 28791;

function request(path, options = {}) {
  const { method = 'POST', headers = {} } = options;
  // Only POST carries a body here. Node's keep-alive agent reuses the socket, and a
  // body a GET/HEAD/OPTIONS route never reads would desynchronise the next request.
  const body = options.body !== undefined ? options.body : method === 'POST' ? '{}' : undefined;
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port: PORT, path, method,
      headers: { 'Content-Type': 'application/json', 'X-UAI-Discovery': '1', ...headers } }, res => {
      let text = ''; res.setEncoding('utf8'); res.on('data', chunk => text += chunk);
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, text }));
    });
    req.setTimeout(4000, () => req.destroy(Error('request timed out')));
    req.on('error', reject); req.end(body);
  });
}
async function desktop(t, environment = {}) {
  const proc = spawn(process.execPath, ['bridge/server.js', '--desktop'], { cwd: root, env: { ...process.env, UAI_BRIDGE_TEST_NO_UPDATES: '1', UAI_OPENCODE_DISABLED: '1', ...environment }, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
  const exit = once(proc, 'exit');
  const stop = async (eof = false) => {
    if (proc.exitCode !== null || proc.signalCode !== null) return;
    if (eof) proc.stdin.end(); else proc.stdin.write('{"type":"stop"}\n');
    await Promise.race([exit, new Promise((_, reject) => {
      const timer = setTimeout(() => { proc.kill(); reject(Error('desktop did not stop')); }, 5000);
      exit.finally(() => clearTimeout(timer));
    })]);
  };
  t.after(stop);
  const message = await new Promise((resolve, reject) => {
    let output = '';
    const timer = setTimeout(() => { proc.kill(); reject(Error('desktop did not become ready')); }, 10000);
    proc.on('error', error => { clearTimeout(timer); reject(error); });
    proc.stdout.on('data', chunk => {
      output += chunk;
      const newline = output.indexOf('\n');
      if (newline >= 0) {
        clearTimeout(timer);
        try { resolve(JSON.parse(output.slice(0, newline))); } catch (error) { reject(error); }
      }
    });
  });
  return { proc, exit, stop, message };
}

test('desktop lifecycle, native discovery and browser isolation', async t => {
  const first = await desktop(t);
  assert.equal(first.message.type, 'ready', first.message.message);
  assert.equal(first.message.port, PORT);
  assert.match(first.message.token, /^[a-f0-9]{64}$/);
  const token = first.message.token;
  const discovery = await request('/api/desktop/discover');
  assert.equal(discovery.status, 200);
  const info = JSON.parse(discovery.text);
  assert.equal(info.product, 'project-uai-desktop');
  assert.equal(info.protocol, 1); assert.equal(info.token, token); assert.ok(info.instance);
  assert.equal(discovery.headers['access-control-allow-origin'], undefined);
  assert.equal(discovery.headers['cache-control'], 'no-store');
  for (const headers of [
    { Origin: 'https://untrusted.invalid' }, { Origin: 'null' }, { Origin: '' },
    { Origin: 'http://127.0.0.1:' + PORT }, { 'Sec-Fetch-Mode': 'cors' },
    { 'Sec-Fetch-Site': 'same-origin' }, { Host: 'untrusted.invalid:' + PORT },
    { 'X-UAI-Discovery': 'wrong' }
  ]) assert.equal((await request('/api/desktop/discover', { headers })).status, 403);
  assert.equal((await request('/api/desktop/discover', { method: 'GET', body: undefined })).status, 405);
  assert.equal((await request('/api/desktop/discover', { method: 'OPTIONS' })).status, 405);
  assert.equal((await request('/api/desktop/discover', { headers: { 'Content-Type': 'text/plain' } })).status, 415);
  assert.equal((await request('/api/desktop/discover', { body: '[]' })).status, 400);
  assert.equal((await request('/api/desktop/discover', { body: '{"unexpected":1}' })).status, 400);
  assert.equal((await request('/api/hello', { method: 'GET' })).status, 401);
  const hello = await request('/api/hello', { method: 'GET', headers: { Authorization: 'Bearer ' + token } });
  assert.equal(hello.status, 200); assert.equal(JSON.parse(hello.text).connected, false);
  const page = await request('/', { method: 'GET' });
  assert.equal(page.status, 200); assert.ok(!page.text.includes(token));

  const duplicate = await desktop(t);
  assert.equal(duplicate.message.type, 'error'); assert.match(duplicate.message.message, /28791.*already in use/);
  await duplicate.exit;
  assert.equal((await request('/api/desktop/discover')).status, 200, 'original instance survives a port conflict');
  await first.stop();
  const second = await desktop(t);
  assert.equal(second.message.type, 'ready'); assert.notEqual(second.message.token, token);
  assert.equal((await request('/api/hello', { method: 'GET', headers: { Authorization: 'Bearer ' + token } })).status, 401);
  await second.stop(true);
  const third = await desktop(t);
  assert.equal(third.message.type, 'ready', 'parent EOF released the port');
  await third.stop();
});

test('terminal bridge does not expose desktop discovery', async t => {
  const bridge = await startBridge(t);
  const result = await fetch(bridge.base + '/api/desktop/discover', { method: 'POST',
    headers: { Authorization: 'Bearer ' + bridge.token, 'X-UAI-Discovery': '1' }, body: '{}' });
  assert.equal(result.status, 404);
});

test('desktop integration switches disable MCP admission and native model discovery', async t => {
  const app = await desktop(t, { UAI_MCP_DISABLED: '1' });
  assert.equal(app.message.type, 'ready');
  const headers = { Authorization: 'Bearer ' + app.message.token };
  const hello = JSON.parse((await request('/api/hello', { method: 'GET', headers })).text);
  assert.equal(hello.capabilities.opencode.enabled, false);
  assert.equal(hello.capabilities.opencode.state, 'disabled');
  assert.equal(hello.capabilities.mcp.enabled, false);
  assert.equal(hello.capabilities.mcp.available, false);
  for (const route of ['/mcp', '/api/mcp']) {
    const response = await request(route, { headers, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize',
      params: { protocolVersion: '2025-11-25', clientInfo: { name: 'disabled probe' }, capabilities: {} } }) });
    assert.equal(response.status, 503);
    assert.match(JSON.parse(response.text).error.message, /turned off/);
  }
  const config = JSON.parse((await request('/api/mcp/config', { method: 'GET', headers })).text);
  assert.equal(config.enabled, false); assert.deepEqual(config.sessions, []);
  await app.stop();
  const enabled = await desktop(t, { UAI_MCP_DISABLED: '0' });
  const active = JSON.parse((await request('/api/hello', { method: 'GET', headers: { Authorization: 'Bearer ' + enabled.message.token } })).text);
  assert.equal(active.capabilities.mcp.enabled, true);
  await enabled.stop();
});
