# Kilo quota recovery

Project UAI 3.7.0 can recover anonymous Kilo free inference after the public IP
allowance is exhausted. Start UAI Bridge on Windows or UAI Relay on Android,
connect Roblox, and choose the Kilo preset with a free model. No additional
provider or API key is needed. The first request goes directly to Kilo.

After a completed HTTP 429 with `PROMOTION_MODEL_LIMIT_REACHED`, the app starts
a private Tor connection and tries the same request. If that exit is also
limited, it asks Tor for another circuit and retries once. A second tunnel
refusal is returned with `x-should-retry: false`; subsequent jobs receive that
refusal locally for 60 seconds to avoid repeated sends. Status displays **Quota
reached** during this cooldown. A circuit change does
not guarantee a different exit or a fresh allowance.

## What was verified

Kilo's [merged quota change](https://github.com/Kilo-Org/cloud/pull/8456), merged
October 22, 2026, specifies **100 anonymous requests/hour/IP**, down from 200,
and **300 authenticated requests/hour/account**. The numeric firewall settings
are outside the public source; the account allowance was not live-tested.
Free models share their quota, so switching models does not reset it.

A controlled sequential test reached an explicit quota refusal on attempt 100
(97 successes, two timeouts, one quota refusal). A single request through a
different verified outbound IP then succeeded, and the original IP still
returned 429. The bridge's real streaming inference module also completed a
Kilo tool-call response through the tunnel. These tests establish IP-scoped
anonymous recovery, not unlimited capacity or a guaranteed number of requests.

Shared exits can already be limited, blocked or slow. Kilo can change its
service or limits. There is no promise that every request beyond 100 will work.
The feature cannot increase an authenticated account's allowance.

## Free models to try

Checked against the [live Kilo catalog](https://api.kilo.ai/api/gateway/models)
on October 25, 2026. These entries report free access, zero input/output token
prices, tool calling and reasoning support. Recommendations follow the catalog's
descriptions and capabilities; they are not comparative benchmark results.

| Model ID | Good starting use | Advertised context |
| --- | --- | --- |
| `kilo-auto/free` | Simplest default; Kilo chooses an available free model | 256,000 |
| `recursive/flint-v1.0:free` | Agent coding and repository changes | 262,144 |
| `cohere/north-mini-code:free` | Coding tasks and tool use | 256,000 |
| `nvidia/nemotron-3.5-super-vl:free` | Screenshot/image questions and text | 1,000,000 |
| `nvidia/nemotron-3-ultra-550b-a55b:free` | Reasoning and planning | 1,000,000 |

Enter the exact ID in the Kilo provider's model field. Model availability and
promotions can change. Free models share the same allowance; changing models
does not reset it. The catalog flags these routes as allowing training on prompts.
See Kilo's [free-model guide](https://kilo.ai/docs/advanced-usage/free-and-budget-models)
for current terms. Poolside Laguna S 2.1 and XS 2.1 also appear as free coding
options, but their catalog promotion expires October 31, 2026.

## Controls and status

- **Windows:** Tunnels > Kilo tunnel. Enabled by default; stop Cowork to
  change it. The first quota recovery downloads a checksum-verified 22 MB Tor
  Expert Bundle. Startup can take up to 150 seconds; use an adequate inference
  deadline or the bridge's existing unlimited-wait setting.
- **Android:** Settings > Kilo tunnel. Enabled by default; stop the relay to
  change it. Native Tor is included in the APK and starts only after a refusal.
  Initial setup waits at most 120 seconds, within the original request deadline.
- **Web UI:** Tunnels and Connection display the current helper state and setup message.
- **Roblox:** Cowork displays the connected bridge or companion's state. The
  script delegates tunneling to that local app; direct executor HTTP does not
  create a Tor process. Without a connected app, ordinary Kilo limits apply.
- **Node bridge:** set `UAI_KILO_TUNNEL=0` before starting to disable recovery.
  Set it to `1` or leave it unset to enable. Windows x64 is automatically
  provisioned; Windows arm64 can use x64 emulation. Other platforms require an
  installed Tor executable at an absolute `UAI_KILO_TOR_BINARY` path.

The Windows archive is cached under the user's Project UAI local application
data. Every startup rechecks its SHA-256 and extracts a fresh private session.
The owned process and session are cleaned up when the bridge stops. Android's
bound native service is stopped with the relay. Neither app changes the system
VPN, global proxy settings or another provider's connection.

## Scope and replay rules

Only HTTPS port 443 on `api.kilo.ai` or `ai-gateway.kilo.ai`, known gateway
inference paths, and `kilo-auto/free` or `:free` models qualify. URL credentials,
query strings, authorization, API-key, token, cookie or organization headers
exclude the request. Signed-in requests remain direct. To use a Kilo account in
the client, select **Bearer** and enter the Kilo key; the no-key preset's
**None** authentication style does not send a saved key.

Timeouts, cancellation, ordinary failures, partial responses and interrupted
streams do not trigger route replay. Both apps keep the caller's single finite
deadline across setup and retry, while preserving the existing zero-timeout
contract. Retries retain the original relay job and payload; Roblox's normal
tool execution and permission checks are unchanged. TLS remains end to end to
Kilo, including certificate and hostname verification through HTTP CONNECT.

The tunnel carries anonymous prompts and replies. Tor exits see the destination
and encrypted traffic, and Kilo sees the exit IP. No provider account is created
or switched by this feature.

Implementation and verification: [3.7.0 testing](TESTING_3.7.0.md).
