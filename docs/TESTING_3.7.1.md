# Project UAI bridge 3.7.1 verification

Prepared October 25, 2026. The bridge, web UI and Android companion (version
code 8) move to 3.7.1; the Roblox client and Windows desktop remain 3.7.0.
The patch accepts every Kilo free-model spelling (`:free`, `/free`, `-free`) in
quota recovery, so `reflection/beam-free` and `openrouter/free` no longer
bypass the Kilo tunnel.

Changed source, documentation, tests and build inputs were manually reviewed
before builds. Generated outputs were inspected before verification, and fixes
were reviewed before retesting. The checks below establish bridge, companion
and live Kilo behavior; they do not establish native Roblox behavior.

## Rule change

`bridge/kilo.js` `eligible()` and the Android `KiloRoute.eligible` now accept a
model id that ends in `free` behind a separator (`:free`, `/free`, `-free`)
instead of only `kilo-auto/free` and `:free`. The separator requirement keeps
unrelated ids such as `free`, `carefree` or `kilo-auto/free-tier` out. The
first send stays direct; only a complete anonymous
`PROMOTION_MODEL_LIMIT_REACHED` refusal still triggers the tunnel, rotation and
cooldown, unchanged.

## Checks

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
