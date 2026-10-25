# Headless client feasibility test (route R2 gate 1, step 1): launch the Dragonwilds CLIENT with no
# rendering beside the running dedicated server and record memory/CPU and how far it boots.
# Safety: kills the client if free RAM drops below $MinFreeMB so the server is never starved.
# Usage: powershell -File tools/client_headless_test.ps1 [-Seconds 240] [-MinFreeMB 600]
param([int]$Seconds = 240, [int]$MinFreeMB = 600)

. "$PSScriptRoot\config.ps1"
$steam    = 'C:\Program Files (x86)\Steam\steam.exe'
$clientRx = 'RSDragonwilds-Win64-Shipping'
$logDir   = Join-Path $env:LOCALAPPDATA 'RSDragonwilds\Saved\Logs'
$out      = Join-Path $RepoRoot ("logs\client_headless_{0}.jsonl" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

& $steam -applaunch 1374490 -nullrhi -nosound -unattended -nosplash -log
$t0 = Get-Date
while (((Get-Date) - $t0).TotalSeconds -lt $Seconds) {
    Start-Sleep -Seconds 5
    $os   = Get-CimInstance Win32_OperatingSystem
    $free = [math]::Round($os.FreePhysicalMemory / 1KB)
    $c    = Get-Process | Where-Object { $_.ProcessName -like "$clientRx*" } | Select-Object -First 1
    $s    = Get-Process | Where-Object { $_.ProcessName -like 'RSDragonwildsServer*' } | Select-Object -First 1
    $row  = [ordered]@{
        t_s        = [math]::Round(((Get-Date) - $t0).TotalSeconds)
        free_mb    = $free
        client_mb  = if ($c) { [math]::Round($c.WorkingSet64 / 1MB) } else { $null }
        client_cpu = if ($c) { [math]::Round($c.CPU) } else { $null }
        server_mb  = if ($s) { [math]::Round($s.WorkingSet64 / 1MB) } else { $null }
    }
    ($row | ConvertTo-Json -Compress) | Add-Content $out
    if ($c -and $free -lt $MinFreeMB) {
        Stop-Process -Id $c.Id -Force
        (@{ event = 'killed_low_memory'; free_mb = $free } | ConvertTo-Json -Compress) | Add-Content $out
        break
    }
}
$c = Get-Process | Where-Object { $_.ProcessName -like "$clientRx*" } | Select-Object -First 1
(@{ event = 'end'; client_running = [bool]$c; log_dir = $logDir } | ConvertTo-Json -Compress) | Add-Content $out
Write-Output $out
