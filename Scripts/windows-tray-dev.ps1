param([switch]$Test, [switch]$Launch, [switch]$InstallTools)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)

# Reuse the installed MSVC toolchain without changing persistent environment settings.
if (!(Get-Command rc.exe -ErrorAction SilentlyContinue)) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    $installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (!$installation -and $InstallTools) {
        winget install --id Microsoft.VisualStudio.2022.BuildTools -e --source winget `
            --override '--wait --passive --add Microsoft.VisualStudio.Component.Windows11SDK.22621 --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64'
        if ($LASTEXITCODE -ne 0) { throw 'Visual Studio build tools installation did not complete.' }
        $installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    }
    if (!$installation) { throw 'Install the Visual Studio C++ x64 build tools and Windows SDK first.' }
    $developerShell = Join-Path $installation 'Common7/Tools/Launch-VsDevShell.ps1'
    & $developerShell -Arch amd64 -HostArch amd64 -SkipAutomaticLocation
}
foreach ($command in @('swiftc', 'rc.exe', 'link.exe')) {
    if (!(Get-Command $command -ErrorAction SilentlyContinue)) { throw "Missing build tool: $command" }
}

$output = Join-Path (Get-Location) '.build/windows-tray-dev'
New-Item -ItemType Directory -Force $output | Out-Null
& "$PSScriptRoot/build_windows_icon.ps1" -OutputDirectory $output
$executable = Join-Path $output 'tray-window.exe'
$timer = [Diagnostics.Stopwatch]::StartNew()
swiftc -swift-version 6 -parse-as-library `
    Sources/CodexBarWindowsTray/TraySnapshot.swift `
    Sources/CodexBarWindowsTray/TrayPresentationState.swift `
    Sources/CodexBarWindowsTray/TrayProviderConfiguration.swift `
    Sources/CodexBarWindowsTray/WindowsTrayDrawing.swift `
    Sources/CodexBarWindowsTray/WindowsTrayHost.swift `
    Tests/WindowsTraySmoke/TrayWindowSmoke.swift `
    -Xlinker User32.lib -Xlinker Gdi32.lib -Xlinker Shell32.lib -Xlinker Comctl32.lib -Xlinker UxTheme.lib `
    -Xlinker (Join-Path $output 'codexbar.res') `
    -Xlinker /SUBSYSTEM:WINDOWS -Xlinker /ENTRY:mainCRTStartup -o $executable
if ($LASTEXITCODE -ne 0) { throw 'Native tray compilation failed.' }
Write-Host ('Tray compiled in {0:N1}s: {1}' -f $timer.Elapsed.TotalSeconds, $executable)
if ($Test) {
    & "$PSScriptRoot/test_windows_tray.ps1" -Executable $executable -OutputDirectory "$output/preview"
    & "$PSScriptRoot/test_windows_tray.ps1" -Executable $executable -Overflow -OutputDirectory "$output/overflow"
}
if ($Launch) {
    Start-Process $executable -ArgumentList ('"' + (Resolve-Path 'Tests/WindowsTraySmoke/dashboard.json').Path + '"') `
        -RedirectStandardOutput (Join-Path $output 'launch-stdout.log') `
        -RedirectStandardError (Join-Path $output 'launch-stderr.log')
}
