using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Windowing;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;
using Windows.Graphics;

namespace CodexBar.Tray;

internal sealed class NotificationDelivery : IDisposable
{
    private readonly Window owner;
    private readonly Action open;
    private bool registered;
    private AlertWindow? overlay;
    public string Status { get; private set; } = "Windows notifications are not registered.";
    public NotificationDelivery(Window owner, Action open)
    {
        this.owner = owner; this.open = open;
        try
        {
            AppNotificationManager.Default.NotificationInvoked += Invoked;
            AppNotificationManager.Default.Register();
            registered = true; Status = "Windows notifications are ready.";
        }
        catch (Exception) { Status = "Windows notifications are unavailable. Check Windows notification settings and run CodexBar without administrator elevation."; }
    }
    private void Invoked(AppNotificationManager sender, AppNotificationActivatedEventArgs args) => owner.DispatcherQueue.TryEnqueue(() => open());
    public string Send(QuotaAlert alert, NotificationOptions options)
    {
        if (registered)
        {
            try
            {
                var builder = new AppNotificationBuilder().AddText(alert.Title).AddText(alert.Message);
                if (alert.Warning && !options.Sound) builder.MuteAudio();
                AppNotificationManager.Default.Show(builder.BuildNotification());
                Status = "Notification sent to Windows. Visibility and sound follow your Windows notification settings.";
            }
            catch (Exception) { Status = "Windows could not show the notification. Check Windows notification settings."; }
        }
        if (alert.Warning && options.OnScreen)
        {
            overlay?.Close(); overlay = new AlertWindow(owner, alert.Title, alert.Message);
            var current = overlay; current.Closed += (_, _) => { if (overlay == current) overlay = null; };
            current.ShowWithoutFocus();
        }
        return Status;
    }
    public void Dispose()
    {
        overlay?.Close();
        AppNotificationManager.Default.NotificationInvoked -= Invoked;
        if (registered) { AppNotificationManager.Default.Unregister(); registered = false; }
    }
}

// Like the Mac warning overlay: transient, centered and nonactivating.
internal sealed class AlertWindow : Window
{
    private readonly Microsoft.UI.Xaml.DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(4.5) };
    public AlertWindow(Window owner, string title, string message)
    {
        Title = "CodexBar notification";
        var panel = new StackPanel { Spacing = 12 };
        panel.Children.Add(Theme.Text(title, 18, true)); panel.Children.Add(Theme.Text(message, 14));
        Content = new Border { Child = panel, Padding = new(24), Background = Theme.Brush("102630"), BorderBrush = Theme.Accent, BorderThickness = new(1), RequestedTheme = ElementTheme.Dark };
        ((OverlappedPresenter)AppWindow.Presenter).SetBorderAndTitleBar(false, false);
        AppWindow.IsShownInSwitchers = false;
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        SetWindowLongPtr(hwnd, -20, (nint)((long)GetWindowLongPtr(hwnd, -20) | 0x08000020L));
        var scale = GetDpiForWindow(hwnd) / 96.0;
        var width = (int)(440 * scale); var height = (int)(150 * scale);
        var area = DisplayArea.GetFromWindowId(owner.AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        AppWindow.Resize(new SizeInt32(width, height));
        AppWindow.Move(new PointInt32(area.X + (area.Width - width) / 2, area.Y + (area.Height - height) / 2));
        timer.Tick += (_, _) => Close(); Closed += (_, _) => timer.Stop();
    }
    public void ShowWithoutFocus()
    {
        AppWindow.Show(false);
        SetWindowPos(WinRT.Interop.WindowNative.GetWindowHandle(this), (nint)(-1), 0, 0, 0, 0, 0x13);
        timer.Start();
    }
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(nint window);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern nint GetWindowLongPtr(nint window, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] private static extern nint SetWindowLongPtr(nint window, int index, nint value);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(nint window, nint after, int x, int y, int width, int height, uint flags);
}
