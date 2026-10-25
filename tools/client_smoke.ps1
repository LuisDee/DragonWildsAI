# Client smoke test (route R2, task R2.16): run after every game patch (docs/RUNBOOK-patch.md,
# "Claude's game client"), or whenever the client was reinstalled. Read-only apart from a 2 m walk
# and one jump (only with -AllowMove: the locomotion owner/main must clear moving the pawn) and one
# chat line (only with -Chat: it is Luis's shared world).
#
#   boot      tools\client_boot.ps1 (idempotent; in the world with the pawn)   [-NoBoot: probe only]
#   services  bridge services chat / vitals / fed_reflex running
#   walk      move.lua go_to 2 m along the facing; displacement >= 1.3 m          [-AllowMove]
#   jump      Jump(); height rises >= 30 cm                                     [-AllowMove]
#   chat      say one line; the server echoes it back into chat.jsonl           [-Chat]
#   inventory inventory.list answers hotbar/bag/loadout
#   equip     the loadout (worn/held) reads back with at least one item
#
# Usage: powershell -File tools\client_smoke.ps1 [-AllowMove] [-Chat] [-NoBoot] [-Release]
# Report: logs\client_smoke_<ts>.json; exit 0 when every step that ran passed.
param([switch]$AllowMove, [switch]$Chat, [switch]$NoBoot, [switch]$Release)
. "$PSScriptRoot\client_lib.ps1"

$steps = New-Object System.Collections.ArrayList
function Step([string]$name, [string]$result, [string]$detail) {
    [void]$steps.Add([pscustomobject][ordered]@{ step = $name; result = $result; detail = (Protect-Secret $detail) })
    Write-Host ("{0,-10} {1,-5} {2}" -f $name, $result.ToUpper(), (Protect-Secret $detail))
}
function Cmd([string]$file, [int]$timeout = 20) {
    $name = [IO.Path]::GetFileNameWithoutExtension($file)
    $r = Invoke-ClientCmd -Path (Join-Path $ClientCmds $file) -Name "smk_$name" -TimeoutS $timeout
    if (-not $r) { Clear-ClientCmd "smk_$name"; return $null }
    $r
}
function Dist($a, $b) { [math]::Sqrt([math]::Pow($a[0] - $b[0], 2) + [math]::Pow($a[1] - $b[1], 2)) }

Write-Host "client smoke test, client build $(Get-ClientBuildId), $(Get-Date -Format o)"

# 1. boot / join
$p = $null
if ($NoBoot) {
    $p = Get-ClientProbe 12
    if ($p -and $p.map -eq 'L_World' -and $p.pawn) { Step 'boot' 'pass' "in world (probe only) pos=$($p.pos_m -join ',')" }
    else { Step 'boot' 'fail' ("not in world: " + $(if ($p) { "map=$($p.map) pawn=$($p.pawn)" } else { 'runner did not answer' })) }
} else {
    $bargs = @('-Quiet'); if ($Release) { $bargs += '-Release' }
    $b = & "$PSScriptRoot\client_boot.ps1" @bargs | Select-Object -Last 1
    if ($b -and $b.ok) { Step 'boot' 'pass' "in world in $($b.duration_s)s, actions: $(@($b.actions) -join '; ')" }
    else { Step 'boot' 'fail' "state=$($b.state) reason=$($b.reason)" }
    $p = Get-ClientProbe 12
}
$inWorld = $p -and $p.map -eq 'L_World' -and $p.pawn

if (-not $inWorld) {
    foreach ($n in 'services', 'walk', 'jump', 'chat', 'inventory', 'equip') { Step $n 'skip' 'not in world' }
} else {
    # 2. services
    $bad = @('chat', 'vitals', 'fed_reflex' | Where-Object { -not $p.bridge.services.$_ -or $p.bridge.services.$_.state -ne 'running' })
    if (-not $p.bridge.running) { Step 'services' 'fail' 'bridge not running' }
    elseif ($p.paused) { Step 'services' 'fail' '_G.DW_PAUSE still set (run unpause.lua)' }
    elseif ($bad.Count) { Step 'services' 'fail' ("not running: " + ($bad -join ', ')) }
    else { Step 'services' 'pass' 'chat, vitals, fed_reflex running' }

    # 3. walk 2 m
    if (-not $AllowMove) { Step 'walk' 'skip' 'needs -AllowMove (moves the pawn)' }
    else {
        $w = Cmd 'smoke_walk.lua'
        if (-not $w -or -not $w.ok -or -not $w.result.ok) { Step 'walk' 'fail' ("go_to did not start: " + ($w | ConvertTo-Json -Compress -Depth 4)) }
        else {
            $start = $w.result.start; $st = $null; $d = (Get-Date).AddSeconds(20)
            do { Start-Sleep -Milliseconds 700; $st = (Cmd 'smoke_move_status.lua').result }
            while ((Get-Date) -lt $d -and $st -and $st.mode -ne 'idle' -and -not ($st.result -and $st.result.status))
            $moved = if ($st -and $st.pos_m) { [math]::Round((Dist $st.pos_m $start), 2) } else { $null }
            $rs = if ($st -and $st.result) { $st.result.status } else { $st.status }
            if ($moved -ge 1.3) { Step 'walk' 'pass' "moved $moved m ($rs)" }
            else { Step 'walk' 'fail' "moved $moved m, status=$rs reason=$($st.result.reason)" }
        }
    }

    # 4. jump
    if (-not $AllowMove) { Step 'jump' 'skip' 'needs -AllowMove (moves the pawn)' }
    else {
        $j = Cmd 'smoke_jump.lua'
        if (-not $j -or -not $j.result.ok) { Step 'jump' 'fail' ("jump not sent: " + ($j | ConvertTo-Json -Compress -Depth 3)) }
        else {
            Start-Sleep -Seconds 2
            $jr = (Cmd 'smoke_jump_read.lua').result
            $dz = if ($jr) { [math]::Round($jr.max_dz_cm) } else { $null }
            if ($dz -ge 30) { Step 'jump' 'pass' "rose $dz cm ($($jr.samples) samples)" } else { Step 'jump' 'fail' "rose $dz cm" }
        }
    }

    # 5. chat round trip
    if (-not $Chat) { Step 'chat' 'skip' 'needs -Chat (writes in the shared world chat)' }
    else {
        $chatFile = Join-Path $ClientIo 'events\chat.jsonl'
        $t0 = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 1
        $c = Cmd 'smoke_chat.lua'
        if (-not $c -or -not $c.result.ok) { Step 'chat' 'fail' ("say failed: " + ($c | ConvertTo-Json -Compress -Depth 3)) }
        else {
            $echo = $null; $d = (Get-Date).AddSeconds(10)
            while (-not $echo -and (Get-Date) -lt $d) {
                Start-Sleep -Milliseconds 500
                $echo = Get-Content $chatFile -Tail 20 -ErrorAction SilentlyContinue | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} } |
                    Where-Object { $_.type -eq 'chat' -and $_.self -and $_.text -like '*smoke test*' -and $_.ts -ge $t0 } | Select-Object -First 1
            }
            if ($echo) { Step 'chat' 'pass' "server echoed it as '$($echo.from)'" } else { Step 'chat' 'fail' 'no echo within 10 s' }
        }
    }

    # 6. inventory + 7. equip (one read)
    $inv = Cmd 'inv_list.lua'
    $l = if ($inv -and $inv.ok) { $inv.result } else { $null }
    if ($l -and $l.ok -ne $false -and $null -ne $l.hotbar -and $null -ne $l.bag) {
        Step 'inventory' 'pass' ("hotbar $(@($l.hotbar).Count), bag $(@($l.bag).Count), empty slots $($l.empty_slots)")
        $worn = @($l.loadout | Where-Object { $_ })
        if ($worn.Count) { Step 'equip' 'pass' (($worn | ForEach-Object { "$($_.loadout_slot)=$($_.name)" }) -join ', ') }
        else { Step 'equip' 'fail' 'loadout empty' }
    } else {
        Step 'inventory' 'fail' ("inventory.list: " + $(if ($inv) { $inv | ConvertTo-Json -Compress -Depth 3 } else { 'no answer' }))
        Step 'equip' 'skip' 'no inventory read'
    }
}

$failed = @($steps | Where-Object result -eq 'fail')
$report = [ordered]@{ ts = (Get-Date).ToUniversalTime().ToString('o'); build = Get-ClientBuildId; ok = ($failed.Count -eq 0)
                      allow_move = [bool]$AllowMove; chat = [bool]$Chat; steps = @($steps) }
$outDir = if ($env:DW_CLIENT_SMOKE_DIR) { $env:DW_CLIENT_SMOKE_DIR } else { Join-Path $RepoRoot 'logs' }
$out = Join-Path $outDir ("client_smoke_{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
($report | ConvertTo-Json -Depth 5) | Set-Content -Encoding utf8 $out
Write-Host ("RESULT: {0} ({1} failed). Report: {2}" -f $(if ($report.ok) { 'PASS' } else { 'FAIL' }), $failed.Count, $out)
if ($report.ok) { exit 0 } else { exit 1 }
