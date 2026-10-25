# Close Claude's game client (kills the process: there is no graceful quit from outside; the character
# is saved server-side). -Hold: also write logs\client.stopped so the client watchdog leaves it down
# (tools\client_boot.ps1 -Release clears it). Steam keeps running.
# Usage: powershell -File tools\stop_client.ps1 [-Hold]
param([switch]$Hold)
. "$PSScriptRoot\client_lib.ps1"

if ($Hold) { New-Item -ItemType File -Force $ClientHoldFile | Out-Null; Write-Host "Hold set: $ClientHoldFile" }
$tree = @(Get-ClientProcessTree)
if (-not $tree) { Write-Host 'Client not running.'; exit 0 }
$tree | Stop-Process -Force -ErrorAction SilentlyContinue
$tree | ForEach-Object { try { $_.WaitForExit(30000) | Out-Null } catch {} }
Write-Host "Stopped: $(($tree | ForEach-Object { "$($_.ProcessName)($($_.Id))" }) -join ', ')"
