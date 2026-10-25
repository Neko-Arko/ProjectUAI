'use strict';
const http = require('node:http');
const https = require('node:https');
const tls = require('node:tls');

// A private CONNECT agent, compatible with the bridge's Node 18 baseline.
// No global proxy environment or other provider's agent is changed.
function createProxyAgent(port, { ca, connectTimeout = 20000 } = {}) {
  const agent = new https.Agent({ keepAlive: false, ca });
  const pending = new Set();
  agent.createConnection = (options, callback) => {
    let settled = false, secure;
    const target = options.hostname || options.host;
    const connect = http.request({ hostname: '127.0.0.1', port, method: 'CONNECT',
      path: `${target}:${options.port || 443}`, agent: false,
      headers: { host: `${target}:${options.port || 443}` } });
    pending.add(connect);
    const finish = (error, socket) => {
      if (settled) return;
      settled = true; clearTimeout(timer); pending.delete(connect);
      if (secure) pending.delete(secure);
      if (error) { secure?.destroy(); connect.destroy(); }
      callback(error, socket);
    };
    const timer = setTimeout(() => finish(Error('Kilo tunnel connection timed out')), connectTimeout);
    connect.once('error', () => finish(Error('Could not connect to the Kilo tunnel')));
    connect.once('close', () => { if (!secure) finish(Error('Kilo tunnel connection closed')); });
    connect.once('connect', (response, socket, head) => {
      if (settled) { socket.destroy(); return; }
      if (response.statusCode !== 200) { socket.destroy(); finish(Error('Kilo tunnel refused the connection')); return; }
      if (head.length) socket.unshift(head);
      secure = tls.connect({ socket, servername: options.servername || target, ca: options.ca || ca,
        rejectUnauthorized: true, ALPNProtocols: ['http/1.1'] });
      pending.add(secure);
      secure.once('error', () => finish(Error('Could not verify the Kilo TLS connection')));
      secure.once('close', () => finish(Error('Kilo TLS connection closed')));
      secure.once('secureConnect', () => finish(null, secure));
    });
    connect.end();
    return undefined;
  };
  const destroy = agent.destroy.bind(agent);
  agent.destroy = () => { for (const connection of pending) connection.destroy(); pending.clear(); destroy(); };
  return agent;
}
module.exports = { createProxyAgent };
