# Shared paths for the tools/ scripts. Dot-source it: . "$PSScriptRoot\config.ps1"
$RepoRoot      = Split-Path $PSScriptRoot -Parent
$ServerRoot    = if ($env:DW_SERVER_ROOT) { $env:DW_SERVER_ROOT } else { 'C:\GameServers\Dragonwilds' }
$ServerWin64   = Join-Path $ServerRoot 'RSDragonwilds\Binaries\Win64'
$ServerLauncher = Join-Path $ServerRoot 'RSDragonwildsServer.exe'
$ServerSaved   = Join-Path $ServerRoot 'RSDragonwilds\Saved'
$ServerLog     = Join-Path $ServerSaved 'Logs\RSDragonwilds.log'
$BackupRoot    = Join-Path (Split-Path $ServerRoot -Parent) 'backups'
$ModName       = 'DWCompanion'
$ModDeployDir  = Join-Path $ServerWin64 "ue4ss\Mods\$ModName"
$ModLogDir     = Join-Path $RepoRoot 'logs\mod'
$BridgeDir     = Join-Path $RepoRoot 'bridge_io'
$AppId         = 4019830

function Get-SteamCmd {
    $c = Get-Command steamcmd -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $fallback = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\steamcmd.exe'
    if (Test-Path $fallback) { return $fallback }
    throw 'steamcmd not found (winget install Valve.SteamCMD)'
}

function Get-ServerBuildId {
    $acf = Join-Path $ServerRoot "steamapps\appmanifest_$AppId.acf"
    if (Test-Path $acf) { (Select-String -Path $acf -Pattern '"buildid"\s+"(\d+)"').Matches[0].Groups[1].Value }
}

function Get-ServerProcess { Get-Process 'RSDragonwildsServer*' -ErrorAction SilentlyContinue }
