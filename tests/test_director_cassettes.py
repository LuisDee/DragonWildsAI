"""Replay of REAL Sonnet Director decisions (tools/director_cassettes.py record; docs/design/director.md wave 5).

Each cassette holds the responses real Sonnet gave for one job on GearWorld. The first decision is replayed through
the real Validator and board: it must still be accepted (predicates valid, checkable, not trivial), produce the same
steps, and respect the board rules added after the recording (one prerequisite per decision). Research tool results
are recomputed (the replay only feeds the model's side).
"""
import json
from pathlib import Path

import pytest

from brain import predicates as P
from brain.llm import FakeLLM, LLMResponse, ToolCall
from brain.mock.gear_jobs import JOBS, JobRig

CASSETTES = sorted((Path(__file__).parent / "fixtures" / "director_cassettes").glob("*.json"))


def recorded_responses(cassette: dict) -> list[LLMResponse]:
    """Every recorded response in order: the replay asks for them just as the recording did (repair rounds
    included); anything after the first decision is only used if the board asks for more."""
    return [LLMResponse(content=r["content"], tool_calls=[ToolCall(c["name"], c["arguments"], c["id"])
                                                          for c in r["tool_calls"]]) for r in cassette["responses"]]


# Recorded answers that today's Validator rejects on purpose (fixes made after the recording), with the reason the
# repair round must carry. The rest must replay to the same plan.
REJECTED_SINCE = {
    "quest": "task_success can't be checked from what the body reports (missing: quests)",
    # recorded before gaps carried a kind (action | perception | knowledge): re-record to refresh
    "better_pickaxe": "kind must be one of action, perception, knowledge",
    "coal_multitrip": "kind must be one of action, perception, knowledge",
    "farm_mob_drop": "kind must be one of action, perception, knowledge",
}


@pytest.mark.parametrize("path", CASSETTES, ids=[p.stem for p in CASSETTES])
def test_recorded_first_decision_replays_through_the_validator_and_board(tmp_path, path):
    cas = json.loads(path.read_text(encoding="utf-8"))
    if not any(e["kind"] == "director_decision" for e in cas["outcome"]["events"]):
        pytest.skip(f"{cas['job']}: the recording stopped before a decision was applied (call cap)")
    chat, open_task, setup = JOBS[cas["job"]]
    responses = recorded_responses(cas)
    rig = JobRig(tmp_path, responses + [json.dumps({"ask_help": "end of cassette"})] * 3, open_tasks=open_task)
    setup(rig)
    rig.say(chat)
    rig.steps(2, dt=1.0)
    recorded = next(e for e in cas["outcome"]["events"] if e["kind"] == "director_decision")
    if cas["job"] in REJECTED_SINCE:
        repairs = [m["content"] for c in rig.director_llm.calls for m in c["messages"][-1:]
                   if m["role"] == "user" and "not usable" in m["content"]]
        failed = [str(r.get("why")) for r in rig.log_rows("director_decision_failed")]  # the last repair's reason
        assert any(REJECTED_SINCE[cas["job"]] in r for r in repairs + failed), (repairs, failed)
        return
    decided = rig.log_rows("director_decision")
    assert decided, rig.trace()
    assert decided[0]["steps"] == recorded["steps"]  # the same plan, through today's validator
    job = next(t for t in rig.director.ops.b.tasks if t.by.startswith("player:"))
    state = rig.game.get_state()["data"]
    for s in job.steps:
        r = P.evaluate(s.success, state, rig.director.ops.step_ctx(job, s, state, rig.store.places()))
        assert r.passed is not None or set(r.missing) <= set(P.BOOKKEEPING_FIELDS), (s.title, r.missing)
        # (a step not activated yet has no clock: elapsed is bookkeeping, checkable once it runs)
    if not open_task:
        assert job.success is not None or job.help is not None
    assert sum(1 for t in rig.director.ops.b.tasks if t.by == "self") <= 1  # one prerequisite per decision
