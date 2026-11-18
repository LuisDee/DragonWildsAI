"""The live lock on Claude's body (logs/state/live_owner.txt), shared by every agent that drives the client.

Content: "<owner> <UTC ISO of the last refresh> pid=<pid>". A lock is stale when it has not been refreshed for
STALE_S AND its pid is not running (or it names none), so a long run that forgot to refresh is not taken over while it
still drives Claude (live 2026-11-01 14:46Z: a chat ladder run outlived its unrefreshed lock and a pickup window
collided with it). Hold it with `run`, which refreshes it every REFRESH_S while the command runs:

    .venv\\Scripts\\python.exe -m tools.live_lock run chat-ladder -- .venv\\Scripts\\python.exe -m tools.chat_ladder run --confirm
    .venv\\Scripts\\python.exe -m tools.live_lock status

Taking the lock first boots him back into the world if the client watchdog parked him (logged off while nobody played
him: tools/client_park.py), then sends the body a `stop` and gets him up out of any bed or shelter (clean=True; --no-clean to
skip), so no job or rest is left over from the last owner. Release it only after your own brain is stopped: a brain
left running keeps driving him under the next owner.

Waiters queue first come, first served (a ticket lock: one file per waiter in logs/state/live_queue, oldest live
ticket claims next; a dead waiter's ticket is dropped). With plain 5 s polling the agent that happened to poll first
after a release won, so one waiter could starve (live 2026-11-01 16:13-16:43Z: the rung 1 gate waited 30 min while
quests, pickup and needs took turns).
"""
from __future__ import annotations

import argparse
import json
import ctypes
import os
import subprocess
import sys
import threading
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

from brain import paths
from tools import client_park, live_guard

# single per VM: under the MAIN working tree even when this code runs from a worktree (brain/paths.LIVE_ROOT)
LOCK = paths.LIVE_ROOT / "logs" / "state" / "live_owner.txt"
QUEUE = LOCK.parent / "live_queue"
AUDIT = LOCK.parent / "live_lock.log"  # one line per claim / release / stale takeover: who drove him when
PRIORITY = LOCK.parent / "live_priority.json"
DEFAULT_RANK = 5
STALE_S = 300
REFRESH_S = 60
AGE_S = 600  # seconds of waiting worth one rank
LIVE_LOCK = LOCK  # the real one (tests repoint LOCK; try_claim binds the real path as its default)


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


def _audit(event: str, owner: str, pid: int, extra: str = "") -> None:
    try:
        with open(AUDIT, "a", encoding="utf-8") as f:
            f.write(f"{datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%fZ')[:-4]}Z {event} {owner} pid={pid}"
                    f"{' ' + extra if extra else ''}\n")
    except OSError:
        pass


def _is_live_lock(path: Path) -> bool:
    return os.path.normcase(os.path.abspath(path)) == os.path.normcase(os.path.abspath(LIVE_LOCK))


def try_claim(owner: str, pid: int | None = None, path: Path = LOCK) -> bool:
    """Create-if-absent; a stale lock (unrefreshed and its pid gone) is replaced."""
    # the real lock is claimed only by a caller allowed to drive the live body (not a test, not a worktree without
    # DW_LIVE_OK); a test passes its own path, which is the fake
    live_guard.check(f"claim the live lock as {owner}", fake=not _is_live_lock(path))
    pid = pid or os.getpid()
    path.parent.mkdir(parents=True, exist_ok=True)
    cur = read(path)
    if cur and cur["stale"]:
        try:
            path.unlink()
        except OSError:
            return False
        _audit("stale-takeover", owner, pid, f"from={cur['text']!r}")
    try:
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError:
        return False
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(_line(owner, pid))
    _audit("claim", owner, pid)
    return True


def release(owner: str, path: Path = LOCK, pid: int | None = None) -> None:
    """Only the holder's own claim: the same owner name may be waiting in another process (two "rung1" gates)."""
    cur = read(path)
    if cur and cur["owner"] == owner and (pid is None or cur["pid"] in (0, pid)):
        try:
            path.unlink()
        except OSError:
            pass
        _audit("release", owner, cur["pid"])


def stop_body(timeout_s: float = 15.0) -> str:
    """The body's own `stop` over the debug channel: a new owner starts with no job left over from the last one (live
    16:02Z: a build window found every call refused "busy: the brain's interact is running", left by a quests run)."""
    out: list[str] = []

    def go():
        try:
            from evals.bench.devrun import default_dev
            # force: the debug channel never pre-empts a brain action without it (BUGS L12), and a left-over action
            # outlives the brain that started it (live 16:4xZ: "stop left-over jobs: failed: busy", a grave walk ran on)
            r = default_dev().body_call("stop", {"force": True})
            out.append("ok" if r.get("ok") else f"failed: {r.get('reason')}")
        except Exception as exc:  # the client may be down or respawning; the lock is still held
            out.append(f"{type(exc).__name__}: {exc}"[:200])
    th = threading.Thread(target=go, daemon=True)
    th.start()
    th.join(timeout_s)
    return out[0] if out else f"no answer in {timeout_s:.0f} s"


def get_up(timeout_s: float = 15.0) -> str:
    """Out of a bed or shelter the last owner left him in, the player's way (client_mod/commands/get_up.lua: an
    interact press ends a rest), checked from his rest component (live 19:59Z: a rung1 rest left him lying in a Summon
    Shelter and the next agent's craft failed "resting")."""
    try:
        from tools.scenario_run import run_client_cmd
        cmd = paths.REPO_ROOT / "client_mod" / "commands" / "get_up.lua"

        def read() -> dict:
            return (run_client_cmd(cmd, "lock_get_up_read", {"press": False}, timeout_s) or {}).get("result") or {}
        r = read()
        if not r.get("ok"):
            return f"get-up check: {r.get('reason') or 'no answer'}"
        if not r.get("resting_in"):
            return "up"
        bed = r["resting_in"]
        run_client_cmd(cmd, "lock_get_up", None, timeout_s)
        t_end = time.time() + 4.0
        while time.time() < t_end:
            time.sleep(0.5)
            if not read().get("resting_in"):
                return f"got up from {bed}"
        return f"still in {bed} after a get-up press"
    except Exception as exc:  # the client may be down or respawning; the lock is still held
        return f"get-up check: {type(exc).__name__}: {exc}"[:200]


def _ticket(owner: str, qdir: Path | None = None) -> Path:
    qdir = qdir or QUEUE
    qdir.mkdir(parents=True, exist_ok=True)
    t = qdir / f"{time.time_ns()}_{owner.replace('_', '-')}_{os.getpid()}"
    t.write_text(owner, encoding="utf-8")
    return t


def priorities(path: Path | None = None) -> dict[str, int]:
    """logs/state/live_priority.json {owner: rank}: a lower rank claims first, less one rank per AGE_S waited, then
    oldest first (unlisted owners rank DEFAULT_RANK). The ladder is climbed in order, so the rung being worked on gets the one body first (main
    2026-11-01 21:3xZ: rung 1's follow and grave had 3 gate tries all day while rung 3 had 51)."""
    try:
        return {str(k): int(v) for k, v in json.loads((path or PRIORITY).read_text(encoding="utf-8")).items()}
    except (OSError, ValueError, TypeError, AttributeError):
        return {}


def queue(qdir: Path | None = None) -> list[dict]:
    """The waiters in claim order (rank, then oldest first); a ticket whose process is gone is removed."""
    qdir = qdir or QUEUE
    out = []
    for t in (qdir.iterdir() if qdir.exists() else []):
        ns, _, rest = t.name.partition("_")
        owner, _, pid = rest.rpartition("_")
        if not (ns.isdigit() and pid.isdigit()):
            continue
        if not _alive(int(pid)):
            try:
                t.unlink()
            except OSError:
                pass
            continue
        out.append({"ticket": t, "ns": int(ns), "owner": owner, "pid": int(pid)})
    # a waiter's rank improves by 1 per AGE_S waited, so a lower rank is delayed, never starved (live 2026-11-02
    # 00:17-00:48Z: rung3's farm gate waited 31 min and build 37 min while rank-0 rung1/rung4 windows re-claimed)
    rank, now = priorities(), time.time_ns()
    return sorted(out, key=lambda x: (rank.get(x["owner"], DEFAULT_RANK) - (now - x["ns"]) / 1e9 / AGE_S, x["ns"]))


def unpark() -> str:
    return client_park.unpark()


@contextmanager
def held(owner: str, wait_s: float = 1800.0, pid: int | None = None, log=print, clean: bool = True,
         unpark_first: bool = True):
    t0 = time.time()
    os.environ.setdefault("DW_LIVE_OWNER", owner)  # bridge commands sent from here (and children) carry it as src
    ticket = _ticket(owner)
    try:
        while True:
            q = queue()
            mine = not q or q[0]["ticket"] == ticket  # first in the queue (or the queue is unreadable)
            if mine and try_claim(owner, pid):
                break
            if time.time() - t0 > wait_s:
                raise TimeoutError(f"live lock busy: {read()}; queue {[x['owner'] for x in q]}")
            time.sleep(2 if mine else 4)
    finally:
        try:
            ticket.unlink()
        except OSError:
            pass
    # parked (the watchdog logged him off while nobody played him: tools/client_park.py): back into the world before
    # anything is sent to the body; the marker is read after the claim, which the watchdog's park checks after writing
    parked_note = f"; park: {unpark()}" if unpark_first and client_park.parked() else ""
    log(f"live lock: {owner} holds it{parked_note}" +
        (f"; stop left-over jobs: {stop_body()}; {get_up()}" if clean else ""))
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
        release(owner, pid=pid or os.getpid())
        log(f"live lock: {owner} released it")


live_guard.mark_live(held, "the live lock")  # quest_run.window_faked tells it from a test's fake


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
        q = queue()
        if q:
            print("queue: " + ", ".join(f"{x['owner']} (pid {x['pid']}, {time.time() - x['ns'] / 1e9:.0f} s)" for x in q))
        return 0
    cmd = tail if tail is not None else extra
    if not cmd:
        ap.error("run needs a command after --")
    if os.path.exists(cmd[0]):  # Windows CreateProcess can't start a relative ".venv/Scripts/python.exe" (WinError 2, live 23:1xZ)
        cmd = [os.path.abspath(cmd[0]), *cmd[1:]]
    with held(a.owner, a.wait, clean=not a.no_clean):
        # not brain.childproc: this pass-through shares its console on purpose (output and Ctrl+C reach the command
        # it holds the lock for) and starts it at once, so it never outlives the console it inherits
        return subprocess.call(cmd)


if __name__ == "__main__":
    sys.exit(main())
