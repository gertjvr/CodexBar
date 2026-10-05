param(
    [Parameter(Mandatory = $true)][string]$Executable,
    [string]$Fixture = "Tests/WindowsTraySmoke/dashboard.json",
    [string]$OutputDirectory = ".build/windows-tray-preview",
    [switch]$Packaged,
    [switch]$Overflow,
    [string]$CLIConfig
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;
public static class TrayPreviewNative {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    private struct GUITHREADINFO {
        public uint Size, Flags;
        public IntPtr Active, Focus, Capture, MenuOwner, MoveSize, Caret;
        public RECT CaretRect;
    }
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll")]
    private static extern bool GetGUIThreadInfo(uint thread, ref GUITHREADINFO info);
    [DllImport("user32.dll")]
    public static extern bool PostMessage(IntPtr window, uint message, UIntPtr word, IntPtr value);
    public static IntPtr FocusWindow(IntPtr window) {
        uint process;
        uint thread = GetWindowThreadProcessId(window, out process);
        var info = new GUITHREADINFO();
        info.Size = (uint)Marshal.SizeOf(typeof(GUITHREADINFO));
        return thread != 0 && GetGUIThreadInfo(thread, ref info) ? info.Focus : IntPtr.Zero;
    }
    private delegate bool EnumChildProc(IntPtr window, IntPtr data);
    [DllImport("user32.dll")]
    private static extern bool EnumChildWindows(IntPtr parent, EnumChildProc callback, IntPtr data);
    public static string[] ChildText(IntPtr parent) {
        var labels = new List<string>();
        EnumChildWindows(parent, (window, data) => {
            var text = new StringBuilder(1024);
            GetWindowText(window, text, text.Capacity);
            labels.Add(text.ToString());
            return true;
        }, IntPtr.Zero);
        return labels.ToArray();
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindow(string className, string title);
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr window, out RECT rect);
    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr window, IntPtr dc, uint flags);
    [DllImport("user32.dll")]
    public static extern IntPtr GetDlgItem(IntPtr window, int id);
    [DllImport("user32.dll")]
    public static extern bool IsWindowEnabled(IntPtr window);
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr window, StringBuilder text, int count);
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr window, uint message, UIntPtr word, IntPtr value);
}
'@
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$stdout = Join-Path $OutputDirectory "stdout.log"
$stderr = Join-Path $OutputDirectory "stderr.log"
$fixturePath = (Resolve-Path $Fixture).Path
if ($Overflow) {
    $expanded = Get-Content $fixturePath -Raw | ConvertFrom-Json
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($row in $expanded.providers) { $rows.Add($row) }
    foreach ($index in 1..200) {
        $row = $expanded.providers[0].PSObject.Copy()
        $row.id = "fixture-$index"
        $row.name = "Fixture $index"
        $rows.Add($row)
    }
    $expanded.providers = $rows.ToArray()
    $fixturePath = Join-Path (Resolve-Path $OutputDirectory).Path "overflow.json"
    $expanded | ConvertTo-Json -Depth 32 | Set-Content $fixturePath -Encoding utf8NoBOM
}
$arguments = '"' + $fixturePath + '"'
if ($Packaged) { $arguments = "--smoke-dashboard " + $arguments }
$savedEnvironment = @{}
try {
    if ($CLIConfig) {
        $arguments = "--smoke-cli"
        $fixtureEnvironment = @{
            CODEXBAR_CONFIG = (Resolve-Path $CLIConfig).Path
            CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS = "1"
            CODEXBAR_TEST_CODEX_FILE_ISOLATION = "1"
            CODEXBAR_TEST_SESSION_FILE_ISOLATION = "1"
        }
        foreach ($key in $fixtureEnvironment.Keys) {
            $savedEnvironment[$key] = [Environment]::GetEnvironmentVariable($key, "Process")
            [Environment]::SetEnvironmentVariable($key, $fixtureEnvironment[$key], "Process")
        }
    }
    $process = Start-Process -FilePath $Executable -ArgumentList $arguments `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
} finally {
    foreach ($key in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($key, $savedEnvironment[$key], "Process")
    }
}
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    $window = [IntPtr]::Zero
    $windowReady = $false
    while (!$windowReady -and [DateTime]::UtcNow -lt $deadline -and !$process.HasExited) {
        Start-Sleep -Milliseconds 100
        $window = [TrayPreviewNative]::FindWindow("CodexBar.WindowsTray", "CodexBar")
        # The HWND exists before render() has created its children. show() runs after initial rendering.
        $windowReady = $window -ne [IntPtr]::Zero -and [TrayPreviewNative]::IsWindowVisible($window) -and
            [TrayPreviewNative]::GetDlgItem($window, 11) -ne [IntPtr]::Zero
    }
    if (!$windowReady) { throw "Tray fixture did not finish rendering its window and footer. See stderr.log." }
    $panels = @("codex", "claude")
    if (!$Packaged) { $panels += "settings" }
    if ($CLIConfig) {
        $ready = [DateTime]::UtcNow.AddSeconds(15)
        do {
            Start-Sleep -Milliseconds 100
            $labels = [TrayPreviewNative]::ChildText($window)
        } while ($labels -notcontains "No providers enabled." -and [DateTime]::UtcNow -lt $ready -and !$process.HasExited)
        if ($labels -notcontains "No providers enabled.") {
            throw "Packaged tray did not display its companion CLI dashboard: $($labels -join '; ')"
        }
        Write-Host "Packaged tray refreshed through its companion CLI with every provider disabled."
        $panels = @("cli")
    }
    foreach ($provider in $panels) {
        if ($provider -eq "claude") {
            # WM_COMMAND for the second provider button, through the production window procedure.
            [TrayPreviewNative]::SendMessage($window, 0x0111, [UIntPtr]101, [IntPtr]::Zero) | Out-Null
        }
        if ($provider -eq "settings") {
            [TrayPreviewNative]::SendMessage($window, 0x0111, [UIntPtr]14, [IntPtr]::Zero) | Out-Null
            $ready = [DateTime]::UtcNow.AddSeconds(5)
            do {
                Start-Sleep -Milliseconds 100
                $toggle = [TrayPreviewNative]::GetDlgItem($window, 17)
            } while (![TrayPreviewNative]::IsWindowEnabled($toggle) -and [DateTime]::UtcNow -lt $ready)
            if (![TrayPreviewNative]::IsWindowEnabled($toggle)) { throw "Provider settings did not load." }
            [TrayPreviewNative]::SendMessage($window, 0x0111, [UIntPtr]17, [IntPtr]::Zero) | Out-Null
            $ready = [DateTime]::UtcNow.AddSeconds(5)
            do {
                Start-Sleep -Milliseconds 100
                $toggle = [TrayPreviewNative]::GetDlgItem($window, 17)
                $title = [Text.StringBuilder]::new(128)
                [TrayPreviewNative]::GetWindowText($toggle, $title, $title.Capacity) | Out-Null
            } while (($title.ToString() -ne "Enable provider") -and [DateTime]::UtcNow -lt $ready)
            if ($title.ToString() -ne "Enable provider") { throw "Provider toggle did not update its state." }
        }
        if ($Overflow -and $provider -ne "settings") {
            $before = New-Object TrayPreviewNative+RECT
            $bounds = New-Object TrayPreviewNative+RECT
            $quit = [TrayPreviewNative]::GetDlgItem($window, 11)
            if (![TrayPreviewNative]::GetWindowRect($quit, [ref]$before) -or
                ![TrayPreviewNative]::GetWindowRect($window, [ref]$bounds)) { throw "Missing overflow fixture bounds." }
            if ($before.Bottom -le $bounds.Bottom) { throw "Fixture did not create vertical overflow." }
            # WM_VSCROLL / SB_BOTTOM must bring the actual footer control into the visible window.
            [TrayPreviewNative]::SendMessage($window, 0x0115, [UIntPtr]7, [IntPtr]::Zero) | Out-Null
            $after = New-Object TrayPreviewNative+RECT
            if (![TrayPreviewNative]::GetWindowRect($quit, [ref]$after)) { throw "Missing scrolled footer." }
            if ($after.Top -lt $bounds.Top -or $after.Bottom -gt $bounds.Bottom) {
                throw "Scrolling did not make the footer reachable."
            }
            if ($provider -eq "codex") {
                [TrayPreviewNative]::SendMessage($window, 0x0115, [UIntPtr]6, [IntPtr]::Zero) | Out-Null
                # Queue Tab keys through the real message pump; inspect focus in the GUI's thread.
                $keyboardDeadline = [DateTime]::UtcNow.AddSeconds(8)
                foreach ($index in 1..260) {
                    $previousFocus = [TrayPreviewNative]::FocusWindow($window)
                    $keyTarget = if ($previousFocus -eq [IntPtr]::Zero) { $window } else { $previousFocus }
                    if (![TrayPreviewNative]::PostMessage($keyTarget, 0x0100, [UIntPtr]9, [IntPtr]1)) {
                        throw "Could not queue the Tab navigation fixture."
                    }
                    $focusDeadline = [DateTime]::UtcNow.AddMilliseconds(200)
                    do {
                        Start-Sleep -Milliseconds 10
                        $focused = [TrayPreviewNative]::FocusWindow($window)
                    } while ($focused -eq $previousFocus -and [DateTime]::UtcNow -lt $focusDeadline)
                    if ($focused -eq $quit -or [DateTime]::UtcNow -ge $keyboardDeadline) { break }
                }
                if ([TrayPreviewNative]::FocusWindow($window) -ne $quit) {
                    $title = [Text.StringBuilder]::new(128)
                    [TrayPreviewNative]::GetWindowText($focused, $title, $title.Capacity) | Out-Null
                    throw "Tab navigation did not reach Quit; focused control: $title"
                }
                # Focus changes inside IsDialogMessage before the host has moved every child window.
                # Wait for that same Tab dispatch to finish revealing the focused control.
                $revealDeadline = [DateTime]::UtcNow.AddSeconds(2)
                do {
                    $hasBounds = [TrayPreviewNative]::GetWindowRect($quit, [ref]$after)
                    $revealed = $hasBounds -and $after.Top -ge $bounds.Top -and $after.Bottom -le $bounds.Bottom
                    if (!$revealed) { Start-Sleep -Milliseconds 10 }
                } while (!$revealed -and [DateTime]::UtcNow -lt $revealDeadline)
                if (!$hasBounds -or
                    $after.Top -lt $bounds.Top -or $after.Bottom -gt $bounds.Bottom) {
                    throw "Keyboard focus moved to an off-screen footer."
                }
                Write-Host "Tab navigation revealed the focused footer in overflowing tray content."
            }
        }
        $rect = New-Object TrayPreviewNative+RECT
        if (![TrayPreviewNative]::GetWindowRect($window, [ref]$rect)) { throw "Cannot read tray bounds." }
        $bitmap = New-Object System.Drawing.Bitmap(($rect.Right - $rect.Left), ($rect.Bottom - $rect.Top))
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $dc = $graphics.GetHdc()
        try {
            if (![TrayPreviewNative]::PrintWindow($window, $dc, 0)) { throw "Cannot render tray preview." }
        } finally {
            $graphics.ReleaseHdc($dc)
            $graphics.Dispose()
        }
        try {
            $bitmap.Save((Join-Path (Resolve-Path $OutputDirectory).Path "$provider.png"))
        } finally {
            $bitmap.Dispose()
        }
    }
    # Exercise normal navigation and Quit; the fixture timer remains a fallback deadline.
    if (!$Packaged -and !$CLIConfig) { [TrayPreviewNative]::SendMessage($window, 0x0111, [UIntPtr]15, [IntPtr]::Zero) | Out-Null }
    [TrayPreviewNative]::SendMessage($window, 0x0111, [UIntPtr]11, [IntPtr]::Zero) | Out-Null
    if (!$process.WaitForExit(5000)) { throw "Tray fixture did not exit before its deadline." }
    if ($process.ExitCode -ne 0) { throw "Tray fixture exited with code $($process.ExitCode). See stderr.log." }
    Get-Content $stdout
} finally {
    if (!$process.HasExited) { $process.Kill(); $process.WaitForExit() }
    $process.Dispose()
}
