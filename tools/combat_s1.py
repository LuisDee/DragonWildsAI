"""S1 practice ladder, live (docs/design/velgar.md §4: Goblin Thug PL 2, Wolf PL 3, Dire Wolf PL 3 packs). DEV WORLD ONLY.

Steps (each prints JSON and writes logs/combat/s1_<step>_<ts>.json):

  .venv\\Scripts\\python.exe -m tools.combat_s1 survey
      READ-ONLY: creatures within 200 m (name, class, PL, HP, distance, attitude), his vitals, statuses, held items,
      healing food, the combat memory status and his history per creature. No input, no fixture.
  .venv\\Scripts\\python.exe -m tools.combat_s1 fights --kind Wolf --n 5 [--spawn BP_..._C] [--pack 2] [--restart-at 3]
      n fights in a row with the same kind. Each fight: HP reset (fixture), optional spawn of `--pack` creatures of a
      class that is LOADED on the world (the fixture takes it from a live instance), then the body's own `attack`
      (force) on the nearest one with defence auto + disengage-heal; waits for the end; collects the combat_end
      activity line (damage taken, pack size, dodges/blocks/parries, kills) and the server's evidence
      (PredictPointDamage hits/evaded). --restart-at K: after fight K, waits for a client restart (watchdog or
      main) and checks the memory is loaded again before fight K+1.
      Ends with the damage-taken trend (least-squares slope over the fights) and combat_brief's own history.

Guards: the client slot must be held by "combat" (tools/client_slot.py); the dev target guard (evals.bench.devrun)
refuses anything but the dev world; never a player.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CMD, OUT = ROOT / "client_io" / "cmd", ROOT / "client_io" / "out"
ACTIVITY = ROOT / "client_io" / "events" / "activity.jsonl"
SERVER_LOG = Path(r"C:\GameServers\Dragonwilds\RSDragonwilds\Saved\Logs\RSDragonwilds.log")
LOGS = ROOT / "logs" / "combat"


def client(name: str, lua: str, timeout: float = 30) -> dict:
    out = OUT / f"{name}.json"
    if out.exists():
        out.unlink()
    tmp = CMD / f"{name}.lua.tmp"
    tmp.write_text(lua, encoding="utf-8")
    os.replace(tmp, CMD / f"{name}.lua")
    with open(CMD / "queue.txt", "a", encoding="utf-8") as q:
        q.write(name + "\n")
    t0 = time.time()
    while time.time() - t0 < timeout:
        if out.exists():
            time.sleep(0.1)
            try:
                return json.loads(out.read_text(encoding="utf-8"))
            except ValueError:
                pass
        time.sleep(0.3)
    return {"ok": False, "error": "timeout"}


def slot_ok() -> bool:
    from tools.client_slot import _load, holder
    h = holder(_load())
    return bool(h and h.get("owner") == "combat" and not h.get("reserved"))


SURVEY = r'''
return function(log)
    local C = assert(loadfile("C:/gameserver/client_mod/scripts/combat.lua"))()
    local I = assert(loadfile("C:/gameserver/client_mod/scripts/inventory.lua"))()
    local pc = C.local_pc(); local pawn = pc and pc.Pawn
    if not (pawn and pawn:IsValid()) then return { ok = false, reason = "no pawn" } end
    local me = C.read_me(pawn, pc); me.pos = nil
    local near = {}
    for _, c in ipairs(C.creatures_near(C.U.loc(pawn), 200)) do
        if not c.dead then
            near[#near + 1] = { id = c.id, name = c.name, class = C.U.class_word(c.actor), pl = c.pl, hp = c.hp, max_hp = c.max_hp,
                                d = c.distance_m and math.floor(c.distance_m), arch = c.archetype, boss = c.boss,
                                history = C.creature_history(c.name) }
        end
    end
    table.sort(near, function(a, b) return (a.d or 1e9) < (b.d or 1e9) end)
    local l = I.list(log)
    local food = {}
    for _, w in ipairs({ "hotbar", "bag" }) do for _, e in ipairs(l[w] or {}) do
        if e.consumable == "food" and (e.heal or 0) > 0 then food[#food + 1] = { name = e.name, heal = e.heal, count = e.count, where = w } end end end
    local mem = C.memory(log, pawn)
    return { ok = true, me = me, held = l.held, food = food, statuses = C.read_statuses(pawn), near = near,
             memory = { status = mem.status, detail = mem.detail, build = mem.build, path = mem.path } }
end
'''

FIGHT = r'''
local ORDERS = __ORDERS__
local KIND = "__KIND__"
return function(log)
    local C = assert(loadfile("C:/gameserver/client_mod/scripts/combat.lua"))()
    C.set_orders(ORDERS)
    local pc = C.local_pc(); local pawn = pc and pc.Pawn
    if not (pawn and pawn:IsValid()) then return { ok = false, reason = "no pawn" } end
    local best
    for _, c in ipairs(C.creatures_near(C.U.loc(pawn), 40)) do
        if not c.dead and (c.name or ""):find(KIND, 1, true) and (not best or c.distance_m < best.distance_m) then best = c end
    end
    if not best then return { ok = false, reason = "no " .. KIND .. " within 40 m" } end
    local r = C.attack(log, best.id, { force = true, by = "s1" })
    r.target_id = best.id
    return r
end
'''

STATUS = r'''
return function(log)
    local C = assert(loadfile("C:/gameserver/client_mod/scripts/combat.lua"))()
    local s = C.status()
    local f = s.fight
    return { fight = f and { phase = f.phase, dist_m = f.dist_m, target = f.target } or nil, memory = s.memory }
end
'''

BRIEF = r'''
return function(log)
    local C = assert(loadfile("C:/gameserver/client_mod/scripts/combat.lua"))()
    local pc = C.local_pc(); local pawn = pc and pc.Pawn
    local mem = C.memory(log, pawn)
    return { history = C.creature_history("__KIND__", mem), memory = { status = mem.status, saves = mem.saves } }
end
'''


def server_offset() -> int:
    return SERVER_LOG.stat().st_size if SERVER_LOG.exists() else 0


def server_evidence(since: int) -> dict:
    out = {"attacks": 0, "hits": 0, "evaded": 0, "zero_dmg": 0, "dmg": 0.0}
    if not SERVER_LOG.exists():
        return out
    with open(SERVER_LOG, "rb") as f:
        f.seek(since)
        data = f.read().decode("utf-8", "replace")
    for line in data.splitlines():
        if "starting attack on authority against player" in line:
            out["attacks"] += 1
        elif "PredictPointDamage" in line and "BP_PlayerCharacter" in line.split("PredictPointDamage")[1][:80]:
            if " evaded " in line:
                out["evaded"] += 1
            elif " will receive " in line:
                try:
                    d = float(line.split(" will receive ")[1].split(" ")[0])
                except (IndexError, ValueError):
                    d = 0.0
                if d > 0:
                    out["hits"] += 1
                    out["dmg"] += d
                else:
                    out["zero_dmg"] += 1
    return out


def activity_after(offset: int, kind: str = "combat_end") -> list[dict]:
    if not ACTIVITY.exists():
        return []
    with open(ACTIVITY, "rb") as f:
        f.seek(offset)
        rows = []
        for line in f.read().decode("utf-8", "replace").splitlines():
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if r.get("kind") == kind:
                rows.append(r)
    return rows


def slope(ys: list[float]) -> float | None:
    n = len(ys)
    if n < 2:
        return None
    xs = list(range(n))
    mx, my = sum(xs) / n, sum(ys) / n
    den = sum((x - mx) ** 2 for x in xs)
    return round(sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den, 2) if den else None


def save(step: str, data: dict) -> Path:
    LOGS.mkdir(parents=True, exist_ok=True)
    p = LOGS / f"s1_{step}_{time.strftime('%Y%m%d-%H%M%S')}.json"
    p.write_text(json.dumps(data, indent=1), encoding="utf-8")
    return p


def wait_fight(max_s: float) -> dict:
    t0 = time.time()
    while time.time() - t0 < max_s:
        r = (client("s1_status", STATUS, 20).get("result") or {})
        if not r.get("fight"):
            return r
        time.sleep(2)
    return {"timeout": True}


def wait_restart(max_s: float = 600) -> bool:
    """After a client restart: the runner answers again and the combat memory is loaded (not 'new' or refused)."""
    print(json.dumps({"waiting": "client restart (watchdog / main), then the memory reload"}), flush=True)
    t0 = time.time()
    seen_down = False
    while time.time() - t0 < max_s:
        r = client("s1_brief", BRIEF.replace("__KIND__", "x"), 15)
        if not r.get("ok"):
            seen_down = True
        elif seen_down and ((r.get("result") or {}).get("memory") or {}).get("status") in ("loaded", "loaded_build_unknown"):
            return True
        time.sleep(5)
    return False


def fights(a) -> dict:
    from evals.bench.devrun import default_dev
    d = default_dev()
    orders = a.orders or '{ defense = "auto", disengage = true, heal_hp = 0.5, reengage_hp = 0.8 }'
    rows = []
    for i in range(1, a.n + 1):
        d.setup("set_health", pct=100, purpose=f"S1 {a.kind} fight {i}: reset")
        if a.spawn:
            for k in range(a.pack):
                d.setup("spawn", **{"class": a.spawn}, offset_m=[-5, 3 * k - 3, 0], purpose=f"S1 {a.kind} fight {i}: pack {k + 1}/{a.pack}")
        off_s, off_a = server_offset(), ACTIVITY.stat().st_size if ACTIVITY.exists() else 0
        start = client("s1_fight", FIGHT.replace("__ORDERS__", orders).replace("__KIND__", a.kind))
        res = (start.get("result") or {})
        if not res.get("ok"):
            rows.append({"fight": i, "ok": False, "why": res.get("reason") or start.get("error")})
            print(json.dumps(rows[-1]), flush=True)
            break
        wait_fight(a.max_s)
        end = (activity_after(off_a) or [{}])[-1]
        row = {"fight": i, "outcome": end.get("outcome"), "reason": end.get("reason"), "damage_taken": end.get("damage_taken"),
               "pack": end.get("pack"), "kills": end.get("kills"), "dodges": end.get("dodges"), "blocks": end.get("blocks"),
               "parries": end.get("parries"), "heals": end.get("heals"), "dur_s": end.get("dur_s"),
               "server": server_evidence(off_s)}
        rows.append(row)
        print(json.dumps(row), flush=True)
        if a.restart_at and i == a.restart_at and i < a.n:
            row["restart_ok"] = wait_restart()
    dmg = [r["damage_taken"] for r in rows if isinstance(r.get("damage_taken"), (int, float))]
    brief = (client("s1_brief", BRIEF.replace("__KIND__", a.kind)).get("result") or {})
    return {"kind": a.kind, "fights": rows, "damage_taken": dmg, "trend_slope_per_fight": slope(dmg),
            "decreasing": (slope(dmg) or 0) < 0, "history": brief.get("history"), "memory": brief.get("memory")}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="step", required=True)
    sub.add_parser("survey")
    f = sub.add_parser("fights")
    f.add_argument("--kind", required=True, help="creature name substring, e.g. Wolf, Goblin Thug")
    f.add_argument("--n", type=int, default=5)
    f.add_argument("--spawn", help="a creature class LOADED on the dev world (from the survey's class column)")
    f.add_argument("--pack", type=int, default=1)
    f.add_argument("--orders", help="Lua table for combat_orders")
    f.add_argument("--restart-at", type=int, dest="restart_at")
    f.add_argument("--max-s", type=float, default=150, dest="max_s")
    a = ap.parse_args(argv)
    if not slot_ok():
        print(json.dumps({"ok": False, "why": "the client slot is not held by combat (python -m tools.client_slot take combat 30)"}))
        return 1
    sys.path.insert(0, str(ROOT))
    if a.step == "survey":
        data = client("s1_survey", SURVEY)
    else:
        data = fights(a)
    print(json.dumps(data, indent=1)[:6000])
    print("saved", save(a.step, data))
    return 0


if __name__ == "__main__":
    sys.exit(main())
