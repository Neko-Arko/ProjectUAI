'use strict';
// Optional interoperability check against the real, externally installed SDK.
// Production and the ordinary wire tests remain dependency-free.
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { startBridge, sleep, root } = require('./helpers/bridge');
const sdk = process.env.MCP_SDK_MODULE;

test('official MCP SDK validates Streamable HTTP and stdio discovery, calls and cancellation', { skip: !sdk }, async t => {
  const { Client } = require(path.join(sdk, 'dist/cjs/client/index.js'));
  const { StreamableHTTPClientTransport } = require(path.join(sdk, 'dist/cjs/client/streamableHttp.js'));
  const { StdioClientTransport } = require(path.join(sdk, 'dist/cjs/client/stdio.js'));
  const { ToolListChangedNotificationSchema } = require(path.join(sdk, 'dist/cjs/types.js'));
  const version = require(path.join(sdk, 'package.json')).version;
  const bridge = await startBridge(t), headers = { Authorization: 'Bearer ' + bridge.token, 'content-type': 'application/json' };
  const tool = { name: 'sdk_probe', description: 'Read a Roblox probe value', risk: 'read', available: true, enabled: true,
    parameters: { type: 'object', properties: { path: { type: 'string' } }, required: ['path'] } };
  const post = async (route, body) => {
    const response = await fetch(bridge.base + route, { method: 'POST', headers, body: JSON.stringify(body) });
    assert.ok(response.ok, route + ': ' + response.status);
  };
  const publish = tools => post('/api/agent/events', { state: { sessionId: 'native-chat', mcp: { schema: 1 }, tools } });
  const inbox = async () => (await (await fetch(bridge.base + '/api/agent/inbox', {
    headers: { ...headers, 'X-UAI-Client': 'sdk-game', 'X-UAI-Poll-Wait-Ms': '0' } })).json()).commands;
  async function nextCommand(type) {
    for (let i = 0; i < 100; i++) {
      const command = (await inbox()).find(item => item.type === type);
      if (command) return command;
      await sleep(25);
    }
    assert.fail('Expected game command ' + type);
  }
  await publish([tool]);
  const transports = [
    ['Streamable HTTP', new StreamableHTTPClientTransport(new URL(bridge.base + '/mcp'), {
      requestInit: { headers: { Authorization: 'Bearer ' + bridge.token } },
    })],
    ['stdio', new StdioClientTransport({ command: process.execPath,
      args: [path.join(root, 'bridge/server.js'), '--mcp-stdio', '--url', bridge.base],
      env: { UAI_BRIDGE_TOKEN: bridge.token }, stderr: 'pipe', cwd: root })],
  ];
  for (const [label, transport] of transports) {
    await t.test(label, async () => {
      await publish([tool]);
      const client = new Client({ name: 'Official SDK ' + label, version });
      let notices = 0, errors = '';
      transport.stderr?.on('data', chunk => { errors += chunk; });
      client.setNotificationHandler(ToolListChangedNotificationSchema, async () => { notices++; });
      t.after(() => client.close());
      await client.connect(transport);
      assert.equal(client.getServerVersion().name, 'Project UAI');
      assert.equal(client.getServerCapabilities().tools.listChanged, true);
      assert.equal((await client.listTools()).tools[0].name, 'sdk_probe');
      const pending = client.callTool({ name: tool.name, arguments: { path: 'Workspace' } }, undefined, { timeout: 7000 });
      const command = await nextCommand('mcp:call');
      await post('/api/agent/ack', { results: [{ id: command.commandId, ok: true, data: { ok: true,
        text: 'Actual receipt from ' + label, data: { path: 'Workspace', found: true } } }] });
      const result = await pending;
      assert.equal(result.content[0].text, 'Actual receipt from ' + label);
      assert.deepEqual(result.structuredContent, { path: 'Workspace', found: true });
      const abort = new AbortController();
      const cancelled = client.callTool({ name: tool.name, arguments: { path: 'Players' } }, undefined, { signal: abort.signal, timeout: 7000 });
      const rejection = assert.rejects(cancelled);
      const running = await nextCommand('mcp:call');
      await post('/api/agent/ack', { results: [{ id: running.commandId, pending: true }] });
      abort.abort(); await rejection;
      const cancellation = await nextCommand('mcp:cancel');
      assert.equal(cancellation.callId, running.callId);
      await post('/api/agent/ack', { results: [{ id: running.commandId, ok: false, error: 'cancelled' },
        { id: cancellation.commandId, ok: true }] });
      await publish([]);
      for (let i = 0; i < 35 && !notices; i++) await sleep(50);
      assert.ok(notices > 0, 'SDK received the catalogue notification');
      assert.deepEqual((await client.listTools()).tools, []);
      if (transport.terminateSession) await transport.terminateSession();
      await client.close(); assert.equal(errors, '');
      await publish([tool]);
      const cleanup = await inbox();
      if (cleanup.length) await post('/api/agent/ack', { results: cleanup.map(item => ({ id: item.commandId, ok: true })) });
    });
  }
});
