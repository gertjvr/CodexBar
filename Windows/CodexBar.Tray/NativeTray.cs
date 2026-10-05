using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;

namespace CodexBar.Tray;

internal sealed class NativeTray : IDisposable
{
    private const uint CallbackMessage = 0x8001;
    private readonly SubclassProc callback;
    private readonly Window window;
    private readonly Action open;
    private static readonly uint ShowMessage = RegisterWindowMessage("CodexBar.WinUI.Show");
    public static void ShowExisting() => PostMessage((nint)0xffff, ShowMessage, 0, 0);
    private readonly uint taskbarCreated = RegisterWindowMessage("TaskbarCreated");
    private NotifyIconData icon;
    private bool disposed;

    public NativeTray(Window window, Action open)
    {
        this.window = window;
        this.open = open;
        callback = Dispatch;
        icon = new NotifyIconData
        {
            Size = (uint)Marshal.SizeOf<NotifyIconData>(),
            Window = WinRT.Interop.WindowNative.GetWindowHandle(window),
            Id = 1,
            Flags = 1 | 2 | 4 | 128,
            Callback = CallbackMessage,
            Icon = LoadImage(0, Path.Combine(AppContext.BaseDirectory, "Assets", "codexbar.ico"), 1, 32, 32, 0x10),
            Tip = "CodexBar",
            Info = "",
            InfoTitle = "",
            Version = 4
        };
        var style = (long)GetWindowLongPtr(icon.Window, -16);
        SetWindowLongPtr(icon.Window, -16, (nint)(style & ~0x00C40000L));
        SetWindowPos(icon.Window, 0, 0, 0, 0, 0, 0x37);
        uint border = 0xFFFFFFFE, corners = 2, dark = 1;
        DwmSetWindowAttribute(icon.Window, 34, ref border, 4);
        DwmSetWindowAttribute(icon.Window, 33, ref corners, 4);
        DwmSetWindowAttribute(icon.Window, 20, ref dark, 4);
        if (icon.Icon == 0) throw new InvalidOperationException("Unable to load the CodexBar tray icon.");
        if (!SetWindowSubclass(icon.Window, callback, 1, 0))
        { DestroyIcon(icon.Icon); throw new InvalidOperationException("Unable to attach the notification icon."); }
        if (!Add()) { Dispose(); throw new InvalidOperationException("Unable to add the notification icon."); }
    }

    private bool Add()
    {
        if (!ShellNotifyIcon(0, ref icon)) return false;
        return ShellNotifyIcon(4, ref icon);
    }

    private nint Dispatch(nint hwnd, uint message, nuint wParam, nint lParam, nuint id, nuint data)
    {
        if (message == taskbarCreated) Add();
        if (message == ShowMessage) window.DispatcherQueue.TryEnqueue(() => { SetForegroundWindow(hwnd); open(); });
        if (message == CallbackMessage)
        {
            var notification = (uint)((long)lParam & 0xffff);
            if (notification is 0x400 or 0x401 or 0x7B)
                window.DispatcherQueue.TryEnqueue(() => { SetForegroundWindow(hwnd); open(); PostMessage(hwnd, 0, 0, 0); });
            return 0;
        }
        return DefSubclassProc(hwnd, message, wParam, lParam);
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        ShellNotifyIcon(2, ref icon);
        RemoveWindowSubclass(icon.Window, callback, 1);
        if (icon.Icon != 0) DestroyIcon(icon.Icon);
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyIconData
    {
        public uint Size;
        public nint Window;
        public uint Id, Flags, Callback;
        public nint Icon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Tip;
        public uint State, StateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Info;
        public uint Version;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string InfoTitle;
        public uint InfoFlags;
        public Guid Guid;
        public nint BalloonIcon;
    }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate nint SubclassProc(nint window, uint message, nuint wParam, nint lParam, nuint id, nuint data);
    [DllImport("shell32.dll", EntryPoint = "Shell_NotifyIconW", CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool ShellNotifyIcon(uint message, ref NotifyIconData data);
    [DllImport("comctl32.dll")][return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetWindowSubclass(nint window, SubclassProc callback, nuint id, nuint data);
    [DllImport("comctl32.dll")][return: MarshalAs(UnmanagedType.Bool)] private static extern bool RemoveWindowSubclass(nint window, SubclassProc callback, nuint id);
    [DllImport("comctl32.dll")] private static extern nint DefSubclassProc(nint window, uint message, nuint wParam, nint lParam);
    [DllImport("user32.dll", EntryPoint = "LoadImageW", CharSet = CharSet.Unicode)] private static extern nint LoadImage(nint instance, string name, uint type, int width, int height, uint flags);
    [DllImport("user32.dll")][return: MarshalAs(UnmanagedType.Bool)] private static extern bool DestroyIcon(nint icon);
    [DllImport("user32.dll", EntryPoint = "PostMessageW")][return: MarshalAs(UnmanagedType.Bool)] private static extern bool PostMessage(nint window, uint message, nuint wParam, nint lParam);
    [DllImport("user32.dll")][return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetForegroundWindow(nint window);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern nint GetWindowLongPtr(nint window, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] private static extern nint SetWindowLongPtr(nint window, int index, nint value);
    [DllImport("user32.dll")][return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetWindowPos(nint window, nint after, int x, int y, int width, int height, uint flags);
    [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(nint window, uint attribute, ref uint value, uint size);
    [DllImport("user32.dll", EntryPoint = "RegisterWindowMessageW", CharSet = CharSet.Unicode)] private static extern uint RegisterWindowMessage(string name);
}
