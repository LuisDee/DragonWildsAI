"""tools/quest_run.py: the human time bar (Luis has no quest baseline) and the preflight's driver check."""
from __future__ import annotations

import json
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


def test_a_window_does_not_start_on_uncommitted_code(tmp_path, capsys):
    import argparse
    import subprocess
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    (tmp_path / "client_mod").mkdir()
    (tmp_path / "docs").mkdir()
    (tmp_path / "docs" / "note.md").write_text("x")           # outside the code a window plays with
    assert q.dirty_code(tmp_path) == []
    (tmp_path / "client_mod" / "combat.lua").write_text("x")  # an unfinished file the running client would hot-load
    rows = q.dirty_code(tmp_path)
    assert len(rows) == 1 and "client_mod" in rows[0]
    assert q.refuse_dirty(argparse.Namespace(dirty_ok=None), rows) is True
    assert "combat.lua" in capsys.readouterr().out or "client_mod" in rows[0]
    assert q.refuse_dirty(argparse.Namespace(dirty_ok="a log line only"), rows) is False
    assert q.refuse_dirty(argparse.Namespace(dirty_ok=None, in_lock=True), rows) is False  # inside a window
    assert q.refuse_dirty(argparse.Namespace(dirty_ok=None), []) is False


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


def test_a_detached_call_is_scored_by_its_late_end_not_by_still_running():
    """study misses_1119: 77 of 236 V1 misses were "still_running" (fight news cut the bridge's wait after 2 s while the
    body carried on). Such a call is scored by its bridge_late_result: ok or interrupted is no miss, a failed end is,
    and with no late end there is no failure to count. It is busy until its end."""
    t0 = 1000.0
    run = lambda cid, tool, t: [{"kind": "tool_call", "call": cid, "tool": tool, "ts": t0 + t},
                                {"kind": "tool_result", "call": cid, "tool": tool, "ts": t0 + t + 2,
                                 "result": {"ok": False, "reason": "still_running", "data": {"id": "b" + cid}}}]
    # the late end carries the bridge's request id (data.id above); its "call" is the turn's, not the detached one's
    late = lambda cid, tool, t, ok, why: {"kind": "bridge_late_result", "id": "b" + cid, "call": "toolu_x", "tool": tool,
                                          "ts": t0 + t, "ok": ok, "reason": why}
    rows = (run("a", "go_to", 10) + [late("a", "go_to", 40, True, None)] + run("b", "gather", 50)
            + [late("b", "gather", 60, False, "interrupted")] + run("c", "attack", 70)
            + [late("c", "attack", 80, False, "unknown_target")] + run("d", "explore", 90))
    tl = q.timeline(sorted(rows, key=lambda r: r["ts"]), t0, t_end=t0 + 95)
    by = {c["tool"]: c for c in tl["calls"]}
    assert by["go_to"]["ok"] is True and by["go_to"]["late_s"] == 30.0 and by["gather"]["reason"] == "interrupted"
    assert [m["tool"] for m in q.verdict({"tool_calls": tl["calls"]})["misses"]] == ["attack"]
    assert not any(i["from"] < 40 for i in tl["idle"] if i["from"] >= 12)  # the walk ran on: no stand inside it


def _run_060504():
    from pathlib import Path
    return json.loads((Path(__file__).parent / "fixtures" / "job_run_060504_timeline.json").read_text(encoding="utf-8"))


def test_run_060504_the_walk_he_was_on_at_the_end_is_work_not_a_stand():
    """Run 20261119-060504 (L2 V1): the Bone Pickaxe made at 517.7 s, equipped by 518.4 s, then go_to Fractured
    Plains from 518.8 s, still walking when the harness read the job done at 527.6 s. The open go_to was counted as a
    9.2 s stand to the end; the six stands before it (Planner and turn assembly) are his."""
    run = _run_060504()
    rows, end = run["rows"], run["wall_s"]
    tl = q.timeline(rows, 0.0, end)
    assert [c["tool"] for c in tl["calls"] if c["dur_s"] is None] == ["go_to"]
    assert not any(i.get("to_end") for i in tl["idle"])
    assert [(i["from"], i["s"]) for i in tl["idle"]] == [(7.1, 5.2), (58.1, 6.5), (202.0, 6.5), (209.3, 9.2),
                                                         (218.9, 7.4), (489.5, 5.6)]
    assert tl["idle"] == q.timeline(rows, 0.0, end, t_done=run["job_done_s"])["idle"]  # done read at its end
    # the same tail without the walk: he stood from 518.4 s, a stand to the end unless the job read done before it
    still = [r for r in rows if r.get("tool") != "go_to" or r["ts"] < 518.5]
    assert q.timeline(still, 0.0, end)["idle"][-1] == {"from": 518.4, "s": 9.2, "to_end": True}
    assert q.timeline(still, 0.0, end, t_done=518.1)["idle"] == tl["idle"]  # done by a read at 518.1 s: not counted
    assert q.timeline(still, 0.0, end, t_done=525.0)["idle"][-1] == {"from": 518.4, "s": 6.6, "to_end": True}


def test_a_read_only_call_left_open_is_no_work_and_a_stand_before_the_done_read_counts():
    t0 = 1000.0
    rows = [{"kind": "prompt", "ts": t0 + 1}, {"kind": "llm_response", "ts": t0 + 2},
            {"kind": "tool_call", "task_id": "w", "tool": "gather", "ts": t0 + 3},
            {"kind": "tool_result", "task_id": "w", "tool": "gather", "ts": t0 + 10, "result": {"ok": True}},
            {"kind": "tool_call", "tool": "look", "ts": t0 + 11}]  # no ids, no result: never busy
    tl = q.timeline(rows, t0, t0 + 30)
    assert tl["idle"] == [{"from": 10.0, "s": 20.0, "to_end": True}]
    tl = q.timeline(rows, t0, t0 + 30, t_done=t0 + 22)
    assert tl["idle"] == [{"from": 10.0, "s": 12.0, "to_end": True}]  # counted up to the done read
    rows = rows + [{"kind": "tool_call", "task_id": "g2", "tool": "go_to", "ts": t0 + 40},
                   {"kind": "tool_result", "task_id": "g2", "tool": "go_to", "ts": t0 + 50, "result": {"ok": True}}]
    tl = q.timeline(rows, t0, t0 + 60, t_done=t0 + 45)
    assert tl["idle"] == [{"from": 10.0, "s": 30.0}]  # a stand wholly before the done read is his


def test_a_hold_that_kept_him_in_place_is_read_from_the_body_results_only():
    calls = [{"tool": "interact", "args": {"target": "BP_AnimaVent_C_UAID_1"}, "t": 391.3, "dur_s": 6.7, "ok": True},
             {"tool": "go_to", "t": 400.0, "ok": True, "reason": None,
              "detail": "I let go of the Water Anima Vent first (holding it kept me in place). Walked 30 m in 9 s"},
             {"tool": "go_to", "t": 420.0, "ok": False, "reason": "rooted", "detail": "I'm held in place by the Air Anima Vent"},
             {"tool": "gather", "t": 430.0, "ok": True, "reason": None, "detail": "Got 35 ash."}]
    assert [(h["tool"], h["t"], h["reason"]) for h in q.holds(calls)] == [("go_to", 400.0, None), ("go_to", 420.0, "rooted")]


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


def test_a_quest_deliverable_held_at_the_start_is_found_by_the_quest_and_tools_are_not():
    class Cli:
        def request(self, tool, args, timeout=None):
            return {"ok": True, "data": {"inventory": {"ITEM_Club_Stone": 2, "ITEM_Pickaxe_Stone": 1,
                                                       "ITEM_Consumable_Meat_Rat_Roast": 4, "ITEM_Rune_Air": 0}}}
    assert q.carried(Cli(), "Getting Started") == {"ITEM_Club_Stone": 2}
    assert q.carried(Cli(), "Ratcatcher") == {"ITEM_Consumable_Meat_Rat_Roast": 4}
    assert q.carried(Cli(), "Rune Mysteries") == {}  # a pickaxe is how he works, and 0 air runes is none
    assert q.carried(Cli(), "First Steps") == {}


def test_a_leftover_under_a_tenth_of_what_the_quest_asks_is_not_a_head_start():
    # chain 101313: one Ash Log left from the fire of the quest before, 49 of Zanik's 50 chopped, "not counted"
    assert q.head_start({"ITEM_Resources_Wood_Ash": 1}, "Rune Mysteries") == {}
    assert q.head_start({"ITEM_Resources_Wood_Ash": 5}, "Rune Mysteries") == {"ITEM_Resources_Wood_Ash": 5}
    assert q.head_start({"ITEM_Rune_Essence": 1}, "Rune Mysteries") == {"ITEM_Rune_Essence": 1}  # no amount asked: any
    assert q.head_start({"ITEM_Club_Stone": 1}, "Getting Started") == {"ITEM_Club_Stone": 1}
    assert q.head_start({"error": "boom"}, "Rune Mysteries") == {"error": "boom"}  # an unread bag is never a pass
    rec = {"quest": "Rune Mysteries", "done": True, "ratio": 1.08, "tool_calls": [], "idle_over_5s": [],
           "carried_at_start": {"ITEM_Resources_Wood_Ash": 1}, "not_counted": "deliverable carried: ITEM_Resources_Wood_Ash x1"}
    assert q.verdict(rec)["bars"]["counted"] is True
    rec["carried_at_start"] = {"ITEM_Resources_Wood_Ash": 50}
    assert q.verdict(rec)["bars"]["counted"] is False
    assert q.verdict({**rec, "carried_at_start": None})["bars"]["counted"] is False  # an old record: as it was written


def test_what_he_got_earlier_in_the_same_chain_is_not_a_head_start():
    # chain 112351: 7 Ash Logs chopped in Getting Started (0 at the chain's start), 8 at the start of Rune Mysteries,
    # 42 chopped in the run for a bar that counts 42: "not counted", although every log was his own work on the clock
    held = {"ITEM_Resources_Wood_Ash": 8}
    assert q.head_start(held, "Rune Mysteries", chain={}) == {}
    assert q.head_start(held, "Rune Mysteries", chain={"ITEM_Resources_Wood_Ash": 3}) == {}  # 3 of 50: a leftover
    assert q.head_start(held, "Rune Mysteries", chain={"ITEM_Resources_Wood_Ash": 30}) == {"ITEM_Resources_Wood_Ash": 8}
    assert q.head_start({"ITEM_Club_Stone": 1}, "Getting Started", chain={"ITEM_Club_Stone": 1}) == {"ITEM_Club_Stone": 1}
    assert q.head_start(held, "Rune Mysteries", chain={"error": "boom"}) == held  # the chain's start unread: as alone
    assert q.head_start(held, "Rune Mysteries") == held  # a run on its own: what he holds is a head start
    rec = {"quest": "Rune Mysteries", "done": True, "ratio": 0.84, "tool_calls": [], "idle_over_5s": [],
           "carried_at_start": held, "not_counted": "deliverable carried: ITEM_Resources_Wood_Ash x8"}
    assert q.verdict(rec)["bars"]["counted"] is False
    assert q.verdict({**rec, "held_at_chain_start": {}})["bars"]["counted"] is True


class _Clock:
    """The bench fixture set_time as mod/bench/fixtures.lua answers it: `hours` is the next time that hour comes."""
    def __init__(self, hour, fail_at=None):
        self.t, self.calls, self.fail_at = 1333 * 24 + hour, 0, fail_at

    def setup(self, verb, purpose="", **a):
        if verb == "set_stat":
            self.stats = {**getattr(self, "stats", {}), a["stat"]: a["value"]}
            if a["stat"] == "endurance" and self.fail_at == "endurance":
                raise RuntimeError("fixture set_stat failed: no_EnduranceComponent")
            return {"ok": True, "stat": a["stat"], "after": a["value"] + 0.0000004}
        assert verb == "set_time"
        if a.get("read"):
            return {"ok": True, "hour": self.t % 24, "day": int(self.t // 24)}
        self.calls += 1
        if self.calls == self.fail_at:
            raise RuntimeError("fixture set_time failed: time_unreadable")
        target = self.t - self.t % 24 + a["hours"]
        target += 24 if target <= self.t else 0
        before, self.t = self.t, target
        return {"ok": True, "before_h": before % 24, "after_h": target % 24, "advanced_h": target - before}


def test_the_step_clock_goes_on_whole_days_and_keeps_the_time_of_day():
    for hour in (20.29, 0.02, 23.99):  # also across midnight: the hour asked for wraps
        c = _Clock(hour)
        r = q.clock_on(c, 3, "test")
        assert r["ok"] and r["days"] == 3 and 71.5 < r["advanced_h"] < 72, r
        assert abs(((c.t % 24) - hour + 12) % 24 - 12) < 0.2, (hour, c.t % 24)


def test_a_clock_that_did_not_move_is_said_and_does_not_raise():
    r = q.clock_on(_Clock(20.0, fail_at=2), 3, "test")
    assert r["ok"] is False and r["days"] == 1 and "time_unreadable" in r["error"], r


def test_the_clock_puts_the_forks_food_water_and_rest_back():
    """The server ages the player on it through the skipped days (food and water to 0): what was read before goes back."""
    c = _Clock(5.14)
    r = q.clock_on(c, 3, "test", vitals={"sustenance": 41.2, "hydration": 47.1, "endurance": 89.4})
    assert r["ok"] and r["vitals_back"] == {"sustenance": 41.2, "hydration": 47.1, "endurance": 89.4}, r
    assert c.stats == {"sustenance": 41.2, "hydration": 47.1, "endurance": 89.4}
    c = _Clock(5.14, fail_at="endurance")  # one stat that will not set is said, the others still go back
    r = q.clock_on(c, 3, "test", vitals={"endurance": 89.4, "hydration": 47.1})
    assert r["vitals_back"] == {"hydration": 47.1} and "no_EnduranceComponent" in r["vitals_error"]["endurance"], r
    assert "vitals_back" not in q.clock_on(_Clock(5.14), 1, "test")  # nothing read, nothing set


def test_vitals_of_reads_the_three_bars_and_nothing_else():
    class Cli:
        def request(self, tool, args, timeout=0):
            return {"ok": True, "data": {"survival": {"hydration": [47.1, 100.0], "sustenance": [41.2, 100.0],
                                                      "endurance": [89.4, 100.0], "odd": None}, "health": 100.0}}
    assert q.vitals_of(Cli()) == {"hydration": 47.1, "sustenance": 41.2, "endurance": 89.4}

    class Dead:
        def request(self, tool, args, timeout=0):
            return None
    assert q.vitals_of(Dead()) == {}
