# UAI Bridge desktop launcher

A Windows 10/11 x64 app that starts Cowork, opens the browser and connects the
updated Roblox script automatically. The desktop project is separate from the
existing bridge and uses its server in `--desktop` mode on **127.0.0.1:28791**.
Manual terminal startup keeps port 8790 and its existing token workflow.

Download and open **UAI-Bridge-3.6.0-win-x64.exe**, then click
**Start Cowork**. The window shows connection, Node.js setup, OpenCode and
update status. It detects Node.js 18+ on your computer. If none is available,
choose **Get Node.js** or **Manual setup**, then **Check again**.
The app downloads the current Windows x64 LTS executable from nodejs.org, checks
its official SHA-256, and installs it for your account without administrator
access.

The single executable includes .NET, the bridge, browser assets, the matching
client and license notices. It verifies and prepares its embedded files in a
private user cache automatically. There is no ZIP to extract or supporting
folder to keep beside the executable. Node.js is installed separately through
the app or detected on your computer. Roblox and the UAI script must remain running.

## Optional OpenCode native workaround

Install [OpenCode Desktop](https://opencode.ai) separately, then restart Cowork.
The OpenCode card reports when its free models are ready. The bridge detects the
installed native CLI, starts its authenticated loopback server privately, and
routes models in its public catalog through the native connection. OpenCode is
**not bundled, downloaded or copied into the desktop distribution**. The app uses
its existing Windows Job Object to own the bridge and its CLI descendant; Stop
and closing the window shut them down. The bridge also supports an absolute
`UAI_OPENCODE_BINARY` override; see the [bridge guide](../bridge/README.md).

The existing direct desktop workaround still works without this app. This native
route provides an additional desktop option; on mobile, OpenCode requires the UAI
Relay app from Discord.
UAI tools are returned to Roblox for execution. Bridge 3.6.2 installs a private
execution permission gate and waits for matching pending permissions before
returning blocked-action feedback. The CLI never receives permission to run local
desktop tools. Provider keys and existing OpenCode credentials are not
copied into its isolated session. OpenCode's retired HTTPS proxy is not used.

OpenCode Go subscriptions use `https://opencode.ai/inference/go/v1` and your Go API
key directly. They do not use this native free-model route. That mobile relay
requirement applies to OpenCode free models, not Go subscriptions.

Project UAI Free is available by default when no provider is configured. Thank you
for your continued use and support. Join [our Discord](https://discord.gg/9xYyyYuKap)
for help, availability updates and news about more free providers.

The window reports bridge startup separately from Roblox connection. Minimize
keeps Cowork in the taskbar. Closing the window stops the owned bridge and its
OpenCode process, then exits; the app never hides in the notification area.
Repeated launches restore the existing window. Occupied ports produce an error;
the app never chooses an undiscoverable random port or kills another application.

## Desktop preferences

The dashboard saves five controls for this installation and retains them across
verified app updates:

| Control | Default | Behavior |
| --- | --- | --- |
| OpenCode tunnel | On | Uses the installed CLI for native free models. Turn off to avoid starting OpenCode. |
| MCP access | On | Allows external coding agents to connect to UAI's MCP endpoint. Turning it off rejects MCP sessions. |
| Open browser when bridge starts | On | Opens Cowork after successful bridge startup. **Open Cowork** always opens it manually. |
| Start bridge when app opens | Off | Starts the bridge after Node.js detection; does not register Windows startup. |
| Download app updates | On | Checks and downloads desktop updates automatically. **Check for updates** remains available when off. |

Stop the bridge before changing OpenCode or MCP. The next start receives the
saved settings; existing tool calls are never silently interrupted by a switch.
The OpenCode card shows readiness, the detected CLI version, or a setup problem.
MCP access controls external agents; OpenCode's private tool relay remains
independent. App preferences contain no credentials, and malformed preference
files recover to defaults. Disabling automatic app downloads lets a download
already in progress finish. Closing always exits, including when an update is
staged; the new version starts the next time you open Cowork. **Restart to update
app** applies a staged update immediately after the bridge has stopped.
Bridge worker updates continue automatically when work is idle.

## Automatic connection

External AI harnesses can use the same desktop bridge as an MCP server. Click
**MCP setup** in the running desktop app to open its browser setup panel, or open
**Settings → MCP** in Cowork to copy the configuration for your harness. The
single executable accepts `--mcp-stdio`, runs its verified embedded adapter with
the detected Node runtime, and discovers the already-running desktop bridge.
This command does not open a window or start another bridge. The HTTP endpoint
is `http://127.0.0.1:28791/mcp`. UAI retains control of tool permissions and uses
an isolated ephemeral conversation per MCP connection. See [MCP setup](../bridge/MCP.md).

`bridge.autoDiscover` defaults to true. Desktop clients probe the dedicated port
every four seconds, with a two-second request deadline. Touch-only mobile clients
skip this Windows discovery route. An enabled manual bridge takes
priority. Turn off **Manual bridge enabled** in Cowork to use the desktop app.
Disable **Find desktop app automatically** to opt out. `bridge.stop()` suspends
discovery until `bridge.sync()` or a connection-setting change. Unloading releases
the discovery worker and ignores pending results.

With client 3.5.6, authenticated bridge contact selects Web runtime automatically;
disconnecting restores Game for subsequent requests. Stopping or restarting the
launcher does not resend an inference request. Update the packaged client and
bridge together when building a desktop distribution.

## Automatic updates

Bridge releases download automatically, are verified, and activate only when
active work and retained receipts/pictures are idle. An automatic worker restart
keeps the same pairing token. The browser reconnects to the updated bridge.
This includes bridge/web assets: desktop 3.6.0 receives the bridge 3.6.2 tunnel fix
without a new executable. Client remains 3.6.1. Refresh an open browser page to
load changed web assets. **Copy client script** still copies the client embedded
in the desktop executable. See [bridge 3.6.2 verification](../docs/TESTING_3.6.2.md).

The desktop app separately checks stable releases in
`Project-Ptolemy/ProjectUAI` on startup and every 15 minutes. It downloads and
verifies a compatible desktop executable in the background. A ready update
applies on restart; the **Restart to update app** action is available once the bridge is
stopped. Updates never automatically stop an active conversation.

Desktop versions are staged in a private per-install cache under LocalAppData.
The original executable is retained. The launcher remembers a verified
new version only after its window opens successfully, and falls back if it
cannot start. The original shortcut continues to work. Bridge cache identity
stays stable across desktop updates. Failed network or integrity checks leave
the current app usable and retry later.

Desktop 1.0 has no updater, so its users need one manual download of 3.6.0 first.
For each future release, publish `desktop-release.json`,
`UAI-Bridge-<version>-win-x64.exe`, and its adjacent `.sha256` on the same official
`v<version>` or `desktop-v<version>` GitHub release. The manifest includes the
exact version, platform, executable name, byte size and SHA-256. Bridge updates independently need `bridge-release.json`
and `uai-bridge-package.json`; see the [bridge guide](../bridge/README.md).

Desktop credentials live only in memory and rotate at each app start. The app
and native executor discover through a desktop-only POST endpoint requiring the
exact loopback Host, a custom header and JSON. Browser Origin and Fetch Metadata
headers are rejected, with no CORS support. Native programs on this computer are
inside this trust boundary; this is not authentication against local malware.
All ordinary bridge routes still require the bearer token.

Discovery returns a fixed product marker, schema, port, instance and token. The
client validates these before attaching and uses one shared effective connection
for commands, web inference and pictures. Credentials never replace saved manual
settings. A changed connection terminates an outstanding relay request rather
than resending it to a new process.

## Build and verification

Install the .NET 10 SDK for Windows and Node.js 18+ for verification. The package
build does not download Node or OpenCode. There are no NuGet library dependencies.
`desktop/make-icon.ps1` draws the native connection glyph; the app has no UAI logo
image. Manually audit all changed source, documentation and tests first, then build:

```powershell
luajit tools/bundle.lua --native
powershell -ExecutionPolicy Bypass -File desktop/build.ps1
# Optional local SDK: -Dotnet C:/path/to/dotnet.exe
```

Inspect generated client and desktop outputs, then verify:

```powershell
node --test bridge/tests/desktop.test.js bridge/tests/opencode-native.test.js bridge/tests/updater.test.js
luajit test/desktop_bridge.lua
luajit test/web_runtime.lua
luajit test/bridge_install.lua
luajit test/check.lua --native
luajit tools/bundle.lua --native --check
powershell -ExecutionPolicy Bypass -File desktop/verify.ps1
```

The desktop verification checks the release executable and embedded file hashes,
single-file startup, and the absence of bundled Node/OpenCode runtimes. It exercises
detected Node, repeated startup, discovery, simulated game status, graceful stop
and restart with a new token. It checks persisted preferences, launch switches,
native minimize/restore, and window-close shutdown against the packaged bridge.
It also renders native WinForms window previews in
`.build/verification/launcher.png` and `launcher-compact.png`; inspect them. These checks do not claim a live
executor/Roblox connection. The source compiles with the official Luau compiler.

Build outputs, dependency caches and intermediate files are ignored by Git.
Publish the executable, release manifest and adjacent SHA-256 as release assets.
This local build is unsigned; signing and public release publication are separate
distribution steps.
