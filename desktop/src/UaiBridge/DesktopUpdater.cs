using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace ProjectUai.Bridge;

internal sealed class DesktopUpdater
{
    public const string CurrentVersion = "3.3.5";
    private const string Repo = "Project-Ptolemy/ProjectUAI";
    private const string ManifestName = "desktop-release.json";
    private const string Executable = "UAI Bridge.exe";
    private const int MaxExecutable = 200 << 20;
    public static string InstallationRoot { get; private set; } = Path.GetFullPath(AppContext.BaseDirectory);
    public static string InstallationExecutable { get; private set; } = Environment.ProcessPath ?? Path.Combine(InstallationRoot, Executable);
    private readonly string cache;
    private readonly Func<Uri, int, bool, CancellationToken, Task<byte[]>> download;
    private bool checking;
    private string? stagedKey;
    public string State { get; private set; } = "Current";
    public string Detail { get; private set; } = "Updates are checked automatically.";
    public string? AvailableVersion { get; private set; }
    public bool ReadyToRestart => stagedKey is not null;
    public event Action? Changed;

    public DesktopUpdater(string? installationRoot = null, Func<Uri, int, bool, CancellationToken, Task<byte[]>>? fetch = null, string? cacheDirectory = null)
    {
        string root = Path.GetFullPath(installationRoot ?? InstallationRoot);
        cache = cacheDirectory is null ? CacheFor(root) : Path.GetFullPath(cacheDirectory); download = fetch ?? UpdateFiles.DownloadAsync;
        try
        {
            string key = ReadPointer("pending.json");
            var pending = Verify(key);
            if (!Rejected(key) && Version.Parse(pending.Version) > Version.Parse(CurrentVersion))
            { stagedKey = key; AvailableVersion = pending.Version; State = "Ready"; Detail = "An update is ready for the next app restart."; }
        }
        catch (Exception error) when (Recoverable(error)) { }
    }

    internal static string CacheFor(string root) => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "ProjectUAI", "desktop-updates", UpdateFiles.Hash(Encoding.UTF8.GetBytes(Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar).ToLowerInvariant()))[..32]);
    private static bool Recoverable(Exception error) => error is IOException or UnauthorizedAccessException or JsonException or ArgumentException or
        KeyNotFoundException or InvalidOperationException or FormatException or HttpRequestException or OperationCanceledException or System.ComponentModel.Win32Exception;
    private void Set(string state, string detail) { State = state; Detail = detail; Changed?.Invoke(); }
    private string ReadPointer(string name)
    {
        using var doc = JsonDocument.Parse(UpdateFiles.ReadBounded(Path.Combine(cache, name), 4096));
        return doc.RootElement.GetProperty("key").GetString() ?? throw new IOException("Invalid update pointer.");
    }
    private bool Rejected(string key)
    {
        try { return ReadPointer("failed.json") == key; }
        catch (Exception error) when (Recoverable(error)) { return false; }
    }

    public async Task CheckAsync(CancellationToken cancellationToken = default)
    {
        if (checking || ReadyToRestart) return;
        checking = true; Set("Checking", "Checking GitHub for an app update...");
        try
        {
            using var releases = JsonDocument.Parse(await download(new Uri($"https://api.github.com/repos/{Repo}/releases?per_page=100"), 2 << 20, false, cancellationToken));
            var candidate = SelectRelease(releases.RootElement, CurrentVersion);
            if (candidate is null) { Set("Current", "You have the latest compatible app release."); return; }
            var (version, manifestUri, archiveUri) = candidate.Value;
            byte[] manifestBytes = await download(manifestUri, 64 << 10, false, cancellationToken);
            var manifest = ParseManifest(manifestBytes, version);
            AvailableVersion = version; Set("Downloading", $"Downloading app version {version}...");
            byte[] archive = await download(archiveUri, MaxExecutable, false, cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();
            string key = Stage(manifestBytes, archive);
            if (Rejected(key)) { Set("Unavailable", "This update could not start on this computer. The current version remains available."); return; }
            UpdateFiles.AtomicJson(Path.Combine(cache, "pending.json"), new { key });
            stagedKey = key;
            Set("Ready", $"Version {version} is ready. It will apply when the app restarts.");
        }
        catch (Exception error) when (Recoverable(error))
        { Set("Unavailable", "Could not verify an app update. This version remains ready to use; another check will follow."); }
        finally { checking = false; }
    }

    internal static (string Version, Uri Manifest, Uri Archive)? SelectRelease(JsonElement releases, string current)
    {
        if (releases.ValueKind != JsonValueKind.Array) throw new IOException("Invalid release list.");
        var candidates = new List<(string Version, Uri Manifest, Uri Archive)>();
        foreach (var release in releases.EnumerateArray().Take(100))
        {
            if (!release.TryGetProperty("draft", out var draft) || draft.ValueKind != JsonValueKind.False ||
                !release.TryGetProperty("prerelease", out var pre) || pre.ValueKind != JsonValueKind.False ||
                !release.TryGetProperty("tag_name", out var tagElement) || !release.TryGetProperty("assets", out var assets) || assets.ValueKind != JsonValueKind.Array) continue;
            string tag = tagElement.GetString() ?? "";
            var match = Regex.Match(tag, @"\A(?:desktop-)?v(\d+\.\d+\.\d+)\z");
            if (!match.Success || !UpdateFiles.StableVersion(match.Groups[1].Value, out var parsed) || parsed <= Version.Parse(current)) continue;
            string version = match.Groups[1].Value;
            Uri? Asset(string name)
            {
                string expected = $"https://github.com/{Repo}/releases/download/{tag}/{name}";
                var matches = assets.EnumerateArray().Where(asset => asset.TryGetProperty("name", out var n) && n.GetString() == name).ToArray();
                return matches.Length == 1 && matches[0].TryGetProperty("browser_download_url", out var u) && u.GetString() == expected ? new Uri(expected) : null;
            }
            var manifest = Asset(ManifestName); var archive = Asset($"UAI-Bridge-{version}-win-x64.exe");
            if (manifest is not null && archive is not null) candidates.Add((version, manifest, archive));
        }
        return candidates.Count == 0 ? null : candidates.OrderByDescending(item => Version.Parse(item.Version)).First();
    }

    internal sealed record ReleaseManifest(string Version, string Hash, long Bytes);
    internal static ReleaseManifest ParseManifest(byte[] bytes, string? expected = null)
    {
        using var doc = JsonDocument.Parse(Encoding.UTF8.GetString(bytes).TrimStart('\uFEFF'));
        var value = doc.RootElement;
        string version = value.GetProperty("version").GetString() ?? "";
        var package = value.GetProperty("package");
        string hash = package.GetProperty("sha256").GetString() ?? "";
        long size = package.GetProperty("bytes").GetInt64();
        if (value.GetProperty("format").GetString() != "project-uai-desktop-release" || value.GetProperty("schema").GetInt32() != 1 ||
            value.GetProperty("protocol").GetInt32() != 1 || value.GetProperty("platform").GetString() != "win-x64" ||
            !UpdateFiles.StableVersion(version, out _) || (expected is not null && version != expected) ||
            package.GetProperty("name").GetString() != $"UAI-Bridge-{version}-win-x64.exe" || size <= 0 || size > MaxExecutable ||
            !Regex.IsMatch(hash, @"\A[a-f0-9]{64}\z")) throw new IOException("Incompatible desktop release manifest.");
        return new ReleaseManifest(version, hash, size);
    }

    internal string Stage(byte[] manifestBytes, byte[] executableBytes)
    {
        var manifest = ParseManifest(manifestBytes);
        if (executableBytes.Length != manifest.Bytes || UpdateFiles.Hash(executableBytes) != manifest.Hash)
            throw new IOException("Desktop executable SHA-256 mismatch.");
        string key = manifest.Version + "-" + manifest.Hash;
        string destination = UpdateFiles.Child(cache, "versions/" + key);
        UpdateFiles.NoLinks(destination); Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
        if (Directory.Exists(destination))
        {
            try { Verify(key); return key; }
            catch (Exception error) when (Recoverable(error))
            { Directory.Move(destination, UpdateFiles.Child(cache, ".invalid-" + Guid.NewGuid().ToString("N"))); }
        }
        string stage = UpdateFiles.Child(cache, ".stage-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(stage);
        try
        {
            File.WriteAllBytes(Path.Combine(stage, Executable), executableBytes);
            File.WriteAllBytes(Path.Combine(stage, ManifestName), manifestBytes);
            VerifyContents(stage, manifest);
            Directory.Move(stage, destination);
            return key;
        }
        finally { UpdateFiles.RemoveOwnedDirectory(cache, stage); }
    }

    internal sealed record CachedRelease(string Key, string Version, string Entry);
    internal CachedRelease Verify(string key)
    {
        if (!Regex.IsMatch(key, @"\A\d+\.\d+\.\d+-[a-f0-9]{64}\z")) throw new IOException("Invalid cached desktop version.");
        string directory = UpdateFiles.Child(cache, "versions/" + key);
        var manifest = ParseManifest(UpdateFiles.ReadBounded(Path.Combine(directory, ManifestName), 64 << 10));
        if (key != manifest.Version + "-" + manifest.Hash) throw new IOException("Cached desktop manifest mismatch.");
        VerifyContents(directory, manifest);
        return new CachedRelease(key, manifest.Version, Path.Combine(directory, Executable));
    }

    private static void VerifyContents(string directory, ReleaseManifest manifest)
    {
        UpdateFiles.NoLinks(directory);
        UpdateFiles.VerifyFile(Path.Combine(directory, Executable), manifest.Bytes, manifest.Hash);
        foreach (string entry in Directory.EnumerateFileSystemEntries(directory))
        {
            UpdateFiles.NoLinks(entry);
            if (Directory.Exists(entry) || Path.GetFileName(entry) is not (Executable or ManifestName))
                throw new IOException("Unexpected cached release file.");
        }
    }
    // Launch an independent, installed helper. It waits for this app and its
    // bridge to close, then verifies again and starts the staged copy. No file in
    // the original download is overwritten; its shortcut remains a safe fallback.
    public bool ApplyOnExit()
    {
        if (stagedKey is null) return false;
        try
        {
            Verify(stagedKey);
            string helper = Environment.ProcessPath ?? throw new IOException("Application path is unavailable.");
            string request = UpdateFiles.Child(cache, ".request-" + Guid.NewGuid().ToString("N") + ".json");
            UpdateFiles.AtomicJson(request, new { key = stagedKey, installationRoot = InstallationRoot,
                parentPid = Environment.ProcessId, parentStart = Process.GetCurrentProcess().StartTime.ToUniversalTime().Ticks,
                fallback = helper });
            using var process = Start(helper, "--installation-root", InstallationRoot, "--installation-executable", InstallationExecutable, "--apply-update", request);
            stagedKey = null; return true;
        }
        catch (Exception error) when (Recoverable(error))
        { Set("Unavailable", "The update could not restart. The current app is still available; try again later."); return false; }
    }

    private static Process Start(string executable, params string[] args)
    {
        return Process.Start(LaunchInfo(executable, args)) ?? throw new IOException("The updated app could not start.");
    }

    internal static ProcessStartInfo LaunchInfo(string executable, params string[] args)
    {
        // The updater helper has no window. The replacement and fallback are
        // interactive apps and must return to the taskbar visibly after restart.
        var info = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true,
            WindowStyle = args.Contains("--apply-update") ? ProcessWindowStyle.Hidden : ProcessWindowStyle.Normal,
            WorkingDirectory = Path.GetDirectoryName(executable)! };
        foreach (string argument in args) info.ArgumentList.Add(argument);
        return info;
    }

    public static void Configure(string[] args)
    {
        int at = Array.IndexOf(args, "--installation-root");
        if (at >= 0 && at + 1 < args.Length && Path.IsPathFullyQualified(args[at + 1])) InstallationRoot = Path.GetFullPath(args[at + 1]);
        at = Array.IndexOf(args, "--installation-executable");
        if (at >= 0 && at + 1 < args.Length && Path.IsPathFullyQualified(args[at + 1]) &&
            string.Equals(Path.GetDirectoryName(Path.GetFullPath(args[at + 1])), InstallationRoot.TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase))
            InstallationExecutable = Path.GetFullPath(args[at + 1]);
    }

    public static async Task<int> RunHelperAsync(string requestFile)
    {
        var updater = new DesktopUpdater();
        string? fallback = null;
        bool parentExited = false;
        Process? candidateChild = null;
        try
        {
            string request = UpdateFiles.Child(updater.cache, Path.GetRelativePath(updater.cache, requestFile));
            if (!Path.GetFileName(request).StartsWith(".request-", StringComparison.Ordinal)) return 1;
            using var doc = JsonDocument.Parse(UpdateFiles.ReadBounded(request, 8192));
            var value = doc.RootElement;
            if (Path.GetFullPath(value.GetProperty("installationRoot").GetString()!) != InstallationRoot) return 1;
            string key = value.GetProperty("key").GetString()!;
            var release = updater.Verify(key);
            string old = value.GetProperty("fallback").GetString()!;
            string baseExe = InstallationExecutable;
            string activeExe = baseExe;
            try { activeExe = updater.Verify(updater.ReadPointer("active.json")).Entry; } catch (Exception error) when (Recoverable(error)) { }
            if (!string.Equals(old, baseExe, StringComparison.OrdinalIgnoreCase) && !string.Equals(old, activeExe, StringComparison.OrdinalIgnoreCase)) return 1;
            fallback = old;
            try
            {
                using var parent = Process.GetProcessById(value.GetProperty("parentPid").GetInt32());
                if (parent.StartTime.ToUniversalTime().Ticks != value.GetProperty("parentStart").GetInt64()) return 1;
                await parent.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(30));
                parentExited = true;
            }
            catch (ArgumentException) { parentExited = true; }
            bool success = await updater.CompleteRestartAsync(key, async candidate =>
            {
                string receipt = UpdateFiles.Child(updater.cache, ".ready-" + Guid.NewGuid().ToString("N") + ".json");
                var child = candidateChild = Start(candidate.Entry, "--installation-root", InstallationRoot, "--installation-executable", InstallationExecutable,
                    "--skip-update", "--update-receipt", receipt);
                bool ready = false;
                try
                {
                    for (int wait = 0; wait < 150; wait++)
                    {
                        if (File.Exists(receipt))
                        {
                            using var response = JsonDocument.Parse(UpdateFiles.ReadBounded(receipt, 4096));
                            ready = !child.HasExited && response.RootElement.GetProperty("version").GetString() == candidate.Version &&
                                response.RootElement.GetProperty("pid").GetInt32() == child.Id;
                            break;
                        }
                        if (child.HasExited) break;
                        await Task.Delay(200);
                    }
                    return ready;
                }
                finally
                {
                    if (File.Exists(receipt)) File.Delete(receipt);
                    if (!ready && !child.HasExited) { child.Kill(true); await child.WaitForExitAsync(); }
                }
            }, () =>
            {
                StopCandidate(candidateChild);
                using var oldApp = Start(old, "--installation-root", InstallationRoot, "--installation-executable", InstallationExecutable, "--skip-update");
            });
            try { File.Delete(request); } catch (Exception error) when (Recoverable(error)) { }
            return success ? 0 : 1;
        }
        catch (Exception error) when (Recoverable(error) || error is TimeoutException)
        {
            StopCandidate(candidateChild);
            if (fallback is not null && parentExited)
                try { using var old = Start(fallback, "--installation-root", InstallationRoot, "--installation-executable", InstallationExecutable, "--skip-update"); } catch (Exception failure) when (Recoverable(failure)) { }
            return 1;
        }
        finally { candidateChild?.Dispose(); }
    }

    private static void StopCandidate(Process? child)
    {
        try { if (child is not null && !child.HasExited) { child.Kill(true); child.WaitForExit(5000); } }
        catch (Exception error) when (Recoverable(error)) { }
    }

    // The same transaction is exercised offline with a synthetic readiness
    // provider: a failed launch never advances the pointer or loses fallback.
    internal async Task<bool> CompleteRestartAsync(string key, Func<CachedRelease, Task<bool>> launch, Action rollback)
    {
        try
        {
            var candidate = Verify(key);
            if (!await launch(candidate)) throw new IOException("The updated app did not become ready.");
            Verify(key);
            UpdateFiles.AtomicJson(Path.Combine(cache, "active.json"), new { key });
            // A cleanup failure after committing must not roll back a ready app.
            try
            {
                string pending = Path.Combine(cache, "pending.json"); UpdateFiles.NoLinks(pending);
                if (File.Exists(pending) && ReadPointer("pending.json") == key) File.Delete(pending);
            }
            catch (Exception error) when (Recoverable(error)) { }
            return true;
        }
        catch (Exception error) when (Recoverable(error) || error is TimeoutException)
        {
            try
            {
                UpdateFiles.AtomicJson(Path.Combine(cache, "failed.json"), new { key });
                foreach (string name in new[] { "pending.json", "active.json" })
                    if (File.Exists(Path.Combine(cache, name)) && ReadPointer(name) == key) File.Delete(Path.Combine(cache, name));
            }
            catch (Exception cleanup) when (Recoverable(cleanup)) { }
            try { rollback(); } catch (Exception failure) when (Recoverable(failure)) { }
            return false;
        }
    }

    public static bool TryDispatch(string[] args)
    {
        if (args.Contains("--skip-update") || args.Any(argument => argument.StartsWith("--", StringComparison.Ordinal) && argument is not ("--installation-root" or "--installation-executable"))) return false;
        try
        {
            var updater = new DesktopUpdater();
            // A normal close may have left a staged release for the next launch.
            if (updater.ReadyToRestart) return updater.ApplyOnExit();
            string key = updater.ReadPointer("active.json");
            if (updater.Rejected(key)) return false;
            var release = updater.Verify(key);
            if (Version.Parse(release.Version) <= Version.Parse(CurrentVersion)) return false;
            updater.stagedKey = key;
            return updater.ApplyOnExit();
        }
        catch (Exception error) when (Recoverable(error)) { return false; }
    }

    public static void MarkReady(string[] args)
    {
        int at = Array.IndexOf(args, "--update-receipt");
        if (at < 0 || at + 1 >= args.Length) return;
        try
        {
            string cache = CacheFor(InstallationRoot);
            string receipt = UpdateFiles.Child(cache, Path.GetRelativePath(cache, args[at + 1]));
            if (!Path.GetFileName(receipt).StartsWith(".ready-", StringComparison.Ordinal)) return;
            UpdateFiles.AtomicJson(receipt, new { version = CurrentVersion, pid = Environment.ProcessId });
        }
        catch (Exception error) when (Recoverable(error)) { }
    }
}
