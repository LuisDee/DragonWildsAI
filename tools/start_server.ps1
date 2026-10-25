# Start the Dragonwilds dedicated server (hidden window). Env vars set here are inherited
# by the server process and read by the DWCompanion mod.
. "$PSScriptRoot\config.ps1"

if (Get-ServerProcess) { Write-Host 'Server already running.'; exit 0 }

New-Item -ItemType Directory -Force $ModLogDir, $BridgeDir | Out-Null
$env:DW_MOD_LOG_DIR = $ModLogDir
$env:DW_BRIDGE_DIR  = $BridgeDir

$p = Start-Process -FilePath $ServerLauncher -ArgumentList '-log' -WorkingDirectory $ServerRoot -WindowStyle Hidden -PassThru
Write-Host "Started launcher pid $($p.Id) (build $(Get-ServerBuildId)). Log: $ServerLog"
