using System.Diagnostics;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace ProjectUai.Bridge;

internal sealed class BridgeProcess : IAsyncDisposable
{
    public const int Port = 28791;
    public const string Origin = "http://127.0.0.1:28791";
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly HttpClient http = new(new HttpClientHandler { UseProxy = false, AllowAutoRedirect = false })
        { Timeout = TimeSpan.FromSeconds(3) };
    // Update checks download a full verified package before answering.
    private readonly HttpClient slowHttp = new(new HttpClientHandler { UseProxy = false, AllowAutoRedirect = false })
        { Timeout = TimeSpan.FromSeconds(60) };
    private Process? child;
    private ChildJob? job;
    private volatile bool stopping;
    private string? token;
    public string State { get; private set; } = "Stopped";
    public string Detail { get; private set; } = "Ready when you are.";
    public string UpdateState { get; private set; } = "current";
    public string BridgeVersion { get; private set; } = DesktopUpdater.CurrentVersion;
    public string OpenCodeState { get; private set; } = "stopped";
    public string? OpenCodeMessage { get; private set; }
    public string? OpenCodeVersion { get; private set; }
    public bool McpEnabled { get; private set; } = true;
    public string OpenCodeDetail => OpenCodeState switch
    {
        "ready" => "Your installed OpenCode CLI is connected" + (OpenCodeVersion is { Length: > 0 } ? " (" + OpenCodeVersion + ")." : "."),
        "starting" => "Starting your installed OpenCode CLI...",
        "missing" => OpenCodeMessage ?? "Install OpenCode Desktop or the v2 CLI, then restart Cowork.",
        "failed" => OpenCodeMessage ?? "OpenCode could not start. Update OpenCode Desktop, then restart Cowork.",
        "disabled" => "Native OpenCode is off for this bridge session.",
        _ => "Use free models through your installed OpenCode CLI."
    };
    public const string Discord = "https://discord.gg/9xYyyYuKap";
    private static string Help(string text) => text.Contains(Discord, StringComparison.Ordinal) ? text : text + " Help: " + Discord;
    public string? AvailableVersion { get; private set; }
    public string? UpdateError { get; private set; }
    public string? BrowserUrl => token is { } secret ? Origin + "/#t=" + secret : null;
    public event Action? Changed;

    private void SetState(string state, string detail)
    {
        State = state;
        Detail = detail;
        Changed?.Invoke();
    }

    public async Task StartAsync(BridgeLaunchOptions? options = null, CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken);
        try
        {
            if (child is { HasExited: false }) return;
            child?.Dispose(); child = null;
            job?.Dispose(); job = null;
            token = null;
            SetState("Starting", "Starting your local Cowork bridge...");
            string root = await Task.Run(EmbeddedPayload.Prepare, cancellationToken);
            var runtime = await NodeRuntime.FindAsync(cancellationToken);
            if (runtime is null) throw new IOException("Node.js is needed to run the bridge. Choose Download Node.js below, or install it from nodejs.org and check again.");
            string node = runtime.Path;
            string server = Path.Combine(root, "bridge", "server.js");
            if (!File.Exists(server))
                throw new IOException("The embedded bridge files are incomplete. Download a fresh copy of the desktop app.");

            var ready = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
            var process = new Process { StartInfo = new ProcessStartInfo(node)
            {
                WorkingDirectory = root, UseShellExecute = false, CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden, RedirectStandardInput = true,
                RedirectStandardOutput = true, RedirectStandardError = true
            }, EnableRaisingEvents = true };
            process.StartInfo.ArgumentList.Add(server);
            process.StartInfo.ArgumentList.Add("--desktop");
            process.StartInfo.Environment["UAI_BRIDGE_INSTALLATION_ID"] = Path.Combine(DesktopUpdater.InstallationRoot, "bridge", "server.js");
            process.StartInfo.Environment["UAI_DESKTOP_EXECUTABLE"] = Environment.ProcessPath;
            options?.Apply(process.StartInfo);
            McpEnabled = options?.McpEnabled ?? Environment.GetEnvironmentVariable("UAI_MCP_DISABLED") != "1";
            OpenCodeState = (options?.OpenCodeEnabled ?? Environment.GetEnvironmentVariable("UAI_OPENCODE_DISABLED") != "1") ? "starting" : "disabled";
            OpenCodeMessage = null; OpenCodeVersion = null;
            process.Exited += (_, _) =>
            {
                if (ReferenceEquals(child, process) && !stopping)
                {
                    token = null;
                    OpenCodeState = "stopped"; OpenCodeMessage = null; OpenCodeVersion = null;
                    SetState("Could not connect", "The bridge stopped unexpectedly. Click Start Cowork to restart it.");
                }
            };
            try { process.Start(); }
            catch { process.Dispose(); throw; }
            child = process;
            job = new ChildJob(process);
            _ = ReadOutputAsync(process, ready);
            // Drain stderr without recording potentially sensitive process output.
            _ = DrainErrorsAsync(process);
            // A cached worker gets one bounded startup attempt before the
            // supervisor restores the packaged worker. This is startup only;
            // inference itself has no overall bridge request deadline.
            string secret = await ready.Task.WaitAsync(TimeSpan.FromSeconds(40), cancellationToken);
            if (process.HasExited) throw new IOException("The bridge exited during startup. Try again.");
            token = secret;
            SetState("Waiting for Roblox", "Load the updated UAI script in Roblox. It will connect automatically.");
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            await StopCoreAsync();
            SetState("Stopped", "Ready when you are.");
            throw;
        }
        catch (Exception error)
        {
            await StopCoreAsync();
            string detail = error is TimeoutException
                ? "The bridge took too long to start. Try again or download a fresh copy of the app."
                : error.Message;
            SetState("Could not start", Help(detail));
            throw new IOException(detail);
        }
        finally { gate.Release(); }
    }

    private static async Task DrainErrorsAsync(Process process)
    {
        try { while (await process.StandardError.ReadLineAsync() is not null) { } }
        catch (Exception error) when (error is IOException or ObjectDisposedException or InvalidOperationException) { }
    }

    private static async Task ReadOutputAsync(Process process, TaskCompletionSource<string> ready)
    {
        try
        {
            while (await process.StandardOutput.ReadLineAsync() is { } line)
            {
                if (line.Length > 8192) continue;
                using var doc = JsonDocument.Parse(line);
                var value = doc.RootElement;
                if (value.GetProperty("type").GetString() == "error")
                {
                    string message = value.GetProperty("message").GetString() ?? "The bridge could not start.";
                    ready.TrySetException(new IOException(message));
                }
                else if (value.GetProperty("type").GetString() == "ready")
                {
                    string secret = value.GetProperty("token").GetString() ?? "";
                    if (value.GetProperty("product").GetString() != "project-uai-desktop" ||
                        value.GetProperty("protocol").GetInt32() != 1 || value.GetProperty("port").GetInt32() != Port ||
                        !Regex.IsMatch(secret, "\\A[a-f0-9]{64}\\z") ||
                        value.GetProperty("url").GetString() != Origin + "/#t=" + secret)
                        throw new IOException("The bridge package is incompatible. Download a fresh copy of the app.");
                    ready.TrySetResult(secret);
                }
            }
        }
        catch (Exception error) when (error is IOException or JsonException or KeyNotFoundException or InvalidOperationException)
        { ready.TrySetException(new IOException("The bridge returned an invalid startup response.")); }
        finally { ready.TrySetException(new IOException("The bridge stopped before it was ready. Try starting it again.")); }
    }

    public async Task RefreshAsync()
    {
        string? secret = token;
        if (secret is null || stopping) return;
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, Origin + "/api/hello");
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", secret);
            using var response = await http.SendAsync(request);
            response.EnsureSuccessStatusCode();
            using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
            bool connected = doc.RootElement.GetProperty("connected").GetBoolean();
            if (secret != token || stopping) return;
            if (doc.RootElement.TryGetProperty("capabilities", out var capabilities) && capabilities.TryGetProperty("opencode", out var openCode))
            {
                OpenCodeState = openCode.TryGetProperty("state", out var backendState) ? backendState.GetString() ?? "missing" : "missing";
                OpenCodeMessage = openCode.TryGetProperty("message", out var backendDetail) ? backendDetail.GetString() : null;
                OpenCodeVersion = openCode.TryGetProperty("version", out var backendVersion) ? backendVersion.GetString() : null;
            }
            if (capabilities.ValueKind == JsonValueKind.Object && capabilities.TryGetProperty("mcp", out var mcp))
                McpEnabled = !mcp.TryGetProperty("enabled", out var enabled) || enabled.GetBoolean();
            if (doc.RootElement.TryGetProperty("update", out var update)) ApplyUpdate(update);
            SetState(connected ? "Connected to Roblox" : "Waiting for Roblox", connected
                ? "Your conversation is ready in Cowork. Keep Roblox and this app running."
                : "Load the updated UAI script in Roblox. It will connect automatically.");
        }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException or JsonException or KeyNotFoundException or InvalidOperationException)
        {
            if (secret == token && !stopping)
                SetState("Reconnecting", "The bridge is not responding. If this continues, stop it and start it again.");
        }
    }

    private void ApplyUpdate(JsonElement update)
    {
        UpdateState = update.TryGetProperty("state", out var s) ? s.GetString() ?? "current" : "current";
        BridgeVersion = update.TryGetProperty("currentVersion", out var v) ? v.GetString() ?? BridgeVersion : BridgeVersion;
        AvailableVersion = update.TryGetProperty("availableVersion", out var a) ? a.GetString() : null;
        UpdateError = update.TryGetProperty("error", out var e) ? e.GetString() : null;
    }

    // The bridge supervisor owns bridge and web updates; this asks it to look now.
    public async Task CheckUpdatesAsync()
    {
        string? secret = token;
        if (secret is null || stopping) throw new IOException("Start the bridge before checking for its updates.");
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, Origin + "/api/desktop/update-check")
                { Content = new StringContent("{}", Encoding.UTF8, "application/json") };
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", secret);
            using var response = await slowHttp.SendAsync(request);
            response.EnsureSuccessStatusCode();
            using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
            ApplyUpdate(doc.RootElement.GetProperty("update"));
            Changed?.Invoke();
        }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException or JsonException or KeyNotFoundException or InvalidOperationException)
        { throw new IOException("The bridge update check did not complete. It will retry automatically."); }
    }

    public async Task StopAsync()
    {
        await gate.WaitAsync();
        try
        {
            SetState("Stopping", "Closing the local bridge...");
            await StopCoreAsync();
            SetState("Stopped", "Ready when you are.");
        }
        finally { gate.Release(); }
    }

    private async Task StopCoreAsync()
    {
        stopping = true;
        token = null;
        OpenCodeState = "stopped";
        var process = child;
        try
        {
            if (process is not null && !process.HasExited)
            {
                try
                {
                    await process.StandardInput.WriteLineAsync("{\"type\":\"stop\"}");
                    await process.StandardInput.FlushAsync();
                    await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(4));
                }
                catch (Exception error) when (error is IOException or InvalidOperationException or TimeoutException)
                {
                    if (!process.HasExited) process.Kill(entireProcessTree: true);
                    await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(3));
                }
            }
        }
        finally
        {
            job?.Dispose(); job = null;
            child = null;
            process?.Dispose();
            stopping = false;
        }
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync();
        http.Dispose();
        slowHttp.Dispose();
        gate.Dispose();
    }
}
