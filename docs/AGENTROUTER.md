# AgentRouter in Project UAI

Add **AgentRouter** in Providers, paste your AgentRouter key, and fetch models.
Use the exact ID returned for your account. Model availability and quotas can
change; the provider gallery does not add a fixed list of advertised models.

UAI uses native **Responses** for GPT models on AgentRouter's documented routes.
Existing saved AgentRouter connections work without changing their API selector.
Other models retain the selected protocol, including Anthropic Messages for
Claude. This follows AgentRouter's [Codex guide](https://agentrouter.org/docs/codex.html)
and [Claude guide](https://agentrouter.org/docs/claude-code.html).

The supported HTTPS bases are `https://agentrouter.org/v1`,
`https://api.agentrouter.org/v1`, and the documented alternate
`https://ps.air-outer.com/v1`. UAI's existing authorized AgentRouter proxy route
also retains native Responses. Custom hosts, nonstandard ports and unrelated
paths keep their own protocol settings.

## Tool use and speed

GPT requests go directly to `/v1/responses`, avoiding a rejected Chat Completions
request and an unused duplicate payload. The chosen reasoning effort is sent
explicitly; **Low** favors shorter reasoning work. **Provider default** intentionally
omits the effort setting. AgentRouter may choose a higher default: the live
October 25 probe reported `max` when effort was omitted.

GPT-6.1 Sol and GPT-6 Astra expose Low, Medium, High, Xhigh and Max in the model
picker, matching their official [model references](https://developers.openai.com/api/docs/guides/reasoning).
GPT-6.1 Sol does not support None or Minimal; a Minimal request uses Low.
Model effort changes affect reasoning work, not provider congestion or quotas.

UAI sends its actual tool declarations and keeps optional arguments optional.
Large catalogs continue to use the bounded tool catalog helper. Model tool calls
return to Roblox's usual validation, permissions and execution flow.

Every native request includes UAI's complete current conversation, including
matched tool calls and results. The default is `store: false`; UAI does not
reuse opaque encrypted reasoning items or remote response IDs across requests.
This avoids relying on state tied to one upstream resource in a shared gateway.
Explicit raw provider/request parameter overrides remain available.

Stop, timeouts and incomplete streams remain terminal. A partial reply followed
by a quota error is not a successful answer and is not replayed. Only an explicit
protocol refusal or the existing authorized-client refusal can invoke their
bounded recovery paths.

## Verified behavior on October 25, 2026

The supplied test account's authenticated catalog listed `gpt-5.6-sol`,
`gpt-6-astra`, and `gpt-6.1-sol`. Catalog membership is separate from a successful
inference or available quota.

- `gpt-6.1-sol` completed a two-tool batch using UAI's real `instance_tree` and
  `instance_get` declarations, then consumed simulated Roblox results and
  returned the expected final reply. The first measured pair took approximately
  2.69 and 2.86 seconds. A second check using UAI's new defaults, with no raw
  parameter overrides, also passed in 4.83 and 3.70 seconds. Both tools retained
  optional arguments and the follow-up returned `UAI_TOOLS_OK FixtureMap`.
  No Roblox world writes were performed.
- `gpt-5.6-sol` did not finish within the probe's 45-second deadline. It was not
  replayed after the unknown outcome.
- `gpt-6-astra` returned an explicit regional token-rate quota error. That test
  establishes the visible failure behavior, not successful tool support.

The temporary test credential is excluded from saved provider settings, source,
release artifacts and logs. Public source notices and these measurements are
dated observations, not an uptime, speed or unlimited-use guarantee.

Offline regressions cover route boundaries, effort, optional schemas, tool
history, bounded refusals, cancellation and stream failures:
`test/agentrouter_protocol.lua` and `test/agentrouter_responses.lua`.
