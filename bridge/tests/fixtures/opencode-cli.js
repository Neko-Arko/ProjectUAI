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
    const id = 'ses_fixture' + (++next); sessions.set(id, { ...body, id, permissions: [] }); log({ type: 'session', id, permissions: body.permissions });
    return reply(res, { data: { id } });
  }
  if (session && parts[4] === 'prompt') {
    session.prompt = body.text; log({ type: 'prompt', id });
    const marker = '\n\nConversation:\n', source = JSON.parse(body.text.slice(body.text.indexOf(marker) + marker.length));
    const userContent = typeof source === 'string' ? source : source.filter(message => message.role === 'user').at(-1)?.content || '';
    const requested = typeof userContent === 'string' ? userContent : JSON.stringify(userContent);
    session.requested = requested;
    const messageID = 'msg_' + id;
    const tool = (name, index, input, status = 'running') => ({ type: 'tool', id: 'tool_' + id + '_' + index, name,
      state: { status, input, metadata: {} }, time: { created: Date.now() } });
    const block = part => ({ id: 'per_' + part.id, sessionID: id, action: part.name, resources: ['*'],
      source: { type: 'tool', messageID, id: part.id } });
    const sendTools = (values, reverse = false) => {
      const config = servers.get(session.location.directory);
      values.forEach((value, index) => setTimeout(() => {
        if (session.interrupted || !sessions.has(id)) return;
        const args = typeof value === 'string' ? { value } : value;
        log({ type: 'mcp-call', id, value: typeof args.value === 'string' && args.value.length < 100 ? args.value : 'oversized' });
        fetch(config.url, { method: 'POST', headers: { ...config.headers, 'content-type': 'application/json' },
          body: JSON.stringify({ jsonrpc: '2.0', id: 2 + index, method: 'tools/call', params: { name: 'lookup', arguments: args } }) })
          .then(result => { if (result.ok) log({ type: 'mcp-result', id }); }).catch(() => {});
      }, (reverse ? values.length - index - 1 : index) * 60));
    };
    if (requested.includes('BROKEN_TOOL')) {
      session.message = { type: 'assistant', id: messageID, content: [tool('uai_lookup', 0, {}, 'error')], time: { streamed: Date.now() } };
    } else if (requested.includes('MIXED_HOST_TOOL')) {
      const content = [tool('uai_lookup', 0, { value: 'first', nested: { a: 1, b: 2 } }), tool('bash', 1, { command: 'never execute this host command' }),
        tool('uai_lookup', 2, { value: 'last' }), tool('read', 3, { path: 'private-host-file' })];
      session.message = { type: 'assistant', id: messageID, content, time: { streamed: Date.now() } };
      session.permissions = [block(content[1]), block(content[3])];
      sendTools([{ nested: { b: 2, a: 1 }, value: 'first' }, 'last'], true);
    } else if (requested.includes('HOST_ACTION') || requested.includes('UNKNOWN_UAI_TOOL') || requested.includes('HOST_STREAMING') || requested.includes('HOST_PENDING')) {
      const streaming = requested.includes('HOST_STREAMING'), pending = requested.includes('HOST_PENDING');
      const part = tool(requested.includes('UNKNOWN_UAI_TOOL') ? 'uai_not_declared' : 'bash', 0,
        streaming ? '{"command":"unfinished' : { command: 'never execute this host command' }, streaming ? 'streaming' : 'running');
      if (requested.includes('HOST_COMPLETED')) { part.state.status = 'completed'; part.executed = true; }
      if (requested.includes('HOST_ERROR')) part.state.status = 'error';
      session.message = { type: 'assistant', id: messageID, content: [part], time: streaming || pending ? {} : { streamed: Date.now() } };
      session.permissions = streaming || part.state.status !== 'running' ? [] : [block(part)];
      if (requested.includes('WRONG_PERMISSION')) session.permissions[0].source.id = 'tool_unrelated';
      if (requested.includes('WRONG_MESSAGE')) session.permissions[0].source.messageID = 'msg_unrelated';
      if (requested.includes('WRONG_SESSION')) session.permissions[0].sessionID = 'ses_unrelated';
      if (requested.includes('WRONG_SOURCE')) session.permissions[0].source.type = 'unknown';
      if (requested.includes('NO_PERMISSION')) session.permissions = [];
    } else if (requested.includes('USE_TOOL') || requested.includes('HOST_THEN_TOOL')) {
      const count = requested.includes('PARALLEL') ? 2 : 1;
      const value = requested.includes('OVERSIZED') ? 'v'.repeat(256001) : 'fixture';
      session.message = { type: 'assistant', id: messageID, content: [{ type: 'text', text: 'Checking Roblox.' },
        ...Array.from({ length: count }, (_, index) => tool('uai_lookup', index, { value }))], time: { streamed: Date.now() } };
      sendTools(Array.from({ length: count }, () => requested.includes('MALFORMED') ? [] : requested.includes('MISMATCHED') ? 'unmatched' : value));
    } else if (!requested.includes('WAIT_FOREVER')) session.message = { type: 'assistant', id: messageID,
      content: [{ type: 'reasoning', text: 'Checked.' }, { type: 'text', text: 'PONG' }], time: { completed: Date.now() }, finish: 'stop' };
    return reply(res, { data: { id: 'inbox_fixture' } });
  }
  if (session && parts[4] === 'message') return reply(res, { data: session.message ? [session.message] : [] });
  if (session && parts[4] === 'permission') {
    if (req.method === 'POST') { log({ type: 'permission-reply', id, decision: body.decision }); return reply(res, undefined, 204); }
    log({ type: 'permission-read', id }); return reply(res, { data: session.permissions || [] });
  }
  if (session && parts[4] === 'interrupt') {
    log({ type: 'interrupt', id });
    if (session.requested?.includes('INTERRUPT_FAIL')) return reply(res, {}, 500);
    if (session.requested?.includes('FALSE_INTERRUPT')) return reply(res, { interrupted: false });
    session.interrupted = true; session.permissions = []; return reply(res, { interrupted: true });
  }
  if (session && req.method === 'DELETE') { sessions.delete(id); log({ type: 'delete', id }); return reply(res, {}); }
  reply(res, {}, 404);
});
server.listen(port, '127.0.0.1', () => log({ type: 'ready', pid: process.pid, legacy: fixtureOldBinary, port, directory: process.cwd(), passwordLength: password.length,
  isolated: ['XDG_DATA_HOME', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'XDG_STATE_HOME'].every(key => process.env[key].startsWith(process.cwd())) }));
