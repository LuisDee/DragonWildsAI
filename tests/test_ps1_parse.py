"""Every PowerShell script in tools/ parses (2026-11-17: a patch split a comment in start_server.ps1, which then failed
to parse; the watchdog calls it on every crash and hang, and nothing showed it until a world restore 20 min later)."""
import subprocess
import sys
from pathlib import Path

import pytest

TOOLS = Path(__file__).resolve().parents[1] / "tools"
CHECK = ("$bad = 0; foreach ($f in Get-ChildItem -Path '{d}' -Filter *.ps1) {{ $t = $null; $e = $null; "
         "$null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$t, [ref]$e); "
         "foreach ($x in $e) {{ $bad++; Write-Output ($f.Name + ':' + $x.Extent.StartLineNumber + ' ' + $x.Message) }} }}; exit $bad")


@pytest.mark.skipif(sys.platform != "win32", reason="Windows PowerShell")
def test_every_tools_script_parses():
    r = subprocess.run(["powershell", "-NoProfile", "-Command", CHECK.format(d=TOOLS)], capture_output=True, text=True,
                       timeout=120)
    assert r.returncode == 0, r.stdout + r.stderr
