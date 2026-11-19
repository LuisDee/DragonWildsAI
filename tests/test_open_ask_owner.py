"""The goal machinery owns the ask (DW_ASK_OWNER=1; design scratchpad goal_owns_ask.md, 19 Nov 2026).

A run that leaves the open ask with no job (request_left_open) used to end the matter: nothing scheduled a next run
(19 of 19 unanswered questions in unanswered_1119.md). With the flag on, step() hands the ask's words, verbatim, to his
Planner as a goal, unless the player's newest line, his own stop / park / done, a goal, a waiting chat line, the cap
of ASK_PLAN_CAP Planner calls or the stall rule stands in the way (each skip logged with why). A Planner answer with
only a question parks the ask (by=planner); a decline (offered only to hand-overs) parks it with the explanation.
Flag off, or the Director attached: nothing of this runs. Offline: scripted LLMs and the mock game.
"""
import json
from types import SimpleNamespace

import pytest

from conftest import Rig

from brain import agent as A
from brain import open_ask as oa
from brain.interface import CommandReceived
from brain.llm import FakeLLM
from brain.planner import DECLINE_LINE, Planner, PlanError

ASK = ("Luis", "claude, which chest is your base chest?")
COPPER = ("Luis", "claude, get me some unobtainium")


@pytest.fixture
def on(monkeypatch):
    monkeypatch.setenv(A.ASK_OWNER_ENV, "1")


def _rows(rig, kind):
    return [r for r in rig.log.read_all() if r.get("kind") == kind]


def _endless(rig):
    """The Controller replies as scripted, then with nothing (no text, no call) for as long as it is asked."""
    llm = rig.controller_llm
    orig = llm.complete

    def complete(messages, tools=None, effort=None, **kw):
        if not llm.script:
            llm.script.append(FakeLLM.say(""))
        return orig(messages, tools, effort, **kw)
    llm.complete = complete


def _open_turns(rig) -> list[dict]:
    return [c for c in rig.controller_llm.calls
            if str(c["messages"][-1].get("content") or "").startswith(oa.NOTE_PREFIX)]


def _shown(call) -> dict:
    return json.loads(call["messages"][-1]["content"][len(oa.NOTE_PREFIX):])["open_request"]


def _ask_and_go_quiet(rig, ask=ASK):
    """He asks the player a question back, then stops with no call on the ask (the 19 cases' shape)."""
    _endless(rig)
    rig.controller_llm.push(FakeLLM.say("which one's yours?"))
    rig.agent._command(CommandReceived(player=ask[0], text=ask[1]))
    left = _rows(rig, "request_left_open")
    assert left and left[-1]["request"] == ask[1]
    assert rig.agent._open_request == ask


def _review(rig, *replies):
    rig.controller_llm.push(*replies)
    rig.agent._command(CommandReceived(player="Luis", text=""), addressed=True,
                       body_events=[{"type": "situation_review", "changes": ["hydration: low"]}])


def _planner_user(call) -> dict:
    return json.loads(call["messages"][1]["content"].split("\n\n")[0])


# ----------------------------------------------------------------------------------------------- the hand-over


def test_a_silent_stop_hands_the_ask_to_the_planner_in_his_words(tmp_path, on):
    rig = Rig(tmp_path)
    _ask_and_go_quiet(rig)
    assert _shown(_open_turns(rig)[0])["if_you_stop"] == A.HANDOVER_IF_YOU_STOP  # told what a stop now leads to
    assert rig.agent._unowned is not None
    rig.planner_llm.push(FakeLLM.plan([{"skill": "gather", "args": {"resource": "log", "count": 2}}]))
    assert rig.agent.step() == "done"
    ho, = _rows(rig, "ask_handover")
    assert ho["request"] == ASK[1] and ho["player"] == "Luis" and ho["run_for"] == "line"
    assert ho["why_unowned"] == "had one this run" and ho["n"] == 1 and ho["plan_calls"] == 0
    assert ho["mode"] == "plan" and ho["prior"] is None and ho["question_pending"] is True
    call, = rig.planner_llm.calls
    assert _planner_user(call)["goal"] == ASK[1]  # verbatim: never rewritten
    assert DECLINE_LINE in call["messages"][0]["content"]  # a hand-over may be declined
    started, = _rows(rig, "plan_started")
    assert started["from_ask"] is True and started["request"] == ASK[1]
    assert rig.calls("gather") == [{"resource": "log", "count": 2}]  # the steps are his Planner's
    ended, = _rows(rig, "ask_handover_ended")
    assert ended["result"] == "done" and ended["plan_calls"] == 1 and ended["his_calls"] == 0
    # the goal's end hands the ask back to him as the open request, as any goal's does
    done_runs = [c for c in rig.controller_llm.calls if '"type": "goal_done"' in str(c["messages"][1].get("content"))]
    assert done_runs and f'"request": "{ASK[1]}"' in str(done_runs[0]["messages"][1]["content"])


def test_flag_off_no_hand_over(tmp_path):
    rig = Rig(tmp_path)
    _ask_and_go_quiet(rig)
    assert "if_you_stop" not in _shown(_open_turns(rig)[0])
    assert rig.agent._unowned is None
    assert rig.agent.step() is None
    assert rig.planner_llm.calls == [] and rig.agent.pending_goal is None
    assert not _rows(rig, "ask_handover") and not _rows(rig, "ask_handover_skipped")


def test_off_while_the_director_is_attached(tmp_path, on):
    rig = Rig(tmp_path)
    rig.agent.director = SimpleNamespace(running=False, owns_transition=False, tool_names=set(),
                                         tick=lambda: None, on_player_command=lambda *a: None)
    _ask_and_go_quiet(rig)
    assert rig.agent._unowned is None and not rig.agent._ask_owner_on()
    assert "if_you_stop" not in _shown(_open_turns(rig)[0])


# ----------------------------------------------------------------------------------------------- what stands


def _skipped(rig) -> str:
    row, = _rows(rig, "ask_handover_skipped")
    assert row["request"] == ASK[1]
    assert rig.planner_llm.calls == [] and not _rows(rig, "ask_handover")
    return row["why"]


def test_his_stop_stands(tmp_path, on):
    rig = Rig(tmp_path)
    _ask_and_go_quiet(rig)
    _review(rig, FakeLLM.say("", FakeLLM.call("stop")))  # his own stop while the ask is open
    assert _rows(rig, "ask_stopped_by_him")
    rig.agent.step()
    assert _skipped(rig) == "stopped by him"
    assert rig.agent._open_request == ASK  # open, as before: only his calls or the player's line close it


def test_his_park_stands(tmp_path, on):
    rig = Rig(tmp_path)
    _ask_and_go_quiet(rig)
    # silent, the stop check (silent), then the open-ask turn, where he parks it
    _review(rig, FakeLLM.say(""), FakeLLM.say(""), FakeLLM.say("", FakeLLM.call("park_request", reason="waiting on Luis")))
    assert rig.agent._open_request is None and rig.agent._parked["ask"] == ASK
    rig.agent.step()
    assert _skipped(rig) == "parked by him"


def test_a_newer_player_line_wins(tmp_path, on):
    rig = Rig(tmp_path)
    _ask_and_go_quiet(rig)
    rig.controller_llm.push(FakeLLM.say(""))  # a line not for him: ignored, the ask stays open
    rig.agent._command(CommandReceived(player="Luis", text="nice sunset"), addressed=False)
    assert rig.agent._open_request == ASK
    rig.agent.step()
    assert _skipped(rig) == "a newer player line"


def test_a_goal_queued_or_running_stands(tmp_path, on):
    rig = Rig(tmp_path)
    _ask_and_go_quiet(rig)
    _review(rig, FakeLLM.say("", FakeLLM.call("start_goal", goal="chop 2 logs")))  # his own job
    assert rig.agent.pending_goal == "chop 2 logs"
    rig.agent._take_up_ask()
    assert _skipped(rig) == "a goal is queued"
    rig2 = Rig(tmp_path / "b")
    _ask_and_go_quiet(rig2)
    rig2.agent.active_goal = "chop 2 logs"
    rig2.agent._take_up_ask()
    assert _skipped(rig2) == "a goal is running"


def test_the_cap_ends_repeated_hand_overs_at_six_planner_calls(tmp_path, on):
    # each hand-over's goal ends done, the run that hears it stops silent with the ask open, something changes in the
    # bag, and the ask is handed over again: bounded by ASK_PLAN_CAP Planner calls on the ask
    rig = Rig(tmp_path)
    _ask_and_go_quiet(rig)
    for _ in range(A.ASK_PLAN_CAP):
        rig.planner_llm.push(FakeLLM.plan([{"skill": "gather", "args": {"resource": "log", "count": 1}}]))
    for _ in range(A.ASK_PLAN_CAP + 2):
        rig.agent.step()
        rig.game.inventory["stone"] += 1  # (no job tree: a change since the done is what lets it go on)
    assert len(_rows(rig, "ask_handover")) == A.ASK_PLAN_CAP == len(rig.planner_llm.calls) == 6
    assert [r["n"] for r in _rows(rig, "ask_handover")] == [1, 2, 3, 4, 5, 6]
    skip, = _rows(rig, "ask_handover_skipped")
    assert skip["why"] == "cap: 6 Planner calls on this request"
    # the last open-ask turn no longer says a stop hands it over
    assert "if_you_stop" not in _shown(_open_turns(rig)[-1])


class _Tree:
    """A job-tree keeper stand-in for the ask: its root reads ``root`` from any state."""

    def __init__(self, root: str):
        self.root, self.dir = root, None

    def open(self, ask):
        self.ask = ask
        return []

    def active(self, ask):
        return oa.same_ask(ask, getattr(self, "ask", None))

    def tree(self, state, spells=None):
        return {"roots": [{"kind": "item", "status": self.root}], "nodes": 1}

    def compact_view(self, *a, **k):
        return None

    def full_view(self, *a, **k):
        return None

    def record(self, *a, **k):
        return []

    def close(self):
        pass


def _done_once(rig):
    _ask_and_go_quiet(rig)
    rig.planner_llm.push(FakeLLM.plan([{"skill": "gather", "args": {"resource": "log", "count": 2}}]))
    assert rig.agent.step() == "done"  # hand-over 1: its plan ran to its end; the run that heard it stopped silent


def test_done_then_stop_is_not_handed_over_again(tmp_path, on):
    rig = Rig(tmp_path)
    _done_once(rig)
    told = [_shown(c) for c in _open_turns(rig)[1:]]  # the goal_done run's open-ask turn: told once, as data
    assert told and told[0]["your_planners_job"] == {"goal": ASK[1], "ended": "done: its plan ran to its end",
                                                     "steps": 1}
    assert "if_you_stop" not in told[0]  # a stop now hands nothing over
    rig.agent.step()
    skip, = _rows(rig, "ask_handover_skipped")
    assert skip["why"] == "done_by_plan" and skip["changed"] is False and skip["root_not_done"] is None
    assert len(rig.planner_llm.calls) == 1 and len(_rows(rig, "ask_handover")) == 1


def test_done_but_the_tree_root_not_done_and_the_bag_changed_is_handed_over_as_a_replan(tmp_path, on):
    rig = Rig(tmp_path)
    rig.agent.jobs = _Tree("open")
    _done_once(rig)
    rig.game.inventory["stone"] += 3  # something changed since the goal ended
    rig.planner_llm.push(FakeLLM.plan([{"skill": "gather", "args": {"resource": "log", "count": 1}}]))
    assert rig.agent.step() == "done"
    second = _rows(rig, "ask_handover")[1]
    assert second["mode"] == "replan" and second["prior"]["goal"] == ASK[1]
    user = _planner_user(rig.planner_llm.calls[1])
    assert user["goal"] == ASK[1] and "failed_task" in user and user["replans_so_far"] == 0


def test_done_with_the_tree_root_done_is_not_handed_over_even_after_a_change(tmp_path, on):
    rig = Rig(tmp_path)
    rig.agent.jobs = _Tree("done")
    _done_once(rig)
    rig.game.inventory["stone"] += 3
    rig.agent.step()
    skip, = _rows(rig, "ask_handover_skipped")
    assert skip["why"] == "done_by_plan" and skip["root_not_done"] is False and skip["changed"] is True
    assert len(rig.planner_llm.calls) == 1


def test_the_stall_rule_parks_after_the_same_failure_twice_with_nothing_changed(tmp_path, on):
    rig = Rig(tmp_path, max_replans=0)
    _ask_and_go_quiet(rig, COPPER)
    step = [{"skill": "gather", "args": {"resource": "unobtainium", "count": 1}}]
    rig.planner_llm.push(FakeLLM.plan(step), FakeLLM.plan(step, explanation="none in range; try again"))
    assert rig.agent.step() == "stuck"  # hand-over 1: a plan, its step fails, stuck
    assert rig.agent.step() == "stuck"  # hand-over 2 goes on from it: a replan of the stuck tree
    first, second = _rows(rig, "ask_handover")
    assert first["mode"] == "plan" and second["mode"] == "replan"
    assert second["prior"]["failed"]["skill"] == "gather"
    assert second["prior"]["failed"]["args"]["resource"] == "unobtainium"
    user = _planner_user(rig.planner_llm.calls[1])
    assert user["goal"] == COPPER[1] and user["failed_task"]["skill"] == "gather" and user["replans_so_far"] == 0
    rig.agent.step()  # the same failure again, nothing changed: parked by code, told to him
    skip, = _rows(rig, "ask_handover_skipped")
    assert skip["why"] == "stall" and skip["reason"].startswith("stopped by code after the same failure twice")
    parked, = _rows(rig, "request_parked")
    assert parked["by"] == "code" and parked["request"] == COPPER[1]
    assert rig.agent._open_request is None and rig.agent._parked["ask"] == COPPER
    told = [c for c in rig.controller_llm.calls if '"type": "ask_parked"' in str(c["messages"][1].get("content"))]
    assert told, "he is told the ask was parked"
    assert len(rig.planner_llm.calls) == 2


# ----------------------------------------------------------------------------------------------- his Planner's answer


def test_a_planner_answer_with_only_a_question_parks_the_ask(tmp_path, on):
    rig = Rig(tmp_path)
    _ask_and_go_quiet(rig)
    rig.planner_llm.push(FakeLLM.plan([], ask_help="Which crate is yours, Luis?"))
    assert rig.agent.step() == "stuck"
    parked, = _rows(rig, "request_parked")
    assert parked["by"] == "planner" and parked["reason"] == "planner waits on the player: Which crate is yours, Luis?"
    assert rig.agent._open_request is None and rig.agent._parked["ask"] == ASK
    runs = [str(c["messages"][1].get("content")) for c in rig.controller_llm.calls]
    assert any('"type": "ask_parked"' in r and "Which crate is yours" in r for r in runs)
    assert not any('"type": "stuck"' in r for r in runs)  # no goal end that would reopen it


def test_a_planner_decline_parks_the_ask_with_its_explanation(tmp_path, on):
    rig = Rig(tmp_path)
    _ask_and_go_quiet(rig)
    why = "That is a question about which chest is his; no work in the game answers it."
    rig.planner_llm.push(FakeLLM.plan([], explanation=why))
    assert rig.agent.step() == "stuck"
    declined, = _rows(rig, "planner_declined")
    assert declined["request"] == ASK[1] and declined["explanation"] == why
    parked, = _rows(rig, "request_parked")
    assert parked["by"] == "planner" and parked["reason"] == f"planner: {why}"
    assert rig.agent._parked["ask"] == ASK


def test_a_decline_is_only_valid_when_offered(tmp_path):
    rig = Rig(tmp_path)
    planner = Planner(rig.planner_llm, rig.store.skills, rig.log)
    empty = FakeLLM.plan([], explanation="nothing to do")
    rig.planner_llm.push(empty, empty)
    with pytest.raises(PlanError):
        planner.plan("what's the best pickaxe?", {}, {})
    assert DECLINE_LINE not in rig.planner_llm.calls[0]["messages"][0]["content"]
    rig.planner_llm.push(empty)
    got = planner.plan("what's the best pickaxe?", {}, {}, may_decline=True)
    assert got.declined and got.explanation == "nothing to do" and got.tasks == []


def test_the_hand_over_and_its_replan_with_the_planner_in_the_background(tmp_path, on, monkeypatch):
    # DW_ASYNC_PLAN=1: the same hand-over, plan and continuation replan made on the worker (plan_started from_ask)
    from brain import plan_async
    monkeypatch.setenv(plan_async.ENV, "1")
    rig = Rig(tmp_path, max_replans=0)
    assert rig.agent.async_plan
    _ask_and_go_quiet(rig, COPPER)
    step = [{"skill": "gather", "args": {"resource": "unobtainium", "count": 1}}]
    rig.planner_llm.push(FakeLLM.plan(step), FakeLLM.plan(step))
    assert rig.agent.step() == "stuck"
    assert rig.agent.step() == "stuck"
    assert [r["mode"] for r in _rows(rig, "ask_handover")] == ["plan", "replan"]
    assert [(r["plan_kind"], r.get("from_ask")) for r in _rows(rig, "plan_started")] == [("plan", True),
                                                                                        ("replan", True)]
    assert _planner_user(rig.planner_llm.calls[1])["goal"] == COPPER[1]
    rig.agent.step()
    assert _rows(rig, "ask_handover_skipped")[0]["why"] == "stall"
