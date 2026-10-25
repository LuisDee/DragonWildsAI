from brain.interface import Attacked, CommandReceived, tool_schemas
from brain.mock import MockGame


def test_tool_schemas_are_openai_style():
    schemas = {s["function"]["name"]: s for s in tool_schemas()}
    assert set(schemas) >= {"get_state", "follow", "stop", "go_to", "attack", "gather", "craft",
                            "place", "give", "say", "remember"}
    gather = schemas["gather"]["function"]["parameters"]
    assert gather["type"] == "object" and set(gather["required"]) == {"resource", "count"}


def test_gather_craft_give():
    g = MockGame.default_world()
    assert g.gather("log", 3)["ok"]
    assert g.inventory["log"] == 3
    assert g.craft("plank", 2)["ok"]  # one batch: 1 log -> 2 planks
    assert g.inventory["log"] == 2 and g.inventory["plank"] == 2
    assert g.give("Luis", "plank", 2)["reason"] == "too_far"
    assert g.go_to("Luis")["ok"]
    assert g.give("Luis", "plank", 2)["ok"]
    assert g.players["Luis"].inventory["plank"] == 2


def test_failure_reasons():
    g = MockGame.default_world()
    assert g.gather("gold", 1)["reason"] == "nothing_in_range"
    assert g.craft("stone_axe")["reason"] == "missing_materials"
    assert g.go_to("narnia")["reason"] == "unknown_target"
    assert g.call("gather", {"resource": "log"})["reason"] == "invalid_args"
    assert g.call("teleport", {})["reason"] == "unknown_tool"


def test_scripted_failures_and_events():
    g = MockGame.default_world()
    g.script_failure("go_to", "path_blocked", times=2)
    assert g.go_to("lake")["reason"] == "path_blocked"
    assert g.go_to("lake")["reason"] == "path_blocked"
    assert g.go_to("lake")["ok"]

    g.script_failure("gather", "interrupted", text="come here")
    assert g.gather("log", 1)["reason"] == "interrupted"
    assert g.poll_events() == [CommandReceived(player="Luis", text="come here")]

    g = MockGame.default_world()
    g.script_failure("gather", "attacked")
    res = g.gather("log", 4)
    assert res["reason"] == "attacked" and res["data"]["gathered"] == 2
    (ev,) = [e for e in g.poll_events() if e.type != "gather_progress"]
    assert isinstance(ev, Attacked)
    assert g.attack(ev.by)["ok"] and not g.entities[ev.by].alive


def test_follow_tracks_player_over_time():
    g = MockGame.default_world()
    g.follow("Luis", 3)
    g.move_player("Luis", [30, 0, 0])
    g.tick(1)
    assert abs(g.pos[0] - 27) < 0.01
