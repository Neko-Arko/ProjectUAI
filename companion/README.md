# UAI Relay (Android companion)

Version **3.5.6** (Android version code 3).

A foreground service that holds the upstream provider connection while the
Project UAI client submits and polls through short loopback calls. The client
budgets each exchange at most five seconds. Some mobile executors cut long
`request()` calls off before a reasoning turn finishes; polling lets the companion
keep that provider connection open until the answer is ready. It is **not** the
Cowork bridge: there is no web UI, no static
serving, no agent state, no commands. Just the relay contract in
[docs/MOBILE_COMPANION.md](../docs/MOBILE_COMPANION.md) Section 4.

## Requirements

- Android 8.0+ (`minSdk 26`). Sideload only; no Play dependency.
- A mobile executor that exposes `request` / `http_request` / `syn.request` /
  `http.request` / `fluxus.request`. Plain `HttpService` cannot reach loopback
  plain-HTTP or set the discovery header, so without an executor function nothing
  can connect.
- The client's `relay.mode` is `auto` by default: the script probes
  `127.0.0.1:8790`, pairs once for a stable token, and relays from then on.

## Build

JDK 17 and the Android SDK are required (Android Studio bundles both).

```powershell
# From companion/
./gradlew :app:assembleDebug          # APK at app/build/outputs/apk/debug/
./gradlew :app:testDebugUnitTest      # JVM contract tests, no device
```

`local.properties` must point at the SDK if `ANDROID_HOME` is unset:

```properties
sdk.dir=C\:\\Android\\Sdk
```

Install with `adb install -r app/build/outputs/apk/debug/app-debug.apk`.

For production signing, automatic updates and release packaging, follow
[Android companion updates](UPDATES.md). The app checks official releases on
startup and every 15 minutes while its process is alive, downloads compatible
updates by default, and asks Android to install only after **Install update** is
tapped. The first transition from a debug-signed APK to the production signing
key requires uninstalling the debug app and pairing again; future updates keep
the same production signer.

## Use

1. Start the app and tap **Start**. The notification appears and the relay listens
   on `127.0.0.1:8790` only.
2. In Roblox, run the Project UAI script. The Cowork panel's Relay card shows the
   companion once paired — no token copying.
3. Keep Roblox and the relay running. **Stop** in the app is authoritative: the
   watchdogs stay down until you start again.

The Roblox status reports actual pairing or authenticated client contact in the
current service run. A saved token alone is shown as saved pairing, not a live
connection. Requests shows accepted jobs, active work, received responses,
failures and cancellations. If Accepted stays at zero, inference has not reached
the app. Recent jobs show only the provider hostname, elapsed time, received bytes
and a safe result category; provider keys and message contents never appear.

Updated clients negotiate `capabilities.inference = {schema:1, unlimited:true}`
and send `timeout:0` for requests without an explicit finite budget. The companion
does not stop these requests because a model is quiet or reasoning takes longer
than ten seconds. Stop, an explicit request deadline, an upstream failure or the
existing response-size limit still ends work. Older clients retain their positive
timeout, and an omitted timeout remains 180 seconds. Connection establishment has
a 15-second limit; established request reads and writes have no hidden timeout.
The relay does not automatically replay a POST after a connection failure or
redirect.

Each running job also needs contact from its waiting Roblox client. A matching
submission retry or authenticated poll for that job renews a two-minute ownership
lease. The service checks leases every five seconds and cancels abandoned provider
connections, releasing the wake lock when no jobs remain. This is independent of
total reasoning time: regular polling can keep a job alive indefinitely. Hello,
status and other jobs cannot renew it. A lost client produces terminal
`client_disconnected`; reconnecting never repeats that inference automatically.

## Survival notes

- The service uses `foregroundServiceType="specialUse"`; Android 15 caps `dataSync`
  services at six hours per day, which would end a long session.
- An exact-alarm watchdog and `BOOT_COMPLETED` resurrect the service unless the
  user pressed Stop. **Force stop** is unrecoverable without reopening the app.
- Grant the battery-optimisation exemption, and allow auto-start in vendor settings
  on Xiaomi/Samsung/Oppo/vivo. The Diagnostics screen logs every restart.

## Security

- Loopback binding only (`127.0.0.1`), never `allowLan`.
- 64-hex token, constant-time compare, generated once and stored in
  `EncryptedSharedPreferences`; `allowBackup=false`.
- `/api/pair` validates the Host and rejects browser Origins; the API never emits
  CORS headers and never serves files.
- Provider keys transit a job in memory only and are never logged or persisted.
  Raw network exception messages are excluded from diagnostics and client errors.

## Verification

For an opt-in measurement on the actual phone, use the
[console diagnostic tools](tools/README.md). They check pairing, a controlled
45-second response through short executor polls, idempotency and cancellation
without any provider API key. Their result does not establish OpenCode access.

`app/src/test` runs on the JVM with a real CIO server and a `MockWebServer`
upstream: header filtering, URL safety, fingerprint idempotency, instance skew,
capacity 503, cancellation, tombstones, negotiated unlimited requests, explicit
deadlines, delayed responses beyond ten seconds, no automatic replay, live
activity, and the pair/auth/hello contract. Android manifest, package installer
and service behavior need a native device or emulator. Actual executor support
requires a phone running the target Roblox executor and the companion; JVM tests
and an emulator without that executor cannot establish it.

Before trusting the companion on a given executor, run the Phase 0 measurement in
`docs/MOBILE_COMPANION.md` Section 9.4: confirm loopback reachability and find the
exact wall. Executors that do not cut long calls do not need this app.
