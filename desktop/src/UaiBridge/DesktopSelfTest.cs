using System.Text;
using System.Text.Json;

namespace ProjectUai.Bridge;

// Synthetic offline checks. No installer, release download, app replacement, or
// bridge startup runs here. Only --version probe children use a real process.
internal static class DesktopSelfTest
{
    public static async Task<int> RunAsync(string output)
    {
        var checks = new List<string>();
        string root = Path.Combine(Path.GetTempPath(), "uai-desktop-selftest-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        string? oldFixture = Environment.GetEnvironmentVariable("UAI_TEST_NODE_VERSION");
        void Check(string name, bool condition) { if (!condition) throw new IOException(name); checks.Add(name); }
        void Reject(string name, Action action)
        {
            bool rejected = false;
            try { action(); } catch (Exception error) when (error is IOException or JsonException or ArgumentException or FormatException or InvalidOperationException) { rejected = true; }
            Check(name, rejected);
        }
        try
        {
            string preferencesPath = Path.Combine(root, "preferences.json");
            Check("Missing preferences preserve enabled integrations and manual startup", DesktopPreferences.Load(preferencesPath) == new DesktopPreferences());
            var savedPreferences = new DesktopPreferences(false, false, false, false, true); savedPreferences.Save(preferencesPath);
            Check("All desktop switches survive a new preferences load", DesktopPreferences.Load(preferencesPath) == savedPreferences);
            File.WriteAllText(preferencesPath, "{\"OpenCodeEnabled\":false}");
            Check("Partial older preferences keep defaults for newly added controls", DesktopPreferences.Load(preferencesPath) == new DesktopPreferences(OpenCodeEnabled: false));
            File.WriteAllText(preferencesPath, "{\"OpenCodeEnabled\":\"yes\"}");
            Check("Invalid preferences recover to usable defaults", DesktopPreferences.Load(preferencesPath) == new DesktopPreferences());
            var launch = new System.Diagnostics.ProcessStartInfo();
            launch.Environment["UAI_OPENCODE_BINARY"] = "C:\\Installed App\\opencode-cli.exe";
            savedPreferences.BridgeOptions.Apply(launch);
            Check("Disabled integration switches are passed to the child process", launch.Environment["UAI_OPENCODE_DISABLED"] == "1" && launch.Environment["UAI_MCP_DISABLED"] == "1");
            new DesktopPreferences().BridgeOptions.Apply(launch);
            Check("Re-enabled integrations override stale disables and retain binary override", launch.Environment["UAI_OPENCODE_DISABLED"] == "0" && launch.Environment["UAI_MCP_DISABLED"] == "0" && launch.Environment["UAI_OPENCODE_BINARY"] == "C:\\Installed App\\opencode-cli.exe");
            string launchFixture = Path.Combine(root, "App with spaces", "Cowork.exe");
            var replacement = DesktopUpdater.LaunchInfo(launchFixture, "--skip-update", "--update-receipt", "receipt with spaces.json");
            var fallbackLaunch = DesktopUpdater.LaunchInfo(launchFixture, "--skip-update");
            var helperLaunch = DesktopUpdater.LaunchInfo(launchFixture, "--apply-update", "request with spaces.json");
            Check("Updated and fallback windows launch normally while the helper stays hidden", replacement.WindowStyle == System.Diagnostics.ProcessWindowStyle.Normal && fallbackLaunch.WindowStyle == System.Diagnostics.ProcessWindowStyle.Normal && helperLaunch.WindowStyle == System.Diagnostics.ProcessWindowStyle.Hidden);
            Check("Update launch preserves paths and arguments with spaces without a shell", !replacement.UseShellExecute && replacement.FileName == launchFixture && replacement.ArgumentList[2] == "receipt with spaces.json");
            Check("Stable versions reject previews, leading zeroes, and overflow", UpdateFiles.StableVersion("24.1.0", out _) &&
                !UpdateFiles.StableVersion("24.1.0-rc.1", out _) && !UpdateFiles.StableVersion("024.1.0", out _) && !UpdateFiles.StableVersion("99999999999999.1.0", out _));
            Check("Missing Node returns a setup state without running another candidate", await NodeRuntime.FindAsync(default, [], Path.Combine(root, "empty-node")) is null);
            string executable = Environment.ProcessPath ?? throw new IOException("No test executable.");
            Environment.SetEnvironmentVariable("UAI_TEST_NODE_VERSION", "v16.20.0");
            Check("Node older than 18 is rejected", await NodeRuntime.FindAsync(default, [executable], Path.Combine(root, "empty-node")) is null);
            Environment.SetEnvironmentVariable("UAI_TEST_NODE_VERSION", "v24.1.0");
            Check("Supported Node is detected from the supplied executable", await NodeRuntime.FindAsync(default, [executable], Path.Combine(root, "empty-node")) is { Version: "24.1.0", Managed: false });
            string sum = new string('a', 64);
            Check("Official Node checksum selects the exact Windows executable", NodeRuntime.ParseChecksum(sum + "  win-x64/node.exe\n", "win-x64/node.exe") == sum);
            Reject("Ambiguous Node checksum is rejected", () => NodeRuntime.ParseChecksum(sum + "  win-x64/node.exe\n" + sum + "  win-x64/node.exe\n", "win-x64/node.exe"));
            Reject("A different platform checksum is rejected", () => NodeRuntime.ParseChecksum(sum + "  win-arm64/node.exe\n", "win-x64/node.exe"));
            byte[] sample = Encoding.UTF8.GetBytes("verified runtime bytes");
            string file = Path.Combine(root, "hash.bin"); File.WriteAllBytes(file, sample);
            UpdateFiles.VerifyFile(file, sample.Length, UpdateFiles.Hash(sample));
            File.WriteAllText(file, "changed runtime bytes");
            Reject("Runtime hash tampering is rejected", () => UpdateFiles.VerifyFile(file, sample.Length, UpdateFiles.Hash(sample)));
            Reject("Cache paths cannot escape through traversal", () => UpdateFiles.Child(root, "../escaped.exe"));
            bool urlRejected = false;
            try { await UpdateFiles.DownloadAsync(new Uri("https://untrusted.invalid/file.exe"), 16, false, default); } catch (IOException) { urlRejected = true; }
            Check("Untrusted update hosts are rejected before network access", urlRejected);

            string original = Path.Combine(root, "original"); Directory.CreateDirectory(original);
            string originalFile = Path.Combine(original, "My Cowork.exe"); File.WriteAllText(originalFile, "original app stays intact");
            string cache = Path.Combine(root, "cache");
            var updater = new DesktopUpdater(original, cacheDirectory: cache);
            var currentVersion = Version.Parse(DesktopUpdater.CurrentVersion);
            string updateVersion = new Version(currentVersion.Major, currentVersion.Minor + 1, 0).ToString();
            string laterVersion = new Version(currentVersion.Major, currentVersion.Minor + 2, 0).ToString();
            byte[] binary = Encoding.UTF8.GetBytes("MZ synthetic release: never execute");
            byte[] manifest = Manifest(updateVersion, binary);
            string key = updater.Stage(manifest, binary);
            var staged = updater.Verify(key);
            Check("Verified single executable stages in a private version cache", staged.Version == updateVersion && File.ReadAllBytes(staged.Entry).SequenceEqual(binary));
            Check("Staging preserves the exact original download", File.ReadAllText(originalFile) == "original app stays intact" && Directory.GetFiles(original).Length == 1);
            Reject("A tampered executable never stages", () => updater.Stage(manifest, Encoding.UTF8.GetBytes("different")));
            Reject("Manifest cannot select another asset path", () => updater.Stage(Manifest(updateVersion, binary, "../app.exe"), binary));
            Reject("Preview version metadata is not accepted", () => DesktopUpdater.ParseManifest(Manifest(updateVersion + "-rc.1", binary)));
            Reject("Invalid cache keys never resolve outside the cache", () => updater.Verify("../../original/My Cowork.exe"));
            File.WriteAllText(staged.Entry, "corrupted");
            Reject("Cached executable is checked again before launch", () => updater.Verify(key));
            Check("A fresh verified download repairs corrupt cached bytes", updater.Stage(manifest, binary) == key && updater.Verify(key).Version == updateVersion);
            string extra = Path.Combine(Path.GetDirectoryName(staged.Entry)!, "unexpected.dll"); File.WriteAllText(extra, "unlisted");
            Reject("Unlisted cached DLLs cannot affect an app launch", () => updater.Verify(key)); File.Delete(extra);

            int rollbacks = 0, launches = 0;
            bool failed = await updater.CompleteRestartAsync(key, candidate => { launches++; return Task.FromResult(false); }, () => rollbacks++);
            Check("Failed readiness invokes fallback once without activation", !failed && launches == 1 && rollbacks == 1 && !File.Exists(Path.Combine(cache, "active.json")));
            UpdateFiles.AtomicJson(Path.Combine(cache, "pending.json"), new { key });
            Check("A failed release does not force repeated automatic startup retries", !new DesktopUpdater(original, cacheDirectory: cache).ReadyToRestart);
            File.Delete(Path.Combine(cache, "failed.json"));
            UpdateFiles.AtomicJson(Path.Combine(cache, "pending.json"), new { key });
            bool accepted = await updater.CompleteRestartAsync(key, _ => Task.FromResult(true), () => rollbacks++);
            Check("Ready app activates atomically and consumes its pending marker", accepted && File.Exists(Path.Combine(cache, "active.json")) && !File.Exists(Path.Combine(cache, "pending.json")) && rollbacks == 1);
            string activeBefore = File.ReadAllText(Path.Combine(cache, "active.json"));
            byte[] later = Encoding.UTF8.GetBytes("MZ next synthetic release");
            string next = updater.Stage(Manifest(laterVersion, later), later);
            bool rollback = await updater.CompleteRestartAsync(next, _ => throw new IOException("simulated launch failure"), () => rollbacks++);
            Check("A failed newer app keeps the previous active release", !rollback && rollbacks == 2 && File.ReadAllText(Path.Combine(cache, "active.json")) == activeBefore);
            bool tamperedDuringLaunch = await updater.CompleteRestartAsync(next, candidate => { File.WriteAllText(candidate.Entry, "changed after start"); return Task.FromResult(true); }, () => rollbacks++);
            Check("Hash changes during readiness cannot activate", !tamperedDuringLaunch && rollbacks == 3 && File.ReadAllText(Path.Combine(cache, "active.json")) == activeBefore);

            using var releaseList = JsonDocument.Parse(JsonSerializer.SerializeToUtf8Bytes(new[] { Release(updateVersion), Release("9.0.0", true), Release("4.0.0", false, true) }));
            Check("Selection accepts only stable official executable assets", DesktopUpdater.SelectRelease(releaseList.RootElement, DesktopUpdater.CurrentVersion)?.Version == updateVersion);
            int downloads = 0;
            byte[] releases = JsonSerializer.SerializeToUtf8Bytes(new[] { Release(updateVersion) });
            var downloaded = new DesktopUpdater(original, (uri, limit, node, token) =>
            {
                downloads++;
                return Task.FromResult(uri.Host == "api.github.com" ? releases : uri.AbsolutePath.EndsWith("desktop-release.json", StringComparison.Ordinal) ? manifest : binary);
            }, Path.Combine(root, "downloaded"));
            await downloaded.CheckAsync();
            Check("Offline release check downloads and stages without launching", downloads == 3 && downloaded.ReadyToRestart && downloaded.AvailableVersion == updateVersion);
            var reopened = new DesktopUpdater(original, cacheDirectory: Path.Combine(root, "downloaded"));
            Check("Pending update survives a fresh app instance", reopened.ReadyToRestart && reopened.AvailableVersion == updateVersion);
            Check("Installation cache identity ignores trailing separator and casing", DesktopUpdater.CacheFor(original) == DesktopUpdater.CacheFor(original.ToUpperInvariant() + Path.DirectorySeparatorChar));
            await File.WriteAllTextAsync(output, JsonSerializer.Serialize(new { ok = true, checks }, new JsonSerializerOptions { WriteIndented = true }));
            return 0;
        }
        catch (Exception error)
        {
            await File.WriteAllTextAsync(output, JsonSerializer.Serialize(new { ok = false, checks, error = error.ToString() }, new JsonSerializerOptions { WriteIndented = true }));
            return 1;
        }
        finally
        {
            Environment.SetEnvironmentVariable("UAI_TEST_NODE_VERSION", oldFixture);
            UpdateFiles.RemoveOwnedDirectory(Path.GetTempPath(), root);
        }
    }

    private static byte[] Manifest(string version, byte[] bytes, string? filename = null) => JsonSerializer.SerializeToUtf8Bytes(new {
        format = "project-uai-desktop-release", schema = 1, version, platform = "win-x64", protocol = 1,
        package = new { name = filename ?? $"UAI-Bridge-{version}-win-x64.exe", bytes = bytes.Length, sha256 = UpdateFiles.Hash(bytes) } });

    private static object Release(string version, bool prerelease = false, bool untrusted = false)
    {
        string[] names = ["desktop-release.json", $"UAI-Bridge-{version}-win-x64.exe"];
        return new { draft = false, prerelease, tag_name = "v" + version, assets = names.Select(name => new {
            name, browser_download_url = $"https://github.com/{(untrusted ? "Other/Repo" : "Project-Ptolemy/ProjectUAI")}/releases/download/v{version}/{name}" }).ToArray() };
    }
}
