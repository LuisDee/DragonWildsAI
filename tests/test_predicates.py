"""brain/predicates.py: success predicates checked only against fresh state (docs/design/director.md 2.2).

Item ids and stats come from the real catalogs in data/ (build 26161880), so these tests also pin the
data the predicates rely on (pickaxe tool tiers, item names).
"""
import re
from pathlib import Path

import pytest

from brain import predicates as P

ROOT = Path(__file__).resolve().parents[1]
COPPER, TIN = "ITEM_Resources_CopperOre", "ITEM_Resources_TinOre"
STONE_PICK, BRONZE_PICK = "ITEM_Pickaxe_Stone", "ITEM_Pickaxe_Bronze"


def v(p):
    return P.validate(p)


def ev(p, state, **ctx):
    return P.evaluate(v(p), state, ctx)


# ------------------------------------------------------------------ validation


def test_names_resolve_to_catalog_ids_and_back():
    p = v({"have": {"item": "Copper Ore", "at_least": 9}})
    assert p == {"have": {"item": "Copper Ore", "ids": [COPPER], "at_least": 9}}
    assert v({"have": {"item": COPPER}})["have"]["at_least"] == 1  # default
    assert v({"equipped": {"item": "bronze pickaxe"}})["equipped"]["ids"] == [BRONZE_PICK]  # case-insensitive


def test_one_name_for_several_ids_counts_all_of_them():
    p = v({"have": {"item": "Grilled Trout", "at_least": 2}})
    assert len(p["have"]["ids"]) == 2
    a, b = p["have"]["ids"]
    assert P.evaluate(p, {"inventory": {a: 1, b: 1}}).passed is True


def test_unknown_item_gives_candidates():
    with pytest.raises(P.PredicateError) as e:
        v({"have": {"item": "Coper Ore"}})
    assert "Copper Ore" in e.value.candidates


@pytest.mark.parametrize("bad", [
    {}, {"have": {}, "gained": {}}, {"zz_not_a_leaf": {}}, {"all": []}, {"have": "Copper Ore"},
    {"skill": {"name": "Mining"}}, {"gear_better": {"stat": "tool_tier"}},
    {"gear_better": {"category": "pickaxe", "stat": "shininess"}},
    {"gear_better": {"category": "pickaxe", "stat": "tool_tier", "where": "chest"}},
    {"bag": {}}, {"bag": {"used_pct_at_least": 90, "free_at_least": 2}},
    {"near": {"within_m": 3}}, {"near": {"position": [1, "x"]}}, {"have": {"item": "Copper Ore", "at_least": 0}},
    {"have": {"item": "Copper Ore", "at_least": True}},
])
def test_invalid_predicates_are_rejected_with_a_reason(bad):
    with pytest.raises(P.PredicateError):
        P.validate(bad)


def test_errors_lists_every_problem_with_its_path():
    errs = P.errors({"all": [{"have": {"item": "Coper Ore"}}, {"skill": {"name": "Mining"}}, {"zz_not_a_leaf": {}}]})
    assert [e["path"] for e in errs] == ["$.all[0].have", "$.all[1].skill", "$.all[2]"]
    assert "Copper Ore" in errs[0]["candidates"]
    assert P.errors({"have": {"item": "Copper Ore"}}) == []


# ------------------------------------------------------------------ leaves


def test_have_gained_tally():
    state = {"inventory": {COPPER: 4, TIN: 9}}
    r = ev({"all": [{"have": {"item": COPPER, "at_least": 9}}, {"have": {"item": TIN, "at_least": 9}}]}, state)
    assert (r.passed, r.detail) == (False, "Copper Ore 4/9; Tin Ore 9/9")
    assert r.progress == pytest.approx((4 / 9 + 1) / 2)
    g = {"gained": {"item": COPPER, "at_least": 3}}
    assert ev(g, state, baseline={"inventory": {COPPER: 1}}).passed is True
    assert ev(g, state, baseline={"inventory": {COPPER: 2}}).passed is False
    assert ev(g, state).passed is None  # no baseline: can't be checked, never done
    t = {"tally": {"item": COPPER, "at_least": 20}}
    assert ev(t, state, tallies={COPPER: 21}).passed is True
    r = ev(t, state)
    assert (r.passed, r.missing) == (None, ["tallies"])
    assert ev({"have": {"item": COPPER}}, {}).missing == ["inventory"]


def test_skill_levels_from_state_rows():
    state = {"skills": [{"skill": "Mining", "level": 5, "xp": 400}, {"skill": "Artisan", "level": 3}]}
    assert ev({"skill": {"name": "mining", "at_least": 5}}, state).passed is True
    assert ev({"skill": {"name": "SKILL_Mining", "at_least": 6}}, state).passed is False
    r = ev({"skill": {"name": "Cooking", "at_least": 2}}, state)
    assert r.passed is None and "Cooking" in r.detail
    gain = {"skill_gain": {"name": "Artisan", "levels": 2}}
    assert ev(gain, state, baseline={"skills": [{"skill": "Artisan", "level": 1}]}).passed is True
    assert ev(gain, state, baseline={"skills": [{"skill": "Artisan", "level": 2}]}).passed is False
    assert ev(gain, state).passed is None
    assert ev({"skill": {"name": "Mining", "at_least": 1}}, {}).missing == ["skills"]


def test_equipped():
    assert ev({"equipped": {"item": "Bronze Pickaxe"}}, {"gear": {"held_right": BRONZE_PICK}}).passed is True
    assert ev({"equipped": {"item": "Bronze Pickaxe"}}, {"gear": {"held_right": STONE_PICK}}).passed is False
    assert ev({"equipped": {"item": "Bronze Pickaxe"}}, {}).passed is None


def test_gear_better_uses_catalog_stats_and_the_baseline():
    p = {"gear_better": {"category": "pickaxe", "stat": "tool_tier", "where": "equipped", "than": "start"}}
    start = {"gear": {"held_right": STONE_PICK}, "inventory": {}}
    r = ev(p, {"gear": {"held_right": BRONZE_PICK}}, baseline=start)
    assert r.passed is True and "Bronze Pickaxe 3" in r.detail and "Stone Pickaxe 1" in r.detail
    assert ev(p, start, baseline=start).passed is False
    # carried but not equipped: only counts with where=carried
    carrying = {"gear": {"held_right": STONE_PICK}, "inventory": {BRONZE_PICK: 1}}
    assert ev(p, carrying, baseline=start).passed is False
    assert ev({"gear_better": {**p["gear_better"], "where": "carried"}}, carrying, baseline=start).passed is True
    # a fixed number, and the reverse direction (lighter)
    assert ev({"gear_better": {"category": "pickaxe", "stat": "tool_tier", "than": 2}},
              {"gear": {"held_right": BRONZE_PICK}}).passed is True
    assert ev({"gear_better": {"category": "pickaxe", "stat": "tool_tier", "than": 3, "op": ">="}},
              {"gear": {"held_right": BRONZE_PICK}}).passed is True
    # no baseline: can't say; nothing at the start: any pickaxe is better
    assert ev(p, {"gear": {"held_right": BRONZE_PICK}}).passed is None
    assert ev(p, {"gear": {"held_right": BRONZE_PICK}}, baseline={"gear": {}, "inventory": {}}).passed is True
    assert ev(p, {"gear": {}}, baseline={"gear": {}, "inventory": {}}).passed is False


def test_gear_better_by_slot():
    p = {"gear_better": {"slot": "two_handed", "stat": "power_level", "than": "start"}}
    assert ev(p, {"gear": {"held_right": BRONZE_PICK}}, baseline={"gear": {"held_right": STONE_PICK}, "inventory": {}}).passed is True


def test_bag():
    state = {"bag": {"used": 19, "capacity": 20}}
    assert ev({"bag": {"used_pct_at_least": 95}}, state).passed is True
    assert ev({"bag": {"free_at_least": 2}}, state).passed is False
    assert ev({"bag": {"free_at_least": 2}}, {}).missing == ["bag"]


def test_vital():
    state = {"health": 30, "max_health": 120, "hydration": 80, "hydration_max": 100}
    assert ev({"vital": {"stat": "health", "below_pct": 30}}, state).passed is True
    assert ev({"vital": {"stat": "hydration", "below_pct": 30}}, state).passed is False
    assert ev({"vital": {"stat": "hydration", "at_least_pct": 75}}, state).passed is True
    assert ev({"vital": {"stat": "stamina", "below_pct": 30}}, state).missing == ["stamina"]
    for bad in ({"stat": "health"}, {"stat": "Health!", "below_pct": 3}, {"stat": "health", "below_pct": 3, "at_least_pct": 4}):
        with pytest.raises(P.PredicateError):
            P.validate({"vital": bad})


def test_near_place_player_thing_position():
    state = {"position": [0, 0, 0], "players": [{"name": "Zezima", "position": [3, 4, 0], "distance": 5.0}],
             "nearby_resources": [{"id": "rock_1", "position": [0, 2, 0]}]}
    places = {"base": {"position": [1, 1, 0]}, "far": [100, 0, 0]}
    assert ev({"near": {"place": "base", "within_m": 3}}, state, places=places).passed is True
    assert ev({"near": {"place": "far", "within_m": 3}}, state, places=places).passed is False
    assert ev({"near": {"place": "nowhere"}}, state, places=places).passed is None
    assert ev({"near": {"player": "zezima", "within_m": 6}}, state).passed is True
    assert ev({"near": {"player": "Someone", "within_m": 6}}, state).passed is False
    assert ev({"near": {"thing": "rock_1", "within_m": 3}}, state).passed is True
    assert ev({"near": {"position": [0, 9, 0], "within_m": 3}}, state).passed is False
    assert ev({"near": {"position": [0, 9, 0]}}, {}).missing == ["position"]


def test_moved():
    assert ev({"moved": {"min_m": 10}}, {"position": [0, 12, 0]}, baseline={"position": [0, 0, 0]}).passed is True
    assert ev({"moved": {"min_m": 10}}, {"position": [0, 2, 0]}, baseline={"position": [0, 0, 0]}).passed is False
    assert ev({"moved": {"min_m": 10}}, {"position": [0, 2, 0]}).passed is None


def test_killed_counts_body_verified_kills_only():
    eps = [{"kind": "combat_end", "target": "Giant Rat", "outcome": "killed"},
           {"kind": "combat_end", "target": "Giant Rat", "outcome": "fled"},
           {"kind": "combat_end", "target": "Goblin Runt", "outcome": "killed"},
           {"kind": "picked_up", "target": "Giant Rat"}]
    assert ev({"killed": {"kind": "rat", "at_least": 1}}, {}, episodes=eps).passed is True
    assert ev({"killed": {"kind": "rat", "at_least": 2}}, {}, episodes=eps).passed is False
    assert ev({"killed": {"kind": "rat"}}, {}, events=eps).passed is True  # alias
    assert ev({"killed": {"kind": "rat"}}, {}).missing == ["episodes"]


def test_quest_is_uncheckable_until_the_body_reports_quests():
    r = ev({"quest": {"name": "Some Quest"}}, {"inventory": {}})
    assert (r.passed, r.missing) == (None, ["quests"])
    q = {"quests": [{"name": "Some Quest", "stage": 2, "completed": False}]}
    assert ev({"quest": {"name": "some quest"}}, q).passed is False
    assert ev({"quest": {"name": "Some Quest", "stage": 2}}, q).passed is True
    assert ev({"quest": {"name": "Other"}}, q).passed is False


# ------------------------------------------------------------------ combinators (Kleene)


@pytest.mark.parametrize("vals,all_,any_", [
    ((True, True), True, True), ((True, False), False, True), ((True, None), None, True),
    ((False, None), False, None), ((None, None), None, None), ((False, False), False, False),
])
def test_three_valued_combinators(vals, all_, any_):
    def leaf(x):  # have 1 when True, 0 when False, unknown inventory when None (a separate state key is not used)
        return {"have": {"item": [f"id_{x}"], "at_least": 1}}
    state = {"inventory": {"id_True": 1}}
    preds = []
    for x in vals:
        preds.append({"tally": {"item": ["id_x"], "at_least": 1}} if x is None else leaf(x))
    ctx = {}  # no tallies: the tally leaves are None
    assert P.evaluate(v({"all": preds}), state, ctx).passed is all_
    assert P.evaluate(v({"any": preds}), state, ctx).passed is any_


def test_not():
    assert ev({"not": {"have": {"item": COPPER}}}, {"inventory": {}}).passed is True
    assert ev({"not": {"have": {"item": COPPER}}}, {}).passed is None


# ------------------------------------------------------------------ registry, helpers


def test_register_leaf_without_editing_the_module():
    def evaluate(a, state, ctx, cat):
        n = sum(1 for r in ctx.get("results") or [] if r.get("tool") == a["tool"] and r.get("ok"))
        return P.Result(n >= 1, f"{a['tool']} ok x{n}", min(1.0, n))
    def validate(a, items):
        if not a.get("tool"):
            raise P.PredicateError("used_tool needs tool")
        return a
    P.register_leaf("used_tool_test", evaluate, validate)
    try:
        with pytest.raises(ValueError):
            P.register_leaf("used_tool_test", evaluate)
        with pytest.raises(P.PredicateError):
            P.validate({"used_tool_test": {}})
        p = P.validate({"all": [{"used_tool_test": {"tool": "craft"}}, {"have": {"item": COPPER}}]})
        r = P.evaluate(p, {"inventory": {COPPER: 1}}, {"results": [{"tool": "craft", "ok": True}]})
        assert r.passed is True
        assert "used_tool_test" in P.describe(p)
    finally:
        P.LEAVES.pop("used_tool_test", None)
    with pytest.raises(ValueError):
        P.register_leaf("all", evaluate)


def test_snapshot_keeps_what_baselines_need():
    state = {"inventory": {COPPER: 2}, "gear": {"held_right": STONE_PICK}, "skills": [], "position": [1, 2, 3],
             "inventory_items": [{"item": COPPER, "name": "Copper Ore", "count": 2, "slot": 3}],
             "nearby_resources": [{"id": "x"}], "players": []}
    snap = P.snapshot(state)
    assert set(snap) == {"inventory", "gear", "skills", "position", "inventory_items"}
    assert snap["inventory_items"] == [{"item": COPPER}]


def test_describe_and_result_dict():
    p = v({"all": [{"have": {"item": "Copper Ore", "at_least": 9}},
                   {"gear_better": {"category": "pickaxe", "stat": "tool_tier"}}]})
    assert P.describe(p) == ("carry 9 Copper Ore and a pickaxe with tool_tier > what you had at the start "
                             "(equipped)")
    d = P.evaluate(p, {"inventory": {}}, {}).to_dict()
    assert set(d) == {"passed", "detail", "progress", "missing", "measures"}
    assert "inventory" not in d["missing"] and "gear" in d["missing"]


def test_schema_doc_names_every_builtin_leaf():
    for name in P.BUILTIN_LEAVES:
        assert f'"{name}"' in P.SCHEMA_DOC


def test_no_game_names_in_the_module():
    import ast
    tree = ast.parse((ROOT / "brain" / "predicates.py").read_text(encoding="utf-8"))
    docs = {id(n.body[0].value) for n in ast.walk(tree)
            if isinstance(n, (ast.Module, ast.FunctionDef, ast.ClassDef)) and n.body
            and isinstance(n.body[0], ast.Expr) and isinstance(n.body[0].value, ast.Constant)}
    code = [n.value for n in ast.walk(tree) if isinstance(n, ast.Constant) and isinstance(n.value, str)
            and id(n) not in docs]  # docstrings may give examples; code and prompts may not
    names = [n.id for n in ast.walk(tree) if isinstance(n, ast.Name)]
    assert not [s for s in code + names if re.search(r"ITEM_|Pickaxe|Copper|Mining|Brynmoor|Goblin", s)]


# ------------------------------------------------------------------ review 2026-10-25 (director-review.md)

SWORD = "ITEM_Sword_Mithril"


def test_h2_switching_to_a_pickaxe_he_already_carried_is_not_better():
    """Held sword at the start (Stone Pickaxe in the bag) -> now holding the Stone Pickaxe: must be False."""
    p = {"gear_better": {"category": "pickaxe", "stat": "tool_tier", "where": "equipped", "than": "start"}}
    start = {"gear": {"held_right": SWORD}, "inventory": {STONE_PICK: 1}}
    now = {"gear": {"held_right": STONE_PICK}, "inventory": {STONE_PICK: 1}}
    assert ev(p, now, baseline=start).passed is False
    # the same with the pickaxe only listed in inventory_items (no inventory count for it)
    start2 = {"gear": {"held_right": SWORD}, "inventory": {}, "inventory_items": [{"item": STONE_PICK}]}
    assert ev(p, now, baseline=start2).passed is False
    # a baseline without inventory can't tell what he carried: unverifiable, not a pass
    r = ev(p, now, baseline={"gear": {"held_right": SWORD}})
    assert (r.passed, r.missing) == (None, ["baseline"])
    # a really new, better pickaxe passes
    assert ev(p, {"gear": {"held_right": BRONZE_PICK}, "inventory": {STONE_PICK: 1}}, baseline=start).passed is True


def test_h2_nothing_at_the_start_and_the_same_item_now_is_not_new():
    p = {"gear_better": {"category": "pickaxe", "stat": "tool_tier", "where": "carried", "than": "start"}}
    # carried at the start but not in the catalog-visible pool would be odd; the guard: an id he had is never new
    start = {"gear": {}, "inventory": {}}
    assert ev(p, {"gear": {}, "inventory": {STONE_PICK: 1}}, baseline=start).passed is True  # got one
    assert ev(p, {"gear": {}, "inventory": {}}, baseline=start).passed is False


def test_l2_killed_matches_whole_words_not_substrings():
    eps = [{"kind": "combat_end", "target": "Hobgoblin", "outcome": "killed"}]
    assert ev({"killed": {"kind": "goblin"}}, {}, episodes=eps).passed is False
    eps.append({"kind": "combat_end", "target": "Goblin Runt", "outcome": "killed", "target_id": "c_7"})
    assert ev({"killed": {"kind": "goblin"}}, {}, episodes=eps).passed is True
    assert ev({"killed": {"kind": "goblins", "at_least": 1}}, {}, episodes=eps).passed is True  # plural folded
    assert ev({"killed": {"kind": "goblin", "target_id": "c_9"}}, {}, episodes=eps).passed is False
    assert ev({"killed": {"kind": "goblin", "target_id": "c_7"}}, {}, episodes=eps).passed is True


def test_h8_xp_is_a_measure_so_levelling_shows_progress_between_levels():
    p = v({"skill_gain": {"name": "Mining", "levels": 1}})
    base = {"skills": [{"skill": "Mining", "level": 5, "xp": 400}]}
    r1 = P.evaluate(p, {"skills": [{"skill": "Mining", "level": 5, "xp": 450}]}, {"baseline": base})
    r2 = P.evaluate(p, {"skills": [{"skill": "Mining", "level": 5, "xp": 520}]}, {"baseline": base})
    assert r1.passed is False and r1.progress == r2.progress == 0.0  # the level ratio alone can't see it
    assert P.grew(r1.measures, r2.measures) and not P.grew(r2.measures, r1.measures)
    assert "+120 xp" in r2.detail
    s = P.evaluate(v({"skill": {"name": "Mining", "at_least": 9}}), {"skills": [{"skill": "Mining", "level": 5}]})
    assert s.measures == {"level:mining": 5.0}  # no xp reported: the level is the measure


def test_measures_merge_and_never_include_distances():
    p = v({"all": [{"have": {"item": COPPER, "at_least": 9}}, {"near": {"position": [0, 0, 0], "within_m": 1}}]})
    r = P.evaluate(p, {"inventory": {COPPER: 4}, "position": [5, 0, 0]})
    assert r.measures == {f"have:{COPPER}": 4.0}
    assert P.grew({}, {"x": 1}) and not P.grew({"x": 1}, {"x": 1}) and not P.grew({"x": 1}, {})
    assert "measures" in r.to_dict()


def test_lost_and_on_ground_make_a_checkable_delivery():
    """The Phase 8 'bring them to me' case: left my inventory AND lying at the player's feet now."""
    p = {"all": [{"lost": {"item": COPPER, "at_least": 5}},
                 {"on_ground": {"item": COPPER, "at_least": 5, "player": "Zezima", "within_m": 3}}]}
    base = {"inventory": {COPPER: 8}}
    players = [{"name": "Zezima", "position": [10, 0, 0]}]
    dropped_at_him = {"inventory": {COPPER: 3}, "players": players,
                      "nearby_items": [{"id": "w1", "item": COPPER, "count": 5, "position": [11, 0, 0]}]}
    dropped_elsewhere = {**dropped_at_him, "nearby_items": [{"id": "w1", "item": COPPER, "count": 5, "position": [40, 0, 0]}]}
    assert ev(p, dropped_at_him, baseline=base).passed is True
    assert ev(p, dropped_elsewhere, baseline=base).passed is False  # a weak proxy (just "not have") would pass
    gone = {"inventory": {COPPER: 3}, "players": [], "nearby_items": []}
    assert ev(p, gone, baseline=base).passed is None  # he is out of sight: can't tell, never a pass
    assert ev({"on_ground": {"item": COPPER}}, {}).missing == ["nearby_items"]
    with pytest.raises(P.PredicateError):
        P.validate({"on_ground": {"item": COPPER, "player": "a", "place": "b"}})


def test_elapsed_and_station():
    assert ev({"elapsed": {"seconds": 60}}, {}, baseline=P.snapshot({}, t=100.0), now=170.0).passed is True
    assert ev({"elapsed": {"seconds": 60}}, {}, baseline=P.snapshot({}, t=100.0), now=130.0).passed is False
    assert ev({"elapsed": {"seconds": 60}}, {}, baseline={}).missing == ["clock"]
    st = {"stations_nearby": [{"id": "st_1", "name": "Furnace", "station": "Furnace", "running": True},
                              {"id": "st_2", "name": "Blacksmith's Bench", "station": "ToolsMeleeBench"}]}
    assert ev({"station": {"station": "furnace", "running": True}}, st).passed is True
    assert ev({"station": {"station": "st_1", "running": False}}, st).passed is False
    assert ev({"station": {"station": "ToolsMeleeBench"}}, st).passed is True
    assert ev({"station": {"station": "ToolsMeleeBench", "running": True}}, st).passed is None  # not reported
    assert ev({"station": {"station": "Kiln"}}, st).passed is False
    assert ev({"station": {"station": "Kiln"}}, {}).passed is None


def test_killed_by_exact_kind_id_or_target_id():
    eps = [{"kind": "combat_end", "target": "Goblin Runt", "outcome": "killed", "target_id": "c_7",
            "target_class": "BP_GoblinRunt_C"}]
    assert ev({"killed": {"kind_id": "BP_GoblinRunt_C"}}, {}, episodes=eps).passed is True
    assert ev({"killed": {"kind_id": "BP_Hobgoblin_C"}}, {}, episodes=eps).passed is False
    assert ev({"killed": {"target_id": "c_7"}}, {}, episodes=eps).passed is True
    no_class = [{"kind": "combat_end", "target": "Goblin Runt", "outcome": "killed"}]
    r = ev({"killed": {"kind_id": "BP_GoblinRunt_C"}}, {}, episodes=no_class)
    assert (r.passed, r.missing) == (None, ["episodes.target_class"])  # can't tell: never a pass
    assert ev({"killed": {"kind_id": "BP_GoblinRunt_C"}}, {}, episodes=[]).passed is False  # no kills at all
    with pytest.raises(P.PredicateError):
        P.validate({"killed": {"kind_id": "a", "target_id": "b"}})
    with pytest.raises(P.PredicateError):
        P.validate({"killed": {}})


def test_recheck8_a_drop_the_player_is_collecting_still_counts():
    p = {"on_ground": {"item": COPPER, "at_least": 5, "player": "Zezima", "within_m": 3}}
    flying = {"players": [{"name": "Zezima", "position": [10, 0, 0]}],
              "nearby_items": [{"id": "w1", "item": COPPER, "count": 5, "position": [30, 0, 0], "magnet_target": "Zezima"}]}
    assert ev(p, flying).passed is True
    to_me = {**flying, "nearby_items": [{**flying["nearby_items"][0], "magnet_target": "Claude"}]}
    assert ev(p, to_me).passed is False


# ------------------------------------------------------------------ structure / stored (GOAL long tasks, Director)


def test_structure_reads_the_bodys_pieces_and_new_means_placed_since_the_start():
    before = {"structures": [{"id": "p1", "name": "Wooden Chest", "piece": "DA_Chest", "distance": 3.0}]}
    now = {"structures": before["structures"] + [{"id": "p2", "name": "Wooden Chest", "distance": 4.0},
                                                 {"id": "p3", "name": "Wooden Chest", "distance": 2.0, "ghosted": True}]}
    ctx = {"baseline": P.snapshot(before)}
    assert P.evaluate(P.validate({"structure": {"name": "chest"}}), now, ctx).passed is True
    new2 = P.validate({"structure": {"name": "chest", "new": True, "at_least": 2}})
    r = P.evaluate(new2, now, ctx)
    assert r.passed is False and "1/2" in r.detail  # the ghost (a preview) is not built
    assert P.evaluate(P.validate({"structure": {"name": "chest"}}), {}, ctx).missing == ["structures"]
    assert P.evaluate(P.validate({"structure": {"name": "chest", "new": True}}), now, {}).passed is None


def test_stored_counts_his_verified_store_rows_and_trips():
    copper = "ITEM_Resources_CopperOre"
    rows = [{"item": copper, "count": 20, "container": "piece_1", "container_name": "Wooden Chest", "run": "s:1"},
            {"item": copper, "count": 20, "container": "piece_1", "container_name": "Wooden Chest", "run": "s:1"}]
    p = P.validate({"stored": {"item": copper, "at_least": 40, "trips_at_least": 2, "container": "chest"}})
    r = P.evaluate(p, {}, {"stored": rows})
    assert r.passed is False and "1/2 trips" in r.detail
    rows[1]["run"] = "s:2"
    assert P.evaluate(p, {}, {"stored": rows}).passed is True
    assert P.evaluate(p, {}, {}).missing == ["stored"] and "stored" in P.BOOKKEEPING_FIELDS


def test_a_store_result_is_a_stored_effect_and_take_brings_items_in():
    from brain.director import effects_of
    data = {"item": "ITEM_Resources_CopperOre", "count": 5, "container": "piece_1", "container_name": "Wooden Chest"}
    st = effects_of({"tool": "store", "ok": True, "data": data})
    assert st["stored"] == [{**{k: data[k] for k in ("item", "count", "container", "container_name")}}]
    assert st["items_out"][0]["count"] == 5 and not st["items_in"]
    tk = effects_of({"tool": "take", "ok": True, "data": data})
    assert tk["items_in"] == [{"item": data["item"], "count": 5}] and not tk["stored"]
