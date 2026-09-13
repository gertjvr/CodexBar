param([switch]$TestPlugins)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path $PSScriptRoot -Parent
Set-Location $repoRoot
$logDirectory = Join-Path $repoRoot ".build/windows-logs"
New-Item -ItemType Directory -Force $logDirectory | Out-Null

function Invoke-LoggedCommand {
    param([string]$Name, [string]$Executable, [string[]]$CommandArguments)
    & $Executable @CommandArguments 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory "$Name.log")
    if ($LASTEXITCODE -ne 0) {
        throw "$Executable failed with exit code $LASTEXITCODE. See $Name.log."
    }
}

Invoke-LoggedCommand "toolchain" "swift" @("--version")

# Match the verified SQLite amalgamation already used by release-cli.yml.
$sqliteVersion = "3530300"
$sqliteChecksum = "d45c688a8cb23f68611a894a756a12d7eb6ab6e9e2468ca70adbeab3808b5ab9"
$sqliteDirectory = Join-Path $env:RUNNER_TEMP "codexbar-sqlite"
New-Item -ItemType Directory -Force $sqliteDirectory | Out-Null
$archive = Join-Path $sqliteDirectory "sqlite.zip"
Invoke-WebRequest "https://www.sqlite.org/2026/sqlite-amalgamation-$sqliteVersion.zip" -OutFile $archive
& python -c 'import hashlib, pathlib, sys; actual = hashlib.sha3_256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest(); assert actual == sys.argv[2], f"SQLite checksum mismatch: {actual}"' $archive $sqliteChecksum
if ($LASTEXITCODE -ne 0) { throw "SQLite checksum verification failed." }
Expand-Archive $archive -DestinationPath $sqliteDirectory -Force
$sqliteSource = Join-Path $sqliteDirectory "sqlite-amalgamation-$sqliteVersion"
$sqliteObject = Join-Path $sqliteDirectory "sqlite3.obj"
$sqliteLibrary = Join-Path $sqliteDirectory "sqlite3.lib"
Invoke-LoggedCommand "sqlite-compile" "cl.exe" @(
    "/nologo", "/O2", "/MD", "/DSQLITE_OMIT_LOAD_EXTENSION=1", "/c",
    (Join-Path $sqliteSource "sqlite3.c"), "/Fo$sqliteObject"
)
Invoke-LoggedCommand "sqlite-link" "lib.exe" @("/nologo", "/OUT:$sqliteLibrary", $sqliteObject)

$env:CODEXBAR_SQLITE3_LIB_DIR = $sqliteDirectory
Invoke-LoggedCommand "resolve" "swift" @("package", "resolve")
$buildArguments = @(
    "build", "-c", "release", "--product", "CodexBarCLI",
    # Swift 6.3.3's Windows LLVM asserts while optimizing dbg.assign fragment metadata.
    # Keep release optimization enabled; omit debug information from the packaged executable.
    "-Xswiftc", "-gnone",
    "-Xcc", "-I$sqliteSource", "-Xlinker", "/LIBPATH:$sqliteDirectory"
)
Invoke-LoggedCommand "build" "swift" $buildArguments
$binDirectory = & swift @buildArguments --show-bin-path
if ($LASTEXITCODE -ne 0) { throw "Could not resolve the CLI output directory." }
$binDirectory = ($binDirectory | Select-Object -Last 1).Trim()
if (-not (Test-Path (Join-Path $binDirectory "CodexBarCLI.exe"))) {
    throw "The build did not produce CodexBarCLI.exe."
}
if ($TestPlugins) {
    $testEnvironment = @{}
    try {
        foreach ($key in @("CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS", "CODEXBAR_TEST_CODEX_FILE_ISOLATION", "CODEXBAR_TEST_SESSION_FILE_ISOLATION")) {
            $testEnvironment[$key] = [Environment]::GetEnvironmentVariable($key, "Process")
            [Environment]::SetEnvironmentVariable($key, "1", "Process")
        }
        Invoke-LoggedCommand "plugin-tests" "swift" @(
            "test", "--filter", "CodexBarPluginTests",
            "-Xcc", "-I$sqliteSource", "-Xlinker", "/LIBPATH:$sqliteDirectory"
        )
        $testLog = Get-Content (Join-Path $logDirectory "plugin-tests.log") -Raw
        if ($testLog -notmatch 'Suite UserProviderPluginPortableTests passed' -or
            $testLog -notmatch 'Test run with [1-9][0-9]* tests? .*passed') {
            throw "Native plugin validation did not report a nonempty successful run and portable runtime suite."
        }
    } finally {
        foreach ($key in $testEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($key, $testEnvironment[$key], "Process")
        }
    }
}
"bin_dir=$binDirectory" >> $env:GITHUB_OUTPUT
