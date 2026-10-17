using System.Diagnostics;

namespace ProjectUai.Bridge;

// A stable stdio command for harnesses: the single desktop EXE owns its adapter,
// while the running desktop bridge continues to own the Roblox connection.
internal static class McpHost
{
    internal static async Task<int> RunAsync(string[] args)
    {
        try
        {
            string root = await Task.Run(EmbeddedPayload.Prepare);
            var runtime = await NodeRuntime.FindAsync()
                ?? throw new IOException("Open UAI Bridge and set up Node.js before connecting your MCP client.");
            using var process = new Process { StartInfo = new ProcessStartInfo(runtime.Path)
            {
                WorkingDirectory = root, UseShellExecute = false, CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden, RedirectStandardInput = true,
                RedirectStandardOutput = true, RedirectStandardError = true
            } };
            process.StartInfo.ArgumentList.Add(Path.Combine(root, "bridge", "server.js"));
            process.StartInfo.ArgumentList.Add("--mcp-stdio");
            foreach (string arg in args) process.StartInfo.ArgumentList.Add(arg);
            process.StartInfo.Environment.Remove("NODE_OPTIONS");
            if (!process.Start()) throw new IOException("Could not start the MCP adapter.");
            try
            {
                using var job = new ChildJob(process);
                Task output = process.StandardOutput.BaseStream.CopyToAsync(Console.OpenStandardOutput());
                Task errors = process.StandardError.BaseStream.CopyToAsync(Console.OpenStandardError());
                // Input can remain parked when the bridge exits. Do not wait on the
                // host's next input after the owned adapter has already terminated.
                _ = ForwardInputAsync(process);
                await process.WaitForExitAsync();
                await Task.WhenAll(output, errors);
                return process.ExitCode;
            }
            finally
            {
                if (!process.HasExited) process.Kill(entireProcessTree: true);
            }
        }
        catch (Exception error)
        {
            await Console.Error.WriteLineAsync("UAI MCP: " + error.Message);
            return 1;
        }
    }

    private static async Task ForwardInputAsync(Process process)
    {
        try { await Console.OpenStandardInput().CopyToAsync(process.StandardInput.BaseStream); }
        catch (Exception error) when (error is IOException or ObjectDisposedException or InvalidOperationException) { }
        finally
        {
            try { process.StandardInput.Close(); }
            catch (Exception error) when (error is IOException or ObjectDisposedException or InvalidOperationException) { }
        }
    }
}
