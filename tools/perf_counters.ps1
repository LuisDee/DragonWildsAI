# Host performance counters for the lag investigation, using Windows' own collector (logman / PLA),
# not a hand-rolled poller. Samples every 10 s to CSV under logs\perf\host_counters_<mmddhhmm>.csv.
# A new file starts on every 'start' and every 24 h (-cnf). tools\perf_report.py reads them.
#
#   powershell -File tools\perf_counters.ps1 start    # create the collector set if missing, then start it
#   powershell -File tools\perf_counters.ps1 status
#   powershell -File tools\perf_counters.ps1 stop
#   powershell -File tools\perf_counters.ps1 recreate # delete + create (after editing the counter list)
#
# Needs an elevated shell. Collector sets do not auto-start at boot: run 'start' after a reboot.
# Notes: wildcard instances (python*, Network Interface(*)) are expanded when collection starts, so
# a python process launched later only appears after the next start. Process "% Processor Time" is
# per core (100 = one full core, 400 = all 4 vCPUs).
param([ValidateSet('start', 'stop', 'status', 'recreate')][string]$Action = 'status',
      [int]$IntervalSec = 10)
. "$PSScriptRoot\config.ps1"

$SetName = 'DWPerf'
$OutDir  = Join-Path $RepoRoot 'logs\perf'
$Server  = [IO.Path]::GetFileNameWithoutExtension($ServerExe)   # RSDragonwildsServer-Win64-Shipping

$Counters = @(
    '\Processor(*)\% Processor Time'                 # _Total plus each core
    '\System\Processor Queue Length'
    '\Memory\Available MBytes'
    '\Memory\Pages/sec'
    '\PhysicalDisk(_Total)\% Disk Time'
    '\PhysicalDisk(_Total)\Avg. Disk sec/Transfer'
    '\Network Interface(*)\Bytes Total/sec'
    '\UDPv4\Datagrams/sec'
    '\UDPv4\Datagrams Received Errors'               # receive-buffer drops on the host
    "\Process($Server)\% Processor Time"
    "\Process($Server)\Working Set"
    "\Process($Server)\IO Data Bytes/sec"
    '\Process(MsMpEng)\% Processor Time'             # Defender
    '\Process(MsMpEng)\IO Data Bytes/sec'
    '\Process(python*)\% Processor Time'
)

function Get-SetStatus {
    $out = logman query $SetName 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { return $null }
    if ($out -match '(?m)^Status:\s+(\S+)') { return $Matches[1] }
    return 'Unknown'
}

function New-Set {
    New-Item -ItemType Directory -Force $OutDir | Out-Null
    $cf = Join-Path $OutDir 'counters.txt'
    # logman reads the counter list from a file (-cf): avoids quoting trouble with '%' and spaces.
    Set-Content -Path $cf -Value $Counters -Encoding ascii
    $interval = [TimeSpan]::FromSeconds($IntervalSec).ToString('hh\:mm\:ss')
    logman create counter $SetName -cf $cf -si $interval -f csv -v mmddhhmm -cnf 24:00:00 `
        -o (Join-Path $OutDir 'host_counters') -ow | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "logman create failed ($LASTEXITCODE)" }
}

switch ($Action) {
    'recreate' {
        if (Get-SetStatus) { logman stop $SetName 2>&1 | Out-Null; logman delete $SetName | Out-Host }
        New-Set
        logman start $SetName | Out-Host
    }
    'start' {
        $st = Get-SetStatus
        if (-not $st) { New-Set; $st = 'Stopped' }
        if ($st -eq 'Running') { Write-Host "$SetName already running." } else { logman start $SetName | Out-Host }
    }
    'stop' {
        if (Get-SetStatus) { logman stop $SetName | Out-Host } else { Write-Host "$SetName does not exist." }
    }
    'status' {
        $st = Get-SetStatus
        if (-not $st) { Write-Host "$SetName does not exist (run: perf_counters.ps1 start)."; break }
        logman query $SetName | Out-Host
        Get-ChildItem $OutDir -Filter 'host_counters*.csv' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime | Select-Object -Last 3 Name, Length, LastWriteTime | Format-Table | Out-Host
    }
}
