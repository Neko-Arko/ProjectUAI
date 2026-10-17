#!/usr/bin/env node
'use strict';

// Newline-delimited MCP for harnesses that launch a local command. This process
// only adapts transport; tools still execute in the desktop's connected game.
const http = require('node:http');
const MAX_LINE = 1024 * 1024, MAX_RESPONSE = 5 * 1024 * 1024;

function options(args, env) {
  const at = args.indexOf('--url');
  if (at >= 0 && !args[at + 1]) throw Error('--url requires the local bridge address');
  const url = new URL(at >= 0 ? args[at + 1] : env.UAI_BRIDGE_URL || 'http://127.0.0.1:28791');
  if (url.protocol !== 'http:' || !['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname) ||
      url.username || url.password || url.search || url.hash || !['/', '/mcp', '/api/mcp'].includes(url.pathname)) {
    throw Error('MCP requires a loopback HTTP bridge URL without credentials or a query');
  }
  // Desktop discovery enforces the canonical loopback host.
  if (url.hostname === 'localhost') url.hostname = '127.0.0.1';
  const token = env.UAI_BRIDGE_TOKEN;
  if (token && !/^[a-f0-9]{64}$/.test(token)) throw Error('UAI_BRIDGE_TOKEN must contain the bridge pairing token');
  return { origin: url.origin, endpoint: url.origin + (url.pathname === '/api/mcp' ? '/api/mcp' : '/mcp'), token };
}

function discoverDesktop(origin) {
  // Node fetch adds Sec-Fetch-Mode, which native desktop discovery correctly
  // refuses. Use HTTP directly so no browser headers or redirects are involved.
  return new Promise((resolve, reject) => {
    const request = http.request(origin + '/api/desktop/discover', { method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': '2', 'X-UAI-Discovery': '1' },
      signal: AbortSignal.timeout(4000) }, response => {
      let size = 0; const chunks = [];
      response.on('error', reject);
      response.on('data', chunk => {
        size += chunk.length;
        if (size > 4096) { response.destroy(Error('Invalid desktop discovery')); return; }
        chunks.push(chunk);
      });
      response.on('end', () => {
        try {
          const value = JSON.parse(Buffer.concat(chunks).toString('utf8'));
          const port = Number(new URL(origin).port || 80);
          if (response.statusCode !== 200 || value?.product !== 'project-uai-desktop' || value.protocol !== 1 || value.port !== port ||
              typeof value.instance !== 'string' || !value.instance.length || value.instance.length > 160 ||
              !/^[a-f0-9]{64}$/.test(value.token)) throw Error('Invalid desktop discovery');
          resolve(value.token);
        } catch { reject(Error('Desktop discovery unavailable; start the desktop bridge or set UAI_BRIDGE_TOKEN for a terminal bridge')); }
      });
    });
    request.on('error', reject); request.end('{}');
  });
}

async function consume(response, callback, signal) {
  let buffer = '', total = 0;
  const decoder = new TextDecoder();
  const sse = /^text\/event-stream/i.test(response.headers.get('content-type') || '');
  for await (const chunk of response.body || []) {
    if (signal?.aborted) return;
    total += chunk.length;
    buffer += decoder.decode(chunk, { stream: true }).replace(/\r\n/g, '\n');
    if (buffer.length > MAX_RESPONSE || !sse && total > MAX_RESPONSE) throw Error('MCP response is too large');
    if (sse) {
      let at;
      while ((at = buffer.indexOf('\n\n')) >= 0) {
        const block = buffer.slice(0, at); buffer = buffer.slice(at + 2);
        const data = block.split('\n').filter(line => line.startsWith('data:')).map(line => line.slice(5).trimStart()).join('\n');
        if (data) callback(JSON.parse(data));
      }
    }
  }
  if (!sse && buffer) callback(JSON.parse(buffer));
  if (sse && buffer.trim() && !buffer.trim().startsWith(':')) throw Error('MCP response ended before its final frame');
}

async function run({ args = process.argv.slice(2), env = process.env, input = process.stdin,
  output = process.stdout, errors = process.stderr } = {}) {
  let config;
  try { config = options(args, env); }
  catch (error) { errors.write(error.message + '\n'); process.exitCode = 1; return; }
  let token = config.token, sessionId, protocol, initializing, stopping = false, stale = false;
  let notificationController, notificationTimer, notificationDelay = 500, buffer = '', pending = 0;
  const controllers = new Set();
  const emit = message => {
    if (stopping || output.destroyed) return;
    if (output.writableLength > 8 * 1024 * 1024) { stop(); return; }
    output.write(JSON.stringify(message) + '\n');
  };
  const fail = (message, code = -32000, reason = 'The MCP bridge request failed. Keep the desktop bridge and Roblox connected. The action was not repeated.') => {
    if (message?.id !== undefined) emit({ jsonrpc: '2.0', id: message.id, error: { code, message: reason } });
  };
  async function discover() {
    if (token) return;
    token = await discoverDesktop(config.origin);
  }
  function auth() {
    return { Authorization: 'Bearer ' + token, 'content-type': 'application/json',
      Accept: 'application/json, text/event-stream', ...(sessionId ? { 'Mcp-Session-Id': sessionId } : {}),
      ...(protocol ? { 'MCP-Protocol-Version': protocol } : {}) };
  }
  async function notifications() {
    if (notificationController || stopping || stale || !sessionId) return;
    clearTimeout(notificationTimer); notificationTimer = null;
    const owner = sessionId;
    const controller = new AbortController(); notificationController = controller;
    try {
      const response = await fetch(config.endpoint, { headers: auth(), signal: controller.signal, redirect: 'error' });
      if (sessionId === owner && notificationController === controller && (response.status === 401 || response.status === 404)) {
        stale = true;
        if (!config.token && response.status === 401) token = null;
      }
      if (response.ok) await consume(response, message => {
        if (sessionId === owner && notificationController === controller) { notificationDelay = 500; emit(message); }
      }, controller.signal);
      else await response.body?.cancel();
    } catch { /* Tool requests retain independent receipts when notifications disconnect. */ }
    finally {
      if (notificationController === controller) notificationController = null;
      // Only reopen the read-only stream. Requests with possible tool effects
      // are never repeated when this connection ends.
      if (!stopping && !stale && sessionId === owner) {
        notificationTimer = setTimeout(notifications, notificationDelay);
        notificationDelay = Math.min(notificationDelay * 2, 10000);
      }
    }
  }
  async function forward(message) {
    if (initializing && message.method !== 'initialize') await initializing;
    if (stopping) return;
    if (stale && message.method !== 'initialize') return fail(message, -32000, 'The MCP session ended. Reconnect this MCP server in your harness; no action was repeated.');
    const controller = new AbortController(); controllers.add(controller);
    try {
      await discover();
      if (message.method === 'initialize' && stale) { sessionId = null; protocol = null; stale = false; }
      const response = await fetch(config.endpoint, { method: 'POST', headers: auth(), body: JSON.stringify(message), signal: controller.signal, redirect: 'error' });
      if (response.status === 404 || response.status === 401) {
        stale = true; notificationController?.abort(); notificationController = null;
        clearTimeout(notificationTimer); notificationTimer = null;
        if (!config.token && response.status === 401) token = null;
      }
      const id = response.headers.get('mcp-session-id');
      if (message.method === 'initialize' && response.ok && id) sessionId = id;
      let received = false;
      await consume(response, result => {
        if (!result || result.jsonrpc !== '2.0' || (!result.method && result.id === undefined)) throw Error('Invalid MCP response');
        if (result.id !== undefined) {
          if (message.id === undefined) return;
          // Session/auth failures can precede body parsing and carry id:null.
          // Settle the actual stdio request immediately instead of leaving it
          // waiting for a response that can never arrive on this HTTP exchange.
          if (!response.ok && result.id === null && result.error) result = { ...result, id: message.id };
          if (result.id !== message.id) throw Error('MCP response identity mismatch');
          received = true;
        }
        if (message.method === 'initialize' && result.result?.protocolVersion) protocol = result.result.protocolVersion;
        emit(result);
      }, controller.signal);
      if (message.id !== undefined && !received) fail(message);
      if (message.method === 'notifications/initialized' && response.ok) notifications();
    } catch { if (!stopping) fail(message); }
    finally { controllers.delete(controller); }
  }
  function line(text) {
    let message;
    try { message = JSON.parse(text); }
    catch { emit({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Invalid JSON' } }); return; }
    if (!message || typeof message !== 'object' || Array.isArray(message)) return fail({ id: null }, -32600, 'Invalid JSON-RPC request');
    // Notifications remain available at capacity so cancellation cannot queue
    // behind the requests it needs to stop.
    if (pending >= 64 || pending >= 32 && message.id !== undefined) return fail(message, -32000, 'Too many concurrent MCP requests');
    pending++;
    const work = forward(message).finally(() => { pending--; });
    if (message.method === 'initialize' || message.method === 'notifications/initialized') {
      initializing = work;
      work.finally(() => { if (initializing === work) initializing = null; });
    }
  }
  async function stop() {
    if (stopping) return; stopping = true;
    clearTimeout(notificationTimer); notificationTimer = null;
    notificationController?.abort();
    for (const controller of controllers) controller.abort();
    input.removeListener('data', onData); input.pause();
    if (sessionId && token) {
      try { await fetch(config.endpoint, { method: 'DELETE', headers: auth(), signal: AbortSignal.timeout(2000), redirect: 'error' }); } catch { /* The desktop may already be gone. */ }
    }
  }
  function onData(chunk) {
    buffer += chunk;
    let at;
    while ((at = buffer.indexOf('\n')) >= 0) {
      const text = buffer.slice(0, at).replace(/\r$/, ''); buffer = buffer.slice(at + 1);
      if (Buffer.byteLength(text) > MAX_LINE) { errors.write('MCP input exceeds 1 MiB\n'); stop(); return; }
      if (text.trim()) line(text);
    }
    if (Buffer.byteLength(buffer) > MAX_LINE) { errors.write('MCP input exceeds 1 MiB\n'); stop(); }
  }
  input.setEncoding('utf8');
  input.on('data', onData);
  input.once('end', stop); input.once('error', stop); output.once('error', stop);
  process.once('SIGINT', stop); process.once('SIGTERM', stop);
  input.resume();
}

module.exports = { run, options, consume, discoverDesktop };
if (require.main === module) run();
