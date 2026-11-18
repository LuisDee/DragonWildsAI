"""The open ask survives a brain restart (brain/ask_store.py; goal item 1 of docs/GOAL-2026-11-17-long-jobs.md).

Run 20261118-021010-N1-I5: the brain was killed 4 s into a gather for the chest job; the new brain knew no ask and boiled
water. Now the ask is written to the world store whenever it changes and read back at startup; the first turn gets
``where_you_were`` (the ask, how long ago, the game now, a lost call said as unknown). A done ask removes the file; the
harness clears a world with ``ask_store.clear_world``. Offline: scripted LLMs and the mock game.
"""
import json

import pytest
from conftest import Rig

from brain import ask_store
from brain import open_ask as oa
from brain.interface import CommandReceived
from brain.llm import FakeLLM

ASK = ("Luis", "claude, chop me 2 logs")


def _rows(rig, kind):
    return [r for r in rig.log.read_all() if r.get("kind") == kind]


def _rig(tmp_path, name="a"):
    rig = Rig(tmp_path / name)
    wd = tmp_path / "state" / "worlds" / "dev_ClaudeDev"
    rig.agent.attach_ask_store(wd)
    return rig, wd


def _ask(rig, *replies):
    rig.controller_llm.push(*replies)
    rig.agent._command(CommandReceived(player=ASK[0], text=ASK[1]))


def _saved(wd):
    return json.loads((wd / ask_store.FILE).read_text(encoding="utf-8"))


def test_the_ask_is_on_disk_as_soon_as_it_is_heard(tmp_path):
    rig, wd = _rig(tmp_path)
    seen = {}

    def first_reply(*a, **k):  # read the file while the first model call runs (a kill here must not lose the ask)
        seen.update(_saved(wd))
        return FakeLLM.say("")
    rig.controller_llm.push(first_reply, FakeLLM.say(""))
    rig.agent._command(CommandReceived(player=ASK[0], text=ASK[1]))
    assert seen["words"] == ASK[1] and seen["player"] == "Luis" and seen["state"] == "open"
    assert isinstance(seen["asked_unix"], (int, float)) and seen["baseline"]["inventory"] is not None


def test_a_body_call_is_in_flight_on_disk_while_it_runs_and_a_step_after(tmp_path):
    rig, wd = _rig(tmp_path)
    during = {}
    run = rig.executor.run_task

    def spy(task):
        during.update(_saved(wd))
        return run(task)
    rig.executor.run_task = spy
    _ask(rig, FakeLLM.say("", FakeLLM.call("gather", resource="log", count=1)), FakeLLM.say(""), FakeLLM.say(""))
    assert during["in_flight"]["tool"] == "gather" and during["in_flight"]["args"]["resource"] == "log"
    rec = _saved(wd)
    assert rec["in_flight"] is None
    step, = rec["steps"]
    assert step["tool"] == "gather" and step["ok"] is True


def test_request_done_removes_the_file_and_park_keeps_it_parked(tmp_path):
    rig, wd = _rig(tmp_path)
    _ask(rig, FakeLLM.say("", FakeLLM.call("gather", resource="log", count=2)), FakeLLM.say(""),
         FakeLLM.say("", FakeLLM.call("request_done", evidence="2 logs in my bag")))
    assert not (wd / ask_store.FILE).exists()
    rig2, wd2 = _rig(tmp_path, "b")
    why = "no trees left near here"
    _ask(rig2, FakeLLM.say("", FakeLLM.call("gather", resource="log", count=1)), FakeLLM.say(""),
         FakeLLM.say("", FakeLLM.call("park_request", reason=why)))
    rec = _saved(wd2)
    assert rec["state"] == "parked" and rec["park_reason"] == why and rec["words"] == ASK[1]


def test_a_kept_fact_is_written_with_the_ask(tmp_path):
    rig, wd = _rig(tmp_path)
    _ask(rig, FakeLLM.say(""), FakeLLM.say(""))
    rig.agent._serving_ask = ASK
    rig.agent._keep_ask_fact("node:Copper", "explore 'copper' not_found", "Copper Ore Node: Bone pickaxe or better")
    f, = _saved(wd)["facts"]
    assert f["text"].startswith("Copper Ore Node") and isinstance(f["t_unix"], (int, float))


def test_a_restart_brings_the_ask_back_and_the_first_turn_hears_where_he_was(tmp_path):
    rig, wd = _rig(tmp_path)

    def killed(task):  # the brain dies while the body's gather runs: its result is never seen
        raise KeyboardInterrupt
    rig.executor.run_task = killed
    with pytest.raises(KeyboardInterrupt):
        _ask(rig, FakeLLM.say("on it", FakeLLM.call("gather", resource="log", count=2)))
    assert _saved(wd)["in_flight"]["tool"] == "gather"

    new = Rig(tmp_path / "new")  # a new brain process on the same world
    chest = {"BP_Crate_C_1": {"name": "Crate", "position": [169.0, 1888.0, 0.0], "mine": True,
                              "items": {"log": 3}, "t": 0}}
    new.agent.attach_ask_store(wd, containers=chest)
    assert new.agent._open_request == ASK
    restored, = _rows(new, "ask_restored")
    assert restored["request"] == ASK[1] and restored["state"] == "open" and restored["lost_call"] == "gather"
    new.controller_llm.push(FakeLLM.say(""), FakeLLM.say(""))
    new.agent.flush_situations()
    first = new.controller_llm.calls[0]
    text = json.dumps(first["messages"], ensure_ascii=False)
    assert "brain_restarted" in text and ask_store.LOST_CALL in text and ASK[1] in text
    ctx = next(json.loads(m["content"][m["content"].index("{"):]) for m in first["messages"]
               if "brain_restarted" in str(m.get("content")))
    w = (ctx.get("body_event") or ctx)["where_you_were"]
    assert w["open_request"]["words"] == ASK[1] and isinstance(w["open_request"]["asked_s_ago"], int)
    assert w["call_running_when_stopped"]["tool"] == "gather"
    assert w["game_now"]["carried"] == ask_store.carried(new.agent._fresh_state()) and restored["carried_read"]
    assert w["game_now"]["containers_seen"][0]["container"].startswith("your Crate")
    # code gives facts, never advice
    note = json.dumps(w).replace(ASK[1], "")
    assert not any(x in note.lower() for x in ("should", "continue", "next step")), note
    # the restored ask is the open one: his silent stop gets the open-ask turn, changes read against the saved baseline
    opened = [c for c in new.controller_llm.calls if str(c["messages"][-1].get("content") or "").startswith(oa.NOTE_PREFIX)]
    assert len(opened) == 1
    shown = json.loads(opened[0]["messages"][-1]["content"][len(oa.NOTE_PREFIX):])["open_request"]
    assert shown["words"] == ASK[1] and shown["changed_since_asked"] != "unknown: no state read from when it was asked"
    assert _saved(wd)["in_flight"] is None  # said once; the next save drops it


def test_a_parked_ask_comes_back_parked(tmp_path):
    rig, wd = _rig(tmp_path)
    _ask(rig, FakeLLM.say("", FakeLLM.call("gather", resource="log", count=1)), FakeLLM.say(""),
         FakeLLM.say("", FakeLLM.call("park_request", reason="need an axe first")))
    new = Rig(tmp_path / "new")
    new.agent.attach_ask_store(wd)
    assert new.agent._open_request is None and new.agent._parked["ask"] == ASK
    assert new.agent._situations[-1]["where_you_were"]["open_request"]["park_reason"] == "need an axe first"


def test_the_harness_clears_a_world_and_nothing_comes_back(tmp_path):
    rig, wd = _rig(tmp_path)
    _ask(rig, FakeLLM.say(""), FakeLLM.say(""))
    assert ask_store.clear_world("dev_ClaudeDev", tmp_path / "state") is True
    assert ask_store.clear_world("dev_ClaudeDev", tmp_path / "state") is False
    new = Rig(tmp_path / "new")
    new.agent.attach_ask_store(wd)
    assert new.agent._open_request is None and new.agent._situations == [] and not _rows(new, "ask_restored")
    # other worlds are untouched: one file per world guid
    other = tmp_path / "state" / "worlds" / "dev_Other"
    ask_store.save(other, {"player": "Luis", "words": "x", "state": "open"})
    assert ask_store.clear_world("dev_ClaudeDev", tmp_path / "state") is False and ask_store.load(other)


def test_a_new_line_replaces_the_saved_ask(tmp_path):
    rig, wd = _rig(tmp_path)
    _ask(rig, FakeLLM.say(""), FakeLLM.say(""))
    rig.controller_llm.push(FakeLLM.say(""), FakeLLM.say(""))
    rig.agent._command(CommandReceived(player="Luis", text="claude, bring me stone"))
    rec = _saved(wd)
    assert rec["words"] == "claude, bring me stone" and rec["steps"] == []


def test_no_store_attached_writes_nothing(tmp_path):
    rig = Rig(tmp_path)
    _ask(rig, FakeLLM.say(""), FakeLLM.say(""))
    assert not list(tmp_path.rglob(ask_store.FILE))
