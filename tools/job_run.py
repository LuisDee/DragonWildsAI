"""Long-job trials (docs/GOAL-2026-11-17-long-jobs.md section 1): one ask from a player carried to an end the GAME
STATE confirms, whole (L1 to L3, held-out H1 to H3) or with one interruption put in by the harness (I1 to I5).

    .venv\\Scripts\\python.exe -m tools.job_run trial --confirm --job L2 -k 3
    .venv\\Scripts\\python.exe -m tools.job_run trial --confirm --job N1 -k 3 --until mid --save-as job_n1_midjob
    .venv\\Scripts\\python.exe -m tools.job_run interrupt --confirm --step I3 --job L2 -k 5
    .venv\\Scripts\\python.exe -m tools.job_run trial --confirm --job N1 --interrupt I1 -k 5   # the same, near home
    .venv\\Scripts\\python.exe -m tools.job_run trial --confirm --job L2 --rung V1 -k 5 --save-as job_l2_v1
    .venv\\Scripts\\python.exe -m tools.job_run trial --confirm --job L2 --rung V2 --from job_l2_v1 -k 5 --save-as job_l2_v2
    .venv\\Scripts\\python.exe -m tools.job_run trial --confirm --job K --rung K1 -k 3 --save-as vault_door   # the vault
    .venv\\Scripts\\python.exe -m tools.job_run trial --confirm --job K --rung K2 -k 3                       # from vault_door

A rung (data/jobs.json L2 "rungs", the goal's venture ladder) is a trial of the job itself, his ask the job's line: it
sets only where the trial ends (its own end, read from the game) and where it starts (its "from": the checkpoint a
passing run of the rung before saved). A rung's pass that is saved also writes <label>.ladder.json beside the save: the
item instances he made in the ladder so far (ladder_made), read by the next rung, so gear he made in V1 counts in V2.

A mid-job checkpoint (the window recipe, each window from the named world, in the foreground):
    stop_server.ps1 -Hold; world_snapshot restore base --confirm; start_server.ps1 (nav_reset.ps1 restarts the helper)
    job_run trial --job N1 --until mid --save-as job_n1_midjob -k 3
        ends a trial once 0.2 of the asked units are got (read from the game every 3 s) with nothing of the job stored,
        and keeps the save only when the END read is inside 0.2-0.6 and nothing was stored (the trial row says
        `not_saved: why` otherwise; the next trial tries again). `--until first_step` is kept for jobs with no counts:
        its save can hold the whole job (window 1118d: job_n1_mid had all 20 ash and 10 stone carried).
    then per step, a new restore and: job_run trial --job N1 --interrupt I<n> -k 5   (from data/jobs.json interrupt_from)
A checkpoint with a chest of his own (N1's interrupt_from and I4's from, both job_n1_own_chest):
    job_run trial --job N1 --until own_chest --save-as job_n1_own_chest -k 3
        ends a trial once the game shows a container whose owner is HIM (this character's guid, never ClaudeDev's or
        his account's) holding an asked item put in after the line, the job not done; kept only when the end read
        says so. A fork finds the base crates "ClaudeDev's, not mine" and asks which to use (2026-11-18 runs 052749,
        053829, 080852-N1-I5): a mid checkpoint meets that question in every trial. A run that ends without his own
        chest says why (`not_saved: he never made a chest of his own: ...`).
A probe (--until first_step, mid or own_chest) is recorded with probe: true and is never a trial (not_counted, failure_ledger).
--save-as keeps a checkpoint PAIR (tools/checkpoint_pair.py): his save and the world, both written after the trial
ended (the client and server are stopped for the world copy, up to 5.5 min of waiting first). A trial --from a pair
restores its world and plays the checkpoint's own character (same guid and name) instead of a new fork, so what he
built or claimed before the checkpoint is still his; --from ClaudeDev or a plain checkpoint forks freshly as before.
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
docs/research/2026-11-17-long-job-harness.md is in), logs/evals/job_windows.jsonl (one per lock window),
logs/evals/trace_reads.jsonl (one per trace `show` opened). A scored record carries trial_n and, for the first three
of its item, first_three_blind (no trace of its job opened by `show` before it; tools/breadth.py reports it).
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import math
import os
import re
import sys
import time
from functools import lru_cache
from pathlib import Path
from typing import Any

from brain import paths

ROOT = paths.REPO_ROOT
JOBS = ROOT / "data" / "jobs.json"
OUT = ROOT / "logs" / "evals" / "job_runs.jsonl"
WINDOW_OUT = ROOT / "logs" / "evals" / "job_windows.jsonl"
# every trace `show` opened (run, job, when): a trial is scored blind when no trace of its job was opened before it
TRACE_READS = ROOT / "logs" / "evals" / "trace_reads.jsonl"
# a window is stopped by creating this file, never by killing it: the trial ends "stopped" and the window still
# switches back to ClaudeDev (2026-11-17 18:04Z: a killed L2 window left the client on its fork, and the next
# window's fixtures took him for another player)
STOP_FILE = paths.LIVE_ROOT / "logs" / "job_run.stop"  # single per VM: the main tree's
STEPS = ("I1", "I2", "I3", "I4", "I5")
SAMPLE_S = 15.0       # a get_state read for the end predicate and the body's state, this often
# ... and this often while a moment read from his progress is awaited (--until mid, a progress trigger): a 15 s
# sample let one 19-log gather take N1 from 0.03 to 0.63 between two reads (window 1118d, run 014312)
FAST_SAMPLE_S = 3.0
AWAIT_POLL_S = 0.5    # the brain log is read this often while a step's interruption is awaited (rows only, no reads)
MID_DEFAULT = (0.2, 0.6)  # --until mid: end a probe once this share of the job is got and nothing of it is stored
# --until own_chest: end a probe once the game shows a container whose owner is HIM (this character, never his line or
# his account) holding an asked item put in after the line, the job not done. Forks of ClaudeDev found the base crates
# "ClaudeDev's, not mine" and asked the player which to use (2026-11-18 runs 052749, 053829, 080852-N1-I5); a mid
# checkpoint stops before he has a chest of his own, so every trial from it met the same question.
OWN_CHEST = "own_chest"
UNTILS = ("done", "first_step", "resumed", OWN_CHEST)
CONFIRM_S = 60.0      # an interruption trial goes on this long after he took the job up again (it was not a blip)
TRACE_AFTER = 3       # the first three trials of anything are scored before its trace is read (goal: held-out)
RESPAWN_M = 20.0
DEADLINE_S = 1800.0   # a trial's deadline when neither --deadline nor the job's deadline_s names one
# a job's world_needs census (world_check): rows asked of the body's census, past get_state's 15 nearest. describe runs
# on every resource in the radius before the cap, so the cap bounds the reply's size, not the read's cost
WORLD_CENSUS_MAX = 1000
WORLD_SHORT = "world short"


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
# A trial starts fed and watered: the save a fork copies and the body at the join hold food and water at START_PCT
# (70 %), not only the fit bar. Window n2_i4 of 2026-11-19 forked a save at food 67, water 56 (fit at 40), every line
# met him at water 42-46 %, under his own 40 % drink line within a minute, and drinking ate I4's 120 s resume window in
# all six trials (tools/vitals_rescue.py START_PCT has the numbers).
from tools.vitals_rescue import START_PCT  # noqa: E402
START_WHY = (f"a job trial starts at food and water {START_PCT:.0f} % or more, so the walk to the line and the step's "
             f"timed part do not cross his {FIT_PCT:.0f} % drink line (2026-11-19 window n2_i4: forks of a save at water "
             "56 met the line at 42-46 % and spent the 120 s on water)")


def start_unfit(src, cli=None) -> str | None:
    """Why a trial must not start (a harness fault, never his), or None: the save a fork copies (`src`) under
    START_PCT, else, with `cli`, the body as it joined. The reason names the bar and its remedy."""
    from tools.vitals_rescue import save_unfit
    why = save_unfit(src, pct=START_PCT) if cli is None else unfit(cli, START_PCT)
    return f"{why}; {START_WHY}" if why else None


def vitals(d: dict | None) -> dict | None:
    """{food, water, health} as % of their max from a get_state (flat keys or the survival table), the ones read;
    None when none was read. The record's start and end carry it, so a start the stay-fed reflex had to answer is
    readable afterwards (2026-11-19: the six N2/I4 records held no bars; their start water came from the prompts)."""
    d = d or {}
    surv = d.get("survival") if isinstance(d.get("survival"), dict) else {}
    out = {}
    for what, cur, mx in (("food", "sustenance", "sustenance_max"), ("water", "hydration", "hydration_max"),
                          ("health", "health", "max_health")):
        c, m = d.get(cur), d.get(mx)
        if not isinstance(c, (int, float)) and isinstance(surv.get(cur), list) and len(surv[cur]) >= 2:
            c, m = surv[cur][0], surv[cur][1]
        if isinstance(c, (int, float)) and not isinstance(c, bool) and isinstance(m, (int, float)) and m > 0:
            out[what] = round(100.0 * c / m, 1)
    return out or None


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
    kind}; container_where {id: position} of his (an actor's name is per client session and changes when the game
    re-creates it; where it stands does not); empty_slots (the game's count over every page); bag_room (bag_room(), else
    get_state's item-page bag {capacity - used}) and bag_room_from ("pages" or "bag"); unread (why the read is not a
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
    worn_detail: dict[str, dict] = {}
    instances: dict[str, list] = {}
    held: list[dict] = []  # each counted stack: {item, guid, broken} (a made tool or weapon on him: made_carried)
    on_him = {r.get("item") or r.get("name") for r in rows or [] if r.get("where") != "loadout"}
    for r in rows or []:
        item = r.get("item") or r.get("name")
        n = int(r.get("count") or 1)
        slot = str(r.get("loadout_slot") or "")
        loadout = r.get("where") == "loadout"
        if item and not (loadout and slot.startswith(REF_SLOTS) and item in on_him):
            carried[item] = carried.get(item, 0) + n
            instances.setdefault(item, []).append(r.get("guid") or None)  # UItem.Guid (describe_item); None: unread
            held.append({"item": item, "guid": r.get("guid") or None,
                         "broken": broken({"broken": r.get("broken"), "durability": r.get("durability"),
                                           "max_durability": r.get("max_durability")})})
        if loadout and slot and item:
            worn[slot] = item
            worn_detail[slot] = {"item": item, "guid": r.get("guid") or None, "durability": r.get("durability"),
                                 "max_durability": r.get("max_durability"), "broken": bool(r.get("broken"))}
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
    where = {str(e["id"]): list(e["position"]) for key in ("structures", "interactables") for e in d.get(key) or []
             if isinstance(e, dict) and e.get("mine") and e.get("id") and isinstance(e.get("position"), (list, tuple))
             and len(e["position"]) >= 2}
    pl = d.get("power_level")
    room, room_from = bag_room(d), "pages"
    b = d.get("bag") if isinstance(d.get("bag"), dict) else {}
    if room is None and all(isinstance(b.get(k), (int, float)) and not isinstance(b.get(k), bool) for k in ("used", "capacity")):
        # get_state's bag {used, capacity}: the item page only (skills.lua), so a sample reads room without a request;
        # 0 here may still be room in the hotbar (bag_watch then asks the raw pages)
        room, room_from = max(0, int(b["capacity"]) - int(b["used"])), "bag"
    unread = d.get("unread") or (None if rows is not None or d.get("inventory") or d.get("position") is not None
                                 else "the read carried no position and no inventory")
    out = {"carried": carried, "worn": worn, "worn_detail": worn_detail, "instances": instances, "held_detail": held,
           "consumables": cons, "position": d.get("position"),
           "dead": bool(d.get("dead")), "own_containers": sorted(own), "container_kinds": kinds, "container_where": where,
           "empty_slots": d.get("empty_slots"), "bag_room": room, "bag_room_from": room_from if room is not None else None,
           "power_level": pl if isinstance(pl, (int, float)) and not isinstance(pl, bool) else None}
    if (v := vitals(d)) is not None:
        out["vitals"] = v
    # the vault (goal item 4, the capstone): the game's own in-a-vault flag and the vault that holds him (sense.vault_here,
    # absent when unread: None here, never False), the vault rows in reach (a door's destination / leads_to / locked, a
    # lever's switch_position, a chest's chest_state: sense.vault_row), his last kills (combat recent_kills, newest first)
    # and the fight he is in
    # in_vault is kept as read but never required: it read false inside Crasorak Kara (DISCOVERIES 2026-11-19); inside is
    # vault_place's (the registry box that holds him, else a door jump)
    iv = d.get("in_vault")
    out["in_vault"] = iv if isinstance(iv, bool) else None
    out["vault"] = str(d["vault"]) if isinstance(d.get("vault"), str) and d["vault"] else None
    out["vault_rows"] = [vault_row(e) for e in d.get("interactables") or []
                         if isinstance(e, dict) and is_vault_row(e)][:VAULT_ROWS_MAX]
    out["hostiles_near"] = hostiles_near(d)
    out["recent_kills"] = [dict(k) for k in d.get("recent_kills") or [] if isinstance(k, dict)]
    for k in ("fight", "boss_fight"):
        out[k] = d[k] if isinstance(d.get(k), dict) else None
    if left_out:
        out["consumables_left_out"] = left_out
    if unread:
        out["unread"] = str(unread)
    return out


# the fields sense.vault_row adds to an interactable row (a vault's door teleporter, lever or chest)
VAULT_FIELDS = ("destination", "arrives_at", "leads_to", "locked", "switch_position", "switch_highest", "drives",
                "chest_state")
VAULT_ROWS_MAX = 20
DOOR_PROMPTS = ("Enter",)


HOSTILE_NEAR_M = 30.0
HOSTILES_NEAR_MAX = 5


def hostiles_near(d: dict) -> list[dict]:
    """The hostile creatures within HOSTILE_NEAR_M of him in a get_state read (nearby_entities rows that read hostile),
    nearest first: what met him where a door jump landed him (the vault probe of 19 Nov: a Hulk at 10.7 m)."""
    rows = []
    for e in d.get("nearby_entities") or []:
        dist = e.get("distance") if isinstance(e, dict) else None
        if isinstance(dist, (int, float)) and dist <= HOSTILE_NEAR_M and (e.get("hostile") is True
                                                                          or e.get("attitude") == "hostile"):
            rows.append({k: e[k] for k in ("name", "distance", "power_level", "alertness") if e.get(k) is not None})
    return sorted(rows, key=lambda r: r["distance"])[:HOSTILES_NEAR_MAX]


def is_vault_row(e: dict) -> bool:
    """A row sense.vault_row described (any vault field), or a door by its prompt (the door row of 1-2 Nov had name
    and prompt "Enter" before the vault fields existed)."""
    return any(e.get(k) is not None for k in VAULT_FIELDS) or e.get("prompt") in DOOR_PROMPTS


def vault_row(e: dict) -> dict:
    keep = ("id", "name", "prompt", "position", "actor_position", "distance") + VAULT_FIELDS
    return {k: e[k] for k in keep if e.get(k) is not None}


def _item_id(name: str | None) -> str | None:
    from brain import stash
    try:
        return stash._item_id(name)
    except Exception:  # the catalog could not load: the name stays unresolved
        return None


# a container's owner as the body read it from the game (client_mod/scripts/sense.lua owner_row: the actor's
# UOwnershipComponent.OwningCharacterGuid, "yours" / a character name / "nobody"; same_account: the placer's account
# (OwningPlayerId) against his own); owner and owner_guid first (game_owner); mine last (chests_seen sets it)
# copied_from: the brain showed it as his because a character he was copied from owns it (brain/fork_line.py)
OWNER_KEYS = ("owner", "owner_guid", "owner_name", "same_account", "private", "copied_from", "mine")


def chests_seen(rows: list[dict]) -> dict[str, dict]:
    """What each container held when his body last had it open: {container id: {items: {item id: n}, t, tool, mine}}
    from the store / take / inspect results in the brain log. The counts are the body's read of the game's own
    container screen (inventory.external_rows), not a word of the model's. The newest result per container wins."""
    out: dict[str, dict] = {}
    for r in rows:
        got = _container_result(r)
        if got:
            cid, items, d = got
            # mine/owner: the body's read of the game's owner (sense.owner_row); None when the result does not say
            # (run 015315-N1-I2 recorded "mine": false for a store result that carried no owner at all)
            out[cid] = {"items": items, "t": r.get("ts"), "tool": r.get("tool"), "mine": d.get("mine"),
                        **{k: d[k] for k in OWNER_KEYS[:-1] if d.get(k) is not None}}
    return out


def _container_result(r: dict) -> tuple[str, dict[str, int], dict] | None:
    """(container id, {item id: n} in it AFTER the call, the result's data) of one store / take / inspect result row
    whose body read the container's screen; None for any other row (a grave is not a chest)."""
    from brain import stash
    if r.get("kind") != "tool_result" or r.get("tool") not in stash.CONTAINER_TOOLS:
        return None
    res = r.get("result") or {}
    d = res.get("data") if isinstance(res.get("data"), dict) else {}
    cid = d.get("container") or (d.get("id") if r.get("tool") == "inspect" else None)
    contents = d.get("contents")
    if not cid or "Gravestone" in str(cid) or not isinstance(contents, list):
        return None
    items: dict[str, int] = {}
    for e in contents:
        iid, name, n = stash._parse(e)
        iid = iid or _item_id(name)
        if iid:
            items[iid] = items.get(iid, 0) + n
    if d.get("item") and isinstance(d.get("inside_now"), (int, float)):  # a one-item store / take: its own count
        items[d["item"]] = int(d["inside_now"])
    return str(cid), items, d


def moved_by(r: dict) -> dict[str, int]:
    """{item id: n} one ok store (+) or take (-) result row moved, from the body's own result (data.item and count for
    one item; data.taken [{item, count}] for a queue: client_mod/scripts/skills.lua store and take)."""
    if r.get("kind") != "tool_result" or r.get("tool") not in ("store", "take"):
        return {}
    res = r.get("result") or {}
    if res.get("ok") is not True:
        return {}
    d = res.get("data") if isinstance(res.get("data"), dict) else {}
    rows = [{"item": d["item"], "count": d.get("count")}] if d.get("item") else [x for x in d.get("taken") or []
                                                                                  if isinstance(x, dict)]
    sign = 1 if r.get("tool") == "store" else -1
    out: dict[str, int] = {}
    for x in rows:
        iid = x.get("item") or _item_id(x.get("name"))
        if iid and int(x.get("count") or 0):
            out[iid] = out.get(iid, 0) + sign * int(x["count"])
    return out


def chests_before(rows: list[dict]) -> dict[str, dict[str, int]]:
    """What each container held just BEFORE his first store or take into it in the run: the body's read of the
    container after that call less what the call moved (the game's own counts, never the model's). The start count of
    a container the harness could not read at the start (out of the 30 m census, or built in the run: 0)."""
    out: dict[str, dict[str, int]] = {}
    for r in rows:
        if r.get("tool") not in ("store", "take") or (r.get("result") or {}).get("ok") is not True:
            continue
        got = _container_result(r)
        if not got or got[0] in out:
            continue
        cid, after, _ = got
        mv = moved_by(r)
        out[cid] = {k: max(0, after.get(k, 0) - mv.get(k, 0)) for k in set(after) | set(mv)}
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


def walk_targets(rows: list[dict]) -> list[dict]:
    """[{ts, position}] of where his walks were headed, from the brain log: a go_to call given a position, the place
    the executor resolved a name to (place_resolved: the game's map data), the body's go_to result (target_position).
    A target given only as a name or an actor id with no position read is left out."""
    out = []
    for r in rows:
        k = r.get("kind")
        p = None
        if k == "place_resolved":
            p = r.get("position")
        elif k == "tool_call" and r.get("tool") == "go_to":
            p = (r.get("args") or {}).get("target")
        elif k == "tool_result" and r.get("tool") == "go_to":
            d = (r.get("result") or {}).get("data")
            p = d.get("target_position") if isinstance(d, dict) else None
        if isinstance(p, (list, tuple)) and len(p) >= 2 and all(isinstance(v, (int, float)) for v in p[:2]):
            out.append({"ts": r.get("ts"), "position": list(p)})
    return out


def evidence(rows: list[dict]) -> dict:
    return {"chests": chests_seen(rows), "crafted": crafted_in_run(rows), "chests_before": chests_before(rows),
            "walk_targets": walk_targets(rows)}


def first_done_read(job: dict, start: dict, seen: "_Seen", rows: list[dict], after: float, until: float) -> float | None:
    """The time of the earliest get_state reply in the brain log (bridge_recv; a game read like the harness's own, as
    held_in_run reads them) between ``after`` (the last harness read that was not done) and ``until`` (the harness's
    first done read), on which the job reads done by done() itself; None when none does. Only when stands are counted:
    the harness reads every SAMPLE_S, so in run 20261119-060504 the Bone Pickaxe was on him by the brain's read at
    518.1 s and the harness read it at 527.6 s. A read done() cannot decide alone (a chest job's end read) is never
    taken."""
    sent: dict = {}
    for r in rows:
        k, m = r.get("kind"), r.get("msg")
        if k == "bridge_send" and isinstance(m, dict):
            sent[m.get("id")] = m.get("tool")
            continue
        ts = float(r.get("ts") or 0)
        if k != "bridge_recv" or not isinstance(m, dict) or not (after < ts < until):
            continue
        if sent.get(m.get("id")) != "get_state" or m.get("ok") is False or not isinstance(m.get("data"), dict):
            continue
        snap = snapshot(m["data"])
        if snap.get("unread"):
            continue
        snap.update(evidence([x for x in rows if float(x.get("ts") or 0) <= ts]))
        seen.into(snap)
        if done(job, start, snap)[0] is True:
            return ts
    return None


# tool results that name an item he did not gain (eaten, worn, put away, failed) or only looked at
NO_GAIN_TOOLS = {"consume", "equip", "unequip", "store", "drop", "inspect", "look", "explore", "deconstruct"}


def held_in_run(rows: list[dict], snaps: list[dict]) -> dict:
    """What his bag held in the run, from game reads only: peak {item: the most any read of his bag showed} over the
    harness's own get_state reads (snaps) and every get_state / inventory reply in the brain log (bridge_recv); reads
    (how many); gained {item: n} the client's pickups and crafts reported (ok tool results: data.item with its
    count, data.gained, data.collected). His words are never read."""
    peak: dict[str, int] = {}
    reads = 0

    def bag(carried: dict) -> None:
        nonlocal reads
        reads += 1
        for k, v in (carried or {}).items():
            peak[k] = max(peak.get(k, 0), int(v or 0))

    for s in snaps:
        if s and not s.get("unread"):
            bag(s.get("carried") or {})
    gained: dict[str, int] = {}

    def gain(item: Any, n: Any) -> None:
        if isinstance(item, str) and item:
            gained[item] = gained.get(item, 0) + max(1, int(n) if isinstance(n, (int, float)) else 1)

    for r in rows:
        if r.get("kind") == "bridge_recv":
            m = r.get("msg") or {}
            d = m.get("data")
            if m.get("ok") is False or not isinstance(d, dict):
                continue
            if isinstance(d.get("inventory_items"), list) or (
                    any(k in d for k in ("hotbar", "bag", "loadout"))
                    and all(isinstance(d.get(k), list) for k in ("hotbar", "bag", "loadout") if k in d)):
                bag(snapshot(d)["carried"])
        elif r.get("kind") == "tool_result" and r.get("tool") not in NO_GAIN_TOOLS:
            res = r.get("result") or {}
            d = res.get("data") if isinstance(res.get("data"), dict) else {}
            if res.get("ok") is not True:
                continue
            if isinstance(d.get("gained"), dict):
                for k, n in d["gained"].items():
                    gain(k, n)
            for e in d.get("collected") or []:
                if isinstance(e, dict):
                    gain(e.get("item"), e.get("count"))
            if not isinstance(d.get("gained"), dict) and not d.get("collected"):
                gain(d.get("item"), next((d[k] for k in ("gathered", "gained", "count", "crafts")
                                          if isinstance(d.get(k), (int, float)) and d[k] > 0), 1))
    return {"reads": reads, "peak": peak, "gained": gained}


def never_held(end: dict, want: dict) -> str | None:
    """Why he cannot have put any of this want anywhere in the run, from game reads (end["held_in_run"]: no read of
    his bag held it, no pickup or craft gave it, no container his body opened showed it), or None when that is not
    sure."""
    h = end.get("held_in_run") or {}
    if not h.get("reads"):
        return None
    if _want_count(h.get("peak") or {}, want) or _want_count(h.get("gained") or {}, want) \
            or _want_count(end.get("crafted") or {}, want) \
            or any(_want_count(c.get("items") or {}, want) for c in (end.get("chests") or {}).values()):
        return None
    return f"never carried any ({h['reads']} reads of his bag held none; no pickup or craft of it)"


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
    if read.get("no_inventory"):  # the body found it and it holds no inventory: not storage
        return False
    return None


def read_container(reply: Any) -> dict:
    """An `inspect` reply on one container -> {read, items {item id: n}, kind, class, why}. read is False (unread)
    when the body could not find it or found no inventory on it: never an empty chest."""
    r = reply if isinstance(reply, dict) else {}
    d = r.get("data") if isinstance(r.get("data"), dict) else {}
    out = {"kind": d.get("kind"), "class": d.get("class"),
           **{k: d[k] for k in OWNER_KEYS if d.get(k) is not None}}  # the game's owner, when the body read it
    if r.get("ok") is not True or not isinstance(d.get("contents"), list):
        why = r.get("reason") or d.get("detail") or ("no inventory read on it" if r.get("ok") else "no reply")
        if r.get("reason") and d.get("detail"):  # the client's own words on it: "it's 89 m away, beyond 80 m" (000146)
            why = f"{r['reason']}: {d['detail']}"
        # found, and no inventory on it: the game holds nothing in it (his door, 2026-11-17 runs 211950 and 212448)
        none_in = r.get("ok") is True and d.get("contents") is None
        return {**out, "read": False, "why": str(why)[:200], **({"no_inventory": True} if none_in else {})}
    from brain import stash
    items: dict[str, int] = {}
    for e in d["contents"]:
        iid, name, n = stash._parse(e)
        iid = iid or _item_id(name)
        if iid:
            items[iid] = items.get(iid, 0) + n
    return {**out, "read": True, "items": items}


def game_owner(cid: str, start: dict, end: dict) -> tuple[bool | None, str]:
    """Is this container his by the GAME's owner read (the actor's UOwnershipComponent, as the body reported it in an
    inspect, look or store result): True, False, or None when no read of it carried an owner. His = owned by this
    character (mine) or by a character of the same line (start["own_guids"]: the fork, the save it was forked from
    and ClaudeDev; a fork is a new character guid, and the world 'base' crates belong to ClaudeDev: run 015315-N1-I2,
    BP_BaseBuilding_Crate_C_2147472971, OwningCharacterGuid E71C5DC1... in the world save). The client ledger
    (get_state structures "mine") is only the fallback when the game's owner was not read."""
    guids = {str(g).upper() for g in start.get("own_guids") or []}
    for src in ((end.get("chest_end") or {}).get(cid), (end.get("chest_first") or {}).get(cid),
                (end.get("chests") or {}).get(cid), (start.get("chest_start") or {}).get(cid)):
        if not isinstance(src, dict) or not any(src.get(k) is not None for k in OWNER_KEYS[:2]):
            continue
        who = src.get("owner")
        if src.get("mine") is True or who == "yours":
            return True, "owner: yours"
        if src.get("owner_guid") and str(src["owner_guid"]).upper() in guids:
            return True, f"owner: {who or src['owner_guid']} (a character of his line)"
        if src.get("same_account") is True:  # the game's account read: a character of his own account placed it
            return True, f"owner: {who or src.get('owner_guid')}"
        return False, f"owner: {who or src.get('owner_guid')}"
    return None, "owner not read"


def chest_candidates(start: dict, end: dict) -> list[str]:
    """His containers worth an end read: every id a read in the run marked his (start, samples, end) and every one his
    body's own container result marked his (by the game's owner read: game_owner), less those known not to be
    storage."""
    kinds = {**(start.get("container_kinds") or {}), **(end.get("container_kinds") or {})}
    own = set(start.get("own_containers") or []) | set(end.get("own_containers") or [])
    own |= {cid for cid in (end.get("chests") or {}) if game_owner(cid, start, end)[0]}
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


def broken(detail: dict | None) -> bool:
    """A worn piece the game reads as broken (UItem:IsBroken, or durability 0 of a piece that has durability): it
    gives nothing (a broken tunic reads PL 0 in the game, docs/research/2026-11-17-job-end-readability.md)."""
    d = detail or {}
    dur = d.get("durability")
    return bool(d.get("broken")) or (isinstance(dur, (int, float)) and not isinstance(dur, bool) and dur <= 0
                                     and d.get("max_durability") is not None)


def made_here(item: str, guid: str | None, start: dict) -> tuple[bool | None, str]:
    """Whether the worn instance of item is not one he held at the start, from the game's reads only: the start read
    holds none of the item (then any instance of it is new), or the worn instance's UItem.Guid is not among the
    start's instances of it (every one of them read). Else None: the reads cannot tell (a guid unread)."""
    had = (start.get("instances") or {}).get(item)
    if had is None and not count_of(start.get("carried") or {}, item):
        return True, "he held none at the start"
    had = had or [None]
    if not guid or any(g is None for g in had):
        return None, f"cannot tell the worn {item} from the {len(had)} he had at the start (no instance guid read)"
    if guid in had:
        return False, f"the {item} worn is the one he had at the start"
    return True, "a new instance"


def p_worn_made_in_run(spec: dict, start: dict, end: dict) -> tuple[bool | None, str]:
    """Each slot holds one of its items, not broken, made in this run: a craft of it confirmed in the run, and the
    worn instance is not one he held at the start (made_here: by UItem.Guid, or the start read holding none of it).
    A piece carried but not in its loadout slot is not worn. No crafted-by mark exists on an item instance
    (inventory.describe_item has none), and his words are never read. Before 2026-11-18 the rule was 'he holds more
    of it than at the start': a new cowl in the bag and his old one still on passed."""
    short, unread = [], []
    for slot, items in spec.items():
        on = (end.get("worn") or {}).get(slot)
        det = (end.get("worn_detail") or {}).get(slot) or {}
        if not on or on not in items:
            short.append(f"{slot}: {on or 'nothing'} worn")
        elif broken(det):
            short.append(f"{slot}: {on} worn but broken ({det.get('durability')} of {det.get('max_durability')})")
        elif not _crafted(end, on):
            short.append(f"{slot}: {on} worn but no craft of it in this run")
        else:
            new, why = made_here(on, det.get("guid"), start)
            if new is False:
                short.append(f"{slot}: {why} (had at the start)")
            elif new is None:
                unread.append(f"{slot}: {why}")
    if short:
        return False, "; ".join(short + unread)
    if unread:
        return None, "; ".join(unread)
    return True, "all worn, whole and made in the run"


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
    first = end.get("chest_first") or {}  # each one's read the first time a run read listed it near him

    def kind_read(cid: str) -> dict | None:  # the end read decides what it is; else his read of it in the run
        r = reads.get(cid) or {}
        return r if (r.get("read") or r.get("no_inventory") or cid not in first) else first[cid]

    # one truth on whose it is: the game's owner read wins over the client ledger (game_owner)
    theirs = {cid: why for cid in sorted(own) for his, why in [game_owner(cid, start, end)] if his is False}
    own -= set(theirs)
    if not own:
        return False, "the game says none of these is his: " + "; ".join(f"{c} ({w})" for c, w in theirs.items())
    storage = {cid: is_storage(cid, kinds, kind_read(cid)) for cid in sorted(own)}
    if not any(v is not False for v in storage.values()):
        return False, f"none of his containers is storage ({', '.join(sorted(own)[:4])})"
    good = {cid: reads[cid]["items"] for cid, s in storage.items() if s and (reads.get(cid) or {}).get("read")}
    unread = {cid: ((reads.get(cid) or {}).get("why") or "not read")
              + (f"; seen {reads[cid]['seen_m']} m from where he ended" if (reads.get(cid) or {}).get("seen_m") else "")
              for cid, s in storage.items() if s is not False and cid not in good}
    short, doubt = [], []
    used: set[str] = set()
    for want in spec:
        label = want.get("label") or want.get("item")
        n = int(want["count"])
        gained = bool(want.get("gained"))
        no_start: list[str] = []

        def put_in(cid: str, items: dict) -> int:
            """The count in that container; for a 'gained' want, less what it held at the start (the harness's start
            read, else the body's read at his first store or take into it). A container with neither: no start."""
            have = _want_count(items, want)
            if not gained:
                return have
            base = ((start.get("chest_start") or {}).get(cid) or {})
            if base.get("read"):
                return have - _want_count(base.get("items") or {}, want)
            if cid in (end.get("chests_before") or {}):
                return have - _want_count(end["chests_before"][cid], want)
            if have >= n:
                no_start.append(cid)
            return have
        counts = [(cid, put_in(cid, items)) for cid, items in good.items()]
        # one whose start is known and that got enough wins over a fuller one with no start read (run 034838-N1-I2:
        # ...149 held 297 logs, never read before his stores; ...171 went 3 -> 23 by his store's read)
        sure_best = max(((c, v) for c, v in counts if c not in no_start), key=lambda x: x[1], default=(None, 0))
        best = sure_best if sure_best[1] >= n else max(counts, key=lambda x: x[1], default=(None, 0))
        word = " put in during the run" if gained else ""
        if best[1] >= n and best[0] not in no_start:
            used.add(best[0])
            continue
        if no_start:
            doubt.append(f"{label}: {best[1]} in {best[0]}, but what it held at the start was not read")
            continue
        if unread:
            # a pass the reads rule out: he never held any, so nothing of it went into an unread container in the
            # run, and it holds no more than when it was read in the run (fail_certain: the count asked can be
            # neither there nor put in); else unread, with what is known
            sure = never_held(end, want)
            was = {c: _want_count(first[c].get("items") or {}, want) for c in unread
                   if (first.get(c) or {}).get("read")}
            if sure and (gained or (len(was) == len(unread) and max(was.values()) < n)):
                short.append(f"{label}: {best[1]} of {n}{word} in the read ones; fail_certain: {sure}"
                             + ("" if gained else ", and the unread ones held " + "; ".join(
                                 f"{c} {k} when read at {first[c].get('t')} s" for c, k in sorted(was.items())[:3])))
                continue
            doubt.append(f"{label}: {best[1]} of {n}{word} in the read ones; unread: "
                         + "; ".join(f"{c} ({w}{'' if c in was else '; never read in the run'})"
                                     for c, w in sorted(unread.items())[:3])
                         + (f"; he {sure}" if sure else ""))
            continue
        before = [(cid, put_in(cid, opened[cid]["items"])) for cid in good
                  if cid in opened and opened[cid].get("tool") != "take"]
        was = max(before, key=lambda x: x[1], default=(None, 0))
        if was[1] >= n:
            doubt.append(f"{label}: the end read of {was[0]} has {put_in(was[0], good[was[0]])} of {n}{word}, his "
                         f"last open of it ({opened[was[0]].get('tool')}) {was[1]}, and he took nothing out since")
            continue
        short.append(f"{label}: {best[1]} of {n}{word} (best: {best[0]})")
    if theirs:  # what he put in a container that is not his is named, never counted
        short += [f"not his: {c} ({w})" for c, w in theirs.items() if short or doubt]
    if short:
        return False, "; ".join(short + doubt)
    if doubt:
        return None, "unread: " + "; ".join(doubt)
    return True, "in his chest (end read: " + "; ".join(f"{c}, {game_owner(c, start, end)[1]}" for c in sorted(used)) + ")"


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
    why = f"armour PL {on['pl']}, kit {on['kit']}" if not short else "; ".join(short)
    return (not short), why + (vault_target_words(tg, end.get("worn") or {}, cat) if tg.get("vault") else "")


def vault_target_words(tg: dict, worn: dict, cat: dict | None = None) -> str:
    """'; target for Crasorak Kara: armour PL 2 ... (rows: ...)': what a vault-aware gear target asked and from which
    data rows (rung4_gate.gear_target with a vault). The damage type is told, not judged: the goal names armour PL,
    weapon, food and drink."""
    out = f"; target for {tg['vault']}: armour PL {tg['pl']}"
    if tg.get("reachable_pl") is not None and int(tg["reachable_pl"]) < int(tg["pl"]):
        out += f" (gear_plan's data reaches only PL {tg['reachable_pl']} from what he owns or can make: not reachable)"
    if tg.get("kit"):
        out += f", kit {tg['kit']}"
    if tg.get("damage_pref"):
        held = worn.get("HeldRight") or worn.get("held_right")
        entry = (cat.get(held) or {}) if cat is not None and held else _cat_entry(held)
        types = [str(t).rsplit(".", 1)[-1] for t in entry.get("damage_types") or []]
        out += (f"; its enemies are weak to {', '.join(tg['damage_pref'])}, his weapon deals "
                f"{', '.join(types) or 'nothing known'} (told, not judged)")
    if tg.get("rows"):
        out += f" (rows: {' | '.join(tg['rows'])})"
    return out


def _tier(item: str, order: list[str]) -> int:
    word = str(item).rsplit("_", 1)[-1].lower()
    low = [o.lower() for o in order]
    return low.index(word) if word in low else -1


def _tool_rank(item: str, order: list[str]) -> tuple[int, int]:
    """A tool's rank in its family from the game's data (data/items_<build>.json: tier, then power_level, since
    watering cans all read tier 0 and the Rune and Adamant pickaxes share tier 7); an item the catalog does not know
    falls back to its id's last word in the spec's order."""
    e = _cat_entry(item)
    if e:
        t, pl = e.get("tier"), e.get("power_level")
        return (int(t) if isinstance(t, (int, float)) and not isinstance(t, bool) else 0,
                int(pl) if isinstance(pl, (int, float)) and not isinstance(pl, bool) else 0)
    i = _tier(item, order)
    return (i, i)


def p_next_tier_tools(spec: dict, start: dict, end: dict) -> tuple[bool | None, str]:
    """H3: for each tool family he carried at the start, he now carries, unbroken, one of a higher rank (_tool_rank) he
    did not carry then. When he carried none of the families at the start and the spec says from_none, the step up
    from none is any one of each family (the family's first tier or better), new and unbroken. With neither: unread
    (nothing to step up from), never a fail of his."""
    order, out, short = spec.get("order") or [], [], []
    held = end.get("held_detail")
    carried_start = {k: n for k, n in (start.get("carried") or {}).items() if n}
    fams = {f: [k for k in carried_start if matches(k, pat)] for f, pat in spec["families"].items()}
    from_none = not any(fams.values())
    if from_none and not spec.get("from_none"):
        return None, "he carried none of the tool families at the start: nothing to step up from"

    def whole(k: str) -> bool:  # an unbroken stack of k on him at the end (no held_detail read: as carried)
        if held is None:
            return True
        return any(h.get("item") == k and not h.get("broken") for h in held)

    for fam, pat in spec["families"].items():
        had = fams[fam]
        if not had and not from_none:
            continue
        best = max((_tool_rank(k, order) for k in had), default=None)
        top = max(had, key=lambda k: _tool_rank(k, order)) if had else "none"
        cand = sorted((k for k, n in (end.get("carried") or {}).items()
                       if n and matches(k, pat) and k not in had and (best is None or _tool_rank(k, order) > best)),
                      key=lambda k: _tool_rank(k, order))
        good = [k for k in cand if whole(k)]
        if good:
            out.append(f"{fam}: {top} -> {good[0]}")
        elif cand:
            short.append(f"{fam}: {top} -> {cand[0]} broken")
        else:
            short.append(f"{fam}: {top} -> nothing higher")
    head = "carried none of the tool families at the start, so the step up is one of each; " if from_none else ""
    return (not short), head + "; ".join(out + short)


# ------------------------------------------------------------------ the venture ladder's rungs (L2 V1, V2)
def _cat_entry(item: str | None) -> dict:
    from brain import item_stats
    return (item_stats.catalog().get(item or "") or {}) if item else {}


def tool_tier(item: str | None) -> int | None:
    """The game's tier of a tool (data/items_<build>.json `tier`: the field client_mod weapons_data carries and
    gather.lua compares with a rock's DamageModifiers RequiredTier), or None when the catalog does not know the item."""
    e = _cat_entry(item)
    t = e.get("tier")
    return int(t) if isinstance(t, (int, float)) and not isinstance(t, bool) and e else None


def _tagged(item: str, prefix: str) -> bool:
    return str(_cat_entry(item).get("category_tag") or "").startswith(prefix)


def p_made_carried(spec: dict, start: dict, end: dict) -> tuple[bool | None, str]:
    """V1: on him (hotbar, bag or loadout) an instance of an item of the game's category_tag, of tier min_tier or more,
    not broken, made in this run: a craft of it confirmed in the run and an instance he did not hold at the start
    (made_here: by UItem.Guid, or the start read holding none of it). An instance the reads cannot tell: unread."""
    tag, need = spec["category_tag"], int(spec.get("min_tier") or 0)
    label = spec.get("label") or f"a {tag} of tier {need} or better"
    held = [h for h in end.get("held_detail") or [] if _tagged(h["item"], tag)]
    good = [h for h in held if (tool_tier(h["item"]) or 0) >= need]
    if not good:
        have = ", ".join(f"{h['item']} (tier {tool_tier(h['item'])})" for h in held) or "none"
        return False, f"he carries none of {label}; of the kind he carries: {have}"
    short, unread = [], []
    for h in good:
        it, t = h["item"], tool_tier(h["item"])
        if h.get("broken"):
            short.append(f"{it} (tier {t}) broken")
        elif not _crafted(end, it):
            short.append(f"{it} (tier {t}): no craft of it in this run")
        else:
            new, why = made_here(it, h.get("guid"), start)
            if new:
                return True, f"{it} (tier {t}, min {need}) made in this run and carried ({why})"
            (short if new is False else unread).append(f"{it}: {why}" + (" (had at the start)" if new is False else ""))
    if unread:
        return None, "; ".join(unread + short)
    return False, "; ".join(short)


def made_by_him(item: str, guid: str | None, start: dict, end: dict) -> tuple[bool | None, str]:
    """An instance he made: in this run (a craft of it confirmed and made_here), or in an earlier rung of the ladder
    (its UItem.Guid among start["ladder_made"][item], the ladder record of the checkpoint he started from). None when
    the reads cannot tell (a guid unread where it decides). Never his words."""
    ladder = (start.get("ladder_made") or {}).get(item) or []
    if guid and guid in ladder:
        return True, "made by him in an earlier rung (its instance)"
    new = None
    if _crafted(end, item):
        new, why = made_here(item, guid, start)
        if new:
            return True, "made in this run"
        if new is None:
            return None, why
    if ladder and (not guid or None in ladder):
        return None, f"cannot tell the {item} from the one he made in an earlier rung (instance guid unread)"
    if new is False:
        return False, f"the {item} is the one he had at the start"
    return False, f"no craft of {item} in this run, nor one of his from an earlier rung"


@lru_cache(maxsize=1)
def _places():
    from brain.places import Places
    return Places()


def region_power(name: str) -> int | None:
    """The power of a region (data/places_<build>.json `power`), or None for a name the data does not have."""
    r = next((x for x in _places().regions if x.get("name") == name), None)
    p = (r or {}).get("power")
    return int(p) if isinstance(p, (int, float)) and p >= 0 else None


def copper_region(pos: Any, spec: dict) -> dict | None:
    """{region, power} of the region at pos when it is one of spec copper_in (by its region or province name)."""
    if not (isinstance(pos, (list, tuple)) and len(pos) >= 2):
        return None
    r = _places().region_at(pos)
    if not r or not ({r.get("name"), r.get("province")} & set(spec.get("copper_in") or [])):
        return None
    return {"region": r["name"], "power": region_power(r["name"])}


def heading_for(end: dict, spec: dict) -> dict:
    """The copper region he heads for: the region of his latest walk target that is one of copper_in (walk_targets),
    else spec default_region; {region, power, how}."""
    for w in reversed(end.get("walk_targets") or []):
        got = copper_region(w.get("position"), spec)
        if got:
            return {**got, "how": f"his walk to {[round(v) for v in w['position'][:2]]}"}
    d = spec.get("default_region") or "Fractured Plains"
    return {"region": d, "power": region_power(d), "how": "no walk toward a copper region yet: the nearest"}


def entry_read(job: dict, snap: dict, t: float) -> dict | None:
    """The read that put him inside a copper region of the job's venture_gear: {region, power, power_level (the game's,
    the fact recorded), t, position} and what he wore and carried then; None while he is outside them."""
    spec = (job.get("end") or {}).get("venture_gear")
    if not spec or snap.get("unread"):
        return None
    got = copper_region(snap.get("position"), spec)
    if not got:
        return None
    return {**got, "power_level": snap.get("power_level"), "t": round(t, 1), "position": snap.get("position"),
            **{k: snap.get(k) for k in ("worn", "worn_detail", "held_detail", "instances")}}


def p_venture_gear(spec: dict, start: dict, end: dict) -> tuple[bool | None, str]:
    """V2: every armour slot worn, whole and made by him; a weapon (the game's tag spec weapon_tag, so not a pickaxe)
    made by him on him; and the game's power level at least the power of the copper region he heads for (heading_for).
    When a read put him inside a copper region (end["entered"]: entry_read), that read is judged: gear made and power
    level at least the region's power passes; gear not made fails; under the power only spec entry_bar judges it
    (the goal fixes none: null is bar_open, recorded and never a pass or a fail)."""
    at = end.get("entered") or end
    short, unread = [], []
    for slot in spec.get("armour_slots") or []:
        on = (at.get("worn") or {}).get(slot)
        det = (at.get("worn_detail") or {}).get(slot) or {}
        if not on:
            short.append(f"{slot}: nothing worn")
            continue
        if broken(det):
            short.append(f"{slot}: {on} broken")
            continue
        mine, why = made_by_him(on, det.get("guid"), start, end)
        (short if mine is False else unread if mine is None else []).append(f"{slot}: {on}: {why}")
    weapons = [h for h in at.get("held_detail") or [] if _tagged(h["item"], spec.get("weapon_tag") or "Item.Equipment.Weapon.")
               and not h.get("broken")]
    w_read = [(h, made_by_him(h["item"], h.get("guid"), start, end)) for h in weapons]
    if not any(m[0] for _, m in w_read):
        if any(m[0] is None for _, m in w_read):
            unread += [f"weapon {h['item']}: {m[1]}" for h, m in w_read if m[0] is None]
        else:
            short.append("no weapon made by him on him" + (
                " (" + "; ".join(f"{h['item']}: {m[1]}" for h, m in w_read) + ")" if w_read else ""))
    where = ({"region": at["region"], "power": at.get("power"), "how": "entered"} if end.get("entered")
             else heading_for(end, spec))
    power, pl = where.get("power"), at.get("power_level")
    gear = "armour " + ", ".join(f"{s} {(at.get('worn') or {}).get(s)}" for s in spec.get("armour_slots") or [])
    place = f"{where['region']} (power {power})"
    if short:
        return False, "; ".join(short + unread) + f"; bar {place}, power level {pl}"
    if unread:
        return None, "; ".join(unread)
    if power is None:
        return None, f"no power for {where['region']} in the map data"
    if not isinstance(pl, (int, float)):
        return None, "the game's power_level was not read" + (" at the entry" if end.get("entered") else "")
    if end.get("entered"):
        fact = f"entered {place} at power level {pl:g} (t {at.get('t')} s), {gear} and a weapon made by him"
        if pl >= power:
            return True, fact
        bar = spec.get("entry_bar")
        if not isinstance(bar, dict) or bar.get("min_below_power") is None:
            return None, f"bar_open: {fact}; the goal fixes no bar for entering under the region's power"
        need = power - int(bar["min_below_power"])
        return pl >= need, f"{fact}; entry bar power level {need}"
    bar = spec.get("entry_bar")  # the goal's V2 bar (decided 2026-11-18): power level >= the region's power minus 1
    need = power - int(bar["min_below_power"]) if isinstance(bar, dict) and bar.get("min_below_power") is not None else power
    if pl < need:
        return False, f"power level {pl:g} of {need} for {place} (power {power}), headed there by {where['how']}"
    return True, f"power level {pl:g} (bar {need}) for {place} ({where['how']}), {gear} and a weapon, made by him"


# ------------------------------------------------------------------ the vault (goal item 4: Crasorak Kara, stages K1-K4)
VAULT_ENDS = ("at_place", "in_vault", "boss_killed", "left_vault")


def _xy(p: Any) -> list[float] | None:
    return [float(p[0]), float(p[1])] if isinstance(p, (list, tuple)) and len(p) >= 2 and all(
        isinstance(v, (int, float)) and not isinstance(v, bool) for v in p[:2]) else None


# Inside a vault, read from the game's state that is true there (DISCOVERIES 2026-11-19, build 26670300): the game's own
# flag in_vault (ULocalPlayerAudioSubsystem.bInDungeon) read FALSE inside Crasorak Kara on the headless client, while
# the vault registry box (get_state vault, sense.vault_here: AGameplayObjectRegistry.Dungeons[i].Box holds his
# position) named it. So: inside = a vault box holds him (its name read), else the last door jump of the run landed
# him where a door that leads to a vault arrives (a move of over VAULT_JUMP_M between two reads, landing within
# VAULT_ARRIVE_R_M of that door row's arrives_at), else the flag when it reads true (a vault, unnamed). Outside = a
# vault read happened (in_vault read) with no box holding him and no such jump. in_vault stays a field, never required.
VAULT_JUMP_M = 200.0  # the door jump of 19 Nov was 2211 m; reads 3 s apart cannot walk 200 m
VAULT_ARRIVE_R_M = 60.0  # the probe's settled spot was 44.7 m from the door's arrives_at (after 25 s of path tries)


def vault_place(snap: dict, jumps: Any = ()) -> dict:
    """{inside: True | False | None, vault: name | None, how: words} for one read (snapshot() fields), given the door
    jumps of the run up to it (_Seen.jumps)."""
    name, flag = snap.get("vault"), snap.get("in_vault")
    flag_words = f"; the game's in_vault flag reads {str(flag).lower()}" if isinstance(flag, bool) else ""
    if name:
        return {"inside": True, "vault": name, "how": f"the {name} registry box holds him{flag_words}"}
    last = jumps[-1] if jumps else None
    if last and last.get("into"):
        return {"inside": True, "vault": last["into"],
                "how": (f"a {last.get('m')} m door jump landed him {last.get('arrives_m')} m from where the "
                        f"{(last.get('door') or {}).get('name')} door arrives, in {last['into']} (no vault box read)"
                        + flag_words)}
    if flag is True:
        return {"inside": True, "vault": None, "how": "the game's in_vault flag reads true; no vault box names it"}
    if flag is False:
        return {"inside": False, "vault": None, "how": "no vault box holds him and no door jump took him in"
                + flag_words}
    return {"inside": None, "vault": None, "how": "no vault read (get_state has neither in_vault nor vault)"}


def _place_of(r: dict) -> dict:
    """A trace row's or a kill's place: as run_job stored it (inside, inside_vault), else read from its raw fields."""
    if "inside" in r:
        return {"inside": r.get("inside"), "vault": r.get("inside_vault"), "how": r.get("how") or ""}
    return vault_place(r)


def p_at_place(spec: dict, start: dict, end: dict) -> tuple[bool | None, str]:
    """He stands within spec r_m of a place: the door named spec door when the read lists its row (its actor_position,
    else position: the game's), else spec at (the data's, from his body's earlier reads). His position is the game's."""
    me = _xy(end.get("position"))
    if me is None:
        return None, "no position in the read"
    r_m = float(spec.get("r_m", 10))
    door = spec.get("door")
    rows = [e for e in end.get("vault_rows") or [] if door and e.get("name") == door
            and _xy(e.get("actor_position") or e.get("position"))]
    at = _xy(spec.get("at"))
    if rows:
        row = min(rows, key=lambda e: math.dist(_xy(e.get("actor_position") or e.get("position")), at or me))
        target, how = _xy(row.get("actor_position") or row.get("position")), f"the {door} row ({row.get('id')})"
    elif at:
        target, how = at, f"{[round(v, 1) for v in at]} (data; no {door} row in this read)" if door else "the data's spot"
    else:
        return None, f"no {door} row in the read and no 'at' in the spec"
    dist = math.dist(me, target)
    pl = vault_place(end, end.get("jumps") or ())
    inside = f" (inside {pl['vault'] or 'a vault'}: {pl['how']})" if pl["inside"] else ""
    return dist <= r_m, f"{dist:.1f} m from {how}, within {r_m:g}{inside}"


def p_in_vault(spec: Any, start: dict, end: dict) -> tuple[bool | None, str]:
    """Inside a vault, and for spec vault that one, by vault_place: the registry box that holds him (get_state vault),
    else the run's last door jump into a vault, else the game's flag when true. in_vault false is not 'outside' on its
    own (it read false inside Crasorak Kara). A vault unnamed reads unread: never a pass on a guess."""
    want = spec.get("vault") if isinstance(spec, dict) else None
    pl = vault_place(end, end.get("jumps") or ())
    if pl["inside"] is None:
        return None, pl["how"]
    if pl["inside"] is False:
        return False, f"outside any vault: {pl['how']}"
    v = pl["vault"]
    if not want:
        return True, f"inside {v or 'a vault'}: {pl['how']}"
    if v is None:
        return None, f"inside a vault, but the registry names none (sense.vault_list complete=false?): {want} unread"
    return v == want, f"inside {v}" + ("" if v == want else f", not {want}") + f": {pl['how']}"


@lru_cache(maxsize=1)
def _bestiary() -> dict:
    try:
        d = json.loads((ROOT / "data" / "bestiary.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return d.get("creatures") or {} if isinstance(d, dict) else {}


def _norm(s: Any) -> str:
    return "".join(ch for ch in str(s or "").lower() if ch.isalnum())


def class_stem(cls: Any) -> str | None:
    """A game class word as the bestiary keeps it (sense.clean_class without the spaces): BP_AI_RuntGoblin_Character_C
    -> RuntGoblin."""
    if not cls:
        return None
    s = re.sub(r"^BP_AI_|^BP_", "", str(cls))
    s = re.sub(r"_C$", "", s)
    s = re.sub(r"_Character$", "", s)
    s = re.sub(r"_\d+$", "", s)
    return s or None


def creature_names(name: str, cls: str | None = None) -> set[str]:
    """Every name a creature goes by, normalised: the bestiary entry's name, title, aliases and game class stems
    (data/bestiary.json class_names), and spec class when given (its class word read live)."""
    e = _bestiary().get(name) or next((v for v in _bestiary().values() if _norm(v.get("name")) == _norm(name)), None) or {}
    out = {_norm(n) for n in [name, e.get("name"), e.get("title"), *(e.get("aliases") or []),
                              *(e.get("class_names") or [])] if n}
    if cls:
        out.add(_norm(class_stem(cls) or cls))
    return out


def _kill_key(k: dict) -> tuple:
    return (k.get("creature"), k.get("class"), k.get("iso"), k.get("mine"))


def p_boss_killed(spec: dict, start: dict, end: dict) -> tuple[bool | None, str]:
    """A kill in the run (a recent_kills row the start read did not hold) of spec creature: by its game class or its
    name, matched to the bestiary entry (creature_names); spec mine: his own kill (the fatal hit's instigator);
    spec vault: the first read that listed it had him in that vault (run_job keeps every kill a sample saw in
    kills_seen, with that read's in_vault, vault and vault_place: inside, inside_vault)."""
    want = spec.get("creature")
    names = creature_names(want, spec.get("class"))
    before = {_kill_key(k) for k in start.get("recent_kills") or []}
    seen = end.get("kills_seen")
    if seen is None:
        pl = vault_place(end, end.get("jumps") or ())
        seen = [{**k, "in_vault": end.get("in_vault"), "vault": end.get("vault"), "inside": pl["inside"],
                 "inside_vault": pl["vault"]} for k in end.get("recent_kills") or []]
    new = [k for k in seen if _kill_key(k) not in before]
    hits = [k for k in new if _norm(k.get("creature")) in names or _norm(class_stem(k.get("class"))) in names]
    if not hits:
        others = ", ".join(sorted({str(k.get("creature")) for k in new})[:6])
        return False, f"no kill of {want} in the run" + (f" (killed: {others})" if others else "")
    if spec.get("mine"):
        mine = [k for k in hits if k.get("mine") is True]
        if not mine:
            return False, f"{want} died, not by his hand (killed_by {hits[0].get('killed_by')})"
        hits = mine
    vault = spec.get("vault")
    if vault:
        places = [(k, _place_of(k)) for k in hits]
        inside = [k for k, pl in places if pl["inside"] is True and pl["vault"] == vault]
        if not inside:
            if any(pl["inside"] is True and pl["vault"] is None for _, pl in places):
                return None, f"{want} killed inside a vault the registry did not name: {vault} unread"
            if all(pl["inside"] is None for _, pl in places):
                return None, f"{want} killed; no vault read at that read"
            return False, f"{want} killed outside {vault} ({places[0][1]['vault'] or 'no vault'})"
        hits = inside
    k = hits[0]
    return True, (f"{k.get('creature')} ({k.get('class') or 'class unread'}) killed {k.get('iso')}"
                  + (" by him" if k.get("mine") else "") + (f" in {vault}" if vault else ""))


def p_left_vault(spec: Any, start: dict, end: dict) -> tuple[bool | None, str]:
    """He was inside (a read in the run that vault_place put inside, and for spec vault that vault) and the last read
    has him outside. run_job keeps every read's place in vault_trace (at each change)."""
    want = spec.get("vault") if isinstance(spec, dict) else None
    trace = end.get("vault_trace")
    if trace is None:  # a read on its own (no run around it): only itself
        trace = [{"t": None, "in_vault": end.get("in_vault"), "vault": end.get("vault")}]
    trace = [{**r, "inside": pl["inside"], "inside_vault": pl["vault"]} for r in trace
             if (pl := _place_of(r))["inside"] is not None]
    if not trace:
        return None, "no vault read in the run"
    ins = [i for i, r in enumerate(trace) if r["inside"] is True]
    if not ins:
        return False, "never inside a vault in the run"
    named = [i for i in ins if trace[i].get("inside_vault") == want] if want else ins
    if not named:
        if any(trace[i].get("inside_vault") is None for i in ins):
            return None, f"inside a vault the registry did not name: {want} unread"
        return False, f"inside {trace[ins[0]].get('inside_vault')}, never {want}"
    last = trace[-1]
    if last["inside"] is True:
        return False, "still inside at the last read"
    return True, f"inside{' ' + want if want else ''} at t {trace[named[0]].get('t')} s, outside at the last read"


PREDICATES = {"worn_made_in_run": p_worn_made_in_run, "in_own_chest": p_in_own_chest, "carried_gain": p_carried_gain,
              "made_in_run": p_made_in_run, "near_start_m": p_near_start_m,
              "consumables_carried": p_consumables_carried, "gear_target": p_gear_target,
              "next_tier_tools": p_next_tier_tools, "made_carried": p_made_carried, "venture_gear": p_venture_gear,
              "at_place": p_at_place, "in_vault": p_in_vault, "boss_killed": p_boss_killed, "left_vault": p_left_vault}


def rung_job(job: dict, rung: str) -> dict:
    """The job as one rung of its ladder trials it: the job's line and work tools, the rung's end and start (from), no
    interruption. A SystemExit for a rung the job does not have."""
    rungs = job.get("rungs") or {}
    r = rungs.get(rung)
    if not r:
        raise SystemExit(f"job {job.get('id')} has no rung {rung!r} (have {', '.join(rungs) or 'none'})")
    return {**{k: v for k, v in job.items() if k != "rungs"}, "rung": rung, "end": r["end"], "start": r["from"],
            "not_carried_at_start": r.get("not_carried_at_start") or [], "interrupt_from": None,
            "interrupt_trigger": None, "bar": None,
            "bar_note": "a rung has no composed bar of Luis's: human_bar per run", "goal": r.get("goal")}


# ------------------------------------------------------------------ the ladder record beside a rung's checkpoint
def ladder_made(start: dict, end: dict, prev: dict | None) -> dict[str, list]:
    """{item: [guid or None]} he made in the ladder up to the end of this run: the previous rungs' (prev) and every
    instance on him at the end of an item crafted in this run that he did not hold at the start (by its guid; a
    guid unread is kept as None, never matched later)."""
    out = {k: list(v) for k, v in (prev or {}).items()}
    for item, guids in (end.get("instances") or {}).items():
        if not _crafted(end, item):
            continue
        had = set((start.get("instances") or {}).get(item) or [])
        for g in guids:
            if g is not None and g in had:
                continue
            made = out.setdefault(item, [])
            if g not in made:
                made.append(g)
    return out


def ladder_path(label: str, folder: Path | None = None) -> Path:
    from tools import quest_clone
    return Path(folder or quest_clone.CHECKPOINT_DIR) / f"{label}.ladder.json"


def read_ladder(label: str, folder: Path | None = None) -> dict:
    """The ladder record of a checkpoint ({} when it has none: a save that no rung made)."""
    try:
        d = json.loads(ladder_path(label, folder).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return d if isinstance(d, dict) else {}


def write_ladder(rec: dict, label: str, prev: dict, folder: Path | None = None) -> Path:
    """Beside the checkpoint a passing rung saved: what he made in the ladder so far and the runs it comes from."""
    p = ladder_path(label, folder)
    p.parent.mkdir(parents=True, exist_ok=True)
    made = ladder_made(rec.get("state_start") or {}, rec.get("state_end") or {}, (prev or {}).get("made"))
    p.write_text(json.dumps({"job": rec.get("job"), "rung": rec.get("rung"), "checkpoint": label,
                             "runs": list((prev or {}).get("runs") or []) + [rec.get("run")], "made": made},
                            indent=1), encoding="utf-8")
    return p


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


def is_probe(rec: dict) -> bool:
    """A run that ends before the job's end on purpose (--until first_step, mid or own_chest: a checkpoint probe):
    never a trial."""
    return (bool(rec.get("probe")) or rec.get("until") in ("first_step", OWN_CHEST)
            or str(rec.get("until") or "").startswith("mid"))


def until_ok(spec: str | None) -> bool:
    """done, first_step, resumed, own_chest, mid, or mid:LO-HI (0 <= LO < HI <= 1)."""
    if spec in UNTILS:
        return True
    try:
        return mid_range(spec) is not None
    except ValueError:
        return False


def mid_range(spec: str | None) -> tuple[float, float] | None:
    """(lo, hi) of a 'mid' until: the share of the job's asked units got at which a probe ends; None for any other.
    A ValueError for a 'mid' spec that does not parse."""
    s = str(spec or "")
    if s == "mid":
        return MID_DEFAULT
    if not s.startswith("mid:"):
        return None
    lo, sep, hi = s[4:].partition("-")
    lo_f, hi_f = float(lo), float(hi) if sep else float("nan")
    if not (0.0 <= lo_f < hi_f <= 1.0):
        raise ValueError(f"mid range {s[4:]!r}: want LO-HI with 0 <= LO < HI <= 1")
    return lo_f, hi_f


def save_ok(rec: dict, until: str | None) -> tuple[bool, str]:
    """May this trial's next save be kept as the --save-as checkpoint, and why. mid: only when the END read (after
    the brain and his last job were stopped, just before the save) has the share inside the window and nothing of
    the job stored in the run (window 1118d: job_n1_mid was kept with the whole job carried)."""
    lo_hi = mid_range(until) if str(until or "").startswith("mid") else None
    if lo_hi:
        m = rec.get("mid") or {}
        return bool(m.get("ok")), m.get("why") or "no mid read"
    if until == OWN_CHEST:
        oc = rec.get("own_chest") or {}
        return bool(oc.get("ok")), oc.get("why") or "no own-chest read"
    if until == "first_step":
        return rec.get("ended") == "first step", f"ended {rec.get('ended')}"
    if rec.get("rung") and rec.get("job_done"):
        # a rung's checkpoint stands for a PASSING run of it (goal: the venture ladder; rule 8): its end read, and the
        # whole verdict (time, misses, stands, counted)
        v = rec.get("verdict") or verdict(rec)
        if not v.get("pass"):
            return False, "rung done but the run did not pass: " + ", ".join(
                k for k, ok in (v.get("bars") or {}).items() if not ok)
        return True, f"rung {rec['rung']} passed"
    return bool(rec.get("job_done")), "job done" if rec.get("job_done") else f"job not done ({rec.get('ended')})"


def mid_read(job: dict, start: dict, end: dict, rows: list[dict], t0: float, lo_hi: tuple[float, float]) -> dict:
    """The end read of a mid probe: progress (the game's: carried more than at the start plus stored), whether any
    asked item was stored in the run (first_deposit), and whether that is a checkpoint (ok) with why."""
    share = progress(job, start, end, rows)
    dep = first_deposit(rows, job, t0)
    lo, hi = lo_hi
    if share is None:
        ok, why = False, "progress unread at the end"
    elif dep is not None:
        ok, why = False, f"he stored some of the job at {dep} s: not a point before the first deposit"
    elif not lo <= share <= hi:
        ok, why = False, f"progress {share} at the end read, outside {lo}-{hi}"
    else:
        ok, why = True, f"progress {share} in {lo}-{hi}, nothing of the job stored"
    return {"progress": share, "deposited": dep is not None, "ok": ok, "why": why,
            "carried": {w["item"]: count_of(end.get("carried") or {}, w["item"]) for w in _chest_wants(job)}}


def self_owned(src: Any, self_guid: str | None) -> bool | None:
    """Is this read's container HIS, this character's, by the game's owner read: True, False, or None when the read
    carried no owner. Stricter than game_owner: a character of his line (ClaudeDev, the save he was forked from) or of
    his account is not him (a fork finds ClaudeDev's crates "ClaudeDev's, not mine")."""
    if not isinstance(src, dict) or not any(src.get(k) is not None for k in ("owner", "owner_guid", "mine")):
        return None
    if src.get("owner") == "yours" or (src.get("mine") is True and not src.get("copied_from")):
        return True
    g = src.get("owner_guid")
    return bool(g and self_guid and str(g).upper() == str(self_guid).upper())


def own_chest_read(job: dict, start: dict, snap: dict) -> dict:
    """Every container a read of the run carried the game's owner for, split: his ({id: {items: the asked kinds put in
    after the line, owner}}) and others ({id: owner}). The items come from the newest read of it: the end read
    (chest_end, when it read), else his body's last store/take/inspect result (chests), else the harness's first
    read (chest_first); for a 'gained' want, less what the start read (chest_start) found in it."""
    me = start.get("self_guid")
    wants = _chest_wants(job)
    srcs = [snap.get("chest_end") or {}, snap.get("chests") or {}, snap.get("chest_first") or {},
            start.get("chest_start") or {}]
    his: dict[str, dict] = {}
    others: dict[str, str] = {}
    for cid in sorted({c for src in srcs for c in src}):
        owner_src = next((src[cid] for src in srcs if self_owned(src.get(cid), me) is not None), None)
        if owner_src is None:
            continue
        who = owner_src.get("owner") or owner_src.get("owner_guid") or "unnamed"
        if not self_owned(owner_src, me):
            others[cid] = str(who)
            continue
        end_r = srcs[0].get(cid) or {}
        items_src = end_r if end_r.get("read") else (srcs[1].get(cid) or srcs[2].get(cid) or {})
        items = items_src.get("items") or {}
        base = (start.get("chest_start") or {}).get(cid) or {}
        got = {}
        for w in wants:
            n = _want_count(items, w)
            if w.get("gained") and base.get("read"):
                n -= _want_count(base.get("items") or {}, w)
            if n > 0:
                got[w["item"]] = n
        his[cid] = {"items": got, "owner": str(who)}
    return {"his": his, "others": others}


def own_chest_check(job: dict, start: dict, snap: dict, rows: list[dict], ended: str | None = None) -> dict:
    """The read of an own_chest probe: ok when a container of HIS (self_owned) holds an asked item put in after the
    line and the job is not done (progress under 1, read from the game); why in either case. ended: how the run ended,
    for a probe that ends without it ("he never made a chest of his own: ...")."""
    r = own_chest_read(job, start, snap)
    share = progress(job, start, snap, rows)
    holding = {cid: v for cid, v in r["his"].items() if v["items"]}
    out = {"progress": share, "his": r["his"], "others": r["others"], "ok": False}
    if holding:
        cid = max(holding, key=lambda c: sum(holding[c]["items"].values()))
        out.update(container=cid, items=holding[cid]["items"], owner=holding[cid]["owner"])
        if share is None:
            out["why"] = f"his own {cid} holds {holding[cid]['items']}, but progress is unread"
        elif share >= 1 or done(job, start, snap)[0] is True:
            out["why"] = f"the job was done (progress {share}): not a point before the job's end"
        else:
            out.update(ok=True, why=f"his own {cid} (owner: {holding[cid]['owner']}) holds {holding[cid]['items']}; "
                                    f"progress {share}")
        return out
    tail = [f"the run ended {ended}"] if ended else []
    said = [str(x.get("text") or (x.get("args") or {}).get("text")) for x in rows
            if x.get("kind") == "say" and (x.get("text") or (x.get("args") or {}).get("text"))]
    if said:
        tail.append(f'his last words: "{said[-1][:200]}"')
    if r["his"]:
        out["why"] = "; ".join([f"he made a chest of his own ({', '.join(sorted(r['his']))}) but nothing the job "
                                "asks for went into it"] + tail)
        return out
    used = sorted(set(snap.get("chests") or {}) | set(r["others"]))
    what = ("he used " + ", ".join(f"{c} (owner: {r['others'].get(c, 'not read')})" for c in used)
            if used else "he used no container")
    builds = sum(1 for x in rows if x.get("kind") == "tool_call" and x.get("tool") == "build")
    what += f"; {builds} build call(s)" if builds else "; no build call"
    out["why"] = "he never made a chest of his own: " + "; ".join([what] + tail)
    return out


def wait_nav(check, sleep, max_s: float = 150.0, step_s: float = 5.0) -> str | None:
    """Wait for the nav helper to offer routes (check: chat_ladder.nav_not_ready); None once it does, else the last
    reason. Window 1118d I4: the helper is stopped at every server start (tools/nav_reset.ps1) and the watchdog may
    restart it only 3 times in 30 min, so the fourth window's preflight met a 90 s old heartbeat and skipped."""
    waited = 0.0
    why = check()
    while why and waited < max_s:
        sleep(step_s)
        waited += step_s
        why = check()
    return why


def sender_fault(error: str | None) -> bool:
    """A trial error that every later trial on this server run would meet too (the test sender is unproven)."""
    return "sender:" in str(error or "")


def not_counted(rec_or_job: dict, state_start: dict | None = None) -> str | None:
    """Why a trial does not count, or None. With a run record alone: what it says (failure_ledger.scan's argument),
    or that its end state was unread. With a job and its start state: the items it must not start with that he holds
    (a head start, as quest_run.not_counted)."""
    if state_start is None:
        if rec_or_job.get("not_counted"):
            return rec_or_job["not_counted"]
        if is_probe(rec_or_job):  # failure_ledger.scan took probe 20261118-014312-N1 for a failed trial
            return f"a checkpoint probe (--until {rec_or_job.get('until')}), not a trial"
        return f"end state unread: {rec_or_job['unread']}" if rec_or_job.get("unread") else None
    held = {k: n for k, n in (state_start.get("carried") or {}).items() if n
            and any(matches(k, p) for p in rec_or_job.get("not_carried_at_start") or [])}
    return ("held at the start: " + ", ".join(f"{k} x{n}" for k, n in sorted(held.items()))) if held else None


# ------------------------------------------------------------------ the world a trial needs
# A job whose end needs things the WORLD must hold (L1: about 22 wild flax roots, 1 a root, gone for over an hour once
# picked) names them in data/jobs.json world_needs: [{resource, match?, at_least, within_m, of}]. Before the brain
# starts and the ask is sent, the standing sources are counted by the body's own census (client_bridge census ->
# sense.census, resources only; a picked spawner reads available = false). Short, the ask is never sent and the trial
# is recorded as not counted, a fault of the run, never his (six I4 trials of 18-19 Nov were voided after the fact for
# a false flax precondition). A read that cannot say (census failed, no point, the cap cut rows) refuses the same way.
def deadline_of(job: dict, cli: float | None = None) -> float:
    """A trial's deadline: --deadline when given, else the job's deadline_s, else DEADLINE_S."""
    if cli is not None:
        return float(cli)
    return float(job.get("deadline_s") or DEADLINE_S)


def home_of(raw: dict | None, snap: dict) -> tuple[list[float] | None, str]:
    """(where his home is, from what): the base of his get_state my_bases with the most pieces (his placement
    ledger, clustered), else where the start read has him (no base read)."""
    bases = [b for b in (raw or {}).get("my_bases") or [] if isinstance(b, dict) and _xy(b.get("centre"))]
    if bases:
        b = max(bases, key=lambda x: int(x.get("pieces") or 0))
        return _xy(b["centre"]), f"his base of {b.get('pieces')} pieces (my_bases)"
    pos = _xy(snap.get("position"))
    return (pos, "where he starts (no my_bases in the start read)") if pos else (None, "no base and no position read")


def need_centre(need: dict, raw: dict | None, snap: dict) -> tuple[list[float] | None, str]:
    """The point a need counts around: of 'home' (home_of), 'start' (his start position) or [x, y]."""
    of = need.get("of", "home")
    if isinstance(of, (list, tuple)):
        return _xy(of), "a fixed point"
    if of == "home":
        return home_of(raw, snap)
    pos = _xy(snap.get("position"))
    return (pos, "where he starts") if of == "start" and pos else (None, f"no point for of={of!r}")


def _census_data(reply: Any) -> tuple[dict | None, str | None]:
    if not isinstance(reply, dict):
        return None, "no census reply"
    if reply.get("ok") is False:
        d = reply.get("data") if isinstance(reply.get("data"), dict) else {}
        return None, "census failed: " + str(reply.get("reason") or d.get("detail") or "?")
    return (reply["data"] if isinstance(reply.get("data"), dict) else reply), None


def world_count(io, need: dict, raw: dict | None, snap: dict) -> dict:
    """One world need read: {resource, match, at_least, within_m, of, centre, centre_from, standing, picked, read,
    why?, census {radius_m, rows, total, cut, farthest_m}}. standing = the census resource rows of the kind (match in
    class, name, item or id, case-blind) within within_m (2D) of the centre that do not read available = false."""
    res = str(need.get("resource") or "")
    match = str(need.get("match") or res).lower()
    want, within = int(need.get("at_least") or 0), float(need.get("within_m") or 0)
    out: dict = {"resource": res, "match": match, "at_least": want, "within_m": within, "of": need.get("of", "home"),
                 "standing": 0, "picked": 0, "read": False}
    centre, frm = need_centre(need, raw, snap)
    out.update(centre=centre, centre_from=frm)
    pos = _xy(snap.get("position"))
    if centre is None or pos is None:
        out["why"] = frm if centre is None else "no position in the start read"
        return out
    radius = round(within + math.dist(pos, centre) + 5.0, 1)  # the census counts from him: reach the far side
    try:
        reply = io.census({"radius_m": radius, "max": WORLD_CENSUS_MAX, "kinds": {"resources": True},
                           "lean": True, "foliage": False})
    except Exception as exc:
        reply = {"ok": False, "reason": repr(exc)[:200]}
    d, err = _census_data(reply)
    if err:
        out["why"] = err
        return out
    rows = [x for x in d.get("resources") or [] if isinstance(x, dict)]
    total = (d.get("totals") or {}).get("resources")
    cut = isinstance(total, int) and total > len(rows)
    dists = [float(x["distance"]) for x in rows if isinstance(x.get("distance"), (int, float))]
    out["census"] = {"radius_m": radius, "rows": len(rows), "total": total, "cut": cut,
                     "farthest_m": max(dists, default=None)}
    for x in rows:
        if match not in " ".join(str(x.get(k) or "") for k in ("class", "name", "item", "id")).lower():
            continue
        at = _xy(x.get("position"))
        if at is None or math.dist(at, centre) > within:
            continue
        out["picked" if x.get("available") is False else "standing"] += 1
    if cut and out["standing"] < want:
        out["why"] = (f"the census listed {len(rows)} of {total} resources within {radius:.0f} m of him (its cap): "
                      f"{out['standing']} {res} counted, the rest unseen")
        return out
    out["read"] = True
    return out


def world_needs_for(job: dict, step: str | None = None) -> list[dict]:
    """The job's world_needs that hold for this trial: every one for a whole trial (and its probes); for a step trial
    only a need with steps: true or naming the step. A step from a mid-job checkpoint stands in the world its run
    saved (rule 8), with part of the job got: as a head start, a whole job's need is not the step's."""
    return [n for n in job.get("world_needs") or [] if isinstance(n, dict) and (
        not step or n.get("steps") is True or step in (n.get("steps") if isinstance(n.get("steps"), list) else []))]


def world_check(io, job: dict, raw: dict | None, snap: dict, step: str | None = None) -> dict | None:
    """None when no world_needs hold for the trial (world_needs_for). Else {ok, needs: [world_count ...], why}: ok
    when every need reads and stands at its at_least; why names each one short or unread ('world short: flax 14 of 22
    within 350 m of home')."""
    needs = world_needs_for(job, step)
    if not needs:
        return None
    counts = [world_count(io, n, raw, snap) for n in needs]
    whys = []
    for c in counts:
        where = f"within {c['within_m']:.0f} m of {c['of'] if isinstance(c['of'], str) else c['centre']}"
        if not c["read"]:
            whys.append(f"world unread: {c['resource']} {where}: {c.get('why')}")
        elif c["standing"] < c["at_least"]:
            cz = c.get("census") or {}
            whys.append(f"{WORLD_SHORT}: {c['resource']} {c['standing']} of {c['at_least']} {where}"
                        + (f" ({c['picked']} picked)" if c["picked"] else "")
                        + f" [census {cz.get('radius_m')} m from him: {cz.get('rows')} resources, farthest "
                          f"{cz.get('farthest_m')} m]")
    return {"ok": not whys, "needs": counts, "why": "; ".join(whys) or None}


def world_short_record(job: dict, opts: dict, t0: float, start: dict, check: dict, ask_cleared: Any) -> dict:
    """The record of a trial whose ask was never sent: the world lacks what the job needs (a run fault, never his)."""
    step, rung = opts.get("step"), job.get("rung")
    why = check["why"]
    return {"run": time.strftime("%Y%m%d-%H%M%S", time.gmtime(t0)) + f"-{job['id']}" + (f"-{rung}" if rung else "")
            + (f"-{step}" if step else ""),
            "item": f"job: {job['id']}" + (f" / {rung}" if rung else "") + (f" / {step}" if step else ""),
            "kind": "interrupt" if step else "job", "job": job["id"], "step": step, "held_out": bool(job.get("held_out")),
            "until": opts.get("until") or ("resumed" if step else "done"), "character": opts.get("character"),
            "checkpoint": opts.get("checkpoint"), "holder": opts.get("holder"), "lines": [], "ended": WORLD_SHORT,
            "wall_s": 0.0, "active_s": 0.0, "done": False, "job_done": False,
            "done_why": "the ask was never sent: " + why, "state_start": start, "world": check,
            "not_counted": why + " (a fault of the run, not his: the ask was never sent)",
            "misses": {"n": 0, "list": []}, "haiku": 0, "sonnet": 0, "usd": 0.0, "brain_logs": [],
            "ask_store": ask_cleared,
            "verdict": {"pass": False, "bars": {"world": False, "counted": False}, "misses": [], "truth": "not run"}}


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


def first_work(calls: list[dict], job: dict) -> float | None:
    """When his first work call STARTED (seconds into the run), whatever it returned: the moment a `work:S` trigger
    counts from."""
    return next((round(float(c["t"]), 1) for c in calls if _work_call(c, job.get("work_tools"))), None)


def resumed(calls: list[dict], interruption: dict, work_tools=None, lines: list[dict] | None = None,
            serves=None) -> dict:
    """Did he take the job up again after the interruption: the first work call that STARTED after it cleared
    (t_clear; seconds into the run), or one he started while it lasted and that was still running when it cleared and
    then ended ok (through: he kept the job going through it; run 034838-N1-I2 stored stone through the fight and was
    in a store when it cleared, with nothing left to start after); how many seconds after, and whether a line from the
    player came in between (lines: [{t, line}] sent after the first). serves(call) (I4, I5: serves_test): only a call
    that moved the job by the game's reads counts; upkeep or fuel does not (run 021010-N1-I5 took a 3-ash pickup for
    a fire as the resume). first_work_call: the first work call after the clear, serving or not."""
    clear = interruption.get("t_clear")
    if clear is None:
        return {"resumed": False, "why": "the interruption has not cleared"}
    clear = float(clear)
    put = float(interruption.get("t_put") if interruption.get("t_put") is not None else clear)
    ok_ = serves or (lambda c: True)
    through = next((c for c in calls if _work_call(c, work_tools) and put <= float(c.get("t") or 0) < clear
                    and c.get("ok") is True and c.get("dur_s") is not None
                    and float(c["t"]) + float(c["dur_s"]) >= clear and ok_(c)), None)
    after = [c for c in calls if float(c.get("t") or 0) >= clear and _work_call(c, work_tools)]
    nxt = through or next((c for c in after if ok_(c)), None)
    new_lines = [l for l in lines or [] if float(l.get("t") or 0) >= put]
    first = ({"first_work_call": {"tool": after[0].get("tool"), "args": after[0].get("args"), "ok": after[0].get("ok"),
                                  "t": float(after[0]["t"])}} if after else {})
    if nxt is None:
        why = ("no work call after the interruption cleared" if not after else
               "no work call after the interruption cleared moved the job (by the game's reads)")
        return {"resumed": False, "new_line": bool(new_lines), "why": why, **first}
    t = clear if through else float(nxt["t"])
    return {"resumed": True, "t": t, "after_s": round(t - clear, 1), "call": {"tool": nxt.get("tool"), "args": nxt.get("args"),
            "ok": nxt.get("ok"), "t": float(nxt["t"])}, "through": bool(through),
            "new_line": any(float(l.get("t") or 0) <= t for l in new_lines), **first,
            **({"served": True} if serves else {})}


def asked_carried(job: dict, snap: dict | None) -> dict[str, int]:
    """{asked item pattern: n he carries} of a chest job, from one read ({} for a job with no item counts)."""
    return {w["item"]: count_of((snap or {}).get("carried") or {}, w["item"]) for w in _chest_wants(job)}


def unheld_wants(job: dict, snap: dict | None) -> list[str]:
    """The asked kinds he carries none of: the next unit of one needs a new slot (I4 can bite only there)."""
    return [k for k, n in asked_carried(job, snap).items() if n == 0] if snap and not snap.get("unread") else []


def _store_result(rows: list[dict], t0: float, c: dict, tol: float = 0.25) -> dict | None:
    """The result row of a timeline call, by its end (seconds into the run, to the timeline's 0.1 s)."""
    end = t0 + float(c["t"]) + float(c["dur_s"])
    near = [r for r in rows if r.get("kind") == "tool_result" and r.get("tool") == c.get("tool")
            and abs(float(r.get("ts") or 0) - end) <= tol]
    return min(near, key=lambda r: abs(float(r["ts"]) - end)) if near else None


def serves_test(job: dict, rows: list[dict], t0: float, samples: list[dict], intr: dict):
    """serves(call) for resumed() on I4 and I5, read from the game, never from the model's words: a store whose body
    result moved an asked item into a container (moved_by), or any other work call after whose end a read shows the
    units of an asked kind he was short of at the clear above their level then (carried, plus what his stores put in
    since the clear). The level at the clear: intr["at_clear"]["carried"] (I5: the read at ready; I4: the read with
    room), else the first sample at or after the clear. None for a job with no item counts (no test: any work call)."""
    wants = {w["item"]: int(w["count"]) for w in _chest_wants(job)}
    clear = intr.get("t_clear")
    if not wants or clear is None:
        return None
    clear = float(clear)
    base = (intr.get("at_clear") or {}).get("carried")
    if not isinstance(base, dict):
        s0 = next((s for s in samples if s["t"] >= clear), None)
        base = s0["carried"] if s0 else None

    def stored_since(pattern: str, t_rel: float) -> int:
        return sum(n for r in rows if t0 + clear <= float(r.get("ts") or 0) <= t0 + t_rel
                   for k, n in moved_by(r).items() if matches(k, pattern))

    def serves(c: dict) -> bool:
        if c.get("ok") is not True or c.get("dur_s") is None:
            return False
        if c.get("tool") == "store":
            r = _store_result(rows, t0, c)
            return bool(r) and any(n > 0 and any(matches(k, p) for p in wants) for k, n in moved_by(r).items())
        if base is None:
            return False  # no read at the clear: never a resume on a reading that is not there
        end = float(c["t"]) + float(c["dur_s"])
        s = next((s for s in samples if s["t"] >= end), None)
        return bool(s) and any(int(base.get(p, 0)) < n and
                               int(s["carried"].get(p, 0)) + stored_since(p, s["t"]) > int(base.get(p, 0))
                               for p, n in wants.items())
    return serves


def _chest_wants(job: dict) -> list[dict]:
    return [w for w in (job.get("end") or {}).get("in_own_chest") or [] if w.get("item")]


def first_deposit(rows: list[dict], job: dict, t0: float) -> float | None:
    """When his first deposit of an item the job asks for ended (seconds into the run): the first ok store result
    that moved one into a container, by the body's read of the container screen (moved_by)."""
    wants = _chest_wants(job)
    for r in rows:
        mv = moved_by(r)
        if r.get("tool") == "store" and any(n > 0 and any(matches(k, w["item"]) for w in wants) for k, n in mv.items()):
            return round(float(r["ts"]) - t0, 1)
    return None


def progress(job: dict, start: dict, cur: dict | None, rows: list[dict]) -> float | None:
    """The share of the units a chest job asks for that he has got so far, read from the game: what he carries more
    than at the start (a get_state sample) plus what his stores put in a container less what he took out (the
    body's results). None for a job with no item counts, or before a sample was read."""
    wants = _chest_wants(job)
    if not wants or not cur or cur.get("unread"):
        return None
    net: dict[str, int] = {}
    for r in rows:
        for k, n in moved_by(r).items():
            net[k] = net.get(k, 0) + n
    got = asked = 0
    for w in wants:
        n = int(w["count"])
        units = _gain(start, cur, w["item"]) + sum(v for k, v in net.items() if matches(k, w["item"]))
        got += min(n, max(0, units))
        asked += n
    return round(got / asked, 3) if asked else None


TRIGGERS = ("first_step", "first_deposit", "progress", "share", "at", "work")
VALUED = ("progress", "share", "at", "work")  # the kinds that take a number


def trigger_ok(spec: str | None) -> bool:
    """Every alternative of a trigger spec is a known kind, with a number where it takes one."""
    for s in str(spec or "").split("|"):
        kind, sep, val = s.strip().partition(":")
        if kind not in TRIGGERS or (kind in VALUED) != bool(sep):
            return False
        try:
            val and float(val)
        except ValueError:
            return False
    return bool(spec)


def trigger_due(spec: str, first_step_t: float | None, t: float, bar: float | None,
                deposit_t: float | None = None, share: float | None = None, work_t: float | None = None) -> bool:
    """When to put the interruption in: 'first_step' (after his first verified step), 'first_deposit' (after his
    first store of an asked item: first_deposit), 'progress:0.5' (half the asked units got: progress), 'share:0.3'
    (at that share of the job's bar; with no bar, after the first step), 'at:120' (seconds into the run), 'work:4'
    (4 s after his first work call started: first_work; inside the job's first work from a mid-job checkpoint).
    'a|b': whichever comes first."""
    alts = [s.strip() for s in (spec or "first_step").split("|") if s.strip()] or ["first_step"]
    if len(alts) > 1:
        return any(trigger_due(s, first_step_t, t, bar, deposit_t, share, work_t) for s in alts)
    kind, _, val = alts[0].partition(":")
    if kind not in TRIGGERS:
        raise ValueError(f"unknown trigger {alts[0]!r}")
    if kind == "at":
        return t >= float(val)
    if kind == "work":
        return work_t is not None and t >= work_t + float(val)
    if kind == "first_deposit":
        return deposit_t is not None and t >= deposit_t
    if kind == "progress":
        return share is not None and share >= float(val)
    if kind == "share" and bar:
        return t >= float(val) * bar
    return first_step_t is not None and t >= first_step_t


# ------------------------------------------------------------------ the verdict
def verdict(rec: dict) -> dict:
    """A whole job: quest_run's bars (done, <= 1.5x human_bar, <= 1 miss, no stand over 5 s), counted by the job's
    own rule. An interruption step: the interruption took, he took the job up again without a new line, within its
    resume_within_s; misses are recorded and split, and are not a bar of the step."""
    from tools import quest_run as q
    if rec.get("ended") == WORLD_SHORT:  # the ask was never sent: nothing of his to judge
        return {"pass": False, "bars": {"world": False, "counted": False}, "misses": [], "truth": "not run"}
    if rec.get("kind") == "interrupt":
        r = rec.get("resume") or {}
        lim = rec.get("resume_within_s")
        intr = rec.get("interruption") or {}
        # I4: the bag read full AND a call of his met it (bag_watch); every other step: it took
        took = (bool(intr.get("full_read")) and bool(intr.get("bite"))) if rec.get("step") == "I4" else bool(intr.get("took"))
        bars = {"interrupted": took, "resumed": bool(r.get("resumed")),
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
    return (rec.get("job", "?") + (f" / {rec['rung']}" if rec.get("rung") else "")
            + (f" / {rec['step']}" if rec.get("step") else ""))


def all_runs(path: Path | None = None) -> list[dict]:
    p = path or OUT
    if not p.exists():
        return []
    return [json.loads(line) for line in p.read_text(encoding="utf-8").splitlines() if line.strip()]


def scored(recs: list[dict], void: set[str]) -> list[tuple[dict, bool]]:
    """(run, passed) of the trials that say something: to the end (not a first_step probe), counted, not void."""
    return [(r, verdict(r)["pass"]) for r in recs
            if not is_probe(r) and r["run"] not in void and not not_counted(r)]


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


def trace_reads(path: Path | None = None) -> list[dict]:
    p = path or TRACE_READS
    if not p.exists():
        return []
    return [json.loads(line) for line in p.read_text(encoding="utf-8").splitlines() if line.strip()]


def note_trace_read(rec: dict, path: Path | None = None, now: float | None = None) -> None:
    """`show` printed this run's trace: kept, so later trials of the job know it was read before them."""
    p = path or TRACE_READS
    p.parent.mkdir(parents=True, exist_ok=True)
    t = time.time() if now is None else now
    with p.open("a", encoding="utf-8") as f:
        f.write(json.dumps({"at": time.strftime("%Y%m%d-%H%M%S", time.gmtime(t)), "run": rec.get("run"),
                            "job": rec.get("job"), "item": item_key(rec)}) + "\n")


def blind_mark(rec: dict, recs: list[dict], void: set[str], reads: list[dict]) -> dict:
    """What a new record carries about the held-out rule (the first three trials of anything new are scored before
    its trace is read): trial_n, its place among the scored trials of its item, and for the first TRACE_AFTER,
    first_three_blind: True when no trace of a run of the same job was opened with `show` before this run began.
    Only `show` is seen: a trace read another way (the brain log, replay_episode) is not. A probe or a run that does
    not count gets neither (it is not a scored trial)."""
    if rec.get("until") == "first_step" or not_counted(rec):
        return {}
    n = sum(1 for r, _ in scored(recs, void) if item_key(r) == item_key(rec) and r["run"] < rec["run"])
    out: dict = {"trial_n": n + 1}
    if n < TRACE_AFTER:
        start = str(rec["run"])[:15]
        read = [x for x in reads if x.get("job") == rec.get("job") and str(x.get("at", "")) < start]
        out["first_three_blind"] = not read
        if read:
            out["trace_read_before"] = sorted({str(x.get("run")) for x in read})[:5]
    return out


SCORE_KEYS = ("run", "job", "step", "kind", "held_out", "character", "checkpoint", "holder", "ended", "wall_s",
              "done", "done_why", "not_counted", "ratio", "bar_s", "longest_stand_s", "haiku", "sonnet", "usd",
              "trial_n", "first_three_blind")


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
        for k in ("full_read", "bite", "t_ready"):  # I4's fill and bite, I5's ready
            if (rec.get("interruption") or {}).get(k) is not None:
                out["interruption"][k] = rec["interruption"][k]
        if rec.get("ask_restored") is not None:  # beside the verdict, never a bar
            out["ask_restored"] = rec["ask_restored"].get("seen")
    return out


# ------------------------------------------------------------------ putting an interruption in (dev fixtures)
def settled_room(io, before: int, added: int | None, settle_s: float, every_s: float = 0.5) -> int | None:
    """I4: his bag room read again after a grant, once his client shows it: room down to before - added (the server's
    own count of what landed), or, when that count is unread, any change from before. At settle_s the last read
    stands (the trial then says what it read)."""
    want = max(0, before - added) if added is not None else None
    t_end = io.now() + settle_s
    while True:
        r = io.bag_room()
        if r is not None and (r <= want if want is not None else r != before):
            return r
        if io.now() >= t_end:
            return r
        io.sleep(every_s)


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
            room = io.bag_room()
            for _ in range(int(spec.get("rounds", 3))):
                if not room:
                    break
                g = io.fixture("grant", purpose, item=spec["filler"], count=int(room)) or {}
                b, a = g.get("before"), g.get("after")
                added = a - b if isinstance(a, int) and isinstance(b, int) and not isinstance(a, bool) else None
                filled += int(room) if added is None else added
                # the grant is the server's, the read is his client's replica: wait until the read shows it, so a
                # round never grants again on a stale read (an over-grant into a full bag is the fixture's not_added,
                # a void trial) and the last read never calls a full bag not full
                room = settled_room(io, int(room), added, float(spec.get("settle_s", 5.0)))
            left = room
            # full_read: the bag reads full. Not yet an interruption: it took (and later clears) only when a call of
            # his meets it (bag_watch); the fill's own time is never the clear (study 2026-11-18: a false pass)
            out.update(full_read=left == 0, filled=filled, left=left, took=None if left == 0 else False,
                       t_clear=None, how=f"{filled} {spec['filler']} granted; " + (
                           "bag room unread (no hotbar and item page sizes in the inventory read)" if left is None
                           else f"{left} free hotbar and item slot(s) left"))
        elif step == "I5":
            # the old brain stopped, the gap, the new one started, ready (its warm-up logged): times apart (run
            # 021010 took 50 s against a 5 s gap). io.restart_brain gives {ready, t_stopped, t_started, t_ready}
            got = io.restart_brain(float(spec.get("gap_s", 5)))
            info = got if isinstance(got, dict) else {"ready": bool(got)}
            ready = bool(info.get("ready"))
            for k in ("t_stopped", "t_started", "t_ready"):
                if isinstance(info.get(k), (int, float)):
                    out[k] = round(float(info[k]) - t0, 1)
            if ready:
                out.setdefault("t_ready", rel())
            out.update(took=ready, t_clear=out.get("t_ready") if ready else None,
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


GATHER_TOOLS = ("gather", "pickup")


def bag_watch(calls: list[dict], intr: dict, samples: list[dict]) -> dict:
    """I4 read from the game (study 2026-11-18 section 3): the bag read full (full_read) is not yet an interruption.
    bite = the first call of his after the fill that met it: a result with reason inventory_full, or a gather or
    pickup ended short while he held none of an asked kind (moment.unheld): failed, or ok with the next read showing
    none of it. took turns True there. Room read before any call met it: freed_before_bite, never a bite. t_clear =
    the first read at or after the bite with room (samples: [{t, carried, room}], seconds into the run), with the call
    that freed it (the last that ended in between) and that read as at_clear. Never the fill's own time."""
    out = dict(intr)
    if not out.get("full_read") or out.get("t_clear") is not None:
        return out
    put = float(out.get("t_put") or 0)
    unheld = list((out.get("moment") or {}).get("unheld") or [])
    after = [s for s in samples if s["t"] >= put]
    if not out.get("bite"):
        if out.get("freed_before_bite"):
            return out
        room_at = next((s for s in after if (s.get("room") or 0) > 0), None)
        bite = None
        for c in sorted(calls, key=lambda c: float(c.get("t") or 0)):
            if float(c.get("t") or 0) < put or c.get("dur_s") is None:
                continue
            end = round(float(c["t"]) + float(c["dur_s"]), 1)
            if room_at and end > room_at["t"]:
                break
            if c.get("reason") == "inventory_full":
                bite = (c, end, "inventory_full")
            elif c.get("tool") in GATHER_TOOLS and unheld:
                if c.get("ok") is not True:
                    bite = (c, end, f"short: {c.get('reason')} while he held none of {', '.join(unheld)}")
                else:
                    nxt = next((s for s in after if s["t"] >= end), None)
                    if nxt is None:
                        break  # undecided until a read after it ended
                    if all(int(nxt["carried"].get(k, 0)) == 0 for k in unheld):
                        bite = (c, end, f"short: ok, but the read at {nxt['t']} s shows none of {', '.join(unheld)}")
            if bite:
                break
        if bite:
            c, end, how = bite
            out.update(took=True, bite={"t": end, "how": how, "call": {"tool": c.get("tool"), "args": c.get("args"),
                                                                      "ok": c.get("ok"), "reason": c.get("reason"),
                                                                      "t": float(c["t"])}})
        elif room_at:
            out["freed_before_bite"] = {"t": room_at["t"], "room": room_at.get("room")}
            return out
        else:
            return out
    b = float(out["bite"]["t"])
    s = next((s for s in samples if s["t"] >= b and (s.get("room") or 0) > 0), None)
    if s:
        freed = [c for c in calls if c.get("dur_s") is not None and b <= float(c["t"]) + float(c["dur_s"]) <= s["t"]]
        last = max(freed, key=lambda c: float(c["t"]) + float(c["dur_s"]), default=None)
        out.update(t_clear=s["t"], at_clear={"t": s["t"], "room": s.get("room"), "carried": dict(s["carried"])},
                   freed_by=({"tool": last.get("tool"), "args": last.get("args"), "ok": last.get("ok"),
                              "t": float(last["t"])} if last else None))
    return out


def clear_read(io, job: dict, start: dict, seen, rows: list[dict], rel: float) -> dict:
    """I5's read at ready (study 2026-11-18 section 3): his bag and his containers as the game shows them, because a
    call in flight at the kill may have moved the job with no row to show it (run 021010: the store finished in the
    gap). carried and chests: the asked kinds only; done: the job's end read on it."""
    _, snap = _read_state(io)
    out: dict = {"t": round(rel, 1)}
    if snap.get("unread"):
        out["unread"] = snap["unread"]
        return out
    seen.see(snap, rel)
    snap.update(evidence(rows))
    seen.into(snap)
    out["carried"] = asked_carried(job, snap)
    wants = [w["item"] for w in _chest_wants(job)]
    if "in_own_chest" in (job.get("end") or {}):
        snap["chest_end"] = chest_reads(io, chest_candidates(start, snap))
        out["chests"] = {cid: {k: n for k, n in (r.get("items") or {}).items() if any(matches(k, p) for p in wants)}
                         for cid, r in snap["chest_end"].items() if r.get("read")}
    out["done"], out["done_why"] = done(job, start, snap)
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

    READ_CAP = 8  # new containers read per sample

    def __init__(self):
        self.own: set[str] = set()
        self.kinds: dict[str, str] = {}
        self.where: dict[str, list] = {}
        self.first: dict[str, dict] = {}
        self.bags: list[dict] = []
        self.vault_trace: list[dict] = []  # {t, in_vault, vault, inside, inside_vault, how, position} at each change
        self.kills: list[dict] = []  # every recent_kills row a read listed, once, with that read's vault place
        self.jumps: list[dict] = []  # each move of over VAULT_JUMP_M between two reads (a door, a death), with its door
        self.doors: dict[str, dict] = {}  # every door row with an arrives_at the run's reads listed, by id
        self.last_pos: list | None = None

    def see(self, snap: dict, t: float | None = None) -> None:
        self.own |= set(snap.get("own_containers") or [])
        self.kinds.update(snap.get("container_kinds") or {})
        self.where.update(snap.get("container_where") or {})
        self.bags.append({"carried": snap.get("carried") or {}})
        self._jump(snap, t)
        pl = vault_place(snap, self.jumps)
        at = {"in_vault": snap.get("in_vault"), "vault": snap.get("vault"), "inside": pl["inside"],
              "inside_vault": pl["vault"]}
        last = self.vault_trace[-1] if self.vault_trace else None
        if pl["inside"] is not None and (last is None or any(last.get(k) != v for k, v in at.items())):
            self.vault_trace.append({"t": None if t is None else round(t, 1), **at, "how": pl["how"],
                                     "position": snap.get("position")})
        known = {_kill_key(k) for k in self.kills}
        for k in snap.get("recent_kills") or []:  # a kill is tagged with the first read that listed it
            if _kill_key(k) not in known:
                self.kills.append({**k, **at, "t": None if t is None else round(t, 1)})

    def _jump(self, snap: dict, t: float | None) -> None:
        """A move of over VAULT_JUMP_M since the last read with a position: kept with where it landed (the arrival
        spot), the door whose arrives_at it landed nearest (rows of this run's earlier reads), the vault that door
        leads to (into, when it landed within VAULT_ARRIVE_R_M), the vault box read there and the hostiles near."""
        pos = snap.get("position")
        p2 = _xy(pos)
        prev, prev2 = self.last_pos, _xy(self.last_pos)
        if p2 is not None and prev2 is not None and (m := math.dist(prev2, p2)) > VAULT_JUMP_M:
            door, arrives_m = None, None
            for row in self.doors.values():
                d = math.dist(_xy(row["arrives_at"]), p2)
                if arrives_m is None or d < arrives_m:
                    door, arrives_m = row, d
            leads = door.get("leads_to") if door and arrives_m <= VAULT_ARRIVE_R_M else None
            self.jumps.append({"t": None if t is None else round(t, 1), "from": prev, "to": pos, "m": round(m, 1),
                               "door": {k: door[k] for k in ("id", "name", "leads_to", "arrives_at") if k in door}
                               if door else None, "arrives_m": None if arrives_m is None else round(arrives_m, 1),
                               "into": leads if leads and leads != "outside" else None, "vault": snap.get("vault"),
                               "in_vault": snap.get("in_vault"), "hostiles_near": snap.get("hostiles_near") or []})
        for row in snap.get("vault_rows") or []:
            if row.get("id") and _xy(row.get("arrives_at")):
                self.doors[row["id"]] = row
        if p2 is not None:
            self.last_pos = pos

    def arrival(self) -> dict | None:
        """The first door jump that landed him inside a vault (its box named at the landing read, or a door's
        arrives_at in a vault): where, when, how far, the flag there and the hostiles near."""
        return next((j for j in self.jumps if j.get("vault") or j.get("into")), None)

    def read_new(self, io, snap: dict, t: float) -> None:
        """Read each container of his that this read lists (so within 30 m of him: inside the client's 80 m inspect
        reach, client_bridge LOOK_MAX_RADIUS_M) the first time it is listed. Run 20261118-000146-L2: his chest at the
        bed camp he respawned at was listed there and read only at the end, from his base 89 m off ("it's 89 m away,
        beyond 80 m"), and the run was left out. A failed read is tried again the next time it is listed."""
        todo = [cid for cid in snap.get("own_containers") or []
                if cid not in self.first and is_storage(cid, self.kinds) is not False][:self.READ_CAP]
        for cid, r in chest_reads(io, todo).items():
            if r.get("read") or r.get("no_inventory"):
                self.first[cid] = {**r, "t": round(t, 1)}

    def into(self, snap: dict) -> None:
        snap["own_containers"] = sorted(self.own | set(snap.get("own_containers") or []))
        snap["container_kinds"] = {**self.kinds, **(snap.get("container_kinds") or {})}
        snap["container_where"] = {**self.where, **(snap.get("container_where") or {})}
        snap["chest_first"] = dict(self.first)
        snap["vault_trace"] = list(self.vault_trace)
        snap["kills_seen"] = list(self.kills)
        snap["jumps"] = list(self.jumps)
        snap["vault_arrival"] = self.arrival()


def seen_from_end(reads: dict, where: dict, pos: Any) -> None:
    """Mark each failed end read with how far from where he ended the container was last listed (seen_m)."""
    if not (isinstance(pos, (list, tuple)) and len(pos) >= 2):
        return
    for cid, r in reads.items():
        p = where.get(cid)
        if not r.get("read") and not r.get("no_inventory") and p:
            r["seen_m"] = round(math.dist(p[:2], pos[:2]), 1)


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
    lo_hi = mid_range(until)
    # the open ask on disk (brain/ask_store.py) is per world guid: cleared here, with no brain running, so this trial
    # never meets the last trial's ask; never at the restart inside the trial (I5 measures that it survives)
    clear_ask = getattr(io, "clear_ask", None)
    try:
        ask_cleared = clear_ask() if clear_ask else None
    except Exception as exc:  # recorded; the brain then may read an old ask, which the record shows
        ask_cleared = {"error": repr(exc)[:200]}
    world = None
    if world_needs_for(job, step):  # before the brain and the ask: a world short of what the job needs is no trial
        raw_w, snap_w = _read_state(io)
        world = world_check(io, job, raw_w, snap_w, step)
        if world and not world["ok"]:
            return world_short_record(job, opts, io.now(), snap_w, world, ask_cleared)
    if not io.start_brain():  # the reason (window 1118d I1: the sender's prove, not the brain, failed)
        why_not = getattr(io, "start_why", None)
        return {"error": "brain did not start" + (f": {why_not}" if why_not else "")}
    left_before = io.leave_dialogue()
    raw0, start = _read_state(io)
    if opts.get("own_guids"):  # the characters of his line: whose a container is, by the game (game_owner)
        start["own_guids"] = sorted({str(g).upper() for g in opts["own_guids"] if g})
    if opts.get("self_guid"):  # this character alone (--until own_chest: a container of HIS, self_owned)
        start["self_guid"] = str(opts["self_guid"]).upper()
    if opts.get("ladder_made"):  # what he made in the ladder's earlier rungs (the checkpoint's ladder record)
        start["ladder_made"] = opts["ladder_made"]
    venture = "venture_gear" in (job.get("end") or {})
    # a vault end (K1-K4): read every FAST_SAMPLE_S, so a stand at the door before he presses Enter, a walk in, or a
    # kill among five is not missed between two 15 s reads
    vault_job = any(k in VAULT_ENDS for k in (job.get("end") or {}))
    entered: dict | None = None  # the read that put him inside a copper region (V2): its facts end the trial
    chest_job = "in_own_chest" in (job.get("end") or {})
    seen = _Seen()
    if not start.get("unread"):
        seen.see(start, 0.0)
    if "gear_target" in (job.get("end") or {}):
        try:
            start["gear_target"] = io.gear_target(raw0, ((job.get("end") or {}).get("gear_target") or {}).get("vault"))
        except Exception as exc:
            start["gear_target_error"] = repr(exc)[:200]
    if any(w.get("gained") for w in (job.get("end") or {}).get("in_own_chest") or []) and not start.get("unread"):
        # what his containers in reach hold before the line: a 'gained' want counts only what goes in after it
        start["chest_start"] = chest_reads(io, chest_candidates(start, start))
        seen.first.update({cid: {**r, "t": 0.0} for cid, r in start["chest_start"].items()
                           if r.get("read") or r.get("no_inventory")})
    if chest_job and not start.get("unread"):
        seen.read_new(io, start, 0.0)  # the start read of his containers (those chest_start did not read)
    trigger = opts.get("trigger") or job.get("interrupt_trigger") or "first_step"
    by_progress = "progress" in str(trigger)
    t0 = io.now()
    sent = [{"t": 0.0, "line": job["line"], "sent": io.send(job["line"])}]
    intr = None
    first_t = None
    work_t = None
    why = None
    ok, ok_why = False, "not read yet"
    last_sample = -1e9
    rows: list[dict] = []
    res: dict = {}
    cur: dict | None = None
    samples: list[dict] = []  # [{t, carried (asked kinds), room}] of every read: I4's bite and clear, I4/I5's serves
    t_done: float | None = None  # the first read of the job done (seconds into the run)
    t_not_done = 0.0  # the last harness read that was not done (seconds into the run)
    gate_blocked = False  # I4's needs_new_slot held the fill back while the trigger was due
    while True:
        now = io.now()
        rel = now - t0
        rows = io.rows(t0 - 1, now + 1)
        tl = q.timeline(rows, t0)
        calls = cl.model_calls(rows)
        if first_t is None:
            first_t = first_step(tl["calls"], job)
        if work_t is None:
            work_t = first_work(tl["calls"], job)
        fast = bool(lo_hi) or until == OWN_CHEST or (bool(step) and intr is None and by_progress) or venture \
            or vault_job
        if now - last_sample >= (FAST_SAMPLE_S if fast else SAMPLE_S):
            last_sample = now
            read = snapshot(io.state())
            if not read.get("unread"):  # a failed read is skipped, never judged
                cur = read
                seen.see(cur, rel)
                if chest_job:
                    seen.read_new(io, cur, rel)
                cur.update(evidence(rows))
                seen.into(cur)
                if venture and entered is None:
                    entered = entry_read(job, cur, rel)
                if entered:
                    cur["entered"] = entered
                ok, ok_why = done(job, start, cur)
                if ok is None and chest_job and done(job, start, {**cur, "chest_end": _open_reads(cur)})[0] is True:
                    cur["chest_end"] = chest_reads(io, chest_candidates(start, cur))  # his opens say done: read it now
                    ok, ok_why = done(job, start, cur)
                if ok is True and t_done is None:
                    t_done = round(rel, 1)
                elif ok is not True and t_done is None:
                    t_not_done = rel
                room = cur.get("bag_room")
                if step == "I4" and intr is not None and intr.get("full_read") and intr.get("t_clear") is None \
                        and not (room or 0) > 0:
                    room = io.bag_room()  # get_state's bag is the item page only: the raw pages decide "no room"
                samples.append({"t": round(rel, 1), "carried": asked_carried(job, cur), "room": room})
        busy = [r for r in rows if r.get("kind") in ("prompt", "llm_response", "tool_call", "tool_result", "say")]
        open_prompt = bool(busy) and busy[-1].get("kind") == "prompt"
        open_tool = any(c.get("dur_s") is None for c in tl["calls"]) or bool(tl["body_busy"])
        if step and intr is None and ok is not True:
            dep_t, share = first_deposit(rows, job, t0), progress(job, start, cur, rows)
            # between_calls (I4): wait for no open call, so the bag fills before his next gather, not inside one
            due = trigger_due(trigger, first_t, rel, bar, dep_t, share, work_t) and not (spec.get("between_calls") and open_tool)
            # needs_new_slot (I4): only while he carries none of an asked kind, so his next unit needs a new slot; a
            # unit that merges into a stack he holds never meets a full bag (N1: stacks of 99)
            unheld = unheld_wants(job, cur)
            if due and spec.get("needs_new_slot") and not unheld:
                gate_blocked, due = True, False
            if due:
                open_c = [c for c in tl["calls"] if c.get("dur_s") is None]
                moment = {"trigger": trigger, "at_s": round(rel, 1), "first_work_s": work_t, "first_step_s": first_t,
                          "first_deposit_s": dep_t, "progress": share, "carried": asked_carried(job, cur) or None,
                          "unheld": unheld,
                          # the call open at this moment (I5: the body runs it on with no brain to log its result)
                          "open_call": ({k: open_c[-1].get(k) for k in ("tool", "args", "t")} if open_c else None)}
                intr = apply_interruption(io, step, spec, t0)
                intr["moment"] = moment
                print(f"[{rel:6.1f}s] {step} put in at {json.dumps(moment, default=str)}: {intr.get('how')}")
                if step == "I5" and intr.get("t_clear") is not None:  # what the game shows at ready
                    rows = io.rows(t0 - 1, io.now() + 1)
                    intr["at_clear"] = clear_read(io, job, start, seen, rows, io.now() - t0)
        if intr is not None and step == "I2" and intr.get("t_clear") is None:
            intr = fight_cleared(rows, intr, t0, float(spec.get("fight_wait_s", 40)))
        if intr is not None and step == "I4" and intr.get("full_read") and intr.get("t_clear") is None:
            intr = bag_watch(tl["calls"], intr, samples)
        if intr is not None and intr.get("t_clear") is not None:
            serves = serves_test(job, rows, t0, samples, intr) if step in ("I4", "I5") else None
            res = resumed(tl["calls"], intr, job.get("work_tools"), sent[1:], serves)
        quiet = now - max(tl["last_busy"], float(busy[-1]["ts"]) if busy else t0)
        share_now = progress(job, start, cur, rows) if lo_hi else None
        # own_chest: his body's container results are read every poll (the owner and contents the game showed him)
        own_now = own_chest_check(job, start, {**cur, "chests": chests_seen(rows)}, rows) \
            if until == OWN_CHEST and cur is not None else {}
        if entered:
            why = f"entered {entered['region']}"  # the rung's end: his power level there is the fact recorded
        elif ok:
            why = "job done"
        elif until == "first_step" and first_t is not None:
            why = "first step"
        elif own_now.get("ok"):
            why = "own chest"  # the game shows a container of his own holding some of the job, the job not done
        elif lo_hi and share_now is not None and share_now >= lo_hi[0] and first_deposit(rows, job, t0) is None:
            why = "mid-job"  # a moment read from the game: that share got, nothing of the job stored yet
        elif intr is not None and intr.get("took") is False:
            why = "interruption did not take"
        elif until == "resumed" and res.get("resumed") and rel >= res["t"] + float(opts.get("confirm_s", CONFIRM_S)):
            why = "resumed"
        elif intr is not None and intr.get("t_clear") is not None and not res.get("resumed") \
                and rel - float(intr["t_clear"]) > float(spec.get("resume_within_s", 120)):
            why = "no resumption"
        elif calls["haiku"] > int(opts.get("max_haiku", 80)):
            why = "haiku cap"
        elif rel > (float(opts["deadline"]) if opts.get("deadline") is not None else deadline_of(job)):
            why = "deadline"
        elif Path(opts.get("stop_file") or STOP_FILE).exists():
            why = "stopped"
        elif any(r.get("kind") == "budget_blocked" and float(r.get("ts") or 0) >= t0 for r in rows):
            # the trial's own spend cap (--usd) stopped his model calls: the brain then runs template lines and drops
            # queued goals, and the stand that follows is not his (study quiet_1119: 8 of 14 V1 'quiet' ends were
            # this). A run fault: not counted
            why = "budget"
        elif not open_prompt and not open_tool and quiet >= q.QUIET_S and calls["calls"]:
            why = "quiet"
        if why:
            break
        # while an interruption is awaited the moment can be short (window 1118h: 0.7 s between two of his calls for
        # I4's between_calls, 2.1-2.8 s between his first and last store for first_deposit): poll it more often
        io.sleep(AWAIT_POLL_S if step and intr is None else q.POLL_S)
    ended = io.now()
    left_after = io.stop_all()
    _, end = _read_state(io)
    rows = io.rows(t0 - 1, ended + 3)
    if not end.get("unread"):
        seen.see(end, ended - t0)
    end.update(evidence(rows))
    seen.into(end)
    if entered:
        end["entered"] = entered
    if chest_job:
        end["chest_end"] = chest_reads(io, chest_candidates(start, end))
        seen_from_end(end["chest_end"], end.get("container_where") or {}, end.get("position"))
        end["held_in_run"] = held_in_run(rows, seen.bags)  # start, every sample and end (seen.see)
    ok, ok_why = done(job, start, end)
    if ok is True and t_done is None:
        t_done = round(ended - t0, 1)
    if not end.get("unread"):  # the end read is the last sample (a call that ended just before it)
        samples.append({"t": round(ended - t0, 1), "carried": asked_carried(job, end), "room": end.get("bag_room")})
    # stands count up to the first read of the job done, the brain's own get_state replies included: after it he has
    # finished and only the harness's read is awaited (run 20261119-060504: done by the brain's read at 518.1 s, the
    # harness's at 527.6 s)
    stands_to = None
    if ok is True and t_done is not None:
        stands_to = first_done_read(job, start, seen, rows, t0 + t_not_done, t0 + t_done) or t0 + t_done
    tl = q.timeline(rows, t0, ended, t_done=stands_to)
    calls = cl.model_calls(rows)
    if intr is not None and step == "I2" and intr.get("took") is None:
        intr = fight_cleared(rows, intr, t0, float(spec.get("fight_wait_s", 40)))
    if intr is not None and step == "I4" and intr.get("full_read") and intr.get("t_clear") is None:
        intr = bag_watch(tl["calls"], intr, samples)
    if intr is not None and intr.get("t_clear") is not None:
        serves = serves_test(job, rows, t0, samples, intr) if step in ("I4", "I5") else None
        res = resumed(tl["calls"], intr, job.get("work_tools"), sent[1:], serves)
        if res.get("resumed"):
            intr["t_resumed"] = res["t"]
    active = round(tl["last_busy"] - t0, 1) if why == "quiet" else round(ended - t0, 1)
    idle_total = round(sum(i["s"] for i in tl["idle"]), 1)
    rung = job.get("rung")
    rec = {"run": time.strftime("%Y%m%d-%H%M%S", time.gmtime(t0)) + f"-{job['id']}" + (f"-{rung}" if rung else "")
           + (f"-{step}" if step else ""),
           "item": f"job: {job['id']}" + (f" / {rung}" if rung else "") + (f" / {step}" if step else ""),
           "kind": "interrupt" if step else "job", "job": job["id"], "step": step, "held_out": bool(job.get("held_out")), "until": until,
           "character": opts.get("character"), "checkpoint": opts.get("checkpoint"), "holder": opts.get("holder"),
           "lines": sent, "ended": why, "wall_s": round(ended - t0, 1), "active_s": active,
           # one truth: done is the job's end read from the game in every record (it was a step's resumption, and run
           # 015315-N1-I2 read "done": false beside "job_done": true); a step's own verdict is "resumed"
           "done": ok is True, "job_done": ok is True, "done_why": ok_why,
           "state_start": start, "state_end": {k: v for k, v in end.items() if k != "chests"}, "chests": end.get("chests"),
           "first_step_s": first_t, "tool_calls": tl["calls"], "says": tl["says"], "idle_over_5s": tl["idle"],
           "idle_total_s": idle_total, "longest_stand_s": max([i["s"] for i in tl["idle"]], default=0),
           "stands_to_s": round(stands_to - t0, 1) if stands_to is not None else None,
           "haiku": calls["haiku"], "sonnet": calls["sonnet"], "usd": calls["usd"], "brain_logs": io.brain_logs(),
           "dialogue_left": {"before": left_before, "after": left_after}, "bar_s": bar}
    if world is not None:  # what the world held before the ask (world_needs)
        rec["world"] = world
    if rung:
        rec["rung"] = rung
    if end.get("vault_arrival"):  # where a door jump landed him in a vault (the K stages)
        rec["vault_arrival"] = end["vault_arrival"]
    if entered:
        rec["entered"] = entered
    for cid, c in (rec.get("chests") or {}).items():  # whose each container he used is, by the game (game_owner)
        c["his"], c["his_why"] = game_owner(cid, start, end)
    if is_probe({"until": until}):
        rec["probe"] = True  # never a trial: not_counted, failure_ledger.scan and rates leave it out
    if lo_hi:
        rec["mid"] = mid_read(job, start, end, rows, t0, lo_hi)
    if until == OWN_CHEST:  # the end read decides the save (save_ok), with why when it is not one
        rec["own_chest"] = own_chest_check(job, start, end, rows, why)
    if step:
        rec["resumed"] = bool(res.get("resumed"))
        never = f"never put in: {trigger} was not due when the run ended ({why})" + (
            "; when it was due he carried some of every asked kind, so no unit needed a new slot (needs_new_slot)"
            if gate_blocked else "")
        rec.update(interruption=intr or {"step": step, "took": False, "how": never},
                   resume=res, resume_within_s=spec.get("resume_within_s"),
                   says_after_put=[s for s in tl["says"] if intr and intr.get("t_put") is not None and s["t"] >= intr["t_put"]])
        rec["ask_store"] = ask_cleared
        rec["job_done_s"] = t_done
    if step == "I5" and intr:  # beside the verdict, never a bar: did the new brain bring the ask back from disk
        t_new = t0 + float(intr.get("t_started") if intr.get("t_started") is not None else intr.get("t_put") or 0)
        ar = [r for r in rows if r.get("kind") == "ask_restored" and float(r.get("ts") or 0) >= t_new]
        rec["ask_restored"] = {"seen": bool(ar), "note": "beside the verdict, not a bar"}
        if ar:
            rec["ask_restored"].update(t=round(float(ar[0]["ts"]) - t0, 1), ok=ar[0].get("ok", True),
                                       request=ar[0].get("request"), lost_call=ar[0].get("lost_call"),
                                       error=ar[0].get("error"))
    # a head start is a whole job's rule: a step trial from a mid-job checkpoint carries the job's things by design
    nc = None if step else not_counted(job, start)
    clear_t = (intr or {}).get("t_clear")
    if step and not intr:  # the harness's moment never came: no trial of the step, never a fail (window 1118h)
        nc = ("the job was done before the interruption was due: the step says nothing" if ok is True
              else f"the interruption was never put in ({trigger} not due when the run ended: {why}"
                   + ("; needs_new_slot held it back" if gate_blocked else "") + "): the step says nothing")
    elif step == "I4" and intr.get("full_read") and not intr.get("bite"):
        fb = intr.get("freed_before_bite")
        nc = "the full bag met no call of his: the step says nothing" + (
            f" (room again at {fb['t']} s before any call met it)" if fb else "")
    elif step == "I5" and (intr.get("at_clear") or {}).get("done") is True:
        oc = (intr.get("moment") or {}).get("open_call") or {}
        nc = (f"finished by the in-flight call ({oc.get('tool') or 'none open'}) before the new brain was ready: "
              "the step says nothing")
    elif step and ok is True and clear_t is not None and t_done is not None and t_done <= float(clear_t):
        nc = f"the job read done at {t_done} s, at or before the interruption cleared: the step says nothing"
    elif step and ok is True and not res.get("resumed") and why == "job done":
        nc = "the job was done before he could take it up again: the step says nothing"
    if nc:
        rec["not_counted"] = nc
    if ok is None and not step and "bar_open" in str(ok_why):
        # read, and the goal fixes no bar for it (V2: in the copper region under its power): recorded, not counted
        rec["bar_open"] = True
        rec.setdefault("not_counted", "bar_open: " + str(ok_why)[:400])
    elif ok is None and not step:  # a whole job whose end state could not be read: not counted, the reason kept
        rec["unread"] = ok_why
    rec["misses"] = misses(tl["calls"], active - idle_total, intr)
    if why == "budget" and ok is not True and not rec.get("not_counted") and rec["misses"]["n"] <= 1:
        # the trial's spend cap ended his model calls while he was within the miss bar: a run fault (rule 3). With
        # more than one miss by then he had already failed a bar on his own: counted (confirm_1119s trial 2, 29 misses)
        rec["not_counted"] = "the trial's spend cap (--usd) stopped his model calls before the end: a run fault, not counted"
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
        self.start_why = None
        ok, how = cl.ensure_sender()
        if not ok:  # the player's line goes through the sender: no trial without it (run_job keeps this reason)
            self.start_why = f"sender: {how}"
            print(self.start_why)
            return False
        p, f = cl.start_brain(self.a, spend.spend_today()["spent_usd"])
        self.procs.append(p)
        if f is None:
            cl.stop_brain(p)
            self.start_why = "no brain-live log with its session_start within 90 s (logs/brain-chat-ladder-console.log)"
            return False
        self.files.append(f)
        return True

    def restart_brain(self, gap_s: float) -> dict:
        """I5: the brain stopped, the gap, a new one on the same world store; the open ask on disk is kept (only a
        trial's start clears it). {ready, t_stopped, t_started, t_ready} (unix times)."""
        from tools import chat_ladder as cl
        for p in self.procs:
            cl.stop_brain(p)
        t_stopped = time.time()
        time.sleep(gap_s)
        t_started = time.time()
        ready = self.start_brain()
        return {"ready": bool(ready), "t_stopped": t_stopped, "t_started": t_started,
                "t_ready": time.time() if ready else None}

    def clear_ask(self) -> dict:
        """The trial's fresh start: the open ask of this trial's world (DW_WORLD_GUID = a.world) removed, with no
        brain running (brain/ask_store.clear_world), so trial N+1 never reads trial N's ask."""
        from brain import ask_store
        return {"world": self.a.world, "had_ask": ask_store.clear_world(self.a.world)}

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

    def census(self, args: dict) -> dict:
        """The body's census (client_bridge census -> sense.census): world_check counts standing sources with it."""
        return self.cli.request("census", args, timeout=30)

    def inspect(self, cid: str) -> dict:
        """One container's contents through the body's own read (client_bridge inspect -> contents_of)."""
        return self.cli.request("inspect", {"target": cid}, timeout=20)

    def fixture(self, verb: str, purpose: str, **kw) -> dict:
        return self.dev.setup(verb, purpose=purpose, **kw)

    def gear_target(self, state: dict, vault: str | None = None) -> dict:
        from tools import rung4_gate
        from brain.stash import Stash
        stash = Stash(paths.state_dir() / "worlds" / self.a.world / "containers.json").labels()
        tg = rung4_gate.gear_target(state, stash, vault)
        out = {"pl": tg["pl"], "pl_now": tg["pl_now"], "kit": tg["kit"]}
        if vault:  # what the vault asks and from which data rows: the verdict names them (p_gear_target)
            need = tg["vault"]
            out.update(vault=need["vault"], reachable_pl=tg["reachable_pl"], damage_pref=need["damage_pref"],
                       enemies=need["enemies"], rows=need["rows"])
        return out

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
def start_ref(job: dict, step: str | None, override: str | None, spec: dict | None = None) -> tuple[str, str]:
    """(checkpoint or save to fork, why): --from, else the step's own checkpoint on its vehicle (spec "from" when the
    job is spec "job": I4 on N2), else a mid-job checkpoint for an interruption step when it exists, else the job's
    start (the interruption then comes after his first verified step)."""
    from tools import quest_clone
    if override:
        return override, "--from"
    spec = spec or {}
    if step and spec.get("from") and spec.get("job") == job.get("id"):
        if (quest_clone.CHECKPOINT_DIR / f"{spec['from']}.json").exists():
            return spec["from"], f"{step}'s checkpoint"
        return job["start"], f"the job's start ({spec['from']} not made yet)"
    mid = job.get("interrupt_from")
    if step and mid and (quest_clone.CHECKPOINT_DIR / f"{mid}.json").exists():
        return mid, "the job's mid-job checkpoint"
    return job["start"], "the job's start" + (f" ({mid} not made yet)" if step and mid else "")


def char_guid(path: Path) -> str | None:
    """A character save's meta_data.char_guid (read only), or None."""
    try:
        d = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    d = d.get("result", d) if isinstance(d, dict) else {}
    g = (d.get("meta_data") or {}).get("char_guid") if isinstance(d, dict) else None
    return str(g).upper() if g else None


def cmd_window(a, step: str | None) -> int:
    from tools import quest_run as q
    from tools import quest_clone
    if not a.confirm:
        print("refusing: a live trial relaunches the client on forked characters; pass --confirm")
        return 2
    from tools import live_guard  # a test passes a fake lock window (q.window_faked); a worktree needs DW_LIVE_OK=1
    why = live_guard.why_refused("a job_run window", fake=q.window_faked())
    if why:
        print(why)
        return live_guard.REFUSED_RC
    doc = load_jobs()
    job = job_of(a.job, doc)
    spec = (doc.get("interruptions") or {}).get(step) or {}
    if step and spec.get("job") and spec["job"] != a.job:  # the step bites only on its vehicle (I4: N1 cannot)
        print(f"{step}'s vehicle is {spec['job']} (data/jobs.json interruptions.{step}.job), not {a.job}: "
              + (spec.get("job_note") or "the step says nothing on another job"))
        return 2
    if q.refuse_dirty(a):
        return 7
    rung = getattr(a, "rung", None)
    if rung:  # a rung of the job's ladder: the job's line, the rung's end and start (from)
        job = rung_job(job, rung)
    ref, ref_why = start_ref(job, step, a.checkpoint, spec)
    ladder = read_ladder(ref) if rung else {}  # what he made in the earlier rungs, from the checkpoint's record
    if rung:
        ref_why = (f"rung {rung}'s from" if ref_why == "the job's start" else ref_why) + (
            f"; ladder record of runs {', '.join(ladder.get('runs') or [])}" if ladder else "; no ladder record")
    trigger = getattr(a, "trigger", None) or job.get("interrupt_trigger") or "first_step"
    if step and not trigger_ok(trigger):
        print(f"{a.job}: unknown interrupt trigger {trigger!r}")
        return 2
    try:
        src, place = quest_clone.source_of(ref), quest_clone.place_of(ref)
    except SystemExit as exc:
        print(f"no start for {a.job}: {exc}")
        return 2
    # his line (whose a container is: game_owner): the save forked from, and ClaudeDev (every fork's first source)
    src_guid, dev_guid = char_guid(src), char_guid(quest_clone.SAVE_DIR / "ClaudeDev.json")
    if a.save_as and (quest_clone.CHECKPOINT_DIR / f"{a.save_as}.json").exists():
        print(f"checkpoint {a.save_as!r} exists already: pick a new --save-as label")
        return 2
    # a fork copies the SAVE, not his live bars (live 2026-11-17 21:05Z), and starts at them: START_PCT, not only fit
    if (why := start_unfit(src)) is not None:
        print(f"not running: {why}")
        return 3
    # a checkpoint pair (tools/checkpoint_pair.py): every trial restores the checkpoint's world and plays its own
    # character (same guid and name); a job's start or a plain checkpoint forks freshly as before
    from tools import checkpoint_pair as cpair
    others_ok = getattr(a, "others_ok", "") or ""
    pairs, pair, why = cpair.window_pair(ref, others_ok, a.save_as)
    if why:
        print(f"not running: {why}")
        return 2
    if pair:
        print(f"{ref} is a checkpoint pair: each trial restores world {pair['world']} and plays {pair['char_name']} "
              f"(guid {pair['char_guid']}) as that checkpoint saved him")
    print(f"{a.job}{' / ' + rung if rung else ''}{' / ' + step if step else ''}: {a.k} trial(s) from {ref} ({ref_why}); holder {a.holder}; "
          + (f"the interruption goes in at {trigger}; " if step else "") +
          f"each up to {a.max_haiku} Haiku calls (controller) plus the Planner (Sonnet), capped at ${a.usd} a trial on "
          f"top of today's spend")
    if job.get("held_out"):
        print(f"held-out job: scored only; its trace stays closed (show --read-trace after {TRACE_AFTER} scored trials)")
    stamp = time.strftime("%d%H%M", time.gmtime())
    forks = [f"ClaudeJ{stamp}{chr(97 + i)}" for i in range(min(a.k, 26))]
    out = {"window": time.strftime("%Y%m%d-%H%M%S", time.gmtime()), "job": a.job, "step": step, "from": ref,
           "source": str(src), "k": a.k, "place": place, "holder": a.holder, "trials": []}
    if pair:
        out["pair"] = {k: pair[k] for k in ("world", "char_name", "char_guid", "char_saved_at")}
    used = []
    old = os.environ.get("DW_GATE_DIRECTOR")
    os.environ["DW_GATE_DIRECTOR"] = "1" if a.holder == "board" else "0"  # chat_ladder.start_brain reads it
    try:
        with q.clone_window(a.wait, out, WINDOW_OUT) as (sw, cli, t0):
            for i, name in enumerate(forks):
                if STOP_FILE.exists():
                    out["trials"].append({"character": name, "skipped": f"{STOP_FILE.name} present"})
                    break
                left = a.window_s - a.reserve_s - (time.time() - t0) - q.SWITCH_S - (cpair.PAIR_S if pair else 0)
                if left < 120:
                    out["trials"].append({"character": name, "skipped": f"window: {left:.0f} s left"})
                    break
                try:
                    got = cpair.start_character(ref, name, pair, pairs, quest_clone.fork, others_ok)
                except SystemExit as exc:
                    raise RuntimeError(f"fork: {exc}") from None
                except cpair.Refused as exc:
                    raise RuntimeError(f"checkpoint pair: {exc}") from None
                name = got["name"]
                if not got["paired"]:
                    used.append(name)
                else:
                    print(f"[{time.time() - t0:6.1f}s] {ref}: world {pair['world']} restored and {name} written back "
                          f"in {got['prep']['s']} s; parked {got['prep']['parked']}; "
                          f"deaths forgotten {len(got['prep']['deaths_forgotten'])}")
                made = sw.ensure(name, create=False, wait_s=150)
                fault = cpair.identity_fault(made, pair)
                if fault:  # the harness's: every trial of this pair would meet it
                    out["trials"].append({"character": name, "skipped": fault, "void": "harness"})
                    print(f"{name}: {fault}")
                    break
                if got["paired"]:
                    got["prep"]["file_after_join"] = pairs.file_check(pair, got["prep"]["written_at"])
                bad_start = start_unfit(src, cli)  # the body this fork starts as (an unread state refuses too)
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
                # the brain's per-world memory: a fresh one per trial (a pair's trials share a name, never a memory)
                memory = f"dev_{name}_{chr(97 + i)}" if got["paired"] else f"dev_{name}"
                ns = argparse.Namespace(**{**vars(a), "world": memory, "in_lock": True, "start_brain": True,
                                           "use_running_brain": False,
                                           # whose copy he is (brain/fork_line.py): ClaudeDev's crates are his
                                           "forked_from": q.forked_from(src, made.get("guid"))})
                from tools import chat_ladder as cl
                nav_why = wait_nav(cl.nav_not_ready, time.sleep)  # I4 of window 1118d: skipped on a stale heartbeat
                if nav_why:
                    print(f"{name}: after {150:.0f} s: {nav_why}")
                bad = q.preflight(ns)
                if bad:
                    out["trials"].append({"character": name, "skipped": "preflight: " + "; ".join(bad)})
                    continue
                io = Live(ns, cli, dev)
                left = a.window_s - a.reserve_s - (time.time() - t0)
                rec = run_job(io, job, {"step": step, "interruptions": doc.get("interruptions"), "until": a.until,
                                        "trigger": trigger, "deadline": min(deadline_of(job, a.deadline), left),
                                        "max_haiku": a.max_haiku, "character": name, "checkpoint": ref,
                                        "holder": a.holder, "confirm_s": getattr(a, "confirm_s", CONFIRM_S),
                                        "own_guids": [made.get("guid"), src_guid, dev_guid],
                                        "self_guid": made.get("guid"),
                                        "ladder_made": ladder.get("made")})
                if "error" in rec:  # no trial ran: the harness's (void), with its reason
                    out["trials"].append({"character": name, "error": rec["error"], "void": "harness"})
                    print(f"{name}: {rec['error']}")
                    if sender_fault(rec["error"]):
                        print("every trial on this server run would meet the same: restart the dev server "
                              "(stop_server.ps1 -Hold, world_snapshot restore, start_server.ps1) and run the window again")
                        break
                    continue
                if rec.get("ended") == WORLD_SHORT:  # the ask was never sent: recorded, not counted, no pass/fail
                    write(rec)
                    out["trials"].append({"character": name, "run": rec["run"], "skipped": rec["not_counted"],
                                          "world": rec["world"]["needs"]})
                    print(f"{name}: {rec['not_counted']}")
                    if a.regrow_days > 0 and not got["paired"]:  # the clock on: picked roots may stand again
                        out["trials"][-1]["clock_after"] = q.clock_on(dev, a.regrow_days, f"job_run {a.job}: regrow",
                                                                      vitals=q.vitals_of(cli))
                    continue
                from tools import failure_ledger
                rec.update(blind_mark(rec, all_runs(), failure_ledger.voided(), trace_reads()))
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
                if got["paired"]:
                    out["trials"][-1]["prep"] = {k: got["prep"].get(k) for k in
                                                 ("s", "parked", "deaths_forgotten", "file_after_join")}
                keep_tried = False
                if a.save_as and "saved_as" not in out:
                    good, why_save = save_ok(rec, a.until)
                    if good:  # the pair: his save and the world, both written after the trial ended
                        keep_tried = True
                        try:
                            kept = pairs.keep(a.save_as, name, t_end=t_end, wait_s=q.AUTOSAVE_S,
                                              note=f"job {a.job} run {rec['run']}", window=out["window"])
                        except cpair.Refused as exc:
                            kept = {"kept": False, "why": str(exc)}
                        good = kept["kept"]
                        if good:
                            out["saved_as"] = str(pairs.checkpoint_dir / f"{a.save_as}.json")
                            out["saved_pair"] = kept
                            out["saved_at"] = rec.get("mid") or rec.get("own_chest") or {"ended": rec["ended"]}
                            if rung:  # what he made so far goes with the save, for the next rung
                                out["ladder"] = str(write_ladder(rec, a.save_as, ladder))
                        else:  # the next trial tries again
                            why_save = f"{why_save}; pair not kept: {kept['why']}"
                            out["trials"][-1]["not_saved"] = why_save
                    else:
                        out["trials"][-1]["not_saved"] = why_save
                    print(f"{name}: {'saved as ' + a.save_as if good else 'not saved'}: {why_save}")
                # on the fork that has played, never on the one about to; not when the next trial restores the world
                # anyway (a pair), nor after a pair keep (it stopped the client)
                if a.regrow_days > 0 and not got["paired"] and not keep_tried:
                    out["trials"][-1]["clock_after"] = q.clock_on(dev, a.regrow_days, f"job_run {a.job}: regrow",
                                                                  vitals=q.vitals_of(cli))
    finally:
        if old is None:
            os.environ.pop("DW_GATE_DIRECTOR", None)
        else:
            os.environ["DW_GATE_DIRECTOR"] = old
    if out.get("back") and not a.keep_forks:
        print("parked:", quest_clone.park(used))
        if pair:  # the last trial's end, as the record of where it ended (never over an earlier one)
            print("parked:", pairs.park(pair["char_name"], time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())))
    done_ = [t for t in out["trials"] if "pass" in t]
    print(f"== {a.job}{' / ' + rung if rung else ''}{' / ' + step if step else ''} from {ref}: {sum(1 for t in done_ if t['pass'])} of {len(done_)} passed")
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
    note_trace_read(rec)
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
    tr.add_argument("--interrupt", dest="step", choices=STEPS, default=None,
                    help="put this interruption in mid-job (the same as the interrupt command with --step)")
    tr.add_argument("--rung", default=None, metavar="V1|V2|K1..K4",
                    help="one rung of the job's ladder (data/jobs.json rungs): his ask is the job's line; the trial "
                         "starts from the rung's from (or --from) and ends at the rung's end read from the game")
    for p in (tr, it):
        p.add_argument("--trigger", default=None, help="when the interruption goes in: the job's interrupt_trigger, "
                       "else first_step; or first_deposit, progress:0.5, share:0.3 (of the bar), at:SECONDS; a|b = "
                       "whichever comes first")
        p.add_argument("--confirm-s", type=float, default=CONFIRM_S, help="how long the trial goes on after he resumed")
    for p in (tr, it):
        p.add_argument("--confirm", action="store_true")
        p.add_argument("--job", required=True)
        p.add_argument("-k", type=int, default=3)
        p.add_argument("--from", dest="checkpoint", help="a checkpoint label or a save name to fork (default: the job's)")
        p.add_argument("--until", default=None, metavar="done|first_step|resumed|own_chest|mid[:LO-HI]",
                       help="end at the job's end (trial default), when he took the job up again (interrupt default), "
                            "or a probe for --save-as: mid (a mid-job checkpoint: once LO of the asked units are got, "
                            f"read from the game, and nothing of the job is stored yet; default {MID_DEFAULT[0]}-"
                            f"{MID_DEFAULT[1]}, kept only when the end read is inside), own_chest (once a container "
                            "whose owner is HIM, by the game, holds an asked item and the job is not done) or "
                            "first_step")
        p.add_argument("--save-as", metavar="LABEL", help="keep the next save of the first trial that ends as --until "
                       "asks (mid: inside the window by the end read; own_chest: his own chest by the end read; "
                       "first_step; else done)")
        p.add_argument("--holder", choices=("default", "board"), default="default",
                       help="which holder carries the ask: the default path, or the board with the Director (DW_DIRECTOR=1)")
        p.add_argument("--deadline", type=float, default=None,
                       help=f"per trial (wins over the job's deadline_s; else {DEADLINE_S:.0f})")
        p.add_argument("--max-haiku", type=int, default=120)
        p.add_argument("--usd", type=float, default=1.5, help="each trial's spend cap on top of today's spend (was "
                       "0.6: V1 trials cost 0.60-0.84 and 8 of 14 were cut off by it, study quiet_1119; done runs 0.35)")
        p.add_argument("--wait", type=float, default=3000.0, help="seconds to wait for the live lock")
        p.add_argument("--window-s", type=float, default=3600.0)
        p.add_argument("--reserve-s", type=float, default=240.0)
        p.add_argument("--regrow-days", type=int, default=3)
        p.add_argument("--keep-forks", action="store_true")
        p.add_argument("--others-ok", default="", metavar="WORDS", help="a checkpoint pair's world is restored "
                       "although another player joined since it was kept (world_snapshot's rule): Luis's words")
        p.add_argument("--dirty-ok", metavar="REASON")
    rt = sub.add_parser("rates")
    rt.add_argument("-n", type=int, default=10)
    rt.add_argument("--since", default="20261117")
    sh = sub.add_parser("show")
    sh.add_argument("run")
    sh.add_argument("--read-trace", action="store_true")
    a = ap.parse_args(argv)
    try:  # a window's output goes to a file: line by line, so a killed window still shows how far it got (I5, 1118d)
        sys.stdout.reconfigure(line_buffering=True)
    except (AttributeError, ValueError):
        pass
    if a.cmd in ("trial", "interrupt") and a.until and not until_ok(a.until):
        print(f"unknown --until {a.until!r} (done, first_step, resumed, own_chest, mid, mid:LO-HI)")
        return 2
    if a.cmd in ("trial", "interrupt") and a.trigger and not trigger_ok(a.trigger):
        print(f"unknown --trigger {a.trigger!r} (first_step, first_deposit, progress:F, share:F, at:SECONDS, a|b)")
        return 2
    if a.cmd == "trial" and a.rung and (a.step or (a.until and a.until != "done")):
        print("a rung is a whole trial to its own end: no --interrupt and no --until with --rung")
        return 2
    if a.cmd == "trial":
        a.until = a.until or ("resumed" if a.step else "done")
        return cmd_window(a, a.step)
    if a.cmd == "interrupt":
        a.until = a.until or "resumed"
        return cmd_window(a, a.step)
    return {"rates": cmd_rates, "show": cmd_show}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
