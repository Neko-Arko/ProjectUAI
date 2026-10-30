'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const { createTor } = require('../kilo-tor');

test('closing during session creation waits for startup and removes its private directory', async t => {
  const mkdtemp = fsp.mkdtemp.bind(fsp); let release, session;
  const gate = new Promise(resolve => { release = resolve; });
  t.mock.method(fsp, 'mkdtemp', async (...args) => {
    await gate; session = await mkdtemp(...args); return session;
  });
  const tor = createTor({ env: { UAI_KILO_TOR_BINARY: process.execPath } });
  t.after(() => { release(); return tor.close(); });
  const startup = assert.rejects(tor.ensure(), /stopped/);
  let closed = false; const closing = tor.close().then(() => { closed = true; });
  await new Promise(resolve => setImmediate(resolve));
  const closedBeforeStartup = closed;
  release(); await startup; await closing;
  assert.equal(closedBeforeStartup, false);
  assert.equal(fs.existsSync(session), false);
});

test('closing while writing configuration never launches the helper after shutdown', async t => {
  const writeFile = fsp.writeFile.bind(fsp); let release, config;
  const gate = new Promise(resolve => { release = resolve; });
  let reachedWrite; const writing = new Promise(resolve => { reachedWrite = resolve; });
  t.mock.method(fsp, 'writeFile', async (file, ...args) => {
    config = file; reachedWrite(); await gate; return writeFile(file, ...args);
  });
  const states = [];
  const tor = createTor({ env: { UAI_KILO_TOR_BINARY: process.execPath }, onState: (state, message) => states.push(message) });
  t.after(() => { release(); return tor.close(); });
  const startup = assert.rejects(tor.ensure(), /stopped/);
  await writing;
  let closed = false; const closing = tor.close().then(() => { closed = true; });
  await new Promise(resolve => setImmediate(resolve));
  const closedBeforeStartup = closed;
  release(); await startup; await closing;
  assert.equal(closedBeforeStartup, false);
  assert.equal(states.includes('Connecting the Kilo tunnel.'), false);
  assert.equal(fs.existsSync(config), false);
});
