# Run from a checkout of gertjvr/CodexBar on windows-cli-actions.
$ErrorActionPreference = 'Stop'
$remote = git remote get-url origin
if ($LASTEXITCODE -ne 0 -or $remote -notmatch 'github.com[:/]gertjvr/CodexBar(?:\.git)?$') {
    throw 'Run this helper from the gertjvr/CodexBar fork checkout.'
}
git remote set-url origin https://github.com/gertjvr/CodexBar.git
if ($LASTEXITCODE -ne 0) { throw 'Could not select HTTPS for the public fork.' }
git pull --ff-only
if ($LASTEXITCODE -ne 0) { throw 'Could not update the fork checkout.' }
& ./Scripts/windows-tray-dev.ps1 -InstallTools -Test
