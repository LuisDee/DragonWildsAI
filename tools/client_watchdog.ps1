# Keep Claude's game client in the world (route R2, task R2.15), plus the two cheap helpers the client
# mover uses: the nav oracle (python -m tools.nav_oracle serve) and the nav-only dev server
# (start_server.ps1 with DW_NO_BODY=1). Pattern: tools/watchdog.ps1 (server). Run it hidden with
# tools/start_client_watchdog.ps1. Events: logs/client_watchdog.jsonl. Status: logs/state/client_status.json.
#
# Client failures and what happens:
#   crash       process gone, or a new UE4SS crash_*.dmp (its handler then blocks on an invisible
#               MessageBox, so a crash looks like a hang), or CrashReportClient running -> kill, boot
#   hang        process alive but the DWClient runner does not answer: either game log and client.log
#               both stale > HangStaleS with CPU ~0 (confirmed by one probe), or ProbeFails probes in
#               a row -> read-only cdb stack (cdb -pv, like the server watchdog), kill, boot
#   disconnect  runner answers but not in L_World, no pawn, or still DW_PAUSEd for > DisconnectS -> boot_and_join
#               (no kill); two failed rejoins in a row -> kill, boot
#   wrong server in the world on a server other than the join target (client_lib.ps1 "join targets": a
#               scenario-run lease, else shockbyte) for > WrongServerS -> boot_and_join, which leaves and
#               joins the target. An unknown joined server (no LoadMap line) is never acted on.
#   low memory  free RAM < WarnFreeMB -> warn event; < CritFreeMB -> critical event with the top
#               processes. Nothing is killed for memory (report only); boot refuses to LAUNCH below
#               its own MinLaunchFreeMB.
# Restarts (kill or boot) are rate-limited: at most MaxRestarts per RestartWindowMin, then it only logs.
# logs\client.stopped (tools/stop_client.ps1 -Hold) pauses all client recovery. -DryRun detects and
# logs decisions but never kills, boots or starts anything.
param(
    [int]$PollS = 10,
    [int]$ProbeEveryS = 30,
    [int]$HangStaleS = 60,
    [double]$HangCpuCores = 0.05,
    [int]$ProbeFails = 3,
    [int]$DisconnectS = 30,
    [int]$WrongServerS = 60,
    [int]$GraceS = 240,           # a client younger than this is still booting (someone else may be driving it)
    [int]$MaxRestarts = 3,
    [int]$RestartWindowMin = 30,
    [int]$WarnFreeMB = 700,
    [int]$CritFreeMB = 350,
    [switch]$NoDevServer,
    [switch]$NoNavOracle,
    [switch]$DryRun,
    [int]$Loops = 0               # stop after N passes (tests); 0 = run forever
)
. "$PSScriptRoot\client_lib.ps1"

$events = if ($env:DW_CLIENT_WD_EVENTS) { $env:DW_CLIENT_WD_EVENTS } else { Join-Path $RepoRoot 'logs\client_watchdog.jsonl' }
function Ev([string]$event, [hashtable]$f = @{}) {
    $o = [ordered]@{ ts = (Get-Date).ToUniversalTime().ToString('o'); event = $event }
    if ($DryRun) { $o.dry_run = $true }
    foreach ($k in $f.Keys) { $o[$k] = $f[$k] }
    Protect-Secret ($o | ConvertTo-Json -Compress -Depth 6) | Add-Content -Encoding utf8 $events
}
function AgeS([string]$path) {
    if (-not (Test-Path $path)) { return 1e9 }
    [math]::Round(((Get-Date).ToUniversalTime() - (Get-Item $path).LastWriteTimeUtc).TotalSeconds)
}
function Get-LatestDump([string]$dir) {
    Get-ChildItem $dir -Filter 'crash_*.dmp' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
}

# ------------------------------------------------------------------ rate limit
$script:restarts = New-Object System.Collections.ArrayList   # [datetime] of client recoveries
$script:limitedLogged = $null
function Allow-Restart([string]$why) {
    $cut = (Get-Date).AddMinutes(-$RestartWindowMin)
    @($script:restarts | Where-Object { $_ -lt $cut }) | ForEach-Object { [void]$script:restarts.Remove($_) }
    if ($script:restarts.Count -ge $MaxRestarts) {
        if (-not $script:limitedLogged -or $script:limitedLogged -lt $cut) {
            $script:limitedLogged = Get-Date
            Ev 'restart_rate_limited' @{ why = $why; restarts = $script:restarts.Count; window_min = $RestartWindowMin }
        }
        return $false
    }
    [void]$script:restarts.Add((Get-Date)); $true
}

# ------------------------------------------------------------------ client recovery
function Save-Stack($proc, [string]$why) {
    $cdb = Get-Cdb
    if (-not $cdb) { Ev 'stack_skipped' @{ why = 'cdb not found' }; return $null }
    $out = Join-Path $RepoRoot ("logs\client\hang_{0}_{1}.txt" -f $proc.Id, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    if ($DryRun) { return "(dry run) $out" }
    # -pv: non-invasive attach (suspends, reads, detaches; no breakpoint, no code change)
    & $cdb.FullName -pv -p $proc.Id -c "~*kn 30; q" *> $out
    $out
}

# BUGS L24: the relaunch overwrites UE4SS.log (and rotates the game log), so the lines before a crash were
# lost. Copy both (plus our own client.log tail) into a folder next to the dump BEFORE anything restarts.
function Save-CrashLogs($dump) {
    if (-not $dump) { return $null }
    $dest = Join-Path $dump.DirectoryName ($dump.BaseName + '.logs')
    if ($DryRun) { return "(dry run) $dest" }
    try {
        New-Item -ItemType Directory -Force $dest | Out-Null
        $ue4ss = Join-Path $ClientDumpDir 'UE4SS.log'
        foreach ($f in @($ue4ss, $ClientGameLog)) {
            if ($f -and (Test-Path $f)) { Copy-Item -LiteralPath $f -Destination $dest -Force -ErrorAction SilentlyContinue }
        }
        $own = Join-Path $RepoRoot 'logs\client\client.log'
        if (Test-Path $own) { Get-Content $own -Tail 400 | Set-Content -Encoding utf8 (Join-Path $dest 'client.log.tail') }
        Ev 'crash_logs_saved' @{ dump = $dump.Name; dir = $dest }
        return $dest
    } catch { Ev 'crash_logs_failed' @{ dump = $dump.Name; err = "$_" }; return $null }
}

function Stop-Client([string]$why) {
    foreach ($n in 'wd_boot_probe', 'boot_pick_char', 'boot_join_server', 'boot_skip_intro') { Clear-ClientCmd $n }
    $tree = @(Get-ClientProcessTree)
    Ev 'client_kill' @{ why = $why; pids = @($tree | ForEach-Object { $_.Id }) }
    if ($DryRun -or -not $tree) { return }
    $tree | Stop-Process -Force -ErrorAction SilentlyContinue
    $tree | ForEach-Object { try { $_.WaitForExit(30000) | Out-Null } catch {} }
    Start-Sleep -Seconds 5
}

$script:bootFails = 0
$script:inWorldPid = $null   # pid a probe last saw in the world (ends the boot grace early)
function Recover-Client([string]$why, [switch]$Kill, $proc) {
    if (Get-ClientHold) { return }
    if (-not (Allow-Restart $why)) { return }
    if ($Kill) {
        if ($why -eq 'hang' -and $proc) { $s = Save-Stack $proc $why; if ($s) { Ev 'hang_stack' @{ file = $s } } }
        Stop-Client $why
    }
    Ev 'boot_start' @{ why = $why; kill = [bool]$Kill }
    if ($DryRun) { return }
    $r = & "$PSScriptRoot\client_boot.ps1" -Quiet | Select-Object -Last 1
    $script:bootFails = if ($r -and $r.ok) { 0 } else { $script:bootFails + 1 }
    Ev 'boot_result' @{ ok = [bool]($r -and $r.ok); state = $r.state; reason = $r.reason; actions = $r.actions;
                        duration_s = $r.duration_s; attempt = $r.attempt; consecutive_fails = $script:bootFails }
    $script:notWorldSince = $null; $script:probeFails = 0; $script:lastProbe = Get-Date
}

# ------------------------------------------------------------------ helpers: nav oracle + dev server
$python = Join-Path $RepoRoot '.venv\Scripts\python.exe'
$navAlive = Join-Path $ClientIo 'nav\alive.lua'
$script:helperRestarts = @{}
function Allow-Helper([string]$name) {
    $cut = (Get-Date).AddMinutes(-$RestartWindowMin)
    $l = @($script:helperRestarts[$name] | Where-Object { $_ -ge $cut })
    if ($l.Count -ge $MaxRestarts) { $script:helperRestarts[$name] = $l; return $false }
    $script:helperRestarts[$name] = $l + (Get-Date); $true
}
function Get-NavOracleProcs {
    Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*tools.nav_oracle serve*' }
}
function Check-NavOracle {
    $procs = @(Get-NavOracleProcs); $age = AgeS $navAlive
    if ($procs.Count -and $age -lt 60) { return }
    $why = if (-not $procs.Count) { 'missing' } else { "heartbeat stale ${age}s" }
    if (-not (Allow-Helper 'nav_oracle')) { return }
    Ev 'nav_oracle_restart' @{ why = $why; pids = @($procs | ForEach-Object { $_.ProcessId }) }
    if ($DryRun) { return }
    $procs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    $cmd = "`"$python`" -u -m tools.nav_oracle serve >> logs\nav_oracle.log 2>&1"
    Start-Process cmd.exe -ArgumentList '/c', $cmd -WorkingDirectory $RepoRoot -WindowStyle Hidden | Out-Null
}

$script:serverDump = (Get-LatestDump (Join-Path $ServerWin64 'ue4ss')).FullName
function Restart-DevServer([string]$why) {
    if (-not (Allow-Helper 'dev_server')) { return }
    Ev 'dev_server_restart' @{ why = $why }
    if ($DryRun) { return }
    $env:DW_NO_BODY = '1'; $env:DW_PERF = '0'   # nav-only dev server, as the locomotion agent runs it (start_server.ps1 passes env on)
    if ((Get-ServerProcess) -and $why -ne 'missing') {
        if ($why -like 'heartbeat*') {
            $proc = Get-ServerProcess | Where-Object Name -like '*Shipping*' | Select-Object -First 1
            $cdb = Get-Cdb
            if ($proc -and $cdb) {
                $out = Join-Path $RepoRoot ("logs\hang_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
                & $cdb.FullName -pv -p $proc.Id -c "~*kn 30; q" *> $out
                Ev 'dev_server_stack' @{ file = $out }
            }
        }
        & "$PSScriptRoot\stop_server.ps1" | Out-Null
    }
    & "$PSScriptRoot\start_server.ps1" | ForEach-Object { Ev 'dev_server_start' @{ out = "$_" } }
}
function Check-DevServer {
    if (Test-Path (Join-Path $RepoRoot 'logs\server.stopped')) { return }   # held on purpose
    $dump = Get-LatestDump (Join-Path $ServerWin64 'ue4ss')
    if ($dump -and $dump.FullName -ne $script:serverDump -and $dump.Length -gt 0) {
        $script:serverDump = $dump.FullName; Restart-DevServer "crash dump $($dump.Name)"; return
    }
    $proc = Get-ServerProcess | Where-Object Name -like '*Shipping*' | Select-Object -First 1
    if (-not (Get-ServerProcess)) { Restart-DevServer 'missing'; return }
    $hb = Join-Path $RepoRoot 'logs\state\heartbeat.txt'
    if ($proc -and (Test-Path $hb) -and ((Get-Date) - $proc.StartTime).TotalSeconds -gt 180 -and
        (Get-Item $hb).LastWriteTime -gt $proc.StartTime) {
        $age = AgeS $hb
        if ($age -gt 90) { Restart-DevServer "heartbeat stale ${age}s" }
    }
}

# ------------------------------------------------------------------ main loop
$script:clientDump = (Get-LatestDump $ClientDumpDir).FullName
$script:lastProbe = [datetime]::MinValue; $script:probeFails = 0; $script:notWorldSince = $null
$script:lastCpu = $null; $script:lastMemEv = [datetime]::MinValue; $script:holdLogged = $false
$script:p = $null
Ev 'watchdog_start' @{ pid = $PID; poll_s = $PollS; dry_run = [bool]$DryRun; last_client_dump = $script:clientDump;
                       dev_server = -not $NoDevServer; nav_oracle = -not $NoNavOracle }

while ($true) {
    try {
        # memory (report only)
        $free = Get-FreeMB
        if ($free -lt $WarnFreeMB -and ((Get-Date) - $script:lastMemEv).TotalMinutes -ge 5) {
            $script:lastMemEv = Get-Date
            $top = Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 5 |
                ForEach-Object { "$($_.ProcessName)=$([math]::Round($_.WorkingSet64 / 1MB))MB" }
            Ev $(if ($free -lt $CritFreeMB) { 'memory_critical' } else { 'memory_low' }) @{ free_mb = $free; top = @($top) }
        }

        if (-not $NoNavOracle) { Check-NavOracle }
        if (-not $NoDevServer) { Check-DevServer }

        $holdFile = Get-ClientHold; $held = [bool]$holdFile
        if ($held -and -not $script:holdLogged) { Ev 'client_held' @{ file = $holdFile } }
        $script:holdLogged = $held
        $bootBusy = $false
        if (Test-Path $ClientLockFile) {
            $lp = Get-Content $ClientLockFile -ErrorAction SilentlyContinue | Select-Object -First 1
            $bootBusy = [bool]($lp -and (Get-Process -Id ([int]$lp) -ErrorAction SilentlyContinue))
        }

        $proc = Get-ClientProcess
        $state = 'unknown'; $cpu = $null
        if (-not $proc) {
            $state = 'down'
            $gone_dump = Get-LatestDump $ClientDumpDir
            if ($gone_dump -and $gone_dump.FullName -ne $script:clientDump -and $gone_dump.Length -gt 0) {
                $script:clientDump = $gone_dump.FullName; Save-CrashLogs $gone_dump | Out-Null
            }
            if (-not $held -and -not $bootBusy) { Ev 'client_gone' @{}; Recover-Client 'crash' }
        } else {
            $ageProc = ((Get-Date) - $proc.StartTime).TotalSeconds
            if ($script:lastCpu -and $script:lastCpu.pid -eq $proc.Id) {
                $cpu = [math]::Round(($proc.CPU - $script:lastCpu.cpu) / ((Get-Date) - $script:lastCpu.t).TotalSeconds, 3)
            }
            $script:lastCpu = @{ pid = $proc.Id; cpu = $proc.CPU; t = Get-Date }
            $gameAge = AgeS $ClientGameLog; $modAge = AgeS $ClientModLog
            $dump = Get-LatestDump $ClientDumpDir
            $reporter = Get-Process CrashReportClient -ErrorAction SilentlyContinue
            if ($dump -and $dump.FullName -ne $script:clientDump -and $dump.Length -gt 0) {
                Start-Sleep 3; $script:clientDump = $dump.FullName; $state = 'crashed'
                Ev 'client_crash_dump' @{ dump = $dump.Name; pid = $proc.Id }
                Save-CrashLogs $dump | Out-Null
                if (-not $held -and -not $bootBusy) { Recover-Client 'crash' -Kill $proc }
            } elseif ($reporter) {
                $state = 'crashed'; Ev 'client_crash_reporter' @{ pid = $proc.Id }
                if (-not $held -and -not $bootBusy) { Recover-Client 'crash' -Kill $proc }
            } elseif (-not $bootBusy) {
                $stale = $gameAge -gt $HangStaleS -and $modAge -gt $HangStaleS -and $null -ne $cpu -and $cpu -lt $HangCpuCores
                if ($stale -or ((Get-Date) - $script:lastProbe).TotalSeconds -ge $ProbeEveryS) {
                    $script:lastProbe = Get-Date
                    $script:p = Get-ClientProbe 12
                    if ($script:p) { $script:probeFails = 0 } else { $script:probeFails++ }
                    # The boot grace ends early once a probe has seen this process in the world (hangs can
                    # strike within a minute of joining: DISCOVERIES "Client hang (R2)").
                    $pastGrace = $ageProc -gt $GraceS -or $script:inWorldPid -eq $proc.Id
                    $hung = -not $script:p -and $pastGrace -and ($stale -or $script:probeFails -ge $ProbeFails)
                    if ($hung) {
                        $state = 'hung'
                        Ev 'client_hang' @{ pid = $proc.Id; cpu_cores = $cpu; game_log_age_s = $gameAge; mod_log_age_s = $modAge;
                                            probe_fails = $script:probeFails; mb = [math]::Round($proc.WorkingSet64 / 1MB); free_mb = $free }
                        if (-not $held) { Recover-Client 'hang' -Kill $proc }
                    } elseif ($script:p -and $script:p.probe_error) {
                        $state = 'probe_error'; Ev 'probe_error' @{ error = $script:p.probe_error }
                    } elseif ($script:p) {
                        $inWorld = $script:p.map -eq 'L_World' -and $script:p.pawn -and -not $script:p.paused
                        $state = if ($inWorld) { 'in_world' } elseif ($script:p.map -eq 'L_World' -and $script:p.pawn) { 'paused' } elseif ($script:p.map -eq 'L_World') { 'no_pawn' } else { 'menu' }
                        if ($inWorld) {
                            $script:notWorldSince = $null; $script:inWorldPid = $proc.Id
                            $want = Resolve-ClientTarget ''; $wantAddr = Get-TargetAddress $want.name; $on = Get-JoinedServer
                            if ($on -and $wantAddr -and $on -ne $wantAddr) {
                                if (-not $script:wrongSince) { $script:wrongSince = Get-Date }
                                if (((Get-Date) - $script:wrongSince).TotalSeconds -ge $WrongServerS -and -not $held) {
                                    Ev 'wrong_server' @{ on = $on; target = $want.name; target_source = $want.source }
                                    $script:wrongSince = $null
                                    Recover-Client 'wrong_server' $proc
                                }
                            } else { $script:wrongSince = $null }
                        }
                        elseif (-not $script:notWorldSince) { $script:notWorldSince = Get-Date }
                        elseif (((Get-Date) - $script:notWorldSince).TotalSeconds -gt $DisconnectS -and $ageProc -gt $GraceS -and -not $held) {
                            Ev 'client_disconnected' @{ map = $script:p.map; screen = $script:p.screen; pawn = $script:p.pawn;
                                                        why = (Get-JoinFailure (Get-Date).ToUniversalTime().AddMinutes(-10)) }
                            Recover-Client 'disconnect' -Kill:($script:bootFails -ge 2) $proc
                        }
                    } else { $state = 'no_answer' }
                } else { $state = 'ok_unprobed' }
            } else { $state = 'booting' }
        }

        $pp = $script:p
        Write-ClientStatus @{
            source = 'client_watchdog'; state = $state; pid = if ($proc) { $proc.Id } else { $null }
            client_mb = if ($proc) { [math]::Round($proc.WorkingSet64 / 1MB) } else { $null }; cpu_cores = $cpu; free_mb = $free
            game_log_age_s = AgeS $ClientGameLog; mod_log_age_s = AgeS $ClientModLog; probe_fails = $script:probeFails
            map = $pp.map; pawn = $pp.pawn; pos_m = $pp.pos_m; logged_in = $pp.logged_in
            services = if ($pp -and $pp.bridge) { $pp.bridge.services } else { $null }
            held = $held; restarts_in_window = $script:restarts.Count; build = Get-ClientBuildId
            nav_oracle_age_s = AgeS $navAlive; dev_server = [bool](Get-ServerProcess)
        }
    } catch {
        Ev 'watchdog_error' @{ error = "$_"; at = "$($_.InvocationInfo.ScriptLineNumber)" }
    }
    if ($Loops -gt 0 -and ++$script:loopN -ge $Loops) { break }
    Start-Sleep -Seconds $PollS
}
