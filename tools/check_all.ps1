# The regression gate: every Python test, every Lua suite (client_mod + legacy mod) and the North Star
# guardrails. Nothing is hot-reloaded into the live client, no brain restart, no commit unless this passes.
# Usage: powershell -File tools\check_all.ps1     (exit code 0 = green)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
& .venv\Scripts\python.exe -m pytest -q -p no:cacheprovider tests
$code = $LASTEXITCODE
if ($code -eq 0) { Write-Host 'CHECK_ALL: GREEN' } else { Write-Host "CHECK_ALL: RED (exit $code)" }
exit $code
