"""tools/job_run.py, the venture ladder of L2 (docs/GOAL-2026-11-17-long-jobs.md "The venture ladder"): rungs V1 and V2
as job_run trials of L2, his ask L2's own line, each rung only setting where the trial ends and what is read. Offline:
every read is a fake get_state or brain-log row; the item tiers and the region powers are the repo's game data
(data/items_<build>.json `tier` as gather.lua's weapons_data reads it, data/places_<build>.json `power`)."""
from __future__ import annotations

import json

import pytest

from tools import job_run as j

T0 = 1000.0
BONE, STONE, BRONZE = "ITEM_Pickaxe_Bone", "ITEM_Pickaxe_Stone", "ITEM_Pickaxe_Bronze"
HEAD, BODY, LEGS = ("ITEM_Armour_T3_Head_HardLeather", "ITEM_Armour_T3_Body_HardLeather",
                    "ITEM_Armour_T3_Legs_HardLeather")
CLUB = "ITEM_Club_Bone"
HOME = [182.4, 1839.9, 0.0]          # Temple Woods (power 1)
PLAINS = [1037.0, 986.8, 0.0]        # Fractured Plains (power 3)
HIGHLANDS = [296.9, 857.9, 0.0]      # Stormtouched Highlands (power 4)
G = lambda c: c * 32  # noqa: E731  (a guid of one repeated hex digit)


def row(item, where="bag", slot=None, guid=None, broken=False, durability=1000, count=1):
    r = {"item": item, "count": count, "where": where, "durability": durability, "max_durability": 1000}
    if slot:
        r["loadout_slot"] = slot
    if guid:
        r["guid"] = guid
    if broken:
        r["broken"] = True
    return r


def gs(rows, pos=HOME, pl=None):
    d = {"position": list(pos) if pos is not None else None, "inventory_items": rows}
    if pl is not None:
        d["power_level"] = pl
    return j.snapshot({"ok": True, "data": d})


def start_v1():
    """ClaudeDev at home: a stone pickaxe, power level 0."""
    return gs([row(STONE, "hotbar", guid=G("1")), row("ITEM_Resources_Skin_Scraps", count=7, guid=G("2"))], pl=0)


@pytest.fixture(scope="module")
def doc():
    return j.load_jobs()


@pytest.fixture(scope="module")
def v1(doc):
    return j.rung_job(j.job_of("L2", doc), "V1")


@pytest.fixture(scope="module")
def v2(doc):
    return j.rung_job(j.job_of("L2", doc), "V2")


# ------------------------------------------------------------------ the data
def test_a_rung_keeps_l2s_line_and_sets_only_its_end_and_start(doc, v1, v2):
    l2 = doc["jobs"]["L2"]
    for r in (v1, v2):
        assert r["line"] == l2["line"] == "claude, we need thirty copper ore in the chest at your base"
        assert r["id"] == "L2" and set(r["end"]) <= set(j.PREDICATES) and r["end"] != l2["end"]
        assert r["interrupt_from"] is None and r["work_tools"]
    assert v1["rung"] == "V1" and v1["start"] == l2["start"] == "ClaudeDev"
    assert v2["rung"] == "V2" and v2["start"] == "job_l2_v1"   # V1's save, made by a passing V1 run
    with pytest.raises(SystemExit):
        j.rung_job(j.job_of("L2", doc), "V9")
    with pytest.raises(SystemExit):
        j.rung_job(j.job_of("N1", doc), "V1")


# ------------------------------------------------------------------ V1: a pickaxe of tier 2 or better, made and carried
def test_v1_a_bone_pickaxe_made_in_the_run_and_carried_passes(v1):
    end = gs([row(STONE, "hotbar", guid=G("1")), row(BONE, "hotbar", guid=G("3"))])
    end["crafted"] = {BONE: 1}
    ok, why = j.done(v1, start_v1(), end)
    assert ok is True, why
    assert "ITEM_Pickaxe_Bone" in why and "tier 2" in why


def test_v1_the_tier_is_the_games_item_data_not_the_name(v1):
    """A stone pickaxe made in the run is tier 1 (data/items_<build>.json); a bronze one, tier 3, passes."""
    end = gs([row(STONE, "hotbar", guid=G("4"))])
    end["crafted"] = {STONE: 1}
    ok, why = j.done(v1, gs([], pl=0), end)
    assert ok is False and "tier 2" in why
    end = gs([row(BRONZE, "bag", guid=G("5"))])
    end["crafted"] = {BRONZE: 1}
    assert j.done(v1, start_v1(), end)[0] is True
    assert j.tool_tier(BONE) == 2 and j.tool_tier(STONE) == 1 and j.tool_tier("ITEM_NoSuchThing") is None


def test_v1_the_pickaxe_he_had_at_the_start_is_not_made_in_the_run(v1):
    start = gs([row(BONE, "hotbar", guid=G("6"))], pl=0)
    end = gs([row(BONE, "hotbar", guid=G("6"))])
    end["crafted"] = {BONE: 1}        # a craft in the run, but the one he carries is his old one
    ok, why = j.done(v1, start, end)
    assert ok is False and "had at the start" in why


def test_v1_no_craft_or_a_broken_one_or_none_carried_fails(v1):
    end = gs([row(BONE, "hotbar", guid=G("7"))])
    ok, why = j.done(v1, start_v1(), end)              # picked up, not made
    assert ok is False and "no craft" in why
    end = gs([row(BONE, "hotbar", guid=G("7"), broken=True, durability=0)])
    end["crafted"] = {BONE: 1}
    assert j.done(v1, start_v1(), end)[0] is False
    end = gs([row(STONE, "hotbar", guid=G("1"))])
    end["crafted"] = {BONE: 1}                         # made and dropped or stored: not carried
    ok, why = j.done(v1, start_v1(), end)
    assert ok is False and "carries none" in why


def test_v1_without_instance_reads_a_kind_he_held_at_the_start_is_unread(v1):
    start = gs([row(BONE, "hotbar")], pl=0)
    end = gs([row(BONE, "hotbar")])
    end["crafted"] = {BONE: 1}
    ok, why = j.done(v1, start, end)
    assert ok is None and "guid" in why


# ------------------------------------------------------------------ V2: gear for the region's power, made by him
def kit(pl, pos=HOME, weapon=CLUB, guids="ABC", worn=(HEAD, BODY, LEGS), crafted=True, extra=()):
    rows = [row(i, "loadout", s, G(g)) for i, s, g in zip(worn, ("Head", "Body", "Legs"), guids)]
    if weapon:
        rows.append(row(weapon, "hotbar", guid=G("D")))
    rows += list(extra)
    end = gs(rows, pos=pos, pl=pl)
    if crafted:
        end["crafted"] = {i: 1 for i in (*worn, weapon) if i}
    return end


def start_v2(pl=0):
    """V1's save: his bone pickaxe (made in V1), the stone one, broken starter clothes."""
    return gs([row(BONE, "hotbar", guid=G("3")), row(STONE, "hotbar", guid=G("1")),
               row("ITEM_Armour_T1_Body_Adventurers", "loadout", "Body", G("8"), broken=True, durability=0)], pl=pl)


def test_v2_made_armour_worn_and_a_made_weapon_at_the_plains_power_passes(v2):
    ok, why = j.done(v2, start_v2(), kit(3))
    assert ok is True, why
    assert "Fractured Plains" in why and "power 3" in why and "power level 3" in why


def test_v2_below_the_regions_power_is_not_done(v2):
    ok, why = j.done(v2, start_v2(), kit(2))
    assert ok is False and "power level 2 of 3" in why


def test_v2_the_power_level_is_the_games_reading_unread_is_never_a_pass(v2):
    ok, why = j.done(v2, start_v2(), kit(None))
    assert ok is None and "power_level" in why


def test_v2_a_pickaxe_is_a_tool_not_a_weapon(v2):
    """The catalog's role for a pickaxe is 'weapon'; the game's own tag says tool (Item.Equipment.Tool.Pickaxe)."""
    end = kit(3, weapon=None, extra=[row(BRONZE, "hotbar", guid=G("E"))])
    end["crafted"][BRONZE] = 1
    ok, why = j.done(v2, start_v2(), end)
    assert ok is False and "weapon" in why


def test_v2_every_armour_slot_worn_whole_and_made_by_him(v2):
    ok, why = j.done(v2, start_v2(), kit(3, worn=(HEAD, BODY, LEGS), crafted=False))
    assert ok is False and "no craft" in why
    end = kit(3)
    end["worn_detail"]["Legs"]["broken"] = True
    assert j.done(v2, start_v2(), end)[0] is False
    ok, why = j.done(v2, start_v2(), kit(3, worn=(HEAD, BODY)))
    assert ok is False and "Legs: nothing worn" in why


def test_v2_gear_made_in_an_earlier_rung_of_his_counts_by_its_instance(v2):
    """Armour and a club he made in V1 are in V1's save: the ladder record of that run names their instances."""
    start = gs([row(HEAD, "loadout", "Head", G("A")), row(BODY, "loadout", "Body", G("B")),
                row(LEGS, "loadout", "Legs", G("C")), row(CLUB, "hotbar", guid=G("D"))], pl=3)
    end = kit(3, crafted=False)
    ok, why = j.done(v2, start, end)
    assert ok is False                                          # no ladder record: his start gear is not his make
    start["ladder_made"] = {HEAD: [G("A")], BODY: [G("B")], LEGS: [G("C")], CLUB: [G("D")]}
    ok, why = j.done(v2, start, end)
    assert ok is True, why
    start["ladder_made"] = {HEAD: [None], BODY: [G("B")], LEGS: [G("C")], CLUB: [G("D")]}
    end["worn_detail"]["Head"]["guid"] = None                   # the instance unread: never a pass
    assert j.done(v2, start, end)[0] is None


def test_v2_the_region_he_heads_for_sets_the_power(v2):
    """His walk toward Stormtouched Highlands (power 4): power level 3 is not enough there."""
    end = kit(3)
    end["walk_targets"] = [{"ts": T0 + 5, "position": PLAINS}, {"ts": T0 + 9, "position": HIGHLANDS}]
    ok, why = j.done(v2, start_v2(), end)
    assert ok is False and "Stormtouched Highlands" in why and "power level 3 of 4" in why
    end["walk_targets"] = [{"ts": T0 + 5, "position": HOME}]   # not a copper region: the default stands
    assert j.done(v2, start_v2(), end)[0] is True


def test_walk_targets_are_read_from_his_walks_in_the_brain_log():
    rows = [{"ts": T0 + 1, "kind": "tool_call", "call": "a", "tool": "go_to", "args": {"target": PLAINS}},
            {"ts": T0 + 2, "kind": "place_resolved", "place": "Fractured Plains", "position": PLAINS},
            {"ts": T0 + 3, "kind": "tool_result", "call": "b", "tool": "go_to",
             "result": {"ok": True, "data": {"target_position": HIGHLANDS}}},
            {"ts": T0 + 4, "kind": "tool_call", "call": "c", "tool": "go_to", "args": {"target": "Zanik"}}]
    assert [w["position"] for w in j.walk_targets(rows)] == [PLAINS, PLAINS, HIGHLANDS]
    assert "walk_targets" in j.evidence(rows)


def test_v2_entering_the_region_with_the_gear_for_its_power_passes(v2):
    end = kit(3, pos=PLAINS)
    end["entered"] = j.entry_read(v2, end, 120.0)
    assert end["entered"]["region"] == "Fractured Plains" and end["entered"]["power_level"] == 3
    ok, why = j.done(v2, start_v2(), end)
    assert ok is True and "entered Fractured Plains" in why


def test_v2_entering_below_its_power_is_recorded_and_judged_only_by_a_bar_the_goal_fixes(v2):
    """The goal does not fix a bar for going in under the region's power: the run records the fact and is not
    judged (bar_open). With an entry bar in the data (power - 1), it is judged by it."""
    end = kit(2, pos=PLAINS)
    end["entered"] = j.entry_read(v2, end, 120.0)
    assert end["entered"]["power_level"] == 2 and end["entered"]["power"] == 3
    ok, why = j.done(v2, start_v2(), end)
    assert ok is None and why.startswith("venture_gear: UNREAD") and "bar_open" in why
    lax = {**v2, "end": {"venture_gear": {**v2["end"]["venture_gear"], "entry_bar": {"min_below_power": 1}}}}
    assert j.done(lax, start_v2(), end)[0] is True


def test_v2_entering_without_gear_he_made_fails(v2):
    end = kit(3, pos=PLAINS, weapon=None)
    end["entered"] = j.entry_read(v2, end, 120.0)
    ok, why = j.done(v2, start_v2(), end)
    assert ok is False and "weapon" in why


def test_entry_read_is_none_outside_the_copper_regions(v2):
    assert j.entry_read(v2, kit(3, pos=HOME), 5.0) is None
    assert j.entry_read(v2, gs([], pos=None), 5.0) is None


# ------------------------------------------------------------------ the trial on a fake body
class Body:
    """run_job's view of the body: a clock, scripted rows, a state that is a function of time."""

    def __init__(self, states, script=()):
        self.t, self.states, self.script, self.sent = T0, states, list(script), []

    def now(self): return self.t
    def sleep(self, s): self.t += s
    def start_brain(self): return True
    def brain_logs(self): return ["brain-live-fake.jsonl"]
    def rows(self, a, b): return [r for r in self.script if a <= r["ts"] <= min(b, self.t)]
    def send(self, line): self.sent.append(line); return True  # noqa: E702
    def state(self): return self.states(self.t)
    def leave_dialogue(self): return []
    def stop_all(self): return []
    def inspect(self, cid): return {"ok": False, "reason": "unknown_target"}


def model(ts):
    return [{"ts": ts, "kind": "prompt", "component": "controller", "model": "claude-haiku-5-5"},
            {"ts": ts + 1, "kind": "llm_response", "component": "controller"}]


def raw(rows, pos, pl):
    return {"position": list(pos), "inventory_items": rows, "power_level": pl}


def test_run_job_v1_ends_when_the_game_reads_the_pickaxe(v1):
    script = model(T0 + 1) + [
        {"ts": T0 + 3, "kind": "tool_call", "call": "c1", "tool": "craft", "args": {"item": "Bone Pickaxe"}},
        {"ts": T0 + 20, "kind": "tool_result", "call": "c1", "tool": "craft",
         "result": {"ok": True, "data": {"item": BONE, "crafts": 1}}}]
    has = [row(STONE, "hotbar", guid=G("1"))]
    body = Body(lambda t: raw(has + ([row(BONE, "hotbar", guid=G("3"))] if t >= T0 + 20 else []), HOME, 0), script)
    rec = j.run_job(body, v1, {})
    assert body.sent == [v1["line"]]
    assert rec["ended"] == "job done" and rec["done"] is True and rec["rung"] == "V1"
    assert rec["run"].endswith("-L2-V1") and rec["item"] == "job: L2 / V1" and j.item_key(rec) == "L2 / V1"
    assert j.ladder_made(rec["state_start"], rec["state_end"], {}) == {BONE: [G("3")]}


def test_run_job_v2_ends_at_the_entry_and_records_his_power_level_there(v2):
    script = model(T0 + 1) + [
        {"ts": T0 + 3, "kind": "tool_call", "call": "w1", "tool": "go_to", "args": {"target": PLAINS}}]
    body = Body(lambda t: raw([row(BONE, "hotbar", guid=G("3"))], PLAINS if t >= T0 + 40 else HOME, 1), script)
    rec = j.run_job(body, v2, {"ladder_made": {BONE: [G("3")]}})
    assert rec["ended"] == "entered Fractured Plains"
    assert rec["entered"]["region"] == "Fractured Plains" and rec["entered"]["power_level"] == 1
    assert rec["done"] is False and "weapon" in rec["done_why"]        # no gear made: the doc's bar fails
    assert rec["state_start"]["ladder_made"] == {BONE: [G("3")]}
    assert rec["entered"]["t"] <= 40 + j.FAST_SAMPLE_S + 1             # read often while he can cross the border


def test_run_job_v2_bar_open_is_recorded_and_not_counted(v2):
    gear = [row(HEAD, "loadout", "Head", G("A")), row(BODY, "loadout", "Body", G("B")),
            row(LEGS, "loadout", "Legs", G("C")), row(CLUB, "hotbar", guid=G("D"))]
    script = model(T0 + 1) + [
        {"ts": T0 + 3, "kind": "tool_call", "call": "c1", "tool": "craft", "args": {}},
        {"ts": T0 + 4, "kind": "tool_result", "call": "c1", "tool": "craft",
         "result": {"ok": True, "data": {"item": CLUB}}}]
    for k, it in enumerate((HEAD, BODY, LEGS)):
        script += [{"ts": T0 + 5 + k, "kind": "tool_call", "call": f"a{k}", "tool": "craft", "args": {}},
                   {"ts": T0 + 5.5 + k, "kind": "tool_result", "call": f"a{k}", "tool": "craft",
                    "result": {"ok": True, "data": {"item": it}}}]
    body = Body(lambda t: raw(gear if t >= T0 + 10 else [], PLAINS if t >= T0 + 40 else HOME, 2), script)
    rec = j.run_job(body, v2, {})
    assert rec["ended"] == "entered Fractured Plains" and rec["done"] is False and rec["job_done"] is False
    assert rec["bar_open"] and "bar_open" in rec["not_counted"] and "unread" not in rec
    assert j.not_counted(rec)


# ------------------------------------------------------------------ the checkpoint and the ladder record
def test_the_ladder_record_carries_what_he_made_to_the_next_rung(tmp_path):
    start = gs([row(STONE, "hotbar", guid=G("1"))])
    end = gs([row(STONE, "hotbar", guid=G("1")), row(BONE, "hotbar", guid=G("3")), row(CLUB, "hotbar")])
    end["crafted"] = {BONE: 1, CLUB: 1}
    made = j.ladder_made(start, end, {HEAD: [G("A")]})
    assert made == {HEAD: [G("A")], BONE: [G("3")], CLUB: [None]}  # an instance unread is kept as unread
    rec = {"run": "20261118-100000-L2-V1", "job": "L2", "rung": "V1", "state_start": start, "state_end": end}
    p = j.write_ladder(rec, "job_l2_v1", {}, folder=tmp_path)
    assert p.name == "job_l2_v1.ladder.json"
    got = j.read_ladder("job_l2_v1", folder=tmp_path)
    assert got["made"] == {BONE: [G("3")], CLUB: [None]} and got["runs"] == ["20261118-100000-L2-V1"]
    assert j.read_ladder("ClaudeDev", folder=tmp_path) == {}
    assert json.loads(p.read_text(encoding="utf-8"))["rung"] == "V1"


def test_save_ok_for_a_rung_is_its_pass_only():
    assert j.save_ok({"job_done": True, "ended": "job done"}, "done")[0] is True
    assert j.save_ok({"job_done": False, "ended": "entered Fractured Plains"}, "done")[0] is False
    rung = {"rung": "V1", "job_done": True, "ended": "job done"}
    assert j.save_ok({**rung, "verdict": {"pass": True, "bars": {}}}, "done")[0] is True
    ok, why = j.save_ok({**rung, "verdict": {"pass": False, "bars": {"done": True, "time": False}}}, "done")
    assert ok is False and "time" in why                     # done, but not a passing run: no checkpoint


# ------------------------------------------------------------------ the command line
def test_cli_rung_v1_and_v2_reach_the_window(monkeypatch):
    seen = []
    monkeypatch.setattr(j, "cmd_window", lambda a, step: seen.append((a.job, a.rung, a.k, a.checkpoint, step)) or 0)
    assert j.main(["trial", "--job", "L2", "--rung", "V1", "-k", "5"]) == 0
    assert j.main(["trial", "--job", "L2", "--rung", "V2", "--from", "job_l2_v1"]) == 0
    assert seen == [("L2", "V1", 5, None, None), ("L2", "V2", 3, "job_l2_v1", None)]
    assert j.main(["trial", "--job", "L2", "--rung", "V1", "--interrupt", "I1"]) == 2   # a rung is a whole trial


def test_a_rungs_default_start_is_its_from(v1, v2):
    assert j.start_ref(v1, None, None)[0] == "ClaudeDev"
    assert j.start_ref(v2, None, None)[0] == "job_l2_v1"
    assert j.start_ref(v2, None, "job_l2_v1b")[0] == "job_l2_v1b"
