using System.Windows;
using System.Windows.Threading;

namespace ProjectUai.Bridge;

// Named kernel objects can survive through updater/duplicate process handles even
// after the window owner exits. Their existence does not establish a live owner.
internal sealed class DesktopInstance : IDisposable
{
    private readonly Mutex mutex;
    private readonly EventWaitHandle show;
    private readonly object gate = new();
    private RegisteredWaitHandle? waiter;
    private Window? window;
    private RoutedEventHandler? loaded;
    private EventHandler? closed;
    private int disposed;
    internal bool OwnsWindow { get; }

    internal DesktopInstance(string name = "ProjectUAI.Bridge.28791")
    {
        mutex = new Mutex(false, @"Local\" + name);
        string eventName = name == "ProjectUAI.Bridge.28791" ? "ProjectUAI.Bridge.Show.28791" : name + ".Show";
        show = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\" + eventName);
        try { OwnsWindow = mutex.WaitOne(0); }
        catch (AbandonedMutexException) { OwnsWindow = true; }
    }

    internal void RestoreExisting() => show.Set();

    internal void Listen(Window target, Action restore)
    {
        // Start listening after the native window has loaded. Until then the
        // AutoResetEvent retains the signal from an early duplicate launch.
        int windowClosed = 0;
        void StartListening()
        {
            lock (gate)
            {
                if (waiter is not null || Volatile.Read(ref disposed) != 0 || Volatile.Read(ref windowClosed) != 0) return;
                waiter = ThreadPool.RegisterWaitForSingleObject(show, (_, _) =>
                {
                    if (Volatile.Read(ref disposed) != 0 || Volatile.Read(ref windowClosed) != 0 || target.Dispatcher.HasShutdownStarted) return;
                    try
                    {
                        target.Dispatcher.BeginInvoke(DispatcherPriority.Normal, new Action(() =>
                        {
                            if (Volatile.Read(ref disposed) == 0 && Volatile.Read(ref windowClosed) == 0) restore();
                        }));
                    }
                    catch (InvalidOperationException) { }
                }, null, Timeout.Infinite, false);
            }
        }
        if (window is not null) throw new InvalidOperationException("This instance is already listening for a window.");
        window = target;
        loaded = (_, _) => StartListening();
        closed = (_, _) =>
        {
            Interlocked.Exchange(ref windowClosed, 1);
            StopListening();
        };
        target.Loaded += loaded;
        target.Closed += closed;
        if (target.IsLoaded) StartListening();
    }

    private void StopListening()
    {
        lock (gate)
        {
            waiter?.Unregister(null);
            waiter = null;
        }
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        StopListening();
        if (window is not null)
        {
            window.Loaded -= loaded;
            window.Closed -= closed;
            window = null;
        }
        if (OwnsWindow) mutex.ReleaseMutex();
        show.Dispose(); mutex.Dispose();
    }
}
