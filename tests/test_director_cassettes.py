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


def first_decision(cassette: dict) -> list[LLMResponse]:
    out = []
    for r in cassette["responses"]:
        out.append(LLMResponse(content=r["content"], tool_calls=[ToolCall(c["name"], c["arguments"], c["id"])
                                                                for c in r["tool_calls"]]))
        if (r["content"] or "").strip().startswith("{") and not r["tool_calls"]:
            break
    return out


@pytest.mark.parametrize("path", CASSETTES, ids=[p.stem for p in CASSETTES])
def test_recorded_first_decision_replays_through_the_validator_and_board(tmp_path, path):
    cas = json.loads(path.read_text(encoding="utf-8"))
    chat, open_task, setup = JOBS[cas["job"]]
    responses = first_decision(cas)
    rig = JobRig(tmp_path, responses + [json.dumps({"ask_help": "end of cassette"})] * 3, open_tasks=open_task)
    setup(rig)
    rig.say(chat)
    rig.steps(2, dt=1.0)
    recorded = next(e for e in cas["outcome"]["events"] if e["kind"] == "director_decision")
    decided = rig.log_rows("director_decision")
    assert decided, rig.trace()
    assert decided[0]["steps"] == recorded["steps"]  # the same plan, through today's validator
    job = next(t for t in rig.director.ops.b.tasks if t.by.startswith("player:"))
    state = rig.game.get_state()["data"]
    for s in job.steps:
        r = P.evaluate(s.success, state, rig.director.ops.step_ctx(job, s, state, rig.store.places()))
        assert r.passed is not None, (s.title, r.missing)
    if not open_task:
        assert job.success is not None or job.help is not None
    assert sum(1 for t in rig.director.ops.b.tasks if t.by == "self") <= 1  # one prerequisite per decision
