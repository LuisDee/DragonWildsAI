r"""Unattended runner for the M1 session (docs/RUNBOOK-m1-session.md), built on tools/m1_session.py.

    .venv\Scripts\python.exe -m tools.m1_run [--blocks A1,B1,A2,B2] [--block-min 30] [--dry]

1. Queue for Claude's client (tools/client_slot: owner "m1-session") and take it when the queue hands it over.
2. Preflight: client and server bridges answer; the dev server's speech_direct `prove` passes; board jobs queued.
3. Brain block A1 (addressed effort off) starts; `m1_session proof --confirm` must pass all its checks, else stop.
4. Blocks in order (A* = DW_CONTROLLER_EFFORT_ADDRESSED off, B* = medium): (re)start the brain, `mark`, test chat
   for --block-min, stop the brain. DW_SPEND_CAP_USD = today's spend + $3 for every brain; the chat driver also stops at
   $3 of session spend.
5. `m1_session report --json` into the session log; release the slot.
Never touches Shockbyte (the client's default target is dev; client_forbid_targets has shockbyte).
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

from brain import paths
from tools import m1_session as ms

OWNER = "m1-session"
REPO = paths.REPO_ROOT
PY = sys.executable
WORLD = "dev_director"
JOBS = ["chop some ash logs and keep them in your bag", "mine a few stones and keep them",
        "keep yourself fed and watered"]


def sh(*args: str, timeout: float = 120) -> subprocess.CompletedProcess:
    return subprocess.run([PY, "-m", *args], capture_output=True, text=True, timeout=timeout, cwd=REPO)


def say(msg: str) -> None:
    print(f"{time.strftime('%H:%M:%S')} {msg}", flush=True)
    ms.write({"kind": "runner", "msg": msg})


def slot_status() -> dict:
    out = sh("tools.client_slot", "status")
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError:
        return {}


def wait_for_slot(minutes: float, poll_s: float = 20) -> None:
    sh("tools.client_slot", "enqueue", OWNER, "--why", f"M1 observed session ~{minutes:.0f} min (voice agent)")
    while True:
        h = (slot_status().get("holder") or {})
        if h.get("owner") == OWNER:
            r = sh("tools.client_slot", "take", OWNER, f"{minutes:g}", "--why", "M1 observed session")
            if r.returncode == 0:
                say(f"slot taken for {minutes:g} min")
                return
        time.sleep(poll_s)


def start_brain(effort: str | None, cap_usd: float) -> subprocess.Popen:
    env = dict(os.environ, DW_DIRECTOR="1", DW_DIRECTOR_CALLS_PER_HOUR="10", DW_PLAYER_NAME=ms.TEST_SENDER,
               DW_SPEND_CAP_USD=f"{cap_usd:.2f}")
    env.pop("DW_CONTROLLER_EFFORT_ADDRESSED", None)
    env.pop("DW_COMPANION_NAME", None)  # the brain is Claude; "Tester" is only the dev server's test chat name
    if effort:
        env["DW_CONTROLLER_EFFORT_ADDRESSED"] = effort
    log = open(paths.log_dir() / "m1_brain_stdout.log", "a", encoding="utf-8")
    return subprocess.Popen(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                             str(REPO / "tools" / "start_brain.ps1"), "-Body", "client", "-World", WORLD],
                            cwd=REPO, env=env, stdout=log, stderr=subprocess.STDOUT)


def stop_brain(p: subprocess.Popen) -> None:
    subprocess.run(["taskkill", "/T", "/F", "/PID", str(p.pid)], capture_output=True)
    p.wait(timeout=30)


def brain_started(lines, since: float) -> bool:
    """A brain run is up once its log has, after ``since``, the bridge answering its ping (bridge_recv pong) or a
    model prompt. (Brain-live logs have no session_start row early on: the first rows are bridge traffic.)"""
    for line in lines:
        try:
            r = json.loads(line)
        except (json.JSONDecodeError, TypeError):
            continue
        if not isinstance(r, dict) or float(r.get("ts") or 0) < since:
            continue
        msg = r.get("msg") if isinstance(r.get("msg"), dict) else {}
        if r.get("kind") == "bridge_recv" and (msg.get("data") or {}).get("pong") is True:
            return True
        if r.get("kind") == "prompt":
            return True
    return False


def wait_brain_up(since: float, timeout: float = 180) -> bool:
    end = time.time() + timeout
    while time.time() < end:
        for f in paths.log_dir().glob("brain-live-*.jsonl"):
            if f.stat().st_mtime >= since:
                with open(f, encoding="utf-8", errors="replace") as fh:
                    if brain_started(fh, since):
                        return True
        time.sleep(3)
    return False


def ps(script: str, *args: str, env: dict | None = None, timeout: float = 600) -> subprocess.CompletedProcess:
    return subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(REPO / "tools" / script),
                           *args], capture_output=True, text=True, cwd=REPO, env=env, timeout=timeout)


def client_in_world() -> bool:
    return "state=in_world" in ps("client_boot.ps1", "-DryRun", timeout=120).stdout


def restart_dev_server(rejoin_wait_s: float = 300) -> str | None:
    """The DEV server only (start_server.ps1 only ever starts the local dev server; it now defaults
    DW_COMPANION_NAME=Tester there). Nav-only like the client watchdog's restarts (DW_NO_BODY=1, DW_PERF=0).
    Claude's client rejoins via the client watchdog; client_boot -Target dev if it hasn't after rejoin_wait_s."""
    env = {k: v for k, v in os.environ.items() if k != "DW_COMPANION_NAME"}  # let the script's dev default apply
    env.update(DW_NO_BODY="1", DW_PERF="0")
    say("restarting the dev server (DW_COMPANION_NAME=Tester default)")
    say("stop: " + ps("stop_server.ps1", env=env).stdout.strip()[-200:])
    time.sleep(5)
    say("start: " + ps("start_server.ps1", env=env).stdout.strip()[-200:])
    end = time.time() + rejoin_wait_s
    time.sleep(60)  # the server loads its world before anyone can join
    while time.time() < end:
        if client_in_world():
            say("client back in world")
            return None
        time.sleep(20)
    say("client not back by itself: client_boot -Target dev")
    r = ps("client_boot.ps1", "-Target", "dev", timeout=900)
    return None if "state=in_world" in r.stdout else f"client did not rejoin: {r.stdout[-300:]}"


def preflight(jobs: bool = True) -> str | None:
    if not ms.client_ping():
        return "client bridge does not answer"
    if sh("tools.bridge_cmd", "ping", "--body", "server", "--timeout", "10").returncode != 0:
        return "server bridge does not answer"
    r = sh("tools.bridge_cmd", "debug_run", json.dumps({"module": "speech_direct", "args": {"action": "prove"}}),
           "--body", "server", "--timeout", "30")
    ms.write({"kind": "prove", "out": (r.stdout or r.stderr)[-1500:]})
    if '"pass": true' not in r.stdout.replace("'", '"'):
        return "speech_direct prove did not pass"
    for j in (JOBS if jobs else []):
        sh("tools.board", "add", j, "--world", WORLD)
    return None


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--blocks", default="A1,B1,A2,B2")
    ap.add_argument("--block-min", type=float, default=30)
    ap.add_argument("--per-hour", type=int, default=30)
    ap.add_argument("--dry", action="store_true", help="print the plan only")
    ap.add_argument("--no-jobs", action="store_true", help="don't queue the board jobs (already queued)")
    ap.add_argument("--restart-dev-server", action="store_true",
                    help="after taking the slot: restart the DEV server (Tester chat name) and wait for the client")
    a = ap.parse_args(argv)
    blocks = [b.strip() for b in a.blocks.split(",") if b.strip()]
    total = len(blocks) * a.block_min + 20 + (15 if a.restart_dev_server else 0)
    if a.dry:
        print(json.dumps({"blocks": blocks, "block_min": a.block_min, "slot_min": total,
                          "estimate": ms.estimate(len(blocks) * a.block_min / 60, a.per_hour)}, indent=1))
        return 0
    wait_for_slot(total)
    brain = None
    try:
        why = restart_dev_server() if a.restart_dev_server else None
        why = why or preflight(jobs=not a.no_jobs)
        if why:
            say(f"STOP preflight: {why}")
            return 3
        base = ms.spent_today() or 0.0
        cap = base + ms.SPEND_LIMIT_USD
        for i, block in enumerate(blocks):
            effort = "medium" if block.startswith("B") else None
            t0 = time.time()
            brain = start_brain(effort, cap)
            if not wait_brain_up(t0):
                say(f"STOP: the brain did not start for {block}")
                return 4
            time.sleep(20)  # warm-up and the first board tick
            ms.main(["mark", block, "--note", f"addressed effort {effort or 'off'}"])
            if i == 0:
                say("proof: one test line + 60 s client health")
                if ms.main(["proof", "--confirm"]) != 0:
                    say("STOP: proof failed (see m1_session.jsonl)")
                    return 5
            rc = ms.main(["chat", "--sender", "speech_direct", "--confirm", "--per-hour", str(a.per_hour),
                          "--minutes", str(a.block_min)])
            stop_brain(brain)
            brain = None
            if rc != 0:
                say(f"STOP: chat driver exit {rc} in {block}")
                return 6
            say(f"block {block} done")
        rep = sh("tools.m1_session", "report", "--json", timeout=600)
        ms.write({"kind": "report", "out": rep.stdout[-20000:]})
        say("session done; report written")
        return 0
    finally:
        if brain is not None:
            stop_brain(brain)
        sh("tools.client_slot", "release", OWNER)


if __name__ == "__main__":
    raise SystemExit(main())
