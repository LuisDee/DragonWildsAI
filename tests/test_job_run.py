"""tools/job_run.py: the long-job harness, offline. Every live piece is a fake: no server, client, brain or model."""
from __future__ import annotations

import json

import pytest

from tools import job_run as j
from tools import quest_run as q


@pytest.fixture(autouse=True)
def _no_live_stop_file(monkeypatch, tmp_path):
    """The live tree's logs/job_run.stop (set by hand to end a window) never reaches a test: 11 tests read it as
    "stopped" on 2026-11-20 while it stood from 04:13Z."""
    monkeypatch.setattr(j, "STOP_FILE", tmp_path / "job_run.stop")


T0 = 1000.0
CRATE = "BP_BaseBuilding_Crate_C_7"


# ------------------------------------------------------------------ helpers
def call(ts, cid, tool, args=None):
    return {"ts": ts, "kind": "tool_call", "call": cid, "tool": tool, "args": args or {}}


def result(ts, cid, tool, ok=True, reason=None, data=None):
    return {"ts": ts, "kind": "tool_result", "call": cid, "tool": tool,
            "result": {"ok": ok, "reason": reason, "data": data or {}}}


def model(ts):
    return [{"ts": ts, "kind": "prompt", "component": "controller", "model": "claude-haiku-5-5"},
            {"ts": ts + 1, "kind": "llm_response", "component": "controller"}]


def state(carried=None, worn=None, food=0, drink=0, pos=(0.0, 0.0, 0.0), mine=(), dead=False):
    rows = [{"item": k, "count": n, "where": "bag"} for k, n in (carried or {}).items()]
    rows += [{"item": v, "count": 1, "where": "loadout", "loadout_slot": k} for k, v in (worn or {}).items()]
    if food:
        rows.append({"item": "ITEM_Consumable_Farm_Steak", "count": food, "where": "bag", "consumable": "food"})
    if drink:
        rows.append({"item": "ITEM_Consumable_Water_Clean", "count": drink, "where": "bag", "consumable": "drink"})
    return {"position": list(pos), "inventory_items": rows, "dead": dead,
            "structures": [{"id": m, "mine": True, "position": [1, 2, 3]} for m in mine]}


def snap(*a, **k):
    return j.snapshot(state(*a, **k))


@pytest.fixture(scope="module")
def doc():
    return j.load_jobs()


# ------------------------------------------------------------------ the data
def test_jobs_file_has_the_goals_jobs_and_steps(doc):
    jobs = doc["jobs"]
    assert set(jobs) == {"L1", "L2", "L3", "N1", "N2", "H1", "H2", "H3", "K"}
    assert {k for k, v in jobs.items() if v["held_out"]} == {"H1", "H2", "H3"}
    for k, v in jobs.items():
        assert "\n" not in v["line"] and v["line"].startswith("claude, "), k
        assert v["end"] and set(v["end"]) <= set(j.PREDICATES), k
        assert v["start"] and v["work_tools"], k
        assert v["bar"] is None and v.get("bar_note") or v["bar"]["parts"], k
    assert set(doc["interruptions"]) == set(j.STEPS)
    assert all(doc["interruptions"][s].get("resume_within_s") for s in j.STEPS)


def test_job_of_refuses_an_unknown_job(doc):
    assert j.job_of("L2", doc)["id"] == "L2"
    with pytest.raises(SystemExit):
        j.job_of("L9", doc)


# ------------------------------------------------------------------ reading the game
def test_snapshot_of_get_state_and_of_a_raw_inventory():
    s = snap({"ITEM_Resources_CopperOre": 12}, {"Body": "ITEM_Armour_T2_Body_Leather"}, food=3, drink=2,
             mine=[CRATE])
    assert s["carried"]["ITEM_Resources_CopperOre"] == 12 and s["carried"]["ITEM_Armour_T2_Body_Leather"] == 1
    assert s["worn"] == {"Body": "ITEM_Armour_T2_Body_Leather"}
    assert s["consumables"] == {"food": 3, "drink": 2} and s["own_containers"] == [CRATE]
    raw = {"ok": True, "data": {"hotbar": [{"item": "ITEM_Pickaxe_Bronze", "count": 1}],
                                "bag": [{"item": "ITEM_Resources_Stone", "count": 40}],
                                "loadout": [{"item": "ITEM_Sword_Bronze", "loadout_slot": "HeldRight"}],
                                "empty_slots": 4}}
    r = j.snapshot(raw)
    assert r["carried"] == {"ITEM_Pickaxe_Bronze": 1, "ITEM_Resources_Stone": 40, "ITEM_Sword_Bronze": 1}
    assert r["worn"] == {"HeldRight": "ITEM_Sword_Bronze"} and r["empty_slots"] == 4


def test_chests_seen_takes_the_newest_read_and_the_one_item_count():
    rows = [result(1, "a", "store", data={"container": CRATE, "contents": ["10 Copper Ore"]}),
            result(2, "b", "store", data={"container": CRATE, "item": "ITEM_Resources_CopperOre", "inside_now": 30,
                                          "contents": ["30 Copper Ore", "2 Stone"]}),
            result(3, "c", "take", data={"container": "BP_Gravestone_C_1", "contents": ["1 Torch"]}),
            result(4, "d", "gather", data={"container": "x", "contents": ["9 Stone"]})]
    c = j.chests_seen(rows)
    assert list(c) == [CRATE]
    assert c[CRATE]["items"] == {"ITEM_Resources_CopperOre": 30, "ITEM_Resources_Stone": 2}


def test_crafted_in_run_counts_only_confirmed_crafts():
    rows = [result(1, "a", "craft", data={"item": "ITEM_Armour_T2_Body_Leather", "crafts": 1}),
            result(2, "b", "craft", ok=False, reason="missing_inputs", data={"item": "ITEM_Armour_T2_Legs_Leather"})]
    assert j.crafted_in_run(rows) == {"ITEM_Armour_T2_Body_Leather": 1}


# ------------------------------------------------------------------ the end predicates
LEATHER = {"Head": "ITEM_Armour_T2_Head_Leather", "Body": "ITEM_Armour_T2_Body_Leather",
           "Legs": "ITEM_Armour_T2_Legs_Leather"}


def test_l1_done_when_all_three_are_worn_and_made_in_the_run(doc):
    job = j.job_of("L1", doc)
    start = snap()
    end = snap(worn=LEATHER)
    end["crafted"] = {v: 1 for v in LEATHER.values()}
    ok, why = j.done(job, start, end)
    assert ok, why
    end["crafted"].pop(LEATHER["Legs"])
    ok, why = j.done(job, start, end)
    assert not ok and "Legs" in why and "no craft" in why
    held = snap(carried={LEATHER["Legs"]: 1})  # he had chaps before the run, and no instance guid was read
    end["crafted"] = {v: 1 for v in LEATHER.values()}
    end2 = snap(worn=LEATHER)  # chaps at the start, chaps (worn) at the end: the same pair or a new one?
    end2["crafted"] = end["crafted"]
    ok, why = j.done(job, held, end2)
    assert ok is None and "Legs" in why and "cannot tell" in why  # unread, never a pass (tests/test_job_run_l1.py)


def test_l1_not_counted_when_he_starts_with_hides(doc):
    job = j.job_of("L1", doc)
    assert j.not_counted(job, snap({"ITEM_Resources_Animal_Hide": 4})).startswith("held at the start")
    assert j.not_counted(job, snap({"ITEM_Resources_Stone": 4})) is None
    assert j.not_counted({"not_counted": "x"}) == "x"


def end_read(n, item="ITEM_Resources_CopperOre"):
    return {"read": True, "items": {item: n} if n else {}, "kind": "storage", "class": "BP_BaseBuilding_Crate_C"}


def test_l2_done_from_the_end_read_of_his_own_chest_only(doc):
    job = j.job_of("L2", doc)
    rows = [result(5, "s", "store", data={"container": CRATE, "item": "ITEM_Resources_CopperOre", "inside_now": 30,
                                          "contents": ["30 Copper Ore"]})]
    start, end = snap(mine=[CRATE]), snap()
    end.update(j.evidence(rows))
    end["chest_end"] = {CRATE: end_read(30)}
    assert j.done(job, start, end)[0] is True
    not_his = snap()
    assert j.done(job, not_his, dict(end, chest_end={}))[0] is None  # he stored in it, nothing marked it his: unread
    rows[0]["result"]["data"].update(inside_now=29, contents=["29 Copper Ore"])
    end.update(j.evidence(rows))
    end["chest_end"] = {CRATE: end_read(29)}
    ok, why = j.done(job, start, end)
    assert ok is False and "29 of 30" in why


def test_h1_made_gained_and_back(doc):
    job = j.job_of("H1", doc)
    start = snap({"ITEM_Resources_Animal_Hide": 1}, pos=(0, 0, 0))
    end = snap({"ITEM_Shortbow_Wood": 1, "ITEM_Ammo_Arrows_Wood": 45, "ITEM_Resources_Animal_Hide": 6}, pos=(10, 5, 0))
    end["crafted"] = {"ITEM_Shortbow_Wood": 1, "ITEM_Ammo_Arrows_Wood": 3}
    assert j.done(job, start, end)[0]
    far = dict(end, position=[200, 0, 0])
    ok, why = j.done(job, start, far)
    assert not ok and "near_start_m: NO" in why
    end["crafted"] = {"ITEM_Shortbow_Wood": 1}
    assert "no craft" in j.done(job, start, end)[1]


def test_h2_cooked_meals_and_water_in_his_chest(doc):
    job = j.job_of("H2", doc)
    cooked = sorted(x for x in j.made_at(["Campfire", "Grill"], "Item.Food") if "Burnt" not in x)[0]
    start, end = snap(mine=[CRATE]), snap()
    start["chest_start"] = {CRATE: {"read": True, "items": {cooked: 26, "ITEM_Consumable_Water_Clean": 29}}}
    end["chest_end"] = {CRATE: {"read": True, "items": {cooked: 26, "ITEM_Consumable_Water_Clean": 29}}}
    assert not j.done(job, start, end)[0]   # the base crate already held them: nothing was put in (gained)
    end["chest_end"] = {CRATE: {"read": True, "items": {cooked: 36, "ITEM_Consumable_Water_Clean": 39}}}
    assert j.done(job, start, end)[0]
    start["chest_start"] = {CRATE: {"read": True, "items": {}}}
    end["chest_end"] = {CRATE: {"read": True, "items": {cooked: 10, "ITEM_Consumable_Water_Clean": 10}}}
    assert j.done(job, start, end)[0]
    end["chest_end"][CRATE]["items"] = {"ITEM_Consumable_Bread_Burnt": 10, "ITEM_Consumable_Water_Clean": 10}
    assert not j.done(job, start, end)[0]


def test_h3_next_tier_of_each_family_he_carried(doc):
    job = j.job_of("H3", doc)
    start = snap({"ITEM_Pickaxe_Stone": 1, "ITEM_Logging_Axe_Stone": 1})
    end = snap({"ITEM_Pickaxe_Stone": 1, "ITEM_Pickaxe_Bronze": 1, "ITEM_Logging_Axe_Bronze": 1})
    assert j.done(job, start, end)[0]
    ok, why = j.done(job, start, snap({"ITEM_Pickaxe_Bronze": 1, "ITEM_Logging_Axe_Stone": 1}))
    assert not ok and "logging axe" in why
    # the logging axe has no Bone tier: Stone (tier 1) steps up to Bronze (3); a Rune pickaxe (tier 7, PL 8) is above
    # an Adamant one (tier 7, PL 7); watering cans all read tier 0 and rank by power level
    assert j.done(job, snap({"ITEM_Pickaxe_Adamant": 1}), snap({"ITEM_Pickaxe_Rune": 1}))[0]
    assert not j.done(job, snap({"ITEM_Pickaxe_Rune": 1}), snap({"ITEM_Pickaxe_Rune": 1, "ITEM_Pickaxe_Adamant": 1}))[0]
    assert j.done(job, snap({"ITEM_WateringCan_Wood": 1}), snap({"ITEM_WateringCan_Bronze": 1}))[0]
    assert not j.done(job, snap({"ITEM_WateringCan_Steel": 1}), snap({"ITEM_WateringCan_Bronze": 1}))[0]


TOOLS_NONE = {"ITEM_Ammo_Arrows_Stone": 20, "ITEM_Sword_Bronze": 1, "ITEM_Resources_Stone": 5}  # ClaudeDev's fork
FIRST = {"ITEM_Pickaxe_Stone": 1, "ITEM_Logging_Axe_Stone": 1, "ITEM_WateringCan_Wood": 1}


def test_h3_from_none_one_of_each_family(doc):
    job = j.job_of("H3", doc)
    assert job["line"] == "claude, get yourself the next tools up from the ones you carry"
    start = snap(TOOLS_NONE)
    ok, why = j.done(job, start, snap({**TOOLS_NONE, **FIRST}))
    assert ok and "carried none" in why
    # one family missing: a fail that names it
    ok, why = j.done(job, start, snap({**TOOLS_NONE, "ITEM_Pickaxe_Stone": 1, "ITEM_Logging_Axe_Stone": 1}))
    assert ok is False and "watering can: none -> nothing higher" in why
    # nothing got: a fail, never a grader fault
    ok, why = j.done(job, start, snap(TOOLS_NONE))
    assert ok is False and "pickaxe: none -> nothing higher" in why
    # a higher tier than the first counts as a step up from none
    assert j.done(job, start, snap({"ITEM_Pickaxe_Bone": 1, "ITEM_Logging_Axe_Bronze": 1, "ITEM_WateringCan_Wood": 1}))[0]


def test_h3_broken_tool_is_no_step_up(doc):
    job = j.job_of("H3", doc)
    st = state({**TOOLS_NONE, **FIRST})
    for r in st["inventory_items"]:
        if r["item"] == "ITEM_Pickaxe_Stone":
            r.update(broken=True, durability=0, max_durability=100)
    ok, why = j.done(job, snap(TOOLS_NONE), j.snapshot(st))
    assert ok is False and "ITEM_Pickaxe_Stone broken" in why
    # a broken one beside a whole one of the family: the whole one counts
    st["inventory_items"].append({"item": "ITEM_Pickaxe_Bone", "count": 1, "where": "hotbar"})
    assert j.done(job, snap(TOOLS_NONE), j.snapshot(st))[0]


def test_h3_unread_and_no_from_none(doc):
    job = j.job_of("H3", doc)
    end = snap({**TOOLS_NONE, **FIRST})
    assert j.done(job, {"unread": "get_state failed"}, end)[0] is None
    assert j.done(job, snap(TOOLS_NONE), {"unread": "get_state failed"})[0] is None
    spec = {k: v for k, v in job["end"]["next_tier_tools"].items() if k != "from_none"}
    ok, why = j.p_next_tier_tools(spec, snap(TOOLS_NONE), end)
    assert ok is None and "nothing to step up from" in why


def test_l3_gear_target_and_consumables(doc):
    cat = {"H": {"power_level": 3}, "B": {"power_level": 3}, "L": {"power_level": 3}, "S": {"power_level": 3}}
    start = snap()
    start["gear_target"] = {"pl": 3, "kit": {"right_hand": 3}}
    end = snap(worn={"Head": "H", "Body": "B", "Legs": "L", "HeldRight": "S"}, food=5, drink=5)
    assert j.p_gear_target({}, start, end, cat)[0]
    end["worn"]["Legs"] = None
    ok, why = j.p_gear_target({}, start, end, cat)
    assert not ok and "armour PL 2 of 3" in why
    assert not j.p_gear_target({}, snap(), end, cat)[0]  # no target at the start: never done
    assert j.p_consumables_carried({"food": 5, "drink": 5}, start, snap(food=5, drink=5))[0]
    assert not j.p_consumables_carried({"food": 5, "drink": 5}, start, snap(food=5, drink=4))[0]


def test_unknown_predicate_is_never_done():
    assert j.done({"end": {"vibes": 1}}, snap(), snap()) == (False, "unknown predicate 'vibes'")
    assert j.done({"end": {}}, snap(), snap())[0] is False


# ------------------------------------------------------------------ the bar
def test_bar_s_from_luis_baselines(doc):
    b = q._baseline()
    l2 = j.bar_s(j.job_of("L2", doc), b)
    assert l2 == pytest.approx(30 * q._per_item(b, "mine") + 2 * b["families"]["pickup"]["unit_s"], abs=0.1)
    assert j.bar_s(j.job_of("L1", doc), b) > 300
    assert j.bar_s(j.job_of("L3", doc), b) is None
    with pytest.raises(KeyError):
        j.bar_s({"bar": {"parts": [{"task": "no such task"}]}}, b)


# ------------------------------------------------------------------ misses, steps, resumption
CALLS = [{"t": 2.0, "tool": "gather", "args": {"resource": "copper"}, "dur_s": 20.0, "ok": True},
         {"t": 23.0, "tool": "attack", "args": {"target": "x"}, "dur_s": 1.0, "ok": False, "reason": "no_target"},
         {"t": 30.0, "tool": "look", "args": {}, "dur_s": 1.0, "ok": False, "reason": "nothing"},
         {"t": 40.0, "tool": "gather", "args": {}, "dur_s": 5.0, "ok": False, "reason": "interrupted"},
         {"t": 70.0, "tool": "store", "args": {"item": "Copper Ore"}, "dur_s": 9.0, "ok": False, "reason": "container_full"},
         {"t": 90.0, "tool": "gather", "args": {}, "dur_s": 9.0, "ok": True}]


def test_misses_follow_quest_runs_rule_with_kind_time_and_call():
    m = j.misses(CALLS, work_s=150.0, interruption={"t_put": 50.0, "t_resumed": 90.0})
    assert m["n"] == len(q.verdict({"tool_calls": CALLS})["misses"]) == 2
    assert m["list"][0] == {"t": 23.0, "kind": "no_target", "tool": "attack", "args": {"target": "x"}, "detail": None}
    assert m["per_5min"] == 4.0
    assert m["by_phase"] == {"before": 1, "during": 1, "after": 0}
    assert j.misses([], 0)["per_5min"] is None


def test_first_step_is_the_first_ok_work_call():
    job = {"work_tools": ["gather", "store"]}
    assert j.first_step(CALLS, job) == 22.0
    assert j.first_step(CALLS[1:4], job) is None


def test_resumed_with_and_without_a_new_line():
    intr = {"t_put": 50.0, "t_clear": 60.0}
    r = j.resumed(CALLS, intr, ["gather", "store"])
    assert r["resumed"] and r["after_s"] == 10.0 and r["call"]["tool"] == "store" and not r["new_line"]
    r = j.resumed(CALLS, intr, ["gather", "store"], lines=[{"t": 65.0, "line": "claude, the ore?"}])
    assert r["new_line"]
    assert not j.resumed(CALLS, {"t_put": 95.0, "t_clear": 100.0}, ["gather"])["resumed"]
    assert j.resumed(CALLS, {"t_put": 95.0}, ["gather"])["why"] == "the interruption has not cleared"
    # a read is never taking the job up again, even if listed
    assert not j.resumed([{"t": 70.0, "tool": "look"}], {"t_clear": 60.0}, ["look"])["resumed"]


def test_trigger_due():
    assert not j.trigger_due("first_step", None, 500, 100)
    assert j.trigger_due("first_step", 22.0, 22.0, None)
    assert j.trigger_due("share:0.5", None, 50.0, 100.0) and not j.trigger_due("share:0.5", None, 49.0, 100.0)
    assert j.trigger_due("share:0.5", 10.0, 11.0, None)  # no bar: after the first step
    assert j.trigger_due("at:120", None, 120.0, None)


# ------------------------------------------------------------------ the verdict, the ledger, rates, the guard
def irec(run="20261117-120000-L2-I3", resumed=True, after=12.0, took=True, new_line=False, job="L2", held=False):
    return {"run": run, "item": f"job: {job} / I3", "kind": "interrupt", "job": job, "step": "I3", "held_out": held,
            "until": "resumed", "done": resumed, "ended": "resumed" if resumed else "no resumption", "wall_s": 200.0,
            "interruption": {"step": "I3", "took": took, "t_put": 30.0, "t_clear": 60.0},
            "resume": {"resumed": resumed, "after_s": after if resumed else None, "new_line": new_line},
            "resume_within_s": 180, "misses": j.misses(CALLS, 150.0), "idle_over_5s": [], "tool_calls": CALLS}


def test_interrupt_verdict():
    assert j.verdict(irec())["pass"]
    assert not j.verdict(irec(resumed=False))["pass"]
    assert not j.verdict(irec(new_line=True))["bars"]["no_new_line"]
    assert not j.verdict(irec(after=200.0))["bars"]["in_time"]
    assert not j.verdict(irec(took=False))["bars"]["interrupted"]


def test_whole_job_verdict_uses_quest_runs_bars_and_the_jobs_count_rule():
    rec = {"run": "20261117-120000-L2", "kind": "job", "job": "L2", "done": True, "ratio": 1.2, "checkpoint": "ClaudeDev",
           "tool_calls": CALLS[:1], "idle_over_5s": []}
    assert j.verdict(rec)["pass"]
    rec["not_counted"] = "held at the start: hides"
    v = j.verdict(rec)
    assert not v["pass"] and v["bars"]["counted"] is False


def test_failure_ledger_scan_finds_a_failed_job_run(tmp_path):
    from tools import failure_ledger as fl
    path = tmp_path / "ledger.jsonl"
    recs = [irec(), irec(run="20261117-130000-L2-I3", resumed=False)]
    new = fl.scan(recs, j.verdict, j.not_counted, path=path)
    assert [r["run"] for r in new] == ["20261117-130000-L2-I3"]
    assert new[0]["first_wrong"] == "miss: attack no_target"  # the first thing that went wrong, by the ledger's rule


def test_rates_split_items_and_held_out():
    recs = [irec(), irec(run="20261117-130000-L2-I3", resumed=False), irec(run="20261117-140000-L2-I3"),
            irec(run="20261117-150000-H1-I3", job="H1", held=True)]
    rs = j.rates(recs, void={"20261117-130000-L2-I3"})
    assert rs["L2 / I3"] == {"passes": 2, "of": 2, "streak": 2, "held_out": False}
    assert rs["H1 / I3"]["held_out"] is True
    probe = dict(irec(run="20261117-160000-L2-I3"), until="first_step")
    assert "L2 / I3" in j.rates([probe] + recs[:1], set()) and j.rates([probe], set()) == {}


def test_held_out_trace_guard():
    h = [irec(run=f"20261117-15000{i}-H1-I3", job="H1", held=True) for i in range(3)]
    assert not j.trace_allowed(h[0], h[:1], set(), read_trace=False)[0]
    assert not j.trace_allowed(h[0], h[:2], set(), read_trace=True)[0]          # 2 of 3 scored
    assert j.trace_allowed(h[0], h, set(), read_trace=True)[0]
    assert not j.trace_allowed(h[0], h, set(), read_trace=False)[0]            # never without the flag
    assert not j.trace_allowed(h[0], h, {h[1]["run"]}, read_trace=True)[0]    # a void run is not scored
    t = [irec(run=f"20261117-16000{i}-L2-I3") for i in range(3)]
    assert not j.trace_allowed(t[0], t[:2], set(), read_trace=False)[0]       # anything new: three scored first
    assert j.trace_allowed(t[0], t, set(), read_trace=False)[0]


def test_show_prints_scores_but_not_a_held_out_trace(tmp_path, monkeypatch, capsys):
    from tools import failure_ledger as fl
    rec = irec(run="20261117-150000-H1-I3", job="H1", held=True)
    out = tmp_path / "job_runs.jsonl"
    out.write_text(json.dumps(rec) + "\n", encoding="utf-8")
    monkeypatch.setattr(j, "OUT", out)
    monkeypatch.setattr(fl, "LEDGER", tmp_path / "ledger.jsonl")
    assert j.main(["show", rec["run"], "--read-trace"]) == 0
    text = capsys.readouterr().out
    assert '"resumed": true' in text and "trace stays closed" in text and "gather" not in text


def test_blind_mark_first_three_and_a_trace_read_before(tmp_path):
    t = [irec(run=f"20261117-16000{i}-L2-I3") for i in range(4)]
    assert j.blind_mark(t[0], [], set(), []) == {"trial_n": 1, "first_three_blind": True}
    assert j.blind_mark(t[2], t[:2], set(), []) == {"trial_n": 3, "first_three_blind": True}
    assert j.blind_mark(t[3], t[:3], set(), []) == {"trial_n": 4}                       # past the first three: no flag
    assert j.blind_mark(t[3], t[:3], {t[1]["run"]}, [])["trial_n"] == 3                  # a void run is not a trial
    reads = tmp_path / "reads.jsonl"
    j.note_trace_read(t[0], reads, now=1795428000.0)                                     # 2026-11-23: after t[1]
    early = [dict(r, at="20261117-155959") for r in j.trace_reads(reads)]
    assert j.trace_reads(reads)[0]["job"] == "L2" and j.trace_reads(reads)[0]["item"] == "L2 / I3"
    assert j.blind_mark(t[1], t[:1], set(), j.trace_reads(reads))["first_three_blind"] is True   # read after it
    m = j.blind_mark(t[1], t[:1], set(), early)
    assert m["first_three_blind"] is False and m["trace_read_before"] == [t[0]["run"]]
    assert j.blind_mark(dict(t[1], until="first_step"), [], set(), []) == {}           # a probe is not a trial
    assert j.blind_mark(dict(t[1], not_counted="head start"), [], set(), []) == {}


def test_show_notes_an_opened_trace_and_scores_carry_the_flag(tmp_path, monkeypatch, capsys):
    from tools import failure_ledger as fl
    recs = [dict(irec(run=f"20261117-16000{i}-L2-I3"), trial_n=i + 1, first_three_blind=True) for i in range(3)]
    out = tmp_path / "job_runs.jsonl"
    out.write_text("".join(json.dumps(r) + "\n" for r in recs), encoding="utf-8")
    monkeypatch.setattr(j, "OUT", out)
    monkeypatch.setattr(j, "TRACE_READS", tmp_path / "reads.jsonl")
    monkeypatch.setattr(fl, "LEDGER", tmp_path / "ledger.jsonl")
    assert j.main(["show", recs[0]["run"]]) == 0
    assert '"first_three_blind": true' in capsys.readouterr().out
    assert [r["run"] for r in j.trace_reads()] == [recs[0]["run"]]                     # three scored: it opened


# ------------------------------------------------------------------ the interruptions, on a fake body
class FakeIO:
    """The body, brain and fixtures as run_job sees them: a clock, scripted brain-log rows, scripted states."""

    def __init__(self, script=(), states=None, me_seq=None, room=None, fixture_fail=None, chests=None):
        self.t = T0
        self.script = list(script)
        self.states = states or (lambda t: state())
        self.me_seq = list(me_seq or [])
        self.room = list(room or [])
        self.chests = chests if callable(chests) else (lambda t, cid: (chests or {}).get(cid))
        self.inspected: list[str] = []
        self.fixtures: list[tuple] = []
        self.restarts = 0
        self.sent: list[str] = []
        self.fixture_fail = fixture_fail

    def now(self):
        return self.t

    def sleep(self, s):
        self.t += s

    def start_brain(self):
        return True

    def restart_brain(self, gap_s):
        self.t += gap_s
        self.restarts += 1
        return True

    def brain_logs(self):
        return ["brain-live-fake.jsonl"]

    def rows(self, a, b):
        return [r for r in self.script if a <= r["ts"] <= min(b, self.t)]

    def send(self, line):
        self.sent.append(line)
        return True

    def state(self):
        return self.states(self.t)

    def me(self):
        return self.me_seq.pop(0) if self.me_seq else {"position": [0, 0, 0]}

    def bag_room(self):
        return self.room.pop(0) if self.room else 0

    def inspect(self, cid):
        self.inspected.append(cid)
        c = self.chests(self.t, cid)
        if c is None:
            return {"ok": False, "reason": "unknown_target", "data": {"detail": "not perceived within 60 m"}}
        return {"ok": True, "data": {"id": cid, "class": "BP_BaseBuilding_Crate_C", "kind": "storage", "contents": c}}

    def fixture(self, verb, purpose, **kw):
        if self.fixture_fail:
            raise RuntimeError(self.fixture_fail)
        self.fixtures.append((verb, kw))
        return {"ok": True, "after": kw.get("pct"), "id": "BP_AI_RuntGoblin_Character_C_1"}

    def gear_target(self, raw, vault=None):
        self.gear_vault = vault
        return {"pl": 3, "kit": {}}

    def leave_dialogue(self):
        return []

    def stop_all(self):
        return []


def test_i1_sets_food_and_water_low():
    io = FakeIO()
    out = j.apply_interruption(io, "I1", {"what": "hunger", "pct": 10}, T0)
    assert out["took"] and out["t_clear"] == 0.0
    assert io.fixtures == [("set_stat", {"stat": "sustenance", "pct": 10.0}), ("set_stat", {"stat": "hydration", "pct": 10.0})]


def test_i3_waits_for_the_respawn_away_from_the_death():
    io = FakeIO(me_seq=[{"position": [0, 0, 0]}, {"dead": True, "position": [0, 0, 0]}, {"position": [200, 0, 0]}])
    out = j.apply_interruption(io, "I3", {"respawn_wait_s": 120}, T0)
    assert io.fixtures == [("set_health", {"value": 0.0})]
    assert out["took"] and out["t_clear"] == 2.0 and out["respawned_at"] == [200, 0, 0]
    io = FakeIO(me_seq=[{"position": [0, 0, 0]}] + [{"dead": True, "position": [0, 0, 0]}] * 100)
    out = j.apply_interruption(io, "I3", {"respawn_wait_s": 10}, T0)
    assert not out["took"] and out["t_clear"] is None and "no respawn" in out["how"]


def test_i4_fills_his_bag_until_no_slot_is_left():
    io = FakeIO(room=[12, 2, 0])
    out = j.apply_interruption(io, "I4", {"filler": "ITEM_FishingNet_CoarseNet", "rounds": 3}, T0)
    # full_read, not took: the fill is an interruption only once a call of his meets it (job_run.bag_watch)
    assert [kw["count"] for v, kw in io.fixtures] == [12, 2] and out["full_read"] and out["took"] is None
    io = FakeIO(room=[5] * 40)  # a bag that never fills: every read 5
    assert not j.apply_interruption(io, "I4", {"filler": "x", "rounds": 3}, T0)["took"]


def test_i5_restarts_the_brain_and_a_failed_fixture_does_not_take():
    io = FakeIO()
    out = j.apply_interruption(io, "I5", {"gap_s": 5}, T0)
    assert io.restarts == 1 and out["took"] and out["t_clear"] == 5.0
    out = j.apply_interruption(FakeIO(fixture_fail="other_players_connected"), "I1", {}, T0)
    assert out["took"] is False and "other_players_connected" in out["how"]


def test_i2_clears_at_combat_end_or_does_not_take():
    intr = {"step": "I2", "t_put": 10.0, "t_clear": None, "took": None, "how": "spawned"}
    ev = lambda ts, kind: {"ts": ts, "kind": "event", "event": {"type": "activity", "kind": kind, "ts": ts}}  # noqa: E731
    out = j.fight_cleared([ev(T0 + 12, "combat_started"), ev(T0 + 25, "combat_end")], intr, T0, 40)
    assert out["took"] and out["t_clear"] == 25.0
    out = j.fight_cleared([ev(T0 + 12, "combat_started")], intr, T0, 40)
    assert out["took"] and out["t_clear"] is None
    out = j.fight_cleared([{"ts": T0 + 60, "kind": "say"}], intr, T0, 40)
    assert out["took"] is False and "no fight" in out["how"]


# ------------------------------------------------------------------ whole trials on the fake body
def l2_script(store_at=30.0, extra=()):
    rows = model(T0 + 1)
    rows += [call(T0 + 3, "g1", "gather", {"resource": "copper"}),
             result(T0 + 20, "g1", "gather", data={"detail": "Got 30 copper ore.", "count": 30}),
             call(T0 + 21, "s1", "store", {"item": "Copper Ore", "container": CRATE}),
             result(T0 + store_at, "s1", "store", data={"container": CRATE, "item": "ITEM_Resources_CopperOre",
                                                        "inside_now": 30, "contents": ["30 Copper Ore"]})]
    return sorted(rows + list(extra), key=lambda r: r["ts"])


def test_run_job_whole_l2_ends_when_the_game_says_done(doc):
    io = FakeIO(script=l2_script(), states=lambda t: state(mine=[CRATE]),
                chests={CRATE: [{"item": "ITEM_Resources_CopperOre", "name": "Copper Ore", "count": 30}]})
    rec = j.run_job(io, j.job_of("L2", doc), {"interruptions": doc["interruptions"]})
    assert rec["ended"] == "job done" and rec["done"] and rec["job_done"]
    assert io.sent == [doc["jobs"]["L2"]["line"]]
    assert rec["first_step_s"] == 20.0 and rec["misses"]["n"] == 0 and rec["kind"] == "job"
    assert rec["run"].endswith("-L2") and rec["item"] == "job: L2" and rec["chests"][CRATE]["items"]
    assert rec["verdict"]["bars"]["done"]


def test_run_job_i5_resumes_after_the_restart(doc):
    after = model(T0 + 30) + [call(T0 + 33, "g2", "gather", {"resource": "copper"}),
                              result(T0 + 60, "g2", "gather", data={"detail": "Got 5 copper ore."})]
    script = model(T0 + 1) + [call(T0 + 3, "g1", "gather"), result(T0 + 20, "g1", "gather", data={"detail": "Got 3."})]
    # the gather after the restart moved the job by the game's reads (5 copper on him after it): serves_test
    io = FakeIO(script=script + after, states=lambda t: state(carried={"ITEM_Resources_CopperOre": 5} if t >= T0 + 60
                                                               else None, mine=[CRATE]))
    rec = j.run_job(io, j.job_of("L2", doc), {"step": "I5", "interruptions": doc["interruptions"], "confirm_s": 20})
    assert io.restarts == 1
    assert rec["interruption"]["took"] and rec["interruption"]["t_put"] == 20.0  # polled every 0.5 s while awaited
    assert rec["resume"]["resumed"] and rec["resume"]["call"]["tool"] == "gather" and not rec["resume"]["new_line"]
    assert rec["ended"] == "resumed" and rec["resumed"] and not rec["done"] and not rec["job_done"] and rec["verdict"]["pass"]
    assert rec["item"] == "job: L2 / I5" and rec["misses"]["by_phase"] == {"before": 0, "during": 0, "after": 0}


def test_run_job_i5_without_a_resumption_fails(doc):
    script = model(T0 + 1) + [call(T0 + 3, "g1", "gather"), result(T0 + 20, "g1", "gather", data={"detail": "Got 3."})]
    io = FakeIO(script=script, states=lambda t: state(mine=[CRATE]))
    rec = j.run_job(io, j.job_of("L2", doc), {"step": "I5", "interruptions": doc["interruptions"]})
    assert rec["ended"] in ("quiet", "no resumption") and not rec["resume"].get("resumed")
    assert not rec["verdict"]["pass"] and not rec["resumed"] and not rec["done"]


def test_run_job_first_step_probe_for_a_mid_job_checkpoint(doc):
    io = FakeIO(script=l2_script(store_at=400.0), states=lambda t: state(mine=[CRATE]))
    rec = j.run_job(io, j.job_of("L2", doc), {"until": "first_step"})
    assert rec["ended"] == "first step" and rec["until"] == "first_step" and not rec["job_done"]
    assert j.rates([rec], set()) == {}  # a probe is not a trial


# ------------------------------------------------------------------ the CLI refuses before touching anything
def test_cli_refuses_without_confirm(capsys):
    assert j.main(["trial", "--job", "L2", "-k", "1"]) == 2
    assert j.main(["interrupt", "--step", "I3", "--job", "L2", "-k", "1"]) == 2
    assert "pass --confirm" in capsys.readouterr().out


def test_start_ref_prefers_a_mid_job_checkpoint_only_when_it_exists(doc, tmp_path, monkeypatch):
    from tools import quest_clone
    monkeypatch.setattr(quest_clone, "CHECKPOINT_DIR", tmp_path)
    job = j.job_of("L2", doc)
    assert j.start_ref(job, "I3", None)[0] == "ClaudeDev"
    (tmp_path / "job_l2_mid.json").write_text("{}", encoding="utf-8")
    assert j.start_ref(job, "I3", None)[0] == "job_l2_mid"
    assert j.start_ref(job, None, None)[0] == "ClaudeDev"
    assert j.start_ref(job, "I3", "rm_part2") == ("rm_part2", "--from")


def test_a_stop_file_ends_the_trial_stopped(doc, tmp_path):
    stop = tmp_path / "job_run.stop"
    stop.write_text("", encoding="utf-8")
    io = FakeIO(script=l2_script(store_at=400.0), states=lambda t: state(mine=[CRATE]))
    rec = j.run_job(io, j.job_of("L2", doc), {"interruptions": doc["interruptions"], "stop_file": str(stop)})
    assert rec["ended"] == "stopped" and not rec["job_done"]


def test_gear_target_judges_on_the_games_own_power_level():
    # a broken tunic and leggings under a cowl: the catalog's levels say PL 1, the game says 0 (broken counts 0)
    cat = {"cowl": {"power_level": 2}, "tunic": {"power_level": 1}, "legs": {"power_level": 1}}
    start = {"gear_target": {"pl": 1}}
    end = {"worn": {"Head": "cowl", "Body": "tunic", "Legs": "legs"}, "power_level": 0.0}
    ok, why = j.p_gear_target({}, start, end, cat)
    assert not ok and "armour PL 0 of 1" in why
    end["power_level"] = None
    assert j.p_gear_target({}, start, end, cat)[0]  # no game figure: the catalog's, as before
    assert j.snapshot({"power_level": 0.0, "position": [0, 0, 0]})["power_level"] == 0.0


def test_a_starving_start_is_unfit():
    st = {"health": 1.0, "max_health": 100.0, "sustenance": 0.0, "sustenance_max": 100.0, "hydration": 90.0,
          "hydration_max": 100.0}
    why = j.unfit({"ok": True, "data": st})
    assert why.startswith("body unfit: health 1 of 100, food 0 of 100 (") and "water" not in why
    st.update(health=100.0, sustenance=90.0)
    assert j.unfit(st) is None


def fit_save(path, food=90.0, water=90.0, health=100.0):
    """A character save file with only the bars the start check reads (GameProgress.Character)."""
    path.write_text(json.dumps({"GameProgress": {"Character": {
        "Health": {"CurrentValue": health}, "Sustenance": {"SustenanceValue": food},
        "Hydration": {"HydrationValue": water}}}}), encoding="utf-8")
    return path


def test_the_window_refuses_when_the_save_it_forks_is_under_the_bar(tmp_path, monkeypatch, capsys):
    # live 2026-11-17 21:05Z: a vitals rescue on ClaudeDev's live body, then a job window forked his older SAVE and
    # both forks were unfit. A fork copies the save, so the save is checked before any switch.
    from tools import quest_clone
    monkeypatch.setattr(quest_clone, "SAVE_DIR", tmp_path)
    fit_save(tmp_path / "ClaudeDev.json", food=33.0, water=20.0)

    def no_window(*a, **k):
        raise AssertionError("opened the lock window")

    def no_fork(ref, name):
        raise AssertionError("forked")
    monkeypatch.setattr(q, "refuse_dirty", lambda a: False)
    monkeypatch.setattr(q, "clone_window", no_window)
    monkeypatch.setattr(j, "load_jobs", lambda: {"jobs": {"L9": {"start": "ClaudeDev"}}})
    monkeypatch.setattr(j, "start_ref", lambda job, step, override, spec=None: ("ClaudeDev", "the job's start"))
    monkeypatch.setattr(quest_clone, "CHECKPOINT_DIR", tmp_path / "no_checkpoints")
    monkeypatch.setattr(quest_clone, "place_of", lambda ref: None)
    monkeypatch.setattr(quest_clone, "fork", no_fork)
    assert j.main(["trial", "--confirm", "--job", "L9", "-k", "2"]) == 3
    out = capsys.readouterr().out
    assert "ClaudeDev's save unfit: food 33 of 100, water 20 of 100" in out and "-m tools.vitals_rescue" in out


def test_a_save_fit_but_under_the_start_bar_refuses_the_window(tmp_path, monkeypatch, capsys):
    # window n2_i4 2026-11-19: ClaudeDev's save read food 67, water 56 (fit at 40); every fork met the line at water
    # 42-46 % and spent I4's 120 s on drinking. A trial starts at START_PCT (70), and says why and what to run.
    from tools import quest_clone
    monkeypatch.setattr(quest_clone, "SAVE_DIR", tmp_path)
    fit_save(tmp_path / "ClaudeDev.json", food=66.9, water=56.2)

    def no_window(*a, **k):
        raise AssertionError("opened the lock window")
    monkeypatch.setattr(q, "refuse_dirty", lambda a: False)
    monkeypatch.setattr(q, "clone_window", no_window)
    monkeypatch.setattr(j, "load_jobs", lambda: {"jobs": {"L9": {"start": "ClaudeDev"}}})
    monkeypatch.setattr(j, "start_ref", lambda job, step, override, spec=None: ("ClaudeDev", "the job's start"))
    monkeypatch.setattr(quest_clone, "CHECKPOINT_DIR", tmp_path / "no_checkpoints")
    monkeypatch.setattr(quest_clone, "place_of", lambda ref: None)
    assert j.main(["trial", "--confirm", "--job", "L9", "-k", "2"]) == 3
    out = capsys.readouterr().out
    assert "ClaudeDev's save unfit: food 67 of 100, water 56 of 100 (under 70 % is unfit" in out
    assert "-m tools.vitals_rescue" in out and "drink line" in out
    assert j.START_PCT == 70.0 > j.FIT_PCT


def test_start_unfit_reads_the_save_then_the_joined_body(tmp_path):
    save = fit_save(tmp_path / "cp.json", food=80.0, water=75.0)
    assert j.start_unfit(save) is None
    body = {"health": 100.0, "max_health": 100.0, "sustenance": 80.0, "sustenance_max": 100.0, "hydration": 56.0,
            "hydration_max": 100.0}
    why = j.start_unfit(save, {"ok": True, "data": body})
    assert why.startswith("body unfit: water 56 of 100 (under 70 % is unfit)") and "drink line" in why
    body["hydration"] = 71.0
    assert j.start_unfit(save, {"ok": True, "data": body}) is None


def test_the_record_carries_his_bars():
    st = {"position": [0, 0, 0], "health": 90.0, "max_health": 100.0,
          "survival": {"sustenance": [60.0, 80.0], "hydration": [44.0, 100.0]}}
    assert j.snapshot(st)["vitals"] == {"food": 75.0, "water": 44.0, "health": 90.0}
    assert "vitals" not in j.snapshot({"position": [0, 0, 0]})


def test_the_window_skips_a_fork_that_starts_starved(tmp_path, monkeypatch):
    # the per-fork check is chat_ladder's body_unfit, read through the window's debug client before the walk to the start
    import contextlib
    import time
    from tools import quest_clone
    starved = {"health": 1.0, "max_health": 100.0, "sustenance": 0.0, "sustenance_max": 100.0, "hydration": 0.0,
               "hydration_max": 100.0}
    forked, out = [], {}

    class Cli:
        def request(self, tool, args, timeout=None):
            assert tool == "get_state"
            return {"ok": True, "data": dict(starved)}

    class Sw:
        def ensure(self, name, create=False, wait_s=0):
            return {"guid": "g", "name": name}

    @contextlib.contextmanager
    def window(wait_s, o, out_file):
        yield Sw(), Cli(), time.time()
        out.update(o)

    def walked(*a):
        raise AssertionError("walked to the job's start")

    monkeypatch.setattr(q, "refuse_dirty", lambda a: False)
    monkeypatch.setattr(q, "clone_window", window)
    monkeypatch.setattr(q, "to_start", walked)
    monkeypatch.setattr(j, "load_jobs", lambda: {"jobs": {"L9": {"start": "cp"}}})
    monkeypatch.setattr(j, "start_ref", lambda job, step, override, spec=None: ("cp", "the job's start"))
    monkeypatch.setattr(j, "STOP_FILE", tmp_path / "none.stop")
    monkeypatch.setattr(quest_clone, "source_of", lambda ref: fit_save(tmp_path / "cp.json"))
    monkeypatch.setattr(quest_clone, "place_of", lambda ref: [0.0, 0.0, 0.0])
    monkeypatch.setattr(quest_clone, "fork", lambda ref, name: forked.append(name))
    assert j.main(["trial", "--confirm", "--job", "L9", "-k", "2"]) == 1
    assert len(forked) == 1  # every fork of this save starts the same: the window stops at the first
    (t,) = out["trials"]
    assert t["skipped"].startswith("body unfit: health 1 of 100, food 0 of 100, water 0 of 100")


# ------------------------------------------------------------------ the grader reads only what the game says
# (docs/research/2026-11-17-job-end-readability.md: each fixture below is a reading from its evidence lines)
def _gs(rows, **kw):
    return {"position": [0.0, 0.0, 0.0], "inventory_items": rows, **kw}


def test_h1_an_equipped_stack_is_counted_once():
    # last get_state of run 20261117-195219-L2: Stone Arrows bag 20 + loadout Ammo 20 read as 40; one Stone Pickaxe in
    # the hotbar + HeldRight + HeldLeft read as 3; the worn Leather Cowl only in the loadout
    rows = [{"item": "ITEM_Ammo_Arrows_Stone", "count": 20, "where": "bag", "slot_type": "InventoryAmmunition"},
            {"item": "ITEM_Ammo_Arrows_Stone", "count": 20, "where": "loadout", "loadout_slot": "Ammo"},
            {"item": "ITEM_Pickaxe_Stone", "count": 1, "where": "hotbar", "slot_type": "QuickAction"},
            {"item": "ITEM_Pickaxe_Stone", "count": 1, "where": "loadout", "loadout_slot": "HeldRight"},
            {"item": "ITEM_Pickaxe_Stone", "count": 1, "where": "loadout", "loadout_slot": "HeldLeft"},
            {"item": "ITEM_Armour_T2_Head_Leather", "count": 1, "where": "loadout", "loadout_slot": "Head"}]
    s = j.snapshot(_gs(rows))
    assert s["carried"] == {"ITEM_Ammo_Arrows_Stone": 20, "ITEM_Pickaxe_Stone": 1, "ITEM_Armour_T2_Head_Leather": 1}
    assert s["worn"]["Ammo"] == "ITEM_Ammo_Arrows_Stone" and s["worn"]["HeldRight"] == "ITEM_Pickaxe_Stone"
    # an ammo slot whose stack the read did not list is still counted (it is the only sight of it)
    assert j.snapshot(_gs(rows[1:2]))["carried"] == {"ITEM_Ammo_Arrows_Stone": 20}


def test_h1_one_craft_of_33_arrows_equipped_is_not_40(doc):
    job = j.job_of("H1", doc)
    start = j.snapshot(_gs([{"item": "ITEM_Resources_Animal_Hide", "count": 1, "where": "bag"}]))
    end = j.snapshot(_gs([{"item": "ITEM_Shortbow_Ash", "count": 1, "where": "hotbar"},
                          {"item": "ITEM_Ammo_Arrows_Stone", "count": 33, "where": "bag", "slot_type": "InventoryAmmunition"},
                          {"item": "ITEM_Ammo_Arrows_Stone", "count": 33, "where": "loadout", "loadout_slot": "Ammo"},
                          {"item": "ITEM_Resources_Animal_Hide", "count": 6, "where": "bag"}]))
    end["crafted"] = {"ITEM_Shortbow_Ash": 1, "ITEM_Ammo_Arrows_Stone": 1}
    ok, why = j.done(job, start, end)
    assert ok is False and "ITEM_Ammo_Arrows_*: +33 of +40" in why


def raw_inventory(hotbar_n, item_n, runes_n=6, empty_slots=164):
    """inventory {raw: true}: the pages and rows as inventory.list gives them; empty_slots is GetNumEmptySlots."""
    hot = [{"item": f"ITEM_H{i}", "count": 1, "slot_type": "QuickAction", "slot": i} for i in range(hotbar_n)]
    bag = [{"item": f"ITEM_B{i}", "count": 1, "slot_type": "InventoryItems", "slot": i} for i in range(item_n)]
    bag += [{"item": f"ITEM_Rune_{i}", "count": 50, "slot_type": "InventoryRunes", "slot": i} for i in range(runes_n)]
    return {"ok": True, "data": {"pages": ["QuickAction:8", "InventoryItems:32", "InventoryRunes:32",
                                           "InventoryAmmunition:32", "InventoryQuestItems:72"],
                                 "hotbar": hot, "bag": bag, "loadout": [], "empty_slots": empty_slots}}


def test_i4_bag_room_is_the_hotbar_and_item_page_not_every_page():
    # live: GetNumEmptySlots read 164 with the item page full, so "left == 0" could never be true
    assert j.bag_room(raw_inventory(8, 32)) == 0
    assert j.bag_room(raw_inventory(8, 30)) == 2 and j.bag_room(raw_inventory(5, 32)) == 3
    assert j.bag_room({"ok": True, "data": {"hotbar": [], "bag": [], "empty_slots": 164}}) is None  # pages unread
    assert j.snapshot(raw_inventory(8, 32))["bag_room"] == 0


def test_i4_unread_room_never_takes():
    io = FakeIO(room=[None, None])
    out = j.apply_interruption(io, "I4", {"filler": "ITEM_FishingNet_CoarseNet", "rounds": 3}, T0)
    assert out["took"] is False and "unread" in out["how"] and io.fixtures == []


def test_l3_dirty_water_and_burnt_food_are_not_provisions():
    # 17 Nov: Dirty Water reads consumable "drink" (236 rows); the game's data gives it Soulscourge 20
    rows = [{"item": "ITEM_Consumable_Water_Dirty", "count": 5, "where": "bag", "consumable": "drink"},
            {"item": "ITEM_Consumable_Farm_Steak_Burnt", "count": 5, "where": "bag", "consumable": "food"},
            {"item": "ITEM_Consumable_Farm_Steak", "count": 5, "where": "hotbar", "consumable": "food"}]
    s = j.snapshot(_gs(rows))
    assert s["consumables"] == {"food": 5, "drink": 0}
    ok, why = j.p_consumables_carried({"food": 5, "drink": 5}, {}, s)
    assert not ok and "drink: 0 of 5" in why and "Water_Dirty" in why and "soulscourge 20" in why
    rows.append({"item": "ITEM_Consumable_Water_Clean", "count": 5, "where": "bag", "consumable": "drink"})
    assert j.p_consumables_carried({"food": 5, "drink": 5}, {}, j.snapshot(_gs(rows)))[0]


CAMPFIRE = "BP_Station_Campfire_C_2147473018"


def test_h2_his_campfire_is_not_his_chest(doc):
    # a station he built is "mine" in get_state; meals left in it and read by a take there were "in his chest"
    job = j.job_of("H2", doc)
    cooked = sorted(x for x in j.made_at(["Campfire", "Grill"], "Item.Food") if "Burnt" not in x)[0]
    rows = [result(5, "t", "take", data={"container": CAMPFIRE, "contents": ["10 Clean Water"]})]
    st = _gs([], structures=[{"id": CAMPFIRE, "mine": True, "piece": "BUILDPIECE_Campfire"}],
             interactables=[{"id": CAMPFIRE, "kind": "processing_station", "class": "BP_Station_Campfire_C"}])
    start, end = j.snapshot(st), j.snapshot(st)
    end.update(j.evidence(rows))
    end["chests"][CAMPFIRE]["items"] = {cooked: 10, "ITEM_Consumable_Water_Clean": 10}
    end["chest_end"] = {CAMPFIRE: {"read": True, "items": {cooked: 10, "ITEM_Consumable_Water_Clean": 10}}}
    ok, why = j.done(job, start, end)
    assert ok is False and "storage" in why
    assert j.is_storage(CAMPFIRE) is False and j.is_storage("BP_Crafting_StartingBench_C_1") is False
    assert j.is_storage(CRATE, {CRATE: "storage"}) is True and j.is_storage(CRATE) is None
    assert j.is_storage(CRATE, {}, {"read": True, "items": {}, "class": "BP_BaseBuilding_Crate_C"}) is True
    assert j.chest_candidates(start, end) == []


def test_l2_without_an_end_read_is_unread_never_a_pass(doc):
    job = j.job_of("L2", doc)
    rows = [result(5, "s", "store", data={"container": CRATE, "item": "ITEM_Resources_CopperOre", "inside_now": 30,
                                          "contents": ["30 Copper Ore"]})]
    start, end = snap(mine=[CRATE]), snap()
    end.update(j.evidence(rows))
    ok, why = j.done(job, start, end)  # his last open of it said 30: memory
    assert ok is None and "no end read" in why
    end["chest_end"] = {CRATE: {"read": False, "why": "unknown_target"}}
    ok, why = j.done(job, start, end)
    assert ok is None and "unknown_target" in why
    end["chest_end"] = {CRATE: end_read(0)}  # an end read below his last open, nothing taken out since: doubted
    ok, why = j.done(job, start, end)
    assert ok is None and "took nothing out since" in why
    end["chests"][CRATE]["tool"] = "take"  # he took them out himself: the end read stands
    assert j.done(job, start, end)[0] is False


def test_read_container_of_an_inspect_reply():
    r = j.read_container({"ok": True, "data": {"id": CRATE, "kind": "storage", "contents": [
        {"item": "ITEM_Resources_CopperOre", "name": "Copper Ore", "count": 30}]}})
    assert r == {"kind": "storage", "class": None, "read": True, "items": {"ITEM_Resources_CopperOre": 30}}
    assert j.read_container({"ok": True, "data": {"id": CRATE}})["read"] is False  # no inventory read: not empty
    assert j.read_container({"ok": False, "reason": "unknown_target"}) == {"kind": None, "class": None,
                                                                           "read": False, "why": "unknown_target"}


def test_run_job_l2_reads_his_crate_at_the_end_even_when_get_state_drops_it(doc):
    # run 20261117-195219-L2: the crate was in neither the start nor the end read (15 rows within 30 m); it was in
    # the reads while he stood at it
    near = lambda t: state(mine=[CRATE]) if T0 + 15 <= t <= T0 + 40 else state()  # noqa: E731
    io = FakeIO(script=l2_script(), states=near,
                chests={CRATE: [{"item": "ITEM_Resources_CopperOre", "name": "Copper Ore", "count": 30}]})
    rec = j.run_job(io, j.job_of("L2", doc), {"interruptions": doc["interruptions"]})
    assert rec["job_done"] and rec["state_end"]["chest_end"][CRATE]["items"] == {"ITEM_Resources_CopperOre": 30}
    assert CRATE in io.inspected and "end read" in rec["done_why"]


def test_run_job_l2_with_his_crate_unreadable_is_unread_and_not_counted(doc):
    io = FakeIO(script=l2_script(), states=lambda t: state(mine=[CRATE]), chests={})
    rec = j.run_job(io, j.job_of("L2", doc), {"interruptions": doc["interruptions"], "deadline": 200})
    assert not rec["job_done"] and rec["unread"] and "unknown_target" in rec["unread"]
    v = j.verdict(rec)
    assert not v["pass"] and v["bars"]["read"] is False
    assert j.not_counted(rec).startswith("end state unread") and j.scored([rec], set()) == []


def test_a_failed_get_state_is_unread_never_an_empty_character(doc):
    # 78 of 4 760 replies: ok false, "no local player controller"
    bad = {"ok": False, "reason": "no local player controller", "data": {}}
    s = j.snapshot(bad)
    assert s["unread"] == "no local player controller" and s["carried"] == {}
    assert j.snapshot({"unread": "get_state failed"})["unread"]
    job = j.job_of("H1", doc)
    end = j.snapshot(_gs([{"item": "ITEM_Shortbow_Ash", "count": 1, "where": "hotbar"},
                          {"item": "ITEM_Ammo_Arrows_Stone", "count": 66, "where": "bag"},
                          {"item": "ITEM_Resources_Animal_Hide", "count": 6, "where": "bag"}]))
    end["crafted"] = {"ITEM_Shortbow_Ash": 1, "ITEM_Ammo_Arrows_Stone": 2}
    ok, why = j.done(job, s, end)
    assert ok is None and "start get_state" in why


def test_l1_the_cowl_he_wears_is_no_head_start(doc):
    # the cowl is read once (the loadout); since 2026-11-18 the end read tells it from a new one by its instance
    # (worn_made_in_run), so it no longer leaves every L1 trial from ClaudeDev not counted
    job = j.job_of("L1", doc)
    start = j.snapshot(_gs([{"item": "ITEM_Armour_T2_Head_Leather", "count": 1, "where": "loadout", "loadout_slot": "Head"}]))
    assert start["carried"] == {"ITEM_Armour_T2_Head_Leather": 1}
    assert j.not_counted(job, start) is None


def test_a_door_he_built_is_not_left_unread_as_a_chest():
    """Live 2026-11-17 (runs 20261117-211950-L2, -212448-L2): his T1 door was read ok with no inventory on it, counted
    as a storage container "not known", and both runs ended "end state unread" (not counted) with 0 of 30 copper.
    A piece the body found that holds no inventory is not storage."""
    door = j.read_container({"ok": True, "data": {"class": "BP_T1_Door_C"}})
    assert door["read"] is False and door.get("no_inventory") is True
    assert j.is_storage("BP_T1_Door_C_2147472981", {}, door) is False
    assert j.is_storage("BP_Storage_Crate_C_1", {}, j.read_container({"ok": False, "reason": "not_found"})) is None


# ------------------------------------------------------------------ 2026-11-18 run 20261118-000146-L2
# He died twice and respawned at a bed camp of his ~100 m west of his base. A sample there listed his small chest at
# [85.98, 1851.65] and his door at [94.71, 1853.14] (that door under two names: the game re-creates a door that left
# relevancy). The end read was made where he ended, at his base: the client's inspect reaches 80 m
# (client_bridge LOOK_MAX_RADIUS_M): "it's 89 m away, beyond 80 m", "not perceived within 80 m". He never carried a
# copper ore, and the run was left out.
CHEST = "BP_BaseBuilding_Chest_Small_C_2147473017"
DOOR = "BP_T1_Door_C_2147458506"


def at_camp(t):
    return T0 + 30 <= t <= T0 + 60


def far_state(t):
    """At his base, except 30-60 s at the bed camp 100 m west, where get_state lists the chest and the door."""
    if at_camp(t):
        st = state(pos=(90.0, 1852.0, -31.0))
        st["structures"] = [{"id": CHEST, "mine": True, "position": [85.98, 1851.65, -31.7]},
                            {"id": DOOR, "mine": True, "position": [94.71, 1853.14, -30.3]}]
        return st
    return state(pos=(153.59, 1909.79, -30.9))


def far_chests(near_contents):
    """What the client's inspect answers: the camp's pieces only from within 80 m of them."""
    return lambda t, cid: near_contents.get(cid) if at_camp(t) else None


class DoorIO(FakeIO):
    def inspect(self, cid):
        if cid == DOOR and at_camp(self.t):
            self.inspected.append(cid)
            return {"ok": True, "data": {"id": cid, "class": "BP_T1_Door_C", "kind": "actor"}}
        return super().inspect(cid)


def nothing_script():
    return model(T0 + 1) + [call(T0 + 3, "e1", "explore", {"about": "copper ore"}),
                            result(T0 + 90, "e1", "explore", ok=False, reason="nothing_in_range",
                                   data={"detail": "saw nothing matching 'copper ore'"})]


def test_snapshot_keeps_where_his_containers_stood():
    s = j.snapshot(far_state(T0 + 40))
    assert s["container_where"] == {CHEST: [85.98, 1851.65, -31.7], DOOR: [94.71, 1853.14, -30.3]}


def test_read_container_keeps_the_clients_detail():
    r = j.read_container({"ok": False, "reason": "unknown_target",
                          "data": {"detail": "it's 89 m away, beyond 80 m", "distance": 89}})
    assert r["read"] is False and r["why"] == "unknown_target: it's 89 m away, beyond 80 m"


def test_held_in_run_from_bag_reads_and_pickups_only():
    rows = [{"ts": 1, "kind": "bridge_recv", "msg": {"ok": True, "data": state({"ITEM_Resources_Stone": 5})}},
            {"ts": 2, "kind": "bridge_recv", "msg": {"ok": True, "data": state({"ITEM_Resources_Stone": 9})}},
            {"ts": 3, "kind": "bridge_recv", "msg": {"ok": False, "data": {"bag": 3}}},
            result(4, "g", "gather", data={"item": "ITEM_Resources_Wood_Ash", "gathered": 5}),
            result(5, "i", "interact", data={"gained": {"ITEM_Sword_Bronze": 1}}),
            result(6, "c", "craft", data={"collected": [{"item": "ITEM_Consumable_Water_Clean", "count": 2}]}),
            result(7, "x", "consume", data={"item": "ITEM_Consumable_Meat_Rat_Roast", "count_left": 3}),
            result(8, "y", "gather", ok=False, data={"item": "ITEM_Resources_CopperOre"}),
            {"ts": 9, "kind": "say", "text": "got 30 copper ore"}]  # his words are never a read
    h = j.held_in_run(rows, [snap({"ITEM_Resources_Stone": 2}), j.snapshot({"unread": "x"})])
    assert h["reads"] == 3 and h["peak"]["ITEM_Resources_Stone"] == 9
    assert h["gained"] == {"ITEM_Resources_Wood_Ash": 5, "ITEM_Sword_Bronze": 1, "ITEM_Consumable_Water_Clean": 2}
    assert "ITEM_Resources_CopperOre" not in h["peak"] and "ITEM_Resources_CopperOre" not in h["gained"]


def test_run_job_reads_a_chest_of_his_while_he_is_near_it(doc):
    """000146's cause: the chest was listed only at the bed camp and read only at the end, 89 m off. It is now read
    the first time a sample lists it (he is within 30 m then), and the end read's failure says how far it was."""
    io = DoorIO(script=nothing_script(), states=far_state, chests=far_chests({CHEST: []}))
    rec = j.run_job(io, j.job_of("L2", doc), {"interruptions": doc["interruptions"], "deadline": 200})
    first = rec["state_end"]["chest_first"]
    assert first[CHEST]["read"] is True and first[CHEST]["items"] == {} and 30 <= first[CHEST]["t"] <= 60
    assert first[DOOR].get("no_inventory") is True
    end = rec["state_end"]["chest_end"]
    assert end[CHEST]["read"] is False and end[CHEST]["seen_m"] == 89.2


def test_l2_fail_certain_when_he_never_carried_any_and_the_unread_held_none(doc):
    io = DoorIO(script=nothing_script(), states=far_state, chests=far_chests({CHEST: []}))
    rec = j.run_job(io, j.job_of("L2", doc), {"interruptions": doc["interruptions"], "deadline": 200})
    assert rec["job_done"] is False and not rec.get("unread") and "fail_certain: never carried any" in rec["done_why"]
    assert j.not_counted(rec) is None and rec["verdict"]["bars"]["read"] is True and not rec["verdict"]["pass"]


def test_l2_stays_unread_when_an_unread_chest_was_never_read_or_held_enough(doc):
    job = j.job_of("L2", doc)
    io = DoorIO(script=nothing_script(), states=far_state, chests=lambda t, cid: None)  # never readable
    rec = j.run_job(io, job, {"interruptions": doc["interruptions"], "deadline": 200})
    assert rec["unread"] and "never carried any" in rec["unread"] and "seen 89.2 m from where he ended" in rec["unread"]
    copper = [{"item": "ITEM_Resources_CopperOre", "name": "Copper Ore", "count": 30}]
    io = DoorIO(script=nothing_script(), states=far_state, chests=far_chests({CHEST: copper}))
    rec = j.run_job(io, job, {"interruptions": doc["interruptions"], "deadline": 200})
    assert rec["unread"] and "fail_certain" not in rec["done_why"]  # it held 30 when read: it may still


def test_l2_never_fail_certain_once_he_held_the_item(doc):
    job = j.job_of("L2", doc)
    start = snap(mine=[CHEST])
    end = snap()
    end.update(j.evidence([]))
    end["chest_end"] = {CHEST: {"read": False, "why": "unknown_target: not perceived within 80 m"}}
    end["chest_first"] = {CHEST: {"read": True, "items": {}, "t": 0.0}}
    end["held_in_run"] = {"reads": 40, "peak": {}, "gained": {}}
    assert j.done(job, start, end)[0] is False
    for held in ({"reads": 40, "peak": {"ITEM_Resources_CopperOre": 3}, "gained": {}},
                 {"reads": 40, "peak": {}, "gained": {"ITEM_Resources_CopperOre": 1}}, {}):
        end["held_in_run"] = held
        assert j.done(job, start, end)[0] is None


def test_a_gained_want_he_never_held_is_fail_certain_even_unread():
    # "put in during the run": what an unread container held before does not matter if he never held any
    want = [{"item": "ITEM_Resources_Stone", "count": 10, "gained": True}]
    start, end = snap(mine=[CHEST]), snap()
    end.update(j.evidence([]))
    end["chest_end"] = {CHEST: {"read": False, "why": "unknown_target: not perceived within 80 m"}}
    end["chest_first"] = {}
    end["held_in_run"] = {"reads": 12, "peak": {}, "gained": {}}
    ok, why = j.p_in_own_chest(want, start, end)
    assert ok is False and "fail_certain" in why
    end["held_in_run"] = {"reads": 12, "peak": {"ITEM_Resources_Stone": 2}, "gained": {}}
    assert j.p_in_own_chest(want, start, end)[0] is None


def test_a_trial_its_spend_cap_cut_off_ends_budget_and_does_not_count(doc):
    """8 of 14 V1 'quiet' ends of 19 Nov were the trial's own --usd cap (study quiet_1119): budget_blocked, then
    template lines and a blind plan. It ends "budget", not counted; the same run without the row stays quiet."""
    script = model(T0 + 1) + [call(T0 + 3, "g1", "gather"), result(T0 + 20, "g1", "gather", data={"detail": "Got 3."}),
                              {"ts": T0 + 25, "kind": "budget_blocked", "call": "controller", "why": "run cap"}]
    io = FakeIO(script=sorted(script, key=lambda r: r["ts"]), states=lambda t: state(mine=[CRATE]))
    rec = j.run_job(io, j.job_of("L2", doc), {"interruptions": doc["interruptions"]})
    assert rec["ended"] == "budget" and "spend cap" in rec["not_counted"] and not rec["done"]
    io2 = FakeIO(script=model(T0 + 1) + [call(T0 + 3, "g1", "gather"),
                                         result(T0 + 20, "g1", "gather", data={"detail": "Got 3."})],
                 states=lambda t: state(mine=[CRATE]))
    rec2 = j.run_job(io2, j.job_of("L2", doc), {"interruptions": doc["interruptions"]})
    assert rec2["ended"] == "quiet" and not rec2.get("not_counted")


def test_a_capped_trial_that_had_already_failed_the_miss_bar_counts(doc):
    """confirm_1119s trial 2: 29 misses, then the 1.5 dollar cap. He had failed the miss bar on his own: counted."""
    bad = []
    for i in range(3):
        t = T0 + 3 + 6 * i
        bad += [call(t, f"g{i}", "gather"), result(t + 2, f"g{i}", "gather", ok=False, reason="nothing_in_range")]
    script = model(T0 + 1) + bad + [{"ts": T0 + 40, "kind": "budget_blocked", "call": "controller", "why": "run cap"}]
    io = FakeIO(script=sorted(script, key=lambda r: r["ts"]), states=lambda t: state(mine=[CRATE]))
    rec = j.run_job(io, j.job_of("L2", doc), {"interruptions": doc["interruptions"]})
    assert rec["ended"] == "budget" and rec["misses"]["n"] > 1 and not rec.get("not_counted")


def test_l3_names_its_vault_and_the_verdict_says_the_target_and_its_rows(doc):
    assert j.job_of("L3", doc)["end"]["gear_target"]["vault"] == "Crasorak Kara"
    cat = {"H": {"power_level": 2}, "B": {"power_level": 2}, "L": {"power_level": 2},
           "S": {"power_level": 3, "damage_types": ["DamageType.Physical.Slash"]}}
    start = snap()
    start["gear_target"] = {"pl": 2, "kit": {"right_hand": 3}, "vault": "Crasorak Kara", "reachable_pl": 2,
                            "damage_pref": ["Stab", "Fire"], "rows": ["vaults/Crasorak Kara/enemies: Giant Rat x9 PL 2 (wiki 3515)"]}
    end = snap(worn={"Head": "H", "Body": "B", "Legs": "L", "HeldRight": "S"})
    ok, why = j.p_gear_target({}, start, end, cat)
    assert ok and "target for Crasorak Kara: armour PL 2" in why and "wiki 3515" in why
    assert "weak to Stab, Fire, his weapon deals Slash (told, not judged)" in why
    start["gear_target"]["reachable_pl"] = 1
    end["worn"]["Legs"] = None
    ok, why = j.p_gear_target({}, start, end, cat)
    assert not ok and "armour PL 1 of 2" in why and "reaches only PL 1" in why


def test_run_job_hands_l3s_vault_to_the_gear_target(doc, tmp_path):
    stop = tmp_path / "job_run.stop"
    stop.write_text("", encoding="utf-8")
    io = FakeIO()
    rec = j.run_job(io, j.job_of("L3", doc), {"interruptions": doc["interruptions"], "stop_file": str(stop)})
    assert io.gear_vault == "Crasorak Kara" and rec["state_start"]["gear_target"]["pl"] == 3


# ------------------------------------------------------------------ world_needs: the world before the ask
HOME = [173.2, 1915.2, -30.0]


def flax_row(i, at, available=True):
    return {"item": "ITEM_Resources_Flax", "kind": "gatherable", "class": "BP_Spawner_Flax_C", "name": "Flax",
            "available": available, "id": f"BP_Spawner_Flax_C_UAID_{i}", "position": list(at), "distance": 1.0}


FLAX_NEED = {"resource": "flax", "match": "Spawner_Flax", "at_least": 22, "within_m": 350, "of": "home"}


def flax_job(doc):
    """L1 with a flax need put in (data/jobs.json has none since 19 Nov: thread also spins from coarse fur); the
    world_check machinery is the same for any need."""
    return {**j.job_of("L1", doc), "world_needs": [dict(FLAX_NEED)]}


def flax_world(standing, picked=0, far=0, stones=5):
    """A census reply: `standing` flax within 350 m of HOME (300 m E of it), `picked` there reading available=false,
    `far` standing ones 400 m off, and some stones."""
    rows = [flax_row(i, (HOME[0] + 300, HOME[1] + (i % 7), -40)) for i in range(standing)]
    rows += [flax_row(100 + i, (HOME[0] + 290, HOME[1], -40), available=False) for i in range(picked)]
    rows += [flax_row(200 + i, (HOME[0] + 400, HOME[1], -40)) for i in range(far)]
    rows += [{"class": "BP_Spawner_Stone_C", "name": "Stone", "available": True, "position": [HOME[0] + 5, HOME[1], -30],
              "distance": 30.0} for _ in range(stones)]
    return {"ok": True, "data": {"resources": rows, "totals": {"resources": len(rows)}}}


class CensusIO(FakeIO):
    def __init__(self, reply, **kw):
        super().__init__(states=lambda t: {**state(pos=(150.0, 1900.0, -30.0)),
                                           "my_bases": [{"centre": [0.0, 0.0, 0.0], "pieces": 2},
                                                        {"centre": HOME, "pieces": 12, "covered": True}]}, **kw)
        self.reply, self.census_args, self.brain_started = reply, [], False

    def census(self, args):
        self.census_args.append(args)
        return self.reply

    def start_brain(self):
        self.brain_started = True
        return True


def test_world_short_never_sends_the_ask_and_is_not_counted(doc):
    io = CensusIO(flax_world(14, picked=3, far=4))
    rec = j.run_job(io, flax_job(doc), {"interruptions": doc["interruptions"]})
    assert io.sent == [] and not io.brain_started
    assert rec["ended"] == "world short" and rec["lines"] == []
    assert rec["not_counted"].startswith("world short: flax 14 of 22 within 350 m of home (3 picked)")
    assert "a fault of the run, not his" in rec["not_counted"] and j.not_counted(rec) == rec["not_counted"]
    need = rec["world"]["needs"][0]
    assert (need["standing"], need["picked"], need["at_least"], need["centre"]) == (14, 3, 22, HOME[:2])
    assert need["centre_from"].startswith("his base of 12 pieces")
    a = io.census_args[0]  # from him (23 m off home) far enough to reach 350 m beyond home; resources only
    assert a["radius_m"] >= 350 + 23 and a["kinds"] == {"resources": True} and a["max"] == j.WORLD_CENSUS_MAX
    assert rec["verdict"]["pass"] is False and j.verdict(rec)["bars"]["counted"] is False
    assert j.scored([rec], set()) == [] and j.blind_mark(rec, [rec], set(), []) == {}


def test_world_unread_refuses_too(doc):
    cut = flax_world(14)
    cut["data"]["totals"]["resources"] = 5000  # the census's cap cut rows: 14 is a floor, not a count
    io = CensusIO(cut)
    rec = j.run_job(io, flax_job(doc), {"interruptions": doc["interruptions"]})
    assert io.sent == [] and rec["not_counted"].startswith("world unread: flax within 350 m of home: the census listed")
    io = CensusIO({"ok": False, "reason": "paused"})
    rec = j.run_job(io, flax_job(doc), {"interruptions": doc["interruptions"]})
    assert io.sent == [] and "census failed: paused" in rec["not_counted"]


def test_world_enough_runs_the_trial(doc, tmp_path):
    stop = tmp_path / "job_run.stop"
    stop.write_text("", encoding="utf-8")
    io = CensusIO(flax_world(22, picked=5, far=10))
    rec = j.run_job(io, flax_job(doc), {"interruptions": doc["interruptions"], "stop_file": str(stop)})
    assert io.brain_started and io.sent == [doc["jobs"]["L1"]["line"]] and rec["ended"] == "stopped"
    assert rec["world"]["ok"] and rec["world"]["needs"][0]["standing"] == 22 and not rec.get("not_counted")


def test_a_job_without_world_needs_is_unchanged(doc):
    assert not doc["jobs"]["L2"].get("world_needs")
    io = FakeIO(script=l2_script(), states=lambda t: state(mine=[CRATE]),
                chests={CRATE: [{"item": "ITEM_Resources_CopperOre", "name": "Copper Ore", "count": 30}]})
    assert not hasattr(io, "census")  # it would raise had the check run
    rec = j.run_job(io, j.job_of("L2", doc), {"interruptions": doc["interruptions"]})
    assert rec["ended"] == "job done" and "world" not in rec and io.sent == [doc["jobs"]["L2"]["line"]]


def test_world_needs_hold_for_a_step_only_when_the_need_says_so(doc):
    job = flax_job(doc)
    assert j.world_needs_for(job) and not j.world_needs_for(job, "I1")  # a mid-job checkpoint: as a head start
    named = {**job, "world_needs": [{**job["world_needs"][0], "steps": ["I4"]}]}
    assert j.world_needs_for(named, "I4") and not j.world_needs_for(named, "I1")
    io = CensusIO(flax_world(3))
    rec = j.run_job(io, named, {"step": "I4", "interruptions": doc["interruptions"]})
    assert io.sent == [] and rec["kind"] == "interrupt" and rec["not_counted"].startswith("world short: flax 3 of 22")
    assert j.verdict(rec)["pass"] is False


def test_deadline_cli_wins_over_the_jobs_own(doc):
    assert j.deadline_of(doc["jobs"]["L1"]) == 2700.0
    assert j.deadline_of(doc["jobs"]["L1"], 900.0) == 900.0
    assert j.deadline_of(doc["jobs"]["L2"]) == j.DEADLINE_S == 1800.0


def test_world_check_counts_foliage_and_lists_every_row(doc):
    """Live probe 19 Nov 13:55Z: wild flax is foliage; with foliage off the census listed none (every L1 trial would
    have been refused as world short), and with foliage on 1057 resources stood within 450 m of home, over the old
    1000-row cap. The check asks for foliage and a cap above that."""
    io = CensusIO(flax_world(22))
    j.run_job(io, flax_job(doc), {"interruptions": doc["interruptions"]})
    a = io.census_args[0]
    assert a["foliage"] is True and a["max"] >= 1500


# ------------------------------------------------------------------ I4 inside a long job (2026-11-20)
BONE_PICK, STONE_PICK = "ITEM_Pickaxe_Bone", "ITEM_Pickaxe_Stone"
V1_LABEL = "a pickaxe of tier 2 or better"


def _inv(item, where="bag", guid=None, count=1):
    r = {"item": item, "count": count, "where": where, "durability": 1000, "max_durability": 1000}
    if guid:
        r["guid"] = guid
    return r


def _v1(doc):
    return j.rung_job(j.job_of("L2", doc), "V1")


def test_i4_goes_into_l2_v1_l3_l1_and_l2_by_their_own_end(doc):
    spec = doc["interruptions"]["I4"]
    assert j.i4_mode(_v1(doc), spec)[0] == "job_end"
    for jid in ("L1", "L2", "L3"):
        assert j.i4_mode(j.job_of(jid, doc), spec)[0] == "job_end", jid
    assert j.i4_mode(j.job_of("N2", doc), spec)[0] == "vehicle"  # N2 as before: unheld_wants, no end bar


def test_i4_refused_where_it_cannot_apply_with_the_reason(doc):
    spec = doc["interruptions"]["I4"]
    mode, why = j.i4_mode(j.job_of("N1", doc), spec)
    assert mode is None and "vehicle is N2" in why and "stack" in why  # every unit merges into a stack he holds
    for jid in ("H1", "K"):
        mode, why = j.i4_mode(j.job_of(jid, doc), spec)
        assert mode is None and "long_jobs" in why, jid
    mode, why = j.i4_mode(j.rung_job(j.job_of("L2", doc), "V2"), spec)
    assert mode is None and "L2 / V2" in why and "venture_gear" in why and "new slot" in why


def test_end_owed_is_the_v1_pickaxe_until_he_holds_one_he_made(doc):
    v1 = _v1(doc)
    start = j.snapshot({"position": [0, 0, 0], "inventory_items": [_inv(STONE_PICK, "hotbar", "1" * 32)]})
    assert j.end_owed(v1, start, None) is None  # no read yet: the trigger time alone
    assert j.end_owed(v1, start, start) == [V1_LABEL]
    made = j.snapshot({"position": [0, 0, 0], "inventory_items": [_inv(STONE_PICK, "hotbar", "1" * 32),
                                                                   _inv(BONE_PICK, "hotbar", "3" * 32)]})
    made["crafted"] = {BONE_PICK: 1}
    assert j.end_owed(v1, start, made) == []
    # L2 itself: the copper he carries none of
    assert j.end_owed(j.job_of("L2", doc), start, start) == ["ITEM_Resources_CopperOre"]


def v1_script(finish=True):
    """L2 / V1 from ClaudeDev: bones 3-25 s; the bag filled at the trigger (at:30, no call open); his craft 35-37 s
    meets it (inventory_full: the bite); a store 40-44 s frees a slot; the pickaxe craft 50-60 s (ok when finish)."""
    rows = model(T0 + 1) + [call(T0 + 3, "g1", "gather", {"resource": "bones", "count": 4}),
                            result(T0 + 25, "g1", "gather", data={"detail": "Got 4 bones."}),
                            call(T0 + 35, "c1", "craft", {"item": "Bone Pickaxe"}),
                            result(T0 + 37, "c1", "craft", ok=False, reason="inventory_full",
                                   data={"detail": "My bag is full, so I couldn't make the Bone Pickaxe."}),
                            call(T0 + 40, "s1", "store", {"item": "Coarse Net", "container": CRATE}),
                            result(T0 + 44, "s1", "store", data={"detail": "Stored 1 Coarse Net."}),
                            call(T0 + 50, "c2", "craft", {"item": "Bone Pickaxe"}),
                            (result(T0 + 60, "c2", "craft", data={"item": BONE_PICK, "crafts": 1}) if finish else
                             result(T0 + 60, "c2", "craft", ok=False, reason="not_enough_resources"))]
    return sorted(rows, key=lambda r: r["ts"])


def v1_state(finish=True):
    def f(t):
        rows = [_inv(STONE_PICK, "hotbar", "1" * 32)]
        if finish and t >= T0 + 60:
            rows.append(_inv(BONE_PICK, "hotbar", "3" * 32))
        return {"position": [0, 0, 0], "inventory_items": rows,
                "bag": {"used": 32 if T0 + 30 <= t < T0 + 44 else 31, "capacity": 32}}
    return f


def test_i4_on_l2_v1_gate_opens_at_the_trigger_and_the_pass_reads_the_end(doc):
    io = FakeIO(script=v1_script(), states=v1_state(), room=[10, 0])
    rec = j.run_job(io, _v1(doc), {"step": "I4", "interruptions": doc["interruptions"], "trigger": "at:30",
                                   "deadline": 300})
    intr = rec["interruption"]
    assert 30.0 <= intr["t_put"] < 31.0 and intr["full_read"]  # at the trigger, not before
    assert intr["moment"]["gate"] == "job_end" and intr["moment"]["owed"] == [V1_LABEL]
    assert io.fixtures and io.fixtures[0][0] == "grant" and io.fixtures[0][1]["item"] == "ITEM_FishingNet_CoarseNet"
    assert intr["bite"]["t"] == 37.0 and intr["bite"]["how"] == "inventory_full"
    assert 44.0 <= intr["t_clear"] <= 50.0
    assert rec["until"] == "done" and rec["i4_gate"] == "job_end" and rec["ended"] == "job done"
    r = rec["resume"]
    assert r["resumed"] and r["call"]["tool"] == "craft" and r["call"]["t"] == 50.0 and not r["new_line"]
    v = rec["verdict"]
    assert v["bars"]["job_done"] and v["pass"] and not rec.get("not_counted"), (v, rec.get("not_counted"))
    assert j.item_key(rec) == "L2 / V1 / I4"


def test_i4_on_l2_v1_resumed_but_not_finished_fails_on_the_end(doc):
    io = FakeIO(script=v1_script(finish=False), states=v1_state(finish=False), room=[10, 0])
    rec = j.run_job(io, _v1(doc), {"step": "I4", "interruptions": doc["interruptions"], "trigger": "at:30",
                                   "deadline": 120})
    v = rec["verdict"]
    assert rec["resume"]["resumed"] and v["bars"]["resumed"] and v["bars"]["interrupted"]
    assert v["bars"]["job_done"] is False and not v["pass"]


def test_i4_on_a_long_job_held_back_when_the_end_owes_no_new_slot(doc):
    # the end owes only what takes a new slot: the pickaxe made, a helmet still owed
    both = {**_v1(doc), "end": {"made_carried": _v1(doc)["end"]["made_carried"],
                                "worn_made_in_run": {"Head": ["ITEM_Armour_T2_Head_Leather"]}}}
    made = j.snapshot(v1_state()(T0 + 61))
    made["crafted"] = {BONE_PICK: 1}
    assert j.end_owed(both, j.snapshot(v1_state()(T0)), made) == ["worn_made_in_run"]
    # the pickaxe made and carried before the trigger: the gate stays shut, nothing granted, the step says nothing
    script = model(T0 + 1) + [call(T0 + 3, "c", "craft", {"item": "Bone Pickaxe"}),
                              result(T0 + 8, "c", "craft", data={"item": BONE_PICK, "crafts": 1})]
    io = FakeIO(script=script, states=lambda t: {"position": [0, 0, 0], "inventory_items": [
        _inv(STONE_PICK, "hotbar", "1" * 32)] + ([_inv(BONE_PICK, "hotbar", "3" * 32)] if t >= T0 + 8 else [])},
                room=[10, 0])
    rec = j.run_job(io, _v1(doc), {"step": "I4", "interruptions": doc["interruptions"], "trigger": "at:30",
                                   "deadline": 60})
    assert not io.fixtures and rec["not_counted"]


def test_cli_i4_on_l2_v1_reaches_the_window_and_runs_to_the_end(monkeypatch, capsys):
    seen = []

    def stop_here(a):  # past every check of the step: record what the window would run, open nothing
        seen.append((a.job, a.rung, a.step, a.until, a.trigger))
        return True

    def never(*a, **k):
        raise AssertionError("a window opened from a test")
    monkeypatch.setattr(q, "refuse_dirty", stop_here)
    monkeypatch.setattr(q, "clone_window", never)
    assert j.main(["trial", "--confirm", "--job", "L2", "--rung", "V1", "--interrupt", "I4", "--trigger", "at:240",
                   "-k", "1"]) == 7
    assert j.main(["trial", "--confirm", "--job", "L3", "--interrupt", "I4", "--trigger", "at:240"]) == 7
    assert seen == [("L2", "V1", "I4", "done", "at:240"), ("L3", None, "I4", "done", "at:240")]
    # refused with the reason: a job it cannot bite on, a rung whose end names no new-slot item, a --until short of
    # the end, and another step on a rung
    assert j.main(["trial", "--confirm", "--job", "N1", "--interrupt", "I4"]) == 2
    assert "vehicle is N2" in capsys.readouterr().out
    assert j.main(["trial", "--confirm", "--job", "L2", "--rung", "V2", "--interrupt", "I4"]) == 2
    assert "names no item that takes a new slot" in capsys.readouterr().out
    assert j.main(["trial", "--confirm", "--job", "L3", "--interrupt", "I4", "--until", "resumed"]) == 2
    assert "--until done" in capsys.readouterr().out
    assert j.main(["trial", "--confirm", "--job", "L2", "--rung", "V1", "--interrupt", "I3"]) == 2
    assert len(seen) == 2


def test_i4_on_n2_is_unchanged(doc):
    from tests.test_job_run_i4_i5 import AskIO, n2_crate, n2_script, n2_state
    io = AskIO(script=n2_script(), states=n2_state, chests=n2_crate, room=[14, 0, 0, 0, 0, 0, 0, 0])
    rec = j.run_job(io, j.job_of("N2", doc), {"step": "I4", "interruptions": doc["interruptions"], "confirm_s": 5,
                                              "deadline": 200})
    assert rec["until"] == "resumed" and "i4_gate" not in rec and "gate" not in rec["interruption"]["moment"]
    assert "job_done" not in rec["verdict"]["bars"] and rec["verdict"]["pass"]
