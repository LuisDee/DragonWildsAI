"""Fight news during a body call, and the truth about a call his death cut short (grave study 2026-11-18).

Shapes from the logs:
- logs/brain-live-20261118-010135-17424.jsonl: go_to my_grave sent at 485.2 s; the reflex's combat_started (Giant Rat,
  bare hands, likely_win, est_s_to_die 80) at 592.8 s reached the brain at 669.7 s, after he died at 666.5 s; the go_to
  came back "interrupted / the move ended without arriving (stopped)".
- logs/brain-live-20261116-062404-15380.jsonl: explore "Air Altar"; combat_end outcome died at 308.0 s; the explore
  answered nothing_in_range 0.6 s later.
"""
from __future__ import annotations

import copy

from brain import bridge_client as bc
from brain import fight_news
from brain.interface import Activity, ChatHeard, fail, ok, parse_event
from brain.jsonl_log import JsonlLogger
from brain.planner import _trim_state
from brain.state_store import Task

from test_chat_mid_action import Body, _agent

GRAVE = "my_grave:1794960568.869"

RAT_START = {"type": "activity", "kind": "combat_started", "by": "reflex", "ts": 1794960688.444, "target_hp": 100.0,
             "est_s_to_kill": 14, "weapon": "bare hands", "est_s_to_die": 80, "because": "winnable", "decision": "fight",
             "target": "Giant Rat", "target_id": "BP_AI_GiantRat_Character_C_2147456961", "verdict": "likely_win",
             "max_hp": 100.0, "hp": 100.0, "why": "hostile_near"}
ARCHER_START = {"type": "activity", "kind": "combat_started", "by": "reflex", "ts": 1794960554.51, "target_hp": 60.0,
                "est_s_to_kill": 19, "weapon": "Bronze Sword", "est_s_to_die": 6, "because": "too_strong",
                "decision": "flee", "target": "Goblin Archer", "verdict": "too_strong", "max_hp": 100.0, "hp": 100.0,
                "why": "hostile_near", "target_id": "BP_AI_RangedGoblin_Character_C_2147459509"}
ARCHER_FLEE_FAILED = {"type": "activity", "kind": "flee_failed", "by": "reflex", "ts": 1794960556.905, "fled_m": 8,
                      "next": "fighting back", "why": "it kept hitting me while I ran (38 HP in 2 s)", "hp": 62.0,
                      "from": "Goblin Archer", "from_id": "BP_AI_RangedGoblin_Character_C_2147459509"}
CAMP = {"type": "activity", "kind": "threat_seen", "by": "reflex", "target": "Goblin Archer", "target_pl": 2,
        "distance_m": 18, "pack": 5, "hostiles": "Goblin Archer x2, Goblin Warrior x2, Goblin Runt",
        "verdict": "outnumbered", "est_s_to_die": 6, "est_s_to_kill": 60, "hp": 100.0, "max_hp": 100.0}


def _ev(d):
    return parse_event(copy.deepcopy(d))


# --------------------------------------------------------------------------- what takes the floor


def test_a_reflex_fight_or_a_failed_flee_or_a_camp_in_sight_takes_the_floor():
    assert fight_news.interrupt_reason(_ev(RAT_START)) == "fight"
    assert fight_news.interrupt_reason(_ev(ARCHER_FLEE_FAILED)) == "fight"
    assert fight_news.interrupt_reason(_ev(CAMP)) == "threat"
    # memory only: a fight's end, the reflex holding back a drink, a creature's death cinematic
    for d in ({"type": "activity", "kind": "combat_end", "by": "reflex", "outcome": "killed"},
              {"type": "activity", "kind": "reflex_no_drink", "by": "reflex", "reason": "no drink carried"},
              {"type": "activity", "kind": "creature_ability", "by": None, "ability": "cinematic"},
              {"type": "activity", "kind": "combat_started", "by": "brain", "target": "Giant Rat"}):
        assert fight_news.interrupt_reason(_ev(d)) is None, d


def test_the_live_agent_check_keeps_chat_and_adds_fights(tmp_path):
    agent, body, model, log = _agent(tmp_path)
    assert agent._addressed_line(_ev(RAT_START)) == "fight"
    assert agent._addressed_line(_ev(CAMP)) == "threat"
    assert agent._addressed_line(ChatHeard(player="Zezima", text="claude stop"))
    assert not agent._addressed_line(ChatHeard(player="Bob", text="nice weather"))


def test_the_bridge_detaches_a_walk_for_a_fight_and_says_why(tmp_path, monkeypatch):
    """010135 at 592.8 s: the rat fight started 107 s into the grave walk. The wait detaches at once (the walk goes on
    in the body), and the result says a fight took the floor, not the player."""
    monkeypatch.setattr(bc, "HEARTBEAT_S", 0.0)
    monkeypatch.setattr(bc, "DETACH_AFTER_S", 0.0)
    body = Body()
    body.push.append({"v": 1, "type": "event", "event": copy.deepcopy(RAT_START)})
    c = bc.BridgeClient(body, JsonlLogger(tmp_path / "b.jsonl"))
    c.interrupt_check = fight_news.interrupt_reason
    res = c.request("go_to", {"target": GRAVE}, timeout=300)
    assert res["reason"] == "still_running" and res["data"]["by"] == "fight", res
    assert "fight started on you" in res["data"]["detail"]
    assert [e.kind for e in c.poll_events()] == ["combat_started"]  # kept for the agent
    rows = [r for r in JsonlLogger(tmp_path / "b.jsonl").read_all() if r["kind"] == "bridge_wait_interrupted"]
    assert rows and rows[0]["why"] == "fight"


# --------------------------------------------------------------------------- the fight turn


def _running(by="fight", rid="g1"):
    return fail("still_running", tool="go_to", id=rid, by=by, running=True, running_s=107.4,
                detail=bc.DETACH_WORDS[by])


def test_the_grave_walk_fight_gives_the_model_a_turn_with_the_fight_shown(tmp_path):
    """010135 replayed: the go_to's wait is cut by the rat fight; the next pump runs ONE model turn whose body_event
    shows the rat, its level, the reflex's odds and choice, his HP, what he carries, and the walk still running."""
    agent, body, model, log = _agent(tmp_path)
    body.state.update(health=100.0, max_health=100.0)
    seen = []
    model.body_reply = lambda ctx: seen.append(ctx) or __import__("brain.llm", fromlist=["FakeLLM"]).FakeLLM.say("")
    body.act("go_to", _running(), emitted=[copy.deepcopy(RAT_START)])
    out = agent._run_task(Task(skill="go_to", args={"target": GRAVE}))
    assert out.reason == "still_running" and out.interrupt
    agent.step()
    assert len(seen) == 1, [c.get("body_event") for c in model.contexts]
    ev = seen[0]["body_event"]
    assert ev["type"] == "fight" and ev["by"] == "fight" and ev["who"] == "Giant Rat", ev
    assert ev["level"].startswith("PL 1-5 (wiki"), ev["level"]
    assert "likely win" in ev["odds"] and "kills you ~80 s" in ev["odds"], ev["odds"]
    assert ev["reflex"] == "fight (winnable), with bare hands", ev["reflex"]
    assert ev["your_hp"] == "100/100" and set(ev["carried"]) == {"food", "drink"}, ev
    assert ev["still_running"].startswith("go_to") and "still doing it" in ev["still_running"]
    status = " | ".join(seen[0].get("body_status") or [])
    assert "when a fight started on you" in status and "when the player spoke" not in status, status
    turns = [r for r in log.read_all() if r["kind"] == "fight_turn"]
    assert turns and turns[0]["who"] == "Giant Rat" and turns[0]["events"] == ["combat_started"]
    # the model decided nothing: code ran no body call of its own
    assert [c[0] for c in body.calls] == ["go_to"]


def test_the_camp_and_the_failed_flee_are_shown_as_the_game_said_them(tmp_path):
    """010135 at 458.9 s (explore leg 5, a goblin camp): a camp in sight, then a flee that failed."""
    s = fight_news.fight_situation([_ev(CAMP)], {"health": 100.0, "max_health": 100.0}, {"tool": "explore",
                                   "args": {"about": "copper ore vein"}, "ran_s": 52}, "threat")
    assert s["who"] == "Goblin Archer" and s["level"] == "PL 2 (the game)", s
    assert s["hostiles_in_sight"].startswith("Goblin Archer x2, Goblin Warrior x2, Goblin Runt (5"), s
    assert "outnumbered" in s["odds"] and "nothing has attacked you yet" in s["about"]
    s2 = fight_news.fight_situation([_ev(ARCHER_START), _ev(ARCHER_FLEE_FAILED)],
                                    {"health": 62.0, "max_health": 100.0}, None, "fight")
    assert s2["flee"] == "failed: it kept hitting me while I ran (38 HP in 2 s); now fighting back", s2
    assert "much stronger" in s2["odds"] and s2["reflex"].startswith("flee (too_strong)"), s2
    assert s2["your_hp"] == "62/100"


def test_a_goal_step_cut_by_a_fight_gives_a_turn_and_is_not_counted_as_an_interrupt(tmp_path):
    agent, body, model, log = _agent(tmp_path)
    agent.max_interrupts = 0  # one chat interrupt would end the job: fights never count
    seen = []
    from brain.llm import FakeLLM
    model.body_reply = lambda ctx: seen.append(ctx["body_event"]) or FakeLLM.say("")
    body.act("go_to", _running(), emitted=[copy.deepcopy(RAT_START)])
    res = agent.run_goal("walk to my grave", tasks=[Task(skill="go_to", args={"target": GRAVE})])
    assert any(e.get("type") == "fight" for e in seen), seen
    assert res == "done", res  # the walk was re-attached after the turn (DetachBody.reattach: arrived)
    assert [c[0] for c in body.calls] == ["go_to", "reattach"]


# --------------------------------------------------------------------------- a call cut short by his death


def _dead_state(state, ago=0, killed_by="Giant Rat", respawned=False):
    s = copy.deepcopy(state)
    s["last_death"] = {"ago_s": ago, "respawned": respawned, "killed_by": killed_by, "at": [413.6, 1756.7, -41.6]}
    return s


def test_a_walk_his_death_cut_short_says_he_died_and_what_killed_him(tmp_path):
    """010135 at 668.5 s: go_to -> interrupted "the move ended without arriving (stopped)", 2 s after his death."""
    agent, body, model, log = _agent(tmp_path)
    body.act("go_to", fail("interrupted", detail="the move ended without arriving (stopped)",
                           position=[413.59, 1756.71, -41.63]), state_after=_dead_state(body.state))
    out = agent._run_task(Task(skill="go_to", args={"target": GRAVE}))
    assert out.reason == "companion_down", out
    d = out.data["detail"]
    assert d.startswith("I died during this go_to (killed by Giant Rat"), d
    assert "the move ended without arriving (stopped)" in d and out.data["body_reason"] == "interrupted"
    assert [r for r in log.read_all() if r["kind"] == "death_during_call"]


def test_a_job_that_answered_nothing_in_range_after_his_death_says_he_died(tmp_path):
    """062404 at 308.6 s (explore there; the same shape on gather, a body tool of this harness): nothing_in_range
    0.6 s after combat_end outcome died (a Goblin Runt pack)."""
    agent, body, model, log = _agent(tmp_path)
    body.act("gather", fail("nothing_in_range", detail="saw nothing matching 'Air Altar'"),
             state_after=_dead_state(body.state, ago=0, killed_by="Goblin Runt"))
    out = agent._run_task(Task(skill="gather", args={"resource": "rune_essence", "count": 5}))
    assert out.reason == "companion_down" and "killed by Goblin Runt" in out.data["detail"], out
    assert out.data["body_reason"] == "nothing_in_range"


def test_an_old_death_is_not_this_calls_death(tmp_path):
    agent, body, model, log = _agent(tmp_path)
    body.act("go_to", fail("path_blocked", detail="the walkable map ends 145 m short of the goal"),
             state_after=_dead_state(body.state, ago=300, respawned=True))
    out = agent._run_task(Task(skill="go_to", args={"target": GRAVE}))
    assert out.reason == "path_blocked" and "died" not in out.data["detail"], out


def test_the_late_result_of_a_walk_left_running_says_he_died(tmp_path):
    """A walk detached for a fight ends in the body later: its late result is shown as his death, not "stopped"."""
    agent, body, model, log = _agent(tmp_path)
    seen = []
    from brain.llm import FakeLLM
    model.body_reply = lambda ctx: seen.append(ctx["body_event"]) or FakeLLM.say("")
    body.act("go_to", _running(), emitted=[copy.deepcopy(RAT_START)])
    agent._run_task(Task(skill="go_to", args={"target": GRAVE}))
    agent.step()  # the fight turn
    body.state = _dead_state(body.state, ago=1)
    body.end("g1", fail("interrupted", detail="the move ended without arriving (stopped)"))
    agent.step()
    late = [e for e in seen if e.get("type") == "running_action_result"]
    assert late and late[0]["reason"] == "companion_down", seen
    assert late[0]["detail"].startswith("I died during this go_to (killed by Giant Rat") and \
        "when a fight started on you" in late[0]["note"], late[0]


# --------------------------------------------------------------------------- the Planner sees the odds


def test_the_planner_sees_the_bodys_odds_line_not_raw_rows():
    """010135 at 953.7 s: the Planner saw the Goblin Archer 18 m off only as power_level 2 and planned an explore."""
    state = {"nearby_entities": [
        {"id": "BP_AI_RangedGoblin_Character_C_1", "name": "Goblin Archer", "kind": "Goblin Archer", "hostile": True,
         "alive": True, "distance": 17.57, "power_level": 2, "hp": 120.0, "max_health": 120.0, "class": "BP_AI_..."},
        {"id": "BP_AI_RuntGoblin_Character_C_2", "name": "Goblin Runt", "hostile": True, "alive": True,
         "distance": 30.0, "power_level": 1}],
        "fight_odds": {"BP_AI_RangedGoblin_Character_C_1": {"verdict": "too_strong", "die_s": 6, "kill_s": 15,
                                                            "pl_gap": 2}}}
    rows = _trim_state(state)["nearby_entities"]
    assert "odds now: much stronger (PL +2; kills you ~6 s; you it ~15 s)" in rows[0]["note"], rows[0]
    assert rows[0]["hostiles_in_sight"] == 2 and "class" not in rows[0]
