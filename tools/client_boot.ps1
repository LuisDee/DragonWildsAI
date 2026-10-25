# boot_and_join for Claude's game client (route R2, task R2.15). Idempotent: every step first checks
# the live state (read-only probe, client_mod/commands/boot_probe.lua) and only acts when needed, so
# running it against a client that is already in the world with its services up does nothing.
#
#   Steam running and logged in -> client launched headless (steam -applaunch 1374490 -nullrhi ...)
#   -> DWClient runner answering -> consent (if shown) -> pick_char (select + EOS sign-in, until
#   logged_in) -> join_server (address/password from gitignored client_io/secrets/server.txt)
#   -> skip_intro (new character only) -> pawn present -> bridge services chat/vitals/fed_reflex
#   running (the bridge's supervisor starts them; this starts them by hand only if it did not).
#
# Retries the whole sequence with backoff (the server can reject a fast rejoin as DuplicateChar while
# it still holds the old connection). Writes logs\state\client_status.json; logs to logs\client\boot.log.
# Never prints the server password (the game log's own ?p=<base64> lines are redacted on the way out).
#
# Usage:
#   powershell -File tools\client_boot.ps1                 # boot and join (no-op if already in world)
#   powershell -File tools\client_boot.ps1 -DryRun         # probe only; says what it would do
#   powershell -File tools\client_boot.ps1 -NoLaunch       # never start the client (join/repair only)
#   powershell -File tools\client_boot.ps1 -Release        # clear a hold (logs\client.hold / client.stopped), then boot
#   powershell -File tools\client_boot.ps1 -Target dev     # join client_io/secrets/server_dev.txt instead (see below)
# Targets (client_lib.ps1 "join targets"): -Target <name>, else an unexpired lease in logs\state\client_target.json
# (tools/scenario_run.py), else shockbyte (server.txt). When the client is in the world on a DIFFERENT server than
# the target (game log LoadMap address), boot disconnects it (disconnect.lua) and joins the target. When the
# joined server is unknown it is left alone.
# While a hold file exists it does nothing (exit 3). Returns a result object ({ok, state, reason, actions, ...}); exit code 0 when in world.
param(
    [switch]$DryRun,
    [switch]$NoLaunch,
    [int]$Attempts = 3,
    [int]$BackoffS = 30,          # 30, 60, 120 ...
    [int]$MinLaunchFreeMB = 1200, # the client needs ~1 GB at the menu, ~2 GB in the world
    [int]$LoadTimeoutS = 240,     # process start -> DWClient runner answering
    [int]$JoinTimeoutS = 120,     # join sent -> in L_World
    [int]$PawnTimeoutS = 90,      # in L_World -> pawn
    [int]$ServiceWaitS = 30,      # bridge supervisor checks every 10 s
    [switch]$Release,             # clear the hold files first (a held client is otherwise left alone)
    [string]$Target = '',         # join target name (shockbyte = server.txt; dev = server_dev.txt); '' = lease or shockbyte
    [switch]$Quiet
)
. "$PSScriptRoot\client_lib.ps1"

$bootLog = if ($env:DW_CLIENT_BOOT_LOG) { $env:DW_CLIENT_BOOT_LOG } else { Join-Path $RepoRoot 'logs\client\boot.log' }
New-Item -ItemType Directory -Force (Split-Path $bootLog) | Out-Null
function BLog($msg) {
    $line = "$(Get-Date -Format o) $(Protect-Secret $msg)"
    Add-Content -Encoding utf8 $bootLog $line
    if (-not $Quiet) { Write-Host $line }
}

$script:actions = New-Object System.Collections.ArrayList
function Act([string]$what) { [void]$script:actions.Add($what); BLog ("{0}{1}" -f ($(if ($DryRun) { 'DRY-RUN would: ' } else { 'do: ' })), $what) }

# Run one command file from client_mod/commands under a boot_ name (no collision with other agents).
# -Source: run this file instead (same name), e.g. the join command with its target prefixed.
function Run-Cmd([string]$file, [int]$timeout = 20, [string]$Source = '', [string]$Note = '') {
    $name = 'boot_' + [IO.Path]::GetFileNameWithoutExtension($file)
    Act ($file + $Note)
    if ($DryRun) { return $null }
    $path = if ($Source) { $Source } else { Join-Path $ClientCmds $file }
    $r = Invoke-ClientCmd -Path $path -Name $name -TimeoutS $timeout
    if (-not $r) { Clear-ClientCmd $name; BLog "  ${file}: no answer in ${timeout}s"; return $null }
    BLog ("  ${file} -> " + (Protect-Secret ($r | ConvertTo-Json -Compress -Depth 4)))
    $r
}

function Services-Ok($p) {
    if (-not $p -or -not $p.bridge -or -not $p.bridge.running -or -not $p.bridge.services) { return $false }
    foreach ($n in 'chat', 'vitals', 'fed_reflex') {
        $s = $p.bridge.services.$n
        if (-not $s -or $s.state -ne 'running') { return $false }
    }
    $true
}

function Summary($p) {
    if (-not $p) { return 'no answer' }
    "map=$($p.map) screen=$($p.screen) logged_in=$($p.logged_in) pawn=$([bool]$p.pawn) intro=$($p.intro_widgets) paused=$($p.paused) bridge=$($p.bridge.running)"
}

function New-Result([bool]$ok, [string]$state, [string]$reason, $p, [datetime]$t0) {
    $c = Get-ClientProcess
    [ordered]@{
        ok = $ok; state = $state; reason = $reason; dry_run = [bool]$DryRun
        actions = @($script:actions); duration_s = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
        target = $script:joinTarget.name; target_source = $script:joinTarget.source; joined = Get-JoinedServer
        pid = if ($c) { $c.Id } else { $null }; client_mb = if ($c) { [math]::Round($c.WorkingSet64 / 1MB) } else { $null }
        free_mb = Get-FreeMB; build = Get-ClientBuildId
        map = $p.map; pawn = $p.pawn; pos_m = $p.pos_m; logged_in = $p.logged_in
        services = if ($p -and $p.bridge) { $p.bridge.services } else { $null }
    }
}

# join_server.lua with `local SECRETS_FILE = "<file>"` prefixed (a chunk local: the plain file defaults to server.txt).
function New-JoinCmd {
    $src = Join-Path $ClientCmds 'join_server.lua'
    $leaf = Split-Path $TargetFile -Leaf
    $tmp = Join-Path $ClientStateDir "join_server_$($script:joinTarget.name).lua"
    New-Item -ItemType Directory -Force $ClientStateDir | Out-Null
    ("local SECRETS_FILE = `"$leaf`"`n" + (Get-Content $src -Raw)) | Set-Content -Encoding utf8 $tmp
    $tmp
}

# One pass of the sequence. Returns a result; ok=$true only when in the world with services running.
function Invoke-BootOnce([datetime]$t0) {
    # 1. Steam
    $st = Get-SteamState
    if (-not $st.running) {
        Act 'start Steam (-silent)'
        if ($DryRun) { return New-Result $false 'down' 'steam_not_running' $null $t0 }
        Start-Process $SteamExe -ArgumentList '-silent'
        $d = (Get-Date).AddSeconds(120)
        while ((Get-Date) -lt $d -and -not (Get-SteamState).logged_in) { Start-Sleep 3 }
        $st = Get-SteamState
    }
    if (-not $st.logged_in) { return New-Result $false 'down' 'steam_not_logged_in' $null $t0 }

    # 2. Client process
    $proc = Get-ClientProcess
    if (-not $proc) {
        if ($NoLaunch) { return New-Result $false 'down' 'client_not_running' $null $t0 }
        $free = Get-FreeMB
        if ($free -lt $MinLaunchFreeMB) { BLog "free RAM ${free} MB < ${MinLaunchFreeMB} MB: not launching"; return New-Result $false 'down' 'low_memory' $null $t0 }
        Act "launch client: steam -applaunch $ClientAppId $($ClientArgs -join ' ')"
        if ($DryRun) { return New-Result $false 'down' 'client_not_running' $null $t0 }
        foreach ($n in 'wd_boot_probe', 'boot_pick_char', 'boot_join_server', 'boot_skip_intro') { Clear-ClientCmd $n }
        & $SteamExe -applaunch $ClientAppId @ClientArgs
        $d = (Get-Date).AddSeconds(120)
        while ((Get-Date) -lt $d -and -not ($proc = Get-ClientProcess)) { Start-Sleep 2 }
        if (-not $proc) { return New-Result $false 'down' 'launch_timeout' $null $t0 }
        BLog "client pid $($proc.Id) started"
    }
    $procStart = $proc.StartTime

    # 3. Runner answering (= DWClient loaded and the game thread free)
    $p = $null; $d = $procStart.AddSeconds($LoadTimeoutS)
    if ((Get-Date) -gt $d) { $d = (Get-Date).AddSeconds(45) }   # long-running client: short wait
    while (-not $p) {
        $p = Get-ClientProbe 12
        if ($p) { break }
        if (-not (Get-ClientProcess)) { return New-Result $false 'down' 'client_exited' $null $t0 }
        if ((Get-Date) -gt $d) { return New-Result $false 'unresponsive' 'runner_timeout' $null $t0 }
    }
    if ($p.probe_error) { return New-Result $false 'error' ("probe_error: " + $p.probe_error) $null $t0 }
    BLog ("probe: " + (Summary $p))

    # 4. Menu -> world -> pawn
    $loginTries = 0; $joinTries = 0; $joinSent = $null; $worldSince = $null; $introTries = 0; $noAnswer = 0
    $leaveTries = 0
    $deadline = (Get-Date).AddSeconds($JoinTimeoutS + $PawnTimeoutS + 120)
    while ($true) {
        if ($p -and $p.map -eq 'L_World' -and $p.pawn) {
            # in a world: the right one? (unknown = leave it alone; only a known, different address switches)
            $on = Get-JoinedServer
            if (-not $on -or -not $TargetAddr -or $on -eq $TargetAddr -or $joinSent) { break }
            if ($leaveTries -ge 2) { return New-Result $false 'in_world' "wrong_server: on $on, target $($script:joinTarget.name)" $p $t0 }
            $leaveTries++
            BLog "in the world on $on but the target is $($script:joinTarget.name) ($TargetAddr): leaving"
            [void](Run-Cmd 'disconnect.lua' 20 '' " (on $on, target $($script:joinTarget.name))")
            if ($DryRun) { return New-Result $false 'in_world' "wrong_server: on $on" $p $t0 }
            $worldSince = $null
            Start-Sleep 5
            $p = Get-ClientProbe 12
            continue
        }
        if ((Get-Date) -gt $deadline) { return New-Result $false 'stuck' ("timeout at: " + (Summary $p)) $p $t0 }
        if (-not (Get-ClientProcess)) { return New-Result $false 'down' 'client_exited' $p $t0 }
        if (-not $p) {
            # map loads block the game thread for a few seconds; a long silence is a hang
            if (++$noAnswer -ge 6) { return New-Result $false 'unresponsive' 'runner_silent' $null $t0 }
        } elseif ($p.map -eq 'L_World') {
            if (-not $worldSince) { $worldSince = Get-Date; BLog 'in L_World, waiting for the pawn' }
            if (($p.intro_widgets -gt 0 -or ((Get-Date) - $worldSince).TotalSeconds -gt 30) -and $introTries -lt 3 -and
                (-not $script:lastIntro -or ((Get-Date) - $script:lastIntro).TotalSeconds -ge 15)) {
                $script:lastIntro = Get-Date; $introTries++
                [void](Run-Cmd 'skip_intro.lua')
                if ($DryRun) { return New-Result $false 'loading' 'no_pawn' $p $t0 }
            }
            if (((Get-Date) - $worldSince).TotalSeconds -gt $PawnTimeoutS) { return New-Result $false 'stuck' 'no_pawn' $p $t0 }
        } else {
            $worldSince = $null
            if ($joinSent -and ((Get-Date) - $joinSent).TotalSeconds -lt $JoinTimeoutS) {
                # join in flight (or rejected: the client falls back to the menu)
                $why = Get-JoinFailure $joinSent.ToUniversalTime().AddSeconds(-5)
                if ($why -and ((Get-Date) - $joinSent).TotalSeconds -gt 10) { return New-Result $false 'menu' ("join_failed: $why") $p $t0 }
            } elseif ($p.screen -eq 20) {
                [void](Run-Cmd 'consent.lua')
                if ($DryRun) { return New-Result $false 'menu' 'consent_pending' $p $t0 }
            } elseif (-not $p.logged_in) {
                if ($loginTries -ge 3) { return New-Result $false 'menu' 'sign_in_failed' $p $t0 }
                if (-not $script:lastLogin -or ((Get-Date) - $script:lastLogin).TotalSeconds -ge 20) {
                    $script:lastLogin = Get-Date; $loginTries++
                    [void](Run-Cmd 'pick_char.lua')
                    if ($DryRun) { return New-Result $false 'menu' 'not_signed_in' $p $t0 }
                }
            } else {
                if (-not (Test-Path $TargetFile)) { return New-Result $false 'menu' 'no_secrets_file' $p $t0 }
                if ($joinTries -ge 2) { return New-Result $false 'menu' 'join_timeout' $p $t0 }
                $joinTries++
                if ($script:joinTarget.name -eq $ClientDefaultTarget) { [void](Run-Cmd 'join_server.lua') }
                else { [void](Run-Cmd 'join_server.lua' 20 $(if ($DryRun) { '' } else { New-JoinCmd }) " (target $($script:joinTarget.name))") }
                if ($DryRun) { return New-Result $false 'menu' 'not_joined' $p $t0 }
                $joinSent = Get-Date
            }
        }
        Start-Sleep 3
        $p = Get-ClientProbe 12
        if ($p) { $noAnswer = 0; BLog ("probe: " + (Summary $p)) }
    }

    # 5. Teardown pause: join_server.lua / disconnect.lua set _G.DW_PAUSE; clear it now the pawn exists
    if ($p.paused) {
        [void](Run-Cmd 'unpause.lua')
        if (-not $DryRun) { $q = Get-ClientProbe 12; if ($q) { $p = $q } }
        if (-not $DryRun -and $p.paused) { return New-Result $false 'in_world' 'still_paused' $p $t0 }
    }

    # 6. Background services (chat hooks, vitals watcher, stay-fed reflex)
    if (-not (Services-Ok $p)) {
        BLog ("services not all running yet: " + ($p.bridge | ConvertTo-Json -Compress -Depth 4))
        if (-not $p.bridge.running) {
            [void](Run-Cmd 'bridge_start.lua' 30)
        }
        if (-not $DryRun) {
            $d = (Get-Date).AddSeconds($ServiceWaitS)
            while ((Get-Date) -lt $d -and -not (Services-Ok $p)) { Start-Sleep 5; $q = Get-ClientProbe 12; if ($q) { $p = $q } }
        }
        if (-not (Services-Ok $p)) {
            foreach ($f in 'chat_start.lua', 'sense_vitals_start.lua', 'inv_reflex_start.lua') { [void](Run-Cmd $f 30) }
            if (-not $DryRun) { Start-Sleep 2; $q = Get-ClientProbe 12; if ($q) { $p = $q } }
        }
        if (-not $DryRun -and -not (Services-Ok $p) -and $p.bridge.running) {
            # started by hand: they run even if the bridge supervisor reports otherwise; note it, don't fail
            BLog 'services started by hand; bridge supervisor does not report them all running'
            return New-Result $true 'in_world' 'services_unconfirmed' $p $t0
        }
    }
    $svcOk = Services-Ok $p
    New-Result $svcOk 'in_world' $(if ($svcOk) { $null } else { 'services_not_running' }) $p $t0
}

# ------------------------------------------------------------------ main
$t0 = Get-Date
$script:joinTarget = Resolve-ClientTarget $Target
$TargetFile = Get-TargetFile $script:joinTarget.name
$TargetAddr = Get-TargetAddress $script:joinTarget.name
if (Test-TargetForbidden $script:joinTarget.name) {
    # never join a forbidden target (GOAL.md: shockbyte during /goal), whatever asked for it
    BLog "target $($script:joinTarget.name) [$($script:joinTarget.source)] is FORBIDDEN (client_forbid_targets): not booting"
    Write-Output ([pscustomobject][ordered]@{ ok = $false; state = 'forbidden'; reason = "target $($script:joinTarget.name) is forbidden"; actions = @() }); exit 4
}
$hold = Get-ClientHold
if ($hold -and -not $DryRun) {
    if (-not $Release) {
        BLog "client is on hold ($hold): not acting. Use -Release to clear the hold and boot."
        Write-Output ([pscustomobject][ordered]@{ ok = $false; state = 'held'; reason = "hold file $hold"; actions = @() }); exit 3
    }
    # like start_server.ps1 clearing logs\server.stopped: booting on purpose resumes watchdog supervision
    $ClientHoldFiles | ForEach-Object { Remove-Item $_ -ErrorAction SilentlyContinue }
    BLog "released hold ($hold)"
}
if (-not $DryRun -and -not (Enter-ClientLock)) {
    BLog 'another boot is running (lock held): exiting'
    $res = [ordered]@{ ok = $false; state = 'busy'; reason = 'boot_locked'; actions = @() }
    Write-Output ([pscustomobject]$res); exit 2
}
BLog ("boot_and_join start" + $(if ($DryRun) { ' (dry run)' } else { '' }) + " build=$(Get-ClientBuildId) target=$($script:joinTarget.name) [$($script:joinTarget.source)] joined=$(Get-JoinedServer)")
try {
    $res = $null
    for ($a = 1; $a -le $Attempts; $a++) {
        $res = Invoke-BootOnce $t0
        $res.attempt = $a
        BLog ("attempt ${a}: ok=$($res.ok) state=$($res.state) reason=$($res.reason)")
        if ($res.ok -or $DryRun) { break }
        if ($res.reason -in @('low_memory', 'no_secrets_file', 'steam_not_logged_in', 'client_not_running')) { break }   # retrying won't help
        if ($a -lt $Attempts) { $w = $BackoffS * [math]::Pow(2, $a - 1); BLog "retry in ${w}s"; Start-Sleep -Seconds $w }
    }
    $res.ts = (Get-Date).ToUniversalTime().ToString('o')
    if (-not $DryRun) { Write-ClientStatus @{ source = 'client_boot'; state = $res.state; last_boot = $res } }
    BLog ("boot_and_join end: ok=$($res.ok) state=$($res.state) reason=$($res.reason) actions=$($res.actions.Count) in $($res.duration_s)s")
    Write-Output ([pscustomobject]$res)
    if ($res.ok) { exit 0 } else { exit 1 }
} finally {
    if (-not $DryRun) { Exit-ClientLock }
}
