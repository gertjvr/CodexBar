# Run from an extracted package only after authorizing live Codex and Claude usage checks.
# Uses existing sign-ins and temporary provider configuration; never prints raw account data.
$ErrorActionPreference = 'Stop'
$appRoot = (Get-Location).Path
$exe = Join-Path $appRoot 'codexbar.exe'
$tray = Join-Path $appRoot 'CodexBarTray.exe'
$qa = Join-Path $env:TEMP ('codexbar-live-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $qa | Out-Null
$savedConfig = $env:CODEXBAR_CONFIG
try {
    $env:CODEXBAR_CONFIG = Join-Path $qa 'config.json'
    Set-Content $env:CODEXBAR_CONFIG '{"version":1,"providers":[]}' -Encoding utf8NoBOM
    $raw = & $exe config dump --json
    if ($LASTEXITCODE -ne 0) { throw 'Config dump failed.' }
    $config = $raw | ConvertFrom-Json
    foreach ($provider in $config.providers) {
        $provider.enabled = $provider.id -in @('codex', 'claude')
    }
    $config | ConvertTo-Json -Depth 32 | Set-Content $env:CODEXBAR_CONFIG -Encoding utf8NoBOM
    $raw = & $exe config providers --json
    if ($LASTEXITCODE -ne 0) { throw 'Provider configuration check failed.' }
    $enabled = @(($raw | ConvertFrom-Json) | Where-Object enabled)
    if ($enabled.Count -ne 2 -or @($enabled | Where-Object { $_.provider -notin @('codex', 'claude') }).Count) {
        throw 'Expected only Codex and Claude to be enabled.'
    }
    $raw = & $exe dashboard --timeout 30 --identity redacted
    if ($LASTEXITCODE -ne 0) { throw 'Live dashboard failed.' }
    $dashboard = $raw | ConvertFrom-Json
    if ($dashboard.schemaVersion -ne 1 -or @($dashboard.providers).Count -ne 2) {
        throw 'Unexpected dashboard schema or provider count.'
    }
    foreach ($provider in $dashboard.providers) {
        if ($provider.error) { throw "Live dashboard provider failed: $($provider.id) ($($provider.error.code))." }
        if (-not @($provider.windows).Count) { throw "No usage windows for $($provider.id)." }
        Write-Host "Live dashboard passed: $($provider.id), source=$($provider.source), windows=$(@($provider.windows).Count)"
    }
    $process = Start-Process -FilePath $tray -WorkingDirectory $appRoot -PassThru
    Write-Host "TRAY_PID=$($process.Id)"
} finally {
    $env:CODEXBAR_CONFIG = $savedConfig
}
