"""A line beside a quick action is held until the action ends (a failure replaces it, single voice). M1
2026-10-26: interact/craft lines were said 62-107 s late. The bridge now reports a watched action that is
accepted and still running (bridge_client.ACCEPTED_AFTER_S or a heartbeat naming its id); the held line is
said then, once. A failure that answers before acceptance still replaces the line."""
from __future__ import annotations

from brain.jsonl_log import JsonlLogger
from brain.llm import FakeLLM


class Stub:
    """A body that answers pings and answers the action only when ``answer`` is set."""

    def __init__(self, answer=None):
        self.sent, self.push, self.answer = [], [], answer

    def send(self, msg):
        self.sent.append(msg)
        if msg["tool"] == "ping":
            self.push.append({"v": 1, "type": "result", "id": msg["id"], "ok": True, "reason": None,
                              "data": {"pong": True}})
        elif self.answer is not None:
            self.push.append({"v": 1, "type": "result", "id": msg["id"], **self.answer})

    def receive(self, timeout):
        out, self.push = self.push, []
        return out


def _client(tmp_path, monkeypatch, stub, accepted_after=0.0):
    from brain import bridge_client as bc
    monkeypatch.setattr(bc, "HEARTBEAT_S", 0.05)
    monkeypatch.setattr(bc, "WATCH_AFTER_S", 0.0)
    monkeypatch.setattr(bc, "ACCEPTED_AFTER_S", accepted_after)
    c = bc.BridgeClient(stub, JsonlLogger(tmp_path / "b.jsonl"))
    c._started = 5
    return c


def test_a_running_action_reports_accepted_once(tmp_path, monkeypatch):
    c = _client(tmp_path, monkeypatch, Stub())
    seen = []
    c.on_long_action = lambda tool, rid: seen.append(tool)
    res = c.request("interact", {"target": "x"}, timeout=0.3)
    assert res["reason"] == "timeout"
    assert seen == ["interact"]


def test_a_quick_answer_is_never_reported_accepted(tmp_path, monkeypatch):
    c = _client(tmp_path, monkeypatch, Stub({"ok": False, "reason": "unknown_target", "data": {}}), accepted_after=5.0)
    seen = []
    c.on_long_action = lambda tool, rid: seen.append(tool)
    res = c.request("interact", {"target": "x"}, timeout=10)
    assert res["reason"] == "unknown_target" and seen == []


def test_held_line_is_said_while_the_action_runs_not_after(rig):
    wolf = rig.game.add_entity("wolf", [6, 0, 0], hp=30, hostile=True)
    rig.game.player_say("kill that wolf")
    order = []
    real_call = rig.game.call

    def call(skill, args):  # the bridge reports the action accepted partway through
        if skill == "attack":
            rig.agent._long_action("attack", "id1")
            order.append(("acted", list(rig.companion_said())))
        return real_call(skill, args)
    rig.game.call = call
    rig.controller_llm.push(FakeLLM.say("going for the wolf", FakeLLM.call("attack", target=wolf)), FakeLLM.say(""))
    rig.agent.step()
    said = rig.companion_said()
    assert order and order[0][1] == ["going for the wolf"]  # said during the action
    assert said.count("going for the wolf") == 1  # and not again after it


def test_a_failure_before_acceptance_still_replaces_the_line(rig):
    wolf = rig.game.add_entity("wolf", [6, 0, 0], hp=30, hostile=True)
    rig.game.script_failure("attack", "path_blocked", times=None)
    rig.game.player_say("kill that wolf")
    rig.controller_llm.push(FakeLLM.say("On it!", FakeLLM.call("attack", target=wolf)))
    rig.agent.step()
    assert "On it!" not in rig.companion_said()
