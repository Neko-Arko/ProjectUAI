using System.Diagnostics;

namespace ProjectUai.Bridge;

internal sealed class MainForm : Form
{
    private readonly BridgeProcess bridge;
    private readonly DesktopUpdater updater = new();
    private readonly CancellationTokenSource lifetime = new();
    private readonly Label state = new(), detail = new(), nodeState = new(), nodeDetail = new(), bridgeUpdate = new(), appUpdate = new(), openCodeDetail = new();
    private readonly ActionButton start = new(), stop = new(), install = new(), recheck = new(), restart = new();
    private readonly ConnectionStrip connection = new();
    private readonly NotifyIcon tray;
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 1500 };
    private readonly ToolStripMenuItem trayOpen, trayStop;
    private NodeInstallation? runtime;
    private bool busy, refreshing, installing, detecting, allowClose, trayHintShown, preview, checkingUpdates;
    private DateTime nextUpdateCheck = DateTime.MinValue;

    public MainForm(BridgeProcess bridge)
    {
        this.bridge = bridge;
        Text = "Cowork — Desktop bridge";
        Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!) ?? SystemIcons.Application;
        ShowIcon = false;
        BackColor = Palette.Canvas; ForeColor = Palette.Ink;
        Font = new Font("Segoe UI", 10); AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(860, 836); MinimumSize = new Size(790, 738);
        StartPosition = FormStartPosition.CenterScreen;

        var layout = Column(BackColor, 32); layout.AutoScroll = true; layout.RowCount = 6;
        foreach (int height in new[] { 40, 114, 254, 208, 108, 48 }) layout.RowStyles.Add(new RowStyle(SizeType.Absolute, height));
        Controls.Add(layout);
        var masthead = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, Margin = Padding.Empty };
        masthead.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); masthead.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 200));
        masthead.Controls.Add(TextLabel("Cowork", 16, FontStyle.Bold, Palette.Ink), 0, 0);
        var edition = TextLabel($"DESKTOP  /  {DesktopUpdater.CurrentVersion}", 9, FontStyle.Regular, Palette.Muted);
        edition.TextAlign = ContentAlignment.TopRight; edition.Padding = new Padding(0, 7, 0, 0);
        masthead.Controls.Add(edition, 1, 0); layout.Controls.Add(masthead, 0, 0);
        var intro = Column(Palette.Canvas);
        intro.RowStyles.Add(new RowStyle(SizeType.Absolute, 56)); intro.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        intro.Controls.Add(TextLabel("Your workspace, connected.", 28, FontStyle.Bold, Palette.Ink), 0, 0);
        intro.Controls.Add(TextLabel("Bring your Roblox conversations to the browser.", 11, FontStyle.Regular, Palette.Muted), 0, 1);
        layout.Controls.Add(intro, 0, 1);

        var card = new SurfacePanel { Dock = DockStyle.Fill, Fill = Palette.Dark, Border = Palette.Dark, Padding = new Padding(26), Margin = new Padding(0, 0, 0, 20) };
        var cardContent = new TableLayoutPanel { BackColor = Palette.Dark, Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 2, Margin = Padding.Empty };
        cardContent.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 63)); cardContent.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 37));
        cardContent.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); cardContent.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
        var status = Column(Palette.Dark);
        status.RowStyles.Add(new RowStyle(SizeType.Absolute, 27)); status.RowStyles.Add(new RowStyle(SizeType.Absolute, 43)); status.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        status.Controls.Add(TextLabel("YOUR CONNECTION", 8.5f, FontStyle.Bold, Color.FromArgb(163, 193, 175)), 0, 0);
        StyleLabel(state, 21, FontStyle.Bold, Color.White); StyleLabel(detail, 10, FontStyle.Regular, Color.FromArgb(192, 212, 200));
        state.AccessibleName = "Bridge connection status"; detail.AccessibleName = "Connection instructions";
        status.Controls.Add(state, 0, 1); status.Controls.Add(detail, 0, 2); cardContent.Controls.Add(status, 0, 0);
        connection.Dock = DockStyle.Fill; connection.Margin = new Padding(8, 24, 0, 18); connection.AccessibleName = "Desktop, bridge and Roblox connection";
        cardContent.Controls.Add(connection, 1, 0);
        var actions = new TableLayoutPanel { BackColor = Palette.Dark, Dock = DockStyle.Fill, ColumnCount = 3, Margin = Padding.Empty };
        actions.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 166)); actions.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 126)); actions.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        StyleButton(start, "Start Cowork", true, true); StyleButton(stop, "Stop bridge", false, true);
        start.Click += async (_, _) => { if (bridge.BrowserUrl is not null) OpenBrowser(); else await StartAsync(); };
        stop.Click += async (_, _) => await StopAsync(); actions.Controls.Add(start, 0, 0); actions.Controls.Add(stop, 1, 0);
        var privateNote = TextLabel("Local to this computer", 9, FontStyle.Regular, Color.FromArgb(153, 183, 164)); privateNote.TextAlign = ContentAlignment.MiddleRight;
        actions.Controls.Add(privateNote, 2, 0); cardContent.Controls.Add(actions, 0, 1); cardContent.SetColumnSpan(actions, 2);
        card.Controls.Add(cardContent); layout.Controls.Add(card, 0, 2);

        var lower = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, Margin = Padding.Empty };
        lower.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50)); lower.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        var nodeCard = MakeCard(new Padding(0, 0, 8, 12)); var nodeContent = Column(Color.White);
        foreach (int height in new[] { 29, 28, 56, 40 }) nodeContent.RowStyles.Add(new RowStyle(SizeType.Absolute, height));
        nodeContent.Controls.Add(TextLabel("Node.js runtime", 12, FontStyle.Bold, Palette.Ink), 0, 0);
        StyleLabel(nodeState, 10, FontStyle.Regular, Palette.Ink); StyleLabel(nodeDetail, 9, FontStyle.Regular, Palette.Muted);
        nodeContent.Controls.Add(nodeState, 0, 1); nodeContent.Controls.Add(nodeDetail, 0, 2);
        var runtimeActions = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, Margin = Padding.Empty };
        runtimeActions.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 55)); runtimeActions.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 45));
        StyleButton(install, "Download Node.js", true); StyleButton(recheck, "Check again");
        install.Click += async (_, _) => await InstallNodeAsync(); recheck.Click += async (_, _) => await FindNodeAsync();
        runtimeActions.Controls.Add(install, 0, 0); runtimeActions.Controls.Add(recheck, 1, 0);
        nodeContent.Controls.Add(runtimeActions, 0, 3); nodeCard.Controls.Add(nodeContent); lower.Controls.Add(nodeCard, 0, 0);
        var updateCard = MakeCard(new Padding(8, 0, 0, 12)); var updateContent = Column(Color.White);
        foreach (int height in new[] { 29, 35, 49, 40 }) updateContent.RowStyles.Add(new RowStyle(SizeType.Absolute, height));
        updateContent.Controls.Add(TextLabel("Always up to date", 12, FontStyle.Bold, Palette.Ink), 0, 0);
        StyleLabel(bridgeUpdate, 9, FontStyle.Regular, Palette.Muted); StyleLabel(appUpdate, 9, FontStyle.Regular, Palette.Muted);
        updateContent.Controls.Add(bridgeUpdate, 0, 1); updateContent.Controls.Add(appUpdate, 0, 2);
        StyleButton(restart, "Restart to update"); restart.Click += async (_, _) => await ExitAsync(true);
        updateContent.Controls.Add(restart, 0, 3); updateCard.Controls.Add(updateContent); lower.Controls.Add(updateCard, 1, 0);
        layout.Controls.Add(lower, 0, 3);

        var openCodeCard = MakeCard(new Padding(0, 0, 0, 12));
        var openCodeContent = new TableLayoutPanel { BackColor = Color.White, Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 2, Margin = Padding.Empty };
        openCodeContent.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); openCodeContent.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 190));
        openCodeContent.RowStyles.Add(new RowStyle(SizeType.Absolute, 24)); openCodeContent.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        openCodeContent.Controls.Add(TextLabel("OpenCode free models", 11, FontStyle.Bold, Palette.Ink), 0, 0);
        StyleLabel(openCodeDetail, 9, FontStyle.Regular, Palette.Muted); openCodeDetail.AccessibleName = "OpenCode backend status";
        openCodeContent.Controls.Add(openCodeDetail, 0, 1);
        openCodeContent.Controls.Add(Link("Install OpenCode Desktop", () => OpenExternal("https://opencode.ai")), 1, 0);
        openCodeContent.Controls.Add(Link("Discord help and updates", () => OpenExternal(BridgeProcess.Discord)), 1, 1);
        openCodeCard.Controls.Add(openCodeContent); layout.Controls.Add(openCodeCard, 0, 4);

        var footer = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 4, Margin = Padding.Empty, Padding = new Padding(0, 5, 0, 0) };
        footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); footer.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 120));
        footer.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 110)); footer.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 65));
        footer.Controls.Add(Link("Install Node manually", () => OpenExternal(NodeRuntime.DownloadPage)), 0, 0);
        footer.Controls.Add(Link("Copy client script", async () =>
        {
            try
            {
                string root = await Task.Run(EmbeddedPayload.Prepare);
                if (IsDisposed) return;
                Clipboard.SetText(await File.ReadAllTextAsync(Path.Combine(root, "client", "uai.lua")));
                detail.Text = "Client script copied. Paste it into your Roblox executor.";
            }
            catch (Exception) { if (!IsDisposed) detail.Text = "The script could not be copied. Use the published UAI loader."; }
        }), 1, 0);
        footer.Controls.Add(Link("Hide to tray", HideToTray), 2, 0); footer.Controls.Add(Link("Exit app", async () => await ExitAsync()), 3, 0);
        layout.Controls.Add(footer, 0, 5);
        var menu = new ContextMenuStrip(); menu.Items.Add("Show Cowork", null, (_, _) => RestoreWindow());
        trayOpen = new ToolStripMenuItem("Open Cowork", null, (_, _) => OpenBrowser()); trayStop = new ToolStripMenuItem("Stop bridge", null, async (_, _) => await StopAsync());
        menu.Items.Add(trayOpen); menu.Items.Add(trayStop); menu.Items.Add(new ToolStripSeparator()); menu.Items.Add("Exit", null, async (_, _) => await ExitAsync());
        tray = new NotifyIcon { Icon = Icon, Text = "Cowork · Stopped", ContextMenuStrip = menu, Visible = true }; tray.DoubleClick += (_, _) => RestoreWindow();
        bridge.Changed += OnChanged; updater.Changed += OnChanged;
        timer.Tick += async (_, _) =>
        {
            if (refreshing || busy || preview) return;
            refreshing = true; try { await bridge.RefreshAsync(); } finally { refreshing = false; }
            if (DateTime.UtcNow >= nextUpdateCheck) await CheckUpdatesAsync();
        };
        Shown += async (_, _) => { if (preview) return; await FindNodeAsync(); if (IsDisposed) return; timer.Start(); await CheckUpdatesAsync(); };
        Resize += (_, _) => { if (WindowState == FormWindowState.Minimized) HideToTray(); };
        FormClosing += (_, args) =>
        {
            if (allowClose || args.CloseReason == CloseReason.WindowsShutDown || args.CloseReason == CloseReason.TaskManagerClosing) return;
            if (busy || installing || bridge.BrowserUrl is not null) { args.Cancel = true; HideToTray(); }
        };
        FormClosed += (_, _) =>
        {
            lifetime.Cancel(); timer.Stop(); timer.Dispose(); bridge.Changed -= OnChanged; updater.Changed -= OnChanged;
            tray.Visible = false; tray.Dispose(); menu.Dispose();
        };
        nodeState.Text = "Looking for Node.js…"; nodeDetail.Text = "Checking your installed runtime."; UpdateState();
    }

    private static SurfacePanel MakeCard(Padding margin) => new() { Dock = DockStyle.Fill, Padding = new Padding(21), Margin = margin };
    private static TableLayoutPanel Column(Color back, int padding = 0) => new() { Dock = DockStyle.Fill, ColumnCount = 1, BackColor = back, Padding = new Padding(padding), Margin = Padding.Empty };
    private static Label TextLabel(string text, float size, FontStyle style, Color color)
    { var label = new Label { Text = text }; StyleLabel(label, size, style, color); return label; }
    private static void StyleLabel(Label label, float size, FontStyle style, Color color)
    { label.Dock = DockStyle.Fill; label.Margin = Padding.Empty; label.Font = new Font("Segoe UI", size, style); label.ForeColor = color; label.AutoEllipsis = false; }
    private static void StyleButton(ActionButton button, string text, bool primary = false, bool dark = false)
    {
        button.Text = text; button.AccessibleName = text; button.Primary = primary; button.OnDark = dark;
        button.Dock = DockStyle.Fill; button.Margin = new Padding(0, 0, 8, 0); button.BackColor = dark ? Palette.Dark : Color.White;
    }
    private static LinkLabel Link(string text, Action action)
    {
        var link = new LinkLabel { Text = text, Dock = DockStyle.Fill, Font = new Font("Segoe UI", 9), Margin = Padding.Empty,
            LinkColor = Palette.Muted, ActiveLinkColor = Palette.Ink, VisitedLinkColor = Palette.Muted, LinkBehavior = LinkBehavior.HoverUnderline };
        link.Click += (_, _) => action(); return link;
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
        state.Text = bridge.State == "Stopped" ? "Ready when you are." : bridge.State;
        detail.Text = bridge.State == "Stopped" ? "Start Cowork, then open the UAI script in Roblox.\nWe’ll take care of the connection." : bridge.Detail;
        state.ForeColor = bridge.State == "Connected to Roblox" ? Palette.Accent : Color.White;
        start.Enabled = !busy && !installing && (runtime is not null || running); start.Text = busy ? "Please wait…" : running ? "Open Cowork" : "Start Cowork";
        stop.Enabled = trayStop.Enabled = running && !busy; trayOpen.Enabled = running && !busy;
        install.Enabled = !installing && !detecting && !busy && runtime is null;
        install.Text = installing ? "Downloading…" : runtime is not null ? "Node.js is ready" : "Download Node.js"; recheck.Enabled = !installing && !detecting && !busy;
        connection.Running = running; connection.Connected = bridge.State == "Connected to Roblox"; connection.Invalidate();
        connection.AccessibleDescription = running ? connection.Connected ? "All three connected" : "Bridge ready; waiting for Roblox" : "Bridge stopped";
        bridgeUpdate.Text = !running ? "Bridge · Updates automatically while running" : bridge.UpdateState switch
        {
            "staged" => $"Bridge {bridge.AvailableVersion} · Ready when work finishes",
            "checking" => "Bridge · Checking GitHub for updates…", "restarting" => "Bridge · Applying update…",
            "error" => $"Bridge {bridge.BridgeVersion} · Update check failed; will retry",
            _ => $"Bridge {bridge.BridgeVersion} · Automatic updates on"
        };
        appUpdate.Text = "Desktop · " + updater.Detail;
        openCodeDetail.Text = bridge.OpenCodeDetail;
        restart.Enabled = updater.ReadyToRestart && !busy && !running && !installing;
        restart.Text = updater.ReadyToRestart ? running ? "Stop bridge to update app" : "Restart to update app" : "Updates automatically";
        tray.Text = "Cowork · " + bridge.State;
    }
    private async Task FindNodeAsync()
    {
        if (installing || detecting) return; detecting = true; UpdateState();
        try
        {
            runtime = await NodeRuntime.FindAsync(lifetime.Token); if (IsDisposed) return;
            nodeState.Text = runtime is null ? "One quick setup step" : $"Version {runtime.Version} · Ready";
            nodeDetail.Text = runtime is null ? "Download Node.js here, or use the manual link below. No administrator access needed." : runtime.Managed ? "Installed for Cowork. Nothing else to configure." : "Using the Node.js already on your computer.";
        }
        catch (OperationCanceledException) { }
        catch (Exception) { if (!IsDisposed) nodeDetail.Text = "Could not check Node.js. Try again or install it manually."; }
        finally { detecting = false; if (!IsDisposed) UpdateState(); }
    }
    private async Task InstallNodeAsync()
    {
        if (installing || detecting || busy) return; installing = true; UpdateState();
        try
        {
            runtime = await NodeRuntime.InstallAsync(new Progress<string>(message => { if (!IsDisposed) nodeDetail.Text = message; }), lifetime.Token);
            if (!IsDisposed) { nodeState.Text = $"Version {runtime.Version} · Ready"; nodeDetail.Text = "Installed for Cowork. You’re ready to start."; }
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { if (!IsDisposed) { nodeState.Text = "Download didn’t finish"; nodeDetail.Text = error.Message; } }
        finally { installing = false; if (!IsDisposed) UpdateState(); }
    }
    private async Task CheckUpdatesAsync()
    {
        if (checkingUpdates || preview) return; checkingUpdates = true; nextUpdateCheck = DateTime.UtcNow.AddMinutes(15);
        try { await updater.CheckAsync(lifetime.Token); }
        catch (OperationCanceledException) { }
        catch (Exception) { if (!IsDisposed) appUpdate.Text = "Desktop · Update check failed; will retry."; }
        finally { checkingUpdates = false; if (!IsDisposed) UpdateState(); }
    }
    private async Task StartAsync()
    {
        if (busy) return; busy = true; UpdateState();
        try { await bridge.StartAsync(); OpenBrowser(); }
        catch (IOException) { }
        finally { busy = false; if (!IsDisposed) UpdateState(); }
    }
    private async Task StopAsync()
    {
        if (busy) return; busy = true; UpdateState();
        try { await bridge.StopAsync(); }
        catch (Exception) { detail.Text = "Could not stop the bridge. Exit the app to release it."; }
        finally { busy = false; if (!IsDisposed) UpdateState(); }
    }
    private void OpenBrowser() { if (bridge.BrowserUrl is { } url) OpenExternal(url); }
    private void OpenExternal(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException)
        { detail.Text = "Windows could not open your browser. Set a default browser, then try again."; }
    }
    private void HideToTray()
    {
        Hide(); if (trayHintShown) return; trayHintShown = true;
        tray.ShowBalloonTip(3000, "Cowork is in your tray", "Double-click its tray icon to return. Choose Exit to stop the bridge.", ToolTipIcon.Info);
    }
    public void RestoreWindow() { if (IsDisposed) return; Show(); WindowState = FormWindowState.Normal; Activate(); }
    private async Task ExitAsync(bool applyUpdate = false)
    {
        if (busy || installing || (applyUpdate && bridge.BrowserUrl is not null)) { RestoreWindow(); return; }
        busy = true; UpdateState();
        try
        {
            await bridge.StopAsync();
            if (updater.ReadyToRestart && !updater.ApplyOnExit() && applyUpdate) { busy = false; UpdateState(); return; }
        }
        catch (Exception) { busy = false; UpdateState(); detail.Text = "The update could not start. Your current app is still available."; return; }
        allowClose = true; Close();
    }
    public void RenderPreview(string path)
    {
        preview = true; StartPosition = FormStartPosition.Manual; Location = new Point(-30000, -30000); ShowInTaskbar = false;
        Shown += async (_, _) =>
        {
            await FindNodeAsync(); await Task.Delay(250);
            using var bitmap = new Bitmap(Width, Height); DrawToBitmap(bitmap, new Rectangle(Point.Empty, Size)); bitmap.Save(Path.GetFullPath(path));
            allowClose = true; Close();
        };
    }
}
