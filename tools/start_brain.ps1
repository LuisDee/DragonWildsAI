# Run the live brain (python -m brain.run_live) with the model env vars loaded from the user
# environment (ANTHROPIC_API_KEY, DW_CONTROLLER_MODEL, DW_PLANNER_MODEL are stored there, never in files).
#   -Body server  the server puppet mod (bridge_io\), the default
#   -Body client  Claude's own game client (client_mod\, client_io\bridge\; route R2)
#   -DryRun       rule-based fake models, no API spend
#   -World <guid> per-world state folder (overrides the user-level DW_WORLD_GUID, e.g. -World dev on the dev server)
param([switch]$DryRun, [ValidateSet('server', 'client')][string]$Body = $(if ($env:DW_BODY) { $env:DW_BODY } else { 'server' }),
      [string]$World = '')
. "$PSScriptRoot\config.ps1"
foreach ($name in 'ANTHROPIC_API_KEY', 'DW_CONTROLLER_MODEL', 'DW_PLANNER_MODEL', 'DW_CHAT_PREFIXES', 'DW_WORLD_GUID') {
    $v = [Environment]::GetEnvironmentVariable($name, 'User')
    if ($v) { Set-Item "env:$name" $v }
}
if ($World) { $env:DW_WORLD_GUID = $World }
$env:DW_BODY = $Body
$env:DW_BRIDGE_DIR = if ($Body -eq 'client') { $ClientBridgeDir } else { $BridgeDir }
$py = Join-Path $RepoRoot '.venv\Scripts\python.exe'
$runArgs = @('-m', 'brain.run_live', '--body', $Body)
if ($DryRun) { $runArgs += '--dry-run' }
Set-Location $RepoRoot
& $py @runArgs
