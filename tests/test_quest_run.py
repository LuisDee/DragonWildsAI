"""tools/quest_run.py: the human time bar (Luis has no quest baseline) and the preflight's driver check."""
from __future__ import annotations

import time

from tools import quest_run as q

B = {"families": {"craft": {"unit_s": 9.6}, "cook": {"unit_s": 15.0}, "kill": {"unit_s": 20.0}, "pickup": {"unit_s": 1.0},
                  "build": {"unit_s": 4.0}, "spell": {"unit_s": 9.0}},
     "constants": {"REACT_S": 1.5}, "travel_speed_mps": 6.25,
     "windows": [{"family": "chop", "unit_s": 30.0, "units": 1, "gained": {"ITEM_Resources_Wood_Ash": 10}}]}


def _state(ts, x, y):
    return {"kind": "bridge_recv", "ts": ts, "msg": {"data": {"hydration": 50, "position": [x, y, 0]}}}


def _result(ts, tool, ok, **data):
    return {"kind": "tool_result", "ts": ts, "tool": tool, "result": {"ok": ok, "data": data}}


def test_the_bar_counts_successful_steps_at_his_pace_and_reading_time():
    rows = [_state(0, 0, 0),
            _result(5, "go_to", False, detail="path_blocked"),           # a miss: nothing
            _state(6, 100, 0),                                            # ...but it moved him 100 m
            _result(10, "go_to", True), _state(11, 62.5, 0),              # the step ends 62.5 m from the start
            _result(20, "talk", True, lines=[{"text": " ".join(["w"] * 238)}]),  # 238 words: 60 s to read
            _result(30, "craft", True, crafts=1),
            _result(40, "craft", True, crafts=1, fuel_used={"ITEM_Resources_Wood_Ash": 1}),  # a fuelled station: cook
            _result(50, "gather", True, detail="Got 4 ash.", trains="Woodcutting"),          # chop: 3 s per log
            {"kind": "event", "ts": 55, "event": {"type": "activity", "kind": "combat_end", "outcome": "killed", "kills": 2, "by": "reflex"}},
            _result(60, "quests", True), {"kind": "tool_result", "ts": 61, "tool": "inventory", "read_only": True, "result": {"ok": True}}]
    rows[-2]["read_only"] = True
    h = q.human_bar(rows, lines_sent=1, b=B)
    assert h["walk_m"] == 62 and h["steps"] == 5
    assert h["parts"] == {"walk": 10.0, "read": 60.0, "craft": 9.6, "cook": 15.0, "chop": 12.0, "kill": 40.0, "react": 9.0}
    assert h["human_s"] == 155.6


def test_the_real_baseline_file_gives_his_chop_rate():
    b = q._baseline()
    assert abs(q._per_item(b, "chop") - 40.94 / 13) < 0.01  # 13 Ash Logs in 40.94 s


def test_pure_reads_are_not_driving(tmp_path, monkeypatch):
    now = time.time()
    rows = {"debug_to_client.jsonl": [{"ts": now - 20, "tool": "move_status"}, {"ts": now - 10, "tool": "inventory"}],
            "brain_to_client.jsonl": []}
    monkeypatch.setattr(q.cl, "_tail_rows", lambda path: rows.get(path.name, []))
    assert q.driver() is None
    rows["debug_to_client.jsonl"].append({"ts": now - 5, "tool": "go_to"})
    assert "go_to" in q.driver()


def test_reflex_fights_are_work_not_a_stand_and_keep_the_run_from_ending_quiet():
    # live 19:38Z (ClaudeQ3, Ratcatcher): after his last call at 110.5 s the combat reflex fought, fled and fought
    # back for 40 s; the run ended "quiet" mid-fight and counted a 40.6 s stand
    t0 = 1000.0
    act = lambda kind, t: {"kind": "event", "ts": t0 + t + 0.3, "event": {"type": "activity", "kind": kind, "ts": t0 + t}}
    rows = [{"kind": "tool_call", "call": "a", "tool": "attack", "ts": t0 + 100}, {"kind": "tool_result", "call": "a",
            "tool": "attack", "ts": t0 + 110.5, "result": {"ok": False, "reason": "interrupted", "data": {}}},
            act("combat_started", 107.3), act("flee_started", 130.1), act("creature_ability", 131), act("healed", 132.3),
            act("flee_failed", 141.8)]
    tl = q.timeline(rows, t0)
    assert tl["body_busy"] == ["combat"]  # the fight is still on: the run is not quiet
    assert tl["last_busy"] >= t0 + 141.8
    rows.append(act("combat_end", 150.0))
    tl = q.timeline(rows, t0, t_end=t0 + 160)
    assert tl["body_busy"] == [] and tl["last_busy"] == t0 + 150.0
    assert tl["idle"][1:] == [{"from": 150.0, "s": 10.0, "to_end": True}]  # after his call, only the stand after the fight


def test_an_anima_vent_interact_is_let_go_once_and_recorded():
    sent, done = [], []
    send = lambda f, name, args, t: sent.append(name) or {"ok": True, "result": {"ok": True}}  # noqa: E731
    calls = [{"tool": "interact", "args": {"target": "BP_AnimaVent_C_UAID_1"}, "t": 391.3, "dur_s": 6.7, "ok": True},
             {"tool": "interact", "args": {"target": "BP_Chest_C_1"}, "t": 400.0, "dur_s": 1.0, "ok": True},
             {"tool": "interact", "args": {"target": "BP_AnimaVent_C_UAID_2"}, "t": 410.0, "dur_s": None, "ok": None}]
    q.hold_release(calls, done, time.time(), send)
    q.hold_release(calls, done, time.time(), send)  # the next poll: not again
    assert sent == ["quest_hold_release"] and done[0]["after"] == 391.3 and done[0]["ok"] is True


def test_an_open_dialogue_is_left_by_name_and_checked_closed():
    class Cli:
        def __init__(self):
            self.open, self.sent = True, []

        def request(self, tool, args, timeout=None):
            self.sent.append((tool, args))
            if tool == "get_state":
                return {"ok": True, "data": {"conversation": {"npc": "Doric", "speaker": "Doric"}} if self.open else {}}
            self.open = False
            return {"ok": True, "data": {"detail": "The conversation ended."}}
    c = Cli()
    assert q.leave_dialogue(c, settle_s=0) == [{"npc": "Doric", "ok": True, "reason": None, "detail": "The conversation ended."}]
    assert c.sent == [("get_state", {}), ("talk", {"target": "Doric", "leave": True}), ("get_state", {})]
    assert q.leave_dialogue(c, settle_s=0) == []  # nothing open: one read, nothing pressed
