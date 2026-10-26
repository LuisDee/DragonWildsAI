"""Restart Steam on this VM ONLY when it can log itself back in (BUGS L35, 2026-10-26).

A Steam restart without a remembered login leaves Steam at the login screen (ActiveUser 0) and Claude's client
cannot start until a person logs in over RDP. So before any restart this checks:
  * config/loginusers.vdf lists the account with "RememberPassword" "1", and
  * HKCU\\Software\\Valve\\Steam AutoLoginUser names that account.
Either missing -> refuse (exit 3), touch nothing.

  .venv\\Scripts\\python.exe tools/steam_restart.py --check            # report only
  .venv\\Scripts\\python.exe tools/steam_restart.py --yes              # shutdown, start -silent, wait for login
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
import time
from pathlib import Path

STEAM = Path(r"C:\Program Files (x86)\Steam")
ACCOUNT = "bootymaxer"


def remembered_login(loginusers_text: str, auto_login_user: str, account: str = ACCOUNT) -> tuple[bool, str]:
    """(ok, why). loginusers.vdf: "users" { "<steamid64>" { "AccountName" "x" "RememberPassword" "1" ... } }."""
    if not auto_login_user:
        return False, "HKCU AutoLoginUser is empty (Steam will not log in by itself)"
    if auto_login_user.lower() != account.lower():
        return False, f"AutoLoginUser is {auto_login_user!r}, not {account!r}"
    for block in re.findall(r'"\d{17}"\s*\{(.*?)\}', loginusers_text, flags=re.S):
        name = re.search(r'"AccountName"\s+"([^"]*)"', block, flags=re.I)
        rem = re.search(r'"RememberPassword"\s+"(\d)"', block, flags=re.I)
        if name and name.group(1).lower() == account.lower():
            if rem and rem.group(1) == "1":
                return True, "remembered login present"
            return False, f"{account} is in loginusers.vdf without RememberPassword 1"
    return False, f"{account} is not in config/loginusers.vdf"


def _auto_login_user() -> str:
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam") as k:
            return str(winreg.QueryValueEx(k, "AutoLoginUser")[0] or "")
    except OSError:
        return ""


def _active_user() -> int:
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam\ActiveProcess") as k:
            return int(winreg.QueryValueEx(k, "ActiveUser")[0] or 0)
    except OSError:
        return 0


def check(steam: Path = STEAM) -> tuple[bool, str]:
    f = steam / "config" / "loginusers.vdf"
    text = f.read_text(encoding="utf-8", errors="replace") if f.exists() else ""
    return remembered_login(text, _auto_login_user())


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--yes", action="store_true")
    ap.add_argument("--wait-s", type=int, default=180)
    a = ap.parse_args(argv)
    ok, why = check()
    print(f"remembered login: {ok} ({why})")
    if a.check or not ok:
        return 0 if ok else 3
    if not a.yes:
        print("re-run with --yes to restart Steam (stop Claude's client first: tools/stop_client.ps1 -Hold)")
        return 2
    exe = str(STEAM / "steam.exe")
    subprocess.run([exe, "-shutdown"], timeout=60)
    for _ in range(40):
        if b"steam.exe" not in subprocess.run(["tasklist"], capture_output=True).stdout.lower():
            break
        time.sleep(3)
    subprocess.Popen([exe, "-silent"])
    for _ in range(a.wait_s // 3):
        if _active_user():
            print(f"logged in again (ActiveUser {_active_user()})")
            return 0
        time.sleep(3)
    print("Steam did not log in again: a person must log in over RDP")
    return 4


if __name__ == "__main__":
    sys.exit(main())
