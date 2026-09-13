param([string]$CLI)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$output = Join-Path $repo '.build/windows-winui'
if (!(Test-Path (Join-Path $output 'CodexBar.Tray.exe'))) { throw 'Build the WinUI renderer first.' }
$base = Join-Path $env:LOCALAPPDATA 'Programs/CodexBar'
if (!$CLI) {
    $CLI = Get-ChildItem $base -Directory | Where-Object { $_.Name -like 'CodexBar-*' } |
        Get-ChildItem -Filter codexbar.exe | Sort-Object LastWriteTime -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}
if (!$CLI -or !(Test-Path $CLI)) { throw 'Pass the path to the verified companion CLI with -CLI.' }
$revision = (git -C $repo rev-parse --short=12 HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot identify the source revision.' }
$destination = Join-Path $base "WinUI-$revision"
if (Test-Path $destination) { throw 'This revision is already installed; use its existing shortcut or build a new revision.' }
New-Item -ItemType Directory -Path $destination | Out-Null
Copy-Item (Join-Path $output '*') $destination -Recurse
$companion = Join-Path $destination 'CLI'
New-Item -ItemType Directory -Path $companion | Out-Null
Copy-Item (Join-Path (Split-Path (Resolve-Path $CLI).Path -Parent) '*') $companion -Recurse
# Keep the installed Win32 tray shortcut available for comparison and rollback.
$shell = New-Object -ComObject WScript.Shell
foreach ($folder in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) {
    $shortcut = $shell.CreateShortcut((Join-Path $folder 'CodexBar WinUI.lnk'))
    $shortcut.TargetPath = Join-Path $destination 'CodexBar.Tray.exe'
    $shortcut.WorkingDirectory = $destination
    $shortcut.IconLocation = Join-Path $destination 'Assets/codexbar.ico'
    $shortcut.Save()
}
Get-Process -Name CodexBar.Tray -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq (Join-Path $output 'CodexBar.Tray.exe') -or $_.Path.StartsWith((Join-Path $base 'WinUI-')) } | Stop-Process
Start-Process (Join-Path $destination 'CodexBar.Tray.exe')
Write-Host "Installed CodexBar WinUI revision $revision with its companion CLI."
