# Project UAI 3.3.0 verification

Release: October 17, 2026. Scope: MCP through the desktop bridge, bridge workspace
and modal redesign, model/reasoning/context controls, adaptive free routing,
queued follow-ups, native Code Library/Explorer/Remote Spy improvements, editor
selection alignment, temperature compatibility and Gemini support.

Source, documentation, examples, fixtures and build inputs are manually reviewed
before building. Generated outputs are inspected before focused verification.
Every fix follows that order again. The entire native suite is excluded by the
user's request. The mobile companion, SDK version and UI LIB are unchanged.

## Completed bridge checks

The following checks passed after input review, build and output inspection.
Later fixes reran the affected focused checks; unrelated passing checks were not
repeated. The final routing preference and artifact checks are recorded below.

| Check | Result |
| --- | --- |
| MCP wire, official MCP SDK and bridge security | 22 tests passed; HTTP/stdio initialization, schemas, calls, cancellation, receipts, notification reconnect and authentication |
| Bridge updater | 17 tests passed; stable 3.3 update fixtures, pinned 3.1 updater compatibility, idle replacement, rollback, retained token and standalone startup |
| Pictures, provider hydration and streaming | 50 tests passed; Gemini signed raw responses with text/thought/tool previews, native image parts, ownership, expiry, limits, truncation and terminal errors |
| Browser desktop redesign | Passed; modal destinations, MCP prompt/config copy, model/effort/temperature/context controls, pending messages, subagent tabs/tool selection/drafts/Stop/copy and responsive geometry |
| Browser regression/audit | Revamp, visual rework and UI audit passed; upload removal races, response ordering, focus, modal recovery, themes, contrast and forced colors |
| Final Windows executable | 28 self-test checks, 5 smoke checks and packaged MCP 1/1 passed with no skipped tests; copied executable works without neighboring runtime/bridge files |

The MCP SDK interoperability checks used SDK 1.32.1. This establishes protocol
interoperability, not a manual test of every release of Claude Code, Codex,
Cursor, OpenCode or other harnesses. The setup prompt tells the user's agent to
preserve unrelated configuration and verify the actual connection.

## Focused native checks

| Check | Result |
| --- | --- |
| Gemini provider | 9 cases, 56 assertions; JSON/SSE, discovery, native/Go auth, tools/results, signatures, images, thinking, errors and media rejection |
| Provider compatibility | 56 cases, 906 assertions; all presets, bounded repairs, scopes, protocol recovery and transport behavior |
| Go registry / bridge metadata | 4 cases, 53 assertions / 4 cases, 21 assertions |
| Temperature compatibility | 10 cases, 57 assertions; manual policy, scoped refusal learning, cancellation, editor draft/replacement/removal and protocol handoff ownership |
| Existing sampling / output budget / key snapshots | 3 cases, 36 assertions / 5 cases, 43 assertions / 6 cases, 19 assertions |
| Native improvements | 46 cases, 174 assertions; includes idle Stop invalidating old contexts while permitting new work |
| Queued messages / composer | 12 cases, 98 assertions / 15 checks; ordering, safe boundaries, held restoration, attachment preparation, admission and separate Stop |
| Attachments / request lifecycle | 70 checks / 5 cases, 22 assertions |
| Embedding SDK / sessions | 34 checks / 95 checks |
| Code tab / Library / Explorer | 14 cases, 82 assertions / 3 cases, 15 assertions / 4 cases, 13 assertions |
| Compact inspectors / Remote Spy UI | 7 cases, 128 assertions / 3 cases, 21 assertions |
| Temperature UI / effort and routing UI / model picker / subagent activity | 12 assertions / 5 cases, 43 assertions / 31 checks / 6 cases, 32 assertions |
| MCP native / desktop bridge / Web runtime | 8 cases, 28 assertions / 40 checks / 22 checks |
| Scripting guide / prompt context | 37 checks / 5 cases, 120 assertions; 18 guide sections, main 11,730 bytes and child 12,191 bytes within unchanged prompt budgets |
| Native static audit | 215 parsed, 214 modules, zero failures or warnings |
| Official Luau compiler | 43 changed source/bundle files compiled successfully; the final routing update's 10 affected files compiled again |
| Public site | v3.3.0, 174 tools, 21 groups; 8,361 static checks and generated mirror freshness passed |

## Adaptive routing evidence

See [free-routing validation](FREE_ROUTING_VALIDATION.md) for live synthetic
tool-call and tool-result measurements. Ordering varied between probes, which is
why no model is hardcoded as fastest. The under-ten-second target is a selection
criterion from recent measurements, not a latency guarantee. Cold, unknown or
incompatible requests retain provider `auto`; user prompts are never raced.
Automatic free routing is on by default and has an explicit off switch in both
interfaces. Routing notices identify the selected model and the setting location.
The final routing checks passed 14 cases and 171 assertions. They cover default-on
and disabled startup, cancellation of probes, preserving an in-flight request,
using saved `auto` on its next tool step, stale owners, notice retention and
suppression of repeated notices for the same model. Request lifecycle checks
passed another 5 cases and 22 assertions after the routing change.

## Native rendering limits

Offline fixtures verify behavior, ownership, syntax and layout invariants.
Chromium previews verify browser layout. They do not establish Roblox rendering,
executor input/hook forwarding, engine font metrics, touch selection or native
performance. No Roblox Studio instance was connected during the editor review.
Native hold-drag selection and long-file font alignment require a live check.

## Final release verification

Native and bridge freshness checks pass on the final routing build; the website
mirror is current. The final standalone desktop self-test, smoke test and MCP
interop check passed. The generated launcher preview was inspected for legibility,
complete controls and clipping. No source changes followed these checks.

| Artifact | Final build |
| --- | --- |
| Client | `3.3.0-ce10b048fb5e0b1c`, 219 modules, 3,367,473 bytes |
| Client SHA-256 | `d1c84a34f8bf72ab4411520d2473ea38e80bd7a942a122a3a3552e44f1fd4b9a` |
| Bridge package | 3.3.0, 21 files, 1,162,837 bytes |
| Bridge SHA-256 | `4e45e5cd107b5001893291934ecc09ba6cc943b218e9b52b779fbbef4e255567` |
| Windows executable | `UAI-Bridge-3.3.0-win-x64.exe`, 53,927,238 bytes, 30 embedded bridge/client/license files |
| Windows SHA-256 | `ad549518122e664dd1abe5d5295533e176354a863c12c5ddfebfc42ba916146f` |

The embedded client hash matches the standalone native bundle. Node.js and the
OpenCode CLI are not bundled. Artifacts are built locally; no release was published.
