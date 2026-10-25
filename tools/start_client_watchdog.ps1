# Start tools\client_watchdog.ps1 as a hidden background process (once), like start_watchdog.ps1 for
# the server. It runs in this interactive session on purpose: Steam and the game client live in the
# logged-on user's session, which a Windows service (NSSM/WinSW, session 0) cannot drive.
#   powershell -File tools\start_client_watchdog.ps1            # start (no-op if running)
#   powershell -File tools\start_client_watchdog.ps1 -Stop      # stop it (the client keeps running)
#   powershell -File tools\start_client_watchdog.ps1 -Register  # also start it at every logon (Task Scheduler)
# Extra watchdog switches pass through: -WatchdogArgs '-NoDevServer','-DryRun'
# Pause client recovery without stopping it: create logs\client.hold (or tools\stop_client.ps1 -Hold).
param([switch]$Stop, [switch]$Register, [string[]]$WatchdogArgs = @())
. "$PSScriptRoot\config.ps1"

$script = Join-Path $PSScriptRoot 'client_watchdog.ps1'
$running = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*client_watchdog.ps1*' -and $_.CommandLine -notlike '*start_client_watchdog.ps1*' }
if ($Stop) {
    if (-not $running) { Write-Host 'Client watchdog not running.'; exit 0 }
    $running | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    Write-Host "Client watchdog stopped (pid $($running.ProcessId -join ', '))."; exit 0
}
if ($Register) {
    # At logon of this user, only while logged on (interactive: needs the same session as Steam).
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName 'DragonwildsClientWatchdog' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host 'Registered scheduled task DragonwildsClientWatchdog (at logon).'
}
if ($running) { Write-Host "Client watchdog already running (pid $($running.ProcessId -join ', '))."; exit 0 }
$argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script) + $WatchdogArgs
$p = Start-Process powershell -ArgumentList $argList -WindowStyle Hidden -PassThru
Write-Host "Client watchdog started (pid $($p.Id)). Events: $(Join-Path $RepoRoot 'logs\client_watchdog.jsonl')"
