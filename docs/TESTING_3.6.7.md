# Project UAI 3.6.7 verification

Prepared October 24, 2026. This is a bridge and Windows desktop release: the
bridge and the desktop app report 3.6.7, while the Roblox client remains 3.6.6
and the Android companion remains 3.6.5 until their own builds.

The release migrates the Windows app from WinForms to WPF with a custom title
bar and typeset branding, fixes an embedded-payload gap that stopped the bridge
from starting (`environment.js` was missing from the packaged module list), adds
an on-demand bridge and web UI update check surfaced on the Updates page, and
prunes stale payload, desktop-update and bridge-update cache entries. The
bridge supervisor answers an authenticated `POST /api/desktop/update-check`
after its check and applies a staged release once the worker is idle.

Changed source, documentation, tests and build inputs were manually audited
before building, and each generated payload and executable was inspected before
verification. The results below establish behavior in the listed offline
fixtures and on this Windows machine; they do not establish native Roblox
rendering or host input. See the [changelog](../CHANGELOG.md).

## Bridge

| Check | Result |
| --- | --- |
| Updater and supervisor | 20 tests passed; release selection, staging, activation, rollback, idle negotiation, manual update-check round trip, cache pruning |
| Full bridge suite (`--skip-images`) | 117 tests, 114 passed, 3 image suites skipped |
| Desktop update-check | One supervised check answers `staged` before the reply, applies after the worker is idle, and a second check settles to `current` on the updated worker |
| Cache pruning | Stale version and quarantine folders removed; referenced and fresh entries retained |

## Windows desktop

| Check | Result |
| --- | --- |
| Self-test | 50 checks passed; preferences, launch info, update staging, receipts, release selection, cancellation, cache pruning |
| Startup test | 9 checks passed; single-instance ownership, duplicate-launch restore, owner cleanup |
| Smoke test | 6 checks passed; start/stop, discovery, simulated game, manual bridge update check |
| Window test | 10 checks passed; command binding, navigation at 760/1120 px, minimize/restore, close during bridge startup, staged-update close |
| Update test | Helper handoff exercised end to end for missing, corrupt and refused candidates |
| Standalone | Executable verified from an isolated copy with no neighboring runtime or bridge folders |
| Previews | 7 native renders inspected (normal, compact, narrow and all four pages) |

The window test probes the bridge port through the active-listener table
rather than a loopback connect: local filtering software on this machine
delayed refused connections past the previous two-second deadline.

## Known limits

- The WPF previews are rendered offscreen at 96 DPI; multi-monitor per-monitor
  DPI scaling was reviewed in the manifest but not exercised on a second display.
- Bridge update checks performed by installed 3.6.6 bridges continue to work;
  the on-demand endpoint is present from 3.6.7, and older workers answer 404,
  which the desktop reports as a retry notice.
