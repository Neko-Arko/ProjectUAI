using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace ProjectUai.Bridge;

public partial class MainWindow : Window
{
    private bool allowClose;
    private Task? closing;
    internal bool IsClosed { get; private set; }
    internal BridgeViewModel Model { get; }

    internal MainWindow(BridgeProcess bridge, bool offline = false, DesktopUpdater? updates = null)
    {
        InitializeComponent();
        MinimizeButton.Click += (_, _) => WindowState = WindowState.Minimized;
        MaximizeButton.Click += (_, _) => WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
        CloseButton.Click += (_, _) => _ = RequestCloseAsync();
        StateChanged += (_, _) => MaximizeButton.Content = WindowState == WindowState.Maximized ? "\uE923" : "\uE922";
        Model = new BridgeViewModel(bridge, updates ?? new(), offline, Dispatcher, RequestCloseAsync);
        DataContext = Model;
        SizeChanged += (_, _) => Model.IsCompact = ActualWidth < 900;
        Model.PropertyChanged += (_, args) =>
        {
            // Each destination starts at its heading. Resizing and live status
            // updates preserve the user's position within the current page.
            if (args.PropertyName == nameof(BridgeViewModel.SelectedPage)) PageScroll.ScrollToTop();
        };
        Loaded += async (_, _) =>
        {
            if (!offline) FitWorkingArea();
            await Model.InitializeAsync();
        };
        Closed += (_, _) => { IsClosed = true; Model.Dispose(); };
    }

    private void FitWorkingArea()
    {
        Rect area = SystemParameters.WorkArea;
        double width = Math.Max(320, area.Width - 24), height = Math.Max(300, area.Height - 24);
        MinWidth = Math.Min(MinWidth, width); MinHeight = Math.Min(MinHeight, height);
        Width = Math.Min(Width, width); Height = Math.Min(Height, height);
        Left = area.Left + (area.Width - Width) / 2;
        Top = area.Top + (area.Height - Height) / 2;
    }

    protected override void OnClosing(CancelEventArgs args)
    {
        base.OnClosing(args);
        if (allowClose) return;
        args.Cancel = true;
        // Let the native close event complete before asynchronous shutdown can
        // close this same window, including when the bridge is already idle.
        Dispatcher.BeginInvoke(DispatcherPriority.Normal, new Action(() => _ = RequestCloseAsync()));
    }

    internal Task RequestCloseAsync(bool applyUpdate = false)
    {
        if (IsClosed) return Task.CompletedTask;
        if (closing is not null) return closing;
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        closing = completion.Task;
        _ = CloseCoreAsync(applyUpdate, completion);
        return completion.Task;
    }

    private async Task CloseCoreAsync(bool applyUpdate, TaskCompletionSource completion)
    {
        try
        {
            if (!await Model.PrepareCloseAsync(applyUpdate)) { closing = null; return; }
            allowClose = true; Close();
        }
        finally { completion.TrySetResult(); }
    }

    public void RestoreWindow()
    {
        if (IsClosed || Model.IsExiting) return;
        Show();
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
    }

    internal void RenderPreview(string path, bool compact = false, bool narrow = false)
    {
        WindowStartupLocation = WindowStartupLocation.Manual;
        Left = -30000; Top = -30000; ShowInTaskbar = false;
        if (narrow) { Width = 640; Height = 600; }
        else if (compact) { Width = 870; Height = 650; }
        Loaded += async (_, _) =>
        {
            try
            {
                await Model.InitializeAsync();
                await Task.Delay(180);
                string output = Path.GetFullPath(path);
                Capture(output);
                if (narrow)
                {
                    PageScroll.ScrollToBottom(); await Task.Delay(60);
                    Capture(Sibling(output, "-bottom"));
                    Model.SelectedPage = 4; PageScroll.ScrollToTop(); await Task.Delay(60);
                    Capture(Sibling(output, "-tunnels"));
                    PageScroll.ScrollToBottom(); await Task.Delay(60);
                    Capture(Sibling(output, "-tunnels-bottom"));
                }
                if (!compact && !narrow)
                {
                    string[] destinations = ["workspace", "connections", "updates", "settings", "tunnels"];
                    for (int page = 1; page < destinations.Length; page++)
                    {
                        Model.SelectedPage = page; PageScroll.ScrollToTop(); await Task.Delay(60);
                        Capture(Sibling(output, "-" + destinations[page]));
                        if (destinations[page] == "tunnels")
                        {
                            PageScroll.ScrollToBottom(); await Task.Delay(60);
                            Capture(Sibling(output, "-tunnels-bottom"));
                        }
                    }
                }
            }
            catch (Exception) { Environment.ExitCode = 1; }
            finally { await RequestCloseAsync(); }
        };
    }

    private static string Sibling(string path, string suffix) => Path.Combine(Path.GetDirectoryName(path)!, Path.GetFileNameWithoutExtension(path) + suffix + ".png");
    private void Capture(string path)
    {
        UpdateLayout();
        var content = (Visual)Content;
        var size = ((FrameworkElement)Content).RenderSize;
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(size.Width), (int)Math.Ceiling(size.Height), 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(content);
        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var file = File.Create(path); encoder.Save(file);
    }
}
