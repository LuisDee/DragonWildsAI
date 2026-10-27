"""FX checks must consume wrapped probe data and reject process changes."""
import json
from pathlib import Path

import pytest

from tools import live_queue as lq

ROOT = Path(__file__).resolve().parents[1]
CHECKS = ROOT / "tools" / "live_checks"
NAMES = ("fx_damage_spell_fire_spirit", "fx_enchant_weapon_held_fx", "fx_status_effect_dirty_water")


def context(spec):
    ctx = {"cast_spirit": {"ok": True}, "equip": {"ok": True}, "cast1": {"ok": True},
           "drink": {"ok": True}, "before": {"inventory": {"ITEM_Consumable_Water_Dirty": 1}},
           "after": {"inventory": {"ITEM_Consumable_Water_Dirty": 0}, "input_mode": "DIM_Gameplay"}}
    for n, step in enumerate(s for s in spec["steps"] if s.get("client_cmd", "").endswith("fx_null_probe.lua")):
        ctx[step["save"]] = {"ok": True, "result": {"token": "process-a", "runs": 10 + n,
                             "fxguard": {"guarded": True}, "local_fx": [], "status": [],
                             "held": [], "tag_fx": [], "drain": []}}
    return ctx


@pytest.mark.parametrize("name", NAMES)
def test_fx_wrapped_results_and_restart(name):
    path = CHECKS / (name + ".json")
    spec = json.loads(path.read_text(encoding="utf-8"))
    assert not lq.validate(spec, path)
    ctx = context(spec)
    logs = lambda source, regex: []
    ok, rows = lq.evaluate(spec["pass"], ctx, logs)
    assert ok, rows
    for step in spec["steps"]:
        if not step.get("client_cmd", "").endswith("fx_null_probe.lua") or step["save"] == "fx_before":
            continue
        probe = ctx[step["save"]]["result"]
        probe["token"] = "process-b"
        probe["runs"] = 1000
        ok, rows = lq.evaluate(spec["pass"], ctx, logs)
        assert not ok, rows
        probe["token"] = "process-a"
    del ctx["fx_before"]["result"]["token"]
    assert not lq.evaluate(spec["pass"], ctx, logs)[0]


def test_expected_reference_and_literal_dicts():
    ctx = {"a": "token", "b": "token", "literal": {"$ref": "x", "extra": True}}
    logs = lambda source, regex: []
    criteria = [{"ref": "a", "eq": {"$ref": "b"}},
                {"ref": "literal", "eq": {"$ref": "x", "extra": True}}]
    assert lq.evaluate(criteria, ctx, logs)[0]
    ctx["b"] = "other"
    assert not lq.evaluate(criteria, ctx, logs)[0]
    del ctx["b"]
    ok, rows = lq.evaluate(criteria, ctx, logs)
    assert not ok and rows[0]["missing_expected"]
    json.dumps(rows)
