"""The live lock on Claude's body (logs/state/live_owner.txt), shared by every agent that drives the client.

Content: "<owner> <UTC ISO of the last refresh> pid=<pid>". A lock is stale when it has not been refreshed for
STALE_S AND its pid is not running (or it names none), so a long run that forgot to refresh is not taken over while it
still drives Claude (live 2026-11-01 14:46Z: a chat ladder run outlived its unrefreshed lock and a pickup window
collided with it). Hold it with `run`, which refreshes it every REFRESH_S while the command runs:

    .venv\\Scripts\\python.exe -m tools.live_lock run chat-ladder -- .venv\\Scripts\\python.exe -m tools.chat_ladder run --confirm
    .venv\\Scripts\\python.exe -m tools.live_lock status

Taking the lock sends the body a `stop` first (clean=True; --no-clean to skip), so no job is left over from the last
owner. Release it only after your own brain is stopped: a brain left running keeps driving him under the next owner.
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


def stop_body(timeout_s: float = 15.0) -> str:
    """The body's own `stop` over the debug channel: a new owner starts with no job left over from the last one (live
    16:02Z: a build window found every call refused "busy: the brain's interact is running", left by a quests run)."""
    out: list[str] = []

    def go():
        try:
            from evals.bench.devrun import default_dev
            r = default_dev().body_call("stop", {})
            out.append("ok" if r.get("ok") else f"failed: {r.get('reason')}")
        except Exception as exc:  # the client may be down or respawning; the lock is still held
            out.append(f"{type(exc).__name__}: {exc}"[:200])
    th = threading.Thread(target=go, daemon=True)
    th.start()
    th.join(timeout_s)
    return out[0] if out else f"no answer in {timeout_s:.0f} s"


@contextmanager
def held(owner: str, wait_s: float = 1800.0, pid: int | None = None, log=print, clean: bool = True):
    t0 = time.time()
    while not try_claim(owner, pid):
        if time.time() - t0 > wait_s:
            raise TimeoutError(f"live lock busy: {read()}")
        time.sleep(5)
    log(f"live lock: {owner} holds it" + (f"; stop left-over jobs: {stop_body()}" if clean else ""))
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
    r.add_argument("--no-clean", action="store_true", help="don't send the body a stop when the lock is taken")
    # the command is everything after "--" (split here: a REMAINDER positional swallowed options given after the
    # owner, so `run chat-ladder --wait 3000 -- cmd` ran "--wait" as the command, WinError 2, live 15:1xZ)
    argv = list(sys.argv[1:] if argv is None else argv)
    tail = None
    if "--" in argv:
        i = argv.index("--")
        argv, tail = argv[:i], argv[i + 1:]
    a, extra = ap.parse_known_args(argv)
    if a.cmd == "status":
        print(read() or "free")
        return 0
    cmd = tail if tail is not None else extra
    if not cmd:
        ap.error("run needs a command after --")
    with held(a.owner, a.wait, clean=not a.no_clean):
        return subprocess.call(cmd)


if __name__ == "__main__":
    sys.exit(main())
