"""Catalog timing normalisation (tools/build_catalog.py) and the combo-table generator
(tools/gen_attack_data.py -> mod/body/attack_data.lua)."""
from tools import build_catalog as bc
from tools import gen_attack_data as gen

CLUB = "/Game/Gameplay/Character/Player/Attacks/Club/"


def notify(cls, t, dur=0.0):
    return {"class": cls, "t": t, "dur": dur}


def raw_attack(win, dmg, reset, nxt=None, no_perk=None):
    return {"damage": 13.5, "next": nxt, "next_no_perk": no_perk, "montage_root_motion": {
        "path": "/Game/AM_X.AM_X", "length": 2.5, "rate": 1.0, "notifies": [
            notify("FoleyAnimNotify", 0.1), notify(bc.INPUT_WINDOW, win[0], win[1] - win[0]),
            notify(bc.DAMAGE_POINT, dmg), notify(bc.RESET_CHAIN, reset), notify(bc.ALLOW_MOVE, 0.85)]}}


def test_timing_from_notifies():
    t = bc.timing(raw_attack((0.367, 0.805), 0.501, 1.702))
    assert t["input_window"] == [0.367, 0.805] and t["damage_points"] == [0.501]
    assert t["reset_chain"] == 1.702 and t["allow_move"] == 0.85 and t["length"] == 2.5
    assert bc.timing({"damage": 1}) is None


def test_chains_full_and_short():
    a = {
        "A1": {"next": "A2"}, "A2": {"next": "A3"},
        "A3": {"next": "A4", "next_no_perk": "A4S"}, "A4": {"next": "A1"}, "A4S": {"next": "A1"},
    }
    assert bc.chain(a, "A1") == ["A1", "A2", "A3", "A4"]
    assert bc.short_chain(a, "A1") == ["A1", "A2", "A3", "A4S"]


def test_step_next_is_window_end_but_after_damage_point():
    attacks = bc.attacks_out({
        "early": raw_attack((0.3, 0.8), 0.5, 1.7),   # window end 0.8 > damage 0.5 + 0.2
        "late": raw_attack((0.3, 0.6), 0.55, 1.5),   # damage 0.55 + 0.2 = 0.75 > window end
        "none": {"damage": 5},
    })
    assert gen.step(attacks, "early")["next_ms"] == 800 and gen.step(attacks, "early")["reset_ms"] == 1700
    assert gen.step(attacks, "late")["next_ms"] == 750
    s = gen.step(attacks, "none")
    assert s["next_ms"] == gen.FALLBACK_NEXT_MS and s["reset_ms"] == gen.FALLBACK_RESET_MS and s["timed"] is False


def test_build_and_render():
    act = CLUB + "PA_Attack_Club.PA_Attack_Club_C"
    cat = {
        "build": "1",
        "attacks": bc.attacks_out({CLUB + "A1.A1_C": raw_attack((0.3, 0.8), 0.5, 1.7)}),
        "attack_sets": {act: {"action": act, "kind": "melee", "name": "Attack", "chain": [CLUB + "A1.A1_C"]}},
        "items": {
            "ITEM_Mace_X": {"path": "/Game/ITEM_Mace_X.ITEM_Mace_X", "range_type": "melee", "category": "mace",
                            "attacks": {"primary": {"action": act, "kind": "melee", "chain": [CLUB + "A1.A1_C"]}}},
            "ITEM_Bow": {"path": "/Game/ITEM_Bow.ITEM_Bow", "range_type": "ranged", "attacks": {}},
        },
    }
    data = gen.build(cat)
    assert list(data["items"]) == ["/Game/ITEM_Mace_X.ITEM_Mace_X"]
    assert data["sets"][act]["cdo"] == CLUB + "PA_Attack_Club.Default__PA_Attack_Club_C"
    assert data["categories"] == {"mace": act}
    lua = gen.render(data, "x.json")
    assert lua.startswith("-- GENERATED") and "return {" in lua and "next_ms = 800" in lua
