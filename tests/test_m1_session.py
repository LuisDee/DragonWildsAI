"""tools/m1_session.py: the M1 session driver sends nothing without --sender speech_direct --confirm, needs a mark
(the spend baseline) first, and stops at the session spend limit."""
from __future__ import annotations

from tools import m1_session as m


def _env(tmp_path, monkeypatch, spend):
    monkeypatch.setenv("DW_LOG_DIR", str(tmp_path))
    vals = iter(spend)
    monkeypatch.setattr(m, "spent_today", lambda: next(vals))
    monkeypatch.setattr(m.time, "sleep", lambda s: None)


def test_chat_needs_a_mark_first(tmp_path, monkeypatch):
    _env(tmp_path, monkeypatch, [1.0])
    assert m.main(["chat", "--minutes", "1"]) == 2


def test_speech_direct_needs_confirm(tmp_path, monkeypatch):
    _env(tmp_path, monkeypatch, [1.0])
    assert m.main(["chat", "--sender", "speech_direct"]) == 2


def test_dry_chat_logs_lines_and_stops_at_the_spend_limit(tmp_path, monkeypatch):
    _env(tmp_path, monkeypatch, [1.0, 1.1, 1.2, 5.0])
    sent = []
    monkeypatch.setattr(m, "send_speech_direct", lambda text: sent.append(text) or (True, ""))
    assert m.main(["mark", "A1", "--note", "effort off"]) == 0
    assert m.main(["chat", "--minutes", "60"]) == 3  # 1.0 -> 5.0 is over the $3 limit
    chats = [r for r in m.rows() if r["kind"] == "chat"]
    assert len(chats) == 2 and all(r["sender"] == "none" for r in chats) and sent == []
    assert m.rows()[-1]["kind"] == "stop"


def test_phases_and_plan():
    rs = [{"kind": "mark", "phase": "A1", "ts": 10.0}, {"kind": "chat", "ts": 11.0}, {"kind": "mark", "phase": "B1", "ts": 20.0}]
    assert m.phases(rs) == [("A1", 10.0, 20.0), ("B1", 20.0, None)]
    est = m.estimate(2.0, 30)
    assert est["chat_lines"] == 60 and est["usd_estimate"] <= est["usd_limit"]
