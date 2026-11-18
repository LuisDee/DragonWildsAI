# Steam launch prompts that wait for a click (dot-sourced by tools/client_lib.ps1; no other dependencies, so a test
# can dot-source it alone: tests/test_steam_dialog.py).
#
# 2026-11-17 23:06Z-23:51Z: Steam was offline (console_log "LogonFailure No Connection"), the cloud check before the
# launch failed and Steam showed "Unable to Sync ... Play anyway / Cancel". The launch action waited on that dialog;
# every later -applaunch was swallowed (ExecCommandLine, no new GameAction) and client_boot said launch_timeout for
# 45 min. Clicking "Play anyway" continued the waiting action (console_log: continues with user response "IgnoreCloud").
#
# How a prompt is read (verified on build 1792618285 of steamwebhelper):
#   - Steam's own logs name it. console_log.txt:
#       GameAction [AppID 1374490, ActionID 1799] : LaunchApp waiting for user response to SynchronizingCloud "syncfailed"
#     webhelper_js.txt: "showing cloud sync failed dialog 1374490". Prompts that Steam answers itself in the same
#     second (ShowInterstitials, CreatingProcess) are not dialogs.
#   - Its window: every Steam UI window is a top-level "SDL_app" window of steamwebhelper.exe. Its title is a native
#     window title, so UI Automation reads it. Its CONTENT is a CEF page, and Steam's CEF exposes no accessibility tree
#     (2026-11-18: the main window's UIA tree is 3 panes ending in an empty "Chrome Legacy Window", and MSAA on that
#     window reports 0 children; CEF leaves renderer accessibility off unless the host turns it on). So a button is
#     pressed by UIA Invoke only where Steam exposes it; where it does not, the dialog is reported, never clicked blind.

$SteamDialogAutoTasks = @('ShowInterstitials', 'CreatingProcess')   # Steam continues these itself at once

# The last LaunchApp line for an app in Steam's console log, parsed: $null when the log has none, else
# {task, detail, waiting, line}. waiting = the action is waiting for a user response right now.
function Get-SteamLaunchPrompt([string]$LogPath, [int]$AppId) {
    if (-not $LogPath -or -not (Test-Path $LogPath)) { return $null }
    $last = $null
    try {
        $last = Select-String -Path $LogPath -Pattern "AppID $AppId, ActionID \d+\] : LaunchApp" -ErrorAction Stop | Select-Object -Last 1
    } catch { return $null }
    if (-not $last) { return $null }
    ConvertFrom-SteamLaunchLine $last.Line
}

function ConvertFrom-SteamLaunchLine([string]$Line) {
    if ($Line -match 'LaunchApp waiting for user response to (\S+) "([^"]*)"') {
        return [pscustomobject]@{ task = $Matches[1]; detail = $Matches[2]; waiting = $true; line = $Line.Trim() }
    }
    $task = if ($Line -match 'LaunchApp changed task to (\S+)') { $Matches[1] } elseif ($Line -match 'LaunchApp (\S+)') { $Matches[1] } else { '' }
    [pscustomobject]@{ task = $task; detail = ''; waiting = $false; line = $Line.Trim() }
}

# What kind of dialog holds the launch, from the log prompt and/or the texts seen in Steam's windows.
#   'cloud_sync' : "Unable to Sync" (cloud check failed; answer "Play anyway": saves are local, Steam Cloud is off)
#   'eula'       : the game's EULA (tools/client_lib.ps1 Get-SteamLaunchBlock: steam_eula_pending, never answered here)
#   'unknown'    : the launch waits on some other prompt, or a Steam window shows a dialog we do not know
#   $null        : nothing waits
function Get-SteamDialogKind($Prompt, [string[]]$Texts = @()) {
    $joined = (@($Texts) | Where-Object { $_ }) -join "`n"
    if ($Prompt -and $Prompt.waiting -and $Prompt.task -eq 'SynchronizingCloud') { return 'cloud_sync' }
    if ($joined -match '(?i)\bUnable to Sync\b') { return 'cloud_sync' }
    if ($Prompt -and $Prompt.waiting -and $Prompt.task -eq 'ShowEula') { return 'eula' }
    if ($Prompt -and $Prompt.waiting -and $Prompt.task -notin $SteamDialogAutoTasks) { return 'unknown' }
    $null
}

# The button that answers a known dialog, matched by name (case and spacing loose: "Play anyway" / "Play Anyway").
function Test-SteamButtonName([string]$Name, [string]$Want) {
    if (-not $Name -or -not $Want) { return $false }
    (($Name -replace '\s+', ' ').Trim()) -ieq (($Want -replace '\s+', ' ').Trim())
}

function Initialize-SteamUia {
    try { Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes -ErrorAction Stop; $true } catch { $false }
}

# Steam's top-level windows (steamwebhelper.exe) through UI Automation, read only: title, class, rect, the names of
# whatever UIA exposes inside (texts) and the buttons among them. Returns @() when UIA is missing or Steam is down.
function Get-SteamUiWindows([int]$MaxNodes = 400) {
    if (-not (Initialize-SteamUia)) { return @() }
    $pids = @(Get-Process steamwebhelper -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    if (-not $pids.Count) { return @() }
    $A = [System.Windows.Automation.AutomationElement]
    $out = @()
    try {
        $tops = $A::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
    } catch { return @() }
    foreach ($w in $tops) {
        try {
            $c = $w.Current
            if ($pids -notcontains $c.ProcessId) { continue }
            $texts = New-Object System.Collections.ArrayList; $buttons = New-Object System.Collections.ArrayList
            $all = $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
            $n = 0
            foreach ($e in $all) {
                if (++$n -gt $MaxNodes) { break }
                $ec = $e.Current
                if ($ec.Name -and $ec.Name -ne 'Chrome Legacy Window') { [void]$texts.Add(($ec.Name -replace '\s+', ' ').Trim()) }
                if ($ec.ControlType -eq [System.Windows.Automation.ControlType]::Button -and $ec.Name) { [void]$buttons.Add($ec.Name) }
            }
            $r = $c.BoundingRectangle
            $out += [pscustomobject]@{
                pid = $c.ProcessId; hwnd = $c.NativeWindowHandle; title = $c.Name; class = $c.ClassName
                rect = "{0},{1} {2}x{3}" -f [int]$r.X, [int]$r.Y, [int]$r.Width, [int]$r.Height
                nodes = $all.Count; texts = @($texts); buttons = @($buttons); element = $w
            }
        } catch { }
    }
    $out
}

# One line per window for a log: title [class rect, nodes] texts...
function Format-SteamUiWindows($Windows) {
    (@($Windows) | ForEach-Object {
        $t = @($_.texts | Select-Object -First 12) -join ' | '
        "'$($_.title)' [$($_.class) $($_.rect), $($_.nodes) uia nodes]" + $(if ($t) { ": $t" } else { '' })
    }) -join '; '
}

# Press a button by UIA Invoke (no mouse, no focus change). Returns the window title it was pressed in, else $null.
function Invoke-SteamDialogButton($Windows, [string]$ButtonName) {
    if (-not (Initialize-SteamUia)) { return $null }
    $A = [System.Windows.Automation.AutomationElement]
    $cond = New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
    foreach ($w in @($Windows)) {
        if (-not $w.element) { continue }
        try {
            foreach ($b in $w.element.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)) {
                if (-not (Test-SteamButtonName $b.Current.Name $ButtonName)) { continue }
                $pat = $null
                if ($b.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pat)) {
                    $pat.Invoke(); return $w.title
                }
            }
        } catch { }
    }
    $null
}
