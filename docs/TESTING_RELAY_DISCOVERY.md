# Companion discovery correction

October 18, 2026, after the 3.5.6 release. A user reported that Roblox could not
find the companion on port 8790 while the Android app was on. Source inspection
found that the one-second discovery budget could become less than one second
before a scheduled HTTP worker ran. Flooring that remaining budget sent
`Timeout = 0` to the executor. The discovery code also discarded the transport
reason and reported every invalid hello as an absent companion.

The client now rounds positive native budgets up, preserves the original caller
deadline, skips dispatch when a queued worker outlives its caller, and gives each
discovery/pairing exchange five seconds. Errors identify the failing step and a
fixed transport category, HTTP status or protocol problem. Raw native exceptions,
response bodies and pairing tokens are excluded from the discovery diagnostic.

All source, documentation and test inputs were manually reviewed before the native
bundle was rebuilt. Generated changes and the manifest were inspected before the
following verification passed:

| Check | Result |
| --- | --- |
| HTTP diagnostics | 6 cases, 33 assertions |
| Companion discovery | 24 cases, 84 assertions |
| Mobile deadlines | 15 cases, 54 assertions |
| Mobile relay / bridge lifecycle | 28 / 54 checks |
| Bridge previews | 7 cases, 25 assertions |
| Provider compatibility | 56 cases, 906 assertions |
| Native static checker | 216 files, zero failures or warnings |
| Official Luau compiler | Three changed source modules and the native bundle passed |
| Native bundle/manifest freshness | Passed |

The corrected main-branch bundle is `3.5.6-a0ce7714ae058363`, 3,404,719 bytes,
SHA-256 `632d61e21814db7f79b33218dd980b642a4a5358c0bae57c1a5533397075c44a`.
The published `v3.5.6` tag and release artifacts retain their original bytes.
This correction changes the client; it does not require a companion APK update.

The tests reproduce delayed setup, replies taking more than two seconds,
five-second timeouts, queued and active cancellation, retained native ownership,
single dispatch and diagnostic privacy. They do not confirm the cause on the
reporting user's phone or establish mobile OpenCode support at that time; a later
Delta report (October 18, 2026) confirmed OpenCode inference through the UAI Relay
app. The
[same-phone browser check](../companion/README.md#use) distinguishes a listening
companion from an executor that cannot reach it.

## Executor request compatibility follow-up

The user identified Delta on Android after the first correction reported an
unknown native transport failure. Discovery now compares the standard request
options with a minimal hello request and distinct captured aliases after a
completed native exception. It distinguishes native throws from unusable returned
responses and stopped waits. Returned responses, native timeouts, cancellation
and capacity failures stop the search. New profiles carry no credential until
hello metadata is validated and are retained only after successful authentication.
Accepted jobs copy the selected profile through submission, polling and DELETE.

Source, documentation and test changes received manual review before building;
the generated bundle and changed module hashes were inspected before testing.
The following checks passed:

| Check | Result |
| --- | --- |
| HTTP diagnostics | 10 cases, 50 assertions |
| Companion discovery | 45 cases, 172 assertions |
| Mobile deadlines | 15 cases, 54 assertions |
| Mobile relay / bridge lifecycle | 28 / 54 checks |
| Bridge previews | 7 cases, 25 assertions |
| Provider compatibility | 56 cases, 906 assertions |
| Native static checker | 216 files, zero failures or warnings |
| Official Luau compiler | Four changed source modules and the native bundle passed |
| Native bundle/manifest freshness | Passed |

The follow-up bundle is `3.5.6-52a12d862ea17328`, 3,410,876 bytes,
SHA-256 `220768711e1ce3ad255805851fa33d8a368639714527909f5a4c33db2cc285a6`.
The published release and APK are unchanged. These offline results verify
compatibility selection and ownership, not successful Delta loopback access or
OpenCode inference on Android. No Android executor was available for that check.
