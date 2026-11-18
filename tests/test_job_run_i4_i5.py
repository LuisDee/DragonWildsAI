"""I4 (a full bag) and I5 (a brain restart) read from the game (study 2026-11-18, section 4).

I4: the fill is never a pass on its own. It bites when a call of his meets the full bag (a result `inventory_full`, or
a gather of a kind he holds none of that comes back short); it clears at the first read with room after the bite; he
resumed when a call after the clear moved the job by the game's reads. A full bag that met no call says nothing. N1
cannot bite (every unit it needs merges into a stack he holds), so the vehicle is N2 (a chest job of an item he holds
none of).

I5: the open call at the kill, the stop / start / ready times, the at-clear read of his chest and bag, a resume that
serves the ask (upkeep does not), not counted when the in-flight call finished the job, the ask store cleared at each
trial's start and kept across the restart inside it, and whether `ask_restored` appeared (beside the verdict).
Offline: every live piece is a fake.
"""
from __future__ import annotations

import argparse
import json

import pytest

from tools import job_run as j
from tests.test_job_run import CRATE, T0, FakeIO, call, model, result, state
from tests.test_job_run_near_home import store_one

ASH, STONE, FLAX = "ITEM_Resources_Wood_Ash", "ITEM_Resources_Stone", "ITEM_Resources_Flax"


@pytest.fixture(scope="module")
def doc():
    return j.load_jobs()


class AskIO(FakeIO):
    """FakeIO that also keeps the order of brain starts, restarts and ask-store clears, and gives restart times."""

    def __init__(self, *a, **kw):
        super().__init__(*a, **kw)
        self.order: list[str] = []

    def clear_ask(self):
        self.order.append("clear_ask")
        return {"world": "dev_ClaudeJ_a", "had_ask": True}

    def start_brain(self):
        self.order.append("start_brain")
        return True

    def restart_brain(self, gap_s):
        self.order.append("restart_brain")
        stopped = self.t + 1.0
        self.t += gap_s + 10.0  # the new brain took 10 s to be ready after the gap
        self.restarts += 1
        return {"ready": True, "t_stopped": stopped, "t_started": stopped + gap_s, "t_ready": self.t}


# ------------------------------------------------------------------ I4 1. the fill is not a pass
def test_i4_fill_reads_full_but_has_not_bitten():
    io = FakeIO(room=[12, 0])
    out = j.apply_interruption(io, "I4", {"filler": "ITEM_FishingNet_CoarseNet", "rounds": 3}, T0)
    assert out["full_read"] is True and out["filled"] == 12 and out["left"] == 0
    assert out["took"] is None and out["t_clear"] is None  # a fill is not an interruption until a call meets it
    out = j.apply_interruption(FakeIO(room=[5, 5, 5, 5]), "I4", {"filler": "x", "rounds": 3}, T0)
    assert out["full_read"] is False and out["took"] is False


def test_snapshot_reads_room_from_get_states_bag_when_the_pages_are_not_there():
    s = j.snapshot({"position": [0, 0, 0], "inventory_items": [], "bag": {"used": 30, "capacity": 32}})
    assert s["bag_room"] == 2 and s["bag_room_from"] == "bag"
    s = j.snapshot({"position": [0, 0, 0], "inventory_items": [], "bag": {"used": 32}})
    assert s["bag_room"] is None


# ------------------------------------------------------------------ I4 2. bite, clear, from the game
def _intr(unheld=(FLAX,)):
    return {"step": "I4", "t_put": 10.0, "t_clear": None, "took": None, "full_read": True,
            "moment": {"unheld": list(unheld)}}


def test_bag_watch_bites_on_inventory_full_and_clears_at_the_first_room_after():
    calls = [{"t": 12.0, "tool": "gather", "dur_s": 1.0, "ok": False, "reason": "inventory_full", "args": {}},
             {"t": 15.0, "tool": "store", "dur_s": 4.0, "ok": True, "reason": None, "args": {"item": "Stone"}}]
    samples = [{"t": 11.0, "carried": {FLAX: 0}, "room": 0}, {"t": 16.0, "carried": {FLAX: 0}, "room": 0},
               {"t": 21.0, "carried": {FLAX: 0}, "room": 1}]
    out = j.bag_watch(calls, _intr(), samples)
    assert out["took"] is True and out["bite"]["t"] == 13.0 and out["bite"]["how"] == "inventory_full"
    assert out["t_clear"] == 21.0 and out["freed_by"]["tool"] == "store"
    assert out["at_clear"]["carried"] == {FLAX: 0} and out["at_clear"]["room"] == 1
    # no room read yet after the bite: bitten, not cleared
    out = j.bag_watch(calls, _intr(), samples[:2])
    assert out["took"] is True and out["t_clear"] is None


def test_bag_watch_bites_on_a_short_gather_of_a_kind_he_holds_none_of():
    # the body's own gather check misses a full item page today (inventory.lua counts every page): it comes back
    # nothing_in_range or ok with nothing got; both are a bite while the bag reads full and he holds none of the kind
    failed = [{"t": 12.0, "tool": "gather", "dur_s": 8.0, "ok": False, "reason": "nothing_in_range", "args": {}}]
    out = j.bag_watch(failed, _intr(), [{"t": 21.0, "carried": {FLAX: 0}, "room": 0}])
    assert out["took"] is True and out["bite"]["how"].startswith("short")
    got_none = [dict(failed[0], ok=True, reason=None)]
    assert j.bag_watch(got_none, _intr(), [{"t": 21.0, "carried": {FLAX: 0}, "room": 0}])["took"] is True
    # undecided until a read after it ended
    assert j.bag_watch(got_none, _intr(), [{"t": 15.0, "carried": {FLAX: 0}, "room": 0}])["took"] is None
    # it got some: no bite
    assert j.bag_watch(got_none, _intr(), [{"t": 21.0, "carried": {FLAX: 3}, "room": 0}])["took"] is None
    # nothing unheld (every asked kind already on him): a short gather is no bite
    assert j.bag_watch(failed, _intr(unheld=()), [{"t": 21.0, "carried": {FLAX: 2}, "room": 0}])["took"] is None


def test_bag_watch_room_before_any_call_met_it_is_never_a_bite():
    calls = [{"t": 30.0, "tool": "gather", "dur_s": 1.0, "ok": False, "reason": "inventory_full", "args": {}}]
    samples = [{"t": 20.0, "carried": {FLAX: 0}, "room": 3}, {"t": 35.0, "carried": {FLAX: 0}, "room": 0}]
    out = j.bag_watch(calls, _intr(), samples)
    assert out["took"] is None and out["freed_before_bite"]["t"] == 20.0 and not out.get("bite")


# ------------------------------------------------------------------ I4 3-5. whole trials, the vehicle
def test_n2_is_the_i4_vehicle_a_chest_job_of_an_item_he_holds_none_of(doc):
    job = j.job_of("N2", doc)
    wants = job["end"]["in_own_chest"]
    assert [w["item"] for w in wants] == [FLAX] and wants[0]["gained"] and not job["held_out"]
    assert job["line"].startswith("claude, ") and "go_to" not in job["work_tools"]
    assert FLAX in job["not_carried_at_start"]
    assert job["check_live"] and {c["item"] for c in job["candidates"]} >= {FLAX, "ITEM_Resources_Weeds"}
    assert all(c.get("check_live") for c in job["candidates"])
    assert j.bar_s(job) and j.trigger_ok(job["interrupt_trigger"])
    i4 = doc["interruptions"]["I4"]
    assert i4["job"] == "N2" and i4["from"] and i4["needs_new_slot"] is True and i4["between_calls"] is True


def test_start_ref_takes_i4s_own_from_on_its_vehicle(doc, monkeypatch, tmp_path):
    from tools import quest_clone
    monkeypatch.setattr(quest_clone, "CHECKPOINT_DIR", tmp_path)
    job, spec = j.job_of("N2", doc), doc["interruptions"]["I4"]
    assert j.start_ref(job, "I4", None, spec) == ("ClaudeDev", f"the job's start ({spec['from']} not made yet)")
    (tmp_path / f"{spec['from']}.json").write_text("{}", encoding="utf-8")
    assert j.start_ref(job, "I4", None, spec) == (spec["from"], "I4's checkpoint")
    assert j.start_ref(job, "I4", "other", spec) == ("other", "--from")


def test_cli_refuses_i4_on_a_job_that_is_not_its_vehicle(capsys, monkeypatch):
    from tools import quest_run as q

    def never(*a, **k):  # a window must never open from a test (it boots the real client)
        raise AssertionError("cmd_window went past the vehicle check")
    monkeypatch.setattr(q, "refuse_dirty", never)
    monkeypatch.setattr(q, "clone_window", never)
    assert j.main(["trial", "--confirm", "--job", "N1", "--interrupt", "I4", "-k", "1"]) == 2
    assert "vehicle is N2" in capsys.readouterr().out


def n2_script():
    """From a checkpoint with no flax: the bag is filled at once (at:0, no call open); his flax pickup 6-14 s comes
    back nothing_in_range (the bite); he stores his stone 16-20 s (room back at the 21 s read); picks 10 flax 25-45 s;
    stores them 47-52 s."""
    rows = model(T0 + 1) + [call(T0 + 6, "p1", "pickup", {"resource": "flax", "count": 10}),
                            result(T0 + 14, "p1", "pickup", ok=False, reason="nothing_in_range"),
                            call(T0 + 16, "s1", "store", {"item": "Stone", "container": CRATE}),
                            store_one(T0 + 20, "s1", STONE, "Stone", 5, 5, ["5 Stone"]),
                            call(T0 + 25, "p2", "pickup", {"resource": "flax", "count": 10}),
                            result(T0 + 45, "p2", "pickup", data={"detail": "Got 10 flax."}),
                            call(T0 + 47, "s2", "store", {"item": "Flax", "container": CRATE}),
                            store_one(T0 + 52, "s2", FLAX, "Flax", 10, 10, ["5 Stone", "10 Flax"])]
    return sorted(rows, key=lambda r: r["ts"])


def _nz(carried):
    return {k: n for k, n in carried.items() if n}  # a bag row is a stack: none carried is no row


def n2_state(t):
    flax = 10 if T0 + 45 <= t < T0 + 52 else 0
    stone = 5 if t < T0 + 20 else 0
    s = state(carried=_nz({STONE: stone, FLAX: flax}), mine=[CRATE])
    s["bag"] = {"used": 32 if t < T0 + 20 else 31, "capacity": 32}
    return s


def n2_crate(t, cid):
    if cid != CRATE:
        return None
    return ([{"item": STONE, "name": "Stone", "count": 5}] if t >= T0 + 20 else []) + \
           ([{"item": FLAX, "name": "Flax", "count": 10}] if t >= T0 + 52 else [])


def test_i4_on_n2_bites_clears_and_resumes_by_the_games_reads(doc):
    io = AskIO(script=n2_script(), states=n2_state, chests=n2_crate, room=[14, 0, 0, 0, 0, 0, 0, 0])
    rec = j.run_job(io, j.job_of("N2", doc), {"step": "I4", "interruptions": doc["interruptions"], "confirm_s": 5,
                                              "deadline": 200})
    intr = rec["interruption"]
    assert intr["full_read"] and intr["moment"]["unheld"] == [FLAX] and intr["t_put"] < 6
    assert intr["bite"]["t"] == 14.0 and intr["bite"]["call"]["tool"] == "pickup"
    assert intr["freed_by"]["tool"] == "store" and 20.0 <= intr["t_clear"] <= 36.0
    r = rec["resume"]
    assert r["resumed"] and r["call"]["tool"] == "pickup" and r["call"]["t"] == 25.0
    v = rec["verdict"]
    assert v["bars"]["interrupted"] and v["pass"] and not rec.get("not_counted"), (v, rec.get("not_counted"))


def _n1_no_gate(doc):
    return {**doc["interruptions"], "I4": {**doc["interruptions"]["I4"], "needs_new_slot": False}}


def test_i4_on_n1_waits_for_a_new_slot_and_is_never_put_in(doc):
    from tests.test_job_run_n1_i2i4 import carried, crate, run_035300
    io = FakeIO(script=run_035300(), states=carried, chests=crate, room=[4, 0, 0])
    rec = j.run_job(io, j.job_of("N1", doc), {"step": "I4", "interruptions": doc["interruptions"], "deadline": 60})
    assert rec["interruption"]["how"].startswith("never put in") and "new slot" in rec["interruption"]["how"]
    assert rec["not_counted"] and not io.fixtures


def test_i4_a_full_bag_that_met_no_call_says_nothing(doc):
    # the false pass the study found: fill at 15 s, he stores into stacks he holds, the job reads done; before, the
    # fill set t_clear and his next store read as the resume
    from tests.test_job_run_n1_i2i4 import carried, crate, run_035300
    io = FakeIO(script=run_035300(), states=carried, chests=crate, room=[4, 0, 0, 0, 0, 0, 0, 0])
    rec = j.run_job(io, j.job_of("N1", doc), {"step": "I4", "interruptions": _n1_no_gate(doc), "deadline": 60})
    intr = rec["interruption"]
    assert intr["full_read"] and intr["took"] is None and intr["t_clear"] is None and not intr.get("bite")
    assert rec["not_counted"].startswith("the full bag met no call of his")
    assert not rec["verdict"]["bars"]["interrupted"] and not rec["verdict"]["pass"]


# ------------------------------------------------------------------ I5
def test_i5_records_stop_start_and_ready_apart():
    io = AskIO()
    out = j.apply_interruption(io, "I5", {"gap_s": 5}, T0)
    assert (out["t_stopped"], out["t_started"], out["t_ready"]) == (1.0, 6.0, 15.0)
    assert out["took"] and out["t_clear"] == 15.0


def n1_i5_script(after=()):
    """job_n1_midjob: 20 ash and 5 stone on him, 3 ash in his crate. Gather 5 stone 5.5-15.1 s; the store of the ash
    opens at 16 s and the brain is killed inside it (no result row: the old brain died)."""
    rows = model(T0 + 1) + [call(T0 + 5.5, "g", "gather", {"resource": "loose_stones", "count": 5}),
                            result(T0 + 15.1, "g", "gather", data={"detail": "Got 5 loose_stones."}),
                            call(T0 + 16.0, "s1", "store", {"item": "Ash Logs", "container": CRATE})]
    return sorted(rows + list(after), key=lambda r: r["ts"])


def n1_carried(ash_stored_at=None, stone_stored_at=None, extra_ash_at=None):
    def f(t):
        ash = 0 if ash_stored_at and t >= T0 + ash_stored_at else 20
        if extra_ash_at and t >= T0 + extra_ash_at:
            ash += 3
        stone = (5 if t < T0 + 15.1 else 10)
        if stone_stored_at and t >= T0 + stone_stored_at:
            stone = 0
        return state(carried=_nz({ASH: ash, STONE: stone}), mine=[CRATE])
    return f


def n1_crate(ash_in_at=None, stone_in_at=None):
    def f(t, cid):
        if cid != CRATE:
            return None
        ash = 23 if ash_in_at and t >= T0 + ash_in_at else 3
        out = [{"item": ASH, "name": "Ash Logs", "count": ash}]
        return out + ([{"item": STONE, "name": "Stone", "count": 10}] if stone_in_at and t >= T0 + stone_in_at else [])
    return f


def _i5(doc, trigger="at:17"):
    return {"step": "I5", "interruptions": doc["interruptions"], "confirm_s": 10, "deadline": 200, "trigger": trigger}


def test_i5_finished_by_the_in_flight_call_is_not_counted(doc):
    # run 021010: the body finished the store while no brain ran; the at-clear read shows the job done
    io = AskIO(script=n1_i5_script(), states=n1_carried(ash_stored_at=18, stone_stored_at=19),
               chests=n1_crate(ash_in_at=18, stone_in_at=19))
    rec = j.run_job(io, j.job_of("N1", doc), _i5(doc))
    intr = rec["interruption"]
    assert intr["moment"]["open_call"]["tool"] == "store" and intr["moment"]["open_call"]["t"] == 16.0
    ac = intr["at_clear"]
    assert ac["done"] is True and ac["carried"] == {ASH: 0, STONE: 0} and ac["chests"][CRATE][ASH] == 23
    assert rec["not_counted"].startswith("finished by the in-flight call")


def test_i5_upkeep_after_the_restart_is_not_a_resume(doc):
    # run 021010's "resume": a 3-ash pickup for fire fuel with 20 ash already on him
    after = model(T0 + 40) + [call(T0 + 42, "w", "collect_water", {}), result(T0 + 60, "w", "collect_water"),
                              call(T0 + 62, "p", "pickup", {"resource": "ash", "count": 3}),
                              result(T0 + 70, "p", "pickup", data={"detail": "Got 3 ash."})]
    io = AskIO(script=n1_i5_script(after), states=n1_carried(extra_ash_at=70), chests=n1_crate())
    rec = j.run_job(io, j.job_of("N1", doc), _i5(doc))
    assert rec["interruption"]["at_clear"]["done"] is False
    assert not rec["resume"].get("resumed") and not rec["verdict"]["pass"] and not rec.get("not_counted")
    assert rec["resume"].get("first_work_call", {}).get("tool") == "pickup"


def test_i5_a_store_of_an_asked_item_after_the_restart_resumes(doc):
    after = model(T0 + 40) + [call(T0 + 42, "s2", "store", {"item": "Ash Logs", "container": CRATE}),
                              store_one(T0 + 48, "s2", ASH, "Ash Logs", 20, 23, ["23 Ash Logs"]),
                              call(T0 + 50, "s3", "store", {"item": "Stone", "container": CRATE}),
                              store_one(T0 + 53, "s3", STONE, "Stone", 10, 10, ["23 Ash Logs", "10 Stone"])]
    io = AskIO(script=n1_i5_script(after), states=n1_carried(ash_stored_at=48, stone_stored_at=53),
               chests=n1_crate(ash_in_at=48, stone_in_at=53))
    rec = j.run_job(io, j.job_of("N1", doc), _i5(doc))
    r = rec["resume"]
    assert r["resumed"] and r["call"]["tool"] == "store" and r["call"]["t"] == 42.0
    assert rec["verdict"]["pass"] and not rec.get("not_counted")


def test_the_ask_store_is_cleared_at_the_trials_start_and_kept_across_its_restart(doc):
    io = AskIO(script=n1_i5_script(), states=n1_carried(), chests=n1_crate())
    rec = j.run_job(io, j.job_of("N1", doc), _i5(doc))
    assert io.order == ["clear_ask", "start_brain", "restart_brain"]
    assert rec["ask_store"] == {"world": "dev_ClaudeJ_a", "had_ask": True}


def test_ask_restored_is_recorded_beside_the_verdict(doc):
    after = [{"ts": T0 + 34, "kind": "ask_restored", "request": doc["jobs"]["N1"]["line"], "lost_call": "store"}]
    after += model(T0 + 40) + [call(T0 + 42, "s2", "store", {"item": "Ash Logs", "container": CRATE}),
                               store_one(T0 + 48, "s2", ASH, "Ash Logs", 20, 23, ["23 Ash Logs"])]
    io = AskIO(script=n1_i5_script(after), states=n1_carried(ash_stored_at=48), chests=n1_crate(ash_in_at=48))
    rec = j.run_job(io, j.job_of("N1", doc), _i5(doc))
    assert rec["ask_restored"]["seen"] is True and rec["ask_restored"]["lost_call"] == "store"
    assert "ask_restored" not in rec["verdict"]["bars"]
    io = AskIO(script=n1_i5_script(after[1:]), states=n1_carried(ash_stored_at=48), chests=n1_crate(ash_in_at=48))
    rec2 = j.run_job(io, j.job_of("N1", doc), _i5(doc))
    assert rec2["ask_restored"]["seen"] is False and rec2["verdict"]["pass"] == rec["verdict"]["pass"]


def test_live_clears_the_ask_of_its_world_and_its_restart_keeps_it(tmp_path, monkeypatch):
    from brain import ask_store
    from tools import chat_ladder as cl
    monkeypatch.setenv("DW_STATE_DIR", str(tmp_path))
    wd = ask_store.world_dir("dev_ClaudeJ181200a_a")
    ask_store.save(wd, {"words": "claude, put twenty ash logs", "state": "open"})
    live = j.Live(argparse.Namespace(world="dev_ClaudeJ181200a_a"), None, None)
    monkeypatch.setattr(cl, "stop_brain", lambda p: None)
    monkeypatch.setattr(j.time, "sleep", lambda s: None)
    monkeypatch.setattr(j.Live, "start_brain", lambda self: True)
    r = live.restart_brain(5)
    assert r["ready"] and r["t_stopped"] <= r["t_started"] <= r["t_ready"] and ask_store.load(wd)
    got = live.clear_ask()
    assert got["world"] == "dev_ClaudeJ181200a_a" and got["had_ask"] is True and ask_store.load(wd) is None
    assert live.clear_ask()["had_ask"] is False
