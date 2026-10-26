"""Fixes from the first observed M1 session (2026-10-26 17:50-18:25 UTC, brain-live-20261026-185027-7136.jsonl).

1. A chat line buffered just before a body request started (it arrived during the model call) never interrupted
   the wait: 17:57:25 waited 72 s behind a go_to, 18:02:37 26 s behind a craft (bridge_client ``seen`` started at
   the buffer's end).
2. After ONE client relaunch every later watched command failed body_restarted (18:05-18:24, 40+ failures): the
   client kept the old bridge start time as its reference.
3. A proactive review ran while a chat line sat in the stash (peeked by ``_player_spoke``): 17:53:42 waited 140 s.
4. The Director's budget-wait template promised ("I'll plan my next step ... in about 9 min"), a
   talk_without_action anomaly at 18:08:07; it now states the wait.
"""
from __future__ import annotations

from brain.interface import ChatHeard, CommandReceived
from brain.jsonl_log import JsonlLogger


class Stub:
    """A body that answers pings with ``beats`` and never answers the action itself."""

    def __init__(self, beats=None):
        self.sent, self.push, self.beats = [], [], list(beats or [])

    def send(self, msg):
        self.sent.append(msg)
        if msg["tool"] == "ping":
            data = self.beats.pop(0) if self.beats else {"pong": True}
            self.push.insert(0, {"v": 1, "type": "result", "id": msg["id"], "ok": True, "reason": None, "data": data})

    def receive(self, timeout):
        out, self.push = self.push, []
        return out


def _client(tmp_path, monkeypatch, stub):
    from brain import bridge_client as bc
    monkeypatch.setattr(bc, "HEARTBEAT_S", 0.0)
    monkeypatch.setattr(bc, "WATCH_AFTER_S", 0.0)
    c = bc.BridgeClient(stub, JsonlLogger(tmp_path / "b.jsonl"))
    c._started = 5
    return c


def test_a_line_buffered_before_the_request_interrupts_its_wait(tmp_path, monkeypatch):
    c = _client(tmp_path, monkeypatch, Stub())
    c._events.append(ChatHeard(player="Tester", text="claude what's in your bag"))  # arrived during the model call
    c.interrupt_check = lambda ev: isinstance(ev, ChatHeard)
    res = c.request("go_to", {"target": [1, 2, 3]}, timeout=30)
    assert res["reason"] == "interrupted", res


def test_after_one_restart_the_next_command_is_not_failed_again(tmp_path, monkeypatch):
    stub = Stub([{"pong": True, "started": 9, "action": None}])  # the client was relaunched: new start time
    c = _client(tmp_path, monkeypatch, stub)
    first = c.request("go_to", {"target": [1, 2, 3]}, timeout=30)
    assert first["reason"] == "body_restarted"
    assert c._started == 9  # the new bridge is the reference now
    stub.beats = [{"pong": True, "started": 9, "action": None}] * 3
    stub.push = []
    from brain import bridge_client as bc
    monkeypatch.setattr(bc, "LOST_AFTER_BEATS", 99)
    second = c.request("go_to", {"target": [1, 2, 3]}, timeout=0.2)
    assert second["reason"] != "body_restarted", second


def test_no_review_or_situation_run_while_a_chat_line_is_stashed(tmp_path):
    from test_event_hygiene import STATES, Replay
    r = Replay(tmp_path, STATES[5])
    r.agent._stash.append(ChatHeard(player="Zezima", text="claude go and gather some berries"))
    assert r.agent._chat_stashed()
    r.agent._situations.append({"type": "situation_review", "changes": []})
    calls = len(r.model.calls)
    r.agent.flush_situations()
    assert len(r.model.calls) == calls  # the chat run goes first and takes the situation along
    r.agent._stash = [CommandReceived(player="Zezima", text="hi")]
    assert r.agent._chat_stashed()
    r.agent._stash = []
    assert not r.agent._chat_stashed()


def test_the_budget_wait_line_states_the_wait_without_a_promise():
    import inspect
    from brain import director
    src = inspect.getsource(director.Director._dispatch)
    assert "I'll plan my next step" not in src and "once my planning budget frees up" in src
