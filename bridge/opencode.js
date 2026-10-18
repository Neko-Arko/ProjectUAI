'use strict';

const RELEASE = require('./release');

// OpenCode owns the upstream connection. This adapter owns an isolated CLI
// server and returns UAI tool calls to Roblox without executing host tools.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const { spawn, execFile } = require('node:child_process');
const { once } = require('node:events');
const { help } = require('./support');

const MAX_REPLY = 8 << 20;
const WAIT_MS = 150;
const REQUIRED_ROUTES = ['/api/model', '/api/session', '/api/session/{sessionID}', '/api/session/{sessionID}/prompt',
  '/api/session/{sessionID}/message', '/api/session/{sessionID}/interrupt', '/api/session/{sessionID}/permission', '/api/experimental/mcp/{server}'];
const missing = 'Install OpenCode Desktop from https://opencode.ai, then restart Cowork. OpenCode free models require the desktop workaround; mobile is unsupported.';
const pause = (ms, signal) => new Promise((resolve, reject) => {
  if (signal?.aborted) { reject(Error('Stopped')); return; }
  const abort = () => { clearTimeout(timer); reject(Error('Stopped')); };
  const timer = setTimeout(() => { signal?.removeEventListener('abort', abort); resolve(); }, ms);
  signal?.addEventListener('abort', abort, { once: true });
});

function official(url) {
  try {
    const u = new URL(url);
    return u.protocol === 'https:' && u.hostname === 'opencode.ai' && !u.port && !u.username && !u.password &&
      /^\/(?:zen\/v1|inference\/v1|inference\/openai\/v1)\/(?:chat\/completions|responses)\/?$/.test(u.pathname);
  } catch { return false; }
}

function findBinary(env = process.env, platform = process.platform) {
  if (env.UAI_OPENCODE_DISABLED === '1') return null;
  const names = platform === 'win32' ? ['opencode-cli.exe', 'opencode.exe'] : ['opencode-cli', 'opencode'];
  const candidates = [];
  if (env.UAI_OPENCODE_BINARY) candidates.push(env.UAI_OPENCODE_BINARY);
  else {
    if (platform === 'win32' && env.LOCALAPPDATA) candidates.push(path.join(env.LOCALAPPDATA, 'Programs', '@opencodedesktop', 'resources', 'opencode-cli.exe'));
    if (platform === 'darwin') candidates.push('/Applications/OpenCode.app/Contents/MacOS/opencode-cli');
    for (const folder of (env.PATH || env.Path || '').split(path.delimiter)) {
      if (path.isAbsolute(folder)) for (const name of names) candidates.push(path.join(folder, name));
    }
    if (env.USERPROFILE || env.HOME) for (const name of names) candidates.push(path.join(env.USERPROFILE || env.HOME, '.opencode', 'bin', name));
  }
  for (const candidate of candidates) {
    try {
      if (!path.isAbsolute(candidate) || (platform === 'win32' && !candidate.toLowerCase().endsWith('.exe'))) continue;
      if (!fs.statSync(candidate).isFile()) continue;
      fs.accessSync(candidate, platform === 'win32' ? fs.constants.F_OK : fs.constants.X_OK);
      return fs.realpathSync(candidate);
    } catch { /* Try the next installed native binary. Never invoke a shell shim. */ }
  }
  return null;
}

function jsonRequest(base, password, route, method = 'GET', body, signal, timeout = 5000) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) { reject(Error('Stopped')); return; }
    const bytes = body === undefined ? null : Buffer.from(JSON.stringify(body));
    const req = http.request(base + route, { method, signal, headers: {
      authorization: 'Basic ' + Buffer.from('opencode:' + password).toString('base64'),
      accept: 'application/json', ...(bytes ? { 'content-type': 'application/json', 'content-length': bytes.length } : {})
    } }, res => {
      const chunks = []; let size = 0;
      res.on('data', chunk => { size += chunk.length; if (size > MAX_REPLY) req.destroy(Error('OpenCode response exceeds the relay limit')); else chunks.push(chunk); });
      res.on('error', () => reject(Error('OpenCode local response was interrupted')));
      res.on('end', () => {
        if (res.statusCode < 200 || res.statusCode >= 300) { reject(Error('OpenCode local API returned HTTP ' + res.statusCode)); return; }
        if (res.statusCode === 204) { resolve(null); return; }
        try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); }
        catch { reject(Error('OpenCode returned an incompatible API response; update OpenCode Desktop')); }
      });
    });
    if (timeout) req.setTimeout(timeout, () => req.destroy(Error('OpenCode local API did not respond')));
    req.on('error', reject); req.end(bytes);
  });
}

function toolDefinitions(body) {
  if (!Array.isArray(body.tools)) return [];
  const seen = new Set();
  // These compatibility declarations belong only to the old direct wire
  // workaround. The real CLI supplies its own native schemas.
  const legacy = new Set(['bash', 'read', 'edit', 'glob', 'grep', 'list', 'shell']);
  return body.tools.filter(tool => !legacy.has((tool.function || tool)?.name)).map(tool => {
    const f = tool.type === 'function' ? tool.function || tool : null;
    if (!f || typeof f.name !== 'string' || !/^[a-zA-Z0-9_-]{1,100}$/.test(f.name) || seen.has(f.name)) throw Error('OpenCode requires unique UAI function tools');
    seen.add(f.name);
    return { name: f.name, description: String(f.description || ''), inputSchema: f.parameters || { type: 'object', properties: {} } };
  });
}

function promptFor(body) {
  const source = body.messages || body.input;
  if (!Array.isArray(source) && typeof source !== 'string') throw Error('OpenCode requires a conversation');
  // No history is carried between native sessions: the caller's compacted
  // messages and tool results remain the sole conversation of record.
  const instructions = [
    'You are Project UAI, operating in Roblox through its supplied remote tools.',
    'The JSON below is the conversation to continue. Respect its system/developer instructions and message roles.',
    'Only the uai MCP tools act in Roblox. They are exposed directly as uai_<original tool name>. Call these top-level tools directly; never use execute, search, filesystem, terminal, web, task, permission or other host tools.',
    'Return the assistant answer or call the requested uai tools. Tool results will arrive in the next conversation. Do not invent results.',
  ];
  if (typeof body.instructions === 'string') instructions.push(body.instructions);
  return instructions.join('\n') + '\n\nConversation:\n' + JSON.stringify(source);
}

function promptInput(body) {
  const files = [], source = body.messages || body.input;
  const conversation = Array.isArray(source) ? source.map(message => {
    if (!Array.isArray(message?.content)) return message;
    return { ...message, content: message.content.map(part => {
      if (!['image_url', 'input_image'].includes(part?.type)) return part;
      const uri = typeof part.image_url === 'string' ? part.image_url : part.image_url?.url;
      if (typeof uri !== 'string' || !/^data:image\/(?:png|jpeg|webp);base64,[A-Za-z0-9+/=]+$/.test(uri))
        throw Error('OpenCode needs images attached through Cowork; reattach the picture or use another image-capable provider.');
      if (files.length >= 8 || Buffer.byteLength(uri) > 8 << 20) throw Error('OpenCode image attachment limit reached');
      const number = files.length + 1;
      files.push({ uri, name: 'image-' + number + '.' + (/^data:image\/jpeg/.test(uri) ? 'jpg' : /^data:image\/webp/.test(uri) ? 'webp' : 'png') });
      return { type: 'text', text: '[Attached image ' + number + ' for this message]' };
    }) };
  }) : source;
  const normalized = { ...body, ...(body.messages ? { messages: conversation } : { input: conversation }) };
  return { text: promptFor(normalized), ...(files.length ? { files } : {}) };
}

function responseBody(model, message, calls, responses) {
  const parts = Array.isArray(message?.content) ? message.content : [];
  const text = parts.filter(p => p.type === 'text').map(p => p.text || '').join('');
  const reasoning = parts.filter(p => p.type === 'reasoning').map(p => p.text || '').join('');
  const id = 'uai_' + crypto.randomBytes(12).toString('hex');
  const tokens = message?.tokens;
  // Native input/output contain only uncached input and visible output.
  // OpenAI-compatible totals include cache reads/writes and reasoning.
  const promptTokens = (tokens?.input || 0) + (tokens?.cache?.read || 0) + (tokens?.cache?.write || 0);
  const completionTokens = (tokens?.output || 0) + (tokens?.reasoning || 0);
  const usage = tokens ? { prompt_tokens: promptTokens, completion_tokens: completionTokens,
    total_tokens: promptTokens + completionTokens, cache_creation_input_tokens: tokens.cache?.write || 0,
    prompt_tokens_details: { cached_tokens: tokens.cache?.read || 0 }, completion_tokens_details: { reasoning_tokens: tokens.reasoning || 0 } } : undefined;
  if (responses) {
    const output = [];
    if (reasoning) output.push({ type: 'reasoning', summary: [{ type: 'summary_text', text: reasoning }] });
    if (text) output.push({ type: 'message', role: 'assistant', content: [{ type: 'output_text', text }] });
    for (const call of calls) output.push({ type: 'function_call', id: call.id, call_id: call.id, name: call.name, arguments: JSON.stringify(call.arguments) });
    return { id, object: 'response', model, status: message?.finish === 'length' ? 'incomplete' : 'completed', output,
      ...(tokens ? { usage: { input_tokens: usage.prompt_tokens, output_tokens: usage.completion_tokens, total_tokens: usage.total_tokens,
        cache_creation_input_tokens: usage.cache_creation_input_tokens,
        input_tokens_details: usage.prompt_tokens_details, output_tokens_details: usage.completion_tokens_details } } : {}) };
  }
  const result = { role: 'assistant', content: text || null };
  if (reasoning) result.reasoning_content = reasoning;
  if (calls.length) result.tool_calls = calls.map(call => ({ id: call.id, type: 'function', function: { name: call.name, arguments: JSON.stringify(call.arguments) } }));
  return { id, object: 'chat.completion', model, ...(usage ? { usage } : {}), choices: [{ index: 0, message: result,
    finish_reason: message?.finish === 'length' ? 'length' : calls.length ? 'tool_calls' : 'stop' }] };
}

function createOpenCode({ env = process.env, binary = findBinary(env), binaryArgs = [], startupMs = 30000, pollMs = WAIT_MS } = {}) {
  let child, directory, base, password, rpcServer, rpcSecret, starting, closed = false;
  const enabled = env.UAI_OPENCODE_DISABLED !== '1';
  if (!enabled) binary = null;
  let state = !enabled ? 'disabled' : binary ? 'starting' : 'missing', modelsCache = [], version;
  let failure = 'OpenCode could not start. Update OpenCode Desktop and restart Cowork.';
  const jobs = new Map();
  const killOwnedChild = () => { if (child && child.exitCode === null && child.signalCode === null) child.kill(); };
  process.once('exit', killOwnedChild);
  const api = (route, method, body, signal, timeout) => jsonRequest(base, password, route, method, body, signal, timeout);
  const capability = () => ({ schema: 1, enabled, available: !!binary && !closed && state !== 'failed', state, models: '/api/opencode/models',
    ...(binary ? { binary: path.basename(binary) } : {}), ...(version ? { version } : {}),
    ...(state === 'disabled' ? { message: 'OpenCode tunnel is turned off. Enable it in the desktop app, then start Cowork again.' }
      : state === 'missing' ? { message: help(missing) } : state === 'failed' ? { message: help(failure) } : {}) });

  async function start() {
    if (closed) throw Error('OpenCode bridge stopped');
    if (!enabled) throw Error('OpenCode tunnel is turned off');
    if (!binary) throw Error(missing);
    if (starting) return starting;
    starting = (async () => {
      directory = fs.mkdtempSync(path.join(os.tmpdir(), 'project-uai-opencode-'));
      rpcSecret = crypto.randomBytes(32).toString('hex');
      password = crypto.randomBytes(32).toString('hex');
      rpcServer = http.createServer((req, res) => {
        const job = jobs.get(req.url?.slice('/mcp/'.length));
        if (req.method !== 'POST' || !req.url?.startsWith('/mcp/') || !job || req.headers.origin !== undefined ||
            req.headers.authorization !== 'Bearer ' + rpcSecret) { res.writeHead(403); res.end(); return; }
        let size = 0; const chunks = [];
        const hold = () => { if (!job.pending.has(res)) { job.pending.add(res); res.on('close', () => job.pending.delete(res)); } };
        req.on('error', () => {});
        req.on('data', chunk => {
          size += chunk.length;
          if (size > 1 << 20) { job.failure = 'OpenCode returned oversized tool arguments'; hold(); }
          else chunks.push(chunk);
        });
        req.on('end', () => {
          if (job.failure) return;
          let input;
          try { input = JSON.parse(Buffer.concat(chunks).toString()); } catch { res.writeHead(400); res.end(); return; }
          const reply = result => { res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify({ jsonrpc: '2.0', id: input.id, result })); };
          if (input.method === 'initialize') reply({ protocolVersion: '2024-11-05', capabilities: { tools: {} }, serverInfo: { name: 'Project UAI', version: RELEASE.version } });
          else if (input.method === 'tools/list') reply({ tools: job.tools });
          else if (input.method === 'tools/call') {
            const name = input.params?.name, args = input.params?.arguments;
            const argumentBytes = Buffer.byteLength(JSON.stringify(args || {}));
            if (!job.tools.some(tool => tool.name === name) || !args || typeof args !== 'object' || Array.isArray(args) || job.calls.length >= 64 ||
                job.argumentBytes + argumentBytes > 256000) {
              job.failure = 'OpenCode returned invalid or oversized tool arguments'; hold(); return;
            }
            job.argumentBytes += argumentBytes;
            job.calls.push({ id: 'call_' + crypto.randomBytes(12).toString('hex'), name, arguments: args });
            // Hold the result. Roblox must execute the call; returning a fake
            // result here would let the native agent take a second model turn.
            hold();
          } else if (input.id === undefined) { res.writeHead(202); res.end(); }
          else reply({});
        });
      });
      rpcServer.listen(0, '127.0.0.1'); await once(rpcServer, 'listening');
      const reserve = http.createServer(); reserve.listen(0, '127.0.0.1'); await once(reserve, 'listening');
      const port = reserve.address().port; await new Promise(resolve => reserve.close(resolve));
      if (closed) throw Error('OpenCode bridge stopped');
      base = 'http://127.0.0.1:' + port;
      const config = { update: 'disable', share: 'disabled', snapshots: false, lsp: false, formatter: false,
        permissions: [{ action: '*', resource: '*', effect: 'ask' }], agents: { uai: { mode: 'primary',
          system: 'Continue the supplied Project UAI Roblox conversation. Only call its uai MCP tools. Never execute host tools.' } } };
      const isolated = { ...env, OPENCODE_SERVER_PASSWORD: password, OPENCODE_SERVER_USERNAME: 'opencode',
        OPENCODE_CONFIG_CONTENT: JSON.stringify(config), OPENCODE_CONFIG: '', OPENCODE_CONFIG_DIR: '',
        XDG_DATA_HOME: path.join(directory, 'data'), XDG_CONFIG_HOME: path.join(directory, 'config'),
        XDG_CACHE_HOME: path.join(directory, 'cache'), XDG_STATE_HOME: path.join(directory, 'state') };
      for (const name of Object.keys(isolated)) {
        if (/(?:^|_)(?:API_KEY|API_TOKEN|ACCESS_TOKEN|AUTH_TOKEN|SECRET_KEY)$/.test(name) || name === 'OPENCODE_AUTH_JSON') delete isolated[name];
      }
      // Check the selected executable itself, not the desktop app's adjacent
      // version file. Old compatible v2 builds may omit this diagnostic.
      version = await new Promise(resolve => execFile(binary, [...binaryArgs, '--version'],
        { cwd: directory, env: isolated, windowsHide: true, timeout: 4000, maxBuffer: 4096 }, (error, stdout) => {
          const match = !error && /^opencode\s+v?(\d+\.\d+\.\d+(?:[-+][\w.-]+)?)\s*$/i.exec(stdout.trim());
          resolve(match ? match[1] : undefined);
        }));
      if (closed) throw Error('OpenCode bridge stopped');
      child = spawn(binary, [...binaryArgs, 'serve', '--port', String(port), '--hostname', '127.0.0.1'],
        { cwd: directory, env: isolated, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
      child.stdout.resume(); child.stderr.resume(); // Never expose credentials or provider output in launcher logs.
      child.on('error', () => { state = 'failed'; });
      child.on('exit', () => { if (!closed) state = 'failed'; });
      const expires = Date.now() + startupMs;
      while (!closed && Date.now() < expires) {
        if (state === 'failed') break;
        try {
          const spec = await api('/openapi.json');
          if (!REQUIRED_ROUTES.every(route => spec.paths?.[route])) {
            failure = 'The installed OpenCode CLI has an incompatible server API. Install an updated OpenCode Desktop v2 and restart Cowork.';
            break;
          }
          const list = await api('/api/model');
          modelsCache = modelRows(list);
          if (modelsCache.length) { state = 'ready'; return; }
        } catch { /* The native server and its built-in provider plugin start independently. */ }
        await pause(pollMs);
      }
      if (closed) throw Error('OpenCode bridge stopped');
      state = 'failed'; child?.kill();
      throw Error(failure);
    })().catch(error => { if (!closed) state = 'failed'; throw error; });
    return starting;
  }

  function modelRows(value) {
    if (!Array.isArray(value?.data)) throw Error('OpenCode returned an invalid model catalog');
    return value.data.filter(item => item?.providerID === 'opencode' && typeof item.id === 'string' &&
      Array.isArray(item.cost) && item.cost.length > 0 && item.cost.every(tier =>
        tier.input === 0 && tier.output === 0 && tier.cache?.read === 0 && tier.cache?.write === 0)).map(item => ({
      id: item.id, object: 'model', owned_by: 'opencode', name: item.name,
      ...(item.limit ? { context_length: item.limit.context, max_output_tokens: item.limit.output } : {}),
      ...(item.capabilities ? { capabilities: item.capabilities } : {})
    }));
  }

  async function models() {
    await start();
    modelsCache = modelRows(await api('/api/model'));
    return { object: 'list', data: modelsCache };
  }

  async function request({ body, url, signal, onFrame = () => {} }) {
    await start();
    if (signal?.aborted || closed) throw Error('Stopped');
    if (!official(url)) throw Error('Unsupported OpenCode endpoint');
    const input = JSON.parse(body), tools = toolDefinitions(input);
    if (typeof input.model !== 'string' || !input.model) throw Error('Choose an OpenCode model');
    const prompt = promptInput(input);
    const key = crypto.randomBytes(16).toString('hex'), location = path.join(directory, key);
    fs.mkdirSync(location);
    const job = { tools, calls: [], argumentBytes: 0, pending: new Set() }; jobs.set(key, job);
    const locationQuery = '?location[directory]=' + encodeURIComponent(location);
    let session, registered = false;
    const abort = () => { if (session) api('/api/session/' + session + '/interrupt', 'POST', {}).catch(() => {}); };
    signal?.addEventListener('abort', abort, { once: true });
    try {
      if (tools.length) {
        registered = true;
        await api('/api/experimental/mcp/uai' + locationQuery, 'PUT', { config: { type: 'remote',
          url: 'http://127.0.0.1:' + rpcServer.address().port + '/mcp/' + key,
          headers: { Authorization: 'Bearer ' + rpcSecret }, oauth: false, codemode: false, protocol: 'legacy' } }, signal);
      }
      const created = await api('/api/session', 'POST', { title: 'Project UAI temporary request', agent: 'uai',
        location: { directory: location }, model: { id: input.model.replace(/^opencode\//, ''), providerID: 'opencode' },
        permissions: [{ action: '*', resource: '*', effect: 'ask' },
          ...tools.map(tool => ({ action: 'uai_' + tool.name, resource: '*', effect: 'allow' }))] }, signal);
      session = created?.data?.id;
      if (typeof session !== 'string' || !/^[\w-]+$/.test(session)) throw Error('OpenCode returned an invalid session');
      await api('/api/session/' + session + '/prompt', 'POST', prompt, signal);
      let message, textSize = 0, reasoningSize = 0;
      for (;;) {
        if (closed || signal?.aborted || state !== 'ready') throw Error(signal?.aborted ? 'Stopped' : 'OpenCode stopped during the request');
        if (job.failure) throw Error(job.failure);
        const page = await api('/api/session/' + session + '/message?limit=20&order=desc', 'GET', undefined, signal);
        message = page?.data?.find(value => value.type === 'assistant');
        if (message?.error) throw Error('OpenCode provider rejected the request (' + String(message.error.type || message.error.name || 'provider_error').replace(/[^\w.-]/g, '').slice(0, 80) + '). Check the model availability in OpenCode Desktop.');
        const parts = Array.isArray(message?.content) ? message.content : [];
        const text = parts.filter(part => part.type === 'text').map(part => part.text || '').join('');
        const reasoning = parts.filter(part => part.type === 'reasoning').map(part => part.text || '').join('');
        if (text.length > textSize) onFrame({ choices: [{ delta: { content: text.slice(textSize) } }] });
        if (reasoning.length > reasoningSize) onFrame({ choices: [{ delta: { reasoning_content: reasoning.slice(reasoningSize) } }] });
        textSize = text.length; reasoningSize = reasoning.length;
        const nativeTools = parts.filter(part => part.type === 'tool');
        if (nativeTools.some(part => !tools.some(tool => 'uai_' + tool.name === part.name)))
          throw Error('OpenCode requested a local desktop action. UAI runs tools only in Roblox; the desktop action was not approved.');
        // OpenCode v2 records time.streamed when the provider stream ends,
        // before waiting for MCP results. time.completed waits for those
        // results, which intentionally remain held for the Roblox handoff.
        if (message?.time?.streamed && nativeTools.length && job.calls.length === nativeTools.length) break;
        if (message?.time?.completed && !nativeTools.length) break;
        if (message?.time?.completed || nativeTools.some(part => ['error', 'completed'].includes(part.state?.status)))
          throw Error('OpenCode could not hand off the requested tool call. No desktop action was approved; the request was not repeated.');
        const permissions = await api('/api/session/' + session + '/permission', 'GET', undefined, signal);
        if (Array.isArray(permissions?.data) && permissions.data.length) throw Error('OpenCode requested a local desktop action. UAI runs tools only in Roblox; the desktop action was not approved.');
        await pause(pollMs, signal);
      }
      if (!message) throw Error('OpenCode returned no assistant response');
      if (job.calls.length) await api('/api/session/' + session + '/interrupt', 'POST', {});
      for (const [index, call] of job.calls.entries()) onFrame({ choices: [{ delta: { tool_calls: [{ index, id: call.id, type: 'function', function: { name: call.name, arguments: JSON.stringify(call.arguments) } }] } }] });
      const payload = responseBody(input.model, message, job.calls, new URL(url).pathname.endsWith('/responses'));
      return { status: 200, headers: { 'content-type': 'application/json' }, body: JSON.stringify(payload) };
    } finally {
      signal?.removeEventListener('abort', abort);
      if (session) {
        await api('/api/session/' + session + '/interrupt', 'POST', {}).catch(() => {});
        await api('/api/session/' + session, 'DELETE').catch(() => {});
      }
      for (const res of job.pending) res.destroy();
      if (registered) await api('/api/experimental/mcp/uai' + locationQuery, 'DELETE').catch(() => {});
      jobs.delete(key);
      if (path.dirname(location) === directory && path.basename(location) === key)
        try { fs.rmSync(location, { recursive: true, force: true, maxRetries: 2, retryDelay: 100 }); } catch { /* Native watcher may still hold the isolated directory; close retries the root. */ }
    }
  }

  async function close() {
    if (closed) return; closed = true;
    if (state !== 'disabled' && state !== 'missing') state = 'stopped';
    process.removeListener('exit', killOwnedChild);
    for (const job of jobs.values()) for (const res of job.pending) res.destroy();
    rpcServer?.closeAllConnections(); rpcServer?.close();
    if (child && child.exitCode === null && child.signalCode === null) {
      const exited = once(child, 'exit').catch(() => {}); child.kill();
      await Promise.race([exited, pause(2500)]);
    }
    // This root was created by mkdtemp, never derived from a caller's path.
    if (directory && path.dirname(directory) === os.tmpdir() && path.basename(directory).startsWith('project-uai-opencode-'))
      try { fs.rmSync(directory, { recursive: true, force: true, maxRetries: 2, retryDelay: 100 }); } catch { /* Locked native cache is safe to leave private. */ }
  }
  function accepts(url, body) {
    if (!official(url) || state !== 'ready') return false;
    try {
      const model = JSON.parse(body).model?.replace(/^opencode\//, '');
      return modelsCache.some(item => item.id === model);
    } catch { return false; }
  }
  return { start, request, models, capability, close, accepts };
}

module.exports = { createOpenCode, findBinary, official, promptFor, promptInput, responseBody, toolDefinitions };
