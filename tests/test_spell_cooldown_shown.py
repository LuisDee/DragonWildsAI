"""A spell's recharge is shown truthfully to both models (L2-V1, 2026-11-19).

Live: plans queued several Bark to Bones casts; each after the first failed on_cooldown (the game's 300 s
recharge, CooldownDuration) and forced a replan (57 s of stands over 13 trials, 2 misses per done run). The job
tree's spell node said "yours, castable now" with no recharge time, a recharging spell read "yours, on_cooldown"
with no seconds, the Planner's state had no spell rows, and the Controller's list came from a 60 s cache.
Live shape of the state row (brain-live-20261119-030251-32216.jsonl line 202):
{"castable": false, "reason": "on_cooldown", "name": "Bark to Bones", "remaining_s": 234.1, ...}; the client now
adds the game's recharge time as cooldown_s.
"""
from brain import job_tree as jt
from brain import plan_sources as ps
from brain import spells as sp
from brain.planner import _trim_state

BARK_ID = "USD_Treequipment"
SPELLS = {BARK_ID: {"name": "Bark to Bones", "cost": {"Earth": 10, "Nature": 10}, "cooldown_s": 300.0,
                    "requirement": {"text": "Cast on a Tree"}, "unlock": {"skill": "Artisan", "level": 11}}}
RECHARGING = {"id": BARK_ID, "name": "Bark to Bones", "castable": False, "reason": "on_cooldown",
              "remaining_s": 82.4, "cooldown_s": 300.0, "cast_type": "placed"}
READY = {"id": BARK_ID, "name": "Bark to Bones", "castable": True, "cooldown_s": 300.0, "cast_type": "placed"}


def _spell_node(state, spells=None):
    d = jt.GameData(recipes={}, stations={}, items={}, spell_makes={"animal bone": [BARK_ID]}, spells=SPELLS)
    b = jt._Builder(d, state, spells, None)
    return b.casts("Animal Bone")[0]


def test_job_tree_spell_recharging_shows_seconds_left_and_is_blocked():
    node = _spell_node({"spells": [RECHARGING]})
    assert node["status"] == "blocked"
    assert node["his"] == "yours, recharging, 83 s left (300 s after each cast)"


def test_job_tree_spell_castable_says_how_long_it_recharges_after_a_cast():
    node = _spell_node({"spells": [READY]})
    assert node["status"] == "ready"
    assert node["his"] == "yours, castable now; recharges 300 s after each cast"
    # the row without the client's cooldown_s: the game data's recharge (data/spell_effects.json) stands in
    node = _spell_node({"spells": [{"name": "Bark to Bones", "castable": True}]})
    assert node["his"] == "yours, castable now; recharges 300 s after each cast"


def test_plan_sources_spell_line_carries_the_recharge():
    line = ps._spells("Animal Bone", [RECHARGING])[0][2]
    assert "yours, recharging, 83 s left (300 s after each cast)" in line, line
    line = ps._spells("Animal Bone", [READY])[0][2]
    assert "yours, castable now; recharges 300 s after each cast" in line, line


def test_compact_row_keeps_the_numbers_and_words_them():
    row = sp.compact_row({**RECHARGING, "role": "placed"})
    assert row["castable"] is False and row["note"] == "recharging, 83 s left (300 s after each cast)"
    assert row["remaining_s"] == 82.4 and row["recharge_s"] == 300.0
    row = sp.compact_row({**READY, "role": "placed"})
    assert "note" not in row and row["recharge_s"] == 300.0


def test_a_stale_spellbook_row_takes_the_fresh_state_cooldown():
    stale = sp.compact_row({**READY, "role": "placed"})  # the 60 s SpellBook cache, read before the cast
    fresh = sp.with_state([stale], {"spells": [RECHARGING]})
    assert fresh[0]["castable"] is False and fresh[0]["note"].startswith("recharging, 83 s left")
    # and back: recharged in the state, the cached cooldown note goes
    cached = sp.compact_row({**RECHARGING, "role": "placed"})
    again = sp.with_state([cached], {"spells": [READY]})
    assert "note" not in again[0] and again[0].get("castable", True) is not False
    assert sp.with_state([stale], {}) == [stale]


def test_controller_lines_show_seconds_left_and_the_recharge():
    from brain.controller import Controller
    rows = [sp.compact_row({**READY, "role": "placed"}),
            sp.compact_row({"id": "USD_Windstep", "name": "Windstep", "role": "instant", "castable": True, "cooldown_s": 3})]
    fake = type("C", (), {"castable_spells": lambda self: rows})()
    lines = Controller.spell_lines(fake, {"spells": [RECHARGING]})
    assert any(s.startswith("Bark to Bones (NOT castable now: recharging, 83 s left (300 s after each cast)") for s in lines), lines
    assert any(s.startswith("Windstep (") and "recharges 3 s after each cast" in s for s in lines), lines


def test_planner_state_has_his_spells_with_their_recharge():
    out = _trim_state({"position": [0, 0, 0], "spells": [RECHARGING, {"name": "Windstep", "castable": True, "cooldown_s": 3},
                                                         {"name": "Recall", "castable": False, "reason": "not_on_wheel"}]})
    assert out["spells"] == ["Bark to Bones: recharging, 83 s left (300 s after each cast)",
                             "Windstep: castable now; recharges 3 s after each cast",
                             "Recall: not castable now (not_on_wheel)"]
    assert "spells" not in _trim_state({"position": [0, 0, 0]})
