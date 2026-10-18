# Project UAI 3.5.6 verification

Release: October 18, 2026. Client, bridge, Windows desktop and Android companion
share version 3.5.6; Android version code is 3. UI LIB remains 1.3.0 and SDK 1.0.0.
The release fixes mobile relay admission, deadline handling, pairing and job
ownership, and adds signed Android release packaging and automatic update
discovery/downloads. See the [changelog](../CHANGELOG.md) and
[companion update contract](../companion/UPDATES.md).

Source, documentation, tests and build inputs were manually audited before
building. Generated outputs were inspected before verification. Fixes followed
the same review order. The results below describe the final local artifacts;
native Android installation and mobile executor acceptance remain outstanding.

## Client and bridge

| Check | Result |
| --- | --- |
| Mobile deadlines | 15 cases, 54 assertions passed; integer wire budgets, negotiated unlimited default inference, finite explicit deadlines, same-job polling and cancellation |
| Mobile relay | 28 checks passed |
| Bridge lifecycle | 54 checks passed |
| Bridge previews | 7 cases, 25 assertions passed |
| Provider compatibility | 56 cases, 906 assertions passed |
| Runtime changelog and wide/narrow modal | 2 scenarios, 423 checks passed |
| Native static audit | 216 files, zero warnings |
| Official Luau compiler | 222 files compiled: 220 source modules, entry point and native bundle |
| Native bundle freshness | Passed |
| Public site and generated mirror | 174 tools, 21 groups, 8,361 static checks passed |
| Focused bridge Node tests | 30 tests passed |
| Bridge package freshness | Passed |
| Desktop bridge / web runtime / bridge installation | 40 / 22 / 70 Lua checks passed |

The final client uses build ID `3.5.6-a48e003980a18e6a` and contains 220 modules.
Offline harnesses and compiler checks establish behavior and syntax under their
fixtures; they do not establish native Roblox rendering or executor networking.

## Windows desktop

The packaged executable passed 36 self-test checks, 5 packaged smoke checks and
5 native window checks. Normal and compact native previews were inspected.
All 30 embedded bridge/client/license files match the reviewed release inputs,
including the final native bundle. The executable reports FileVersion 3.5.6.0.

## Android companion

The final `:app:testDebugUnitTest :app:lintRelease` run completed successfully.
All 68 JVM tests across nine suites passed with zero failures, errors or skips.
These cover request validation, leases, receipts, cancellation, server behavior,
release selection, bounded downloads, integrity checks, offline restoration,
installer ownership and interrupted-install recovery. GitHub API requests use
JSON Accept headers; binary release assets use the binary Accept header.

Android lint reported zero errors and 24 warnings, plus one informational item.
Warnings concern the battery-exemption request, the job-owned wake lock,
dependency upgrades, labels/resources/icons and Kotlin extension style. The app
is distributed through GitHub sideloading. Job leases and service teardown own
wake-lock release; a live Android run is still needed to confirm device behavior.

The first test run encountered ten setup failures from stale Kotlin incremental
test bytecode calling an obsolete test-helper constructor. Recompiling test
classes with incremental compilation disabled corrected the mismatch; bytecode
inspection confirmed the current constructor before the successful rerun. No
production source change was needed. An additional production reference audit
found no missing internal targets in 151 JVM classes or the APK's three DEX files.

The release packager's 10 tests passed, and its final `--check` passed against the
signed 3.5.6 APK. Inspection confirmed package `dev.projectuai.relay`, version
3.5.6/code 3, minimum Android API 26, target API 36, a non-debuggable build, the
private installer receiver and required updater/install classes. APK v2 signature
verification passed with one RSA-3072 production signer matching the committed
public certificate pin:

`ad7d215b8ad67ce70ae2ce89ad3ea959b68202b5c38e72141a68f7d54331f4b5`

The executor probe fixture passed three HTTP tests and 406 simulated Lua checks.
These are fixture checks, not a run inside a phone executor.

## Artifacts

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `uai.lua` | 3,400,568 | `6640d0c669c79833c982a58a587003a3e27f2c5d0dddb0918530bce31c9a6944` |
| `uai-bridge-package.json` | 1,189,254 | `2bae6a80c3e644594ad4ed80dd2b55badcbc63050a053806ea14f546a15d1cdc` |
| `UAI-Bridge-3.5.6-win-x64.exe` | 53,956,422 | `655ace947f7344e9b06b60e2976733af3a3d89c677259101abb1ffcba5ef0957` |
| `UAI-Relay-3.5.6.apk` | 9,606,374 | `985b0686f53c7cdc868c749a445c26e43e88c8affbdeda95c8b7214a65c44240` |

Release manifests and adjacent desktop/Android checksum files accompany these
artifacts. The Android signer is retained outside the repository. Existing
debug-signed installations require a one-time uninstall/reinstall and new pairing;
later production updates must retain the same signing key.

## OpenCode and native-device limits

OpenCode text, native tool invocation and tool-result replay succeeded on Windows
using the companion's actual OkHttp 4.12.0 library and desktop-compatible request
shape. Responses included `PONG`, the `uai_probe` tool call and `NEBULA_42` replay.
This establishes Windows JVM provider acceptance only. It does not verify Android
TLS, a mobile executor's loopback transport, or a complete phone session.

No physical Android device was attached. Emulator attempts failed before Android
boot and had no mobile executor; they supplied no mobile acceptance evidence.
No native Android package installation, upgrade, permission/cancellation flow,
process-death recovery or data-retention run is claimed. See the remaining
[device checks](../companion/UPDATES.md#device-acceptance) and
[mobile research](OPENCODE_MOBILE_RESEARCH.md). This historical scope predates the
later Delta phone report; mobile OpenCode now requires the UAI Relay app from
Discord, and Project UAI Free remains an alternative.
