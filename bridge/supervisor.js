'use strict';

// This process remains owned by the terminal/native desktop for its lifetime.
// Only its non-detached IPC worker changes during an idle update. The token is
// session memory: automatic updates retain it, manual starts generate a new one.
const path = require('node:path');
const crypto = require('node:crypto');
const { fork } = require('node:child_process');
const { EventEmitter } = require('node:events');
const { Updater, compare } = require('./updater');
const RELEASE = require('./release');

class Supervisor extends EventEmitter {
  constructor({ entry = path.join(__dirname, 'server.js'), args = process.argv.slice(2), updater = new Updater(),
    enabled = process.env.UAI_BRIDGE_TEST_NO_UPDATES !== '1', initialDelayMs = 30000, intervalMs = 15 * 60 * 1000,
    idleRetryMs = 5000, readyTimeoutMs = 15000, stdout = process.stdout, stderr = process.stderr, onExit = () => {} } = {}) {
    super();
    this.base = { entry: path.resolve(entry), version: RELEASE.version };
    this.args = args; this.updater = updater; this.enabled = enabled;
    this.initialDelayMs = initialDelayMs; this.intervalMs = intervalMs; this.idleRetryMs = idleRetryMs; this.readyTimeoutMs = readyTimeoutMs;
    this.stdout = stdout; this.stderr = stderr; this.onExit = onExit;
    this.token = crypto.randomBytes(32).toString('hex'); this.current = this.base;
    this.status = { state: 'current', currentVersion: this.base.version };
    this.stopped = false; this.transition = false; this.checking = false; this.staged = null;
    this.controller = new AbortController(); this.failedKeys = new Set();
  }
  setStatus(state, error) {
    this.status = { state, currentVersion: this.current.version,
      ...(this.staged ? { availableVersion: this.staged.version } : {}), ...(error ? { error } : {}) };
    this.send({ type: 'update-state', update: this.status }); this.emit('status', this.status);
  }
  send(message) {
    const child = this.worker?.child;
    if (child?.connected) child.send(message, () => {});
  }
  spawn(release) {
    const child = fork(release.entry, this.args, { execPath: process.execPath, cwd: path.dirname(release.entry),
      env: { ...process.env, UAI_BRIDGE_WORKER: '1', UAI_BRIDGE_SESSION_TOKEN: this.token },
      stdio: ['pipe', 'pipe', 'pipe', 'ipc'], windowsHide: true });
    const worker = { child, release, expectedExit: false };
    this.worker = worker;
    // Every child's stdio/IPC stays attached to us. The worker also exits on IPC
    // disconnect, including a hard parent kill on Windows.
    // A saved candidate may fail before its fallback starts. Do not expose its
    // desktop {type:error} first: the native owner would abort the whole start.
    // Startup output is bounded and released only after valid IPC readiness.
    const output = [];
    let outputBytes = 0;
    for (const [stream, destination] of [[child.stdout, this.stdout], [child.stderr, this.stderr]]) {
      stream.on('data', chunk => {
        if (!destination) return;
        if (worker.confirmed) destination.write(chunk);
        else if (outputBytes + chunk.length <= 65536) { output.push([destination, chunk]); outputBytes += chunk.length; }
      });
    }
    worker.flush = () => { for (const [destination, chunk] of output) destination.write(chunk); output.length = 0; };
    child.stdin.on('error', () => {});
    worker.exited = new Promise(resolve => child.once('close', (code, signal) => resolve({ code, signal })));
    child.once('exit', (code, signal) => {
      worker.idleReply?.(false);
      this.emit('worker-exit', { pid: child.pid, code, signal });
      if (!worker.expectedExit && !this.transition && !this.stopped) {
        this.stop().finally(() => this.onExit(code || 1));
      }
    });
    worker.ready = new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(Error('Updated bridge did not become ready')), this.readyTimeoutMs);
      const settle = (error, value) => { clearTimeout(timer); error ? reject(error) : resolve(value); };
      child.once('error', error => settle(error));
      child.once('exit', () => settle(Error('Bridge worker exited before becoming ready')));
      child.on('message', message => {
        if (message?.type === 'ready') {
          if (message.version !== release.version || message.token !== this.token || message.updateProtocol !== RELEASE.updateProtocol) {
            settle(Error('Updated bridge reported incompatible readiness')); return;
          }
          worker.confirmed = true; worker.flush();
          this.send({ type: 'update-state', update: this.status });
          settle(null, message); this.emit('worker-ready', { pid: child.pid, ...message });
        }
        if (message?.type === 'update-idle' && worker.idleReply && message.requestId === worker.idleRequestId) worker.idleReply(message.idle === true);
        if (message?.type === 'check-update' && typeof message.requestId === 'string') {
          const reply = () => this.send({ type: 'check-result', requestId: message.requestId, update: this.status });
          this.checkNow().then(reply, reply);
        }
      });
    });
    return worker;
  }
  async stopWorker(worker) {
    if (!worker) return;
    worker.expectedExit = true;
    worker.idleReply?.(false);
    if (worker.child.exitCode !== null || worker.child.signalCode !== null) { await worker.exited; return; }
    if (worker.child.connected) worker.child.send({ type: 'stop' }, () => {});
    worker.child.stdin.end();
    const timer = setTimeout(() => worker.child.kill(), 3000);
    try { await worker.exited; } finally { clearTimeout(timer); }
  }
  async start() {
    this.transition = true;
    const cached = this.enabled ? this.updater.active(this.base.version) : null;
    this.current = cached || this.base;
    if (this.enabled) this.updater.prune(cached ? [cached.key] : []);
    this.setStatus('current');
    let worker = this.spawn(this.current);
    try { await worker.ready; }
    catch (error) {
      await this.stopWorker(worker);
      if (!cached || this.stopped) { worker.flush(); this.transition = false; throw error; }
      this.failedKeys.add(cached.key); this.current = this.base;
      this.setStatus('error', 'The saved bridge update could not start; using the installed version.');
      worker = this.spawn(this.base);
      try { await worker.ready; } catch (failure) { await this.stopWorker(worker); worker.flush(); this.transition = false; throw failure; }
    }
    this.transition = false;
    if (this.stopped) { await this.stopWorker(worker); return; }
    if (this.enabled) this.checkTimer = setTimeout(() => this.scheduleCheck(), this.initialDelayMs);
    return this;
  }
  async scheduleCheck() {
    try { await this.checkUpdates(); }
    finally { if (!this.stopped) this.checkTimer = setTimeout(() => this.scheduleCheck(), this.intervalMs); }
  }
  // A desktop-initiated check answers with the outcome of the check itself, not
  // the restart: applying a staged release replaces the worker whose HTTP reply
  // is still in flight, so application is re-negotiated once that worker is idle.
  async checkNow() {
    if (this.stopped || !this.enabled || this.checking || this.transition || this.staged) return this.status;
    clearTimeout(this.checkTimer);
    try { await this.checkUpdates({ apply: false }); }
    finally {
      if (!this.stopped) this.checkTimer = setTimeout(() => this.scheduleCheck(), this.intervalMs);
      if (this.staged) this.idleTimer = setTimeout(() => this.applyStaged(), this.idleRetryMs);
    }
    return this.status;
  }
  async checkUpdates({ apply = true } = {}) {
    if (this.stopped || this.checking || this.transition || this.staged) return this.status;
    this.checking = true; this.setStatus('checking');
    let staged = false;
    try {
      const release = await this.updater.check(this.current.version, this.controller.signal);
      if (this.stopped) return this.status;
      if (!release || this.failedKeys.has(release.key) || compare(release.version, this.current.version) <= 0) this.setStatus('current');
      else { this.staged = release; staged = true; this.setStatus('staged'); }
    } catch {
      // Never relay provider/URL/error payloads from a network response into UI.
      if (!this.stopped) this.setStatus('error', 'Could not verify the bridge update. The current version keeps running; another check will follow.');
    } finally { this.checking = false; }
    if (staged && apply && !this.stopped) await this.applyStaged();
    return this.status;
  }
  requestIdle(worker) {
    if (!worker?.child.connected || worker.child.exitCode !== null || worker.child.signalCode !== null) return Promise.resolve(false);
    return new Promise(resolve => {
      const timer = setTimeout(() => finish(false), 3000);
      const finish = idle => { clearTimeout(timer); worker.idleReply = null; resolve(idle); };
      worker.idleRequestId = crypto.randomUUID(); worker.idleReply = finish;
      this.send({ type: 'prepare-update', requestId: worker.idleRequestId });
    });
  }
  async applyStaged() {
    if (!this.staged || this.stopped || this.transition) return false;
    clearTimeout(this.idleTimer);
    this.transition = true;
    const previous = this.current, oldWorker = this.worker, candidate = this.staged;
    let candidateWorker;
    try {
      // Recheck after staging and before executing cached code. Idle admission
      // closes atomically inside the worker before it acknowledges this request.
      this.updater.verify(candidate.key);
      if (!await this.requestIdle(oldWorker)) {
        if (oldWorker.child.exitCode !== null || oldWorker.child.signalCode !== null) throw Error('Bridge exited during idle negotiation');
        this.send({ type: 'cancel-update' });
        if (!this.stopped) this.idleTimer = setTimeout(() => this.applyStaged(), this.idleRetryMs);
        return false;
      }
      if (this.stopped) return false;
      this.setStatus('restarting');
      await this.stopWorker(oldWorker);
      if (this.stopped) return false;
      candidateWorker = this.spawn(candidate);
      await candidateWorker.ready;
      if (this.stopped) return false;
      // The active pointer only moves after the new server owns the port and
      // reports the expected protocol, version and session token.
      this.updater.activate(candidate);
      this.updater.prune([candidate.key]);
      this.current = candidate; this.staged = null; this.setStatus('updated');
      return true;
    } catch {
      this.failedKeys.add(candidate.key); this.staged = null;
      if (candidateWorker) await this.stopWorker(candidateWorker);
      if (this.stopped) return false;
      this.current = previous;
      if (oldWorker.child.exitCode !== null || oldWorker.child.signalCode !== null) {
        const rollback = this.spawn(previous);
        try { await rollback.ready; }
        catch { await this.stopWorker(rollback); await this.stop(); this.onExit(1); return false; }
      } else this.send({ type: 'cancel-update' });
      this.setStatus('error', 'The bridge update could not start. The previous version is running.');
      return false;
    } finally { this.transition = false; }
  }
  async stop() {
    if (this.stopPromise) return this.stopPromise;
    this.stopped = true; this.controller.abort();
    clearTimeout(this.checkTimer); clearTimeout(this.idleTimer);
    this.stopPromise = this.stopWorker(this.worker);
    return this.stopPromise;
  }
}

function start(options) {
  const supervisor = new Supervisor({ ...options, onExit: code => process.exit(code) });
  let stopping = false;
  const stop = () => {
    if (stopping) return;
    stopping = true; supervisor.stop().finally(() => process.exit(0));
  };
  process.on('SIGINT', stop); process.on('SIGTERM', stop);
  process.stdout.on('error', stop); process.stderr.on('error', stop);
  if (supervisor.args.includes('--desktop')) {
    const control = require('node:readline').createInterface({ input: process.stdin });
    control.on('line', line => {
      if (line.length > 256) return;
      try { if (JSON.parse(line).type === 'stop') stop(); } catch { /* Ignore malformed control messages. */ }
    });
    control.on('close', stop);
  }
  supervisor.start().catch(() => supervisor.stop().finally(() => process.exit(1)));
  return supervisor;
}

module.exports = { Supervisor, start };
