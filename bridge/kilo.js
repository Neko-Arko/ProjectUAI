'use strict';
const https = require('node:https');
const { EventEmitter } = require('node:events');
const { Readable } = require('node:stream');
const { createTor } = require('./kilo-tor');
const { createProxyAgent } = require('./kilo-proxy');

const HOUR = 3600000;
const PATHS = new Set(['/api/gateway', '/api/gateway/v1', '/api/v1'].flatMap(base =>
  ['/chat/completions', '/responses', '/messages'].map(route => base + route)));
function eligible(url, headers, body) {
  if (url.protocol !== 'https:' || url.port && url.port !== '443' || url.username || url.password || url.search ||
    !['api.kilo.ai', 'ai-gateway.kilo.ai'].includes(url.hostname) || !PATHS.has(url.pathname)) return false;
  if (Object.keys(headers).some(name => /authorization|api[-_]?key|token|cookie|organization/i.test(name))) return false;
  try {
    const model = JSON.parse(body).model;
    return typeof model === 'string' && (model === 'kilo-auto/free' || model.endsWith(':free'));
  } catch { return false; }
}
function quota(status, body) {
  if (status !== 429) return false;
  try { return JSON.parse(body).error?.code === 'PROMOTION_MODEL_LIMIT_REACHED'; } catch { return false; }
}
function bufferedResponse(status, headers, body) {
  const response = Readable.from([body]);
  response.statusCode = status; response.headers = headers; return response;
}

// At most one direct refusal, one tunnel attempt and one tunnel retry per job.
// Only a complete, explicit anonymous quota response can cause a second send.
function createKilo({ enabled = process.env.UAI_KILO_TUNNEL !== '0', torFactory = createTor,
  agentFactory = createProxyAgent, request = https.request, now = Date.now, warm = false, onChange = () => {} } = {}) {
  let state = enabled ? 'standby' : 'disabled';
  let message = enabled ? 'Starts automatically after an anonymous Kilo quota response.' : 'Kilo tunnel is off.';
  let directUntil = 0, blockedUntil = 0, blockedResponse, cooldownTimer, agent, stopped = false;
  const jobs = new Set();
  const capability = () => {
    const limited = !stopped && state !== 'failed' && now() < blockedUntil;
    return { schema: 1, enabled, available: !limited && (state === 'ready' || state === 'rotating'),
      state: limited ? 'limited' : state,
      message: limited ? 'Shared Kilo tunnel exits are limited. Waiting briefly before another attempt.' : message };
  };
  const tor = enabled ? torFactory({ onState: (next, detail) => { if (!stopped) { state = next; message = detail; onChange(capability()); } } }) : null;
  let preparing;
  function prepare() {
    if (stopped) return Promise.reject(Error('Kilo tunnel stopped'));
    return preparing ||= tor.ensure().then(({ port }) => {
      if (stopped) throw Error('Kilo tunnel stopped');
      agent = agentFactory(port); return agent;
    }).catch(() => {
      if (stopped) throw Error('Kilo tunnel stopped');
      state = 'failed'; message = 'The Kilo tunnel could not start. Restart the bridge to try again.';
      onChange(capability()); throw Error(message);
    });
  }
  if (enabled && warm) queueMicrotask(() => { if (!stopped) prepare().catch(() => {}); });
  return {
    accepts(url, headers, body) { return enabled && !stopped && eligible(url, headers, body); },
    capability,
    request(url, options, callback) {
      const facade = new EventEmitter();
      let active, body, destroyed = false, ended = false, released = false, retried = false, tunneled = false, epoch;
      jobs.add(facade);
      const releaseBody = () => {
        body = undefined;
        // Inference uses finish to release its request-memory reservation. The
        // facade retains the payload beyond each transport send for replay.
        if (ended && !released) { released = true; facade.emit('finish'); }
      };
      const done = () => { releaseBody(); jobs.delete(facade); };
      const fail = error => {
        done(); if (!destroyed) { destroyed = true; facade.emit('error', error); }
      };
      function deliver(response) {
        if (destroyed) { response.destroy(); return; }
        releaseBody();
        response.once('end', done); response.once('close', done);
        callback(response);
      }
      async function send(useTunnel) {
        if (destroyed || stopped) return;
        try {
          let selectedAgent;
          if (useTunnel) selectedAgent = await prepare();
          if (destroyed || stopped) return;
          tunneled = useTunnel; epoch = tor.generation;
          active = request(url, { ...options, ...(useTunnel ? { agent: selectedAgent } : {}) }, response => {
            if (destroyed) { response.destroy(); return; }
            if (response.statusCode !== 429) { deliver(response); return; }
            const chunks = []; let size = 0;
            response.on('data', chunk => {
              size += chunk.length;
              if (size > 65536) { response.destroy(); fail(Error('Kilo quota response exceeded its limit')); return; }
              chunks.push(chunk);
            });
            response.once('error', () => fail(Error('Kilo response connection closed')));
            response.once('close', () => { if (!response.readableEnded) fail(Error('Kilo response connection closed')); });
            response.once('end', () => {
              if (destroyed) return;
              const bytes = Buffer.concat(chunks);
              if (!quota(response.statusCode, bytes)) { deliver(bufferedResponse(response.statusCode, response.headers, bytes)); return; }
              const headers = { ...response.headers, 'x-should-retry': 'false' };
              if (!tunneled) {
                directUntil = now() + HOUR;
                send(true).catch(fail);
              } else if (!retried) {
                retried = true;
                tor.rotate(epoch).then(() => send(true)).catch(() => fail(Error('Could not change the Kilo tunnel connection')));
              } else {
                // Shared exits may already be limited. Suppress immediate storms
                // across concurrent agent jobs without claiming a reset time.
                blockedUntil = now() + 60000;
                blockedResponse = { status: response.statusCode, headers, bytes };
                clearTimeout(cooldownTimer);
                cooldownTimer = setTimeout(() => {
                  blockedUntil = 0; blockedResponse = undefined;
                  if (!stopped) onChange(capability());
                }, 60000);
                cooldownTimer.unref?.();
                onChange(capability());
                deliver(bufferedResponse(response.statusCode, headers, bytes));
              }
            });
          });
          active.setTimeout(0);
          active.once('error', () => fail(Error('Could not complete the Kilo connection')));
          active.end(body);
        } catch (error) { fail(error); }
      }
      facade.setTimeout = () => facade;
      facade.destroy = () => { destroyed = true; active?.destroy(); done(); return facade; };
      facade.end = value => {
        if (ended || destroyed) return facade;
        ended = true; body = value;
        if (blockedResponse && now() < blockedUntil) {
          queueMicrotask(() => deliver(bufferedResponse(blockedResponse.status, blockedResponse.headers, blockedResponse.bytes)));
        } else send(now() < directUntil).catch(fail);
        return facade;
      };
      return facade;
    },
    async close() {
      stopped = true; state = 'disabled'; message = 'Kilo tunnel stopped.';
      clearTimeout(cooldownTimer);
      for (const job of jobs) job.destroy();
      agent?.destroy(); await tor?.close();
    }
  };
}
module.exports = { createKilo, eligible, quota };
