# Start the Dragonwilds dedicated server (hidden window). Env vars set here are inherited
# by the server process and read by the DWCompanion mod.
# Runs the shipping exe directly from Win64 (as RSE-Server does); the RSDragonwildsServer.exe
# launcher only spawns it. The server writes its log to Saved\Logs\RSDragonwilds.log either way.
. "$PSScriptRoot\config.ps1"

Remove-Item (Join-Path $RepoRoot 'logs\server.stopped') -ErrorAction SilentlyContinue
if (Get-ServerProcess) { Write-Host 'Server already running.'; exit 0 }

New-Item -ItemType Directory -Force $ModLogDir, $BridgeDir, (Join-Path $RepoRoot 'logs\perf') | Out-Null
$env:DW_MOD_LOG_DIR = $ModLogDir
$env:DW_BRIDGE_DIR  = $BridgeDir
$env:DW_MOD_ROOT    = $ModDeployDir
# Repo root: the mod reads data catalogs from <repo>/data (e.g. spells_<build>.json; data/ isn't deployed).
$env:DW_REPO_ROOT   = $RepoRoot
# Bot gear/state must live outside the deployed mod folder (deploy_mod.ps1 wipes that folder).
$stateDir = Join-Path $RepoRoot 'logs\state'
New-Item -ItemType Directory -Force $stateDir | Out-Null
$env:DW_BOT_STATE   = Join-Path $stateDir 'bot_state.json'
$env:DW_HEARTBEAT_FILE = Join-Path $stateDir 'heartbeat.txt'
# Speech: hand-built Client_ReceiveChatMessage / Client_DisplayTextNotification froze Luis's client
# (2026-10-25). Default to log-only until a speech path is proven safe; override with DW_SAY_MODE.
if (-not $env:DW_SAY_MODE) { $env:DW_SAY_MODE = 'log' }

$p = Start-Process -FilePath $ServerExe -WorkingDirectory $ServerWin64 -WindowStyle Hidden -PassThru
Write-Host "Started server pid $($p.Id) (build $(Get-ServerBuildId)). Log: $ServerLog"
