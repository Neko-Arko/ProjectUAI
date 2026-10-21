# Tool context, evidence and support

Three capabilities share one goal: keep the agent's context small without taking
capabilities away, keep its evidence after the context is compacted, and make a
failure report useful without exposing credentials.

## Tool profiles

Every offered tool's schema is part of every provider request. The full catalogue
is roughly 27k tokens; a profile declares a smaller set while leaving every tool
callable.

| Profile | Declares |
| --- | --- |
| **All tools** (default) | Every available tool, exactly as before. |
| **Lean** | A core set of files, execution, instance, memory and delegation tools. |
| **Inspect** | Core plus remotes, screen, diagnostics, metadata, web and capture. |
| **Build** | Core plus the code workspace, interface and project tools. |
| **Script UI** | Core plus the code workspace and interface tools. |
| **Integrations** | Core plus Gravity, Infinite Yield, players, character, world and remotes. |
| **Chat** | Core plus in-game chat and players. |

Set it in **Settings → Agent → Tool profile** or `agent.toolProfile` in
configuration. The default stays **All**, so existing behavior is unchanged.

A profile only changes the declarations sent to the provider. It never changes
dispatch scope, permission rules or the conversation's tool groups. Hidden tools
remain reachable through `tool_search`:

- `action = "list"` finds names by query or group.
- `action = "describe"` returns the exact schema pages.
- `action = "call"` runs the tool with its declared arguments.

A tool that is denied, outside the conversation's scope, in a disabled group, or
missing a capability is not listed and cannot be called through the toolbox.

## Persistent evidence ledger

Every tool result is copied under the app root (`evidence/<conversation>/`) with
a compact per-conversation index. The normal inline result is unchanged, so this
is additive rather than a replacement.

The `evidence` tool reads it:

- `list` / `search` — receipts with tool, time, bytes and a short preview.
- `read` — full `text`, structured `data`, or a `summary`, paged by byte offset.

This is most useful after compaction removes an earlier tool result. The ledger
is conversation-scoped: another conversation's records are not readable. The
index keeps the newest 200 results per conversation and removes the oldest
record files. Removing a conversation removes its ledger. Evidence is local; it
is excluded from the support bundle.

## Support bundle

`support_bundle` writes a versioned `uai-support` JSON file under
`exports/uai-support-<time>.json` and returns its verified path. The same action
is available as **Create support bundle** in **Settings → Developer →
Diagnostics**.

It contains:

- build/version, PlaceId and workspace identity
- capabilities, HTTP transport and executor identity
- redacted configuration shape and provider health
- permission mode and rules
- enabled tool groups and profile
- session metadata (ids, titles, message counts — not messages)
- recent HTTP failures without response bodies
- recent redacted log lines
- viewport, input mode and UI settings

It deliberately excludes API keys, authorization/cookie values, custom header
values, memory entries and custom instructions, conversation text, file contents
and captured payloads. It is local-only; nothing is uploaded. A full
configuration export is still the separate, key-bearing migration path.

## Verification

`test/tool_profiles.lua`, `test/evidence.lua` and `test/support_bundle.lua` cover
the profile schema reduction, toolbox scope and permission checks, durable
receipts, truncation and cross-conversation isolation, and bundle redaction and
filesystem failure.
