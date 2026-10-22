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

Substantial tool results are copied under the app root
(`evidence/<conversation>/`) with a compact per-conversation index. The normal
inline result is unchanged, so this is additive rather than a replacement.

The default **Large results** policy keeps results at or above 8 KiB, deduplicates
identical results and skips tools that already have a durable home: source and
file reads, memory, conversation reads, the toolbox and the capture readers. A
small result costs more to index than to call again. **Settings → Agent → Tool
evidence** can switch to **All results** or **Off**.

Writes are batched off the tool path: at most 64 queued results / 4 MiB are held,
then flushed in short batches of 8 / 2 MiB. If a fast model produces results
faster than they can be written, new entries are dropped and counted rather than
blocking a tool call or growing memory without bound. Each text/data field is
capped at 256 KiB.

The `evidence` tool reads it:

- `list` / `search` — receipts with tool, time, bytes and a short preview.
- `read` — full `text`, structured `data`, or a `summary`, paged by byte offset.
- `evidence_clear` — remove this conversation's ledger.

This is most useful after compaction removes an earlier tool result. The ledger
is conversation-scoped: another conversation's records are not readable. The
index keeps the newest 200 results / 16 MiB per conversation and removes the
oldest record files. Removing a conversation removes its ledger. Evidence is
local; it is excluded from the support bundle.

## Compaction archive

Compaction replaces older messages with a structured handover, but it does not
discard them. The removed messages are kept as plain text inside the conversation
file, in segments of at most 64 KiB and at most 512 KiB total. The handover
system message is followed by a short line naming the segments, so the agent knows
what exists without carrying their text in every request.

`context_archive` reads only this conversation's archive:

- `list` -- segment ids, message counts, sizes and a preview.
- `search` -- literal matches with segment id and byte offset.
- `read` -- a UTF-8 byte page of one segment, with `nextOffset`.

Use it to recover exact earlier wording or a receipt that the handover summarised.
It is read-only: it does not restore messages to the live context, re-run tools or
change the conversation. The archive is saved and restored with the conversation
and removed with it.

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
