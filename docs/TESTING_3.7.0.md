# Project UAI 3.7.0 verification

Prepared October 25, 2026. The Roblox client, bridge/web UI, Windows desktop
and Android companion share version 3.7.0; Android uses version code 7 and the
existing production signer. Cline is bridge-only. Kilo recovery is available in
the desktop bridge and Android companion.

Changed source, documentation, tests and build inputs were manually reviewed
before builds. Generated outputs were inspected before verification, and fixes
were reviewed before retesting. The checks below establish the stated fixture
and Windows behavior; they do not establish native Roblox or Android behavior.

## Bridge and tunnels

| Check | Result |
| --- | --- |
| Full bridge suite | 176 tests: 173 passed, 0 failures, 0 cancellations, 3 conditional/platform skips |
| Kilo focused fixtures | 17 tests covering complete quota refusals, credential exclusions, bounded retry, cooldown, cancellation, TLS and process lifecycle |
| Cline native fixtures | 12 process/HTTP tests covering authentication, exact free-model selection, host-tool denial, validated handoff, Unicode streaming, cancellation and cleanup |
| Cline routing fixtures | 3 tests: reserved URLs cannot escape to outbound HTTP, errors stay terminal, Stop prevents late completion |
| Live Kilo helper | Verified archive/startup, HTTPS catalog response 200 with 401 models, circuit generation 1, owned-process shutdown and private-session removal |
| Live Cline 3.0.73 text | Existing signed-in account, `reflection/beam-free`, HTTP 200 with the exact requested text |
| Live Cline tool handoff | HTTP 200 with both `get_workspace_snapshot` and `get_selection` in the completed batch; no Roblox tools executed by this probe |
| Browser | Existing connection, Tunnels and model-catalog lifecycle fixtures passed, including live SSE status, refresh, exact model-ID copy, malformed catalogs, cost coverage and actual bridge disconnect |
| Browser layout | Tunnels and model dialogs inspected at 320, 390 and 1440 px; long IDs fit and six screenshots were retained locally |
| Bridge package | 21 files; embedded tunnel modules inspected; deterministic freshness check passed |

The final bridge suite ran without concurrent compilation. Earlier loaded runs
hit two pre-existing fixture timing deadlines; both passed unchanged alone and
in the final complete run. General bridge fixtures disable installed Cline so
they cannot consume the user's account. Live probes were separate and cleaned
up their owned processes and temporary files.

Cline's official promotion feed is the free-model authority. Its generic ACP
catalog omits some promotional IDs, so the bridge verifies the exact explicit
model, provider and permission settings before prompting. Images are rejected:
CLI 3.0.73's ACP handler drops image blocks despite advertising image support.
Generic UAI temperature and reasoning-effort settings are not forwarded by this
adapter; the installed CLI's sampling defaults apply.

## AgentRouter and provider selection

| Check | Result |
| --- | --- |
| AgentRouter affected regressions | 172 cases and 2,969 assertions across protocol, Responses lifecycle, bridge metadata, provider compatibility/proxy/transport, pricing and agent-audit suites; no failures |
| Live AgentRouter catalog | Authenticated account returned `gpt-5.6-sol`, `gpt-6-astra` and `gpt-6.1-sol` |
| Live UAI tool round trip | `gpt-6.1-sol` returned the real `instance_tree` and `instance_get` declarations as one batch, consumed simulated Roblox results and completed with `UAI_TOOLS_OK FixtureMap`; no Roblox world writes |
| Final default-request probe | Both native Responses requests returned HTTP 200 in 4.829 and 3.697 seconds with Low effort, `store: false`, parallel tools and optional arguments preserved; no raw parameter overrides |
| Other AgentRouter models | `gpt-5.6-sol` exceeded the 45-second deadline and was not replayed; `gpt-6-astra` returned a regional token quota refusal |
| New provider presets | Vercel, FriendliAI, Venice, Nscale, Arcee, AI/ML API and Perplexity Orchestrator checked against current public documentation and available unauthenticated catalogs |
| Catalog and setup fixtures | Provider catalog filtering (38 assertions), searchable menus (9), setup (16), gallery (437) and editor (169) passed |
| Model picker fixtures | Layout (58 assertions), touch controls (136), discovery cancellation (9), modal fit (25), dismissal (166) and motion (31) passed |

The temporary AgentRouter credential was removed after testing and is absent
from release inputs. These live checks establish the supplied account's observed
behavior, not access for all users or successful inference on every listed model.
The first successful tool pair took 2.69 and 2.86 seconds; measured latency varies
with upstream capacity. See [AgentRouter details](AGENTROUTER.md).

Paid inference on the seven new services was not exercised. Vercel credits apply
only to eligible free-tier models, and AI/ML API's paused free tier is labelled
paid. Setup guides keep discovery, authentication, balance and tool support
separate; see [provider setup](providers/README.md).

## Client and website

| Check | Result |
| --- | --- |
| Desktop bridge client transport | 42 checks passed, including forwarding unknown-cost coverage to Cowork |
| Additional focused client suites | 87 cases and 411 assertions passed: native improvements (46/174), native workspace (13/76), code workspace (14/79) and coding-tab interactions (14/82) |
| Final coding layouts | 19 cases and 7,924 assertions passed after preserving the Following button's width at 320 px |
| Official Luau compiler | 259 inputs passed, including all client source, new modules, UI library, examples and generated bundles |
| Website static checks | 8,703 checks passed |
| Corrected main-suite scenarios | All 15 affected scenarios passed: 209 checks, no failures, 29 seconds |

The inspected final client bundle is `3.7.0-5bbebc4231380c30`, containing 237
modules and 3,729,615 bytes. Bundle/manifest freshness passed. Its SHA-256 is:

```text
3a8d8bf73c5ccc9b50f5f44cc1179b2a353e8675d6560fda5c7453315b7f4509
```

The initial comprehensive native runner stopped after the main suite reported
137 scenarios, 2,184 passing checks and 38 failures. Running the same suite on
clean `main` reproduced all 38 failure labels (2,170 passing checks). These were
obsolete fixtures: first-run provider selection, startup discovery requests
counted as inference, schema property-map traversal, the old summary budget,
planning permissions, and outdated result shapes or prompt text.

The fixtures were corrected and manually reviewed, then all 15 affected scenarios
were rerun successfully. They retain the protocol, permission, schema, replay and
UI assertions and add explicit history counts and single-key dispatch evidence.
At the user's request, remaining verification was narrowed to affected behavior
instead of restarting the complete runner. No fresh full-client-suite pass is
claimed; the focused results above and elsewhere in this record describe the
actual coverage.

## Windows desktop

The final standalone executable passed 134 checks: 69 self-tests, 9 startup,
6 bridge smoke, 11 native-window and 39 updater checks. Installation detection
and refresh work before Cowork starts. All 11 final WPF previews were manually
inspected, including normal and narrow Tunnels pages at both scroll positions.

The executable embeds 40 verified bridge, client and license files. Every
embedded file matched its reviewed input, including the final client above and
the Cline reserved-address fix. Startup passed without adjacent bridge or runtime
folders. Node.js is detected or downloaded; OpenCode and Cline remain separate
installations.

`UAI-Bridge-3.7.0-win-x64.exe` is 67,379,587 bytes, with SHA-256:

```text
b6b2ae7106dca7c046124ddedee95c9f20695f06d698dc070d036dec37a796e5
```

## Android companion

| Check | Result |
| --- | --- |
| JVM tests | 89 tests across 12 suites, no failures, errors or skips |
| Packaging | 10 packager tests and deterministic package verification passed |
| Release lint | 0 errors, 35 warnings; dependency/policy, battery behavior, UI metadata and Kotlin API suggestions remain recorded |
| APK identity | `dev.projectuai.relay`, version code 7, non-debuggable, minimum SDK 26, target SDK 36 |
| Signing | APK Signature Scheme v2 verified with the existing pinned production signer |
| Native payload | Tor and notices for arm64-v8a, armeabi-v7a, x86 and x86_64; 64-bit ELF and ZIP 16 KiB alignment passed |

The Tor AAR requires compile API 37.1. The reviewed build uses AGP 9.4.1,
Gradle 9.6.0 with its distribution SHA-256 pinned, and Kotlin 2.2.10 plugins;
minimum and target API requirements remain unchanged. The production APK is
39,830,460 bytes with SHA-256:

```text
fc6c65cf8bbc27c6d701190a14142152c8ca7788c5727ebbc483006a0a876ad4
```

See [companion update verification](../companion/UPDATES.md) for signing and
device-acceptance details.

## Model metadata

The October 25 snapshot contains 1,760 entries across 15 providers. All five
sources were fetched successfully: models.dev, LiteLLM, OpenRouter, Kilo and
Cline. Source URLs and SHA-256 hashes are retained in
`tools/data/model_metadata.json`. The generated Lua catalog was inspected and
its deterministic freshness check passed; 21 normalization assertions passed.

Spot checks confirmed changed Mistral Large 4 and Together Qwen rates, corrected
Together and DeepSeek context/reply limits, and exact Kilo/Cline route ownership.
The current models.dev catalog covers the old OpenCode CLI supplement, so the
October 15 CLI overlay was removed. The refresh preserves unknown prices,
rejects unverified zero placeholders and never borrows free pricing across
endpoints. See [pricing sources and scope](PROVIDER_COMPATIBILITY.md#model-prices-and-limits).

## Discovery, diagnostics and usage

Seven focused suites passed: bounded search (8 assertions), tool discovery (6),
log storage (8), usage accounting (9), persisted cost coverage (7), lazy tool
panel (7) and diagnostics search (6). Existing tool-profile checks (14 assertions)
and model-pricing checks (90) also passed. Tests exercise real dispatch scope and
permission changes, normalized schemas, explicit page limits, log redaction and
retention, malformed counters, partial usage, reloads and clipboard refusal.

The browser catalog lifecycle fixture used 800 valid models mixed with duplicate
and malformed IDs. Five unrelated state snapshots caused zero model-row DOM
mutations and retained focus/scroll. Provider add/rename/removal, metadata/free
status changes, dialog cancellation, stale results and retry after HTTP 503 passed.

## Practical limits

- Kilo recovery is bounded. Shared exit addresses retain provider quotas, and
  switching models does not reset their allowance. Unlimited requests are not
  guaranteed. Exhausted exits return a visible terminal refusal and cooldown.
- Cline requires the separately installed, signed-in CLI and a currently free
  promotion. CLI/service changes and account limits can affect availability.
- No Android device was attached. Native Tor bootstrap/circuit changes,
  install/update behavior and mobile executor integration remain unverified.
- Roblox previews use the existing mock/Lune/Chromium harness. Native rendering,
  phone keyboards and executor input still require a real-device acceptance run.
- Windows previews use offscreen WPF rendering at 96 DPI. A second display with
  different per-monitor scaling was not exercised.
