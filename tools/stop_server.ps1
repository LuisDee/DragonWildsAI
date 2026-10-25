# Stop the server. There is no RCON/graceful-shutdown command, so this kills the process;
# the server autosaves every ~5 minutes, so the last few minutes may be lost (dev world only).
# -Hold: also tell tools\watchdog.ps1 not to restart it (until start_server.ps1 runs).
param([switch]$Hold)
. "$PSScriptRoot\config.ps1"

if ($Hold) { New-Item -ItemType File -Force (Join-Path $RepoRoot 'logs\server.stopped') | Out-Null }

$procs = Get-ServerProcess
if (-not $procs) { Write-Host 'Server not running.'; exit 0 }
$procs | Stop-Process -Force
$procs | ForEach-Object { $_.WaitForExit(30000) | Out-Null }
Write-Host "Stopped: $($procs.Name -join ', ')"
