# Project UAI 3.2.0 verification

Release: October 15, 2026. Scope: Project UAI Free, the direct desktop OpenCode
workaround, optional installed CLI bridge, retirement of the OpenCode proxy,
mobile guidance, Discord support, current model pricing/limits and client/desktop
release artifacts, including separate OpenCode Go subscription routing.

The existing direct desktop path is required independently of the bridge. Keep
compatibility tool declarations and the Chat/Responses fallback. The CLI binary
must remain separately installed. Only the proper AgentRouter proxy domain is
supported. Session-only test credentials must not enter source or artifacts.

Changed inputs are manually reviewed before build; generated outputs are inspected
before focused tests. Every fix is reviewed before rebuilding and retesting.
The full native suite is excluded by request. UI LIB and the SDK remain unchanged.

## Live evidence

- The intentionally distributed HCNSEC credential returned `/models` HTTP 200 in
  1.58 seconds, including `auto`. An `auto` request returned a real `check_status`
  call in 6.18 seconds, selecting `agnes-3.0-flash`. The session-only HCNSEC key was
  not used for product defaults.
- The deployed proper-domain proxy returned `/health` HTTP 200 with only
  `/agentrouter/v1`; the retired OpenCode route returned 410. Authenticated
  AgentRouter `/models` returned HTTP 200 with four models.
- Native CLI and keyed direct desktop results, including model-specific failures,
  are recorded in [OpenCode validation](OPENCODE_3.2_VALIDATION.md). Synthetic
  protocol checks do not establish native Roblox/executor behavior.
- The official Go documentation was read. Public discovery returned 37 Go models.
  Four minimal keyed DeepSeek requests across canonical/legacy Go routes returned
  HTTP 400 requiring Global regions, including two canonical retries after the
  user reported changing the workspace setting. The reported subscription 403 was
  not reproduced. Live Go text/tool/result success remains unverified; no account
  settings were changed by the probes. Offline Go tool/result routing passed.

## Focused verification

Client verification targets provider defaults/editor/model selection, proper-domain
proxy recovery and migration, direct OpenCode identity/tools/protocol fallback,
mobile refusal guidance, cancellation, desktop capability discovery and first-run
introduction. Bridge verification targets CLI lifecycle, loopback authentication,
tool handoff, streaming, cancellation, direct fallback and packaging. Desktop
verification targets the standalone executable and its embedded inventory.

These focused checks passed after source review and the applicable client build.
The final Go build repeated Go routing/discovery, provider compatibility, transport,
support, proxy, editor, model picker, pricing, source, compiler and freshness checks.
Other results below are the earlier completed release checks.

| Command | Result |
| --- | --- |
| `luajit test/provider_compatibility.lua` | 56 cases, 906 assertions; final Go build |
| `luajit test/opencode_go.lua` | 8 cases, 118 assertions; canonical/legacy Chat, Responses, Messages, tool replay and refusal guidance |
| `luajit test/opencode_go_registry.lua` | 4 cases, 53 assertions; route, identity, discovery and native-free isolation |
| `luajit test/provider_transport.lua` | 21 cases, 554 assertions |
| `luajit test/free_provider.lua` | 8 cases, 68 assertions |
| `luajit test/provider_editor.lua` | 19 cases, 150 assertions |
| `luajit test/provider_support.lua` | 1 case, 38 assertions |
| `luajit test/provider_proxy.lua` | 15 cases, 111 assertions |
| `luajit test/opencode_bridge.lua` | 9 assertions |
| `luajit test/desktop_bridge.lua` | 40 checks |
| `luajit test/bridge_lifecycle.lua` | 54 checks |
| `luajit test/model_picker.lua` | 31 checks |
| `luajit test/run.lua --native first-run` | 1 scenario, 19 checks |
| `luajit test/check.lua --native` | 207 files, 206 modules, no failures or warnings |
| `luajit test/model_pricing.lua` | 9 cases, 69 assertions |
| `node test/model_pricing.js` | 11 normalization assertions |
| `luajit test/context_compaction.lua` | 185 checks |
| `luajit test/model_effort.lua` | 3 cases, 35 assertions |
| `luajit test/run.lua --native "what a model accepts" "universal model pricing"` | 2 selected scenarios, 32 checks |
| Official `luau-compile.exe --null` | 31 pre-Go files; final 13 affected source/bundle files compiled with Luau 0.742 |
| `luajit tools/bundle.lua --native --check` | Bundle, manifest and embedded icons current |
| `node tools/sync_pricing.js --check` | Generated metadata matches the reviewed snapshot |
| `node tools/build_site.js --check` | Version 3.2.0, 174 tools, 21 groups; root/docs match |
| `python test/site_static.py` | 8,361 checks |

The first proxy check exposed a test fixture comparing a pre-save URL with a
normalized URL. The fixture now snapshots after Save; manual review preceded the
successful rerun. Mobile refusal coverage establishes no alternate protocol or
proxy recovery; it does not claim that every generic HTTP retry is disabled.

One old pricing assertion assumed an unlisted direct Anthropic id was unknown
without specifying an endpoint, although an exact OpenCode entry exists. The
assertion now supplies the Anthropic endpoint; the two selected scenarios passed
after reviewing this test-only fix.

The pricing snapshot has 1,334 entries across 13 providers, refreshed at
`2026-10-15T11:42:05.985Z`. Source URLs and hashes are retained in
`tools/data/model_metadata.json`. The ten CLI free-model entries use the live
2.0.27 catalog. Prices match the provider and exact model id, including documented
cache prices and context tiers. Unknown gateway costs remain unknown. Included
Free access requires consistent effective authentication before its cost is zero.
The 38 Go metadata entries came from the same verified models.dev source hash;
Go limits remain separate and subscription charges are not inferred from Zen rates.

## Bridge and desktop verification

The selected bridge suites passed across the reviewed iterations:

| Suite | Result |
| --- | --- |
| `bridge/tests/opencode-native.test.js` | 8 checks, including total input/output and cache accounting |
| `bridge/tests/security.test.js` | 10 checks |
| `bridge/tests/updater.test.js` | 17 checks, including the pinned 3.1 updater staging and activating 3.2 |
| `bridge/tests/streaming.test.js` | 22 checks |
| `bridge/tests/desktop.test.js` | 2 checks |
| `bridge/tests/opencode.test.js` | 1 Responses wire check |
| `node tools/build_bridge.js --check` | 19-file release package current |
| `bridge/tests/browser-ui-audit.js` | Browser workflows passed; screenshots manually inspected |

The final six-suite bridge pass completed 60 checks. Go exclusions include both
canonical and legacy URLs even when the requested model also appears in the free
native catalog. The final browser audit included AgentRouter exact-route matching,
retired OpenCode disclosure, and both Go bases; mobile disclosure screenshots were
manually inspected. Desktop compilation then embedded the final client build.
`desktop/verify.ps1` passed 28 self-tests and five lifecycle smoke checks; the native
launcher screenshot was inspected at `desktop/.build/verification/launcher.png`.

The final browser audit used an isolated `playwright-core` installation under
the ignored desktop cache and the existing Chromium browser. Checks covered
desktop/mobile layouts and error help. An expected security error string was
updated for its Discord suffix. A static-junction fixture was corrected to use
the production package generator after helper inlining; the affected suite passed
after reviewing the fix.

To preserve upgrades from 3.1, the release generator embeds the new helper modules
as ordinary CommonJS closures inside the original allowed runtime filenames.
Source checkouts and desktop payloads retain separate modules. The real pinned
3.1 updater accepted, staged and activated the generated 3.2 package.

## Artifacts and limits

- Client: `dist/uai.lua`, 211 modules, 3,203,115 bytes.
  Build id: `3.2.0-602069c33d8df5c8`.
  SHA-256: `f104c5476f145beabc0547392d50566719d4cb253acb37b5df59c9f9e613ecc3`.
- Bridge: `dist/uai-bridge-package.json`, 19 files, 508,501 bytes.
  SHA-256: `f3cad8c6e023442a935b2e0e9920d14c63e2895f52b639c7fa92f6ad0630c31c`.
- Desktop: `desktop/release/UAI-Bridge-3.2.0-win-x64.exe`, 53,047,899 bytes.
  SHA-256: `1c884e0a6ccef3690020679cbcb24c7e3925210e929be33a9fd1e15607c548d7`.
  All 26 embedded payload hashes match; the embedded client matches the final
  bundle. Neither Node nor the OpenCode CLI binary is packaged.
- Official Luau 0.742 Windows archive was fetched from `luau-lang/luau` and
  verified against its published SHA-256:
  `1114966cd8198f407069f07e8b4e6bacf2ded933e4a57d6ddc75617969278c75`.
- The final credential scan covered 87 changed source, documentation, fixture and
  generated files, 19 decoded bridge-package files, the 26 desktop payload files
  plus manifest, and exact private-key matching against the EXE. No private
  handover credential or unexpected long API key was found. The deliberately
  public community key and short synthetic test credentials remain allowed.

The full native suite was not run. Mock/Chromium checks do not establish native
Roblox rendering or executor HTTP behavior. Live free-model results are dated
observations; the direct Step 5 request received an upstream availability refusal.
Native cancellation was checked before output, not mid-token. Mobile OpenCode free
access was unsupported at this time; a later correction establishes that mobile
OpenCode requires the UAI Relay app from Discord. No release was published or
deployed by this work.
