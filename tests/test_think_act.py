"""tools/think_act.py: the think-and-act measures, on short samples cut from real brain-live rows.

Samples: SAMPLE_PLAN_FIRST is brain-live-20261115-235756-19752 (the house ask; the Planner composed before any act),
cut to its first 28 s with big payloads removed. The Director rows follow brain-live-20261102-023341-8528.
"""
from __future__ import annotations

import json
import os
import time

import pytest

from tools import think_act as T

EP = "chat-0001-52b5"
SAMPLE_PLAN_FIRST = r'''
{"ts": 1794783476.898, "kind": "bridge_send", "msg": {"type": "cmd", "id": "8fef977e00ec", "tool": "get_state"}, "episode_id": null}
{"ts": 1794783477.445, "kind": "bridge_recv", "msg": {"ok": true, "type": "result", "id": "8fef977e00ec", "data": {"position": [123.7, 1932.25, -30.12], "dead": false, "inventory": {"ITEM_Ammo_Bolts_Bone": 2, "ITEM_Resources_Wood_Ash": 2}}}, "episode_id": null}
{"ts": 1794783477.448, "kind": "bridge_send", "msg": {"type": "cmd", "id": "530f662a9011", "tool": "world_info"}, "episode_id": null}
{"ts": 1794783477.564, "kind": "bridge_recv", "msg": {"ok": false, "type": "result", "id": "530f662a9011", "data": {"position": [0, 0, 0], "inventory": {}}}, "episode_id": null}
{"ts": 1794783478.735, "kind": "session_start", "name": "Claude", "planner_model": "anthropic/claude-sonnet-5-5", "controller_model": "anthropic/claude-haiku-5-5"}
{"ts": 1794783484.914, "kind": "event", "event": {"type": "chat_heard", "player": "Tester", "text": "claude, tear down my house here, then build yourself a house"}, "episode_id": "chat-0001-52b5"}
{"ts": 1794783484.915, "kind": "chat_decision", "player": "Tester", "decision": "addressed", "reason": "named or prefixed", "episode_id": "chat-0001-52b5"}
{"ts": 1794783484.915, "kind": "bridge_send", "msg": {"type": "cmd", "id": "62d980ee14ba", "tool": "get_state"}, "episode_id": "chat-0001-52b5"}
{"ts": 1794783485.3, "kind": "bridge_recv", "msg": {"ok": true, "type": "result", "id": "62d980ee14ba", "data": {"position": [123.7, 1932.25, -30.12], "dead": false, "inventory": {"ITEM_Ammo_Bolts_Bone": 2, "ITEM_Resources_Wood_Ash": 2}}}, "episode_id": "chat-0001-52b5"}
{"ts": 1794783485.93, "kind": "prompt", "component": "controller", "model": "anthropic/claude-haiku-5-5", "step": 0, "effort": "low", "messages": [{"role": "system", "content": "long"}], "episode_id": "chat-0001-52b5"}
{"ts": 1794783488.512, "kind": "llm_response", "component": "controller", "step": 0, "usage": {"prompt": 18494, "completion": 427, "cached": 14036, "latency_ms": 2578, "cost_usd": 0.000911}, "finish_reason": "tool_calls", "episode_id": "chat-0001-52b5"}
{"ts": 1794783488.515, "kind": "say", "text": "on it, tearing yours down first then I'll build mine", "voice": "reply", "episode_id": "chat-0001-52b5"}
{"ts": 1794783489.127, "kind": "say_result", "ok": true, "reason": null, "episode_id": "chat-0001-52b5"}
{"ts": 1794783489.15, "kind": "request_state", "ended": "talk_only", "episode_id": "chat-0001-52b5"}
{"ts": 1794783489.152, "kind": "bridge_send", "msg": {"type": "cmd", "id": "4129234624f1", "tool": "get_state"}, "episode_id": "chat-0001-52b5"}
{"ts": 1794783489.514, "kind": "bridge_recv", "msg": {"ok": true, "type": "result", "id": "4129234624f1", "data": {"position": [123.7, 1932.25, -30.12], "dead": false, "inventory": {"ITEM_Ammo_Bolts_Bone": 2, "ITEM_Resources_Wood_Ash": 2}}}, "episode_id": "chat-0001-52b5"}
{"ts": 1794783489.538, "kind": "prompt", "component": "planner", "model": "anthropic/claude-sonnet-5-5", "episode_id": "chat-0001-52b5"}
{"ts": 1794783503.296, "kind": "llm_response", "component": "planner", "model": "anthropic/claude-sonnet-5-5", "usage": {"prompt": 14320, "completion": 2096, "cached": 0, "latency_ms": 13750, "cost_usd": 0.056758}, "episode_id": "chat-0001-52b5"}
{"ts": 1794783503.301, "kind": "plan_invalid", "error": "trailing characters", "round": 0, "episode_id": "chat-0001-52b5"}
{"ts": 1794783512.224, "kind": "llm_response", "component": "planner", "model": "anthropic/claude-sonnet-5-5", "usage": {"prompt": 15756, "completion": 1308, "cached": 14316, "latency_ms": 8922, "cost_usd": 0.0181096}, "episode_id": "chat-0001-52b5"}
{"ts": 1794783512.261, "kind": "bridge_send", "msg": {"type": "cmd", "id": "73d3a0d56d58", "tool": "get_state"}, "episode_id": "chat-0001-52b5"}
{"ts": 1794783512.742, "kind": "bridge_recv", "msg": {"ok": true, "type": "result", "id": "73d3a0d56d58", "data": {"position": [123.7, 1932.25, -30.12], "dead": false, "inventory": {"ITEM_Ammo_Bolts_Bone": 2, "ITEM_Resources_Wood_Ash": 2}}}, "episode_id": "chat-0001-52b5"}
{"ts": 1794783512.758, "kind": "tool_call", "task_id": "5012566b", "tool": "deconstruct", "args": {"target": "BuildingPiece_282", "whole": true}, "attempt": 1, "episode_id": "chat-0001-52b5"}
{"ts": 1794783512.765, "kind": "bridge_send", "msg": {"type": "cmd", "id": "3428d846b026", "tool": "deconstruct"}, "episode_id": "chat-0001-52b5"}
{"ts": 1794783581.0, "kind": "tool_result", "task_id": "5012566b", "tool": "deconstruct", "result": {"ok": true, "reason": null, "data": {"detail": "Took down 11 pieces"}}, "episode_id": "chat-0001-52b5"}
'''
T0 = 1794783484.914


def _rows_from(text: str, tmp_path) -> list[dict]:
    p = tmp_path / "brain-live-20261115-235756-19752.jsonl"
    p.write_text(text.strip() + "\n", encoding="utf-8")
    return list(T.read_rows(p))


def _row(ts, kind, ep=EP, **kw) -> dict:
    return {"ts": ts, "kind": kind, "ep": ep, **kw}


# ------------------------------------------------------------------ reading
def test_read_rows_keeps_state_reads_only_for_get_state_and_drops_payloads(tmp_path):
    rows = _rows_from(SAMPLE_PLAN_FIRST, tmp_path)
    states = [r for r in rows if r["kind"] == "state"]
    assert len(states) == 4                                     # the world_info reply is not a state read
    assert states[0]["pos"] == [123.7, 1932.25, -30.12] and states[0]["inv"]["ITEM_Resources_Wood_Ash"] == 2
    assert not any(r["kind"] in ("bridge_send", "bridge_recv") for r in rows)
    prompt = next(r for r in rows if r["kind"] == "prompt")
    assert "messages" not in prompt and prompt["component"] == "controller"


# ------------------------------------------------------------------ the four measures on the house ask
def test_plan_first_ask_measures(tmp_path):
    res = T.analyse(_rows_from(SAMPLE_PLAN_FIRST, tmp_path), "20261115-235756-19752")
    (a,) = res["asks"]
    assert a["id"] == "20261115-235756-19752/chat-0001-52b5" and a["player"] == "Tester"
    assert a["first_act_s"] == pytest.approx(27.84, abs=0.01) and a["first_act"] == "deconstruct"
    assert a["first_say_s"] == pytest.approx(3.6, abs=0.01)                 # a line said is not an act
    assert a["planner"] and not a["act_before_plan"]
    (c,) = res["compositions"]
    assert c["kind"] == "planner" and c["outcome"] == "plan" and len(c["calls"]) == 2   # the repair is one composition
    assert c["secs"] == pytest.approx(22.69, abs=0.01) and c["stand"] == pytest.approx(22.69, abs=0.01)
    assert c["usd"] == pytest.approx(0.07487, abs=1e-5)
    assert a["stand_plan_s"] == pytest.approx(22.69, abs=0.01)
    assert a["planner_calls"] == 2 and a["controller_calls"] == 1
    assert a["planner_tokens"]["completion"] == 2096 + 1308
    assert c["basis_known"] and c["stale"] == []                            # nothing moved while he stood
    assert c["next"]["tool"] == "deconstruct" and c["next"]["after_s"] == pytest.approx(0.53, abs=0.01)
    sh = a["share"]
    assert sum(sh.values()) == pytest.approx(a["window_s"], abs=0.2)
    assert sh["planner"] == pytest.approx(22.69, abs=0.05) and sh["body_and_planner"] == 0


def test_llm_start_is_derived_from_latency_and_falls_back_to_the_prompt_row():
    rows = [_row(10.0, "prompt", component="controller"),
            _row(13.0, "llm_response", component="controller", usage={"latency_ms": 2500}),
            _row(20.0, "prompt", component="controller"),
            _row(24.0, "llm_response", component="controller", usage={})]
    res = T.analyse(rows)
    starts = [c["start"] for c in res["controller_api"]]
    assert starts == [pytest.approx(10.5), pytest.approx(20.0)]
    assert [c["derived"] for c in res["controller_api"]] == [True, False]


def test_a_replan_is_told_from_a_plan_by_its_failed_step():
    gs: set = set()
    plan = T.slim({"ts": 1.0, "kind": "prompt", "component": "planner",
                   "messages": [{"role": "system", "content": "x"}, {"role": "user", "content": '{"goal": "g"}'}]}, gs)
    replan = T.slim({"ts": 2.0, "kind": "prompt", "component": "planner",
                     "messages": [{"role": "user", "content": '{"goal": "g", "failed_task": {"skill": "build"}}'}]}, gs)
    assert plan["replan"] is False and replan["replan"] is True
    rows = [{**replan, "ep": EP}, _row(5.0, "llm_response", component="planner", usage={"latency_ms": 3000}),
            _row(5.5, "tool_call", tool="go_to", task_id="t", args={})]
    (c,) = T.analyse(rows)["compositions"]
    assert c["decision"] == "replan" and c["outcome"] == "plan"


# ------------------------------------------------------------------ asks
def _heard(ts, ep, text="claude chop logs", player="Tester", decision="addressed"):
    return [_row(ts, "event", ep, type="chat_heard", player=player, text=text),
            _row(ts, "chat_decision", ep, decision=decision),
            _row(ts + 0.5, "prompt", ep, component="controller"),
            _row(ts + 2.0, "llm_response", ep, component="controller", usage={"latency_ms": 1500, "cost_usd": 0.001})]


def test_controller_acts_first_then_a_goal_is_planned_quest_style():
    """The quest shape of 15 to 17 Nov: go_to at once, start_goal later, the Planner in line, then the plan's act."""
    rows = [*_heard(100.0, "chat-0001-aaaa", "claude, go and see Zanik and do her quest"),
            _row(102.3, "tool_call", "chat-0001-aaaa", tool="go_to", task_id="t1", args={"target": "Zanik"}),
            _row(130.0, "tool_result", "chat-0001-aaaa", tool="go_to", task_id="t1", ok=True),
            _row(131.0, "prompt", "chat-0001-aaaa", component="controller"),
            _row(133.0, "llm_response", "chat-0001-aaaa", component="controller", usage={"latency_ms": 2000}),
            _row(134.0, "prompt", "chat-0001-aaaa", component="planner"),
            _row(139.0, "llm_response", "chat-0001-aaaa", component="planner", usage={"latency_ms": 5000, "cost_usd": 0.04}),
            _row(139.5, "tool_call", "chat-0001-aaaa", tool="gather", task_id="t2", args={"resource": "ash", "count": 5}),
            _row(160.0, "tool_result", "chat-0001-aaaa", tool="gather", task_id="t2", ok=True)]
    (a,) = T.analyse(rows)["asks"]
    assert a["first_act_s"] == pytest.approx(2.3) and a["act_before_plan"]
    assert a["first_act_after_plan_s"] == pytest.approx(39.5)
    assert a["stand_plan_s"] == pytest.approx(5.0)
    (c,) = T.analyse(rows)["compositions"]
    assert c["idle_before_s"] == pytest.approx(4.0) and c["gap_s"] == pytest.approx(9.5)
    assert a["share"]["controller"] == pytest.approx(1.5 + 2.0) and a["share"]["planner"] == pytest.approx(5.0)


def test_ignored_lines_and_own_lines_are_not_asks_and_a_new_ask_ends_the_window():
    rows = [*_heard(10.0, "chat-0001-a", "nice weather", decision="ignored"),
            *_heard(20.0, "chat-0002-b", "claude chop 5 logs"),
            _row(22.5, "tool_call", "chat-0002-b", tool="gather", task_id="g", args={}),
            _row(40.0, "tool_result", "chat-0002-b", tool="gather", task_id="g", ok=True),
            *_heard(50.0, "chat-0003-c", "claude come here"),
            _row(51.0, "event", "chat-0004-d", type="chat_heard", player="Claude", text="me"),
            _row(51.0, "session_start", None, name="Claude")]
    asks = T.analyse(rows)["asks"]
    assert [a["id"] for a in asks] == ["chat-0002-b", "chat-0003-c"]
    assert asks[0]["window_s"] == pytest.approx(30.0)        # to the next ask, not past it
    assert asks[1]["first_act_s"] is None                    # a talk-only ask has no act


def test_set_vitals_policy_is_not_an_act_and_a_situation_runs_act_is_not_the_asks():
    rows = [*_heard(0.0, "chat-0001-x"),
            _row(2.5, "tool_call", "chat-0001-x", tool="set_vitals_policy", task_id="v", args={}),
            _row(2.6, "tool_result", "chat-0001-x", tool="set_vitals_policy", task_id="v", ok=True),
            _row(3.0, "tool_call", "situation-0002-y", tool="consume", task_id="c", args={"item": "Fillet"}),
            _row(3.5, "tool_result", "situation-0002-y", tool="consume", task_id="c", ok=True),
            _row(9.0, "tool_call", "chat-0001-x", tool="gather", task_id="g", args={}),
            _row(20.0, "tool_result", "chat-0001-x", tool="gather", task_id="g", ok=True)]
    (a,) = T.analyse(rows)["asks"]
    assert a["first_act_s"] == pytest.approx(9.0) and a["first_act"] == "gather"


# ------------------------------------------------------------------ the Director (2 Nov runs)
def test_director_composition_runs_from_dispatch_to_decision_and_board_acts_count():
    rows = [*_heard(0.0, "chat-0001-dbcb", "claude get all your stuff together and gear up properly"),
            _row(5.0, "tool_call", "chat-0001-dbcb", tool="consume", task_id="c1", args={"item": "Fillet"}),
            _row(5.4, "tool_result", "chat-0001-dbcb", tool="consume", task_id="c1", ok=True),
            _row(103.3, "director_dispatch", None, task="786fbd23", decision="plan"),
            _row(103.3, "prompt", "director-0002-3e", component="director"),
            _row(105.8, "llm_response", "director-0002-3e", component="director", usage={"latency_ms": 2468, "cost_usd": 0.03}),
            _row(146.3, "llm_response", "director-0002-3e", component="director", usage={"latency_ms": 27734, "cost_usd": 0.05}),
            _row(146.4, "director_decision", None, task="786fbd23", decision="plan"),
            _row(147.2, "tool_call", "board-0003-be6d", tool="gather", task_id="g1", args={"resource": "ash", "count": 16}),
            _row(257.6, "tool_result", "board-0003-be6d", tool="gather", task_id="g1", ok=True)]
    res = T.analyse(rows)
    (c,) = res["compositions"]
    assert c["kind"] == "director" and c["outcome"] == "plan" and len(c["calls"]) == 2
    assert c["secs"] == pytest.approx(43.1) and c["stand"] == pytest.approx(43.1)
    assert c["next"]["tool"] == "gather"
    (a,) = res["asks"]
    assert a["planner"] and a["act_before_plan"] and a["first_act_after_plan_s"] == pytest.approx(147.2)
    assert a["window_s"] == pytest.approx(257.6) and a["planner_usd"] == pytest.approx(0.08)


def test_a_command_left_running_and_a_reflex_fight_count_as_body_work():
    rows = [*_heard(0.0, "chat-0001-z"),
            _row(3.0, "tool_call", "chat-0001-z", tool="go_to", task_id="m", args={}),
            _row(5.0, "tool_result", "chat-0001-z", tool="go_to", task_id="m", ok=False),
            _row(5.0, "action_left_running", "chat-0001-z", id="b1", tool="go_to"),
            _row(6.0, "prompt", "chat-0001-z", component="planner"),
            _row(12.0, "llm_response", "chat-0001-z", component="planner", usage={"latency_ms": 6000}),
            _row(9.0, "bridge_late_result", "chat-0001-z", id="b1", tool="go_to"),
            _row(10.0, "event", None, type="activity", what="combat_started", ets=10.0),
            _row(11.0, "event", None, type="activity", what="combat_end", ets=11.0),
            _row(12.5, "tool_call", "chat-0001-z", tool="gather", task_id="g", args={}),
            _row(14.0, "tool_result", "chat-0001-z", tool="gather", task_id="g", ok=True)]
    res = T.analyse(rows)
    (c,) = res["compositions"]
    assert c["body_during"] == pytest.approx(4.0)            # 6 to 9 left running, 10 to 11 the fight
    assert c["stand"] == pytest.approx(2.0)
    assert "fight" in c["stale"]
    assert res["asks"][0]["share"]["body_and_planner"] == pytest.approx(4.0)


# ------------------------------------------------------------------ the stale rule
def _st(ts, pos=(0, 0, 0), inv=None, fight=False, dead=False):
    return {"ts": ts, "kind": "state", "pos": list(pos), "inv": inv or {"ITEM_Ore_Copper": 3}, "fight": fight, "dead": dead}


def test_stale_reasons():
    comp = {"start": 10.0, "end": 20.0}
    base = _st(9.0)
    assert T.stale_reasons(comp, base, _st(21.0), [], None) == []
    assert T.stale_reasons(comp, base, _st(21.0, pos=(25, 0, 0)), [], None) == ["moved"]
    assert T.stale_reasons(comp, base, _st(21.0, pos=(15, 0, 0)), [], None) == []          # 15 m is not 20
    assert T.stale_reasons(comp, base, _st(21.0, inv={"ITEM_Ore_Copper": 4}), [], None) == ["bag"]
    assert T.stale_reasons(comp, base, _st(21.0, inv={"ITEM_Ore_Copper": 3, "ITEM_Consumable_Water_Clean": 1}),
                           [], None) == ["bag_minor"]                                          # the reflex drank
    assert T.stale_reasons(comp, base, _st(21.0, fight=True), [], None) == ["fight"]
    assert T.stale_reasons(comp, base, _st(21.0), [15.0], None) == ["fight"]
    assert T.stale_reasons(comp, base, _st(21.0, dead=True), [], None) == ["died"]
    assert T.stale_reasons(comp, base, _st(21.0), [], {"tool": "explore", "reason": "already_in_sight"}) == ["first_done"]
    assert T.stale_reasons(comp, base, _st(21.0, pos=(1, 1, 0)), [],
                           {"tool": "go_to", "args": {"target": [2.0, 2.0, 0.0]}}) == ["first_done"]
    assert T.stale_reasons(comp, None, None, [], None) == []                                  # unknown is not stale


# ------------------------------------------------------------------ intervals and statistics
def test_union_overlap_and_exclusive_shares():
    assert T.union([(0, 2), (1, 3), (5, 6), (6, 6)]) == [(0, 3), (5, 6)]
    assert T.overlap(1, 5.5, [(0, 3), (5, 6)]) == pytest.approx(2.5)
    sh = T.shares(0, 10, body=[(0, 4)], controller=[(3, 6)], planner=[(2, 8)], learner=[])
    assert sh == {"body_and_planner": 2.0, "body": 2.0, "controller": 2.0, "planner": 2.0, "learner": 0.0,
                  "nothing": 2.0}


def test_summ_and_trials_needed():
    s = T.summ([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, None])
    assert (s["n"], s["median"], s["p90"], s["worst"]) == (10, 5.5, 9.0, 10.0)
    assert T.summ([])["n"] == 0
    # 2 (1.96 + 0.84)^2 * 2.56^2 / 3^2 = 11.4: twelve compositions per arm for a 3 s change at SD 2.56 s
    assert T.need_mean(2.56, 3.0) == 12


def test_pick_files_skips_a_log_written_in_the_last_ten_minutes(tmp_path):
    old = tmp_path / "brain-live-20261115-235756-19752.jsonl"
    new = tmp_path / "brain-live-20261116-000000-1.jsonl"
    for p in (old, new):
        p.write_text("", encoding="utf-8")
    os.utime(old, (time.time() - 3600, time.time() - 3600))
    got = T.pick_files(T.parse_when("2026-11-15"), T.parse_when("2026-11-17"), tmp_path)
    assert got == [old]
    assert T.pick_files(T.parse_when("2026-11-10"), T.parse_when("2026-11-12"), tmp_path) == []


def test_parse_when_is_utc():
    assert T.parse_when("2026-11-14") == 1794614400.0
    assert T.parse_when("2026-11-14T01:30Z") == 1794614400.0 + 5400
    with pytest.raises(ValueError):
        T.parse_when("14/11/2026")


def test_report_cli_runs_on_a_sample(tmp_path, monkeypatch, capsys):
    p = tmp_path / "brain-live-20261115-235756-19752.jsonl"
    p.write_text(SAMPLE_PLAN_FIRST.strip() + "\n", encoding="utf-8")
    os.utime(p, (time.time() - 3600, time.time() - 3600))
    monkeypatch.setattr(T, "LOGS", tmp_path)
    assert T.main(["report", "--since", "2026-11-15", "--until", "2026-11-17", "--json"]) == 0
    out = json.loads(capsys.readouterr().out)
    assert out["asks"] == 1 and out["with_planner"]["first_act_s"]["median"] == pytest.approx(27.84, abs=0.01)
    assert out["worst_stands"][0]["stand_s"] == pytest.approx(22.69, abs=0.01)

    assert T.main(["ask", "20261115-235756-19752/chat-0001-52b5"]) == 0
    assert "composition planner" in capsys.readouterr().out


# ------------------------------------------------------------------ DW_ASYNC_PLAN (brain/plan_async.py)
def test_an_async_composition_runs_from_plan_started_to_the_workers_end_and_his_turns_do_not_end_it():
    """The quest shape with the flag on: start_goal, plan_started, his turn walks while the Planner composes, the plan
    lands (composed_s), his chain ends, the plan's first act. The gap is the longest stand, not the whole stretch."""
    ep = "chat-0001-aaaa"
    rows = [*_heard(100.0, ep, "claude, go and see Zanik and do her quest"),
            _row(102.3, "tool_call", ep, tool="go_to", task_id="t1", args={"target": "Zanik"}),
            _row(130.0, "tool_result", ep, tool="go_to", task_id="t1", ok=True),
            _row(131.0, "prompt", ep, component="controller"),
            _row(133.0, "llm_response", ep, component="controller", usage={"latency_ms": 2000}),
            _row(133.5, "plan_started", ep, plan_kind="plan", goal="chop 5 ash"),
            _row(133.6, "prompt", ep, component="planner"),
            _row(134.0, "prompt", ep, component="controller"),                       # his turn while it composes
            _row(135.5, "llm_response", ep, component="controller", usage={"latency_ms": 1500}),
            _row(135.6, "tool_call", ep, tool="go_to", task_id="t2", args={"target": "Ash Tree"}),
            _row(138.6, "llm_response", ep, component="planner", usage={"latency_ms": 5000, "cost_usd": 0.04}),
            _row(141.0, "tool_result", ep, tool="go_to", task_id="t2", ok=True),
            _row(141.2, "prompt", ep, component="controller"),
            _row(142.2, "llm_response", ep, component="controller", usage={"latency_ms": 1000}),
            _row(142.4, "acted_while_planning", ep, n=1, tools=["go_to"]),
            _row(142.5, "plan_arrived", ep, plan_kind="plan", age_s=9.0, composed_s=5.1, stale=False, why=[],
                 applied=True, ok=True),
            _row(142.7, "tool_call", ep, tool="gather", task_id="t3", args={"resource": "ash", "count": 5}),
            _row(160.0, "tool_result", ep, tool="gather", task_id="t3", ok=True)]
    res = T.analyse(rows)
    (c,) = res["compositions"]
    assert c["async"] and c["outcome"] == "plan" and c["applied"] and c["acted"] == 1 and len(c["calls"]) == 1
    assert c["secs"] == pytest.approx(5.1) and c["taken_s"] == pytest.approx(9.0)
    assert c["stand"] == pytest.approx(2.1)                  # 133.5 to 135.6; the walk covers the rest
    assert c["gap_s"] == pytest.approx(5.6)                  # 130.0 to 135.6, the longest stand before the gather
    assert c["stale"] == [] and c["basis_known"]
    agg = T.aggregate([res])["compositions"]
    assert agg["async"] == 1 and agg["async_acted"] == 1 and agg["applied"] == 1 and agg["stale"] == 0
    (a,) = res["asks"]
    assert a["first_act_s"] == pytest.approx(2.3)


def test_an_async_plan_marked_stale_by_the_brain_and_an_abandoned_one():
    ep = "chat-0001-bbbb"
    rows = [*_heard(0.0, ep),
            _row(3.0, "plan_started", ep, plan_kind="replan"),
            _row(3.1, "tool_call", ep, tool="gather", task_id="g", args={"resource": "log", "count": 2}),
            _row(6.0, "tool_result", ep, tool="gather", task_id="g", ok=True),
            _row(8.0, "acted_while_planning", ep, n=1),
            _row(8.1, "plan_arrived", ep, plan_kind="replan", composed_s=4.0, stale=True, applied=False, ok=True,
                 why=["its first step (gather 2 log) is done"]),
            _row(20.0, "plan_started", ep, plan_kind="plan"),
            _row(22.0, "acted_while_planning", ep, n=0),
            _row(22.1, "plan_abandoned", ep, plan_kind="plan", age_s=2.1)]
    gs: set = set()
    assert T.slim({"ts": 1.0, "kind": "plan_arrived", "why": ["x"], "stale": True, "composed_s": 2}, gs)["why"] == ["x"]
    s, ab = T.analyse(rows)["compositions"]
    assert s["decision"] == "replan" and s["stale"] == ["its first step (gather 2 log) is done"] and not s["applied"]
    assert ab["outcome"] == "abandoned" and ab["secs"] == pytest.approx(2.1)
    assert T.aggregate([T.analyse(rows)])["compositions"]["stale"] == 1


def test_longest_idle():
    assert T.longest_idle(0.0, 10.0, [(2.0, 3.0), (7.0, 8.0)]) == pytest.approx(4.0)
    assert T.longest_idle(0.0, 10.0, []) == pytest.approx(10.0)
    assert T.longest_idle(0.0, 10.0, [(-1.0, 11.0)]) == pytest.approx(0.0)
