r"""Driver for an observed M1 dev-world session (docs/RUNBOOK-m1-session.md): test-player chat on a schedule, phase
markers for the addressed-effort A/B, a session spend guard, and the per-phase report from tools/obs.py.

    .venv\Scripts\python.exe -m tools.m1_session plan                         # schedule + call/cost estimate, no side effects
    .venv\Scripts\python.exe -m tools.m1_session proof --confirm             # preflight: ONE test line + 60 s health watch
    .venv\Scripts\python.exe -m tools.m1_session mark A1 --note "effort off"  # at each brain (re)start
    .venv\Scripts\python.exe -m tools.m1_session chat --sender speech_direct --confirm [--per-hour 30] [--minutes 120]
    .venv\Scripts\python.exe -m tools.m1_session report [--json]

It never starts or stops the game, the brain or the client: the runbook does that. The only thing it sends is test-player
chat, and only with --sender speech_direct --confirm (the dev server mod's on-demand chat, mod/body/speech.lua
send_direct, which must have passed its own `prove` in this server run; Luis's go-ahead is needed before first use).
--sender none (default) logs what it would send. Session log: <log_dir>/m1_session.jsonl.
"""
from __future__ import annotations

import argparse
import calendar
import json
import random
import subprocess
import sys
import time
from pathlib import Path

from brain import paths

LOG_NAME = "m1_session.jsonl"
TEST_SENDER = "Tester"  # the dev server's DW_COMPANION_NAME for the session: a test name, never a real player's
NOT_TESTER = ("Zezima", "Luis", "Claude", "ClaudeDev")  # names a test line must never carry (Luis's, Claude's)
PROOF_LINE = "claude this is a test line from the Tester account, please ignore"
HEALTH_WATCH_S = 60
HEALTH_EVERY_S = 10
MOD_LOG_FRESH_S = 30
REGISTER_SETTLE_S = 5
SPEND_LIMIT_USD = 3.0  # the session's own spend (today's spend at the first mark is the baseline)
# Generic co-play lines a player would type to a mate who is out doing his own thing. Written for this driver, not
# taken from any eval or benchmark case. Mostly requests that need an action (the latency metric is chat -> first
# world action), some questions, some small talk. Every line is addressed ("claude ...", the chat prefix).
LINES = [
    "claude grab me a few logs when you get a sec", "claude what are you up to", "claude go get some stone",
    "claude you hungry? eat something if you are", "claude chop that tree nearest you", "claude how's it going",
    "claude pick up whatever's lying around near you", "claude have you got a pickaxe on you",
    "claude mine a rock or two for me", "claude drink something, you look thirsty", "claude what's in your bag",
    "claude collect some of the plants near you", "claude stop for a sec", "claude carry on with what you were doing",
    "claude get a couple more logs", "claude anything good around you", "claude go and gather some berries",
    "claude what are you wearing", "claude take a break and have a snack", "claude cut down another tree",
    "claude any mobs near you", "claude get some more stone please", "claude nice work", "claude whats your plan",
    "claude grab the closest thing you can pick up", "claude chop a few more logs then carry on",
    "claude can you see any trees", "claude find something to eat", "claude what skill are you levelling",
    "claude get back to your job",
]


def log_path() -> Path:
    return paths.log_dir() / LOG_NAME


def write(row: dict) -> None:
    p = log_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    with open(p, "a", encoding="utf-8") as f:
        f.write(json.dumps({"ts": round(time.time(), 3), **row}, ensure_ascii=False) + "\n")


def rows() -> list[dict]:
    p = log_path()
    if not p.exists():
        return []
    return [json.loads(x) for x in p.read_text(encoding="utf-8").splitlines() if x.strip()]


def spent_today() -> float | None:
    out = subprocess.run([sys.executable, "-m", "tools.obs", "spend", "--json"], capture_output=True, text=True)
    try:
        return float(json.loads(out.stdout)["spent_usd"])
    except (ValueError, KeyError, json.JSONDecodeError):
        return None


def estimate(hours: float = 2.0, per_hour: int = 30) -> dict:
    """Calls and $ from the measured rates (tools.obs spend 2026-10-25/26: Haiku ~$0.0008 per Controller call,
    Sonnet ~$0.016 per Director request; the dev Director smoke ran ~300 Controller calls/h)."""
    ctl_h, director_h, chat_calls = 300, 10, 3  # Controller calls/h from Director work, Director requests/h, calls/line
    calls = {"controller": int(hours * (ctl_h + per_hour * chat_calls)), "director": int(hours * director_h)}
    usd = calls["controller"] * 0.0008 * 1.3 + calls["director"] * 0.016  # +30 % for the medium-effort halves
    return {"hours": hours, "chat_lines": int(hours * per_hour), "calls": calls, "usd_estimate": round(usd, 2),
            "usd_limit": SPEND_LIMIT_USD}


def send_speech_direct(text: str, timeout: float = 30.0) -> tuple[bool, str]:
    """One line via the dev server mod's on-demand chat (debug_run speech_direct send). Refuses itself there
    unless `prove` passed this server run."""
    args = json.dumps({"module": "speech_direct", "args": {"action": "send", "confirm": True, "text": text,
                                                           "name": TEST_SENDER, "test_guid": True}})
    out = subprocess.run([sys.executable, "-m", "tools.bridge_cmd", "debug_run", args, "--body", "server",
                          "--timeout", str(timeout)], capture_output=True, text=True)
    return out.returncode == 0 and '"ok": true' in out.stdout.replace("'", '"').lower(), (out.stdout or out.stderr)[-300:]


def _chat_rows_since(t0: float) -> list[dict]:
    f = paths.REPO_ROOT / "client_io" / "events" / "chat.jsonl"
    if not f.exists():
        return []
    out = []
    for line in f.read_text(encoding="utf-8", errors="replace").splitlines()[-200:]:
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(r.get("ts"), (int, float)) and r["ts"] >= t0 - 2:
            out.append(r)
    return out


def _brain_heard_since(t0: float, sender: str) -> bool:
    logs = sorted(paths.log_dir().glob("brain-live-*.jsonl"), key=lambda q: q.stat().st_mtime)
    for line in (logs[-1].read_text(encoding="utf-8", errors="replace").splitlines()[-500:] if logs else []):
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            continue
        if r.get("kind") == "chat_decision" and r.get("player") == sender and float(r.get("ts") or 0) >= t0 - 2:
            return True
    return False


def client_ping() -> bool:
    out = subprocess.run([sys.executable, "-m", "tools.bridge_cmd", "ping", "--body", "client", "--timeout", "8"],
                         capture_output=True, text=True)
    return out.returncode == 0


def mod_log_age_s() -> float | None:
    """Age of the client's UE4SS log (written continuously while the client runs; the client watchdog's hang
    signal). The mod's own jsonl is event-driven and can be quiet for minutes when the client is idle."""
    f = paths.log_dir() / "client" / "client.log"
    return (time.time() - f.stat().st_mtime) if f.exists() else None


def watchdog_trouble_since(t0: float) -> list[str]:
    f = paths.log_dir() / "client_watchdog.jsonl"
    bad = []
    for line in (f.read_text(encoding="utf-8", errors="replace").splitlines()[-200:] if f.exists() else []):
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            continue
        ev = str(r.get("event") or "")
        ts = r.get("ts")
        when = calendar.timegm(time.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S")) if isinstance(ts, str) else 0
        if when >= t0 - 2 and any(k in ev for k in ("hang", "crash", "restart", "recover")):
            bad.append(ev)
    return bad


def proof_checks(row: dict | None, heard: bool, pings: list[bool], mod_age: float | None, trouble: list[str]) -> dict:
    """Every condition the single proof line must meet (pure; the IO is in cmd_proof)."""
    sender = (row or {}).get("from")
    return {
        "logged_in_chat": row is not None,
        "from_is_the_test_name": sender == TEST_SENDER,
        "not_a_real_player_name": sender is not None and sender not in NOT_TESTER,
        "non_self": row is not None and row.get("self") is False,
        "brain_heard_it": heard,
        "client_answered_every_ping": bool(pings) and all(pings),
        "client_log_fresh": mod_age is not None and mod_age <= MOD_LOG_FRESH_S,
        "no_watchdog_hang_or_crash": not trouble,
    }


def cmd_proof(a) -> int:
    """Preflight: ONE test line, then 60 s of client health. Pass only if every check holds."""
    if not a.confirm:
        print("refusing: proof sends one real chat line on the dev server; pass --confirm (after Luis's go-ahead)")
        return 2
    reg_ok, reg = register_sender()
    write({"kind": "proof_register", "ok": reg_ok, "detail": reg[-200:]})
    time.sleep(REGISTER_SETTLE_S)  # let the name replicate to the client before the line arrives
    t0 = time.time()
    ok, detail = send_speech_direct(PROOF_LINE)
    write({"kind": "proof_send", "ok": ok, "detail": detail[-200:], "text": PROOF_LINE})
    if not ok:
        print(f"FAIL: the send itself failed: {detail[-200:]}")
        return 4
    pings, row = [], None
    while time.time() - t0 < HEALTH_WATCH_S:
        if row is None:
            row = next((r for r in _chat_rows_since(t0) if r.get("text") == PROOF_LINE), None)
        pings.append(client_ping())
        time.sleep(HEALTH_EVERY_S)
    checks = proof_checks(row, _brain_heard_since(t0, TEST_SENDER), pings, mod_log_age_s(), watchdog_trouble_since(t0))
    passed = all(checks.values())
    write({"kind": "proof", "passed": passed, "checks": checks, "chat_row": row, "pings": pings})
    for k, v in checks.items():
        print(f"  {'ok  ' if v else 'FAIL'} {k}")
    print("PROOF PASSED" if passed else "PROOF FAILED: do not run the session; report it")
    return 0 if passed else 5


def register_sender(timeout: float = 30.0) -> tuple[bool, str]:
    """Register the test sender's display name for its test guid (no chat), so the client resolves it."""
    args = json.dumps({"module": "speech_direct", "args": {"action": "register", "name": TEST_SENDER, "test_guid": True}})
    out = subprocess.run([sys.executable, "-m", "tools.bridge_cmd", "debug_run", args, "--body", "server",
                          "--timeout", str(timeout)], capture_output=True, text=True)
    return out.returncode == 0 and '"ok": true' in out.stdout.replace("'", '"').lower(), (out.stdout or out.stderr)[-300:]


def cmd_chat(a) -> int:
    if a.sender == "speech_direct" and not a.confirm:
        print("refusing: --sender speech_direct needs --confirm (and Luis's go-ahead before its first use)")
        return 2
    marks = [r for r in rows() if r.get("kind") == "mark"]
    if not marks:
        print("refusing: run `mark <phase>` first (it records the spend baseline)")
        return 2
    if a.sender == "speech_direct" and not any(r.get("kind") == "proof" and r.get("passed") for r in rows()):
        print("refusing: no passed `proof` in the session log (the one-line test + 60 s client health watch)")
        return 2
    base = marks[0].get("spent_usd")
    rng = random.Random(a.seed)
    order = LINES[:]
    rng.shuffle(order)
    gap = 3600.0 / max(1, a.per_hour)
    end = time.time() + a.minutes * 60
    i = 0
    while time.time() < end:
        now_spent = spent_today()
        if base is not None and now_spent is not None and now_spent - base > SPEND_LIMIT_USD:
            write({"kind": "stop", "why": "session spend limit", "spent_usd": now_spent, "base_usd": base})
            print(f"stop: session spend {now_spent - base:.2f} > {SPEND_LIMIT_USD}")
            return 3
        text = order[i % len(order)]
        i += 1
        if a.sender == "speech_direct":
            ok, detail = send_speech_direct(text)
        else:
            ok, detail = True, "dry: not sent"
        write({"kind": "chat", "sender": a.sender, "text": text, "ok": ok, "detail": detail[-200:]})
        print(f"{time.strftime('%H:%M:%S')} {'sent' if ok else 'FAILED'}: {text}")
        if a.sender == "speech_direct" and not ok:
            print("stop: the sender failed (see the session log); fix before retrying")
            return 4
        time.sleep(gap * rng.uniform(0.6, 1.4))  # irregular, like a person
    return 0


def cmd_mark(a) -> int:
    write({"kind": "mark", "phase": a.phase, "note": a.note, "spent_usd": spent_today()})
    print(f"marked {a.phase}")
    return 0


def phases(rs: list[dict]) -> list[tuple[str, float, float | None]]:
    marks = [r for r in rs if r.get("kind") == "mark"]
    return [(m["phase"], m["ts"], marks[i + 1]["ts"] if i + 1 < len(marks) else None) for i, m in enumerate(marks)]


def obs_metrics(since: float, until: float | None) -> dict:
    iso = lambda t: time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t))  # noqa: E731
    cmd = [sys.executable, "-m", "tools.obs", "metrics", "--json", "--since", iso(since)] + (
        ["--until", iso(until)] if until else [])
    out = subprocess.run(cmd, capture_output=True, text=True)
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError:
        return {"error": (out.stderr or out.stdout)[-300:]}


def cmd_report(a) -> int:
    rs = rows()
    ph = phases(rs)
    if not ph:
        print("no marks yet")
        return 1
    out = {"phases": {}, "session": obs_metrics(ph[0][1], None)}
    for name, t0, t1 in ph:
        m = obs_metrics(t0, t1)
        out["phases"][name] = {"latency": m.get("latency"), "anomalies_per_hour": m.get("anomalies_per_hour"),
                               "exposure": m.get("exposure")}
    for group in ("A", "B"):  # the A/B halves: A* = addressed effort off, B* = on
        lat = [v["latency"]["chat_to_first_action_s"] for k, v in out["phases"].items()
               if k.startswith(group) and v.get("latency")]
        out[f"half_{group}"] = lat
    s = out["session"]
    out["m1"] = {k: s.get(k) for k in ("exposure", "latency", "anomalies_per_hour", "stability", "deaths")}
    if a.json:
        print(json.dumps(out, indent=1))
    else:
        for k, v in out["m1"].items():
            print(f"{k}: {json.dumps(v)}")
        for name, v in out["phases"].items():
            print(f"phase {name}: latency {json.dumps((v.get('latency') or {}).get('chat_to_first_action_s'))}")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--hours", type=float, default=2.0)
    p.add_argument("--per-hour", type=int, default=30)
    pf = sub.add_parser("proof")
    pf.add_argument("--confirm", action="store_true")
    m = sub.add_parser("mark")
    m.add_argument("phase")
    m.add_argument("--note", default="")
    c = sub.add_parser("chat")
    c.add_argument("--sender", choices=("none", "speech_direct"), default="none")
    c.add_argument("--confirm", action="store_true")
    c.add_argument("--per-hour", type=int, default=30)
    c.add_argument("--minutes", type=float, default=120)
    c.add_argument("--seed", type=int, default=1)
    r = sub.add_parser("report")
    r.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    if a.cmd == "plan":
        print(json.dumps(estimate(a.hours, a.per_hour), indent=1))
        return 0
    return {"mark": cmd_mark, "chat": cmd_chat, "report": cmd_report, "proof": cmd_proof}[a.cmd](a)


if __name__ == "__main__":
    raise SystemExit(main())
