#!/usr/bin/env node
'use strict';

// Package a previously reviewed, signed Android APK. Never signs or publishes.
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '..');
const APP_ID = 'dev.projectuai.relay';
const MANIFEST = 'relay-release.json';
const MAX_APK = 150 * 1024 * 1024;
const SHA256 = /^[a-f0-9]{64}$/;
const VERSION = /^(0|[1-9]\d{0,5})\.(0|[1-9]\d{0,5})\.(0|[1-9]\d{0,5})$/;
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const json = value => Buffer.from(JSON.stringify(value, null, 2) + '\n');

function checkPolicy(policy) {
  if (policy?.schema !== 1 || policy.applicationId !== APP_ID || !SHA256.test(policy.signerSha256 ?? '')) {
    throw Error('Configure the reviewed public release certificate in companion/release-policy.json');
  }
  return policy;
}

function projectMetadata(source) {
  const block = source.match(/defaultConfig\s*\{([\s\S]*?)\}/)?.[1] ?? '';
  const applicationId = block.match(/\bapplicationId\s*=\s*"([^"]+)"/)?.[1];
  const version = block.match(/\bversionName\s*=\s*"([^"]+)"/)?.[1];
  const versionCode = Number(block.match(/\bversionCode\s*=\s*(\d+)/)?.[1]);
  const minSdk = Number(block.match(/\bminSdk\s*=\s*(\d+)/)?.[1]);
  if (applicationId !== APP_ID || !VERSION.test(version ?? '') || !Number.isSafeInteger(versionCode) || versionCode < 1 || versionCode > 2100000000 || !Number.isInteger(minSdk) || minSdk < 26 || minSdk > 100) {
    throw Error('Unsupported Android project release metadata');
  }
  return { applicationId, version, versionCode, minSdk };
}

function inspectBadging(output, expected) {
  if (/^application-debuggable\b/m.test(output)) throw Error('Debuggable APKs cannot become update releases');
  const packageLine = output.match(/^package:\s+(.+)$/m)?.[1] ?? '';
  const applicationId = packageLine.match(/\bname='([^']+)'/)?.[1];
  const version = packageLine.match(/\bversionName='([^']+)'/)?.[1];
  const versionCode = Number(packageLine.match(/\bversionCode='(\d+)'/)?.[1]);
  const minSdk = Number(output.match(/^sdkVersion:'(\d+)'/m)?.[1]);
  if (applicationId !== expected.applicationId || version !== expected.version ||
      versionCode !== expected.versionCode || minSdk !== expected.minSdk) {
    throw Error('APK metadata does not match the reviewed Android project');
  }
  return { applicationId, version, versionCode, minSdk };
}

function inspectSigner(output, expected) {
  if (!SHA256.test(expected ?? '')) throw Error('An expected release certificate fingerprint is required');
  if (/\bCN\s*=\s*Android Debug\b/i.test(output)) throw Error('The Android debug certificate cannot sign update releases');
  if (!/^Number of signers:\s*1\s*$/m.test(output) ||
      !/^Verified using v2 scheme[^\r\n]*:\s*true\s*$/m.test(output)) {
    throw Error('A single verified APK Signature Scheme v2 signer is required for Android 8 support');
  }
  const signers = [...output.matchAll(/^Signer #\d+ certificate SHA-256 digest:\s*([a-fA-F0-9]{64})\s*$/gm)];
  if (signers.length !== 1 || signers[0][1].toLowerCase() !== expected) throw Error('APK signing certificate does not match the pinned release identity');
  return expected;
}

function createOutputs(apk, metadata, signerSha256) {
  if (!Buffer.isBuffer(apk) || apk.length < 1 || apk.length > MAX_APK) throw Error('APK exceeds the release size limit');
  const name = `UAI-Relay-${metadata.version}.apk`;
  const digest = hash(apk);
  const manifest = { format: 'project-uai-relay-release', schema: 1, version: metadata.version,
    versionCode: metadata.versionCode, platform: 'android', applicationId: metadata.applicationId,
    minSdk: metadata.minSdk, protocol: 2,
    package: { name, bytes: apk.length, sha256: digest, signerSha256 } };
  return [[name, apk], [MANIFEST, json(manifest)], [name + '.sha256', Buffer.from(`${digest}  ${name}\n`)]];
}

function androidTools(sdk) {
  const directory = path.join(sdk, 'build-tools');
  const versions = fs.readdirSync(directory).filter(name => VERSION.test(name)).sort((a, b) => {
    const aa = a.split('.').map(Number), bb = b.split('.').map(Number);
    return bb[0] - aa[0] || bb[1] - aa[1] || bb[2] - aa[2];
  });
  for (const version of versions) {
    const base = path.join(directory, version);
    const aapt = path.join(base, process.platform === 'win32' ? 'aapt.exe' : 'aapt');
    const signer = path.join(base, 'lib', 'apksigner.jar');
    if (fs.existsSync(aapt) && fs.existsSync(signer)) return { aapt, signer };
  }
  throw Error('Android SDK build-tools with aapt and apksigner are required');
}

function run(executable, args, label) {
  const result = spawnSync(executable, args, { encoding: 'utf8', timeout: 30000, maxBuffer: 2 * 1024 * 1024, windowsHide: true });
  if (result.error || result.status !== 0) throw Error(`${label} failed; no release assets were written`);
  return result.stdout;
}

function readApk(apkPath) {
  const stat = fs.lstatSync(apkPath);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size < 1 || stat.size > MAX_APK) throw Error('Input must be a regular signed APK within 150 MiB');
  const fd = fs.openSync(apkPath, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0));
  try {
    const opened = fs.fstatSync(fd);
    if (!opened.isFile() || opened.size !== stat.size || opened.dev !== stat.dev || opened.ino !== stat.ino) throw Error('APK changed before it could be read');
    const bytes = Buffer.alloc(opened.size);
    let offset = 0;
    while (offset < bytes.length) {
      const count = fs.readSync(fd, bytes, offset, bytes.length - offset, offset);
      if (!count) throw Error('APK changed while it was read');
      offset += count;
    }
    if (fs.readSync(fd, Buffer.alloc(1), 0, 1, offset)) throw Error('APK changed while it was read');
    return bytes;
  } finally { fs.closeSync(fd); }
}

function inspectSnapshot(apk, inspect) {
  // Inspect exactly the bytes we package, even if Gradle replaces its source APK.
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'uai-relay-release-'));
  const snapshot = path.join(directory, 'verified.apk');
  try {
    fs.chmodSync(directory, 0o700);
    fs.writeFileSync(snapshot, apk, { flag: 'wx', mode: 0o400 });
    inspect(snapshot);
    if (!fs.readFileSync(snapshot).equals(apk)) throw Error('APK verification snapshot changed');
  } finally {
    if (fs.existsSync(snapshot)) { fs.chmodSync(snapshot, 0o600); fs.unlinkSync(snapshot); }
    fs.rmdirSync(directory);
  }
}

function main(args = process.argv.slice(2)) {
  const options = {};
  for (let index = 0; index < args.length; index++) {
    const key = args[index];
    if (key === '--check') { options.check = true; continue; }
    if (!['--apk', '--out', '--sdk', '--signer-sha256'].includes(key) || !args[index + 1]) throw Error('Usage: node tools/build_companion.js --apk SIGNED_APK [--sdk SDK] [--out DIR] [--check]');
    options[key.slice(2)] = args[++index];
  }
  if (!options.apk) throw Error('Provide the already signed release APK with --apk');
  const policy = checkPolicy(JSON.parse(fs.readFileSync(path.join(ROOT, 'companion/release-policy.json'), 'utf8')));
  if (options['signer-sha256'] && options['signer-sha256'] !== policy.signerSha256) throw Error('Supplied signer does not match the committed public release pin');
  const sdk = options.sdk || process.env.ANDROID_HOME || process.env.ANDROID_SDK_ROOT ||
    (process.platform === 'win32' && process.env.LOCALAPPDATA ? path.join(process.env.LOCALAPPDATA, 'Android/Sdk') : '');
  if (!sdk) throw Error('Set ANDROID_HOME or provide --sdk');
  const apkPath = path.resolve(options.apk);
  const apk = readApk(apkPath);
  const metadata = projectMetadata(fs.readFileSync(path.join(ROOT, 'companion/app/build.gradle.kts'), 'utf8'));
  const { aapt, signer } = androidTools(path.resolve(sdk));
  const java = process.env.JAVA_HOME ? path.join(process.env.JAVA_HOME, 'bin', process.platform === 'win32' ? 'java.exe' : 'java') : 'java';
  inspectSnapshot(apk, snapshot => {
    inspectBadging(run(aapt, ['dump', 'badging', snapshot], 'APK metadata inspection'), metadata);
    inspectSigner(run(java, ['-jar', signer, 'verify', '--verbose', '--print-certs', snapshot], 'APK signature verification'), policy.signerSha256);
  });
  const outputs = createOutputs(apk, metadata, policy.signerSha256);
  const out = path.resolve(options.out || path.join(ROOT, 'companion/release'));
  if (options.check) {
    for (const [name, bytes] of outputs) {
      const target = path.join(out, name);
      if (!fs.existsSync(target) || !fs.lstatSync(target).isFile() || fs.lstatSync(target).isSymbolicLink() || !fs.readFileSync(target).equals(bytes)) {
        throw Error('Stale or missing Android release asset: ' + name);
      }
    }
    process.stdout.write(`Android ${metadata.version} (${metadata.versionCode}) release assets are current.\n`);
    return;
  }
  fs.mkdirSync(out, { recursive: true });
  // Check every destination before changing any existing local asset.
  for (const [name] of outputs) {
    const destination = path.join(out, name);
    if (fs.existsSync(destination) && (!fs.lstatSync(destination).isFile() || fs.lstatSync(destination).isSymbolicLink())) throw Error('Unexpected release output: ' + name);
  }
  for (const [name, bytes] of outputs) {
    const destination = path.join(out, name);
    const temporary = path.join(out, '.' + name + '.' + crypto.randomUUID() + '.tmp');
    try { fs.writeFileSync(temporary, bytes, { flag: 'wx' }); fs.renameSync(temporary, destination); }
    finally { if (fs.existsSync(temporary)) fs.unlinkSync(temporary); }
  }
  process.stdout.write(`Packaged Android ${metadata.version} (${metadata.versionCode}), ${apk.length} bytes, signer ${policy.signerSha256}.\n`);
  process.stdout.write(`Inspect ${out} before verification. Nothing was published.\n`);
}

module.exports = { checkPolicy, projectMetadata, inspectBadging, inspectSigner, createOutputs, readApk, inspectSnapshot, MAX_APK, main };
if (require.main === module) { try { main(); } catch (error) { process.stderr.write(error.message + '\n'); process.exitCode = 1; } }
