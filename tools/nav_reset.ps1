# After a server start, point the nav helper at the new server process and restart it (client_watchdog.ps1 starts it
# again; it reads the policy at start). Until then it stays "recovering: server_identity_changed" and every walk goes
# without navmesh routes (live 2026-11-02: go_to waited 40-60 s for 77 min; 2026-11-17 17:43-18:04Z: an L2 trial
# sprinted straight off a 37 m drop). start_server.ps1 runs this hidden after every start, so a manual start, a
# watchdog restart and a world restore all get it. Log: logs\watchdog.log.
. "$PSScriptRoot\config.ps1"
$logFile = Join-Path $RepoRoot 'logs\watchdog.log'
function Log($msg) { "$(Get-Date -Format o) $msg" | Add-Content -Encoding utf8 $logFile }
$python = Join-Path $RepoRoot '.venv\Scripts\python.exe'
$helpers = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'nav_oracle serve' })
$ok = $false; $proc = $null
for ($i = 0; $i -lt 24; $i++) { # the mod logs bridge_started a few seconds after the map loads
    Start-Sleep -Seconds 5
    # read each time: a second server started in a race exits within seconds (2026-11-17 17:43Z)
    $proc = Get-ServerProcess | Where-Object Name -like '*Shipping*' | Select-Object -First 1
    if (-not $proc) { continue }
    Push-Location $RepoRoot
    & $python -m tools.nav_oracle policy $proc.Id --retired @($helpers | ForEach-Object { $_.ProcessId }) *> $null
    $ok = $LASTEXITCODE -eq 0
    Pop-Location
    if ($ok) { break }
}
if ($ok) { $helpers | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } }
# Start the helper here: this stop is planned, and the watchdog's helper restarts are capped at 3 in 30 min (window
# 1118d: restarts at 01:37, 01:47 and 01:50Z, then the I4 window's preflight met a 90 s old heartbeat and skipped;
# the next restart came at 02:07Z). Its single-instance lock (client_io\nav\oracle.lock) lets a racing second
# start (the watchdog's) exit at once.
if ($ok) {
    Start-Sleep -Seconds 1
    $cmd = "`"$python`" -u -m tools.nav_oracle serve >> logs\nav_oracle.log 2>&1"
    Start-Process cmd.exe -ArgumentList '/c', $cmd -WorkingDirectory $RepoRoot -WindowStyle Hidden | Out-Null
}
Log "nav oracle policy for server pid $(if ($proc) { $proc.Id } else { '-' }): $(if ($ok) { 'written, helper restarted here' } else { 'NOT written' })"
