'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const {
  checkPolicy, projectMetadata, inspectBadging, inspectSigner, createOutputs,
  readApk, inspectSnapshot, MAX_APK,
} = require('../tools/build_companion');

const pin = 'a'.repeat(64);
const metadata = { applicationId: 'dev.projectuai.relay', version: '1.2.3', versionCode: 7, minSdk: 26 };
const gradle = `defaultConfig {
  applicationId = "dev.projectuai.relay"
  minSdk = 26
  targetSdk = 36
  versionCode = 7
  versionName = "1.2.3"
}`;
const badging = `package: name='dev.projectuai.relay' versionCode='7' versionName='1.2.3' platformBuildVersionName='16'
sdkVersion:'26'
targetSdkVersion:'36'
application-label:'UAI Relay'
`;
const signature = `Verifies
Verified using v1 scheme (JAR signing): false
Verified using v2 scheme (APK Signature Scheme v2): true
Verified using v3 scheme (APK Signature Scheme v3): true
Number of signers: 1
Signer #1 certificate DN: CN=Project UAI Relay, O=Project Ptolemy
Signer #1 certificate SHA-256 digest: ${pin}
`;

function temporaryApk(t, bytes) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'uai-relay-package-test-'));
  const file = path.join(directory, 'input.apk');
  fs.writeFileSync(file, bytes);
  t.after(() => { if (fs.existsSync(file)) fs.unlinkSync(file); fs.rmdirSync(directory); });
  return file;
}

test('release policy requires the exact application and a lowercase certificate pin', () => {
  assert.equal(checkPolicy({ schema: 1, applicationId: metadata.applicationId, signerSha256: pin }).signerSha256, pin);
  for (const policy of [null, {}, { schema: 2, applicationId: metadata.applicationId, signerSha256: pin },
    { schema: 1, applicationId: 'dev.other.app', signerSha256: pin },
    { schema: 1, applicationId: metadata.applicationId, signerSha256: pin.toUpperCase() },
    { schema: 1, applicationId: metadata.applicationId, signerSha256: '../certificate' }]) {
    assert.throws(() => checkPolicy(policy));
  }
});

test('project metadata rejects dynamic, malformed and incompatible release values', () => {
  assert.deepEqual(projectMetadata(gradle), metadata);
  for (const source of [gradle.replace('dev.projectuai.relay', 'dev.other.app'),
    gradle.replace('versionCode = 7', 'versionCode = 0'),
    gradle.replace('versionCode = 7', 'versionCode = 2100000001'),
    gradle.replace('versionName = "1.2.3"', 'versionName = "../escape"'),
    gradle.replace('versionName = "1.2.3"', 'versionName = "1000000.2.3"'),
    gradle.replace('versionName = "1.2.3"', 'versionName = providers.gradleProperty("version").get()'),
    gradle.replace('minSdk = 26', 'minSdk = 25')]) assert.throws(() => projectMetadata(source));
});

test('release metadata inspection rejects debug and independently mismatched APKs', () => {
  assert.deepEqual(inspectBadging(badging, metadata), metadata);
  for (const output of [badging + 'application-debuggable\n',
    badging.replace('dev.projectuai.relay', 'dev.other.app'),
    badging.replace("versionCode='7'", "versionCode='6'"),
    badging.replace("versionName='1.2.3'", "versionName='1.2.2'"),
    badging.replace("sdkVersion:'26'", "sdkVersion:'27'"), '']) {
    assert.throws(() => inspectBadging(output, metadata));
  }
});

test('signing inspection requires verified v2, one signer and the pinned identity', () => {
  assert.equal(inspectSigner(signature, pin), pin);
  for (const output of [signature.replace('CN=Project UAI Relay', 'CN=Android Debug'),
    signature.replace(pin, 'b'.repeat(64)),
    signature.replace('v2 scheme (APK Signature Scheme v2): true', 'v2 scheme (APK Signature Scheme v2): false'),
    signature.replace('Number of signers: 1', 'Number of signers: 2'),
    signature + `Signer #2 certificate SHA-256 digest: ${pin}\n`,
    signature.replace('Number of signers: 1', ''), '']) assert.throws(() => inspectSigner(output, pin));
  assert.throws(() => inspectSigner(signature, ''));
});

test('package metadata hashes the unchanged bytes and generates deterministic asset names', () => {
  const apk = Buffer.from([0x50, 0x4b, 0, 255, 10, 13]);
  const outputs = createOutputs(apk, metadata, pin);
  assert.deepEqual(outputs.map(([name]) => name), ['UAI-Relay-1.2.3.apk', 'relay-release.json', 'UAI-Relay-1.2.3.apk.sha256']);
  assert.ok(outputs[0][1].equals(apk));
  const digest = crypto.createHash('sha256').update(apk).digest('hex');
  assert.deepEqual(JSON.parse(outputs[1][1]), {
    format: 'project-uai-relay-release', schema: 1, version: '1.2.3', versionCode: 7,
    platform: 'android', applicationId: metadata.applicationId, minSdk: 26, protocol: 2,
    package: { name: 'UAI-Relay-1.2.3.apk', bytes: apk.length, sha256: digest, signerSha256: pin },
  });
  assert.equal(outputs[2][1].toString(), `${digest}  UAI-Relay-1.2.3.apk\n`);
  assert.deepEqual(createOutputs(Buffer.from(apk), metadata, pin), outputs);
  assert.throws(() => createOutputs(Buffer.alloc(0), metadata, pin));
});

test('input bytes are bounded before allocation and directories are rejected', t => {
  const file = temporaryApk(t, Buffer.from('signed bytes'));
  assert.equal(readApk(file).toString(), 'signed bytes');
  assert.throws(() => readApk(path.dirname(file)));
  fs.truncateSync(file, 0);
  assert.throws(() => readApk(file));
  fs.truncateSync(file, MAX_APK + 1);
  assert.throws(() => readApk(file));
});

test('metadata and signature inspection use the original snapshot after source replacement', t => {
  const file = temporaryApk(t, Buffer.from('signed original'));
  const apk = readApk(file);
  let inspected;
  inspectSnapshot(apk, snapshot => {
    inspected = snapshot;
    fs.writeFileSync(file, Buffer.from('other source now'));
    assert.equal(fs.readFileSync(snapshot).toString(), 'signed original');
  });
  assert.equal(createOutputs(apk, metadata, pin)[0][1].toString(), 'signed original');
  assert.equal(fs.existsSync(inspected), false);
  assert.equal(fs.existsSync(path.dirname(inspected)), false);
});

test('same-length snapshot tampering is rejected and temporary bytes are removed', () => {
  let inspected;
  assert.throws(() => inspectSnapshot(Buffer.from('original'), snapshot => {
    inspected = snapshot;
    fs.chmodSync(snapshot, 0o600);
    fs.writeFileSync(snapshot, Buffer.from('modified'));
  }), /snapshot changed/);
  assert.equal(fs.existsSync(path.dirname(inspected)), false);
});

test('failed native inspection cleans its snapshot and preserves the failure', () => {
  let inspected;
  assert.throws(() => inspectSnapshot(Buffer.from('apk fixture'), snapshot => {
    inspected = snapshot;
    throw Error('signature rejected');
  }), /signature rejected/);
  assert.equal(fs.existsSync(path.dirname(inspected)), false);
});

test('committed public policy matches the Android application metadata', () => {
  const policy = checkPolicy(JSON.parse(fs.readFileSync(path.join(__dirname, '../companion/release-policy.json'), 'utf8')));
  const current = projectMetadata(fs.readFileSync(path.join(__dirname, '../companion/app/build.gradle.kts'), 'utf8'));
  assert.equal(policy.applicationId, current.applicationId);
});
