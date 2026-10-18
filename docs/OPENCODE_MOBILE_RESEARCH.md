# OpenCode mobile investigation

Research date: October 18, 2026. This records evidence for a phone workaround;
it does not certify the Android companion or a native phone executor.

The current evidence does **not** establish that OpenCode free models categorically
exclude Android. There are viable transport and runtime candidates, but neither a
model listing nor a CLI that starts proves that inference works. The next decisive
check is text, tool invocation and tool-result replay through the actual Android
HTTP stack, followed by the companion and a phone executor.

## What has been observed

| Check | Result | What it establishes |
| --- | --- | --- |
| October 18 Windows Node request to `big-pickle` with an identifying Project UAI User-Agent | HTTP 403 | That request identity was refused on the tested connection. |
| Same baseline with the existing desktop compatibility identity and tool declarations | HTTP 200, `PONG`, about 1.8 seconds | The existing request shape still worked from Windows. This is not Android evidence. |
| Windows Java 17, actual OkHttp 4.12.0, `big-pickle` text/tool/replay | Three HTTP 200 responses; exact `PONG`, validated `uai_probe` arguments, exact `NEBULA_42` replay | OkHttp can carry the accepted request shape with the companion's connection settings on a Windows JVM. This does not test Android TLS. |
| Official npm metadata | `@opencode/cli` and its Linux ARM64 musl package both report `2.0.32` | A current official ARM64 Linux binary is available. |
| Android emulator with OkHttp | Not executed: host emulators failed before Android booted | Actual Android provider acceptance remains unverified. |

The historical desktop matrix, including real tool/replay checks, is in
[OpenCode 3.2 validation](OPENCODE_3.2_VALIDATION.md). Its Windows results must not
be promoted into a mobile support claim.

The live JVM probe used the authorized secondary credential only in memory, passed
to the Java process through stdin. It used the companion's OkHttp 4.12.0 settings:
15-second connection establishment, no read/write/total call deadline, retries and
redirects disabled, and `accept-encoding: identity`. The three requests retained
the same session headers and compatibility declarations. Text took **3278 ms**,
the harmless fixture tool request **3953 ms**, and tool-result replay **4090 ms**.
No real host or Roblox tool was executed. Public discovery first confirmed that
`big-pickle` was available. Probe source is local and ignored; no key, request
payload or raw provider response was written to a report.

No physical Android device was attached. On this Windows host, emulator 37's crash
handler suspended QEMU before the Android kernel started. Emulator 33, tested with
x86 and x64 images and software CPU/GPU variants, exited with Windows access
violation `0xc0000005` before boot. These host failures provide no evidence about
the companion's behavior on Android. JVM tests and successful APK compilation
cannot substitute for Android TLS, executor loopback access, background survival
or native rendering/input checks. The
[credential-free device relay probe](../companion/tools/README.md) now provides
the transport measurement: a controlled response taking at least 35 seconds,
short executor calls, exactly one upstream dispatch and confirmed cancellation.
Its three local HTTP fixture tests passed, including a 35.15-second delay, and
the simulated Lua probe contract passed 406 checks. These harness results are
separate from a real phone run.

The remaining acceptance requirement is an actual Android phone running the
companion and a mobile Roblox executor: first collect a passing transport report,
then verify OpenCode text, harmless tool invocation and tool-result replay through
that same phone's companion. Confirm Stop and background behavior on the target
device. A successful controlled fixture does not by itself test OpenCode; a JVM
OpenCode response does not by itself test the phone. Until these checks are
observed, the mobile workaround remains a candidate and the original goal is open.

## Companion defects identified during this investigation

Source review found a concrete protocol mismatch before any provider request:
the client serialized its remaining timeout as fractional seconds, while Kotlin's
`SubmitRequest.timeout` is an integer. Time spent on the preceding hello could
therefore make an otherwise valid submission fail decoding. The client now rounds
finite wire budgets to integer seconds.

The client also enforced a 300-second total wait despite the companion owning the
provider connection. The updated contract negotiates `timeout:0` only when hello
advertises `capabilities.inference = {schema:1, unlimited:true}`. Explicit caller
budgets and legacy companions remain finite; each executor-visible exchange stays
short. Provider-side limits still apply.

The client regression suite passed 54 assertions across 15 cases, including all four
provider protocols beyond 300 seconds, a stalled native poll, exact caller deadlines,
pairing repair, start-after-Roblox discovery and cancellation. Existing relay,
lifecycle and provider checks also passed after rebuilding and inspecting the native
bundle. These offline results explain and verify specific client failure modes;
they do not establish Android provider acceptance or native executor compatibility.
See [the client regression cases](../test/mobile_deadlines.lua) and
[the companion engine tests](../companion/app/src/test/kotlin/dev/projectuai/relay/engine/JobEngineTest.kt).

## Candidate paths

| Path | Evidence | Remaining proof |
| --- | --- | --- |
| Existing Kotlin companion forwards the accepted request shape with OkHttp | Live Windows JVM OkHttp text/tool/replay succeeded with the companion's connection settings. The companion owns long connections and exposes short loopback polling. | Actual Android text/tool/replay, executor loopback access, cancellation and background survival. This is the first candidate to test because it needs no CLI runtime. |
| Official OpenCode v2 musl CLI hosted by Termux; companion calls its authenticated local server | A community wrapper and upstream reports describe working Android CLI/server installations without root or proot. | Current binary startup, DNS/TLS, free inference, tool handoff and Android process lifetime. Installation reports alone are insufficient. |
| Official CLI and musl loader packaged inside the companion APK | Foreground `serve` is a real upstream command; Android permits packaged native executable code. | APK packaging, native dependencies, executable memory restrictions, DNS, seccomp, memory use and full inference. This is an architectural option, not an implemented fallback. |
| Phone connects to an OpenCode server on a computer or private host | Upstream documents authenticated network server and browser access. | UAI integration and the actual phone connection. This requires another host and does not solve a phone-only setup. |

No public proxy is needed for these candidates. The retired UAI OpenCode proxy
remains retired. OpenCode Go subscription entitlement is separate from the free
model investigation.

## Current official runtime and Android constraints

The v2 package is [`@opencode/cli`](https://registry.npmjs.org/@opencode/cli/latest),
currently `2.0.32`. [`@opencode/cli-linux-arm64-musl`](https://registry.npmjs.org/@opencode/cli-linux-arm64-musl/latest)
has the same version, approximately 206 MB unpacked, and npm SHA-512 integrity
metadata. The legacy `opencode-ai` package currently reports `1.19.3`; the older
`@opencode-ai/cli` namespace also does not identify the current stable v2 package.
Installers must choose the correct namespace and verify the downloaded artifact.

Official [postinstall source](https://github.com/anomalyco/opencode/blob/dev/packages/cli/script/postinstall.mjs)
still omits Android from its platform map. The proposed Android mapping in
[PR #48405](https://github.com/anomalyco/opencode/pull/48405) was closed without
merging. Linux musl and Android Bionic are different runtimes; a Linux package's
existence is not an Android prebuild.

The current [CLI build](https://github.com/anomalyco/opencode/blob/dev/packages/cli/script/build.ts)
uses `Bun.build` with compilation. A separate
[Node build](https://github.com/anomalyco/opencode/blob/dev/packages/cli/script/build-node.ts)
exists. Some community reports say v2 replaces Bun entirely; the current source
does not support treating that statement as a general runtime guarantee.

[nemoobc/opencode-termux](https://github.com/nemoobc/opencode-termux) adapts the
official musl executable. Its current wrapper patches only `PT_INTERP` and supplies
libraries through `LD_LIBRARY_PATH`: its earlier RPATH patch caused crashes on
large binaries. Its ARM64 musl loader redirects resolver files to Termux's prefix.
The wrapper's [upstream report](https://github.com/anomalyco/opencode/issues/50203)
describes Android TUI and background-server success. These are community reports,
not a Project UAI device test or an endorsement of unreviewed installer scripts.
The wrapper currently pins an older upstream version, so installing it is not
equivalent to testing official `2.0.32`.

The companion targets Android 36. Android's
[execution restriction](https://developer.android.com/about/versions/10/behavior-changes-10#execute-permission)
prevents modern apps from executing downloaded code from writable app storage.
An embedded runtime would need packaged native code, with appropriate
[native library extraction](https://developer.android.com/guide/topics/manifest/application-element#extractNativeLibs),
rather than a download-and-chmod installation into `filesDir`. Upstream
[foreground server code](https://github.com/anomalyco/opencode/blob/dev/packages/cli/src/server-process.ts)
can run directly; this avoids relying on the CLI's background-service self-reexec
path. It does not prove that every native dependency works inside an APK.

## What a free-tier refusal does and does not mean

[Issue #52903](https://github.com/anomalyco/opencode/issues/52903) reports the
official v2 CLI starting under Android 16, Termux and proot Ubuntu, then failing
free inference. The reporter later wrote "Fixed" without identifying a method.
This shows why startup is an inadequate acceptance test.

The same message also occurs on official desktop installations. Controlled
[network comparisons in #56334](https://github.com/anomalyco/opencode/issues/56334)
describe the same client, account and model succeeding on one connection and
failing again on the original connection. An October 18
[WSL2 report in #56681](https://github.com/anomalyco/opencode/issues/56681) likewise
reports Wi-Fi failure and mobile-hotspot success with `2.0.32`. These reports do
not identify the server's rule, but they contradict treating the error text as
proof that Android itself is forbidden.

[Issue #50627](https://github.com/anomalyco/opencode/issues/50627) also documents
tool removal triggering the same refusal inside the official client. Keeping
required declarations visible while leaving host actions subject to approval is
consistent with the existing UAI CLI adapter. A workaround must not grant shell
or filesystem execution merely to obtain model text.

For remote operation, upstream documents
[server authentication](https://opencode.ai/docs/server/) and
[network browser access](https://opencode.ai/docs/web/). The current v2 server's
actual OpenAPI and authentication behavior must be inspected: some prose examples
still describe the older API surface. A remotely hosted server remains a separate
option from a phone-only companion.
