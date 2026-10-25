# Update the server via SteamCMD after a game patch (server and client builds must match).
# Stops the server, backs up Saved/ (worlds + config), updates, prints old/new build IDs.
# Then: record the build ID in docs/DISCOVERIES.md and run the smoke tests (CLAUDE.md section 8).
param([switch]$NoValidate)
. "$PSScriptRoot\config.ps1"

& "$PSScriptRoot\stop_server.ps1"

$old = Get-ServerBuildId
if (Test-Path $ServerSaved) {
    $dest = Join-Path $BackupRoot ("Saved_{0}_build{1}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $old)
    New-Item -ItemType Directory -Force $BackupRoot | Out-Null
    Copy-Item $ServerSaved $dest -Recurse
    Write-Host "Backed up Saved/ to $dest"
}

$steamArgs = @('+force_install_dir', $ServerRoot, '+login', 'anonymous', '+app_update', $AppId)
if (-not $NoValidate) { $steamArgs += 'validate' }
$steamArgs += '+quit'
$steamcmd = Get-SteamCmd
& $steamcmd @steamArgs
# SteamCMD exits 7 after self-updating without doing the app update; run once more if so.
if ($LASTEXITCODE -eq 7) { & $steamcmd @steamArgs }

$new = Get-ServerBuildId
Write-Host "Build: $old -> $new"
if ($old -ne $new) { Write-Host 'Build changed: redeploy UE4SS/mod if validate removed them, regenerate the dump, run smoke tests.' }
