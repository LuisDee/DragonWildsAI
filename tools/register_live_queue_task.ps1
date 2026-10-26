# Auto-drain the live validation queue (tools/live_queue.py) with Windows Task Scheduler: every 5 minutes run
# `live_queue.py run --if-free`, which is a quiet no-op unless the client slot is free, no hold file exists and a
# check is pending. MultipleInstances IgnoreNew: a drain still running when the next trigger fires is left alone
# (live_queue.py also holds its own OS file lock, so a manual run and the task can't overlap either).
#   powershell -File tools\register_live_queue_task.ps1              # register (or update) the task
#   powershell -File tools\register_live_queue_task.ps1 -Unregister  # remove it
#   powershell -File tools\register_live_queue_task.ps1 -Status      # show it
# Interactive logon on purpose (like DragonwildsClientWatchdog): the bridge files and the client live in this
# user's session. Why a scheduled task and not a hook in client_slot release: an expired lock (an agent that died)
# never calls release, and nothing would drain the queue; a timer covers both. Sources: ARCHITECTURE.md §8.7.
param([switch]$Unregister, [switch]$Status, [int]$EveryMinutes = 5)
. "$PSScriptRoot\config.ps1"
$name = 'DragonwildsLiveQueue'
if ($Unregister) {
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Removed scheduled task $name."; exit 0
}
if ($Status) {
    $t = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if (-not $t) { Write-Host "$name not registered."; exit 0 }
    $i = $t | Get-ScheduledTaskInfo
    [pscustomobject]@{ state = $t.State; last_run = $i.LastRunTime; last_result = $i.LastTaskResult; next_run = $i.NextRunTime } | Format-List
    exit 0
}
$py = Join-Path $RepoRoot '.venv\Scripts\python.exe'
if (-not (Test-Path $py)) { throw "no venv python at $py" }
$log = Join-Path $RepoRoot 'logs\live_queue\task.log'
New-Item -ItemType Directory -Force (Split-Path $log) | Out-Null
# cmd /c only to append stdout/stderr to a log; the python process itself is the drain
$cmdArgs = "/c `"`"$py`" -m tools.live_queue run --if-free >> `"$log`" 2>&1`""
$action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument $cmdArgs -WorkingDirectory $RepoRoot
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $EveryMinutes)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 3)
Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "Registered ${name}: every $EveryMinutes min, '$py -m tools.live_queue run --if-free' (log $log)."
