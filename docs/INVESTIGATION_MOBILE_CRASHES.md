# Mobile crash, scrolling and stream investigation

October 20, 2026. Reports: Roblox crashes when the AI starts thinking; the
companion patch initially worked, then crashes recurred. A separate report says
mobile scrolling fails, presumed to be the native Chat window. Device, executor,
provider/model, exact installed versions and native crash logs are unavailable.
These reports establish timing, not which process or code caused termination.

## Findings and changes

**Native poll accumulation is a client defect.** `net/http` correctly keeps a
native worker's slot after its five-second Lua waiter expires. Previously,
`net/relay` could then dispatch a fresh poll for the same unlimited job while
the previous native poll remained running. Repeated stuck polls could consume
all eight native HTTP slots. This is bounded globally, but places avoidable
concurrent native work on a phone precisely while inference is waiting.

Each relay job now supplies a shared native owner for its short exchanges.
Another exchange waits, within its own short deadline, for the preceding native
call to return. Late replies stay discarded; provider submission identity stays
the same. Stop can send cancellation independently of the stuck poll. Native
coroutines are never forcibly closed. This removes a plausible contributor; it
does not establish the cause of an Android/Roblox process crash.

**Folded thinking performed unnecessary native text layout.** The reasoning
disclosure previously assigned its complete hidden trace to an automatically
sized, wrapped Roblox TextLabel, including every folded preview update. Merged
retained activity can contain substantial text. The folded label now stays
empty with automatic sizing disabled. Opening renders the retained text;
folding clears the label. Formatting is cached for unchanged reopening, and
provider reasoning in model context/persistence is preserved.

**Chat could override mobile scrolling.** The welcome card was moved to its top
on every layout update. During history replay, native scroll changes were
ignored while successive slices kept following the bottom. The view now
accepts reader movement during replay and preserves the welcome reading offset
through reflow and returning to Chat. Latest and a new send retain their
explicit follow behavior. This fixes confirmed control-flow defects; native
touch routing still needs a phone check.

**`malformed_stream: stream ended before completion` means the selected
protocol's completion marker was missing.** Chat accepts `[DONE]` or a final
`finish_reason`; Messages accepts `message_stop` or `stop_reason`; Responses
requires `response.completed`. The shared SSE decoder already accepts an EOF
tail without a final blank line, BOM, CR/CRLF, multiline data and event metadata.
No valid framing false positive was found in those paths.

A truncated provider/gateway response or incompatible provider Protocol can
produce this error. The companion buffers the upstream body and can report
HTTP completion at clean EOF even if an SSE completion event never arrived;
the client then rejects that body. A native IOException instead fails the
companion job. There is no evidence the companion itself cut a valid stream.
Diagnostics now name the missing marker or a recognizable protocol mismatch.
Partial answers and tool calls stay terminal failures and are not executed or
automatically replayed.

The desktop bridge also rejected compatible Chat/Messages streams that closed
after a valid final reason without a separate sentinel. Its completion checks
now match the client; later provider errors still override completion.

## Verification and practical limits

Source, documentation, changed harness expectations and new regression fixtures
are reviewed before building. Generated client bundle and manifest are inspected
before verification. Focused regressions cover repeated stuck polls, independent
Stop, late completion, same-job recovery, folded text assignment, exact reasoning
retention, replay/welcome scrolling, EOF markers, protocol mismatch and terminal
stream failures.

Passed: poll ownership (3 cases/14 assertions), HTTP diagnostics (10/50),
companion deadlines (15/54), discovery (50/207), mobile relay (28 checks),
bridge concurrency (13 checks), mobile scrolling/reading/viewport (18/79),
reasoning retention/display (9/47), stream completion/transport/provider
compatibility (83/1,514), and bridge streaming (27 tests). Native static checks
passed for 217 files; the official Luau compiler accepted the changed sources
and bundle. Client and bridge deterministic freshness checks passed. The full
native suite was not run.

The selected chat regression suite exposed two existing failures concerning
busy composer admission and the active context model. Both reproduce against
the committed release bundle in an isolated baseline; neither is introduced by
these fixes. The changed reasoning scenarios passed.

The companion uses bounded provider buffers, four active jobs, a 32 MiB retained
body budget, 60-second receipt retention and a periodic ownership-lease sweep.
Normal thinking does not install native remote hooks or trigger decompilation.
No forced native coroutine closure was found in the inference path. These
findings narrow the investigation; they do not rule out executor/native faults,
Android memory pressure, provider interruption or device-specific touch issues.

To attribute the crash, obtain the reporter's device/Android version, executor
and version, UAI/companion versions, provider/model and approximate failure time,
then compare the Roblox/executor native crash or Android Logcat record with the
companion's request activity. Test scrolling on empty Chat, during long history
loading, after returning to background messages, while a reply arrives, and
after tapping Latest. These offline fixtures cannot establish native rendering,
touch behavior or that the reported crash has stopped.
