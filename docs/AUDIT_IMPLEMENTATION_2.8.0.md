# 2.8.0 audit implementation

Reviewed October 12, 2026 against `AUDIT_COMBINED.md` and its two source reports.
The audit mixes confirmed defects, already-correct behavior, proposed product
changes and references to findings that are not included in the repository.
Changes below preserve SPEC's runtime/presentation boundary and managed execution
contract. Verification is recorded in TESTING_2.8.0.md (archived).

## Scripting harness investigation

Three concrete model-facing failure paths were identified:

1. OpenCode's required compatibility declarations include `bash`, `read`, `edit`,
   `glob`, `grep` and `list`. These names usually have no local UAI handler. The
   old error listed the first twelve registered tools, which could omit the
   relevant file/execution tools. The workaround declarations and streaming stay
   intact. Scoped main/child prompts now explain the declaration-only names;
   unknown-tool errors prioritize real alternatives that the conversation can use.
   Host-registered implementations retain their normal behavior.
2. A token-limited tool batch never executes, but previously advanced the repeated
   call counter. Two truncated attempts could therefore cause the first complete
   `file_write` to be blocked as a repeat. Such batches now reset that counter.
   A deterministic response sequence exercises write, compile and execute by path
   after two truncated responses, and checks the actual returned value.
3. Native tools frequently returned instance IDs, source IDs, listings, revisions
   and continuations only in `result.data`. The model received only `result.text`,
   sometimes just "Script source references" or "Opened source snapshot". This
   prevented a model from using information the tool had successfully obtained.
   Structured-result delivery is covered at the actual agent request boundary,
   including bounded output and subsequent reads.

Other corrected sources of misleading feedback include lost execution status,
undisclosed output omission, blanket pending-work warnings on ordinary errors,
template failures reported as successes, inconsistent memory keys and incomplete
JSON reads losing requested filters. Prompts now distinguish Lua source from JSON,
saved paths from Code document IDs, and compilation from API/behavior validation.

The LuaJIT mock compiler applies repository authoring restrictions to injected
source. That is a limitation of the offline fixture, not proof that the native
client rejects valid Luau. A focused Lune fixture substitutes the real Luau
compiler and exercises typed declarations, interpolation, `continue`, floor
division, numeric literals, generalized iteration and a saved-path Part script
through the real execution wrapper. Roblox services and scheduling remain mocks.

These are reproducible harness defects and focused language checks. They do not
establish the quality improvement of any particular live model; no before/after
provider benchmark or native Roblox rendering result is claimed.

## Implemented groups

- Execution/source validation, status and output feedback; protected capability
  lookup; recovering fractional clocks; Code input snapshots and timeout margins.
- Project-test discovery and case-limit accounting; safe template data quoting,
  failure propagation and temporary listener cleanup.
- Read-risk subagent scope and preset validation; strict incomplete-argument
  rejection; tool-specific unknown-name recovery; consistent memory operations.
- Explicit write-risk labels, distinct client/worker status tools, truthful input
  outcomes, typed remote prefixes, exponent parsing, log redaction, bounded world
  scans, guarded hierarchy operations and Gravity selection recovery.
- Messages sampling preferences and explicit-error-only transient classification.
- Protected Code highlighting, literal output logs, complete permission argument
  review and consistent prompt cleanup; retained orphan results, unread failure
  counts and explicit failure disclosure without overriding reader choices.
- An on-demand scripting manual with exact tool examples and targeted workflows,
  available to the client without inflating every model request.
- Bundle source line ranges, required version metadata, website risk filtering,
  batch-read examples and generated counters; current 2.8.0 release surfaces.

## Decompilation investigation

Source inspection first reads host-accessible `Source`, then tries the native
decompiler, bundled luacid and ByteFall when decompilation is needed. Explicit
decompilation skips the direct `Source` read. Opening or reading the resulting
snapshot never executes its contents.

The review found that invalid native output could block a working fallback,
comment blocks and service documents could be accepted as source, and fallback
attempts could begin after every reader had cancelled. Validation now precedes
acceptance and caching, with useful attempt diagnostics that omit raw host and
service bodies. Missing capabilities and failed attempts are distinct outcomes.

Luacid also retained an unbounded second cache, which defeated the shared source
service's Refresh behavior. It now uses that service's bounded cache and installs
inside a private environment instead of replacing executor globals. Bytecode
requests, retry waits and source results are bounded. Cancellation and deadlines
prevent new stages and reject late results; native calls remain cooperative and
retain their worker slots until they return. These limits cannot force an
executor's blocked native call to terminate.

Focused offline coverage and any synthetic live-service probe are recorded in
TESTING_2.8.0.md (archived). Availability of an external decompiler and
reconstruction fidelity for arbitrary game bytecode remain separate from the
correctness of the client pipeline.

## Recommendations not applied

| Recommendation | Review finding / decision |
| --- | --- |
| Replace Lua `^` patterns because an initial offset is ignored | The anchor applies at the supplied start position; existing instrumentation is valid. |
| Guard every `table[nil]` read as a crash | Lua permits the read; nil-key assignment is a different operation. |
| Require one global Code run slot for agents and manual work | SPEC reserves the single manual slot while preserving bounded agent concurrency. |
| Remove OpenCode compatibility declarations | The user confirmed the workaround needs them; it is preserved. |
| Retry every relay 599 except cancellation | A submission or result may have an unknown outcome; blindly retrying can duplicate inference. |
| Discard all learned caps without a scope | SPEC explicitly adopts older saved caps into their current scope once. |
| Change default permissions, identity, effort or unknown-model traits | These are product-contract changes or unsupported capability guesses, not demonstrated audit fixes. |
| Change Code browsing to a files-only namespace | The Code browser intentionally supports app-root files; altering only bare-path interpretation would break existing round trips. |
| Limit the complete file after every append | The documented 2 MiB limit applies per call; a total-file cap is a separate policy. |
| Automatically open every failed tool group and pin all failures | SPEC preserves the reader's disclosure state and bounded virtualized rendering. |
| Rewrite the offline mock as a strict Roblox security sandbox | It is a trusted synthetic test environment. A broad redesign would require separate compatibility work; native language checks are isolated instead. |
| Rename every use of “checkpoint” or fabricate model-family limits | These are unrelated terminology/default changes without a demonstrated failure. |

Remaining audit shorthand that points only to external `ses_...` returns lacks
the full finding or reproduction in this checkout. It is not recorded as fixed.
The historical UI LIB and bridge audits are outside this client audit scope.

## Source locations

`dist/uai.manifest.json` retains its version-1 identity fields and adds inclusive
`sourceStartLine` / `sourceEndLine` ranges for each module and the bootstrap.
For a line inside a source range:

`sourceLine = bundleLine - sourceStartLine + 1`

Build identity normalizes CRLF and trailing whitespace at end of file. Interior
whitespace still contributes to identity. Wrapper/banner lines lie outside source
ranges; generated artifacts remain reproducible and are never edited directly.
