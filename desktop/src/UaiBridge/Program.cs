using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Windows;

namespace ProjectUai.Bridge;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "--mcp-stdio")
            return McpHost.RunAsync(args[1..]).GetAwaiter().GetResult();
        DesktopUpdater.Configure(args);
        // Offline verification uses this executable as a controlled Node probe.
        if (args is ["--version"] && Environment.GetEnvironmentVariable("UAI_TEST_NODE_VERSION") is { } fixture)
        { Console.WriteLine(fixture); return 0; }
        int helper = Array.IndexOf(args, "--apply-update");
        if (helper >= 0 && helper + 1 < args.Length)
            return DesktopUpdater.RunHelperAsync(args[helper + 1]).GetAwaiter().GetResult();
        if (args.Length == 2 && args[0] == "--update-test")
            return DesktopUpdateTest.RunAsync(args[1]).GetAwaiter().GetResult();
        int updateParent = Array.IndexOf(args, "--update-test-parent");
        if (updateParent >= 0 && updateParent + 1 < args.Length)
            return DesktopUpdateTest.RunParentAsync(args[updateParent + 1]).GetAwaiter().GetResult();
        if (DesktopUpdateTest.TryRunWindowFixture(args, out int fixtureResult)) return fixtureResult;
        bool offline = args.Any(argument => argument is "--smoke-test" or "--render-preview" or "--render-preview-compact" or "--render-preview-narrow" or "--self-test" or "--window-test" or "--startup-test");
        if (offline)
        {
            Environment.SetEnvironmentVariable("UAI_BRIDGE_TEST_NO_UPDATES", "1");
            Environment.SetEnvironmentVariable("UAI_OPENCODE_DISABLED", "1");
        }
        if (args.Length == 2 && args[0] == "--self-test")
            return DesktopSelfTest.RunAsync(args[1]).GetAwaiter().GetResult();
        if (args.Length == 2 && args[0] == "--smoke-test")
            return SmokeAsync(args[1]).GetAwaiter().GetResult();
        if (args.Length == 2 && args[0] == "--startup-test")
            return DesktopStartupTest.RunAsync(args[1]).GetAwaiter().GetResult();
        var app = new Application { ShutdownMode = ShutdownMode.OnMainWindowClose };
        if (args.Length == 2 && args[0] == "--window-test") return DesktopWindowTest.Run(args[1]);
        string instanceName = offline && Environment.GetEnvironmentVariable("UAI_DESKTOP_TEST_INSTANCE") is { Length: > 0 } fixtureInstance
            ? "ProjectUAI.Bridge.Test." + fixtureInstance : "ProjectUAI.Bridge.28791";
        using var instance = new DesktopInstance(instanceName);
        if (!instance.OwnsWindow) { instance.RestoreExisting(); return 0; }
        if (!offline && DesktopUpdater.TryDispatch(args)) return 0;
        var bridge = new BridgeProcess();
        var window = new MainWindow(bridge, offline);
        window.Loaded += async (_, _) =>
        {
            if (!args.Contains("--update-receipt")) return;
            try
            {
                await Task.Run(EmbeddedPayload.Prepare);
                if (!window.IsClosed) DesktopUpdater.MarkReady(args);
            }
            catch (Exception)
            {
                // The helper owns fallback. A failed candidate must close without
                // a receipt or a modal dialog that could outlive the old app.
                window.Close();
            }
        };
        instance.Listen(window, window.RestoreWindow);
        if (args.Length == 2 && args[0] is "--render-preview" or "--render-preview-compact" or "--render-preview-narrow")
            window.RenderPreview(args[1], args[0] == "--render-preview-compact", args[0] == "--render-preview-narrow");
        try { app.Run(window); }
        finally
        {
            bridge.DisposeAsync().AsTask().GetAwaiter().GetResult();
        }
        return Environment.ExitCode;
    }

    // Exercises the packaged runtime and controller without opening a browser.
    private static async Task<int> SmokeAsync(string output)
    {
        var checks = new List<string>();
        try
        {
            await using var bridge = new BridgeProcess();
            using var http = new HttpClient(new HttpClientHandler { UseProxy = false, AllowAutoRedirect = false })
                { Timeout = TimeSpan.FromSeconds(4) };
            await bridge.StartAsync();
            checks.Add("Detected Node starts without a visible terminal");
            string firstUrl = bridge.BrowserUrl ?? throw new Exception("No browser address");
            await bridge.StartAsync();
            if (bridge.BrowserUrl != firstUrl) throw new Exception("Duplicate start replaced the bridge");
            checks.Add("Repeated start preserves the owned instance");
            await bridge.RefreshAsync();
            if (bridge.State != "Waiting for Roblox") throw new Exception("Incorrect disconnected state");
            using var discovery = new HttpRequestMessage(HttpMethod.Post, BridgeProcess.Origin + "/api/desktop/discover")
                { Content = new StringContent("{}", Encoding.UTF8, "application/json") };
            discovery.Headers.Add("X-UAI-Discovery", "1");
            using var response = await http.SendAsync(discovery);
            response.EnsureSuccessStatusCode();
            using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
            string secret = doc.RootElement.GetProperty("token").GetString()!;
            if (firstUrl != BridgeProcess.Origin + "/#t=" + secret) throw new Exception("Discovery mismatch");
            checks.Add("Native discovery returns the owned bridge credentials");
            using var events = new HttpRequestMessage(HttpMethod.Post, BridgeProcess.Origin + "/api/agent/events")
            {
                Content = new StringContent("{\"batchId\":\"desktop-smoke\",\"sessionId\":\"smoke\",\"events\":[],\"snapshot\":[],\"state\":{\"protocol\":2}}", Encoding.UTF8, "application/json")
            };
            events.Headers.Authorization = new AuthenticationHeaderValue("Bearer", secret);
            using var accepted = await http.SendAsync(events);
            accepted.EnsureSuccessStatusCode();
            await bridge.RefreshAsync();
            if (bridge.State != "Connected to Roblox") throw new Exception("Incorrect connected state");
            checks.Add("Connection status follows an authenticated simulated game");
            using var bridgeUpdateCheck = new HttpRequestMessage(HttpMethod.Post, BridgeProcess.Origin + "/api/desktop/update-check")
                { Content = new StringContent("{}", Encoding.UTF8, "application/json") };
            bridgeUpdateCheck.Headers.Authorization = new AuthenticationHeaderValue("Bearer", secret);
            using var updateResponse = await http.SendAsync(bridgeUpdateCheck);
            updateResponse.EnsureSuccessStatusCode();
            using var updateDoc = JsonDocument.Parse(await updateResponse.Content.ReadAsStringAsync());
            if (updateDoc.RootElement.GetProperty("ok").GetBoolean() != true ||
                updateDoc.RootElement.GetProperty("update").GetProperty("state").GetString() != "current")
                throw new Exception("Manual bridge update check did not settle");
            checks.Add("Manual bridge update check reports the running state");
            await bridge.StopAsync();
            if (bridge.BrowserUrl is not null || bridge.State != "Stopped") throw new Exception("Stop did not settle");
            await bridge.StartAsync();
            if (firstUrl == bridge.BrowserUrl) throw new Exception("Token was reused after restart");
            checks.Add("Graceful stop releases port; restart rotates credentials");
            await bridge.StopAsync();
            await File.WriteAllTextAsync(output, JsonSerializer.Serialize(new { ok = true, checks }, new JsonSerializerOptions { WriteIndented = true }));
            return 0;
        }
        catch (Exception error)
        {
            await File.WriteAllTextAsync(output, JsonSerializer.Serialize(new { ok = false, checks, error = error.Message }, new JsonSerializerOptions { WriteIndented = true }));
            return 1;
        }
    }
}
