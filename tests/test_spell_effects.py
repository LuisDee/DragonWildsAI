"""data/spell_effects.json (tools/gen_spell_effects.py): one effect signature per player spell, for T0 cases."""
import json

from tools import gen_spell_effects as G


def build():
    return G.build(json.loads(G.SRC.read_text(encoding="utf-8")))


def test_every_player_spell_has_a_proof_shape():
    out = build()
    assert out["version"] == 1 and out["build"] == G.BUILD
    assert len(out["spells"]) >= 38
    for sid, s in out["spells"].items():
        assert s["proof"]["required"], sid
        assert s["proof"]["required"][-1] == {"kind": "cooldown_started"}, sid
        assert s["target"] in {"self", "ground", "thing", "aim"}, sid
        assert s["confidence"] in {"live", "data", "data_weak"}, sid
        for e in s["proof"]["effect"]:
            assert e["kind"] in out["signal_kinds"], (sid, e)


def test_live_observations_win_and_carry_evidence():
    out = build()
    ws = out["spells"]["USD_Windstep"]
    assert ws["confidence"] == "live" and "7.38" in ws["evidence"]
    assert ws["proof"]["effect"][0] == {"kind": "tag_added", "tag": "Player.Spell.WindStep"}
    assert out["spells"]["USD_PhaseDash"]["proof"]["effect"][0]["kind"] == "air_dash_m"
    assert out["spells"]["USD_Splinter"]["target"] == "thing"
    assert out["spells"]["USD_SummonShelter"]["target"] == "ground"


def test_data_derived_signals_come_from_game_modules():
    out = build()
    fire = out["spells"]["USD_FireSpirit"]["proof"]["effect"]
    assert {"kind": "tag_added", "tag": "Player.Status.FireSpirit"} in fire  # GE add_tags in the spell data
    ench = out["spells"]["USD_EnchantWeapon_Air"]
    assert ench["requirement"]["strategy"] == "BP_USSRS_RequiresHeldEnchantableMeleeWeapon_C"
    assert ench["proof"]["effect"][0]["kind"] == "held_item_effect"
    assert "DamageType.Magical.Air" in ench["proof"]["effect"][0]["damage_types"]


def test_checked_in_file_is_current():
    on_disk = json.loads(G.OUT.read_text(encoding="utf-8"))
    fresh = build()
    on_disk.pop("generated_at"), fresh.pop("generated_at")
    assert on_disk == fresh, "run: python -m tools.gen_spell_effects"
