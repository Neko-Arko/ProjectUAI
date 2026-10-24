using System.Windows.Input;

namespace ProjectUai.Bridge;

internal sealed class DesktopCommand(Action<object?> execute, Func<bool>? canExecute = null) : ICommand
{
    public event EventHandler? CanExecuteChanged;
    public bool CanExecute(object? parameter) => canExecute?.Invoke() ?? true;
    public void Execute(object? parameter) { if (CanExecute(parameter)) execute(parameter); }
    internal void Refresh() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);
}

internal sealed class AsyncDesktopCommand(Func<Task> execute, Func<bool> canExecute, Action<Exception> failed) : ICommand
{
    private bool running;
    public event EventHandler? CanExecuteChanged;
    public bool CanExecute(object? parameter) => !running && canExecute();
    public async void Execute(object? parameter)
    {
        if (!CanExecute(parameter)) return;
        running = true; Refresh();
        try { await execute(); }
        catch (OperationCanceledException) { }
        catch (Exception error) { failed(error); }
        finally { running = false; Refresh(); }
    }
    internal void Refresh() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);
}
