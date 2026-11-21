"""DW_PLAN_AT_ASK=1: a plan that lands for an ask he parked while it was made is shown to him once as facts (the steps,
the done_when with its truth now, his park reason and when); his park stands and nothing starts; his start_goal on the
ask's words in that turn takes the landed plan (no second Planner call), else it is let go. Live L3 20261121-005621
("claude, gear up for the vault"): parked 12 s in as "Vault is PL 2 and I'm PL 0, so I'm not going in yet"; the plan
landed 18 s later with steps and a done_when (not met) and was logged "let go: parked by him", never shown.
Offline: scripted LLMs and the mock game.
"""
from __future__ import annotations

from conftest import Rig

from brain import agent as A
from brain.interface import CommandReceived
from brain.llm import FakeLLM
from test_plan_at_ask import (LOGS, PL2, T1_BODY, VAULT, SlowPlanner, _hear, _rows, _wearing,  # noqa: F401
                              on)

REASON = "Vault is PL 2 and I'm PL 0, so I'm not going in yet"


def _parks_while_planned(rig, slow, then):
    """He parks the ask while its plan is made; ``then`` is his reply in the turn that shows the landed plan."""
    seen = {}

    def turn(messages, tools):
        names = {t["function"]["name"] for t in tools or []}
        if "for_parked_request" in messages[1]["content"]:
            seen.setdefault("shown", messages[1]["content"])
            return then
        if "parked" in seen:
            return FakeLLM.say("")
        if "park_request" in names:
            seen["parked"] = True
            return FakeLLM.say("", FakeLLM.call("park_request", reason=REASON))
        return FakeLLM.say("")

    _hear(rig, VAULT, *([turn] * 12))
    parked, = _rows(rig, "request_parked")
    assert parked["reason"] == REASON and rig.agent._open_request is None
    assert rig.agent._at_ask is None and len(rig.agent._at_ask_gone) == 1
    assert not _rows(rig, "plan_at_ask")  # not logged as let go while it is made
    rig.controller_llm.push(*([turn] * 4))
    slow.gate.set()
    rig.agent._at_ask_gone[0].future.result(timeout=10)
    return seen


def test_a_plan_landing_after_his_park_is_shown_once_as_facts_and_starts_nothing(tmp_path, on):
    rig = Rig(tmp_path)
    _wearing(rig, T1_BODY)
    slow = SlowPlanner(FakeLLM.plan(LOGS, done_when=PL2))
    rig.planner_llm.push(slow)
    seen = _parks_while_planned(rig, slow, FakeLLM.say(""))
    assert rig.agent.step() is None  # nothing started
    shown = seen["shown"]
    assert A.AT_ASK_PARKED_NOTE in shown and "gather" in shown and REASON in shown and "s_ago" in shown
    assert "done_when" in shown and "not yet: " in shown and "power_level >= 2" in shown
    row, = _rows(rig, "plan_at_ask")
    assert row["landed"] == "shown, not started: he parked the request" and row["park_reason"] == REASON
    checked = [r for r in _rows(rig, "done_when_checked") if r["where"] == "plan_arrived"]
    assert len(checked) == 1 and checked[0]["holds"] is False
    let_go, = _rows(rig, "plan_at_ask_let_go")
    assert let_go["why"].startswith("he parked the request") and rig.agent._at_ask_held is None
    assert rig.agent._parked["ask"] == VAULT and rig.agent._open_request is None  # his park stands
    assert rig.calls("gather") == [] and rig.agent.pending_goal is None and not _rows(rig, "request_reopened")
    assert rig.agent.step() is None and rig.calls("gather") == []  # and nothing later either


def test_his_start_goal_in_that_turn_takes_the_landed_plan(tmp_path, on):
    rig = Rig(tmp_path)
    slow = SlowPlanner(FakeLLM.plan(LOGS))
    rig.planner_llm.push(slow)
    _parks_while_planned(rig, slow, FakeLLM.say("on it after all", FakeLLM.call("start_goal", goal=VAULT[1])))
    assert rig.agent.step() == "done"
    assert len(rig.planner_llm.calls) == 1  # the landed plan, no second Planner call
    adopted, = _rows(rig, "plan_at_ask_adopted")
    assert adopted["after_park"] is True and adopted["goal"] == VAULT[1]
    assert rig.game.players["Luis"].inventory["log"] == 2


def test_a_question_landing_after_his_park_is_shown(tmp_path, on):
    rig = Rig(tmp_path)
    slow = SlowPlanner(FakeLLM.plan([], ask_help="which vault?"))
    rig.planner_llm.push(slow)
    seen = _parks_while_planned(rig, slow, FakeLLM.say(""))
    assert rig.agent.step() is None
    assert "which vault?" in seen["shown"] and A.AT_ASK_PARKED_Q_NOTE in seen["shown"]
    row, = _rows(rig, "plan_at_ask")
    assert row["landed"] == "shown: he parked the request" and rig.agent._at_ask_held is None
    assert rig.agent._parked["ask"] == VAULT and rig.agent._parked["reason"] == REASON


def test_a_decline_after_his_park_is_let_go_as_before(tmp_path, on):
    rig = Rig(tmp_path)
    slow = SlowPlanner(FakeLLM.plan([], explanation="nothing to do in the game"))
    rig.planner_llm.push(slow)
    seen = _parks_while_planned(rig, slow, FakeLLM.say(""))
    assert rig.agent.step() is None and "shown" not in seen
    row, = _rows(rig, "plan_at_ask")
    assert row["landed"] == "let go: parked by him" and row["outcome"] == "decline"


def test_a_newer_line_after_his_park_lets_it_go_unseen(tmp_path, on):
    rig = Rig(tmp_path)
    slow = SlowPlanner(FakeLLM.plan(LOGS, done_when=PL2))
    rig.planner_llm.push(slow)
    seen = _parks_while_planned(rig, slow, FakeLLM.say(""))
    rig.planner_llm.push(FakeLLM.plan([], explanation="a chat line"))  # the newer line's own at-ask call
    rig.agent._command(CommandReceived(player="Luis", text="claude, never mind"))
    assert rig.agent._parked is None
    rig.agent.step()
    assert "shown" not in seen
    row = next(r for r in _rows(rig, "plan_at_ask") if r["request"] == VAULT[1])
    assert row["landed"] == "let go: parked by him; the park no longer stands"
    assert rig.calls("gather") == []


def test_after_the_landed_plan_his_park_is_carried_by_the_idle_review_as_facts(tmp_path, on):
    """Live L3 20261121-020517: parked with the done_when unmet, the trial player silent, 40 s standing. The idle
    review (broker REVIEW_IDLE_ASK_S) now carries the parked ask: words, who asked, his park and reason, the lines
    since, the end condition its plan wrote with its truth now. His park stands; nothing is started."""
    rig = Rig(tmp_path)
    _wearing(rig, T1_BODY)
    slow = SlowPlanner(FakeLLM.plan(LOGS, done_when=PL2))
    rig.planner_llm.push(slow)
    _parks_while_planned(rig, slow, FakeLLM.say(""))
    assert rig.agent.step() is None
    p = rig.agent._idle_ask()["parked_ask"]
    assert p["words"] == VAULT[1] and p["asked_by"] == VAULT[0] and p["park_reason"] == REASON
    assert p["parked_by"] == A.PARKED_BY_WORDS["him"] and p["parked_s_ago"] >= 0
    assert p["player_lines_since_park"] == []
    assert "power_level >= 2" in p["done_when"]["end_condition"] and p["done_when"]["now"].startswith("not yet")
    checked = [r for r in _rows(rig, "done_when_checked") if r["where"] == "idle_review_parked"]
    assert len(checked) == 1 and checked[0]["holds"] is False
    assert rig.agent._parked["ask"] == VAULT and rig.agent._open_request is None and rig.agent.pending_goal is None
    assert rig.calls("gather") == []
    rig.agent._last_line[VAULT[0]] = ("never mind the vault", rig.agent.clock() + 1)  # he answers after the park
    assert rig.agent._idle_ask() is None
