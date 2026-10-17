'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const { startBridge, root, sleep } = require('./helpers/bridge');

test('standalone desktop executable carries an MCP stdio adapter with no neighboring files',
  { skip: !process.env.UAI_MCP_DESKTOP_EXE, timeout: 45000 }, async t => {
    const original = path.resolve(process.env.UAI_MCP_DESKTOP_EXE);
    const folder = path.join(root, 'desktop', '.build', 'mcp-standalone-' + crypto.randomUUID());
    fs.mkdirSync(folder, { recursive: true });
    const executable = path.join(folder, 'Cowork.exe');
    fs.copyFileSync(original, executable);
    const bridge = await startBridge(t);
    const auth = { Authorization: 'Bearer ' + bridge.token, 'content-type': 'application/json' };
    async function game(route, body) {
      const response = await fetch(bridge.base + route, { method: 'POST', headers: auth, body: JSON.stringify(body) });
      assert.ok(response.ok, route + ': ' + response.status);
    }
    await game('/api/agent/events', { state: { mcp: { schema: 1 }, tools: [{ name: 'desktop_fixture', risk: 'read',
      available: true, enabled: true, parameters: { type: 'object', properties: {} } }] } });
    const child = spawn(executable, ['--mcp-stdio', '--url', bridge.base], { cwd: folder, windowsHide: true,
      env: { ...process.env, UAI_BRIDGE_TOKEN: bridge.token }, stdio: ['pipe', 'pipe', 'pipe'] });
    t.after(async () => {
      if (child.exitCode === null && child.signalCode === null) { const done = once(child, 'exit'); child.kill(); await done; }
    });
    let buffer = '', errors = ''; const messages = [];
    child.stdout.on('data', chunk => {
      buffer += chunk;
      let at;
      while ((at = buffer.indexOf('\n')) >= 0) {
        messages.push(JSON.parse(buffer.slice(0, at))); buffer = buffer.slice(at + 1);
      }
    });
    child.stderr.on('data', chunk => { errors += chunk; });
    const send = message => child.stdin.write(JSON.stringify({ jsonrpc: '2.0', ...message }) + '\n');
    async function reply(id) {
      for (let i = 0; i < 600; i++) {
        const message = messages.find(item => item.id === id);
        if (message) return message;
        if (child.exitCode !== null) break;
        await sleep(30);
      }
      assert.fail('Missing desktop MCP response ' + id + ': ' + errors);
    }
    send({ id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18', capabilities: {},
      clientInfo: { name: 'Desktop packaging test', version: '1' } } });
    assert.equal((await reply(1)).result.serverInfo.name, 'Project UAI');
    send({ method: 'notifications/initialized' });
    send({ id: 2, method: 'tools/list' });
    assert.equal((await reply(2)).result.tools[0].name, 'desktop_fixture');
    send({ id: 3, method: 'tools/call', params: { name: 'desktop_fixture', arguments: {} } });
    let command;
    for (let i = 0; i < 100 && !command; i++) {
      const response = await fetch(bridge.base + '/api/agent/inbox', { headers: { ...auth, 'X-UAI-Poll-Wait-Ms': '0' } });
      command = (await response.json()).commands.find(item => item.type === 'mcp:call');
      if (!command) await sleep(30);
    }
    assert.ok(command, 'packaged adapter delivered a tool call');
    await game('/api/agent/ack', { results: [{ id: command.commandId, ok: true,
      data: { ok: true, text: 'Packaged MCP received the actual tool receipt' } }] });
    assert.match((await reply(3)).result.content[0].text, /actual tool receipt/);
    const exited = once(child, 'exit'); child.stdin.end(); await exited;
    assert.equal(child.exitCode, 0); assert.equal(errors, '');
    assert.deepEqual(fs.readdirSync(folder), ['Cowork.exe']);
    assert.ok(!JSON.stringify(messages).includes(bridge.token));
    const config = await (await fetch(bridge.base + '/api/mcp/config', { headers: auth })).json();
    assert.equal(config.sessions.length, 0, 'parent EOF cleaned up the packaged adapter session');
  });
