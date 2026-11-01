"""Preflight before a session with Luis (ISSUES F2/B12, 2026-11-01): is Claude fit to play?

  .venv\\Scripts\\python.exe -m tools.preflight            # human report; exit 0 = ready, 1 = refused (with the list)
  .venv\\Scripts\\python.exe -m tools.preflight --json     # the same as JSON
  .venv\\Scripts\\python.exe -m tools.preflight --fix      # dev server only: top up food/water (and HP under 30) via
                                                      # tools.supply.top_up, then check again. A harness fixture:
                                                      # never in survival/needs tests (they test self-sufficiency).

Read-only over the bridge's debug channel (get_state + bridge_status; nothing moves). It REFUSES with a list when:
  - the body doesn't answer, or he is dead;
  - health, water or food are low, or he carries too little food/drink to last a session;
  - rest (endurance) is under 25: the game then caps his stamina at 60 (40 at 0), caps food/water at 75 and drains
    them faster (dragonwilds.runescape.wiki/w/Rest; live read 2026-11-01: endurance 14.8, max stamina 60, maxes 75);
  - he holds no weapon and carries none, or wears no body armour;
  - an unrecovered grave from the last day still holds his items (co-play 2026-11-01: his gear sat in a grave);
  - the stay-fed reflex, vitals watcher or combat guard isn't running.
Why: co-play 2026-11-01 started at 0.5/100 HP with nothing to eat or drink and endurance 0 all session (B8, B12),
and nobody noticed for hours. Each failure names what to do.
"""
from __future__ import annotations

import argparse
import json
import sys
import time

from brain.situation import consumable_rows

MIN_HP_PCT = 60
MIN_STAT_PCT = 40  # water / food (the stay-fed policy default)
MIN_FOOD, MIN_DRINK = 3, 3  # usable items carried (hotbar or bag)
MIN_REST = 25  # the wiki's "Knackered" step
GRAVE_DAYS = 1.0
SERVICES = ("fed_reflex", "vitals", "combat_guard")


def _pct(cur, mx):
    try:
        return 100.0 * float(cur) / float(mx) if mx else float(cur)
    except (TypeError, ValueError):
        return None


def check(state: dict, status: dict | None = None, now: float | None = None) -> dict:
    """{ok, problems: [{check, detail, fix}], facts: {...}} from a client get_state (and bridge_status data)."""
    now = time.time() if now is None else now
    problems, facts = [], {}

    def bad(name, detail, fix):
        problems.append({"check": name, "detail": detail, "fix": fix})

    if not state or state.get("unavailable"):
        bad("body", f"no game state ({(state or {}).get('unavailable') or 'no answer'})", "boot the client: tools/client_boot.ps1")
        return {"ok": False, "problems": problems, "facts": facts}
    if state.get("dead"):
        bad("alive", "he is dead", "respawn him, then recover his grave")
    hp = _pct(state.get("health"), state.get("max_health"))
    facts["health_pct"] = hp
    if hp is not None and hp < MIN_HP_PCT:
        bad("health", f"health {hp:.0f}%", "eat healing food or rest before Luis joins")
    for stat, word in (("hydration", "water"), ("sustenance", "food")):
        p = _pct(state.get(stat), state.get(f"{stat}_max"))
        facts[f"{word}_pct"] = p
        facts[f"{word}_max"] = state.get(f"{stat}_max")
        if p is not None and p < MIN_STAT_PCT:
            bad(word, f"{word} {state.get(stat):.0f}/{state.get(f'{stat}_max'):.0f} ({p:.0f}%)",
                "drink clean water" if word == "water" else "eat")
    rows = consumable_rows(state)
    count = {"food": 0, "drink": 0}
    hotbar = {"food": 0, "drink": 0}
    for kind, r in rows:
        if kind in count:
            n = int(r.get("count") or 1)
            count[kind] += n
            if r.get("where") == "hotbar":
                hotbar[kind] += n
    facts["food_carried"], facts["drink_carried"] = count["food"], count["drink"]
    facts["food_on_hotbar"], facts["drink_on_hotbar"] = hotbar["food"], hotbar["drink"]
    if count["food"] < MIN_FOOD:
        bad("food_stock", f"{count['food']} food carried (need {MIN_FOOD}+)", "gather or cook food, or take it from his chest")
    if count["drink"] < MIN_DRINK:
        bad("drink_stock", f"{count['drink']} drinks carried (need {MIN_DRINK}+)",
            "collect water at a pond (collect_water) and boil it at a Campfire (craft Clean Water)")
    for kind in ("food", "drink"):
        if count[kind] and not hotbar[kind]:
            bad(f"{kind}_hotbar", f"his {kind} is all in the bag (only hotbar items can be used)", f"move_item a {kind} to the hotbar")
    rest = _pct(state.get("endurance"), state.get("endurance_max"))
    facts["rest_pct"] = rest
    facts["max_stamina"] = state.get("max_stamina")
    if rest is not None and rest < MIN_REST:
        bad("rest", f"rest (endurance) {rest:.0f}/100: max stamina {state.get('max_stamina')}, food/water capped at "
                    f"{state.get('sustenance_max')}/{state.get('hydration_max')}",
            "rest in a bed or a Summon Shelter (by day +1 a second; a night's sleep refills it)")
    held = state.get("held") or state.get("held_item")
    gear = state.get("gear") if isinstance(state.get("gear"), dict) else {}
    weapons = [r for r in state.get("inventory_items") or []
               if isinstance(r, dict) and "Weapon" in str(r.get("category") or "")]
    facts["held"] = held
    facts["weapons_carried"] = sorted({str(r.get("name") or r.get("item")) for r in weapons})
    if not held and not weapons:
        bad("weapon", "no weapon held or carried", "recover his grave or craft one")
    if not gear.get("Body"):
        bad("armour", "no body armour worn", "equip armour (or recover his grave)")
    facts["worn"] = {k: v for k, v in gear.items() if k in ("Head", "Body", "Legs", "Cape")}
    graves = []
    for g in state.get("graves_remembered") or []:
        if not isinstance(g, dict):
            continue
        ago = g.get("ago_s")
        if ago is None and isinstance(g.get("ts"), (int, float)):
            ago = now - g["ts"]
        if isinstance(ago, (int, float)) and ago <= GRAVE_DAYS * 86400 and (g.get("lost_items") or 0) > 0:
            graves.append(g)
    facts["recent_graves"] = [{"iso": g.get("iso"), "distance_m": g.get("distance"), "items": g.get("lost_items"),
                               "lost": (g.get("lost") or [])[:6], "go_to": g.get("go_to")} for g in graves]
    for g in graves:
        bad("grave", f"unrecovered grave from {g.get('iso')}, {g.get('distance')} m away: {', '.join((g.get('lost') or [])[:5])}",
            f"go_to {g.get('go_to')} and Take All")
    harmful = {k: v for k, v in (state.get("status_effects") or {}).items()
               if str(k).lower() in ("poison", "bleed", "burning", "soulscourge", "shocked")} \
        if isinstance(state.get("status_effects"), dict) else {}
    if harmful:
        bad("status", f"harmful status: {', '.join(harmful)}", "cure it (antipoison) or sleep it off")
    if status is not None:
        svc = status.get("services") if isinstance(status.get("services"), dict) else {}
        for name in SERVICES:
            st = (svc.get(name) or {}).get("state")
            if st != "running":
                bad("service", f"{name} is {st or 'missing'}", "restart the bridge services (client_mod/commands/bridge_start.lua)")
    return {"ok": not problems, "problems": problems, "facts": facts}


def _fetch() -> tuple[dict, dict | None]:
    from brain.bridge_client import BridgeClient
    from brain.transport import file_transport_pair
    brain_side, _ = file_transport_pair(body="client", channel="debug")
    c = BridgeClient(brain_side)
    st = c.request("get_state", {}, timeout=15)
    bs = c.request("bridge_status", {}, timeout=10)
    state = st.get("data") if st.get("ok") else {"unavailable": st.get("reason") or "get_state failed"}
    return state or {"unavailable": "empty state"}, (bs.get("data") if bs.get("ok") else None)


SUPPLY_FIXES = {"food_stock", "drink_stock", "health"}  # what tools.supply.top_up can mend (Luis 2026-11-01)


def _fix(r: dict) -> dict | None:
    """Top up through the dev fixture when only supply problems stand in the way of a test; None when none apply."""
    if not any(p["check"] in SUPPLY_FIXES for p in r["problems"]):
        return None
    from evals.bench.devrun import default_dev
    from tools.supply import top_up
    dev = default_dev()
    dev.brain_running = lambda: False  # a top-up between runs; the grant is guarded (dev server only, nobody else on)
    try:
        return top_up(dev, max(6, MIN_FOOD), max(6, MIN_DRINK), heal=True, purpose="preflight --fix")
    except Exception as exc:  # the fixture's guards raise (another player connected, not the dev server)
        return {"ok": False, "why": str(exc)}


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--fix", action="store_true", help="dev server: top up food/water (and HP) via tools.supply, recheck")
    a = ap.parse_args()
    state, status = _fetch()
    r = check(state, status)
    if a.fix:
        fixed = _fix(r)
        if fixed is not None:
            print("preflight --fix:", json.dumps(fixed))
            if fixed.get("ok"):
                time.sleep(3)  # the grant lands in his inventory; the reflex may eat/drink
                state, status = _fetch()
                r = check(state, status)
            r["fixed"] = fixed
    if a.json:
        print(json.dumps(r, indent=2))
    else:
        f = r["facts"]
        print("preflight:", "READY" if r["ok"] else f"REFUSED ({len(r['problems'])} problems)")
        pc = {k: (round(f[k]) if isinstance(f.get(k), (int, float)) else f.get(k)) for k in ("health_pct", "water_pct", "food_pct", "rest_pct")}
        print(f"  health {pc['health_pct']}%, water {pc['water_pct']}%, food {pc['food_pct']}%, rest {pc['rest_pct']}%"
              f" (max stamina {f.get('max_stamina')})")
        print(f"  carried: food {f.get('food_carried')} ({f.get('food_on_hotbar')} on hotbar), "
              f"drink {f.get('drink_carried')} ({f.get('drink_on_hotbar')} on hotbar)")
        print(f"  held {f.get('held')}, weapons {f.get('weapons_carried')}, worn {f.get('worn')}")
        print(f"  recent graves: {len(f.get('recent_graves') or [])}")
        for p in r["problems"]:
            print(f"  - {p['check']}: {p['detail']} -> {p['fix']}")
    sys.exit(0 if r["ok"] else 1)


if __name__ == "__main__":
    main()
