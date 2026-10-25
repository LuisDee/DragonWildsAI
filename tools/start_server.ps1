# Start the Dragonwilds dedicated server (hidden window). Env vars set here are inherited
# by the server process and read by the DWCompanion mod.
# Runs the shipping exe directly from Win64 (as RSE-Server does); the RSDragonwildsServer.exe
# launcher only spawns it. The server writes its log to Saved\Logs\RSDragonwilds.log either way.
. "$PSScriptRoot\config.ps1"

Remove-Item (Join-Path $RepoRoot 'logs\server.stopped') -ErrorAction SilentlyContinue
if (Get-ServerProcess) { Write-Host 'Server already running.'; exit 0 }

New-Item -ItemType Directory -Force $ModLogDir, $BridgeDir | Out-Null
$env:DW_MOD_LOG_DIR = $ModLogDir
$env:DW_BRIDGE_DIR  = $BridgeDir
$env:DW_MOD_ROOT    = $ModDeployDir

$p = Start-Process -FilePath $ServerExe -WorkingDirectory $ServerWin64 -WindowStyle Hidden -PassThru
Write-Host "Started server pid $($p.Id) (build $(Get-ServerBuildId)). Log: $ServerLog"
