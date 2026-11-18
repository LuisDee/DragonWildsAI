"""tools/job_run.py, the near-home job N1 and the interruption put in mid-job (goal 2026-11-17, "The venture ladder":
I1 to I5 move off L2 to a job he can finish near home). Offline: every live piece is a fake. The store rows are in the
body's own result shape (client_mod/scripts/skills.lua store: data.item, count, inside_now, contents words; the queue
form data.taken), the brain-log rows as the brain writes them (tool_call / tool_result, ts in seconds)."""
from __future__ import annotations

import pytest

from tools import job_run as j
from tests.test_job_run import CRATE, T0, FakeIO, call, model, result, state

ASH, STONE = "ITEM_Resources_Wood_Ash", "ITEM_Resources_Stone"


@pytest.fixture(scope="module")
def doc():
    return j.load_jobs()


def store_one(ts, cid, item, name, n, inside, contents, container=CRATE):
    """One-item store result, as skills.lua finishes it (count = moved, inside_now = that item's count inside)."""
    return result(ts, cid, "store", data={"item": item, "name": name, "count": n, "container": container,
                                           "container_name": "Crate", "carried_now": 0, "inside_now": inside,
                                           "contents": contents, "walked_m": 4,
                                           "detail": f"Put {n} {name} in the Crate (I walked 4 m to it)."})


def store_queue(ts, cid, taken, contents, container=CRATE):
    """A store of several stacks (skills.lua finish_queue): data.taken [{item, name, count}], count = total moved."""
    return result(ts, cid, "store", data={"container": container, "container_name": "Crate", "taken": taken,
                                           "left": [], "count": sum(t["count"] for t in taken),
                                           "inside_now": 0, "contents": contents, "detail": "Put them in the Crate."})


# ------------------------------------------------------------------ the job in the table
def test_n1_is_a_near_home_chest_job_with_a_gained_count(doc):
    job = j.job_of("N1", doc)
    assert job["line"].startswith("claude, ") and "\n" not in job["line"] and not job["held_out"]
    wants = {w["item"]: w for w in job["end"]["in_own_chest"]}
    assert wants[ASH]["count"] == 20 and wants[STONE]["count"] == 10
    assert all(w["gained"] for w in wants.values())
    assert job["start"] == "ClaudeDev" and job["interrupt_from"] == "job_n1_own_chest"
    assert j.trigger_ok(job["interrupt_trigger"]) and "go_to" not in job["work_tools"]
    assert 60 < j.bar_s(job) < 200  # 20 logs at 3.15 s, 10 stone at 0.91 s, a crate, three presses
    assert doc["interruptions"]["I4"]["between_calls"] is True


# ------------------------------------------------------------------ what went in, read from the body's results
def test_moved_by_reads_one_item_and_queue_stores_and_takes():
    assert j.moved_by(store_one(10, "s", ASH, "Ash Logs", 12, 73, ["73 Ash Logs"])) == {ASH: 12}
    q = store_queue(10, "s", [{"item": ASH, "name": "Ash Logs", "count": 8}, {"item": STONE, "name": "Stone", "count": 4}],
                    ["8 Ash Logs", "4 Stone"])
    assert j.moved_by(q) == {ASH: 8, STONE: 4}
    take = result(10, "t", "take", data={"item": ASH, "count": 3, "container": CRATE, "inside_now": 5, "contents": []})
    assert j.moved_by(take) == {ASH: -3}
    assert j.moved_by(result(10, "s", "store", ok=False, reason="container_full", data={"item": ASH, "count": 3})) == {}
    assert j.moved_by(call(10, "s", "store", {"item": "Ash Logs"})) == {}


def test_chests_before_is_the_crates_count_before_his_first_store():
    rows = [store_one(T0 + 30, "s1", ASH, "Ash Logs", 12, 73, ["73 Ash Logs", "5 Stone"]),
            store_one(T0 + 60, "s2", STONE, "Stone", 10, 15, ["73 Ash Logs", "15 Stone"])]
    assert j.chests_before(rows) == {CRATE: {ASH: 61, STONE: 5}}
    new = store_queue(T0 + 30, "s1", [{"item": ASH, "name": "Ash Logs", "count": 20}], ["20 Ash Logs"], container="NEW")
    assert j.chests_before([new]) == {"NEW": {ASH: 0}}  # a crate built in the run held nothing


def _end(chest_items, rows=(), start_read=None):
    start = j.snapshot(state(mine=[CRATE]))
    if start_read is not None:
        start["chest_start"] = {CRATE: {"read": True, "items": start_read}}
    end = j.snapshot(state(mine=[CRATE]))
    end.update(j.evidence(list(rows)))
    end["chest_end"] = {CRATE: {"read": True, "items": chest_items, "kind": "storage"}}
    return start, end


def test_n1_counts_only_what_went_in_after_the_line(doc):
    job = j.job_of("N1", doc)
    # the crate held 61 logs from an earlier run: 75 at the end is 14 put in, not 75
    s, e = _end({ASH: 75, STONE: 10}, start_read={ASH: 61})
    ok, why = j.done(job, s, e)
    assert ok is False and "14 of 20" in why
    s, e = _end({ASH: 81, STONE: 10}, start_read={ASH: 61})
    assert j.done(job, s, e)[0] is True
    # no start read (out of reach at the start): the body's read at his first store gives the start count
    rows = [store_one(T0 + 30, "s1", ASH, "Ash Logs", 20, 81, ["81 Ash Logs"]),
            store_one(T0 + 40, "s2", STONE, "Stone", 10, 10, ["81 Ash Logs", "10 Stone"])]
    s, e = _end({ASH: 81, STONE: 10}, rows=rows)
    assert j.done(job, s, e)[0] is True
    # neither read and enough inside: unread, never a pass on a count that may be old
    s, e = _end({ASH: 81, STONE: 10})
    ok, why = j.done(job, s, e)
    assert ok is None and "not read" in why


# ------------------------------------------------------------------ the moment the interruption goes in
def test_first_deposit_is_his_first_store_of_an_asked_item(doc):
    job = j.job_of("N1", doc)
    rows = [call(T0 + 20, "x", "store", {"item": "Bronze Sword"}),
            store_one(T0 + 25, "x", "ITEM_Weapon_Sword_Bronze", "Bronze Sword", 1, 1, ["1 Bronze Sword"]),
            result(T0 + 28, "y", "store", ok=False, reason="not_carried", data={"item": ASH, "count": 0}),
            call(T0 + 30, "s1", "store", {"item": "Ash Logs"}),
            store_one(T0 + 41.5, "s1", ASH, "Ash Logs", 9, 9, ["9 Ash Logs", "1 Bronze Sword"])]
    assert j.first_deposit(rows, job, T0) == 41.5
    assert j.first_deposit(rows[:3], job, T0) is None


def test_progress_is_carried_more_plus_stored_net(doc):
    job = j.job_of("N1", doc)
    start = j.snapshot(state(carried={ASH: 4}))
    assert j.progress(job, start, None, []) is None
    cur = j.snapshot(state(carried={ASH: 14, STONE: 5}))  # +10 ash, +5 stone of 30
    assert j.progress(job, start, cur, []) == 0.5
    rows = [store_one(T0 + 30, "s1", ASH, "Ash Logs", 14, 14, ["14 Ash Logs"])]
    cur = j.snapshot(state(carried={STONE: 5}))  # the 14 went in: 4 of them carried at the start
    assert j.progress(job, start, cur, rows) == 0.5
    assert j.progress(j.job_of("L1", doc), start, cur, rows) is None  # no item counts: no progress


def test_trigger_kinds_and_alternatives():
    assert j.trigger_due("first_deposit", 10.0, 50.0, None, deposit_t=41.5)
    assert not j.trigger_due("first_deposit", 10.0, 50.0, None, deposit_t=None)
    assert j.trigger_due("progress:0.5", None, 50.0, None, share=0.5)
    assert not j.trigger_due("progress:0.5", 10.0, 50.0, None, share=0.4)
    assert j.trigger_due("first_deposit|progress:0.5", None, 50.0, None, deposit_t=None, share=0.6)
    assert j.trigger_ok("first_deposit|progress:0.5") and j.trigger_ok("at:120") and j.trigger_ok("first_step")
    assert not j.trigger_ok("first_depost") and not j.trigger_ok("progress") and not j.trigger_ok("at:x")


# ------------------------------------------------------------------ whole step trials on the fake body
DEP = "first_deposit|progress:0.5"  # the mechanism these trials test; N1's own trigger is work:4 (window 1118h)


def n1_script(deposit_at=30.0, extra=()):
    rows = model(T0 + 1)
    rows += [call(T0 + 3, "g1", "gather", {"resource": "ash", "count": 9}),
             result(T0 + 20, "g1", "gather", data={"detail": "Got 9 ash (9 asked for; 9 in my bag now)."}),
             call(T0 + 21, "s1", "store", {"item": "Ash Logs", "container": CRATE}),
             store_one(T0 + deposit_at, "s1", ASH, "Ash Logs", 9, 9, ["9 Ash Logs"])]
    return sorted(rows + list(extra), key=lambda r: r["ts"])


def test_i1_goes_in_after_his_first_deposit_and_he_takes_the_job_up_again(doc):
    after = model(T0 + 50) + [call(T0 + 52, "g2", "gather", {"resource": "ash", "count": 11}),
                              result(T0 + 80, "g2", "gather", data={"detail": "Got 11 ash."})]
    io = FakeIO(script=n1_script(extra=after), states=lambda t: state(mine=[CRATE]),
                chests={CRATE: [{"item": ASH, "name": "Ash Logs", "count": 9}]})
    rec = j.run_job(io, j.job_of("N1", doc), {"step": "I1", "interruptions": doc["interruptions"], "confirm_s": 20,
                                              "trigger": DEP})
    intr = rec["interruption"]
    assert intr["took"] and intr["moment"]["first_deposit_s"] == 30.0
    assert intr["moment"]["trigger"] == "first_deposit|progress:0.5" and intr["t_put"] >= 30.0
    assert io.fixtures[0] == ("set_stat", {"stat": "sustenance", "pct": 10.0})
    r = rec["resume"]
    assert r["resumed"] and r["call"]["tool"] == "gather" and not r["new_line"]
    assert r["after_s"] == round(52.0 - intr["t_clear"], 1)
    assert rec["verdict"]["pass"] and rec["item"] == "job: N1 / I1" and io.sent == [doc["jobs"]["N1"]["line"]]
    assert rec["state_start"]["chest_start"][CRATE]["read"]  # the crate read before the line


def test_i4_waits_until_no_call_is_open_so_the_bag_fills_before_the_next_gather(doc):
    # his first deposit lands at 30 s, but a gather is open from 29 s to 47 s: the grant goes in after it ends
    extra = [call(T0 + 29, "g2", "gather", {"resource": "stone"}),
             result(T0 + 47, "g2", "gather", data={"detail": "Got 5 stone."})]
    extra += model(T0 + 60) + [call(T0 + 62, "s2", "store", {"item": "Stone"}),
                               result(T0 + 65, "s2", "store", ok=False, reason="inventory_full")]
    spec = {**doc["interruptions"], "I4": {**doc["interruptions"]["I4"], "needs_new_slot": False}}
    io = FakeIO(script=n1_script(extra=extra), states=lambda t: state(mine=[CRATE]), room=[12, 0])
    rec = j.run_job(io, j.job_of("N1", doc), {"step": "I4", "interruptions": spec, "confirm_s": 10, "trigger": DEP})
    intr = rec["interruption"]
    assert intr["t_put"] >= 47.0 and intr["full_read"]
    assert [v for v, kw in io.fixtures] == ["grant"]
    # the result inventory_full is the bite; no read with room after it: bitten, never cleared, not resumed
    assert intr["took"] and intr["bite"]["t"] == 65.0 and intr["t_clear"] is None and not rec["resume"].get("resumed")


def test_i5_score_reads_the_new_brains_first_work_call(doc):
    after = model(T0 + 70) + [call(T0 + 74, "g2", "gather", {"resource": "stone", "count": 10}),
                              result(T0 + 90, "g2", "gather", data={"detail": "Got 10 stone."})]
    # the new brain's gather moved the job by the game's reads (10 stone on him after it): serves_test
    io = FakeIO(script=n1_script(extra=after), states=lambda t: state(carried={STONE: 10} if t >= T0 + 90 else None,
                                                                      mine=[CRATE]))
    rec = j.run_job(io, j.job_of("N1", doc), {"step": "I5", "interruptions": doc["interruptions"], "confirm_s": 20,
                                              "trigger": DEP})
    assert io.restarts == 1 and rec["interruption"]["took"]
    assert rec["resume"]["resumed"] and rec["resume"]["after_s"] == round(74.0 - rec["interruption"]["t_clear"], 1)
    assert rec["verdict"]["pass"]


def test_no_resumption_within_the_limit_fails_the_step(doc):
    io = FakeIO(script=n1_script(), states=lambda t: state(mine=[CRATE]))
    rec = j.run_job(io, j.job_of("N1", doc), {"step": "I1", "interruptions": doc["interruptions"], "trigger": DEP})
    assert rec["interruption"]["took"] and not rec["resume"].get("resumed") and not rec["verdict"]["pass"]


def test_a_job_done_before_the_interruption_says_nothing(doc):
    # everything in one store at 30 s: the job is done, the interruption never went in
    rows = model(T0 + 1) + [call(T0 + 3, "g1", "gather"), result(T0 + 20, "g1", "gather"),
                            call(T0 + 21, "s1", "store"),
                            store_queue(T0 + 30, "s1", [{"item": ASH, "name": "Ash Logs", "count": 20},
                                                        {"item": STONE, "name": "Stone", "count": 10}],
                                        ["20 Ash Logs", "10 Stone"])]
    full = [{"item": ASH, "name": "Ash Logs", "count": 20}, {"item": STONE, "name": "Stone", "count": 10}]
    io = FakeIO(script=rows, states=lambda t: state(mine=[CRATE]), chests=lambda t, cid: full if t >= T0 + 30 else [])
    rec = j.run_job(io, j.job_of("N1", doc), {"step": "I1", "interruptions": doc["interruptions"], "trigger": DEP})
    assert rec["ended"] == "job done" and not io.fixtures
    assert "done before" in rec["not_counted"] and j.rates([rec], set()) == {}


def test_a_step_from_a_mid_job_checkpoint_is_not_a_head_start(doc):
    """A step trial carries the job's things by design (L1 from job_l1_mid holds hides): counted."""
    after = model(T0 + 50) + [call(T0 + 52, "c1", "craft", {"item": "Leather"}),
                              result(T0 + 60, "c1", "craft", data={"item": "ITEM_Resources_Leather"})]
    script = model(T0 + 1) + [call(T0 + 3, "g1", "gather"), result(T0 + 20, "g1", "gather")] + after
    io = FakeIO(script=script, states=lambda t: state(carried={"ITEM_Resources_Animal_Hide": 6}))
    rec = j.run_job(io, j.job_of("L1", doc), {"step": "I1", "interruptions": doc["interruptions"], "confirm_s": 10})
    assert not rec.get("not_counted") and rec["verdict"]["bars"]["counted"]
    whole = j.run_job(FakeIO(script=script, states=lambda t: state(carried={"ITEM_Resources_Animal_Hide": 6})),
                      j.job_of("L1", doc), {"interruptions": doc["interruptions"], "deadline": 70})
    assert "held at the start" in whole["not_counted"]


# ------------------------------------------------------------------ the command line
def test_cli_trial_takes_an_interrupt_and_checks_the_trigger(monkeypatch, capsys):
    got = {}
    monkeypatch.setattr(j, "cmd_window", lambda a, step: got.update(a=a, step=step) or 0)
    assert j.main(["trial", "--job", "N1", "--interrupt", "I1", "-k", "2"]) == 0
    assert got["step"] == "I1" and got["a"].until == "resumed" and got["a"].k == 2 and got["a"].trigger is None
    assert j.main(["trial", "--job", "N1", "-k", "1"]) == 0 and got["step"] is None and got["a"].until == "done"
    assert j.main(["trial", "--job", "N1", "--interrupt", "I4", "--trigger", "progress:0.3"]) == 0
    assert got["a"].trigger == "progress:0.3"
    assert j.main(["trial", "--job", "N1", "--interrupt", "I1", "--trigger", "after_lunch"]) == 2
    assert "unknown --trigger" in capsys.readouterr().out


def test_cli_trial_with_interrupt_refuses_without_confirm(capsys):
    assert j.main(["trial", "--job", "N1", "--interrupt", "I3", "-k", "1"]) == 2
    assert "pass --confirm" in capsys.readouterr().out
