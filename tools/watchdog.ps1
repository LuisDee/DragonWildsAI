# Keep the dev server up. UE4SS's crash handler writes crash_*.dmp and then blocks on a
# MessageBox nobody can see (UE4SS CrashDumper.cpp: no setting skips it), so a crash looks like a
# hang. This loop turns that into fail-fast: new dump -> kill -> restart. Also restarts the server
# if the process is gone. Log: logs\watchdog.log. Run hidden: tools\start_watchdog.ps1.
param([int]$PollSeconds = 5)
. "$PSScriptRoot\config.ps1"

$logFile = Join-Path $RepoRoot 'logs\watchdog.log'
$dumpDir = Join-Path $ServerWin64 'ue4ss'
function Log($msg) { "$(Get-Date -Format o) $msg" | Add-Content -Encoding utf8 $logFile }

# After a restart the nav helper stays "recovering: server_identity_changed" until its recovery policy names the new
# server process (live 2026-11-02: every go_to waited 40-60 s for 77 min). Write it once the new bridge has started, then
# stop the helper: client_watchdog.ps1 restarts it, and it reads the policy at start.
function Reset-NavOracle {
    $proc = Get-ServerProcess | Where-Object Name -like '*Shipping*' | Select-Object -First 1
    if (-not $proc) { return }
    $python = Join-Path $RepoRoot '.venv\Scripts\python.exe'
    $helpers = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'nav_oracle serve' })
    for ($i = 0; $i -lt 24; $i++) { # the mod logs bridge_started a few seconds after the map loads
        Start-Sleep -Seconds 5
        Push-Location $RepoRoot
        & $python -m tools.nav_oracle policy $proc.Id --retired @($helpers | ForEach-Object { $_.ProcessId }) *> $null
        $ok = $LASTEXITCODE -eq 0
        Pop-Location
        if ($ok) { break }
    }
    $helpers | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Log "nav oracle policy for server pid $($proc.Id): $(if ($ok) { 'written, helper restarted' } else { 'NOT written' })"
}
function Get-LatestDump { Get-ChildItem $dumpDir -Filter 'crash_*.dmp' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1 }

$seen = (Get-LatestDump).FullName
Log "watchdog started (poll ${PollSeconds}s), last dump: $seen"
$hold = Join-Path $RepoRoot 'logs\server.stopped'
while ($true) {
    Start-Sleep -Seconds $PollSeconds
    # stopped on purpose (stop_server.ps1 -Hold): no branch restarts it, the hang one included. On 2026-11-17 the hang
    # branch restarted a server stopped for a world snapshot, and start_server.ps1 removed the hold file.
    if (Test-Path $hold) { continue }
    $dump = Get-LatestDump
    if ($dump -and $dump.FullName -ne $seen -and (Get-Item $dump.FullName).Length -gt 0) {
        Start-Sleep -Seconds 3 # let the dump finish writing
        $seen = $dump.FullName
        Log "crash dump $($dump.Name): killing hung server and restarting"
        & "$PSScriptRoot\stop_server.ps1" | Out-Null
        & "$PSScriptRoot\start_server.ps1" | ForEach-Object { Log $_ }; Reset-NavOracle
        continue
    }
    # Game-thread hang with no crash dump: the mod's heartbeat (written every 10 s from the game
    # thread) goes stale. Grace period after start for loading. Capture stacks, then restart.
    $hb = Join-Path $RepoRoot 'logs\state\heartbeat.txt'
    $proc = Get-ServerProcess | Where-Object Name -like '*Shipping*' | Select-Object -First 1
    if ($proc -and (Test-Path $hb) -and ((Get-Date) - $proc.StartTime).TotalSeconds -gt 180) {
        $age = ((Get-Date) - (Get-Item $hb).LastWriteTime).TotalSeconds
        if ($age -gt 60 -and (Get-Item $hb).LastWriteTime -gt $proc.StartTime) {
            Log "heartbeat stale (${age}s): capturing stacks, restarting"
            $cdb = Get-ChildItem 'C:\Program Files\WindowsApps\Microsoft.WinDbg_*\amd64\cdb.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($cdb) {
                $out = Join-Path $RepoRoot ("logs\hang_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
                & $cdb.FullName -pv -p $proc.Id -c "~*kn 30; q" *> $out
                Log "stacks: $out"
            }
            & "$PSScriptRoot\stop_server.ps1" | Out-Null
            & "$PSScriptRoot\start_server.ps1" | ForEach-Object { Log $_ }; Reset-NavOracle
            continue
        }
    }
    if (-not (Get-ServerProcess)) {
        Log 'server process missing: starting it'
        & "$PSScriptRoot\start_server.ps1" | ForEach-Object { Log $_ }; Reset-NavOracle
    }
}
