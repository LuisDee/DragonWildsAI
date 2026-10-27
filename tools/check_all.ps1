# The regression gate: every Python test, every Lua suite (client_mod + legacy mod) and the North Star
# guardrails. Nothing is hot-reloaded into the live client, no brain restart, no commit unless this passes.
# Usage: powershell -File tools\check_all.ps1 [-Python C:\path\to\python.exe]
param([string]$Python = '.venv\Scripts\python.exe')
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
& $Python -m pytest -q -p no:cacheprovider tests
$code = $LASTEXITCODE
if ($code -eq 0) { Write-Host 'CHECK_ALL: GREEN' } else { Write-Host "CHECK_ALL: RED (exit $code)" }
exit $code
