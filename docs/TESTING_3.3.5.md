# Project UAI 3.3.5 verification

Scope: system and worker prompts, provider tool catalogs, native and browser
queued messages, bridge assistant/tool presentation, installed OpenCode CLI,
desktop lifecycle/preferences, and stable release/update artifacts.

All changed inputs are reviewed before builds; generated outputs are inspected
before focused verification. The mobile companion is excluded, and the entire
native suite is not run. Verification results are recorded below as completed.

## Investigation of fbd093a

Commit `fbd093a0378dbcb554c51d382e7747b86123caae` clamps Chat and Responses tool
declarations to 128, reserving compatibility tools for OpenCode. This prevents
the provider's declaration-limit error, but silently removes later registered
tools. Its regression test checks counts and first declarations, not whether the
omitted tools remain usable. Release 3.3.5 addresses that loss of functionality.
The regression now proves all 163 original tools remain reachable and exercises
schema discovery, execution, permissions and replay through both real adapter
paths and the agent loop. It also covers forced choices, name collisions, smaller
learned limits, malformed arguments and bounded schema pages.

## Installed OpenCode evidence

The installed official `opencode-cli.exe` reports `opencode v2.0.32`. A live
baseline probe on October 18 discovered ten zero-price models through its
authenticated local API. `deepseek-v4.1-flash-free` called a synthetic
`bridge_probe_echo` tool with the requested `native-335` argument. The bridge
returned the call without executing desktop tools. A second isolated request
received the synthetic tool receipt in conversation history and returned it as
the final answer. Both temporary sessions and the owned CLI were shut down.

The live OpenAPI document also confirms every session, interrupt, permission,
message, model and MCP route used by this adapter. Fixtures alone are not the
evidence for native API compatibility. This diagnostic does not claim every
model's quality or native Roblox rendering.

The revised backend passed a second live probe with 121 directly offered UAI
tools (the OpenCode 128-declaration ceiling minus its seven compatibility names).
It selected tool 121 with the exact requested argument in 9.5 seconds.

A final live probe used the actual Lua adapter and current prompt to build 128
wire declarations from 163 synthetic tools. The model called `uai_tool_catalog`
to describe `synthetic_tool_163` in 6.7 seconds, received the real Lua-generated
schema receipt in replay, then called that tool with `overflow-335-verified` in
4.5 seconds. The real Lua resolver preserved its original name, arguments and
call ID. No host or Roblox action executed. This proves the repaired overflow
path works through the installed CLI, beyond the deterministic fixtures.

## Build and focused verification

- Seven prompt/provider/loop checks pass: `prompt_context` (123 assertions),
  `tool_count` (733), `provider_compatibility` (906), `structured_results` (63),
  `agent_efficiency` (32), `subagent_tools` (34), `scripting_harness` (15).
- Queue behavior: `queued_messages` passes 15 cases / 115 assertions;
  `queued_composer` passes 27 checks, including bridge command delivery.
- Bridge backend: 39 focused tests pass across native OpenCode, desktop
  discovery/switches, MCP and updater suites. The shipped 3.1 updater accepts the
  generated 3.3.5 package and retains its token/idle/rollback contracts.
- Native static checks parse 216 files with zero failures/warnings. The official
  Luau 0.742 compiler compiles all 12 changed source/bootstrap files plus the
  complete generated bundle (74 KLOC) successfully.
- Native bundle: `3.3.5-82ab1a052c6a9d3e`, 220 modules, 3,394,235 bytes.
  Bridge: 21 files, 1,189,254 package bytes. Generated module entries, package
  hashes, embedded switches, queue controls and safe Markdown links inspected.

- Final desktop package: `desktop/verify.ps1` passes 46 checks: 36 preference,
  runtime and updater self-tests; five packaged bridge startup/discovery/restart
  checks; and five native window/integration checks. Minimize retains the taskbar
  window, restore returns it, closing waits for the owned bridge to stop, and
  closing with an update staged exits while retaining the pending update.
- Desktop executable: `UAI-Bridge-3.3.5-win-x64.exe`, 53,954,886 bytes,
  SHA-256 `b9e704f33e4d93e80e2426e4fe904d4f8a0d7f7b9824736980e163d0cb3a5b6c`.
  Its manifest and adjacent checksum agree. All 30 payload entries match their
  archive hashes; embedded bridge/browser/client sources match the final inputs.
  The executable works without neighboring support files or bundled Node/OpenCode.
- Final native full-size and compact previews were inspected at
  `desktop/.build/verification/launcher.png` and `launcher-compact.png`. The compact
  window keeps the title and connection controls visible and scrolls vertically.
- A live-update probe using the exact `v3.3.1` desktop updater and download code
  passes against the published release. Starting with an empty isolated cache,
  it discovers, downloads, verifies and stages 3.3.5, then verifies the staged
  file again. The result is `verified=true`, `state=Ready`; the staged executable
  matches the final byte count and SHA-256 above. No downloaded app is launched
  or installed by this probe.

- Browser verification passes `browser.js`, `browser-tool-cards.js`,
  `browser-queue.js`, `browser-desktop-redesign.js` and `browser-workflows.js`.
  Coverage includes exact tool input/result copying, scoped progress, readable
  errors, safe Markdown links, streaming reconciliation, retained drafts,
  attachment failures, edit conflicts, stable queue ordering, reviewed-identity
  clearing, older-client controls and the desktop's authenticated MCP setup link.
  The separate Markdown suite passes both escaping and URL-scheme checks.
- Dark/light desktop and narrow browser screenshots were inspected. Queue
  controls remain reachable at 390×844, 320×480 and 844×390, including actual
  pointer targeting after scrolling a short queue panel. The short-window header
  fix was reviewed, rebuilt and verified before repeating affected checks.
  Chromium and LuaJIT fixtures do not establish native Roblox rendering or input.
- Site static verification passes 8,361 checks. Final browser reruns were
  sequential after Windows process startup slowed under concurrent load; all
  final suites completed with exit code zero.

## Publication

The annotated `v3.3.5` tag points to release commit
`49cc1b3877b88b4069260b89d4cffad6d4012780`, pushed to `main` with the tag.
The [GitHub release](https://github.com/Project-Ptolemy/ProjectUAI/releases/tag/v3.3.5)
is published as stable and latest, with all seven assets: both updater manifests,
the bridge package, the desktop executable and checksum, and the native bundle
and manifest.

Post-publication verification passes on October 18, 2026. All seven assets were
downloaded anonymously from their public release URLs and matched the reviewed
local byte counts and SHA-256 hashes. The exact 3.3.1 desktop updater independently
downloaded and staged this release from an empty cache, reaching `Ready` with
verified executable bytes. Desktop 1.0 predates the updater and still needs one
manual download.
