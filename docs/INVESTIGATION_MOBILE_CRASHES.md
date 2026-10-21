# Mobile crash, scrolling and stream investigation

Updated October 21, 2026. Reports: Roblox crashes when the AI starts thinking; the
companion patch initially worked, then crashes recurred. A separate report says
mobile scrolling fails, presumed to be the native Chat window. The reporter has
now supplied a native crash summary, described below. Device model, Android and
executor versions, provider/model, installed UAI/companion versions and a complete
native tombstone remain unavailable.

Client, bridge, Windows desktop and Android companion fixes are included in the
unified 3.6.5 release. The offline verification below does not establish that the
reported native crash has stopped.

## Reporter evidence

The supplied summary identifies Android arm64, Roblox build `74100`, signal
`SIGSEGV` (`11`) and fault address `0x148`. Its last recorded operation is
`EXECUTE SCRIPT`, timestamped `2026-10-19T14:41:31.244Z`. That timestamp precedes
the October 20 client fixes and 3.6.1 release; the summary does not establish that
the same crash occurred with those updates installed.

A segmentation fault at a low address suggests invalid native memory access,
such as dereferencing an invalid pointer. It differs from an Android low-memory
killer termination. This establishes a native crash in the reported Roblox
process, but the summary has no module/stack frames that identify Roblox,
executor code, HTTP, UI text layout or another native component as the faulting
path. `EXECUTE SCRIPT` is the last recorded operation, not a proven faulting
function. A symbolized tombstone or equivalent native backtrace is needed to
attribute that path. Memory pressure can still affect native code, but an LMKD
kill alone does not explain this `SIGSEGV` summary.

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

Client 3.6.5 extends this ownership across ordinary native HTTP exchanges on
touch-only hosts, including discovery, different jobs and captured native
aliases. A process-global lane survives client unload/reload until its original
worker actually returns. Stop uses a separate single cancellation lane. A Lua
deadline never releases either unfinished native call. Desktop native capacity
keeps its existing parallel behavior.

**Unusable completed replies could be fetched repeatedly.** An oversized or
malformed native reply previously looked like a lost poll, so an unlimited job
could fetch the same unusable receipt again. Client 3.6.5 treats those received
response categories as terminal, cancels the original job once and stops polling
without replaying inference. Silent polls also skip diagnostic body formatting;
ordinary retained diagnostic excerpts are shortened before normalization.

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

The 3.6.5 follow-up passed mobile native ownership (6 cases/16 assertions),
expanded reasoning (4/22), relay response/ownership (8/35), mobile routing
(38 checks), and 80 companion JVM tests across 11 suites. Android release lint
passed with zero errors, 24 warnings and two informational items. The signed
3.6.5/code 6 APK passed metadata and production-certificate inspection.
See [3.6.5 verification](TESTING_3.6.5.md) for the unified release record.

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

## Remaining pressure points

The companion's four active jobs can each buffer up to 8 MiB of upstream data.
Those in-flight buffers are separate from its 32 MiB budget for completed
receipts. UTF-8 conversion, retained-byte counting and JSON response/envelope
serialization add temporary copies. Gzip request decoding similarly holds wire,
expanded and decoded representations while checking its 8 MiB wire/expanded
limits. These bounds do not describe the whole process's peak memory. The
foreground service and partial wake lock keep work running; they do not exempt
either app from Android memory management. The companion has no code that
normally closes the Roblox process, but the two apps share the phone's memory.

Client 3.6.5 bounds expanded touch-only reasoning to an 8 KiB presentation excerpt
before Markdown formatting and native measurement, with a 32 KiB RichText cap.
It labels the excerpt and retains original reasoning in context and persistence.
The byte limits are conservative choices, not measured crash thresholds. There
is currently no full-trace copy control on the disclosure. Folded reasoning
avoids native body layout. Live text previews use one label with a
64 KiB preview bound and roughly 100 ms updates. Final Markdown virtualizes
blocks and chunks long lists; one very long paragraph can remain one large
native label. These are presentation risks to reduce independently, not an
attribution of the reported `SIGSEGV`.

Companion 3.6.5 counts complete UTF-8 response bytes before escaping retained
provider bodies into JSON. Both direct replies and the nested `/api/executor`
envelope must fit the client's existing 8 MiB cap. A 2 MiB provider body made
entirely of quotes expands beyond that limit inside the executor envelope, even
though its direct reply fits. Oversized replies now return fixed HTTP/status 413
without discarding the receipt or repeating inference. Permitted replies still
use full-body serialization, so this avoids oversized delivery without removing
all temporary allocation.

The companion sends the provider body only when it finishes, with no live
reasoning preview. If Roblox closes while the companion is still receiving a
quiet response, newly received reasoning cannot yet be entering the client UI.
Request preparation, native polling, other client activity and system pressure
remain possible at that stage. Record whether the app had received the response
before the closure instead of treating "thinking" as a precise transport stage.

## Safe device attribution

No physical or usable emulator device is connected in this workspace, and no
reporter tombstone or Android system log is available. The existing emulator logs
describe Windows emulator failures before Android boot; they do not provide
evidence about Roblox on the reporter's phone.

On a USB-debugging Android phone, confirm the actual Roblox/executor package
name. `com.roblox.client` below is the standard Roblox package; an executor may
use another. Record device model, Android and executor versions, installed UAI
and companion versions, provider/model, and local/UTC time around one controlled
reproduction. Avoid hardware identifiers, provider keys, pairing tokens, message
contents and complete unfiltered Logcat exports.

On Android 11 or later, inspect the process exit reason after the closure:

```powershell
adb shell dumpsys activity exit-info com.roblox.client
adb shell dumpsys activity exit-info dev.projectuai.relay
```

Compare timestamps and reasons: `LOW_MEMORY` points to Android memory pressure;
`CRASH_NATIVE`, signal details and a tombstone point to native failure. A relay
process exit and a Roblox process exit are separate events. Availability and
detail depend on Android/OEM permissions; missing records do not prove survival.

Capture small memory snapshots before the request, during the wait and after the
response, using the same package names:

```powershell
adb shell dumpsys meminfo com.roblox.client
adb shell dumpsys meminfo dev.projectuai.relay
```

For one controlled reproduction, stream only Android system memory/crash tags
and stop collection when the failure occurs:

```powershell
adb logcat -v threadtime -b main -b system -b crash 'lmkd:I' 'lowmemorykiller:I' 'ActivityManager:I' 'libc:F' 'DEBUG:F' 'crash_dump64:I' 'AndroidRuntime:E' '*:S'
```

Share only the relevant timestamps, process/package names, exit reasons, signal,
fault address and module/stack frames after reviewing for private identifiers.
Do not clear existing logs first. A native backtrace is more useful for this
`SIGSEGV` than an inference error message.

## Controlled polling without a provider key

The existing [phone diagnostic tools](../companion/tools/README.md) separate
loopback/native polling from provider availability and chat rendering. Run
`loopback_probe.lua` first. Then start the 45-second local fixture on the computer
and forward its port over USB:

```powershell
node companion/tools/delay_fixture.js
adb reverse tcp:8791 tcp:8791
```

On the phone, start UAI Relay and run `relay_probe.lua` with
`UAI_RELAY_PROBE = { url = "http://127.0.0.1:8791/probe", port = 8790 }`.
It uses a controlled nonce, no provider credential and no chat UI; its report
contains timings and fixed categories instead of tokens or response bodies.
Remove the mapping afterward with `adb reverse --remove tcp:8791` and stop the
fixture. This deliberately verifies repeated polls of the same fixture job ID;
it does not authorize replaying an uncertain real inference.

A closure with this fixture would narrow the investigation to native transport,
client/executor activity or system behavior. A successful fixture run does not
rule out a payload-size or UI problem in the real request. Compare system exit
evidence with companion received-byte/activity timing in both cases.

Separately test scrolling on empty Chat, during long history loading, after
returning to background messages, while a reply arrives, and after tapping
Latest. Offline fixtures cannot establish native rendering, touch behavior or
that the reported crash has stopped.
