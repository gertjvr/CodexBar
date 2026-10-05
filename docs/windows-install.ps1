# Install a packaged Windows tray ZIP for the current user, without administrator rights.
param([Parameter(Mandatory = $true)][string]$Archive)
$ErrorActionPreference = 'Stop'
$archivePath = (Resolve-Path -LiteralPath $Archive).Path
$expected = ((Get-Content -LiteralPath ($archivePath + '.sha256') -Raw).Trim() -split '\s+')[0]
$actual = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
if ($expected -notmatch '^[a-fA-F0-9]{64}$' -or $actual -ne $expected) {
    throw 'Package checksum does not match.'
}
$version = [IO.Path]::GetFileNameWithoutExtension($archivePath)
$installRoot = Join-Path $env:LOCALAPPDATA 'Programs/CodexBar'
$destination = Join-Path $installRoot $version
if (Test-Path -LiteralPath $destination) { throw "Installation directory already exists: $destination" }
New-Item -ItemType Directory -Path $destination -Force | Out-Null
Expand-Archive -LiteralPath $archivePath -DestinationPath $destination
$tray = Join-Path $destination 'CodexBarTray.exe'
$cli = Join-Path $destination 'codexbar.exe'
foreach ($file in @($tray, $cli)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Package is missing $file" }
}
& $cli --version
if ($LASTEXITCODE -ne 0) { throw 'Installed CLI startup failed.' }
$shell = New-Object -ComObject WScript.Shell
foreach ($folder in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) {
    $shortcutPath = Join-Path $folder 'CodexBar.lnk'
    if (Test-Path -LiteralPath $shortcutPath) {
        Copy-Item -LiteralPath $shortcutPath -Destination ($shortcutPath + '.' + [guid]::NewGuid().ToString('N') + '.bak')
    }
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $tray
    $shortcut.WorkingDirectory = $destination
    $shortcut.IconLocation = "$tray,0"
    $shortcut.Description = 'CodexBar provider usage'
    $shortcut.Save()
    if (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) { throw 'Shortcut creation failed.' }
}
Write-Host "Installed: $destination"
Write-Host 'Desktop and Start menu shortcuts created. Launch CodexBar to open its tray icon.'
