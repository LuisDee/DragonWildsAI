"""Live validation queue: CI-like, back-to-back live checks on Claude's ONE game client (dev server only).

  .venv\\Scripts\\python.exe -m tools.live_queue list                  # every check + its state
  .venv\\Scripts\\python.exe -m tools.live_queue status                # slot, lock, last run
  .venv\\Scripts\\python.exe -m tools.live_queue add path\\to\\check.json [--requeue]
  .venv\\Scripts\\python.exe -m tools.live_queue requeue <id>          # back to pending (e.g. after a fix)
  .venv\\Scripts\\python.exe -m tools.live_queue run --dry-run         # validate the check files only (no game calls)
  .venv\\Scripts\\python.exe -m tools.live_queue run [--only a,b]      # drain the queue now
  .venv\\Scripts\\python.exe -m tools.live_queue run --if-free         # the Scheduled Task's call: quiet no-op unless
                                                                       # the slot is free and something is pending
Detached (Claude Code's reaper kills background shells), from PowerShell:
  Start-Process -WindowStyle Hidden -WorkingDirectory C:\\gameserver C:\\gameserver\\.venv\\Scripts\\python.exe `
      -ArgumentList '-m','tools.live_queue','run'
Auto-drain: tools/register_live_queue_task.ps1 (Task Scheduler, every 5 min, MultipleInstances IgnoreNew).

A check = one JSON file in tools/live_checks/<id>.json (format + recipe: ARCHITECTURE.md §8.7 "How to queue a live
check"). A run:
  1. one instance at a time (an OS file lock, logs/state/live_queue.lock; a second run exits 0 at once);
  2. refuses while logs/client.hold / logs/client.stopped exists, and stops between checks when one appears;
  3. takes the client slot (tools/client_slot.py, owner "live-queue"; renewed before every check, released in a finally);
  4. health precheck: client in world (logs/state/client_status.json from the watchdog), the dev-server guard
     (evals.bench.devtarget.DevTarget.guard: loopback server, never a forbidden target, run_live not running), bridge
     ping; then bridge_start.lua (client_mod/commands);
  5. every pending check: preconditions (dev fixtures through DevTarget.setup, input mode from bench_probe.lua),
     steps (bridge tools on the DEBUG channel, client_mod commands through the runner, probes, sleeps), then the pass
     criteria judged from the saved replies, probes and the log lines written during the check;
  6. between checks: recovery. A crashed/relaunching client is WAITED for (the client watchdog relaunches it; this
     never launches, kills or boots the client and never touches Steam), then bridge_start again; a stuck input mode
     gets one input_gate_once.lua (the modal gate's own sweep) and is reported if it stays;
  7. results: logs/live_queue/<date>.jsonl, state: logs/state/live_queue.json (verdict per check + the check file's
     hash: editing a check file puts it back to pending).
Verdicts: passed | failed (criteria not met: stays failed until the file changes or `requeue`) | observed
(observe_only checks) | blocked (a precondition could not be set up) | error (infra: timeout, crash, lost command).
blocked/error checks are retried on later drains, at most MAX_INCONCLUSIVE_RUNS times.
"""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import io
import json
import math
import os
import re
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

ROOT = Path(__file__).resolve().parents[1]
CHECK_DIR = ROOT / "tools" / "live_checks"
RESULT_DIR = ROOT / "logs" / "live_queue"
STATE_FILE = ROOT / "logs" / "state" / "live_queue.json"
LOCK_FILE = ROOT / "logs" / "state" / "live_queue.lock"
CLIENT_STATUS = ROOT / "logs" / "state" / "client_status.json"
HOLD_FILES = [ROOT / "logs" / "client.hold", ROOT / "logs" / "client.stopped"]
CMDS = ROOT / "client_mod" / "commands"
LOG_SOURCES = {"client": ROOT / "logs" / "client" / "client.log",
               "game": Path(os.environ.get("LOCALAPPDATA", "")) / "RSDragonwilds" / "Saved" / "Logs" / "RSDragonwilds.log",
               "vitals": ROOT / "client_io" / "events" / "vitals.jsonl",
               "activity": ROOT / "client_io" / "events" / "activity.jsonl"}
OWNER = "live-queue"
MAX_INCONCLUSIVE_RUNS = 3
STATUS_FRESH_S = 180
RELAUNCH_WAIT_S = 480
INFRA_REASONS = {"timeout", "body_restarted", "lost_by_body", "paused", "no_reply"}
DONE = {"passed", "failed", "observed"}
FIXTURE_VERBS = {"grant", "grant_runes", "unlock", "set_health", "set_time", "teleport", "spawn", "raise_skills",
                 "reset_skills", "hold", "scene", "claim_bed", "ground_item", "felled_log", "recall_beacon"}
OPS = ("eq", "ne", "gt", "gte", "lt", "lte", "in", "contains", "exists", "truthy", "falsy", "regex")
STEP_KINDS = ("bridge", "client_cmd", "probe", "sleep_s", "fixture", "server")
SERVER_MODULES = ROOT / "mod" / "experiments"  # `server` steps: dev-server debug_run of a mod/experiments module only


class Blocked(Exception):
    """A precondition or a step argument could not be satisfied (no verdict)."""


class InfraError(Exception):
    """The client, bridge or runner failed under the check (no verdict)."""


class HoldSet(Exception):
    pass


def iso(t: float | None = None) -> str:
    return datetime.fromtimestamp(time.time() if t is None else t, timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


# ------------------------------------------------------------------ check files (pure)
def file_hash(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()[:16]


def load_checks(d: Path | None = None) -> list[tuple[Path, dict]]:
    out = []
    for p in sorted((d or CHECK_DIR).glob("*.json")):
        if p.name.lower() == "readme.json":
            continue
        out.append((p, json.loads(p.read_text(encoding="utf-8"))))
    return out


def _expr_errors(e: Any, where: str) -> list[str]:
    if not isinstance(e, dict):
        return [f"{where}: a criterion must be an object"]
    lhs = [k for k in ("ref", "delta", "dist", "log") if k in e]
    errs = []
    if len(lhs) != 1:
        errs.append(f"{where}: exactly one of ref/delta/dist/log")
    if "delta" in e or "dist" in e:
        v = e.get("delta", e.get("dist"))
        if not (isinstance(v, list) and len(v) == 2 and all(isinstance(x, str) for x in v)):
            errs.append(f"{where}: delta/dist takes [ref_a, ref_b]")
    if "log" in e:
        lg = e["log"]
        if not (isinstance(lg, dict) and lg.get("source") in LOG_SOURCES and isinstance(lg.get("regex"), str)):
            errs.append(f"{where}: log takes {{source: {'|'.join(LOG_SOURCES)}, regex}}")
        else:
            try:
                re.compile(lg["regex"])
            except re.error as x:
                errs.append(f"{where}: bad regex {x}")
    return errs


def validate(spec: dict, path: Path | None = None, *, root: Path = ROOT, item_ok: Callable[[str], bool] | None = None,
             spell_ok: Callable[[str], bool] | None = None) -> list[str]:
    """Problems with one check file ([] = valid). item_ok/spell_ok: catalog lookups for fixture items (optional)."""
    errs = []
    for k in ("id", "owner", "steps", "pass", "timeout_s"):
        if k not in spec:
            errs.append(f"missing {k}")
    cid = spec.get("id")
    if cid is not None and not re.fullmatch(r"[a-z0-9_]+", str(cid)):
        errs.append("id must be [a-z0-9_]+")
    if path is not None and cid and path.stem != cid:
        errs.append(f"file name {path.name} must be {cid}.json")
    if not (spec.get("commit") or spec.get("area")):
        errs.append("give commit and/or area")
    if not isinstance(spec.get("timeout_s"), (int, float)) or spec.get("timeout_s", 0) <= 0:
        errs.append("timeout_s must be a positive number")
    if not isinstance(spec.get("max_retries", 0), int) or spec.get("max_retries", 0) < 0:
        errs.append("max_retries must be an int >= 0")
    pre = spec.get("preconditions") or {}
    if not isinstance(pre, dict):
        errs.append("preconditions must be an object")
        pre = {}
    fixtures = list(pre.get("fixtures") or [])
    if pre.get("set_health") is not None:
        fixtures.append({"verb": "set_health", **pre["set_health"]})
    steps = spec.get("steps") or []
    if not isinstance(steps, list) or not steps:
        errs.append("steps must be a non-empty list")
        steps = []
    cleanup = spec.get("cleanup") or []
    if not isinstance(cleanup, list):
        errs.append("cleanup must be a list of steps")
        cleanup = []
    for i, s in enumerate(list(steps) + list(cleanup)):
        kinds = [k for k in STEP_KINDS if k in s] if isinstance(s, dict) else []
        if len(kinds) != 1:
            errs.append(f"step {i}: exactly one of {STEP_KINDS}")
            continue
        if kinds[0] == "client_cmd" and not (root / s["client_cmd"]).is_file():
            errs.append(f"step {i}: no command file {s['client_cmd']}")
        if kinds[0] == "server" and not (re.fullmatch(r"[A-Za-z0-9_]+", str(s["server"]))
                                         and (root / "mod" / "experiments" / f"{s['server']}.lua").is_file()):
            errs.append(f"step {i}: server module {s['server']!r} is not a mod/experiments/*.lua module")
        if kinds[0] == "fixture":
            fixtures.append(s)
        if kinds[0] == "bridge" and not isinstance(s.get("args", {}), dict):
            errs.append(f"step {i}: args must be an object")
    for f in fixtures:
        verb = f.get("verb") or f.get("fixture")
        if verb not in FIXTURE_VERBS:
            errs.append(f"fixture verb {verb!r} unknown")
        if verb == "grant" and item_ok and not item_ok(str(f.get("item"))):
            errs.append(f"fixture grant: item {f.get('item')!r} not in the catalog")
        if verb == "unlock" and spell_ok and not spell_ok(str(f.get("spell"))):
            errs.append(f"fixture unlock: spell {f.get('spell')!r} not in the catalog")
    if pre.get("input_mode") is not None and not str(pre["input_mode"]).startswith("DIM_"):
        errs.append("preconditions.input_mode must be a DIM_* mode")
    crit = spec.get("pass")
    if not isinstance(crit, list) or not crit:
        errs.append("pass must be a non-empty list of criteria")
        crit = []
    for i, c in enumerate(crit):
        errs += _expr_errors(c, f"pass[{i}]")
        ops = [o for o in OPS if o in c] if isinstance(c, dict) else []
        if len(ops) != 1:
            errs.append(f"pass[{i}]: exactly one operator of {OPS}")
    for i, c in enumerate(spec.get("observe") or []):
        errs += _expr_errors(c if isinstance(c, dict) else {"ref": c}, f"observe[{i}]")
    return errs


# ------------------------------------------------------------------ refs, templates, criteria (pure)
_MISSING = object()


def get_ref(ctx: dict, ref: str) -> Any:
    cur: Any = ctx
    for part in str(ref).split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        elif isinstance(cur, list) and re.fullmatch(r"-?\d+", part) and -len(cur) <= int(part) < len(cur):
            cur = cur[int(part)]
        else:
            return _MISSING
    return cur


def resolve(v: Any, ctx: dict) -> Any:
    """Templates inside step args: {"$ref": "a.b"}, {"$offset": ["a.position", [dx, dy, dz]]},
    {"$find": {"in": "a.list", "match": {"field": "substring"}, "get": "id"}} (case-insensitive substring match)."""
    if isinstance(v, list):
        return [resolve(x, ctx) for x in v]
    if not isinstance(v, dict):
        return v
    if "$ref" in v:
        x = get_ref(ctx, v["$ref"])
        if x is _MISSING:
            raise Blocked(f"unresolved {v['$ref']}")
        return x
    if "$offset" in v:
        ref, off = v["$offset"]
        base = get_ref(ctx, ref)
        if not (isinstance(base, list) and len(base) >= 2 and all(isinstance(b, (int, float)) for b in base)):
            raise Blocked(f"unresolved position {ref}")
        off = list(off) + [0] * (len(base) - len(off))
        return [round(b + o, 2) for b, o in zip(base, off)]
    if "$find" in v:
        f = v["$find"]
        rows = get_ref(ctx, f["in"])
        if not isinstance(rows, list):
            raise Blocked(f"unresolved list {f['in']}")
        for r in rows:
            if isinstance(r, dict) and all(str(want).lower() in str(r.get(k, "")).lower() for k, want in (f.get("match") or {}).items()):
                return r.get(f["get"]) if f.get("get") else r
        raise Blocked(f"nothing in {f['in']} matches {f.get('match')}")
    return {k: resolve(x, ctx) for k, x in v.items()}


def _num(x: Any) -> float | None:
    return float(x) if isinstance(x, (int, float)) and not isinstance(x, bool) else None


def value_of(e: dict, ctx: dict, logs: Callable[[str, str], list[str]]) -> Any:
    if "ref" in e:
        return get_ref(ctx, e["ref"])
    if "delta" in e:
        a, b = (get_ref(ctx, r) for r in e["delta"])
        a = 0 if a is _MISSING or a is None else a
        b = 0 if b is _MISSING or b is None else b
        return (b - a) if _num(a) is not None and _num(b) is not None else _MISSING
    if "dist" in e:
        a, b = (get_ref(ctx, r) for r in e["dist"])
        try:
            return round(math.hypot(a[0] - b[0], a[1] - b[1]), 2)
        except (TypeError, IndexError, KeyError):
            return _MISSING
    if "log" in e:
        return len(logs(e["log"]["source"], e["log"]["regex"]))
    return _MISSING


def compare(actual: Any, op: str, want: Any) -> bool:
    if op == "exists":
        return (actual is not _MISSING) == bool(want)
    if actual is _MISSING:
        return False
    if op == "eq":
        return actual == want
    if op == "ne":
        return actual != want
    if op == "truthy":
        return bool(actual) == bool(want)
    if op == "falsy":
        return (not actual) == bool(want)
    if op == "in":
        return actual in want
    if op == "contains":
        return want in actual if isinstance(actual, (list, str, dict)) else False
    if op == "regex":
        return re.search(want, str(actual)) is not None
    a, w = _num(actual), _num(want)
    if a is None or w is None:
        return False
    return {"gt": a > w, "gte": a >= w, "lt": a < w, "lte": a <= w}[op]


def evaluate(crit: list[dict], ctx: dict, logs: Callable[[str, str], list[str]]) -> tuple[bool, list[dict]]:
    rows, ok = [], True
    for c in crit:
        op = next(o for o in OPS if o in c)
        actual = value_of(c, ctx, logs)
        good = compare(actual, op, c[op])
        ok = ok and good
        lhs = {k: c[k] for k in ("ref", "delta", "dist", "log") if k in c}
        rows.append({**lhs, "op": op, "want": c[op], "actual": None if actual is _MISSING else actual,
                     "missing": actual is _MISSING, "ok": good, "why": c.get("why")})
    return ok, rows


def observe(items: list, ctx: dict, logs: Callable[[str, str], list[str]]) -> dict:
    out = {}
    for it in items or []:
        e = it if isinstance(it, dict) else {"ref": it}
        key = e.get("name") or e.get("ref") or json.dumps({k: e[k] for k in ("delta", "dist", "log") if k in e})
        v = value_of(e, ctx, logs)
        out[key] = None if v is _MISSING else v
    return out


def short(v: Any, n: int = 1500) -> Any:
    s = json.dumps(v, default=str)
    return v if len(s) <= n else {"truncated": s[:n]}


# ------------------------------------------------------------------ state (verdicts across runs)
def load_state(p: Path = STATE_FILE) -> dict:
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"checks": {}}


def save_state(st: dict, p: Path = STATE_FILE) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps(st, indent=1), encoding="utf-8")
    os.replace(tmp, p)


def entry(st: dict, cid: str, h: str) -> dict:
    """The check's state row; a changed check file starts over as pending."""
    e = st.setdefault("checks", {}).get(cid)
    if not e or e.get("hash") != h:
        e = {"status": "pending", "hash": h, "inconclusive_runs": 0, "history": []}
        st["checks"][cid] = e
    return e


def is_pending(e: dict) -> bool:
    if e["status"] in DONE:
        return False
    return e.get("inconclusive_runs", 0) < MAX_INCONCLUSIVE_RUNS


# ------------------------------------------------------------------ environment (real side effects; tests fake it)
class Env:
    """Everything with a side effect. tests/test_live_queue.py replaces it."""

    def __init__(self) -> None:
        self._bridge = None
        self._dev = None

    # clock
    def now(self) -> float:
        return time.time()

    def sleep(self, s: float) -> None:
        time.sleep(max(0.0, s))

    # guards
    def held(self) -> str | None:
        return next((str(p) for p in HOLD_FILES if p.exists()), None)

    def slot_status(self) -> dict:
        from tools import client_slot
        return _slot_json(client_slot.main, ["status"])

    def slot_take(self, minutes: float, why: str) -> bool:
        from tools import client_slot
        return bool(_slot_json(client_slot.main, ["take", OWNER, f"{minutes:.0f}", "--why", why]).get("ok"))

    def slot_release(self) -> None:
        from tools import client_slot
        _slot_json(client_slot.main, ["release", OWNER])

    def client_status(self) -> dict:
        try:
            return json.loads(CLIENT_STATUS.read_text(encoding="utf-8-sig"))
        except (OSError, ValueError):
            return {}

    def dev(self):
        if self._dev is None:
            from evals.bench.devrun import default_dev
            self._dev = default_dev()
        return self._dev

    def guard(self) -> None:
        """Dev server only, run_live not running (raises InfraError with the reason)."""
        from evals.bench.observer import Abort
        try:
            self.dev().guard("live_queue")
        except Abort as x:
            raise InfraError(str(x)) from x

    # body
    def bridge(self, tool: str, args: dict, timeout: float) -> dict:
        if self._bridge is None:
            from brain.bridge_client import BridgeClient
            from brain.transport import file_transport_pair
            self._bridge = BridgeClient(file_transport_pair(body="client", channel="debug")[0])
        r = self._bridge.request(tool, args, timeout=timeout)
        return r if isinstance(r, dict) else {"ok": False, "reason": repr(r)}

    def reset_bridge(self) -> None:
        self._bridge = None

    def client_cmd(self, rel: str, args: dict | None, timeout: float) -> dict | None:
        from tools.scenario_run import run_client_cmd
        p = ROOT / rel
        return run_client_cmd(p, "lq_" + p.stem, args or None, timeout)

    def probe(self) -> dict:
        from evals.bench.devtarget import normalise_probe
        r = self.client_cmd("client_mod/commands/bench_probe.lua", None, 30)
        res = (r or {}).get("result") or {}
        if not res.get("ok"):
            raise InfraError(f"probe failed: {(r or {}).get('error') or res.get('error') or 'no answer'}")
        return normalise_probe(res["probe"])

    def server(self, module: str, args: dict, timeout: float) -> dict:
        """debug_run of a mod/experiments module on the DEV server (after the dev guard); the module's own result."""
        from brain.bridge_client import BridgeClient
        from brain.transport import file_transport_pair
        self.guard()
        dev = self.dev()
        r = BridgeClient(file_transport_pair(body="server", channel="main")[0]).request(
            "debug_run", {"module": module, "args": {"character_guid": dev.character_guid, **(args or {})}}, timeout=timeout)
        if not isinstance(r, dict) or not r.get("ok"):
            raise InfraError(f"server {module}: {(r or {}).get('reason') if isinstance(r, dict) else r!r} "
                             f"{((r or {}).get('data') or {}).get('detail') if isinstance(r, dict) else ''}")
        res = (r.get("data") or {}).get("result")
        return res if isinstance(res, dict) else {"ok": False, "result": res}

    def fixture(self, verb: str, purpose: str, args: dict) -> dict:
        from evals.bench.observer import Abort
        try:
            return self.dev().setup(verb, purpose=purpose, **args)
        except Abort as x:
            raise Blocked(f"fixture {verb}: {x}") from x
        except (KeyError, TypeError, ValueError) as x:
            raise Blocked(f"fixture {verb}: {x!r}") from x

    # logs
    def log_offsets(self) -> dict:
        return {k: (p.stat().st_size if p.exists() else 0) for k, p in LOG_SOURCES.items()}

    def log_lines(self, source: str, since: int, regex: str) -> list[str]:
        p = LOG_SOURCES[source]
        try:
            with open(p, "rb") as f:
                size = p.stat().st_size
                f.seek(since if since <= size else 0)  # a rotated/truncated log: read it from the start
                text = f.read().decode("utf-8", "replace")
        except OSError:
            return []
        rx = re.compile(regex)
        return [ln for ln in text.splitlines() if rx.search(ln)][-20:]


def _slot_json(fn: Callable, argv: list[str]) -> dict:
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        fn(argv)
    try:
        return json.loads(buf.getvalue().strip().splitlines()[-1])
    except (ValueError, IndexError):
        return {}


# ------------------------------------------------------------------ the runner
@dataclass
class Runner:
    env: Env
    out: Path = field(default_factory=lambda: RESULT_DIR / f"{datetime.now().strftime('%Y-%m-%d')}.jsonl")
    state_path: Path = STATE_FILE
    run_id: str = field(default_factory=lambda: datetime.now().strftime("%Y%m%d-%H%M%S"))
    verbose: bool = True

    def write(self, event: str, **kv) -> None:
        row = {"t": iso(self.env.now()), "run": self.run_id, "event": event, **kv}
        self.out.parent.mkdir(parents=True, exist_ok=True)
        with open(self.out, "a", encoding="utf-8") as f:
            f.write(json.dumps(row, default=str) + "\n")
        if self.verbose:
            print(json.dumps(row, default=str)[:600], flush=True)

    # ---- health and recovery
    def precheck(self) -> None:
        h = self.env.held()
        if h:
            raise HoldSet(h)
        st = self.env.client_status()
        age = self.env.now() - _ts(st.get("ts"))
        if st.get("state") != "in_world" or age > STATUS_FRESH_S:
            raise InfraError(f"client not in world (watchdog status {st.get('state')!r}, {age:.0f} s old)")
        self.env.guard()
        r = self.env.bridge("ping", {}, 8)
        if not r.get("ok"):
            raise InfraError(f"bridge ping failed: {r.get('reason')}")

    def bridge_start(self) -> dict:
        r = self.env.client_cmd("client_mod/commands/bridge_start.lua", None, 30) or {"ok": False, "error": "no_reply"}
        self.env.reset_bridge()
        return short(r, 600)

    def recover(self, why: str) -> bool:
        """After a check: crashed client -> wait for the watchdog's relaunch + bridge_start; stuck input mode -> the
        gate's sweep once. False = could not recover (the run stops)."""
        t0 = self.env.now()
        try:
            self.precheck()
            healthy = True
        except InfraError as x:
            healthy, first = False, str(x)
        if not healthy:
            self.write("recover_wait", why=why, problem=first)
            while self.env.now() - t0 < RELAUNCH_WAIT_S:
                if self.env.held():
                    raise HoldSet(self.env.held())
                self.env.sleep(10)
                try:
                    self.precheck()
                    break
                except InfraError:
                    continue
            else:
                self.write("recover_failed", why=why, problem=first, waited_s=round(self.env.now() - t0))
                return False
            self.write("recover_bridge_start", result=self.bridge_start())
        try:
            mode = self.env.probe().get("input_mode")
        except InfraError as x:
            self.write("recover_failed", why=why, problem=str(x))
            return False
        if mode != "DIM_Gameplay":
            g = self.env.client_cmd("client_mod/commands/input_gate_once.lua", None, 15)
            self.env.sleep(1.5)
            after = self.env.probe().get("input_mode")
            self.write("recover_input_mode", before=mode, gate=short(g, 400), after=after,
                       stuck=after != "DIM_Gameplay")
        return True

    # ---- one check
    def run_check(self, spec: dict) -> tuple[str, dict]:
        env, deadline = self.env, self.env.now() + float(spec["timeout_s"])
        ctx: dict = {"check": {"id": spec["id"]}}
        offs = env.log_offsets()
        logs = lambda src, rx: env.log_lines(src, offs.get(src, 0), rx)  # noqa: E731
        ev: dict = {"steps": [], "setup": []}

        def left() -> float:
            r = deadline - env.now()
            if r <= 0:
                raise InfraError("check timeout")
            return r
        try:
            pre = spec.get("preconditions") or {}
            fixtures = list(pre.get("fixtures") or [])
            if pre.get("set_health") is not None:
                fixtures.append({"verb": "set_health", **pre["set_health"]})
            for f in fixtures:
                a = {k: v for k, v in f.items() if k not in ("verb", "fixture", "purpose")}
                r = env.fixture(f.get("verb") or f["fixture"], f.get("purpose") or f"live check {spec['id']}", resolve(a, ctx))
                ev["setup"].append({"verb": f.get("verb"), "ok": bool(r.get("ok")), "result": short(r, 300)})
            if pre.get("input_mode"):
                mode = env.probe().get("input_mode")
                if mode != pre["input_mode"]:
                    raise Blocked(f"input mode is {mode}, need {pre['input_mode']}")
            for i, s in enumerate(spec["steps"]):
                left()
                rec = self._step(i, s, ctx, left)
                ev["steps"].append(rec)
        except Blocked as x:
            return "blocked", {**ev, "why": str(x), **self._cleanup(spec, ctx)}
        except InfraError as x:
            return "error", {**ev, "why": str(x), **self._cleanup(spec, ctx)}
        ev.update(self._cleanup(spec, ctx))
        ok, rows = evaluate(spec["pass"], ctx, logs)
        ev["criteria"] = rows
        ev["observed"] = observe(spec.get("observe") or [], ctx, logs)
        if spec.get("observe_only"):
            return "observed", ev
        return ("passed" if ok else "failed"), ev

    def _cleanup(self, spec: dict, ctx: dict) -> dict:
        """`cleanup` steps (teardown, e.g. remove what the check spawned) run after the steps whatever happened, each
        best effort with its own small time budget; a template that does not resolve (the thing was never made) skips
        that step. Their saves join ctx, so pass/observe can read them."""
        out = []
        for i, s in enumerate(spec.get("cleanup") or []):
            try:
                rec = self._step(i, s, ctx, lambda: 60.0)
            except Blocked as x:
                rec = {"i": i, "skipped": str(x)}
            except Exception as x:  # noqa: BLE001  (teardown never raises; the failure is evidence)
                rec = {"i": i, "error": repr(x)}
            out.append(rec)
        return {"cleanup": out} if out else {}

    def _step(self, i: int, s: dict, ctx: dict, left: Callable[[], float]) -> dict:
        env = self.env
        save = s.get("save")
        t0 = env.now()
        if "sleep_s" in s:
            env.sleep(min(float(s["sleep_s"]), left()))
            return {"i": i, "sleep_s": s["sleep_s"]}
        if "probe" in s:
            val = env.probe()
            rec = {"i": i, "probe": True, "input_mode": val.get("input_mode"), "position": val.get("position")}
        elif "fixture" in s:
            a = {k: v for k, v in s.items() if k not in ("fixture", "save", "purpose")}
            val = env.fixture(s["fixture"], s.get("purpose") or "live check step", resolve(a, ctx))
            rec = {"i": i, "fixture": s["fixture"], "ok": bool(val.get("ok"))}
        elif "server" in s:
            val = env.server(s["server"], resolve(s.get("args") or {}, ctx), min(float(s.get("timeout_s", 30)), left()))
            rec = {"i": i, "server": s["server"], "ok": bool(val.get("ok")), "result": short(val, 1200)}
        elif "client_cmd" in s:
            val = env.client_cmd(s["client_cmd"], resolve(s.get("args") or {}, ctx), min(float(s.get("timeout_s", 20)), left()))
            if val is None:
                raise InfraError(f"step {i}: {s['client_cmd']} did not answer")
            rec = {"i": i, "client_cmd": s["client_cmd"], "result": short(val, 800)}
        else:
            args = resolve(s.get("args") or {}, ctx)
            val = env.bridge(s["bridge"], args, min(float(s.get("timeout_s", 60)), left()))
            rec = {"i": i, "bridge": s["bridge"], "args": args, "ok": val.get("ok"), "reason": val.get("reason"),
                   "reply": short(val, 1200)}
            if not val.get("ok") and val.get("reason") in INFRA_REASONS:
                raise InfraError(f"step {i}: {s['bridge']} -> {val.get('reason')}")
        if save:
            ctx[save] = val
        rec["s"] = round(env.now() - t0, 1)
        return rec

    # ---- the drain
    def drain(self, checks: list[tuple[Path, dict]], only: set[str] | None = None) -> dict:
        st = load_state(self.state_path)
        todo = []
        for p, spec in checks:
            e = entry(st, spec["id"], file_hash(p))
            if (only and spec["id"] in only) or (not only and is_pending(e)):
                todo.append(spec)
        save_state(st, self.state_path)
        summary: dict = {"run": self.run_id, "checks": {}}
        if not todo:
            self.write("run_empty")
            return summary
        minutes = sum(float(s["timeout_s"]) * (1 + int(s.get("max_retries", 0))) for s in todo) / 60 + 10
        if not self.env.slot_take(min(minutes, 120), f"live queue: {len(todo)} checks"):
            self.write("run_slot_busy", slot=self.env.slot_status())
            summary["slot_busy"] = True
            return summary
        try:
            if self.env.held():
                raise HoldSet(self.env.held())
            try:
                self.precheck()
            except InfraError as x:
                self.write("run_precheck_failed", why=str(x))
                summary["precheck_failed"] = str(x)
                return summary
            self.write("run_start", checks=[s["id"] for s in todo], bridge_start=self.bridge_start())
            for spec in todo:
                if self.env.held():
                    raise HoldSet(self.env.held())
                self.env.slot_take(float(spec["timeout_s"]) * (1 + int(spec.get("max_retries", 0))) / 60 + 5,
                                   f"live queue: {spec['id']}")
                verdict, attempts = "error", 0
                for attempt in range(1 + int(spec.get("max_retries", 0))):
                    attempts = attempt + 1
                    t0 = self.env.now()
                    verdict, ev = self.run_check(spec)
                    self.write("check", id=spec["id"], owner=spec.get("owner"), commit=spec.get("commit"),
                               area=spec.get("area"), attempt=attempts, verdict=verdict,
                               duration_s=round(self.env.now() - t0, 1), evidence=ev)
                    recovered = self.recover(f"after {spec['id']} ({verdict})")
                    if not recovered:
                        break
                    if verdict in ("passed", "observed", "blocked"):
                        break
                st = load_state(self.state_path)
                e = entry(st, spec["id"], next(file_hash(p) for p, s in checks if s["id"] == spec["id"]))
                e["status"] = verdict
                e["last_run"] = iso(self.env.now())
                e["attempts"] = attempts
                e["results_file"] = str(self.out)
                e["inconclusive_runs"] = e.get("inconclusive_runs", 0) + (verdict in ("blocked", "error"))
                e["history"] = (e.get("history") or [])[-9:] + [{"run": self.run_id, "verdict": verdict}]
                save_state(st, self.state_path)
                summary["checks"][spec["id"]] = verdict
                if not recovered:
                    summary["stopped"] = "client did not recover"
                    break
        except HoldSet as h:
            self.write("run_hold", hold=str(h))
            summary["stopped"] = f"hold {h}"
        finally:
            self.env.slot_release()
            self.write("run_end", summary=summary)
        return summary


def _ts(s: Any) -> float:
    """ISO time from PowerShell ('...44.4604404Z': 7 fraction digits) or Python -> epoch; 0 when unreadable."""
    try:
        d = datetime.fromisoformat(re.sub(r"(\.\d{6})\d+", r"\1", str(s)).replace("Z", "+00:00"))
        return (d if d.tzinfo else d.replace(tzinfo=timezone.utc)).timestamp()
    except ValueError:
        return 0.0


# ------------------------------------------------------------------ single instance (OS lock, released on death)
@contextlib.contextmanager
def single_instance(p: Path = LOCK_FILE):
    p.parent.mkdir(parents=True, exist_ok=True)
    f = open(p, "a+")
    try:
        try:
            if os.name == "nt":
                import msvcrt
                f.seek(0)
                msvcrt.locking(f.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            yield False
            return
        f.seek(0)
        f.truncate()
        f.write(f"{os.getpid()} {iso()}\n")
        f.flush()
        yield True
    finally:
        f.close()


# ------------------------------------------------------------------ CLI
def catalog_lookups() -> tuple[Callable[[str], bool] | None, Callable[[str], bool] | None]:
    try:
        from evals.bench.devtarget import item_path, spell_path
        return (lambda i: item_path(i) is not None), (lambda s: spell_path(s) is not None)
    except Exception:  # noqa: BLE001  (the dry run still checks the structure without the catalog)
        return None, None


def body_tool_known(tool: str, scripts: Path = ROOT / "client_mod" / "scripts") -> bool:
    """Offline hint only: the bridge tool's name appears as a manifest/handler/route key in client_mod/scripts."""
    rx = re.compile(r"(^|[\s{,.])" + re.escape(tool) + r"\s*=", re.M)
    return tool in ("ping", "capabilities", "get_state") or any(rx.search(f.read_text(encoding="utf-8", errors="replace"))
                                                                for f in scripts.glob("*.lua"))


def dry_run(checks: list[tuple[Path, dict]]) -> int:
    item_ok, spell_ok = catalog_lookups()
    st, bad = load_state(), 0
    for p, spec in checks:
        errs = validate(spec, p, item_ok=item_ok, spell_ok=spell_ok)
        errs += [f"bridge tool {s['bridge']!r} not found in client_mod/scripts" for s in spec.get("steps") or []
                 if isinstance(s, dict) and "bridge" in s and not body_tool_known(str(s["bridge"]))]
        cid = spec.get("id", p.stem)
        e = (st.get("checks") or {}).get(cid) or {}
        changed = e and e.get("hash") != file_hash(p)
        status = "pending" if (not e or changed) else e.get("status")
        print(json.dumps({"id": cid, "valid": not errs, "errors": errs, "status": status,
                          "would_run": not errs and (not e or changed or is_pending(e))}))
        bad += bool(errs)
    if item_ok is None:
        print(json.dumps({"note": "catalog lookups unavailable (run with .venv python): items/spells not checked"}))
    return 1 if bad else 0


def cmd_list(checks) -> int:
    st = load_state()
    for p, spec in checks:
        e = (st.get("checks") or {}).get(spec.get("id")) or {}
        changed = bool(e) and e.get("hash") != file_hash(p)
        print(f"{spec.get('id', p.stem):32} {('pending (edited)' if changed else e.get('status', 'pending')):16} "
              f"owner={spec.get('owner')} commit={spec.get('commit', '-')} last={e.get('last_run', '-')}")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list")
    sub.add_parser("status")
    a_add = sub.add_parser("add")
    a_add.add_argument("file")
    a_add.add_argument("--requeue", action="store_true")
    a_rq = sub.add_parser("requeue")
    a_rq.add_argument("id")
    a_run = sub.add_parser("run")
    a_run.add_argument("--dry-run", action="store_true", help="validate the check files only")
    a_run.add_argument("--if-free", action="store_true", help="no-op unless the slot is free and a check is pending")
    a_run.add_argument("--only", default="", help="comma list of ids (runs them even if done)")
    a = ap.parse_args(argv)
    checks = load_checks()
    if a.cmd == "list":
        return cmd_list(checks)
    if a.cmd == "status":
        env = Env()
        with single_instance() as free:
            running = not free
        rows = sorted(RESULT_DIR.glob("*.jsonl"))
        last = None
        if rows:
            for ln in rows[-1].read_text(encoding="utf-8").splitlines()[::-1]:
                if '"run_end"' in ln:
                    last = json.loads(ln)
                    break
        st = load_state()
        pending = [s["id"] for p, s in checks if is_pending(entry(st, s["id"], file_hash(p)))]
        print(json.dumps({"running": running, "slot": env.slot_status(), "hold": env.held(), "pending": pending,
                          "last_run": last}, indent=1))
        return 0
    if a.cmd == "add":
        src = Path(a.file).resolve()
        spec = json.loads(src.read_text(encoding="utf-8"))
        item_ok, spell_ok = catalog_lookups()
        errs = validate(spec, None, item_ok=item_ok, spell_ok=spell_ok)
        if errs:
            print(json.dumps({"ok": False, "errors": errs}))
            return 1
        dst = CHECK_DIR / f"{spec['id']}.json"
        if src != dst.resolve():
            dst.write_text(json.dumps(spec, indent=1) + "\n", encoding="utf-8")
        if a.requeue:
            return main(["requeue", spec["id"]])
        print(json.dumps({"ok": True, "file": str(dst)}))
        return 0
    if a.cmd == "requeue":
        st = load_state()
        p = CHECK_DIR / f"{a.id}.json"
        if not p.exists():
            print(json.dumps({"ok": False, "error": f"no check {a.id}"}))
            return 1
        st.setdefault("checks", {})[a.id] = {"status": "pending", "hash": file_hash(p), "inconclusive_runs": 0,
                                             "history": ((st["checks"].get(a.id) or {}).get("history") or [])}
        save_state(st)
        print(json.dumps({"ok": True, "id": a.id, "status": "pending"}))
        return 0
    # run
    if a.dry_run:
        return dry_run(checks)
    only = {x for x in a.only.split(",") if x} or None
    bad = [(s.get("id", p.stem), errs) for p, s in checks if (errs := validate(s, p))]
    if bad:
        print(json.dumps({"invalid_checks": bad}))
        checks = [(p, s) for p, s in checks if not validate(s, p)]
    env = Env()
    if a.if_free:
        st = load_state()
        pending = [s["id"] for p, s in checks if is_pending(entry(st, s["id"], file_hash(p)))]
        slot = env.slot_status()
        if not pending or not slot.get("free") or env.held():
            return 0
        try:  # cheap gates before touching the slot: in world, on the dev server, run_live not running
            st_c = env.client_status()
            if st_c.get("state") != "in_world" or env.now() - _ts(st_c.get("ts")) > STATUS_FRESH_S:
                return 0
            env.guard()
        except InfraError:
            return 0
    with single_instance() as mine:
        if not mine:
            print(json.dumps({"ok": True, "note": "another live_queue run holds the lock"}))
            return 0
        summary = Runner(env).drain(checks, only)
    return 0 if all(v in DONE - {"failed"} for v in summary.get("checks", {}).values()) else 2


if __name__ == "__main__":
    sys.exit(main())
