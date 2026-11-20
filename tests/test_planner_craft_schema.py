"""The Planner's craft is the body's craft (study craft_hold_gap 2026-11-20).

Copper L2, 6 runs: the Planner saw craft as the brain's stub {item, count} while the Controller had the body's
manifest (item, input, recipe, station, fuel, count), and validation stripped any recipe/station the Planner wrote.
10 of 19 craft misses were Planner steps failing ambiguous_target or unknown_recipe with the inputs carried.
Here: the Planner is shown the Controller's craft schema, a step with station and input survives validation and
reaches the body as written, and an arg the body does not take is refused with the reason.
"""
import json

import pytest

from brain.capabilities import MANIFEST_ARGS, Capabilities
from brain.executor import Executor
from brain.interface import ok
from brain.jsonl_log import JsonlLogger
from brain.llm import FakeLLM
from brain.mock import MockGame
from brain.planner import Planner, parse_steps
from brain.state_store import MOCK_SKILLS, SkillArgsError, StateStore

# client_mod/scripts/crafting.lua M.MANIFEST.craft, as the body publishes it (max_count from its cfg)
CRAFT = {
    "kind": "action", "llm": True, "moves": True, "priority": "command", "duration_s": 15, "timeout_s": 300,
    "detail_is_speech": True,
    "description": "Make one recipe at a nearby station from carried items (walks there, uses it, collects the "
                   "result). It needs every input carried, the recipe unlocked and a station of its type: without one "
                   "it fails and says which. What a recipe takes, and what of it you are short of, is read with "
                   "recipes. It does not gather or craft ingredients (craft_plan plans those).",
    "args": {"type": "object", "properties": {
        "item": {"type": "string", "description": "Item to make (name or id)."},
        "input": {"type": "string", "description": "Or a carried item to put in the station instead of naming what "
                  "comes out (e.g. raw food at a fire): the recipe that takes it."},
        "recipe": {"type": "string", "description": "Recipe id, to pick one of several."},
        "count": {"type": "integer", "minimum": 1, "maximum": 50,
                  "description": "Items, default 1 (crafts with recipe or input; input without count: all of it)."},
        "station": {"type": "string", "description": "Station id (default nearest)."},
        "fuel": {"type": "string", "description": "Fuel to burn (processing)."}}},
}
MOVE_ITEM = {"kind": "action", "llm": True, "description": "Move a carried item.",
             "args": {"type": "object", "properties": {"item": {"type": "string"}, "to": {"type": "string"}},
                      "required": ["item", "to"]}}
GATHER = {"kind": "action", "llm": True, "description": "Gather.",
          "args": {"type": "object", "properties": {"resource": {"type": "string"}}}}
STATION = "BP_Station_SpinningWheel_C_2147480001"


def caps() -> Capabilities:
    return Capabilities(list(MOCK_SKILLS), "capabilities", manifest={"craft": CRAFT, "move_item": MOVE_ITEM, "gather": GATHER})


def plan_text(*steps: dict) -> str:
    return json.dumps({"description": None, "explanation": None, "ask_help": None, "tasks": list(steps)})


class Body(MockGame):
    """The mock world with the craft manifest: calls go through the same validator as live (interface.call)."""

    def __init__(self, c: Capabilities):
        w = MockGame.default_world()
        self.__dict__.update(w.__dict__)
        self.manifest_tools = frozenset(c.manifest)
        self.manifest_validator = c.validate
        self.sent: list[tuple[str, dict]] = []

    def call_manifest(self, tool, args):
        self.sent.append((tool, dict(args)))
        return ok(detail="made it")


def test_craft_is_in_the_manifest_set():
    assert "craft" in MANIFEST_ARGS


def test_planner_is_shown_the_controllers_craft_schema(tmp_path):
    c = caps()
    reg = c.registry()
    shown = {d["name"]: d for d in reg.describe()}["craft"]
    fn = c.function_schema("craft")["function"]  # what the Controller's tool list carries (tool_registry)
    assert shown["args"] == fn["parameters"]["properties"]
    assert shown["description"] == fn["description"]
    assert shown["required"] == fn["parameters"].get("required", [])
    assert {"item", "input", "recipe", "station", "fuel", "count"} <= set(shown["args"])
    # and it is in the Planner's system prompt as such
    system = Planner(FakeLLM(), reg, JsonlLogger(tmp_path / "b.jsonl"))._system()["content"]
    assert '"station"' in system and '"recipe"' in system and '"fuel"' in system
    # other stub skills stay on the brain's typed models (one change per window)
    assert {d["name"]: d for d in reg.describe()}["gather"]["args"].keys() >= {"resource", "count", "radius"}


def test_craft_step_with_station_and_input_survives_and_reaches_the_body(tmp_path):
    c = caps()
    store = StateStore(tmp_path / "state", c.registry())
    log = JsonlLogger(tmp_path / "b.jsonl")
    planner = Planner(FakeLLM(), store.skills, log)
    step = {"skill": "craft", "args": {"input": "Coarse Animal Fur", "count": 2, "station": STATION,
                                       "recipe": "RECIPE_Process_Thread_Coarse", "fuel": "Ash Logs"}}
    plan = planner._validate(plan_text(step))
    assert len(plan.tasks) == 1
    task = plan.tasks[0]
    assert task.args == step["args"]  # nothing stripped, nothing added
    body = Body(c)
    ex = Executor(body, store, log, max_attempts=1)
    ex.run_task(task)
    assert body.sent == [("craft", step["args"])]


def test_craft_by_item_alone_gets_no_invented_count(tmp_path):
    """The stub added count=1 to every step; the body reads "input without count" as all of it."""
    tasks, errors = parse_steps(caps().registry(), [{"skill": "craft", "args": {"input": "Raw Rat Meat"}}])
    assert not errors and tasks[0].args == {"input": "Raw Rat Meat"}


def test_unknown_craft_arg_is_refused_with_the_reason():
    tasks, errors = parse_steps(caps().registry(), [{"skill": "craft", "args": {"item": "Coarse Thread",
                                                                                "wheel": STATION}}])
    assert not tasks and len(errors) == 1
    assert "unknown arg 'wheel'" in errors[0] and "station" in errors[0] and "craft takes" in errors[0]


def test_wrong_type_is_refused_with_the_reason():
    tasks, errors = parse_steps(caps().registry(), [{"skill": "craft", "args": {"item": "Coarse Thread",
                                                                                "count": 0}}])
    assert not tasks and errors[0].startswith("task 0 (craft): craft:") and "minimum" in errors[0]
    with pytest.raises(SkillArgsError):
        caps().registry().validate("craft", {"item": "Coarse Thread", "station": 7})


def test_planner_repair_round_carries_the_refusal(tmp_path):
    """An invalid step is not dropped: the plan fails validation and its reason goes back for one repair."""
    llm = FakeLLM()
    llm.push(plan_text({"skill": "craft", "args": {"item": "Coarse Thread", "wheel": STATION}}),
             plan_text({"skill": "craft", "args": {"item": "Coarse Thread", "station": STATION}}))
    store = StateStore(tmp_path / "state", caps().registry())
    planner = Planner(llm, store.skills, JsonlLogger(tmp_path / "b.jsonl"))
    plan = planner.plan("make coarse thread", {"inventory": []}, {})
    assert plan.tasks[0].args == {"item": "Coarse Thread", "station": STATION}
    repair = json.dumps(llm.calls[1]["messages"], default=str)
    assert "unknown arg 'wheel'" in repair


def test_other_manifest_skills_refuse_unknown_args_too():
    tasks, errors = parse_steps(caps().registry(), [{"skill": "move_item", "args": {"item": "A", "to": "hotbar",
                                                                                    "slot": 3}}])
    assert not tasks and "unknown arg 'slot'" in errors[0]


def test_old_body_without_manifest_keeps_the_stub():
    c = Capabilities(list(MOCK_SKILLS), "probe")
    tasks, errors = parse_steps(c.registry(), [{"skill": "craft", "args": {"item": "Coarse Thread"}}])
    assert not errors and tasks[0].args == {"item": "Coarse Thread", "count": 1}
