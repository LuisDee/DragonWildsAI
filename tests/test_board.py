"""brain/board.py + brain/capability_gaps.py + tools/board.py: the task board's bookkeeping (director.md wave 2).

Covers the review's H1 (immutable / trivial success), H3 + re-check 1 (segments around board runs, taint,
positive tallies, own drops), H5 (zero-gain loops, the task-level progress rule), H10 (prerequisite caps),
M1 (parked tasks don't block), M2 (quarantine, Windows replace retry, exactly-once inbox), M4 (gap claims).
"""
import json
import os

import pytest

from brain import board as B
from brain import predicates as P
from brain.capability_gaps import GapLog
from brain.interface import Reason

COPPER, TIN = "ITEM_Resources_CopperOre", "ITEM_Resources_TinOre"


class Clock:
    def __init__(self, t=1000.0):
        self.t = t

    def __call__(self):
        return self.t


@pytest.fixture
def clock():
    return Clock()


@pytest.fixture
def ops(tmp_path, clock):
    return B.BoardOps(B.BoardStore(tmp_path, clock=clock), clock=clock)


def have(item, n):
    return P.validate({"have": {"item": item, "at_least": n}})


def gained(item, n):
    return P.validate({"gained": {"item": item, "at_least": n}})


def inv(**counts):
    names = {"copper": COPPER, "tin": TIN}
    return {"inventory": {names.get(k, k): v for k, v in counts.items()}}


# ------------------------------------------------------------------ store


def test_round_trip_and_version(tmp_path, ops):
    t = ops.add_task("first job", by="player:Zezima")
    v = ops.b.version
    again = B.BoardStore(tmp_path)
    assert again.board.task(t.id).text == "first job" and again.board.version == v


@pytest.mark.parametrize("content", ["{not json", json.dumps({"v": 99, "tasks": []}), json.dumps({"tasks": "x"})])
def test_bad_or_newer_file_is_quarantined_not_fatal(tmp_path, content):
    (tmp_path / "goals.json").write_text(content, encoding="utf-8")
    store = B.BoardStore(tmp_path)
    assert store.board.tasks == [] and store.quarantined is not None and store.quarantined.exists()
    assert not (tmp_path / "goals.json").exists()


def test_replace_retries_a_windows_permission_error(tmp_path, monkeypatch):
    real, calls = os.replace, {"n": 0}

    def flaky(a, b):
        calls["n"] += 1
        if calls["n"] < 3:
            raise PermissionError("a reader has it open")
        return real(a, b)
    monkeypatch.setattr(B.os, "replace", flaky)
    B._atomic_write(tmp_path / "f.json", "{}", sleep=lambda s: None)
    assert (tmp_path / "f.json").read_text() == "{}" and calls["n"] == 3
    assert not list(tmp_path.glob("*.tmp"))


def test_persistent_save_failure_keeps_the_board_in_memory(tmp_path, monkeypatch, ops):
    monkeypatch.setattr(B, "_atomic_write", lambda *a, **k: (_ for _ in ()).throw(PermissionError("locked")))
    t = ops.add_task("still here", by="cli")
    assert ops.store.save_failed and ops.b.task(t.id) is not None


def test_inbox_is_ingested_exactly_once(tmp_path, clock):
    store = B.BoardStore(tmp_path, clock=clock)
    ops = B.BoardOps(store, clock=clock)
    B.append_inbox(tmp_path, {"op": "add", "text": "job one"})
    B.append_inbox(tmp_path, {"op": "add", "text": "job two", "when": "next"})
    with (tmp_path / "board_inbox.jsonl").open("a", encoding="utf-8") as f:
        f.write('{"op": "add", "text": "half writ')  # a line still being written: not ingested yet
    assert store.ingest_inbox(lambda r: B.apply_inbox_record(ops, r)) == 2
    # a restart (new store over the same files) ingests nothing twice
    store2 = B.BoardStore(tmp_path, clock=clock)
    ops2 = B.BoardOps(store2, clock=clock)
    assert store2.ingest_inbox(lambda r: B.apply_inbox_record(ops2, r)) == 0
    with (tmp_path / "board_inbox.jsonl").open("a", encoding="utf-8") as f:
        f.write('ten"}\n')
    assert store2.ingest_inbox(lambda r: B.apply_inbox_record(ops2, r)) == 1
    assert sorted(t.text for t in store2.board.tasks) == ["half written", "job one", "job two"]


def test_inbox_cancel_and_bad_records(tmp_path, ops):
    t = ops.add_task("to cancel", by="cli")
    B.append_inbox(tmp_path, {"op": "cancel", "id": t.id})
    B.append_inbox(tmp_path, {"op": "explode"})
    assert ops.store.ingest_inbox(lambda r: B.apply_inbox_record(ops, r)) == 1
    assert ops.b.task(t.id).status == "cancelled"


# ------------------------------------------------------------------ tasks and order


def test_now_preempts_the_current_task_which_keeps_its_place(ops):
    a = ops.add_task("a", by="player:Zezima")
    assert ops.pick_current() is a and a.status == "active"
    b = ops.add_task("b", by="player:Zezima", when="now")
    assert ops.b.current == b.id and a.status == "preempted"
    assert [t.text for t in ops.b.tasks] == ["b", "a"]
    c = ops.add_task("c", by="cli", when="next")
    assert [t.text for t in ops.b.tasks] == ["b", "c", "a"]


def test_prerequisites_are_capped_and_never_repeat_a_stuck_one(ops):
    parent = ops.add_task("parent", by="player:Zezima")
    ops.pick_current()
    kid = ops.add_task("upgrade first", by="self", because="under-geared")
    assert kid.parent == parent.id and kid.depth == 1 and ops.b.current == kid.id and parent.status == "preempted"
    grand = ops.add_task("deeper", by="self")
    assert grand.depth == 2
    with pytest.raises(B.BoardError, match="deep"):
        ops.add_task("too deep", by="self")
    ops.end_task(kid, "stuck", "no ore anywhere")
    ops.b.current = parent.id
    with pytest.raises(B.BoardError, match="already stuck"):
        ops.add_task("upgrade first", by="self", parent=parent.id)
    ops.add_task("x1", by="self", parent=parent.id)
    ops.add_task("x2", by="self", parent=parent.id)
    ops.add_task("x3", by="self", parent=parent.id)
    with pytest.raises(B.BoardError, match="open prerequisites"):
        ops.add_task("x4", by="self", parent=parent.id)
    with pytest.raises(B.BoardError, match="parent"):
        B.BoardOps(B.BoardStore(ops.store.dir / "other")).add_task("orphan", by="self")


def test_cancel_cascades_to_prerequisites(ops):
    parent = ops.add_task("parent", by="player:Zezima")
    ops.pick_current()
    kid = ops.add_task("kid", by="self")
    ops.cancel(parent.id, "not needed")
    assert parent.status == kid.status == "cancelled" and ops.b.current is None
    with pytest.raises(B.BoardError):
        ops.cancel(parent.id)


def test_parked_and_help_tasks_do_not_block_the_board(ops):
    a = ops.add_task("a", by="player:Zezima")
    b = ops.add_task("b", by="cli")
    ops.pick_current()
    ops.park(a, "no tin anywhere", question="Do you know where tin is?", player="Zezima")
    assert a.status == "waiting_help" and ops.pick_current() is b
    # the player's answer brings it back first, with the note
    back = ops.resume("there is tin by the lake")
    assert back is a and ops.b.current == a.id and a.status == "active"
    assert a.notes_from_player == ["there is tin by the lake"]


def test_open_tasks_yield_to_queued_specific_ones(ops):
    o = ops.add_task("level what you like", by="player:Zezima", kind="open")
    ops.pick_current()
    s = ops.add_task("specific job", by="cli")
    assert ops.yield_open() and ops.b.current == s.id and o.status == "queued"
    assert not ops.yield_open()


def test_pause_holds_until_resume(ops):
    a = ops.add_task("a", by="player:Zezima")
    ops.pick_current()
    ops.pause("player:Zezima", "wait here")
    assert a.status == "paused" and ops.b.paused and ops.pick_current() is None
    ops.resume()
    assert ops.b.paused is None and ops.pick_current() is a


# ------------------------------------------------------------------ success (review H1)


def test_task_success_is_immutable_except_by_the_player_and_trivial_is_flagged(ops):
    t = ops.add_task("collect", by="player:Zezima")
    assert ops.set_success(t, have(COPPER, 9), "director", state=inv(copper=0))
    assert not t.success["trivial"]
    assert not ops.set_success(t, have(COPPER, 1), "director")  # a weaker test later: refused
    assert t.success["predicate"]["have"]["at_least"] == 9
    assert ops.set_success(t, have(COPPER, 3), "player", state=inv(copper=5))  # the player changed it
    assert t.success["trivial"]  # already true now: stored, flagged


# ------------------------------------------------------------------ segments (H3, re-check 1)


def _step(ops, t, pred, state):
    s = B.Step(title="mine", success=pred)
    ops.set_steps(t, [s])
    ops.activate(s, state)
    return s


def test_only_board_runs_count_for_gained(ops, clock):
    t = ops.add_task("mine copper", by="player:Zezima")
    ops.set_success(t, have(COPPER, 50), "director")
    s = _step(ops, t, gained(COPPER, 5), inv(copper=2))
    ops.open_segment(s, inv(copper=2))
    ops.close_segment(t, s, inv(copper=4))  # the run mined 2
    # between runs Luis hands him 10 ore (a chat command): never counted
    ops.open_segment(s, inv(copper=14))
    ops.close_segment(t, s, inv(copper=15))  # the next run mined 1
    r = P.evaluate(s.success, inv(copper=15), ops.step_ctx(t, s, inv(copper=15)))
    assert r.detail.startswith("Copper Ore +3/") and r.passed is False
    assert t.tallies == {COPPER: 3.0}


def test_a_nested_chat_command_taints_the_items_it_touched(ops):
    """Re-check 1: a chat 'give him ore' during a run_skill step is not the step's work."""
    t = ops.add_task("mine", by="player:Zezima")
    s = _step(ops, t, gained(COPPER, 5), inv(copper=0, tin=0))
    ops.open_segment(s, inv(copper=0, tin=0))
    ops.close_segment(t, s, inv(copper=10, tin=2), tainted={COPPER})  # +10 copper came from the chat command
    assert s.accumulated == {TIN: 2.0} and s.segments[-1].tainted == [COPPER]
    assert P.evaluate(s.success, inv(copper=10, tin=2), ops.step_ctx(t, s, inv(copper=10, tin=2))).passed is False


def test_tallies_count_positive_named_gains_minus_his_own_repicked_drops(ops):
    t = ops.add_task("haul", by="player:Zezima")
    ops.set_success(t, P.validate({"tally": {"item": COPPER, "at_least": 20}}), "director")
    s = _step(ops, t, gained(COPPER, 1), inv(copper=0, tin=0))
    ops.open_segment(s, inv(copper=0, tin=0))
    ops.close_segment(t, s, inv(copper=8, tin=3))  # tin is not named by any predicate
    ops.open_segment(s, inv(copper=8))
    ops.close_segment(t, s, inv(copper=0))  # a deposit: a negative delta never lowers the tally
    ops.note_drop(t, ["w1"], COPPER, 8)
    rp = ops.repicked(t, ["w1", "w9"])
    ops.open_segment(s, inv(copper=0))
    ops.close_segment(t, s, inv(copper=8), repicked=rp)  # picked his own drop back up: not a new gain
    assert t.tallies == {COPPER: 8.0}


def test_skill_xp_accumulates_per_segment(ops):
    t = ops.add_task("train", by="player:Zezima")
    pred = P.validate({"skill_gain": {"name": "Mining", "levels": 1}})
    st = lambda lvl, xp: {"skills": [{"skill": "Mining", "level": lvl, "xp": xp}], "inventory": {}}
    s = _step(ops, t, pred, st(5, 100))
    ops.open_segment(s, st(5, 100))
    ops.close_segment(t, s, st(5, 180))
    r1 = P.evaluate(pred, st(5, 180), ops.step_ctx(t, s, st(5, 180)))
    ops.open_segment(s, st(5, 200))  # +20 xp between runs (not the step's)
    ops.close_segment(t, s, st(6, 260))
    r2 = P.evaluate(pred, st(6, 260), ops.step_ctx(t, s, st(6, 260)))
    assert r1.passed is False and r2.passed is True and "+140 xp" in r2.detail
    assert P.grew(r1.measures, r2.measures)


def test_kills_are_counted_only_inside_segments(ops):
    t = ops.add_task("hunt", by="player:Zezima")
    s = _step(ops, t, P.validate({"killed": {"kind": "rat", "at_least": 2}}), inv())
    ep = {"kind": "combat_end", "target": "Giant Rat", "outcome": "killed"}
    ops.note_kill(s, ep)  # no open segment: a fight between runs
    ops.open_segment(s, inv())
    ops.note_kill(s, ep)
    ops.note_kill(s, ep)
    ops.close_segment(t, s, inv())
    assert P.evaluate(s.success, inv(), ops.step_ctx(t, s, inv())).passed is True and len(s.kills) == 2


# ------------------------------------------------------------------ loops (trips) and caps (H5)


def _loop_task(ops, until):
    t = ops.add_task("trips", by="player:Zezima")
    ops.set_success(t, until, "director")
    steps = [B.Step(title="mine", success=gained(COPPER, 1), group="trip"),
             B.Step(title="deliver", success=P.validate({"lost": {"item": COPPER, "at_least": 1}}), group="trip")]
    ops.set_steps(t, steps, loops={"trip": B.Loop(until=until)})
    return t


def _run_trip(ops, t, gain):
    for s in [x for x in t.steps if x.status == "pending"][:2]:
        ops.activate(s, inv(copper=0))
        ops.open_segment(s, inv(copper=0))
        ops.close_segment(t, s, inv(copper=gain if s.title == "mine" else 0))
        ops.finish_step(t, s, "done")
    return ops.requeue_loop(t, t.steps[-1], inv(copper=0))


def test_loop_requeues_until_the_tally_passes(ops):
    t = _loop_task(ops, P.validate({"tally": {"item": COPPER, "at_least": 20}}))
    assert _run_trip(ops, t, 8) == "requeued" and len(t.pending()) == 2
    assert t.pending()[0].loop_iter == 1
    assert _run_trip(ops, t, 8) == "requeued"
    assert _run_trip(ops, t, 8) == "ended" and t.tallies[COPPER] == 24.0


def test_two_zero_gain_loops_end_the_loop_and_count_as_a_replan(ops):
    t = _loop_task(ops, P.validate({"tally": {"item": COPPER, "at_least": 20}}))
    assert _run_trip(ops, t, 0) == "requeued"
    assert _run_trip(ops, t, 0).startswith("capped:2 loops gained nothing") and t.replans == 1


def test_a_skill_loop_with_growing_xp_is_not_zero_gain(ops):
    until = P.validate({"skill": {"name": "Mining", "at_least": 9}})
    t = ops.add_task("train", by="player:Zezima")
    ops.set_steps(t, [B.Step(title="swing", success=P.validate({"skill_gain": {"name": "Mining", "levels": 1}}),
                             group="g")], loops={"g": B.Loop(until=until)})
    for xp in (100, 200, 300):
        s = t.pending()[0]
        ops.activate(s, {})
        ops.finish_step(t, s, "done")
        out = ops.requeue_loop(t, s, {"skills": [{"skill": "Mining", "level": 5, "xp": xp}]})
        assert out == "requeued"


def test_the_task_progress_rule_trips_after_three_flat_decisions(ops):
    t = ops.add_task("collect", by="player:Zezima")
    ops.set_success(t, have(COPPER, 9), "director")
    assert not ops.record_decision(t, inv(copper=1))  # the first decision sets the reference
    assert not ops.record_decision(t, inv(copper=2))  # progress: reset
    assert not ops.record_decision(t, inv(copper=2))
    assert not ops.record_decision(t, inv(copper=2))
    assert ops.record_decision(t, inv(copper=2))
    assert not ops.record_decision(t, inv(copper=2), new_done=True)  # a newly done step counts as progress


def test_set_steps_keeps_history_and_a_review_keeps_the_active_step(ops):
    t = ops.add_task("x", by="cli")
    a, b = B.Step(title="a", success=have(COPPER, 1)), B.Step(title="b", success=have(COPPER, 2))
    ops.set_steps(t, [a, b])
    ops.activate(a, inv())
    ops.set_steps(t, [B.Step(title="c", success=have(COPPER, 3))], replace_active=False)
    assert [s.title for s in t.steps] == ["a", "c"] and a.status == "active"
    ops.set_steps(t, [B.Step(title="d", success=have(COPPER, 4))])
    assert [(s.title, s.status) for s in t.steps] == [("a", "dropped"), ("d", "pending")]


def test_brief_shows_done_when_progress_step_and_collected(ops):
    t = ops.add_task("haul copper", by="player:Zezima")
    ops.pick_current()
    ops.set_success(t, P.validate({"tally": {"item": COPPER, "at_least": 20}}), "director", state=inv())
    s = _step(ops, t, gained(COPPER, 5), inv(copper=0))
    ops.open_segment(s, inv(copper=0))
    ops.close_segment(t, s, inv(copper=3))
    row = ops.brief(inv(copper=3))["tasks"][0]
    assert row["done_when"] == "collect 20 Copper Ore in total"
    assert row["progress"] == "Copper Ore total 3/20" and row["step"] == "mine"
    assert row["step_progress"].startswith("Copper Ore +3/5") and row["collected"] == {COPPER: 3.0}


# ------------------------------------------------------------------ the hourly window


def test_hourly_window_slides_and_persists(tmp_path, clock):
    store = B.BoardStore(tmp_path, clock=clock)
    w = B.HourlyWindow(store, per_hour=3, clock=clock)
    w.spend(2)
    clock.t += 1000
    w.spend()
    assert not w.allows() and w.wait_s() == pytest.approx(2600)
    w2 = B.HourlyWindow(B.BoardStore(tmp_path, clock=clock), per_hour=3, clock=clock)  # a restart keeps it
    assert w2.left() == 0
    clock.t += 2601
    assert w2.allows() and w2.left() == 2


# ------------------------------------------------------------------ capability gaps (M4)


def test_gap_log_sources_and_claims(tmp_path, clock):
    g = GapLog(tmp_path / "gaps.json", tools={"gather", "go_to"}, clock=clock)
    r = g.from_tool_result("deposit", {"ok": False, "reason": Reason.NOT_IMPLEMENTED, "data": {}}, task="t1")
    assert r["count"] == 1 and r["new_for_task"]
    assert g.from_tool_result("deposit", {"ok": False, "reason": Reason.NOT_IMPLEMENTED, "data": {}},
                              task="t1")["new_for_task"] is False  # told once per task
    assert g.from_tool_result("run_skill", {"ok": False, "reason": Reason.UNKNOWN_SKILL, "data": {}}) is None
    claim = g.record("gather", source="director", task="t1", why="needs to mine")
    assert claim["tool_exists"] and not claim["new_for_task"] and g.gaps["gather"]["count"] == 0
    perc = g.from_uncheckable(["quests", "baseline", "clock"], task="t2")
    assert [x["primitive"] for x in perc] == ["perceive:quests"]
    g.seed(missing={"pickup": "not implemented"}, debug_tools=["equip"],
           known=[("travel:long_distance", "action", "go_to times out after 120 s")])
    g.seed(missing={"pickup": "not implemented"})  # restarts don't inflate counts
    again = GapLog(tmp_path / "gaps.json")
    assert again.gaps["equip"]["count"] == 0 and "seed" in again.gaps["equip"]["sources"]
    assert again.rows()[0]["primitive"] == "deposit"


# ------------------------------------------------------------------ CLI


def test_cli_add_list_cancel_gaps(tmp_path, monkeypatch, capsys):
    from tools import board as cli
    monkeypatch.setenv("DW_STATE_DIR", str(tmp_path))
    world = tmp_path / "worlds" / "dev"
    world.mkdir(parents=True)
    assert cli.main(["add", "some job", "--world", "dev"]) == 0
    ops = B.BoardOps(B.BoardStore(world))
    ops.store.ingest_inbox(lambda r: B.apply_inbox_record(ops, r))
    tid = ops.b.tasks[0].id
    capsys.readouterr()
    assert cli.main(["list", "--world", "dev", "--json"]) == 0
    out = json.loads(capsys.readouterr().out)
    assert out["tasks"][0]["task"] == "some job" and out["tasks"][0]["by"] == "cli"
    cli.main(["cancel", tid, "--world", "dev"])
    ops.store.ingest_inbox(lambda r: B.apply_inbox_record(ops, r))
    assert ops.b.task(tid).status == "cancelled"
    GapLog(tmp_path / "capability_gaps.json").record("deposit", task="x")
    capsys.readouterr()
    assert cli.main(["gaps", "--json"]) == 0
    assert json.loads(capsys.readouterr().out)[0]["primitive"] == "deposit"
