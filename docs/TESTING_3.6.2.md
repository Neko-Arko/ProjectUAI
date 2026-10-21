# Project UAI bridge 3.6.2 verification

Prepared October 21, 2026. Bridge 3.6.2 addresses the remaining
`OpenCode could not verify that a desktop tool was blocked` failure after 3.6.1.
Client remains 3.6.1; desktop and Android downloads remain 3.6.0.

The native execution wrapper could omit its own permission request. A tool state
could also become visible before its matching pending permission. The fix adds
an execution gate in the isolated native server and waits for matching permission
readiness before confirming interruption and returning a blocked-action receipt.
Exact UAI calls on the private remote MCP server retain the normal Roblox handoff.
Native tool schemas remain present for free-model compatibility.

Changed source, tests and documentation were manually audited before building.
The generated bridge manifest and decoded package were inspected before the
focused native regressions. The package preserves the original seven root files
and embeds the adapter and its local plugin generator in `server.js`.

Checks passed:

- Native adapter: 21 tests. The fixture imports the actual generated execution
  plugin and exercises blocked `execute`/HTTP code, delayed and partial pending
  permissions, streamed input transitions, per-location plugin activation,
  inactive guards, exact session tool scope, interruption and Stop.
- OpenCode discovery, authenticated bridge transport, security and updater:
  35 passed, one Unix-only test skipped on Windows. Includes compatibility with
  the shipped 3.1 updater, idle activation, rollback and pairing-token retention.
- Existing client OpenCode capability harness: 9 assertions. Actual scoped
  scripting loop: 7 cases, 29 assertions, including blocked-action recovery.
- Source/fixture/publication-script syntax and bridge build freshness checks.

The installed official OpenCode CLI 2.0.32 was inspected and probed in isolated,
authenticated loopback servers. Live native `execute` performed internal search
without a permission request before the guard was installed, reproducing the
missing evidence behind the previous fatal error. Denying every native tool
instead caused `FreeTierError`, so the fix preserves those schemas. Fresh request
locations also initially reported no active plugin for roughly 300 ms; the
adapter now waits for its guard before submitting any prompt.

Live production adapter checks passed with `deepseek-v4.1-flash-free` and
`big-pickle`: text, declared Roblox lookup handoff, and supplied tool-result replay.
Big Pickle selected native `execute`; the adapter returned HTTP 200 with a reserved
`opencode_host_action` receipt after confirmed interruption. Replaying that actual
receipt through DeepSeek Chat and Big Pickle Responses produced declared Roblox
lookup calls. Big Pickle Responses also passed direct tool handoff. No host
permission was approved and no real Roblox action was executed; these probes
verify provider transport and continuation with synthetic tool results. The full
native suite and Roblox rendering/input were not exercised for this bridge patch.

## Follow-up with the handover API key

The initial native CLI checks above used the official free-model connection
without supplying a provider API key. A follow-up used the designated secondary
OpenCode key from the private handover, read only into memory.

Requests carrying that key through the production inference bridge passed
DeepSeek text, continuation from the actual blocked `execute` receipt, and
tool-result replay, all HTTP 200. Duplicate submissions retained the same job.
The native backend intentionally does not forward provider keys into the CLI.

Direct requests to `/zen/v1/chat/completions` sent the same real key upstream
and used the production Lua adapter's request builder, desktop headers, seven
compatibility declarations and response parser. DeepSeek passed exact text,
`uai_lookup` invocation and replay of the returned call ID, arguments and
reasoning. The complete tool stream ended with `tool_calls`; synthetic results
were supplied without executing a host or Roblox action.

The previously verified `muse-spark-1.3-contributor-free` Responses model returned
HTTP 410 `ModelDeprecated`. The authenticated current model list supplied no
free Muse/GPT/Grok replacement, so direct keyed Responses inference was not
verified in this follow-up. Native Responses checks above remain valid for the
tested CLI catalog. No private key was written to source, artifacts or logs.

The stable release is `bridge-v3.6.2` with `bridge-release.json` and
`uai-bridge-package.json`. Installed desktop 3.6.0 checks this release through its
existing bridge updater and activates it when work and retained receipts are idle.
No desktop executable or client bundle rebuild is required for this bridge fix.
