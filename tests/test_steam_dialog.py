"""tools/steam_dialog_lib.ps1: which Steam prompt holds the client's launch (2026-11-17: "Unable to Sync" swallowed every
-applaunch for 45 min and client_boot only said launch_timeout). Pure functions, dot-sourced alone; no Steam, no UIA."""
import json
import subprocess
import sys
from pathlib import Path

import pytest

LIB = Path(__file__).resolve().parents[1] / "tools" / "steam_dialog_lib.ps1"
pytestmark = pytest.mark.skipif(sys.platform != "win32", reason="Windows PowerShell")

# The incident's own console_log lines (C:\Program Files (x86)\Steam\logs\console_log.txt, 2026-11-18 local).
INCIDENT = """\
[2026-11-18 00:01:54] GameAction [AppID 1374490, ActionID 1798] : LaunchApp changed task to WaitingGameWindow with ""
[2026-11-18 00:01:54] GameAction [AppID 1374490, ActionID 1798] : LaunchApp changed task to Completed with ""
[2026-11-18 00:06:21] GameAction [AppID 1374490, ActionID 1799] : LaunchApp changed task to SynchronizingCloud with ""
[2026-11-18 00:06:21] GameAction [AppID 1374490, ActionID 1799] : LaunchApp waiting for user response to SynchronizingCloud "syncfailed"
[2026-11-18 00:06:49] LogonFailure No Connection
[2026-11-18 00:08:52] ExecCommandLine: ""C:\\Program Files (x86)\\Steam\\steam.exe" -applaunch 1374490 -nullrhi"
[2026-11-18 00:10:00] GameAction [AppID 999, ActionID 5] : LaunchApp waiting for user response to Other "x"
"""
ANSWERED = INCIDENT + """\
[2026-11-18 00:51:27] GameAction [AppID 1374490, ActionID 1799] : LaunchApp continues with user response "IgnoreCloud"
[2026-11-18 00:51:29] GameAction [AppID 1374490, ActionID 1799] : LaunchApp changed task to Completed with ""
"""


def ps(body: str) -> dict:
    cmd = f". '{LIB}'; $r = & {{ {body} }}; $r | ConvertTo-Json -Compress -Depth 4"
    r = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", cmd],
                       capture_output=True, text=True, timeout=60)
    assert r.returncode == 0 and not r.stderr.strip(), r.stdout + r.stderr
    return json.loads(r.stdout) if r.stdout.strip() else None


def kind_from_log(tmp_path: Path, text: str, texts: str = "@()"):
    log = tmp_path / "console_log.txt"
    log.write_text(text, encoding="utf-8")
    return ps(f"$p = Get-SteamLaunchPrompt '{log}' 1374490; "
              f"[ordered]@{{ kind = (Get-SteamDialogKind $p {texts}); task = $p.task; detail = $p.detail; waiting = $p.waiting }}")


def test_incident_log_is_the_cloud_dialog(tmp_path):
    r = kind_from_log(tmp_path, INCIDENT)
    assert r == {"kind": "cloud_sync", "task": "SynchronizingCloud", "detail": "syncfailed", "waiting": True}


def test_answered_prompt_is_nothing(tmp_path):
    r = kind_from_log(tmp_path, ANSWERED)
    assert r["kind"] is None and r["waiting"] is False and r["task"] == "Completed"


def test_eula_and_unknown_and_auto_prompts(tmp_path):
    line = '[t] GameAction [AppID 1374490, ActionID 7] : LaunchApp waiting for user response to {} "{}"\n'
    assert kind_from_log(tmp_path, line.format("ShowEula", ""))["kind"] == "eula"
    r = kind_from_log(tmp_path, line.format("ShowCDKey", "abc"))
    assert r["kind"] == "unknown" and r["task"] == "ShowCDKey" and r["detail"] == "abc"
    # Steam answers these itself in the same second: never a dialog
    assert kind_from_log(tmp_path, line.format("ShowInterstitials", ""))["kind"] is None
    assert kind_from_log(tmp_path, line.format("CreatingProcess", ""))["kind"] is None


def test_window_text_alone_names_the_cloud_dialog(tmp_path):
    # the log rotated or names nothing, but a Steam window shows the dialog's text
    assert kind_from_log(tmp_path, ANSWERED, "@('Steam', 'Unable to Sync', 'Play anyway', 'Cancel')")["kind"] == "cloud_sync"
    assert kind_from_log(tmp_path, ANSWERED, "@('Steam', 'Library')")["kind"] is None


def test_missing_log_is_no_prompt(tmp_path):
    assert ps(f"[ordered]@{{ p = (Get-SteamLaunchPrompt '{tmp_path / 'nope.txt'}' 1374490); "
              f"k = (Get-SteamDialogKind $null @()) }}") == {"p": None, "k": None}


def test_button_name_match_is_loose_on_case_and_space():
    r = ps("@((Test-SteamButtonName 'Play Anyway' 'Play anyway'), (Test-SteamButtonName ' Play  anyway ' 'Play anyway'), "
           "(Test-SteamButtonName 'Cancel' 'Play anyway'), (Test-SteamButtonName '' 'Play anyway'))")
    assert r == [True, True, False, False]


def test_window_summary_line():
    r = ps("Format-SteamUiWindows @([pscustomobject]@{ title = 'Steam'; class = 'SDL_app'; rect = '480,96 1280x800'; "
           "nodes = 3; texts = @() }, [pscustomobject]@{ title = 'Unable to Sync'; class = 'SDL_app'; rect = '1,2 3x4'; "
           "nodes = 9; texts = @('Warning', 'Play anyway') })")
    assert r == ("'Steam' [SDL_app 480,96 1280x800, 3 uia nodes]; "
                 "'Unable to Sync' [SDL_app 1,2 3x4, 9 uia nodes]: Warning | Play anyway")
