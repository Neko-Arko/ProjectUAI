using System.Diagnostics;
using System.Text.Json;

namespace ProjectUai.Bridge;

// Preferences are kept with the installation identity, so verified app updates
// retain them. This file contains no tokens, provider credentials, or chat data.
internal sealed record DesktopPreferences(bool OpenCodeEnabled = true, bool McpEnabled = true,
    bool OpenBrowser = true, bool AutomaticAppUpdates = true, bool StartOnLaunch = false, bool KiloEnabled = true, bool ClineEnabled = true)
{
    private static string FilePath => Path.Combine(DesktopUpdater.CacheFor(DesktopUpdater.InstallationRoot), "preferences.json");
    internal static DesktopPreferences Load(string? path = null)
    {
        try { return JsonSerializer.Deserialize<DesktopPreferences>(UpdateFiles.ReadBounded(path ?? FilePath, 4096)) ?? new(); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException) { return new(); }
    }
    internal void Save(string? path = null) => UpdateFiles.AtomicJson(path ?? FilePath, this);
    internal BridgeLaunchOptions BridgeOptions => new(OpenCodeEnabled, McpEnabled, KiloEnabled, ClineEnabled);
}

internal sealed record BridgeLaunchOptions(bool OpenCodeEnabled = true, bool McpEnabled = true, bool KiloEnabled = true, bool ClineEnabled = true)
{
    internal void Apply(ProcessStartInfo start)
    {
        start.Environment["UAI_OPENCODE_DISABLED"] = OpenCodeEnabled ? "0" : "1";
        start.Environment["UAI_MCP_DISABLED"] = McpEnabled ? "0" : "1";
        start.Environment["UAI_KILO_TUNNEL"] = KiloEnabled ? "1" : "0";
        start.Environment["UAI_CLINE_DISABLED"] = ClineEnabled ? "0" : "1";
    }
}
