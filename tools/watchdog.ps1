# Keep the dev server up. UE4SS's crash handler writes crash_*.dmp and then blocks on a
# MessageBox nobody can see (UE4SS CrashDumper.cpp: no setting skips it), so a crash looks like a
# hang. This loop turns that into fail-fast: new dump -> kill -> restart. Also restarts the server
# if the process is gone. Log: logs\watchdog.log. Run hidden: tools\start_watchdog.ps1.
param([int]$PollSeconds = 5)
. "$PSScriptRoot\config.ps1"

$logFile = Join-Path $RepoRoot 'logs\watchdog.log'
$dumpDir = Join-Path $ServerWin64 'ue4ss'
function Log($msg) { "$(Get-Date -Format o) $msg" | Add-Content -Encoding utf8 $logFile }

function Get-LatestDump { Get-ChildItem $dumpDir -Filter 'crash_*.dmp' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1 }

$seen = (Get-LatestDump).FullName
Log "watchdog started (poll ${PollSeconds}s), last dump: $seen"
while ($true) {
    Start-Sleep -Seconds $PollSeconds
    $dump = Get-LatestDump
    if ($dump -and $dump.FullName -ne $seen -and (Get-Item $dump.FullName).Length -gt 0) {
        Start-Sleep -Seconds 3 # let the dump finish writing
        $seen = $dump.FullName
        Log "crash dump $($dump.Name): killing hung server and restarting"
        & "$PSScriptRoot\stop_server.ps1" | Out-Null
        & "$PSScriptRoot\start_server.ps1" | ForEach-Object { Log $_ }
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
            & "$PSScriptRoot\start_server.ps1" | ForEach-Object { Log $_ }
            continue
        }
    }
    if (-not (Get-ServerProcess) -and -not (Test-Path (Join-Path $RepoRoot 'logs\server.stopped'))) {
        Log 'server process missing: starting it'
        & "$PSScriptRoot\start_server.ps1" | ForEach-Object { Log $_ }
    }
}
