# Shared paths for the tools/ scripts. Dot-source it: . "$PSScriptRoot\config.ps1"
$RepoRoot      = Split-Path $PSScriptRoot -Parent   # code and data (this working tree)
# State that must be single per VM (one client, one dev server): logs\state, client_io, the hold files, the client's
# log archive. DW_LIVE_ROOT wins; else the MAIN working tree (git rev-parse --git-common-dir), so a script run from a
# worktree sees the live tree's lock and holds instead of empty ones of its own (incident 2026-11-18 06:48Z).
# brain/paths.py LIVE_ROOT is the Python side of the same rule.
function Get-LiveRoot([string]$Root) {
    if ($env:DW_LIVE_ROOT) { return $env:DW_LIVE_ROOT }
    try {
        $c = & git -C $Root rev-parse --path-format=absolute --git-common-dir 2>$null
        if ($LASTEXITCODE -eq 0 -and $c) {
            $c = [IO.Path]::GetFullPath(("$c").Trim())
            if ((Split-Path $c -Leaf) -eq '.git') { return (Split-Path $c -Parent) }
        }
    } catch { }
    $Root
}
$LiveRoot      = Get-LiveRoot $RepoRoot
$InWorktree    = ([IO.Path]::GetFullPath($RepoRoot).TrimEnd('\') -ne [IO.Path]::GetFullPath($LiveRoot).TrimEnd('\'))
# The guard on what launches or drives the live client or server (tools/live_guard.py has the same rules): refused
# under pytest unless the caller says the live part is faked (-Fake), and from a worktree unless DW_LIVE_OK=1.
function Get-LiveRefusal([string]$What, [switch]$Fake) {
    if ($Fake) { return $null }
    if ($env:PYTEST_CURRENT_TEST) {
        return "refused under pytest ($env:PYTEST_CURRENT_TEST): $What drives the live game; a test passes a fake for it"
    }
    if ($InWorktree -and $env:DW_LIVE_OK -ne '1') {
        return "refused: $What from the worktree $RepoRoot (the live tree is $LiveRoot, one client per VM); set DW_LIVE_OK=1 to drive the live client from here"
    }
    $null
}
function Assert-LiveAllowed([string]$What, [switch]$Fake) {
    $why = Get-LiveRefusal $What -Fake:$Fake
    if ($why) { Write-Host $why; exit 9 }
}
$ServerRoot    = if ($env:DW_SERVER_ROOT) { $env:DW_SERVER_ROOT } else { 'C:\GameServers\Dragonwilds' }
$ServerWin64   = Join-Path $ServerRoot 'RSDragonwilds\Binaries\Win64'
$ServerExe     = Join-Path $ServerWin64 'RSDragonwildsServer-Win64-Shipping.exe'
$ServerSaved   = Join-Path $ServerRoot 'RSDragonwilds\Saved'
$ServerLog     = Join-Path $ServerSaved 'Logs\RSDragonwilds.log'
$BackupRoot    = Join-Path (Split-Path $ServerRoot -Parent) 'backups'
$ModName       = 'DWCompanion'
$ModDeployDir  = Join-Path $ServerWin64 "ue4ss\Mods\$ModName"
$ModLogDir     = if ($env:DW_MOD_LOG_DIR) { $env:DW_MOD_LOG_DIR } else { Join-Path $LiveRoot 'logs\mod' }
$BridgeDir     = if ($env:DW_BRIDGE_DIR) { $env:DW_BRIDGE_DIR } else { Join-Path $LiveRoot 'bridge_io' }
# Claude's own game client (route R2): client_mod/scripts/client_bridge.lua serves this dir.
$ClientBridgeDir = if ($env:DW_CLIENT_BRIDGE_DIR) { $env:DW_CLIENT_BRIDGE_DIR } else { Join-Path $LiveRoot 'client_io/bridge' }
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

# A killed server stays in Get-Process with HasExited while any handle to it is open (2026-11-17: the watchdog took the
# stopped server for a hung one and restarted it), so only live processes count.
function Get-ServerProcess { Get-Process 'RSDragonwildsServer*' -ErrorAction SilentlyContinue | Where-Object { try { -not $_.HasExited } catch { $true } } }
