r"""Rung 4 gate (docs/GOAL-2026-11-01.md, "Gear and combat"): each item live on the dev world from chat, graded against
the same 4 bars as Rung 1 (time <= 1.5 x Luis, <= 1 miss, no stand > 5 s without work or a line, every report true).
A thin layer over tools/rung1_gate.py (its leg sampler, bars, grading, report and run loop), like tools/rung3_gate.py:
only the items, their setup and their checks live here.

Items (Luis's tasks from evals/baselines/luis_20261101_tasks.json; T_h = his recorded time):
  tannery  "build yourself a tannery and turn your hides into leather"   [make tannery 35.1 s: built one, 17 hides
           in, Overdrive cast on it (15 Air + 5 Water spent), 3 Leather in the window]       done: +3 Leather
  armour   "make yourself some armour for your level and put it on"     [make armour 32.6 s: Reinforced Body +
           Reinforced Helmet at the bench]  done: 2 armour pieces gained in the window and worn (T_h + 2 equips)
  bow      leg 1 "make yourself a bow and some arrows"  [make bow 25.3 s: longbow, shield, 16 arrow batches]
                 done: +1 bow and +33 arrows
           leg 2 "shoot that kebbit with your bow" (a kebbit spawned 14 m off: dev fixture) [use bow 39.3 s for 3
                 kills with 5 arrows: 1.5 s + 13.1 s per kill]  done: it reads dead and arrows were spent
  spells   "kill that goblin with your attack spells" (a Goblin Runt spawned 12 m off: dev fixture)
           [no Luis staff fight: T_h = rung 1's fight bar, 1.5 s + his kill unit]  done: it reads dead and runes
           were spent (staff casts spend the magic ammo slot's runes)
  gear_up  "get all your stuff together and gear up properly" (Luis 2026-11-01: "get him to get all his shit and put
           his good armour on"). No fixtures at all: he starts as he is. Target from brain/gear_plan.py at the start
           (his state + the containers he remembers): the best full armour set he can reach (PL) and the best
           weapon / off-hand. [T_h composed from Luis's own tasks for what that target is short of: 'kill cow' per
           15 hides / 14 bones, 'make tannery' (build + 5.9 s per leather), 'make armour' per piece + an equip each,
           his run speed for the walk to a container that holds better gear]  done: his worn armour PL and held kit
           reach the target. His graves are read at the end and shown to the judge: going for one is his call, and
           what he says about it is judged.
Materials that are not the item under test are granted (dev fixture) and listed in the row's note. Stations are his
own (his crafting table at the base, the tannery he builds): Luis's are never used. Copies of the item under test he
already carries (a bow, gate-made armour) are dropped at the respawn point first, so he starts as Luis did.

    .venv\Scripts\python.exe -m tools.rung4_gate plan
    .venv\Scripts\python.exe -m tools.rung4_gate run --confirm --only bow,spells [--runs 3]
    .venv\Scripts\python.exe -m tools.rung4_gate report

Rows: logs/evals/rung4_gate.jsonl. The live lock owner is "rung4" (one window per item).
"""
from __future__ import annotations

import json
import re
import sys
import time

from tools import coplay_ladder as cp
from tools import live_lock
from tools import rung1_gate as g
from tools import rung3_gate as r3

OUT = g.ROOT / "logs" / "evals" / "rung4_gate.jsonl"
WORLD = "dev_rung4"
ASH, STONE = "ITEM_Resources_Wood_Ash", "ITEM_Resources_Stone"
HIDE, LEATHER, BONE = "ITEM_Resources_Animal_Hide", "ITEM_Resources_Leather", "ITEM_Resources_AnimalBone"
THREAD, FEATHER = "ITEM_Resources_Thread_Coarse", "ITEM_Resources_Feathers"
KEBBIT = "BP_AI_Kebbit_Character_02_C"
DUMP = r3.DUMP  # the Temple Woods respawn point, 70 m from the base

# where he starts (recorder 2026-11-01): the tannery from Luis's own start spot (5.8 m from where Luis built his);
# armour and bow 2 m from Claude's own crafting table [100.62, 1859.54] (Luis stood 2.8 m from his); the fights on
# the open ground north of the base where Luis slept
SPOT = {"tannery": [102.15, 1854.68, -31.13], "armour": [100.5, 1857.5, -31.0], "bow": [100.5, 1857.5, -31.0],
        "fight": [101.24, 1868.4, -30.69]}
LINES = {"tannery": "claude build yourself a tannery and turn your hides into leather",
         "armour": "claude make yourself some armour for your level and put it on",
         "bow_make": "claude make yourself a bow and some arrows",
         "bow_kill": "claude shoot that kebbit with your bow",
         "spells": "claude kill that goblin with your attack spells",
         "gear_up": "claude get all your stuff together and gear up properly",
         "bag": "claude you're carrying too much, sort your bag out"}
ITEMS4 = ["tannery", "armour", "bow", "spells", "gear_up", "bag"]
# what each item's check reads (inventory display names)
BOW_RX, ARROW_RX = r"(shortbow|longbow|\bbow)$", r"arrow"
ARMOUR_RX = r"(body|helmet|cowl|chaps|platelegs|robe|hat|leggings|chestpiece|legs|gloves|boots|cape)$"
GATE_ARMOUR_RX = r"^(reinforced|leather) (body|helmet|platelegs|cowl|chaps)$"  # what this gate's fixtures make
RUNE_RX = r" rune$"


def luis(name: str) -> float:
    t = g.luis_task_s(name)
    if not t:
        raise RuntimeError(f"no Luis baseline for {name!r}")
    return t


T_H = {"tannery": lambda: luis("make tannery"),
       "armour": lambda: luis("make armour") + 2 * g.MOVE_S,  # + putting the 2 pieces on (his drag gap each)
       "bow_make": lambda: luis("make bow"),
       "bow_kill": lambda: 1.5 + luis("use bow") / 3,  # his 3 kills in one window: one kill's share + reaction
       "spells": lambda: 1.5 + g.unit("kill"),
       "gear_up": lambda: None,  # composed per run from what he is short of (gear_up_t_h)
       "bag": lambda: None}  # per run: a walk to his nearest crate and back + a drag per stack he stores
LUIS_RUN_MS = 384 / 61.7  # 'return back to foundation': 384 m in 61.7 s moving (recorder 2026-11-01)


# ------------------------------------------------------------------ context: worn gear counts as carried
class Ctx4(g.Ctx):
    """rung1's Ctx, whose inventory rows also carry his loadout: worn gear as "worn:<name>" (the armour check sees a
    crafted piece go from the bag onto him; an equipped piece leaves the bag), and the Ammo / MagicAmmo stacks under
    their own names with their counts when no bag stack of that item is listed (the slot references a bag stack, so
    it is counted once; the compact inventory reply keeps only the slot's name). Held items are hotbar references,
    already counted."""
    held_rows = False  # gear_up: held weapon / off-hand as "held:<name>" rows (other items count held gear as hotbar)
    carry_rows = False  # bag: his carry weight as a "carry:cur" / "carry:max" row (the game's encumbrance getters)
    hazard_guard = None  # gear_up: called with every me() sample (fall_guard); sets self.abort to end the window
    abort = None

    def me(self) -> dict:
        m = super().me()
        if self.hazard_guard is not None and m:
            self.hazard_guard(self, m)
        return m

    def stacks(self) -> list[dict]:
        d = cp._data(self.cli.request("inventory", {"raw": True}, timeout=20))
        rows = [{"name": r.get("name") or r.get("item"), "item": r.get("item"), "count": r.get("count")}
                for where in ("hotbar", "bag") for r in d.get(where) or [] if isinstance(r, dict)]
        if self.carry_rows and (c := carry()):
            rows += [{"name": "carry:cur", "item": None, "count": round(c["cur"], 1)},
                     {"name": "carry:max", "item": None, "count": round(c["max"], 1)}]
        for r in d.get("loadout") or []:
            slot = str(r.get("loadout_slot") or r.get("slot") or "") if isinstance(r, dict) else ""
            if slot in ("HeldRight", "HeldLeft") and self.held_rows and (r.get("name") or r.get("item")):
                rows.append({"name": f"held:{r.get('name') or r.get('item')}", "item": None, "count": 1, "slot": f"held:{slot}"})
                continue
            if not slot or slot in ("HeldRight", "HeldLeft") or not (r.get("name") or r.get("item")):
                continue
            if slot.startswith(("MagicAmmo", "Ammo")):
                if any(x.get("item") == r.get("item") for x in rows if not x.get("slot")):
                    continue  # the slot references a bag stack (live 21:36Z: 33 crafted arrows counted 66, 11 shots 22)
                rows.append({"name": r.get("name") or r.get("item"), "item": r.get("item"), "count": r.get("count"),
                             "slot": slot})
            else:
                rows.append({"name": f"worn:{r.get('name') or r.get('item')}", "item": None, "count": 1, "slot": f"worn:{slot}"})
        return rows


CARRY_LUA = r"""return function(log)
    if rawget(_G, "DW_PAUSE") == true then return { ok = false, error = "paused" } end
    local root = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
    local U = assert(loadfile(root .. "/mod/body/util.lua"))()
    local pc
    for _, c in ipairs(U.find_all("BP_PlayerController_C", { skip_defaults = true })) do
        if U.try(function() return c:IsLocalController() end) == true then pc = c end
    end
    local pawn = pc and U.try(function() return pc.Pawn end)
    local ec = U.valid(pawn) and U.try(function() return pawn.PlayerEncumbranceComponent end)
    if not U.valid(ec) then return { ok = false, error = "no encumbrance component" } end
    return { ok = true, cur = U.try(function() return ec:GetCurrentCarryWeight() end),
             max = U.try(function() return ec:GetMaxCarryWeight() end), over = U.try(function() return ec:IsEncumbered() end) }
end
"""


def carry() -> dict | None:
    """His carry weight {cur, max, over} (read-only: UPlayerEncumbranceComponent getters, as move.lua reads them)."""
    from tools import combat_s1
    r = combat_s1.client("r4_carry", CARRY_LUA, timeout=10)
    r = r.get("result") if isinstance(r.get("result"), dict) else r
    if not (r.get("ok") and isinstance(r.get("cur"), (int, float)) and isinstance(r.get("max"), (int, float))):
        return None
    return {"cur": float(r["cur"]), "max": float(r["max"]), "over": r.get("over") is True}


# ------------------------------------------------------------------ checks (registered in coplay_ladder)
def _bag_delta(rec: dict) -> dict[str, int]:
    inv = rec.get("inv") or []
    if len(inv) < 2:
        return {}
    a, b = inv[0][1], inv[-1][1]
    return {k: b.get(k, 0) - a.get(k, 0) for k in set(a) | set(b) if b.get(k, 0) != a.get(k, 0)}


def _delta_words(d: dict) -> str:
    return ", ".join(f"{v:+d} {k}" for k, v in sorted(d.items(), key=lambda kv: kv[1]))


def check_all(rec: dict, rows: list[dict]):
    """Done when every part {name, rx, n} has been gained (bag + hotbar + worn, vs the first sample)."""
    parts, inv = rec["target"]["parts"], rec.get("inv") or []
    base = inv[0][1] if inv else {}

    def got(c: dict, rx: str) -> int:
        r = re.compile(rx, re.I)
        return sum(v - base.get(k, 0) for k, v in c.items() if r.search(k.removeprefix("worn:")) and v > base.get(k, 0))
    when = None
    for t, c in inv[1:]:
        if all(got(c, p["rx"]) >= p["n"] for p in parts):
            when = t
            break
    last = inv[-1][1] if inv else {}
    how = "; ".join(f"gained {got(last, p['rx'])} {p['name']} (asked {p['n']})" for p in parts)
    d = _bag_delta(rec)
    if d:
        how += "; his inventory over the window (worn: = on him): " + _delta_words(d)
    return when is not None, how, when, {"bag_delta": d}


def check_wear(rec: dict, rows: list[dict]):
    """Done when n armour pieces he did not wear at the start are on him and were gained in the window (made)."""
    tg, inv = rec["target"], rec.get("inv") or []
    base = inv[0][1] if inv else {}
    rx = re.compile(tg["rx"], re.I)
    worn0 = {k for k in base if k.startswith("worn:")}

    def new_worn(c: dict) -> list[str]:
        made = {k.removeprefix("worn:") for k in c if k.startswith("worn:") and k not in worn0 and rx.search(k)}
        return sorted(made)
    when = None
    for t, c in inv[1:]:
        if len(new_worn(c)) >= tg["n"]:
            when = t
            break
    last = inv[-1][1] if inv else {}
    made = {k: v - base.get(k, 0) for k, v in last.items() if not k.startswith("worn:") and v > base.get(k, 0) and rx.search(k)}
    how = (f"now wearing {new_worn(last) or 'nothing new'} (wanted {tg['n']} new armour pieces on him); at the start he "
           f"wore {sorted(k.removeprefix('worn:') for k in worn0) or 'nothing'}")
    if made:
        how += f"; made but not worn: {made}"
    d = _bag_delta(rec)
    if d:
        how += "; his inventory over the window (worn: = on him): " + _delta_words(d)
    return when is not None, how, when, {"worn_new": new_worn(last), "bag_delta": d}


def check_kill_with(rec: dict, rows: list[dict]):
    """The creature reads dead (or vanished after a reported kill) AND some of what the item fights with was spent by
    then (arrows for the bow, runes for attack spells): a kill with it, not with a club."""
    done, how, when, m = cp.check({**rec, "kind": "kill"}, rows)
    tg, inv = rec["target"], rec.get("inv") or []
    rx = re.compile(tg["spend_rx"], re.I)
    base = inv[0][1] if inv else {}

    def spent(c: dict) -> int:
        return sum(base.get(k, 0) - c.get(k, 0) for k in base if rx.search(k) and c.get(k, 0) < base.get(k, 0))
    last = inv[-1][1] if inv else {}
    m["spent"] = spent(last)
    how += f"; {tg['spend_name']} spent over the window: {m['spent']}"
    ok = bool(done) and m["spent"] > 0
    hp = [s[5] for s in rec.get("me") or [] if len(s) > 5 and isinstance(s[5], (int, float))]
    if hp:
        how += f"; his HP {hp[0]:.0f} -> low {min(hp):.0f} -> {hp[-1]:.0f}"
    res = [((r.get("result") or {}).get("data") or {}) for r in rows if r.get("kind") == "tool_result" and r.get("tool") == "attack"]
    if res:
        last_res = res[-1]
        how += f"; the attack reported: killed={last_res.get('killed')} weapon={last_res.get('weapon')} " \
               f"ranged={json.dumps(last_res.get('ranged'), default=str)[:200]}"
    d = _bag_delta(rec)
    if d:
        how += "; his inventory over the window: " + _delta_words(d)
    return ok, how, when if ok else None, m


def _gear_index() -> dict[str, tuple[str, int]]:
    """display name (lower) -> (slot, power level) for every armour piece, weapon and shield in the item catalog."""
    from brain import item_stats
    return {str(c["name"]).lower(): (c.get("slot"), int(c["power_level"])) for c in item_stats.catalog().values()
            if c.get("name") and c.get("power_level") is not None and c.get("role") in ("armour", "weapon", "shield")}


def gear_on(c: dict, idx: dict | None = None) -> dict:
    """What one inventory sample has on him: {"pl": armour PL, "slots": {slot: (name, pl)}} from worn:/held: rows."""
    idx = idx if idx is not None else _gear_index()
    slots: dict[str, tuple[str, int]] = {}
    for k in c:
        if not k.startswith(("worn:", "held:")):
            continue
        name = k.split(":", 1)[1]
        slot, pl = idx.get(name.lower(), (None, None))
        if slot and (slot not in slots or pl > slots[slot][1]):
            slots[slot] = (name, pl)
    armour = [slots[s][1] if s in slots else 0 for s in ("head", "body", "legs")]
    return {"pl": sum(armour) // 3, "slots": slots}


def check_gear(rec: dict, rows: list[dict]):
    """Done when his worn armour's PL reaches the target and every kit slot (weapon, off-hand) holds gear of the
    target PL or better (both from gear_plan at the start)."""
    tg, inv = rec["target"], rec.get("inv") or []
    idx = _gear_index()

    def short(c: dict) -> list[str]:
        on = gear_on(c, idx)
        out = [f"armour PL {on['pl']} (target {tg['pl']})"] if on["pl"] < tg["pl"] else []
        for slot, want in (tg.get("kit") or {}).items():
            have = on["slots"].get(slot)
            if not have or have[1] < want:
                out.append(f"{slot} {have[0] + ' PL ' + str(have[1]) if have else 'empty'} (target PL {want})")
        return out
    when = next((t for t, c in inv[1:] if not short(c)), None)
    first, last = (inv[0][1] if inv else {}), (inv[-1][1] if inv else {})

    def words(c: dict) -> str:
        on = gear_on(c, idx)
        return f"PL {on['pl']}: " + (", ".join(f"{s} {n} (PL {pl})" for s, (n, pl) in sorted(on["slots"].items())) or "nothing")
    how = f"at the start {words(first)}; at the end {words(last)}"
    if short(last):
        how += "; still short: " + "; ".join(short(last))
    d = _bag_delta(rec)
    if d:
        how += "; his inventory over the window (worn:/held: = on him): " + _delta_words(d)
    return when is not None, how, when, {"bag_delta": d, "gear_end": gear_on(last, idx)}


def check_carry(rec: dict, rows: list[dict]):
    """Done when his carry weight is at or under his max (the game's encumbrance), from the carry: rows."""
    inv = rec.get("inv") or []

    def w(c: dict) -> tuple[float | None, float | None]:
        return c.get("carry:cur"), c.get("carry:max")
    when = next((t for t, c in inv[1:] if None not in w(c) and w(c)[0] <= w(c)[1]), None)
    first, last = (inv[0][1] if inv else {}), (inv[-1][1] if inv else {})
    how = f"carry weight {w(first)[0]} of {w(first)[1]} at the start, {w(last)[0]} of {w(last)[1]} at the end"
    d = {k: v for k, v in _bag_delta(rec).items() if not k.startswith("carry:")}
    if d:
        how += "; his inventory over the window: " + _delta_words(d)
    return when is not None, how, when, {"bag_delta": d, "carry_end": w(last)}


cp.CHECK_HOOKS.update({"r4_all": check_all, "r4_wear": check_wear, "r4_kill": check_kill_with, "r4_gear": check_gear,
                       "r4_carry": check_carry})


# ------------------------------------------------------------------ setup helpers
def preflight_char(ctx) -> None:
    name = (ctx.me() or {}).get("name")
    if name != g.WHO:
        raise RuntimeError(f"the client is on {name!r}, not {g.WHO} (another agent's character): not run")


def stock(ctx, item: str, want: dict[str, int]) -> list[str]:
    """Grant the shortfall of each precondition (dev fixture); returns what was granted, for the row's note."""
    have, out = r3._bag(ctx), []
    for it, n in want.items():
        short = n - have.get(it, 0)
        if short > 0:
            r3.cl_dev().setup("grant", purpose=f"rung4 gate {item}: precondition {it} (not the item under test)", item=it,
                              count=short)
            out.append(f"{it} x{short}")
    return out


STASH_AT = (112.6, 1850.5)  # by the tannery: his crates on his ledger within STASH_M of here take what a gate sheds
STASH_M = 12.0
PIECES = g.ROOT / "data" / "skills" / "dev" / "my_pieces.json"
RETRY = ("interrupted", "cancelled", "busy", "still_running")


def own_storage(ctx) -> list[tuple[str, list]]:
    """His crates and chests by the base (his piece ledger, within STASH_M of STASH_AT; matched in look by position,
    ids renumber after a client reload), nearest first: [(id, at)]. One alone fills (07:50Z: all 16 slots taken)."""
    try:
        led = json.loads(PIECES.read_text(encoding="utf-8")).get("pieces") or []
    except (OSError, ValueError):
        led = []
    spots = [r["at"] for r in led if isinstance(r, dict) and r.get("name") in ("Crate", "Ash Chest") and r.get("at")
             and ((r["at"][0] - STASH_AT[0]) ** 2 + (r["at"][1] - STASH_AT[1]) ** 2) ** 0.5 <= STASH_M]
    spots.sort(key=lambda a: (a[0] - STASH_AT[0]) ** 2 + (a[1] - STASH_AT[1]) ** 2)
    r3.place(ctx, [STASH_AT[0] - 1.6, STASH_AT[1] + 0.5, -31.2])
    lk = ctx.cli.request("look", {"radius": STASH_M + 8, "max": 60}, timeout=15) or {}
    things = [x for x in ((lk.get("data") or {}).get("things") or []) if x.get("kind") == "storage"]
    out = []
    for a in spots:
        x = next((x for x in things if abs((x.get("position") or [1e9])[0] - a[0]) < 0.8
                  and abs((x.get("position") or [0, 1e9])[1] - a[1]) < 0.8), None)
        if x:
            out.append((x.get("id"), a))
    return out


def store_his(ctx, name: str, n: int, stores: list[tuple[str, list]]) -> tuple[bool, str]:
    """n of `name` into the first of his storages that takes them (store walks there itself); a pre-empted store is
    tried again (the brain is live: its start-up review took the body mid-store at 07:33:40Z, "cancelled")."""
    why = "none of his storage found by the base"
    for cid, at in stores:
        res = {}
        for _ in range(4):
            res = ctx.cli.request("store", {"item": name, "container": cid, "count": n}, timeout=120) or {}
            if res.get("ok") or res.get("reason") not in RETRY:
                break
            time.sleep(4.0)
        if res.get("ok"):
            return True, f"stored {n} {name} in his storage at ({at[0]:.1f}, {at[1]:.1f})"
        why = f"{res.get('reason')}: {(res.get('data') or {}).get('detail')}"
    if stores and why.startswith("container_full") and not getattr(ctx, "built_crate", False):
        # every crate of his by the base is full (08:4xZ: all 4; each gate run makes a bow that the next sheds):
        # as a player would, he builds another crate there (its materials a dev fixture) and it takes them
        ctx.built_crate = True
        cost = build_cost(ctx, "crate")
        stock(ctx, "storage", cost)
        b = ctx.cli.request("build", {"piece": "Crate", "near": [STASH_AT[0], STASH_AT[1] + 2.5, -31.2]}, timeout=180) or {}
        if not b.get("ok"):
            return False, f"{why}; and a new crate wasn't built ({b.get('reason')}: {(b.get('data') or {}).get('detail')})"
        stores[:] = own_storage(ctx)
        ok, msg = store_his(ctx, name, n, stores)
        return ok, f"built him a crate (all his were full, materials {cost}); " + msg
    return False, why


def put_back(ctx, granted: dict[str, int]) -> str:
    """Up to the granted count of each fixture item (id -> n) he still carries goes into his storage; the note says."""
    rows = cp.inv_rows(cp.inventory(ctx.cli))
    stores, done = own_storage(ctx), []
    for it, n in granted.items():
        have = sum(int(r.get("count") or 1) for r in rows if r.get("item") == it)
        name = next((r.get("name") for r in rows if r.get("item") == it), it)
        if min(n, have) > 0:
            ok, msg = store_his(ctx, name, min(n, have), stores)
            done.append(msg if ok else f"{min(n, have)} {name} NOT stored ({msg})")
    return "put back: " + (", ".join(done) or "nothing left")


def shed(ctx, item: str, name_rx: str) -> list[str]:
    """Copies of the item under test he carries or wears (name_rx on display names) go off him into his own storage
    by the base, so he starts without one, as Luis did, and nothing of his is lost or left on the ground (main
    2026-11-02: gates never litter or drop his own gear). A store that fails stops the item (nothing dropped)."""
    rx = re.compile(name_rx, re.I)
    inv = cp.inventory(ctx.cli)
    worn = [(s, n) for s, n in (inv.get("worn") or {}).items() if n and rx.search(str(n))]
    for slot, _ in worn:
        ctx.cli.request("unequip", {"slot": slot}, timeout=20)
    # one in his hand comes off first (store: "the one in my hand has to come off before it can go in a chest");
    # unequip by item answers {already: true} when it isn't held or slotted
    for name in {r.get("name") for r in cp.inv_rows(cp.inventory(ctx.cli)) if rx.search(str(r.get("name") or ""))}:
        ctx.cli.request("unequip", {"item": name}, timeout=20)
    rows = [r for r in cp.inv_rows(cp.inventory(ctx.cli)) if rx.search(str(r.get("name") or ""))]
    if not rows:
        return [f"took off {[n for _, n in worn]}"] if worn else []
    out, stores = [], own_storage(ctx)
    for r in rows:
        n = int(r.get("count") or 1)
        ok, msg = store_his(ctx, r.get("name") or r.get("item"), n, stores)
        if not ok:  # never dropped: the item is not run with them on him
            raise RuntimeError(f"could not store his {n} {r.get('name')} ({msg}); item not run")
        out.append(msg)
    left = [r.get("name") for r in cp.inv_rows(cp.inventory(ctx.cli)) if rx.search(str(r.get("name") or ""))]
    if left:
        raise RuntimeError(f"could not put away his {left} before the item")
    return out


def build_cost(ctx, about: str) -> dict[str, int]:
    """The piece's material cost {item id: count} from his own buildables read (the game's unlocked pieces)."""
    r = ctx.cli.request("buildables", {"about": about}, timeout=20) or {}
    d = r.get("data") or {}
    rows = d.get("pieces") or d.get("buildables") or d.get("matches") or []
    rx = re.compile(re.escape(about), re.I)
    row = next((x for x in rows if isinstance(x, dict) and rx.search(str(x.get("name") or ""))), None)
    if not row:
        raise RuntimeError(f"buildables has no {about!r}: {json.dumps(d, default=str)[:400]}")
    cost = row.get("cost") or row.get("materials") or []
    out = {}
    for c in cost:
        if isinstance(c, dict) and (c.get("item") or c.get("id")):
            out[str(c.get("item") or c.get("id"))] = int(c.get("count") or c.get("need") or 1)
    if not out:
        raise RuntimeError(f"no cost read for {about!r}: {json.dumps(row, default=str)[:400]}")
    return out


def spawn_near(ctx, cls: str, off: list[float], name_rx: str, purpose: str) -> tuple[dict, dict]:
    """A creature spawned off him (dev fixture) and its client census row (client ids differ from the server's)."""
    dev = r3.cl_dev()
    cen = lambda: cp.census(ctx.cli, radius_m=40, max=40, kinds={"creatures": True}, foliage=False).get("creatures") or []  # noqa: E731
    before = {x.get("id") for x in cen()}
    here = (ctx.me().get("position") or [0, 0, 0])[:2]
    res = dev.setup("spawn", purpose=purpose, **{"class": cls, "offset_m": off})
    # the spawn lands off him on world axes (fixtures.lua domSpawnAi); the census row nearest that point is it, not
    # the first new one: a wild kebbit walking into the 40 m census was taken for it (bow run 1, 07:34Z: the gate
    # tracked _239939 while he shot _240842 at 14 m, the spawn)
    at = [here[0] + off[0], here[1] + off[1]]
    tgt = {"server_id": res.get("id"), "spawn_m": round((off[0] ** 2 + off[1] ** 2) ** 0.5, 1)}
    for _ in range(10):
        time.sleep(0.5)
        new = [x for x in cen() if x.get("id") not in before and re.search(name_rx, str(x.get("name")), re.I)]
        if new:
            def far(x):
                q = x.get("position") or [1e9, 1e9]
                return ((q[0] - at[0]) ** 2 + (q[1] - at[1]) ** 2) ** 0.5
            new.sort(key=far)
            tgt.update(id=new[0]["id"], name=new[0].get("name"), from_spawn_m=round(far(new[0]), 1),
                       other_new=[(x["id"], round(far(x), 1)) for x in new[1:4]])
            return res, tgt
    raise RuntimeError(f"the spawned {cls} never showed in his census (spawn {res})")


def remove_spawn(row: dict, res: dict) -> None:
    """A spawn still alive after the leg is the harness's to remove (bench cleanup), as rung1's fight does."""
    seen = row.get("rec", {}).get("seen") or []
    if seen and seen[-1][1] == "alive" and res.get("id"):
        k = g.cl._server_client().request("debug_run", {"module": "bench_creatures", "args": {
            "action": "kill", "character_guid": r3.cl_dev().character_guid, "ids": [res["id"]]}}, timeout=30)
        row["cleanup"] = ((k.get("data") or {}).get("result") or {}).get("ok")


def full_hp(ctx) -> None:
    m = ctx.me()
    if (m.get("health") or 0) < (m.get("max_health") or 100):
        r3.cl_dev().setup("set_health", purpose="rung4 gate fight: full HP", value=float(m.get("max_health") or 100))


def fight_work(row: dict):
    """A stand in a fight is work while the target is alive and in range of what he fights with, its HP changes, his
    HP changes or he spends ammo (a bow or staff stands still while it shoots)."""
    rec = row["rec"]
    seen = [s for s in rec.get("seen") or [] if s[1] == "alive"]
    hp = [(s[0], s[5]) for s in rec.get("me") or [] if len(s) > 5 and isinstance(s[5], (int, float))]
    inv = rec.get("inv") or []
    rx = re.compile(rec["target"]["spend_rx"], re.I)

    def ammo(c):
        return sum(v for k, v in c.items() if rx.search(k))

    def work(a, b):
        th = [s[2] for s in seen if a - 1.5 <= s[0] <= b + 1.5 and isinstance(s[2], (int, float))]
        if len(set(th)) > 1:
            return True
        mh = [h for t, h in hp if a - 1 <= t <= b + 1]
        if len(set(mh)) > 1:
            return True
        am = [ammo(c) for t, c in inv if a - 2 <= t <= b + 2]
        return any(y < x for x, y in zip(am, am[1:]))
    return work


# ------------------------------------------------------------------ the items
def it_tannery(ctx) -> dict:
    preflight_char(ctx)
    r3.place(ctx, SPOT["tannery"])
    cost = build_cost(ctx, "tannery")
    fixtures = stock(ctx, "tannery", {**cost, HIDE: 6})
    time.sleep(2.0)
    row = g.run_leg(ctx, {"id": "tannery", "kind": "r4_all",
                          "check_text": "he builds a tannery of his own and gains 3 Leather (inventory)"},
                    LINES["tannery"], {"parts": [{"name": "Leather", "rx": r"^leather$", "n": 3}]},
                    deadline_s=240, sample=("me", "inv"))
    t_h = T_H["tannery"]()
    return g.finish(ctx, "tannery", [row], t_h, allowed=1, work=r3.processing_work(row["rec"]["t0"]),
                    note=f"Luis 'make tannery' {t_h} s; build cost read {cost}; fixtures: {', '.join(fixtures) or 'none'}")


def it_armour(ctx) -> dict:
    preflight_char(ctx)
    shed_note = shed(ctx, "armour", GATE_ARMOUR_RX)
    r3.place(ctx, SPOT["armour"])
    fixtures = shed_note + stock(ctx, "armour", {LEATHER: 10, BONE: 14})  # Luis's spend for his two pieces
    time.sleep(2.0)
    row = g.run_leg(ctx, {"id": "armour", "kind": "r4_wear",
                          "check_text": "two armour pieces he did not wear at the start, made in the window, are on him"},
                    LINES["armour"], {"name": "armour", "rx": ARMOUR_RX, "n": 2}, deadline_s=150, sample=("me", "inv"))
    t_h = T_H["armour"]()
    return g.finish(ctx, "armour", [row], t_h, allowed=1,
                    note=f"Luis 'make armour' {luis('make armour')} s + 2 equips; fixtures: {', '.join(fixtures) or 'none'}")


def it_bow(ctx) -> dict:
    preflight_char(ctx)
    shed_note = shed(ctx, "bow", BOW_RX)
    # his dev-granted Wooden Arrows go too: the wiki calls them an unused prototype (no recipe, no base damage) and
    # live they hit a kebbit for ~3 of its 30 HP (probe 2026-11-01 20:21Z: 14 arrows, 89 s); Luis shot Stone ones
    shed_note += shed(ctx, "bow", r"^wooden arrows?$")
    # and any arrows: Luis started without (his "make bow" made them), and 63 Fang Arrows left from rung4's bow
    # measurements made the arrow leg moot (run 1, 07:2xZ: "I already had 63 Fang Arrows")
    shed_note += shed(ctx, "bow", r"arrows?$")
    r3.place(ctx, SPOT["bow"])
    # a shortbow (12 Ash, 3 Thread) or Luis's longbow (16 Ash, 6 Thread) + an arrow batch (1 Stone, 2 Ash, 1 Feathers)
    fixtures = shed_note + stock(ctx, "bow", {ASH: 20, THREAD: 6, STONE: 2, FEATHER: 2})
    time.sleep(2.0)
    make = g.run_leg(ctx, {"id": "bow_make", "kind": "r4_all", "check_text": "he gains a bow and at least 33 arrows"},
                     LINES["bow_make"], {"parts": [{"name": "bow", "rx": BOW_RX, "n": 1},
                                                  {"name": "arrows", "rx": ARROW_RX, "n": 33}]},
                     deadline_s=120, sample=("me", "inv"))
    legs = [make]
    if make.get("done"):
        r3.place(ctx, SPOT["fight"])
        full_hp(ctx)
        res, tgt = spawn_near(ctx, KEBBIT, [14, 0, 0], r"kebbit", "rung4 gate bow: a kebbit to shoot")
        kill = g.run_leg(ctx, {"id": "bow_kill", "kind": "r4_kill",
                               "check_text": "the kebbit spawned 14 m from him reads dead and arrows were spent"},
                         LINES["bow_kill"], {**tgt, "spend_rx": ARROW_RX, "spend_name": "arrows"},
                         deadline_s=120, sample=("me", "inv"), creature=tgt.get("id"),
                         settled=lambda rows: any(r.get("kind") == "event" and (r.get("event") or {}).get("kind") == "combat_end"
                                                  for r in rows))
        remove_spawn(kill, res)
        legs.append(kill)
    t_h = T_H["bow_make"]() + T_H["bow_kill"]()
    work = fight_work(legs[-1]) if len(legs) > 1 else None
    return g.finish(ctx, "bow", legs, t_h, allowed=1, work=work,
                    note=f"T_h = Luis 'make bow' {luis('make bow')} s + 1.5 + 'use bow' {luis('use bow')} s / 3 kills; "
                         f"fixtures: {', '.join(fixtures) or 'none'}")


def it_spells(ctx) -> dict:
    preflight_char(ctx)
    r3.place(ctx, SPOT["fight"])
    full_hp(ctx)
    have = r3._bag(ctx)
    fixtures = []
    if not any(k.startswith("ITEM_Staff_") for k in have):
        fixtures += stock(ctx, "spells", {"ITEM_Staff_Ash": 1})
    if have.get("ITEM_Rune_Air", 0) < 40:
        fixtures += stock(ctx, "spells", {"ITEM_Rune_Air": 60})
    time.sleep(1.0)
    res, tgt = spawn_near(ctx, g.RUNT, [12, 0, 0], r"runt", "rung4 gate spells: a hostile to fight")
    row = g.run_leg(ctx, {"id": "spells", "kind": "r4_kill",
                          "check_text": "the Goblin Runt spawned 12 m from him reads dead and runes were spent (staff casts)"},
                    LINES["spells"], {**tgt, "spend_rx": RUNE_RX, "spend_name": "runes"},
                    deadline_s=150, sample=("me", "inv"), creature=tgt.get("id"),
                    settled=lambda rows: any(r.get("kind") == "event" and (r.get("event") or {}).get("kind") == "combat_end"
                                             for r in rows))
    remove_spawn(row, res)
    # the granted staff and what is left of the granted runes go into his crate (gates leave no fixtures on him)
    granted = {"ITEM_Staff_Ash": 1} if any(f.startswith("ITEM_Staff_Ash") for f in fixtures) else {}
    for f in fixtures:
        m = re.match(r"(ITEM_Rune_Air) x(\d+)$", f)
        if m:
            granted[m.group(1)] = int(m.group(2))
    if granted:
        fixtures.append(put_back(ctx, granted))
    t_h = T_H["spells"]()
    return g.finish(ctx, "spells", [row], t_h, allowed=1, work=fight_work(row),
                    note=f"T_h = 1.5 + Luis's kill unit {g.unit('kill')} s (no Luis staff fight recorded); "
                         f"fixtures: {', '.join(fixtures) or 'none'}")


def gear_target(state: dict, stash: dict | None) -> dict:
    """The gear_up target from brain/gear_plan.py: armour PL of the best full set he can reach, the kit slots whose
    best reachable PL beats what he holds, and the way Luis went for armour (Reinforced, 'make armour') per slot that
    is short, for T_h."""
    from brain import gear_plan
    p = gear_plan.plan(state, stash=stash)
    kit = {}
    for slot in gear_plan.KIT_SLOTS:
        sl = p["slots"][slot]
        held = int(sl["worn_pl"] or 0) if sl["worn"] else -1
        if sl["best_pl"] is not None and sl["best_pl"] >= max(held, 0):
            kit[slot] = sl["best_pl"]  # keep (or reach) the best he can hold
    pieces = []
    for slot in gear_plan.ARMOUR_SLOTS:
        sl = p["slots"][slot]
        if sl["best_pl"] is None or (sl["worn"] and sl["best_pl"] <= int(sl["worn_pl"] or 0)):
            continue
        o = next((o for o in sl["best"] if str(o.get("name") or "").startswith("Reinforced")), sl["best"][0])
        pieces.append(o)
    fetch = [(slot, o) for slot in gear_plan.KIT_SLOTS for o in p["slots"][slot]["best"][:1]
             if slot in kit and o["status"] == "owned" and "carried" not in o["where"] and "worn" not in o["where"]]
    fetch += [(o["name"], o) for o in pieces if o["status"] == "owned" and "carried" not in o["where"]]
    return {"pl": p["pl_full_set"], "pl_now": p["pl_now"], "kit": kit, "pieces": pieces, "fetch": fetch, "plan": p}


def gear_up_t_h(tg: dict, state: dict) -> tuple[float, str]:
    """Luis's time for what the target is short of, composed from his own recorded tasks; (seconds, how)."""
    short: dict[str, int] = {}
    for o in tg["pieces"]:
        if o["status"] == "owned":
            continue
        for x in o.get("short") or []:
            m = re.match(r"(.+) x(\d+)$", x)
            if m:
                short[m.group(1)] = short.get(m.group(1), 0) + int(m.group(2))
    have = state.get("inventory") or {}
    leather = short.get("Leather", 0)
    hides = max(0, leather - int(have.get(HIDE, 0) or 0))
    bones = short.get("Animal Bone", 0)
    parts = []
    kill = luis("kill cow") * max(hides / 15, bones / 14)  # his 74 s window: 15 hides, 14 bones
    if kill:
        parts.append(f"'kill cow' {luis('kill cow')} s x max({hides} hides/15, {bones} bones/14) = {kill:.0f} s")
    tan = 0.0
    if leather:
        own = any(re.search(r"tann", str(x.get("name") or ""), re.I) and x.get("mine") for x in state.get("structures") or [])
        build = 0.0 if own else luis("make tannery") - 17.8  # his 17.8 s stand was the leather processing
        tan = build + 17.8 / 3 * leather
        parts.append(f"tannery {'(his own: no build) ' if own else f'build {build:.1f} s + '}{17.8 / 3:.1f} s x {leather} leather")
    n = len([o for o in tg["pieces"] if o["status"] != "owned"])
    arm = (luis("make armour") / 2 + g.MOVE_S) * n
    if n:
        parts.append(f"'make armour' {luis('make armour')} s / 2 per piece + an equip, x {n}")
    walk = 0.0
    pos = state.get("position") or [0, 0]
    for _, o in tg["fetch"]:
        m = re.search(r"\((-?\d+),(-?\d+)\)", " ".join(o["where"]))
        if m:
            d = ((float(m.group(1)) - pos[0]) ** 2 + (float(m.group(2)) - pos[1]) ** 2) ** 0.5
            walk += 2 * d / LUIS_RUN_MS + 2.0 + g.MOVE_S
            parts.append(f"fetch {o['name']} from {o['where'][0]}: {d:.0f} m there and back at his {LUIS_RUN_MS:.1f} m/s + 2 s open + an equip")
    t = kill + tan + arm + walk
    return t, "; ".join(parts) or "nothing short"


def gear_work(t0: float):
    """A stand is work while a station he started runs (rung3), his gather job swings, or the body logs a fight
    (combat: lines in the client log; the target of a hide hunt is not a spawned creature the leg tracks)."""
    proc = r3.processing_work(t0)
    cache: list[float] = []

    def fights() -> list[float]:
        if not cache:
            from datetime import datetime
            path = g.ROOT / "logs" / "client" / "client.log"
            try:
                with open(path, "rb") as f:
                    f.seek(max(0, path.stat().st_size - 3_000_000))
                    text = f.read().decode("utf-8", "replace")
            except OSError:
                text = ""
            for ln in text.splitlines():
                if "combat:" in ln and "ai action" not in ln and ln[:4].isdigit():
                    try:
                        cache.append(datetime.fromisoformat(ln[:20].replace("Z", "+00:00")).timestamp())
                    except ValueError:
                        pass
            cache.append(-1.0)  # read once
        return cache

    def work(a, b):
        return proc(a, b) or r3.gather_work(a, b) or any(a - 1 <= x <= b + 1 for x in fights())
    return work


FALL_DROP_M, FALL_NEAR_M, FALL_WINDOW_S = 2.5, 15.0, 4.0


def hazards() -> list[dict]:
    """The client's recorded fall-death spots (navmem, world "dev"): [{at: [x, y, z], n, drop_m}]."""
    try:
        return json.loads((g.ROOT / "data" / "skills" / "dev" / "nav_memory.json").read_text(encoding="utf-8")).get("hazards") or []
    except (OSError, ValueError):
        return []


def fall_guard(spots: list[dict]):
    """Main 2026-11-02: the post-stop drift at the world edge is not fixed, so a window ends (and his action is
    stopped) on a z drop of more than 2.5 m within 4 s, within 15 m of a recorded drop, or on a death there."""
    hist: list[tuple[float, list]] = []

    def near(p) -> dict | None:
        return next((h for h in spots if ((h["at"][0] - p[0]) ** 2 + (h["at"][1] - p[1]) ** 2) ** 0.5 <= FALL_NEAR_M), None)

    def guard(ctx, m: dict) -> None:
        p = m.get("position")
        if ctx.abort or not (isinstance(p, list) and len(p) >= 3):
            return
        now = time.time()
        hist.append((now, p))
        del hist[:-30]
        h = near(p)
        if not h:
            return
        top = max(q[2] for t, q in hist if now - t <= FALL_WINDOW_S)
        why = None
        if m.get("dead"):
            why = f"fall guard: he died {((h['at'][0] - p[0]) ** 2 + (h['at'][1] - p[1]) ** 2) ** 0.5:.1f} m from the recorded drop at {h['at'][:2]}"
        elif top - p[2] > FALL_DROP_M:
            why = f"fall guard: z dropped {top - p[2]:.1f} m in {FALL_WINDOW_S:.0f} s within {FALL_NEAR_M:.0f} m of the recorded drop at {h['at'][:2]}"
        if why:
            ctx.abort = why
            try:
                ctx.cli.request("stop", {}, timeout=10)
            except Exception:  # noqa: BLE001
                pass
    return guard


def it_gear_up(ctx) -> dict:
    from brain.stash import Stash
    preflight_char(ctx)
    ctx.held_rows, ctx.abort = True, None
    ctx.hazard_guard = fall_guard(hazards())
    r3.place(ctx, SPOT["armour"])
    full_hp(ctx)
    state = cp._data(ctx.cli.request("get_state", {}, timeout=20))
    stash = Stash(g.ROOT / "logs" / "state" / "worlds" / WORLD / "containers.json").labels()
    tg = gear_target(state, stash)
    t_h, t_how = gear_up_t_h(tg, state)
    graves0 = [x.get("position") for x in state.get("graves_remembered") or []]
    deadline = max(600.0, 2.5 * t_h)
    time.sleep(1.0)
    row = g.run_leg(ctx, {"id": "gear_up", "kind": "r4_gear",
                          "check_text": f"his worn armour reaches PL {tg['pl']} (the best full set he can reach, gear_plan "
                                        f"at the start) and he holds kit of PL {tg['kit'] or 'what he has'}"},
                    LINES["gear_up"], {"pl": tg["pl"], "kit": tg["kit"]}, deadline_s=deadline, sample=("me", "inv"))
    ctx.hazard_guard, aborted, ctx.abort = None, ctx.abort, None
    after = cp._data(ctx.cli.request("get_state", {}, timeout=20))
    graves1 = [x.get("position") for x in after.get("graves_remembered") or []]
    p = tg["plan"]
    best = {s: [o["name"] for o in v["best"][:3]] for s, v in p["slots"].items() if v["best"]}
    note = (f"target from gear_plan at the start: armour PL {tg['pl_now']} -> {tg['pl']}, kit {tg['kit']}; best per slot "
            f"{best}; containers remembered {list(stash) or 'none'}; graves at the start {graves0}, at the end {graves1} "
            f"(the 16:37 grave sits 0.6 m from a 42 m drop: movement's guard says path_blocked/known_drop); "
            f"T_h {t_h:.0f} s = {t_how}; no fixtures" + (f"; ENDED BY {aborted}" if aborted else ""))
    row.setdefault("how", "")
    row["how"] += f"; his graves at the start {graves0}, at the end {graves1}"
    return g.finish(ctx, "gear_up", [row], t_h, allowed=1, work=gear_work(row["rec"]["t0"]), note=note)


def it_bag(ctx) -> dict:
    """Movement 2026-11-02: he is encumbered (407.7 of 400) since the gear_up grave runs. One natural line, no
    fixture: he stores or drops what he likes. T_h: Luis's run to Claude's nearest own crate and back + an open + a
    drag per stack that left his bag (his recorded drag gap), or one drag per dropped stack when no crate is near."""
    preflight_char(ctx)
    ctx.carry_rows, ctx.abort = True, None
    ctx.hazard_guard = fall_guard(hazards())
    c0 = carry()
    if not c0:
        raise RuntimeError("no carry weight read (encumbrance component)")
    if not c0["over"] and c0["cur"] <= c0["max"]:
        return {"item": "bag", "pass": False, "fails": ["infra"], "why": f"not over his carry weight: {c0['cur']:.1f} of {c0['max']:.0f}"}
    state = cp._data(ctx.cli.request("get_state", {}, timeout=20))
    pos = state.get("position") or [0, 0]
    crates = [((x["position"][0] - pos[0]) ** 2 + (x["position"][1] - pos[1]) ** 2) ** 0.5 for x in state.get("structures") or []
              if x.get("mine") and re.search(r"crate|chest|box", str(x.get("name") or ""), re.I) and isinstance(x.get("position"), list)]
    near = min(crates) if crates else None
    row = g.run_leg(ctx, {"id": "bag", "kind": "r4_carry", "check_text": "his carry weight is at or under his max"},
                    LINES["bag"], {}, deadline_s=240, sample=("me", "inv"))
    ctx.hazard_guard, ctx.carry_rows, aborted, ctx.abort = None, False, ctx.abort, None
    moved = sum(1 for k, v in (_bag_delta(row["rec"]) or {}).items() if v < 0 and not k.startswith(("carry:", "worn:", "held:")))
    # no crate of his own in reach: a chest built on the spot (Luis's 'crafting table and firepit': 2 pieces in 11 s)
    build = 0.0 if near is not None and near < 40 else luis("crafting table and firepit") / 2
    t_h = (2 * near / LUIS_RUN_MS if build == 0.0 else build) + 2.0 + max(1, moved) * g.MOVE_S + 1.5
    c1 = carry()
    walk = (f" + {near:.0f} m there and back at Luis's {LUIS_RUN_MS:.1f} m/s" if build == 0.0 else
            f" + a chest built ({build:.1f} s: Luis's 'crafting table and firepit' / 2)") + " + 2 s open"
    note = (f"carry {c0['cur']:.1f}/{c0['max']:.0f} -> " + (f"{c1['cur']:.1f}/{c1['max']:.0f}" if c1 else "?")
            + f"; his nearest own crate {near and round(near, 1)} m; T_h = 1.5 s reaction{walk}"
            + f" + {max(1, moved)} drag(s) x {g.MOVE_S} s; no fixtures" + (f"; ENDED BY {aborted}" if aborted else ""))
    return g.finish(ctx, "bag", [row], t_h, allowed=1, note=note)


RUNNERS4 = {"tannery": it_tannery, "armour": it_armour, "bow": it_bow, "spells": it_spells, "gear_up": it_gear_up,
            "bag": it_bag}


class _Lock:  # rung1_gate's run loop takes the lock as "rung1": this gate's owner is "rung4"
    held = staticmethod(lambda owner, wait_s=1800.0: live_lock.held("rung4", wait_s=wait_s))
    read = staticmethod(live_lock.read)


def main(argv=None) -> int:
    g.ITEMS[:] = ITEMS4
    g.RUNNERS.clear()
    g.RUNNERS.update(RUNNERS4)
    g.OUT, g.WORLD, g.live_lock, g.Ctx = OUT, WORLD, _Lock, Ctx4
    if argv is None:
        argv = sys.argv[1:]
    if argv and argv[0] == "plan":
        for k, v in LINES.items():
            t = T_H[k]()
            print(f"  {k:<9} {v!r:<66} T_h {round(t, 1) if t else 'per run'}" + (" s" if t else ""))
        print(f"live lock: {live_lock.read() or 'free'}; cost ~2-8 Haiku calls per item + 1 judge call per leg")
        return 0
    if argv and argv[0] == "run" and "--world" not in argv:
        argv = [*argv, "--world", WORLD]
    return g.main(argv)


if __name__ == "__main__":
    raise SystemExit(main())
