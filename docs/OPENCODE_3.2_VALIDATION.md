# OpenCode 3.2 validation

Live checks on October 15, 2026, approximately 11:04–11:44 UTC, verified both
the direct desktop workaround and the installed native CLI bridge. These are
availability snapshots, not a guarantee that a free model will remain online.
Report problems and compare current availability in the
[Project UAI Discord](https://discord.gg/9xYyyYuKap).
Additional Go discovery and keyed checks on the same date are recorded below.

## Scope and handling

- Native runtime: the already installed OpenCode Desktop `opencode-cli.exe`,
  version **2.0.27**. No CLI binary was downloaded into or packaged with UAI.
- Direct free-model requests used the designated secondary OpenCode key from
  the ignored local handover. The separate Go check used the temporary Go key
  designated for that investigation. Probes read keys into memory; no key was
  placed in a script, process argument, repository artifact, or report.
- Native checks used fresh private XDG directories and the public OpenCode
  provider, without the user's saved OpenCode credentials or conversations.
- The initial free-model matrix exercised only models whose native catalog
  reported zero input, output, cache-read and cache-write prices. The separate
  Go check made four minimal requests to the reported subscription model;
  all were refused before a model response.
- Every native test session was owned by the probe and deleted afterward. Only
  owned servers were stopped. No filesystem or shell permission was approved.
- Scripts and changed inputs were manually reviewed before their live checks.
  The complete native test suite was not run.

These checks ran from Windows Node.js and Windows `curl.exe` 8.9.1 using
Schannel, plus the official native server. They do not establish native Roblox
executor rendering/input behavior or mobile support. Mobile OpenCode free-model
access was unsupported at this time; a later correction establishes that mobile
OpenCode requires the UAI Relay app from Discord. Paid Go is a separate keyed service.

## Go subscription investigation

The [official Go documentation](https://opencode.ai/docs/go/) identifies
`https://opencode.ai/inference/go/v1` as the current Go base. It asks other coding
agents to identify themselves with their own User-Agent and send a stable
`x-opencode-session` per conversation. Go and Go Plus subscriptions belong to a
single-member workspace; a client needs the API key for the subscribed workspace.

Unauthenticated discovery at both `/inference/go/v1/models` and
`/zen/go/v1/models` returned **200** and **37 models**, including
`deepseek-v4.1-flash`. These are public catalogs: successful discovery does not
validate a key, an active subscription, or the workspace's privacy settings.

On October 15, 2026, shortly before 12:20 UTC, the designated temporary Go key
was tested with `ProjectUAI/3.2`, a stable session header, streaming Chat, and one
harmless fixture tool schema. Each request asked only for `PONG`; the tool/result
stages were conditional on successful text and therefore did not run.

| Route | Model | Result |
| --- | --- | --- |
| `/inference/go/v1/chat/completions` | `deepseek-v4.1-flash` | HTTP 400; Global-regions requirement |
| `/zen/go/v1/chat/completions` | `deepseek-v4.1-flash` | HTTP 400; identical Global-regions requirement |

Both responses contained this upstream message:

```text
Upstream request failed: This Go model requires Global regions. Select Global in your workspace's Privacy settings to use it.
```

After the user reported setting the workspace region to Global, the canonical
probe was repeated at approximately **12:22 UTC**. It returned the same HTTP 400
and message. The legacy alias was not retried. That result alone does not
distinguish propagation delay from changing a different workspace's setting.
A final canonical retry at approximately **12:29 UTC**, after the client rebuild,
returned the same HTTP 400.
No further inference requests were made.

This did not reproduce the user's **403** message, `An active OpenCode Go
subscription is required to use Go models.` Both bases reached the same region
refusal with the supplied test key, so changing the legacy alias alone is not an
established fix for that 403. A subscription refusal should direct the user to
check the selected provider's key and its subscribed workspace. A region refusal
should preserve the upstream Privacy-settings instruction. A retired-proxy
**410** is a separate routing failure and does not establish either condition.

The probes did not change account, subscription, billing, or privacy settings.
No model text or tool call was generated. Go text, tool invocation, and tool-result
replay remain **unverified live** until the workspace permits this model. The free-tier
mobile restriction does not establish that paid Go is unsupported on mobile;
these Windows probes did not test mobile Go.

Go also requires model-specific protocols. The official endpoint table routes
DeepSeek, GLM, Kimi, LongCat, MiMo and Step models through Chat Completions;
GPT, Grok and Muse through Responses; Claude, MiniMax and Qwen through Messages;
and Gemini through its native model endpoint. A public model listing is not
proof that every model accepts every adapter or that native Gemini is supported
by UAI.

## Direct desktop identity

The previous Chat defaults, `opencode/stable/2.0.29/cli` with CLI project/request
headers, returned **403 FreeTierError** for Cat Jam and Muse Spark in both tested
HTTP hosts. The existing Responses desktop identity worked, and applying that
same identity to Chat made the direct Chat workaround work too:

```text
User-Agent: opencode/latest/2.0.27/desktop
x-opencode-client: desktop
x-opencode-session: <valid stable session id>
x-opencode-session-id: <same session id>
x-session-affinity: <same session id>
X-Session-Id: <same session id>
Accept: */*
```

The successful default omitted `x-opencode-project` and `x-opencode-request`.
The session ID used the existing timestamp packing and remained stable across
the text request, tool call and tool-result replay. Both adapters kept streaming
and the seven existing compatibility declarations. The real fixture function
`uai_lookup` was supplied alongside those declarations; the declarations were
never executed as host tools.

The three-step test was: request `PONG`; request
`uai_lookup({"lookup_key":"project_uai_fixture"})`; then replay its fixed result
and check the assistant's answer. Chat replay retained reasoning content where
the provider supplied it. Responses replay used `function_call` and
`function_call_output` items.

| Host and route | Model | Text / tool / replay time | Result |
| --- | --- | --- | --- |
| Node, `/zen/v1/chat/completions` | `cat-jam-free` | 1.354 / 1.123 / 0.779 s | Three HTTP 200 responses; exact fixture replay |
| Schannel, `/zen/v1/chat/completions` | `cat-jam-free` | 1.618 / 1.414 / 1.400 s | Three HTTP 200 responses; exact fixture replay |
| Node, `/inference/v1/responses` | `muse-spark-1.3-contributor-free` | 1.918 / 3.419 / 1.148 s | Three HTTP 200 responses; exact fixture replay |
| Schannel, `/inference/v1/responses` | `muse-spark-1.3-contributor-free` | 1.767 / 2.093 / 2.466 s | Three HTTP 200 responses; exact fixture replay |

The same tests also passed on the official `/inference/v1/chat/completions`,
`/inference/openai/v1/chat/completions`, and `/inference/openai/v1/responses`
aliases for their respective models. Cat Jam returned `ModelProtocolUnsupported`
on Responses, and Muse Spark returned that error on Chat. Preserve protocol
selection; swapping every model to a single protocol would break working models.

## Current free-model matrix

The native `/api/model` catalog supplied these ten exact IDs. All ten were
enabled and active, reported tool support, and had zero prices in every reported
tier. Native text checks used real CLI schemas with permissions set to `ask`.
The native MCP checks used a harmless fixture server and the CLI's default Build
agent; they preceded the production adapter's dedicated UAI agent validation.

| Model ID | Native PONG | Native MCP round trip | Direct desktop text / tool / replay |
| --- | --- | --- | --- |
| `cat-jam-free` | 1.461 s | Exact result, 3.292 s | 200 / 200 / 200; exact result |
| `longcat-2.5-preview-free` | 4.295 s | Exact result, 13.252 s | 200 / 200 / 200; exact result |
| `space-bunny-free` | 2.249 s | Exact result, 4.636 s | 200 / 200 / 200; correct result with extra prose |
| `mimo-v2.6-flash-free` | 2.910 s | Exact result, 10.808 s | 200 / 200 / 200; exact result |
| `step-5-preview-free` | 1.496 s | Exact result, 10.597 s | 429 on first request: upstream endpoint unavailable |
| `deepseek-v4.1-flash-free` | 2.557 s | Reported tool unavailable, 4.226 s | 200 / 200 / 200; exact result |
| `muse-spark-1.3-contributor-free` | 1.852 s | Exact result, 5.479 s | 200 / 200 / 200 on Responses; exact result |
| `nemotron-3.5-lightning-free` | 1.959 s | Native permission API serialization error, 6.080 s | 200 / 200 / 200; exact result |
| `nemotron-3-ultra-free` | 2.953 s | Exact result, 10.033 s | 200 / 200 / 200; exact result |
| `big-pickle` | 2.310 s | Exact result, 9.013 s | 200 / 200 / 200; exact result |

The direct matrix used Node and the corrected desktop defaults; the host
comparison above independently checked Schannel. Step 5 was not retried after
the availability refusal. The two native Build-agent tool failures are recorded
as failures, not silently counted as successful tool support. The DeepSeek
response did not establish whether the problem was model behavior or catalog
settlement. Nemotron Lightning's local API error identified
`data[0].metadata.include` as an invalid JSON value.

## Native API and tool handoff

The installed v2 server exposes its schema at `/openapi.json`. Its real API uses
the `/api` prefix. Legacy `/global/health`, `/doc`, and `/provider` paths can return
the web application's HTML with status 200; status alone is not readiness.
The initial `/api/provider` and `/api/model` snapshots can be empty while the
built-in plugin starts. A later snapshot contained the public provider and all
ten free models.

The verified flow is:

1. Start the installed binary on a unique loopback port with a generated Basic
   password and isolated config/data/cache/state directories.
2. Read `/openapi.json` and `/api/model`; wait for a valid model catalog.
3. Register the request's authenticated loopback MCP endpoint with
   `PUT /api/experimental/mcp/<name>` for its unique request location.
4. Create `POST /api/session` with the location, selected model, UAI agent, and
   explicit permissions. Send `POST /api/session/<id>/prompt`.
5. Read `/api/session/<id>/message`, return real UAI tool calls to the Roblox
   caller, then interrupt and delete the temporary native session.

Missing or incorrect Basic credentials returned **401**. Setting every tool
permission to `deny` hid the real schemas and caused every free-model text check
to receive **403 FreeTierError**. Keeping native schemas visible with `ask`
permissions restored text inference. The bridge permits only its own declared
MCP tools; it does not approve native filesystem, shell, or other host actions.

Real MCP calls arrive with the original function name and assembled arguments.
The CLI permission name is `<server>_<function>`. The bridge holds the MCP reply
while Roblox owns the tool execution. A held tool has a `running` state and an
assembled input, while its assistant has `time.streamed` but neither `finish`
nor `time.completed`.

The installed CLI's event projection maps `session.step.streamed` to
`assistant.time.streamed`; its loop emits this after the provider stream ends
and before awaiting tool execution. Waiting for `finish` or `time.completed`
therefore deadlocked the first adapter probe. The corrected adapter waits for
`time.streamed` and the complete matching MCP call batch. The same live probe
then returned its function call successfully.

Repeated runtime MCP mutations in a reused native location produced stale tool
availability during exploratory checks. Separate request locations worked and
are used by the bridge.

The installed 2.0.27 normalization code keeps uncached input, visible output,
reasoning, cache reads and cache writes as separate counts. The bridge maps these
to total prompt tokens (`input + cache.read + cache.write`) and total completion
tokens (`output + reasoning`), retaining cache/reasoning details on both Chat and
Responses. A focused regression covers this accounting; the client accepts both
wire usage shapes without replacing reported counts with text estimates.

## Production adapter and bridge checks

Direct calls through the production `bridge/opencode.js` adapter verified:

| Check | Result |
| --- | --- |
| Cat Jam text | Exact PONG, 3.228 s |
| Cat Jam real tool handoff | Correct function and arguments, 2.506 s |
| Cat Jam result in a fresh request | Exact fixture text, 2.331 s |
| MiMo actual red PNG attachment | Answer `Red`, 26.817 s |
| Muse Spark Responses tool handoff | Correct `function_call`, 4.065 s |
| Muse Spark Responses result replay | Exact fixture text, 4.672 s |
| Cancellation of an unanswered admitted request | Returned `Stopped` after the 45-second probe deadline |
| Next request after cancellation | Exact PONG, 4.205 s |

The image was supplied as an actual `data:image/png;base64,...` attachment to
the native prompt's `files` array; image recognition was not inferred from an
opaque URL. The cancellation probe had received no output frames when its
deadline fired. It proves cancellation of an admitted unanswered request, not
mid-token streaming cancellation.

A final test exercised the actual Supervisor and `bridge/server.js` worker on a
random loopback port, with automatic updates disabled only for the test:

- `/api/hello` reported the native backend ready.
- Authenticated `/api/opencode/models` returned all ten models after the
  zero-cost catalog filter was applied.
- `/api/inference` admitted the request with **202**, then completed with
  **200** and exact `PONG` in **2.854 s**. The submitted upstream Bearer key was
  intentionally invalid, proving this request used the native public-provider
  path rather than the direct keyed route.
- The worker had exactly one observed owned native CLI child. Stopping the
  supervisor stopped both the bridge worker and that native child.

The deprecated OpenCode public proxy was not used for any successful check.
Keep direct desktop compatibility, the optional installed-CLI path, explicit
mobile guidance, and the AgentRouter-only public proxy as separate behaviors.
