"""GOAL M5 long horizon on the mock: one open self-directed Brynmoor session (base, chest, a multi-trip mining run,
farm plots, wheat to bread), measured in simulated time like live (brain/mock/sim_session.py; tools/obs_tasks.py
gaps / idle). Luis asked for idle time and the time between subtasks to be logged and optimised."""
import collections

from brain.mock import sim_session as S
from tools import obs_tasks as OT


def test_a_self_directed_session_chains_the_long_tasks_with_short_gaps_and_no_wasted_runs(tmp_path):
    rig, rows = S.run_session(tmp_path)
    t = rig.director.ops.b.tasks[0]
    assert t.status == "done" and t.end_reason == "ended by choice", (t.status, t.end_reason)
    titles = [s.title for s in t.steps if s.status == "done"]
    assert titles.count("store copper in the chest") == 3 and titles[-1] == "bake bread"
    chest = next(iter(rig.game.containers.values()))
    assert chest["ITEM_Resources_CopperOre"] == 60 and rig.game.inventory["ITEM_Consumable_Bread"] >= 1
    m = OT.summary(OT.analyse(rows))
    assert m["gaps"] >= 15 and m["task_gap_p50"] < 0.5 and m["task_gap_p90"] < 3.0, m  # first calls: no model hop
    waits = [r for r in rows if r.get("kind") == "board_wait_start"]
    assert [w["step"] for w in waits] == ["let the wheat grow"]
    ends = {r["step_id"]: r["ts"] for r in rows if r.get("kind") == "board_step_end"}
    waited = ends[waits[0]["step_id"]] - waits[0]["ts"]
    assert 120 <= waited <= 140  # the crop's own growth time: the body is free, no model runs
    assert m["gap_split_s"]["dead_s"] - waited < 2.0 and m["gap_split_s"]["waiting_decision_s"] < 1.0, m
    runs = collections.Counter(r.get("step") for r in rows if r.get("kind") == "board_run")
    assert max(runs.values()) <= 3, runs  # the crop wait is a wait step: no Controller runs while it grows
    assert rig.director.llm.n <= 6 and rig.controller.llm.n <= 25, (rig.director.llm.n, rig.controller.llm.n)


def test_without_wait_steps_the_crop_wait_burns_a_controller_run_every_poll(tmp_path, monkeypatch):
    """The measured cause behind the wait step (before: 58 runs, 99 Haiku calls for the same session)."""
    monkeypatch.setattr(S, "WAIT_STEPS", False)
    rig, rows = S.run_session(tmp_path)
    runs = collections.Counter(r.get("step") for r in rows if r.get("kind") == "board_run")
    assert runs["let the wheat grow"] > 20 and rig.controller.llm.n > 80


def test_without_first_calls_every_step_waits_for_a_controller_turn(tmp_path, monkeypatch):
    """The measured baseline behind first_call: p50 2.0 s (one Haiku turn) per step, 41 Haiku calls."""
    monkeypatch.setattr(S, "FIRST_CALLS", False)
    rig, rows = S.run_session(tmp_path)
    m = OT.summary(OT.analyse(rows))
    assert rig.director.ops.b.tasks[0].status == "done"
    assert m["task_gap_p50"] >= 1.9 and rig.controller.llm.n > 30, (m, rig.controller.llm.n)


def test_a_first_call_goes_through_the_controllers_own_gates(tmp_path):
    from brain.mock.gear_jobs import JobRig
    rig = JobRig(tmp_path, [])
    rec = rig.agent.run_first_call({"tool": "attack", "args": {"target": "Zezima"}}, "Zezima")
    assert rec["ok"] is False and rec["reason"] == "unsafe" and rec.get("refused")  # Luis's safety rule
    rec = rig.agent.run_first_call({"tool": "gather", "args": {"resource": "ash"}}, "Zezima")
    assert rec["ok"] is False and rec["reason"] == "invalid_args"  # the body's own schema (count required)
    assert rig.agent.run_first_call({"tool": "craft_plan", "args": {"item": "Bread"}}, "Zezima").get("skipped")
