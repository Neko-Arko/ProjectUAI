using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Threading;

namespace ProjectUai.Bridge;

// Exercises the production helper with actual standalone processes. All update
// files belong to fresh temporary installations; candidate/fallback windows are
// offline, offscreen, and admitted through a private instance namespace.
internal static class DesktopUpdateTest
{
    private const string FixtureEnvironment = "UAI_DESKTOP_UPDATE_TEST";
    private sealed record Fixture(string Id, string Root, string Key, string Mode)
    {
        internal string Installation => Path.Combine(Root, "installation");
        internal string Original => Path.Combine(Installation, "UAI Bridge.exe");
        internal string Cache => DesktopUpdater.CacheFor(Installation);
        internal string Spec => Path.Combine(Root, "fixture.json");
        internal string ParentReport => Path.Combine(Root, "parent.json");
        internal string ReleaseParent => Path.Combine(Root, "release-parent.json");
        internal string WindowReport => Path.Combine(Root, "window.json");
        internal string WindowFailure => Path.Combine(Root, "window-error.json");
        internal string WindowClosed => Path.Combine(Root, "window-closed.json");
    }

    internal static async Task<int> RunAsync(string output)
    {
        var checks = new List<string>();
        void Check(string name, bool condition)
        {
            if (!condition) throw new IOException(name);
            checks.Add(name);
        }
        try
        {
            string executable = Environment.ProcessPath ?? throw new IOException("No update test executable.");
            byte[] binary = UpdateFiles.ReadBounded(executable, 200 << 20);
            string hash = UpdateFiles.Hash(binary);
            foreach (string mode in new[] { "ready", "missing", "corrupt", "refused" })
            {
                string id = Guid.NewGuid().ToString("N");
                string root = UpdateFiles.Child(Path.GetTempPath(), "uai-desktop-update-" + id);
                var fixture = new Fixture(id, root, DesktopUpdater.CurrentVersion + "-" + hash, mode);
                Process? parent = null, helper = null, windowProcess = null;
                try
                {
                    UpdateFiles.NoLinks(root);
                    Directory.CreateDirectory(fixture.Installation);
                    File.WriteAllBytes(fixture.Original, binary);
                    var updater = new DesktopUpdater(fixture.Installation);
                    string key = updater.Stage(JsonSerializer.SerializeToUtf8Bytes(new
                    {
                        format = "project-uai-desktop-release", schema = 1, version = DesktopUpdater.CurrentVersion,
                        platform = "win-x64", protocol = 1,
                        package = new { name = $"UAI-Bridge-{DesktopUpdater.CurrentVersion}-win-x64.exe", bytes = binary.Length, sha256 = hash }
                    }), binary);
                    Check($"{mode}: real standalone bytes stage in an isolated installation", key == fixture.Key);
                    UpdateFiles.AtomicJson(Path.Combine(fixture.Cache, "pending.json"), new { key });
                    UpdateFiles.AtomicJson(fixture.Spec, fixture);
                    var info = DesktopUpdater.LaunchInfo(fixture.Original, "--installation-root", fixture.Installation,
                        "--installation-executable", fixture.Original, "--update-test-parent", fixture.Spec);
                    info.Environment[FixtureEnvironment] = fixture.Spec;
                    info.Environment["UAI_BRIDGE_TEST_NO_UPDATES"] = "1";
                    info.Environment["UAI_OPENCODE_DISABLED"] = "1";
                    info.Environment["UAI_CLINE_DISABLED"] = "1";
                    parent = Process.Start(info) ?? throw new IOException("The update parent fixture did not start.");
                    await WaitForFileAsync(fixture.ParentReport, parent, TimeSpan.FromSeconds(15));
                    using var parentReport = JsonDocument.Parse(UpdateFiles.ReadBounded(fixture.ParentReport, 8192));
                    var report = parentReport.RootElement;
                    if (report.TryGetProperty("error", out var error)) throw new IOException(error.GetString());
                    Check($"{mode}: the parent remains alive while the helper validates its request", !parent.HasExited &&
                        report.GetProperty("parentPid").GetInt32() == parent.Id);
                    bool accepted = report.GetProperty("accepted").GetBoolean();
                    if (mode == "refused")
                    {
                        Check("refused: a rejected helper never authorizes app shutdown", !accepted && report.GetProperty("helperExitCode").GetInt32() == 1 &&
                            ReadKey(Path.Combine(fixture.Cache, "pending.json")) == key && !File.Exists(fixture.WindowReport));
                    }
                    else
                    {
                        helper = OwnedProcess(report.GetProperty("helperPid").GetInt32(), report.GetProperty("helperStart").GetInt64());
                        Check($"{mode}: an exact-process acknowledgment arrives before the parent exits", accepted && helper is not null && !helper.HasExited);
                        Check($"{mode}: helper waits for parent exit before launching or activating", !File.Exists(fixture.WindowReport) &&
                            !File.Exists(Path.Combine(fixture.Cache, "active.json")));
                        string entry = updater.Verify(key).Entry;
                        if (mode == "missing") File.Delete(entry);
                        if (mode == "corrupt") File.WriteAllText(entry, "corrupted after helper handoff");
                    }
                    UpdateFiles.AtomicJson(fixture.ReleaseParent, new { release = true });
                    await parent.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5));
                    Check($"{mode}: the isolated parent exits cleanly after the handoff decision", parent.ExitCode == 0);
                    if (helper is not null)
                    {
                        await helper.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(35));
                        Check($"{mode}: production helper reports the transaction result", helper.ExitCode == (mode == "ready" ? 0 : 1));
                        await WaitForFileAsync(fixture.WindowReport, null, TimeSpan.FromSeconds(20), fixture.WindowFailure);
                        using var windowReport = JsonDocument.Parse(UpdateFiles.ReadBounded(fixture.WindowReport, 8192));
                        var child = windowReport.RootElement;
                        bool candidate = child.GetProperty("candidate").GetBoolean();
                        Check($"{mode}: only the expected candidate or retained fallback window opens", candidate == (mode == "ready") &&
                            child.GetProperty("offscreen").GetBoolean() && child.GetProperty("offline").GetBoolean());
                        windowProcess = OwnedProcess(child.GetProperty("pid").GetInt32(), child.GetProperty("processStart").GetInt64());
                        if (windowProcess is not null) await windowProcess.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(10));
                        await WaitForFileAsync(fixture.WindowClosed, null, TimeSpan.FromSeconds(5), fixture.WindowFailure);
                        using var closure = JsonDocument.Parse(UpdateFiles.ReadBounded(fixture.WindowClosed, 4096));
                        Check($"{mode}: the fixture window closes and releases its private instance", (windowProcess is null || windowProcess.ExitCode == 0) &&
                            closure.RootElement.GetProperty("exitCode").GetInt32() == 0 && !File.Exists(fixture.WindowFailure));
                        if (mode == "ready")
                            Check("ready: payload readiness commits the real candidate and consumes pending", ReadKey(Path.Combine(fixture.Cache, "active.json")) == key &&
                                !File.Exists(Path.Combine(fixture.Cache, "pending.json")) && !File.Exists(Path.Combine(fixture.Cache, "failed.json")));
                        else
                            Check($"{mode}: damage after handoff launches fallback without activating damaged bytes", !File.Exists(Path.Combine(fixture.Cache, "active.json")) &&
                                !File.Exists(Path.Combine(fixture.Cache, "pending.json")) && ReadKey(Path.Combine(fixture.Cache, "failed.json")) == key);
                    }
                    UpdateFiles.VerifyFile(fixture.Original, binary.Length, hash);
                    Check($"{mode}: the retained original executable remains intact", true);
                    Check($"{mode}: completed helpers remove their request and acknowledgment files", !Directory.EnumerateFiles(fixture.Cache)
                        .Any(file => Path.GetFileName(file).StartsWith(".request-", StringComparison.Ordinal)));
                }
                finally
                {
                    // Parent/helper identities are captured while alive. Tree
                    // termination can never target a reused or unrelated PID.
                    StopOwned(windowProcess); StopOwned(helper); StopOwned(parent);
                    windowProcess?.Dispose(); helper?.Dispose(); parent?.Dispose();
                    if (Directory.Exists(fixture.Cache)) UpdateFiles.RemoveOwnedDirectory(Path.GetDirectoryName(fixture.Cache)!, fixture.Cache);
                    UpdateFiles.RemoveOwnedDirectory(Path.GetTempPath(), root);
                }
            }
            await WriteResultAsync(output, new { ok = true, checks });
            return 0;
        }
        catch (Exception error)
        {
            await WriteResultAsync(output, new { ok = false, checks, error = error.ToString() });
            return 1;
        }
    }

    // This actual subprocess remains alive until the coordinator has inspected
    // the acknowledgment and (for failure cases) changed the staged bytes.
    internal static async Task<int> RunParentAsync(string specFile)
    {
        Fixture fixture = ReadFixture(specFile);
        Process? helper = null;
        bool accepted = false;
        try
        {
            using var parent = Process.GetCurrentProcess();
            string request = UpdateFiles.Child(fixture.Cache, ".request-" + Guid.NewGuid().ToString("N") + ".json");
            UpdateFiles.AtomicJson(request, new
            {
                key = fixture.Key, installationRoot = fixture.Installation, parentPid = Environment.ProcessId,
                parentStart = parent.StartTime.ToUniversalTime().Ticks,
                fallback = fixture.Mode == "refused" ? Path.Combine(fixture.Installation, "unowned.exe") : fixture.Original
            });
            helper = Process.Start(DesktopUpdater.LaunchInfo(fixture.Original, "--installation-root", fixture.Installation,
                "--installation-executable", fixture.Original, "--apply-update", request)) ?? throw new IOException("The production helper did not start.");
            long helperStart = helper.StartTime.ToUniversalTime().Ticks;
            var deadline = Stopwatch.StartNew();
            while (deadline.Elapsed < TimeSpan.FromSeconds(10))
            {
                if (File.Exists(request + ".accepted"))
                {
                    using var acknowledgment = JsonDocument.Parse(UpdateFiles.ReadBounded(request + ".accepted", 4096));
                    accepted = !helper.HasExited && acknowledgment.RootElement.GetProperty("key").GetString() == fixture.Key &&
                        DesktopUpdater.ReadinessMatches(acknowledgment.RootElement, helper.Id, helperStart);
                    break;
                }
                if (helper.HasExited) break;
                await Task.Delay(40);
            }
            if (fixture.Mode == "refused")
            {
                await helper.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5));
                if (accepted || helper.ExitCode != 1) throw new IOException("An invalid fallback request was accepted.");
            }
            else if (!accepted) throw new IOException("The production helper did not acknowledge its validated request.");
            UpdateFiles.AtomicJson(fixture.ParentReport, new
            {
                accepted, parentPid = Environment.ProcessId, helperPid = helper.Id, helperStart,
                helperExitCode = helper.HasExited ? helper.ExitCode : (int?)null
            });
            await WaitForFileAsync(fixture.ReleaseParent, null, TimeSpan.FromSeconds(15));
            return 0;
        }
        catch (Exception error)
        {
            UpdateFiles.AtomicJson(fixture.ParentReport, new { error = error.ToString(), parentPid = Environment.ProcessId });
            accepted = false;
            return 1;
        }
        finally
        {
            if (!accepted) StopOwned(helper);
            helper?.Dispose();
        }
    }

    // Only helper-created --skip-update children with a validated private spec
    // enter this branch. An invalid fixture exits instead of opening a real UI.
    internal static bool TryRunWindowFixture(string[] args, out int result)
    {
        result = 0;
        string? specFile = Environment.GetEnvironmentVariable(FixtureEnvironment);
        if (specFile is null || !args.Contains("--skip-update")) return false;
        Fixture? fixture = null;
        try
        {
            fixture = ReadFixture(specFile);
            bool candidate = args.Contains("--update-receipt");
            string expected = candidate ? new DesktopUpdater(fixture.Installation).Verify(fixture.Key).Entry : fixture.Original;
            if (!SamePath(Environment.ProcessPath!, expected)) throw new IOException("The update fixture launched an unexpected executable.");
            Environment.SetEnvironmentVariable("UAI_BRIDGE_TEST_NO_UPDATES", "1");
            Environment.SetEnvironmentVariable("UAI_OPENCODE_DISABLED", "1");
            Environment.SetEnvironmentVariable("UAI_CLINE_DISABLED", "1");
            using var instance = new DesktopInstance("ProjectUAI.Bridge.UpdateTest." + fixture.Id);
            if (!instance.OwnsWindow) throw new IOException("The private update fixture instance is already owned.");
            var app = new Application { ShutdownMode = ShutdownMode.OnMainWindowClose };
            var bridge = new BridgeProcess();
            var window = new MainWindow(bridge, true)
            {
                WindowStartupLocation = WindowStartupLocation.Manual,
                Left = -30000, Top = -30000, ShowInTaskbar = false, ShowActivated = false,
                Width = 640, Height = 600
            };
            int fixtureResult = 0;
            var watchdog = new DispatcherTimer { Interval = TimeSpan.FromSeconds(15) };
            watchdog.Tick += async (_, _) =>
            {
                watchdog.Stop(); fixtureResult = 1;
                UpdateFiles.AtomicJson(fixture.WindowFailure, new { error = "The offscreen update fixture exceeded its deadline." });
                await window.RequestCloseAsync();
            };
            window.Loaded += async (_, _) =>
            {
                try
                {
                    await Task.Run(EmbeddedPayload.Prepare);
                    if (candidate) DesktopUpdater.MarkReady(args);
                    using var process = Process.GetCurrentProcess();
                    UpdateFiles.AtomicJson(fixture.WindowReport, new
                    {
                        candidate, pid = Environment.ProcessId, processStart = process.StartTime.ToUniversalTime().Ticks,
                        offline = true, offscreen = window.Left < -10000 && window.Top < -10000 && !window.ShowInTaskbar
                    });
                    // Keep the real candidate alive while the production helper
                    // consumes its readiness receipt and commits the pointer.
                    await Task.Delay(2000);
                }
                catch (Exception error)
                {
                    fixtureResult = 1;
                    UpdateFiles.AtomicJson(fixture.WindowFailure, new { error = error.ToString() });
                }
                finally { watchdog.Stop(); await window.RequestCloseAsync(); }
            };
            watchdog.Start();
            try { app.Run(window); }
            finally { watchdog.Stop(); bridge.DisposeAsync().AsTask().GetAwaiter().GetResult(); }
            result = fixtureResult;
            UpdateFiles.AtomicJson(fixture.WindowClosed, new { exitCode = result });
        }
        catch (Exception error)
        {
            result = 1;
            if (fixture is not null) UpdateFiles.AtomicJson(fixture.WindowFailure, new { error = error.ToString() });
        }
        return true;
    }

    private static Fixture ReadFixture(string file)
    {
        string path = Path.GetFullPath(file);
        var fixture = JsonSerializer.Deserialize<Fixture>(UpdateFiles.ReadBounded(path, 8192)) ?? throw new IOException("Invalid update fixture.");
        if (!Regex.IsMatch(fixture.Id, @"\A[a-f0-9]{32}\z") || fixture.Mode is not ("ready" or "missing" or "corrupt" or "refused") ||
            !Regex.IsMatch(fixture.Key, @"\A\d+\.\d+\.\d+-[a-f0-9]{64}\z")) throw new IOException("Invalid update fixture identity.");
        string expectedRoot = UpdateFiles.Child(Path.GetTempPath(), "uai-desktop-update-" + fixture.Id);
        if (!SamePath(fixture.Root, expectedRoot) || !SamePath(path, fixture.Spec) || !SamePath(DesktopUpdater.InstallationRoot, fixture.Installation) ||
            !SamePath(DesktopUpdater.InstallationExecutable, fixture.Original)) throw new IOException("The update fixture escaped its temporary installation.");
        UpdateFiles.NoLinks(fixture.Root); UpdateFiles.NoLinks(fixture.Cache);
        return fixture;
    }

    private static bool SamePath(string left, string right) => string.Equals(Path.TrimEndingDirectorySeparator(Path.GetFullPath(left)),
        Path.TrimEndingDirectorySeparator(Path.GetFullPath(right)), StringComparison.OrdinalIgnoreCase);

    private static string ReadKey(string file)
    {
        using var document = JsonDocument.Parse(UpdateFiles.ReadBounded(file, 4096));
        return document.RootElement.GetProperty("key").GetString() ?? "";
    }

    private static Process? OwnedProcess(int pid, long start)
    {
        try
        {
            var process = Process.GetProcessById(pid);
            if (process.StartTime.ToUniversalTime().Ticks == start) return process;
            process.Dispose();
        }
        catch (ArgumentException) { }
        return null;
    }

    private static async Task WaitForFileAsync(string file, Process? process, TimeSpan timeout, string? failure = null)
    {
        var watch = Stopwatch.StartNew();
        while (watch.Elapsed < timeout)
        {
            if (File.Exists(file)) return;
            if (failure is not null && File.Exists(failure)) throw new IOException(File.ReadAllText(failure));
            if (process?.HasExited == true) throw new IOException("The update fixture exited before producing its report.");
            await Task.Delay(40);
        }
        throw new TimeoutException("The update fixture did not produce its report in time.");
    }

    private static void StopOwned(Process? process)
    {
        try { if (process is not null && !process.HasExited) { process.Kill(true); process.WaitForExit(5000); } }
        catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception) { }
    }

    private static Task WriteResultAsync(string output, object result) => File.WriteAllTextAsync(output,
        JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true }));
}
