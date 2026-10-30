'use strict';

// Downloads only assets attached to stable releases of the official repository.
// Code is verified in an isolated user cache; the installed/source tree is never
// an update destination. No npm, shell, archive extractor, or credentials needed.
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const https = require('node:https');
const RELEASE = require('./release');

const REPO = 'Project-Ptolemy/ProjectUAI';
const RELEASES_URL = `https://api.github.com/repos/${REPO}/releases?per_page=100`;
const MANIFEST_NAME = 'bridge-release.json';
const PACKAGE_NAME = 'uai-bridge-package.json';
const MAX_PACKAGE = 32 * 1024 * 1024;
const MAX_FILES_BYTES = 20 * 1024 * 1024;
// Keep the published root inventory compatible with the 3.1 updater. The
// release builder embeds new helper modules into these existing entry files.
const ROOT_FILES = ['server.js', 'inference.js', 'picture-store.js', 'launcher.js', 'release.js', 'updater.js', 'supervisor.js'];
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const json = value => Buffer.from(JSON.stringify(value) + '\n');

function version(value) {
  if (typeof value !== 'string' || !/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(value)) throw Error('Invalid stable bridge version');
  const parts = value.split('.').map(Number);
  if (parts.some(n => !Number.isSafeInteger(n))) throw Error('Invalid stable bridge version');
  return parts;
}
function compare(a, b) {
  const left = version(a), right = version(b);
  for (let i = 0; i < 3; i++) if (left[i] !== right[i]) return left[i] > right[i] ? 1 : -1;
  return 0;
}
function validPath(value) {
  if (typeof value !== 'string' || !value || value.length > 180 || value.includes('\\') ||
      value.split('/').some(part => !part || part === '.' || part === '..' || /[<>:"|?*\x00-\x1f\x7f]/.test(part) ||
        /[. ]$/.test(part) || /^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(part))) throw Error('Invalid bridge update path');
  if (!ROOT_FILES.includes(value) && !/^web\/.+\.(?:html|css|js|svg|png|ico|jpg|jpeg|webp|woff2?|txt|json)$/i.test(value)) throw Error('Unexpected bridge update file');
  return value;
}
function contained(root, relative) {
  const target = path.resolve(root, relative);
  if (!target.startsWith(path.resolve(root) + path.sep)) throw Error('Bridge update path escaped cache');
  return target;
}
function noLinks(target) {
  // Check ancestors too: a cache root substituted with a junction is not safe.
  let current = path.resolve(target);
  for (;;) {
    try { if (fs.lstatSync(current).isSymbolicLink()) throw Error('Bridge update cache contains a symbolic link'); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    const parent = path.dirname(current);
    if (parent === current) return;
    current = parent;
  }
}
function readJson(file, limit) {
  noLinks(file);
  const stat = fs.statSync(file);
  if (!stat.isFile() || stat.size > limit) throw Error('Invalid bridge update metadata size');
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}
function checkManifest(value, expectedVersion) {
  if (!value || value.format !== 'project-uai-bridge-release' || value.schema !== 1 ||
      value.version !== expectedVersion || value.protocol !== RELEASE.protocol ||
      value.updateProtocol !== RELEASE.updateProtocol || !Number.isSafeInteger(value.minNode) || value.minNode < 18 ||
      value.minNode > Number(process.versions.node.split('.')[0]) || value.package?.name !== PACKAGE_NAME ||
      !Number.isSafeInteger(value.package.bytes) || value.package.bytes <= 0 || value.package.bytes > MAX_PACKAGE ||
      !/^[a-f0-9]{64}$/.test(value.package.sha256 || '')) throw Error('Incompatible or invalid bridge release manifest');
  version(value.version);
  return value;
}
function checkPackage(bytes, manifest) {
  checkManifest(manifest, manifest?.version);
  if (bytes.length !== manifest.package.bytes || hash(bytes) !== manifest.package.sha256) throw Error('Bridge package SHA-256 or size mismatch');
  const value = JSON.parse(bytes.toString('utf8'));
  if (!value || value.format !== 'project-uai-bridge-package' || value.schema !== 1 || value.version !== manifest.version ||
      !Array.isArray(value.files) || !value.files.length || value.files.length > 200) throw Error('Invalid bridge package');
  const seen = new Set(); let total = 0;
  const files = value.files.map(file => {
    validPath(file?.path);
    if (seen.has(file.path.toLowerCase())) throw Error('Duplicate bridge update path');
    seen.add(file.path.toLowerCase());
    if (!Number.isSafeInteger(file.bytes) || file.bytes < 0 || file.bytes > MAX_FILES_BYTES ||
        !/^[a-f0-9]{64}$/.test(file.sha256 || '') || typeof file.data !== 'string' || file.data.length > MAX_PACKAGE) throw Error('Invalid bridge file metadata');
    const data = Buffer.from(file.data, 'base64'); total += data.length;
    if (data.toString('base64') !== file.data || data.length !== file.bytes || hash(data) !== file.sha256 || total > MAX_FILES_BYTES) throw Error('Bridge file SHA-256 or size mismatch');
    return { path: file.path, bytes: data.length, sha256: file.sha256, data };
  });
  if ([...ROOT_FILES, 'web/index.html'].some(name => !seen.has(name))) throw Error('Bridge package is missing required files');
  const canonical = json({ format: value.format, schema: value.schema, version: value.version,
    files: files.map(file => ({ path: file.path, bytes: file.bytes, sha256: file.sha256, data: file.data.toString('base64') })) });
  if (!canonical.equals(bytes)) throw Error('Bridge package must use the canonical release format');
  return files;
}

function trustedUrl(value) {
  const url = new URL(value);
  if (url.protocol !== 'https:' || url.port || url.username || url.password || url.hash ||
      !['api.github.com', 'github.com', 'release-assets.githubusercontent.com', 'objects.githubusercontent.com'].includes(url.hostname)) throw Error('Untrusted bridge release download URL');
  return url;
}
function download(url, maxBytes, signal) {
  const deadline = Date.now() + 20000;
  function request(address, redirects) {
    return new Promise((resolve, reject) => {
      let parsed;
      try { parsed = trustedUrl(address); } catch (error) { reject(error); return; }
      if (signal?.aborted) { reject(Error('Bridge update stopped')); return; }
      const remaining = deadline - Date.now();
      if (remaining <= 0) { reject(Error('Bridge update download timed out')); return; }
      const req = https.get(parsed, { headers: { 'User-Agent': 'ProjectUAI-Bridge/' + RELEASE.version,
        Accept: 'application/json', 'Accept-Encoding': 'identity' }, signal }, res => {
        if ([301, 302, 303, 307, 308].includes(res.statusCode)) {
          res.resume();
          if (redirects >= 4 || !res.headers.location) { reject(Error('Invalid bridge release redirect')); return; }
          let next;
          try { next = new URL(res.headers.location, parsed).href; } catch (error) { reject(error); return; }
          request(next, redirects + 1).then(resolve, reject); return;
        }
        if (res.statusCode !== 200) { res.resume(); reject(Error('Bridge release service returned HTTP ' + res.statusCode)); return; }
        if (Number(res.headers['content-length']) > maxBytes) { res.destroy(); reject(Error('Bridge release download is too large')); return; }
        const chunks = []; let size = 0;
        res.on('data', chunk => {
          size += chunk.length;
          if (size > maxBytes) { res.destroy(); reject(Error('Bridge release download is too large')); return; }
          chunks.push(chunk);
        });
        res.on('error', reject);
        res.on('end', () => resolve(Buffer.concat(chunks)));
      });
      const timer = setTimeout(() => req.destroy(Error('Bridge update download timed out')), remaining);
      req.on('error', reject); req.on('close', () => clearTimeout(timer));
    });
  }
  return request(url, 0);
}
function releaseCandidates(releases, currentVersion) {
  if (!Array.isArray(releases)) throw Error('Invalid bridge release list');
  const candidates = [];
  for (const release of releases.slice(0, 100)) {
    if (!release || release.draft !== false || release.prerelease !== false || !Array.isArray(release.assets)) continue;
    const match = /^(?:bridge-)?v(\d+\.\d+\.\d+)$/.exec(release.tag_name || '');
    if (!match) continue;
    let newer; try { newer = compare(match[1], currentVersion) > 0; } catch { continue; }
    if (!newer) continue;
    const assets = {};
    for (const name of [MANIFEST_NAME, PACKAGE_NAME]) {
      const matches = release.assets.filter(asset => asset.name === name);
      const expected = `https://github.com/${REPO}/releases/download/${release.tag_name}/${name}`;
      if (matches.length === 1 && matches[0].browser_download_url === expected) assets[name] = expected;
    }
    if (assets[MANIFEST_NAME] && assets[PACKAGE_NAME]) candidates.push({ version: match[1], assets });
  }
  return candidates.sort((a, b) => compare(b.version, a.version));
}
function cacheDirectory(installation = process.env.UAI_BRIDGE_INSTALLATION_ID || process.argv[1]) {
  const userData = process.platform === 'win32' ? (process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local')) :
    process.platform === 'darwin' ? path.join(os.homedir(), 'Library', 'Caches') : (process.env.XDG_CACHE_HOME || path.join(os.homedir(), '.cache'));
  let identity = path.resolve(installation || __filename);
  if (process.platform === 'win32') identity = identity.toLowerCase();
  return path.join(userData, 'ProjectUAI', 'bridge-updates', hash(identity).slice(0, 32));
}

class Updater {
  constructor({ cacheDir = cacheDirectory(), fetchBytes = download } = {}) {
    this.cacheDir = path.resolve(cacheDir); this.fetchBytes = fetchBytes;
  }
  async check(currentVersion, signal) {
    const releases = JSON.parse((await this.fetchBytes(RELEASES_URL, 2 << 20, signal)).toString('utf8'));
    const candidate = releaseCandidates(releases, currentVersion)[0];
    if (!candidate) return null;
    const manifest = checkManifest(JSON.parse((await this.fetchBytes(candidate.assets[MANIFEST_NAME], 64 << 10, signal)).toString('utf8')), candidate.version);
    const bytes = await this.fetchBytes(candidate.assets[PACKAGE_NAME], MAX_PACKAGE, signal);
    if (signal?.aborted) throw Error('Bridge update stopped');
    const files = checkPackage(bytes, manifest);
    return this.stage(manifest, files);
  }
  stage(manifest, files) {
    const key = manifest.version + '-' + manifest.package.sha256;
    const target = contained(this.cacheDir, 'versions/' + key);
    noLinks(target);
    if (fs.existsSync(target)) {
      try { return this.verify(key); }
      catch {
        // A corrupt saved copy must not prevent a later valid download repairing
        // this version. Preserve it outside versions without following its files.
        const quarantine = contained(this.cacheDir, '.invalid-' + crypto.randomUUID());
        noLinks(target); noLinks(quarantine); fs.renameSync(target, quarantine);
      }
    }
    fs.mkdirSync(path.dirname(target), { recursive: true, mode: 0o700 });
    const stage = contained(this.cacheDir, '.stage-' + crypto.randomUUID());
    fs.mkdirSync(stage, { mode: 0o700 });
    try {
      for (const file of files) {
        const dest = contained(stage, validPath(file.path));
        fs.mkdirSync(path.dirname(dest), { recursive: true, mode: 0o700 });
        fs.writeFileSync(dest, file.data, { flag: 'wx', mode: 0o600 });
      }
      fs.writeFileSync(path.join(stage, '.release.json'), json({ manifest,
        files: files.map(({ path, bytes, sha256 }) => ({ path, bytes, sha256 })) }), { flag: 'wx', mode: 0o600 });
      fs.renameSync(stage, target);
      return this.verify(key);
    } finally {
      // Only this invocation's fresh staging folder is ever removed.
      noLinks(stage);
      if (fs.existsSync(stage)) fs.rmSync(stage, { recursive: true });
    }
  }
  verify(key) {
    if (typeof key !== 'string' || !/^\d+\.\d+\.\d+-[a-f0-9]{64}$/.test(key)) throw Error('Invalid cached bridge release');
    const dir = contained(this.cacheDir, 'versions/' + key);
    const { manifest, files } = readJson(path.join(dir, '.release.json'), 128 << 10);
    checkManifest(manifest, key.slice(0, key.indexOf('-')));
    if (key !== manifest.version + '-' + manifest.package.sha256 || !Array.isArray(files) || files.length > 200) throw Error('Invalid cached bridge files');
    const seen = new Set(); let total = 0;
    // Reconstruct the archive hash as well as each individual file hash. This
    // ties the cached inventory to the package accepted from the release asset.
    const archived = files.map(file => {
      validPath(file?.path);
      if (seen.has(file.path.toLowerCase())) throw Error('Duplicate cached bridge file');
      seen.add(file.path.toLowerCase());
      const source = contained(dir, file.path); noLinks(source);
      const stat = fs.statSync(source);
      if (!stat.isFile() || !Number.isSafeInteger(file.bytes) || file.bytes < 0 || stat.size !== file.bytes || stat.size > MAX_FILES_BYTES) throw Error('Cached bridge file size mismatch');
      const data = fs.readFileSync(source); total += data.length;
      if (hash(data) !== file.sha256 || total > MAX_FILES_BYTES) throw Error('Cached bridge file SHA-256 mismatch');
      return { path: file.path, bytes: file.bytes, sha256: file.sha256, data: data.toString('base64') };
    });
    if ([...ROOT_FILES, 'web/index.html'].some(name => !seen.has(name))) throw Error('Cached bridge is incomplete');
    const archive = json({ format: 'project-uai-bridge-package', schema: 1, version: manifest.version, files: archived });
    if (archive.length !== manifest.package.bytes || hash(archive) !== manifest.package.sha256) throw Error('Cached bridge package SHA-256 mismatch');
    // An extra source file could influence Node resolution without appearing in
    // the manifest. Reject any extra files, directories, or links in the cache.
    function walk(folder, prefix = '') {
      for (const entry of fs.readdirSync(folder, { withFileTypes: true })) {
        const name = prefix + entry.name;
        if (entry.isSymbolicLink()) throw Error('Cached bridge contains a link');
        if (entry.isDirectory()) {
          if (![...seen].some(file => file.startsWith(name.toLowerCase() + '/'))) throw Error('Unexpected cached bridge directory');
          walk(path.join(folder, entry.name), name + '/');
        } else if (!entry.isFile() || (name !== '.release.json' && !files.some(file => file.path === name))) throw Error('Unexpected cached bridge file');
      }
    }
    walk(dir);
    return { key, version: manifest.version, entry: path.join(dir, 'server.js') };
  }
  active(baseVersion) {
    try {
      const pointer = readJson(path.join(this.cacheDir, 'active.json'), 4096);
      const release = this.verify(pointer.key);
      return compare(release.version, baseVersion) > 0 ? release : null;
    } catch { return null; }
  }
  activate(release) {
    this.verify(release.key);
    noLinks(this.cacheDir);
    const pointer = contained(this.cacheDir, 'active.json'), temporary = contained(this.cacheDir, '.active-' + crypto.randomUUID());
    noLinks(pointer);
    try {
      fs.writeFileSync(temporary, json({ key: release.key }), { flag: 'wx', mode: 0o600 });
      fs.renameSync(temporary, pointer);
    } finally { if (fs.existsSync(temporary)) fs.unlinkSync(temporary); }
  }
  prune(keepKeys = []) {
    // Applied updates leave predecessor versions and quarantine folders behind.
    // Entries still referenced stay; older unreferenced ones re-download when
    // needed. Recently written entries may belong to a concurrent process of
    // this installation, so they always survive.
    try {
      const keep = new Set(keepKeys.filter(key => typeof key === 'string' && /^\d+\.\d+\.\d+-[a-f0-9]{64}$/.test(key)));
      const cutoff = Date.now() - 3600000;
      const versions = path.join(this.cacheDir, 'versions');
      if (fs.existsSync(versions)) {
        for (const entry of fs.readdirSync(versions)) {
          if (keep.has(entry)) continue;
          const target = contained(versions, entry);
          try { if (fs.statSync(target).mtimeMs >= cutoff) continue; } catch { continue; }
          try { noLinks(target); fs.rmSync(target, { recursive: true, force: true }); } catch { /* best effort */ }
        }
      }
      for (const entry of fs.readdirSync(this.cacheDir)) {
        if (!/^\.(?:invalid|stage|active)-/.test(entry)) continue;
        const target = contained(this.cacheDir, entry);
        try { if (fs.statSync(target).mtimeMs >= cutoff) continue; } catch { continue; }
        try { noLinks(target); fs.rmSync(target, { recursive: true, force: true }); } catch { /* best effort */ }
      }
    } catch { /* pruning never affects availability */ }
  }
}

module.exports = { Updater, RELEASES_URL, MANIFEST_NAME, PACKAGE_NAME, ROOT_FILES, MAX_PACKAGE,
  checkManifest, checkPackage, compare, version, validPath, trustedUrl, releaseCandidates, cacheDirectory, hash, json };
