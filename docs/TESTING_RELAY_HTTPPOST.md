# Delta local transport correction

The user tested Delta 1.1.741.1062 on Android. Both numeric loopback and localhost
failed through `request` with `HttpError: ConnectFail` in less than 0.1 seconds.
Both returned a valid companion hello through `game:HttpGet`. Public HTTPS through
`request` returned HTTP 200. This establishes that the companion was listening
and identifies a difference between Delta's two HTTP paths.

The client now tries a DataModel profile after completed native discovery failures.
Companion 3.5.7 advertises its authenticated POST adapter. The client validates
that capability before pairing with HttpPost; a saved token must authenticate
through the selected profile. Submission, polling and cancellation then use the
same engine and job identities through POST envelopes. Credentials are in bodies,
never URLs. Older companions show the required update instead of pairing.

Inputs were manually reviewed before building, and generated outputs inspected
before focused verification. Lua discovery passed 49 cases / 197 assertions,
HTTP diagnostics 10 / 50, mobile deadlines 15 / 54, and mobile relay 28 checks.
The native checker passed 217 files without failures or warnings. Official Luau
compilation and deterministic bundle freshness also passed.

Client build: `3.5.6-05dc1beebbbff484`, 3,413,972 bytes, SHA-256
`3bfa53c431c6d3ac0168da786dac1bb1541e03370e2aae50de0bceb114c5533d`.

Signed companion: `UAI-Relay-3.5.7.apk`, version code 4, 9,622,758 bytes,
SHA-256 `ed5cd07b515160e01acdaee419af3538f508d91ee6d39a6eb9eee78f04ba1580`.
The release packager verified package metadata and the existing production signer.
Release assembly and its vital lint check passed. The source/APK credential scan
reported zero matches. The original 3.5.6 release assets remain unchanged.
All 70 companion JVM tests passed with zero failures, errors or skips. The new
server tests cover authentication, browser/content-type rejection, operation
allowlisting, same-ID replay, polling, stale instances and cancellation.

The phone result above does not establish HttpPost support or end-to-end inference.
Those remain target-device checks after installing the new companion and client.

Subsequently, the user confirmed OpenCode inference on a Delta Android phone
through the UAI Relay app after manually retrying an initial
`Relay rejected the request (400)`. The initial 400 remains an unresolved observed
error; the retry confirms inference, not phone tool execution, tool-result replay
or background survival. Mobile OpenCode requires the UAI Relay app from Discord.
