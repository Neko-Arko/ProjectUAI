using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

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
        bool offline = args.Any(argument => argument is "--smoke-test" or "--render-preview" or "--render-preview-compact" or "--self-test" or "--window-test");
        if (offline)
        {
            Environment.SetEnvironmentVariable("UAI_BRIDGE_TEST_NO_UPDATES", "1");
            Environment.SetEnvironmentVariable("UAI_OPENCODE_DISABLED", "1");
        }
        if (args.Length == 2 && args[0] == "--self-test")
            return DesktopSelfTest.RunAsync(args[1]).GetAwaiter().GetResult();
        if (args.Length == 2 && args[0] == "--smoke-test")
            return SmokeAsync(args[1]).GetAwaiter().GetResult();
        ApplicationConfiguration.Initialize();
        if (args.Length == 2 && args[0] == "--window-test") return DesktopWindowTest.Run(args[1]);
        using var mutex = new Mutex(true, @"Local\ProjectUAI.Bridge.28791", out bool first);
        using var show = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\ProjectUAI.Bridge.Show.28791");
        if (!first) { show.Set(); return 0; }
        if (!offline && DesktopUpdater.TryDispatch(args)) return 0;
        var bridge = new BridgeProcess();
        using var form = new MainForm(bridge, offline);
        form.Shown += async (_, _) =>
        {
            if (!args.Contains("--update-receipt")) return;
            try
            {
                await Task.Run(EmbeddedPayload.Prepare);
                if (!form.IsDisposed) DesktopUpdater.MarkReady(args);
            }
            catch (Exception)
            {
                // The helper owns fallback. A failed candidate must close without
                // a receipt or a modal dialog that could outlive the old app.
                form.Close();
            }
        };
        var waiter = ThreadPool.RegisterWaitForSingleObject(show, (_, _) =>
        {
            if (form.IsHandleCreated && !form.IsDisposed)
                try { form.BeginInvoke(form.RestoreWindow); } catch (InvalidOperationException) { }
        }, null, Timeout.Infinite, false);
        if (args.Length == 2 && args[0] is "--render-preview" or "--render-preview-compact") form.RenderPreview(args[1], args[0] == "--render-preview-compact");
        try { Application.Run(form); }
        finally
        {
            waiter.Unregister(null);
            bridge.DisposeAsync().AsTask().GetAwaiter().GetResult();
            mutex.ReleaseMutex();
        }
        return 0;
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
