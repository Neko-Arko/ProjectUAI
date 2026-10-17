# Project UAI 3.3.1 verification

Scope: native model-picker space and free-model outlines, visible queued messages,
bridge tool/error cards, native live bridge previews and relay HTTP capacity.
The reference screenshots stay local and are excluded from the commit.

All changed inputs were manually reviewed before building. Generated native,
bridge and desktop artifacts are inspected before focused checks. This patch
does not run the entire native suite or change the mobile companion.

Focused coverage includes native picker/temperature/effort, queued composer,
real bridge preview delivery before upstream completion, repeated/lost cursors,
terminal cancellation, old bridge compatibility, all four provider adapters,
requests beyond the 300-second native limit, and ten concurrent relay requests
alongside the bridge inbox. Browser coverage checks compact tool statuses,
readable errors, exact copied payloads, restored outcomes and narrow layouts.

Roblox Studio was not connected. Offline layout checks and browser screenshots
do not establish native Roblox rendering or executor behavior.

## Completed checks

- Picker layout: 3 cases / 37 assertions; temperature UI: 12 assertions; effort:
  5 cases / 43 assertions; bundled model picker: 31 checks.
- Queued composer: 22 checks. Browser tool-card and workflow suites passed;
  desktop and 320px light/dark screenshots were inspected.
- Bridge streaming, native-preview HTTP and OpenCode native route: 35 tests.
  Native bridge previews: 7 cases / 25 assertions; Web runtime: 22 checks.
- Bridge updater: 17 tests, including installed 3.1 compatibility, verified
  package activation, idle-only replacement, retained tokens and rollback.
- Concurrent relay admission: 13 checks; desktop discovery: 40 checks;
  bridge lifecycle: 54 checks, including waits beyond 300 seconds.
- Native transport/UI regressions: 46 cases / 174 assertions. Native static
  audit: 215 parsed, zero failures/warnings. Official Luau compiler: 17 changed
  source/bundle files compiled.
- Standalone desktop: 28 self-test checks, 5 smoke checks and packaged MCP 1/1
  passed. The generated launcher preview was inspected. Native, bridge and
  website freshness checks passed.

Native build: `3.3.1-fb6c6581e29d4e1a`, 219 modules, 3,372,290 bytes.
Bridge package: 3.3.1, 21 files, 1,173,805 bytes. Desktop embeds 30 verified
bridge/client/license files; its embedded native bundle matches the standalone
bundle. Node.js and the OpenCode CLI remain external.

The release ships version 3.3.1 bridge update assets and the matching standalone
desktop executable. Installed updaters discover published stable GitHub releases;
pushing source or a tag alone does not distribute these assets.
