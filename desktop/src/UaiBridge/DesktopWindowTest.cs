using System.Text.Json;
using System.Text;

namespace ProjectUai.Bridge;

// Runs the native window with a real, offline bridge. It never opens a browser,
// checks for updates, or changes saved preferences. The window stays offscreen.
internal static class DesktopWindowTest
{
    internal static int Run(string output)
    {
        var checks = new List<string>();
        string? failure = null;
        var bridge = new BridgeProcess();
        using var form = new MainForm(bridge, offline: true)
        {
            StartPosition = FormStartPosition.Manual,
            Location = new Point(-30000, -30000)
        };
        using var instance = new DesktopInstance("ProjectUAI.Bridge.Test." + Guid.NewGuid().ToString("N"));
        int queuedRestores = 0;
        instance.RestoreExisting();
        instance.Listen(form, () => { form.RestoreWindow(); queuedRestores++; });
        using var deadline = new System.Windows.Forms.Timer { Interval = 50000 };
        deadline.Tick += (_, _) => { failure = "Window lifecycle exceeded 50 seconds."; deadline.Stop(); form.Close(); };
        form.Shown += async (_, _) =>
        {
            try
            {
                await bridge.StartAsync(new BridgeLaunchOptions(false, false));
                await bridge.RefreshAsync();
                if (bridge.BrowserUrl is null || bridge.OpenCodeState != "disabled" || bridge.McpEnabled)
                    throw new IOException("Integration switches did not reach the packaged bridge.");
                checks.Add("Packaged bridge honors disabled OpenCode and MCP switches");
                await Task.Delay(100);
                if (queuedRestores != 1) throw new IOException("A duplicate launch during startup lost its restore signal.");
                checks.Add("A duplicate launch before the window handle exists restores after first show");
                static IEnumerable<Control> Descendants(Control parent)
                {
                    foreach (Control child in parent.Controls)
                    {
                        yield return child;
                        foreach (Control nested in Descendants(child)) yield return nested;
                    }
                }
                var cards = Descendants(form).OfType<SurfacePanel>().Where(panel => panel.Fill == Color.White).ToArray();
                var buttons = Descendants(form).OfType<ActionButton>().ToArray();
                var scroll = form.Controls.OfType<Panel>().Single(panel => panel.AutoScroll);
                if (cards.Length != 4 || buttons.Length != 5) throw new IOException("The dashboard lost a settings card or action.");
                foreach (var size in new[] { new Size(700, 600), new Size(1000, 854) })
                {
                    form.ClientSize = size; form.PerformLayout(); await Task.Delay(100);
                    if (cards.Any(panel => !panel.Visible || panel.Width <= 0 || panel.Height <= 0 || !scroll.Contains(panel)) ||
                        buttons.Any(button => !button.Visible || button.Width <= 0 || button.Height <= 0 || string.IsNullOrWhiteSpace(button.AccessibleName) || !scroll.Contains(button)))
                        throw new IOException("Dashboard resizing hid or detached a settings card or accessible action.");
                    foreach (var button in buttons)
                    {
                        // WinForms ScrollControlIntoView uses nested container
                        // coordinates. Exercise the actual scrollbar range instead.
                        form.ActiveControl = null;
                        Rectangle before = scroll.RectangleToClient(button.RectangleToScreen(button.ClientRectangle));
                        int target = -scroll.AutoScrollPosition.Y + before.Top - (scroll.ClientSize.Height - before.Height) / 2;
                        scroll.AutoScrollPosition = new Point(0, Math.Max(0, target));
                        await Task.Delay(50);
                        Rectangle bounds = scroll.RectangleToClient(button.RectangleToScreen(button.ClientRectangle));
                        if (!scroll.ClientRectangle.IntersectsWith(bounds))
                            throw new IOException($"Dashboard action '{button.AccessibleName}' cannot be reached at {size.Width}x{size.Height}; bounds {bounds}, viewport {scroll.ClientRectangle}, display {scroll.DisplayRectangle}, minimum {scroll.AutoScrollMinSize}, child {scroll.Controls[0].Size}, offset {scroll.AutoScrollPosition}, target {target}, active {form.ActiveControl?.AccessibleName}.");
                    }
                    scroll.AutoScrollPosition = Point.Empty;
                }
                checks.Add("Narrow and restored layouts retain four settings cards and five accessible scroll-reachable actions");
                form.WindowState = FormWindowState.Minimized;
                await Task.Delay(150);
                if (!form.Visible || !form.ShowInTaskbar || form.WindowState != FormWindowState.Minimized)
                    throw new IOException("Minimize hid the native app from the taskbar.");
                checks.Add("Minimize preserves the native taskbar window");
                form.RestoreWindow(); await Task.Delay(150);
                if (!form.Visible || form.WindowState != FormWindowState.Normal) throw new IOException("Restore did not show the app.");
                checks.Add("Repeated-launch restore returns the normal window");
            }
            catch (Exception error) { failure = error.Message; }
            form.Close();
        };
        form.FormClosed += (_, _) =>
        {
            deadline.Stop();
            if (bridge.BrowserUrl is not null || bridge.State != "Stopped") failure ??= "Closing left an owned bridge running.";
            else checks.Add("Closing the running window waits for owned bridge shutdown");
        };
        try { deadline.Start(); Application.Run(form); }
        finally { bridge.DisposeAsync().AsTask().GetAwaiter().GetResult(); }
        // A ready update must survive ordinary X without spawning an updater
        // helper or reopening the app. The fixture bytes are never executable.
        string fixtureRoot = Path.Combine(Path.GetTempPath(), "uai-window-update-" + Guid.NewGuid().ToString("N"));
        try
        {
            string cache = Path.Combine(fixtureRoot, "cache");
            var current = Version.Parse(DesktopUpdater.CurrentVersion);
            string version = new Version(current.Major, current.Minor + 1, 0).ToString();
            byte[] bytes = Encoding.UTF8.GetBytes("MZ synthetic update: must never launch");
            byte[] manifest = JsonSerializer.SerializeToUtf8Bytes(new { format = "project-uai-desktop-release", schema = 1, version,
                platform = "win-x64", protocol = 1, package = new { name = $"UAI-Bridge-{version}-win-x64.exe", bytes = bytes.Length, sha256 = UpdateFiles.Hash(bytes) } });
            var staging = new DesktopUpdater(fixtureRoot, cacheDirectory: cache);
            string key = staging.Stage(manifest, bytes);
            string pending = Path.Combine(cache, "pending.json"); UpdateFiles.AtomicJson(pending, new { key });
            var ready = new DesktopUpdater(fixtureRoot, cacheDirectory: cache);
            if (!ready.ReadyToRestart) throw new IOException("Pending update fixture did not stage.");
            var idleBridge = new BridgeProcess();
            using var idle = new MainForm(idleBridge, offline: true, updates: ready)
                { StartPosition = FormStartPosition.Manual, Location = new Point(-30000, -30000) };
            idle.Shown += (_, _) => idle.BeginInvoke(idle.Close);
            try { Application.Run(idle); }
            finally { idleBridge.DisposeAsync().AsTask().GetAwaiter().GetResult(); }
            if (!ready.ReadyToRestart || !File.Exists(pending) || Directory.GetFiles(cache, ".request-*").Length != 0)
                throw new IOException("Normal close consumed or launched the staged update.");
            checks.Add("Closing with a staged update exits and retains it for the next launch");
        }
        catch (Exception error) { failure ??= error.Message; }
        finally { UpdateFiles.RemoveOwnedDirectory(Path.GetTempPath(), fixtureRoot); }
        File.WriteAllText(output, JsonSerializer.Serialize(new { ok = failure is null, checks, error = failure }, new JsonSerializerOptions { WriteIndented = true }));
        return failure is null ? 0 : 1;
    }
}
