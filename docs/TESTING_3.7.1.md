# Project UAI 3.7.1 verification

Prepared October 25, 2026. The Roblox client joins the bridge, web UI and Android
companion (version code 8) at 3.7.1; the Windows desktop remains 3.7.0.
The client update finishes UI polish and adds independently editable numbered
API keys. The existing bridge and Android patch accepts every Kilo free-model
spelling (`:free`, `/free`, `-free`) in quota recovery, so `reflection/beam-free`
and `openrouter/free` no longer bypass the Kilo tunnel.

Changed source, documentation, tests and build inputs were manually reviewed
before builds. Generated outputs were inspected before verification, and fixes
were reviewed before retesting. The client checks exercise the offline harness
and compiler; visual previews approximate layout. The separate bridge and
companion checks retain their live Kilo evidence. None establishes native
Roblox rendering or host input behavior.

## Client UI and API keys

Provider configuration preserves existing key pools while exposing API key 1,
API key 2 and further entries with individual Replace and Remove actions. Add
API key appends credentials. Invalid or cancelled replacements preserve the
pool; saved-provider edits and new-provider drafts remain isolated until Save.
Saved secrets are masked, including short keys. The setup guide starts expanded.

Shared modal padding and fitted content heights cover log details, context
breakdown, Discord, tutorial and donation. The model catalogue keeps its own
scrolling viewport while preserving focused search and fixed controls. Settings,
Code, tool and conversation surfaces retain the existing application design.

The following records the completed UI verification before changing the client
version metadata to 3.7.1. The final implementation bundle in that pass was
`3.7.0-c40d0186198c0bd4`; these results do not claim a post-version-update rerun.

| Check | Result |
| --- | --- |
| Source and artifact review | Changed source, tests and documentation manually audited; native bundle rebuilt and generated outputs inspected before verification |
| Static client checks | 233 files checked, including 232 modules and the bootstrap; no violations |
| Official Luau compiler | Native bundle compilation passed |
| Main native scenarios | 137 scenarios run; 134 passed initially. Three assertions still described the old model chip, one-line model rows and segmented auth selector. After manual review, the expectations were updated to the new visible behavior; those three scenarios passed all 48 checks on rerun |
| Code, picker and settings fixtures | 16 focused suites passed, totaling 9,150 checks/assertions: Code interactions, layout, selection and contrast; mobile Code/reviews; native improvements/performance; model desktop/touch/temperature; shared and panel layout; UI audit; settings entry; conversation folders |
| Individual API key entries | 7 cases, 37 assertions passed: middle-key replacement, append/remove, short-key masking, rejected values, cancellation, saved-provider isolation and resumed new-provider drafts |
| Provider editor and setup | 23 editor cases / 169 assertions and 8 setup cases / 38 assertions passed after the final key-masking change; setup guidance, drafts, discovery and validation remain covered |
| Modal content layout | 12 cases, 82 assertions passed across 1000×800, 320×568 and 844×220 layouts; related invitation, tutorial, support and log fixtures passed |
| Visual review | 14 mock/Chromium previews inspected: log details, context, Discord, tutorial, donation, provider keys and setup guide, each at desktop 1280×840 and phone 390×844 |

Local logs and preview artifacts for that pass are under
`refer/ui-polish-finish-20261025/`. The previews do not verify native Roblox
glyph rendering, pointer selection, mobile keyboards or executor input.

### Final 3.7.1 packaging checks

After updating the bootstrap version and in-app changelog, the native bundle
was rebuilt as `3.7.1-6fa62e1ae970c9d6`. The bundle, manifest, website version
markers and generated documentation mirror were inspected before verification.

- Changelog history, unread markers and wide/narrow rendering: 2 scenarios,
  492 checks passed.
- Build identity and safe client replacement: 45 checks passed.
- Release UI fixtures: 22 checks passed.
- Static client validation: 233 files, 232 modules, no warnings or failures.
- Official Luau compilation and deterministic bundle freshness passed.
- Website freshness passed; both copies report 3.7.1, 182 tools and 24 groups.
  Public-site structural and contrast validation passed all 8,703 checks.

## Kilo rule change

`bridge/kilo.js` `eligible()` and the Android `KiloRoute.eligible` now accept a
model id that ends in `free` behind a separator (`:free`, `/free`, `-free`)
instead of only `kilo-auto/free` and `:free`. The separator requirement keeps
unrelated ids such as `free`, `carefree` or `kilo-auto/free-tier` out. The
first send stays direct; only a complete anonymous
`PROMOTION_MODEL_LIMIT_REACHED` refusal still triggers the tunnel, rotation and
cooldown, unchanged.

## Bridge and companion checks

| Check | Result |
| --- | --- |
| Live Kilo catalog (October 25) | 401 models; every zero-priced free route ends in `free` behind `:`, `/` or `-`; `reflection/beam-free` is the only dash-spelled free route; `kilo-auto/free` and `openrouter/free` use the slash |
| Direct limit reproduction | `reflection/beam-free` POST from the limited local address returned HTTP 429 `PROMOTION_MODEL_LIMIT_REACHED`, matching the reported client log |
| Live tunnel recovery | Real Tor bootstrap from the cached verified archive in 23.4 s; exit `185.220.101.108` versus direct `136.158.2.56`; the same `reflection/beam-free` request completed HTTP 200 through the tunnel with the expected reply, served as `reflection/beam` |
| Eligibility after the fix | `accepts()` true for `reflection/beam-free`, `openrouter/free`, `kilo-auto/free` and `:free` routes; false for `reflection/beam-1.0-501b-a23b` |
| Full bridge suite | 176 tests: 173 passed, 0 failures, 0 cancellations, 3 conditional/platform skips |
| Kilo focused fixtures | Extended with the `-free`/`/free` spellings and the separator-negative cases; unchanged quota, rotation, cooldown and cancellation fixtures all pass |
| Android unit tests | Full `testDebugUnitTest` suite: 88 tests across 12 classes, 0 failures, 0 errors, 0 skipped, including the extended `KiloRouteTest` anonymous-scope cases; `lintRelease` clean |
| Signed companion APK | 3.7.1, version code 8, 39,830,600 bytes; `tools/build_companion.js` verified badging and the pinned production signer (`ad7d215b…`) and generated the manifest, APK and checksum; deterministic asset check passed |
| Bridge package | 21 files, 1,334,506 package bytes; embedded `server.js` inspected: new rule present, old `endsWith(':free')` rule absent; deterministic freshness check passed |
| Release compatibility | One `v3.7.1` release carries the bridge (`bridge-release.json`, `uai-bridge-package.json`) and companion (`relay-release.json`, `UAI-Relay-3.7.1.apk`, checksum) assets; the bridge updater discovers it via its `(?:bridge-)?v` tag rule and the companion via its `(?:relay-)?v` rule (both verified against the live release list); the desktop shell ignores it because it has no `desktop-release.json` |

## Operational note

Provisioning runs `tar.exe` from `PATH`. Windows' built-in `System32` bsdtar
extracts correctly; GNU tar from a Git Bash/MSYS `PATH` interprets `C:\...` as
a remote host ("Cannot connect to C: resolve failed") and fails helper startup.
The desktop app is unaffected. Start a Node bridge from a shell whose `PATH`
resolves `tar.exe` to `System32`, or set `UAI_KILO_TOR_BINARY` to an installed
Tor executable.
