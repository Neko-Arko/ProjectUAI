'use strict';

// Controlled provider fixture: no API keys, forwarding, files, or account access.
// Loopback by default. Use an explicit LAN interface only for a phone test.
const http = require('node:http');
const { performance } = require('node:perf_hooks');

function createFixture({ delayMs = 45000 } = {}) {
  if (!Number.isInteger(delayMs) || delayMs < 1 || delayMs > 120000) throw Error('Invalid fixture delay');
  const jobs = new Map();
  const pending = new Set();
  const reply = (res, status, value) => {
    if (!res.destroyed) res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' }).end(JSON.stringify(value));
  };
  const server = http.createServer((req, res) => {
    if (req.method === 'GET' && req.url === '/health') {
      reply(res, 200, { fixture: 'uai-relay-delay-v1', delayMs, active: pending.size }); return;
    }
    if (req.method !== 'POST' || req.url !== '/probe') { reply(res, 404, { error: 'fixture_route_only' }); return; }
    if (req.headers.authorization) { reply(res, 400, { error: 'credentials_not_expected' }); req.resume(); return; }
    let size = 0, raw = '', oversized = false;
    req.on('data', chunk => {
      size += chunk.length;
      if (size > 1024) { oversized = true; raw = ''; }
      else if (!oversized) raw += chunk.toString('utf8');
    });
    req.on('error', () => {});
    req.on('end', () => {
      if (oversized) { reply(res, 413, { error: 'fixture_body_limit' }); return; }
      let input;
      try { input = JSON.parse(raw); } catch { reply(res, 400, { error: 'invalid_fixture_json' }); return; }
      if (!input || typeof input.probeId !== 'string' || !/^uai_probe_[a-zA-Z0-9_-]{8,80}$/.test(input.probeId)) {
        reply(res, 400, { error: 'invalid_probe_id' }); return;
      }
      if (pending.size >= 8) { reply(res, 503, { error: 'fixture_busy' }); return; }
      if (!jobs.has(input.probeId) && jobs.size >= 256) { reply(res, 503, { error: 'restart_fixture_for_more_tests' }); return; }
      const record = jobs.get(input.probeId) || { dispatches: 0 };
      record.dispatches++;
      jobs.set(input.probeId, record);
      const start = performance.now();
      const active = { res, timer: null };
      pending.add(active);
      const cleanup = () => { clearTimeout(active.timer); pending.delete(active); };
      res.on('close', cleanup);
      active.timer = setTimeout(() => {
        reply(res, 200, { fixture: 'uai-relay-delay-v1', ok: true, probeId: input.probeId,
          dispatches: record.dispatches, elapsedMs: Math.round(performance.now() - start) });
        cleanup();
      }, delayMs);
    });
  });
  server.requestTimeout = 5000;
  server.headersTimeout = 5000;
  return {
    server,
    async close() {
      for (const active of pending) { clearTimeout(active.timer); active.res.destroy(); }
      pending.clear();
      server.closeAllConnections();
      if (server.listening) await new Promise(resolve => server.close(resolve));
    },
  };
}

if (require.main === module) {
  const values = { host: '127.0.0.1', port: 8791, seconds: 45 };
  const args = process.argv.slice(2);
  for (let i = 0; i < args.length; i += 2) {
    const key = args[i].replace(/^--/, '');
    if (!Object.hasOwn(values, key) || args[i + 1] === undefined) throw Error('Usage: node delay_fixture.js [--host IP] [--port 8791] [--seconds 45]');
    values[key] = key === 'host' ? args[i + 1] : Number(args[i + 1]);
  }
  if (!Number.isInteger(values.port) || values.port < 1 || values.port > 65535 || !Number.isInteger(values.seconds) || values.seconds < 35 || values.seconds > 120) {
    throw Error('Port must be 1..65535 and delay must be 35..120 seconds');
  }
  const fixture = createFixture({ delayMs: values.seconds * 1000 });
  fixture.server.on('error', error => { console.error('Fixture could not listen:', error.code || 'network_error'); process.exitCode = 1; });
  fixture.server.listen(values.port, values.host, () => {
    const host = values.host.includes(':') ? '[' + values.host + ']' : values.host;
    console.log('Controlled delay fixture: http://' + host + ':' + values.port + '/probe');
    console.log('Delay: ' + values.seconds + ' seconds. No provider key is used. Stop with Ctrl+C.');
  });
  for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => { fixture.close().catch(() => {}); });
}

module.exports = { createFixture };
