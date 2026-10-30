'use strict';
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const net = require('node:net');
const crypto = require('node:crypto');
const { spawn, execFile } = require('node:child_process');
const { promisify } = require('node:util');
const { once } = require('node:events');
const run = promisify(execFile);
const TOR_VERSION = '15.0.26';
const ARCHIVE = `tor-expert-bundle-windows-x86_64-${TOR_VERSION}.tar.gz`;
const ARCHIVE_HASH = 'c1988c701de2f24f7d098d1d6d7f507b58f27740d097f29c246e0524d639b252';
const ARCHIVE_URL = `https://archive.torproject.org/tor-package-archive/torbrowser/${TOR_VERSION}/${ARCHIVE}`;
const MAX_ARCHIVE_BYTES = 32 * 1024 * 1024;

async function reservePort() {
  const server = net.createServer(); server.listen(0, '127.0.0.1');
  await once(server, 'listening'); const port = server.address().port;
  await new Promise(resolve => server.close(resolve)); return port;
}
const digest = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const quote = value => '"' + value.replace(/\\/g, '/').replace(/["\r\n]/g, '') + '"';

// A verified archive is extracted into a fresh private session. Nothing executes
// from a cached extraction, and the cache never contains account credentials.
async function prepareBinary(session, signal, state, env) {
  const override = env.UAI_KILO_TOR_BINARY;
  if (override) {
    if (!path.isAbsolute(override) || !fs.statSync(override).isFile()) throw Error('UAI_KILO_TOR_BINARY must name a Tor executable');
    return { binary: override };
  }
  if (process.platform !== 'win32' || !['x64', 'arm64'].includes(process.arch)) {
    throw Error('Set UAI_KILO_TOR_BINARY to an installed Tor executable on this platform');
  }
  const cache = path.join(env.LOCALAPPDATA || os.tmpdir(), 'Project UAI', 'kilo-tunnel');
  await fsp.mkdir(cache, { recursive: true });
  const archivePath = path.join(cache, ARCHIVE);
  let bytes;
  try { if ((await fsp.stat(archivePath)).size <= MAX_ARCHIVE_BYTES) bytes = await fsp.readFile(archivePath); } catch {}
  if (!bytes || digest(bytes) !== ARCHIVE_HASH) {
    state('downloading', 'Downloading the verified Tor connection helper.');
    const response = await fetch(ARCHIVE_URL, { signal, redirect: 'error' });
    if (!response.ok) throw Error('The Tor helper download failed');
    const chunks = []; let size = 0;
    for await (const chunk of response.body) {
      size += chunk.length;
      if (size > MAX_ARCHIVE_BYTES) { await response.body.cancel().catch(() => {}); throw Error('Tor helper download is too large'); }
      chunks.push(chunk);
    }
    bytes = Buffer.concat(chunks);
    if (digest(bytes) !== ARCHIVE_HASH) throw Error('The Tor helper checksum did not match');
    const temporary = path.join(cache, crypto.randomUUID() + '.download');
    await fsp.writeFile(temporary, bytes, { flag: 'wx' });
    try { await fsp.rename(temporary, archivePath); }
    catch (error) { await fsp.rm(temporary, { force: true }); throw error; }
  }
  if (signal.aborted) throw Error('Kilo tunnel stopped');
  // tar only reads a pinned, checksum-verified archive; no user-supplied archive.
  const archive = path.join(session, ARCHIVE);
  await fsp.writeFile(archive, bytes);
  const bundle = path.join(session, 'bundle'); await fsp.mkdir(bundle);
  await run('tar.exe', ['-xzf', archive, '-C', bundle], { windowsHide: true, timeout: 30000, signal, maxBuffer: 65536 });
  return { binary: path.join(bundle, 'tor', 'tor.exe'), bundle };
}

function createTor({ env = process.env, onState = () => {} } = {}) {
  const controller = new AbortController();
  let child, control, session, ready, closing, pendingCommand, buffer = '', generation = 0, rotation, lastRotation = 0;
  controller.signal.addEventListener('abort', () => { control?.destroy(); child?.kill(); }, { once: true });
  function command(text) {
    if (!control || control.destroyed || pendingCommand) return Promise.reject(Error('Kilo tunnel control is unavailable'));
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { pendingCommand = null; reject(Error('Kilo tunnel control timed out')); control.destroy(); }, 5000);
      pendingCommand = { resolve: () => { clearTimeout(timer); pendingCommand = null; resolve(); },
        reject: () => { clearTimeout(timer); pendingCommand = null; reject(Error('Kilo tunnel control failed')); } };
      control.write(text + '\r\n');
    });
  }
  async function start() {
    onState('starting', 'Starting a private Kilo connection.');
    session = await fsp.mkdtemp(path.join(os.tmpdir(), 'project-uai-kilo-'));
    const startupTimer = setTimeout(() => controller.abort(), 150000);
    try {
      if (controller.signal.aborted) throw Error('Kilo tunnel stopped');
      const prepared = await prepareBinary(session, controller.signal, onState, env);
      if (controller.signal.aborted) throw Error('Kilo tunnel stopped');
      const port = await reservePort(), controlPort = await reservePort();
      const data = path.join(session, 'data'); await fsp.mkdir(data);
      const cookie = path.join(data, 'control.cookie'), config = path.join(session, 'torrc');
      const lines = ['ClientOnly 1', 'SocksPort 0', `HTTPTunnelPort 127.0.0.1:${port}`,
        `ControlPort 127.0.0.1:${controlPort}`, 'CookieAuthentication 1', `CookieAuthFile ${quote(cookie)}`,
        `DataDirectory ${quote(data)}`, `__OwningControllerProcess ${process.pid}`,
        'AvoidDiskWrites 1', 'MaxCircuitDirtiness 3600', 'Log notice stdout'];
      if (prepared.bundle) lines.push(`GeoIPFile ${quote(path.join(prepared.bundle, 'data/geoip'))}`, `GeoIPv6File ${quote(path.join(prepared.bundle, 'data/geoip6'))}`);
      await fsp.writeFile(config, lines.join('\n') + '\n');
      if (controller.signal.aborted) throw Error('Kilo tunnel stopped');
      onState('starting', 'Connecting the Kilo tunnel.');
      child = spawn(prepared.binary, ['-f', config], { windowsHide: true, cwd: session, stdio: ['ignore', 'pipe', 'pipe'] });
      await new Promise((resolve, reject) => {
        let done = false, output = '';
        const finish = error => { if (done) return; done = true; controller.signal.removeEventListener('abort', aborted); error ? reject(error) : resolve(); };
        const aborted = () => finish(Error('Kilo tunnel startup stopped or timed out'));
        controller.signal.addEventListener('abort', aborted, { once: true });
        child.once('error', () => finish(Error('Could not start the Tor helper')));
        child.once('exit', () => finish(Error('The Tor helper stopped during setup')));
        child.stdout.on('data', chunk => {
          output = (output + chunk.toString()).slice(-8192);
          if (/Bootstrapped 100%/.test(output)) finish();
          else if (/\[err\]/.test(output)) finish(Error('The Tor helper could not initialize'));
        });
        child.stderr.resume();
        if (controller.signal.aborted) aborted();
      });
      if (controller.signal.aborted) throw Error('Kilo tunnel stopped');
      control = net.connect(controlPort, '127.0.0.1');
      control.on('error', () => pendingCommand?.reject());
      control.on('close', () => {
        pendingCommand?.reject();
        if (!controller.signal.aborted) onState('failed', 'The Kilo tunnel control connection stopped. Restart the bridge.');
      });
      control.on('data', chunk => {
        buffer += chunk.toString();
        if (buffer.length > 65536) { control.destroy(); return; }
        let at;
        while ((at = buffer.indexOf('\r\n')) >= 0) {
          const line = buffer.slice(0, at); buffer = buffer.slice(at + 2);
          if (/^250 /.test(line)) pendingCommand?.resolve();
          else if (/^[45]\d\d /.test(line)) pendingCommand?.reject();
        }
      });
      await once(control, 'connect', { signal: controller.signal });
      const cookieBytes = await fsp.readFile(cookie);
      if (cookieBytes.length !== 32) throw Error('Invalid Tor control cookie');
      await command('AUTHENTICATE ' + cookieBytes.toString('hex'));
      await command('TAKEOWNERSHIP');
      child.once('exit', () => { if (!controller.signal.aborted) onState('failed', 'The Kilo tunnel stopped. Restart the bridge.'); });
      onState('ready', 'Kilo free requests can use the tunnel when their address allowance runs out.');
      return { port };
    } finally { clearTimeout(startupTimer); }
  }
  return {
    get generation() { return generation; },
    ensure() {
      if (controller.signal.aborted) return Promise.reject(Error('Kilo tunnel is stopped'));
      if (!ready) {
        ready = start();
        // Keep the startup promise separate: close waits for it before removing
        // the session, including when shutdown races with mkdir or extraction.
        ready.catch(() => this.close()).catch(() => {});
      }
      return ready;
    },
    async rotate(expected) {
      await this.ensure();
      if (controller.signal.aborted) throw Error('Kilo tunnel stopped');
      if (expected !== generation) return;
      if (rotation) return rotation;
      rotation = (async () => {
        const delay = Math.max(0, 15000 - (Date.now() - lastRotation));
        if (delay) await new Promise((resolve, reject) => {
          const abort = () => { clearTimeout(timer); reject(Error('Kilo tunnel stopped')); };
          const timer = setTimeout(() => { controller.signal.removeEventListener('abort', abort); resolve(); }, delay);
          controller.signal.addEventListener('abort', abort, { once: true });
        });
        if (controller.signal.aborted) throw Error('Kilo tunnel stopped');
        onState('rotating', 'Trying another Kilo connection after a quota response.');
        await command('SIGNAL NEWNYM'); generation++; lastRotation = Date.now();
        onState('ready', 'Kilo tunnel is ready. Each outbound address has its own allowance.');
      })().catch(error => {
        if (!controller.signal.aborted) onState('failed', 'The Kilo tunnel could not change its connection. Restart the bridge.');
        throw error;
      }).finally(() => { rotation = null; });
      return rotation;
    },
    close() {
      if (closing) return closing;
      closing = (async () => {
        controller.abort(); control?.destroy();
        await ready?.catch(() => {});
        if (child && child.exitCode === null && child.signalCode === null) {
          const exited = once(child, 'exit').catch(() => {}); child.kill();
          await Promise.race([exited, new Promise(resolve => setTimeout(resolve, 2000))]);
        }
        // session is created only by mkdtemp above, never by configuration.
        if (session) {
          const resolved = path.resolve(session), temporaryRoot = path.resolve(os.tmpdir());
          if (path.dirname(resolved) === temporaryRoot && /^project-uai-kilo-[\w-]+$/.test(path.basename(resolved))) {
            await fsp.rm(resolved, { recursive: true, force: true, maxRetries: 3, retryDelay: 100 }).catch(() => {});
          }
        }
      })(); return closing;
    }
  };
}
module.exports = { createTor, ARCHIVE_HASH, ARCHIVE_URL };
