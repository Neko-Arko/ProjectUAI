using System.Diagnostics;
using System.Text.Json;

namespace ProjectUai.Bridge;

// Real standalone startup admission with a private instance namespace. Preview
// children stay offscreen and do not start bridges, download updates or pair.
internal static class DesktopStartupTest
{
    internal static async Task<int> RunAsync(string output)
    {
        var checks = new List<string>();
        string root = Path.Combine(Path.GetTempPath(), "uai-desktop-startup-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        string id = Guid.NewGuid().ToString("N"), name = "ProjectUAI.Bridge.Test." + id;
        string executable = Environment.ProcessPath ?? throw new IOException("No startup test executable.");
        void Check(string text, bool condition) { if (!condition) throw new IOException(text); checks.Add(text); }
        async Task Launch(string image)
        {
            var info = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden };
            info.ArgumentList.Add("--render-preview"); info.ArgumentList.Add(image);
            info.Environment["UAI_DESKTOP_TEST_INSTANCE"] = id;
            using var child = Process.Start(info) ?? throw new IOException("Startup fixture did not launch.");
            try
            {
                await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(20));
                Check("Standalone startup exits cleanly", child.ExitCode == 0);
            }
            finally { if (!child.HasExited) { child.Kill(true); await child.WaitForExitAsync(); } }
        }
        try
        {
            string first = Path.Combine(root, "first.png");
            using (var stale = new Mutex(false, @"Local\" + name))
            {
                await Launch(first);
                Check("First launch opens with an existing unowned instance mutex", File.Exists(first));
            }
            string abandonedImage = Path.Combine(root, "abandoned.png");
            using (var abandoned = new Mutex(false, @"Local\" + name))
            {
                var crashedOwner = new Thread(() => abandoned.WaitOne());
                crashedOwner.Start(); crashedOwner.Join();
                await Launch(abandonedImage);
                Check("A window owner that exits without cleanup cannot block the next launch", File.Exists(abandonedImage));
            }
            string duplicate = Path.Combine(root, "duplicate.png");
            // Mutex ownership is thread-affine. The owner waits on a dedicated
            // thread while this async harness waits for an actual second process.
            using var acquired = new ManualResetEventSlim(); using var release = new ManualResetEventSlim();
            using var show = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\" + name + ".Show");
            var owner = new Thread(() =>
            {
                using var mutex = new Mutex(false, @"Local\" + name);
                mutex.WaitOne(); acquired.Set(); release.Wait(); mutex.ReleaseMutex();
            });
            owner.Start();
            try
            {
                Check("Live window fixture acquires instance ownership", acquired.Wait(TimeSpan.FromSeconds(5)));
                await Launch(duplicate);
                Check("A duplicate launch signals the live owner without opening another window", !File.Exists(duplicate) && show.WaitOne(0));
            }
            finally { release.Set(); owner.Join(); }
            string next = Path.Combine(root, "next.png");
            await Launch(next);
            Check("The next launch opens immediately after the old owner exits", File.Exists(next));
            await File.WriteAllTextAsync(output, JsonSerializer.Serialize(new { ok = true, checks }, new JsonSerializerOptions { WriteIndented = true }));
            return 0;
        }
        catch (Exception error)
        {
            await File.WriteAllTextAsync(output, JsonSerializer.Serialize(new { ok = false, checks, error = error.Message }, new JsonSerializerOptions { WriteIndented = true }));
            return 1;
        }
        finally { UpdateFiles.RemoveOwnedDirectory(Path.GetTempPath(), root); }
    }
}
