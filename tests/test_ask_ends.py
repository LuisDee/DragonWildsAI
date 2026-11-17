"""tools/ask_ends.py: how a player's ask ended and whether it was done, on short samples cut from real brain logs
(the files and times are named on each sample). Offline: no game, no model, logs/ is not read."""
import json

from tools import ask_ends as AE


def chat(ts, ep, player, text):
    return [{"ts": ts, "kind": "event", "event": {"type": "chat_heard", "player": player, "text": text, "ts": ts},
             "episode_id": ep},
            {"ts": ts, "kind": "chat_decision", "player": player, "text": text, "decision": "addressed",
             "reason": "named or prefixed", "episode_id": ep}]


def call(ts, ep, tool, task, args=None):
    return {"ts": ts, "kind": "tool_call", "task_id": task, "tool": tool, "args": args or {}, "attempt": 1,
            "episode_id": ep}


def fail(ts, ep, tool, task, reason):
    return {"ts": ts, "kind": "task_failed", "task_id": task, "skill": tool, "reason": reason, "attempts": 1,
            "episode_id": ep}


def turn(ts, ep, n, actions, speech=None):
    return {"ts": ts, "kind": "chain_turn", "turn": n, "actions": actions, "speech": speech, "episode_id": ep}


def say(ts, ep, text):
    return {"ts": ts, "kind": "say", "text": text, "voice": "reply", "episode_id": ep}


START = {"ts": 1794837791.0, "kind": "session_start", "player": "Tester"}  # 2026-11-16 14:03Z: era 2
ZANIK = "claude, carry on with Zanik's quest"


def era2_rune_altar():
    """brain-live-20261116-150305-4524: three failed builds, a line asking for help, a silent turn, request_closed."""
    ep = "chat-0001-f0c1"
    return [START, *chat(1794837800.7, ep, "Tester", ZANIK),
            call(1794837806.0, ep, "build", "301938d1"), fail(1794837819.0, ep, "build", "301938d1", "blocked"),
            turn(1794837822.0, ep, 1, ["go_to", "build"]),
            call(1794837822.1, ep, "go_to", "6e7c0048"), fail(1794837882.0, ep, "go_to", "6e7c0048", "path_blocked"),
            call(1794837884.0, ep, "build", "608aa4f9"), fail(1794837937.0, ep, "build", "608aa4f9", "path_blocked"),
            call(1794837939.0, ep, "build", "ec658705"), fail(1794837978.0, ep, "build", "ec658705", "path_blocked"),
            say(1794837982.0, ep, "Stuck on the Rune Altar: every spot I try near here is blocked or unreachable. "
                                  "Can you help me find a clear flat patch to place it?"),
            turn(1794837983.6, ep, 5, []),
            {"ts": 1794837983.653, "kind": "request_closed", "request": ZANIK, "episode_id": ep},
            call(1794837989.0, "review-0002-ce", "go_to", "f24f3f0c")]


def test_era2_request_closed_ends_the_ask_after_failed_calls():
    rows = era2_rune_altar()
    (a,) = AE.reconstruct(rows, name="brain-live-20261116-150305-4524.jsonl", end_ts=1794838100.0)
    assert a.era == 2 and a.ending == "closed_silent" and a.end == 1794837983.653
    assert a.cause == "closed silent after his last call failed"
    assert a.body_calls == 4 and a.failed_calls == 4
    assert a.last_calls == ["go_to failed path_blocked", "build failed path_blocked", "build failed path_blocked"]
    assert a.calls_after == 1  # the review run walked on with no ask open


def test_quest_verdict_joins_by_brain_log_and_line():
    (a,) = AE.reconstruct(era2_rune_altar(), name="brain-live-20261116-150305-4524.jsonl", end_ts=1794838100.0)
    verdicts = {"by_log": {"brain-live-20261116-150305-4524.jsonl": [
        {"source": "quest", "line": AE.norm_line(ZANIK), "done": False, "done_at": None,
         "detail": "quest_run 20261116-140319 Rune Mysteries until=complete ended=deadline"}]}, "lines": {}}
    AE.judge([a], verdicts)
    assert (a.source, a.group, a.verdict, a.verdict_by) == ("quest", "harness", "not_done", "quest")


def test_done_after_the_end_is_done_later_not_done():
    (a,) = AE.reconstruct(era2_rune_altar(), name="x.jsonl", end_ts=1794838100.0)
    row = {"source": "quest", "line": AE.norm_line(ZANIK), "done": True, "detail": ""}
    AE.judge([a], {"by_log": {"x.jsonl": [dict(row, done_at=a.end + 200)]}})
    assert a.verdict == "done_later"
    (b,) = AE.reconstruct(era2_rune_altar(), name="x.jsonl", end_ts=1794838100.0)
    AE.judge([b], {"by_log": {"x.jsonl": [dict(row, done_at=b.end + 10)]}})
    assert b.verdict == "done"


def test_era2_open_at_the_end_of_the_log_is_brain_ended():
    """brain-live-20261117-151932-23576: Ratcatcher; the harness stopped the brain at 'quest complete' with the ask
    still open (no request_closed)."""
    ep = "chat-0001-8a69"
    line = "claude, go and see Vannaka near the windmill and do his quest"
    rows = [START, *chat(1794925185.4, ep, "Tester", line), call(1794925188.0, ep, "talk", "90981d1c"),
            {"ts": 1794925198.0, "kind": "llm_response", "component": "planner", "tool_calls": [], "episode_id": ep},
            call(1794925315.0, "situation-0002", "talk", "78851f3b"), say(1794925317.0, "situation-0002", "done")]
    progress = [{"ts": 1794925192.8, "msg": "goal started", "goal": "Ratcatcher quest"},
                {"ts": 1794925240.4, "msg": "goal done", "goal": "Ratcatcher quest"}]
    (a,) = AE.reconstruct(rows, progress, name="r.jsonl", end_ts=1794925320.0)
    assert a.ending == "brain_ended" and a.planner_calls == 1
    assert [g["outcome"] for g in a.goals] == ["done"]


def test_a_new_line_replaces_the_open_ask():
    rows = [START, *chat(1794837800.0, "chat-0001", "Tester", "claude mine about 10 stone"),
            call(1794837801.0, "chat-0001", "gather", "t1"),
            *chat(1794837830.0, "chat-0002", "Tester", "claude stop, wait there")]
    a, b = AE.reconstruct(rows, name="r.jsonl", end_ts=1794837840.0)
    assert (a.ending, a.end) == ("replaced", 1794837830.0)
    assert b.ending == "brain_ended"


ERA1 = {"ts": 1793548414.0, "kind": "session_start", "player": "Tester"}  # 2026-11-01


def test_era1_silent_turn_after_a_promise_closes_it():
    """brain-live-20261101-165334-3708: 'got the quest. next is killing rats ...' and no call; the quest ran out."""
    ep = "chat-0001-302e"
    rows = [ERA1, *chat(1793548421.1, ep, "Tester", "claude, go and see Vannaka near the windmill and do his quest"),
            call(1793548423.0, ep, "go_to", "50fca857"), turn(1793548470.0, ep, 1, ["talk"]),
            call(1793548470.1, ep, "talk", "badd0d14"),
            turn(1793548475.1, ep, 2, [], "got the quest. next is killing rats up the hill at the windmill"),
            say(1793548475.2, ep, "got the quest. next is killing rats up the hill at the windmill"),
            call(1793548674.0, "review-0003-2d", "cast", "13236735")]
    (a,) = AE.reconstruct(rows, name="r.jsonl", end_ts=1793548800.0)
    assert a.era == 1 and a.ending == "closed_silent"
    assert a.cause == "closed silent after his last call worked" and a.last_calls == ["go_to ok", "talk ok"]
    assert 50 < a.life_s < 60


def test_era1_goal_from_the_ask_ends_it_when_the_goal_ends():
    """brain-live-20261116-060645-12424 (before c019a6f): the goal was 'chop 50 ash logs', narrower than the ask."""
    ep = "chat-0001"
    rows = [{"ts": 1794800800.0, "kind": "session_start"},
            *chat(1794800814.0, ep, "Tester", "claude, go and see Zanik and do her quest"),
            call(1794800816.0, ep, "talk", "a"),
            {"ts": 1794800830.0, "kind": "llm_response", "component": "planner", "tool_calls": [], "episode_id": ep},
            call(1794800840.0, ep, "gather", "b"), call(1794800990.0, ep, "talk", "c"),
            say(1794801030.0, "situation-0002", "Zanik wants rune essence next")]
    progress = [{"ts": 1794800835.0, "msg": "goal started", "goal": "Chop ash logs until I have 50"},
                {"ts": 1794801021.8, "msg": "goal done", "goal": "Chop ash logs until I have 50"}]
    (a,) = AE.reconstruct(rows, progress, name="r.jsonl", end_ts=1794801100.0)
    assert (a.ending, a.end, a.cause) == ("goal_done", 1794801021.8, "goal_done")


def test_era1_goal_stuck_names_its_reason():
    ep = "chat-0001"
    rows = [{"ts": 1793600000.0, "kind": "session_start"},
            *chat(1793600010.0, ep, "Tester", "claude, get yourself a wooden spade and a watering can for the farm"),
            {"ts": 1793600020.0, "kind": "llm_response", "component": "planner", "tool_calls": [], "episode_id": ep},
            call(1793600030.0, ep, "craft", "a"), fail(1793600040.0, ep, "craft", "a", "verification_failed")]
    progress = [{"ts": 1793600025.0, "msg": "goal started", "goal": "Get 3 Coarse Animal Fur"},
                {"ts": 1793600050.0, "msg": "replanned"},
                {"ts": 1793600150.0, "msg": "stuck", "goal": "Get 3 Coarse Animal Fur", "reason": "verification_failed"}]
    (a,) = AE.reconstruct(rows, progress, name="r.jsonl", end_ts=1793600300.0)
    assert a.ending == "goal_stuck" and a.replans == 1
    assert a.cause == "goal ended stuck (verification_failed)"


def test_era1_parked_and_run_ended():
    ep = "chat-0072"
    rows = [ERA1, *chat(1793548500.0, ep, "luisdeburnaybast", "come to the temple"),
            call(1793548501.0, ep, "go_to", "a"), fail(1793548510.0, ep, "go_to", "a", "unknown_target"),
            {"ts": 1793548527.6, "kind": "chain_stopped", "turns": 2, "why": "parked", "episode_id": ep}]
    (a,) = AE.reconstruct(rows, name="r.jsonl", end_ts=1793548900.0)
    assert a.ending == "parked"
    ep = "chat-0006-bf66"  # brain-live-20261101-022223-3892: rows stop after collect_water, nothing says why
    rows = [ERA1, *chat(1793548500.0, ep, "Tester", "claude get yourself over to Zanik"),
            call(1793548502.0, ep, "go_to", "a"), fail(1793548620.0, ep, "go_to", "a", "path_blocked"),
            turn(1793548754.0, ep, 2, ["collect_water"]), call(1793548754.1, ep, "collect_water", "d")]
    (b,) = AE.reconstruct(rows, name="r.jsonl", end_ts=1793549000.0)
    assert b.ending == "run_ended"


def test_deaths_count_once_per_minute():
    ep = "chat-0005"  # brain-live-20261101-013832-16124: every go_to failed companion_down while he was dead
    rows = [ERA1, *chat(1793548500.0, ep, "Tester", "claude get yourself over to Zanik"),
            *[x for i in range(3) for x in (call(1793548501.0 + i * 10, ep, "go_to", f"t{i}"),
                                            fail(1793548502.0 + i * 10, ep, "go_to", f"t{i}", "companion_down"))],
            turn(1793548560.0, ep, 3, [], "still stuck, my character says dead so I can't walk to Zanik")]
    (a,) = AE.reconstruct(rows, name="r.jsonl", end_ts=1793548700.0)
    assert a.deaths == 1 and a.ending == "closed_silent"


def test_judge_is_strict_without_a_harness_row():
    rows = [ERA1, *chat(1793548500.0, "chat-1", "luisdeburnaybast", "claude stop"),
            call(1793548501.0, "chat-1", "stop", "a"), turn(1793548505.0, "chat-1", 1, []),
            *chat(1793548509.0, "chat-2", "luisdeburnaybast", "stop"),
            turn(1793548512.0, "chat-2", 1, []),
            *chat(1793548700.0, "chat-3", "luisdeburnaybast", "come to me urgently"),
            call(1793548701.0, "chat-3", "go_to", "b"), fail(1793548710.0, "chat-3", "go_to", "b", "unknown_target"),
            say(1793548712.0, "chat-3", "can't see you from here, where are you?"),
            turn(1793548713.0, "chat-3", 1, []),
            *chat(1793549000.0, "chat-4", "luisdeburnaybast", "where are you going?"),
            say(1793549002.0, "chat-4", "heading to the trees"), turn(1793549003.0, "chat-4", 1, [])]
    asks = AE.reconstruct(rows, name="r.jsonl", end_ts=1793549100.0)
    AE.judge(asks, {"by_log": {}, "lines": {}})
    assert [(a.verdict, a.verdict_by) for a in asks] == [
        ("not_done", "repeated"), ("unknown", ""), ("not_done", "said_could_not"), ("unknown", "")]
    assert asks[3].talk_only and asks[3].group == "free" and asks[3].source == "player"


def test_norm_line():
    assert AE.norm_line("Claude, go and see Zanik!") == AE.norm_line("go and see zanik")


def test_read_rows_keeps_what_it_needs(tmp_path):
    p = tmp_path / "brain-live-x.jsonl"
    rows = [{"ts": 1.0, "kind": "bridge_send", "x": 1}, {"ts": 2.0, "kind": "prompt", "messages": []},
            {"ts": 3.0, "kind": "event", "event": {"type": "activity", "kind": "reflex_use"}},
            {"ts": 4.0, "kind": "event", "event": {"type": "activity", "kind": "combat_started"}},
            *chat(5.0, "chat-1", "Tester", "claude chop about 13 logs")]
    p.write_text("".join(json.dumps(r) + "\n" for r in rows) + "not json\n", encoding="utf-8")
    kept = list(AE.read_rows(p))
    assert [r["kind"] for r in kept] == ["event", "event", "chat_decision"]
    assert AE.last_ts(p) == 5.0


def test_load_verdicts_times_a_quest_from_its_run_id(tmp_path):
    q = {"run": "20261117-141943", "quest": "Ratcatcher", "brain_log": "b.jsonl", "done": True, "ended": "quest complete",
         "lines": [{"t": 1.6, "line": "claude, go and see Vannaka near the windmill and do his quest"}],
         "steps": [{"t": 0.0, "state": "given"}, {"t": 131.1, "state": "complete"}]}
    g = {"item": "chop", "brain_log": "c.jsonl", "ts": 1.0, "pass": True,
         "legs": [{"line": "claude chop about 13 logs", "done": True, "done_s": 65.5}]}
    (tmp_path / "quest_runs.jsonl").write_text(json.dumps(q) + "\n", encoding="utf-8")
    (tmp_path / "rung3_gate.jsonl").write_text(json.dumps(g) + "\n", encoding="utf-8")
    v = AE.load_verdicts(tmp_path)
    (row,) = v["by_log"]["b.jsonl"]
    assert row["done"] and abs(row["done_at"] - (1794925183.0 + 131.1)) < 0.01  # 14:19:43Z + 131.1 s
    assert v["by_log"]["c.jsonl"][0]["done_s"] == 65.5 and "chop about 13 logs" in v["lines"]["gate"]


def test_summarize_counts_by_group():
    rows = era2_rune_altar()
    (a,) = AE.reconstruct(rows, name="x.jsonl", end_ts=1794838100.0)
    AE.judge([a], {"by_log": {"x.jsonl": [{"source": "quest", "line": AE.norm_line(ZANIK), "done": False}]}})
    s = AE.summarize([a])
    assert s["by_group"]["harness"]["endings"] == {"closed_silent": 1}
    assert s["by_group"]["free"]["asks"] == 0
    assert "closed_silent" in AE.report([a])
