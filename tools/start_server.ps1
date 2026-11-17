# Start the Dragonwilds dedicated server (hidden window). Env vars set here are inherited
# by the server process and read by the DWCompanion mod.
# Runs the shipping exe directly from Win64 (as RSE-Server does); the RSDragonwildsServer.exe
# launcher only spawns it. The server writes its log to Saved\Logs\RSDragonwilds.log either way.
. "$PSScriptRoot\config.ps1"

# The hold file goes only once the new process exists: removed first, the watchdog saw "no server, no hold" in the gap
# and started a second server (2026-11-17 17:42Z); one exited, and the nav policy was written for its pid.
$hold = Join-Path $RepoRoot 'logs\server.stopped'
if (Get-ServerProcess) { Remove-Item $hold -ErrorAction SilentlyContinue; Write-Host 'Server already running.'; exit 0 }

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
if (-not $env:DW_SAY_MODE) { $env:DW_SAY_MODE = 'direct' }
# The only server this script starts is the local dev server; the bench fixtures/referee refuse without it.
$env:DW_SERVER_ROLE = 'dev'
# The dev server's on-demand chat (speech_direct) speaks as a TEST player, never as "Claude": the harness's
# test-player chat for the M1 sessions (tools/m1_session.py, Tester) and a watchdog restart keep the name.
# This script only ever starts the local dev server; Shockbyte is vanilla and never runs it.
if ($env:DW_SERVER_ROLE -eq 'dev' -and -not $env:DW_COMPANION_NAME) { $env:DW_COMPANION_NAME = 'Tester' }

$p = Start-Process -FilePath $ServerExe -WorkingDirectory $ServerWin64 -WindowStyle Hidden -PassThru
for ($i = 0; $i -lt 50 -and -not (Get-ServerProcess); $i++) { Start-Sleep -Milliseconds 200 }
Remove-Item $hold -ErrorAction SilentlyContinue
# the nav helper must be pointed at this new process, whoever started it (tools
av_reset.ps1)
Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'nav_reset.ps1') -WindowStyle Hidden | Out-Null
Write-Host "Started server pid $($p.Id) (build $(Get-ServerBuildId)). Log: $ServerLog"
