param(
    [Parameter(Mandatory)][string]$BinDirectory,
    [Parameter(Mandatory)][ValidatePattern('^[0-9A-Za-z._-]+$')][string]$Version
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$repoRoot = Split-Path $PSScriptRoot -Parent
$stage = Join-Path $env:RUNNER_TEMP "codexbar-windows-package café 测试"
New-Item -ItemType Directory $stage | Out-Null
Copy-Item (Join-Path $BinDirectory "CodexBarCLI.exe") (Join-Path $stage "codexbar.exe")
Set-Content (Join-Path $stage "VERSION") $Version -Encoding utf8NoBOM
Copy-Item (Join-Path $repoRoot "LICENSE") $stage

$resourceCandidates = @(
    (Join-Path $BinDirectory "CodexBar_CodexBarCore.bundle"),
    (Join-Path $BinDirectory "CodexBar_CodexBarCore.resources")
)
$resources = $resourceCandidates | Where-Object { Test-Path $_ -PathType Container } | Select-Object -First 1
if (-not $resources) { throw "The CodexBarCore resource bundle is missing." }
Copy-Item $resources (Join-Path $stage "CodexBar_CodexBarCore.bundle") -Recurse

# Resolve the executable's actual DLL closure, including the Swift runtime and CRT.
# System DLLs remain supplied by Windows; VC runtime DLLs must travel with the ZIP.
$searchDirectories = @($BinDirectory) + @($env:PATH -split ";" | Where-Object { $_ -and (Test-Path $_) })
if ($env:VCToolsRedistDir) {
    $searchDirectories += @(Get-ChildItem (Join-Path $env:VCToolsRedistDir "x64") -Directory -Filter "Microsoft.VC*.CRT" | ForEach-Object FullName)
}
$pending = [Collections.Generic.Queue[string]]::new()
$pending.Enqueue((Join-Path $stage "codexbar.exe"))
$visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
while ($pending.Count -gt 0) {
    $binary = $pending.Dequeue()
    $imports = & dumpbin.exe /NOLOGO /DEPENDENTS $binary
    if ($LASTEXITCODE -ne 0) {
        throw "Cannot inspect DLL dependencies of $binary (exit $LASTEXITCODE): $($imports -join [Environment]::NewLine)"
    }
    foreach ($line in $imports) {
        if ($line -notmatch '^\s+([A-Za-z0-9_.-]+\.dll)\s*$') { continue }
        $dll = $Matches[1]
        if (-not $visited.Add($dll)) { continue }
        if ($dll -match '^(api-ms-|ext-ms-)') { continue }
        $systemDLL = Join-Path $env:SystemRoot "System32/$dll"
        $isVCRuntime = $dll -match '^(vcruntime|msvcp|concrt|vcomp)\d'
        if ((Test-Path $systemDLL) -and -not $isVCRuntime) { continue }
        $source = $searchDirectories | ForEach-Object { Join-Path $_ $dll } |
            Where-Object { Test-Path $_ -PathType Leaf } | Select-Object -First 1
        if (-not $source -and $isVCRuntime -and (Test-Path $systemDLL)) { $source = $systemDLL }
        if (-not $source) { throw "Cannot locate required runtime DLL: $dll" }
        $destination = Join-Path $stage $dll
        Copy-Item $source $destination
        $pending.Enqueue($destination)
    }
}

# Keep dependency licenses with the redistributed runtime and bundled sources.
$licenses = Join-Path $stage "licenses"
New-Item -ItemType Directory $licenses | Out-Null
Copy-Item (Join-Path $repoRoot "Sources/CQuickJS/LICENSE") (Join-Path $licenses "QuickJS.txt")
Get-ChildItem (Join-Path $repoRoot ".build/checkouts") -Directory | ForEach-Object {
    $dependency = $_
    Get-ChildItem $dependency.FullName -File -Filter "LICENSE*" | ForEach-Object {
        Copy-Item $_.FullName (Join-Path $licenses "$($dependency.Name)-$($_.Name)")
    }
}

$fixtureRoot = Join-Path $env:RUNNER_TEMP "codexbar-cli-fixture-$([Guid]::NewGuid())"
New-Item -ItemType Directory $fixtureRoot | Out-Null
$smokeConfig = Join-Path $fixtureRoot "config.json"
$disabledConfig = Join-Path $fixtureRoot "disabled.json"
$dashboardOutput = Join-Path $fixtureRoot "dashboard café 测试.json"
Set-Content $smokeConfig '{"version":1,"providers":[{"id":"codex","enabled":false,"apiKey":"offline-fixture-key"}]}' -Encoding utf8NoBOM

function Invoke-PackagedSmoke {
    param(
        [string[]]$CommandArguments,
        [string]$Expected = "",
        [int]$ExpectedExitCode = 0,
        [string]$ConfigPath = $smokeConfig,
        [scriptblock]$ValidateOutput,
        [hashtable]$FixtureEnvironment = @{},
        [switch]$Resources
    )
    $info = [Diagnostics.ProcessStartInfo]::new((Join-Path $stage "codexbar.exe"))
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.WorkingDirectory = $stage
    $info.Environment["PATH"] = "$env:SystemRoot\System32;$env:SystemRoot"
    $info.Environment["CODEXBAR_CONFIG"] = $ConfigPath
    $info.Environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] = "1"
    $info.Environment["CODEXBAR_TEST_CODEX_FILE_ISOLATION"] = "1"
    $info.Environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] = "1"
    foreach ($key in $FixtureEnvironment.Keys) { $info.Environment[$key] = $FixtureEnvironment[$key] }
    if ($Resources) { $info.Environment["CODEXBAR_RESOURCE_SMOKE"] = "1" }
    foreach ($argument in $CommandArguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($info)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(20000)) {
        $process.Kill($true)
        throw "Packaged CLI smoke test timed out."
    }
    $output = $stdout.GetAwaiter().GetResult()
    $errors = $stderr.GetAwaiter().GetResult()
    if ($process.ExitCode -ne $ExpectedExitCode -or -not $output.Contains($Expected)) {
        throw "Packaged CLI smoke test failed: $output $errors"
    }
    $process.Dispose()
    if ($ValidateOutput) { & $ValidateOutput $output $errors }
}

function Assert-DashboardFixture {
    param([string]$OutputJSON)
    $snapshot = ConvertFrom-Json -InputObject $OutputJSON
    if ($snapshot.schemaVersion -ne 1 -or $snapshot.host.codexBarVersion -ne $Version) {
        throw "Packaged dashboard schema or version changed."
    }
    if ($snapshot.providers -isnot [Array] -or $snapshot.providers.Count -ne 0) {
        throw "Packaged dashboard fetched providers despite the disabled fixture configuration."
    }
}

# Prevent a source-tree fallback from hiding a broken packaged resource layout.
$hiddenResources = "$resources.package-smoke-hidden"
Move-Item $resources $hiddenResources
try {
    Invoke-PackagedSmoke -CommandArguments @("--version") -Expected "CodexBar $Version"
    Invoke-PackagedSmoke -CommandArguments @("--help") -Expected "codexbar"
    Invoke-PackagedSmoke -CommandArguments @() -Expected "CODEXBAR_RESOURCE_SMOKE_OK" -Resources
    foreach ($command in @("usage", "cards", "cost", "dashboard", "serve", "config", "hooks", "guard", "sessions", "diagnose", "cookie", "cache", "plugins")) {
        Invoke-PackagedSmoke -CommandArguments @($command, "--help") -Expected "codexbar"
    }
    Invoke-PackagedSmoke -CommandArguments @("config", "validate", "--json") -ValidateOutput {
        param($output)
        $issues = ConvertFrom-Json -InputObject $output -NoEnumerate
        if ($issues -isnot [Array] -or $issues.Count -ne 0) { throw "Synthetic config did not validate cleanly." }
    }
    Invoke-PackagedSmoke -CommandArguments @("config", "providers", "--json") -ValidateOutput {
        param($output)
        $providers = ConvertFrom-Json -InputObject $output -NoEnumerate
        $codex = @($providers | Where-Object provider -EQ "codex")
        if ($providers -isnot [Array] -or $codex.Count -ne 1 -or $codex[0].enabled -ne $false -or !$codex[0].displayName) {
            throw "Provider settings JSON lost provider identity or enablement."
        }
    }
    foreach ($toggle in @("enable", "disable")) {
        $expectedEnabled = $toggle -eq "enable"
        Invoke-PackagedSmoke -CommandArguments @("config", $toggle, "--provider", "codex", "--json") -ValidateOutput {
            param($output)
            $result = ConvertFrom-Json -InputObject $output
            if ($result.provider -ne "codex" -or $result.enabled -ne $expectedEnabled) {
                throw "Provider toggle response disagrees with the requested setting."
            }
            $saved = Get-Content $smokeConfig -Raw | ConvertFrom-Json
            $codex = @($saved.providers | Where-Object id -EQ "codex")
            if ($codex.Count -ne 1 -or $codex[0].enabled -ne $expectedEnabled -or $codex[0].apiKey -ne "offline-fixture-key") {
                throw "Provider toggle did not persist, or changed unrelated credential configuration."
            }
        }
    }
    Invoke-PackagedSmoke -CommandArguments @("config", "dump", "--json") -ValidateOutput {
        param($output)
        $config = ConvertFrom-Json -InputObject $output
        $codex = @($config.providers | Where-Object id -EQ "codex")
        if ($config.version -ne 1 -or $codex.Count -ne 1 -or $codex[0].enabled -ne $false -or $codex[0].apiKey -ne "[REDACTED]") {
            throw "Packaged config dump lost enablement, schema, or secret redaction."
        }
        if ($output.Contains("offline-fixture-key")) { throw "Packaged config dump exposed the fixture secret." }
        foreach ($provider in $config.providers) { $provider.enabled = $false }
        ConvertTo-Json -InputObject $config -Depth 32 | Set-Content $disabledConfig -Encoding utf8NoBOM
    }
    Invoke-PackagedSmoke -CommandArguments @("usage", "--definitely-unknown-option", "--json") -ExpectedExitCode 1 -ValidateOutput {
        param($output)
        $errors = ConvertFrom-Json -InputObject $output -NoEnumerate
        if ($errors -isnot [Array] -or $errors.Count -ne 1 -or $errors[0].provider -ne "cli" -or $errors[0].error.kind -ne "args" -or $errors[0].error.code -ne 1) {
            throw "Packaged CLI argument-error JSON or exit status changed."
        }
    }
    Invoke-PackagedSmoke -CommandArguments @("dashboard", "--timeout", "5") -ConfigPath $disabledConfig -ValidateOutput {
        param($output)
        Assert-DashboardFixture $output
    }
    Invoke-PackagedSmoke -CommandArguments @("dashboard", "--timeout", "5", "--output", $dashboardOutput) -ConfigPath $disabledConfig -ValidateOutput {
        param($output)
        if ($output.Trim()) { throw "Dashboard --output unexpectedly wrote to stdout." }
        Assert-DashboardFixture (Get-Content $dashboardOutput -Raw)
    }
    # Exercise the production provider path through a synthetic Codex app-server and CMD shim.
    # Python is runner tooling only: it is neither copied into nor required by the package.
    $python = (Get-Command python.exe -ErrorAction Stop).Source
    $rpcFixture = Join-Path $repoRoot "Scripts/fixtures/codex_rpc.py"
    $rpcShim = Join-Path $fixtureRoot "codex café 测试.cmd"
    $rpcLog = Join-Path $fixtureRoot "rpc.log"
    $rpcConfig = Join-Path $fixtureRoot "rpc.json"
    Set-Content $rpcShim ('@"' + $python + '" -I "' + $rpcFixture + '" %*') -Encoding utf8NoBOM
    Set-Content $rpcConfig '{"version":1,"providers":[{"id":"codex","enabled":true}]}' -Encoding utf8NoBOM
    Invoke-PackagedSmoke -CommandArguments @("usage", "--provider", "codex", "--source", "cli", "--json") `
        -ConfigPath $rpcConfig -FixtureEnvironment @{
            CODEX_CLI_PATH = $rpcShim
            CODEX_HOME = (Join-Path $fixtureRoot "codex-home")
            CODEXBAR_RPC_FIXTURE_LOG = $rpcLog
        } -ValidateOutput {
            param($output)
            $rows = ConvertFrom-Json -InputObject $output -NoEnumerate
            if ($rows -isnot [Array] -or $rows.Count -ne 1) { throw "Codex fixture JSON envelope changed." }
            $row = $rows[0]
            if ($row.provider -ne "codex" -or $row.source -ne "codex-cli" -or
                $row.usage.primary.usedPercent -ne 24 -or $row.usage.primary.windowMinutes -ne 300 -or
                $row.usage.secondary.usedPercent -ne 38 -or $row.usage.secondary.windowMinutes -ne 10080 -or
                $row.usage.identity.accountEmail -ne "codex@example.test" -or
                $row.usage.identity.providerID -ne "codex" -or $row.usage.identity.loginMethod -ne "plus" -or
                $row.credits.remaining -ne 18.75) { throw "Packaged Codex provider results differ from the RPC fixture." }
        }
    $requests = @(Get-Content $rpcLog)
    if (($requests -join ",") -ne "initialize,initialized,account/rateLimits/read,account/read") {
        throw "Packaged Codex did not follow the expected app-server request sequence."
    }
    Write-Host "Packaged Codex CLI provider passed synthetic RPC, identity, limits, and credits checks."
} finally {
    Move-Item $hiddenResources $resources
    Remove-Item $fixtureRoot -Recurse -Force
}

$assetName = "CodexBarCLI"
$asset = Join-Path $env:RUNNER_TEMP "$assetName-$Version-windows-x86_64.zip"
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $asset
$hash = (Get-FileHash $asset -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content "$asset.sha256" "$hash  $([IO.Path]::GetFileName($asset))" -Encoding ascii
"asset=$asset" >> $env:GITHUB_OUTPUT
