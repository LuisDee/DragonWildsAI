"""tools/job_run.py: the long-job harness, offline. Every live piece is a fake: no server, client, brain or model."""
from __future__ import annotations

import json

import pytest

from tools import job_run as j
from tools import quest_run as q

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
    assert set(jobs) == {"L1", "L2", "L3", "H1", "H2", "H3"}
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
    held = snap(carried={LEATHER["Legs"]: 1})  # he had the chaps before the run: not made in it
    end["crafted"] = {v: 1 for v in LEATHER.values()}
    end2 = snap(worn=LEATHER)  # one pair of chaps at the start, one (worn) at the end
    end2["crafted"] = end["crafted"]
    ok, why = j.done(job, held, end2)
    assert not ok and "held as many" in why


def test_l1_not_counted_when_he_starts_with_hides(doc):
    job = j.job_of("L1", doc)
    assert j.not_counted(job, snap({"ITEM_Resources_Animal_Hide": 4})).startswith("held at the start")
    assert j.not_counted(job, snap({"ITEM_Resources_Stone": 4})) is None
    assert j.not_counted({"not_counted": "x"}) == "x"


def test_l2_done_from_his_own_chest_only(doc):
    job = j.job_of("L2", doc)
    rows = [result(5, "s", "store", data={"container": CRATE, "item": "ITEM_Resources_CopperOre", "inside_now": 30,
                                          "contents": ["30 Copper Ore"]})]
    start, end = snap(mine=[CRATE]), snap()
    end.update(j.evidence(rows))
    assert j.done(job, start, end)[0]
    not_his = snap()
    assert not j.done(job, not_his, end)[0]
    rows[0]["result"]["data"].update(inside_now=29, contents=["29 Copper Ore"])
    end.update(j.evidence(rows))
    ok, why = j.done(job, start, end)
    assert not ok and "29 of 30" in why


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
    end["chests"] = {CRATE: {"items": {cooked: 10, "ITEM_Consumable_Water_Clean": 10}}}
    assert j.done(job, start, end)[0]
    end["chests"][CRATE]["items"] = {"ITEM_Consumable_Bread_Burnt": 10, "ITEM_Consumable_Water_Clean": 10}
    assert not j.done(job, start, end)[0]


def test_h3_next_tier_of_each_family_he_carried(doc):
    job = j.job_of("H3", doc)
    start = snap({"ITEM_Pickaxe_Stone": 1, "ITEM_Logging_Axe_Stone": 1})
    end = snap({"ITEM_Pickaxe_Stone": 1, "ITEM_Pickaxe_Bronze": 1, "ITEM_Logging_Axe_Bronze": 1})
    assert j.done(job, start, end)[0]
    ok, why = j.done(job, start, snap({"ITEM_Pickaxe_Bronze": 1, "ITEM_Logging_Axe_Stone": 1}))
    assert not ok and "logging axe" in why
    assert not j.done(job, snap(), end)[0]  # carried none at the start: nothing to step up from


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


# ------------------------------------------------------------------ the interruptions, on a fake body
class FakeIO:
    """The body, brain and fixtures as run_job sees them: a clock, scripted brain-log rows, scripted states."""

    def __init__(self, script=(), states=None, me_seq=None, empty=None, fixture_fail=None):
        self.t = T0
        self.script = list(script)
        self.states = states or (lambda t: state())
        self.me_seq = list(me_seq or [])
        self.empty = list(empty or [])
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

    def empty_slots(self):
        return self.empty.pop(0) if self.empty else 0

    def fixture(self, verb, purpose, **kw):
        if self.fixture_fail:
            raise RuntimeError(self.fixture_fail)
        self.fixtures.append((verb, kw))
        return {"ok": True, "after": kw.get("pct"), "id": "BP_AI_RuntGoblin_Character_C_1"}

    def gear_target(self, raw):
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
    io = FakeIO(empty=[12, 2, 0])
    out = j.apply_interruption(io, "I4", {"filler": "ITEM_FishingNet_CoarseNet", "rounds": 3}, T0)
    assert [kw["count"] for v, kw in io.fixtures] == [12, 2] and out["took"]
    io = FakeIO(empty=[5, 5, 5, 5])
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
    io = FakeIO(script=l2_script(), states=lambda t: state(mine=[CRATE]))
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
    io = FakeIO(script=script + after, states=lambda t: state(mine=[CRATE]))
    rec = j.run_job(io, j.job_of("L2", doc), {"step": "I5", "interruptions": doc["interruptions"], "confirm_s": 20})
    assert io.restarts == 1
    assert rec["interruption"]["took"] and rec["interruption"]["t_put"] == 21.0
    assert rec["resume"]["resumed"] and rec["resume"]["call"]["tool"] == "gather" and not rec["resume"]["new_line"]
    assert rec["ended"] == "resumed" and rec["done"] and not rec["job_done"] and rec["verdict"]["pass"]
    assert rec["item"] == "job: L2 / I5" and rec["misses"]["by_phase"] == {"before": 0, "during": 0, "after": 0}


def test_run_job_i5_without_a_resumption_fails(doc):
    script = model(T0 + 1) + [call(T0 + 3, "g1", "gather"), result(T0 + 20, "g1", "gather", data={"detail": "Got 3."})]
    io = FakeIO(script=script, states=lambda t: state(mine=[CRATE]))
    rec = j.run_job(io, j.job_of("L2", doc), {"step": "I5", "interruptions": doc["interruptions"]})
    assert rec["ended"] in ("quiet", "no resumption") and not rec["resume"].get("resumed")
    assert not rec["verdict"]["pass"] and not rec["done"]


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
    monkeypatch.setattr(j, "start_ref", lambda job, step, override: ("cp", "the job's start"))
    monkeypatch.setattr(j, "STOP_FILE", tmp_path / "none.stop")
    monkeypatch.setattr(quest_clone, "source_of", lambda ref: tmp_path / "cp.json")
    monkeypatch.setattr(quest_clone, "place_of", lambda ref: [0.0, 0.0, 0.0])
    monkeypatch.setattr(quest_clone, "fork", lambda ref, name: forked.append(name))
    assert j.main(["trial", "--confirm", "--job", "L9", "-k", "2"]) == 1
    assert len(forked) == 1  # every fork of this save starts the same: the window stops at the first
    (t,) = out["trials"]
    assert t["skipped"].startswith("body unfit: health 1 of 100, food 0 of 100, water 0 of 100")
