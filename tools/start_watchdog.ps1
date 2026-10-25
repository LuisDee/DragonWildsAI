# Start tools\watchdog.ps1 as a hidden background process (once). To stop the server on purpose
# without the watchdog restarting it, create logs\server.stopped (stop_server.ps1 -Hold does this).
. "$PSScriptRoot\config.ps1"
$running = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*watchdog.ps1*' }
if ($running) { Write-Host "Watchdog already running (pid $($running.ProcessId -join ', '))."; exit 0 }
$p = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'watchdog.ps1') -WindowStyle Hidden -PassThru
Write-Host "Watchdog started (pid $($p.Id)). Log: $(Join-Path $RepoRoot 'logs\watchdog.log')"
