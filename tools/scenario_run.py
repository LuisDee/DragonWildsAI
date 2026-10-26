"""Scenario suite for Claude's game client on the nav-only DEV server (streamline plan step 6, task S.6).

Switches Claude's client from Luis's Shockbyte world to the dev server, runs scripted scenarios through the
DWClient bridge (debug channel) and command runner, asserts each outcome from FRESH game state, writes a
JSON + Markdown report (+ the run's merged timeline) to logs/scenarios/, and switches back to Shockbyte.

  .venv\\Scripts\\python.exe -m tools.scenario_run                    # DRY RUN (default): read-only, no switch
  .venv\\Scripts\\python.exe -m tools.scenario_run --live             # switch to dev, run, switch back
  .venv\\Scripts\\python.exe -m tools.scenario_run --live --only pit_escape,ledge_jump
  .venv\\Scripts\\python.exe -m tools.scenario_run --here             # already on dev: run there, no switching

Live run, in order (any failure still runs the restore steps):
  1. preflight: client in world, joined server = Shockbyte, no hold file, dev server running, dev target file,
     nav oracle alive, the live brain (run_live) NOT running (its actions would share the one action slot;
     --allow-brain overrides).
  2. baseline on Shockbyte: inventory counts, skills, gear, position (read-only get_state).
  3. backup of Claude.json, then a target LEASE (logs/state/client_target.json, renewed per scenario) so the
     client watchdog's rejoins during the run go to dev, and an expired lease sends him back to Shockbyte.
  4. tools/client_boot.ps1 -Target dev (disconnect, join dev), verified from the game log's LoadMap address.
  5. scenarios (tools/scenarios/dev_suite.json): pass | fail | skip | error, each with evidence.
  6. lease removed, tools/client_boot.ps1 -Target shockbyte, verified; post-run snapshot compared with the
     baseline (Shockbyte keeps its own per-character state, so nothing should change; a diff is reported).

Navigation memory (--memory): move.lua learns routes/traps into the world store named by
traverse_learn.world_id(), whose fallback is "shockbyte" on EVERY server. So a live run sets _G.DW_WORLD_GUID
(client_mod/commands/scn_world.lua) after the switch, re-applies it per scenario and restores it before switching back:
  dev     (default) "dev_scenarios": isolated store that keeps learning across runs; Shockbyte's memory untouched
  nomem   "scn_nomem_<ts>": a fresh empty store for this run (map seeds still load: data/nav/L_World_seeds.json)
  shared  no override: uses and WRITES Shockbyte's memory (same map; opt-in only)

Dry run: on whatever server the client is on, read-only: capabilities, get_state, the ledge probe (traces),
and per scenario the candidates it would use (items, creatures, graves) and leg distances. No movement, no chat.
Scenario kinds (KINDS): go_to_chain, ledge_jump, fetch_consume, combat, collect_cluster, grave_recovery.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

ROOT = Path(__file__).resolve().parents[1]
SUITE = ROOT / "tools" / "scenarios" / "dev_suite.json"
REPORT_DIR = ROOT / "logs" / "scenarios"
CLIENT_IO = Path(os.environ.get("DW_CLIENT_IO", ROOT / "client_io"))
STATE_DIR = Path(os.environ.get("DW_CLIENT_STATE_DIR", ROOT / "logs" / "state"))
LEASE = STATE_DIR / "client_target.json"
SECRETS = CLIENT_IO / "secrets"
HOLD_FILES = [ROOT / "logs" / "client.stopped", ROOT / "logs" / "client.hold"]
GAME_LOG = Path(os.environ.get("DW_CLIENT_GAME_LOG",
                               Path(os.environ.get("LOCALAPPDATA", "")) / "RSDragonwilds" / "Saved" / "Logs" / "RSDragonwilds.log"))
CLIENT_LOG = Path(os.environ.get("DW_CLIENT_MOD_LOG", ROOT / "logs" / "client" / "client.log"))
CHAR_FILE = Path(os.environ.get("LOCALAPPDATA", "")) / "RSDragonwilds" / "Saved" / "SaveCharacters" / "Claude.json"
BACKUPS = Path(r"C:\GameServers\backups")
DEFAULT_TARGET = "shockbyte"


def now() -> float:
    return time.time()


def iso(t: float | None = None) -> str:
    return datetime.fromtimestamp(t if t is not None else now(), timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def d2(a, b) -> float:
    return math.hypot(a[0] - b[0], a[1] - b[1])


# ------------------------------------------------------------------ the world as files (targets, lease, game log)
def target_file(name: str) -> Path:
    if name == DEFAULT_TARGET:
        return SECRETS / "server.txt"
    if not re.fullmatch(r"[a-z0-9_]+", name):
        raise ValueError(f"bad target name {name!r}")
    return SECRETS / f"server_{name}.txt"


def target_address(name: str) -> str | None:
    """Line 1 of the target file (host:port). The password (line 2) is never read here."""
    try:
        with open(target_file(name), encoding="utf-8-sig") as f:
            return f.readline().strip() or None
    except OSError:
        return None


def joined_server(game_log: Path = GAME_LOG) -> str | None:
    """host:port from the client game log's last 'LoadMap: <addr>/Game/Maps/World/L_World' (as client_lib.ps1)."""
    last = None
    try:
        with open(game_log, encoding="utf-8", errors="replace") as f:
            for line in f:
                if "LoadMap: " in line:
                    last = line
    except OSError:
        return None
    m = re.search(r"LoadMap: ([0-9A-Za-z.\-]+:\d+)/Game/Maps/World/L_World", last or "")
    return m.group(1) if m else None


def frontend_state(timeout_s: float = 60) -> dict | None:
    """Front-end returns of the running client process (BUGS L24): tools/client_frontend.ps1 ->
    {pid, returns, log, recorded, max, needs_relaunch}. The game crashes on the 3rd return to the menu in one process;
    client_boot.ps1 enforces the rule itself (with needs_relaunch it relaunches instead of disconnecting/rejoining), so
    a switch through Ops.boot is always safe. Callers use this to report and plan (a relaunch takes ~1-2 min and loses
    module state such as the scenario memory world). None when PowerShell gives no answer."""
    try:
        out = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                              str(ROOT / "tools" / "client_frontend.ps1")], capture_output=True, text=True,
                             timeout=timeout_s).stdout
        return json.loads(out.strip().splitlines()[-1])
    except (OSError, subprocess.TimeoutExpired, ValueError, IndexError):
        return None


def relaunched(boot_result: dict) -> bool:
    """Did this client_boot run relaunch the client for the front-end limit (its actions say so)?"""
    return any("relaunch client" in str(a) for a in boot_result.get("actions") or [])


def write_lease(target: str, minutes: float, by: str) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = LEASE.with_suffix(".tmp")
    tmp.write_text(json.dumps({"target": target, "until": iso(now() + minutes * 60), "by": by}), encoding="utf-8")
    os.replace(tmp, LEASE)


def clear_lease() -> None:
    try:
        LEASE.unlink()
    except FileNotFoundError:
        pass


def lua_literal(v) -> str:
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(float(v)) if isinstance(v, float) else str(v)
    if isinstance(v, str):
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'
    if isinstance(v, (list, tuple)):
        return "{" + ", ".join(lua_literal(x) for x in v) + "}"
    if isinstance(v, dict):
        parts = []
        for k, x in v.items():
            if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", str(k)):
                raise ValueError(f"bad Lua key {k!r}")
            parts.append(f"{k} = {lua_literal(x)}")
        return "{" + ", ".join(parts) + "}"
    raise TypeError(type(v))


def run_client_cmd(file: Path, name: str, args: dict | None = None, timeout: float = 20.0) -> dict | None:
    """One client_mod command through the DWClient runner (same protocol as Invoke-ClientCmd /
    tools/client_cmd.sh), with `local ARGS = {...}` prefixed when args are given. None on timeout."""
    cmd_dir, out_dir = CLIENT_IO / "cmd", CLIENT_IO / "out"
    cmd_dir.mkdir(parents=True, exist_ok=True)
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / f"{name}.json"
    out.unlink(missing_ok=True)
    src = file.read_text(encoding="utf-8")
    if args:
        src = f"local ARGS = {lua_literal(args)}\n" + src
    tmp = cmd_dir / f"{name}.tmp"
    tmp.write_text(src, encoding="utf-8")
    os.replace(tmp, cmd_dir / f"{name}.lua")
    # the runner reads client_io/cmd/queue.txt (no directory listing on the game thread, L28): queue the name
    with open(cmd_dir / "queue.txt", "a", encoding="ascii") as q:
        q.write(name + "\n")
    deadline = now() + timeout
    while now() < deadline:
        time.sleep(0.25)
        if out.exists():
            for _ in range(8):
                try:
                    return json.loads(out.read_text(encoding="utf-8-sig"))
                except (OSError, ValueError):
                    time.sleep(0.1)
    (cmd_dir / f"{name}.lua").unlink(missing_ok=True)
    return None


# ------------------------------------------------------------------ ops: process checks, boot, backups (PowerShell side)
class Ops:
    """Everything outside the bridge. Tests replace it with a fake."""

    def brain_running(self) -> bool:
        return bool(self._procs("python.exe", "run_live"))

    def dev_server_running(self) -> bool:
        return bool(self._procs("RSDragonwildsServer-Win64-Shipping.exe", ""))

    def held(self) -> str | None:
        return next((str(p) for p in HOLD_FILES if p.exists()), None)

    def nav_oracle_age_s(self) -> float | None:
        p = CLIENT_IO / "nav" / "alive.lua"
        return now() - p.stat().st_mtime if p.exists() else None

    def joined(self) -> str | None:
        return joined_server()

    def frontend(self) -> dict | None:
        return frontend_state()

    def boot(self, target: str, timeout_s: float = 900) -> dict:
        """tools/client_boot.ps1 -Target <target>; the result from logs/state/client_status.json."""
        cmd = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(ROOT / "tools" / "client_boot.ps1"),
               "-Target", target, "-Quiet"]
        t0 = now()
        try:
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout_s)
            code = p.returncode
        except subprocess.TimeoutExpired:
            code = -1
        st = {}
        try:
            st = json.loads((STATE_DIR / "client_status.json").read_text(encoding="utf-8-sig")).get("last_boot") or {}
        except (OSError, ValueError):
            pass
        return {"exit": code, "ok": code == 0, "state": st.get("state"), "reason": st.get("reason"),
                "actions": st.get("actions"), "joined": self.joined(), "duration_s": round(now() - t0, 1)}

    def backup_character(self) -> str | None:
        if not CHAR_FILE.exists():
            return None
        BACKUPS.mkdir(parents=True, exist_ok=True)
        dst = BACKUPS / f"claude_char_{datetime.now().strftime('%Y%m%d-%H%M%S')}_pre_scenarios.json"
        shutil.copy2(CHAR_FILE, dst)
        return str(dst)

    @staticmethod
    def _procs(image: str, needle: str) -> list[str]:
        try:
            out = subprocess.run(["powershell", "-NoProfile", "-Command",
                                  f"Get-CimInstance Win32_Process -Filter \"Name='{image}'\" | ForEach-Object {{ $_.CommandLine }}"],
                                 capture_output=True, text=True, timeout=30).stdout
        except (OSError, subprocess.TimeoutExpired):
            return []
        return [x for x in out.splitlines() if x.strip() and needle in x]


def log_offset(path: Path = CLIENT_LOG) -> int:
    try:
        return path.stat().st_size
    except OSError:
        return 0


def log_since(offset: int, path: Path = CLIENT_LOG, max_bytes: int = 2_000_000) -> list[str]:
    """client.log lines written after `offset` (what the modules logged during a leg)."""
    try:
        with open(path, "rb") as f:
            f.seek(offset)
            return f.read(max_bytes).decode("utf-8", "replace").splitlines()
    except OSError:
        return []


class Body:
    """The client bridge's DEBUG channel (tools/bridge_cmd --channel debug): same tools, its own file pair."""

    def __init__(self):
        from brain.bridge_client import BridgeClient
        from brain.jsonl_log import JsonlLogger
        from brain.transport import file_transport_pair
        brain_side, _ = file_transport_pair(body="client", channel="debug")
        REPORT_DIR.mkdir(parents=True, exist_ok=True)
        self.client = BridgeClient(brain_side, logger=JsonlLogger(REPORT_DIR / f"bridge_{datetime.now():%Y%m%d-%H%M%S}.jsonl"))

    def request(self, tool: str, args: dict | None = None, timeout: float = 15.0) -> dict:
        return self.client.request(tool, args or {}, timeout=timeout)

    log_offset = staticmethod(log_offset)
    log_since = staticmethod(log_since)

    def cmd(self, file: str, args: dict | None = None, timeout: float = 20.0) -> dict | None:
        stem = Path(file).stem
        return run_client_cmd(ROOT / "client_mod" / "commands" / file, stem if stem.startswith("scn_") else "scn_" + stem, args, timeout)


# ------------------------------------------------------------------ the runner
@dataclass
class Outcome:
    scenario: str
    result: str                  # pass | fail | skip | error | dry
    detail: str
    evidence: dict = field(default_factory=dict)
    started: float = 0.0
    duration_s: float = 0.0


class Runner:
    def __init__(self, body, ops, suite: dict, live: bool, log: Callable[[str], None] = print):
        self.body, self.ops, self.suite, self.live, self.say = body, ops, suite, live, log
        self.places = suite.get("places", {})
        self.steps: list[dict] = []
        self.caps: set[str] = set()

    # ---- helpers
    def step(self, scenario: str, result: str, detail: str, **ev) -> None:
        self.steps.append({"ts": iso(), "scenario": scenario, "result": result, "detail": detail, **({"evidence": ev} if ev else {})})
        self.say(f"  [{scenario}] {result}: {detail}")

    def place(self, p) -> list[float]:
        if isinstance(p, str):
            if p not in self.places:
                raise KeyError(f"unknown place {p!r}")
            return list(self.places[p])
        return list(p)

    def state(self) -> dict | None:
        r = self.body.request("get_state", {}, timeout=15)
        return r.get("data") if r.get("ok") else None

    def look(self, about: str | None = None, radius: float = 30, max_n: int = 30) -> list[dict]:
        args = {"radius": radius, "max": max_n}
        if about:
            args["about"] = about
        r = self.body.request("look", args, timeout=15)
        return (r.get("data") or {}).get("things", []) if r.get("ok") else []

    def go(self, to, tol: float, timeout: float, label: str, expect_log: str | None = None) -> tuple[bool, dict]:
        """go_to + verification from a fresh get_state (2D within tol, height within 1.5 m). expect_log: a regex
        over what client.log got during the leg (e.g. 'remembered route'), reported as evidence, not required."""
        goal = self.place(to)
        off = self.body.log_offset() if expect_log and hasattr(self.body, "log_offset") else None
        t0 = now()
        r = self.body.request("go_to", {"target": goal, "tolerance": tol}, timeout=min(timeout, 105) + 15)
        st = self.state() or {}
        here = st.get("position")
        ev = {"leg": label, "goal": goal, "ok": r.get("ok"), "reason": r.get("reason"),
              "detail": (r.get("data") or {}).get("detail"), "position": here, "secs": round(now() - t0, 1)}
        if here:
            ev["dist_2d_m"] = round(d2(here, goal), 2)
            ev["dz_m"] = round(here[2] - goal[2], 2)
        if off is not None:
            hits = [x for x in self.body.log_since(off) if re.search(expect_log, x)]
            ev["expect_log"] = {"pattern": expect_log, "seen": bool(hits), "lines": hits[:5]}
        arrived = bool(r.get("ok")) and here is not None and ev["dist_2d_m"] <= tol and abs(ev["dz_m"]) <= 1.5
        return arrived, ev

    # ---- scenario kinds
    def k_go_to_chain(self, sc: dict) -> Outcome:
        legs = []
        if sc.get("start"):
            if not self.live:
                st = self.state() or {}
                here = st.get("position")
                plan = [{"to": sc["start"], "dist_m": round(d2(here, self.place(sc["start"])), 1) if here else None}]
                prev = self.place(sc["start"])
                for leg in sc["legs"]:
                    nxt = self.place(leg["to"])
                    plan.append({"to": leg["to"], "dist_m": round(d2(prev, nxt), 1), "timeout": leg.get("timeout")})
                    prev = nxt
                return Outcome(sc["id"], "dry", f"{len(sc['legs'])} legs after the start leg", {"plan": plan})
            ok, ev = self.go(sc["start"], 3.0, 105, "start:" + str(sc["start"]))
            if not ok:
                return Outcome(sc["id"], "error", f"could not reach the start {sc['start']} ({ev.get('reason')})", {"setup": ev})
        elif not self.live:
            return Outcome(sc["id"], "dry", f"{len(sc['legs'])} legs", {"legs": sc["legs"]})
        t0 = now()
        for i, leg in enumerate(sc["legs"]):
            ok, ev = self.go(leg["to"], float(leg.get("tol", 3.0)), float(leg.get("timeout", 105)), f"{i + 1}:{leg['to']}",
                             leg.get("expect_log"))
            legs.append(ev)
            if not ok:
                return Outcome(sc["id"], "fail", f"leg {i + 1} to {leg['to']}: {ev.get('reason') or 'not at goal'} "
                                                 f"(2D {ev.get('dist_2d_m')} m, dz {ev.get('dz_m')} m)", {"legs": legs})
        note = ""
        exp = [lg["expect_log"]["seen"] for lg in legs if "expect_log" in lg]
        if exp:
            note = f"; expected log seen on {sum(exp)}/{len(exp)} legs"
        return Outcome(sc["id"], "pass", f"{len(legs)} legs arrived in {round(now() - t0)} s{note}", {"legs": legs})

    def k_ledge_jump(self, sc: dict) -> Outcome:
        led = sc.get("ledge")
        probe = None
        if not led:
            probe = self.body.cmd("scn_find_ledge.lua", {"radius_m": sc.get("radius_m", 6), "rise_min_m": sc.get("rise_min_m", 0.6),
                                                         "rise_max_m": sc.get("rise_max_m", 1.4)}, timeout=30)
            res = (probe or {}).get("result") or {}
            if not probe or not probe.get("ok") or not res.get("ok"):
                return Outcome(sc["id"], "error", f"ledge probe failed: {(probe or {}).get('error') or res.get('error') or 'no answer'}")
            cands = res.get("candidates") or []
            if not cands:
                return Outcome(sc["id"], "skip", f"no 0.6-1.4 m ledge within {sc.get('radius_m', 6)} m ({res.get('traces')} traces)",
                               {"feet": res.get("feet")})
            led = cands[0]
        if not self.live:
            return Outcome(sc["id"], "dry", f"ledge rise {led.get('rise_m')} m at {led.get('dist_m')} m", {"ledge": led})
        ok, ev0 = self.go(led["base"], 1.0, 30, "base")
        if not ok:
            return Outcome(sc["id"], "error", f"could not reach the ledge base ({ev0.get('reason')})", {"ledge": led, "base": ev0})
        ok, ev1 = self.go(led["top"], 1.5, 30, "top")
        here = ev1.get("position") or [0, 0, -1e9]
        rose = here[2] - led["base"][2]
        need = 0.6 * float(led.get("rise_m") or 1.0)
        ev = {"ledge": led, "base": ev0, "top": ev1, "rose_m": round(rose, 2)}
        if ev1.get("ok") and rose >= need and ev1.get("dist_2d_m", 99) <= 1.5:
            return Outcome(sc["id"], "pass", f"on the ledge: rose {rose:.2f} m (rise {led.get('rise_m')} m)", ev)
        return Outcome(sc["id"], "fail", f"not on the ledge: rose {rose:.2f} m of {led.get('rise_m')} m, "
                                         f"2D {ev1.get('dist_2d_m')} m, reason {ev1.get('reason')}", ev)

    def _stats(self, st: dict) -> dict:
        return {"hydration": st.get("hydration"), "sustenance": st.get("sustenance"), "health": st.get("health"),
                "hydration_max": st.get("hydration_max"), "sustenance_max": st.get("sustenance_max"), "max_health": st.get("max_health")}

    def k_fetch_consume(self, sc: dict) -> Outcome:
        things = self.look(sc.get("about"), radius=float(sc.get("radius", 40)), max_n=40)
        words = [w for w in (sc.get("about") or "").lower().split() if len(w) > 2]

        def edible(t):
            hay = f"{t.get('name', '')} {t.get('item', '')}".lower()
            return any(w in hay for w in words)
        items = [t for t in things if t.get("category") == "items" and "interact" in (t.get("actions") or [])]
        crops = [t for t in things if t.get("kind") == "foliage" and t.get("foliage") == "pickup" and edible(t)]
        picks = [t for t in items if edible(t)] + crops
        if not picks:
            seen = sorted({t.get("name") for t in things if t.get("name")})[:12]
            return Outcome(sc["id"], "skip", "nothing edible lying around on this server", {"seen": seen})
        pick = picks[0]
        ev: dict[str, Any] = {"target": {k: pick.get(k) for k in ("id", "name", "item", "kind", "distance", "position")},
                              "candidates": len(picks)}
        if not self.live:
            return Outcome(sc["id"], "dry", f"would fetch {pick.get('name')} at {pick.get('distance')} m", ev)
        before = self.state() or {}
        tool = "fetch" if "fetch" in self.caps else "interact"
        r = self.body.request(tool, {"target": pick["id"]}, timeout=115)
        ev["fetch"] = {"tool": tool, "ok": r.get("ok"), "reason": r.get("reason"), "data": r.get("data")}
        if not r.get("ok"):
            return Outcome(sc["id"], "fail", f"{tool} {pick.get('name')}: {r.get('reason')} {(r.get('data') or {}).get('detail') or ''}", ev)
        gained = (r.get("data") or {}).get("item") or pick.get("item")
        after = self.state() or {}
        inv_b, inv_a = before.get("inventory") or {}, after.get("inventory") or {}
        ev["inventory_delta"] = {k: inv_a.get(k, 0) - inv_b.get(k, 0) for k in set(inv_a) | set(inv_b) if inv_a.get(k, 0) != inv_b.get(k, 0)}
        row = next((x for x in after.get("inventory_items") or [] if x.get("item") == gained), None)
        if not row or not row.get("consumable"):
            return Outcome(sc["id"], "pass", f"fetched {gained}; consume skipped: {gained} is not consumable", ev)
        if row.get("where") != "hotbar":
            return Outcome(sc["id"], "pass", f"fetched {gained}; consume skipped: it is in the bag (hotbar-only rule)", ev)
        stat = {"food": "sustenance", "drink": "hydration"}.get(row["consumable"], "health")
        cur, mx = after.get(stat), after.get(f"{stat}_max") or after.get("max_health")
        if cur is not None and mx and cur >= mx - 1:
            return Outcome(sc["id"], "pass", f"fetched {gained}; consume skipped: {stat} is full ({cur}/{mx})", ev)
        if "consume" in self.caps:
            c = self.body.request("consume", {"item": gained}, timeout=30)
            ev["consume"] = {"tool": "consume", "ok": c.get("ok"), "reason": c.get("reason"), "data": c.get("data")}
        else:
            c = self.body.cmd("scn_consume.lua", {"item": gained}, timeout=20)
            ev["consume"] = {"tool": "scn_consume.lua", "answer": c}
            c = {"ok": bool(c and c.get("ok") and (c.get("result") or {}).get("ok"))}
        if not c.get("ok"):
            return Outcome(sc["id"], "fail", f"fetched {gained}; consume did not run", ev)
        rose = None
        for _ in range(6):
            time.sleep(1)
            st2 = self.state() or {}
            if st2.get(stat) is not None and cur is not None and st2[stat] >= cur + 1:
                rose = st2[stat] - cur
                break
        ev["stat"] = {"stat": stat, "before": cur, "rose_by": rose}
        if rose is None:
            return Outcome(sc["id"], "fail", f"fetched {gained}; {stat} did not rise after consuming", ev)
        return Outcome(sc["id"], "pass", f"fetched and consumed {gained}: {stat} +{rose:.1f}", ev)

    def k_combat(self, sc: dict) -> Outcome:
        st = self.state() or {}
        hp, mhp = st.get("health") or 0, st.get("max_health") or 100
        ents = [e for e in st.get("nearby_entities") or [] if e.get("alive", True)]
        radius = float(sc.get("radius", 40))
        aggro = [e for e in ents if e.get("archetype") == "Aggressive"]

        def ok_target(e):
            if e.get("boss") or e.get("archetype") not in sc.get("archetypes", []):
                return False
            if (e.get("health") or e.get("hp") or 1e9) > float(sc.get("max_hp", 120)) or (e.get("distance") or 1e9) > radius:
                return False
            p = e.get("position")
            return not any(p and a.get("position") and d2(p, a["position"]) < float(sc.get("avoid_aggressive_m", 25)) for a in aggro)
        cands = sorted([e for e in ents if ok_target(e)], key=lambda e: e.get("distance") or 1e9)
        if not cands:
            return Outcome(sc["id"], "skip", f"no weak creature within {radius:.0f} m away from aggressive packs",
                           {"seen": [(e.get("name"), e.get("archetype"), e.get("health")) for e in ents][:10]})
        tgt = cands[0]
        ev: dict[str, Any] = {"target": {k: tgt.get(k) for k in ("id", "name", "archetype", "health", "distance")}}
        if not self.live:
            return Outcome(sc["id"], "dry", f"would attack {tgt.get('name')} ({tgt.get('health')} HP) at {tgt.get('distance')} m", ev)
        if hp < float(sc.get("min_own_hp_frac", 0.8)) * mhp:
            return Outcome(sc["id"], "skip", f"own HP {hp}/{mhp} too low to start a fight", ev)
        r = self.body.request("attack", {"target": tgt["id"]}, timeout=float(sc.get("timeout", 110)) + 10)
        ev["attack"] = {"ok": r.get("ok"), "reason": r.get("reason"), "data": r.get("data")}
        st2 = self.state() or {}
        still = next((e for e in st2.get("nearby_entities") or [] if e.get("id") == tgt["id"]), None)
        ev["after"] = {"target_alive": bool(still and still.get("alive", True)), "own_hp": st2.get("health"), "dead": st2.get("dead")}
        if st2.get("dead"):
            return Outcome(sc["id"], "fail", f"Claude died fighting {tgt.get('name')}", ev)
        if r.get("ok") and not ev["after"]["target_alive"]:
            return Outcome(sc["id"], "pass", f"killed {tgt.get('name')}; own HP {st2.get('health')}", ev)
        return Outcome(sc["id"], "fail", f"attack {tgt.get('name')}: {r.get('reason')}; target alive={ev['after']['target_alive']}", ev)

    def k_grave_recovery(self, sc: dict) -> Outcome:
        graves = [t for t in self.look("grave gravestone", radius=float(sc.get("radius", 80)), max_n=20)
                  if "grave" in f"{t.get('name', '')} {t.get('class', '')}".lower()]
        if not graves:
            return Outcome(sc["id"], "skip", "no gravestone perceived (no natural death; deaths are never forced)")
        g = graves[0]
        ev: dict[str, Any] = {"grave": {k: g.get(k) for k in ("id", "name", "class", "distance", "position")}}
        if not self.live:
            return Outcome(sc["id"], "dry", f"would recover the grave at {g.get('distance')} m", ev)
        before = (self.state() or {}).get("inventory") or {}
        r = self.body.request("interact", {"target": g["id"]}, timeout=115)
        after = (self.state() or {}).get("inventory") or {}
        ev["interact"] = {"ok": r.get("ok"), "reason": r.get("reason"), "data": r.get("data")}
        ev["gained"] = {k: after.get(k, 0) - before.get(k, 0) for k in after if after.get(k, 0) > before.get(k, 0)}
        gone = not any(t.get("id") == g["id"] for t in self.look("grave gravestone", radius=float(sc.get("radius", 80)), max_n=20))
        if r.get("ok") and gone and ev["gained"]:
            return Outcome(sc["id"], "pass", f"grave taken: {sum(ev['gained'].values())} items back", ev)
        return Outcome(sc["id"], "fail", f"grave: interact {r.get('reason') or 'ok'}, gone={gone}, gained={len(ev['gained'])}", ev)

    def k_collect_cluster(self, sc: dict) -> Outcome:
        """Several stacks within radius_m -> collect all, against a time budget (the 7-rune-stacks case)."""
        st = self.state() or {}
        here = st.get("position")
        if not here:
            return Outcome(sc["id"], "error", "no position")
        want, radius, min_n = int(sc.get("stacks", 7)), float(sc.get("radius_m", 3.0)), int(sc.get("min_stacks", 2))
        budget = float(sc.get("max_s", 35))

        def ground():
            return [t for t in self.look(None, radius=max(radius + 2, 5), max_n=40)
                    if t.get("category") == "items" and "interact" in (t.get("actions") or [])
                    and t.get("position") and d2(t["position"], here) <= radius + 0.5]
        stacks = ground()
        ev: dict[str, Any] = {"on_ground": [(t.get("name"), t.get("count")) for t in stacks]}
        dropped: list[dict] = []
        if len(stacks) < want and sc.get("setup") == "drop_own":
            prefer = str(sc.get("prefer", "Rune")).lower()
            rows = [x for x in st.get("inventory_items") or [] if x.get("kind") in (None, "Item") and not x.get("consumable")
                    and x.get("durability") is None and re.search(r"Rune|Resources|Ammo", str(x.get("item", "")))]
            rows.sort(key=lambda x: (prefer not in f"{x.get('item', '')} {x.get('name', '')}".lower(), str(x.get("item"))))
            plan = rows[:want - len(stacks)]
            ev["drop_plan"] = [x.get("item") for x in plan]
            if len(stacks) + len(plan) < min_n:
                return Outcome(sc["id"], "skip", f"{len(stacks)} stacks on the ground and only {len(plan)} droppable stacks carried", ev)
            if not self.live:
                return Outcome(sc["id"], "dry", f"{len(stacks)} on the ground; would drop {len(plan)} own stacks, then collect "
                                                f"{len(stacks) + len(plan)}", ev)
            for x in plan:
                r = self.body.request("drop", {"item": x["item"], "count": 1}, timeout=15)
                dropped.append({"item": x["item"], "ok": r.get("ok"), "reason": r.get("reason")})
            time.sleep(1.5)  # let the drops land
            stacks = ground()
            ev["dropped"] = dropped
        elif not self.live:
            if len(stacks) < min_n:
                return Outcome(sc["id"], "skip", f"only {len(stacks)} stacks within {radius} m", ev)
            return Outcome(sc["id"], "dry", f"would collect {len(stacks)} stacks within {radius} m", ev)
        if len(stacks) < min_n:
            return Outcome(sc["id"], "fail" if dropped else "skip", f"only {len(stacks)} stacks on the ground", ev)
        inv_before = (self.state() or {}).get("inventory") or {}
        t0 = now()
        per: list[dict] = []
        if "collect_all" in self.caps:
            r = self.body.request("collect_all", {"radius": radius + 0.5}, timeout=budget + 30)
            per.append({"tool": "collect_all", "ok": r.get("ok"), "reason": r.get("reason"), "secs": round(now() - t0, 1)})
        else:
            tool = next((t for t in ("pickup", "fetch") if t in self.caps), "interact")
            for t in sorted(stacks, key=lambda t: d2(t["position"], here)):
                t1 = now()
                r = self.body.request(tool, {"target": t["id"]}, timeout=60)
                per.append({"tool": tool, "name": t.get("name"), "ok": r.get("ok"), "reason": r.get("reason"),
                            "secs": round(now() - t1, 1)})
        total = round(now() - t0, 1)
        left = ground()
        inv_after = (self.state() or {}).get("inventory") or {}
        gained = {k: inv_after.get(k, 0) - inv_before.get(k, 0) for k in inv_after if inv_after.get(k, 0) > inv_before.get(k, 0)}
        ev.update(per_stack=per, total_s=total, left_on_ground=[t.get("name") for t in left], gained=gained)
        missing = ([x["item"] for x in dropped if x.get("ok") and gained.get(x["item"], 0) < 1] if dropped
                   else [t.get("name") for t in left])
        ev["not_recovered"] = missing
        n_ok = sum(1 for x in per if x.get("ok"))
        if not missing and not left and total <= budget:
            return Outcome(sc["id"], "pass", f"collected {len(stacks)} stacks in {total} s ({n_ok}/{len(per)} calls ok)", ev)
        return Outcome(sc["id"], "fail", f"{len(left)} stacks left, not recovered {missing}, {total} s (budget {budget:g} s)", ev)

    KINDS = {"go_to_chain": k_go_to_chain, "ledge_jump": k_ledge_jump, "fetch_consume": k_fetch_consume,
             "combat": k_combat, "grave_recovery": k_grave_recovery, "collect_cluster": k_collect_cluster}

    def run_one(self, sc: dict, renew, healthy) -> Outcome:
        if renew:
            renew()
        why = healthy() if healthy else None
        if why:
            return Outcome(sc["id"], "error", f"not run: {why}")
        t0 = now()
        try:
            if self.live:
                self.body.request("stop", {}, timeout=10)
            o = self.KINDS[sc["kind"]](self, sc)
        except Exception as exc:  # one broken scenario must not stop the suite (or the switch back)
            o = Outcome(sc["id"], "error", f"{type(exc).__name__}: {exc}")
        o.started, o.duration_s = t0, round(now() - t0, 1)
        return o

    def run_scenarios(self, only: set[str] | None, renew: Callable[[], None] | None = None,
                      healthy: Callable[[], str | None] | None = None, repeat: int | None = None) -> list[Outcome]:
        """repeat: run each scenario N times in a row (default its own 'repeat', else 1); it passes only when every
        run passes. A dry run never repeats (nothing changes between read-only runs)."""
        out = []
        for sc in self.suite["scenarios"]:
            if only and sc["id"] not in only:
                continue
            n = max(1, int(repeat if repeat is not None else sc.get("repeat", 1))) if self.live else 1
            runs = []
            for i in range(n):
                o = self.run_one(sc, renew, healthy)
                if n > 1:
                    self.step(f"{sc['id']}#{i + 1}", o.result, o.detail, **o.evidence)
                runs.append(o)
                if o.result in ("skip", "error") and o.detail.startswith(("not run", "could not reach")):
                    break  # the setup itself is broken: more runs prove nothing
            if n == 1:
                o = runs[0]
            else:
                res = [r.result for r in runs]
                agg = ("pass" if all(r == "pass" for r in res) and len(res) == n else
                       "skip" if all(r == "skip" for r in res) else
                       "error" if "error" in res and "fail" not in res else "fail")
                o = Outcome(sc["id"], agg, f"{res.count('pass')}/{n} runs passed in a row: {', '.join(res)}",
                            {"runs": [{"result": r.result, "detail": r.detail, "secs": r.duration_s, **r.evidence} for r in runs]},
                            runs[0].started, round(sum(r.duration_s for r in runs), 1))
            self.step(o.scenario, o.result, o.detail, **({} if n > 1 else o.evidence))
            out.append(o)
        return out


# ------------------------------------------------------------------ the whole run
def snapshot(st: dict | None) -> dict:
    st = st or {}
    return {"position": st.get("position"), "inventory": st.get("inventory"), "gear": st.get("gear"),
            "skills": {s.get("skill"): s.get("level") for s in st.get("skills") or []}, "total_level": st.get("total_level"),
            "health": st.get("health"), "hydration": st.get("hydration"), "sustenance": st.get("sustenance")}


def diff_snapshots(a: dict, b: dict) -> dict:
    out = {}
    for k in ("inventory", "skills", "gear"):
        x, y = a.get(k) or {}, b.get(k) or {}
        d = {i: [x.get(i), y.get(i)] for i in set(x) | set(y) if x.get(i) != y.get(i)}
        if d:
            out[k] = d
    return out


def run(args, body=None, ops=None, suite: dict | None = None, log: Callable[[str], None] = print) -> dict:
    suite = suite or json.loads(Path(args.suite).read_text(encoding="utf-8"))
    ops = ops or Ops()
    body = body or Body()
    target = suite.get("target", "dev")
    live = bool(args.live or args.here)
    only = {s.strip() for s in args.only.split(",")} if args.only else None
    t_start = now()
    rep: dict[str, Any] = {"started": iso(t_start), "mode": "live" if args.live else ("here" if args.here else "dry_run"),
                           "target": target, "preflight": {}, "switch": {}, "scenarios": [], "steps": []}
    runner = Runner(body, ops, suite, live, log)
    pf = rep["preflight"]
    shock_addr, dev_addr = target_address(DEFAULT_TARGET), target_address(target)
    pf["joined"] = ops.joined()
    pf["on"] = ("shockbyte" if pf["joined"] and pf["joined"] == shock_addr else
                target if pf["joined"] and pf["joined"] == dev_addr else pf["joined"])
    pf["hold"] = ops.held()
    pf["brain_running"] = ops.brain_running()
    pf["dev_server_running"] = ops.dev_server_running()
    pf["dev_target_file"] = dev_addr is not None
    fe = ops.frontend() if hasattr(ops, "frontend") else None
    pf["frontend"] = fe
    if fe and fe.get("needs_relaunch"):
        pf["warn_frontend"] = (f"client pid {fe.get('pid')} has used {fe.get('returns')} of {fe.get('max')} front-end returns: "
                               "the switch relaunches it instead of disconnecting (BUGS L24)")
    age = ops.nav_oracle_age_s()
    pf["nav_oracle_age_s"] = round(age, 1) if age is not None else None
    caps = body.request("capabilities", {}, timeout=10)
    runner.caps = set((caps.get("data") or {}).get("tools") or [])
    pf["tools"] = sorted(runner.caps)
    st0 = runner.state()
    pf["in_world"] = st0 is not None
    problems = []
    if not pf["in_world"]:
        problems.append("client not answering get_state (not in world?)")
    if pf["hold"] and live:
        problems.append(f"client on hold ({pf['hold']})")
    if pf["brain_running"] and live and not args.allow_brain:
        problems.append("the live brain (run_live) is running: stop it first (it shares the action slot) or pass --allow-brain")
    if args.live:
        if pf["on"] != "shockbyte":
            problems.append(f"expected to start on Shockbyte, joined={pf['joined']}")
        if not pf["dev_server_running"]:
            problems.append("dev server not running (tools/start_server.ps1 with DW_NO_BODY=1)")
        if not pf["dev_target_file"]:
            problems.append(f"no target file {target_file(target)}")
    if args.here and pf["on"] == "shockbyte" and not args.allow_shockbyte:
        problems.append("--here on Shockbyte (Luis's world) needs --allow-shockbyte")
    if pf["nav_oracle_age_s"] is None or pf["nav_oracle_age_s"] > 10:
        pf["warn_nav_oracle"] = "nav oracle heartbeat stale: long go_to legs will rely on local planning only"
    rep["baseline"] = snapshot(st0)
    for k, v in pf.items():
        log(f"preflight {k}: {v if k != 'tools' else ','.join(v)}")
    if problems:
        rep["result"] = "aborted"
        rep["problems"] = problems
        for p in problems:
            log("ABORT: " + p)
        return finish(rep, runner, t_start, args)

    mem_mode = getattr(args, "memory", None) or "dev"
    mem_world = {"dev": "dev_scenarios", "nomem": f"scn_nomem_{datetime.now():%Y%m%d_%H%M%S}", "shared": None}[mem_mode]
    rep["memory"] = {"mode": mem_mode, "world": mem_world}
    mem_prev: dict[str, Any] = {}

    def set_memory() -> None:
        if not (args.live or args.here) or mem_world is None:
            return
        r = body.cmd("scn_world.lua", {"set": mem_world}, timeout=20)
        res = (r or {}).get("result") or {}
        if "previous" not in mem_prev:
            mem_prev["previous"] = res.get("previous")
        rep["memory"]["applied"] = bool(r and r.get("ok"))

    def restore_memory() -> None:
        if not (args.live or args.here) or mem_world is None or "previous" not in mem_prev:
            return
        a = {"restore": True}
        if mem_prev["previous"] and mem_prev["previous"] != mem_world:
            a["previous"] = mem_prev["previous"]
        r = body.cmd("scn_world.lua", a, timeout=20)
        rep["memory"]["restored"] = bool(r and r.get("ok"))

    def healthy() -> str | None:
        if args.live or args.here:
            j = ops.joined()
            if args.live and j != dev_addr:
                return f"not on the dev server (joined {j})"
        return None if runner.state() is not None else "client not answering"

    try:
        if args.live:
            rep["switch"]["backup"] = ops.backup_character()
            write_lease(target, float(suite.get("lease_min", 45)), f"scenario_run pid {os.getpid()}")
            log(f"switching to {target} ...")
            b = ops.boot(target)
            rep["switch"]["to_dev"] = b
            b["relaunched"] = relaunched(b)
            log(f"  boot: ok={b.get('ok')} joined={b.get('joined')} reason={b.get('reason')}"
                + (" (relaunched: front-end limit, BUGS L24)" if b["relaunched"] else ""))
            if not b.get("ok") or b.get("joined") != dev_addr:
                rep["result"] = "aborted"
                rep["problems"] = [f"switch to {target} failed: {b.get('reason')} (joined {b.get('joined')})"]
            else:
                time.sleep(5)
                rep["dev_start"] = snapshot(runner.state())
        if rep.get("result") != "aborted":
            def renew() -> None:   # the lease (live) and the memory world (live / here; a client restart loses it)
                if args.live:
                    write_lease(target, float(suite.get("lease_min", 45)), f"scenario_run pid {os.getpid()}")
                set_memory()
            outs = runner.run_scenarios(only, renew=renew if live else None, healthy=healthy if live else None,
                                        repeat=getattr(args, "repeat", None))
            rep["scenarios"] = [o.__dict__ for o in outs]
    finally:
        try:
            restore_memory()
        except Exception as exc:  # never block the switch back
            rep["memory"]["restore_error"] = repr(exc)
        if args.live:
            clear_lease()
            log("switching back to Shockbyte ...")
            b = ops.boot(DEFAULT_TARGET)
            b["relaunched"] = relaunched(b)
            rep["switch"]["back"] = b
            log(f"  boot: ok={b.get('ok')} joined={b.get('joined')} reason={b.get('reason')}"
                + (" (relaunched: front-end limit, BUGS L24)" if b["relaunched"] else ""))
            if b.get("joined") != shock_addr:
                rep.setdefault("problems", []).append(
                    f"NOT back on Shockbyte (joined {b.get('joined')}): the watchdog will retry (no lease = shockbyte)")
            time.sleep(3)
            rep["after"] = snapshot(runner.state())
            rep["baseline_diff"] = diff_snapshots(rep["baseline"], rep["after"])
    counts: dict[str, int] = {}
    for o in rep["scenarios"]:
        counts[o["result"]] = counts.get(o["result"], 0) + 1
    rep["counts"] = counts
    rep.setdefault("result", "fail" if counts.get("fail") or counts.get("error") or rep.get("problems") else
                   ("dry_run" if not live else "pass"))
    return finish(rep, runner, t_start, args)


def finish(rep: dict, runner: Runner, t_start: float, args) -> dict:
    rep["steps"] = runner.steps
    rep["ended"] = iso()
    rep["duration_s"] = round(now() - t_start, 1)
    if getattr(args, "no_report", False):
        return rep
    out_dir = Path(getattr(args, "report_dir", None) or REPORT_DIR)
    out_dir.mkdir(parents=True, exist_ok=True)
    stem = f"scn_{datetime.now():%Y%m%d-%H%M%S}_{rep['mode']}"
    tl = ""
    try:
        from tools import timeline
        rows = timeline.build(ROOT, t_start - 5, now() + 1, set(timeline.SOURCES) - {"scenario"})
        tl = timeline.render_text(rows, timezone.utc, 240)
        (out_dir / f"{stem}_timeline.txt").write_text(tl, encoding="utf-8")
        rep["timeline"] = str(out_dir / f"{stem}_timeline.txt")
    except Exception as exc:  # the report matters more than its timeline
        rep["timeline_error"] = repr(exc)
    (out_dir / f"{stem}.json").write_text(json.dumps(rep, indent=2, default=str), encoding="utf-8")
    (out_dir / f"{stem}.md").write_text(markdown(rep), encoding="utf-8")
    rep["report"] = str(out_dir / f"{stem}.json")
    return rep


def markdown(rep: dict) -> str:
    L = [f"# Scenario run {rep['started']} ({rep['mode']})", "",
         f"Result: **{rep.get('result')}**, {rep.get('counts', {})}, {rep.get('duration_s')} s. Target `{rep['target']}`.", ""]
    for p in rep.get("problems") or []:
        L.append(f"- PROBLEM: {p}")
    pf = rep.get("preflight", {})
    L += ["", "## Preflight", "", "| check | value |", "|---|---|"]
    for k in ("on", "joined", "in_world", "hold", "brain_running", "dev_server_running", "dev_target_file", "nav_oracle_age_s"):
        L.append(f"| {k} | {pf.get(k)} |")
    if rep.get("memory"):
        L += ["", f"Nav memory: {json.dumps(rep['memory'])}"]
    L += ["", "## Scenarios", "", "| scenario | result | time (s) | detail |", "|---|---|---|---|"]
    for o in rep.get("scenarios") or []:
        L.append(f"| {o['scenario']} | {o['result']} | {o.get('duration_s')} | {str(o['detail']).replace('|', '/')} |")
    sw = rep.get("switch") or {}
    if sw:
        L += ["", "## Switch", ""]
        for k, v in sw.items():
            L.append(f"- {k}: {json.dumps(v, default=str)}")
    if rep.get("baseline_diff") is not None:
        L += ["", "## Shockbyte state before vs after", "", "```", json.dumps(rep["baseline_diff"], indent=1) or "{}", "```"]
    if rep.get("timeline"):
        L += ["", f"Timeline of the run: `{rep['timeline']}`  (or `python -m tools.timeline --since {rep['started'][11:19]} --until {rep.get('ended', '')[11:19]}`)"]
    L += ["", "Evidence per scenario: the `scenarios[].evidence` objects in the JSON report."]
    return "\n".join(L) + "\n"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--live", action="store_true", help="switch to the dev server, run, switch back (needs main's OK)")
    g.add_argument("--here", action="store_true", help="run live on the CURRENT server without switching (dev only)")
    ap.add_argument("--only", help="comma list of scenario ids")
    ap.add_argument("--repeat", type=int, help="run each scenario N times in a row (overrides the suite's repeat; 1 = quick)")
    ap.add_argument("--suite", default=str(SUITE))
    ap.add_argument("--memory", choices=("dev", "nomem", "shared"), default="dev",
                    help="nav memory store for the run: dev (isolated, default), nomem (fresh, seeds only), shared (Shockbyte's)")
    ap.add_argument("--allow-brain", action="store_true", help="run even though run_live is up (shares the action slot)")
    ap.add_argument("--allow-shockbyte", action="store_true", help=argparse.SUPPRESS)
    ap.add_argument("--report-dir", default=str(REPORT_DIR))
    a = ap.parse_args(argv)
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    rep = run(a)
    print(f"RESULT: {rep.get('result')} {rep.get('counts', {})}  report: {rep.get('report')}")
    return 0 if rep.get("result") in ("pass", "dry_run") else 1


if __name__ == "__main__":
    raise SystemExit(main())
