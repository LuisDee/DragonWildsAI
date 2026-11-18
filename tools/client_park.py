"""Parked: Claude's client logged off the dev world because nobody was playing him (tools/client_watchdog.ps1, park).

    .venv\\Scripts\\python.exe -m tools.client_park status
    .venv\\Scripts\\python.exe -m tools.client_park unpark      # boot him back in (what live_lock.held does first)

Why (docs/research/2026-11-17-idle-starvation.md): on the server his food and water drain on a clock, 5.5 and 4.15
points a minute whatever he does, and off it they do not. Between windows no brain runs on ClaudeDev, so nothing
fetches food, and the stay-fed reflex only eats what he carries: an idle body is dry in about 23 minutes and windows
then refuse it (2026-11-18 01:30Z: water 37). A real player who walks away logs off; the watchdog does the same when
there is no live-lock owner or waiter and no brain, and writes logs/state/client_park.json (mode "menu", or "off" when
the client process was closed). Whoever needs the world unparks him first: live_lock.held for every window and the
vitals rescue, start_brain.ps1 -Body client for real play. A client_boot that ends in the world clears the marker.
logs/state/client_stay (any content) keeps him in the world, e.g. while Luis wants to see him standing there.
"""
from __future__ import annotations

import json
import subprocess
import sys
import time
from pathlib import Path

from brain import paths
from tools import live_guard

ROOT = Path(__file__).resolve().parents[1]
LIVE = paths.LIVE_ROOT  # single per VM (the main working tree, also from a worktree)
PARK = LIVE / "logs" / "state" / "client_park.json"
STAY = LIVE / "logs" / "state" / "client_stay"
BOOT_LOCKED = 2  # client_boot.ps1's exit when another boot (the watchdog's own unpark) is running


def parked(path: Path | None = None) -> dict | None:
    """The park marker, or None when he is not parked. An unreadable marker still counts as parked."""
    p = path or PARK
    try:
        text = p.read_text(encoding="utf-8-sig")
    except OSError:
        return None
    try:
        d = json.loads(text)
        return d if isinstance(d, dict) else {"mode": "unknown"}
    except ValueError:
        return {"mode": "unknown"}


def _boot(timeout_s: float = 900.0) -> int:
    """tools/client_boot.ps1 (no target: the lease, else the default dev; never -Release, so a hold stays a hold)."""
    cmd = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(ROOT / "tools" / "client_boot.ps1"),
           "-Quiet"]
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout_s).returncode
    except subprocess.TimeoutExpired:
        return 124


def unpark(boot=None, path: Path | None = None, wait_s: float = 900.0, sleep=time.sleep, now=time.time) -> str:
    """Back into the world when parked; a no-op otherwise. Waits out a boot already running (the watchdog unparking
    him because this caller's lock or ticket appeared). Returns one line for the caller's log, never raises: a window
    that still finds him out of the world refuses on its own preflight with that reason."""
    p = path or PARK
    mark = parked(p)
    if mark is None:
        return "not parked"
    if boot is None:  # the real client_boot: a test passes its own boot; a worktree needs DW_LIVE_OK=1
        why = live_guard.why_refused("unpark: tools/client_boot.ps1")
        if why:
            return f"unpark refused: {why}"
    boot = boot or _boot
    t_end = now() + wait_s
    while True:
        rc = boot()
        if rc == 0:
            try:
                p.unlink()
            except OSError:
                pass  # client_boot clears it on success too
            return f"unparked (was logged off: {mark.get('mode')}, since {mark.get('since')}): back in the world"
        if rc == BOOT_LOCKED and now() < t_end:
            sleep(10)
            continue
        return f"unpark failed: client_boot exit {rc} (he was logged off: {mark.get('mode')}); see logs/client/boot.log"


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    cmd = args[0] if args else "status"
    if cmd == "status":
        m = parked()
        print(json.dumps(m) if m else "not parked" + (" (client_stay set: he stays in the world)" if STAY.exists() else ""))
        return 0
    if cmd == "unpark":
        msg = unpark()
        print(msg)
        return 0 if not msg.startswith("unpark failed") else 1
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
