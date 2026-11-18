"""tools/job_run.py after window n1_i2i4_1118h (logs/window_n1_i2i4_1118h.txt, 2026-11-18 03:44-04:10Z). Offline.

1. 5 of 6 trials: the interruption was never put in. From job_n1_midjob he carries 20 ash and 5 stone, so his job is
   one gather of 5 stone and two stores; `first_deposit|progress:0.5` comes due only between the end of his first
   store and the end of his second: 2.1 to 2.8 s (runs 035300, 040526, 040824), under the 3 s poll; I4 (between_calls)
   also needs no call open, and the second store started 0.7 to 0.8 s after the first ended. Window n1_i1_1118g (I1,
   no between_calls) caught it 5 of 5 only because its second stores ran 2.2 to 3.9 s. Fix: `work:S`, S seconds into
   his first work call (the job's work_tools), and a 0.5 s poll while an interruption is awaited. A trial whose
   interruption never went in is not counted (the harness's), never a fail.
2. Run 034838-N1-I2: the goblin went in at 55.5 s and the fight cleared at 73.7 s; he stored the 10 stone at 58.2 s
   (into crate ...131: 177 -> 187) and was in a store when it cleared. resumed False: the judge took only a work
   call STARTED after the clear, and the end read was UNREAD because the grader picked crate ...149 (297 logs, no
   start read) over ...171 (3 -> 23 by the body's read at his store).
3. Runs 034457 and 040149: "the crates I can see aren't mine" (owner ClaudeDev, mine false) and he stopped. The body's
   row now says whose account the placer is on (sense.owner_row: OwningPlayerId against his own account); the harness
   takes same_account as the game's word that the crate is his.
"""
from __future__ import annotations

import pytest

from tools import job_run as j
from tests.test_job_run import T0, FakeIO, call, model, result, state

ASH, STONE = "ITEM_Resources_Wood_Ash", "ITEM_Resources_Stone"
DEV_GUID = "E71C5DC146F0A55B69FF52A881255DEF"
FORK_GUID = "11111111222222223333333344444444"
C149, C171, C131 = ("BP_BaseBuilding_Crate_C_2147480149", "BP_BaseBuilding_Crate_C_2147480171",
                    "BP_BaseBuilding_Crate_C_2147480131")


@pytest.fixture(scope="module")
def doc():
    return j.load_jobs()


def run_035300(stores=True):
    """Run 20261118-035300-N1-I2 (and 040526/040824-N1-I4): gather 5 stone 5.5-15.1 s, look 16.5-17.0 s, store the ash
    19.4-25.9 s, store the stone 26.6-28.7 s. Without the stores: run 034457 (he stopped, quiet)."""
    rows = model(T0 + 1) + [call(T0 + 5.5, "g", "gather", {"resource": "loose_stones", "count": 5}),
                            result(T0 + 15.1, "g", "gather", data={"detail": "Got 5 loose_stones."}),
                            call(T0 + 16.5, "l", "look", {"about": "crate"}), result(T0 + 17.0, "l", "look")]
    if stores:
        rows += [call(T0 + 19.4, "s1", "store", {"item": "Ash Logs", "container": C171}),
                 result(T0 + 25.9, "s1", "store", data={"container": C171, "item": ASH, "count": 20,
                                                         "contents": ["23 Ash Logs"]}),
                 call(T0 + 26.6, "s2", "store", {"item": "Stone", "container": C171}),
                 result(T0 + 28.7, "s2", "store", data={"container": C171, "item": STONE, "count": 10,
                                                         "contents": ["23 Ash Logs", "10 Stone"]})]
    return rows


def carried(t):
    return state(carried={ASH: 20 if t < T0 + 25.9 else 0, STONE: (5 if t < T0 + 15.1 else 10) if t < T0 + 28.7 else 0},
                 mine=[C171])


def crate(t, cid):
    """C171 as the body reads it: 3 ash before his stores, 23 after the first, 23 and 10 stone after the second."""
    if cid != C171:
        return None
    out = [{"item": ASH, "name": "Ash Logs", "count": 3 if t < T0 + 25.9 else 23}]
    return out + ([{"item": STONE, "name": "Stone", "count": 10}] if t >= T0 + 28.7 else [])


# ------------------------------------------------------------------ 1. the moment, from a mid checkpoint
def test_work_trigger_is_a_known_kind():
    assert j.trigger_ok("work:4") and j.trigger_ok("first_deposit|work:4")
    assert not j.trigger_ok("work") and not j.trigger_ok("work:x")
    # due S seconds after his first work call started, whatever it returned
    assert not j.trigger_due("work:4", None, 8.0, None, work_t=None)
    assert not j.trigger_due("work:4", None, 9.4, None, work_t=5.5)
    assert j.trigger_due("work:4", None, 9.5, None, work_t=5.5)


def test_first_work_is_the_start_of_his_first_work_call(doc):
    job = j.job_of("N1", doc)
    calls = [{"t": 2.0, "tool": "look", "dur_s": 0.3, "ok": True},
             {"t": 5.5, "tool": "gather", "dur_s": None, "ok": None}]
    assert j.first_work(calls, job) == 5.5
    assert j.first_work(calls[:1], job) is None


def test_n1_puts_the_interruption_inside_his_first_work_call(doc):
    job = j.job_of("N1", doc)
    assert job["interrupt_trigger"].startswith("work:") and j.trigger_ok(job["interrupt_trigger"])
    io = FakeIO(script=run_035300(), states=carried, chests=crate)
    rec = j.run_job(io, job, {"step": "I2", "interruptions": doc["interruptions"], "deadline": 60})
    m = rec["interruption"]["moment"]
    assert m["first_work_s"] == 5.5 and 9.5 <= m["at_s"] <= 10.5, m  # inside the gather (5.5-15.1 s)


def test_between_calls_finds_the_short_gap_after_his_gather(doc):
    # I4 waits for no open call: the gap after the gather (15.1-16.5 s) is 1.4 s, under the 3 s poll
    # needs_new_slot off: on N1 it never lets the fill in (he holds both kinds); the gap is what this tests
    spec = {**doc["interruptions"], "I4": {**doc["interruptions"]["I4"], "needs_new_slot": False}}
    io = FakeIO(script=run_035300(), states=carried, chests=crate, room=[4, 0, 0])
    rec = j.run_job(io, j.job_of("N1", doc), {"step": "I4", "interruptions": spec, "deadline": 60})
    m = rec["interruption"]["moment"]
    assert 15.1 <= m["at_s"] < 16.5, m
    assert rec["interruption"]["full_read"] is True and rec["interruption"]["took"] is None  # filled, never bit


def test_the_old_trigger_at_the_old_poll_misses_the_window_shape(doc, monkeypatch):
    # the cause, kept as a test: from this checkpoint first_deposit is due for 0.7 s before his next call opens, and
    # the 3 s poll did not see it; the job was done before it came due (not counted, never a fail)
    from tools import quest_run as q
    monkeypatch.setattr(j, "AWAIT_POLL_S", q.POLL_S)
    io = FakeIO(script=run_035300(), states=carried, chests=crate, room=[4, 0, 0])
    rec = j.run_job(io, j.job_of("N1", doc), {"step": "I4", "interruptions": doc["interruptions"], "deadline": 60,
                                              "trigger": "first_deposit|progress:0.5"})
    assert rec["interruption"]["took"] is False and rec["interruption"]["how"].startswith("never put in")
    assert rec["ended"] == "job done" and rec["not_counted"].startswith("the job was done before")


def test_a_trial_whose_interruption_never_went_in_is_not_counted(doc):
    # run 034457: he stopped before the moment came (quiet): the step says nothing about resuming, never a fail
    io = FakeIO(script=run_035300(stores=False), states=lambda t: state(carried={ASH: 20, STONE: 10}, mine=[C171]),
                chests=lambda t, cid: [{"item": ASH, "name": "Ash Logs", "count": 3}] if cid == C171 else None)
    rec = j.run_job(io, j.job_of("N1", doc), {"step": "I2", "interruptions": doc["interruptions"], "deadline": 200,
                                              "trigger": "first_deposit"})
    assert rec["ended"] == "quiet"
    assert rec["interruption"]["how"].startswith("never put in") and "first_deposit" in rec["interruption"]["how"]
    assert rec["not_counted"].startswith("the interruption was never put in")
    assert j.not_counted(rec) and not j.scored([rec], set())


# ------------------------------------------------------------------ 3. whose a crate is: the game's account read
def test_a_crate_of_his_account_is_his_by_the_games_account_read():
    # the body's row (sense.owner_row): ClaudeDev placed it, OwningPlayerId = his own account string
    r = j.read_container({"ok": True, "data": {"kind": "storage", "contents": [], "owner_guid": DEV_GUID,
                                               "owner": "ClaudeDev (another character of your account)",
                                               "owner_name": "ClaudeDev", "same_account": True, "mine": False}})
    assert r["same_account"] is True and r["owner_name"] == "ClaudeDev"
    start, end = j.snapshot(state()), j.snapshot(state())  # no own_guids: only the game's read says
    end["chest_end"] = {C171: r}
    his, why = j.game_owner(C171, start, end)
    assert his is True and "another character of your account" in why
    end["chest_end"] = {C171: {**r, "same_account": False, "owner": "luisdeburnaybast (another player)"}}
    assert j.game_owner(C171, start, end)[0] is False
    c = j.chests_seen([result(1, "a", "store", data={"container": C171, "contents": ["2 Ash Logs"], "same_account": True,
                                                       "owner": "ClaudeDev (another character of your account)"})])
    assert c[C171]["same_account"] is True


# ------------------------------------------------------------------ 2. the resume judge
def test_a_work_call_he_carried_through_the_interruption_is_taking_it_up():
    # run 034838: put in 55.5 s, cleared 73.7 s; the store that started at 62.7 s ran until 76.8 s
    calls = [{"t": 48.2, "tool": "store", "dur_s": 5.0, "ok": True},
             {"t": 58.2, "tool": "store", "dur_s": 3.8, "ok": True},
             {"t": 62.7, "tool": "store", "dur_s": 14.1, "ok": True},
             {"t": 87.7, "tool": "inventory", "dur_s": 0.2, "ok": True}]
    r = j.resumed(calls, {"t_put": 55.5, "t_clear": 73.7}, ["store", "gather"])
    assert r["resumed"] is True and r["after_s"] == 0.0 and r["through"] is True and r["t"] == 73.7
    assert r["call"]["tool"] == "store"


def test_a_call_from_before_the_interruption_is_not_taking_it_up():
    calls = [{"t": 50.0, "tool": "gather", "dur_s": 30.0, "ok": True}]  # started before it went in
    assert j.resumed(calls, {"t_put": 55.5, "t_clear": 73.7}, ["gather"])["resumed"] is False
    calls = [{"t": 60.0, "tool": "gather", "dur_s": 30.0, "ok": False}]  # started in it, failed after: not work done
    assert j.resumed(calls, {"t_put": 55.5, "t_clear": 73.7}, ["gather"])["resumed"] is False


def test_a_crate_with_a_known_start_wins_over_a_fuller_one_without(doc):
    # run 034838's end read: ...149 holds 297 of each and was never read before his stores; ...171 went 3 -> 23 ash and
    # ...131 177 -> 187 stone by the body's reads at his stores (chests_before)
    job = j.job_of("N1", doc)
    start = j.snapshot(state(mine=[C149, C171, C131]))
    start["own_guids"] = [FORK_GUID, DEV_GUID]
    end = j.snapshot(state(mine=[C149, C171, C131]))
    end["chests_before"] = {C171: {ASH: 3, STONE: 99}, C131: {ASH: 73, STONE: 177}}
    own = {"owner": "ClaudeDev", "owner_guid": DEV_GUID, "mine": False, "kind": "storage"}
    end["chest_end"] = {C149: {"read": True, "items": {ASH: 297, STONE: 297}, **own},
                        C171: {"read": True, "items": {ASH: 23, STONE: 99}, **own},
                        C131: {"read": True, "items": {ASH: 73, STONE: 187}, **own}}
    ok, why = j.done(job, start, end)
    assert ok is True, why
    # and with no crate of known start holding enough, it stays unread (never a pass on the 297)
    end["chests_before"] = {C171: {ASH: 10, STONE: 99}, C131: {ASH: 73, STONE: 177}}
    ok, why = j.done(job, start, end)
    assert ok is None and C149 in why
