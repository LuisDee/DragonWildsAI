import json
import pytest
from brain import director as D, predicates as P
from test_director import make, step, have, gained, COPPER, TIN


def test_round_trip_runs_outbound_before_return_can_finish(tmp_path):
    from test_director import decision, ticks

    def drive(event, port):
        if event["type"] != "board_step":
            return None
        title = event["step"]["title"]
        assert port.director.ops.b.current_task().status != "done"
        port.world.state["position"] = [210., 0., 0.] if title == "outbound" else [0., 0., 0.]
        return {"actions": [], "ended": "normal"}

    home = {"near": {"position": [0., 0., 0.], "within_m": 2}}
    planned = decision(
        completion_mode="ordered_steps", task_success=home, steps=[
            step("start", home),
            step("outbound", {"moved": {"min_m": 200}}, checkpoint_id="away"),
            step("return", home, checkpoint_id="home")])
    # The planner gets one advisory round for the deliberately recurring state.
    d, port, _, _, _ = make(tmp_path, controller=drive, script=[planned, planned])
    task = d.ops.add_task("Walk out and back", by="cli")
    ticks(d, 8)
    assert [e["step"]["title"] for e in port.events if e["type"] == "board_step"] == ["outbound", "return"]
    assert task.status == "done"
    assert all(c["status"] == "done" for c in d.ops.checkpoint_progress(task))


def plan():
    return {"completion_mode": "ordered_steps", "task_success": P.validate(have(COPPER, 1)), "steps": [
        step("out", P.validate(have(TIN, 1)), checkpoint_id="out"), step("back", P.validate(have(COPPER, 1)), checkpoint_id="back")]}


def test_ordered_contract_gates_recurring_final_and_inputs(tmp_path):
    d, port, world, _, _ = make(tmp_path)
    world.add(COPPER, 1)
    task = d.ops.add_task("out and back", by="cli")
    d._apply(task, {"kind": "plan"}, plan(), world.state)
    assert not d.ops.checkpoints_complete(task)
    first, second = task.steps
    world.add(TIN, 1)
    d._step_done(task, first, P.evaluate(first.success, world.state, d.ops.step_ctx(task, first, world.state)), world.state)
    assert task.status != "done"
    snap = d._snapshot(task, {"kind": "replan"}, world.state)
    msg = json.loads(d._messages(snap)[1]["content"])
    assert [x["status"] for x in msg["job"]["checkpoints"]] == ["done", "pending"]
    ev = d._event(task, second, P.evaluate(second.success, world.state, d.ops.step_ctx(task, second, world.state)))
    assert ev["checkpoints"][1]["id"] == "back"
    assert not any(x.get("type") == "task_report" for x in port.events)
    d._step_done(task, second, P.evaluate(second.success, world.state, d.ops.step_ctx(task, second, world.state)), world.state)
    assert task.status == "done"


@pytest.mark.parametrize("final", [{"have": {"item": COPPER, "at_least": 5}}, {"quest_complete": {"name": "missing"}}])
def test_final_false_or_unknown_does_not_complete(tmp_path, final):
    d, _, world, _, _ = make(tmp_path)
    task = d.ops.add_task("job", by="cli")
    v = plan(); v["task_success"] = P.validate(final)
    d._apply(task, {"kind": "plan"}, v, world.state)
    for s in task.steps:
        d._step_done(task, s, P.Result(passed=True, detail="observed"), world.state)
    assert task.status != "done"


def test_retry_preserves_evidence_and_rejects_mutation(tmp_path):
    d, _, world, _, _ = make(tmp_path)
    task = d.ops.add_task("job", by="cli")
    d._apply(task, {"kind": "plan"}, plan(), world.state)
    old = task.steps[0]; old.status = "failed"; old.accumulated = {TIN: 2}; old.failures = [{"reason": "blocked"}]
    bad = plan(); bad["steps"] = bad["steps"][1:]
    before = task.model_dump()
    assert D._checkpoint_errors(before, bad, "replan")
    for mutation in ([bad["steps"][0], plan()["steps"][0]], [dict(plan()["steps"][0], success=have(TIN, 2)), plan()["steps"][1]]):
        assert D._checkpoint_errors(before, {**plan(), "steps": mutation}, "replan")
    d._apply(task, {"kind": "replan"}, plan(), world.state)
    assert task.steps[0] is old and old.status == "pending" and old.accumulated[TIN] == 2
    assert len([s for s in task.steps if s.checkpoint_id == "out"]) == 1
    old.status = "done"
    assert D._checkpoint_errors(task.model_dump(), plan(), "replan")
    d.store.flush()
    from brain import director
    restarted = director.Director(d.port, d.llm, tmp_path / "worlds" / "dev", executor=director.SyncExecutor())
    assert restarted.ops.b.task(task.id).steps[0].accumulated[TIN] == 2


def test_legacy_and_loop_contract():
    assert not D._checkpoint_errors({"completion_mode": "state"}, {"steps": [step("loop", have(TIN, 1), group="g")]}, "plan")
    v = plan(); v["steps"][0]["group"] = "g"
    assert D._checkpoint_errors({}, v, "plan")


def test_validator_and_review_keep_active_checkpoint(tmp_path):
    from test_director import decision, World
    raw = {"completion_mode": "ordered_steps", "task_success": have(COPPER, 1), "steps": [
        step("out", have(TIN, 1), checkpoint_id="out"), step("back", have(COPPER, 1), checkpoint_id="back")]}
    validator = D.Validator("plan", World().state, {"kind": "specific"}, research_left=lambda: False)
    value, _ = validator(decision(**raw), 0)
    d, _, world, _, _ = make(tmp_path)
    task = d.ops.add_task("job", by="cli")
    d._apply(task, {"kind": "plan"}, value, world.state)
    active = task.steps[0]
    d.ops.activate(active, world.state)
    old_key = d.ops.plan_key(task)
    reviewed = {**value, "steps": [step("prepare", P.validate(have(COPPER, 1))), *value["steps"]]}
    d._apply(task, {"kind": "review"}, reviewed, world.state)
    assert task.active_step() is active
    assert sum(s is active for s in task.steps) == 1
    assert task.steps[-2].title == "prepare"
    active.status = "done"
    assert d.ops.plan_key(task) != old_key
    assert D._checkpoint_errors(task.model_dump(), reviewed, "review")


def test_initial_help_defers_contract_and_preserves_gap_then_resumes(tmp_path):
    from test_director import decision
    d, _, world, _, _ = make(tmp_path)
    task = d.ops.add_task("job", by="cli")
    raw = {"completion_mode": "ordered_steps", "task_success": have(COPPER, 1),
           "ask_help": "Where?", "capability_gaps": [{"primitive": "location", "kind": "knowledge", "why": "unknown"}]}
    validator = D.Validator("plan", world.state, task.model_dump(), research_left=lambda: False)
    value, _ = validator(decision(**raw), 0)
    d._apply(task, {"kind": "plan"}, value, world.state)
    assert task.success is None and not task.checkpoints
    assert any("unknown: location" in str(x) for x in d.memory.snapshot().values())
    raw = {"completion_mode": "ordered_steps", "task_success": have(COPPER, 1), "steps": [
        step("out", have(TIN, 1), checkpoint_id="out"), step("back", have(COPPER, 1), checkpoint_id="back")]}
    validator = D.Validator("help_answer", world.state, task.model_dump(), research_left=lambda: False)
    value, _ = validator(decision(**raw), 0)
    d._apply(task, {"kind": "help_answer"}, value, world.state)
    assert task.completion_mode == "ordered_steps" and len(task.checkpoints) == 2


def test_unrequired_prep_does_not_reuse_checkpoint(tmp_path):
    d, _, world, _, _ = make(tmp_path)
    task = d.ops.add_task("job", by="cli")
    v = plan(); d._apply(task, {"kind": "plan"}, v, world.state)
    old = task.steps[0]
    prep = step(old.title, old.success)
    d._apply(task, {"kind": "replan"}, {**v, "steps": [prep, *v["steps"]]}, world.state)
    assert len(task.steps) == 3 and task.steps[0] is not old and task.steps[1] is old
    assert task.steps[0].checkpoint_id is None and task.steps[1].checkpoint_id == "out"


def test_rejected_apply_counts_consecutive_failures(tmp_path):
    d, _, world, _, _ = make(tmp_path)
    task = d.ops.add_task("job", by="cli")
    v = plan(); d._apply(task, {"kind": "plan"}, v, world.state)
    bad = {**v, "steps": v["steps"][1:]}
    d._apply(task, {"kind": "replan"}, bad, world.state)
    assert d._fail_count[task.id] == 1
    d._apply(task, {"kind": "replan"}, bad, world.state)
    assert task.status == "parked"


def test_open_ordered_rejected_on_plan_and_done(tmp_path):
    from test_director import decision
    d, _, world, _, _ = make(tmp_path)
    task = d.ops.add_task("open job", by="cli", kind="open")
    raw = {"completion_mode": "ordered_steps", "steps": [step("out", have(TIN, 1), checkpoint_id="out")]}
    validator = D.Validator("curriculum", world.state, task.model_dump(), research_left=lambda: False)
    with pytest.raises(ValueError, match="only for specific"):
        validator(decision(**raw), 0)
    task.completion_mode = "ordered_steps"
    task.checkpoints = [{"id": "out", "predicate": P.validate(have(TIN, 1))}]
    task.steps = [D.Step(title="out", success=P.validate(have(TIN, 1)), checkpoint_id="out")]
    validator = D.Validator("review", world.state, task.model_dump(), research_left=lambda: False)
    with pytest.raises(ValueError, match="only for specific"):
        validator(decision(done=True), 0)
    d._apply(task, {"kind": "review"}, {"done": True}, world.state)
    assert task.status != "done"


def test_state_help_still_sets_success(tmp_path):
    from test_director import decision
    d, _, world, _, _ = make(tmp_path)
    task = d.ops.add_task("job", by="cli")
    validator = D.Validator("plan", world.state, task.model_dump(), research_left=lambda: False)
    value, _ = validator(decision(task_success=have(COPPER, 1), ask_help="Where?"), 0)
    d._apply(task, {"kind": "plan"}, value, world.state)
    assert task.success and task.success["predicate"] == P.validate(have(COPPER, 1))
