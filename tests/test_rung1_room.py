"""rung1_gate.make_room puts away only what harness fixtures added (main 2026-11-02: don't touch his own things)."""
import json

from tools import rung1_gate as g


def _log(path, rows):
    path.write_text("".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8")


def test_fixture_surplus_counts_only_rung1_grants_less_what_was_put_away_and_what_he_needs(tmp_path):
    setup, cleanup = tmp_path / "setup.jsonl", tmp_path / "cleanup.jsonl"
    _log(setup, [
        {"verb": "grant", "ok": True, "purpose": "rung1 gate fight: his kit", "args": {"item": "ITEM_Sword_Bronze", "count": 1}},
        {"verb": "grant", "ok": True, "purpose": "rung1 gate fight: his kit", "args": {"item": "ITEM_Sword_Bronze", "count": 1}},
        {"verb": "grant", "ok": False, "purpose": "rung1 gate fight: his kit", "args": {"item": "ITEM_Sword_Bronze", "count": 1}},
        {"verb": "grant", "ok": True, "purpose": "rung3 cook: stock", "args": {"item": "ITEM_Resources_Stone", "count": 50}},
        {"verb": "grant", "ok": True, "purpose": "rung1 gate split/drop stock", "args": {"item": "ITEM_Resources_Stone", "count": 30}},
        {"verb": "grant", "ok": True, "purpose": "rung1 gate rest: top up to 6", "args": {"item": "ITEM_Consumable_Meat_Fillet", "count": 20}},
        {"verb": "set_health", "ok": True, "purpose": "rung1 gate grave: die here", "args": {"value": 0}},
    ])
    _log(cleanup, [{"item": "ITEM_Resources_Stone", "count": 25, "ok": True}])
    carried = {"ITEM_Sword_Bronze": 3, "ITEM_Resources_Stone": 40, "ITEM_Consumable_Meat_Fillet": 8, "ITEM_Club_Stone": 1}
    s = g.fixture_surplus(carried, setup_log=setup, cleanup_log=cleanup)
    # 2 swords granted, he keeps one: 2 go, the one left is the one he keeps; stone 30 + rung3's 50 granted, 25 put
    # away, 40 carried: all 40; fillets: 8 carried - 6 kept = 2; his club was never granted (his own: stays)
    assert s == {"ITEM_Sword_Bronze": 2, "ITEM_Resources_Stone": 40, "ITEM_Consumable_Meat_Fillet": 2}


def test_a_read_only_lookup_that_finds_nothing_is_no_miss_but_world_actions_and_collisions_are():
    # main 2026-11-02: craft_plan / recipes / inventory / look / stations / buildables answering ambiguous_target or
    # not-found change nothing and their time is in the time bar; a still_running collision and a failed action count
    def res(tool, reason):
        return {"kind": "tool_result", "tool": tool, "result": {"ok": False, "reason": reason}}
    brain = [res("craft_plan", "ambiguous_target"), res("recipes", "unknown_recipe"), res("look", "not_perceived"),
             res("stations", "unknown_target"), res("buildables", "ambiguous_target"), res("inventory", "not_in_inventory"),
             res("go_to", "interrupted"),
             res("consume", "in_bag"), res("store", "still_running"), res("craft", "missing_materials"),
             {"kind": "tool_result", "tool": "consume", "result": {"ok": True}}]
    assert g.count_fumbles(brain) == 3
