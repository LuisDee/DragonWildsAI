"""A waiter (cast, move_item, equip ...) is in flight outside the bridge's action slot: the heartbeat lists
waiter ids, and a request that is waiting is never reported lost_by_body (spells agent, 2026-10-26: a 10 s
debug cast came back lost_by_body)."""
from __future__ import annotations

from brain.jsonl_log import JsonlLogger


class Stub:
    def __init__(self):
        self.sent, self.push, self.beats, self.reply_after = [], [], [], 3

    def send(self, msg):
        self.sent.append(msg)
        if msg["tool"] == "ping":
            data = self.beats.pop(0) if self.beats else {"pong": True}
            self.push.insert(0, {"v": 1, "type": "result", "id": msg["id"], "ok": True, "reason": None, "data": data})
        elif msg["tool"] == "cast":
            self.cast_id = msg["id"]

    def receive(self, timeout):
        out, self.push = self.push, []
        pings = [m for m in self.sent if m["tool"] == "ping"]
        if len(pings) >= self.reply_after and getattr(self, "cast_id", None) and not getattr(self, "replied", False):
            self.replied = True
            out.append({"v": 1, "type": "result", "id": self.cast_id, "ok": True, "reason": None, "data": {"verified": True}})
        return out


def test_a_waiting_cast_is_not_lost(monkeypatch, tmp_path):
    from brain import bridge_client as bc
    monkeypatch.setattr(bc, "HEARTBEAT_S", 0.0)
    t = Stub()
    c = bc.BridgeClient(t, JsonlLogger(tmp_path / "b.jsonl"))
    c._started = 5
    orig = t.send

    def send(msg):
        orig(msg)
        if msg["tool"] == "cast":  # the bridge's slot is empty (cast is a waiter), its id is in waiters
            t.beats = [{"pong": True, "started": 5, "action": None, "waiters": [msg["id"]]}] * 5
    t.send = send
    res = c.request("cast", {"spell": "Internal Alchemy"}, timeout=30)
    assert res["ok"] is True, res


def test_a_command_in_neither_the_slot_nor_the_waiters_is_lost(monkeypatch, tmp_path):
    from brain import bridge_client as bc
    monkeypatch.setattr(bc, "HEARTBEAT_S", 0.0)
    t = Stub()
    t.reply_after = 99
    c = bc.BridgeClient(t, JsonlLogger(tmp_path / "b.jsonl"))
    c._started = 5
    t.beats = [{"pong": True, "started": 5, "action": None, "waiters": []}] * 5
    res = c.request("cast", {"spell": "Internal Alchemy"}, timeout=30)
    assert res["reason"] == "lost_by_body", res
