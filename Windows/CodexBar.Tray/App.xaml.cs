using Microsoft.UI.Xaml;

namespace CodexBar.Tray;

public partial class App : Application
{
    private MenuWindow? window;
    private Mutex? instanceMutex;
    public App()
    {
        InitializeComponent();
        RequestedTheme = ApplicationTheme.Dark;
        UnhandledException += (_, e) => File.WriteAllText(Path.Combine(AppContext.BaseDirectory, "failure.log"), e.Exception.ToString());
    }
    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        instanceMutex = new Mutex(true, "Local\\CodexBar.WinUI", out var firstInstance);
        if (!firstInstance) { NativeTray.ShowExisting(); Exit(); return; }
        window = new MenuWindow(Environment.GetCommandLineArgs().Skip(1).ToArray());
        window.Closed += (_, _) => { instanceMutex.ReleaseMutex(); instanceMutex.Dispose(); };
        window.Activate();
    }
}
