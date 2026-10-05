# Run from an extracted Windows package. Uses only temporary config and disabled providers.
$ErrorActionPreference = 'Stop'
$appRoot = (Get-Location).Path
$exe = Join-Path $appRoot 'codexbar.exe'
$tray = Join-Path $appRoot 'CodexBarTray.exe'
$qa = Join-Path $env:TEMP ('codexbar-desktop-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $qa | Out-Null
$saved = @{}
$changes = @{
    CODEXBAR_CONFIG = (Join-Path $qa 'config.json')
    CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS = '1'
    CODEXBAR_TEST_CODEX_FILE_ISOLATION = '1'
    CODEXBAR_TEST_SESSION_FILE_ISOLATION = '1'
    PATH = "$env:SystemRoot/System32;$env:SystemRoot"
}
try {
    foreach ($key in $changes.Keys) {
        $saved[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, $changes[$key], 'Process')
    }
    Set-Content $env:CODEXBAR_CONFIG '{"version":1,"providers":[]}' -Encoding utf8NoBOM
    $raw = & $exe config dump --json
    if ($LASTEXITCODE -ne 0) { throw 'Config dump failed.' }
    $config = $raw | ConvertFrom-Json
    foreach ($provider in $config.providers) { $provider.enabled = $false }
    $config | ConvertTo-Json -Depth 32 | Set-Content $env:CODEXBAR_CONFIG -Encoding utf8NoBOM
    $raw = & $exe config providers --json
    if ($LASTEXITCODE -ne 0) { throw 'Provider config failed.' }
    $providers = @($raw | ConvertFrom-Json)
    if (!$providers.Count -or @($providers | Where-Object enabled).Count) { throw 'Providers are not all disabled.' }
    & $exe config validate
    if ($LASTEXITCODE -ne 0) { throw 'Config validation failed.' }
    $raw = & $exe dashboard --timeout 5
    if ($LASTEXITCODE -ne 0) { throw 'Dashboard failed.' }
    $dashboard = $raw | ConvertFrom-Json
    if ($dashboard.schemaVersion -ne 1 -or @($dashboard.providers).Count) { throw 'Unexpected dashboard.' }
    $raw | Set-Content (Join-Path $qa 'dashboard.json') -Encoding utf8NoBOM
    Write-Host 'Offline CLI dashboard and config checks passed with minimal PATH.'
    Write-Host "QA_ROOT=$qa"
    $process = Start-Process -FilePath $tray -WorkingDirectory $appRoot -PassThru
    Write-Host "TRAY_PID=$($process.Id)"
} finally {
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key], 'Process') }
}
