"""brain/director.py: the Director loop and the step runner (docs/design/director.md waves 3; review H1-H12,
re-check items 1-11). Offline: a fake port (scripted world + scripted Controller runs) and a scripted Sonnet.
"""
import concurrent.futures as cf
import copy
import json
import threading

import pytest

from brain import board as B

from brain import director as D
from brain import predicates as P
from brain.capability_gaps import GapLog
from brain.llm import FakeLLM, LLMResponse, ToolCall

COPPER, TIN = "ITEM_Resources_CopperOre", "ITEM_Resources_TinOre"
STONE_PICK, BRONZE_PICK = "ITEM_Pickaxe_Stone", "ITEM_Pickaxe_Bronze"


class Clock:
    def __init__(self, t=10_000.0):
        self.t = t

    def __call__(self):
        return self.t


class World:
    def __init__(self):
        self.state = {"position": [0.0, 0.0, 0.0], "inventory": {}, "gear": {"held_right": STONE_PICK},
                      "skills": [{"skill": "Mining", "level": 5, "xp": 100}],
                      "players": [{"name": "Zezima", "position": [2.0, 0.0, 0.0], "distance": 2.0}],
                      "bag": {"used": 2, "capacity": 20}, "health": 100, "max_health": 100}

    def add(self, item, n):
        inv = self.state["inventory"]
        inv[item] = inv.get(item, 0) + n
        if inv[item] <= 0:
            inv.pop(item)


class FakePort:
    """The Agent as the Director sees it. ``controller(event, port)`` plays the Controller model + body for one
    run and returns {actions, ended, said}; it may call port.director.handle_tool (report_step, pause_board)."""

    def __init__(self, world, controller=None):
        self.world, self.controller = world, controller
        self.events, self.said, self.reads = [], [], []
        self.busy_flag = self.chat = False
        self.director = None
        self.ticks_inside_run = 0

    def run(self, event):
        self.events.append(copy.deepcopy(event))
        if self.director is not None:  # re-check 5: run_directed -> run_goal -> pump -> tick must be a no-op
            before = len(self.events)
            self.director.tick()
            self.ticks_inside_run += 1
            assert len(self.events) == before
        out = self.controller(event, self) if self.controller else None
        out = dict(out or {"actions": [], "ended": "normal"})
        out.setdefault("said", event.get("type") == "board_notice")
        return out

    def state(self):
        return copy.deepcopy(self.world.state)

    def say(self, text):
        self.said.append(text)

    def body_read(self, tool, args):
        self.reads.append((tool, args, threading.get_ident()))
        return {"ok": True, "data": {"tool": tool, "steps": [{"do": "gather", "item": COPPER}]}}

    def busy(self):
        return self.busy_flag

    def chat_pending(self):
        return self.chat


class ListLog:
    def __init__(self):
        self.rows = []

    def log(self, kind, **data):
        self.rows.append({"kind": kind, **data})


def decision(**kw):
    out = {"description": "plan", "explanation": None, "facts": [], "steps": [], "ask_help": None}
    out.update(kw)
    return json.dumps(out)


def step(title, success, **kw):
    return {"title": title, "why": "", "hints": "", "success": success, **kw}


def gained(item, n):
    return {"gained": {"item": item, "at_least": n}}


def have(item, n):
    return {"have": {"item": item, "at_least": n}}


def make(tmp_path, controller=None, script=(), clock=None, per_hour=20, budget=None, body_tools=None, executor=None,
         knowledge=None, map_memory=None):
    world = World()
    port = FakePort(world, controller)
    llm = FakeLLM(list(script), model="fake/director")
    clock = clock or Clock()
    d = D.Director(port, llm, tmp_path / "worlds" / "dev", knowledge=knowledge,
                   body_tools=body_tools or {"gather": "harvest", "craft": "craft", "drop": "drop", "go_to": "walk"},
                   budget=budget, per_hour=per_hour, executor=executor or D.SyncExecutor(), clock=clock,
                   map_memory=map_memory)
    port.director = d
    return d, port, world, llm, clock


def ticks(d, n=4):
    for _ in range(n):
        d.tick()


def mine(item, n):
    def run(ev, port):
        if ev["type"] != "board_step":
            return None
        port.world.add(item, n)
        return {"actions": [{"tool": "gather", "args": {"resource": "x", "count": n}, "ok": True,
                             "data": {"item": item}, "origin": "board"}], "ended": "normal"}
    return run


# ------------------------------------------------------------------ the happy path


def test_plan_run_verify_done_from_state_only(tmp_path):
    d, port, world, llm, clock = make(tmp_path, mine(COPPER, 5), [
        decision(task_success=have(COPPER, 5), steps=[step("mine copper", gained(COPPER, 5))])])
    t = d.handle_tool("add_task", {"text": "mine some copper", "when": "now"}, "Zezima")["data"]
    ticks(d)
    task = d.ops.b.task(t["id"])
    assert task.status == "done" and task.steps[0].status == "done"
    run = [e for e in port.events if e["type"] == "board_step"][0]
    assert run["step"]["title"] == "mine copper" and "board checks" in run["instructions"]
    assert run["job_done_when"] == "carry 5 Copper Ore" and run["step_done_when"] == "gain 5 Copper Ore"
    notices = [e for e in port.events if e["type"] == "board_notice"]
    assert notices[-1]["about"] == "task_report" and port.said == []  # the Controller voiced it (single voice)
    assert d.window.left() == 19 and len(llm.calls) == 1
    assert port.ticks_inside_run >= 1  # tick() was re-entered during runs and did nothing


@pytest.mark.parametrize("repair_to_help", [False, True])
def test_mixed_work_help_repairs_before_any_board_side_effect(tmp_path, repair_to_help):
    mixed = decision(task_success=have(COPPER, 5), steps=[step("mine", gained(COPPER, 5))],
                     add_tasks=[{"text": "a separate job"}], ask_help="If it fails, can you help?")
    d, port, world, llm, clock = make(tmp_path, mine(COPPER, 5), [mixed])
    t = d.handle_tool("add_task", {"text": "mine copper", "when": "now"}, "Zezima")["data"]
    def repair(messages, tools):
        task = d.ops.b.task(t["id"])
        assert len(d.ops.b.tasks) == 1 and not task.steps and task.success is None
        assert task.status != "waiting_help" and not port.events and not port.said
        assert "choose one" in messages[-1]["content"]
        fixed = decision(ask_help="Where can I find ore?") if repair_to_help else decision(
            task_success=have(COPPER, 5), steps=[step("mine", gained(COPPER, 5))])
        return LLMResponse(content=fixed)
    llm.push(repair)
    ticks(d, 4)
    task = d.ops.b.task(t["id"])
    assert len(llm.calls) == 2 and d.window.left() == 18 and len(d.ops.b.tasks) == 1
    if repair_to_help:
        assert task.status == "waiting_help" and not task.steps
        assert not any(e["type"] == "board_step" for e in port.events)
    else:
        assert task.status == "done" and task.steps[0].title == "mine"
        assert any(e["type"] == "board_step" for e in port.events)


@pytest.mark.parametrize("fields", [
    {"steps": "bad"}, {"loops": []}, {"add_tasks": "bad"}, {"steps": ["bad"]},
    {"add_tasks": [{}]}, {"loops": {"g": "bad"}}, {"done": "false"}, {"ask_help": True},
    {"ask_help": "need help", "add_tasks": [{"text": "prep"}]},
    {"ask_help": "need help", "loops": {"g": {"until": {"elapsed": {"seconds": 3}}}}},
    {"ask_help": "need help", "done": True},
    {"done": True, "steps": [step("work", gained(COPPER, 1))]},
    {"loops": {"g": {"until": {"elapsed": {"seconds": 3}}}}},
    {"done": True},
])
def test_invalid_decision_shapes_require_repair(fields):
    validator = D.Validator("plan", World().state, {"kind": "specific"}, research_left=lambda: False)
    with pytest.raises(ValueError):
        validator(decision(**fields), 0)


@pytest.mark.parametrize("kind", ["review", "reflect"])
def test_no_change_and_review_prerequisite_remain_valid(kind):
    validator = D.Validator(kind, World().state, {"kind": "specific", "success": {}}, research_left=lambda: False)
    value, _ = validator(decision(description="keep plan"), 0)
    assert value["steps"] == [] and not value["done"] and not value["ask_help"]
    value, _ = validator(decision(add_tasks=[{"text": "prepare separately"}]), 0)
    assert value["add_tasks"][0]["text"] == "prepare separately"


def test_conflict_repairs_remain_bounded_and_budgeted():
    from brain.llm_json import BudgetStop, DecisionError, json_decision
    mixed = decision(steps=[step("work", gained(COPPER, 1))], ask_help="Help now?")
    validator = D.Validator("plan", World().state, {"kind": "specific"}, research_left=lambda: False)
    requests = []
    with pytest.raises(DecisionError):
        json_decision(FakeLLM([mixed] * 3), [{"role": "user", "content": "plan"}], validator,
                      max_repairs=2, before_request=lambda: requests.append(1) or True)
    assert len(requests) == 3
    requests.clear()
    with pytest.raises(BudgetStop):
        json_decision(FakeLLM([mixed] * 3), [{"role": "user", "content": "plan"}], validator,
                      max_repairs=2, before_request=lambda: len(requests) < 1 and not requests.append(1))
    assert len(requests) == 1


def test_the_director_prompt_carries_tools_predicates_and_the_job(tmp_path):
    d, port, world, llm, clock = make(tmp_path, mine(COPPER, 5), [
        decision(task_success=have(COPPER, 5), steps=[step("mine", gained(COPPER, 5))])])
    d.handle_tool("add_task", {"text": "mine some copper"}, "Zezima")
    ticks(d, 2)
    msgs = llm.calls[0]["messages"]
    assert "- gather: harvest" in msgs[0]["content"] and '"gained"' in msgs[0]["content"]
    user = json.loads(msgs[1]["content"])
    assert user["job"]["text"] == "mine some copper" and user["decision"] == "plan"
    assert user["me"]["gear"]["held_right"]["item"] == STONE_PICK  # gear with catalog stats
    names = {t["function"]["name"] for t in llm.calls[0]["tools"]}
    assert {"recall", "compare_gear", "map_memory", "skills_progress"} <= names and "lookup" not in names


# ------------------------------------------------------------------ claims never count (H12a negative controls)


def claims_only(ev, port):
    if ev["type"] == "board_step":
        port.director.handle_tool("report_step", {"outcome": "done", "reason": "all done!"}, "Zezima")
    return {"actions": [], "ended": "normal"}


def test_claims_only_and_do_nothing_controllers_never_finish(tmp_path):
    for ctrl in (claims_only, None):
        d, port, world, llm, clock = make(tmp_path / str(id(ctrl)), ctrl, [
            decision(task_success=have(COPPER, 5), steps=[step("mine", gained(COPPER, 5))]),
            decision(description="retry", steps=[step("mine", gained(COPPER, 5))]),
            decision(ask_help="I can't seem to mine here; any idea?")])
        t = d.handle_tool("add_task", {"text": "mine some copper"}, "Zezima")["data"]
        ticks(d, 12)
        task = d.ops.b.task(t["id"])
        assert task.status == "waiting_help" and task.success and all(s.status != "done" for s in task.steps)
        runs = [e for e in port.events if e["type"] == "board_step"]
        if ctrl is claims_only:
            assert any("you reported this step done" in e.get("note", "") for e in runs)
        assert [e for e in port.events if e["type"] == "board_notice"][-1]["facts"]["question"].startswith("I can't")


def test_a_trivial_test_is_information_first_then_flagged(tmp_path):
    d, port, world, llm, clock = make(tmp_path, None, [
        decision(task_success=have(COPPER, 1), steps=[step("x", have(COPPER, 1))]),
        decision(task_success=have(COPPER, 1), steps=[step("x", have(COPPER, 1))])])
    world.add(COPPER, 3)
    t = d.handle_tool("add_task", {"text": "hold copper"}, "Zezima")["data"]
    ticks(d, 2)
    assert "already true now" in llm.calls[1]["messages"][-1]["content"]
    task = d.ops.b.task(t["id"])
    assert task.success["trivial"] is True


def test_the_task_success_is_immutable(tmp_path):
    d, port, world, llm, clock = make(tmp_path, None, [
        decision(task_success=have(COPPER, 9), steps=[step("mine", gained(COPPER, 9))]),
        decision(task_success=have(COPPER, 1), steps=[step("mine", gained(COPPER, 1))])])
    t = d.handle_tool("add_task", {"text": "collect copper"}, "Zezima")["data"]
    ticks(d, 2)
    task = d.ops.b.task(t["id"])
    d._need(task, "review", {})
    ticks(d, 2)
    assert task.success["predicate"]["have"]["at_least"] == 9
    assert any(h.get("outcome") == "ignored" for h in task.history)


# ------------------------------------------------------------------ DEPS, caps, help (H5)


def test_failure_replans_with_the_real_results_then_asks_for_help(tmp_path):
    def nothing_here(ev, port):
        if ev["type"] != "board_step":
            return None
        port.director.handle_tool("report_step", {"outcome": "blocked", "reason": "no tin rocks within 30 m"},
                                  "Zezima")
        return {"actions": [{"tool": "gather", "args": {"resource": "tin", "count": 3}, "ok": False,
                             "reason": "nothing_in_range", "data": {}, "origin": "board"}], "ended": "normal"}
    d, port, world, llm, clock = make(tmp_path, nothing_here, [
        decision(task_success=have(TIN, 3), steps=[step("mine tin here", gained(TIN, 3))]),
        decision(description="tin was not here", explanation="no rocks nearby",
                 steps=[step("mine tin by the lake", gained(TIN, 3))]),
        decision(ask_help="I couldn't find tin anywhere I've looked. Do you know where tin rocks are?")])
    t = d.handle_tool("add_task", {"text": "get tin"}, "Zezima")["data"]
    ticks(d, 10)
    replan = json.loads(llm.calls[1]["messages"][1]["content"])
    assert replan["decision"] == "replan" and "blocked: no tin rocks within 30 m" in json.dumps(replan["detail"])
    assert replan["detail"]["failed"]["last_actions"][0]["reason"] == "nothing_in_range"
    task = d.ops.b.task(t["id"])
    assert task.status == "waiting_help" and task.help.question.startswith("I couldn't find tin")
    # the player answers: the note reaches the next decision, which is a help_answer
    llm.push(decision(steps=[step("mine tin at the quarry", gained(TIN, 3))]))
    d.handle_tool("resume_board", {"note": "tin is at the quarry"}, "Zezima")
    ticks(d, 1)
    ans = next(u for u in (json.loads(c["messages"][1]["content"]) for c in llm.calls[3:])
               if u["decision"] == "help_answer")  # (then the step runs, is blocked again, and replans)
    assert ans["decision"] == "help_answer" and ans["job"]["notes_from_player"] == ["tin is at the quarry"]


def test_no_progress_twice_fails_the_attempt(tmp_path):
    d, port, world, llm, clock = make(tmp_path, lambda ev, port: {"actions": [], "ended": "normal"}, [
        decision(task_success=have(COPPER, 5), steps=[step("mine", gained(COPPER, 5))])])
    d.handle_tool("add_task", {"text": "copper"}, "Zezima")
    ticks(d, 2)
    replan = json.loads(llm.calls[1]["messages"][1]["content"])
    assert replan["decision"] == "replan"
    assert replan["detail"]["failed"]["reason"].startswith("no progress: Copper Ore +0/5")
    assert len([e for e in port.events if e["type"] == "board_step"]) == 2


def test_chat_cut_runs_do_not_count_but_spend_a_little_of_the_budget(tmp_path):
    d, port, world, llm, clock = make(tmp_path, lambda ev, port: {"actions": [], "ended": "chat"}, [
        decision(task_success=have(COPPER, 5), steps=[step("mine", gained(COPPER, 5), )])])
    d.handle_tool("add_task", {"text": "copper"}, "Zezima")
    ticks(d, 1)  # the plan lands and the first run starts in the same tick
    task = d.ops.b.current_task()
    s = task.steps[0]
    assert s.runs == 0 and s.uncounted_runs == 1 and d.ops.b.awaiting_decision is None
    assert task.spent == pytest.approx(0.25)
    ticks(d, int(B.PROGRESS_BUDGET / 0.25) + 2)
    assert task.status == "waiting_help" and "chat kept interrupting" in task.end_reason


# ------------------------------------------------------------------ preemption (H4, H6)


def test_a_player_command_preempts_and_the_resume_run_may_decline(tmp_path):
    def ctrl(ev, port):
        # the fake model judges from what the player said (simplify item 6: code never decides "stop")
        if ev["type"] == "board_step" and (ev.get("preempted_by") or {}).get("said") == "wait here":
            port.director.handle_tool("pause_board", {"reason": "he told me to wait"}, "Zezima")
            return {"actions": [], "ended": "normal"}
        return mine(COPPER, 1)(ev, port)
    d, port, world, llm, clock = make(tmp_path, ctrl, [
        decision(task_success=have(COPPER, 50), steps=[step("mine", gained(COPPER, 50))])])
    d.handle_tool("add_task", {"text": "copper"}, "Zezima")
    ticks(d, 2)
    n = len(port.events)
    d.on_player_command("Zezima", ["stop"], "wait here")  # he said something that made the Controller stop
    task = d.ops.b.current_task()
    assert task.status == "preempted"
    clock.t += 10
    ticks(d, 2)
    assert len(port.events) == n  # 30 s idle not reached
    clock.t += 25
    ticks(d, 1)
    ev = port.events[-1]
    assert ev["resumed"] and ev["preempted_by"]["tools"] == ["stop"] and ev["preempted_by"]["said"] == "wait here"
    assert "paused_by_player" not in ev
    assert d.ops.b.paused and task.status == "paused"
    ticks(d, 3)
    assert len(port.events) == n + 1  # stays paused until resume_board


def test_add_task_now_while_following_starts_at_once(tmp_path):
    d, port, world, llm, clock = make(tmp_path, mine(COPPER, 5), [
        decision(task_success=have(COPPER, 5), steps=[step("mine", gained(COPPER, 5))])])
    world.state["following"] = "Zezima"
    d.handle_tool("add_task", {"text": "copper", "when": "now"}, "Zezima")
    ticks(d, 2)
    assert [e for e in port.events if e["type"] == "board_step"]


def test_a_nested_chat_command_inside_a_run_is_tainted(tmp_path):
    """Re-check 1/2: during a board run, the player's own command gives him ore: not the step's work."""
    def ctrl(ev, port):
        if ev["type"] != "board_step":
            return None
        port.world.add(COPPER, 10)
        return {"actions": [{"tool": "fetch", "args": {"item": COPPER}, "ok": True, "data": {"item": COPPER},
                             "origin": "chat"}], "ended": "normal"}
    d, port, world, llm, clock = make(tmp_path, ctrl, [
        decision(task_success=have(COPPER, 50), steps=[step("mine", gained(COPPER, 5))])])
    d.handle_tool("add_task", {"text": "copper"}, "Zezima")
    ticks(d, 1)
    s = d.ops.b.current_task().steps[0]
    assert s.status == "active" and s.accumulated == {} and d.ops.b.current_task().tallies == {}


# ------------------------------------------------------------------ races and threads (H7a, H11)


class ManualExecutor:
    def __init__(self):
        self.jobs = []

    def submit(self, fn, *a):
        f = cf.Future()
        self.jobs.append((fn, a, f))
        return f

    def finish(self):
        for fn, a, f in self.jobs:
            f.set_result(fn(*a))
        self.jobs = []


def test_a_decision_for_a_cancelled_task_is_discarded_but_counted(tmp_path):
    ex = ManualExecutor()
    d, port, world, llm, clock = make(tmp_path, None, [
        decision(task_success=have(COPPER, 5), steps=[step("mine", gained(COPPER, 5))])], executor=ex)
    t = d.handle_tool("add_task", {"text": "copper"}, "Zezima")["data"]
    ticks(d, 1)
    d.handle_tool("cancel_task", {"id": t["id"]}, "Zezima")  # while Sonnet thinks
    ex.finish()
    ticks(d, 1)
    task = d.ops.b.task(t["id"])
    assert task.status == "cancelled" and task.steps == [] and d.window.left() == 19


def test_a_hung_decision_times_out_twice_then_parks_and_says_so(tmp_path):
    ex = ManualExecutor()
    d, port, world, llm, clock = make(tmp_path, None, [], executor=ex)
    t = d.handle_tool("add_task", {"text": "copper"}, "Zezima")["data"]
    for _ in range(2):
        ticks(d, 1)
        clock.t += D.DECISION_TIMEOUT_S + 1
        ticks(d, 1)
        ex.jobs = []
    task = d.ops.b.task(t["id"])
    assert task.status == "parked" and "planning" in task.end_reason
    assert [e for e in port.events if e["type"] == "board_notice"]


def test_body_reads_from_the_worker_are_served_on_the_agent_loop(tmp_path):
    calls = [LLMResponse(tool_calls=[ToolCall("craft_plan", {"item": "Bronze Pickaxe"}, "c1")]),
             decision(task_success=have(COPPER, 5), steps=[step("mine", gained(COPPER, 5))])]
    pool = cf.ThreadPoolExecutor(max_workers=1)
    d, port, world, llm, clock = make(tmp_path, None, calls, executor=pool,
                                      body_tools={"gather": "harvest", "craft_plan": "plan crafting"})
    d.handle_tool("add_task", {"text": "better pickaxe"}, "Zezima")
    main = threading.get_ident()
    for _ in range(200):
        d.tick()
        if d.ops.b.current_task().steps:
            break
        threading.Event().wait(0.01)
    pool.shutdown()
    assert port.reads and port.reads[0][0] == "craft_plan" and port.reads[0][2] == main
    assert d.ops.b.current_task().steps[0].title == "mine"


# ------------------------------------------------------------------ budget (M5)


class NoMoney:
    def allows(self, kind):
        return False


def test_out_of_budget_waits_and_says_so_once(tmp_path):
    d, port, world, llm, clock = make(tmp_path, None, [], budget=NoMoney())
    d.handle_tool("add_task", {"text": "copper"}, "Zezima")
    ticks(d, 5)
    notes = [e for e in port.events if e["type"] == "board_notice"]
    assert len(notes) == 1 and llm.calls == [] and d.ops.b.current_task().status == "waiting_budget"
    assert "out of planning budget" in d.handle_tool("add_task", {"text": "more"}, "Zezima")["data"]["note"]


def test_the_hourly_window_holds_decisions(tmp_path):
    d, port, world, llm, clock = make(tmp_path, None, [], per_hour=4)  # fewer than MAX_REQUESTS
    d.handle_tool("add_task", {"text": "copper"}, "Zezima")
    ticks(d, 3)
    notes = [e for e in port.events if e["type"] == "board_notice"]
    assert llm.calls == [] and len(notes) == 1 and notes[0]["facts"]["budget_wait_min"] >= 1


def test_kill_switch(tmp_path, monkeypatch):
    d, port, world, llm, clock = make(tmp_path, None, [])
    d.handle_tool("add_task", {"text": "copper"}, "Zezima")
    monkeypatch.setenv("DW_DIRECTOR", "0")
    ticks(d, 3)
    assert llm.calls == [] and port.events == []


# ------------------------------------------------------------------ knowledge gaps (section 2.11)


class FakeKnowledge:
    def __init__(self):
        self.queries = []

    def lookup(self, query, kind=None):
        self.queries.append(query)
        return {"ok": True, "data": {"results": [{"title": "Tin Ore", "text": "Tin rocks are by the river.",
                                                   "authoritative": False}]}}

    def kinds(self):
        return []


def test_unknown_facts_get_one_nudge_and_lookups_are_cached_and_scored(tmp_path):
    k = FakeKnowledge()
    plan_unknown = decision(task_success=have(TIN, 3), steps=[step("mine tin", gained(TIN, 3))],
                            facts=[{"fact": "where tin rocks are", "status": "unknown", "source": "none"}])
    calls = [plan_unknown, LLMResponse(tool_calls=[ToolCall("lookup", {"query": "where are tin rocks"}, "l1")]),
             decision(task_success=have(TIN, 3), steps=[step("mine tin", gained(TIN, 3))],
                      facts=[{"fact": "where tin rocks are", "status": "unknown", "source": "wiki"}])]
    d, port, world, llm, clock = make(tmp_path, None, calls, knowledge=k)
    d.log = ListLog()
    tid = d.handle_tool("add_task", {"text": "get tin"}, "Zezima")["data"]["id"]
    ticks(d, 1)
    assert "These facts are listed as unknown" in llm.calls[1]["messages"][-1]["content"] and k.queries == ["where are tin rocks"]
    assert d.memory.recall("tin rocks")[0]["source"] == "wiki"
    assert d.ops.b.task(tid).steps[0].title == "mine tin"
    assert [r["needed"] for r in d.log.rows if r["kind"] == "director_lookup"] == [True]


# ------------------------------------------------------------------ gaps (M4) and prerequisites (H10)


def test_gap_claims_are_cross_checked_and_new_gaps_are_told_once(tmp_path):
    d, port, world, llm, clock = make(tmp_path, mine(COPPER, 1), [
        decision(task_success=have(COPPER, 9), steps=[step("mine", gained(COPPER, 9))],
                 capability_gaps=[{"primitive": "deposit", "kind": "action", "why": "to store the ore", "workaround": "drop at base"},
                                  {"primitive": "gather", "kind": "action", "why": "to mine"}])])
    d.handle_tool("add_task", {"text": "copper"}, "Zezima")
    ticks(d, 2)
    assert d.gaps.gaps["deposit"]["count"] == 1 and d.gaps.gaps["gather"]["count"] == 0
    first = [e for e in port.events if e["type"] == "board_step"][0]
    assert first["tell_player"] == ["I can't deposit yet (to store the ore); workaround: drop at base"]
    assert any(h.get("outcome") == "claim" for h in d.ops.b.current_task().history)
    later = [e for e in port.events if e["type"] == "board_step"][1:]
    assert all("tell_player" not in e for e in later)


def test_a_self_added_prerequisite_runs_first(tmp_path):
    d, port, world, llm, clock = make(tmp_path, mine(COPPER, 5), [
        decision(task_success=have(COPPER, 5), steps=[step("mine", gained(COPPER, 5))],
                 add_tasks=[{"text": "upgrade my pickaxe", "because": "tier 1 is slow"}]),
        decision(task_success=have(COPPER, 5), steps=[step("prep", gained(COPPER, 5))])])
    t = d.handle_tool("add_task", {"text": "copper"}, "Zezima")["data"]
    ticks(d, 3)
    kid = next(x for x in d.ops.b.tasks if x.by == "self")
    assert kid.parent == t["id"] and kid.because == "tier 1 is slow"
    first_run = [e for e in port.events if e["type"] == "board_step"][0]
    assert first_run["task"] == "upgrade my pickaxe"


# ------------------------------------------------------------------ prep, abort, loops, reflection


def test_a_risky_step_gets_a_prepare_decision_and_abort_if_stops_it(tmp_path):
    def hurt(ev, port):
        if ev["type"] == "board_step":
            port.world.state["health"] = 20
        return {"actions": [], "ended": "normal"}
    d, port, world, llm, clock = make(tmp_path, hurt, [
        decision(task_success={"killed": {"kind": "rat", "at_least": 1}},
                 steps=[step("hunt rats", {"killed": {"kind": "rat", "at_least": 1}}, risk="fight")]),
        decision(steps=[step("hunt rats", {"killed": {"kind": "rat", "at_least": 1}}, risk="fight",
                             abort_if={"vital": {"stat": "health", "below_pct": 30}}, escape="run back home")]),
        decision(steps=[step("heal up", {"vital": {"stat": "health", "at_least_pct": 80}})])])
    d.handle_tool("add_task", {"text": "hunt"}, "Zezima")
    ticks(d, 6)
    kinds = [json.loads(c["messages"][1]["content"])["decision"] for c in llm.calls]
    assert kinds[:3] == ["plan", "prepare", "replan"]
    run = [e for e in port.events if e["type"] == "board_step"][0]
    assert run["step"]["escape"] == "run back home"
    replan = json.loads(llm.calls[2]["messages"][1]["content"])
    assert replan["detail"]["failed"]["reason"].startswith("aborted: health 20%")


def test_trips_loop_without_model_calls_and_drops_are_tracked(tmp_path):
    def trip(ev, port):
        if ev["type"] != "board_step":
            return None
        if ev["step"]["title"] == "mine":
            port.world.add(COPPER, 4)
            return {"actions": [{"tool": "gather", "ok": True, "args": {}, "data": {"item": COPPER}}], "ended": "normal"}
        port.world.add(COPPER, -4)
        return {"actions": [{"tool": "drop", "ok": True, "args": {"item": COPPER, "count": 4},
                             "data": {"item": COPPER, "count": 4, "world_items": ["w%d" % len(port.events)]}}],
                "ended": "normal"}
    until = {"tally": {"item": COPPER, "at_least": 12}}
    d, port, world, llm, clock = make(tmp_path, trip, [
        decision(task_success=until, steps=[step("mine", gained(COPPER, 4), group="trip"),
                                            step("drop", {"lost": {"item": COPPER, "at_least": 4}}, group="trip")],
                 loops={"trip": {"until": until}})])
    t = d.handle_tool("add_task", {"text": "haul copper"}, "Zezima")["data"]
    ticks(d, 12)
    task = d.ops.b.task(t["id"])
    assert task.status == "done" and task.tallies == {COPPER: 12.0} and len(llm.calls) == 1
    assert len(task.my_drops) == 2  # the tally reached 12 after the third mining step: done before a third drop


def test_restart_continues_the_active_step(tmp_path):
    d, port, world, llm, clock = make(tmp_path, mine(COPPER, 1), [
        decision(task_success=have(COPPER, 50), steps=[step("mine", gained(COPPER, 50))])])
    d.handle_tool("add_task", {"text": "copper"}, "Zezima")
    ticks(d, 3)
    acc = dict(d.ops.b.current_task().steps[0].accumulated)
    d2 = D.Director(port, FakeLLM([]), tmp_path / "worlds" / "dev", executor=D.SyncExecutor(), clock=clock)
    port.director = d2
    d2.tick()
    s = d2.ops.b.current_task().steps[0]
    assert s.status == "active" and s.accumulated[COPPER] == acc[COPPER] + 1


def test_board_tool_schemas_and_validation(tmp_path):
    d, *_ = make(tmp_path)
    names = [t["function"]["name"] for t in d.tool_schemas()]
    assert names == list(D.BOARD_TOOL_NAMES) and d.read_tool_names == ("board",)
    with pytest.raises(Exception):
        d.validate_tool("add_task", {})
    assert d.handle_tool("report_step", {"outcome": "done", "reason": "x"}, "Z")["reason"] == "no_current_step"
    assert d.handle_tool("cancel_task", {}, "Z")["reason"] == "board_refused"
    assert d.retrieval_text({"type": "board_step", "step": {"title": "mine"}}) == "mine"
    assert "task board" in d.persona_lines()


def test_help_waits_for_the_asked_player_to_be_around(tmp_path):
    d, port, world, llm, clock = make(tmp_path, None, [
        decision(ask_help="Where should I look for tin?")])
    d.handle_tool("add_task", {"text": "get tin"}, "Zezima")
    world.state["players"] = []  # he logged off
    ticks(d, 3)
    task = d.ops.b.current_task() or next(t for t in d.ops.b.tasks)
    assert task.status == "waiting_help" and task.help.revoice_pending and not port.events
    world.state["players"] = [{"name": "Zezima", "distance": 5.0}]
    d._last_state = port.state()
    ticks(d, 1)
    assert [e["facts"]["question"] for e in port.events if e["type"] == "board_notice"] == ["Where should I look for tin?"]


def test_nothing_in_range_is_negative_evidence_in_map_memory(tmp_path):
    class Mem:
        def __init__(self):
            self.neg = []

        def note_negative(self, item, position, why, kind="depleted"):
            self.neg.append((item, position, why, kind))

        def snapshot(self):
            return {"sightings": [], "negative": []}

    def empty(ev, port):
        if ev["type"] != "board_step":
            return None
        return {"actions": [{"tool": "gather", "args": {"resource": "tin", "count": 3}, "ok": False,
                             "reason": "nothing_in_range", "data": {}}], "ended": "normal"}
    mem = Mem()
    d, port, world, llm, clock = make(tmp_path, empty, [
        decision(task_success=have(TIN, 3), steps=[step("mine", gained(TIN, 3))])], map_memory=mem)
    d.handle_tool("add_task", {"text": "tin"}, "Zezima")
    ticks(d, 1)
    assert mem.neg == [("tin", [0.0, 0.0, 0.0], "nothing_in_range", "empty")]


def test_a_finished_step_is_learned_on_the_worker_and_saved_on_the_loop(tmp_path):
    from brain.skill_library import SkillLibrary
    from brain.state_store import SkillRegistry
    lib_dir = tmp_path / "skills"
    owner = SkillLibrary(lib_dir)
    skill = {"name": "mine_and_craft", "description": "Mine then craft.", "params": {},
             "steps": [{"skill": "gather", "args": {"resource": "copper", "count": 5}},
                       {"skill": "craft", "args": {"item": "plank", "count": 1}}],
             "preconditions": [], "postcondition": None, "example_params": {}}

    def ctrl(ev, port):
        if ev["type"] != "board_step":
            return None
        port.world.add(COPPER, 5)
        return {"actions": [{"tool": "gather", "args": {"resource": "copper", "count": 5}, "ok": True,
                             "data": {"item": COPPER}},
                            {"tool": "craft", "args": {"item": "plank", "count": 1}, "ok": True, "data": {}}],
                "ended": "normal"}
    d, port, world, llm, clock = make(tmp_path, ctrl, [
        decision(task_success=have(COPPER, 10), steps=[step("mine", gained(COPPER, 5)),
                                                       step("mine more", gained(COPPER, 5))]),
        json.dumps(skill)])
    d.skills, d.skills_registry = owner, SkillRegistry()
    d.handle_tool("add_task", {"text": "copper"}, "Zezima")
    ticks(d, 4)
    assert owner.names() == ["mine_and_craft"] and (lib_dir / "mine_and_craft.json").exists()
    assert d.window.left() == 18  # the plan + the learning request


def test_a_slow_loop_triggers_a_reflect_decision_and_a_trend_line(tmp_path):
    rates = iter([8, 8, 2, 2, 2, 2])

    def trip(ev, port):
        if ev["type"] != "board_step":
            return None
        port.world.add(COPPER, next(rates))
        port.director.clock.t += 60
        return {"actions": [{"tool": "gather", "ok": True, "args": {}, "data": {"item": COPPER}}], "ended": "normal"}
    until = {"tally": {"item": COPPER, "at_least": 100}}
    d, port, world, llm, clock = make(tmp_path, trip, [
        decision(task_success=until, steps=[step("mine", gained(COPPER, 1), group="g")], loops={"g": {"until": until}}),
        decision(description="slower now: switch spots", steps=[step("mine", gained(COPPER, 1), group="g")])])
    d.handle_tool("add_task", {"text": "lots of copper"}, "Zezima")
    ticks(d, 8)
    kinds = [json.loads(c["messages"][1]["content"])["decision"] for c in llm.calls]
    assert "reflect" in kinds
    lines = (tmp_path / "worlds" / "dev" / "efficiency.jsonl").read_text(encoding="utf-8").splitlines()
    assert lines and json.loads(lines[0])["key"] == f"item:{COPPER}"


# ------------------------------------------------------------------ the real Agent + the applied hooks


@pytest.mark.parametrize("channel", ["text", "say"])
def test_silent_board_results_get_a_reply_without_waiting_or_self_preemption(tmp_path, monkeypatch, channel):
    from conftest import Rig
    from brain.interface import CommandReceived

    monkeypatch.setenv("DW_SPEECH_CHANNEL", channel)
    rig = Rig(tmp_path)
    worker = ManualExecutor()
    director = D.Director(D.AgentPort(rig.agent, "Luis"), FakeLLM([], model="fake/director"),
                          tmp_path / "board", executor=worker)
    rig.agent.director = director
    rig.controller.attach_director(director)

    def spoken(text):
        return LLMResponse(tool_calls=[FakeLLM.call("say", text=text)]) if channel == "say" else FakeLLM.say(text)

    rig.controller_llm.push(LLMResponse(tool_calls=[FakeLLM.call("add_task", text="collect supplies", when="now")]),
                            spoken("It's on my task list."))
    rig.agent.handle_event(CommandReceived(player="Luis", text="collect supplies"))
    task = director.ops.b.current_task()
    assert task is not None and task.status == "active"
    assert rig.companion_said() == ["It's on my task list."]
    result = [json.loads(m["content"]) for m in rig.controller_llm.calls[1]["messages"]
              if m.get("role") == "tool" and m.get("name") == "add_task"]
    assert result and result[0]["ok"] and result[0]["data"]["id"] == task.id

    director.tick()
    future = director._future
    assert future is not None and not future.done() and len(worker.jobs) == 1
    rig.controller_llm.push(LLMResponse(tool_calls=[FakeLLM.call("board")]),
                            spoken("The plan is still pending."))
    rig.agent.handle_event(CommandReceived(player="Luis", text="what's happening with the task?"))
    director.tick()
    assert director._future is future and not future.done() and len(worker.jobs) == 1
    assert task.status == "active"
    assert rig.companion_said() == ["It's on my task list.", "The plan is still pending."]


@pytest.mark.parametrize("channel", ["text", "say"])
def test_failed_board_result_is_explained_without_claiming_success(tmp_path, monkeypatch, channel):
    from conftest import Rig
    from brain.interface import CommandReceived

    monkeypatch.setenv("DW_SPEECH_CHANNEL", channel)
    rig = Rig(tmp_path)
    director = D.Director(D.AgentPort(rig.agent, "Luis"), FakeLLM([], model="fake/director"),
                          tmp_path / "board", executor=ManualExecutor())
    rig.agent.director = director
    rig.controller.attach_director(director)
    reply = "I need a task description."
    speech = LLMResponse(tool_calls=[FakeLLM.call("say", text=reply)]) if channel == "say" else FakeLLM.say(reply)
    rig.controller_llm.push(LLMResponse(tool_calls=[FakeLLM.call("add_task", text="")]), speech)
    rig.agent.handle_event(CommandReceived(player="Luis", text="queue a task"))
    assert rig.companion_said() == [reply]
    assert not director.ops.b.tasks
    results = [json.loads(m["content"]) for m in rig.controller_llm.calls[1]["messages"]
               if m.get("role") == "tool" and m.get("name") == "add_task"]
    assert results and results[0]["ok"] is False


def test_end_to_end_with_the_real_agent_controller_and_hooks(tmp_path):
    """Chat -> add_task (a board tool through Agent._run_turn) -> a Sonnet plan -> run_directed (a body-initiated
    Controller run on the mock) -> gather verified -> the step and the job are done from fresh state -> the
    Controller voices the end. Uses brain/agent.py and controller.py as they are (hooks applied)."""
    from conftest import Rig
    rig = Rig(tmp_path)
    items = P.Items(names={"log": "log", "stone": "stone"})  # the mock's own item ids
    plan = decision(task_success={"have": {"item": "log", "at_least": 3}},
                    steps=[step("chop logs", {"gained": {"item": "log", "at_least": 3}})])
    director = D.Director(D.AgentPort(rig.agent, "Luis"), FakeLLM([plan], model="fake/director"), tmp_path / "board",
                          body_tools={"gather": "harvest"}, executor=D.SyncExecutor(), items=items)
    rig.agent.director = director
    rig.controller.attach_director(director)
    assert {"add_task", "board", "report_step"} <= rig.controller.offered()
    c = rig.controller_llm
    c.push(FakeLLM.say("Sure, I'll get you some logs.", FakeLLM.call("add_task", text="get 3 logs", when="now")),
           FakeLLM.say("Chopping logs.", FakeLLM.call("gather", resource="log", count=3)), "",
           "Got your 3 logs.", "", "", "")
    rig.game.player_say("claude get me 3 logs")
    for _ in range(4):
        rig.agent.step()
    task = director.ops.b.tasks[0]
    assert task.by == "player:Luis" and task.status == "done", (task.status, task.end_reason)
    assert rig.game.inventory["log"] >= 3 and rig.calls("gather")
    body_events = [json.loads(m["content"]).get("body_event") for call in c.calls for m in call["messages"]
                   if m["role"] == "user" and m["content"].startswith("{")]
    kinds = [e.get("type") for e in body_events if e]
    assert "board_step" in kinds and "board_notice" in kinds
    said = rig.companion_said()
    assert "Sure, I'll get you some logs." in said and "Got your 3 logs." in said


def test_a_review_that_keeps_the_plan_changes_nothing(tmp_path):
    d, port, world, llm, clock = make(tmp_path, mine(COPPER, 1), [
        decision(task_success=have(COPPER, 50), steps=[step("mine", gained(COPPER, 50)), step("then", have(TIN, 1))]),
        decision(description="still fine")])
    d.handle_tool("add_task", {"text": "copper"}, "Zezima")
    ticks(d, 2)
    clock.t += D.REVIEW_EVERY_S + 1
    ticks(d, 3)
    task = d.ops.b.current_task()
    kinds = [json.loads(c["messages"][1]["content"])["decision"] for c in llm.calls]
    assert kinds == ["plan", "review"] and [s.title for s in task.steps] == ["mine", "then"]
    assert task.steps[0].status == "active"


# ------------------------------------------------------------------ wave 5 fixes (real Sonnet cassettes)


def test_research_limit_keeps_tools_offered_says_so_and_refuses_late_calls():
    from brain.llm_json import RESEARCH_OVER, json_decision
    look = lambda i: LLMResponse(tool_calls=[ToolCall("recall", {"query": f"q{i}"}, f"t{i}")])
    llm = FakeLLM([look(1), look(2), look(3), look(4), '{"ok": 1}'])
    ran = []
    value, info = json_decision(llm, [{"role": "user", "content": "go"}], lambda t, r: json.loads(t),
                                tools=[{"type": "function", "function": {"name": "recall"}}],
                                run_tool=lambda n, a: ran.append(a) or {"ok": True}, max_tool_rounds=3, max_repairs=1)
    assert value == {"ok": 1} and len(ran) == 3 and info["requests"] == 5
    assert all(c["tools"] for c in llm.calls)  # never withdrawn (LiteLLM would inject a dummy tool)
    assert llm.calls[3]["messages"][-1]["content"] == RESEARCH_OVER
    assert info["tool_calls"][-1]["refused"] is True


def test_lookup_scoring_needed_needless_or_unknown():
    facts = [{"fact": "where coal nodes are", "status": "unknown"}]
    lookups = [{"query": "coal node locations", "result": {}}, {"query": "Lodestone", "result": {}},
               {"query": "lodestone", "result": {}}]
    calls = [{"name": "lookup", "args": {"query": q["query"]}} for q in lookups]
    assert [x["needed"] for x in D.score_lookups(lookups, facts, calls)] == [True, None, False]


def test_only_one_prerequisite_is_taken_per_decision(tmp_path):
    d, port, world, llm, clock = make(tmp_path, None, [
        decision(task_success=have(COPPER, 5), steps=[step("mine", gained(COPPER, 5))],
                 add_tasks=[{"text": "a", "because": "x"}, {"text": "b", "because": "y"}, {"text": "c", "because": "z"}])])
    d.handle_tool("add_task", {"text": "copper"}, "Zezima")
    ticks(d, 2)
    assert [t.text for t in d.ops.b.tasks if t.by == "self"] == ["a"]


def test_a_job_test_that_can_never_be_checked_goes_back_for_repair(tmp_path):
    d, port, world, llm, clock = make(tmp_path, None, [
        decision(task_success={"quest": {"name": "Some Quest", "completed": True}}, steps=[step("go", have(COPPER, 1))]),
        decision(ask_help="I can't see quest progress; want me to do something else?")])
    d.handle_tool("add_task", {"text": "do the quest"}, "Zezima")
    ticks(d, 2)
    assert "task_success can't be checked from what the body reports (missing: quests)" in \
        llm.calls[1]["messages"][-1]["content"]
    t = d.ops.b.tasks[0]
    assert t.success is None and t.status == "waiting_help"


def test_a_knowledge_gap_is_never_a_capability_gap(tmp_path):
    d, port, world, llm, clock = make(tmp_path, mine(COPPER, 1), [
        decision(task_success=have(COPPER, 9), steps=[step("mine", gained(COPPER, 9))],
                 capability_gaps=[{"primitive": "read drop tables", "why": "the wiki lists no source"}]),
        decision(task_success=have(COPPER, 9), steps=[step("mine", gained(COPPER, 9))],
                 capability_gaps=[{"primitive": "read drop tables", "kind": "knowledge", "why": "no source found"},
                                  {"primitive": "deposit", "kind": "action", "why": "to store it"},
                                  {"primitive": "perceive:quests", "kind": "perception", "why": "no quest state"}])])
    d.handle_tool("add_task", {"text": "copper"}, "Zezima")
    ticks(d, 2)
    assert "kind must be one of action, perception, knowledge" in llm.calls[1]["messages"][-1]["content"]
    backlog = [g["primitive"] for g in d.gaps.backlog()]
    assert "read drop tables" not in backlog and set(backlog) >= {"deposit", "perceive:quests"}
    assert "read drop tables" not in d.gaps.gaps  # knowledge gaps live only in the knowledge memory (item 7)
    told = [line for e in port.events if e.get("tell_player") for line in e["tell_player"]]
    assert not any("drop tables" in line for line in told) and any("deposit" in line for line in told)
    assert d.memory.recall("drop tables")[0]["value"]["status"] == "unknown"


def test_chat_arriving_during_a_run_stops_the_chain_until_the_next_tick(tmp_path):
    """Chaining never runs over a player: a chat line that arrives during a board run ends the tick's chain, and
    the next step starts only after the agent has handled the chat."""
    def ctrl(ev, port):
        if ev["type"] != "board_step":
            return None
        port.world.add(COPPER, 1)
        port.chat = ev["step"]["title"] == "first"  # the player speaks while the first step runs
        return {"actions": [{"tool": "gather", "args": {}, "ok": True, "data": {"item": COPPER}, "origin": "board"}],
                "ended": "normal"}
    d, port, world, llm, clock = make(tmp_path, ctrl, [
        decision(task_success=have(COPPER, 3), steps=[step("first", gained(COPPER, 1)), step("second", gained(COPPER, 1)),
                                                      step("third", gained(COPPER, 1))])])
    d.handle_tool("add_task", {"text": "copper"}, "Zezima")
    ticks(d, 1)
    assert [e["step"]["title"] for e in port.events if e["type"] == "board_step"] == ["first"]
    ticks(d, 1)  # chat still waiting: nothing starts
    assert len([e for e in port.events if e["type"] == "board_step"]) == 1
    port.chat = False  # the agent answered the chat
    ticks(d, 1)
    assert [e["step"]["title"] for e in port.events if e["type"] == "board_step"] == ["first", "second", "third"]
    assert d.ops.b.tasks[0].status == "done"


def test_a_wait_step_runs_no_controller_and_ends_when_its_test_passes_or_fails_after_the_wait_cap(tmp_path):
    d, port, world, llm, clock = make(tmp_path, mine(COPPER, 1), [
        decision(task_success=have(COPPER, 1), steps=[
            {"title": "let it smelt", "why": "", "hints": "", "success": P.validate({"elapsed": {"seconds": 60}}),
             "wait": True},
            step("mine", gained(COPPER, 1))])])
    d.handle_tool("add_task", {"text": "copper"}, "Zezima")
    ticks(d, 3)
    assert not [e for e in port.events if e["type"] == "board_step"]  # waiting is not a Controller run
    clock.t += 61
    ticks(d, 1)
    assert [e["step"]["title"] for e in port.events if e["type"] == "board_step"] == ["mine"]
    assert d.ops.b.tasks[0].status == "done"


def test_a_wait_that_never_ends_fails_the_attempt_for_a_replan(tmp_path):
    d, port, world, llm, clock = make(tmp_path, None, [
        decision(task_success=have(COPPER, 1), steps=[
            {"title": "wait for copper", "why": "", "hints": "", "success": have(COPPER, 1), "wait": True}])])
    d.handle_tool("add_task", {"text": "copper"}, "Zezima")
    ticks(d, 1)
    clock.t += D.WAIT_MAX_S + 1
    ticks(d, 1)
    s = d.ops.b.tasks[0].steps[0]
    assert s.status == "failed" and "waited 30 min" in s.failures[-1]["reason"]


def test_a_plans_first_call_runs_before_the_controller_and_a_passed_step_needs_no_turn(tmp_path):
    d, port, world, llm, clock = make(tmp_path, mine(COPPER, 1), [
        decision(task_success=have(COPPER, 20), steps=[
            step("first", gained(COPPER, 1)),
            {**step("second", gained(COPPER, 1)), "first_call": {"tool": "gather", "args": {"resource": "x", "count": 1}}},
            {**step("third", gained(COPPER, 5)), "first_call": {"tool": "gather", "args": {"resource": "x", "count": 1}}}])])
    calls = []

    def first_call(call):
        calls.append(call)
        world.add(COPPER, 1)
        return {"tool": call["tool"], "args": call["args"], "ok": True, "reason": None, "data": {"item": COPPER},
                "interrupt": False, "origin": "board"}
    port.first_call = first_call
    d.handle_tool("add_task", {"text": "copper"}, "Zezima")
    ticks(d, 1)
    runs = [e for e in port.events if e["type"] == "board_step"]
    assert len(calls) == 2  # "second" and "third" started with the plan's own call
    assert [e["step"]["title"] for e in runs] == ["first", "third"]  # "second" passed on its first call
    assert runs[1]["first_call_result"]["ok"] is True  # the Controller carries on from it


def test_a_first_call_must_name_one_of_his_tools(tmp_path):
    d, port, world, llm, clock = make(tmp_path, None, [
        decision(task_success=have(COPPER, 1), steps=[
            {**step("mine", gained(COPPER, 1)), "first_call": {"tool": "teleport", "args": {}}}]),
        decision(task_success=have(COPPER, 1), steps=[step("mine", gained(COPPER, 1))])])
    d.handle_tool("add_task", {"text": "copper"}, "Zezima")
    ticks(d, 1)
    assert "first_call: tool must be one of your tools" in llm.calls[1]["messages"][-1]["content"]


def test_a_working_step_tested_only_by_elapsed_time_gets_one_advisory(tmp_path):
    """Live smoke run 2: steps tested only by elapsed time passed although their tools failed. The model hears it
    once (information) and may keep the plan."""
    d, port, world, llm, clock = make(tmp_path, None, [
        decision(task_success=have(COPPER, 1), steps=[step("set my policy", P.validate({"elapsed": {"seconds": 3}}))]),
        decision(task_success=have(COPPER, 1), steps=[step("set my policy", P.validate({"elapsed": {"seconds": 3}}))])])
    d.handle_tool("add_task", {"text": "copper"}, "Zezima")
    ticks(d, 1)
    assert "only counts time" in llm.calls[1]["messages"][-1]["content"]
    assert d.ops.b.tasks[0].steps and d.ops.b.tasks[0].steps[0].title == "set my policy"


def test_the_planner_snapshot_shows_what_he_can_gather_here():
    """M4 mock run (real Sonnet): get_state listed the nodes in reach, but the Director's snapshot dropped them, so the
    plan guessed a resource that wasn't there. Rows are grouped per kind, nearest first, keeping the body's tool needs."""
    state = {"nearby_resources": [
        {"id": "n1", "name": "Rock A", "item": "ITEM_A", "distance": 31.0, "tool": "pickaxe", "tool_tier": 2},
        {"id": "n2", "name": "Rock A", "item": "ITEM_A", "distance": 18.24},
        {"id": "n3", "name": "Tree B", "verb": "chop", "distance": 6.0},
        "junk", {"id": "n4"}]}
    me = D._compact_state(state)
    assert me["resources_near"] == [
        {"name": "Tree B", "nodes": 1, "nearest_m": 6.0, "verb": "chop"},
        {"name": "Rock A", "nodes": 2, "nearest_m": 18.2, "item": "ITEM_A", "tool": "pickaxe", "tool_tier": 2}]
    assert "resources_near" not in D._compact_state({})


def test_the_planner_snapshot_lists_his_spells_for_prep():
    """M4 mock run (real Sonnet, a weakness fight): the plan skipped the enchant because it couldn't tell whether he
    can cast it; get_state.spells (spells.lua) was dropped from the Director's snapshot."""
    state = {"spells": [{"id": "s1", "name": "Spell A", "role": "enchant", "castable": True, "use_when": "long text"},
                        {"id": "s2", "name": "Spell B", "castable": False, "reason": "requirement", "needs": "X"},
                        {"id": "s3"}]}
    assert D._compact_state(state)["spells"] == [
        {"name": "Spell A", "role": "enchant", "castable": True},
        {"name": "Spell B", "castable": False, "reason": "requirement", "needs": "X"}]
