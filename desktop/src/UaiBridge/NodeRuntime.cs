using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace ProjectUai.Bridge;

internal sealed record NodeInstallation(string Path, string Version, bool Managed);

internal static class NodeRuntime
{
    public const string DownloadPage = "https://nodejs.org/en/download";
    private static string Cache => System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ProjectUAI", "node");

    public static async Task<NodeInstallation?> FindAsync(CancellationToken cancellationToken = default,
        IEnumerable<string>? candidatePaths = null, string? managedCache = null)
    {
        var candidates = new List<string>();
        foreach (string directory in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(System.IO.Path.PathSeparator))
            if (!string.IsNullOrWhiteSpace(directory) && System.IO.Path.IsPathFullyQualified(directory.Trim('"')))
                candidates.Add(System.IO.Path.Combine(directory.Trim('"'), "node.exe"));
        foreach (string root in new[] { Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData) })
            if (!string.IsNullOrEmpty(root)) candidates.Add(System.IO.Path.Combine(root, "nodejs", "node.exe"));
        foreach (string file in (candidatePaths ?? candidates).Distinct(StringComparer.OrdinalIgnoreCase))
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (await ProbeAsync(file, cancellationToken) is { } found) return found;
        }
        try
        {
            string runtimeCache = managedCache ?? Cache;
            string pointer = System.IO.Path.Combine(runtimeCache, "active.json");
            UpdateFiles.NoLinks(pointer);
            using var metadata = JsonDocument.Parse(UpdateFiles.ReadBounded(pointer, 4096));
            string version = metadata.RootElement.GetProperty("version").GetString()!;
            if (!UpdateFiles.StableVersion(version, out var parsed) || parsed.Major < 18) return null;
            string file = UpdateFiles.Child(runtimeCache, version + "/node.exe");
            UpdateFiles.VerifyFile(file, metadata.RootElement.GetProperty("bytes").GetInt64(), metadata.RootElement.GetProperty("sha256").GetString()!);
            var result = await ProbeAsync(file, cancellationToken);
            return result?.Version == version ? result with { Managed = true } : null;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or ArgumentException or KeyNotFoundException or InvalidOperationException or FormatException) { return null; }
    }

    internal static async Task<NodeInstallation?> ProbeAsync(string file, CancellationToken cancellationToken)
    {
        if (!File.Exists(file)) return null;
        using var process = new Process { StartInfo = new ProcessStartInfo(file) {
            UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden,
            RedirectStandardOutput = true, RedirectStandardError = true } };
        process.StartInfo.ArgumentList.Add("--version");
        // A user NODE_OPTIONS preload should not execute while detecting the runtime.
        process.StartInfo.Environment.Remove("NODE_OPTIONS");
        try
        {
            if (!process.Start()) return null;
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(4));
            var output = process.StandardOutput.ReadLineAsync(timeout.Token).AsTask();
            var errors = process.StandardError.ReadToEndAsync(timeout.Token);
            await process.WaitForExitAsync(timeout.Token);
            string text = (await output ?? "").Trim();
            await errors;
            return process.ExitCode == 0 && text.StartsWith('v') && UpdateFiles.StableVersion(text[1..], out var version) && version.Major >= 18
                ? new NodeInstallation(System.IO.Path.GetFullPath(file), text[1..], false) : null;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) { return null; }
        catch (Exception error) when (error is IOException or System.ComponentModel.Win32Exception or InvalidOperationException) { return null; }
        finally
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
        }
    }

    public static async Task<NodeInstallation> InstallAsync(IProgress<string>? progress = null, CancellationToken cancellationToken = default)
    {
        progress?.Report("Finding the current Node.js LTS release...");
        byte[] index = await UpdateFiles.DownloadAsync(new Uri("https://nodejs.org/dist/index.json"), 4 << 20, true, cancellationToken);
        using var versions = JsonDocument.Parse(index);
        var latest = versions.RootElement.EnumerateArray().Where(item => item.GetProperty("lts").ValueKind == JsonValueKind.String)
            .Select(item => item.GetProperty("version").GetString()).Where(value => value is not null && value.StartsWith('v') &&
                UpdateFiles.StableVersion(value[1..], out var parsed) && parsed.Major >= 18)
            .OrderByDescending(value => Version.Parse(value![1..])).FirstOrDefault() ?? throw new IOException("No compatible Node.js LTS release was found.");
        string version = latest[1..];
        byte[] sums = await UpdateFiles.DownloadAsync(new Uri($"https://nodejs.org/dist/{latest}/SHASUMS256.txt"), 1 << 20, true, cancellationToken);
        string hash = ParseChecksum(Encoding.UTF8.GetString(sums), "win-x64/node.exe");
        progress?.Report($"Downloading Node.js {version} for your account...");
        byte[] binary = await UpdateFiles.DownloadAsync(new Uri($"https://nodejs.org/dist/{latest}/win-x64/node.exe"), 150 << 20, true, cancellationToken);
        if (UpdateFiles.Hash(binary) != hash) throw new IOException("The Node.js download failed SHA-256 verification. Try again.");
        UpdateFiles.NoLinks(Cache); Directory.CreateDirectory(Cache);
        string stage = UpdateFiles.Child(Cache, ".stage-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(stage);
        try
        {
            string executable = System.IO.Path.Combine(stage, "node.exe");
            await File.WriteAllBytesAsync(executable, binary, cancellationToken);
            if (await ProbeAsync(executable, cancellationToken) is not { } installed || installed.Version != version)
                throw new IOException("The downloaded Node.js runtime could not start on this computer.");
            string destination = UpdateFiles.Child(Cache, version);
            UpdateFiles.NoLinks(destination);
            if (Directory.Exists(destination))
            {
                // Never replace a runtime which another app instance may be using.
                UpdateFiles.VerifyFile(System.IO.Path.Combine(destination, "node.exe"), binary.Length, hash);
            }
            else Directory.Move(stage, destination);
            UpdateFiles.AtomicJson(System.IO.Path.Combine(Cache, "active.json"), new { version, bytes = binary.Length, sha256 = hash });
            progress?.Report($"Node.js {version} is ready.");
            return new NodeInstallation(System.IO.Path.Combine(destination, "node.exe"), version, true);
        }
        finally { UpdateFiles.RemoveOwnedDirectory(Cache, stage); }
    }

    internal static string ParseChecksum(string text, string filename)
    {
        var matches = text.Split('\n').Select(line => Regex.Match(line.TrimEnd('\r'), @"\A([a-f0-9]{64})\s+\*?(.+)\z"))
            .Where(match => match.Success && match.Groups[2].Value == filename).ToArray();
        return matches.Length == 1 ? matches[0].Groups[1].Value : throw new IOException("The official Node.js checksum list is invalid.");
    }
}

// Shared bounded download and cache operations. Every write remains beneath an
// explicit private cache; package paths never become shell command text.
internal static class UpdateFiles
{
    internal static string Hash(byte[] bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));
    internal static bool StableVersion(string? value, out Version version)
    {
        version = new Version(0, 0, 0);
        return value is not null && Regex.IsMatch(value, @"\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\z") && Version.TryParse(value, out version!);
    }
    internal static string Child(string root, string relative)
    {
        string fullRoot = System.IO.Path.GetFullPath(root).TrimEnd(System.IO.Path.DirectorySeparatorChar) + System.IO.Path.DirectorySeparatorChar;
        string full = System.IO.Path.GetFullPath(System.IO.Path.Combine(root, relative));
        if (!full.StartsWith(fullRoot, StringComparison.OrdinalIgnoreCase)) throw new IOException("Update path escaped its cache.");
        return full;
    }
    internal static void NoLinks(string path)
    {
        for (string? current = System.IO.Path.GetFullPath(path); current is not null; current = System.IO.Path.GetDirectoryName(current))
        {
            try
            {
                if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                    throw new IOException("Updates cannot use symbolic links or directory junctions.");
            }
            catch (FileNotFoundException) { }
            catch (DirectoryNotFoundException) { }
        }
    }
    internal static byte[] ReadBounded(string file, long limit)
    {
        NoLinks(file);
        if (new FileInfo(file).Length > limit) throw new IOException("Update metadata is too large.");
        return File.ReadAllBytes(file);
    }
    internal static void VerifyFile(string file, long bytes, string hash)
    {
        NoLinks(file);
        if (bytes < 0 || bytes > 300L << 20 || !Regex.IsMatch(hash, @"\A[a-f0-9]{64}\z") || new FileInfo(file).Length != bytes)
            throw new IOException("Update file size is invalid.");
        using var input = File.OpenRead(file);
        if (Convert.ToHexStringLower(SHA256.HashData(input)) != hash) throw new IOException("Update file SHA-256 verification failed.");
    }
    internal static void AtomicJson(string file, object value)
    {
        NoLinks(file); Directory.CreateDirectory(System.IO.Path.GetDirectoryName(file)!);
        string temp = file + "." + Guid.NewGuid().ToString("N");
        try { File.WriteAllText(temp, JsonSerializer.Serialize(value)); File.Move(temp, file, true); }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
    internal static void RemoveOwnedDirectory(string root, string target)
    {
        string checkedTarget = Child(root, System.IO.Path.GetRelativePath(root, target));
        NoLinks(checkedTarget);
        if (Directory.Exists(checkedTarget)) Directory.Delete(checkedTarget, true);
    }
    internal static async Task<byte[]> DownloadAsync(Uri uri, int limit, bool node, CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromMinutes(4));
        using var client = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false });
        client.Timeout = Timeout.InfiniteTimeSpan;
        for (int redirect = 0; redirect <= 4; redirect++)
        {
            string[] hosts = node ? ["nodejs.org"] : ["api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"];
            if (uri.Scheme != "https" || !uri.IsDefaultPort || uri.UserInfo.Length != 0 || uri.Fragment.Length != 0 || !hosts.Contains(uri.Host))
                throw new IOException("Untrusted update download address.");
            using var request = new HttpRequestMessage(HttpMethod.Get, uri);
            request.Headers.UserAgent.ParseAdd("ProjectUAI-Desktop/" + DesktopUpdater.CurrentVersion);
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
            if ((int)response.StatusCode is 301 or 302 or 303 or 307 or 308)
            {
                uri = response.Headers.Location is { } location ? new Uri(uri, location) : throw new IOException("Invalid update redirect.");
                continue;
            }
            response.EnsureSuccessStatusCode();
            if (response.Content.Headers.ContentLength > limit) throw new IOException("Update download is too large.");
            await using var source = await response.Content.ReadAsStreamAsync(timeout.Token);
            using var output = new MemoryStream();
            byte[] buffer = new byte[65536];
            for (int count; (count = await source.ReadAsync(buffer, timeout.Token)) != 0;)
            {
                if (output.Length + count > limit) throw new IOException("Update download is too large.");
                output.Write(buffer, 0, count);
            }
            return output.ToArray();
        }
        throw new IOException("Too many update redirects.");
    }
}
