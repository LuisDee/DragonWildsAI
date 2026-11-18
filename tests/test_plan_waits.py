"""tools/plan_waits.py on fixture logs: the sync rows as brain-live-20261118-082528-29060 writes them (a planner prompt,
research llm_responses, the `plan` row), the async rows as brain/agent.py _plan_in_background writes them
(commit 8185af0: plan_started, the worker's planner rows in the goal's episode, acted_while_planning, plan_arrived)."""
from __future__ import annotations

import json
import os
import time

from tools import plan_waits as W

EP = "chat-0001-636c"
T0 = 1794986740.0


def row(dt: float, kind: str, ep: str | None = EP, **kw) -> dict:
    return {"ts": T0 + dt, "kind": kind, **kw, "episode_id": ep}


def call(dt: float, tool: str, tid: str, ep: str = EP, read_only: bool = False) -> dict:
    return row(dt, "tool_call", ep, tool=tool, task_id=tid, read_only=read_only, args={})


def result(dt: float, tool: str, tid: str, ep: str = EP) -> dict:
    return row(dt, "tool_result", ep, tool=tool, task_id=tid, result={"ok": True})


def heard(dt: float, player: str = "Tester") -> dict:
    return row(dt, "event", event={"type": "chat_heard", "player": player, "text": "claude, thirty copper"})


def A(rows: list[dict], source: str = "s") -> dict:
    """The rows as read_rows gives them (W.slim of each raw row)."""
    return W.analyse([s for r in rows if (s := W.slim(r)) is not None], source)


START = [row(-10, "session_start", None, name="Claude"), heard(0)]

SYNC = START + [
    row(4.3, "request_state", ended="talk_only"),
    row(4.88, "prompt", component="planner", messages=[{"role": "user", "content": "goal"}]),
    row(7.17, "llm_response", component="planner"),
    row(9.24, "llm_response", component="planner"),
    row(21.74, "llm_response", component="planner"),
    row(21.74, "plan", component="planner", mode="plan"),
    call(22.5, "look", None, read_only=True),          # a read is not a body call
    call(23.0, "gather", "t1"), result(40.0, "gather", "t1"),
    # a replan: the failed step in the request; a command left running from before covers 3 s of the wait
    row(41.0, "prompt", component="planner", messages=[{"role": "user", "content": {"failed_task": {"skill": "gather"}}}]),
    row(41.5, "action_left_running", id="x1", tool="gather"),
    row(44.5, "bridge_late_result", id="x1", tool="gather"),
    row(50.0, "llm_response", component="planner"),
    row(50.0, "plan", component="planner", mode="replan"),
    call(52.0, "craft", "t2"), result(55.0, "craft", "t2"),
]


def test_sync_wait_is_request_to_first_body_call_minus_body_running():
    res = A(SYNC, "s")
    assert not res["async_session"]
    p1, p2 = res["plans"]
    assert (p1["mode"], p1["kind"], p1["outcome"]) == ("sync", "plan", "plan")
    assert p1["planner_s"] == 16.86
    assert p1["body_wait_s"] == 18.12 and p1["over_5s"] and p1["wait_ended_by"] == "body"
    assert p1["first_body_call"]["tool"] == "gather" and p1["body_calls"] == 0
    assert (p2["kind"], p2["planner_s"]) == ("replan", 9.0)
    assert p2["body_wait_s"] == 8.0            # 11 s to the craft, 3 s of it the left-running gather
    assert p2["body_during_s"] == 3.0


def test_sync_without_plan_row_ends_at_last_planner_response():
    rows = START + [row(1, "prompt", component="planner"), row(6, "llm_response", component="planner"),
                    row(6.2, "say", text="on it"), call(7, "gather", "t1"), result(9, "gather", "t1")]
    (p,) = A(rows, "s")["plans"]
    assert p["planner_s"] == 5.0 and p["body_wait_s"] == 6.0 and p["outcome"] == "plan"


ASYNC = START + [
    row(4.95, "prompt", component="planner"),          # the worker logged its prompt before plan_started (race)
    row(5.0, "plan_started", composer="planner", plan_kind="plan", goal="thirty copper"),
    row(5.1, "prompt", component="controller"),
    row(7.0, "llm_response", component="controller"),
    call(8.0, "gather", "t1"),                          # his act while the plan is made
    row(9.0, "llm_response", component="planner"),
    result(14.0, "gather", "t1"),
    row(20.0, "llm_response", component="planner"),
    row(20.0, "plan", component="planner", mode="plan"),
    row(20.3, "acted_while_planning", n=1, tools=["gather"], n_before_start=0, plan_kind="plan"),
    row(20.4, "plan_arrived", plan_kind="plan", age_s=15.4, composed_s=15.0, stale=False, ok=True, applied=True),
    call(20.6, "gather", "t2"), result(30.0, "gather", "t2"),
]


def test_async_plan_counts_his_acts_and_the_worker_rows_are_its_own():
    res = A(ASYNC, "a")
    assert res["async_session"]
    (p,) = res["plans"]                                 # the worker's planner prompt is not a second, sync plan
    assert (p["mode"], p["kind"], p["outcome"]) == ("async", "plan", "plan")
    assert p["planner_s"] == 15.0
    assert p["body_wait_s"] == 3.0 and p["over_5s"] is False
    assert p["body_calls"] == 1 and p["acted_logged"] == 1 and p["body_during_s"] == 6.0


def test_async_abandoned_and_stale_outcomes():
    rows = START + [row(1, "plan_started", plan_kind="replan"), row(3, "plan_abandoned", plan_kind="replan", age_s=2.0),
                    row(4, "plan_started", plan_kind="plan"),
                    row(9, "plan_arrived", plan_kind="plan", composed_s=4.5, stale=True, ok=True, applied=False),
                    call(12, "go_to", "t1"), result(13, "go_to", "t1")]
    a, b = A(rows, "a")["plans"]
    assert (a["kind"], a["outcome"], a["planner_s"]) == ("replan", "abandoned", 2.0)
    assert (b["outcome"], b["planner_s"], b["body_wait_s"]) == ("stale", 4.5, 8.0)


def test_wait_cut_at_players_line_after_landing_and_none_without_either():
    rows = START + [row(1, "prompt", component="planner"), row(4, "llm_response", component="planner"),
                    row(4, "plan", component="planner", mode="plan"), row(4.1, "plan_question"),
                    heard(30), call(33, "gather", "t1"), result(34, "gather", "t1"),
                    row(40, "prompt", component="planner"), row(45, "llm_response", component="planner"),
                    row(45, "plan", component="planner", mode="plan")]
    a, b = A(rows, "s")["plans"]
    assert a["asked_player"] and a["wait_ended_by"] == "player" and a["body_wait_s"] == 29.0
    assert b["body_wait_s"] is None and b["over_5s"] is None
    s = W.side([a, b])
    assert (s["plans"], s["known"], s["over_5s"], s["ended_by_player"]) == (2, 1, 1, 1)


def test_vitals_policy_and_reads_are_not_body_calls():
    rows = START + [row(1, "prompt", component="planner"), row(3, "plan", component="planner", mode="plan"),
                    call(3.5, "set_vitals_policy", "v1"), result(3.6, "set_vitals_policy", "v1"),
                    call(4, "craft_plan", None, read_only=True), call(6, "gather", "t1"), result(8, "gather", "t1")]
    (p,) = A(rows, "s")["plans"]
    assert p["body_wait_s"] == 5.0 and p["over_5s"] is False and p["first_body_call"]["tool"] == "gather"


def _write(path, rows):
    path.write_text("\n".join(json.dumps(r) for r in rows) + "\n", encoding="utf-8")
    old = time.time() - 3600
    os.utime(path, (old, old))


def test_report_from_files_splits_sides_and_windows(tmp_path):
    _write(tmp_path / "brain-live-20261118-082528-29060.jsonl",
           SYNC + [{"ts": T0, "kind": "bridge_recv", "msg": {"data": {}}, "episode_id": None}])
    _write(tmp_path / "brain-live-20261118-090126-27620.jsonl", ASYNC)
    ev = tmp_path / "evals"
    ev.mkdir()
    (ev / "job_runs.jsonl").write_text(
        json.dumps({"run": "R1", "item": "job: L2 / V1", "brain_logs": ["brain-live-20261118-082528-29060.jsonl"]}) + "\n"
        + json.dumps({"run": "R2", "item": "job: N1", "brain_logs": ["brain-live-20261118-090126-27620.jsonl"]}) + "\n",
        encoding="utf-8")
    (ev / "job_windows.jsonl").write_text(json.dumps({"window": "20261118-071019", "trials": [{"run": "R1"}]}) + "\n",
                                          encoding="utf-8")
    agg = W.aggregate(W.run(W.parse_when("2026-11-18"), None, tmp_path), W.window_map(ev))
    assert agg["sessions"] == 2 and agg["async_sessions"] == 1
    assert (agg["sides"]["sync"]["plans"], agg["sides"]["sync"]["over_5s"]) == (2, 2)
    assert (agg["sides"]["async"]["plans"], agg["sides"]["async"]["over_5s"]) == (1, 0)
    wins = {(w["window"], w["mode"]): w for w in agg["windows"]}
    assert wins[("20261118-071019", "sync")]["item"] == "job: L2 / V1"
    assert wins[("-", "async")]["item"] == "job: N1"     # a run with no window record still names its item
    assert "async" in W.render(agg, listing=True)
    # --since after both: nothing
    assert W.run(W.parse_when("2026-11-19"), None, tmp_path) == []
