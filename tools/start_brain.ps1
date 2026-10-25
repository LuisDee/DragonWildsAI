# Run the live brain (python -m brain.run_live) with the model env vars loaded from the user
# environment (ANTHROPIC_API_KEY, DW_CONTROLLER_MODEL, DW_PLANNER_MODEL are stored there, never in files).
# Extra args pass through, e.g. -DryRun for no API spend.
param([switch]$DryRun)
. "$PSScriptRoot\config.ps1"
foreach ($name in 'ANTHROPIC_API_KEY', 'DW_CONTROLLER_MODEL', 'DW_PLANNER_MODEL', 'DW_CHAT_PREFIXES') {
    $v = [Environment]::GetEnvironmentVariable($name, 'User')
    if ($v) { Set-Item "env:$name" $v }
}
$env:DW_BRIDGE_DIR = $BridgeDir
$py = Join-Path $RepoRoot '.venv\Scripts\python.exe'
$runArgs = @('-m', 'brain.run_live')
if ($DryRun) { $runArgs += '--dry-run' }
Set-Location $RepoRoot
& $py @runArgs
