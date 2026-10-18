using System.Diagnostics;

namespace ProjectUai.Bridge;

internal sealed class MainForm : Form
{
    private readonly BridgeProcess bridge;
    private readonly DesktopUpdater updater;
    private readonly CancellationTokenSource lifetime = new();
    private readonly Label state = new(), detail = new(), nodeState = new(), nodeDetail = new(), bridgeUpdate = new(), appUpdate = new(), openCodeDetail = new(), mcpDetail = new(), settingsNote = new();
    private readonly ActionButton start = new(), stop = new(), install = new(), recheck = new(), restart = new();
    private readonly ToggleSwitch openCode = new(), mcp = new(), openBrowser = new(), automaticUpdates = new(), startOnLaunch = new();
    private readonly StatusPill openCodeStatus = new(), mcpStatus = new();
    private readonly ConnectionStrip connection = new();
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 1500 };
    private DesktopPreferences preferences;
    private NodeInstallation? runtime;
    private bool busy, refreshing, installing, detecting, allowClose, preview, checkingUpdates, exiting;
    private DateTime nextUpdateCheck = DateTime.MinValue;

    public MainForm(BridgeProcess bridge, bool offline = false, DesktopUpdater? updates = null)
    {
        this.bridge = bridge; updater = updates ?? new(); preview = offline;
        preferences = offline ? new() : DesktopPreferences.Load();
        Text = "Cowork - Desktop bridge";
        Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!) ?? SystemIcons.Application;
        ShowIcon = false; ShowInTaskbar = true;
        BackColor = Palette.Canvas; ForeColor = Palette.Ink;
        Font = new Font("Segoe UI", 10); AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(980, 830); MinimumSize = new Size(870, 600);
        StartPosition = FormStartPosition.CenterScreen;

        var scroll = new Panel { Dock = DockStyle.Fill, AutoScroll = true, BackColor = Palette.Canvas };
        var layout = Column(Palette.Canvas, 28); layout.Dock = DockStyle.Top; layout.Height = 830;
        layout.RowCount = 5;
        foreach (int height in new[] { 44, 80, 202, 400, 48 }) layout.RowStyles.Add(new RowStyle(SizeType.Absolute, height));
        scroll.Controls.Add(layout); Controls.Add(scroll);
        var masthead = Grid(Palette.Canvas, 2); masthead.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); masthead.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 210));
        masthead.Controls.Add(TextLabel("cowork", 19, FontStyle.Bold, Palette.Ink), 0, 0);
        var edition = TextLabel($"PROJECT UAI   /   {DesktopUpdater.CurrentVersion}", 8.5f, FontStyle.Bold, Palette.Muted);
        edition.TextAlign = ContentAlignment.TopRight; edition.Padding = new Padding(0, 10, 0, 0);
        masthead.Controls.Add(edition, 1, 0); layout.Controls.Add(masthead, 0, 0);

        var intro = Column(Palette.Canvas);
        intro.RowStyles.Add(new RowStyle(SizeType.Absolute, 43)); intro.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        intro.Controls.Add(TextLabel("Your workspace, connected.", 26, FontStyle.Bold, Palette.Ink), 0, 0);
        intro.Controls.Add(TextLabel("A little bridge. A bigger place to build.", 10.5f, FontStyle.Regular, Palette.Muted), 0, 1);
        layout.Controls.Add(intro, 0, 1);

        var card = new SurfacePanel { Dock = DockStyle.Fill, Fill = Palette.Dark, Border = Palette.Dark, Padding = new Padding(25, 22, 25, 20), Margin = new Padding(0, 0, 0, 18) };
        var cardContent = Grid(Palette.Dark, 2); cardContent.RowCount = 2;
        cardContent.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 63)); cardContent.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 37));
        cardContent.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); cardContent.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
        var status = Column(Palette.Dark);
        status.RowStyles.Add(new RowStyle(SizeType.Absolute, 21)); status.RowStyles.Add(new RowStyle(SizeType.Absolute, 34)); status.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        status.Controls.Add(TextLabel("LIVE CONNECTION", 8, FontStyle.Bold, Color.FromArgb(161, 190, 165)), 0, 0);
        StyleLabel(state, 20, FontStyle.Bold, Color.White); StyleLabel(detail, 9.5f, FontStyle.Regular, Color.FromArgb(200, 217, 204));
        state.AccessibleName = "Bridge connection status"; detail.AccessibleName = "Connection instructions";
        status.Controls.Add(state, 0, 1); status.Controls.Add(detail, 0, 2); cardContent.Controls.Add(status, 0, 0);
        connection.Dock = DockStyle.Fill; connection.Margin = new Padding(18, 15, 4, 10); connection.AccessibleName = "Desktop, bridge and Roblox connection";
        cardContent.Controls.Add(connection, 1, 0);
        var actions = Grid(Palette.Dark, 3);
        actions.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 158)); actions.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 128)); actions.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        StyleButton(start, "Start Cowork", true, true); StyleButton(stop, "Stop bridge", false, true);
        start.Click += async (_, _) => { if (bridge.BrowserUrl is not null) OpenBrowser(); else await StartAsync(); };
        stop.Click += async (_, _) => await StopAsync(); actions.Controls.Add(start, 0, 0); actions.Controls.Add(stop, 1, 0);
        var privateNote = TextLabel("PRIVATE  /  ON THIS COMPUTER", 8, FontStyle.Bold, Color.FromArgb(153, 183, 164)); privateNote.TextAlign = ContentAlignment.MiddleRight;
        actions.Controls.Add(privateNote, 2, 0); cardContent.Controls.Add(actions, 0, 1); cardContent.SetColumnSpan(actions, 2);
        card.Controls.Add(cardContent); layout.Controls.Add(card, 0, 2);

        var body = Grid(Palette.Canvas, 2);
        body.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 56)); body.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 44));
        var left = Column(Palette.Canvas); left.Margin = new Padding(0, 0, 8, 0);
        left.RowStyles.Add(new RowStyle(SizeType.Absolute, 260)); left.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        var integrations = MakeCard(new Padding(0, 0, 0, 12)); var integrationContent = Column(Color.White);
        foreach (int height in new[] { 28, 86, 72, 22 }) integrationContent.RowStyles.Add(new RowStyle(SizeType.Absolute, height));
        integrationContent.Controls.Add(TextLabel("Connections", 12, FontStyle.Bold, Palette.Ink), 0, 0);
        openCode.Checked = preferences.OpenCodeEnabled; mcp.Checked = preferences.McpEnabled;
        integrationContent.Controls.Add(Integration("OpenCode tunnel", openCode, openCodeStatus, openCodeDetail), 0, 1);
        integrationContent.Controls.Add(Integration("MCP access", mcp, mcpStatus, mcpDetail), 0, 2);
        StyleLabel(settingsNote, 8.5f, FontStyle.Regular, Palette.Muted);
        integrationContent.Controls.Add(settingsNote, 0, 3); integrations.Controls.Add(integrationContent); left.Controls.Add(integrations, 0, 0);
        var behavior = MakeCard(Padding.Empty); behavior.Padding = new Padding(20, 13, 20, 13);
        var behaviorContent = Column(Color.White);
        behaviorContent.RowStyles.Add(new RowStyle(SizeType.Absolute, 26)); behaviorContent.RowStyles.Add(new RowStyle(SizeType.Absolute, 40)); behaviorContent.RowStyles.Add(new RowStyle(SizeType.Absolute, 35));
        behaviorContent.Controls.Add(TextLabel("Make yourself at home", 11, FontStyle.Bold, Palette.Ink), 0, 0);
        openBrowser.Checked = preferences.OpenBrowser; startOnLaunch.Checked = preferences.StartOnLaunch;
        behaviorContent.Controls.Add(PreferenceRow("Open browser when bridge starts", openBrowser), 0, 1);
        behaviorContent.Controls.Add(PreferenceRow("Start bridge when app opens", startOnLaunch), 0, 2);
        behavior.Controls.Add(behaviorContent); left.Controls.Add(behavior, 0, 1); body.Controls.Add(left, 0, 0);

        var right = Column(Palette.Canvas); right.Margin = new Padding(8, 0, 0, 0);
        right.RowStyles.Add(new RowStyle(SizeType.Absolute, 194)); right.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        var nodeCard = MakeCard(new Padding(0, 0, 0, 12)); var nodeContent = Column(Color.White);
        foreach (int height in new[] { 29, 24, 49, 40 }) nodeContent.RowStyles.Add(new RowStyle(SizeType.Absolute, height));
        var nodeHeading = Grid(Color.White, 2); nodeHeading.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); nodeHeading.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 86));
        nodeHeading.Controls.Add(TextLabel("Ready to run", 12, FontStyle.Bold, Palette.Ink), 0, 0);
        var manualNode = Link("Manual setup", () => OpenExternal(NodeRuntime.DownloadPage)); manualNode.Padding = new Padding(0, 4, 0, 0);
        nodeHeading.Controls.Add(manualNode, 1, 0); nodeContent.Controls.Add(nodeHeading, 0, 0);
        StyleLabel(nodeState, 10, FontStyle.Bold, Palette.Ink); StyleLabel(nodeDetail, 9, FontStyle.Regular, Palette.Muted);
        nodeContent.Controls.Add(nodeState, 0, 1); nodeContent.Controls.Add(nodeDetail, 0, 2);
        var runtimeActions = Grid(Color.White, 2);
        runtimeActions.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 59)); runtimeActions.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 41));
        StyleButton(install, "Get Node.js", true); StyleButton(recheck, "Check again");
        install.Click += async (_, _) => await InstallNodeAsync(); recheck.Click += async (_, _) => await FindNodeAsync();
        runtimeActions.Controls.Add(install, 0, 0); runtimeActions.Controls.Add(recheck, 1, 0);
        nodeContent.Controls.Add(runtimeActions, 0, 3); nodeCard.Controls.Add(nodeContent); right.Controls.Add(nodeCard, 0, 0);
        var updateCard = MakeCard(Padding.Empty); var updateContent = Column(Color.White);
        foreach (int height in new[] { 27, 32, 31, 38, 38 }) updateContent.RowStyles.Add(new RowStyle(SizeType.Absolute, height));
        updateContent.Controls.Add(TextLabel("Always moving forward", 12, FontStyle.Bold, Palette.Ink), 0, 0);
        automaticUpdates.Checked = preferences.AutomaticAppUpdates;
        updateContent.Controls.Add(PreferenceRow("Download app updates", automaticUpdates), 0, 1);
        StyleLabel(bridgeUpdate, 8.5f, FontStyle.Regular, Palette.Muted); StyleLabel(appUpdate, 8.5f, FontStyle.Regular, Palette.Muted);
        updateContent.Controls.Add(bridgeUpdate, 0, 2); updateContent.Controls.Add(appUpdate, 0, 3);
        StyleButton(restart, "Check for updates"); restart.Click += async (_, _) => { if (updater.ReadyToRestart) await ExitAsync(true); else await CheckUpdatesAsync(true); };
        updateContent.Controls.Add(restart, 0, 4); updateCard.Controls.Add(updateContent); right.Controls.Add(updateCard, 0, 1);
        body.Controls.Add(right, 1, 0); layout.Controls.Add(body, 0, 3);

        var footer = Grid(Palette.Canvas, 5); footer.Padding = new Padding(0, 18, 0, 0);
        footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); footer.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 135));
        footer.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 121)); footer.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 94)); footer.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 72));
        footer.Controls.Add(TextLabel("Minimize to taskbar. Close to disconnect.", 8.5f, FontStyle.Regular, Palette.Muted), 0, 0);
        footer.Controls.Add(Link("Install OpenCode", () => OpenExternal("https://opencode.ai")), 1, 0);
        footer.Controls.Add(Link("Copy client script", CopyClient), 2, 0);
        footer.Controls.Add(Link("MCP setup", () =>
        {
            if (bridge.BrowserUrl is { } url) OpenExternal(url.Replace("/#t=", "/?settings=mcp#t=", StringComparison.Ordinal));
            else OpenExternal("https://github.com/Project-Ptolemy/ProjectUAI/blob/main/bridge/MCP.md");
        }), 3, 0);
        footer.Controls.Add(Link("Get help", () => OpenExternal(BridgeProcess.Discord)), 4, 0); layout.Controls.Add(footer, 0, 4);

        foreach (var toggle in new[] { openCode, mcp, openBrowser, automaticUpdates, startOnLaunch }) toggle.CheckedChanged += (_, _) => SavePreferences();
        bridge.Changed += OnChanged; updater.Changed += OnChanged;
        timer.Tick += async (_, _) =>
        {
            if (refreshing || busy || preview || exiting) return;
            refreshing = true; try { await bridge.RefreshAsync(); } finally { refreshing = false; }
            if (!exiting && preferences.AutomaticAppUpdates && DateTime.UtcNow >= nextUpdateCheck) await CheckUpdatesAsync();
        };
        Shown += async (_, _) =>
        {
            if (preview) return;
            await FindNodeAsync(); if (IsDisposed || exiting) return; timer.Start();
            if (preferences.StartOnLaunch && runtime is not null) await StartAsync();
            if (!exiting) await CheckUpdatesAsync();
        };
        // Minimize stays in the taskbar. X waits for owned processes to stop.
        FormClosing += async (_, args) =>
        {
            if (allowClose || args.CloseReason == CloseReason.WindowsShutDown || args.CloseReason == CloseReason.TaskManagerClosing) return;
            args.Cancel = true; await Task.Yield(); await ExitAsync();
        };
        FormClosed += (_, _) =>
        {
            lifetime.Cancel(); timer.Stop(); timer.Dispose(); bridge.Changed -= OnChanged; updater.Changed -= OnChanged;
        };
        nodeState.Text = "Looking for Node.js..."; nodeDetail.Text = "Checking your installed runtime."; UpdateState();
    }

    protected override void OnLoad(EventArgs e)
    {
        if (!preview)
        {
            // Respect small displays, the taskbar, and display scaling. The
            // dashboard scrolls vertically without moving the title bar offscreen.
            Rectangle area = Screen.FromControl(this).WorkingArea;
            int width = Math.Max(320, area.Width - 24), height = Math.Max(300, area.Height - 24);
            MinimumSize = new Size(Math.Min(MinimumSize.Width, width), Math.Min(MinimumSize.Height, height));
            Size = new Size(Math.Min(Width, width), Math.Min(Height, height));
            Location = new Point(area.Left + (area.Width - Width) / 2, area.Top + (area.Height - Height) / 2);
        }
        base.OnLoad(e);
    }

    private static SurfacePanel MakeCard(Padding margin) => new() { Dock = DockStyle.Fill, Padding = new Padding(20), Margin = margin };
    private static TableLayoutPanel Column(Color back, int padding = 0) => new() { Dock = DockStyle.Fill, ColumnCount = 1, BackColor = back, Padding = new Padding(padding), Margin = Padding.Empty };
    private static TableLayoutPanel Grid(Color back, int columns) => new() { Dock = DockStyle.Fill, ColumnCount = columns, BackColor = back, Margin = Padding.Empty };
    private static Label TextLabel(string text, float size, FontStyle style, Color color)
    { var label = new Label { Text = text }; StyleLabel(label, size, style, color); return label; }
    private static void StyleLabel(Label label, float size, FontStyle style, Color color)
    { label.Dock = DockStyle.Fill; label.Margin = Padding.Empty; label.Font = new Font("Segoe UI", size, style); label.ForeColor = color; label.AutoEllipsis = true; }
    private static void StyleButton(ActionButton button, string text, bool primary = false, bool dark = false)
    {
        button.Text = text; button.AccessibleName = text; button.Primary = primary; button.OnDark = dark;
        button.Dock = DockStyle.Fill; button.Margin = new Padding(0, 0, 8, 0); button.BackColor = dark ? Palette.Dark : Color.White;
    }
    private static Control Integration(string title, ToggleSwitch toggle, StatusPill pill, Label description)
    {
        var row = Grid(Color.White, 2); row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); row.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 60));
        row.RowStyles.Add(new RowStyle(SizeType.Absolute, 28)); row.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        var titleRow = Grid(Color.White, 2); titleRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); titleRow.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 84));
        titleRow.Controls.Add(TextLabel(title, 10, FontStyle.Bold, Palette.Ink), 0, 0);
        pill.Dock = DockStyle.Fill; pill.Margin = new Padding(2, 0, 2, 4); pill.AccessibleName = title + " status"; titleRow.Controls.Add(pill, 1, 0);
        row.Controls.Add(titleRow, 0, 0);
        StyleLabel(description, 9, FontStyle.Regular, Palette.Muted); description.Padding = new Padding(0, 3, 7, 0); description.AccessibleName = title + " details";
        row.Controls.Add(description, 0, 1);
        toggle.Anchor = AnchorStyles.Top | AnchorStyles.Right; toggle.AccessibleName = "Enable " + title; toggle.Margin = new Padding(6, 0, 0, 0);
        row.Controls.Add(toggle, 1, 0); row.SetRowSpan(toggle, 2); return row;
    }
    private static Control PreferenceRow(string title, ToggleSwitch toggle)
    {
        var row = Grid(Color.White, 2); row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); row.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 52));
        var label = TextLabel(title, 9, FontStyle.Regular, Palette.Ink); label.TextAlign = ContentAlignment.MiddleLeft; row.Controls.Add(label, 0, 0);
        toggle.AccessibleName = title; toggle.Anchor = AnchorStyles.Right; toggle.Margin = Padding.Empty; row.Controls.Add(toggle, 1, 0); return row;
    }
    private static LinkLabel Link(string text, Action action)
    {
        var link = new LinkLabel { Text = text, Dock = DockStyle.Fill, Font = new Font("Segoe UI", 8.5f), Margin = Padding.Empty,
            LinkColor = Palette.Muted, ActiveLinkColor = Palette.Ink, VisitedLinkColor = Palette.Muted, LinkBehavior = LinkBehavior.HoverUnderline };
        link.Click += (_, _) => action(); return link;
    }
    private void SavePreferences()
    {
        preferences = new(openCode.Checked, mcp.Checked, openBrowser.Checked, automaticUpdates.Checked, startOnLaunch.Checked);
        if (!preview)
        {
            try { preferences.Save(); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { detail.Text = "Preferences apply now, but could not be saved for your next launch."; return; }
        }
        nextUpdateCheck = DateTime.MinValue; UpdateState();
    }
    private void OnChanged()
    {
        if (IsDisposed || !IsHandleCreated) return;
        try { BeginInvoke(UpdateState); } catch (InvalidOperationException) { }
    }
    private void UpdateState()
    {
        if (IsDisposed) return;
        bool running = bridge.BrowserUrl is not null;
        state.Text = exiting ? "Closing your workspace..." : bridge.State == "Stopped" ? "Ready when you are." : bridge.State;
        detail.Text = exiting ? "Stopping the bridge and its OpenCode process." : bridge.State == "Stopped" ? "Start Cowork, then load UAI in Roblox.\nYour browser workspace is one click away." : bridge.Detail;
        state.ForeColor = bridge.State == "Connected to Roblox" ? Palette.Accent : Color.White;
        start.Enabled = !busy && !installing && (runtime is not null || running); start.Text = busy ? "Please wait..." : running ? "Open Cowork" : "Start Cowork";
        stop.Enabled = running && !busy;
        install.Enabled = !installing && !detecting && !busy && runtime is null;
        install.Text = installing ? "Downloading..." : runtime is not null ? "Node.js ready" : "Get Node.js"; recheck.Enabled = !installing && !detecting && !busy;
        connection.Running = running; connection.Connected = bridge.State == "Connected to Roblox"; connection.Invalidate();
        connection.AccessibleDescription = running ? connection.Connected ? "All three connected" : "Bridge ready; waiting for Roblox" : "Bridge stopped";
        bridgeUpdate.Text = !running ? "Bridge updates when running." : bridge.UpdateState switch
        {
            "staged" => $"Bridge {bridge.AvailableVersion} ready when work finishes.",
            "checking" => "Bridge is checking for updates...", "restarting" => "Bridge is applying an update...",
            "error" => $"Bridge {bridge.BridgeVersion}: update check will retry.",
            _ => $"Bridge {bridge.BridgeVersion} updates automatically."
        };
        appUpdate.Text = !preferences.AutomaticAppUpdates && !updater.ReadyToRestart && !checkingUpdates ? "App downloads paused. Check manually below." : updater.Detail;
        openCodeDetail.Text = !preferences.OpenCodeEnabled && !running ? "Turn on to use the installed OpenCode CLI." : bridge.OpenCodeDetail;
        string openState = !preferences.OpenCodeEnabled ? "OFF" : !running ? "ON START" : bridge.OpenCodeState switch
        { "ready" => "READY", "starting" => "STARTING", "missing" => "INSTALL", "failed" => "RETRY", "disabled" => "OFF", _ => "WAITING" };
        SetPill(openCodeStatus, openState, running && bridge.OpenCodeState == "ready");
        bool mcpOn = running ? bridge.McpEnabled : preferences.McpEnabled;
        SetPill(mcpStatus, mcpOn ? running ? "ENABLED" : "ON START" : "OFF", running && mcpOn);
        mcpDetail.Text = mcpOn ? "Connect a coding agent to UAI tools in Roblox.\nGame permissions stay in your control." : "External agents cannot connect through MCP.";
        openCode.Enabled = mcp.Enabled = !running && !busy;
        openBrowser.Enabled = automaticUpdates.Enabled = startOnLaunch.Enabled = !exiting;
        settingsNote.Text = running ? "Stop the bridge to change connections." : "Connection preferences apply on the next start.";
        restart.Enabled = !busy && !installing && !checkingUpdates && (!updater.ReadyToRestart || !running);
        restart.Text = checkingUpdates ? "Checking for updates..." : updater.ReadyToRestart ? running ? "Stop bridge to update" : "Restart to update app" : "Check for updates";
    }
    private static void SetPill(StatusPill pill, string text, bool active) { pill.Text = text; pill.Active = active; pill.Invalidate(); }
    private async Task FindNodeAsync()
    {
        if (installing || detecting || exiting) return; detecting = true; UpdateState();
        try
        {
            runtime = await NodeRuntime.FindAsync(lifetime.Token); if (IsDisposed || exiting) return;
            nodeState.Text = runtime is null ? "Node.js needs a quick setup" : $"Node.js {runtime.Version}";
            nodeDetail.Text = runtime is null ? "Get a verified runtime with one click. No administrator access needed." : runtime.Managed ? "Verified runtime installed for Cowork.\nEverything is in place." : "Using the runtime on your computer.\nEverything is in place.";
        }
        catch (OperationCanceledException) { }
        catch (Exception) { if (!IsDisposed) nodeDetail.Text = "Could not check Node.js. Try again or use nodejs.org."; }
        finally { detecting = false; if (!IsDisposed) UpdateState(); }
    }
    private async Task InstallNodeAsync()
    {
        if (installing || detecting || busy) return; installing = true; UpdateState();
        try
        {
            runtime = await NodeRuntime.InstallAsync(new Progress<string>(message => { if (!IsDisposed && !exiting) nodeDetail.Text = message; }), lifetime.Token);
            if (!IsDisposed && !exiting) { nodeState.Text = $"Node.js {runtime.Version}"; nodeDetail.Text = "Installed for Cowork. You are ready to start."; }
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { if (!IsDisposed) { nodeState.Text = "Download did not finish"; nodeDetail.Text = error.Message; } }
        finally { installing = false; if (!IsDisposed) UpdateState(); }
    }
    private async Task CheckUpdatesAsync(bool manual = false)
    {
        if (checkingUpdates || preview || exiting || (!manual && !preferences.AutomaticAppUpdates)) return;
        checkingUpdates = true; nextUpdateCheck = DateTime.UtcNow.AddMinutes(15); UpdateState();
        try { await updater.CheckAsync(lifetime.Token); }
        catch (OperationCanceledException) { }
        catch (Exception) { if (!IsDisposed) appUpdate.Text = "Update check failed. Try again shortly."; }
        finally { checkingUpdates = false; if (!IsDisposed) UpdateState(); }
    }
    private async Task StartAsync()
    {
        if (busy || exiting) return; busy = true; UpdateState();
        try { await bridge.StartAsync(preferences.BridgeOptions); if (!exiting && preferences.OpenBrowser) OpenBrowser(); }
        catch (IOException) { }
        finally { busy = exiting; if (!IsDisposed) UpdateState(); }
    }
    private async Task StopAsync()
    {
        if (busy || exiting) return; busy = true; UpdateState();
        try { await bridge.StopAsync(); }
        catch (Exception) { if (!IsDisposed) detail.Text = "Could not stop the bridge. Close the app to release it."; }
        finally { busy = exiting; if (!IsDisposed) UpdateState(); }
    }
    private async void CopyClient()
    {
        try
        {
            string root = await Task.Run(EmbeddedPayload.Prepare);
            string script = await File.ReadAllTextAsync(Path.Combine(root, "client", "uai.lua"));
            if (IsDisposed || exiting) return; Clipboard.SetText(script);
            detail.Text = "Client script copied. Paste it into your Roblox executor.";
        }
        catch (Exception) { if (!IsDisposed) detail.Text = "The script could not be copied. Use the published UAI loader."; }
    }
    private void OpenBrowser() { if (bridge.BrowserUrl is { } url && !exiting) OpenExternal(url); }
    private void OpenExternal(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException)
        { detail.Text = "Windows could not open your browser. Set a default browser, then try again."; }
    }
    public void RestoreWindow() { if (IsDisposed || exiting) return; Show(); WindowState = FormWindowState.Normal; Activate(); }
    private async Task ExitAsync(bool applyUpdate = false)
    {
        if (exiting || (applyUpdate && (busy || installing || bridge.BrowserUrl is not null))) return;
        exiting = true; busy = true; timer.Stop(); if (!applyUpdate) lifetime.Cancel(); UpdateState();
        try
        {
            await bridge.StopAsync();
            if (applyUpdate && updater.ReadyToRestart && !updater.ApplyOnExit())
            {
                exiting = false; busy = false; timer.Start(); UpdateState(); detail.Text = "The update could not start. Close and reopen the app to try again.";
                return;
            }
        }
        catch (Exception) { /* Closing still releases the owned job in Program's final cleanup. */ }
        lifetime.Cancel(); allowClose = true; Close();
    }
    public void RenderPreview(string path, bool compact = false)
    {
        preview = true; StartPosition = FormStartPosition.Manual; Location = new Point(-30000, -30000); ShowInTaskbar = false;
        if (compact) ClientSize = new Size(870, 650);
        Shown += async (_, _) =>
        {
            await FindNodeAsync(); await Task.Delay(250);
            using var bitmap = new Bitmap(Width, Height); DrawToBitmap(bitmap, new Rectangle(Point.Empty, Size)); bitmap.Save(Path.GetFullPath(path));
            allowClose = true; Close();
        };
    }
}
