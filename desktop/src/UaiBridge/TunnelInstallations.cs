using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace ProjectUai.Bridge;

internal sealed record TunnelInstallations(bool? OpenCode, bool? Cline, string Detail)
{
    internal static TunnelInstallations Unknown(string detail) => new(null, null, detail);

    // Reuse the exact native-file detectors used by the bridge. Requiring these
    // modules never constructs an adapter, starts a CLI, or reads account files.
    private const string Discovery = """
        const path=require('node:path');
        const env={...process.env,UAI_OPENCODE_DISABLED:'0',UAI_CLINE_DISABLED:'0'};
        const root=process.argv[1];
        const opencode=!!require(path.join(root,'bridge','opencode.js')).findBinary(env);
        const cline=!!require(path.join(root,'bridge','cline.js')).findBinary(env);
        process.stdout.write(JSON.stringify({schema:1,opencode,cline}));
        """;

    internal static async Task<TunnelInstallations> FindAsync(NodeInstallation? node, CancellationToken cancellationToken,
        IReadOnlyDictionary<string, string>? environment = null)
    {
        if (node is null) return Unknown("Set up Node.js on Workspace to check installed apps.");
        string root = await Task.Run(EmbeddedPayload.Prepare, cancellationToken);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(8));
        using var process = new Process { StartInfo = new ProcessStartInfo(node.Path)
        {
            UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden,
            RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = root
        } };
        if (environment is not null)
        {
            process.StartInfo.Environment.Clear();
            foreach (var entry in environment) process.StartInfo.Environment[entry.Key] = entry.Value;
        }
        // Discovery must not execute user-provided Node preloads.
        process.StartInfo.Environment.Remove("NODE_OPTIONS");
        process.StartInfo.Environment.Remove("NODE_PATH");
        process.StartInfo.ArgumentList.Add("--eval");
        process.StartInfo.ArgumentList.Add(Discovery);
        process.StartInfo.ArgumentList.Add(root);
        try
        {
            if (!process.Start()) return Unknown("Could not check installed apps. Refresh to try again.");
            var output = ReadBoundedAsync(process.StandardOutput, timeout.Token);
            var errors = ReadBoundedAsync(process.StandardError, timeout.Token);
            await Task.WhenAll(output, errors, process.WaitForExitAsync(timeout.Token));
            string text = await output;
            if (process.ExitCode != 0) return Unknown("Could not check installed apps. Refresh to try again.");
            using var result = JsonDocument.Parse(text);
            if (result.RootElement.GetProperty("schema").GetInt32() != 1) throw new IOException("Unsupported discovery result.");
            return new(result.RootElement.GetProperty("opencode").GetBoolean(), result.RootElement.GetProperty("cline").GetBoolean(),
                "Install an app, then refresh. Sign-in and model access are checked when Cowork starts.");
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        { return Unknown("Checking installed apps took too long. Refresh to try again."); }
        catch (Exception error) when (error is IOException or System.ComponentModel.Win32Exception or JsonException or InvalidOperationException or KeyNotFoundException)
        { return Unknown("Could not check installed apps. Refresh to try again."); }
        finally
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
            catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception) { }
        }
    }

    private static async Task<string> ReadBoundedAsync(StreamReader reader, CancellationToken cancellationToken)
    {
        var output = new StringBuilder();
        var buffer = new char[1024];
        for (int count; (count = await reader.ReadAsync(buffer.AsMemory(), cancellationToken)) != 0;)
        {
            if (output.Length + count > 4096) throw new IOException("Discovery output exceeded its limit.");
            output.Append(buffer, 0, count);
        }
        return output.ToString();
    }
}
