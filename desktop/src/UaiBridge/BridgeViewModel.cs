using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Input;
using System.Windows.Threading;

namespace ProjectUai.Bridge;

// The window declares presentation. This model owns application operations and
// preferences; BridgeProcess and DesktopUpdater retain their process/cache logic.
internal sealed class BridgeViewModel : INotifyPropertyChanged, IDisposable
{
    private readonly BridgeProcess bridge;
    private readonly DesktopUpdater updater;
    private readonly Dispatcher dispatcher;
    private readonly bool offline;
    private readonly CancellationTokenSource lifetime = new();
    private readonly DispatcherTimer timer;
    private readonly List<AsyncDesktopCommand> asyncCommands = [];
    private readonly List<DesktopCommand> commands = [];
    private DesktopPreferences preferences;
    private NodeInstallation? runtime;
    private TunnelInstallations tunnelInstallations = TunnelInstallations.Unknown("Checking installed apps.");
    private Task? initialization;
    private DateTime nextUpdateCheck = DateTime.MinValue;
    private bool busy, installing, detecting, checkingInstallations, checkingUpdates, refreshing, checkingBridge, exiting, disposed, compact;
    private int selectedPage;
    private string nodeState = "Checking Node.js", nodeDetail = "Looking for a compatible runtime on your computer.", notice = "";

    internal BridgeViewModel(BridgeProcess bridge, DesktopUpdater updater, bool offline, Dispatcher dispatcher,
        Func<bool, Task> requestClose)
    {
        this.bridge = bridge; this.updater = updater; this.offline = offline; this.dispatcher = dispatcher;
        preferences = offline ? new() : DesktopPreferences.Load();
        StartCommand = Async(() => IsRunning ? OpenCoworkAsync() : StartAsync(), () => CanStart);
        StopCommand = Async(StopAsync, () => CanStop);
        InstallNodeCommand = Async(InstallNodeAsync, () => CanInstall);
        RecheckNodeCommand = Async(FindNodeAsync, () => CanRecheck);
        RefreshInstallationsCommand = Async(RefreshTunnelInstallationsAsync, () => CanRefreshInstallations);
        UpdateCommand = Async(() => IsUpdateReady ? requestClose(true) : CheckUpdatesAsync(true), () => CanUpdate);
        CheckBridgeCommand = Async(CheckBridgeUpdatesAsync, () => CanCheckBridge);
        CopyClientCommand = Async(CopyClientAsync, () => !IsExiting);
        McpSetupCommand = Command(_ => OpenExternal(bridge.BrowserUrl + "&panel=mcp"), () => IsRunning && bridge.McpEnabled && !IsExiting);
        OpenCodeWebsiteCommand = Command(_ => OpenExternal("https://opencode.ai"));
        ClineWebsiteCommand = Command(_ => OpenExternal("https://docs.cline.bot/cline-cli/overview"));
        CopyClineSignInCommand = Async(() => { Clipboard.SetText(ClineSignInText); SetNotice("Cline sign-in command copied. Run it in PowerShell, then restart the bridge."); return Task.CompletedTask; }, () => !IsExiting);
        NodeWebsiteCommand = Command(_ => OpenExternal(NodeRuntime.DownloadPage));
        HelpCommand = Command(_ => OpenExternal(BridgeProcess.Discord));
        ProjectCommand = Command(_ => OpenExternal("https://github.com/Project-Ptolemy/ProjectUAI"));
        DismissNoticeCommand = Command(_ => SetNotice(""));
        NavigateCommand = Command(value => { if (int.TryParse(value?.ToString(), out int page) && page is >= 0 and <= 4) SelectedPage = page; });
        timer = new DispatcherTimer(TimeSpan.FromMilliseconds(1500), DispatcherPriority.Background, OnTick, dispatcher);
        timer.Stop();
        bridge.Changed += OnChanged; updater.Changed += OnChanged;
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    public string Version => DesktopUpdater.CurrentVersion;
    public int SelectedPage { get => selectedPage; set { if (value is < 0 or > 4 || selectedPage == value) return; selectedPage = value; PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(SelectedPage))); Refresh(); } }
    public bool IsCompact { get => compact; set { if (compact == value) return; compact = value; Refresh(); } }
    public bool IsRunning => bridge.BrowserUrl is not null;
    public bool IsConnected => bridge.State == "Connected to Roblox";
    public bool IsBusy => busy || exiting;
    public bool IsInstalling => installing;
    public bool IsDetecting => detecting;
    public bool IsCheckingUpdates => checkingUpdates;
    public bool IsExiting => exiting;
    public bool IsUpdateReady => updater.ReadyToRestart;
    public bool HasNotice => notice.Length > 0;
    public string Notice => notice;
    public string State => exiting ? "Closing your workspace" : bridge.State == "Stopped" ? "Ready when you are." : bridge.State;
    public string Detail => exiting ? "Stopping the bridge and its owned processes." : bridge.State == "Stopped"
        ? "Start your bridge, then load UAI in Roblox. Your Cowork workspace opens in your browser." : bridge.Detail;
    public string ActivityLabel => IsConnected ? "Roblox connected" : IsRunning ? "Bridge running" : IsBusy ? "Working" : "Bridge stopped";
    public string NodeState => nodeState;
    public string NodeDetail => nodeDetail;
    public string StartLabel => busy ? "Please wait..." : IsRunning ? "Open Cowork" : "Start Cowork";
    public string InstallLabel => installing ? "Downloading Node.js..." : runtime is not null ? "Node.js ready" : "Get Node.js";
    public string UpdateActionLabel => checkingUpdates ? "Checking for updates..." : IsUpdateReady
        ? IsRunning ? "Stop bridge to update" : "Restart to update app" : "Check for updates";
    public string AvailableVersion => updater.AvailableVersion ?? "No update staged";
    public string UpdateStatus => IsUpdateReady ? "Ready to restart" : checkingUpdates ? "Checking" : updater.State == "Unavailable"
        ? "Check failed" : AutomaticAppUpdates ? "Automatic updates on" : "Manual updates";
    public string AppUpdateDetail => !AutomaticAppUpdates && !IsUpdateReady && !checkingUpdates && updater.State != "Unavailable"
        ? "Automatic app downloads are paused. You can check for updates at any time." : updater.Detail;
    public string BridgeUpdateDetail => !IsRunning ? "The bridge checks for updates while it is running." : bridge.UpdateState switch
    {
        "staged" => $"Bridge {bridge.AvailableVersion} is verified and will apply when active work finishes.",
        "checking" => "The bridge is checking for updates.",
        "restarting" => "The bridge is applying its update. Your browser will reconnect.",
        "error" => $"Bridge {bridge.BridgeVersion} is running. Its update check will retry.",
        _ => $"Bridge {bridge.BridgeVersion} is running with automatic updates."
    };
    public string BridgeVersionLine => IsRunning ? $"Bridge {bridge.BridgeVersion} · Web UI {bridge.BridgeVersion}" : "";
    public bool CanCheckBridge => IsRunning && !IsBusy && !checkingBridge;
    public string CheckBridgeLabel => checkingBridge ? "Checking bridge..." : "Check for bridge updates";
    public string OpenCodeDetail => !OpenCodeEnabled && !IsRunning ? "Enable to use your installed OpenCode CLI." : bridge.OpenCodeDetail;
    public string OpenCodeStatus => !OpenCodeEnabled ? "Off" : !IsRunning ? "On next start" : bridge.OpenCodeState switch
        { "ready" => "Ready", "starting" => "Starting", "missing" => "Setup needed", "failed" => "Needs attention", "disabled" => "Off", _ => "Waiting" };
    public string ClineStatus => !ClineEnabled ? "Off" : !IsRunning ? "On next start" : bridge.ClineState switch
        { "ready" => "Ready", "auth-required" => "Sign in needed", "starting" => "Starting", "missing" => "Install Cline", "failed" => "Needs attention", "disabled" => "Off", _ => "Waiting" };
    public string ClineDetail => !IsRunning ? "Uses your UAI Cline profile when present, otherwise your existing Cline sign-in." : bridge.ClineDetail;
    public string ClineSignInText => "cline auth cline";
    public string OpenCodeInstallation => InstallationLabel(tunnelInstallations.OpenCode);
    public string ClineInstallation => InstallationLabel(tunnelInstallations.Cline);
    public string InstallationDetail => checkingInstallations ? "Looking for installed OpenCode and Cline apps." : tunnelInstallations.Detail;
    public string RefreshInstallationsLabel => checkingInstallations ? "Checking installed apps..." : "Refresh installed apps";
    public bool CanRefreshInstallations => !checkingInstallations && !detecting && !installing && !exiting;
    private string InstallationLabel(bool? installed) => checkingInstallations ? "Checking installation" : installed switch
        { true => "Installed", false => "Not found", _ => "Not checked" };
    public string McpStatus => (IsRunning ? bridge.McpEnabled : McpEnabled) ? IsRunning ? "Enabled" : "On next start" : "Off";
    public string KiloStatus => !KiloEnabled ? "Off" : !IsRunning ? "On next start" : bridge.KiloState switch
        { "standby" => "Ready when needed", "ready" => "Ready", "limited" => "Quota reached", "rotating" => "Changing connection", "starting" => "Connecting", "downloading" => "Downloading helper", "failed" => "Needs attention", _ => "Waiting" };
    public string KiloDetail => !IsRunning ? "Uses a private Tor connection for anonymous Kilo free requests after a quota response. Each outbound address still has an hourly allowance." : bridge.KiloDetail;
    public string McpDetail => (IsRunning ? bridge.McpEnabled : McpEnabled)
        ? "Connect a coding agent to UAI tools in Roblox. Game permissions stay in your control."
        : "External agents cannot connect through MCP.";
    public string SettingsNote => IsRunning ? "Stop the bridge to change connections or tunnels." : "Connections and tunnels apply when you next start the bridge.";
    public bool CanStart => !IsBusy && !installing && !detecting && (runtime is not null || IsRunning);
    public bool CanStop => IsRunning && !IsBusy;
    public bool CanInstall => !installing && !detecting && !IsBusy && runtime is null;
    public bool CanRecheck => !installing && !detecting && !IsBusy;
    public bool CanUpdate => !IsBusy && !installing && !detecting && !checkingUpdates && (!IsUpdateReady || !IsRunning);
    public bool CanConfigureConnections => !IsRunning && !IsBusy;
    public bool CanConfigureSettings => !IsExiting;
    public bool OpenCodeEnabled { get => preferences.OpenCodeEnabled; set { if (CanConfigureConnections) Save(preferences with { OpenCodeEnabled = value }); } }
    public bool McpEnabled { get => preferences.McpEnabled; set { if (CanConfigureConnections) Save(preferences with { McpEnabled = value }); } }
    public bool KiloEnabled { get => preferences.KiloEnabled; set { if (CanConfigureConnections) Save(preferences with { KiloEnabled = value }); } }
    public bool ClineEnabled { get => preferences.ClineEnabled; set { if (CanConfigureConnections) Save(preferences with { ClineEnabled = value }); } }
    public bool OpenBrowserOnStart { get => preferences.OpenBrowser; set { if (CanConfigureSettings) Save(preferences with { OpenBrowser = value }); } }
    public bool AutomaticAppUpdates { get => preferences.AutomaticAppUpdates; set { if (CanConfigureSettings) Save(preferences with { AutomaticAppUpdates = value }); } }
    public bool StartOnLaunch { get => preferences.StartOnLaunch; set { if (CanConfigureSettings) Save(preferences with { StartOnLaunch = value }); } }
    public ICommand StartCommand { get; }
    public ICommand StopCommand { get; }
    public ICommand InstallNodeCommand { get; }
    public ICommand RecheckNodeCommand { get; }
    public ICommand RefreshInstallationsCommand { get; }
    public ICommand UpdateCommand { get; }
    public ICommand CheckBridgeCommand { get; }
    public ICommand CopyClientCommand { get; }
    public ICommand McpSetupCommand { get; }
    public ICommand OpenCodeWebsiteCommand { get; }
    public ICommand ClineWebsiteCommand { get; }
    public ICommand CopyClineSignInCommand { get; }
    public ICommand NodeWebsiteCommand { get; }
    public ICommand HelpCommand { get; }
    public ICommand ProjectCommand { get; }
    public ICommand NavigateCommand { get; }
    public ICommand DismissNoticeCommand { get; }

    private AsyncDesktopCommand Async(Func<Task> action, Func<bool> canExecute)
    {
        var command = new AsyncDesktopCommand(action, canExecute, _ => SetNotice("The action could not finish. Please try again."));
        asyncCommands.Add(command); return command;
    }
    private DesktopCommand Command(Action<object?> action, Func<bool>? canExecute = null)
    {
        var command = new DesktopCommand(action, canExecute); commands.Add(command); return command;
    }
    private void Save(DesktopPreferences next)
    {
        if (preferences == next) return;
        bool updatesEnabled = !preferences.AutomaticAppUpdates && next.AutomaticAppUpdates;
        preferences = next;
        if (!offline)
        {
            try { preferences.Save(); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            { SetNotice("Your settings apply now, but could not be saved for the next launch."); }
        }
        if (updatesEnabled) nextUpdateCheck = DateTime.MinValue;
        Refresh();
    }
    internal void SetNotice(string message) { if (disposed) return; notice = message; Refresh(); }
    private void OnChanged()
    {
        if (disposed || dispatcher.HasShutdownStarted) return;
        if (dispatcher.CheckAccess()) Refresh();
        else dispatcher.BeginInvoke(DispatcherPriority.DataBind, new Action(Refresh));
    }
    private void Refresh()
    {
        if (disposed) return;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));
        foreach (var command in asyncCommands) command.Refresh();
        foreach (var command in commands) command.Refresh();
    }
    public Task InitializeAsync() => initialization ??= InitializeCoreAsync();
    private async Task InitializeCoreAsync()
    {
        await FindNodeAsync();
        if (disposed || exiting) return;
        if (offline) return;
        timer.Start();
        if (StartOnLaunch && runtime is not null) await StartAsync();
        await CheckUpdatesAsync();
    }
    private async void OnTick(object? sender, EventArgs args)
    {
        if (refreshing || busy || disposed || exiting) return;
        refreshing = true;
        try
        {
            await bridge.RefreshAsync();
            if (!exiting && DateTime.UtcNow >= nextUpdateCheck) await CheckUpdatesAsync();
        }
        catch (Exception) { SetNotice("Connection status could not refresh. Try stopping and starting the bridge."); }
        finally { refreshing = false; }
    }
    private async Task FindNodeAsync()
    {
        if (installing || detecting || exiting) return;
        detecting = true; nodeState = "Checking Node.js"; Refresh();
        try
        {
            runtime = await NodeRuntime.FindAsync(lifetime.Token);
            if (exiting) return;
            nodeState = runtime is null ? "Set up Node.js" : "Node.js " + runtime.Version;
            nodeDetail = runtime is null ? "Get a verified runtime for your account. No administrator access needed."
                : runtime.Managed ? "Verified runtime installed for Cowork." : "Using the runtime installed on your computer.";
        }
        catch (OperationCanceledException) { }
        catch (Exception) { nodeState = "Could not check Node.js"; nodeDetail = "Check again, or install Node.js from its official website."; }
        finally { detecting = false; Refresh(); }
        if (!exiting && !disposed) await RefreshTunnelInstallationsAsync();
    }
    internal async Task RefreshTunnelInstallationsAsync()
    {
        if (!CanRefreshInstallations) return;
        checkingInstallations = true; Refresh();
        try
        {
            var found = await TunnelInstallations.FindAsync(runtime, lifetime.Token);
            if (!exiting && !disposed) tunnelInstallations = found;
        }
        catch (OperationCanceledException) { }
        catch (Exception) { tunnelInstallations = TunnelInstallations.Unknown("Could not check installed apps. Refresh to try again."); }
        finally { checkingInstallations = false; Refresh(); }
    }
    private async Task InstallNodeAsync()
    {
        if (!CanInstall || offline) return;
        installing = true; nodeState = "Setting up Node.js"; Refresh();
        try
        {
            runtime = await NodeRuntime.InstallAsync(new Progress<string>(message => { if (!exiting && !disposed) { nodeDetail = message; Refresh(); } }), lifetime.Token);
            if (!exiting) { nodeState = "Node.js " + runtime.Version; nodeDetail = "Installed for Cowork. You are ready to start."; }
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { nodeState = "Download did not finish"; nodeDetail = error.Message; }
        finally { installing = false; Refresh(); }
        if (!exiting && !disposed) await RefreshTunnelInstallationsAsync();
    }
    internal async Task CheckUpdatesAsync(bool manual = false)
    {
        if (checkingUpdates || offline || exiting || (!manual && !AutomaticAppUpdates)) return;
        checkingUpdates = true; nextUpdateCheck = DateTime.UtcNow.AddMinutes(15); Refresh();
        try { await updater.CheckAsync(lifetime.Token, retryFailed: manual); }
        catch (OperationCanceledException) { }
        catch (Exception) { SetNotice("The update check could not finish. Your current app is still usable."); }
        finally { checkingUpdates = false; Refresh(); }
    }
    private async Task CheckBridgeUpdatesAsync()
    {
        if (!CanCheckBridge) return;
        checkingBridge = true; Refresh();
        try { await bridge.CheckUpdatesAsync(); }
        catch (IOException) { SetNotice("The bridge update check could not finish. It will retry automatically."); }
        finally { checkingBridge = false; Refresh(); }
    }
    public async Task StartAsync()
    {
        if (!CanStart) return;
        busy = true; SetNotice(""); Refresh();
        try
        {
            await bridge.StartAsync(preferences.BridgeOptions, lifetime.Token);
            if (!exiting && !offline && preferences.OpenBrowser) OpenExternal(bridge.BrowserUrl!);
        }
        catch (OperationCanceledException) { }
        catch (IOException) { /* BridgeProcess supplies the actionable status. */ }
        finally { busy = false; Refresh(); }
    }
    public async Task StopAsync()
    {
        if (!CanStop) return;
        busy = true; Refresh();
        try { await bridge.StopAsync(); }
        catch (Exception) { SetNotice("Could not stop the bridge. Close the app to release its owned processes."); }
        finally { busy = false; Refresh(); }
    }
    private Task OpenCoworkAsync() { if (bridge.BrowserUrl is { } url) OpenExternal(url); return Task.CompletedTask; }
    private async Task CopyClientAsync()
    {
        try
        {
            string root = await Task.Run(EmbeddedPayload.Prepare, lifetime.Token);
            string script = await File.ReadAllTextAsync(Path.Combine(root, "client", "uai.lua"), lifetime.Token);
            if (exiting || disposed) return;
            Clipboard.SetText(script); SetNotice("Client script copied. Paste it into your Roblox executor.");
        }
        catch (OperationCanceledException) { }
        catch (Exception) { SetNotice("The script could not be copied. Try again, or use the published UAI loader."); }
    }
    private void OpenExternal(string url)
    {
        if (offline || exiting || disposed) return;
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
        catch (Exception error) when (error is Win32Exception or InvalidOperationException)
        { SetNotice("Windows could not open the link. Set a default browser and try again."); }
    }
    internal async Task<bool> PrepareCloseAsync(bool applyUpdate)
    {
        if (exiting || (applyUpdate && (!CanUpdate || !IsUpdateReady))) return false;
        exiting = true; timer.Stop(); if (!applyUpdate) lifetime.Cancel(); Refresh();
        try { await bridge.StopAsync(); }
        catch (Exception)
        {
            if (applyUpdate)
            {
                exiting = false;
                if (!offline) timer.Start();
                SetNotice("The bridge could not stop cleanly. Close and reopen the app to update.");
                return false;
            }
            // Program disposes the controller once the ordinary close settles.
        }
        if (applyUpdate && !await updater.ApplyOnExitAsync())
        {
            exiting = false;
            if (!offline) timer.Start();
            SetNotice("The update could not start. Your staged update is retained; try restarting again.");
            return false;
        }
        lifetime.Cancel();
        return true;
    }
    public void Dispose()
    {
        if (disposed) return;
        disposed = true; lifetime.Cancel(); timer.Stop(); timer.Tick -= OnTick;
        bridge.Changed -= OnChanged; updater.Changed -= OnChanged; lifetime.Dispose();
    }
}
