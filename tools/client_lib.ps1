# Shared helpers for Claude's game client (route R2): paths, process lookup, the DWClient command
# runner from PowerShell, the read-only boot probe, status file, lock, redaction.
# Dot-source it: . "$PSScriptRoot\client_lib.ps1"   (it dot-sources config.ps1)
# Used by tools/client_boot.ps1, tools/client_watchdog.ps1, tools/client_smoke.ps1.
. "$PSScriptRoot\config.ps1"

$ClientAppId   = 1374490
$SteamExe      = if ($env:DW_STEAM_EXE) { $env:DW_STEAM_EXE } else { 'C:\Program Files (x86)\Steam\steam.exe' }
$ClientWin64   = if ($env:DW_CLIENT_WIN64) { $env:DW_CLIENT_WIN64 } else {
    'C:\Program Files (x86)\Steam\steamapps\common\RSDragonwilds\RSDragonwilds\Binaries\Win64' }
$ClientManifest = 'C:\Program Files (x86)\Steam\steamapps\appmanifest_1374490.acf'
$ClientArgs    = @('-nullrhi', '-nosound', '-unattended', '-nosplash', '-log')
# DW_CLIENT_* overrides exist for offline tests (a fake client: tests/test_client_ops.py).
$ClientProcName = if ($env:DW_CLIENT_PROC) { $env:DW_CLIENT_PROC } else { 'RSDragonwilds-Win64-Shipping' }
# With DW_CLIENT_PROC overridden (tests: a fake client) the tree is ONLY that process, never the real
# launcher/crash reporter, so a test watchdog or stop_client can't see or kill the live game.
$ClientTreeNames = if ($env:DW_CLIENT_PROC) { @($ClientProcName) } else { @($ClientProcName, 'RSDragonwilds', 'CrashReportClient') }
$ClientGameLog = if ($env:DW_CLIENT_GAME_LOG) { $env:DW_CLIENT_GAME_LOG } else { Join-Path $env:LOCALAPPDATA 'RSDragonwilds\Saved\Logs\RSDragonwilds.log' }
$ClientModLog  = if ($env:DW_CLIENT_MOD_LOG) { $env:DW_CLIENT_MOD_LOG } else { Join-Path $RepoRoot 'logs\client\client.log' }
$ClientDumpDir = if ($env:DW_CLIENT_DUMP_DIR) { $env:DW_CLIENT_DUMP_DIR } else { Join-Path $ClientWin64 'ue4ss' }
$ClientIo      = if ($env:DW_CLIENT_IO) { $env:DW_CLIENT_IO } else { Join-Path $RepoRoot 'client_io' }
$ClientSecrets = Join-Path $ClientIo 'secrets\server.txt'
$ClientCmds    = Join-Path $RepoRoot 'client_mod\commands'
$ClientStateDir = if ($env:DW_CLIENT_STATE_DIR) { $env:DW_CLIENT_STATE_DIR } else { Join-Path $RepoRoot 'logs\state' }
$ClientStatusFile = Join-Path $ClientStateDir 'client_status.json'
$ClientLockFile = Join-Path $ClientStateDir 'client_boot.lock'
# Hold flags (like logs\server.stopped): while either exists the watchdog never restarts or rejoins the
# client and client_boot.ps1 refuses to act (unless -Release). logs\client.stopped is what
# tools/stop_client.ps1 -Hold writes; logs\client.hold is the one main/humans create by hand.
$ClientHoldFiles = if ($env:DW_CLIENT_HOLD) { @($env:DW_CLIENT_HOLD) } else {
    @((Join-Path $RepoRoot 'logs\client.stopped'), (Join-Path $RepoRoot 'logs\client.hold')) }
$ClientHoldFile = $ClientHoldFiles[0]
function Get-ClientHold { $ClientHoldFiles | Where-Object { Test-Path $_ } | Select-Object -First 1 }

function Get-ClientProcess {
    Get-Process $ClientProcName -ErrorAction SilentlyContinue | Select-Object -First 1
}
# Everything that belongs to one client instance: the shipping exe, its launcher stub, the crash reporter.
function Get-ClientProcessTree {
    Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -in $ClientTreeNames }
}
function Get-ClientBuildId {
    if (Test-Path $ClientManifest) { (Select-String -Path $ClientManifest -Pattern '"buildid"\s+"(\d+)"').Matches[0].Groups[1].Value }
}
function Get-FreeMB { [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB) }

# Steam must run, logged in (HKCU ActiveProcess.ActiveUser = the logged-in account's 32-bit id, 0 = none).
function Get-SteamState {
    $p = Get-Process steam -ErrorAction SilentlyContinue | Select-Object -First 1
    $u = 0
    try { $u = [int64](Get-ItemProperty 'HKCU:\Software\Valve\Steam\ActiveProcess' -ErrorAction Stop).ActiveUser } catch {}
    [ordered]@{ running = [bool]$p; pid = if ($p) { $p.Id } else { $null }; logged_in = ($u -ne 0); account_id = $u }
}

# Never let the world password reach a log: the game log's Browse/LoadMap lines carry ?p=<base64 pw>.
# Every target file (server.txt, server_<name>.txt) is redacted, not only the default one.
function Protect-Secret([string]$s) {
    if (-not $s) { return $s }
    $s = $s -replace '\?p=[^?\s"]*', '?p=<redacted>'
    foreach ($f in @(Get-ChildItem (Split-Path $ClientSecrets) -Filter 'server*.txt' -ErrorAction SilentlyContinue)) {
        $pw = (Get-Content $f.FullName -TotalCount 2 -ErrorAction SilentlyContinue | Select-Object -Skip 1 -First 1)
        if ($pw) { $pw = $pw.Trim(); if ($pw.Length -ge 3) { $s = $s.Replace($pw, '<redacted>') } }
    }
    $s
}

# ------------------------------------------------------------------ join targets (which server Claude joins)
# A target is a gitignored secrets file: line 1 address (host:port), line 2 world password.
#   shockbyte (default, Luis's world) -> client_io/secrets/server.txt
#   <name>                            -> client_io/secrets/server_<name>.txt   (e.g. dev -> 127.0.0.1:7777)
# Which target applies: an explicit -Target, else an unexpired lease in logs/state/client_target.json
# (written by tools/scenario_run.py for the length of a scenario run, so the watchdog's rejoins go to the
# same server), else shockbyte. An expired or missing lease always means shockbyte.
# The default target and the forbidden targets are per-machine settings (GOAL.md: during /goal the
# default is dev and shockbyte is forbidden):
#   DW_CLIENT_DEFAULT_TARGET env, else logs/state/client_default_target.txt, else 'shockbyte'
#   DW_CLIENT_FORBID_TARGETS env (comma list), else logs/state/client_forbid_targets.txt (one per line)
# A forbidden target is never joined: Resolve-ClientTarget marks it, and client_boot refuses.
$ClientDefaultTargetFile = Join-Path $ClientStateDir 'client_default_target.txt'
$ClientForbidTargetsFile = Join-Path $ClientStateDir 'client_forbid_targets.txt'
$ClientDefaultTarget = if ($env:DW_CLIENT_DEFAULT_TARGET) { $env:DW_CLIENT_DEFAULT_TARGET.Trim() }
    elseif (Test-Path $ClientDefaultTargetFile) { (Get-Content $ClientDefaultTargetFile -TotalCount 1).Trim() }
    else { 'shockbyte' }
$ClientTargetLease = Join-Path $ClientStateDir 'client_target.json'
function Get-ForbiddenTargets {
    $raw = if ($env:DW_CLIENT_FORBID_TARGETS) { $env:DW_CLIENT_FORBID_TARGETS -split ',' }
           elseif (Test-Path $ClientForbidTargetsFile) { Get-Content $ClientForbidTargetsFile } else { @() }
    @($raw | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
}
function Test-TargetForbidden([string]$Name) { (Get-ForbiddenTargets) -contains $Name }
function Get-TargetFile([string]$Name) {
    # 'shockbyte' (and the empty name) is server.txt, whatever the default target is
    if (-not $Name -or $Name -eq 'shockbyte') { return $ClientSecrets }
    if ($Name -notmatch '^[a-z0-9_]+$') { throw "bad target name '$Name' (a-z, 0-9, _)" }
    Join-Path (Split-Path $ClientSecrets) "server_$Name.txt"
}
function Get-TargetAddress([string]$Name) {
    $f = Get-TargetFile $Name
    if (-not (Test-Path $f)) { return $null }
    $a = Get-Content $f -TotalCount 1 -ErrorAction SilentlyContinue
    if ($a) { $a.Trim() } else { $null }
}
function Get-TargetLease {
    if (-not (Test-Path $ClientTargetLease)) { return $null }
    try { $l = Get-Content $ClientTargetLease -Raw -ErrorAction Stop | ConvertFrom-Json } catch { return $null }
    if (-not $l.target -or -not $l.until) { return $null }
    try { $until = [datetime]::Parse($l.until, $null, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() } catch { return $null }
    if ($until -le (Get-Date).ToUniversalTime()) { return $null }
    $l
}
function Resolve-ClientTarget([string]$Explicit) {
    if ($Explicit) { return [pscustomobject]@{ name = $Explicit; source = 'explicit' } }
    $l = Get-TargetLease
    if ($l) { return [pscustomobject]@{ name = [string]$l.target; source = "lease (until $($l.until), by $($l.by))" } }
    [pscustomobject]@{ name = $ClientDefaultTarget; source = 'default' }
}
# Is the address the client is on (Get-JoinedServer) the address of a forbidden target?
function Test-JoinedForbidden([string]$Joined) {
    if (-not $Joined) { return $false }
    foreach ($n in Get-ForbiddenTargets) { $a = Get-TargetAddress $n; if ($a -and $a -eq $Joined) { return $true } }
    $false
}
# The server the client last loaded L_World from: the game log's "LoadMap: <host:port>/Game/Maps/World/L_World"
# line (the ?p= part is never returned). $null when unknown (menu, fresh log, no line).
# Which server the client is on. Two sources; the NEWER wins:
#   - the game log's last "LoadMap: <host:port>/Game/Maps/World/L_World" (its [YYYY.MM.DD-HH.MM.SS] stamp is UTC)
#   - logs/state/last_join.json, written by client_boot when it SENDS a join (Set-JoinedServer)
# The game log can stall (live 2026-10-25: it stopped at 22:04 UTC while the client kept running), and then
# it named an old server; the boot's own record keeps this right.
$ClientLastJoinFile = Join-Path $ClientStateDir 'last_join.json'
function Set-JoinedServer([string]$Addr) {
    if (-not $Addr) { return }
    [pscustomobject]@{ addr = $Addr; ts = (Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json -Compress |
        Set-Content -Path $ClientLastJoinFile -Encoding utf8
}
function Get-JoinedServer {
    $logAddr, $logTs = $null, [datetime]::MinValue
    if (Test-Path $ClientGameLog) {
        $last = Select-String -Path $ClientGameLog -Pattern 'LoadMap: ' -ErrorAction SilentlyContinue | Select-Object -Last 1
        if ($last -and $last.Line -match 'LoadMap: ([0-9A-Za-z.\-]+:\d+)/Game/Maps/World/L_World') {
            $logAddr = $Matches[1]
            if ($last.Line -match '^\[(\d{4})\.(\d{2})\.(\d{2})-(\d{2})\.(\d{2})\.(\d{2})') {
                $logTs = [datetime]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], [int]$Matches[4], [int]$Matches[5], [int]$Matches[6], [DateTimeKind]::Utc)
            }
        }
    }
    $joinAddr, $joinTs = $null, [datetime]::MinValue
    if (Test-Path $ClientLastJoinFile) {
        try {
            $j = Get-Content $ClientLastJoinFile -Raw | ConvertFrom-Json
            $joinAddr = [string]$j.addr
            $joinTs = [datetime]::Parse($j.ts, $null, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        } catch { }
    }
    # the log's stamp has whole seconds only: a LoadMap within 2 s of the join counts as the answer to it
    if ($joinAddr -and $joinTs -gt $logTs.AddSeconds(2)) { return $joinAddr }
    $logAddr
}

# Run one client_mod command through the DWClient runner (client_mod/scripts/main.lua reads
# client_io/cmd/queue.txt every 500 ms on the game thread). Same protocol as tools/client_cmd.sh:
# write <name>.lua (rename), then append "<name>" to the queue. -Name lets a
# caller use its own file name so it never collides with another agent's command of the same name.
# Returns the parsed {ok, result | error} object, or $null on timeout (runner not loaded or game thread busy).
function Invoke-ClientCmd {
    param([Parameter(Mandatory)][string]$Path, [string]$Name, [int]$TimeoutS = 20)
    if (-not $Name) { $Name = [IO.Path]::GetFileNameWithoutExtension($Path) }
    $cmdDir = Join-Path $ClientIo 'cmd'; $outDir = Join-Path $ClientIo 'out'
    New-Item -ItemType Directory -Force $cmdDir, $outDir | Out-Null
    $out = Join-Path $outDir "$Name.json"
    Remove-Item $out -ErrorAction SilentlyContinue
    $tmp = Join-Path $cmdDir "$Name.tmp"
    Copy-Item $Path $tmp -Force
    Move-Item $tmp (Join-Path $cmdDir "$Name.lua") -Force   # rename: the runner never sees a half-written file
    # then queue it: the runner reads client_io/cmd/queue.txt (no directory listing on the game thread, L28)
    [IO.File]::AppendAllText((Join-Path $cmdDir 'queue.txt'), "$Name`n", [Text.Encoding]::ASCII)
    $deadline = (Get-Date).AddSeconds($TimeoutS)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 250
        if (Test-Path $out) {
            for ($i = 0; $i -lt 8; $i++) {   # the runner may still be writing it
                try { return (Get-Content $out -Raw -ErrorAction Stop | ConvertFrom-Json) } catch { Start-Sleep -Milliseconds 100 }
            }
        }
    }
    $null
}
# Withdraw a command the runner never picked up (hung or not loaded), so it cannot fire on a later start.
function Clear-ClientCmd([string]$Name) {
    Remove-Item (Join-Path $ClientIo "cmd\$Name.lua") -ErrorAction SilentlyContinue
}

# Read-only probe: map, menu screen, signed in, pawn, intro, bridge services (client_mod/commands/boot_probe.lua).
function Get-ClientProbe([int]$TimeoutS = 12) {
    $r = Invoke-ClientCmd -Path (Join-Path $ClientCmds 'boot_probe.lua') -Name 'wd_boot_probe' -TimeoutS $TimeoutS
    if (-not $r) { Clear-ClientCmd 'wd_boot_probe'; return $null }
    if (-not $r.ok) { return [pscustomobject]@{ probe_error = (Protect-Secret ([string]$r.error)) } }
    $r.result
}

function Write-ClientStatus([hashtable]$Fields) {
    New-Item -ItemType Directory -Force $ClientStateDir | Out-Null
    $o = [ordered]@{ ts = (Get-Date).ToUniversalTime().ToString('o') }
    foreach ($k in $Fields.Keys) { $o[$k] = $Fields[$k] }
    $tmp = "$ClientStatusFile.tmp"
    ($o | ConvertTo-Json -Depth 6) | Set-Content -Encoding utf8 $tmp
    Move-Item $tmp $ClientStatusFile -Force
}

# One boot at a time (watchdog vs a manual run). A lock whose pid is gone is stale.
function Enter-ClientLock {
    New-Item -ItemType Directory -Force $ClientStateDir | Out-Null
    if (Test-Path $ClientLockFile) {
        $old = (Get-Content $ClientLockFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($old -and $old -ne "$PID" -and (Get-Process -Id ([int]$old) -ErrorAction SilentlyContinue)) { return $false }
    }
    Set-Content -Encoding ascii $ClientLockFile "$PID"
    $true
}
function Exit-ClientLock {
    $old = (Get-Content $ClientLockFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($old -eq "$PID") { Remove-Item $ClientLockFile -ErrorAction SilentlyContinue }
}

# Last lines of the game log that explain a failed join (redacted), e.g. "Connection Failed for reason [DuplicateChar]".
function Get-JoinFailure([datetime]$SinceUtc) {
    if (-not (Test-Path $ClientGameLog)) { return $null }
    $rx = 'Connection Failed|NetworkFailure|TravelFailure|PendingConnectionFailure|Missing user ID|ConnectionLost|ConnectionTimeout|Disconnect.*reason'
    $hits = Select-String -Path $ClientGameLog -Pattern $rx -ErrorAction SilentlyContinue | Select-Object -Last 3
    $out = @()
    foreach ($h in $hits) {
        if ($h.Line -match '^\[(\d{4})\.(\d\d)\.(\d\d)-(\d\d)\.(\d\d)\.(\d\d)') {
            $t = [datetime]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], [int]$Matches[4], [int]$Matches[5], [int]$Matches[6], [DateTimeKind]::Utc)
            if ($t -lt $SinceUtc) { continue }
        }
        $line = $h.Line; if ($line.Length -gt 240) { $line = $line.Substring(0, 240) }
        $out += (Protect-Secret $line)
    }
    if ($out.Count) { $out -join ' | ' } else { $null }
}

function Get-Cdb {
    Get-ChildItem 'C:\Program Files\WindowsApps\Microsoft.WinDbg_*\amd64\cdb.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
}

# ------------------------------------------------------------------ front-end returns (BUGS L24)
# The game crashes on the 3rd return to L_FrontEnd within ONE client process (null+0x250 in blueprint UI code
# right after LoadMap(L_FrontEnd); A/B 2026-10-25: with our hooks, without them, and without UE4SS's engine
# hooks alike). So a process may return to the front end at most $ClientMaxFrontEndReturns (2) times: before an
# action that would need another visit (a disconnect for a target switch, a rejoin from the menu) the client is
# relaunched instead (Restart-ClientProcess), which starts the count again at 0.
# Count per client process = the larger of
#   - the game log: LoadMap lines for /Game/Maps/L_FrontEnd after the startup one (only when the log belongs to
#     this process: its "Log file open" stamp is not older than the process), and
#   - logs/state/client_frontend_returns.json: {pid, start, returns}, raised by Register-FrontEndReturn whenever
#     a tool sends disconnect.lua (the game log can stall: L23).
$ClientMaxFrontEndReturns = if ($env:DW_CLIENT_MAX_FE_RETURNS) { [int]$env:DW_CLIENT_MAX_FE_RETURNS } else { 2 }
$ClientFrontEndFile = Join-Path $ClientStateDir 'client_frontend_returns.json'
function Get-ProcStartIso($Proc) { try { $Proc.StartTime.ToUniversalTime().ToString('o') } catch { '' } }
function Get-FrontEndReturnsFromLog($Proc) {
    if (-not $Proc -or -not (Test-Path $ClientGameLog)) { return $null }
    $head = Get-Content $ClientGameLog -TotalCount 1 -ErrorAction SilentlyContinue
    if ($head -match 'Log file open, (\d\d/\d\d/\d\d \d\d:\d\d:\d\d)') {
        try {
            $opened = [datetime]::ParseExact($Matches[1], 'MM/dd/yy HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
            if ($opened -lt $Proc.StartTime.AddSeconds(-120)) { return $null }   # an older process's log
        } catch { }
    }
    $maps = @(Select-String -Path $ClientGameLog -Pattern 'LogLoad: LoadMap: \S*/Game/Maps/' -ErrorAction SilentlyContinue)
    if (-not $maps.Count) { return 0 }
    $fe = @($maps | Where-Object { $_.Line -match 'LoadMap: \S*/Game/Maps/L_FrontEnd' }).Count
    if ($maps[0].Line -match '/Game/Maps/L_FrontEnd') { $fe-- }   # the startup load is not a return
    [math]::Max(0, $fe)
}
function Read-FrontEndRecord($Proc) {
    if (-not $Proc -or -not (Test-Path $ClientFrontEndFile)) { return 0 }
    try { $r = Get-Content $ClientFrontEndFile -Raw -ErrorAction Stop | ConvertFrom-Json } catch { return 0 }
    # pid AND start time: a reused pid is another process
    if ([int]$r.pid -ne $Proc.Id -or ([string]$r.start -and [string]$r.start -ne (Get-ProcStartIso $Proc))) { return 0 }
    [int]$r.returns
}
function Write-FrontEndRecord($Proc, [int]$Returns, [string]$Why) {
    New-Item -ItemType Directory -Force $ClientStateDir | Out-Null
    $o = [ordered]@{ pid = $Proc.Id; start = Get-ProcStartIso $Proc; returns = $Returns; max = $ClientMaxFrontEndReturns
                     why = $Why; ts = (Get-Date).ToUniversalTime().ToString('o') }
    $tmp = "$ClientFrontEndFile.tmp"
    ($o | ConvertTo-Json -Compress) | Set-Content -Encoding utf8 $tmp
    Move-Item $tmp $ClientFrontEndFile -Force
}
# {pid, returns, log, recorded, max, needs_relaunch}; returns 0 when no client runs.
function Get-FrontEndReturns($Proc = (Get-ClientProcess)) {
    if (-not $Proc) { return [pscustomobject][ordered]@{ pid = $null; returns = 0; log = $null; recorded = 0; max = $ClientMaxFrontEndReturns; needs_relaunch = $false } }
    $log = Get-FrontEndReturnsFromLog $Proc
    $rec = Read-FrontEndRecord $Proc
    $n = [math]::Max([int]$rec, [int]$log)
    if ($n -gt $rec) { Write-FrontEndRecord $Proc $n 'game log' }
    [pscustomobject][ordered]@{ pid = $Proc.Id; returns = $n; log = $log; recorded = $rec; max = $ClientMaxFrontEndReturns
                                needs_relaunch = ($n -ge $ClientMaxFrontEndReturns) }
}
# Would another front-end visit (a disconnect, or a rejoin from the menu that a later leave must undo) be one too many?
function Test-ClientNeedsRelaunch($Proc = (Get-ClientProcess)) { [bool](Get-FrontEndReturns $Proc).needs_relaunch }
# A tool just sent disconnect.lua (or saw the client fall back to the menu): count it now, before the log shows it.
function Register-FrontEndReturn([string]$Why, $Proc = (Get-ClientProcess)) {
    if (-not $Proc) { return 0 }
    $n = (Get-FrontEndReturns $Proc).returns + 1
    Write-FrontEndRecord $Proc $n $Why
    $n
}

# Start the client the way the game is started (Steam -applaunch). DW_CLIENT_LAUNCH (tests: the fake client's exe,
# args in DW_CLIENT_LAUNCH_ARGS) replaces it so an offline test can relaunch without Steam or the game.
function Start-ClientProcess {
    if ($env:DW_CLIENT_LAUNCH) {
        $sp = @{ FilePath = $env:DW_CLIENT_LAUNCH; WindowStyle = 'Hidden' }
        if ($env:DW_CLIENT_LAUNCH_ARGS) { $sp.ArgumentList = $env:DW_CLIENT_LAUNCH_ARGS }
        Start-Process @sp | Out-Null
    } else {
        & $SteamExe -applaunch $ClientAppId @ClientArgs
    }
}
# Kill the client process tree (tools/stop_client.ps1 without -Hold); the character is saved server-side.
function Stop-ClientProcess {
    $tree = @(Get-ClientProcessTree)
    if (-not $tree) { return @() }
    $tree | Stop-Process -Force -ErrorAction SilentlyContinue
    $tree | ForEach-Object { try { $_.WaitForExit(30000) | Out-Null } catch {} }
    @($tree | ForEach-Object { "$($_.ProcessName)($($_.Id))" })
}
