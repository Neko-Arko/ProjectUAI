'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { findBinary } = require('../opencode');

function installation(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'uai-opencode-discovery-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  function file(relative, contents = Buffer.from([0x4d, 0x5a, 0, 0])) {
    const target = path.join(root, relative);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, contents, { mode: 0o755 });
    return fs.realpathSync(target);
  }
  return { root, file };
}

test('Windows quoted PATH and case-insensitive environment keys locate a native CLI', t => {
  const f = installation(t);
  const expected = f.file('Program Files/OpenCode/resources/opencode-cli.exe');
  f.file('Program Files/OpenCode/OpenCode.exe');
  f.file('Program Files/OpenCode/resources/app.asar', 'desktop');
  const folder = path.join(f.root, 'Program Files', 'OpenCode');
  assert.equal(findBinary({ Path: 'relative;"' + folder + '";' }, 'win32'), expected);
  assert.equal(findBinary({ localappdata: f.root, uai_opencode_disabled: '1', Path: folder }, 'win32'), null);
});

test('Windows npm global installs work without npm on the desktop process PATH', t => {
  const f = installation(t);
  f.file('Roaming/npm/opencode.cmd', '@echo this shim must never run');
  const expected = f.file('Roaming/npm/node_modules/@opencode/cli/bin/opencode.exe');
  f.file('Roaming/npm/node_modules/opencode-ai/bin/opencode.exe');
  assert.equal(findBinary({ APPDATA: path.join(f.root, 'Roaming'), PATH: '' }, 'win32'), expected,
    'the current scoped v2 package takes precedence over the legacy package in the same installation');
});

test('Bun, active nvm and custom npm prefixes resolve their installed native package', t => {
  const f = installation(t);
  const locations = [
    [{ USERPROFILE: f.root }, '.bun/install/global/node_modules/@opencode/cli/bin/opencode.exe'],
    [{ BUN_INSTALL: path.join(f.root, 'custom-bun') }, 'custom-bun/install/global/node_modules/@opencode/cli/bin/opencode.exe'],
    [{ NVM_SYMLINK: path.join(f.root, 'nvm-node') }, 'nvm-node/node_modules/@opencode/cli/bin/opencode.exe'],
    [{ npm_config_prefix: path.join(f.root, 'custom-npm') }, 'custom-npm/node_modules/@opencode/cli/bin/opencode.exe'],
  ];
  for (const [env, relative] of locations) {
    const expected = f.file(relative);
    assert.equal(findBinary(env, 'win32'), expected);
  }
});

test('older package launchers resolve platform dependencies without running JavaScript or shell shims', t => {
  const f = installation(t), prefix = path.join(f.root, 'npm');
  f.file('npm/opencode.cmd', '@echo this shim must never run');
  f.file('npm/node_modules/@opencode/cli/bin/opencode.cjs', 'throw Error("must not execute")');
  const expected = f.file('npm/node_modules/@opencode/cli/node_modules/@opencode/cli-windows-arm64/bin/opencode.exe');
  assert.equal(findBinary({ PATH: prefix }, 'win32', 'arm64'), expected);
  const legacy = f.file('legacy/node_modules/opencode-windows-x64-baseline/bin/opencode.exe');
  assert.equal(findBinary({ PATH: path.join(f.root, 'legacy') }, 'win32', 'x64'), legacy);
});

test('Desktop installations support all-user Windows and current macOS Resources locations', t => {
  const f = installation(t);
  const windows = f.file('Program Files/OpenCode/resources/opencode-cli.exe');
  assert.equal(findBinary({ ProgramFiles: path.join(f.root, 'Program Files') }, 'win32'), windows);
  const mac = f.file('Home/Applications/OpenCode.app/Contents/Resources/opencode-cli', Buffer.from([0xcf, 0xfa, 0xed, 0xfe]));
  assert.equal(findBinary({ HOME: path.join(f.root, 'Home') }, 'darwin'), mac);
});

test('Unix npm symlink layouts resolve native payloads and require executable permissions', { skip: process.platform === 'win32' }, t => {
  const f = installation(t);
  f.file('prefix/bin/opencode', '#!/bin/sh\nexit 87');
  const expected = f.file('prefix/lib/node_modules/@opencode/cli/bin/opencode', Buffer.from([0x7f, 0x45, 0x4c, 0x46]));
  assert.equal(findBinary({ PATH: path.join(f.root, 'prefix', 'bin') }, 'linux'), expected);
  fs.chmodSync(expected, 0o644);
  assert.equal(findBinary({ PATH: path.join(f.root, 'prefix', 'bin') }, 'linux'), null);
});

test('explicit overrides stay authoritative and scripts or Desktop GUI launchers are never selected', t => {
  const f = installation(t);
  const expected = f.file('native/opencode.exe');
  const shim = f.file('shim/opencode.exe', '@echo not a native binary');
  const gui = f.file('desktop/opencode.exe');
  f.file('desktop/resources/app.asar', 'desktop');
  for (const override of ['relative.exe', shim, path.join(f.root, 'absent.exe')]) {
    assert.equal(findBinary({ UAI_OPENCODE_BINARY: override, PATH: path.dirname(expected) }, 'win32'), null);
  }
  assert.equal(findBinary({ UAI_OPENCODE_BINARY: '"' + expected + '"' }, 'win32'), expected);
  assert.equal(findBinary({ PATH: path.dirname(gui) }, 'win32'), null);
  assert.equal(findBinary({ PATH: ';.;relative;' }, 'win32'), null);
});
