"""Long-job trials (docs/GOAL-2026-11-17-long-jobs.md section 1): one ask from a player carried to an end the GAME
STATE confirms, whole (L1 to L3, held-out H1 to H3) or with one interruption put in by the harness (I1 to I5).

    .venv\\Scripts\\python.exe -m tools.job_run trial --confirm --job L2 -k 3
    .venv\\Scripts\\python.exe -m tools.job_run trial --confirm --job L2 -k 1 --until first_step --save-as job_l2_mid
    .venv\\Scripts\\python.exe -m tools.job_run interrupt --confirm --step I3 --job L2 -k 5
    .venv\\Scripts\\python.exe -m tools.job_run rates            # pass rate and streak per job and per step; held-out apart
    .venv\\Scripts\\python.exe -m tools.job_run show RUN         # one run's scores (a held-out run's trace stays hidden)

What it reuses from tools/quest_run.py (by import, nothing copied): the lock window on forks of a checkpoint
(clone_window, quest_clone.fork, to_start, clock_on, park), the dirty-code refusal, the preflight, leave_dialogue, the
timeline of calls and stands, human_bar, and the miss rule (quest_run.verdict). From tools/chat_ladder.py: the brain
start and stop, the brain-log rows and the model calls and $. The dev fixtures are evals/bench DevTarget.setup.

What is new here: the jobs and their end predicates in data (data/jobs.json), read at the start and the end of a run
from get_state and from the body's own container reads; the interruption put in mid-job and the score for it (did he
take the job up again without a new line from the player, and how many seconds after); misses with kind, time and
call, per job and per 5 minutes of work, split by the interruption; and a held-out guard on reading traces.

Records: logs/evals/job_runs.jsonl (one per trial; failure_ledger finds them once the wiring diff in
docs/research/2026-11-17-long-job-harness.md is in), logs/evals/job_windows.jsonl (one per lock window).
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import math
import os
import sys
import time
from pathlib import Path
from typing import Any

from brain import paths

ROOT = paths.REPO_ROOT
JOBS = ROOT / "data" / "jobs.json"
OUT = ROOT / "logs" / "evals" / "job_runs.jsonl"
WINDOW_OUT = ROOT / "logs" / "evals" / "job_windows.jsonl"
# a window is stopped by creating this file, never by killing it: the trial ends "stopped" and the window still
# switches back to ClaudeDev (2026-11-17 18:04Z: a killed L2 window left the client on its fork, and the next
# window's fixtures took him for another player)
STOP_FILE = ROOT / "logs" / "job_run.stop"
STEPS = ("I1", "I2", "I3", "I4", "I5")
SAMPLE_S = 15.0       # a get_state read for the end predicate and the body's state, this often
CONFIRM_S = 60.0      # an interruption trial goes on this long after he took the job up again (it was not a blip)
TRACE_AFTER = 3       # the first three trials of anything are scored before its trace is read (goal: held-out)
RESPAWN_M = 20.0


# ------------------------------------------------------------------ the jobs
def load_jobs(path: Path | None = None) -> dict:
    return json.loads((path or JOBS).read_text(encoding="utf-8"))


def job_of(jid: str, doc: dict | None = None) -> dict:
    doc = doc or load_jobs()
    j = (doc.get("jobs") or {}).get(jid)
    if not j:
        raise SystemExit(f"no job {jid!r} in {JOBS.name} (have {', '.join(doc.get('jobs') or {})})")
    return {"id": jid, **j}


def matches(item: str | None, pattern: str) -> bool:
    """An item id against a pattern of fnmatch globs; '|' separates alternatives."""
    return bool(item) and any(fnmatch.fnmatchcase(str(item), p.strip()) for p in pattern.split("|"))


def count_of(counts: dict, pattern: str) -> int:
    return sum(int(n or 0) for k, n in (counts or {}).items() if matches(k, pattern))


# ------------------------------------------------------------------ what the game says (get_state, tool results)
# A body unfit to start (health, food or water under 40 % of their maximum, or dead, or unreadable): chat_ladder's
# check, which every window's preflight makes too; job_run also makes it per fork, before the walk to the job's start
# (2026-11-17 19:36Z: both forks of a starved ClaudeDev died to the first rat on that walk)
from tools.chat_ladder import FIT_PCT, body_unfit as unfit  # noqa: E402,F401


# Loadout slots that point at a stack he already carries in the hotbar or the bag: the Held slots reference a hotbar
# slot, the ammo slots a bag stack (DISCOVERIES 2026-11-01 rung 4 gate: "Arrows read as -22 because the loadout's
# Ammo slot references the bag stack"; tools/rung4_gate.Ctx4.stacks counts that stack once). Worn slots (Head, Body,
# Legs, Cape, Trinket) hold the piece itself and count.
REF_SLOTS = ("HeldRight", "HeldLeft", "Ammo", "MagicAmmo", "CrossbowBolts", "FishingBait")
# The pages a picked-up or granted item can land in: the hotbar first, then the item page (DISCOVERIES "Collect =
# the interact key": items landed in the first free hotbar slots; rung 1 gate: runes, ammo and quest items have
# pages of their own, and GetNumEmptySlots counts every page).
ROOM_PAGES = ("QuickAction", "InventoryItems")
# The census's kinds of a thing with a game component (client_mod/scripts/sense.lua FAMILIES, ACTOR_FAMILIES). Only
# "storage" is storage: an actor with an InventoryComponent and no station component (stations own inventories too).
CENSUS_KINDS = {"crafting_station", "processing_station", "enchanting_station", "bed", "lodestone", "container",
                "storage", "chest"}
# deconstruct.kind's marks of a station, a farm plot or a composter in the game's asset id or class
NOT_STORAGE_MARKS = ("Station", "BP_Crafting_", "Composter", "FarmPlot")


def _consumable_harm(item: str | None, kind: str) -> str | None:
    """None when the game's own data says one of these restores food or water and does no harm (no Soulscourge, no
    Wither: data/food_values_<build>.json, the live DT_FoodSustenance / DT_DrinkHydration / DT_Toxicity_V2 /
    DT_Wither_V2 rows); else why it does not count (Dirty Water: Soulscourge 20; burnt food: Soulscourge 20)."""
    from brain import needs_options
    v = ((needs_options.values() or {}).get("items") or {}).get(item or "")
    if not isinstance(v, dict) or v.get("kind") != kind:
        return f"no {kind} row in the game's food data"
    bad = [f"{k} {v[k]:g}" for k in ("soulscourge", "wither") if isinstance(v.get(k), (int, float)) and v[k] > 0]
    return ", ".join(bad) or None


def bag_room(d: dict | None) -> int | None:
    """Free slots a new kind of item can land in, from the raw inventory read (`inventory {raw: true}`): the hotbar
    and item pages' sizes (`pages`, "QuickAction:8", "InventoryItems:32") less the hotbar rows and the item-page bag
    rows. None when the pages were not read. Never GetNumEmptySlots, which counts the rune, ammo and quest pages too
    (164 live with a full item page, docs/research/2026-11-17-job-end-readability.md I4)."""
    d = d or {}
    if isinstance(d.get("data"), dict) and ("ok" in d):
        d = d["data"]
    size: dict[str, int] = {}
    for p in d.get("pages") or []:
        name, _, n = str(p).partition(":")
        if n.strip().isdigit():
            size[name.strip()] = int(n)
    if not all(p in size for p in ROOM_PAGES):
        return None
    used = sum(1 for w in ("hotbar", "bag") for r in d.get(w) or []
               if isinstance(r, dict) and (r.get("slot_type") or ("QuickAction" if w == "hotbar" else None)) in ROOM_PAGES)
    return max(0, sum(size[p] for p in ROOM_PAGES) - used)


def snapshot(data: dict | None) -> dict:
    """A get_state (or raw `inventory`) read in one shape: carried {item: n} over hotbar, bag and loadout, each stack
    once (a loadout slot that references a carried stack is not counted again); worn {slot: item} (Head, Body, Legs,
    HeldRight, held_right ...); consumables {food, drink} that do no harm, and the ones left out; position; dead;
    own_containers (ids get_state marks mine: the client's ledger of what he built); container_kinds {id: census
    kind}; empty_slots (the game's count over every page); bag_room (bag_room()); unread (why the read is not a
    reading of him: a failed get_state is never an empty character)."""
    d = data or {}
    if isinstance(d.get("data"), dict) and ("ok" in d):
        if d.get("ok") is False:
            d = {"unread": str(d.get("reason") or (d["data"].get("detail")) or "get_state failed")}
        else:
            d = d["data"]
    rows = d.get("inventory_items")
    if rows is None and any(k in d for k in ("hotbar", "bag", "loadout")):  # inventory {raw: true}
        rows = [{**r, "where": w} for w in ("hotbar", "bag", "loadout") for r in d.get(w) or []]
    carried: dict[str, int] = {}
    cons = {"food": 0, "drink": 0}
    left_out: dict[str, str] = {}
    worn: dict[str, str] = {}
    on_him = {r.get("item") or r.get("name") for r in rows or [] if r.get("where") != "loadout"}
    for r in rows or []:
        item = r.get("item") or r.get("name")
        n = int(r.get("count") or 1)
        slot = str(r.get("loadout_slot") or "")
        loadout = r.get("where") == "loadout"
        if item and not (loadout and slot.startswith(REF_SLOTS) and item in on_him):
            carried[item] = carried.get(item, 0) + n
        if loadout and slot and item:
            worn[slot] = item
        elif not loadout and r.get("consumable") in cons:
            harm = _consumable_harm(item, r["consumable"])
            if harm is None:
                cons[r["consumable"]] += n
            else:
                left_out[f"{n} {item}"] = harm
    if rows is None:
        carried = {k: int(v or 0) for k, v in (d.get("inventory") or {}).items()}
    for k, v in (d.get("gear") or {}).items():
        if v and k not in worn:
            worn[k] = v
    own = {str(e["id"]) for key in ("structures", "interactables") for e in d.get(key) or []
           if isinstance(e, dict) and e.get("mine") and e.get("id")}
    kinds = {str(e["id"]): str(e["kind"]) for key in ("interactables", "structures") for e in d.get(key) or []
             if isinstance(e, dict) and e.get("id") and e.get("kind") in CENSUS_KINDS}
    pl = d.get("power_level")
    unread = d.get("unread") or (None if rows is not None or d.get("inventory") or d.get("position") is not None
                                 else "the read carried no position and no inventory")
    out = {"carried": carried, "worn": worn, "consumables": cons, "position": d.get("position"),
           "dead": bool(d.get("dead")), "own_containers": sorted(own), "container_kinds": kinds,
           "empty_slots": d.get("empty_slots"), "bag_room": bag_room(d),
           "power_level": pl if isinstance(pl, (int, float)) and not isinstance(pl, bool) else None}
    if left_out:
        out["consumables_left_out"] = left_out
    if unread:
        out["unread"] = str(unread)
    return out


def _item_id(name: str | None) -> str | None:
    from brain import stash
    try:
        return stash._item_id(name)
    except Exception:  # the catalog could not load: the name stays unresolved
        return None


def chests_seen(rows: list[dict]) -> dict[str, dict]:
    """What each container held when his body last had it open: {container id: {items: {item id: n}, t, tool, mine}}
    from the store / take / inspect results in the brain log. The counts are the body's read of the game's own
    container screen (inventory.external_rows), not a word of the model's. The newest result per container wins."""
    from brain import stash
    out: dict[str, dict] = {}
    for r in rows:
        if r.get("kind") != "tool_result" or r.get("tool") not in stash.CONTAINER_TOOLS:
            continue
        res = r.get("result") or {}
        d = res.get("data") if isinstance(res.get("data"), dict) else {}
        cid = d.get("container") or (d.get("id") if r.get("tool") == "inspect" else None)
        contents = d.get("contents")
        if not cid or "Gravestone" in str(cid) or not isinstance(contents, list):
            continue
        items: dict[str, int] = {}
        for e in contents:
            iid, name, n = stash._parse(e)
            iid = iid or _item_id(name)
            if iid:
                items[iid] = items.get(iid, 0) + n
        if d.get("item") and isinstance(d.get("inside_now"), (int, float)):  # a one-item store / take: its own count
            items[d["item"]] = int(d["inside_now"])
        out[str(cid)] = {"items": items, "t": r.get("ts"), "tool": r.get("tool"), "mine": bool(d.get("mine"))}
    return out


def crafted_in_run(rows: list[dict]) -> dict[str, int]:
    """{item id: crafts} of the craft calls the game confirmed in this run (the body's craft result: data.item)."""
    out: dict[str, int] = {}
    for r in rows:
        if r.get("kind") != "tool_result" or r.get("tool") != "craft":
            continue
        res = r.get("result") or {}
        d = res.get("data") if isinstance(res.get("data"), dict) else {}
        if res.get("ok") is True and d.get("item"):
            out[d["item"]] = out.get(d["item"], 0) + int(d.get("crafts") or d.get("count") or 1)
    return out


def evidence(rows: list[dict]) -> dict:
    return {"chests": chests_seen(rows), "crafted": crafted_in_run(rows)}


def is_storage(cid: str, kinds: dict | None = None, read: dict | None = None) -> bool | None:
    """Is this container one the game treats as storage: True, False, or None (not known). The census kind decides
    when it was read ("storage", not a station: sense.FAMILIES); else the game's asset id and class as
    deconstruct.kind reads them (a station, plot or composter is not storage; a piece whose inventory was read is).
    Never by "mine": his campfire is his, and not a chest (docs/research/2026-11-17-job-end-readability.md H2)."""
    read = read or {}
    k = (kinds or {}).get(cid) or read.get("kind")
    if k in CENSUS_KINDS:
        return k == "storage"
    s = f"{cid} {read.get('class') or ''}"
    if any(m in s for m in NOT_STORAGE_MARKS):
        return False
    if str(cid).startswith("BuildingPiece_"):  # an instance-only piece (wall, floor): no actor, no inventory
        return False
    if read.get("read") and isinstance(read.get("items"), dict):
        return True
    return None


def read_container(reply: Any) -> dict:
    """An `inspect` reply on one container -> {read, items {item id: n}, kind, class, why}. read is False (unread)
    when the body could not find it or found no inventory on it: never an empty chest."""
    r = reply if isinstance(reply, dict) else {}
    d = r.get("data") if isinstance(r.get("data"), dict) else {}
    out = {"kind": d.get("kind"), "class": d.get("class")}
    if r.get("ok") is not True or not isinstance(d.get("contents"), list):
        why = r.get("reason") or d.get("detail") or ("no inventory read on it" if r.get("ok") else "no reply")
        return {**out, "read": False, "why": str(why)[:200]}
    from brain import stash
    items: dict[str, int] = {}
    for e in d["contents"]:
        iid, name, n = stash._parse(e)
        iid = iid or _item_id(name)
        if iid:
            items[iid] = items.get(iid, 0) + n
    return {**out, "read": True, "items": items}


def chest_candidates(start: dict, end: dict) -> list[str]:
    """His containers worth an end read: every id a read in the run marked his (start, samples, end) and every one his
    body's own container result marked his, less those known not to be storage."""
    kinds = {**(start.get("container_kinds") or {}), **(end.get("container_kinds") or {})}
    own = set(start.get("own_containers") or []) | set(end.get("own_containers") or [])
    own |= {cid for cid, c in (end.get("chests") or {}).items() if c.get("mine")}
    return sorted(cid for cid in own if is_storage(cid, kinds) is not False)


def chest_reads(io, ids: list[str]) -> dict[str, dict]:
    """The end read of each container (the body's `inspect`: client_bridge.contents_of, the same inventory read the
    store tool proves on a built crate). A failed read is recorded as unread with its reason."""
    out = {}
    for cid in ids:
        try:
            out[cid] = read_container(io.inspect(cid))
        except Exception as exc:  # the debug client failed: unread, never empty
            out[cid] = {"read": False, "why": f"inspect failed: {exc!r}"[:200]}
    return out


# ------------------------------------------------------------------ the end predicates
def _gain(start: dict, end: dict, pattern: str) -> int:
    return count_of(end.get("carried") or {}, pattern) - count_of(start.get("carried") or {}, pattern)


def _crafted(end: dict, pattern: str) -> int:
    return count_of(end.get("crafted") or {}, pattern)


def p_worn_made_in_run(spec: dict, start: dict, end: dict) -> tuple[bool, str]:
    """Each slot holds one of its items, made in this run: a craft of it confirmed in the run, and he has more of it
    than at the start (no crafted-by mark exists on an item instance: inventory.describe_item has none)."""
    short = []
    for slot, items in spec.items():
        on = (end.get("worn") or {}).get(slot)
        if not on or on not in items:
            short.append(f"{slot}: {on or 'nothing'} worn")
        elif not _crafted(end, on):
            short.append(f"{slot}: {on} worn but no craft of it in this run")
        elif _gain(start, end, on) <= 0:
            short.append(f"{slot}: {on} worn but he held as many at the start")
    return (not short), ("all worn and made in the run" if not short else "; ".join(short))


def _want_count(items: dict, want: dict) -> int:
    if want.get("item"):
        return count_of(items, want["item"])
    if want.get("made_at"):
        ok = made_at(want["made_at"], want.get("category"))
        return sum(n for k, n in items.items() if k in ok and not (want.get("exclude") and matches(k, want["exclude"])))
    return 0


def made_at(stations: list[str], category: str | None = None) -> set[str]:
    """Item ids that a recipe at one of these stations makes (data/recipes_<build>.json), of this category."""
    from brain import gear_plan
    cats = _item_categories()
    out = set()
    for r in gear_plan._recipes().values():
        if set(r.get("stations") or []) & set(stations):
            for o in r.get("outputs") or []:
                if o.get("item") and (category is None or cats.get(o["item"]) == category):
                    out.add(o["item"])
    return out


def _item_categories() -> dict[str, str]:
    """{item id: category} from the recipe file gear_plan reads (the same build)."""
    from brain import gear_plan
    try:
        items = json.loads(gear_plan.RECIPES.read_text(encoding="utf-8")).get("items") or {}
    except (OSError, ValueError):
        return {}
    return {k: v.get("category") for k, v in items.items() if isinstance(v, dict)}


def p_in_own_chest(spec: list[dict], start: dict, end: dict) -> tuple[bool | None, str]:
    """Each want is in ONE storage container of his (a read in the run marked it mine; the game treats it as storage)
    in the count asked, by the END read of that container (end["chest_end"]: chest_reads). None (unread) when that
    read is missing or failed for a container that could hold it: his body's earlier open of a chest is memory, and
    is used only to doubt an end read that shows less with nothing taken out since (an unopened crate's replica may
    be stale; unverified live)."""
    kinds = {**(start.get("container_kinds") or {}), **(end.get("container_kinds") or {})}
    reads = end.get("chest_end")
    own = set(chest_candidates(start, end)) | set(reads or {})
    opened = end.get("chests") or {}
    if not own:
        if opened:
            return None, (f"unread: he used {len(opened)} container(s) ({', '.join(sorted(opened)[:3])}) but no read "
                          "in the run marked any of them his")
        return False, "no storage container of his was seen in the run"
    if reads is None:
        return None, "unread: no end read of his containers"
    storage = {cid: is_storage(cid, kinds, reads.get(cid)) for cid in sorted(own)}
    if not any(v is not False for v in storage.values()):
        return False, f"none of his containers is storage ({', '.join(sorted(own)[:4])})"
    good = {cid: reads[cid]["items"] for cid, s in storage.items() if s and (reads.get(cid) or {}).get("read")}
    unread = {cid: (reads.get(cid) or {}).get("why") or "not read" for cid, s in storage.items()
              if s is not False and cid not in good}
    short, doubt = [], []
    for want in spec:
        label = want.get("label") or want.get("item")
        n = int(want["count"])
        best = max(((cid, _want_count(items, want)) for cid, items in good.items()), key=lambda x: x[1],
                   default=(None, 0))
        if best[1] >= n:
            continue
        if unread:
            doubt.append(f"{label}: {best[1]} of {n} in the read ones; unread: "
                         + "; ".join(f"{c} ({w})" for c, w in sorted(unread.items())[:3]))
            continue
        before = [(cid, _want_count(opened[cid]["items"], want)) for cid in good
                  if cid in opened and opened[cid].get("tool") != "take"]
        was = max(before, key=lambda x: x[1], default=(None, 0))
        if was[1] >= n:
            doubt.append(f"{label}: the end read of {was[0]} has {_want_count(good[was[0]], want)} of {n}, his last "
                         f"open of it ({opened[was[0]].get('tool')}) {was[1]}, and he took nothing out since")
            continue
        short.append(f"{label}: {best[1]} of {n} (best: {best[0]})")
    if short:
        return False, "; ".join(short + doubt)
    if doubt:
        return None, "unread: " + "; ".join(doubt)
    return True, "in his chest (end read)"


def p_carried_gain(spec: dict, start: dict, end: dict) -> tuple[bool, str]:
    short = [f"{p}: +{_gain(start, end, p)} of +{n}" for p, n in spec.items() if _gain(start, end, p) < int(n)]
    return (not short), ("gained" if not short else "; ".join(short))


def p_made_in_run(spec: dict, start: dict, end: dict) -> tuple[bool, str]:
    short = []
    for p, n in spec.items():
        if not _crafted(end, p):
            short.append(f"{p}: no craft of it in this run")
        elif _gain(start, end, p) < int(n):
            short.append(f"{p}: +{_gain(start, end, p)} of +{n} on him")
    return (not short), ("made" if not short else "; ".join(short))


def p_near_start_m(spec: float, start: dict, end: dict) -> tuple[bool, str]:
    a, b = start.get("position"), end.get("position")
    if not (isinstance(a, list) and isinstance(b, list) and len(a) >= 2 and len(b) >= 2):
        return False, "no position at the start or the end"
    d = math.dist(a[:2], b[:2])
    return d <= float(spec), f"{d:.0f} m from where he started (within {float(spec):.0f})"


def p_consumables_carried(spec: dict, start: dict, end: dict) -> tuple[bool, str]:
    """Food and drink he carries that the game's data says do no harm (snapshot: Dirty Water and burnt food left
    out, and named in the reason)."""
    have = end.get("consumables") or {}
    short = [f"{k}: {have.get(k, 0)} of {n}" for k, n in spec.items() if int(have.get(k, 0)) < int(n)]
    out = end.get("consumables_left_out") or {}
    if short and out:
        short.append("left out: " + ", ".join(f"{k} ({why})" for k, why in sorted(out.items())[:4]))
    return (not short), ("carried" if not short else "; ".join(short))


def gear_on(worn: dict, cat: dict | None = None) -> dict:
    """{pl: armour PL (head, body, legs summed // 3, as rung4_gate.gear_on), kit: {right_hand, left_hand: PL}}."""
    if cat is None:
        from brain import item_stats
        cat = item_stats.catalog()

    def pl(item):
        return int((cat.get(item) or {}).get("power_level") or 0) if item else 0
    armour = sum(pl(worn.get(s)) for s in ("Head", "Body", "Legs")) // 3
    kit = {"right_hand": pl(worn.get("HeldRight") or worn.get("held_right")),
           "left_hand": pl(worn.get("HeldLeft") or worn.get("held_left"))}
    return {"pl": armour, "kit": kit}


def p_gear_target(spec: dict, start: dict, end: dict, cat: dict | None = None) -> tuple[bool, str]:
    """rung4_gate's gear_up check: worn armour PL reaches the target gear_plan gave at the start, and each kit slot
    of the target holds gear of its PL or better."""
    tg = start.get("gear_target")
    if not isinstance(tg, dict) or "pl" not in tg:
        return False, "no gear target was computed at the start"
    on = gear_on(end.get("worn") or {}, cat)
    # the game's own figure when the state has it: a broken piece counts 0 there, and the item levels the catalog
    # gives do not (2026-11-17: a broken tunic and leggings under a cowl read PL 0 in the game and 1 from the
    # catalog, 13,192 of 13,194 readings; docs/research/2026-11-17-power-level.md)
    game = end.get("power_level")
    if isinstance(game, (int, float)):
        on["pl_items"], on["pl"] = on["pl"], int(game)
    short = [f"armour PL {on['pl']} of {tg['pl']}"] if on["pl"] < int(tg["pl"] or 0) else []
    short += [f"{s} PL {on['kit'].get(s, 0)} of {want}" for s, want in (tg.get("kit") or {}).items()
              if on["kit"].get(s, 0) < int(want)]
    return (not short), (f"armour PL {on['pl']}, kit {on['kit']}" if not short else "; ".join(short))


def _tier(item: str, order: list[str]) -> int:
    word = str(item).rsplit("_", 1)[-1].lower()
    low = [o.lower() for o in order]
    return low.index(word) if word in low else -1


def p_next_tier_tools(spec: dict, start: dict, end: dict) -> tuple[bool, str]:
    """For each tool family he carried at the start, he now carries one of a higher tier he did not carry then."""
    order, out, short = spec["order"], [], []
    for fam, pat in spec["families"].items():
        had = [k for k, n in (start.get("carried") or {}).items() if n and matches(k, pat)]
        if not had:
            continue
        best = max(_tier(k, order) for k in had)
        new = [k for k, n in (end.get("carried") or {}).items()
               if n and matches(k, pat) and _tier(k, order) > best and k not in had]
        (out if new else short).append(f"{fam}: {max(had, key=lambda k: _tier(k, order))} -> {new[0] if new else 'nothing higher'}")
    if not out and not short:
        return False, "he carried none of the tool families at the start"
    return (not short), "; ".join(out + short)


PREDICATES = {"worn_made_in_run": p_worn_made_in_run, "in_own_chest": p_in_own_chest, "carried_gain": p_carried_gain,
              "made_in_run": p_made_in_run, "near_start_m": p_near_start_m,
              "consumables_carried": p_consumables_carried, "gear_target": p_gear_target,
              "next_tier_tools": p_next_tier_tools}


def done(job: dict, state_start: dict, state_end: dict) -> tuple[bool | None, str]:
    """The job's end read from the game: every predicate of job["end"] holds. state_*: snapshot() of a get_state
    read; state_end also carries evidence() of the run's rows (chests, crafted) and the end read of his containers
    (chest_end), state_start the gear target. None (unread) when a read it needs failed and no predicate failed on
    what was read: never a pass or a fail on a reading that is not there."""
    for label, st in (("start", state_start), ("end", state_end)):
        if st.get("unread"):
            return None, f"unread: the {label} get_state ({st['unread']})"
    whys, ok, unread = [], True, False
    for name, spec in (job.get("end") or {}).items():
        fn = PREDICATES.get(name)
        if fn is None:
            return False, f"unknown predicate {name!r}"
        good, why = fn(spec, state_start, state_end)
        unread = unread or good is None
        ok = ok and good is True
        whys.append(f"{name}: {'ok' if good else 'UNREAD' if good is None else 'NO'} ({why})")
    if unread and not any(": NO (" in w for w in whys):
        return None, "; ".join(whys)
    return (ok and bool(whys)), "; ".join(whys)


def not_counted(rec_or_job: dict, state_start: dict | None = None) -> str | None:
    """Why a trial does not count, or None. With a run record alone: what it says (failure_ledger.scan's argument),
    or that its end state was unread. With a job and its start state: the items it must not start with that he holds
    (a head start, as quest_run.not_counted)."""
    if state_start is None:
        if rec_or_job.get("not_counted"):
            return rec_or_job["not_counted"]
        return f"end state unread: {rec_or_job['unread']}" if rec_or_job.get("unread") else None
    held = {k: n for k, n in (state_start.get("carried") or {}).items() if n
            and any(matches(k, p) for p in rec_or_job.get("not_carried_at_start") or [])}
    return ("held at the start: " + ", ".join(f"{k} x{n}" for k, n in sorted(held.items()))) if held else None


# ------------------------------------------------------------------ the bar
def bar_s(job: dict, b: dict | None = None) -> float | None:
    """Luis's time for the job, composed from his per-unit baselines (a floor: walking is the per-run human_bar's).
    None when the job has no composition (its bar_note says why)."""
    spec = job.get("bar")
    if not spec or not spec.get("parts"):
        return None
    from tools import quest_run as q
    b = b or q._baseline()
    fam = b["families"]
    total = 0.0
    for p in spec["parts"]:
        if "task" in p:
            w = [x for x in b.get("windows") or [] if x.get("task") == p["task"]]
            if not w:
                raise KeyError(f"no window {p['task']!r} in the baseline")
            total += float(w[0]["unit_s"]) * float(w[0].get("units") or 1) * float(p.get("x", 1))
        elif "family" in p:
            per = q._per_item(b, p["family"]) if p.get("per_item") else float(fam[p["family"]]["unit_s"])
            total += float(per or 0) * float(p.get("n", 1))
        elif "seconds_each" in p:
            total += float(p["seconds_each"]) * float(p.get("n", 1))
        elif "seconds" in p:
            total += float(p["seconds"])
    return round(total, 1)


# ------------------------------------------------------------------ misses, the first step, the resumption
def misses(calls: list[dict], work_s: float | None = None, interruption: dict | None = None) -> dict:
    """Every miss by quest_run's rule (quest_run.verdict: a failed world action, never an interruption or a read),
    each with its kind (the reason), time, tool and arguments; the count per 5 minutes of work; and the split around
    an interruption (before it was put in, until he took the job up again, after)."""
    from tools import quest_run as q
    rule = q.verdict({"tool_calls": calls})["misses"]
    keyed = [(m.get("t"), m.get("tool"), m.get("reason")) for m in rule]
    out = []
    for c in calls:
        k = (c.get("t"), c.get("tool"), c.get("reason"))
        if k in keyed:
            keyed.remove(k)
            out.append({"t": c.get("t"), "kind": c.get("reason"), "tool": c.get("tool"), "args": c.get("args"),
                        "detail": c.get("detail")})
    res = {"list": out, "n": len(out),
           "per_5min": round(len(out) / (work_s / 300.0), 2) if work_s and work_s > 0 else None}
    if interruption and interruption.get("t_put") is not None:
        put = float(interruption["t_put"])
        back = interruption.get("t_resumed")
        res["by_phase"] = {"before": sum(1 for m in out if float(m["t"] or 0) < put),
                           "during": sum(1 for m in out if float(m["t"] or 0) >= put and (back is None or float(m["t"] or 0) < back)),
                           "after": sum(1 for m in out if back is not None and float(m["t"] or 0) >= back)}
    return res


def _work_call(c: dict, work_tools) -> bool:
    from tools import standard_score as ss
    return c.get("tool") in set(work_tools or ()) and c.get("tool") not in ss.READ_ONLY_TOOLS


def first_step(calls: list[dict], job: dict) -> float | None:
    """When his first verified step ended (seconds into the run): the first work call the body reported ok."""
    for c in calls:
        if c.get("ok") is True and _work_call(c, job.get("work_tools")) and c.get("dur_s") is not None:
            return round(float(c["t"]) + float(c["dur_s"]), 1)
    return None


def resumed(calls: list[dict], interruption: dict, work_tools=None, lines: list[dict] | None = None) -> dict:
    """Did he take the job up again after the interruption: the first work call that STARTED after it cleared
    (t_clear; seconds into the run), how many seconds after, and whether a line from the player came in between
    (lines: [{t, line}] sent after the first)."""
    clear = interruption.get("t_clear")
    if clear is None:
        return {"resumed": False, "why": "the interruption has not cleared"}
    clear = float(clear)
    nxt = next((c for c in calls if float(c.get("t") or 0) >= clear and _work_call(c, work_tools)), None)
    put = float(interruption.get("t_put") or clear)
    new_lines = [l for l in lines or [] if float(l.get("t") or 0) >= put]
    if nxt is None:
        return {"resumed": False, "new_line": bool(new_lines), "why": "no work call after the interruption cleared"}
    t = float(nxt["t"])
    return {"resumed": True, "t": t, "after_s": round(t - clear, 1), "call": {"tool": nxt.get("tool"), "args": nxt.get("args"),
            "ok": nxt.get("ok")}, "new_line": any(float(l.get("t") or 0) <= t for l in new_lines)}


def trigger_due(spec: str, first_step_t: float | None, t: float, bar: float | None) -> bool:
    """When to put the interruption in: 'first_step' (after his first verified step), 'share:0.3' (at that share of
    the job's bar; with no bar, after the first step), 'at:120' (seconds into the run)."""
    kind, _, val = (spec or "first_step").partition(":")
    if kind == "at":
        return t >= float(val)
    if kind == "share" and bar:
        return t >= float(val) * bar
    return first_step_t is not None and t >= first_step_t


# ------------------------------------------------------------------ the verdict
def verdict(rec: dict) -> dict:
    """A whole job: quest_run's bars (done, <= 1.5x human_bar, <= 1 miss, no stand over 5 s), counted by the job's
    own rule. An interruption step: the interruption took, he took the job up again without a new line, within its
    resume_within_s; misses are recorded and split, and are not a bar of the step."""
    from tools import quest_run as q
    if rec.get("kind") == "interrupt":
        r = rec.get("resume") or {}
        lim = rec.get("resume_within_s")
        bars = {"interrupted": bool((rec.get("interruption") or {}).get("took")), "resumed": bool(r.get("resumed")),
                "no_new_line": not r.get("new_line"),
                "in_time": r.get("after_s") is not None and (lim is None or r["after_s"] <= float(lim)),
                "counted": not rec.get("not_counted")}
        ms = [{"t": m.get("t"), "tool": m.get("tool"), "reason": m.get("kind")} for m in (rec.get("misses") or {}).get("list") or []]
        return {"pass": all(bars.values()), "bars": bars, "misses": ms, "truth": "not judged"}
    v = q.verdict(rec)
    v["bars"]["counted"] = not rec.get("not_counted")
    v["bars"]["read"] = not rec.get("unread")  # an unread end state is neither a pass nor a fail (not counted)
    v["pass"] = all(v["bars"].values())
    return v


def item_key(rec: dict) -> str:
    return rec.get("job", "?") + (f" / {rec['step']}" if rec.get("step") else "")


def all_runs(path: Path | None = None) -> list[dict]:
    p = path or OUT
    if not p.exists():
        return []
    return [json.loads(line) for line in p.read_text(encoding="utf-8").splitlines() if line.strip()]


def scored(recs: list[dict], void: set[str]) -> list[tuple[dict, bool]]:
    """(run, passed) of the trials that say something: to the end (not a first_step probe), counted, not void."""
    return [(r, verdict(r)["pass"]) for r in recs
            if r.get("until") != "first_step" and r["run"] not in void and not not_counted(r)]


def rates(recs: list[dict], void: set[str], n: int = 10) -> dict[str, dict]:
    by: dict[str, list[bool]] = {}
    held: dict[str, bool] = {}
    for r, ok in scored(recs, void):
        by.setdefault(item_key(r), []).append(ok)
        held[item_key(r)] = bool(r.get("held_out"))
    out = {}
    for k, oks in by.items():
        last = oks[-n:]
        out[k] = {"passes": sum(last), "of": len(last), "streak": next((i for i, ok in enumerate(reversed(oks)) if not ok), len(oks)),
                  "held_out": held[k]}
    return out


def trace_allowed(rec: dict, recs: list[dict], void: set[str], read_trace: bool) -> tuple[bool, str]:
    """The held-out guard: a held-out job's trace is shown only with --read-trace and once TRACE_AFTER trials of that
    job are scored. Any other item's trace waits for TRACE_AFTER scored trials too (the first three of anything new
    are scored before a trace is read), unless --read-trace."""
    n = sum(1 for r, _ in scored(recs, void) if r.get("job") == rec.get("job"))
    if rec.get("held_out"):
        if not read_trace:
            return False, f"held-out job {rec.get('job')}: scores only (pass --read-trace once {TRACE_AFTER} trials are scored)"
        if n < TRACE_AFTER:
            return False, f"held-out job {rec.get('job')}: {n} of {TRACE_AFTER} trials scored, its trace stays closed"
        return True, f"held-out job {rec.get('job')}: trace opened with --read-trace ({n} trials scored)"
    if n < TRACE_AFTER and not read_trace:
        return False, f"{rec.get('job')}: {n} of {TRACE_AFTER} trials scored; the trace waits (or --read-trace)"
    return True, ""


SCORE_KEYS = ("run", "job", "step", "kind", "held_out", "character", "checkpoint", "holder", "ended", "wall_s",
              "done", "done_why", "not_counted", "ratio", "bar_s", "longest_stand_s", "haiku", "sonnet", "usd")


def scores_of(rec: dict) -> dict:
    v = verdict(rec)
    out = {k: rec.get(k) for k in SCORE_KEYS if k in rec}
    out.update(pass_=v["pass"], bars=v["bars"], misses_n=(rec.get("misses") or {}).get("n"),
               misses_per_5min=(rec.get("misses") or {}).get("per_5min"),
               misses_by_phase=(rec.get("misses") or {}).get("by_phase"))
    if rec.get("kind") == "interrupt":
        r = rec.get("resume") or {}
        out.update(resumed=r.get("resumed"), resumed_after_s=r.get("after_s"), new_line=r.get("new_line"),
                   interruption={k: (rec.get("interruption") or {}).get(k) for k in ("step", "took", "t_put", "t_clear")})
    return out


# ------------------------------------------------------------------ putting an interruption in (dev fixtures)
def apply_interruption(io, step: str, spec: dict, t0: float) -> dict:
    """Put the interruption in now. Returns {step, took, t_put, t_clear (None while it lasts), how}. Every fixture is
    the dev world's (DevTarget.setup: dev server only, the fork's guid, refused while another player is on)."""
    rel = lambda: round(io.now() - t0, 1)  # noqa: E731
    out: dict[str, Any] = {"step": step, "t_put": rel(), "t_clear": None, "took": False}
    purpose = f"job_run {step}: {spec.get('what')}"
    try:
        if step == "I1":
            got = {s: io.fixture("set_stat", purpose, stat=s, pct=float(spec.get("pct", 10))).get("after")
                   for s in ("sustenance", "hydration")}
            out.update(took=True, t_clear=rel(), how=f"sustenance and hydration set to {spec.get('pct', 10)} %: {got}")
        elif step == "I2":
            r = io.fixture("spawn", purpose, **{"class": spec["class"], "offset_m": spec.get("offset_m") or [8, 0, 0]})
            out.update(took=None, how=f"spawned {spec['class']} at {spec.get('offset_m')} m ({r.get('id') or 'no id'})",
                       spawn_id=r.get("id"))  # took: when a fight starts (fight_cleared)
        elif step == "I3":
            before = (io.me() or {}).get("position")
            io.fixture("set_health", purpose, value=0.0)
            t_dead, saw_dead = io.now(), False
            while io.now() - t_dead < float(spec.get("respawn_wait_s", 120)):
                m = io.me() or {}
                saw_dead = saw_dead or bool(m.get("dead"))
                p = m.get("position")
                if m and not m.get("dead") and isinstance(p, list) and isinstance(before, list) \
                        and math.dist(p[:2], before[:2]) > RESPAWN_M:
                    out.update(took=True, t_clear=rel(), died_at=before, respawned_at=p,
                               how=f"set_health 0 at {before}; respawned {math.dist(p[:2], before[:2]):.0f} m away")
                    break
                io.sleep(2.0)
            else:
                out["how"] = f"no respawn within {spec.get('respawn_wait_s', 120)} s (dead seen: {saw_dead})"
        elif step == "I4":  # full = no free hotbar or item-page slot (bag_room), never GetNumEmptySlots
            filled = 0
            for _ in range(int(spec.get("rounds", 3))):
                room = io.bag_room()
                if not room:
                    break
                io.fixture("grant", purpose, item=spec["filler"], count=int(room))
                filled += int(room)
            left = io.bag_room()
            out.update(took=left == 0, t_clear=rel() if left == 0 else None,
                       how=f"{filled} {spec['filler']} granted; " + (
                           "bag room unread (no hotbar and item page sizes in the inventory read)" if left is None
                           else f"{left} free hotbar and item slot(s) left"))
        elif step == "I5":
            ready = io.restart_brain(float(spec.get("gap_s", 5)))
            out.update(took=bool(ready), t_clear=rel() if ready else None,
                       how="brain ended and started again" if ready else "the new brain did not start")
    except Exception as exc:  # a fixture that failed: the trial says so; it is the harness's fault (void)
        out.update(took=False, how=f"fixture failed: {exc!r}"[:300])
    return out


def fight_cleared(rows: list[dict], intr: dict, t0: float, wait_s: float) -> dict:
    """I2: the fight started (combat_started) and ended (combat_end) after the spawn: the interruption took and has
    cleared. No fight within wait_s: it did not take."""
    put = t0 + float(intr["t_put"])
    started = ended = None
    for r in rows:
        ev = r.get("event") if r.get("kind") == "event" and isinstance(r.get("event"), dict) else None
        if not ev or ev.get("type") != "activity":
            continue
        at = float(ev.get("ts") or r.get("ts") or 0)
        if at < put:
            continue
        if ev.get("kind") == "combat_started" and started is None:
            started = at
        elif ev.get("kind") == "combat_end" and started is not None and ended is None:
            ended = at
    out = dict(intr)
    if started is not None:
        out["took"] = True
    if ended is not None:
        out["t_clear"] = round(ended - t0, 1)
    elif started is None and max((float(r.get("ts") or 0) for r in rows), default=put) - put > wait_s:
        out.update(took=False, how=(intr.get("how") or "") + f"; no fight within {wait_s:.0f} s")
    return out


# ------------------------------------------------------------------ one trial
READ_TRIES = 3


def _read_state(io) -> tuple[dict, dict]:
    """(raw get_state, snapshot) with up to READ_TRIES reads 2 s apart while the read fails (78 of 4 760 replies on 16
    and 17 Nov were ok: false, "no local player controller"); the snapshot keeps `unread` if every try failed."""
    raw = io.state()
    snap = snapshot(raw)
    for _ in range(READ_TRIES - 1):
        if not snap.get("unread"):
            break
        io.sleep(2.0)
        raw = io.state()
        snap = snapshot(raw)
    return raw, snap


class _Seen:
    """What the run's reads said about his containers, kept across samples: get_state lists only the 15 nearest
    pieces within 30 m (build.lua cfg.structures), so a crate of his is marked mine only while he is near it (run
    20261117-195219-L2: in neither the start nor the end read)."""

    def __init__(self):
        self.own: set[str] = set()
        self.kinds: dict[str, str] = {}

    def see(self, snap: dict) -> None:
        self.own |= set(snap.get("own_containers") or [])
        self.kinds.update(snap.get("container_kinds") or {})

    def into(self, snap: dict) -> None:
        snap["own_containers"] = sorted(self.own | set(snap.get("own_containers") or []))
        snap["container_kinds"] = {**self.kinds, **(snap.get("container_kinds") or {})}


def _open_reads(snap: dict) -> dict[str, dict]:
    """His body's opens of containers in the run as if they were end reads: only to decide when to make the real end
    read mid-run, never to judge."""
    return {cid: {"read": True, "items": c.get("items") or {}} for cid, c in (snap.get("chests") or {}).items()}


def run_job(io, job: dict, opts: dict) -> dict:
    """One trial on the body io gives: the brain started, the player's line sent, the run watched until the end the
    game confirms (or the step's end), the interruption put in when due, and the record written. io: Live (or a
    fake in the tests)."""
    from tools import quest_run as q
    from tools import chat_ladder as cl
    step = opts.get("step")
    spec = (opts.get("interruptions") or {}).get(step) or {}
    until = opts.get("until") or ("resumed" if step else "done")
    bar = bar_s(job) if job.get("bar") else None
    if not io.start_brain():
        return {"error": "brain did not start"}
    left_before = io.leave_dialogue()
    raw0, start = _read_state(io)
    chest_job = "in_own_chest" in (job.get("end") or {})
    seen = _Seen()
    if not start.get("unread"):
        seen.see(start)
    if "gear_target" in (job.get("end") or {}):
        try:
            start["gear_target"] = io.gear_target(raw0)
        except Exception as exc:
            start["gear_target_error"] = repr(exc)[:200]
    t0 = io.now()
    sent = [{"t": 0.0, "line": job["line"], "sent": io.send(job["line"])}]
    intr = None
    first_t = None
    why = None
    ok, ok_why = False, "not read yet"
    last_sample = -1e9
    rows: list[dict] = []
    res: dict = {}
    while True:
        now = io.now()
        rel = now - t0
        rows = io.rows(t0 - 1, now + 1)
        tl = q.timeline(rows, t0)
        calls = cl.model_calls(rows)
        if first_t is None:
            first_t = first_step(tl["calls"], job)
        if now - last_sample >= SAMPLE_S:
            last_sample = now
            cur = snapshot(io.state())
            if not cur.get("unread"):  # a failed read is skipped, never judged
                seen.see(cur)
                cur.update(evidence(rows))
                seen.into(cur)
                ok, ok_why = done(job, start, cur)
                if ok is None and chest_job and done(job, start, {**cur, "chest_end": _open_reads(cur)})[0] is True:
                    cur["chest_end"] = chest_reads(io, chest_candidates(start, cur))  # his opens say done: read it now
                    ok, ok_why = done(job, start, cur)
        if step and intr is None and trigger_due(opts.get("trigger") or "first_step", first_t, rel, bar):
            intr = apply_interruption(io, step, spec, t0)
            print(f"[{rel:6.1f}s] {step} put in: {intr.get('how')}")
        if intr is not None and step == "I2" and intr.get("t_clear") is None:
            intr = fight_cleared(rows, intr, t0, float(spec.get("fight_wait_s", 40)))
        if intr is not None and intr.get("t_clear") is not None:
            res = resumed(tl["calls"], intr, job.get("work_tools"), sent[1:])
        busy = [r for r in rows if r.get("kind") in ("prompt", "llm_response", "tool_call", "tool_result", "say")]
        open_prompt = bool(busy) and busy[-1].get("kind") == "prompt"
        open_tool = any(c.get("dur_s") is None for c in tl["calls"]) or bool(tl["body_busy"])
        quiet = now - max(tl["last_busy"], float(busy[-1]["ts"]) if busy else t0)
        if ok:
            why = "job done"
        elif until == "first_step" and first_t is not None:
            why = "first step"
        elif intr is not None and intr.get("took") is False:
            why = "interruption did not take"
        elif until == "resumed" and res.get("resumed") and rel >= res["t"] + float(opts.get("confirm_s", CONFIRM_S)):
            why = "resumed"
        elif intr is not None and intr.get("t_clear") is not None and not res.get("resumed") \
                and rel - float(intr["t_clear"]) > float(spec.get("resume_within_s", 120)):
            why = "no resumption"
        elif calls["haiku"] > int(opts.get("max_haiku", 80)):
            why = "haiku cap"
        elif rel > float(opts.get("deadline", 1800)):
            why = "deadline"
        elif Path(opts.get("stop_file") or STOP_FILE).exists():
            why = "stopped"
        elif not open_prompt and not open_tool and quiet >= q.QUIET_S and calls["calls"]:
            why = "quiet"
        if why:
            break
        io.sleep(q.POLL_S)
    ended = io.now()
    left_after = io.stop_all()
    _, end = _read_state(io)
    rows = io.rows(t0 - 1, ended + 3)
    if not end.get("unread"):
        seen.see(end)
    end.update(evidence(rows))
    seen.into(end)
    if chest_job:
        end["chest_end"] = chest_reads(io, chest_candidates(start, end))
    ok, ok_why = done(job, start, end)
    tl = q.timeline(rows, t0, ended)
    calls = cl.model_calls(rows)
    if intr is not None and step == "I2" and intr.get("took") is None:
        intr = fight_cleared(rows, intr, t0, float(spec.get("fight_wait_s", 40)))
    if intr is not None and intr.get("t_clear") is not None:
        res = resumed(tl["calls"], intr, job.get("work_tools"), sent[1:])
        if res.get("resumed"):
            intr["t_resumed"] = res["t"]
    active = round(tl["last_busy"] - t0, 1) if why == "quiet" else round(ended - t0, 1)
    idle_total = round(sum(i["s"] for i in tl["idle"]), 1)
    rec = {"run": time.strftime("%Y%m%d-%H%M%S", time.gmtime(t0)) + f"-{job['id']}" + (f"-{step}" if step else ""),
           "item": f"job: {job['id']}" + (f" / {step}" if step else ""), "kind": "interrupt" if step else "job",
           "job": job["id"], "step": step, "held_out": bool(job.get("held_out")), "until": until,
           "character": opts.get("character"), "checkpoint": opts.get("checkpoint"), "holder": opts.get("holder"),
           "lines": sent, "ended": why, "wall_s": round(ended - t0, 1), "active_s": active,
           "done": bool(res.get("resumed")) if step else ok is True, "job_done": ok is True, "done_why": ok_why,
           "state_start": start, "state_end": {k: v for k, v in end.items() if k != "chests"}, "chests": end.get("chests"),
           "first_step_s": first_t, "tool_calls": tl["calls"], "says": tl["says"], "idle_over_5s": tl["idle"],
           "idle_total_s": idle_total, "longest_stand_s": max([i["s"] for i in tl["idle"]], default=0),
           "haiku": calls["haiku"], "sonnet": calls["sonnet"], "usd": calls["usd"], "brain_logs": io.brain_logs(),
           "dialogue_left": {"before": left_before, "after": left_after}, "bar_s": bar}
    if step:
        rec.update(interruption=intr or {"step": step, "took": False, "how": "never put in (no first step)"},
                   resume=res, resume_within_s=spec.get("resume_within_s"),
                   says_after_put=[s for s in tl["says"] if intr and intr.get("t_put") is not None and s["t"] >= intr["t_put"]])
    nc = not_counted(job, start)
    if nc:
        rec["not_counted"] = nc
    if ok is None and not step:  # a whole job whose end state could not be read: not counted, the reason kept
        rec["unread"] = ok_why
    rec["misses"] = misses(tl["calls"], active - idle_total, intr)
    try:
        h = q.human_bar(rows, len(sent))
        rec["human"] = h
        rec["ratio"] = round(active / h["human_s"], 2) if h["human_s"] and not step else None
    except Exception as exc:  # the bar is a report: a broken baseline never loses the record
        rec["human"], rec["ratio"] = {"error": repr(exc)}, None
    rec["verdict"] = verdict(rec)
    return rec


def write(rec: dict, path: Path | None = None) -> None:
    p = path or OUT
    p.parent.mkdir(parents=True, exist_ok=True)
    with p.open("a", encoding="utf-8") as f:
        f.write(json.dumps(rec, default=str) + "\n")


# ------------------------------------------------------------------ the live body (never used by the tests)
class Live:
    """The body, the brain and the dev fixtures as one trial sees them, inside a quest_run.clone_window."""

    def __init__(self, a, cli, dev):
        self.a, self.cli, self.dev = a, cli, dev
        self.procs: list = []
        self.files: list[Path] = []

    def now(self) -> float:
        return time.time()

    def sleep(self, s: float) -> None:
        time.sleep(s)

    def start_brain(self) -> bool:
        from tools import chat_ladder as cl
        from tools import spend
        ok, how = cl.ensure_sender()
        if not ok:
            print("sender:", how)
            return False
        p, f = cl.start_brain(self.a, spend.spend_today()["spent_usd"])
        self.procs.append(p)
        if f is None:
            cl.stop_brain(p)
            return False
        self.files.append(f)
        return True

    def restart_brain(self, gap_s: float) -> bool:
        from tools import chat_ladder as cl
        for p in self.procs:
            cl.stop_brain(p)
        time.sleep(gap_s)
        return self.start_brain()

    def brain_logs(self) -> list[str]:
        return [f.name for f in self.files]

    def rows(self, t0: float, t1: float) -> list[dict]:
        from tools import chat_ladder as cl
        return cl.brain_rows(self.files, t0, t1)

    def send(self, line: str) -> bool:
        from tools import m1_session
        return m1_session.send_speech_direct(line)[0]

    def state(self) -> dict:
        r = self.cli.request("get_state", {}, timeout=20)
        if not isinstance(r, dict) or r.get("ok") is False:  # a failed read is unread, never an empty character
            d = (r.get("data") if isinstance(r, dict) else None) or {}
            return {"unread": str((r or {}).get("reason") or d.get("detail") or "get_state failed")}
        return r.get("data") or {}

    def me(self) -> dict | None:
        from tools import chat_ladder as cl
        return cl.me(self.cli)

    def bag_room(self) -> int | None:
        return bag_room(self.cli.request("inventory", {"raw": True}, timeout=20))

    def inspect(self, cid: str) -> dict:
        """One container's contents through the body's own read (client_bridge inspect -> contents_of)."""
        return self.cli.request("inspect", {"target": cid}, timeout=20)

    def fixture(self, verb: str, purpose: str, **kw) -> dict:
        return self.dev.setup(verb, purpose=purpose, **kw)

    def gear_target(self, state: dict) -> dict:
        from tools import rung4_gate
        from brain.stash import Stash
        stash = Stash(ROOT / "logs" / "state" / "worlds" / self.a.world / "containers.json").labels()
        tg = rung4_gate.gear_target(state, stash)
        return {"pl": tg["pl"], "pl_now": tg["pl_now"], "kit": tg["kit"]}

    def leave_dialogue(self) -> list[dict]:
        from tools import quest_run as q
        return q.leave_dialogue(self.cli)

    def stop_all(self) -> list[dict]:
        """The brain(s) stopped, the body's last job stopped, any dialogue left: the lock is handed back clean."""
        from tools import chat_ladder as cl
        from tools import quest_run as q
        time.sleep(2.0)
        for p in self.procs:
            cl.stop_brain(p)
        try:
            self.cli.request("stop", {}, timeout=15)
        except Exception:
            pass
        return q.leave_dialogue(self.cli)


# ------------------------------------------------------------------ the window (K trials on forks)
def start_ref(job: dict, step: str | None, override: str | None) -> tuple[str, str]:
    """(checkpoint or save to fork, why): --from, else a mid-job checkpoint for an interruption step when it exists,
    else the job's start (the interruption then comes after his first verified step)."""
    from tools import quest_clone
    if override:
        return override, "--from"
    mid = job.get("interrupt_from")
    if step and mid and (quest_clone.CHECKPOINT_DIR / f"{mid}.json").exists():
        return mid, "the job's mid-job checkpoint"
    return job["start"], "the job's start" + (f" ({mid} not made yet)" if step and mid else "")


def cmd_window(a, step: str | None) -> int:
    from tools import quest_run as q
    from tools import quest_clone
    if not a.confirm:
        print("refusing: a live trial relaunches the client on forked characters; pass --confirm")
        return 2
    if q.refuse_dirty(a):
        return 7
    doc = load_jobs()
    job = job_of(a.job, doc)
    ref, ref_why = start_ref(job, step, a.checkpoint)
    try:
        src, place = quest_clone.source_of(ref), quest_clone.place_of(ref)
    except SystemExit as exc:
        print(f"no start for {a.job}: {exc}")
        return 2
    if a.save_as and (quest_clone.CHECKPOINT_DIR / f"{a.save_as}.json").exists():
        print(f"checkpoint {a.save_as!r} exists already: pick a new --save-as label")
        return 2
    from tools.vitals_rescue import save_unfit  # a fork copies the SAVE, not his live bars (live 2026-11-17 21:05Z)
    if (why := save_unfit(src)) is not None:
        print(f"not running: {why}")
        return 3
    print(f"{a.job}{' / ' + step if step else ''}: {a.k} trial(s) from {ref} ({ref_why}); holder {a.holder}; "
          f"each up to {a.max_haiku} Haiku calls (controller) plus the Planner (Sonnet), capped at ${a.usd} a trial on "
          f"top of today's spend")
    if job.get("held_out"):
        print(f"held-out job: scored only; its trace stays closed (show --read-trace after {TRACE_AFTER} scored trials)")
    stamp = time.strftime("%d%H%M", time.gmtime())
    forks = [f"ClaudeJ{stamp}{chr(97 + i)}" for i in range(min(a.k, 26))]
    out = {"window": time.strftime("%Y%m%d-%H%M%S", time.gmtime()), "job": a.job, "step": step, "from": ref,
           "source": str(src), "k": a.k, "place": place, "holder": a.holder, "trials": []}
    used = []
    old = os.environ.get("DW_GATE_DIRECTOR")
    os.environ["DW_GATE_DIRECTOR"] = "1" if a.holder == "board" else "0"  # chat_ladder.start_brain reads it
    try:
        with q.clone_window(a.wait, out, WINDOW_OUT) as (sw, cli, t0):
            for name in forks:
                if STOP_FILE.exists():
                    out["trials"].append({"character": name, "skipped": f"{STOP_FILE.name} present"})
                    break
                left = a.window_s - a.reserve_s - (time.time() - t0) - q.SWITCH_S
                if left < 120:
                    out["trials"].append({"character": name, "skipped": f"window: {left:.0f} s left"})
                    break
                try:
                    quest_clone.fork(ref, name)
                except SystemExit as exc:
                    raise RuntimeError(f"fork: {exc}") from None
                used.append(name)
                made = sw.ensure(name, create=False, wait_s=150)
                bad_start = unfit(cli)  # the body this fork starts as (an unread state refuses too)
                if bad_start:
                    out["trials"].append({"character": name, "skipped": bad_start})
                    print(f"{name}: {bad_start}")
                    break  # every fork of this save starts the same
                start = q.to_start(cli, place)
                if start is not None and not start["ok"]:
                    out["trials"].append({"character": name, "start": start, "skipped": "not at the start's place"})
                    continue
                from evals.bench.devrun import default_dev
                dev = default_dev()
                dev.brain_running = lambda: False
                dev.character_guid, dev.character_name = made["guid"], name  # the fixture guard wants the fork's guid
                ns = argparse.Namespace(**{**vars(a), "world": f"dev_{name}", "in_lock": True, "start_brain": True,
                                           "use_running_brain": False})
                bad = q.preflight(ns)
                if bad:
                    out["trials"].append({"character": name, "skipped": "preflight: " + "; ".join(bad)})
                    continue
                io = Live(ns, cli, dev)
                left = a.window_s - a.reserve_s - (time.time() - t0)
                rec = run_job(io, job, {"step": step, "interruptions": doc.get("interruptions"), "until": a.until,
                                        "trigger": getattr(a, "trigger", None), "deadline": min(a.deadline, left),
                                        "max_haiku": a.max_haiku, "character": name, "checkpoint": ref,
                                        "holder": a.holder, "confirm_s": getattr(a, "confirm_s", CONFIRM_S)})
                if "error" in rec:
                    out["trials"].append({"character": name, "error": rec["error"]})
                    continue
                write(rec)
                t_end = time.time()
                v = rec["verdict"]
                row = {"character": name, "run": rec["run"], "pass": v["pass"], "ended": rec["ended"],
                       "misses": rec["misses"]["n"], "at_s": round(t_end - t0, 1)}
                if step:
                    row["resumed_after_s"] = (rec.get("resume") or {}).get("after_s")
                out["trials"].append(row)
                print(json.dumps(scores_of(rec), default=str)[:600] if job.get("held_out") else
                      json.dumps(row, default=str))
                if a.save_as and "saved_as" not in out and (rec["job_done"] or rec["ended"] == "first step"):
                    kept = quest_clone.keep(name, a.save_as, newer_than=t_end, wait_s=q.AUTOSAVE_S)
                    out["saved_as"] = str(kept) if kept else f"no save of {name} within {q.AUTOSAVE_S:.0f} s"
                if a.regrow_days > 0:  # on the fork that has played, never on the one about to
                    out["trials"][-1]["clock_after"] = q.clock_on(dev, a.regrow_days, f"job_run {a.job}: regrow",
                                                                  vitals=q.vitals_of(cli))
    finally:
        if old is None:
            os.environ.pop("DW_GATE_DIRECTOR", None)
        else:
            os.environ["DW_GATE_DIRECTOR"] = old
    if out.get("back") and not a.keep_forks:
        print("parked:", quest_clone.park(used))
    done_ = [t for t in out["trials"] if "pass" in t]
    print(f"== {a.job}{' / ' + step if step else ''} from {ref}: {sum(1 for t in done_ if t['pass'])} of {len(done_)} passed")
    return 0 if done_ and all(t["pass"] for t in done_) else 1


def cmd_rates(a) -> int:
    from tools import failure_ledger
    void = failure_ledger.voided()
    recs = [r for r in all_runs() if r["run"] >= a.since]
    rs = rates(recs, void, a.n)
    print(f"{'item':<20} last {a.n:<3} streak   (void runs left out: {sum(1 for r in recs if r['run'] in void)}; "
          f"end state unread, left out: {sum(1 for r in recs if r.get('unread') and not r.get('not_counted'))})")
    for k, r in sorted(rs.items()):
        print(f"{k:<20} {r['passes']:>2} of {r['of']:<2} {r['streak']:>4}{'   held-out' if r['held_out'] else ''}")
    for label, held in (("tuned", False), ("untuned (held-out)", True)):
        p = sum(r["passes"] for r in rs.values() if r["held_out"] is held)
        n = sum(r["of"] for r in rs.values() if r["held_out"] is held)
        print(f"{label}: {p} of {n}" + (f" = {100 * p / n:.0f} %" if n else ""))
    return 0


def cmd_show(a) -> int:
    from tools import failure_ledger
    recs = all_runs()
    rec = next((r for r in recs if r["run"] == a.run), None)
    if rec is None:
        print(f"no job run {a.run}")
        return 2
    print(json.dumps(scores_of(rec), indent=1, default=str))
    ok, why = trace_allowed(rec, recs, failure_ledger.voided(), a.read_trace)
    if why:
        print(why)
    if not ok:
        return 0
    for c in rec.get("tool_calls") or []:
        print(f"  {c['t']:6.1f}s {c['tool']:<12} {c.get('dur_s')!s:>6}s ok={c.get('ok')} {c.get('reason') or ''} "
              f"{json.dumps(c.get('args'))[:80]} | {c.get('detail', '')}")
    for s in rec.get("says") or []:
        print(f"  {s['t']:6.1f}s say: {s['text']}")
    for m in (rec.get("misses") or {}).get("list") or []:
        print(f"  miss {m['t']}s {m['tool']} {m['kind']}: {json.dumps(m.get('args'))[:100]}")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    tr = sub.add_parser("trial", help="one lock window: K whole-job trials, each on a new fork of the job's start")
    it = sub.add_parser("interrupt", help="one lock window: K trials of the job with one interruption put in")
    it.add_argument("--step", required=True, choices=STEPS)
    it.add_argument("--trigger", default="first_step", help="first_step (default), share:0.3 (of the bar), at:SECONDS")
    it.add_argument("--confirm-s", type=float, default=CONFIRM_S, help="how long the trial goes on after he resumed")
    for p in (tr, it):
        p.add_argument("--confirm", action="store_true")
        p.add_argument("--job", required=True)
        p.add_argument("-k", type=int, default=3)
        p.add_argument("--from", dest="checkpoint", help="a checkpoint label or a save name to fork (default: the job's)")
        p.add_argument("--until", choices=("done", "first_step", "resumed"), default=None,
                       help="end at the job's end (trial default), at his first verified step (a probe, to --save-as a "
                            "mid-job checkpoint), or when he took the job up again (interrupt default)")
        p.add_argument("--save-as", metavar="LABEL", help="keep the next save of the first trial that ends done or at its first step")
        p.add_argument("--holder", choices=("default", "board"), default="default",
                       help="which holder carries the ask: the default path, or the board with the Director (DW_DIRECTOR=1)")
        p.add_argument("--deadline", type=float, default=1800.0, help="per trial")
        p.add_argument("--max-haiku", type=int, default=120)
        p.add_argument("--usd", type=float, default=0.6, help="each trial's spend cap on top of today's spend")
        p.add_argument("--wait", type=float, default=3000.0, help="seconds to wait for the live lock")
        p.add_argument("--window-s", type=float, default=3600.0)
        p.add_argument("--reserve-s", type=float, default=240.0)
        p.add_argument("--regrow-days", type=int, default=3)
        p.add_argument("--keep-forks", action="store_true")
        p.add_argument("--dirty-ok", metavar="REASON")
    rt = sub.add_parser("rates")
    rt.add_argument("-n", type=int, default=10)
    rt.add_argument("--since", default="20261117")
    sh = sub.add_parser("show")
    sh.add_argument("run")
    sh.add_argument("--read-trace", action="store_true")
    a = ap.parse_args(argv)
    if a.cmd == "trial":
        a.until = a.until or "done"
        return cmd_window(a, None)
    if a.cmd == "interrupt":
        a.until = a.until or "resumed"
        return cmd_window(a, a.step)
    return {"rates": cmd_rates, "show": cmd_show}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
