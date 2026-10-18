# Measure the companion on a phone

These opt-in console probes separate executor/companion failures from model
availability. They use no provider account or API key and do not test OpenCode.
Run them on the target Android phone with UAI Relay started. A desktop or mocked
run proves only that execution host; record the phone, Android version and
executor version alongside any report.

`loopback_probe.lua` checks the `uai-relay` marker, pairing response and
authenticated status. It never prints the pairing token or raw bodies. A PASS
here does **not** demonstrate inference forwarding.

## Long-response measurement

Start the controlled delayed provider with Node.js 18+ on a computer on the same
Wi-Fi network, using that computer's actual LAN address:

```powershell
node companion/tools/delay_fixture.js --host 192.168.1.10
```

The fixture waits 45 seconds before returning a nonce. It serves only `/probe`
and `/health`, forwards nothing, rejects an Authorization header, and stores
bounded diagnostic counters in memory. Its default bind is loopback. An explicit
LAN bind makes this temporary fixture reachable by other devices on that network;
stop it with Ctrl+C after measuring. The phone must be able to reach that address
and the computer's firewall must permit the selected port (default 8791).

Two alternatives keep the fixture on loopback:

- Run the same Node script in Termux on the phone and use
  `http://127.0.0.1:8791/probe`.
- For a USB-connected developer phone, run the fixture on the computer with its
  default bind and run `adb reverse tcp:8791 tcp:8791`; use the same loopback URL
  on the phone. Remove that mapping afterward with
  `adb reverse --remove tcp:8791`.

In the mobile executor, prepend this configuration to the contents of
`relay_probe.lua` and execute them together:

```lua
UAI_RELAY_PROBE = { url = "http://192.168.1.10:8791/probe", port = 8790 }
-- Paste the contents of relay_probe.lua below this line.
```

The script uses the production `/api/hello`, `/api/pair`, `/api/status` and
`/api/inference` routes. It submits a job, replays the identical job ID once to
check idempotency, then polls that ID once per second. A PASS requires the matching
nonce after at least 35 seconds, exactly one upstream dispatch, every executor
exchange at most five seconds, and a second job with confirmed cancellation.
This deliberately tests a replay of one job, not a second inference.

The final JSON report contains pass/fail, total elapsed time, the slowest executor
call, poll/error counts, timeout negotiation and result/cancellation checks.
Pairing tokens, full URLs, request bodies and provider credentials are excluded.
The companion's Requests card should show acceptance and activity during the run.

The executor request function remains synchronous: the probe cannot forcibly
interrupt a native call that ignores `Timeout`. It records that call's actual
elapsed time when it returns. The overall observation budget defaults to 100
seconds, after which the probe cancels its own pending jobs; override
`waitSeconds` (60–300) for a fixture started with `--seconds` (35–120).
Failure or completion never causes a new job ID to replace the first request.

Common report categories:

| Category | What was observed |
| --- | --- |
| `companion_not_found` | No compatible loopback hello; check Start, port and executor loopback support. |
| `pairing_not_confirmed` / `authentication_not_confirmed` | Discovery worked but the authenticated contract did not. |
| `long_job_terminal_before_response` | The app accepted work but it ended before the fixture replied; inspect the app's safe error category and fixture reachability. |
| `observation_budget_expired` | The original job did not complete within the measurement budget; it was cancelled. |
| `executor_call_exceeded_five_seconds` | A loopback call itself remained blocked too long on this executor. |
| `upstream_dispatched_more_than_once` | Reusing the same relay ID caused duplicate fixture requests. |

Keep Roblox in front for the first run. A later run while switching apps or
locking the screen adds evidence for that device's background behavior; one run
does not prove survival on every Android vendor or executor. Native OpenCode
availability must be verified separately.

## Harness verification without a phone

After manually reviewing any changes, run from the repository root:

```powershell
node --test companion/tools/delay_fixture.test.js
luajit companion/tools/probe_contract_test.lua
```

The Node suite makes real local HTTP calls, including a 35-second delayed reply.
The Lua suite uses simulated time and a scripted relay to check that the diagnostic
reports failures correctly, retains one job ID and never prints credentials.
Neither suite is evidence that a particular mobile executor can reach the app.
