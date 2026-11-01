"""Options with costs for a pressing food or drink need (rung 1, "eat and drink by comparing options").

Perception with numbers, never a ranking (CLAUDE.md "No phrase->skill mappings"; PRINCIPLES #2): for food and water
this lists every way the game offers right now, each with
  gives   what one item restores, from the game's own data (data/food_values_<build>.json: the live DT_FoodSustenance /
          DT_DrinkHydration rows read by client_mod/commands/food_values_probe.lua, the wiki as fallback),
          and how much of that he can get here;
  where   carried (hotbar or bag), his own grave (in sight or remembered), the ground, a bush, a station, a creature
          in perception, a water source, with the distance;
  steps   what he would do, with a time estimate at a real player's pace (data/baselines/luis-<date>.json: travel
          6.25 m/s, kill ~19.8 s per creature, cook ~15.8 s, a pickup ~1.1 s per item; walking pace when exhausted);
  risk    the body's fight odds and his HP, Soulscourge, the chance to burn at his Cooking level, where he died.
Option groups always come in the same fixed order (carried, graves, ground, gather, cook, hunt, water, craft, ask)
and nothing is sorted by value, so the model compares and chooses. Creatures in sight that drop no food are named
once ("no food from: Kebbit") because that is the fact that saves the wasted trip (Luis: kebbits drop no meat).

Why (co-play 2026-11-01, docs/ISSUES-2026-11-01-coplay.md D1/D2; competence map section 3): food showed as the label
"Sustenance", options had no time or risk, creatures never appeared, and the line was cut at 560 characters, so
"low food -> berries" was the only plan he could see, even with 16 Forager's Sandwiches in his newest grave.
"""
from __future__ import annotations

import json
import math
import re
from contextvars import ContextVar
from functools import lru_cache
from pathlib import Path

from . import knowledge
from .map_memory import lines_for
from .situation import feel, num as _num

DIGEST_CHARS = 2000  # the whole food or drink digest (head + options), bounded
OPTION_CHARS = 360  # one option line (a hunt with its odds and burn chance is ~330)
MAX_PER_GROUP = 2
NEAR_STATION_M = 60.0  # a campfire this close counts as "the fire you'd use"
PEOPLE_M = 40.0

# Pace fallbacks (seconds / metres per second) when no baseline file is present: data/baselines/luis-2026-11-01.json.
PACE_DEFAULT = {"travel_mps": 6.25, "kill_s": 19.84, "cook_s": 15.75, "pickup_s": 1.12, "build_s": 3.81}
EAT_S = 6.0  # one eat/drink: the ~6 s use animation, a second press during it is ignored (DISCOVERIES consumables #9)
TAKE_ALL_S = 2.0  # open a grave + Take All (one interact)
# each further item at a Campfire: the model count x mean(8, 12) s / ProcessingRate 5 = 2 s (DISCOVERIES l. 696); the live
# boil 2026-11-01 13:10 took 33 s for 6 Dirty Water (DISCOVERIES l. 2372), ~3.5 s each after Luis's 15.8 s first cook
PROCESS_EXTRA_S = 3.0
CAMPFIRE_STONE = 6  # BUILDPIECE_Campfire costs 6 Stone (live, DISCOVERIES l. 1791 / 2249)
EXHAUSTED_MPS = 2.0  # walking at endurance 0 (co-play 2026-11-01: 1.6-2.2 m/s on every trip)
AT_ZERO = "at 0 you lose 1 HP a second down to 1 HP, where any hit kills you"  # the survival agent's live read (needs.py)
# Soulscourge (toxicity): a full bar (100) deals 50 damage (wiki Soulscourge; survival agent, needs.WATER_SOURCE)
SOUL_FULL, SOUL_DAMAGE = 100.0, 50

# wiki Culinary Confidence (rev 61907): ingredient power level -> (Cooking level the tier starts, % no-burn gained per
# level above it); the tier starts at 50 % no-burn and caps at 100 %.
CULINARY = {1: (1, 4.55), 2: (12, 3.85), 3: (27, 3.57), 4: (41, 4.55), 5: (50, 2.0), 6: (75, 2.08)}


@lru_cache(maxsize=2)
def values(path: str | None = None) -> dict:
    """data/food_values_<build>.json (tools/gen_food_values.py), {} when absent."""
    if path is None:
        newest = knowledge.newest(knowledge.data_dir(), "food_values")
        if newest is None:
            return {}
        path = str(newest)
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


@lru_cache(maxsize=2)
def pace(path: str | None = None) -> dict:
    """Per-unit human times from the newest data/baselines/luis-*.json (tools/standard_score.py writes it)."""
    out = dict(PACE_DEFAULT)
    if path is None:
        files = sorted((knowledge.data_dir() / "baselines").glob("luis-*.json"))
        if not files:
            return out
        path = str(files[-1])
    try:
        d = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return out
    fam = d.get("families") or {}
    for key, family in (("kill_s", "kill"), ("cook_s", "cook"), ("pickup_s", "pickup"), ("build_s", "build")):
        v = (fam.get(family) or {}).get("unit_s")
        if isinstance(v, (int, float)) and v > 0:
            out[key] = float(v)
    if isinstance(d.get("travel_speed_mps"), (int, float)) and d["travel_speed_mps"] > 0:
        out["travel_mps"] = float(d["travel_speed_mps"])
    return out


def _fmt_s(s: float) -> str:
    s = max(1, int(round(s)))
    return f"{s} s" if s < 90 else f"{s / 60:.1f} min".replace(".0 min", " min")


def _m(d) -> str:
    return f"{d:.0f} m" if isinstance(d, (int, float)) else "? m"


class _Ctx:
    def __init__(self, state: dict, cat: dict, fv: dict, pc: dict):
        self.state, self.cat, self.fv, self.pace = state, cat, fv, pc
        self.items = cat.get("items") or {}
        self.vals = fv.get("items") or {}
        self.names = {}
        for iid, e in self.items.items():
            n = str((e or {}).get("name") or "").lower()
            if n and (n not in self.names or iid in self.vals):
                self.names[n] = iid
        exhausted = state.get("exhausted") is True or (_num(state.get("endurance")) == 0 and _num(state.get("endurance_max")))
        self.exhausted = bool(exhausted)
        self.mps = EXHAUSTED_MPS if self.exhausted else pc["travel_mps"]
        self.cooking = next((int(s.get("level")) for s in state.get("skills") or []
                             if isinstance(s, dict) and s.get("skill") == "Cooking" and isinstance(s.get("level"), (int, float))), None)
        hp, mx = _num(state.get("health")), _num(state.get("max_health"))
        self.hp_pct = (100 * hp / mx if mx else (100 * hp if hp is not None and hp <= 1 else None)) if hp is not None else None
        self.inv = {k: v for k, v in (state.get("inventory") or {}).items() if isinstance(v, (int, float))}

    def walk_s(self, d) -> float:
        return (d / self.mps) if isinstance(d, (int, float)) else 0.0

    def name(self, iid: str | None) -> str:
        return str(((self.items.get(iid) or {}).get("name")) or (self.vals.get(iid) or {}).get("name") or iid)

    def val(self, iid: str | None) -> dict:
        return self.vals.get(iid) or {}

    def kind(self, iid: str | None) -> str | None:
        return self.val(iid).get("kind")

    def station(self, sid: str) -> dict:
        return (self.cat.get("stations") or {}).get(sid) or {}

    def fire(self) -> dict | None:
        """The nearest Campfire or Grill he can use: stations_nearby, else an interactable of that class."""
        best = None
        classes = {c for s in ("Campfire", "Grill") for c in self.station(s).get("class_names") or []}
        for row in self.state.get("stations_nearby") or []:
            if isinstance(row, dict) and row.get("station") in ("Campfire", "Grill") and isinstance(row.get("distance"), (int, float)):
                if best is None or row["distance"] < best["distance"]:
                    best = {"name": row.get("name") or row.get("station"), "station": row.get("station"),
                            "id": row.get("id"), "distance": row["distance"], "position": row.get("position")}
        for t in self.state.get("interactables") or []:
            if isinstance(t, dict) and t.get("class") in classes and isinstance(t.get("distance"), (int, float)):
                if best is None or t["distance"] < best["distance"]:
                    best = {"name": "Campfire" if "Campfire" in str(t.get("class")) else t.get("name"),
                            "station": "Campfire" if "Campfire" in str(t.get("class")) else "Grill",
                            "id": t.get("id"), "distance": t["distance"], "position": t.get("position") or t.get("actor_position")}
        return best if best and best["distance"] <= NEAR_STATION_M else None

    def fuel(self, station: str) -> str | None:
        """'' when the station needs none; the carried fuel ('Ash Logs x38'); None when he carries none."""
        acc = self.station(station).get("accepted_fuels") or []
        if not acc:
            return ""
        for f in acc:
            if self.inv.get(f):
                return f"{self.name(f)} x{int(self.inv[f])}"
        return None

    def fuel_near(self, station: str) -> str | None:
        """The nearest accepted fuel lying in sight ('Oak Logs on the ground 5 m'), for when he carries none."""
        acc = set(self.station(station).get("accepted_fuels") or [])
        best = None
        for src, where in (("nearby_items", "on the ground"), ("nearby_resources", "to pick up")):
            for r in self.state.get(src) or []:
                ok = isinstance(r, dict) and r.get("item") in acc and r.get("available") is not False
                if ok and isinstance(r.get("distance"), (int, float)) and (best is None or r["distance"] < best[0]):
                    best = (r["distance"], f"{r.get('name') or self.name(r['item'])} {where} {r['distance']:.0f} m")
        return best[1] if best else None

    def burn(self, recipe: dict) -> str | None:
        """The chance to burn this cook at his Cooking level (wiki Culinary Confidence), from the recipe's burn attribute."""
        attr = str(((recipe or {}).get("burn_attr")) or "")
        m = re.search(r"Level(\d)", attr)
        if not m:
            return None
        pl = int(m.group(1))
        start, per = CULINARY.get(pl, (None, None))
        if start is None or self.cooking is None:
            return f"may burn (a power level {pl} ingredient)"
        if self.cooking < start:
            return f"burns most times: a power level {pl} ingredient needs Cooking {start} (you have {self.cooking})"
        no_burn = min(100.0, 50.0 + per * (self.cooking - start))
        return None if no_burn >= 100 else f"burn ~{100 - no_burn:.0f}% each at your Cooking {self.cooking}"


def _soul_risk(c: "_Ctx", v: dict, n: int = 1) -> str | None:
    """What n of this item does to his Soulscourge bar (a full bar deals 50 damage), from his toxicity when known."""
    per = v.get("soulscourge")
    if not per:
        return None
    tox = _num(c.state.get("toxicity"))
    if tox is None and isinstance(c.state.get("survival"), dict) and isinstance(c.state["survival"].get("toxicity"), list):
        tox = _num(c.state["survival"]["toxicity"][0])
    left = math.ceil(max(0.0, SOUL_FULL - tox) / per) if tox is not None else math.ceil(SOUL_FULL / per)
    return (f"+{per:g} Soulscourge each: {left} {'more ' if tox else ''}fill the bar for {SOUL_DAMAGE} damage"
            + (f" (bar now {tox:.0f})" if tox is not None else ""))


def _gives(v: dict, need: str) -> str:
    bits = []
    if need == "food" and v.get("sustenance") is not None:
        bits.append(f"+{v['sustenance']:g} food")
    if need == "drink" and v.get("hydration") is not None:
        bits.append(f"+{v['hydration']:g} water")
    if v.get("heal"):
        bits.append(f"+{v['heal']:g} HP")
    if need == "food" and v.get("hydration"):
        bits.append(f"+{v['hydration']:g} water")
    if need == "drink" and v.get("sustenance"):
        bits.append(f"+{v['sustenance']:g} food")
    if v.get("soulscourge"):
        bits.append(f"+{v['soulscourge']:g} Soulscourge")
    return " ".join(bits) or "value unknown"


def _pts(v: dict, need: str) -> float:
    x = v.get("sustenance" if need == "food" else "hydration")
    return float(x) if isinstance(x, (int, float)) else 0.0


def _eat_n(gap: float | None, per: float, have: int) -> int:
    """How many to eat to fill the gap (all of them when the gap is unknown), at most what he has."""
    if per <= 0 or gap is None:
        return have
    return max(1, min(have, math.ceil(gap / per)))


def _got(gap: float | None, x: float) -> float:
    """What an option adds toward full (capped at the gap to full), so options compare on gain against time."""
    return round(min(gap, x) if gap is not None else x)


WORD = {"food": "food", "drink": "water"}
# (current, max, the eat/drink-below line in %, drain per minute or None) of the need being digested, set by digest()
_LEVEL: ContextVar[tuple | None] = ContextVar("needs_options_level", default=None)


def _lead(t: float | None, gain: float | None, need: str) -> str:
    """The comparable part, first on every option: [~time -> +gain, the level after, how long it lasts]. Haiku at low
    effort read the option text and took the first one named (eval 14:57-15:05Z); the outcome up front compares."""
    if gain is None:
        return ""
    bits = [f"+{gain:g} {WORD.get(need, need)}"]
    lv = _LEVEL.get()
    if lv and lv[0] is not None and lv[1]:
        cur, mx, line_pct, rate = lv
        after = min(mx, cur + gain)
        bits.append(f"to {100 * after / mx:.0f}%")
        if rate:
            bits.append(f"lasts ~{max(0, round((after - mx * line_pct / 100) / rate))} min")
    return f"[{'~' + _fmt_s(t) + ' -> ' if t is not None else ''}{', '.join(bits)}] "


def _line(what: str, gives: str, where: str, steps: str, t: float | None, risk: str | None,
          gain: float | None = None, need: str = "food") -> str:
    """One option: [~time -> +gain, level after, lasts] what: gives | where | steps | risk (the same columns for every
    option, so they compare). Without a gain the time stays on the steps."""
    lead = _lead(t, gain, need)
    tail = f" ~{_fmt_s(t)}" if t is not None and not lead else ""
    s = f"- {lead}{what}: {gives} | {where} | {steps}{tail} | risk: {risk or 'none known'}"
    return s if len(s) <= OPTION_CHARS else s[:OPTION_CHARS - 1] + "…"


def _parse_contents(rows) -> list[tuple[str, int]]:
    out = []
    for c in rows or []:
        m = re.match(r"\s*(.+?)\s+x(\d+)\s*$", str(c))
        out.append((m.group(1), int(m.group(2))) if m else (str(c).strip(), 1))
    return out


# ---------------------------------------------------------------------------------------------- option groups


def _carried(c: _Ctx, need: str, gap: float | None) -> list[str]:
    out, raw = [], []
    line = reflex_under_line(c.state, need)
    pick = None  # the reflex's own pick under the line: the first clean one of that kind on the bar, by slot (best())
    if line is not None:
        bar = [r for r in c.state.get("inventory_items") or [] if isinstance(r, dict) and r.get("where") == "hotbar"
               and (r.get("consumable") if isinstance(r.get("consumable"), str) else c.val(r.get("item")).get("kind")) == need
               and c.val(r.get("item")) and not _soul_risk(c, c.val(r.get("item")))]
        pick = min(bar, key=lambda r: r.get("slot") if isinstance(r.get("slot"), (int, float)) else 99, default=None)
    for r in c.state.get("inventory_items") or []:
        if not isinstance(r, dict) or r.get("where") not in ("hotbar", "bag"):
            continue
        iid, n = r.get("item"), int(r.get("count") or 1)
        v = c.val(iid)
        kind = r.get("consumable") if isinstance(r.get("consumable"), str) else v.get("kind")
        if kind != need or not v:
            continue
        k = _eat_n(gap, _pts(v, need), n)
        verb = "drink" if need == "drink" else "eat"
        if r.get("where") == "hotbar":
            steps, t = f"{verb} {k} (one per use)", k * EAT_S
            if r is pick:
                # the reflex's own (live 16:20Z: it drank Clean Water while he queued one too; his ran ~6 s later, when
                # he was over the line already, and held up his second Fillet)
                steps += f"; your reflex is already {verb}ing these by itself, one every ~6 s, until you're over your {line:.0f}% line"
        else:
            # he uses what he moved himself: a move_item of food/drink holds the reflex for that kind while his use
            # follows (inventory.lua REFLEX_HOLD_S.move). The old "your reflex uses one within ~2 s, nothing more to
            # do" contradicted that hold: he moved both and stood 6.5 s until the hold ran out (rung 1 gate, live
            # 19:26Z, 16.9 s against a 9.1 s bar)
            steps, t = f"move_item to the hotbar, then {verb} {k}", 2.0 + k * EAT_S
        risk = _soul_risk(c, v)
        out.append(_line(f"carried {r.get('name') or c.name(iid)} x{n} ({r['where']})", _gives(v, need) + " each",
                         "on you", steps, t, risk, _got(gap, k * _pts(v, need)), need))
    return out or ["- carried: nothing that restores " + ("water" if need == "drink" else "food")]


def _grave_food(c: _Ctx, need: str, pairs) -> list[tuple[str, str, int, dict]]:
    """(item id, name, count, values) for the food/drink rows of a grave (ids, else names via the catalog)."""
    out = []
    for iid, name, n in pairs:
        iid = iid or c.names.get(str(name).lower())
        v = c.val(iid)
        if v and v.get("kind") == need:
            out.append((iid, name or c.name(iid), n, v))
    return out


def _graves(c: _Ctx, need: str, gap: float | None) -> list[str]:
    out = []
    ld = c.state.get("last_death") if isinstance(c.state.get("last_death"), dict) else {}
    g = c.state.get("my_grave") if isinstance(c.state.get("my_grave"), dict) else None
    seen = None
    if g:
        seen = g.get("id")
        rows = _grave_food(c, need, [(None, n, k) for n, k in _parse_contents(g.get("contents"))])
        if rows:
            out.append((g.get("distance"), f"your grave in sight (id {g.get('id')})", rows, None))
    for gv in c.state.get("graves_remembered") or []:
        if not isinstance(gv, dict) or (seen and gv.get("grave_id") == seen):
            continue
        rows = _grave_food(c, need, [(x.get("item"), x.get("name"), int(x.get("count") or 1))
                                     for x in gv.get("lost_ids") or [] if isinstance(x, dict)])
        if not rows:
            continue
        newest = isinstance(ld.get("ago_s"), (int, float)) and isinstance(gv.get("ago_s"), (int, float)) \
            and abs(gv["ago_s"] - ld["ago_s"]) < 30
        risk = None
        if newest:
            why = f"fell {ld['fell_m']:.0f} m" if isinstance(ld.get("fell_m"), (int, float)) else ld.get("killed_by")
            ago = int(ld["ago_s"])
            risk = f"you died there {ago // 60} min ago" if ago >= 120 else f"you died there {ago} s ago"
            risk += f" ({why})" if why else ""
        out.append((gv.get("distance"), f"your grave (go_to '{gv.get('go_to') or 'my_grave'}')", rows, risk))
    lines = []
    for dist, label, rows, risk in sorted(out, key=lambda x: x[0] if isinstance(x[0], (int, float)) else 1e9)[:MAX_PER_GROUP]:
        best = max(rows, key=lambda r: _pts(r[3], need))
        what = ", ".join(f"{name} x{n} ({_gives(v, need)} each)" for _, name, n, v in rows[:3])
        k = _eat_n(gap, _pts(best[3], need), best[2])
        steps = f"walk {_m(dist)}, Take All (gets your gear back too), {'drink' if need == 'drink' else 'eat'} {k} {best[1]}"
        t = c.walk_s(dist) + TAKE_ALL_S + k * EAT_S
        risk = "; ".join(x for x in (risk, _soul_risk(c, best[3])) if x) or None
        lines.append(_line(label, what, f"{_m(dist)} away", steps, t, risk,
                           _got(gap, k * _pts(best[3], need)), need))
    return lines


def _ground(c: _Ctx, need: str, gap: float | None) -> list[str]:
    rows = []
    for gi in c.state.get("nearby_items") or []:
        if not isinstance(gi, dict):
            continue
        v = c.val(gi.get("item"))
        if v.get("kind") == need:
            rows.append(gi)
    rows.sort(key=lambda r: r.get("distance") if isinstance(r.get("distance"), (int, float)) else 1e9)
    out = []
    for gi in rows[:MAX_PER_GROUP]:
        v, n = c.val(gi.get("item")), int(gi.get("count") or 1)
        k = _eat_n(gap, _pts(v, need), n)
        out.append(_line(f"{gi.get('name') or c.name(gi.get('item'))} x{n} on the ground (id {gi.get('id')})",
                         _gives(v, need) + " each", _m(gi.get("distance")),
                         f"walk, pick up (~{c.pace['pickup_s']:.0f} s), eat {k}",
                         c.walk_s(gi.get("distance")) + c.pace["pickup_s"] + k * EAT_S, None, _got(gap, k * _pts(v, need)), need))
    return out


def _node_yield(c: _Ctx, item: str) -> int:
    """Items per Collect from the wiki node whose drops are this item (Redberry Bush: 3)."""
    for node in (c.fv.get("nodes") or {}).values():
        for d in node.get("drops") or []:
            if d.get("item") == item and d.get("chance") == 1.0 and isinstance(d.get("qty"), (int, float)):
                return int(d["qty"])
    return 1


def _locked(c: _Ctx, rid: str, held: bool) -> bool:
    """A recipe he can't use: not in his unlocks (when the body sent them), unless it unlocks by itself on picking up its
    own input (the game's "ALL ITEMS[ <input> ]" bundles; Fillet unlocks on the first Raw Bird Meat) and he doesn't hold
    that input yet."""
    unlocked = c.state.get("recipes_unlocked")
    if not isinstance(unlocked, list) or rid in unlocked:
        return False
    if held:
        return True
    r = (c.cat.get("recipes") or {}).get(rid) or {}
    names = {str(i.get("name")) for i in r.get("inputs") or []}
    bundles = (r.get("unlock") or {}).get("bundles") or []
    auto = bundles and all(not b.get("manual") and re.fullmatch(r"ALL ITEMS\[\s*(.+?)\s*\]", str(b.get("query") or ""))
                           and re.fullmatch(r"ALL ITEMS\[\s*(.+?)\s*\]", str(b.get("query"))).group(1) in names for b in bundles)
    return not auto


def _cook_of(c: _Ctx, iid: str, need: str, held: bool = False) -> tuple[dict, dict] | None:
    """(cook recipe, output values) for a raw item that a Campfire/Grill turns into something of this need."""
    for rec in (c.fv.get("cooks") or {}).get(iid) or []:
        if not set(rec.get("stations") or []) & {"Campfire", "Grill"} or _locked(c, rec.get("recipe"), held):
            continue
        v = c.val(rec.get("output"))
        if v.get("kind") == need and _pts(v, need) > 0:
            return rec, v
    return None


def _burn_risk(c: _Ctx, rec: dict, need: str) -> str | None:
    """The burn chance at his Cooking level, with what a burnt one still gives (the recipe's burnt alternative)."""
    b = c.burn(rec)
    if not b:
        return None
    alt = (((c.cat.get("recipes") or {}).get(rec.get("recipe")) or {}).get("alternative") or {}).get("item")
    v = c.val(alt)
    return b + (f" (burnt: {_gives(v, need)})" if v else "")


def _fuel_note(c: _Ctx, fire: dict) -> tuple[str, bool, bool]:
    """(the fuel words, fuel lies in sight (one more pickup), no fuel at all) for this fire."""
    fuel = c.fuel(fire["station"])
    if fuel == "":
        return "needs no fuel", False, False
    if fuel:
        return f"fuel: {fuel} on you", False, False
    near = c.fuel_near(fire["station"])
    return (f"fuel: none on you, {near}", True, False) if near else ("fuel: none on you or in sight (logs or planks)", False, True)


def _stone(c: _Ctx) -> tuple[int, list]:
    """(Stone he carries, Stone lying in sight) for a Campfire build."""
    lying = [r for k in ("nearby_items", "nearby_resources") for r in c.state.get(k) or []
             if isinstance(r, dict) and r.get("item") == "ITEM_Resources_Stone" and r.get("available") is not False]
    return int(c.inv.get("ITEM_Resources_Stone", 0)), lying


def fire_line(c: _Ctx) -> str:
    """The one fire every cook option means, or what building one takes (named once, so the options stay short)."""
    fire = c.fire()
    if fire:
        words, _, _ = _fuel_note(c, fire)
        return f"- the fire: {fire['name']} {_m(fire.get('distance'))} (id {fire.get('id')}); {words}"
    stone, lying = _stone(c)
    more = ""
    if lying and stone < CAMPFIRE_STONE:
        more = f"; Stone x{len(lying)} to pick in sight, nearest {_m(min((r.get('distance') or 1e9) for r in lying))}"
    return (f"- the fire: no Campfire within 60 m; building one takes {CAMPFIRE_STONE} Stone (you carry {stone}{more}) "
            f"and ~{c.pace['build_s']:.0f} s, then logs or planks as fuel")


def _fire_steps(c: _Ctx, fire: dict | None, n: int, extra_walk: float | None = None) -> tuple[str, float, str | None]:
    """Steps and seconds to cook n items at the fire (load, fuel, cook, collect), and a blocker note."""
    extra = c.pace["cook_s"] + PROCESS_EXTRA_S * max(0, n - 1)
    if not fire:
        stone, lying = _stone(c)
        short = max(0, CAMPFIRE_STONE - stone)
        return (f"build the fire, cook {n}", c.pace["build_s"] + extra + (short * c.pace["pickup_s"] if lying else 0),
                None if not short or lying else "short of Stone for a fire")
    _, pick, none = _fuel_note(c, fire)
    walk = extra_walk if extra_walk is not None else fire.get("distance")
    steps = f"cook {n} at the fire" + (" (grab the fuel first)" if pick else "")
    return steps, c.walk_s(walk) + extra + (c.pace["pickup_s"] if pick else 0), ("no fuel" if none else None)


def _gather(c: _Ctx, need: str, gap: float | None) -> list[str]:
    """Things to pick in sight that are food as they are (bushes) or cook into it (cabbage, potato): raw when edible,
    cooked/dried at a fire when a recipe exists. Ids are the nearest one's (gather / interact take them)."""
    groups: dict[str, list] = {}
    for r in c.state.get("nearby_resources") or []:
        if isinstance(r, dict) and r.get("item") and (c.val(r["item"]).get("kind") == need or _cook_of(c, r["item"], need)):
            groups.setdefault(r["item"], []).append(r)
    out = []
    fire = c.fire()
    near_first = sorted(groups.items(), key=lambda kv: min((r.get("distance") or 1e9) for r in kv[1]))
    for iid, rows in near_first[:MAX_PER_GROUP + 1]:
        rows.sort(key=lambda r: r.get("distance") if isinstance(r.get("distance"), (int, float)) else 1e9)
        ready = [r for r in rows if r.get("available") is not False]
        per = _node_yield(c, iid)
        v = c.val(iid) if c.val(iid).get("kind") == need else {}
        name = rows[0].get("name") or c.name(iid)
        if not ready:
            out.append(_line(f"{name} x{len(rows)} in sight", (_gives(v, need) + " each") if v else "cook it first",
                             _m(rows[0].get("distance")), "all picked: they regrow later", None, None))
            continue
        n_items = per * len(ready)
        near, rid = ready[0].get("distance"), ready[0].get("id")
        label = f"{name} x{len(ready)} to pick (nearest id {rid})"
        if v:
            k = _eat_n(gap, _pts(v, need), n_items)
            presses = math.ceil(k / per)
            spread = max((r.get("distance") or 0) for r in ready[:presses])
            out.append(_line(label, f"{per} per pick, raw {_gives(v, need)} each ({n_items} here = +{_pts(v, need) * n_items:g})",
                             f"nearest {_m(near)}", f"gather {presses}, eat {k}",
                             c.walk_s(spread) + presses * c.pace["pickup_s"] + k * EAT_S, None,
                             _got(gap, k * _pts(v, need)), need))
            label = f"{c.name((_cook_of(c, iid, need) or ({}, {}))[0].get('output'))} from them"
        ck = _cook_of(c, iid, need)
        if ck:
            rec, cv = ck
            kc = _eat_n(gap, _pts(cv, need), n_items)
            pc_ = math.ceil(kc / per)
            spread = max((r.get("distance") or 0) for r in ready[:pc_])
            steps, t_cook, block = _fire_steps(c, fire, kc)
            risk = "; ".join(x for x in (_burn_risk(c, rec, need), block) if x) or None
            if v:
                gives = f"{_gives(cv, need)} each"
            else:
                gives = f"{_gives(cv, need)} each as {c.name(rec['output'])}" + (f" ({n_items} here)" if n_items > 1 else "")
            out.append(_line(label, gives,
                             f"nearest {_m(near)}, then the fire", f"gather {pc_}, {steps}, eat {kc}",
                             c.walk_s(spread) + pc_ * c.pace["pickup_s"] + t_cook + kc * EAT_S, risk,
                             _got(gap, kc * _pts(cv, need)), need))
    return out


def _cook(c: _Ctx, need: str, gap: float | None) -> list[str]:
    """Raw things he carries (or has on the ground near him) that a fire turns into food/clean water."""
    fire = c.fire()
    out = []
    for iid, n in sorted(c.inv.items(), key=lambda kv: kv[0]):
        ck = _cook_of(c, iid, need, held=True) if n > 0 else None
        if not ck:
            continue
        rec, cv = ck
        if c.val(iid).get("kind") == need and _pts(cv, need) <= _pts(c.val(iid), need):
            continue  # edible as it is and cooking adds nothing: only in "carried" (picked berries keep their drying)
        k = _eat_n(gap, _pts(cv, need), int(n))
        steps, t, block = _fire_steps(c, fire, k)
        risk = "; ".join(x for x in (_burn_risk(c, rec, need), block) if x) or None
        verb = "drink" if need == "drink" else "eat"
        out.append(_line(f"cook your {c.name(iid)} x{int(n)} -> {c.name(rec['output'])}",
                         f"{_gives(cv, need)} each", "the fire",
                         f"{steps}, {verb} {k}", t + k * EAT_S, risk, _got(gap, k * _pts(cv, need)), need))
    return out[:MAX_PER_GROUP + 1]


def _creature_key(c: _Ctx, e: dict) -> str | None:
    cr = c.fv.get("creatures") or {}
    low = {k.lower(): k for k in cr}
    for k in (e.get("name"), e.get("kind")):
        if k and str(k).lower() in low:
            return low[str(k).lower()]
    return None


def _hunt(c: _Ctx, need: str, gap: float | None) -> list[str]:
    """Creatures in perception whose drops cook into (or are) food: per kill value, the trip, the body's fight odds."""
    if need != "food":
        return []
    cr = c.fv.get("creatures") or {}
    groups: dict[str, list] = {}
    for e in c.state.get("nearby_entities") or []:
        if isinstance(e, dict) and e.get("alive") is not False and (k := _creature_key(c, e)):
            groups.setdefault(k, []).append(e)
    odds = c.state.get("fight_odds") if isinstance(c.state.get("fight_odds"), dict) else {}
    fire = c.fire()
    out, no_food = [], []
    for key, ents in sorted(groups.items(), key=lambda kv: min((e.get("distance") or 1e9) for e in kv[1])):
        ents.sort(key=lambda e: e.get("distance") if isinstance(e.get("distance"), (int, float)) else 1e9)
        per_kill, items_per_kill, gives, recs = 0.0, 0.0, [], []
        for d in cr[key].get("drops") or []:
            iid, ch = d.get("item"), d.get("chance") or 0
            q = d.get("qty") if isinstance(d.get("qty"), (int, float)) else 1
            ck = _cook_of(c, iid, need)
            v = ck[1] if ck else (c.val(iid) if c.val(iid).get("kind") == need else None)
            if not v or ch <= 0:
                continue
            per_kill += _pts(v, need) * q * ch
            items_per_kill += q * ch
            recs.append(ck[0] if ck else None)
            gives.append(f"{c.name(ck[0]['output']) if ck else c.name(iid)} {_gives(v, need)}"
                         + ("" if q == 1 else f" x{q:g}") + ("" if ch >= 1 else f" ({ch:.0%})"))
        if per_kill <= 0:
            drops = ", ".join(dict.fromkeys(d.get("name") for d in cr[key].get("drops") or [] if d.get("name")))
            no_food.append(f"{key} x{len(ents)} (drops {drops})" if drops else f"{key} x{len(ents)}")
            continue
        if len(out) >= MAX_PER_GROUP:
            continue
        e0 = ents[0]
        kills = max(1, min(len(ents), math.ceil(gap / per_kill))) if gap else 1
        n_cook = max(1, math.ceil(items_per_kill * kills))
        back = None
        if fire and isinstance(fire.get("position"), list) and isinstance(e0.get("position"), list):
            back = math.dist(fire["position"][:2], e0["position"][:2])
        steps_fire, t_fire, block = _fire_steps(c, fire, n_cook, extra_walk=back)
        t = c.walk_s(e0.get("distance")) + kills * (c.pace["kill_s"] + len(gives) * c.pace["pickup_s"]) + t_fire + n_cook * EAT_S
        o = odds.get(str(e0.get("id"))) if isinstance(odds.get(str(e0.get("id"))), dict) else {}
        verdict = o.get("verdict")
        prep = (o.get("prepared") or {}).get("verdict") if isinstance(o.get("prepared"), dict) else None
        risk = [f"PL {e0.get('power_level')}" if e0.get("power_level") is not None else "",
                "hostile" if e0.get("hostile") else ("aggressive" if cr[key].get("aggressive") else "passive"),
                f"odds now {verdict.replace('_', ' ')}" if verdict else "",
                f"prepared {prep.replace('_', ' ')}" if prep and prep != verdict else "",
                f"you are at {c.hp_pct:.0f}% HP" if c.hp_pct is not None and c.hp_pct < 60 else "",
                "; ".join(x for x in dict.fromkeys(_burn_risk(c, r, need) for r in recs if r) if x), block or ""]
        out.append(_line(f"hunt {key} x{len(ents)} (nearest {_m(e0.get('distance'))}, id {e0.get('id')})",
                         f"per kill, cooked: {', '.join(gives)} = +{per_kill:g} food", "in sight",
                         f"kill {kills} (~{c.pace['kill_s']:.0f} s each), loot, {steps_fire}, eat",
                         t, ", ".join(x for x in risk if x), _got(gap, kills * per_kill), need))
    if no_food:
        out.append("- no food from: " + "; ".join(no_food[:3]))
    return out


def _water(c: _Ctx, need: str, gap: float | None) -> list[str]:
    """Water sources in perception: collect Dirty Water (drinkable, Soulscourge), or boil it at a fire."""
    if need != "drink":
        return []
    src = None
    for t in c.state.get("interactables") or []:
        if isinstance(t, dict) and ("WaterVolume" in str(t.get("class") or t.get("id") or "")
                                    or "collect water" in str(t.get("prompt") or "").lower()):
            if isinstance(t.get("distance"), (int, float)) and (src is None or t["distance"] < src["distance"]):
                src = t
    if not src:
        return []
    dirty = c.names.get("dirty water")
    v = c.val(dirty)
    k = _eat_n(gap, _pts(v, need), 99)
    t_collect = c.walk_s(src["distance"]) + k * c.pace["pickup_s"]
    out = [_line(f"collect Dirty Water at {src.get('name') or 'water'} (id {src.get('id')})", _gives(v, need) + " each",
                 _m(src["distance"]), f"collect_water {k}, drink {k}", t_collect + k * EAT_S, _soul_risk(c, v),
                 _got(gap, k * _pts(v, need)), need)]
    ck = _cook_of(c, dirty, need)
    if ck:
        rec, cv = ck
        kc = _eat_n(gap, _pts(cv, need), 99)
        fire = c.fire()
        back = math.dist(fire["position"][:2], src["position"][:2]) if fire and isinstance(fire.get("position"), list) \
            and isinstance(src.get("position"), list) else None
        steps, t, block = _fire_steps(c, fire, kc, extra_walk=back)
        out.append(_line(f"boil it -> {c.name(rec['output'])}", _gives(cv, need) + " each", "the fire",
                         f"collect_water {kc}, {steps}, drink {kc}",
                         c.walk_s(src["distance"]) + kc * c.pace["pickup_s"] + t + kc * EAT_S, block,
                         _got(gap, kc * _pts(cv, need)), need))
    return out


def _remembered(c: _Ctx, need: str, gap: float | None) -> list[str]:
    """Sources seen before, beyond sight (the per-world map memory, BUGS L21), as seen then."""
    rem = c.state.get("remembered") if isinstance(c.state.get("remembered"), dict) else {}
    out = []
    for r in [x for x in rem.get(need) or [] if isinstance(x, dict)][:MAX_PER_GROUP]:
        seen = lines_for({"remembered": {need: [r]}}, [need])[0]
        t = c.walk_s(r.get("distance"))
        steps, gain, risk = "go_to it, then look", None, "it may have changed since"
        if need == "drink" and "collect water" in str(r.get("prompt") or "").lower():
            v = c.val(c.names.get("dirty water"))
            k = _eat_n(gap, _pts(v, need), 99)
            steps = f"go_to it, collect_water {k}, drink {k} (or boil it at a fire)"
            t += k * (c.pace["pickup_s"] + EAT_S)
            gain = _got(gap, k * _pts(v, need))
            risk = "; ".join(x for x in (_soul_risk(c, v), risk) if x)
        out.append(_line(f"remembered: {seen}", "as seen then", _m(r.get("distance")), steps, t, risk, gain, need))
    return out


def _craft(c: _Ctx, need: str, gap: float | None) -> list[str]:
    """Recipes at other stations (ranges, kiln, ...) he can make now or is one ingredient short of; the Campfire/Grill
    cooks are the options above."""
    unlocked = c.state.get("recipes_unlocked")
    unlocked = set(unlocked) if isinstance(unlocked, list) else None
    rows = []
    for rid, r in (c.cat.get("recipes") or {}).items():
        ins, outs, sids = r.get("inputs") or [], r.get("outputs") or [], r.get("stations") or []
        if not ins or not outs or not sids or (unlocked is not None and rid not in unlocked):
            continue
        if len(ins) == 1 and set(sids) & {"Campfire", "Grill"}:
            continue  # a fire cook: listed above
        v = c.val(outs[0].get("item"))
        if v.get("kind") != need or r.get("vendor_reputation") or any(
                c.station(s).get("vendor") or "Vendor" in str((c.station(s).get("row") or {}).get("table")) for s in sids):
            continue  # a vendor's trade (DT_VendorDataTable rows), not a recipe
        missing = [(i, int(i.get("count") or 1) - int(c.inv.get(i.get("item"), 0))) for i in ins]
        missing = [(i, n) for i, n in missing if n > 0]
        if len(missing) > 1:
            continue
        rows.append((len(missing), rid, r, v, missing, sids))
    out = []
    for _, rid, r, v, missing, sids in sorted(rows, key=lambda x: x[0])[:MAX_PER_GROUP]:
        st = " or ".join(dict.fromkeys(str(c.station(s).get("display_name") or s) for s in sids))
        what = "all inputs carried" if not missing else f"missing {missing[0][1]} {missing[0][0].get('name')}"
        out.append(_line(f"craft {outs_name(c, r)} (recipe {rid})", _gives(v, need) + " each", f"at a {st}",
                         what, None, None))
    return out


def outs_name(c: _Ctx, r: dict) -> str:
    o = (r.get("outputs") or [{}])[0]
    return str(o.get("name") or c.name(o.get("item")))


def _ask(c: _Ctx, need: str = "", gap: float | None = None) -> list[str]:
    ps = [f"{p['name']} ({_m(p.get('distance'))})" for p in c.state.get("players") or []
          if isinstance(p, dict) and p.get("name") and isinstance(p.get("distance"), (int, float)) and p["distance"] <= PEOPLE_M]
    return [f"- ask a player: {', '.join(ps)}"] if ps else []


GROUPS = (_carried, _graves, _ground, _gather, _cook, _hunt, _water, _remembered, _ask, _craft)


def gap(state: dict, need: str) -> tuple[float | None, float | None, float | None]:
    """(current, max, points to full) of the need's stat (food: sustenance, drink: hydration)."""
    stat = "sustenance" if need == "food" else "hydration"
    cur, mx = _num(state.get(stat)), _num(state.get(f"{stat}_max"))
    return cur, mx, (max(0.0, mx - cur) if cur is not None and mx else None)


def reflex_under_line(state: dict, need: str) -> float | None:
    """His line (% of max) when the body reports its stay-fed reflex running and the need is under that line: it then
    uses the first clean food/drink of that kind on his hotbar by itself (inventory.lua: a 2 s tick, one per kind
    per ~6 s, first by slot in best()), until the stat is back over the line. None otherwise."""
    pol = state.get("vitals_policy") if isinstance(state.get("vitals_policy"), dict) else {}
    if pol.get("reflex_on") is not True:
        return None
    cur, mx, _ = gap(state, need)
    line = _num(pol.get("eat_below_pct" if need == "food" else "drink_below_pct"))
    return line if cur is not None and mx and line is not None and cur < mx * line / 100.0 else None


def digest(state: dict, need: dict, cat: dict, fv: dict | None = None, pc: dict | None = None) -> str:
    """One bounded block for a pressing food or drink need: the head (how bad, how much to full) and its options."""
    fv = fv if fv is not None else values()
    c = _Ctx(state, cat, fv, pc or pace())
    kind = need["need"]
    cur, mx, short = gap(state, kind)
    word = feel(kind, need.get("pct"))
    head = f"Need {kind} ({word + ', ' if word else ''}[{need['pct']:.0f}%]" if need.get("pct") is not None else f"Need {kind} ("
    if cur is not None and mx:
        head += f", {cur:.0f}/{mx:.0f}, {short:.0f} to full"
    if need.get("zero_min") is not None:
        head += f", empty in ~{need['zero_min']} min at the current drain"
        head += f"; {AT_ZERO}"  # with the clock, as needs.lines says it
    head += ")"
    pace_note = f"walking pace {EXHAUSTED_MPS:g} m/s: you are exhausted" if c.exhausted else f"a player's pace, {c.mps:g} m/s"
    stat = "sustenance" if kind == "food" else "hydration"
    pol = state.get("vitals_policy") if isinstance(state.get("vitals_policy"), dict) else {}
    line_pct = float(pol.get("eat_below_pct" if kind == "food" else "drink_below_pct") or 40)
    rates = state.get("vitals_rate") if isinstance(state.get("vitals_rate"), dict) else {}
    rate = _num(rates.get(f"{stat}_per_min"))
    head += (f" -> options as [~time at {pace_note} -> what it adds, your level after"
             + (f", how long until you're under your {line_pct:.0f}% line again at the current drain" if rate and rate > 0 else "")
             + "] what: gives | where | steps | risk; compare them and choose:")
    tok = _LEVEL.set((cur, mx, line_pct, rate if rate and rate > 0 else None))
    lines = []
    fl = fire_line(c)
    try:
        for grp in GROUPS:
            try:
                lines.extend(grp(c, kind, short))
            except Exception as exc:  # perception is best effort: one broken group never hides the others
                lines.append(f"- ({grp.__name__.strip('_')} options unavailable: {type(exc).__name__})")
    finally:
        _LEVEL.reset(tok)
    uses_fire = next((i for i, ln in enumerate(lines) if "the fire" in ln), None)
    if uses_fire is not None:  # named once, just before the first option that needs it (never ahead of what he carries:
        lines.insert(uses_fire, fl)  # live 15:50Z it led both blocks and he promised "then i'll sort a fire")
    if not fv.get("items"):
        lines.append("- (no food value data loaded: values unknown)")
    out, used = [head], len(head)
    for ln in lines:
        if used + 1 + len(ln) > DIGEST_CHARS:
            out.append(f"- (+{len(lines) - len(out) + 1} more options cut)")
            break
        out.append(ln)
        used += 1 + len(ln)
    return "\n".join(out)


def options_for(state: dict, kind: str, cat: dict | None = None) -> str:
    """The digest for one need on demand, pressing or not (the food_options read tool: he asks "what can we eat?",
    the model infers it wants this; no phrase table)."""
    from . import needs  # lazy: needs imports this module lazily too
    stat = "sustenance" if kind == "food" else "hydration"
    cur, mx, _ = gap(state, kind)
    pct = 100.0 * cur / mx if cur is not None and mx else None
    rates = state.get("vitals_rate") if isinstance(state.get("vitals_rate"), dict) else {}
    r = _num(rates.get(f"{stat}_per_min"))
    zero = round(cur / r) if cur is not None and r and r > 0 else None
    return digest(state, {"need": kind, "kinds": [kind], "pct": pct, "zero_min": zero},
                  cat if cat is not None else needs.catalog())


def pressing_digests(state: dict) -> list[str]:
    """The food/drink digests that situation shows right now (needs.lines), for a follow-up turn's observation: after
    a step changed what he carries (berries picked), the options are re-read, not remembered from the first turn
    (eval 16:27Z: he picked the berries for the Dried Redberries option, then the next turn ate them raw)."""
    from . import needs
    try:
        return [ln for ln in needs.lines(state) if ln.startswith(("Need food", "Need drink"))]
    except Exception:  # perception is best effort: a broken digest never breaks the turn
        return []


def startup_lows(state: dict) -> list:
    """The low-need events the body would send now (client_bridge.lua forward_vitals: hydration or sustenance under
    the model's vitals_policy line, nothing for it on the hotbar), for a brain that has just started or reconnected.
    The body repeats its vitals_low only every 180 s, so the one it sent before the brain was listening was lost and
    he sat hungry for up to 3 min (live 15:17:44-15:20:40Z). Same event, same broker triage; nothing is decided here."""
    from .interface import VitalsLow
    from .situation import consumable_rows
    if not isinstance(state, dict) or state.get("unavailable"):
        return []
    pol = state.get("vitals_policy") if isinstance(state.get("vitals_policy"), dict) else {}
    hot = {k for k, r in consumable_rows(state) if r.get("where") == "hotbar"}
    out = []
    for stat, need, key in (("hydration", "drink", "drink_below_pct"), ("sustenance", "food", "eat_below_pct")):
        v, mx = _num(state.get(stat)), _num(state.get(f"{stat}_max")) or 100.0
        line = _num(pol.get(key)) or 15.0  # client_bridge: the policy line, else VITALS_LOW 15
        if v is None or v >= mx * line / 100.0 or need in hot:
            continue
        out.append(VitalsLow(stat=stat, value=v, max=mx, has_food="food" in hot, has_drink="drink" in hot))
    return out
