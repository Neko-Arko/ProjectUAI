# Finding tools efficiently

Open **Tools** to search names, descriptions, groups and risk labels. Words can
match different fields: `file read` finds file-reading actions even when the
registered name uses underscores. The result count updates as you type.
**Parameters & permissions** builds details only for the tool you open, keeping
the full catalog cheaper to browse. Permission changes still apply immediately.

For model-driven work, the Lean and task-specific tool profiles reduce the
declarations sent with each request. They preserve access to otherwise available
tools through `tool_search`; a profile never grants an unavailable capability,
disabled group, denied permission or tool outside the conversation's scope.

```json
{"action":"list","query":"workspace source","limit":10}
```

Search requires every word, matches plain text rather than Lua patterns, and
ranks exact tool names first. Queries are limited to 256 bytes and 16 distinct
words. A blank query retains catalog order. `group` selects one exact group.

```json
{"action":"describe","name":"file_read","limit":2000}
```

Describe returns the normalized schema used in provider declarations. Its
`limit` counts bytes; list limits count rows. List pages contain at most 100
rows, and schema pages request at most 20,000 bytes within the configured tool
result budget. Follow `nextOffset` to continue. This fixes the former shared
100-byte schema limit, which made explicit schema-page reads unnecessarily small.

Call the discovered tool through `action=call` with its exact arguments. UAI
checks its current permission and scope again at dispatch. Search/listing does
not clone all nested schemas, and only describe materializes the selected one.
