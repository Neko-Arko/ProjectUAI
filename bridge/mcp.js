'use strict';

// Public MCP server. Inference is deliberately absent: the connected game owns
// tool schemas, permission decisions, execution and the final command receipt.
const crypto = require('node:crypto');
const PROTOCOLS = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'];
const MAX_SESSIONS = 32, MAX_CALLS = 64, MAX_SESSION_CALLS = 8;
const MAX_HISTORY = 512, MAX_RESULT_BYTES = 4 * 1024 * 1024, MAX_CACHE_BYTES = 16 * 1024 * 1024;
const IDLE_MS = 30 * 60 * 1000;
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const validId = id => typeof id === 'string' && id.length <= 200 || typeof id === 'number' && Number.isSafeInteger(id);
const rpcError = (id, code, message) => ({ jsonrpc: '2.0', id: id ?? null, error: { code, message } });
const rpcResult = (id, result) => ({ jsonrpc: '2.0', id, result });
const toolError = text => ({ content: [{ type: 'text', text }], isError: true });

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (!object(value)) return value;
  const result = Object.create(null);
  for (const key of Object.keys(value).sort()) result[key] = canonical(value[key]);
  return result;
}

function createMcp({ version, getState, connected, enqueue, receipt, cancelCommand, readBody, headers = {} }) {
  const sessions = new Map(), cached = [];
  let closed = false, activeCalls = 0, cacheBytes = 0, catalogAt = 0;

  function ready() { return connected() && getState()?.mcp?.schema === 1; }
  function catalog() {
    if (!ready()) return [];
    const names = new Set();
    return (Array.isArray(getState()?.tools) ? getState().tools : []).filter(tool => {
      if (!object(tool) || typeof tool.name !== 'string' || !/^[A-Za-z0-9_.-]{1,128}$/.test(tool.name) || names.has(tool.name) ||
          tool.available === false || tool.enabled === false || tool.rule === 'deny' || tool.effectiveRule === 'deny') return false;
      names.add(tool.name); return true;
    }).map(tool => ({
      name: tool.name,
      description: String(tool.description || ''),
      inputSchema: object(tool.parameters) ? { ...tool.parameters, type: 'object',
        properties: object(tool.parameters.properties) ? tool.parameters.properties : {} } : { type: 'object', properties: {} },
      annotations: { readOnlyHint: tool.risk === 'read', destructiveHint: tool.risk !== 'read', openWorldHint: true },
    }));
  }
  function capability() {
    return { schema: 1, endpoint: '/mcp', transports: ['streamable-http', 'stdio'],
      available: ready(), connected: connected(), tools: catalog().length, sessions: sessions.size };
  }
  function catalogFingerprint(tools) {
    return crypto.createHash('sha256').update(JSON.stringify(tools)).digest('hex');
  }
  function connections() {
    return [...sessions.values()].map(session => ({ id: session.id, clientName: session.clientName,
      connectedAt: session.createdAt, activeCalls: session.pending.size }));
  }
  function json(res, status, value, extra = {}) {
    if (res.destroyed || res.writableEnded) return;
    const body = value === undefined ? '' : JSON.stringify(value);
    res.writeHead(status, { ...headers, 'cache-control': 'no-store',
      ...(body ? { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) } : {}), ...extra });
    res.end(body);
  }
  function frame(res, message) {
    if (res.destroyed || res.writableEnded) return;
    // Never retain an unbounded write queue for a stalled harness.
    if (res.writableLength > 1024 * 1024) { res.destroy(); return; }
    res.write('event: message\ndata: ' + JSON.stringify(message) + '\n\n');
  }
  function notification(session, method, params) {
    for (const res of session.streams) frame(res, { jsonrpc: '2.0', method, ...(params ? { params } : {}) });
  }
  function remember(record, result) {
    record.response = result;
    record.bytes = Buffer.byteLength(JSON.stringify(result));
    cached.push(record); cacheBytes += record.bytes;
    while (cacheBytes > MAX_CACHE_BYTES && cached.length) {
      const old = cached.shift(); cacheBytes -= old.bytes;
      old.bytes = 0;
      old.response = rpcError(old.id, -32001, 'The retained result expired. Check Roblox before repeating this action.');
    }
  }
  function settle(session, record, result) {
    if (record.done) return;
    record.done = true;
    session.pending.delete(record.key); activeCalls--;
    if (Buffer.byteLength(JSON.stringify(result)) > MAX_RESULT_BYTES) {
      result = rpcResult(record.id, toolError('The tool finished but its result exceeds the MCP response limit. Inspect Roblox before repeating this action.'));
    }
    remember(record, result);
    for (const observer of record.listeners) {
      clearInterval(observer.heartbeat);
      if (observer.stream) { frame(observer.res, result); observer.res.end(); }
      else json(observer.res, 200, result);
    }
    record.listeners.clear();
    session.touchedAt = Date.now();
  }
  function cancel(session, record, reason) {
    if (record.done) return;
    cancelCommand(record.commandId, { type: 'mcp:cancel', mcpSessionId: session.id, callId: record.callId });
    settle(session, record, rpcError(record.id, -32800, reason || 'Tool request cancelled. Applied effects are not undone.'));
  }
  function closeSession(session, reason) {
    if (!sessions.delete(session.id)) return;
    for (const record of [...session.pending.values()]) cancel(session, record, reason);
    for (const res of session.streams) res.end();
    session.streams.clear();
    // Sessions are game-owned; close only this external session, never the
    // currently selected Roblox conversation or another harness's work.
    if (session.used) {
      try { enqueue({ type: 'mcp:close', mcpSessionId: session.id }); } catch { /* bridge is already at capacity */ }
    }
    for (const record of session.calls.values()) {
      cacheBytes -= record.bytes || 0; record.bytes = 0; record.response = null;
    }
    for (let at = cached.length - 1; at >= 0; at--) if (!cached[at].bytes) cached.splice(at, 1);
  }
  function tick() {
    const now = Date.now();
    if (now - catalogAt >= 1000) {
      catalogAt = now;
      const nextKey = catalogFingerprint(catalog());
      for (const session of sessions.values()) {
        // Compare with what this harness last observed. A tool can appear and
        // disappear between timer samples while a client lists it in between.
        if (session.initialized && session.streams.size && session.catalogKey !== nextKey) {
          session.catalogKey = nextKey;
          notification(session, 'notifications/tools/list_changed');
        }
      }
    }
    for (const session of sessions.values()) {
      for (const record of [...session.pending.values()]) {
        const result = receipt(record.commandId);
        if (result?.result && ['completed', 'failed'].includes(result.state)) {
          const data = result.result.data;
          const failure = result.result.ok === false || data?.ok === false;
          const text = typeof data?.full === 'string' ? data.full : typeof data?.text === 'string' ? data.text :
            failure ? String(data?.error || result.result.error || 'Tool execution failed') : JSON.stringify(data ?? { ok: true });
          settle(session, record, rpcResult(record.id, { content: [{ type: 'text', text }],
            ...(failure ? { isError: true } : {}),
            ...(object(data?.data) && !failure ? { structuredContent: data.data } : {}) }));
        } else if (!connected()) {
          cancelCommand(record.commandId, { type: 'mcp:cancel', mcpSessionId: session.id, callId: record.callId });
          settle(session, record, rpcResult(record.id, toolError('Roblox disconnected before the tool receipt arrived; the outcome may be uncertain. Check Roblox before repeating the action.')));
        } else if (now - record.lastProgress > 15000) {
          record.lastProgress = now;
          record.progress++;
          const message = { jsonrpc: '2.0', method: 'notifications/progress', params: {
            progressToken: record.progressToken, progress: record.progress,
            message: 'Waiting for Roblox. Review any permission prompt in Project UAI.' } };
          if (record.progressToken !== undefined) for (const observer of record.listeners) if (observer.stream) frame(observer.res, message);
        }
      }
      if (!session.pending.size && !session.streams.size && now - session.touchedAt > IDLE_MS) closeSession(session, 'MCP session expired');
    }
    // Cached records whose sessions closed no longer need a place in the FIFO.
    while (cached.length && !cached[0].bytes) cached.shift();
  }
  const timer = setInterval(tick, 100).unref();

  function call(session, input, res, wantsStream) {
    const params = input.params;
    if (!object(params) || typeof params.name !== 'string' || (params.arguments !== undefined && !object(params.arguments)) ||
        (params._meta !== undefined && !object(params._meta)) || (params._meta?.progressToken !== undefined && !validId(params._meta.progressToken))) {
      return json(res, 200, rpcError(input.id, -32602, 'Expected a tool name and an arguments object'));
    }
    const key = typeof input.id + ':' + input.id;
    const fingerprint = crypto.createHash('sha256').update(JSON.stringify(canonical(params))).digest('hex');
    let record = session.calls.get(key);
    if (record && record.fingerprint !== fingerprint) return json(res, 200, rpcError(input.id, -32600, 'Request ID already belongs to another tool call'));
    if (record?.done) return json(res, 200, record.response);
    if (!record) {
      if (!ready()) return json(res, 200, rpcResult(input.id, toolError(connected()
        ? 'Reload the updated Project UAI client to enable MCP tools.' : 'Connect Roblox with Project UAI before calling a tool.')));
      if (!catalog().some(tool => tool.name === params.name)) return json(res, 200, rpcError(input.id, -32602, 'Unknown, disabled or unavailable tool'));
      if (session.pending.size >= MAX_SESSION_CALLS || activeCalls >= MAX_CALLS || session.calls.size >= MAX_HISTORY) {
        return json(res, 200, rpcError(input.id, -32000, 'MCP call capacity reached. Finish pending calls or reconnect this MCP session.'));
      }
      const callId = crypto.randomUUID();
      let command;
      try {
        command = enqueue({ type: 'mcp:call', mcpSessionId: session.id, callId,
          clientName: session.clientName, name: params.name, arguments: params.arguments || {} });
      } catch (error) { return json(res, 200, rpcError(input.id, -32000, error.message)); }
      record = { id: input.id, key, fingerprint, callId, commandId: command.id, done: false,
        lastProgress: Date.now(), progress: 0, progressToken: params._meta?.progressToken, listeners: new Set() };
      session.calls.set(key, record); session.pending.set(key, record); activeCalls++; session.used = true;
    }
    if (record.listeners.size >= 4) return json(res, 429, rpcError(input.id, -32000, 'Too many observers for this request'));
    const observer = { res, stream: wantsStream };
    record.listeners.add(observer);
    res.once('close', () => { clearInterval(observer.heartbeat); record.listeners.delete(observer); });
    if (wantsStream) {
      res.writeHead(200, { ...headers, 'content-type': 'text/event-stream', 'cache-control': 'no-store', connection: 'keep-alive' });
      res.flushHeaders();
      observer.heartbeat = setInterval(() => {
        if (res.writableLength > 1024 * 1024) res.destroy(); else if (!res.destroyed) res.write(': waiting\n\n');
      }, 15000);
    }
  }

  async function handle(req, res) {
    if (closed) return json(res, 503, rpcError(null, -32000, 'MCP bridge stopped'));
    const versionHeader = req.headers['mcp-protocol-version'];
    if (versionHeader && !PROTOCOLS.includes(versionHeader)) return json(res, 400, rpcError(null, -32600, 'Unsupported MCP protocol version'));
    const sessionId = req.headers['mcp-session-id'];
    let session = sessionId && sessions.get(sessionId);
    if (sessionId && !session) return json(res, 404, rpcError(null, -32000, 'MCP session expired; initialize a new session'));
    if (session) session.touchedAt = Date.now();
    if (req.method === 'DELETE') {
      if (!session) return json(res, 400, rpcError(null, -32600, 'Mcp-Session-Id is required'));
      closeSession(session, 'MCP session closed'); return json(res, 200, {});
    }
    if (req.method === 'GET') {
      if (!session) return json(res, 400, rpcError(null, -32600, 'Mcp-Session-Id is required'));
      if (!String(req.headers.accept || '').includes('text/event-stream')) return json(res, 406, rpcError(null, -32600, 'Accept text/event-stream is required'));
      if (session.streams.size >= 2) return json(res, 429, rpcError(null, -32000, 'Too many MCP notification streams'));
      res.writeHead(200, { ...headers, 'content-type': 'text/event-stream', 'cache-control': 'no-store', connection: 'keep-alive' });
      res.write(': Project UAI MCP\n\n'); session.streams.add(res);
      const beat = setInterval(() => { if (res.writableLength > 1024 * 1024) res.destroy(); else res.write(': ping\n\n'); }, 15000);
      res.once('close', () => { clearInterval(beat); session.streams.delete(res); });
      return;
    }
    if (req.method !== 'POST') return json(res, 405, rpcError(null, -32600, 'Method not allowed'), { allow: 'GET, POST, DELETE' });
    if (!/^application\/json(?:\s*;|$)/i.test(req.headers['content-type'] || '')) return json(res, 415, rpcError(null, -32600, 'Content-Type application/json is required'));
    const accept = String(req.headers.accept || '');
    if (!accept.includes('application/json') && !accept.includes('*/*')) return json(res, 406, rpcError(null, -32600, 'Accept application/json is required'));
    let input;
    try { input = JSON.parse(await readBody(req, 1024 * 1024)); }
    catch (error) { return json(res, error.status || 400, rpcError(null, -32700, 'Invalid JSON request'), error.status === 413 ? { connection: 'close' } : {}); }
    if (!object(input) || input.jsonrpc !== '2.0' || typeof input.method !== 'string' ||
        (input.id !== undefined && !validId(input.id)) || (input.params !== undefined && !object(input.params))) {
      return json(res, 400, rpcError(validId(input?.id) ? input.id : null, -32600, 'Invalid JSON-RPC request'));
    }
    if (input.method === 'initialize') {
      if (session || input.id === undefined || typeof input.params?.protocolVersion !== 'string' ||
          !object(input.params?.clientInfo) || typeof input.params.clientInfo.name !== 'string' || !object(input.params?.capabilities)) {
        return json(res, 400, rpcError(input.id, -32602, 'Invalid initialization or session is already initialized'));
      }
      if (sessions.size >= MAX_SESSIONS) return json(res, 503, rpcError(input.id, -32000, 'MCP session capacity reached'));
      session = { id: crypto.randomUUID(), clientName: input.params.clientInfo.name.slice(0, 160),
        protocol: PROTOCOLS.includes(input.params.protocolVersion) ? input.params.protocolVersion : PROTOCOLS[0],
        createdAt: Date.now(), touchedAt: Date.now(), initialized: false, calls: new Map(), pending: new Map(), streams: new Set(),
        catalogKey: catalogFingerprint(catalog()) };
      sessions.set(session.id, session);
      return json(res, 200, rpcResult(input.id, { protocolVersion: session.protocol, capabilities: { tools: { listChanged: true } },
        serverInfo: { name: 'Project UAI', version },
        instructions: 'Tools execute in the connected Roblox client. Approve permission prompts in Project UAI. Each MCP connection has its own conversation; no model inference runs in this bridge. After an uncertain result, inspect Roblox before repeating an action.' }),
      { 'Mcp-Session-Id': session.id });
    }
    if (!session) return json(res, 400, rpcError(input.id, -32600, 'Initialize first and include Mcp-Session-Id'));
    if (input.id === undefined) {
      if (input.method === 'notifications/initialized') session.initialized = true;
      else if (input.method === 'notifications/cancelled' && validId(input.params?.requestId)) {
        const record = session.pending.get(typeof input.params.requestId + ':' + input.params.requestId);
        if (record) cancel(session, record, 'Tool request cancelled by the harness. Applied effects are not undone.');
      }
      return json(res, 202);
    }
    if (input.method === 'ping') return json(res, 200, rpcResult(input.id, {}));
    if (!session.initialized) return json(res, 200, rpcError(input.id, -32000, 'Send notifications/initialized before using tools'));
    if (input.method === 'tools/list') {
      if (input.params?.cursor !== undefined) return json(res, 200, rpcError(input.id, -32602, 'This tool list is not paginated; omit cursor'));
      const tools = catalog(); session.catalogKey = catalogFingerprint(tools);
      return json(res, 200, rpcResult(input.id, { tools }));
    }
    if (input.method === 'tools/call') return call(session, input, res, accept.includes('text/event-stream'));
    return json(res, 200, rpcError(input.id, -32601, 'Method not found'));
  }
  function close() {
    if (closed) return; closed = true; clearInterval(timer);
    for (const session of [...sessions.values()]) closeSession(session, 'MCP bridge stopped');
  }
  return { handle, capability, connections, close, pending: () => activeCalls, protocols: PROTOCOLS };
}

module.exports = { createMcp, PROTOCOLS };
