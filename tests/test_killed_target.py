"""A target that is gone because a fight killed it: the result says so (live 2026-11-01 20:09Z, ClaudeQ4 Ratcatcher:
go_to <rat id> came back unknown_target "target_not_visible"; his combat reflex had killed that rat during the walk,
and the kill reached the brain 0.5 s after the result). Informs only: the reason stays unknown_target."""
from __future__ import annotations

import time

from brain.interface import Activity, fail
from brain.state_store import Task

from test_event_hygiene import STATES, Replay

RAT = "BP_AI_GiantRat_Character_C_2147465669"


def _kill(target_id=RAT, by="reflex", ago=11.0, name="Giant Rat"):
    return {"type": "activity", "kind": "combat_end", "by": by, "ts": time.time() - ago, "target": name,
            "target_id": target_id, "outcome": "killed"}


def test_broker_names_the_kill_of_that_id_or_of_that_kind(tmp_path):
    b = Replay(tmp_path, STATES[5]).agent.broker
    b.remember_activity(Activity(**_kill(ago=11.2)))
    assert b.killed(RAT) == "That Giant Rat is dead: your combat reflex killed it 11 s ago."
    assert b.killed("giant rat") == "A Giant Rat is dead: your combat reflex killed one 11 s ago."
    assert b.killed("BP_AI_GiantRat_Character_C_1") is None and b.killed("Wolf") is None
    b.remember_activity(Activity(**_kill(target_id="X", ago=500)))
    assert b.killed("X") is None  # too long ago to explain a miss


def test_a_go_to_whose_creature_was_killed_meanwhile_says_so_with_the_kill_arriving_after_the_result(tmp_path):
    r = Replay(tmp_path, STATES[5])
    r.body.act("go_to", fail("unknown_target", why="target_not_visible",
                             detail="Walked 13 m in 4 s; paused 11 s while combat:reflex had my legs. (target_not_visible)"),
               emitted=[_kill(ago=0.4)])  # queued with the result, as the bridge delivered it
    out = r.agent._run_task(Task(skill="go_to", args={"target": RAT}))
    assert out.reason == "unknown_target"
    assert out.data["detail"].startswith("That Giant Rat is dead: your combat reflex killed it 0 s ago. Walked 13 m")
    assert any(isinstance(e, Activity) and e.kind == "combat_end" for e in r.agent._stash)  # kept for the chain's news


def test_a_plain_unknown_name_is_not_delayed_or_changed(tmp_path):
    r = Replay(tmp_path, STATES[5])
    r.body.act("go_to", fail("unknown_target", detail="windmill is not in sight"))
    t = time.monotonic()
    out = r.agent._run_task(Task(skill="go_to", args={"target": "windmill"}))
    assert out.data["detail"] == "windmill is not in sight" and time.monotonic() - t < 0.5
