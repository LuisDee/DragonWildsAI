"""Vault probe steps P2-P5 at Crasorak Kara on the DEV world: body only (no brain, no model calls, API spend 0).

  .venv\\Scripts\\python.exe -m tools.vault_probe door --confirm     # P2: stand outside the door, read its row
  .venv\\Scripts\\python.exe -m tools.vault_probe enter --confirm    # P3-P5 on a FORK: one press on the door, read inside, leave
  .venv\\Scripts\\python.exe -m tools.vault_probe home --confirm     # back to a named home spot
  .venv\\Scripts\\python.exe -m tools.vault_probe door               # no --confirm: says what it would do, touches nothing

Plan and facts: docs/research/2026-11-17-vault-reads.md (section 4, P1-P5) and docs/research/2026-11-17-crasorak-route.md
(the door, the spot, the dangers, windows A and B). A harness tool for the main session, never the companion's.

door   Teleport (dev `teleport` fixture, server K2_TeleportTo) to DOOR_SPOT, wait until he stands still, then get_state
       and `look` 20 m. Records the door row (id, name, prompt, distance, destination, arrives_at, leads_to, locked) and
       get_state's in_vault / vault. Needs nothing beyond the sense.lua vault reads (6d78811) in the running client.
enter  If he is not near the door, the `door` placement first. Then ONE body `interact` on the door row's id (never a
       second press), wait for the position jump (> JUMP_M) and the settle, then get_state, `look` 80 m and the raw
       census 80 m. Records levers (switch_position, switch_highest, drives), chests (chest_state), hazards (traps),
       teleporters, creatures (power level, hp, boss), in_vault / vault, the jump, and the client.log lines of the
       teleport (bridge: teleport_begin / teleport_end, client_paused / client_unpaused, vault_*, prop_guard). The full
       replies go to logs/evals/vault_probe/<run>_enter.json. Then it leaves: --leave door (default) presses the inside
       teleporter once (the row whose leads_to is "outside", else the nearest teleporter row) and waits for the jump
       back; with no such row or no jump it teleports home. --leave home teleports home.
       ** Needs DW_TELEPORT_HOOKS=1 in the client's environment ** (or `_G.__dwc_bridge.hook_teleport({ force = true })`
       run from a client command beforehand), so the bridge pauses its loops across the in-map teleport
       (client_bridge.lua M.TELEPORT_HOOKS; the Unstuck crash was a Lua read across such a teleport). Without them the
       loops run on through the stream-out (R16/R17). The probe cannot see the client's environment: the row records
       whether a "bridge: teleport_begin" line appeared, and none means the hooks were off.
home   Teleport to the home spot (--spot, default standing_trees from evals/bench/dev_places.json) and settle.

The client loads client_bridge.lua and sense.lua at start only: after a change to either (or to set DW_TELEPORT_HOOKS),
restart the client (tools\\client_boot.ps1 -Target dev; announce it in text first when Luis may be on).

`enter` never runs on ClaudeDev himself: a vault visit changes the character it is made on (a death, a grave, loot,
a guardian's kill), and ClaudeDev is the jobs' start (CLAUDE.md section 4, character switches). Inside the lock it forks
--from (default ClaudeDev's own save, only read: tools.quest_clone.fork, a new name ClaudeV<ddHHMMSS> and a new guid),
switches the client to the fork (evals.bench.devchar, as tools/job_run.py and tools/travel_ladder.py --fork do), aims
the dev fixtures at the fork's guid, tops the fork up with tools.supply (food, water, heal: a dev-only harness fixture,
logged with its purpose), and gives the reflex FED_WAIT_S to make him fit. Whatever happens (an abort, an error,
Ctrl-C) the client goes back to ClaudeDev (quest_run._on_main, retried every STUCK_S with the lock kept) before the
lock is released, and the fork's save is parked (quest_clone.park). Rule 8 does not bind here: a probe is a harness
look, never a scored trial. `door` (read-only at the door) and `home` stay on ClaudeDev.

Guards, before anything moves him (refused = exit 2, a row with `refused`):
  * --confirm given;
  * DevTarget.guard: the client is on the local dev server, never a forbidden target (Shockbyte), no live brain;
  * the client's own pawn is the probe's character (`me` name: ClaudeDev for door and home, the fork for enter) and
    the dev server lists exactly one player, that character by GUID (the fixtures' guard refuses any other player
    too: never with Luis or anyone else on the dev world);
  * enter: the probe's character is not ClaudeDev;
  * the live lock (tools/live_lock.py held "vault-probe"), unless the caller already holds it (DW_LIVE_OWNER).
Abort rules (each read point: after a placement, after a teleport, after each look): a live hostile creature within
--hostile-m (default 20 m, rat packs stand 25-35 m from the door), his health under --min-health (share, default 0.6),
dead, or a fall (z more than FALL_M under the landing within FALL_S of a placement). An abort teleports him home at once
(from inside too). A trial that met a fight is void, not failed (CLAUDE.md section 2 rule 3).

The world: start a window from a named world (rule 9): `tools\\stop_server.ps1 -Hold`, `tools.world_snapshot restore
base --confirm`, `tools\\start_server.ps1`, `tools\\client_boot.ps1 -Target dev`. Rows: logs/evals/vault_probe.jsonl.
"""
from __future__ import annotations

import argparse
import contextlib
import json
import math
import os
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

from brain import childproc

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "logs" / "evals" / "vault_probe.jsonl"
REPLIES = ROOT / "logs" / "evals" / "vault_probe"
CLIENT_LOG = Path(os.environ.get("DW_CLIENT_MOD_LOG", ROOT / "logs" / "client" / "client.log"))
DEV_PLACES = ROOT / "evals" / "bench" / "dev_places.json"

MAIN_CHARACTER = "ClaudeDev"
LOCK_OWNER = "vault-probe"
# enter plays a throwaway fork (as travel_ladder's ClaudeT and job_run's ClaudeJ forks); NAME_RE allows 16 characters
FORK_PREFIX = "ClaudeV"
FORK_FOOD, FORK_WATER = 6, 6  # tools.supply top-up on the fork: a Hulk patrols the entry hallway (route note B.1)
FED_WAIT_S, FED_POLL_S = 120.0, 10.0  # after the top-up, the reflex has this long to eat and drink him fit
STUCK_S = 120.0  # not back on ClaudeDev: keep the lock and retry this often (quest_run.clone_window's rule)
STEPS_ON_FORK = ("enter",)  # steps that change the character they run on

# The outside door: read live by his body 23 times on 2026-11-01/02 (crasorak-route note section 1)
DOOR_ID = "BP_InteractablePlayerTeleporter_C_UAID_18C04D97CB3D30D401_1397338720"
DOOR_NAME = "Crasorak Kara"
DOOR_AT = (374.58, 1918.74, -2.76)  # actor_position, metres

# Spots: capsule-centre positions he stood on, half a metre above the recorded z (the route note's rule for P2)
SPOTS: dict[str, dict[str, Any]] = {
    # 5.4 m south-west of the door, on the ground he walked on 2026-11-02 (logs/brain-20261102.jsonl l. 39238: `me`
    # position (370.67, 1915.0, -1.19)); within look's 20 m and a short approach for interact; the rat packs seen there
    # stood 25-35 m off (south, west, north-east)
    "door": {"at": [370.7, 1915.0, -0.7], "why": "5.4 m SW of the door, where he walked on 2026-11-02"},
    # 20.5 m south-west, where he stood still and read the door (logs/brain-20261101.jsonl l. 8973; route note P2)
    "door_far": {"at": [363.3, 1901.6, -2.0], "why": "20.5 m SW of the door, where he stood on 2026-11-01"},
}
HOME_DEFAULT = "standing_trees"

HOSTILE_M = 20.0  # route note window A: a hostile within 20 m stops the probe
MIN_HEALTH = 0.6  # ... and HP under 60 %
FALL_M, FALL_S = 3.0, 5.0  # a fall: z drops more than 3 m within 5 s (teleport into cells not yet streamed)
NEAR_DOOR_M = 25.0  # enter places him at the door first when he is farther than this
JUMP_M = 50.0  # route note P3: no jump of more than 50 m within the wait = no teleport
ENTER_WAIT_S = 90.0  # a pause not lifted within 90 s stops the probe
SETTLE_S = 30.0
PLACE_ARRIVE_M = 3.0
LOG_KEYS = ("teleport_begin", "teleport_end", "client_paused", "client_unpaused", "vault_", "prop_guard",
            "teleport_hook", "hookhub")


class Refused(RuntimeError):
    """A guard said no: nothing was moved."""


class Aborted(RuntimeError):
    """An abort rule fired: he was sent home."""


def d2(a, b) -> float:
    return math.hypot(a[0] - b[0], a[1] - b[1])


def d3(a, b) -> float:
    return math.sqrt(sum((a[i] - b[i]) ** 2 for i in range(3)))


def xyz(p) -> list[float] | None:
    if isinstance(p, (list, tuple)) and len(p) == 3 and all(isinstance(v, (int, float)) for v in p):
        return [float(v) for v in p]
    return None


def head() -> str:
    try:
        return childproc.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    except OSError:
        return ""


def spots() -> dict[str, dict[str, Any]]:
    """SPOTS plus the named dev-world spots of evals/bench/dev_places.json (standing_trees: the route note's home)."""
    out = dict(SPOTS)
    try:
        for k, v in json.loads(DEV_PLACES.read_text(encoding="utf-8")).items():
            if isinstance(v, dict) and xyz(v.get("at")):
                out.setdefault(k, {"at": xyz(v["at"]), "why": v.get("why") or "evals/bench/dev_places.json"})
    except (OSError, ValueError):
        pass
    return out


# ------------------------------------------------------------------ pure readers (tested)
def data(r) -> dict:
    return (r.get("data") or {}) if isinstance(r, dict) and r.get("ok") else {}


def threats(rows, within_m: float) -> list[dict]:
    """Live hostile creatures within within_m: rows of get_state nearby_entities, look things or census creatures."""
    out = []
    for r in rows or []:
        if not isinstance(r, dict):
            continue
        if r.get("category") not in (None, "creatures") and r.get("kind") != "creature":
            continue
        hostile = r.get("hostile") is True or r.get("attitude") == "hostile"
        dead = r.get("dead") is True or r.get("alive") is False or (isinstance(r.get("health"), (int, float)) and r["health"] <= 0)
        dist = r.get("distance")
        if hostile and not dead and not r.get("follower") and not r.get("summon") and isinstance(dist, (int, float)) \
                and dist <= within_m:
            out.append({k: r.get(k) for k in ("id", "name", "distance", "power_level", "alertness", "health")})
    return sorted(out, key=lambda x: x["distance"])


def health_share(st: dict) -> float | None:
    hp, mx = st.get("health"), st.get("max_health")
    if isinstance(hp, (int, float)) and isinstance(mx, (int, float)) and mx > 0:
        return hp / mx
    return None


def abort_reason(st: dict, rows=(), hostile_m: float = HOSTILE_M, min_health: float = MIN_HEALTH) -> str | None:
    """The first abort rule that fires on a state read (get_state or me) plus any extra creature rows, else None."""
    if st.get("dead") is True:
        return "dead"
    h = health_share(st)
    if h is not None and h < min_health:
        return f"health {h:.0%} under {min_health:.0%}"
    th = threats(list(st.get("nearby_entities") or []) + list(rows or []), hostile_m)
    if th:
        t = th[0]
        return f"hostile {t.get('name') or t.get('id')} at {t['distance']:.1f} m (within {hostile_m:g} m)"
    return None


TELEPORTER_FIELDS = ("id", "name", "prompt", "distance", "position", "destination", "arrives_at", "leads_to", "locked")


def door_row(things) -> dict | None:
    """The outside door's row: its id, else a teleporter row named Crasorak Kara."""
    rows = [t for t in things or [] if isinstance(t, dict)]
    hit = next((t for t in rows if t.get("id") == DOOR_ID), None) or \
        next((t for t in rows if t.get("name") == DOOR_NAME and t.get("category", "interactables") == "interactables"), None)
    return {k: hit.get(k) for k in TELEPORTER_FIELDS} if hit else None


def exit_row(things, entered_by: str | None = None) -> dict | None:
    """The way out inside: a teleporter row whose leads_to is "outside", else the nearest teleporter row (not the door
    he came in by)."""
    tps = [t for t in things or [] if isinstance(t, dict) and t.get("destination") and t.get("id") != entered_by]
    tps.sort(key=lambda t: t.get("distance") or 1e9)
    hit = next((t for t in tps if t.get("leads_to") == "outside"), None) or (tps[0] if tps else None)
    return {k: hit.get(k) for k in TELEPORTER_FIELDS} if hit else None


def inside_summary(things, census: dict | None = None) -> dict:
    """P4's record: levers, chests, hazards, teleporters, creatures (look rows, plus the raw census categories)."""
    rows = [t for t in things or [] if isinstance(t, dict)]
    c = census or {}
    seen: set = set()
    allrows = []
    for t in rows + [dict(x, category=k) for k in ("interactables", "creatures", "hazards") for x in (c.get(k) or [])
                     if isinstance(x, dict)]:
        key = t.get("id") or json.dumps(t.get("position"))
        if key in seen:
            continue
        seen.add(key)
        allrows.append(t)

    def pick(t, keys):
        return {k: t.get(k) for k in keys if t.get(k) is not None}
    return {
        "levers": [pick(t, ("id", "name", "prompt", "distance", "position", "switch_position", "switch_highest", "drives"))
                   for t in allrows if t.get("switch_position") is not None],
        "chests": [pick(t, ("id", "name", "distance", "position", "chest_state"))
                   for t in allrows if t.get("kind") == "chest" or t.get("chest_state") is not None],
        "hazards": [pick(t, ("id", "name", "distance", "position", "parts", "active_parts"))
                    for t in allrows if t.get("category") == "hazards" or t.get("kind") == "trap"],
        "teleporters": [pick(t, TELEPORTER_FIELDS) for t in allrows if t.get("destination")],
        "creatures": [pick(t, ("id", "name", "distance", "power_level", "health", "max_health", "boss", "hostile",
                               "attitude", "alertness", "in_combat"))
                      for t in allrows if t.get("category") == "creatures" or t.get("kind") == "creature"],
    }


def log_lines(path: Path, offset: int, keys=LOG_KEYS, limit: int = 80) -> list[str]:
    """client.log lines appended since offset that name the teleport, the pause or a vault read."""
    try:
        with open(path, "rb") as f:
            f.seek(offset)
            text = f.read().decode("utf-8", errors="replace")
    except OSError:
        return []
    return [ln.strip()[:300] for ln in text.splitlines() if any(k in ln for k in keys)][-limit:]


def log_size(path: Path) -> int:
    try:
        return path.stat().st_size
    except OSError:
        return 0


# ------------------------------------------------------------------ the probe
@dataclass
class Probe:
    """Side effects injected so tests fake every one: cli = debug-channel bridge client (request), dev = DevTarget
    (guard, setup, server_debug, character_guid)."""
    cli: Any
    dev: Any
    out: Path = OUT
    replies: Path = REPLIES
    client_log: Path = CLIENT_LOG
    hostile_m: float = HOSTILE_M
    min_health: float = MIN_HEALTH
    sleep: Callable[[float], None] = time.sleep
    clock: Callable[[], float] = time.monotonic
    run: str = field(default_factory=lambda: time.strftime("%Y%m%d-%H%M%S"))
    print_fn: Callable[[str], None] = print
    rows: list[dict] = field(default_factory=list)
    character: str = MAIN_CHARACTER  # the pawn this probe drives: ClaudeDev, or the fork for enter

    # -------------------------------------------------------------- rows
    def record(self, step: str, ok: bool | None, **kw) -> dict:
        row = {"ts": round(time.time(), 1), "run": self.run, "step": step, "ok": ok, "head": head(),
               "character": self.character, **kw}
        self.rows.append(row)
        self.out.parent.mkdir(parents=True, exist_ok=True)
        with self.out.open("a", encoding="utf-8") as f:
            f.write(json.dumps(row, default=str) + "\n")
        mark = "REFUSED" if kw.get("refused") else ("ABORT" if kw.get("aborted") else ("OK" if ok else "FAIL"))
        bits = [f"{k}={kw[k]}" for k in ("refused", "aborted", "position", "in_vault", "vault", "jump_m", "detail")
                if kw.get(k) is not None]
        if kw.get("door"):
            dr = kw["door"]
            bits.append(f"door {dr.get('name')!r} prompt={dr.get('prompt')!r} dist={dr.get('distance')} "
                        f"leads_to={dr.get('leads_to')!r} destination={dr.get('destination')!r} locked={dr.get('locked')}")
        if kw.get("inside"):
            s = kw["inside"]
            bits.append("inside " + " ".join(f"{k}={len(v)}" for k, v in s.items()))
        self.print_fn(f"vault_probe {step} {mark} " + " ".join(bits)[:600])
        return row

    # -------------------------------------------------------------- reads
    def req(self, tool: str, args: dict | None = None, timeout: float = 30.0) -> dict:
        r = self.cli.request(tool, args or {}, timeout=timeout)
        return r if isinstance(r, dict) else {"ok": False, "reason": repr(r)}

    def me(self) -> dict:
        return data(self.req("me", {}, 10))

    def state(self) -> dict:
        return data(self.req("get_state", {}, 30))

    def position(self) -> list[float] | None:
        return xyz(self.me().get("position"))

    # -------------------------------------------------------------- guard
    def guard(self, step: str | None = None) -> dict:
        """Refused unless on the local dev server, no live brain, the client's pawn is the probe's character and the
        dev server lists that character (by GUID) and no one else; and never a step that changes him on ClaudeDev."""
        if step in STEPS_ON_FORK and self.character == MAIN_CHARACTER:
            raise Refused(f"{step} runs on a fork, never on {MAIN_CHARACTER} (a vault visit changes the character: "
                          "deaths, loot)")
        try:
            self.dev.guard()
        except Exception as exc:  # observer.Abort and anything else: refuse, move nothing
            raise Refused(f"dev guard: {exc}") from exc
        who = self.me().get("name")
        if who != self.character:
            raise Refused(f"the client is on {who!r}, not {self.character}")
        r = self.dev.server_debug({"part": "referee", "action": "probe"}) or {}
        players = ((r.get("data") or {}).get("result") or {}).get("players")
        if not isinstance(players, list):
            raise Refused(f"the dev server did not list its players: {str(r)[:200]}")
        guid = str(getattr(self.dev, "character_guid", "") or "")
        mine = [p for p in players if isinstance(p, dict) and p.get("name") == self.character
                and str(p.get("character_guid") or "") == guid]
        others = [p.get("name") for p in players if isinstance(p, dict) and p not in mine]
        if not mine:
            raise Refused(f"the dev server does not list {self.character} ({guid}) in the world: {players}")
        if others:
            raise Refused(f"another player is on the dev world: {others}")
        return {"character": self.character, "guid": guid}

    # -------------------------------------------------------------- moves
    def teleport(self, at: list[float], purpose: str) -> dict:
        """The dev teleport fixture, then wait until he stands still within PLACE_ARRIVE_M of at. Records a fall."""
        res = self.dev.setup("teleport", purpose=purpose, at=list(at))
        t0, last, landed, low = self.clock(), None, None, None
        while self.clock() - t0 < SETTLE_S:
            self.sleep(1.0)
            p = self.position()
            if not p:
                continue
            if landed is None and d2(p, at) < PLACE_ARRIVE_M:
                landed = p
            if landed is not None and self.clock() - t0 <= FALL_S + 1.0:
                low = p[2] if low is None else min(low, p[2])
            if landed is not None and last and d3(p, last) < 0.1 and self.clock() - t0 >= FALL_S:
                fell = low is not None and landed[2] - low > FALL_M
                return {"ok": not fell, "position": p, "fell": fell, "offset_m": res.get("offset_m"),
                        "drop_m": round(landed[2] - (low if low is not None else landed[2]), 2)}
            last = p
        p = self.position() or last
        fell = bool(landed and p and landed[2] - p[2] > FALL_M)
        return {"ok": False, "position": p, "fell": fell, "detail": f"did not settle within {SETTLE_S:g} s of {at}"}

    def go_home(self, home: str, why: str) -> dict:
        at = spots()[home]["at"]
        try:
            t = self.teleport(at, f"vault probe: home ({why})")
        except Exception as exc:  # recorded, and the caller still reports its own outcome
            t = {"ok": False, "detail": repr(exc)[:300]}
        st = self.state()
        self.record("home", bool(t.get("ok")), spot=home, why=why, position=t.get("position"),
                    in_vault=st.get("in_vault"), vault=st.get("vault"), detail=t.get("detail"))
        return t

    def check(self, st: dict, rows=(), where: str = "") -> None:
        why = abort_reason(st, rows, self.hostile_m, self.min_health)
        if why:
            raise Aborted(f"{where}: {why}" if where else why)

    def look(self, radius: float) -> dict:
        return data(self.req("look", {"radius": radius, "max": 40}, 30))

    # -------------------------------------------------------------- steps
    def door(self, spot: str = "door", home: str = HOME_DEFAULT) -> dict:
        at = spots()[spot]["at"]
        try:
            t = self.teleport(at, "vault probe P2: outside Crasorak Kara")
            if t.get("fell"):
                raise Aborted(f"fell {t.get('drop_m')} m after the teleport")
            if not t.get("ok"):
                raise Aborted(t.get("detail") or "placement failed")
            st = self.state()
            self.check(st, where="after the placement")
            lk = self.look(20)
            things = lk.get("things") or []
            self.check(st, things, where="after look 20 m")
            row = door_row(things)
            return self.record("door", row is not None, spot=spot, position=t.get("position"), door=row,
                               in_vault=st.get("in_vault"), vault=st.get("vault"), look_in_vault=lk.get("in_vault"),
                               look_vault=lk.get("vault"), health=st.get("health"),
                               detail=None if row else "no door row within 20 m")
        except Aborted as exc:
            self.record("door", False, spot=spot, aborted=str(exc))
            self.go_home(home, f"door abort: {exc}")
            raise

    def wait_jump(self, before: list[float], wait_s: float = ENTER_WAIT_S) -> dict:
        """Poll `me` (it answers "paused" while the bridge holds its loops) until a jump > JUMP_M, then until still."""
        t0, paused_s, jumped_at, last = self.clock(), 0.0, None, None
        while self.clock() - t0 < wait_s:
            self.sleep(1.0)
            r = self.req("me", {}, 10)
            p = xyz(data(r).get("position"))
            if not p:
                paused_s += 1.0
                continue
            if jumped_at is None and d2(p, before) > JUMP_M:
                jumped_at = round(self.clock() - t0, 1)
            if jumped_at is not None and last and d3(p, last) < 0.1:
                return {"jumped": True, "position": p, "jump_m": round(d2(p, before), 1), "t_jump_s": jumped_at,
                        "settled_s": round(self.clock() - t0, 1), "paused_s": paused_s}
            last = p
        p = self.position() or last
        return {"jumped": jumped_at is not None, "position": p, "jump_m": round(d2(p, before), 1) if p else None,
                "t_jump_s": jumped_at, "paused_s": paused_s,
                "detail": f"no settled jump over {JUMP_M:g} m within {wait_s:g} s"}

    def enter(self, home: str = HOME_DEFAULT, leave: str = "door", spot: str = "door") -> dict:
        p = self.position()
        if not p or d2(p, DOOR_AT) > NEAR_DOOR_M:
            self.door(spot, home)  # raises Aborted after sending him home
        st = self.state()
        lk = self.look(20)
        things = lk.get("things") or []
        try:
            self.check(st, things, where="at the door")
        except Aborted as exc:
            self.record("enter", False, aborted=str(exc))
            self.go_home(home, f"enter abort: {exc}")
            raise
        row = door_row(things)
        if not row or not row.get("id"):
            return self.record("enter", False, detail="no door row within 20 m: nothing pressed")
        if row.get("locked") is True:
            return self.record("enter", False, door=row, detail="the door reads locked: nothing pressed")
        before = xyz(self.me().get("position")) or xyz(st.get("position")) or list(DOOR_AT)
        off = log_size(self.client_log)
        ir = self.req("interact", {"target": row["id"]}, 120)  # ONE press, the player's own path
        jump = self.wait_jump(before)
        st2 = self.state()
        lk80 = self.look(80)
        cen = data(self.req("census", {"radius_m": 80, "max": 40, "foliage": False}, 30))
        things80 = lk80.get("things") or []
        lines = log_lines(self.client_log, off)
        inside = inside_summary(things80, cen)
        replies = {"interact": ir, "get_state": st2, "look80": lk80, "census80": cen}
        self.replies.mkdir(parents=True, exist_ok=True)
        rf = self.replies / f"{self.run}_enter.json"
        rf.write_text(json.dumps(replies, default=str, indent=1), encoding="utf-8")
        base = dict(door=row, interact={"ok": ir.get("ok"), "reason": ir.get("reason"),
                                        "detail": (ir.get("data") or {}).get("detail") if isinstance(ir.get("data"), dict) else None},
                    jump_m=jump.get("jump_m"), t_jump_s=jump.get("t_jump_s"), paused_s=jump.get("paused_s"),
                    position=jump.get("position"), in_vault=st2.get("in_vault"), vault=st2.get("vault"),
                    look_in_vault=lk80.get("in_vault"), look_vault=lk80.get("vault"), health=st2.get("health"),
                    prop_guard=cen.get("prop_guard"), inside=inside, client_log=lines,
                    hooks_seen=any("teleport_begin" in ln for ln in lines),
                    replies_file=str(rf.relative_to(ROOT)) if rf.is_relative_to(ROOT) else str(rf))
        why = abort_reason(st2, things80 + list(cen.get("creatures") or []), self.hostile_m, self.min_health)
        if why or not jump.get("jumped"):
            self.record("enter", bool(jump.get("jumped")) and not why, aborted=why, detail=jump.get("detail"), **base)
            self.go_home(home, f"enter: {why or 'no teleport'}")
            if why:
                raise Aborted(why)
            return self.rows[-2]
        self.record("enter", True, **base)
        return self.leave(things80, row["id"], home, leave)

    def leave(self, things, entered_by: str, home: str, how: str) -> dict:
        ex = exit_row(things, entered_by)
        if how != "door" or not ex or not ex.get("id"):
            return self.go_home(home, "leave: " + ("--leave home" if how != "door" else "no exit row in sight"))
        before = self.position() or xyz(ex.get("position")) or [0.0, 0.0, 0.0]
        off = log_size(self.client_log)
        ir = self.req("interact", {"target": ex["id"]}, 120)
        jump = self.wait_jump(before)
        st = self.state()
        lines = log_lines(self.client_log, off)
        row = self.record("leave", bool(jump.get("jumped")) and st.get("in_vault") is not True, exit=ex,
                          interact={"ok": ir.get("ok"), "reason": ir.get("reason")}, jump_m=jump.get("jump_m"),
                          t_jump_s=jump.get("t_jump_s"), paused_s=jump.get("paused_s"), position=jump.get("position"),
                          in_vault=st.get("in_vault"), vault=st.get("vault"), client_log=lines,
                          door_m=round(d2(jump["position"], DOOR_AT), 1) if jump.get("position") else None,
                          detail=jump.get("detail"))
        if not jump.get("jumped"):
            self.go_home(home, "leave: the exit press did not move him")
        return row

    def home(self, home: str = HOME_DEFAULT) -> dict:
        return self.go_home(home, "home step")


# ------------------------------------------------------------------ live wiring
def default_probe(dev=None, **kw) -> Probe:
    from evals.bench.devrun import default_dev
    from tools.chat_ladder import _debug_client
    return Probe(cli=_debug_client(), dev=dev if dev is not None else default_dev(), **kw)


@contextlib.contextmanager
def on_fork(dev, info: dict, source: str = MAIN_CHARACTER):
    """Inside a live lock the caller already holds: fork `source` (a checkpoint label or a save name; ClaudeDev.json
    is only read) to a new character ClaudeV<ddHHMMSS> (tools.quest_clone.fork: a new name and guid), switch the
    client to it (evals.bench.devchar, as job_run and travel_ladder do), aim the dev fixtures at its guid, top it up
    with tools.supply (a dev-only harness fixture, logged with its purpose) and yield its name. Whatever the body does
    or raises, it ends back on ClaudeDev (quest_run._on_main), retrying every STUCK_S and never returning (so the
    caller never releases the lock) until he is; then the fork's save is parked (quest_clone.park). `info` gains
    character, source, switch_s, supply, back, back_s, parked."""
    from evals.bench.devchar import default_switch
    from tools import quest_clone, supply
    from tools import quest_run as q
    sw, cli = default_switch(dev), q.cl._debug_client()
    name = FORK_PREFIX + time.strftime("%d%H%M%S", time.gmtime())
    old = (getattr(dev, "character_guid", None), getattr(dev, "character_name", None))
    info.update(character=name, source=source)
    t0 = time.time()
    try:
        quest_clone.fork(source, name)
        info["forked"] = True
        made = sw.ensure(name, create=False, wait_s=150)
        info["switch_s"] = round(time.time() - t0, 1)
        dev.character_guid, dev.character_name = made["guid"], name  # the fixture guard wants the fork's guid
        print(f"[fork] on {name} (from {source}) after {info['switch_s']} s", flush=True)
        info["supply"] = supply.top_up(dev, FORK_FOOD, FORK_WATER, heal=True,
                                       purpose=f"vault_probe enter on fork {name}: harness fixture, food and water "
                                               "for a look inside Crasorak Kara")
        yield name
    finally:
        t1 = time.time()
        back = q._on_main(sw, cli)
        while back is None:  # never release the lock while the client is on another character (CLAUDE.md 4)
            print(f"STUCK: the client is not back on {MAIN_CHARACTER}; keeping the lock and retrying every "
                  f"{STUCK_S:.0f} s", flush=True)
            time.sleep(STUCK_S)
            back = q._on_main(sw, cli, tries=1)
        info["back"], info["back_s"] = back, round(time.time() - t1, 1)
        dev.character_guid, dev.character_name = old
        if info.get("forked"):
            info["parked"] = quest_clone.park([name])
        print(f"[fork] back on {MAIN_CHARACTER} after {info['back_s']} s; parked {info.get('parked')}", flush=True)


def fed(cli, wait_s: float | None = None, sleep: Callable[[float], None] = time.sleep) -> str | None:
    """chat_ladder.body_unfit, given the reflex up to FED_WAIT_S to eat and drink what supply put in his bag."""
    from tools.chat_ladder import body_unfit
    end = time.monotonic() + (FED_WAIT_S if wait_s is None else wait_s)
    while (why := body_unfit(cli)) is not None and time.monotonic() < end:
        sleep(FED_POLL_S)
    return why


@contextlib.contextmanager
def lock_window(wait_s: float):
    """The live lock, unless the caller's window already holds it (as tools/travel_ladder.py)."""
    from tools import live_lock
    cur = live_lock.read()
    if cur and not cur["stale"] and cur["owner"] == os.environ.get("DW_LIVE_OWNER"):
        yield
        return
    with live_lock.held(LOCK_OWNER, wait_s=wait_s):
        yield


def run_step(probe: Probe, step: str, a) -> int:
    try:
        probe.guard(step)
    except Refused as exc:
        probe.record(step, False, refused=str(exc))
        return 2
    try:
        if step == "door":
            row = probe.door(a.spot, a.home)
        elif step == "enter":
            row = probe.enter(a.home, a.leave, a.spot)
        else:
            row = probe.home(a.home)
    except Aborted:
        return 1
    except Exception as exc:  # harness fault: recorded, and he is sent home when he was moved
        probe.record(step, None, error=repr(exc)[:400])
        if step != "home":
            probe.go_home(a.home, f"error: {type(exc).__name__}")
        return 1
    return 0 if row.get("ok") else 1


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0], formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("step", choices=("door", "enter", "home"))
    ap.add_argument("--confirm", action="store_true", help="really move him (dev world only)")
    ap.add_argument("--spot", default="door", help=f"the door spot: {', '.join(SPOTS)}")
    ap.add_argument("--home", default=HOME_DEFAULT, help="the named home spot (SPOTS or evals/bench/dev_places.json)")
    ap.add_argument("--leave", choices=("door", "home"), default="door", help="enter: leave by the exit door or teleport")
    ap.add_argument("--from", dest="source", default=MAIN_CHARACTER,
                    help="enter: the save or checkpoint the fork is made from (default: ClaudeDev's own save, only read)")
    ap.add_argument("--hostile-m", type=float, default=HOSTILE_M)
    ap.add_argument("--min-health", type=float, default=MIN_HEALTH)
    ap.add_argument("--wait", type=float, default=1800.0, help="seconds to wait for the live lock")
    a = ap.parse_args(argv)
    sp = spots()
    for k in (a.spot, a.home):
        if k not in sp:
            ap.error(f"unknown spot {k!r} (known: {', '.join(sp)})")
    on_fork_ = a.step in STEPS_ON_FORK
    if not a.confirm:
        who = (f"on a fork of {a.source} ({FORK_PREFIX}<ddHHMMSS>), switching back to {MAIN_CHARACTER} at the end"
               if on_fork_ else f"on {MAIN_CHARACTER}")
        print(f"dry: would {a.step} {who}: spot {a.spot} {sp[a.spot]['at']}, home {a.home} {sp[a.home]['at']}, door "
              f"{DOOR_ID} at {DOOR_AT}; abort on a hostile within {a.hostile_m:g} m or health under "
              f"{a.min_health:.0%}. Add --confirm (dev world only).")
        return 0
    with lock_window(a.wait):
        if not on_fork_:
            probe = default_probe(hostile_m=a.hostile_m, min_health=a.min_health)
            return run_step(probe, a.step, a)
        return run_on_fork(a)


def run_on_fork(a) -> int:
    """A step that changes the character (enter) on a fork of a.source, inside the caller's lock: refused before any
    switch when the dev guard says no; a "fork" row records the switch there and back whatever the step did."""
    from evals.bench.devrun import default_dev
    dev = default_dev()
    probe = default_probe(dev=dev, hostile_m=a.hostile_m, min_health=a.min_health)
    try:
        dev.guard()  # off the dev server or with a live brain: no fork, no switch
    except Exception as exc:  # observer.Abort and anything else
        probe.record(a.step, False, refused=f"dev guard: {exc}")
        return 2
    info: dict = {}
    rc = 1
    try:
        with on_fork(dev, info, a.source) as name:
            probe.character = name
            unfit = fed(probe.cli)
            if unfit:
                probe.record(a.step, False, refused=f"the fork is unfit to start: {unfit}")
                rc = 2
            else:
                rc = run_step(probe, a.step, a)
    finally:
        if info.get("back"):
            probe.character = MAIN_CHARACTER
        probe.record("fork", bool(info.get("back")), fork=info, step_rc=rc)
    return rc


if __name__ == "__main__":
    sys.exit(main())
