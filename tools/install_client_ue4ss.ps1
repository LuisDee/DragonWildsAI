# Install UE4SS + Ultimate ASI Loader into Claude's game CLIENT (route R2) by copying the already-
# verified server install (same UE4SS build, same loader method), then deploy client_mod as DWClient.
# The server's own mods (DWCompanion etc.) are NOT copied: the client gets only DWClient.
# Usage: powershell -File tools/install_client_ue4ss.ps1   (client must not be running)
. "$PSScriptRoot\config.ps1"
$clientWin64 = if ($env:DW_CLIENT_WIN64) { $env:DW_CLIENT_WIN64 } else {
    'C:\Program Files (x86)\Steam\steamapps\common\RSDragonwilds\RSDragonwilds\Binaries\Win64' }
if (Get-Process | Where-Object { $_.ProcessName -like 'RSDragonwilds-Win64-Shipping*' }) { throw 'Close the client first.' }

$dst = Join-Path $clientWin64 'ue4ss'
New-Item -ItemType Directory -Force (Join-Path $dst 'Mods') | Out-Null
Copy-Item (Join-Path $ServerWin64 'ue4ss\UE4SS.dll') $dst -Force
Copy-Item (Join-Path $ServerWin64 'ue4ss\UE4SS-settings.ini') $dst -Force
Copy-Item (Join-Path $ServerWin64 'ue4ss\Mods\shared') (Join-Path $dst 'Mods') -Recurse -Force
Copy-Item (Join-Path $ServerWin64 'version.dll') $clientWin64 -Force
Copy-Item (Join-Path $ServerWin64 'version.ini') $clientWin64 -Force

$mod = Join-Path $dst 'Mods\DWClient'
New-Item -ItemType Directory -Force $mod | Out-Null
Copy-Item (Join-Path $RepoRoot 'client_mod\*') $mod -Recurse -Force
Set-Content (Join-Path $mod 'enabled.txt') '' -Encoding ascii
Set-Content (Join-Path $dst 'Mods\mods.txt') "DWClient : 1`r`n" -Encoding ascii
Write-Output "UE4SS + DWClient installed into $clientWin64"
