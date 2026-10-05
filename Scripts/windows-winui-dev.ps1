param([string]$CLI, [switch]$Launch, [switch]$Live)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
$project = 'Windows/CodexBar.Tray/CodexBar.Tray.csproj'
$output = Join-Path (Get-Location) '.build/windows-winui'
$runningPath = Join-Path $output "CodexBar.Tray.exe"
Get-Process -Name CodexBar.Tray -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $runningPath } | Stop-Process
$timer = [Diagnostics.Stopwatch]::StartNew()
dotnet build $project -c Debug -p:Platform=x64 -o $output
if ($LASTEXITCODE -ne 0) { throw 'WinUI build failed.' }
Write-Host ('WinUI build completed in {0:N1}s' -f $timer.Elapsed.TotalSeconds)
if ($Launch) {
    if ($Live -and !$CLI) {
        $installed = Join-Path $env:LOCALAPPDATA 'Programs/CodexBar'
        $CLI = Get-ChildItem $installed -Filter codexbar.exe -Recurse | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
        if (!$CLI) { throw 'No installed companion CLI found. Pass -CLI with its path.' }
    }
    $arguments = @('--fixture')
    if ($CLI) { $arguments = @('--cli', ('"' + (Resolve-Path $CLI).Path + '"')) }
    $start = @{ FilePath = (Join-Path $output 'CodexBar.Tray.exe'); RedirectStandardOutput = (Join-Path $output 'stdout.log'); RedirectStandardError = (Join-Path $output 'stderr.log') }
    if ($arguments.Count) { $start.ArgumentList = $arguments -join ' ' }
    Start-Process @start
}
