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
    if effort:
        env["DW_CONTROLLER_EFFORT_ADDRESSED"] = effort
    log = open(paths.log_dir() / "m1_brain_stdout.log", "a", encoding="utf-8")
    return subprocess.Popen(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                             str(REPO / "tools" / "start_brain.ps1"), "-Body", "client", "-World", WORLD],
                            cwd=REPO, env=env, stdout=log, stderr=subprocess.STDOUT)


def stop_brain(p: subprocess.Popen) -> None:
    subprocess.run(["taskkill", "/T", "/F", "/PID", str(p.pid)], capture_output=True)
    p.wait(timeout=30)


def wait_brain_up(since: float, timeout: float = 120) -> bool:
    """A new brain-live log with a session_start row after ``since``."""
    end = time.time() + timeout
    while time.time() < end:
        for f in paths.log_dir().glob("brain-live-*.jsonl"):
            if f.stat().st_mtime >= since and '"session_start"' in f.read_text(encoding="utf-8", errors="replace")[:20000]:
                return True
        time.sleep(3)
    return False


def preflight() -> str | None:
    if not ms.client_ping():
        return "client bridge does not answer"
    if sh("tools.bridge_cmd", "ping", "--body", "server", "--timeout", "10").returncode != 0:
        return "server bridge does not answer"
    r = sh("tools.bridge_cmd", "debug_run", json.dumps({"module": "speech_direct", "args": {"action": "prove"}}),
           "--body", "server", "--timeout", "30")
    ms.write({"kind": "prove", "out": (r.stdout or r.stderr)[-1500:]})
    if '"pass": true' not in r.stdout.replace("'", '"'):
        return "speech_direct prove did not pass"
    for j in JOBS:
        sh("tools.board", "add", j, "--world", WORLD)
    return None


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--blocks", default="A1,B1,A2,B2")
    ap.add_argument("--block-min", type=float, default=30)
    ap.add_argument("--per-hour", type=int, default=30)
    ap.add_argument("--dry", action="store_true", help="print the plan only")
    a = ap.parse_args(argv)
    blocks = [b.strip() for b in a.blocks.split(",") if b.strip()]
    total = len(blocks) * a.block_min + 20
    if a.dry:
        print(json.dumps({"blocks": blocks, "block_min": a.block_min, "slot_min": total,
                          "estimate": ms.estimate(len(blocks) * a.block_min / 60, a.per_hour)}, indent=1))
        return 0
    wait_for_slot(total)
    brain = None
    try:
        why = preflight()
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
