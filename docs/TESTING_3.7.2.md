# Project UAI 3.7.2 verification

The earlier byte-storage and reasoning pass was verified October 29, 2026.
This client-only update changes credential persistence,
exports, included-key migration, the daily free-provider schedule and reasoning
level visibility in compact model pickers. Bridge,
desktop, web UI and companion implementation files are unchanged.

For that pass, changed sources, documentation and tests were manually reviewed before the
client build. The generated bundle and manifest were inspected before verification.
Test fixture and assertion fixes were reviewed before rerunning the affected checks.
No production source changed after the inspected build.

## Earlier build and static checks

- `luajit tools/bundle.lua --native`: passed; 243 bundled modules,
  3,843,785 bytes. Build ID: `3.7.2-e2e69fe4afa59f86`.
- `luajit test/check.lua --native`: passed; 239 files parsed, 238 native modules,
  zero failures and zero warnings.
- Official `luau-compile.exe --null` over client sources and `init.lua`: passed.
- `luajit tools/bundle.lua --native --check`: passed; generated artifacts match
  their inputs.

Outputs: [client bundle](../dist/uai.lua) and [manifest](../dist/uai.manifest.json).

## Focused behavior verification

The initial credential/schedule pass on `3.7.2-b6366b03ccbf2fcd` ran 18 suites,
reporting **2,205 checks/assertions**. Each named suite runs
as `luajit test/<suite>.lua`; the final row uses the command shown.

| Suite | Checks/assertions | Result |
| --- | ---: | --- |
| `credential_codec` | 42 | Passed |
| `credential_storage` | 57 | Passed |
| `credential_ui` | 42 | Passed |
| `config_transfer` | 163 | Passed |
| `build_reload` | 55 | Passed |
| `support_bundle` | 46 | Passed |
| `free_provider` | 116 | Passed |
| `free_routing` | 187 | Passed |
| `request_accounting` | 44 | Passed |
| `provider_key_pause` | 43 | Passed |
| `provider_keys` | 34 | Passed |
| `provider_key_rotation` | 71 | Passed |
| `provider_key_snapshots` | 29 | Passed |
| `provider_transport` | 554 | Passed |
| `provider_setup` | 38 | Passed |
| `provider_editor` | 170 | Passed |
| `provider_keys_ui` | 97 | Passed |
| `luajit test/run.lua --native boot config changelog` | 417 | Passed |

Coverage includes byte reconstruction, corruption/version/size checks, automatic
plaintext migration, verified storage changes, optional session-only use, safe
copies and diagnostics, import policy, included-access references and URL cleaning.
Malformed envelopes remain recoverable without anonymous dispatch. Storage changes
preserve live records, key pools, metadata and running-request references.

An end-to-end offline case saves encoded credentials, cold-loads them, then uses
the actual provider adapter to construct a synthetic HTTP request. It verifies the
exact selected unpaused key, custom and identity headers, URL/query/body overrides,
and a successful simulated response. Build-replacement tests also cover the live
credential handoff and genuine unload/restart behavior.

Schedule tests cover 20:00 opening, 12:00 closing, midnight, the personal-key
exemption, background-probe admission and completion of accepted replies across
closing. UI checks exercise the storage controls, migration notice, private copy
and provider/key-manager flows in the offline harness.

## Reasoning levels follow-up

That pass's final bundle adds only the model-picker fix and its release note to the
initial credential/schedule build. Module hashes confirm other client modules and bootstrap
are unchanged. Source, tests and documentation were reviewed before building;
the generated picker, release note and manifest were inspected before testing.

Four focused suites passed, reporting **370 checks/assertions**:

| Suite | Checks/assertions | Result |
| --- | ---: | --- |
| `model_effort` | 111 | Passed |
| `model_picker_layout` | 58 | Passed |
| `model_picker_touch` | 143 | Passed |
| `model_temperature_ui` | 58 | Passed |

Coverage includes enabling and disabling manual reasoning, documented model
levels, model switching, short and tall viewports, touch targets, keyboard
obstruction, shared effort preferences, and retained search and catalogue state.
Extremely constrained layouts retain the existing Options fallback.

Two stale layout expectations were corrected: catalogue-only scrolling already
replaced whole-body scrolling, and the 777-by-632 fixture fits three complete
model rows. A comparison against the pre-fix picker confirmed identical row
geometry at that size. Test corrections were reviewed before rerunning the suite.
Native static checks and bundle freshness passed again; the official Luau
compiler accepted the changed source modules and regression tests. No live
provider requests or native Roblox rendering checks were performed.

## Local configuration and literal scans

The authorized local configuration was read without modifying its original file.
Migration and reload ran only in the mock filesystem, covering **8 providers and
12 key entries**. All **11 personal entries** reconstructed exactly; the included
community credential followed its replacement/reference policy. No real credential
was sent over the network or printed in test logs.

The artifact scan checked **519 files** against **13 credential strings**, including
the local keys and retired/replacement community credentials. It found no raw key
values in client source, generated client artifacts, tests or the scanned
documentation. The replacement community bytes matched the supplied value.
Detailed logs and read-only audit scripts remain locally under the ignored
`refer/credential-security-20261029/` directory.

## Password vault follow-up

The follow-up adds optional AES-256-SIV encryption and PBKDF2-HMAC-SHA256 password
derivation, password entry, legacy migration, locked startup, private encrypted
transfers and verified storage transitions. The earlier results above describe
the byte-encoding build and do not establish vault correctness.

Added integration cases cover the previously live-tested byte envelope, exact
key-pool metadata and custom authentication, cancellation, wrong passwords,
failed writes and interrupted-primary recovery, password changes, lock/unlock,
encrypted imports, session-only disabling and explicit forgotten-password reset.
The bundle reload fixture covers a private in-memory vault-key handoff and a
genuine UI-free restart that stays locked. Storage fixtures use synthetic
credentials and a cheap deterministic derivation stub with the real envelope and
AES-SIV code; independent KDF/primitive checks exercise the real derivation.

The reviewed follow-up was built and its bundle/manifest inspected before tests.
The final artifact is **`3.7.2-0c9606e7a1ffe6ee`**, with **248 modules** and
**3,915,200 bytes**, generated by `luajit tools/bundle.lua --native`.
The initial pass used `3.7.2-f63b88cb68e97101`. Subsequent reviewed changes serialize
storage operations, preserve recovery after failed removal, validate operation
options, clean up cancelled staging, shorten derivation progress intervals and
explain the wait in password UI.

Final static verification passed: `test/check.lua --native` parsed 244 files and
linked 243 native modules with no failures or warnings. The official Luau compiler
accepted all client sources, bootstrap and the concurrency/storage/UI tests
(74 KLOC, 3,763 KB bytecode). `tools/bundle.lua --native --check` confirmed the
final bundle and manifest match their inputs.

The table records the latest result for each focused suite across this follow-up:
**23 suites, 3,669 checks/assertions, all passed**. After the final rebuild,
storage, concurrency, transfer, reload, vault UI, legacy credential UI/storage and
native boot/config/changelog checks ran again. Each Lua suite below runs as
`luajit test/<suite>.lua`, unless its full command is shown.

| Suite | Checks/assertions | Result |
| --- | ---: | --- |
| `credential_crypto` | 119 | Passed |
| `credential_vault` | 58 | Passed |
| `credential_vault_storage` | 131 | Passed |
| `credential_vault_concurrency` | 40 | Passed |
| `credential_vault_ui` | 75 | Passed |
| `credential_ui` | 42 | Passed |
| `credential_codec` | 42 | Passed |
| `credential_storage` | 57 | Passed |
| `config_transfer` | 163 | Passed |
| `build_reload` | 63 | Passed |
| `provider_transport` | 554 | Passed |
| `request_accounting` | 44 | Passed |
| `provider_key_pause` | 43 | Passed |
| `support_bundle` | 46 | Passed |
| `provider_editor` | 170 | Passed |
| `provider_keys_ui` | 97 | Passed |
| `free_provider` | 116 | Passed |
| `free_routing` | 196 | Passed |
| `model_picker_layout` | 58 | Passed |
| `model_effort` | 111 | Passed |
| `model_picker_touch` | 143 | Passed |
| `luajit test/run.lua --native boot config changelog` | 418 | Passed |
| Python `credential_crypto_interop.py` | 883 | Passed |

Cryptography checks include FIPS AES/SHA vectors, RFC HMAC/CMAC/PBKDF2/SIV vectors,
tampering, wrong passwords and envelope/session ownership. Independent Python
`cryptography` 46.0.7 and `hashlib`/`hmac` checks include 219 authentication
rejections. The official Luau compiler accepted the four runtime cryptography
modules and four associated test scripts. A storage fixture initially omitted a
provider ID; it was corrected to use the normal registry save path and reviewed
before rerunning. The startup UI fixture was corrected to distinguish the app
from the fading boot indicator, and the reload fixture now checks the refused
operation rather than a particular word in its explanation. These fixture failures
did not require production changes.

The final native Luau CLI benchmark derived the full 64-byte key at 600,000
iterations in **80.993 seconds**. Its **9,377 progress calls** had an **8.638 ms
mean** and **72.375 ms maximum** gap. The 128-iteration progress interval retains
the full derivation work. This measures CLI computation, omits frame waits and
does not measure Roblox rendering or executor input. Setup/unlock can take minutes
on slower hosts; the client explains the wait and reports progress with cooperative
cancellation. The LuaJIT mock benchmark includes bit32 wrapper overhead and is not
an executor performance estimate.

A read-only migration audit of the current local byte-encoded configuration
covered **8 providers and 11 key entries, all personal**. Every protected connection
field roundtripped through enable, cold unlock and private import using the full
production 600,000-iteration derivation. The original executor file was unchanged
and no credential was sent over the network. The final literal scan checked
**533 artifacts against 13 distinct credential strings**, found no raw matches,
and confirmed the original configuration stayed unchanged. The local audit script is retained under the ignored
`refer/credential-vault-20261029/local_config.lua` path.

## Required password follow-up

The current source adds mandatory setup/unlock on every execution, including
same-build reuse, changed-build replacement and embedding with `ui = false`.
The Settings entry is **Project UAI**. Earlier optional-vault results above do
not establish correctness of this new access gate.

The required-bootstrap fixture covers retained legacy keys, verified setup,
wrong passwords, repeat authentication, warm credential edits, cold startup,
cancelled/failed setup, disabled storage opt-outs, forgotten-password reset,
missing filesystem support and public no-key routes. Admission coverage checks
direct provider and tool entry points. Configuration export, import preview,
import application and direct replacement are rejected during setup and warm
reauthentication. Reload coverage retains the existing
busy-work/draft/storage protections and authenticates before ordinary work.
Synthetic integration fixtures shorten only password derivation; the real
authenticated envelope remains in use.

Build inputs were manually reviewed before building, and subsequent test fixture
updates were reviewed before their runs. The generated bundle and manifest were
inspected before verification. The final artifact is
**`3.7.2-c2a73a961be9e7c8`**, with **248 modules** and **3,924,936 bytes**.
Its immediate predecessor, `3.7.2-83604373825495c5`, differs only in the reviewed
Exit-refusal toast fix; its bootstrap is unchanged. The table reports the latest
result for each suite across these two builds. Required startup, password UI and
the executable embedding examples passed against the final artifact.

**25 suites, 2,775 checks/assertions, all passed.** Each Lua suite runs as
`luajit test/<suite>.lua`, except the full command shown.

| Suite | Checks/assertions | Result |
| --- | ---: | --- |
| `credential_vault_required` | 44 | Passed |
| `credential_vault_admission` | 40 | Passed |
| `credential_vault_storage` | 131 | Passed |
| `credential_vault_concurrency` | 59 | Passed |
| `credential_vault_ui` | 105 | Passed |
| `credential_ui` | 38 | Passed |
| `credential_crypto` | 119 | Passed |
| `config_transfer` | 163 | Passed |
| `build_reload` | 64 | Passed |
| `embedding_boot` | 53 | Passed |
| `embedding_sdk` | 34 | Passed |
| `embedding_examples` | 20 | Passed |
| `provider_transport` | 554 | Passed |
| `request_accounting` | 44 | Passed |
| `free_provider` | 116 | Passed |
| `free_routing` | 196 | Passed |
| `mcp_bridge` | 28 | Passed |
| `desktop_bridge` | 43 | Passed |
| `bridge_lifecycle` | 54 | Passed |
| `bridge_concurrency` | 13 | Passed |
| `mobile_relay` | 38 | Passed |
| `relay_discovery` | 207 | Passed |
| `relay_poll_ownership` | 35 | Passed |
| `luajit test/run.lua --native boot config changelog` | 419 | Passed |
| `ui_library` | 158 | Passed |

Final native static verification parsed **244 files** and linked **243 modules**
with no failures or warnings. The official Luau compiler accepted client sources,
bootstrap and the reviewed tests (**77 KLOC**, **3,933 KB bytecode**).
`luajit tools/bundle.lua --native --check` confirmed artifact freshness.
The UI-library guide's embedding paragraph was regenerated with
`node tools/build_ui_lib.js`; its standalone **1.4.0** bundle remained unchanged
at **13 modules**, **183,395 bytes**. The embedded guide was inspected, and
`node tools/build_ui_lib.js --check` passed.

The updated embedding fixtures explicitly authenticate and select their synthetic
provider. The reload fixture retains an independent provider template because
encrypted unload clears live credential objects. These fixture corrections were
reviewed before rerunning; their failures did not require runtime changes.
Example coverage verifies blocked requests before password entry and an explicitly
empty provider chain for its missing-provider case.

A final read-only literal scan checked **536 artifacts against 13 distinct
credential strings**, found no matches, and confirmed the original executor
configuration was unchanged. It made no network requests. Logs are retained in
the ignored `refer/credential-required-20261029/` directory.

## Setup warning and presentation follow-up

The encrypted configuration example and its generation helpers were removed.
Setup now groups password fields beneath a themed **NO PASSWORD RECOVERY**
callout. It explains that resetting removes credentials saved in the vault,
requires re-entry, and does not revoke provider keys or erase existing backups.
Show/Hide controls sit beside the field labels. Validation errors and initial
progress scroll into view without moving the user's scroll on later progress ticks.

Source, documentation and test changes were manually reviewed before rebuilding.
The inspected final artifact is **`3.7.2-645284708312dc87`**, with **248 modules**
and **3,928,190 bytes**. Only the `ui/credentialvault` module hash changed from
the previous required-password build; the bootstrap and runtime modules match.

All **203 assertions** passed across the focused suites:

| Suite | Assertions | Result |
| --- | ---: | --- |
| `credential_vault_ui` | 121 | Passed |
| `credential_ui` | 38 | Passed |
| `credential_vault_required` | 44 | Passed |

The native static checker parsed **244 files** and linked **243 modules** with
no failures or warnings. The official Luau compiler accepted client sources,
bootstrap and the vault UI test (**74 KLOC**, **3,737 KB bytecode**).
`luajit tools/bundle.lua --native --check` confirmed artifact freshness.

Initial layout fixtures incorrectly assumed automatic list geometry in the mock
and omitted responsive initialization. Reviewed corrections use declared layout
order and explicit synthetic geometry. The short-keyboard case also guards against
scrolling past feedback to an inline footer. These checks cover behavior, not native
text rendering. Image tests were skipped at the user's request. Logs are retained
in the ignored `refer/vault-setup-20261029/` directory.

## Credential choice and compact progress follow-up

The client now offers the explicit red **Continue without encryption** action.
Its verified save preserves keys and pool metadata using reversible byte storage,
remembers the local choice, and skips subsequent password prompts. An existing
encrypted vault must be authenticated before switching while retaining keys.
Imports retain the destination's protection choice. Failed saves, cancelled work,
reentrant password challenges and failed rollback/recovery remain guarded.

Setup and unlock share a compact bottom-right percentage with Cancel and, during
required startup, Exit. Password work hides its dialog and backdrop and releases
native text focus. The dialog fits its contents when asking for a password.
Error or explicit cancellation restores entry; invalidated import sources close
their stale dialog. Progress updates only when the displayed percentage changes.

New vaults and explicit password changes use **100,000 PBKDF2 iterations**.
Existing vaults retain their recorded count during unlock and ordinary saves.
Unlocking and changing the master password, including to the same password,
rewrites an older vault at the new work factor without discarding its keys.

All source, documentation, examples and test inputs were manually audited before
the build. The regenerated UI-library guide and client output were inspected
before verification. The final client is **`3.7.2-b6970a6995b16277`**, with
**248 modules** and **3,937,245 bytes**. Its bootstrap is unchanged from the
previous setup-presentation build. The standalone UI library remains **1.4.0**,
**13 modules**, **183,395 bytes**.

**13 suites, 1,752 checks/assertions, all passed:**

| Suite | Checks/assertions | Result |
| --- | ---: | --- |
| `credential_vault` | 58 | Passed |
| `credential_vault_storage` | 177 | Passed |
| `credential_vault_concurrency` | 59 | Passed |
| `credential_vault_required` | 50 | Passed |
| `credential_vault_admission` | 40 | Passed |
| `credential_crypto` | 119 | Passed |
| `config_transfer` | 163 | Passed |
| `credential_vault_ui` | 185 | Passed |
| `credential_ui` | 38 | Passed |
| `build_reload` | 64 | Passed |
| `embedding_examples` | 20 | Passed |
| `luajit test/run.lua --native boot config changelog overlays modal` | 621 | Passed |
| `ui_library` | 158 | Passed |

The native checker parsed **244 files** and linked **243 modules** with no
failures or warnings. The official Luau compiler accepted client source,
bootstrap, the changed credential tests, benchmark and embedding example
(**76 KLOC**, **3,866 KB bytecode**). One new UI assertion initially waited beyond
the synthetic operation's completion because the key helper advances time.
The reviewed test-only correction dispatches both key events before checking
pending work; the final UI suite and compilation passed. No production code
changed after the inspected build. Both artifact-freshness checks passed.

The native Luau benchmark derived the full 64-byte key at 100,000 iterations in
**15.542 seconds**, with **1,564 callbacks**, a **9.944 ms mean** gap and
**70.200 ms maximum** gap. It excludes frame waits and does not predict executor
timing. Image tests were skipped as requested; no native rendering claim is made.
Logs are retained under `refer/credential-choice-20261029/`.

## Progress titles follow-up

The compact progress panel now names its operation above the percentage and
actions: **Encrypting API keys**, **Decrypting API keys**, **Changing password**
or **Decrypting config**. Its corner placement and operation lifecycle remain
the same. Inputs were manually audited, then the rebuilt output was inspected.
Build **`3.7.2-af495ac48d709df0`** contains **248 modules**, **3,937,904 bytes**;
only `ui/credentialvault` changed from the previous build.

The vault UI suite passed **23 cases / 185 assertions**. Native static checks
passed **244 files / 243 modules** without failures or warnings. The official
Luau compiler accepted the changed UI source and test, and bundle freshness
passed. Image tests were not run.

## Scope and limits

The real executor configuration and bridge, desktop and companion implementations
remain unchanged. Migration occurs when the updated client loads an existing
configuration and the setup prompt verifies either password encryption or the
explicit unprotected-storage choice. Existing encrypted configurations require
their password before saved credentials can be used or preserved in another mode.
These verification results were recorded before publication.

Offline verification does not establish native Roblox rendering, executor input
behavior, acceptance of the replacement key by the upstream service, or server-side
availability enforcement. No upstream keys were revoked. Local scheduling is
bypassable, and legacy byte encoding is reversible rather than encryption.
The vault protects saved credentials but cannot isolate passwords or live keys
from scripts with equivalent executor access. Lua cannot guarantee memory erasure.
See [API key security](API_KEY_SECURITY.md) for the storage contract and guidance.
