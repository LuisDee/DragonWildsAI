"""The live lock on Claude's body (logs/state/live_owner.txt), shared by every agent that drives the client.

Content: "<owner> <UTC ISO of the last refresh> pid=<pid>". A lock is stale when it has not been refreshed for
STALE_S AND its pid is not running (or it names none), so a long run that forgot to refresh is not taken over while it
still drives Claude (live 2026-11-01 14:46Z: a chat ladder run outlived its unrefreshed lock and a pickup window
collided with it). Hold it with `run`, which refreshes it every REFRESH_S while the command runs:

    .venv\\Scripts\\python.exe -m tools.live_lock run chat-ladder -- .venv\\Scripts\\python.exe -m tools.chat_ladder run --confirm
    .venv\\Scripts\\python.exe -m tools.live_lock status
"""
from __future__ import annotations

import argparse
import ctypes
import os
import subprocess
import sys
import threading
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

LOCK = Path(__file__).resolve().parents[1] / "logs" / "state" / "live_owner.txt"
STALE_S = 300
REFRESH_S = 60


def _alive(pid: int) -> bool:
    if pid <= 0:
        return False
    if os.name == "nt":
        h = ctypes.windll.kernel32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
        if not h:
            return False
        code = ctypes.c_ulong()
        ok = ctypes.windll.kernel32.GetExitCodeProcess(h, ctypes.byref(code))
        ctypes.windll.kernel32.CloseHandle(h)
        return bool(ok) and code.value == 259  # STILL_ACTIVE
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def read(path: Path = LOCK) -> dict | None:
    try:
        text = path.read_text(encoding="utf-8").strip()
        age = time.time() - path.stat().st_mtime
    except OSError:
        return None
    parts = text.split()
    pid = next((int(p[4:]) for p in parts if p.startswith("pid=") and p[4:].isdigit()), 0)
    return {"owner": parts[0] if parts else "?", "text": text, "age_s": round(age, 1), "pid": pid,
            "pid_alive": _alive(pid), "stale": age > STALE_S and not _alive(pid)}


def _line(owner: str, pid: int) -> str:
    return f"{owner} {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')} pid={pid}"


def try_claim(owner: str, pid: int | None = None, path: Path = LOCK) -> bool:
    """Create-if-absent; a stale lock (unrefreshed and its pid gone) is replaced."""
    pid = pid or os.getpid()
    path.parent.mkdir(parents=True, exist_ok=True)
    cur = read(path)
    if cur and cur["stale"]:
        try:
            path.unlink()
        except OSError:
            return False
    try:
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError:
        return False
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(_line(owner, pid))
    return True


def release(owner: str, path: Path = LOCK) -> None:
    cur = read(path)
    if cur and cur["owner"] == owner:
        try:
            path.unlink()
        except OSError:
            pass


@contextmanager
def held(owner: str, wait_s: float = 1800.0, pid: int | None = None, log=print):
    t0 = time.time()
    while not try_claim(owner, pid):
        if time.time() - t0 > wait_s:
            raise TimeoutError(f"live lock busy: {read()}")
        time.sleep(5)
    log(f"live lock: {owner} holds it")
    stop = threading.Event()

    def beat():
        while not stop.wait(REFRESH_S):
            cur = read()
            if cur and cur["owner"] == owner:
                LOCK.write_text(_line(owner, pid or os.getpid()), encoding="utf-8")

    th = threading.Thread(target=beat, daemon=True)
    th.start()
    try:
        yield
    finally:
        stop.set()
        release(owner)
        log(f"live lock: {owner} released it")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    r = sub.add_parser("run", help="hold the lock (refreshed) while a command runs")
    r.add_argument("owner")
    r.add_argument("--wait", type=float, default=1800.0, help="seconds to wait for the lock")
    r.add_argument("command", nargs=argparse.REMAINDER)
    a = ap.parse_args(argv)
    if a.cmd == "status":
        print(read() or "free")
        return 0
    cmd = a.command[1:] if a.command[:1] == ["--"] else a.command
    if not cmd:
        ap.error("run needs a command after --")
    with held(a.owner, a.wait):
        return subprocess.call(cmd)


if __name__ == "__main__":
    sys.exit(main())
