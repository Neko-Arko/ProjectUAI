# Network and payload capture

Project UAI can observe the HTTP calls a script makes and the chunks it compiles,
without acting as a proxy or changing what the script receives. It is a tool for
understanding a loader, not a sandbox and not a replacement executor.

## Workflow

1. Start capture **before** running the loader:
   `net_capture { action = "start", mode = "both", duration = 120 }`
2. Run the loader in the executor (or through `run_luau`).
3. Read the stages with `net_capture_read`:
   - `action = "list"` for HTTP calls, compiled chunks and required modules.
   - `action = "read"` for one record's summary, URL, request, response,
     headers, chunk source or module source.
   - `action = "chain"` for the HTTP → chunk → nested-request graph.
4. `net_capture { action = "stop" }` restores hooks. `clear` removes records.

Capture starts only on an explicit call. It does not install itself at boot.

## What is observed

The runtime installs a fixed set of forwarding wrappers. The agent cannot choose
a function or supply wrapper code.

| Layer | Targets |
| --- | --- |
| Executor HTTP | `request`, `http_request`, `syn.request`, `http.request`, `fluxus.request`, `krnl.request`, `weare.request` |
| Game HTTP | `game:HttpGet`, `HttpGetAsync`, `HttpPost`, `HttpPostAsync` |
| Roblox HTTP | `HttpService:RequestAsync`, `GetAsync`, `PostAsync` |
| Compilation | `loadstring`, `load`, `getgenv().loadstring`, `getgenv().load`, `debug.loadstring` |
| Modules | `require` (ModuleScript and asset IDs) |
| Queued | `queue_on_teleport` |

A wrapper calls the function it replaced and returns its results unchanged. It
records method, URL, status, bounded request and response bodies, headers with
sensitive values redacted, duration, byte counts and a content hash. Errors are
re-raised exactly as they were. A failed recording is swallowed; it cannot break
the script being observed.

`loadstring` and `load` records keep the source that was about to compile,
including source that fails to compile. `require` keeps a readable ModuleScript
`Source` when the host exposes it, and otherwise records the module identity and
why the source was unavailable.

## Why this catches more than a loadstring-only hooker

- **Function objects, not only globals.** A loader that cached `request` or
  `loadstring` before capture started is still observed when the same closure is
  hooked.
- **Both compile spellings.** `load` and reader-style `load` are captured as well
  as `loadstring`; the reader is never consumed.
- **Module loaders.** `require` is forwarded, not replaced with an empty table.
- **No behaviour mutation.** Nothing is spoofed or rewritten: no whitelist
  response, no `continue` rewriting, no `{}` fallback. A loader takes the same
  branch it would without capture.
- **Uncompiled payloads are still visible.** A code-like response body is flagged
  `suspectedCode` even when no chunk reaches the compiler. This is the common
  "it never got the payload" case for custom interpreters and early exits.
- **Hooks before execution.** Start capture first; a loader that already ran is
  not retroactively observable.
- **Self-exclusion.** UAI's own inference, decompiler requests and `run_luau`
  compiles are marked on the coroutine and never recorded. The marker is
  per-thread, so a yielded UAI request cannot hide a loader running elsewhere.

## Linking stages

A chunk is linked to an HTTP record when:

1. the chunk source hash equals the response body hash, or
2. no hash matches, but the call ran on the same coroutine within five seconds
   of the response.

The first is exact; the second is explicitly labelled `link = "thread"`. A chunk
with no parent is shown as a root or marked orphaned when its parent was evicted.
Thread and byte evidence are not proof that the payload executed; only a
captured `loadstring` call proves it reached the compiler.

## Limits and redaction

| Bound | Value |
| --- | --- |
| Records | 500 |
| Total retained bytes | 8 MiB |
| Response body per record | 256 KiB |
| Request body per record | 64 KiB |
| Chunk source | 2 MiB |
| Captured chunks | 32 |
| Default capture duration | 120 seconds (maximum 300; `persistent` is explicit) |

Oldest records are evicted first. Readings use byte offsets with continuation
cursors. Sensitive header values (`Authorization`, `Cookie`, `x-api-key` and
similar) are replaced with `<redacted>`; sensitive query values (`token`,
`api_key`, `secret`, `signature`, `password` and similar) are redacted in the
stored URL. Request and response bodies are not automatically redacted beyond a
bounded preview; treat captured bodies as sensitive.

Exports use the `uai-net-capture` JSON envelope and the verified workspace write
path. A capture larger than the 2 MiB single-file limit must be narrowed with
`record_ids` or cleared first. Exporting without a filesystem fails without
stopping the capture.

## Known gaps

- **Server-side code.** A server `Script` never reaches the client. Only remotes
  and client-side calls are observable.
- **Payloads that never cross a hooked boundary.** A custom bytecode VM that
  executes its own instruction stream without `loadstring`, `load`, `require` or
  a readable module may never produce a chunk. The response body is still stored
  and flagged when it looks like code, but it is not devirtualized.
- **WebSocket traffic.** Not captured in this version.
- **Encrypted or compressed bodies.** The transport wrapper stores the bytes it
  received. Decryption inside the loader is visible only when the result reaches
  `loadstring`.
- **Hook detection and isolation.** An executor that gives a loader a private
  copy of `request`, or a loader that checks function identity, may evade the
  wrapper. There is no anti-tamper bypass.
- **Evidence is not execution.** `chain` shows likely parentage from hashes and
  threads; it does not prove a branch ran.

## Tool reference

### `net_capture` (`write`)

`action = start | stop | status | clear | export`

- `start`: `mode` (`http`, `chunks`, `both`), `host` (up to 16 exact/subdomain
  filters), `method` (up to 8), `duration` (1–300, default 120), `persistent`.
- `stop` / `status`: lifecycle and coverage. A hook that cannot be restored is
  reported as `retained`; it forwards without recording.
- `clear`: drops records; an active capture continues.
- `export`: `record_ids` (up to 100) and `destination`.

### `net_capture_read` (`read`)

`action = list | read | chain`

- `list`: filters `kind`, `host`, `method`, `url`, `status`, `suspected`,
  `after_sequence`, `session_id`; page size 1–20.
- `read`: `record_id` and `section` (`summary`, `url`, `request`, `response`,
  `headers`, `chunk`, `module`), with `offset` and `bytes`.
- `chain`: the retained parent/child graph, bounded to 120 nodes and depth 8.

`net_capture_result_read` pages a retained large list result.

## Verification

`test/net_capture.lua` covers forwarding, redaction, self-exclusion, hash and
thread linking, failed compiles, reader-style `load`, `HttpService`, `require`
failures, code-like responses, filters, expiry, retention limits, revocation,
restore failure, export and degraded hosts. Run:

```bash
luajit test/net_capture.lua
```

The native suite also loads the built bundle with the new group; `node
tools/test_native.js` runs it with the rest of the focused suites.
