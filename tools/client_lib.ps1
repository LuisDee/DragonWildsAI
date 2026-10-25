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
        $_.ProcessName -in @($ClientProcName, 'RSDragonwilds', 'CrashReportClient') }
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
$ClientDefaultTarget = 'shockbyte'
$ClientTargetLease = Join-Path $ClientStateDir 'client_target.json'
function Get-TargetFile([string]$Name) {
    if (-not $Name -or $Name -eq $ClientDefaultTarget) { return $ClientSecrets }
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
# The server the client last loaded L_World from: the game log's "LoadMap: <host:port>/Game/Maps/World/L_World"
# line (the ?p= part is never returned). $null when unknown (menu, fresh log, no line).
function Get-JoinedServer {
    if (-not (Test-Path $ClientGameLog)) { return $null }
    $last = Select-String -Path $ClientGameLog -Pattern 'LoadMap: ' -ErrorAction SilentlyContinue | Select-Object -Last 1
    if (-not $last) { return $null }
    if ($last.Line -match 'LoadMap: ([0-9A-Za-z.\-]+:\d+)/Game/Maps/World/L_World') { return $Matches[1] }
    $null
}

# Run one client_mod command through the DWClient runner (client_mod/scripts/main.lua polls
# client_io/cmd every 2 s on the game thread). Same protocol as tools/client_cmd.sh. -Name lets a
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
