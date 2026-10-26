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


GOOD_ROW = {"type": "chat", "from": "Tester", "self": False, "text": m.PROOF_LINE}


def test_proof_checks_pass_only_when_every_condition_holds():
    ok = m.proof_checks(GOOD_ROW, True, [True] * 6, 3.0, [])
    assert all(ok.values())
    assert not m.proof_checks({**GOOD_ROW, "from": "Zezima"}, True, [True] * 6, 3.0, [])["not_a_real_player_name"]
    assert not m.proof_checks({**GOOD_ROW, "from": "Claude"}, True, [True] * 6, 3.0, [])["from_is_the_test_name"]
    assert not m.proof_checks({**GOOD_ROW, "self": True}, True, [True] * 6, 3.0, [])["non_self"]
    assert not m.proof_checks(GOOD_ROW, True, [True, False, True], 3.0, [])["client_answered_every_ping"]
    assert not m.proof_checks(GOOD_ROW, True, [True] * 6, 90.0, [])["client_log_fresh"]
    assert not m.proof_checks(GOOD_ROW, True, [True] * 6, 3.0, ["client_hang"])["no_watchdog_hang_or_crash"]
    assert not m.proof_checks(None, False, [], None, [])["logged_in_chat"]


def test_proof_needs_confirm_and_chat_needs_a_passed_proof(tmp_path, monkeypatch):
    _env(tmp_path, monkeypatch, [1.0, 1.0])
    assert m.main(["proof"]) == 2
    assert m.main(["mark", "A1"]) == 0
    assert m.main(["chat", "--sender", "speech_direct", "--confirm"]) == 2  # no passed proof in the log


def test_proof_run_records_its_checks(tmp_path, monkeypatch):
    _env(tmp_path, monkeypatch, [1.0])
    clock = {"t": 1000.0}
    monkeypatch.setattr(m.time, "time", lambda: clock["t"])
    monkeypatch.setattr(m.time, "sleep", lambda s: clock.__setitem__("t", clock["t"] + s))
    monkeypatch.setattr(m, "send_speech_direct", lambda text: (True, "ok"))
    monkeypatch.setattr(m, "_chat_rows_since", lambda t0: [GOOD_ROW])
    monkeypatch.setattr(m, "_brain_heard_since", lambda t0, who: True)
    monkeypatch.setattr(m, "client_ping", lambda: True)
    monkeypatch.setattr(m, "mod_log_age_s", lambda: 2.0)
    monkeypatch.setattr(m, "watchdog_trouble_since", lambda t0: [])
    assert m.main(["proof", "--confirm"]) == 0
    row = [r for r in m.rows() if r["kind"] == "proof"][-1]
    assert row["passed"] and len(row["pings"]) == m.HEALTH_WATCH_S // m.HEALTH_EVERY_S


def test_m1_run_detects_a_real_brain_start():
    import json as _j
    from tools import m1_run
    pong = _j.dumps({"ts": 105.0, "kind": "bridge_recv", "msg": {"data": {"pong": True}, "ok": True}})
    other = _j.dumps({"ts": 106.0, "kind": "foliage"})
    old = _j.dumps({"ts": 50.0, "kind": "prompt"})
    assert m1_run.brain_started([other, pong], since=100.0)
    assert m1_run.brain_started([_j.dumps({"ts": 101.0, "kind": "prompt"})], since=100.0)
    assert not m1_run.brain_started([old, other, "not json"], since=100.0)
    live = open(next(iter(sorted(__import__("pathlib").Path("logs").glob("brain-live-20261026-171238-*.jsonl")))), encoding="utf-8") \
        if list(__import__("pathlib").Path("logs").glob("brain-live-20261026-171238-*.jsonl")) else None
    if live:  # the 17:12:38 run the old check missed
        with live:
            assert m1_run.brain_started(live, since=1793031150.0)
