"""The open ask survives one silent turn (brain/open_ask.py; variant C of docs/research/2026-11-17-open-ask-replay.md).

A turn with no call while a player's ask is open runs ONE more Controller turn that shows the ask as data (his words,
who, how long ago, what changed in the game since) and offers request_done(evidence) and park_request(reason). Either
closes the ask and is logged. Nothing else closes it but the player's next line: a second silent turn, or a stop with no
turn left, logs `request_left_open` (after_open_ask_turn / no_open_ask_turn) and the next run carries it (2026-11-18).
Offline: scripted LLMs and the mock game.
"""
import json

from conftest import Rig

from brain import open_ask as oa
from brain.interface import CommandReceived
from brain.llm import FakeLLM

ASK = ("Luis", "claude, chop me 2 logs")


def _rows(rig, kind):
    return [r for r in rig.log.read_all() if r.get("kind") == kind]


def _tools(call) -> set[str]:
    return {t["function"]["name"] for t in call["tools"] or []}


def _open_turns(rig) -> list[dict]:
    """The Controller calls whose last message is the open ask."""
    return [c for c in rig.controller_llm.calls
            if str(c["messages"][-1].get("content") or "").startswith(oa.NOTE_PREFIX)]


def _shown(call) -> dict:
    return json.loads(call["messages"][-1]["content"][len(oa.NOTE_PREFIX):])["open_request"]


def _ask(rig, *replies):
    rig.controller_llm.push(*replies)
    rig.agent._command(CommandReceived(player=ASK[0], text=ASK[1]))


def _review(rig):
    rig.agent._command(CommandReceived(player="Luis", text=""), addressed=True,
                       body_events=[{"type": "situation_review", "changes": ["hydration: low"]}])


def test_a_silent_stop_runs_one_more_turn_that_shows_the_ask_and_what_changed(tmp_path):
    rig = Rig(tmp_path)
    _ask(rig, FakeLLM.say("", FakeLLM.call("gather", resource="log", count=1)), FakeLLM.say(""), FakeLLM.say(""))
    calls = rig.controller_llm.calls
    assert len(calls) == 3  # the ask, the report turn (silent), the open-ask turn (silent again)
    opened = _open_turns(rig)
    assert opened == [calls[2]]  # once
    shown = _shown(calls[2])
    assert shown["player"] == "Luis" and shown["words"] == ASK[1]
    assert isinstance(shown["asked_s_ago"], int) and shown["asked_s_ago"] >= 0
    assert shown["changed_since_asked"]["bag"] == {"log": "+1"}  # read from fresh state against the state at the ask
    assert shown["changed_since_asked"]["worn"] == "no change"
    assert shown["open_until"] == "request_done or park_request is called"
    # the block states facts: no advice in code's words (his own words are quoted as they were)
    note = calls[2]["messages"][-1]["content"].replace(ASK[1], "")
    assert not any(w in note.lower() for w in ("continue", "should", "next step", "you ")), note
    assert calls[2]["messages"][-2]["content"].startswith("Current observation: ")  # as the replay built it
    # the two tools are offered on that turn only
    assert {"request_done", "park_request"} <= _tools(calls[2])
    assert not ({"request_done", "park_request"} & (_tools(calls[0]) | _tools(calls[1])))
    row, = _rows(rig, "open_ask_turn")
    assert row["request"] == ASK[1] and row["player"] == "Luis" and row["outcome"] == "silent"
    assert row["shown"]["open_request"]["changed_since_asked"]["bag"] == {"log": "+1"}
    # a second silent turn does not close it (only request_done, park_request or his next line do): logged, countably
    left, = _rows(rig, "request_left_open")
    assert left["after_open_ask_turn"] is True and "no_open_ask_turn" not in left and left["run_for"] == "line"
    assert rig.agent._open_request == ASK and not _rows(rig, "request_closed")


def test_request_done_closes_the_ask_and_records_his_evidence(tmp_path):
    rig = Rig(tmp_path)
    _ask(rig, FakeLLM.say("", FakeLLM.call("gather", resource="log", count=2)), FakeLLM.say(""),
         FakeLLM.say("", FakeLLM.call("request_done", evidence="2 logs in my bag")))
    assert rig.agent._open_request is None
    claimed, = _rows(rig, "request_done_claimed")
    assert claimed["request"] == ASK[1] and claimed["player"] == "Luis" and claimed["evidence"] == "2 logs in my bag"
    assert _rows(rig, "open_ask_turn")[0]["outcome"] == "done_claim"
    assert not _rows(rig, "request_closed") and not _rows(rig, "request_parked")
    assert len(rig.controller_llm.calls) == 3  # his close is his stop: no further turn
    assert rig.companion_said() == []  # code says nothing for him; the claim is recorded, not judged


def test_park_request_closes_the_ask_and_the_player_hears_the_reason(tmp_path):
    rig = Rig(tmp_path)
    why = "no trees left near here, they're all chopped"
    _ask(rig, FakeLLM.say("", FakeLLM.call("gather", resource="log", count=1)), FakeLLM.say(""),
         FakeLLM.say("", FakeLLM.call("park_request", reason=why)))
    assert rig.agent._open_request is None
    parked, = _rows(rig, "request_parked")
    assert parked["request"] == ASK[1] and parked["player"] == "Luis" and parked["reason"] == why
    assert _rows(rig, "open_ask_turn")[0]["outcome"] == "park"
    assert rig.companion_said() == [why]  # the tool says the player hears it: his own words
    assert not _rows(rig, "request_closed") and len(rig.controller_llm.calls) == 3


def test_work_on_the_extra_turn_keeps_the_ask_open_and_there_is_never_a_second_extra_turn(tmp_path):
    rig = Rig(tmp_path)
    _ask(rig, FakeLLM.say("", FakeLLM.call("gather", resource="log", count=1)), FakeLLM.say(""),
         FakeLLM.say("", FakeLLM.call("gather", resource="log", count=1)), FakeLLM.say(""))
    assert len(rig.calls("gather")) == 2  # he went on after the open-ask turn
    row, = _rows(rig, "open_ask_turn")
    assert row["outcome"] == "world" and row["actions"] == ["gather"]
    assert len(_open_turns(rig)) == 1  # one extra turn per run: no loop
    left, = _rows(rig, "request_left_open")  # his next silent stop leaves it open, with why no second turn
    assert left["after_open_ask_turn"] is False and left["no_open_ask_turn"] == "had one this run"
    assert len(rig.controller_llm.calls) == 4


def test_a_new_player_line_still_replaces_the_open_ask(tmp_path):
    rig = Rig(tmp_path)
    _ask(rig, FakeLLM.say("", FakeLLM.call("start_goal", goal="chop 2 logs for Luis")))  # a goal: the ask stays open
    assert rig.agent._open_request == ASK and not _rows(rig, "open_ask_turn")
    rig.controller_llm.push(FakeLLM.say("", FakeLLM.call("go_to", target="Luis")), FakeLLM.say(""), FakeLLM.say(""))
    rig.agent._command(CommandReceived(player="Luis", text="claude, come here"))
    row, = _rows(rig, "open_ask_turn")
    assert row["request"] == "claude, come here"  # the new line is the open one
    assert _shown(_open_turns(rig)[0])["words"] == "claude, come here"
    assert [r["request"] for r in _rows(rig, "request_left_open")] == ["claude, come here"]  # the first: replaced
    assert rig.agent._open_request == ("Luis", "claude, come here")


def test_a_body_only_run_with_no_ask_open_is_unaffected(tmp_path):
    rig = Rig(tmp_path)
    assert rig.agent._open_request is None
    rig.controller_llm.push(FakeLLM.say("", FakeLLM.call("gather", resource="log", count=1)), FakeLLM.say(""))
    _review(rig)
    assert len(rig.controller_llm.calls) == 2  # the run and its report turn, as before
    assert not _open_turns(rig) and not _rows(rig, "open_ask_turn") and not _rows(rig, "request_left_open")
    assert not any({"request_done", "park_request"} & _tools(c) for c in rig.controller_llm.calls)


def test_the_ask_tools_are_not_offered_and_are_refused_when_no_ask_is_open(tmp_path):
    rig = Rig(tmp_path)
    assert not ({"request_done", "park_request"} & rig.controller.offered())
    rig.controller_llm.push(FakeLLM.say("", FakeLLM.call("request_done", evidence="all done")), FakeLLM.say(""))
    _review(rig)
    assert [r["tool"] for r in _rows(rig, "controller_unknown_tool")] == ["request_done"]
    assert not _rows(rig, "request_done_claimed")
    assert not ({"request_done", "park_request"} & rig.controller.offered())  # nothing left behind


def test_no_extra_turn_when_the_run_handed_the_ask_to_a_job(tmp_path):
    # a goal (or a learned skill) queued in the run carries the ask; its end reopens it (goal_done's request)
    rig = Rig(tmp_path)
    _ask(rig, FakeLLM.say("", FakeLLM.call("gather", resource="log", count=1),
                          FakeLLM.call("start_goal", goal="chop 2 logs for Luis")), FakeLLM.say(""))
    assert len(rig.controller_llm.calls) == 2 and not _open_turns(rig)
    left, = _rows(rig, "request_left_open")  # the job carries it: open, not closed
    assert left["no_open_ask_turn"] == "handed to a job" and rig.agent._open_request == ASK


def test_a_stop_at_the_turn_budget_still_gets_the_turn(tmp_path, monkeypatch):
    # a stop at the limit is a stop with the ask open: the one turn is not barred by MAX_TURNS (it is one call, once)
    from brain import agent as A
    monkeypatch.setattr(A, "MAX_TURNS", 1)
    rig = Rig(tmp_path)
    _ask(rig, FakeLLM.say("", FakeLLM.call("gather", resource="log", count=1)), FakeLLM.say(""), FakeLLM.say(""))
    assert len(rig.controller_llm.calls) == 3 and len(_open_turns(rig)) == 1
    left, = _rows(rig, "request_left_open")
    assert left["after_open_ask_turn"] is True and rig.agent._open_request == ASK
    assert not _rows(rig, "request_closed")


# --------------------------------------------------------------------------- the ask across runs (2026-11-18)

COPPER = ("Tester", "claude, we need thirty copper ore in the chest at your base")


def test_a_goal_stuck_run_carries_the_ask_and_its_stop_gets_the_turn(tmp_path):
    """Live 2026-11-18 00:23Z, logs/brain-live-20261118-012330-23088.jsonl: "on it" + start_goal; the goal got stuck on
    its craft step; the stuck run (situation-0002, inside run_goal, active_goal still set) made a stone pickaxe, found
    no copper in range, said why and stopped. It carried no request (only goal_done did), so no open-ask turn ran and
    nothing was logged: 25 min standing with the ask open."""
    rig = Rig(tmp_path, max_replans=0)
    rig.controller_llm.push(FakeLLM.say("on it", FakeLLM.call("start_goal", goal="gather 30 copper ore into the chest")))
    rig.agent._command(CommandReceived(player=COPPER[0], text=COPPER[1]))
    assert rig.agent.pending_goal and rig.agent._open_request == COPPER and not _rows(rig, "request_left_open")
    rig.planner_llm.push(FakeLLM.plan([{"skill": "gather", "args": {"resource": "unobtainium", "count": 1}}]))
    why = "copper needs a better pickaxe and there's none near here"
    rig.controller_llm.push(FakeLLM.say("", FakeLLM.call("gather", resource="log", count=1)),  # the stone pickaxe
                            FakeLLM.say("", FakeLLM.call("gather", resource="unobtainium", count=1)),  # copper: none
                            FakeLLM.say(why), FakeLLM.say(why),  # why, no call (and the Controller's talk-only check)
                            FakeLLM.say(""))  # the open-ask turn
    assert rig.agent.step() == "stuck"
    stuck = [c for c in rig.controller_llm.calls if '"type": "stuck"' in str(c["messages"][1].get("content"))]
    assert stuck, "the stuck run ran"
    row, = _rows(rig, "open_ask_turn")
    assert row["request"] == COPPER[1] and row["player"] == COPPER[0] and row["run_for"] == "goal_stuck"
    assert _shown(_open_turns(rig)[0])["words"] == COPPER[1]
    left, = _rows(rig, "request_left_open")  # silent on it: open, not closed, and said so
    assert left["after_open_ask_turn"] is True and left["run_for"] == "goal_stuck"
    assert rig.agent._open_request == COPPER and not _rows(rig, "request_closed")


def test_silence_after_the_turn_keeps_the_ask_open_and_a_later_run_gets_its_own_turn(tmp_path):
    """logs/brain-live-20261118-010135-17424.jsonl, situation-0009: a body run on the open ask asked the player a
    question ("want me to go grab them, or do you know where copper is?"), the open-ask turn came back empty (outcome
    "silent"), and request_closed closed the ask: nothing after it carried it. Now it stays open until request_done,
    park_request or his next line, and the next run with it open gets its own one turn."""
    rig = Rig(tmp_path)
    _ask(rig, FakeLLM.say("", FakeLLM.call("gather", resource="log", count=1)),
         FakeLLM.say("no copper near here. want me to look further, or do you know a spot?"), FakeLLM.say(""))
    first, = _rows(rig, "open_ask_turn")
    assert first["outcome"] == "silent"
    assert _rows(rig, "request_left_open")[0]["after_open_ask_turn"] is True
    assert rig.agent._open_request == ASK and not _rows(rig, "request_closed")
    # a later body run (a review: he drank) with the ask still open stops silent: shown the ask again, once
    rig.controller_llm.push(FakeLLM.say("", FakeLLM.call("gather", resource="log", count=1)), FakeLLM.say(""),
                            FakeLLM.say(""), FakeLLM.say(""))
    _review(rig)
    rows = _rows(rig, "open_ask_turn")
    assert len(rows) == 2 and rows[1]["run_for"] == "carried" and rows[1]["request"] == ASK[1]
    assert len(_rows(rig, "request_left_open")) == 2 and rig.agent._open_request == ASK


def test_a_silence_right_after_a_failure_on_the_open_ask_gets_the_turn(tmp_path):
    # failure_unspoken: the model saw the failure and chose silence; with the ask open that is a stop on it
    rig = Rig(tmp_path)
    _ask(rig, FakeLLM.say("", FakeLLM.call("gather", resource="unobtainium", count=1)), FakeLLM.say(""),
         FakeLLM.say("", FakeLLM.call("park_request", reason="there's none of that anywhere near")))
    assert _rows(rig, "failure_unspoken")
    row, = _rows(rig, "open_ask_turn")
    assert row["outcome"] == "park" and not _rows(rig, "failure_unreported")  # straight to the turn, no other check
    assert rig.agent._open_request is None and _rows(rig, "request_parked")[0]["reason"].startswith("there's none")


def test_a_body_run_on_the_open_ask_hands_his_words_on(tmp_path, monkeypatch):
    # brain-live-20261118-010135 row 588: a body run on the ask hit the turn budget; chain_handed_on "request": null
    from brain import agent as A
    monkeypatch.setattr(A, "MAX_TURNS", 1)
    rig = Rig(tmp_path)
    rig.agent._open_request = ASK
    rig.controller_llm.push(FakeLLM.say("", FakeLLM.call("gather", resource="log", count=1)),
                            FakeLLM.say("", FakeLLM.call("gather", resource="log", count=1)))
    _review(rig)
    handed, = _rows(rig, "chain_handed_on")
    assert handed["request"] == ASK[1]
    situ, = [s for s in rig.agent._situations if s.get("type") == A.CHAIN_BUDGET]
    assert (situ["request"], situ["from"]) == (ASK[1], ASK[0])


# ------------------------------------------------------------------ request_done tells back what the game reads
# L3 2026-11-20 (brain-live-20261120-015346 line 45, and 003659/004124/004502): "claude, gear up for the vault"; he
# equipped the Bronze Shield he already wore and closed it "all set". The close stands; its result now carries the
# game's reads of the ask beside his claim (agent._done_reads), and the request_done_claimed row logs them.

L3_GEAR = {"Head": "ITEM_Armour_T2_Head_Leather", "Body": "ITEM_Armour_T1_Body_Adventurers",
           "Legs": "ITEM_Armour_T1_Legs_Adventurers", "held_left": "ITEM_Shield_Bronze",
           "held_right": "ITEM_Sword_Bronze"}
L3_HERE = [151.03, 1911.95, -31.63]


def _as_l3(rig):
    """The mock body read as the L3 one: its worn gear, the game's power level 0, the Temple Woods spot."""
    orig = rig.game.get_state

    def get_state():
        r = orig()
        r["data"].update(gear=dict(L3_GEAR), power_level=0.0, position=list(L3_HERE))
        return r
    rig.game.get_state = get_state


def test_request_done_result_carries_his_power_level_and_the_vault_the_ask_names(tmp_path):
    import pytest

    from brain.places import Places, newest_file
    if newest_file() is None:
        pytest.skip("no data/places_<build>.json")
    rig = Rig(tmp_path)
    _as_l3(rig)
    rig.controller.places = Places()
    vault = "claude, gear up for the vault"
    rig.controller_llm.push(FakeLLM.say("", FakeLLM.call("gather", resource="log", count=1)), FakeLLM.say(""),
                            FakeLLM.say("all set", FakeLLM.call("request_done", evidence="Bronze Shield equipped")))
    rig.agent._command(CommandReceived(player="Luis", text=vault))
    assert rig.agent._open_request is None  # the close stands: nothing reopens it
    claimed, = _rows(rig, "request_done_claimed")
    reads = claimed["game_reads"]
    assert reads["your_power_level"] == {"from_worn_armour": 1, "game_reads": 0, "worn_armour": [
        "Leather Cowl PL 2", "Adventurer's Tunic PL 1", "Adventurer's Leggings PL 1"]}
    place, = reads["places"]
    assert {k: place[k] for k in ("name", "kind", "power_level", "enemies_pl", "said")} == {
        "name": "Crasorak Kara", "kind": "vault", "power_level": 2, "enemies_pl": 2, "said": "vault (the nearest)"}
    assert "job" not in reads  # no item named: no tree
    # facts only: no verdict or advice in code's words
    text = json.dumps(reads).lower()
    assert not any(w in text for w in ("should", "not done", "reopen", "enough", "too low", "need"))
    # his close is still his stop (the chain gives no turn after request_done alone): the result is in the log only
    assert len(rig.controller_llm.calls) == 3


def test_request_done_result_carries_the_job_trees_root_read_before_the_tree_closes(tmp_path, monkeypatch):
    from brain import job_tree as jt
    from brain.llm import ToolCall
    from test_job_tree import LINE, data
    monkeypatch.setenv("DW_JOB_TREE", "1")
    monkeypatch.setattr(jt.GameData, "default", classmethod(lambda cls, knowledge=None, places=None: data()))
    rig = Rig(tmp_path)
    ask = ("Luis", LINE)
    rig.agent._open_request = ask
    rig.agent.jobs.open(ask)
    res = rig.agent._close_ask(ToolCall(name="request_done", arguments={"evidence": "ore is in the chest"}), [])
    assert res["ok"] is True and res["note"] == "request closed as finished"
    job = res["game_reads"]["job"]
    assert job["done"] is False and job["target"][0].startswith("Copper Ore: you carry 0 of 30 [")
    assert "places" not in res["game_reads"]  # no Places attached to this controller
    assert rig.agent._open_request is None and not rig.agent.jobs.active(ask)  # closed all the same
    assert _rows(rig, "request_done_claimed")[0]["game_reads"]["job"] == job


def test_park_request_result_has_no_game_reads_and_an_unreadable_state_says_so(tmp_path):
    from brain.llm import ToolCall
    rig = Rig(tmp_path)
    rig.agent._open_request = ASK
    res = rig.agent._close_ask(ToolCall(name="park_request", arguments={"reason": "no trees"}), [])
    assert res == {"ok": True, "note": "request parked"}
    rig.agent._open_request = ASK
    rig.agent._fresh_state = lambda reuse=False, after_action=False: {"unavailable": "get_state failed: timeout"}
    res = rig.agent._close_ask(ToolCall(name="request_done", arguments={"evidence": "2 logs"}), [])
    assert res["game_reads"] == {"unavailable": "get_state failed: timeout"} and rig.agent._open_request is None
