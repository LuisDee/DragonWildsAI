# Install UE4SS (experimental-latest; stable v3.0.1 predates UE 5.4+) into the server's Win64.
# The dedicated server doesn't load dwmapi.dll, so the proxy goes in as version.dll
# (per kevinw9092/RSE-Server; see docs/research/2026-10-25-ue4ss-chat-bridge.md).
param([string]$Asset)
. "$PSScriptRoot\config.ps1"

if (Get-ServerProcess) { throw 'Stop the server first (tools\stop_server.ps1).' }

$rel = Invoke-RestMethod 'https://api.github.com/repos/UE4SS-RE/RE-UE4SS/releases/tags/experimental-latest'
$zip = if ($Asset) { $rel.assets | Where-Object name -eq $Asset } else { $rel.assets | Where-Object name -like 'UE4SS_v*.zip' | Select-Object -First 1 }
if (-not $zip) { throw 'UE4SS zip asset not found' }

# Downloads are untrusted: extract into a fresh, empty temp dir.
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("ue4ss-" + [guid]::NewGuid())
New-Item -ItemType Directory $tmp | Out-Null
Invoke-WebRequest $zip.browser_download_url -OutFile "$tmp\ue4ss.zip"
Expand-Archive "$tmp\ue4ss.zip" "$tmp\x"

# Keep existing settings and mods on reinstall; only replace the binaries.
$dstUe4ss = Join-Path $ServerWin64 'ue4ss'
if (Test-Path $dstUe4ss) {
    Copy-Item "$tmp\x\ue4ss\UE4SS.dll" $dstUe4ss -Force
} else {
    Copy-Item "$tmp\x\ue4ss" $dstUe4ss -Recurse
}
Copy-Item "$tmp\x\dwmapi.dll" (Join-Path $ServerWin64 'version.dll') -Force
Remove-Item $tmp -Recurse -Force
Write-Host "Installed $($zip.name) into $ServerWin64 (proxy: version.dll)"
