# Copy the repo's mod/ into the server's UE4SS Mods folder and enable it.
# -Dump: create dump.flag so the mod regenerates reflection dumps ~2 min after next start.
param([switch]$Dump)
. "$PSScriptRoot\config.ps1"

$src = Join-Path $RepoRoot 'mod'
if (-not (Test-Path (Join-Path $ServerWin64 'ue4ss'))) { throw "UE4SS not installed in $ServerWin64 (run tools\install_ue4ss.ps1)" }

if (Test-Path $ModDeployDir) { Remove-Item $ModDeployDir -Recurse -Force }
New-Item -ItemType Directory -Force $ModDeployDir, $ModLogDir | Out-Null
Get-ChildItem $src -Directory | Where-Object Name -ne 'tests' | ForEach-Object { Copy-Item $_.FullName (Join-Path $ModDeployDir $_.Name) -Recurse }
Get-ChildItem $ModDeployDir -Recurse -Filter .gitkeep | Remove-Item
New-Item -ItemType File (Join-Path $ModDeployDir 'enabled.txt') -Force | Out-Null
if ($Dump) { New-Item -ItemType File (Join-Path $ModDeployDir 'dump.flag') -Force | Out-Null }
Write-Host "Deployed $ModName to $ModDeployDir$(if ($Dump) { ' (dump scheduled)' })"
