"""data/spell_effects.json (tools/gen_spell_effects.py): one effect signature per player spell, for T0 cases."""
import json

from tools import gen_spell_effects as G


def build():
    return G.build(json.loads(G.SRC.read_text(encoding="utf-8")))


def test_every_player_spell_has_a_proof_shape():
    out = build()
    assert out["version"] == 1 and out["build"] == G.BUILD
    assert len(out["spells"]) == len(json.loads(G.SRC.read_text(encoding="utf-8"))["spells"])  # every spell in the data
    assert out["counts"]["unlocked"] == len(G.UNLOCKED_SNAPSHOT["ids"])
    for sid, s in out["spells"].items():
        assert s["status"] in {"unlocked", "locked", "n/a"}, sid
        assert (s["status"] == "n/a") == bool(s["na_reason"]), sid
        assert isinstance(s["setup_checks"], list), sid
        if s["status"] != "n/a":
            # runes alone never prove a cast: every player spell names a non-rune effect (maybe unobservable yet)
            assert s["proof"]["required"][0] == {"kind": "runes_spent", "observable": "cast_reply"}, sid
            assert s["proof"]["effect"], sid
        for e in s["proof"]["required"] + s["proof"]["effect"]:
            assert e["observable"] in {"cast_reply", "probe", "state", "referee", False}, (sid, e)
            if e.get("probe"):
                assert e["probe_moves_pawn"] is True and e["probe"] in out["probes"], (sid, e)
        assert s["proof"]["required"], sid
        assert s["proof"]["required"][-1] == {"kind": "cooldown_started", "observable": "cast_reply"}, sid
        assert s["target"] in {"self", "ground", "thing", "aim"}, sid
        assert s["confidence"] in {"live", "data", "data_weak"}, sid
        for e in s["proof"]["effect"]:
            assert e["kind"] in out["signal_kinds"], (sid, e)


def test_live_observations_win_and_carry_evidence():
    out = build()
    ws = out["spells"]["USD_Windstep"]
    assert ws["confidence"] == "live" and "7.38" in ws["evidence"]
    assert ws["proof"]["effect"][0] == {"kind": "tag_added", "tag": "Player.Spell.WindStep", "observable": "cast_reply"}
    assert out["spells"]["USD_PhaseDash"]["proof"]["effect"][0]["kind"] == "air_dash_m"
    assert out["spells"]["USD_Splinter"]["target"] == "thing"
    assert out["spells"]["USD_SummonShelter"]["target"] == "ground"


def test_data_derived_signals_come_from_game_modules():
    out = build()
    fire = out["spells"]["USD_FireSpirit"]["proof"]["effect"]
    assert {"kind": "tag_added", "tag": "Player.Status.FireSpirit", "observable": "cast_reply"} in fire  # GE add_tags in the spell data
    ench = out["spells"]["USD_EnchantWeapon_Air"]
    assert ench["requirement"]["strategy"] == "BP_USSRS_RequiresHeldEnchantableMeleeWeapon_C"
    assert ench["proof"]["effect"][0]["kind"] == "held_item_effect" and ench["proof"]["effect"][0]["observable"] == "cast_reply"
    assert {"held_category": "melee_weapon"} in ench["setup_checks"]
    assert out["spells"]["USD_FishCyclone"]["status"] == "locked"  # Fishnado
    assert "DamageType.Magical.Air" in ench["proof"]["effect"][0]["damage_types"]


def test_checked_in_file_is_current():
    on_disk = json.loads(G.OUT.read_text(encoding="utf-8"))
    fresh = build()
    on_disk.pop("generated_at"), fresh.pop("generated_at")
    assert on_disk == fresh, "run: python -m tools.gen_spell_effects"


def test_purposes_for_every_unlocked_spell_never_name_the_spell():
    from brain import predicates as P
    out = build()
    known = set(P.LEAVES) | {"spell_effect"} | set(P.COMBINATORS)

    def leaves(pred):
        (k, v), = pred.items()
        if k in ("all", "any"):
            return [x for sub in v for x in leaves(sub)]
        if k == "not":
            return leaves(v)
        return [k]

    for sid, s in out["spells"].items():
        if s["status"] != "unlocked":
            continue
        assert s["purposes"], sid
        for p in s["purposes"]:
            words = p["situation"].lower()
            assert s["name"].lower() not in words and "cast" not in words and "spell" not in words, (sid, p["id"])
            assert p["observable"] in {"state", "probe", False}, (sid, p["id"])
            assert p["confidence"] in {"live", "data"}, (sid, p["id"])
            assert isinstance(p["world"]["needs"], list), (sid, p["id"])
            assert set(leaves(p["success"])) <= known, (sid, p["id"], p["success"])
            if p["observable"] is False:
                assert p.get("gap"), (sid, p["id"])
