namespace ProjectUai.Bridge;

// Named kernel objects can survive through updater/duplicate process handles even
// after the window owner exits. Their existence does not establish a live owner.
internal sealed class DesktopInstance : IDisposable
{
    private readonly Mutex mutex;
    private readonly EventWaitHandle show;
    private RegisteredWaitHandle? waiter;
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

    internal void Listen(Form form, Action restore)
    {
        // Start listening only when the window can accept BeginInvoke. Until then
        // AutoResetEvent retains the signal from an early duplicate launch.
        form.Shown += (_, _) =>
        {
            if (waiter is not null) return;
            waiter = ThreadPool.RegisterWaitForSingleObject(show, (_, _) =>
            {
                if (form.IsDisposed || !form.IsHandleCreated) return;
                try { form.BeginInvoke(restore); }
                catch (InvalidOperationException) { }
            }, null, Timeout.Infinite, false);
        };
    }

    public void Dispose()
    {
        waiter?.Unregister(null);
        if (OwnsWindow) mutex.ReleaseMutex();
        show.Dispose(); mutex.Dispose();
    }
}
