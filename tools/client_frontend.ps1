# Front-end returns of the running client process (BUGS L24; client_lib.ps1 "front-end returns") as one JSON line:
#   {"pid":..,"returns":..,"log":..,"recorded":..,"max":2,"needs_relaunch":false}
# needs_relaunch = true: the next disconnect or rejoin must be a relaunch (tools/client_boot.ps1 does that itself).
# Used by tools/scenario_run.py (frontend_state) and the bench dev runner. Read-only except that it records a
# count the game log shows in logs/state/client_frontend_returns.json.
#   powershell -File tools\client_frontend.ps1
. "$PSScriptRoot\client_lib.ps1"
Get-FrontEndReturns | ConvertTo-Json -Compress
