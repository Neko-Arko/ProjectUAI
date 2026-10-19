# Project UAI 3.6.0 verification

Prepared October 19, 2026. This release addresses a reproduced Android relay
request-decoding failure, simplifies the companion interface, and updates desktop
OpenCode discovery, browser responses and the public website. Client, bridge, Windows
desktop and Android companion use version 3.6.0; Android version code is 5.

Source, documentation, tests and build inputs were manually reviewed before the
applicable builds and focused verification.
Generated outputs were inspected, and fixes were reviewed before retesting.
The full native suite was not run.

## Companion error: what was reproduced

The reported message included `Relay rejected the request (400): invalid executor
request` followed by `Inference was not resubmitted. (599)`. The relay emits the
inner 400 when the outer `/api/executor` JSON envelope cannot be decoded or its
schema is invalid. That happens before token validation and provider dispatch;
it is different from a bad-token refusal.

A JVM comparison used the previous released server source, renamed only to run
beside the current implementation, with real local HTTP sockets and a local
mock provider. It established this sequence:

1. Ordinary pairing and an authenticated status request succeed with status 200.
   The server records live client contact.
2. A valid large executor envelope, containing nested JSON, quotes, backslashes,
   newlines and Unicode, is sent with `Content-Encoding: gzip`.
3. The old server returns executor status 400 and the exact body
   `{"error":"invalid executor request"}`. No job is accepted and the mock
   provider receives no request.
4. The identical uncompressed envelope returns status 202. Exactly one local
   mock-provider request arrives, with its body preserved exactly.

This reproduces a concrete cause of the reported error and the apparent
"connected, then fails when sending" sequence. The old server decoded compressed
bytes as text. It does **not** prove that the user's Delta build compressed the
failing request: no capture from that phone was available, and executor
`HttpPost` signatures differ. No undocumented compression argument was added to
the client on the assumption that every executor implements it identically.

The current [request-body reader](../companion/app/src/main/kotlin/dev/projectuai/relay/server/RequestBody.kt)
accepts plain and gzip bodies while bounding received and expanded bytes before
JSON parsing. [Server regression tests](../companion/app/src/test/kotlin/dev/projectuai/relay/server/RelayServerTest.kt)
verify large nested JSON, preserved pairing, same-ID handling, direct and
executor routes, malformed compression, unsupported encoding and size refusal
without provider dispatch. Authentication, origin restrictions, cancellation and
the existing rule against resubmitting an uncertain inference remain covered.

The baseline is one additional passing test, separate from the 20 current
companion tests. It is a server-source comparison, not an old/new APK comparison
on Android. Local evidence: [baseline result](../refer/release-3.6.0/relay-baseline/baseline-result.xml)
and [baseline fixture](../refer/release-3.6.0/relay-baseline/source/dev/projectuai/relay/server/LegacyRelayCompressionTest.kt).
These evidence files are ignored and are not shipped; see the evidence note below.

## Focused verification

| Check | Result and scope |
| --- | --- |
| Companion discovery | 50 cases / 207 assertions passed |
| Mobile relay | 28 checks passed |
| Mobile deadlines | 15 cases / 54 assertions passed |
| Native static audit | 217 files; zero failures and warnings; not the full native suite |
| Desktop bridge discovery | 40 checks passed |
| Bridge installer | 70 checks passed |
| Runtime changelog and modal | 2 focused scenarios / 435 checks passed, including wide/narrow viewports and read markers |
| Client build and compiler | Final native bundle freshness passed; changed Lua source compiled with the official Luau compiler |
| Companion JVM server and presentation | 20 tests passed: 15 server tests and 5 status-presentation tests; zero failures, errors or skips |
| Previous server gzip comparison | 1 test passed; exact old error reproduced before dispatch, with an uncompressed control |
| Android release packager | 10 tests passed; final signed APK freshness check passed |
| OpenCode discovery and native adapter | 17 tests passed; 1 Unix-specific test skipped on Windows |
| Bridge updater and desktop Node tests | 21 tests passed; zero failures or skips |
| Final browser response/UI verification | 3 focused Chromium suites passed after the final cancellation-layout fix; desktop and narrow screenshots inspected |
| Final Windows executable | 36 self-tests, 5 packaged smoke checks and 5 native window checks passed; normal/compact previews inspected |
| Public website | 8,447 static checks passed; all focused Chromium checks passed at 320, 390, 768 and 1440px; screenshots inspected |

The companion results are recorded in the local
[server XML](../refer/release-3.6.0/relay-baseline/current-results/TEST-dev.projectuai.relay.server.RelayServerTest.xml),
[presentation XML](../refer/release-3.6.0/relay-baseline/current-results/TEST-dev.projectuai.relay.ui.RelayPresentationTest.xml)
and [Gradle log](../companion/.cache/tests-3.6.0.log).
The latest updater/desktop Node run is in
[bridge-release-tests-3.6.0-final.log](../companion/.cache/bridge-release-tests-3.6.0-final.log).

The presentation tests distinguish an active listener from authenticated Roblox
contact, expire stale contact without claiming that the listener stopped, and
keep pending Android installation from appearing ready for new messages. They
do not exercise Android input, service lifecycle or rendering.

## Bridge response presentation

The final `browser-response-layout.js`, `browser-tool-cards.js` and
`browser-visual-rework.js` suites passed against the reviewed bridge sources.
They exercise grouped answers and optional activity, formatted live and saved
reasoning, exact Copy actions, preserved selection, seven relay/provider error
classification cases, original diagnostic disclosure, draft preservation and
zero command/inference POSTs when reviewing a failed message. Real local SSE
interruption and HTTP cancellation verify terminal states without replay.

Stress coverage exceeds 450 nested entries and verifies bounded retention,
focused controls and cleanup. Desktop and 320/390px layouts, forced colors,
reduced motion and delayed-user ordering are covered. The final cancellation
layout keeps its complete error card above the composer for a reader following
the response. The earlier `browser.js` integration suite also passed, including
320-message history; it preceded the final reasoning/error iteration.

Local [verification notes](../refer/release-3.6.0/browser/verification.txt) and
[final screenshots](../refer/release-3.6.0/browser/reasoning-errors-final/) identify
the exact checks and reviewed images. Bridge package freshness passed. These
Chromium fixtures do not establish native Roblox rendering or executor input.

## Public website

The redesigned page uses a white monochrome palette, a projected 3D Canvas
centerpiece and animated SVG diagrams. The renderer caps drawing at 30 FPS and
device pixel ratio at 1–1.5, and suspends animation when offscreen or when the
document is hidden. Motion can be paused; reduced-motion settings start paused.
A static SVG remains available without Canvas. The recorded workflow has native
controls and does not autoplay when the page loads.

After source review, `node tools/build_site.js` generated the publishing mirror.
The generated HTML, styles, scripts, version and complete 174-tool/21-group
catalog were inspected. Root and `docs/` copies matched byte for byte.
`python test/site_static.py` passed 8,447 structural, link, contrast and catalog
checks. The focused `node test/site_browser.js` gate passed responsive geometry,
navigation and focus, exact loader copying and denied-clipboard fallback,
catalog search/category/risk filters, disclosure/reset behavior, example tabs,
official download targets, motion pause/resume and offscreen suspension. Canvas
failure and JavaScript-disabled scenarios retained usable content and navigation.

Desktop and narrow screenshots were inspected. One test-only search expectation
was corrected: searching "raycast" correctly finds both a matching tool name and
another tool whose description contains that word. The fixture was reviewed
before rerunning; no product change was needed. The browser gate checks release
link destinations without downloading binaries.

Local [verification notes](../refer/release-3.6.0/site-verification/verification.txt)
and [the desktop preview](../refer/release-3.6.0/website/monochrome-review/desktop-hero.png)
record the final design and checks. Other desktop/mobile previews are alongside
that image. Full-page captures can place the sticky navigation at their captured
scroll position; viewport screenshots were also reviewed.

## Windows desktop package

The standalone 3.6.0 executable was rebuilt after the final browser and client
changelog changes. All 30 embedded bridge/client/license files matched their
inventory; embedded bridge sources, web assets and the native client bundle
matched the reviewed release inputs. FileVersion is `3.6.0.0`.

`desktop/verify.ps1` copied only the executable to an isolated directory. Its
36 self-test checks, five packaged lifecycle smoke checks and five native window
checks passed, without adjacent runtime or bridge folders. Normal and compact
native launcher previews were inspected. These checks include native discovery,
integration switches, minimize/restore/close behavior, staged-update retention
and owned bridge shutdown. They use a simulated game connection.

Local evidence is in [the verification log](../companion/.cache/desktop-verify-3.6.0-final.log)
and `desktop/.build/verification/`. The final package does not bundle Node.js or
OpenCode; Node is detected or downloaded, and OpenCode uses an existing install.

## Companion build and visual review

Release assembly and vital release lint passed after the final large-text
adjustment. Package inspection confirmed `dev.projectuai.relay`, version
3.6.0/code 5, minimum API 26, target API 36 and no debuggable marker. `apksigner`
verified the existing production signer, whose public certificate SHA-256 is:

`ad7d215b8ad67ce70ae2ce89ad3ea959b68202b5c38e72141a68f7d54331f4b5`

The final `node tools/build_companion.js --apk
companion/app/build/outputs/apk/release/app-release.apk --check` passed. Build
evidence is in the local [final assembly log](../companion/.cache/assemble-3.6.0-final.log).

The interface now puts connection status and a single Start/Stop action first,
provides three short setup steps, and keeps connection settings and diagnostics
collapsed. Update installation and resume actions remain visible when needed.
Battery permission status refreshes when returning from Android settings.

Clearly labeled Chromium mocks were reviewed at 360 x 800 and at 360 x 640 with
150% text. Their colors, labels, spacing and typography dimensions follow the
Compose source. Review exposed crowded three-column message totals with enlarged
text; the Compose card now stacks those totals at font scales of 1.2 or greater.
The revised mocks were inspected and all five scenarios stayed within their
360-pixel content width. These checks assess design and density only; Android
text measurement, system insets, controls and accessibility input can differ.

Local visual evidence and its limitations are in the
[mock README](../companion/.cache/companion-preview/README.md), including
[normal text](../companion/.cache/companion-preview/companion-mock-360x800-connected-text1-full.png)
and [enlarged text](../companion/.cache/companion-preview/companion-mock-360x640-connected-text1.5-full.png).
These are not screenshots of a running APK.

## OpenCode live discovery

A read-only probe found the installed native OpenCode CLI version 2.0.32, started
its owned local API, and reached the ready state with ten free model IDs. The
probe then closed its owned process and left no private temporary directories.
It issued **zero provider inference requests**. This verifies installed-binary
discovery and the model-list API, not a model reply or phone compatibility.
Local evidence: [focused tests](../refer/release-3.6.0/opencode/focused-tests-serial.log)
and [live result](../refer/release-3.6.0/opencode/live-result.json).

## Artifact identities

The current native client bundle is build `3.6.0-c1be873b5ea20949`, with 221
modules. The Android package retains protocol 2 and the production signing key.

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `dist/uai.lua` | 3,416,928 | `057092fc13a7b830849f7b22a6e1d0243cbd3ade569c91ced46cf29f3ab79d15` |
| `UAI-Relay-3.6.0.apk` | 9,655,526 | `687575277cbe346c0eb5c0adcd11e39431e1386c26a1d8caebce239f5060448e` |
| `uai-bridge-package.json` | 1,234,850 | `3c28c08b17e3ce49aca315206cf3ebf6bd0d8f9bbe9408af41e9232d9e0bcc10` |
| `UAI-Bridge-3.6.0-win-x64.exe` | 53,968,710 | `a2728f4f1c1e7dc1d77e424b31014de455496e09a6c3d60b22db3a516649f32e` |

The companion release manifest and adjacent APK checksum file match the APK
identity above. These are local artifact results; they do not establish remote
publication or successful installation by an existing Android client.

## Native-device limits and evidence availability

No physical Android device was attached. Emulator 37.2.12 failed before Android
boot: its crash reporter recorded Windows exception `0x80000003`, and the
software-emulation attempt exited with `0xC0000005` (access violation). An older
official emulator 33.1.24 was downloaded and verified against Google's published
SHA-256. Both its default CPU and a conservative qemu64 configuration also exited
with `0xC0000005` before boot; the default CPU logged unsupported TCG AVX/F16C
features. The AMD A8-7600 host has virtualization enabled in firmware but lacks
the Android Emulator hypervisor driver. No drivers or host settings were changed.

There was no usable adb device. Neither the old nor the new APK was installed
for this comparison. Native Android rendering, Start/Stop and settings input,
installation/resume behavior, background survival, and the updated Delta
inference path were not verified on a phone. The user's earlier successful
OpenCode phone workaround remains the historical result recorded in
[the HttpPost correction notes](TESTING_RELAY_HTTPPOST.md); it is not a test of
the 3.6.0 APK. No Roblox Studio instance was connected for native client checks.

Paths under `companion/.cache/` and `refer/release-3.6.0/` are local, ignored
verification evidence. Links to them work in the release workspace but these
logs, fixtures and mock images are not committed or shipped with the release.
The committed test sources and artifact identities document the reproducible
scope. A fresh checkout must rerun the applicable checks rather than treating
missing ignored files as published evidence.
