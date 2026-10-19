'use strict';
// Offline native-process fixture. It never contacts an upstream provider.
const fixtureOldBinary = process.env.UAI_OPENCODE_FIXTURE_OLD_BINARY === process.execPath;
if (process.argv.includes('--version')) { process.stdout.write((process.env.UAI_OPENCODE_FIXTURE_VERSION || (fixtureOldBinary ? '1.19.3' : 'opencode v2.0.32')) + '\n'); process.exit(0); }
const http = require('node:http');
const fs = require('node:fs');
const sessions = new Map(), servers = new Map();
let next = 0;
const args = process.argv.slice(2), port = Number(args[args.indexOf('--port') + 1]);
const password = process.env.OPENCODE_SERVER_PASSWORD;
const log = value => fs.appendFileSync(process.env.UAI_OPENCODE_FIXTURE_LOG, JSON.stringify(value) + '\n');
const reply = (res, value, status = 200) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(value === undefined ? undefined : JSON.stringify(value)); };
const server = http.createServer(async (req, res) => {
  if (req.headers.authorization !== 'Basic ' + Buffer.from('opencode:' + password).toString('base64')) { reply(res, {}, 401); return; }
  let raw = ''; for await (const chunk of req) raw += chunk;
  const body = raw ? JSON.parse(raw) : {}, url = new URL(req.url, 'http://localhost');
  const parts = url.pathname.split('/'), id = parts[3], session = sessions.get(id);
  if (url.pathname === '/openapi.json') return reply(res, { paths: Object.fromEntries((fixtureOldBinary || process.env.UAI_OPENCODE_FIXTURE_OLD_API === '1'
    ? ['/api/model', '/api/session/{sessionID}/prompt']
    : ['/api/model', '/api/session', '/api/session/{sessionID}', '/api/session/{sessionID}/prompt', '/api/session/{sessionID}/message',
      '/api/session/{sessionID}/interrupt', '/api/session/{sessionID}/permission', '/api/experimental/mcp/{server}']).map(route => [route, {}])) });
  if (url.pathname === '/api/model') return reply(res, { data: [
    { id: 'fixture-free', modelID: 'fixture-free', providerID: 'opencode', name: 'Fixture', limit: { context: 100000, output: 4096 }, cost: [{ input: 0, output: 0, cache: { read: 0, write: 0 } }] },
    { id: 'fixture-paid', providerID: 'opencode', cost: [{ input: 1, output: 0, cache: { read: 0, write: 0 } }] },
    { id: 'fixture-unknown-price', providerID: 'opencode' }
  ] });
  if (url.pathname.startsWith('/api/experimental/mcp/')) {
    const location = url.searchParams.get('location[directory]');
    if (req.method === 'PUT') {
      servers.set(location, body.config);
      const result = await fetch(body.config.url, { method: 'POST', headers: { ...body.config.headers, 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/list' }) });
      log({ type: 'tools', location, tools: (await result.json()).result.tools });
    } else servers.delete(location);
    return reply(res, undefined, 204);
  }
  if (url.pathname === '/api/session' && req.method === 'POST') {
    const id = 'ses_fixture' + (++next); sessions.set(id, { ...body, id }); log({ type: 'session', id, permissions: body.permissions });
    return reply(res, { data: { id } });
  }
  if (session && parts[4] === 'prompt') {
    session.prompt = body.text; log({ type: 'prompt', id });
    if (body.text.includes('BROKEN_TOOL')) {
      session.message = { type: 'assistant', content: [{ type: 'tool', name: 'uai_lookup', state: { status: 'error' } }], time: { streamed: Date.now() } };
    } else if (body.text.includes('USE_TOOL')) {
      const config = servers.get(session.location.directory);
      const count = body.text.includes('PARALLEL') ? 2 : 1;
      session.message = { type: 'assistant', content: [{ type: 'text', text: 'Checking Roblox.' },
        ...Array.from({ length: count }, () => ({ type: 'tool', name: 'uai_lookup', state: { status: 'running', input: { value: 'fixture' } } }))], time: { streamed: Date.now() } };
      for (let index = 0; index < count; index++) setTimeout(() => {
        fetch(config.url, { method: 'POST', headers: { ...config.headers, 'content-type': 'application/json' },
          body: JSON.stringify({ jsonrpc: '2.0', id: 2 + index, method: 'tools/call', params: { name: 'lookup',
            arguments: { value: body.text.includes('OVERSIZED') ? 'v'.repeat(256001) : 'fixture' } } }) }).catch(() => {});
      }, index * 50);
    } else if (!body.text.includes('WAIT_FOREVER') && !body.text.includes('HOST_ACTION')) session.message = { type: 'assistant', content: [{ type: 'reasoning', text: 'Checked.' }, { type: 'text', text: 'PONG' }], time: { completed: Date.now() }, finish: 'stop' };
    return reply(res, { data: { id: 'inbox_fixture' } });
  }
  if (session && parts[4] === 'message') return reply(res, { data: session.message ? [session.message] : [] });
  if (session && parts[4] === 'permission') return reply(res, { data: session.prompt?.includes('HOST_ACTION') ? [{ action: 'bash' }] : [] });
  if (session && parts[4] === 'interrupt') { log({ type: 'interrupt', id }); return reply(res, { interrupted: true }); }
  if (session && req.method === 'DELETE') { sessions.delete(id); log({ type: 'delete', id }); return reply(res, {}); }
  reply(res, {}, 404);
});
server.listen(port, '127.0.0.1', () => log({ type: 'ready', pid: process.pid, legacy: fixtureOldBinary, port, directory: process.cwd(), passwordLength: password.length,
  isolated: ['XDG_DATA_HOME', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'XDG_STATE_HOME'].every(key => process.env[key].startsWith(process.cwd())) }));
