# Project UAI 3.6.1 verification

Prepared October 20, 2026. Client and bridge 3.6.1 fix the OpenCode tunnel's
fatal desktop-tool-choice error. Desktop and Android app downloads remain 3.6.0.

All changed source, documentation and test inputs were manually reviewed before
building. Client, bridge package and website outputs were inspected before
verification. The full native suite was not run.

Focused checks passed:

- OpenCode native adapter: 16 tests, covering blocked-action receipts, normal
  subsequent Roblox tool handoff, Chat/Responses, mixed call order, malformed and
  unmatched arguments, permission identity, interruption failures and cancellation.
- OpenCode discovery, authenticated bridge transport and updater: 25 passed,
  one platform-specific test skipped. Updater checks include compatibility with
  the shipped 3.1 updater, verified staging, idle activation and retained tokens.
- Actual scripting loop: 7 cases, 29 assertions, including a refused native
  choice followed by a managed Roblox script result and normal completion.
- Targeted source checker and official Luau compiler for the changed client
  modules; client, bridge and website build freshness checks.
- Website: 8,447 static checks and focused Chromium behavior checks, including
  component-specific desktop/Android download versions.

The initial native fixture confused configured permission rules with pending
permission requests. It was corrected and manually reviewed before rerunning the
affected adapter tests; all 16 then passed.

The installed official OpenCode CLI 2.0.32 API was inspected in isolation to
verify tool-state and permission-source shapes. No live upstream inference or
native desktop action was used for this patch's verification. Offline fixtures
establish the handoff behavior; they do not verify every live model's tool choice.

Existing desktop 3.6.0 downloads the bridge and web package automatically and
activates it when idle. Refresh the browser for changed web files and reload the
published Roblox client for the new refusal feedback. The desktop's Copy client
script action retains its embedded client version.
