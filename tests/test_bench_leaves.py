"""Benchmark leaves v2 (goal-cases review 2026-10-26: C1, C2, C3, T-2, L-7, B-2, B-4, L-2, L-4, C5)."""
from __future__ import annotations

import json

import pytest

from brain import predicates as P
from evals.bench import leaves, spec
from evals.bench.observer import Observation, Record, evidence_ctx

COAL = "ITEM_Resources_Coal"


def ctx_of(referee=(), observations=(), supports=("item_change", "damage", "death", "teleport", "defended", "telegraph"),
           probe0=None, probe1=None):
    rec = Record(observations=list(observations), referee=list(referee), probe0=probe0 or {}, probe1=probe1 or {})
    return evidence_ctx(rec, {}, leaves.default_spells(), 0.0, referee_supports=set(supports))


def ev(pred, ctx, state=None):
    return P.evaluate(P.validate(pred), state or {}, ctx)


def ic(t, who, item, delta):
    return {"kind": "item_change", "t": t, "who": who, "item": item, "delta": delta}


# ------------------------------------------------------------------ C1 delivery from outflow


def test_gather_then_give_passes_although_his_bag_is_empty_at_both_ends():
    ref = [ic(10, "self", COAL, 25), ic(20, "self", COAL, 25), ic(30, "self", COAL, -50), ic(31, "Tester", COAL, 50)]
    r = ev({"delivered": {"to": "Tester", "item": COAL, "at_least": 50}}, ctx_of(ref),
           {"inventory": {}})
    assert r.passed is True, r.detail


def test_dropping_without_the_receiver_getting_it_is_not_delivery():
    ref = [ic(10, "self", COAL, 50), ic(30, "self", COAL, -50)]  # dropped somewhere; Tester gains nothing
    ref.append(ic(200, "Tester", "ITEM_Torch", 1))  # the receiver IS observed
    assert ev({"delivered": {"to": "Tester", "item": COAL, "at_least": 1}}, ctx_of(ref)).passed is False


def test_receiver_not_observed_is_a_perception_gap():
    ref = [ic(10, "self", COAL, 50), ic(30, "self", COAL, -50)]
    r = ev({"delivered": {"to": "Tester", "item": COAL, "at_least": 1}}, ctx_of(ref))
    assert r.passed is None and r.missing == ["receiver"]


def test_delivery_pairing_from_probes_on_targets_without_an_item_stream():
    b = {"t": 0, "inventory": {COAL: 50}, "players": [{"name": "Tester", "position": [0, 0, 0], "inventory": {}}], "ground": []}
    a = {"t": 1, "inventory": {}, "players": [{"name": "Tester", "position": [0, 0, 0], "inventory": {COAL: 50}}], "ground": []}
    o = Observation(1, "give", {}, 0, 1, 0, 1, b, a, {"ok": True})
    r = ev({"delivered": {"to": "Tester", "item": COAL, "at_least": 50}}, ctx_of(observations=[o], supports=()))
    assert r.passed is True


def test_trips_count_batches_separated_by_more_gathering():
    one = [ic(10, "self", COAL, 50), ic(30, "self", COAL, -25), ic(31, "Tester", COAL, 25),
           ic(40, "self", COAL, -25), ic(41, "Tester", COAL, 25)]  # two hand-overs, no gathering between
    two = [ic(10, "self", COAL, 25), ic(30, "self", COAL, -25), ic(31, "Tester", COAL, 25),
           ic(50, "self", COAL, 25), ic(60, "self", COAL, -25), ic(61, "Tester", COAL, 25)]
    pred = {"trips": {"to": "Tester", "item": COAL, "at_least": 2}}
    assert ev(pred, ctx_of(one)).passed is False
    assert ev(pred, ctx_of(two)).passed is True


# ------------------------------------------------------------------ C2 missing evidence -> None


def test_damage_type_without_attribution_or_types_is_a_gap_not_a_failure():
    pred = {"damage_type_dealt": {"target_kind_id": "G", "types": ["DamageType.Magical.Fire"]}}
    assert ev(pred, ctx_of([{"kind": "damage", "t": 1, "kind_id": "G", "amount": 8}])).missing == ["referee:damage.by"]
    r = ev(pred, ctx_of([{"kind": "damage", "t": 1, "kind_id": "G", "amount": 8, "by": "self"}]))
    assert r.passed is None and r.missing == ["referee:damage.damage_type"]
    assert ev(pred, ctx_of(supports=())).passed is None


def test_disengaged_without_probed_creatures_is_a_gap():
    o = Observation(1, "go_to", {}, 0, 1, 0, 1, {"t": 0}, {"t": 1, "position": [0, 0, 0]}, {"ok": True})
    r = ev({"disengaged": {"target_kind_id": "G"}}, ctx_of(observations=[o]))
    assert r.passed is None and r.missing == ["probe:creatures"]


# ------------------------------------------------------------------ L-7 min_share


def test_one_fire_hit_in_a_farm_is_not_the_right_weapon():
    hits = [{"kind": "damage", "t": i, "kind_id": "G", "amount": 10, "by": "self",
             "damage_type": "DamageType.Magical.Fire" if i == 0 else "DamageType.Physical.Slash"} for i in range(20)]
    pred = {"damage_type_dealt": {"target_kind_id": "G", "types": ["DamageType.Magical.Fire"], "min_share": 0.6}}
    assert ev(pred, ctx_of(hits)).passed is False
    for h in hits[:15]:
        h["damage_type"] = "DamageType.Magical.Fire"
    assert ev(pred, ctx_of(hits)).passed is True


# ------------------------------------------------------------------ T-2 prepared anchored to the target, all / at_least


def _obs(t, snap):
    return Observation(t, "x", {}, t, t + 0.5, t, t + 0.5, {"t": t, **snap}, {"t": t + 0.5, **snap}, {"ok": True})


def test_prepared_snapshots_before_the_first_damage_with_the_target():
    ref = [{"kind": "damage", "t": 5, "kind_id": "RAT", "amount": 1},  # a rat on the way: not the anchor
           {"kind": "damage", "t": 50, "kind_id": "BOSS", "amount": 1}]
    obs = [_obs(1, {"inventory": {}, "tags": []}), _obs(20, {"inventory": {"ANTI": 1}, "tags": ["Shield"]})]
    pred = {"prepared": {"target_kind_id": "BOSS", "all": [{"item": "ANTI"}, {"tag": "Shield"}]}}
    assert ev(pred, ctx_of(ref, obs)).passed is True
    no_anchor = {"prepared": {"all": [{"item": "ANTI"}, {"tag": "Shield"}]}}  # the rat at t=5 comes first
    assert ev(no_anchor, ctx_of(ref, obs)).passed is False


def test_prepared_at_least_k_and_unobservable_options():
    ref = [{"kind": "damage", "t": 50, "kind_id": "BOSS", "amount": 1}]
    obs = [_obs(20, {"inventory": {"ANTI": 1}, "tags": [], "gaps": ["held_effects"]})]
    base = [{"item": "ANTI"}, {"tag": "Shield"}, {"enchant_type": "DamageType.Magical.Air"}]
    one = ev({"prepared": {"target_kind_id": "BOSS", "any": base, "at_least": 1}}, ctx_of(ref, obs))
    two = ev({"prepared": {"target_kind_id": "BOSS", "any": base, "at_least": 2}}, ctx_of(ref, obs))
    assert one.passed is True and two.passed is None and two.missing == ["probe:prep"]
    three = ev({"prepared": {"target_kind_id": "BOSS", "any": base[:2], "at_least": 2}}, ctx_of(ref, obs))
    assert three.passed is False


# ------------------------------------------------------------------ B-2 dodges, L-4 teleports


def test_dodges_need_outcome_dodged_direction_and_rate():
    d = lambda t, **k: {"kind": "defended", "t": t, "how": "dodge", "outcome": "dodged", "telegraphed": True,  # noqa: E731
                        "direction_ok": True, **k}
    tele = [{"kind": "telegraph", "t": t, "target": "self"} for t in range(10)]
    good = [d(1), d(2), d(3)]
    missed = [d(1, outcome="missed"), d(2), d(3)]
    wrong_dir = [d(1, direction_ok=False), d(2), d(3)]
    pred = {"defended": {"kind": "dodge", "against": "telegraph", "at_least": 3}}
    assert ev(pred, ctx_of(good)).passed is True
    assert ev(pred, ctx_of(missed)).passed is False and ev(pred, ctx_of(wrong_dir)).passed is False
    rated = {"defended": {"kind": "dodge", "against": "telegraph", "at_least": 3, "min_rate": 0.5}}
    assert ev(rated, ctx_of(good + tele)).passed is False  # 3 of 10 telegraphs
    assert ev(rated, ctx_of(good + [d(4), d(5)] + tele[:6])).passed is True


def test_a_respawn_jump_is_not_a_teleport_and_via_needs_the_referee():
    ref = [{"kind": "death", "t": 100, "who": "self"}, {"kind": "teleport", "t": 105, "who": "self", "via": "respawn"},
           {"kind": "teleport", "t": 300, "who": "self", "via": "lodestone"}]
    assert ev({"teleports": {"via": "lodestone", "at_least": 1}}, ctx_of(ref)).passed is True
    assert ev({"teleports": {"at_least": 2}}, ctx_of(ref)).passed is False
    nov = [{"kind": "teleport", "t": 300, "who": "self"}]
    assert ev({"teleports": {"via": "lodestone", "at_least": 1}}, ctx_of(nov)).missing == ["referee:teleport.via"]


# ------------------------------------------------------------------ C5 snapshot content hashing, required evidence


def test_editing_a_snapshot_changes_the_case_hash(tmp_path, monkeypatch):
    monkeypatch.setattr(spec, "SNAPSHOTS", tmp_path)
    (tmp_path / "s1").mkdir()
    (tmp_path / "s1" / "manifest.json").write_text(json.dumps({"bag": []}), encoding="utf-8")
    c = spec.Case.model_validate({"id": "x", "tier": "T1", "family": "misc", "chat": [{"text": "hi there"}],
                                  "success": {"have": {"item": "ITEM_Torch", "at_least": 1}},
                                  "fixtures": {"state_snapshot": "s1"}})
    h1 = spec.case_hash(c)
    (tmp_path / "s1" / "manifest.json").write_text(json.dumps({"bag": ["antipoison"]}), encoding="utf-8")
    assert spec.case_hash(c) != h1
    missing = c.model_copy(update={"fixtures": c.fixtures.model_copy(update={"state_snapshot": "nope"}), "status": "suite"})
    assert any("no manifest" in p for p in spec.lint(missing))


def test_required_evidence_is_derived_from_the_predicates():
    p = P.validate({"all": [{"delivered": {"to": "Tester", "item": COAL, "at_least": 1}},
                            {"no_event": {"kind": "death", "who": "self"}}]})
    assert leaves.required_evidence(p) == ["referee:item_change(receiver)", "referee:death"]


def test_gained_at_counts_only_gains_at_the_place():
    o_far = Observation(1, "interact", {}, 0, 1, 0, 1, {"t": 0, "inventory": {}}, {"t": 1, "inventory": {"W": 5}, "position": [500, 0, 0]}, {"ok": True})
    o_at = Observation(2, "interact", {}, 1, 2, 1, 2, {"t": 1, "inventory": {"ITEM_Resources_Weed_Desert": 5}}, {"t": 2, "inventory": {"ITEM_Resources_Weed_Desert": 10}, "position": [2, 2, 0]}, {"ok": True})
    ctx = ctx_of(observations=[o_far, o_at])
    ctx["places"] = {"our farm": [0, 0, 0]}
    r = ev({"gained_at": {"item": "ITEM_Resources_Weed_Desert", "at_least": 6, "place": "our farm", "within_m": 15}}, ctx)
    assert r.passed is False and r.detail.startswith("5/6")


def test_xp_top_needs_the_target_skill_to_lead():
    p0 = {"skills": {"Mining": {"level": 1, "xp": 0}, "Agility": {"level": 1, "xp": 0}}}
    walk = {"skills": {"Mining": {"level": 1, "xp": 5}, "Agility": {"level": 1, "xp": 40}}}
    mine = {"skills": {"Mining": {"level": 1, "xp": 90}, "Agility": {"level": 1, "xp": 40}}}
    assert ev({"xp_top": {"skill": "Mining"}}, ctx_of(probe0=p0, probe1=walk)).passed is False
    assert ev({"xp_top": {"skill": "Mining"}}, ctx_of(probe0=p0, probe1=mine)).passed is True


def test_solo_fails_when_anyone_else_hit_the_target():
    hits = [{"kind": "damage", "t": 1, "kind_id": "V", "by": "self", "amount": 50},
            {"kind": "damage", "t": 2, "kind_id": "V", "by": "BP_PlayerCharacter_C_9", "amount": 50}]
    assert ev({"solo": {"target_kind_id": "V"}}, ctx_of(hits)).passed is False
    assert ev({"solo": {"target_kind_id": "V"}}, ctx_of(hits[:1])).passed is True


def test_avoided_attacks_without_how_are_a_gap():
    r = ev({"defended": {"kind": "dodge", "against": "telegraph", "at_least": 1}},
           ctx_of([{"kind": "defended", "t": 1, "outcome": "avoided", "telegraphed": True}]))
    assert r.passed is None and r.missing == ["referee:defended.how"]


ORE = "ITEM_Resources_CopperOre"


def cc(t, item, n, new=True, by="self"):
    return {"kind": "container_change", "t": t, "by": by, "item": item, "count": n, "from_player": True, "new_since_start": new}


def test_deposits_into_his_own_chest_over_trips():
    ref = [ic(10, "self", ORE, 20), cc(20, ORE, 20), ic(40, "self", ORE, 20), cc(50, ORE, 20)]
    pred = {"deposited": {"items": [ORE], "into": "own", "at_least": 40, "trips_at_least": 2}}
    assert ev(pred, ctx_of(ref, supports=("item_change", "container_change"))).passed is True
    one_trip = [ic(10, "self", ORE, 40), cc(20, ORE, 20), cc(25, ORE, 20)]
    assert ev(pred, ctx_of(one_trip, supports=("item_change", "container_change"))).passed is False
    shared = [ic(10, "self", ORE, 20), cc(20, ORE, 20, new=False), ic(40, "self", ORE, 20), cc(50, ORE, 20, new=False)]
    assert ev(pred, ctx_of(shared, supports=("item_change", "container_change"))).passed is False  # not HIS chest
    assert ev(pred, ctx_of(ref, supports=("item_change",))).missing == ["referee:container_change"]


def test_crafted_needs_his_own_craft():
    craft = [{"kind": "craft", "t": 5, "by": "self", "recipe": "RECIPE_Process_Ground_Wheat", "count": 2}]
    pred = {"crafted": {"item": "ITEM_Resources_Ground_Wheat", "at_least": 2}}
    assert ev(pred, ctx_of(craft, supports=("craft",))).passed is True
    other = [dict(craft[0], by="Luis")]
    assert ev(pred, ctx_of(other, supports=("craft",))).passed is False
    b = {"t": 0, "inventory": {}}
    a = {"t": 1, "inventory": {"ITEM_Resources_Ground_Wheat": 2}}
    o = Observation(1, "craft", {}, 0, 1, 0, 1, b, a, {"ok": True})
    assert ev(pred, ctx_of(observations=[o], supports=())).passed is True  # probe fallback: gained during HIS craft
    picked = Observation(1, "interact", {}, 0, 1, 0, 1, b, a, {"ok": True})
    assert ev(pred, ctx_of(observations=[picked], supports=())).passed is False


def test_building_and_planting_need_their_referee_kinds():
    assert ev({"built": {"at_least": 1}}, ctx_of(supports=())).missing == ["referee:built"]
    ref = [{"kind": "built", "t": 1, "by": "self", "piece_index": 3, "ghost": True},
           {"kind": "built", "t": 2, "by": "self", "piece_index": 3, "ghost": False}]
    assert ev({"built": {"at_least": 2}}, ctx_of(ref, supports=("built",))).passed is False  # a ghost isn't a building


def test_air_dash_needs_the_harness_effect_probe_not_the_cast_displacement():
    sp = leaves.default_spells()["USD_PhaseDash"]
    cost = {f"ITEM_Rune_{r}": n for r, n in sp["cost"].items()}
    b = {"t": 0, "inventory": {k: 2 * v for k, v in cost.items()}, "cooldowns": {}, "position": [0, 0, 0], "tags": [], "ge": []}
    a = {"t": 1, "inventory": {k: v for k, v in cost.items()}, "cooldowns": {"USD_PhaseDash": 5.0}, "position": [20, 0, 0],
         "tags": [], "ge": []}
    reply = {"ok": True, "data": {"id": "USD_PhaseDash", "runes_spent": cost, "cooldown_started": True, "effects": {"tags": []}}}
    o = Observation(1, "cast", {"spell": "Phase Dash"}, 0, 1, 0, 1, b, a, reply)
    r = ev({"spell_effect": {"spell": "USD_PhaseDash"}}, ctx_of(observations=[o], supports=()))
    assert r.passed is None  # moved 20 m during the cast proves nothing about the dash window
    a2 = dict(a, air_dash_m=8.4)
    o2 = Observation(1, "cast", {"spell": "Phase Dash"}, 0, 1, 0, 1, b, a2, reply)
    assert ev({"spell_effect": {"spell": "USD_PhaseDash"}}, ctx_of(observations=[o2], supports=())).passed is True


def test_view_target_proves_oculus_and_shared_input_mode_is_generic():
    """Spells agent 2026-10-26: Eye of Oculus switches the camera to BP_OculusCamera_C (specific); entering
    DIM_SpellcastingMode is shared by several spells, so it can never prove which one went off."""
    from evals.bench.leaves import _effect, specific_effects
    spells = {"A": {"proof": {"effect": [{"kind": "view_target", "class": "BP_OculusCamera_C"},
                                         {"kind": "input_mode", "contains": "SpellcastingMode"}]}},
              "B": {"proof": {"effect": [{"kind": "input_mode", "contains": "SpellcastingMode"}]}}}
    good, bad = specific_effects("A", spells)
    assert [e["kind"] for e in good] == ["view_target"] and [e["kind"] for e in bad] == ["input_mode"]
    assert specific_effects("B", spells)[0] == []

    class O:
        def __init__(self, b, a):
            self.before, self.after, self.wall0, self.wall1 = b, a, 0.0, 1.0
    vt = good[0]
    assert _effect(vt, O({"view_target": "BP_PlayerCharacter_C"}, {"view_target": "BP_OculusCamera_C"}), None) is True
    # transient: the view is back before the after-probe, so absence is "can't tell", never a pass and never a fail
    assert _effect(vt, O({"view_target": "BP_PlayerCharacter_C"}, {"view_target": "BP_PlayerCharacter_C"}), None) is None
    polled = {"referee": [{"kind": "spell_actor", "class": "BP_OculusCamera_C", "t": 0.5}]}
    assert _effect(vt, O({"view_target": "BP_PlayerCharacter_C"}, {"view_target": "BP_PlayerCharacter_C"}), None, polled) is True


def test_held_item_effect_reads_the_probe_held_effects():
    from evals.bench.leaves import _effect
    e = {"kind": "held_item_effect", "effect": "HEED_EnchantWeaponFire"}

    class O:
        def __init__(self, b, a):
            self.before, self.after, self.wall0, self.wall1 = b, a, 0.0, 1.0
    assert _effect(e, O({"held": {"effects": []}}, {"held": {"effects": ["HEED_EnchantWeaponFire"]}}), None) is True
    assert _effect(e, O({"held": {"effects": []}}, {"held": {"effects": []}}), None) is False
    assert _effect(e, O({}, {"gaps": ["held_effects"]}), None) is None


def test_dump_hypotheses_count_when_they_fire_and_read_null_when_they_do_not():
    """evals/bench/spell_observables.json (2026-10-26): spells whose proof was only needs_live_observation get
    dump-derived hypotheses; a firing hypothesis is evidence, a silent one is 'can't tell' (never a fail)."""
    from evals.bench.leaves import _effect, default_spells, specific_effects
    spells = default_spells()
    good, _ = specific_effects("USD_Confuse", spells)
    kinds = {e["kind"] for e in good}
    assert {"spell_actor", "target_effect"} <= kinds and all(e.get("confidence") == "hypothesis" for e in good)

    class O:
        def __init__(self):
            self.before, self.after, self.wall0, self.wall1, self.t0, self.t1 = {}, {}, 100.0, 102.0, 100.0, 102.0
    te = next(e for e in good if e["kind"] == "target_effect")
    fired = {"referee": [{"kind": "target_effect", "effect": "GE_Confuse_C", "t": 103.0, "by": "self"}]}
    assert _effect(te, O(), None, fired) is True and _effect(te, O(), None, {"referee": []}) is None
    rock = next(e for e in specific_effects("USD_DivineRock", spells)[0] if e["kind"] == "spell_actor")
    seen = {"referee": [{"kind": "spell_actor", "class": "BP_DivineRock_Clay_C", "t": 101.0}]}
    preview = {"referee": [{"kind": "spell_actor", "class": "BP_DivineRockPreview_C", "t": 101.0}]}
    assert _effect(rock, O(), None, seen) is True and _effect(rock, O(), None, preview) is None
