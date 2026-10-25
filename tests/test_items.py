"""Item skills on the brain side: the pickup / drop / give tool contract, the mock's ground items,
and the executor's verifiers (verified state only, CLAUDE.md principle 2)."""
from brain.executor import VERIFIERS
from brain.interface import TOOLS, Reason, tool_schemas, validate_args
from brain.mock import MockGame
from brain.state_store import MOCK_SKILLS


def test_item_tools_in_the_contract():
    schemas = {s["function"]["name"]: s["function"]["parameters"] for s in tool_schemas()}
    assert set(schemas["pickup"]["required"]) == {"target"}
    assert set(schemas["drop"]["required"]) == {"item", "count"}
    assert validate_args("drop", {"item": "oak", "count": 3}) == {"item": "oak", "count": 3, "at": "feet"}
    assert validate_args("pickup", {"target": "nearest"})["limit"] == 1
    for bad in ({"item": "oak", "count": 0}, {"item": "oak", "count": 1, "at": "moon"}):
        try:
            validate_args("drop", bad)
        except Exception:
            continue
        raise AssertionError(f"accepted {bad}")
    assert {"pickup", "drop", "give"} <= set(MOCK_SKILLS) and {"pickup", "drop"} <= set(TOOLS)
    assert Reason.NOT_IN_INVENTORY in Reason.DETERMINISTIC


def test_mock_pickup_and_drop_round_trip():
    g = MockGame.default_world()
    oak = g.add_ground_item("oak_log", 6, [3, 0, 0])
    g.add_ground_item("stone", 2, [4, 0, 0])
    assert {i["id"] for i in g.get_state()["data"]["nearby_items"]} >= {oak}
    res = g.call("pickup", {"target": "nearest", "item": "oak"})
    assert res["ok"] and res["data"]["item"] == "oak_log" and res["data"]["count"] == 6
    assert g.inventory["oak_log"] == 6 and oak not in g.ground
    assert g.call("pickup", {"target": oak})["reason"] == Reason.UNKNOWN_TARGET
    assert g.call("pickup", {"target": "nearest", "item": "gold"})["reason"] == Reason.NOTHING_IN_RANGE
    res = g.call("drop", {"item": "oak_log", "count": 4})
    assert res["ok"] and g.inventory["oak_log"] == 2 and res["data"]["world_items"][0] in g.ground
    assert g.call("drop", {"item": "oak_log", "count": 9})["reason"] == Reason.NOT_ENOUGH
    assert g.call("drop", {"item": "gold", "count": 1})["reason"] == Reason.NOT_IN_INVENTORY


def _state(inv, nearby=()):
    return {"inventory": dict(inv), "nearby_items": [{"id": i} for i in nearby]}


def test_verifiers_use_the_item_id_the_body_resolved():
    # The brain says "oak"; the real body resolves and reports ITEM_Resources_Wood_Oak.
    oak = "ITEM_Resources_Wood_Oak"
    give = VERIFIERS["give"]
    args = {"player": "Luis", "item": "oak", "count": 5}
    assert give(args, _state({oak: 10}), _state({oak: 5}), {"item": oak}) is None
    assert give(args, _state({oak: 10}), _state({oak: 10}), {"item": oak})  # body lied: nothing left

    drop = VERIFIERS["drop"]
    args = {"item": "oak", "count": 5, "at": "feet"}
    data = {"item": oak, "world_items": ["W1"]}
    assert drop(args, _state({oak: 5}), _state({}, ["W1"]), data) is None
    assert "not on the ground" in drop(args, _state({oak: 5}), _state({}, []), data)
    assert drop(args, _state({oak: 5}), _state({oak: 5}, ["W1"]), data)

    pickup = VERIFIERS["pickup"]
    args = {"target": "nearest", "item": "oak", "limit": 1}
    data = {"item": oak, "count": 6, "picked": [{"world_item": "W2", "item": oak, "count": 6}]}
    assert pickup(args, _state({}), _state({oak: 6}), data) is None
    assert "still on the ground" in pickup(args, _state({}), _state({oak: 6}, ["W2"]), data)
    assert pickup(args, _state({}), _state({oak: 2}), data)
    assert pickup(args, _state({}), _state({}), {"count": 0})
