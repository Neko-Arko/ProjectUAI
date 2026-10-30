'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const net = require('node:net');
const http = require('node:http');
const https = require('node:https');
const { once } = require('node:events');
const { createProxyAgent } = require('../kilo-proxy');
const cert = fs.readFileSync(path.join(__dirname, 'fixtures/kilo-test-cert.pem'));
const key = fs.readFileSync(path.join(__dirname, 'fixtures/kilo-test-key.pem'));
async function listen(server) { server.listen(0, '127.0.0.1'); await once(server, 'listening'); return server.address().port; }
test('CONNECT keeps provider TLS and streams the exact response through the local proxy', async t => {
  const sockets = new Set();
  const upstream = https.createServer({ key, cert }, (req, res) => {
    assert.equal(req.headers.authorization, 'Bearer fixture');
    res.writeHead(200, { 'content-type': 'text/event-stream' }); res.end('data: {"ok":true}\n\ndata: [DONE]\n\n');
  });
  const upstreamPort = await listen(upstream);
  const proxy = http.createServer(); let connects = 0;
  proxy.on('connect', (req, client, head) => {
    connects++; assert.equal(req.url, `localhost:${upstreamPort}`); assert.equal(req.headers.authorization, undefined);
    const remote = net.connect(upstreamPort, '127.0.0.1'); sockets.add(remote); sockets.add(client);
    remote.on('error', () => client.destroy()); client.on('error', () => remote.destroy());
    remote.once('connect', () => { client.write('HTTP/1.1 200 Connection Established\r\n\r\n'); if (head.length) remote.write(head); client.pipe(remote).pipe(client); });
  });
  const port = await listen(proxy), agent = createProxyAgent(port, { ca: cert });
  t.after(() => { agent.destroy(); for (const socket of sockets) socket.destroy(); upstream.closeAllConnections(); upstream.close(); proxy.close(); });
  const result = await new Promise((resolve, reject) => {
    const request = https.get(`https://localhost:${upstreamPort}/`, { agent, headers: { Authorization: 'Bearer fixture' } }, response => {
      let body = ''; response.on('data', chunk => { body += chunk; }); response.on('end', () => resolve({ status: response.statusCode, body })); response.on('error', reject);
    }); request.on('error', reject);
  });
  assert.equal(connects, 1); assert.equal(result.status, 200); assert.equal(result.body, 'data: {"ok":true}\n\ndata: [DONE]\n\n');
});
test('proxy refusal and a stalled CONNECT terminate within the connection budget', async t => {
  for (const refuse of [true, false]) {
    const sockets = new Set(); const proxy = http.createServer();
    proxy.on('connect', (req, socket) => { sockets.add(socket); if (refuse) socket.end('HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n'); });
    const port = await listen(proxy), agent = createProxyAgent(port, { connectTimeout: 60 });
    t.after(() => { agent.destroy(); for (const socket of sockets) socket.destroy(); proxy.close(); });
    await assert.rejects(new Promise((resolve, reject) => { https.get('https://localhost/', { agent }, resolve).on('error', reject); }), /refused|timed out/);
  }
});
test('an untrusted provider certificate is rejected even through a working CONNECT', async t => {
  const sockets = new Set(); const upstream = https.createServer({ key, cert });
  const upstreamPort = await listen(upstream), proxy = http.createServer();
  proxy.on('connect', (req, client) => {
    const remote = net.connect(upstreamPort, '127.0.0.1'); sockets.add(remote); sockets.add(client);
    remote.on('error', () => client.destroy()); client.on('error', () => remote.destroy());
    remote.once('connect', () => { client.write('HTTP/1.1 200 Connection Established\r\n\r\n'); client.pipe(remote).pipe(client); });
  });
  const port = await listen(proxy), agent = createProxyAgent(port);
  t.after(() => { agent.destroy(); for (const socket of sockets) socket.destroy(); upstream.closeAllConnections(); upstream.close(); proxy.close(); });
  await assert.rejects(new Promise((resolve, reject) => { https.get(`https://localhost:${upstreamPort}/`, { agent }, resolve).on('error', reject); }), /verify.*TLS/);
});
