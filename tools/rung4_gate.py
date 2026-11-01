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
         "spells": "claude kill that goblin with your attack spells"}
ITEMS4 = ["tannery", "armour", "bow", "spells"]
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
       "spells": lambda: 1.5 + g.unit("kill")}


# ------------------------------------------------------------------ context: worn gear counts as carried
class Ctx4(g.Ctx):
    """rung1's Ctx, whose inventory rows also carry his loadout: worn gear as "worn:<name>" (the armour check sees a
    crafted piece go from the bag onto him; an equipped piece leaves the bag), and the Ammo / MagicAmmo stacks under
    their own names with their counts when no bag stack of that item is listed (the slot references a bag stack, so
    it is counted once; the compact inventory reply keeps only the slot's name). Held items are hotbar references,
    already counted."""
    def stacks(self) -> list[dict]:
        d = cp._data(self.cli.request("inventory", {"raw": True}, timeout=20))
        rows = [{"name": r.get("name") or r.get("item"), "item": r.get("item"), "count": r.get("count")}
                for where in ("hotbar", "bag") for r in d.get(where) or [] if isinstance(r, dict)]
        for r in d.get("loadout") or []:
            slot = str(r.get("loadout_slot") or r.get("slot") or "") if isinstance(r, dict) else ""
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


cp.CHECK_HOOKS.update({"r4_all": check_all, "r4_wear": check_wear, "r4_kill": check_kill_with})


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


def shed(ctx, item: str, name_rx: str) -> list[str]:
    """Copies of the item under test he carries or wears (name_rx on display names) go off him and are dropped at
    DUMP (fixture), so he starts without one, as Luis did."""
    rx = re.compile(name_rx, re.I)
    inv = cp.inventory(ctx.cli)
    worn = [(s, n) for s, n in (inv.get("worn") or {}).items() if n and rx.search(str(n))]
    for slot, _ in worn:
        ctx.cli.request("unequip", {"slot": slot}, timeout=20)
    rows = [r for r in cp.inv_rows(cp.inventory(ctx.cli)) if rx.search(str(r.get("name") or ""))]
    if not rows:
        return [f"took off {[n for _, n in worn]}"] if worn else []
    r3.place(ctx, DUMP)
    out = []
    for r in rows:
        res = ctx.cli.request("drop", {"item": r.get("item"), "count": int(r.get("count") or 1)}, timeout=30)
        out.append(f"dropped {r.get('count') or 1} {r.get('name')} at the respawn point"
                   + ("" if (res or {}).get("ok") else f" (failed: {(res or {}).get('reason')})"))
    left = [r.get("name") for r in cp.inv_rows(cp.inventory(ctx.cli)) if rx.search(str(r.get("name") or ""))]
    if left:
        raise RuntimeError(f"could not drop his {left} before the item")
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
    res = dev.setup("spawn", purpose=purpose, **{"class": cls, "offset_m": off})
    tgt = {"server_id": res.get("id"), "spawn_m": round((off[0] ** 2 + off[1] ** 2) ** 0.5, 1)}
    for _ in range(10):
        time.sleep(0.5)
        new = [x for x in cen() if x.get("id") not in before and re.search(name_rx, str(x.get("name")), re.I)]
        if new:
            tgt.update(id=new[0]["id"], name=new[0].get("name"))
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
    t_h = T_H["spells"]()
    return g.finish(ctx, "spells", [row], t_h, allowed=1, work=fight_work(row),
                    note=f"T_h = 1.5 + Luis's kill unit {g.unit('kill')} s (no Luis staff fight recorded); "
                         f"fixtures: {', '.join(fixtures) or 'none'}")


RUNNERS4 = {"tannery": it_tannery, "armour": it_armour, "bow": it_bow, "spells": it_spells}


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
            print(f"  {k:<9} {v!r:<66} T_h {round(T_H[k](), 1)} s")
        print(f"live lock: {live_lock.read() or 'free'}; cost ~2-8 Haiku calls per item + 1 judge call per leg")
        return 0
    if argv and argv[0] == "run" and "--world" not in argv:
        argv = [*argv, "--world", WORLD]
    return g.main(argv)


if __name__ == "__main__":
    raise SystemExit(main())
