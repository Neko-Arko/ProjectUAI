# Project UAI 3.6.6 verification

Prepared October 23, 2026. This is a client release: the Roblox client reports
3.6.6, the bridge remains `bridge-v3.6.6`, and the Windows and Android downloads
stay 3.6.5 until their own builds. UI LIB remains 1.3.0 and SDK 1.0.0.

The release replaces the add-provider form with a tiered gallery, grows the
provider catalog to 66 presets, labels hybrid services by their free half,
rebuilds the queued-message surface, and moves Settings to one entry point.

Changed source, documentation, tests and build inputs were manually audited
before the bundle was rebuilt, and the generated bundle was inspected before
verification. The results below establish behavior in the listed offline
fixtures. They do not establish native Roblox rendering or host input. See the
[changelog](../CHANGELOG.md) and
[provider compatibility](PROVIDER_COMPATIBILITY.md).

## Client

| Check | Result |
| --- | --- |
| Provider gallery | 7 cases, 396 assertions passed; tier order, hybrid labels, cross-tier search, custom card, seeded editor, reopened gallery |
| Provider editor | 23 cases, 169 assertions passed |
| Provider compatibility | 98 cases, 1,832 assertions passed; one matrix row per catalog preset |
| Queued messages | 27 checks passed |
| Settings entry | 7 checks passed; one sidebar row, modal on General, no Customize, no duplicate |
| Mobile Code and forms | 9 cases, 130 assertions passed |
| Panel layout regressions | 63 checks passed |
| Provider UI ownership | 4 cases, 12 assertions passed |
| Project UAI Free | 8 cases, 68 assertions passed |
| Scenarios: provider | 11 scenarios, 147 checks passed |
| Scenarios: first run and featured | 2 scenarios, 64 checks passed |
| Scenarios: profile menu | 2 scenarios, 21 checks passed |
| Static module check | 232 parsed, 231 modules, 0 failures, 0 warnings |
| Bundle | 231 modules, 3,591,398 bytes |

The catalog matrix asserts a base route, an auth header and both request shapes
for every preset, and the suite fails when a preset has no row. Gallery order,
access labels and search results are asserted from the catalog rather than from
rendered text, so a label change is a test change.

The version reported by the client and the newest changelog entry are the same
value by construction: `boot mounts the interface` compares them, and the
`ui.lastSeenVersion` scenario compares the stored marker with the same entry.

## Known limits

- Two scenarios fail on the parent commit as well and are unrelated to this
  release: `free_routing.lua` expects a two-pixel green outline on the free model
  row where the picker draws one, and `boot mounts the interface` expects the
  "No provider configured" empty state that the included free provider now
  prevents. Both are left for a separate decision.
- Card spacing, the accent border and the scroll edge were reviewed in the
  offline harness. Mock layout does not prove native Roblox rendering; the
  bundled client is verified in Roblox separately.
