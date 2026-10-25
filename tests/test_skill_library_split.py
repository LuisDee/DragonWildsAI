"""SkillLibrary.propose / accept (docs/design/director.md section 12 item 4): the model call can run on a worker
over its OWN library instance and writes nothing; the agent loop's library re-checks and saves (one writer)."""
import json

from brain.llm import FakeLLM
from brain.skill_library import SkillLibrary
from brain.state_store import SkillRegistry, Task

DELIVER = {
    "name": "deliver_resource", "description": "Gather some of a resource and hand it to a player.",
    "params": {"resource": {"type": "str"}, "count": {"type": "int"}, "player": {"type": "str"}},
    "steps": [{"skill": "gather", "args": {"resource": "$resource", "count": "$count"}},
              {"skill": "give", "args": {"player": "$player", "item": "$resource", "count": "$count"}}],
    "preconditions": [], "postcondition": {"near_player": "$player"},
    "example_params": {"resource": "log", "count": 3, "player": "Luis"},
}


def done_tasks():
    ts = [Task(skill="gather", args={"resource": "log", "count": 3}),
          Task(skill="give", args={"player": "Luis", "item": "log", "count": 3})]
    for t in ts:
        t.status = "done"
    return ts


NEAR = {"players": [{"name": "Luis", "distance": 2.0}]}
FAR = {"players": [{"name": "Luis", "distance": 40.0}]}


def test_propose_on_a_worker_instance_writes_nothing_and_accept_saves_on_the_owner(tmp_path):
    reg = SkillRegistry()
    owner = SkillLibrary(tmp_path)
    worker = SkillLibrary(tmp_path)  # its own instance (its own SQLite index), as the Director's worker uses it
    llm = FakeLLM([json.dumps(DELIVER)])
    proposal = worker.propose("bring logs", done_tasks(), NEAR, llm, reg)
    assert proposal is not None and proposal[0].name == "deliver_resource"
    assert not list(tmp_path.glob("*.json")) and owner.names() == worker.names() == []
    rec = owner.accept(proposal, "bring logs", done_tasks(), NEAR, reg, seconds=12.0)
    assert rec is not None and (tmp_path / "deliver_resource.json").exists() and owner.names() == ["deliver_resource"]


def test_accept_refuses_when_fresh_state_no_longer_holds(tmp_path):
    reg = SkillRegistry()
    lib = SkillLibrary(tmp_path)
    proposal = lib.propose("bring logs", done_tasks(), NEAR, FakeLLM([json.dumps(DELIVER)]), reg)
    assert lib.accept(proposal, "bring logs", done_tasks(), FAR, reg) is None  # he walked away meanwhile
    assert lib.names() == [] and not list(tmp_path.glob("*.json"))


def test_learn_is_still_propose_then_accept(tmp_path):
    reg = SkillRegistry()
    lib = SkillLibrary(tmp_path)
    assert lib.learn("bring logs", done_tasks(), NEAR, FakeLLM([json.dumps(DELIVER)]), reg).name == "deliver_resource"
    wrong = {**DELIVER, "example_params": {"resource": "stone", "count": 3, "player": "Luis"}}
    lib2 = SkillLibrary(tmp_path / "b")
    llm = FakeLLM([json.dumps(wrong), json.dumps(wrong)])
    assert lib2.learn("bring logs", done_tasks(), NEAR, llm, reg) is None and len(llm.calls) == 2  # one repair round
    assert lib.propose("x", done_tasks()[:1], NEAR, FakeLLM([]), reg) is None  # one step: nothing to learn
