r"""Small real-model eval: does Claude pick a good food/water option when he can compare them (brain/needs_options.py)?

Four states, each from a REAL get_state of co-play session 1 (logs/brain-live-20261101-115554-7128.jsonl), edited
only where the case needs it (evals/fixtures/needs_options/*.json, written by `extract`):
  grave_food    11:19:45 for real: died 59 s before, food 42 %, nothing carried, his newest grave ~140 m off holding 16
                Forager's Sandwiches (+80 food each), berries 30 m. Live he said "grabbing berries first, starving".
                Pass = he goes for that grave first (go_to its target / interact it), not berries.
  hunt_cook     11:00 base: food 25 %, one bush with 3 berries, 3 Chickens 22-34 m (passive, PL1, "likely win"),
                Campfire 5 m, Ash Logs carried, no graves. Pass = he goes after a chicken (attack / go_to it).
  boil_water    11:00 base: water 20 % (food fine), 6 Dirty Water on the hotbar, Campfire 5 m, Ash Logs carried.
                Pass = he boils it (craft Clean Water / use the Campfire), not drinking it dirty first.
  urgent_raw    11:00 base: food 3 % (empty in ~1 min), HP 30 %, a ready bush 1 m, chickens 40 m, Campfire 30 m.
                Pass = he picks the berries first (gather / interact the bush).
One model call per sample (the Controller's first reply, as Controller.decide sends it, today's persona, tools and
situation digest), no tools run. Prints the planned call count and model, refuses without --yes, stops at --max-usd.

  .venv\Scripts\python.exe -m evals.needs_options_eval extract
  .venv\Scripts\python.exe -m evals.needs_options_eval show [--case hunt_cook]       # the digest, no model call
  .venv\Scripts\python.exe -m evals.needs_options_eval run --repeat 2 --yes          # 4 cases x 2 = 8 Haiku calls
"""
from __future__ import annotations

import argparse
import copy
import json
import os
import re
import sys
import tempfile
import time
from pathlib import Path

from brain import paths

ROOT = paths.REPO_ROOT
LOG = ROOT / "logs" / "brain-live-20261101-115554-7128.jsonl"
FIX = ROOT / "evals" / "fixtures" / "needs_options"
PLAYER = "luisdeburnaybast"
MODEL = "anthropic/claude-haiku-5-5"


def _states(path: Path) -> list[tuple[float, dict]]:
    out = []
    with path.open(encoding="utf-8") as f:
        for line in f:
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            if r.get("kind") == "bridge_recv":
                d = (r.get("msg") or {}).get("data")
                if isinstance(d, dict) and "inventory_items" in d:
                    out.append((r["ts"], d))
    return out


def _at(states, hhmmss: str) -> dict:
    import datetime as dt
    best = None
    for ts, d in states:
        t = dt.datetime.fromtimestamp(ts, dt.UTC).strftime("%H:%M:%S")
        if t <= hhmmss:
            best = d
    return copy.deepcopy(best)


def _entity(eid: str, pos, dist: float, name="Chicken", cls="BP_AI_Chicken_Character_C", hp=20.0) -> dict:
    return {"hostile": False, "alive": True, "position": pos, "distance": dist, "kind": name, "hp": hp,
            "archetype": "NeutralUntilAttacked", "attitude": "neutral", "alertness": "ambient", "id": eid, "class": cls,
            "max_health": hp, "name": name, "power_level": 1, "health": hp}


def _odds(verdict="likely_win") -> dict:
    return {"kill_s": 3, "pl_gap": 0.0, "verdict": verdict, "die_s": 40,
            "prepared": {"kill_s": 3, "verdict": verdict, "die_s": 60, "not_counted": "blocking, dodging, armour"}}


def _hotbar(item: str, name: str, n: int, kind: str, slot: int = 3) -> dict:
    return {"kind": "Item", "id": f"QuickAction:{slot}", "slot": slot, "count": n, "item": item, "name": name,
            "where": "hotbar", "slot_type": "QuickAction", "consumable": kind,
            **({"hydration": "Hydration"} if kind == "drink" else {"sustenance": "Sustenance"})}


def _offset(pos, dx, dy):
    return [round(pos[0] + dx, 2), round(pos[1] + dy, 2), pos[2]]


def build_cases(log: Path = LOG) -> dict[str, dict]:
    st = _states(log)
    cases = {}
    # 1. grave_food: the real 11:19:45 state (the berries-before-grave decision, ISSUES D2)
    g = _at(st, "11:19:45")
    cases["grave_food"] = {"state": g, "event": {"type": "situation_review", "changes": [
        {"what": "health", "now": "healthy", "from_pct": 0, "to_pct": 100, "direction": "up"}]},
        "expect": "the newest grave (16 Forager's Sandwiches)"}
    # 2-4: the 11:00 base (night, berries and a Campfire by the tent; luisdeburnaybast 4 m)
    base = _at(st, "11:00:30")
    me = base["position"]
    base.update({"hydration": 70.0, "hydration_max": 100.0, "sustenance_max": 100.0, "health": 100.0, "max_health": 100.0,
                 "endurance": 80.0, "endurance_max": 100.0, "exhausted": False, "max_stamina": 100.0})
    base["survival"] = {"hydration": [70.0, 100.0], "endurance": [80.0, 100.0], "sustenance": [50.0, 100.0]}
    base["graves_remembered"], base["death_memory"], base["my_grave"] = [], None, None
    base["last_death"] = None
    logs_row = {"kind": "Item", "id": "Inventory:5", "slot": 5, "count": 10, "item": "ITEM_Resources_Wood_Ash",
                "name": "Ash Logs", "where": "bag", "slot_type": "Inventory"}

    h = copy.deepcopy(base)
    h["sustenance"] = 25.0
    h["survival"]["sustenance"] = [25.0, 100.0]
    bush_rows = [r for r in h.get("nearby_resources") or [] if "Redberry" in str(r.get("class"))]
    for i, r in enumerate(bush_rows):
        r["available"] = i == 0
    chickens = [_entity(f"BP_AI_Chicken_Character_C_21474649{i}", _offset(me, 15 + 4 * i, 18 - 3 * i), d)
                for i, d in enumerate((22.0, 27.5, 33.8))]
    h["nearby_entities"] = chickens + (h.get("nearby_entities") or [])
    h["fight_odds"] = {**{c["id"]: _odds() for c in chickens}, **(h.get("fight_odds") or {})}
    h["inventory_items"] = (h.get("inventory_items") or []) + [logs_row]
    h["inventory"] = {**(h.get("inventory") or {}), "ITEM_Resources_Wood_Ash": 10}
    cases["hunt_cook"] = {"state": h, "event": {"type": "vitals_low", "stat": "sustenance", "feels": "hungry", "value": 25.0,
                                                "max": 100.0, "fixed_by": "food", "carrying_one": False},
                          "expect": "hunt a chicken (then cook)"}

    w = copy.deepcopy(base)
    w["sustenance"], w["hydration"] = 70.0, 20.0
    w["survival"].update({"sustenance": [70.0, 100.0], "hydration": [20.0, 100.0]})
    w["inventory_items"] = [r for r in w.get("inventory_items") or [] if r.get("item") != "ITEM_Consumable_Water_Dirty"] + [
        _hotbar("ITEM_Consumable_Water_Dirty", "Dirty Water", 6, "drink"), logs_row]
    w["inventory"] = {**(w.get("inventory") or {}), "ITEM_Consumable_Water_Dirty": 6, "ITEM_Resources_Wood_Ash": 10}
    cases["boil_water"] = {"state": w, "event": {"type": "vitals_low", "stat": "hydration", "feels": "thirsty", "value": 20.0,
                                                 "max": 100.0, "fixed_by": "drink", "carrying_one": True},
                           "expect": "boil the dirty water at the Campfire"}

    u = copy.deepcopy(base)
    u["sustenance"], u["health"] = 3.0, 30.0
    u["survival"]["sustenance"] = [3.0, 100.0]
    u["vitals_rate"] = {"sustenance_per_min": 2.5, "hydration_per_min": 1.5}
    far = [_entity(f"BP_AI_Chicken_Character_C_21474651{i}", _offset(me, 30 + 3 * i, 26), 40.0 + 3 * i) for i in range(2)]
    u["nearby_entities"] = far + (u.get("nearby_entities") or [])
    u["fight_odds"] = {**{c["id"]: _odds() for c in far}, **(u.get("fight_odds") or {})}
    for s in u.get("stations_nearby") or []:
        s["distance"] = 30.0
    for t in u.get("interactables") or []:
        if "Campfire" in str(t.get("class")):
            t["distance"] = 30.0
    for i, r in enumerate([r for r in u.get("nearby_resources") or [] if "Redberry" in str(r.get("class"))]):
        r["available"] = True
    cases["urgent_raw"] = {"state": u, "event": {"type": "vitals_low", "stat": "sustenance", "feels": "starving", "value": 3.0,
                                                 "max": 100.0, "fixed_by": "food", "carrying_one": False},
                           "expect": "pick the berries now (raw)"}
    return cases


# ------------------------------------------------------------------ scoring (on the first reply's tool calls)


def _ids(state: dict, pred) -> set[str]:
    out = set()
    for k in ("nearby_resources", "nearby_entities", "interactables", "stations_nearby"):
        for r in state.get(k) or []:
            if isinstance(r, dict) and pred(r):
                out.add(str(r.get("id")))
    return out


def score(case: str, calls: list[dict], state: dict) -> tuple[bool, str]:
    acts = [c for c in calls if c.get("name") not in ("say",)]
    if not acts:
        return False, "no action"
    first = acts[0]
    name, args = first.get("name"), first.get("arguments") or {}
    blob = json.dumps(args).lower()
    what = f"{name} {json.dumps(args)[:120]}"
    if case == "grave_food":
        newest = [g for g in state.get("graves_remembered") or [] if any(
            "Sandwich" in str(x.get("name")) for x in g.get("lost_ids") or [])]
        targets = {str(g.get("go_to")).lower() for g in newest} | {str(g.get("grave_id")).lower() for g in newest}
        ok = name in ("go_to", "interact") and (any(t in blob for t in targets if t != "none") or blob.strip('{}" ') in ("target: my_grave",)
                                                or '"my_grave"' in blob)
        return ok, what
    if case == "hunt_cook":
        chick = {i.lower() for i in _ids(state, lambda r: r.get("name") == "Chicken")}
        ok = any(c.get("name") in ("attack", "go_to") and (any(i in json.dumps(c.get("arguments") or {}).lower() for i in chick)
                                                          or "chicken" in json.dumps(c.get("arguments") or {}).lower())
                 for c in acts)
        # the other cooked detour (Dried Redberries, +45 food +60 HP in ~42 s) is a compared choice too; only the raw
        # +15 at 25% food is the failure this case is about
        fire = {i.lower() for i in _ids(state, lambda r: "Campfire" in str(r.get("class") or r.get("station")))}
        ok = ok or any((c.get("name") == "craft" and "dried" in json.dumps(c.get("arguments") or {}).lower())
                       or (c.get("name") == "interact" and any(i in json.dumps(c.get("arguments") or {}).lower() for i in fire))
                       for c in acts)
        return ok, what + (f" (+{len(acts) - 1} more: {[c.get('name') for c in acts[1:]]})" if len(acts) > 1 else "")
    if case == "boil_water":
        fire = {i.lower() for i in _ids(state, lambda r: "Campfire" in str(r.get("class") or r.get("station")))}
        ok = (name == "craft" and ("clean" in blob or "water_clean" in blob)) or (name == "interact" and any(i in blob for i in fire))
        return ok, what
    if case == "urgent_raw":
        bush = {i.lower() for i in _ids(state, lambda r: "Redberry" in str(r.get("class")))}
        ok = (name == "gather" and "berr" in blob) or (name == "interact" and any(i in blob for i in bush))
        return ok, what
    return False, what


# ------------------------------------------------------------------ commands


def cmd_extract(a) -> int:
    FIX.mkdir(parents=True, exist_ok=True)
    for k, c in build_cases(Path(a.log)).items():
        (FIX / f"{k}.json").write_text(json.dumps(c, indent=1, ensure_ascii=False) + "\n", encoding="utf-8", newline="\n")
        print(f"{k}: {c['expect']} -> {FIX / (k + '.json')}")
    return 0


def _load(only: str | None) -> dict[str, dict]:
    out = {}
    for f in sorted(FIX.glob("*.json")):
        if not only or f.stem == only:
            out[f.stem] = json.loads(f.read_text(encoding="utf-8"))
    return out


def cmd_show(a) -> int:
    from brain import needs
    sys.stdout.reconfigure(encoding="utf-8")
    for k, c in _load(a.case).items():
        print(f"===== {k} (expect: {c['expect']})")
        for line in needs.lines(c["state"]):
            print(line)
    return 0


def cmd_run(a) -> int:
    from brain.controller import Decision
    from brain.jsonl_log import JsonlLogger
    from brain.llm import missing_keys
    from tools import spend
    from tools.replay_first_call import body_caps, client_for, live_controller
    sys.stdout.reconfigure(encoding="utf-8")
    cases = _load(a.case)
    n = len(cases) * a.repeat
    print(f"[needs_options_eval] {len(cases)} cases x {a.repeat} = planned calls: {n} of {a.model} (no tools run); "
          f"stops at ${a.max_usd:.2f}")
    if n > 10 and not a.allow_more:
        print("Refusing: more than 10 calls (pass --allow-more).")
        return 2
    if missing_keys(a.model):
        print(f"Refusing: API key for {a.model} not set.")
        return 2
    if not a.yes:
        print("Refusing: pass --yes to confirm the API calls above.")
        return 2
    log = JsonlLogger(paths.log_dir() / "evals" / f"needs_options-{time.strftime('%Y%m%d-%H%M%S')}.jsonl")
    prices = spend.load_prices()
    spent, passed, rows = 0.0, 0, []
    caps = body_caps()
    llm = client_for(a.model)
    with tempfile.TemporaryDirectory() as tmp:
        ctl = live_controller(llm, PLAYER, Path(tmp) / "w", log, caps)
        for k, c in cases.items():
            for i in range(a.repeat):
                ctx = ctl.context(PLAYER, "", c["state"], None, addressed=True, body_event=c["event"])
                messages = [{"role": "system", "content": ctl.persona()},
                            {"role": "user", "content": json.dumps(ctx, default=str, ensure_ascii=False)}]
                t0 = time.monotonic()
                resp = ctl._complete(messages, ctl.tools, Decision(), step=0)
                dt = time.monotonic() - t0
                calls = [{"name": t.name, "arguments": t.arguments} for t in resp.tool_calls]
                ok, what = score(k, calls, c["state"])
                usd = spend.price(a.model, getattr(resp, "usage", None) or {}, prices)[0]
                spent += usd
                passed += ok
                say = next((cl["arguments"].get("text") for cl in calls if cl["name"] == "say"), None)
                row = {"case": k, "sample": i, "passed": ok, "first_action": what, "say": say, "latency_s": round(dt, 2),
                       "usd": round(usd, 5), "calls": calls, "content": getattr(resp, "content", None)}
                rows.append(row)
                log.log("needs_options_result", **row)
                print(f"  {k}[{i}] {'PASS' if ok else 'FAIL'} {dt:.1f}s  {what}  say={say!r}")
                if spent >= a.max_usd:
                    print(f"STOPPED: spend cap ${a.max_usd:.2f}")
                    break
    print(f"[needs_options_eval] {passed}/{len(rows)} passed; ${spent:.4f}; results {log.path}")
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("extract")
    e.add_argument("--log", default=str(LOG))
    s = sub.add_parser("show")
    s.add_argument("--case")
    r = sub.add_parser("run")
    r.add_argument("--case")
    r.add_argument("--repeat", type=int, default=1)
    r.add_argument("--model", default=os.environ.get("DW_CONTROLLER_MODEL") or MODEL)
    r.add_argument("--max-usd", type=float, default=0.5)
    r.add_argument("--yes", action="store_true")
    r.add_argument("--allow-more", action="store_true")
    a = ap.parse_args(argv)
    return {"extract": cmd_extract, "show": cmd_show, "run": cmd_run}[a.cmd](a)


if __name__ == "__main__":
    raise SystemExit(main())
