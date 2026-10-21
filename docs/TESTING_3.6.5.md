# Project UAI 3.6.5 verification

Prepared October 21, 2026. Client, bridge, Windows desktop and Android companion
share version 3.6.5; Android version code is 6. UI LIB remains 1.3.0 and SDK 1.0.0.
This unified release includes the OpenCode native execution guard, mobile native
transport ownership and response limits, bounded expanded thinking presentation,
Relay Always routing, and the refreshed desktop connection dashboard with grouped
settings.

Changed source, documentation, tests and build inputs were manually audited
before building or verification. Generated artifacts were inspected before their
applicable checks. The results below establish behavior in the listed fixtures;
they do not establish native Roblox rendering or a fix for the reported phone
crash. See the [investigation](INVESTIGATION_MOBILE_CRASHES.md) and
[changelog](../CHANGELOG.md).

## Mobile client

| Check | Result |
| --- | --- |
| Native HTTP ownership | 6 cases, 16 assertions passed; discovery, jobs and aliases share an unfinished mobile exchange, unload/reload retains ownership, Stop has one separate lane, desktop parallelism remains available |
| Expanded reasoning | 4 cases, 22 assertions passed; touch-only excerpts precede formatting and measurement, RichText has a plain-text fallback, original reasoning persists |
| Relay response and ownership | 8 cases, 35 assertions passed; oversized and malformed received replies stop unlimited polling, cancellation keeps the original job, late results cannot replay inference |
| Mobile relay routing | 38 checks passed; Always requires a relay during absence and failed health checks, Auto keeps direct fallback, a fresh successful scan restores routing |
| Companion deadlines | 15 cases, 54 assertions passed |
| Companion discovery | 50 cases, 207 assertions passed |
| HTTP diagnostics | 10 cases, 50 assertions passed |
| Mobile scrolling | 3 cases, 16 assertions passed |
| Chat reading position | 2 cases, 9 assertions passed |
| Mobile layout | 22 checks passed |
| Provider compatibility | 56 cases, 906 assertions passed |
| Bridge lifecycle | 54 checks passed |
| Bridge concurrency | 13 checks passed |
| Bridge previews | 7 cases, 25 assertions passed |
| Native static audit | 217 files, zero errors |
| Official Luau compiler | Changed source and the native bundle compiled successfully |

The client bounds mobile native concurrency and avoidable diagnostic/layout work.
It does not forcibly close a native HTTP coroutine. Response-size and malformed
receipt failures remain terminal, while unknown deadlines can recover behind the
original native owner. The original provider body and reasoning remain available
within their existing retention/context limits.

## Android companion

All 80 JVM tests across 11 suites passed with zero failures or errors. The focused
server suite passed 19 tests, including exact UTF-8 sizing against the serializer
for escaping, metadata, Unicode and unpaired surrogates, the complete 8 MiB
boundary and one byte beyond it, and repeated oversized receipt reads with one
provider submission. Direct and executor responses retain their protocol-2 and
schema-1 shapes. An oversized reply returns HTTP 413 or executor status 413 before
allocating the expanded provider-body response; its original receipt is retained.

`:app:lintRelease` passed with zero errors, 24 warnings and two informational
items. Findings concern established battery/wake-lock behavior, dependency
versions, resources/labels/icons and Kotlin style; none points to the changed
response preflight or server code. The final signed `:app:assembleRelease` and
its release lint checks passed after the version metadata changed to 3.6.5.

APK inspection confirmed application ID `dev.projectuai.relay`, version 3.6.5,
version code 6, minimum Android API 26, target API 36 and a non-debuggable release.
APK v2 verification passed with one RSA-3072 production signer matching the
committed certificate pin:

`ad7d215b8ad67ce70ae2ce89ad3ea959b68202b5c38e72141a68f7d54331f4b5`

The signed APK is 9,655,526 bytes with SHA-256
`eebaaac1aa94f2018acccafd54d2f765c9a5cd618e07e3b3537f1eae05463cac`.
Signing credentials stayed in the release machine's secret store and process
environment; they are absent from source, artifacts and test output.

## Bridge, website and packaging

The bridge suite passed 113 tests with three skips and zero failures (116 total).
Image suites were excluded with the existing `--skip-images` option. The first
run passed the static junction security assertions but failed during Windows
fixture removal with `EPERM`. Exact-root validation and bounded asynchronous
cleanup retries corrected that test race; the focused junction test and full
suite then passed. Production static serving policy was unchanged.

Client desktop discovery passed 40 checks and bridge installation passed 70.
Android release packaging passed 10 tests and deterministic freshness checks.
Client bundle/manifest and bridge package freshness passed. The public website
passed 8,447 static checks; its root and publishing mirror are synchronized at
3.6.5. The version/download link changes received manual review before generation.

The client build is `3.6.5-e8b508cfe71324ad`, 3,429,852 bytes. The bridge package
contains 21 verified files, 1,245,134 bytes, SHA-256
`a878c2cf1d359f2d8a9ef551ad1d751765c59bee8c5399008cd2cd36b9e8e306`.
Windows and Android release binaries are generated locally and uploaded as
release assets; their private signing/build inputs are excluded from Git.

The final production OpenCode path was also checked with installed CLI 2.1.2
and the designated handover test key held only in memory. DeepSeek text returned
`PONG` (HTTP 200, 3.198 seconds); continuation from an actual blocked `execute`
receipt returned the declared lookup tool (HTTP 200, 12.280 seconds); its result
replay returned the exact fixture game name (HTTP 200, 6.178 seconds). Duplicate
submissions retained their original job. The CLI remained isolated from the key
and no host action executed. These Windows live checks complement the earlier
direct keyed Zen checks in [the 3.6.2 record](TESTING_3.6.2.md).

## Windows desktop

The original 3.6.0 standalone executable reproduced the two-launch defect: an
existing unowned named mutex caused the first process to exit without a window;
after that handle closed, a second launch opened. The corrected implementation
acquires the mutex and handles abandoned ownership instead of using kernel-object
existence as proof of a running window. Restore signals received before `Shown`
are retained until the native window can process them.

The final standalone 3.6.5 executable passed 57 checks: 36 self-test, nine
process startup, five live bridge smoke and seven native window checks. They
cover unowned/abandoned mutexes, duplicate launch restoration, narrow-to-wide
resize with all settings/actions reachable by scrolling, minimize/restore,
owned process shutdown and retained staged updates. The resize test exposed a
real stale native scrollbar range; a deferred refresh after WinForms' resize
pass corrected it. All four final native previews were visually inspected:
normal, compact, narrow top and narrow bottom.

The executable has 30 verified embedded bridge, client and license files, matching
the final source inputs and client bundle. It works as one file without adjacent
runtime or bridge folders. Final size: 53,992,774 bytes; SHA-256:

`4094b92f34fd98334453298cffd38a9676eead6ff1a79e5f51c8fe3a0b6d8107`

## Native-device limits

The reporter supplied an Android arm64 Roblox build 74100 `SIGSEGV` summary with
fault address `0x148` and last operation `EXECUTE SCRIPT`. Its timestamp predates
the October 20 fixes. It identifies a native process crash, but supplies no
module or stack frames that attribute the fault to HTTP, UI, Roblox or executor
code. It does not establish the installed version during a later recurrence.

No physical Android device was connected, and no usable emulator was available.
These checks do not verify native installation/upgrades, executor loopback
networking, host touch input, background survival or a complete phone inference
and tool-result replay. A native tombstone and correlated activity/memory records
are still needed to attribute the reported crash. The bounded transport and
presentation changes address demonstrated code defects independently of that
attribution.
