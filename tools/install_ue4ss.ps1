# Install UE4SS (experimental-latest; stable v3.0.1 predates UE 5.4+; Dragonwilds is UE 5.6)
# into the server's Win64, loaded via Ultimate ASI Loader.
# Why not UE4SS's own proxy: it is a dwmapi.dll proxy, the dedicated server never loads dwmapi,
# and renamed to version.dll it lacks version.dll's exports (the exe imports GetFileVersionInfoW
# etc.), so Windows raises an invisible "entry point not found" error and the server hangs.
# Ultimate ASI Loader is a universal version.dll proxy; version.ini tells it to load ue4ss\UE4SS.dll.
param([string]$Asset)
. "$PSScriptRoot\config.ps1"

if (Get-ServerProcess) { throw 'Stop the server first (tools\stop_server.ps1).' }

# Downloads are untrusted: extract each into a fresh, empty temp dir.
function Get-ReleaseZip([string]$repo, [string]$tag, [scriptblock]$pick) {
    $rel = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/tags/$tag"
    $a = $rel.assets | Where-Object $pick | Select-Object -First 1
    if (-not $a) { throw "asset not found in $repo@$tag" }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("dl-" + [guid]::NewGuid())
    New-Item -ItemType Directory $tmp | Out-Null
    Invoke-WebRequest $a.browser_download_url -OutFile "$tmp\a.zip"
    Expand-Archive "$tmp\a.zip" "$tmp\x"
    Write-Host "Downloaded $($a.name) ($($a.updated_at))"
    return "$tmp\x"
}

$ue = Get-ReleaseZip 'UE4SS-RE/RE-UE4SS' 'experimental-latest' { if ($Asset) { $_.name -eq $Asset } else { $_.name -like 'UE4SS_v*.zip' } }
$asi = Get-ReleaseZip 'ThirteenAG/Ultimate-ASI-Loader' 'x64-latest' { $_.name -eq 'version-x64.zip' }

# Keep existing settings and mods on reinstall; only replace the binary.
$dstUe4ss = Join-Path $ServerWin64 'ue4ss'
if (Test-Path $dstUe4ss) { Copy-Item "$ue\ue4ss\UE4SS.dll" $dstUe4ss -Force } else { Copy-Item "$ue\ue4ss" $dstUe4ss -Recurse }

Copy-Item "$asi\version.dll" (Join-Path $ServerWin64 'version.dll') -Force
@'
[GlobalSets]
LoadPlugins=1
LoadFromScriptsOnly=1
LoadRecursively=0
LoadExtraPlugins=ue4ss\UE4SS.dll
DebugLog=1
ModernUI=0
DisableCrashDumps=1
'@ | Set-Content -Encoding ascii (Join-Path $ServerWin64 'version.ini')

Remove-Item (Split-Path $ue -Parent), (Split-Path $asi -Parent) -Recurse -Force
Write-Host "Installed UE4SS + Ultimate ASI Loader (version.dll) into $ServerWin64"
