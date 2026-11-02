"""tools/rung4_gate.py gear_up: the target comes from gear_plan, the check reads worn:/held: rows."""
from tools import rung4_gate as r4

ST = {"gear": {"Body": "ITEM_Armour_T1_Body_Adventurers", "Legs": "ITEM_Armour_T1_Legs_Adventurers",
               "HeldRight": "ITEM_Sword_Bronze", "HeldLeft": "ITEM_Shield_Bronze"},
      "inventory": {}, "recipes_unlocked": [], "position": [100.5, 1857.5, -31],
      "nearby_entities": [{"name": "Cow", "power_level": 2, "alive": True}], "structures": []}
START = {"worn:Adventurer's Tunic": 1, "worn:Adventurer's Leggings": 1, "held:Bronze Sword": 1, "held:Bronze Shield": 1}


def test_target_is_the_full_reinforced_set_and_keeps_his_bronze_kit():
    tg = r4.gear_target(ST, None)
    assert tg["pl"] == 2 and tg["kit"] == {"right_hand": 3, "left_hand": 3}
    assert [o["name"] for o in tg["pieces"]] == ["Reinforced Helmet", "Reinforced Body", "Reinforced Platelegs"]
    t, how = r4.gear_up_t_h(tg, ST)
    assert 200 < t < 400 and "kill cow" in how and "16 leather" in how


def test_check_needs_the_whole_set_worn_and_the_kit_held():
    rec = {"target": {"pl": 2, "kit": {"right_hand": 3, "left_hand": 3}}, "inv": [
        [0, START],
        [100, {**START, "worn:Reinforced Body": 1, "worn:Reinforced Helmet": 1}],  # 2+2+1 = 5/3 -> PL 1
        [200, {"worn:Reinforced Body": 1, "worn:Reinforced Helmet": 1, "worn:Reinforced Platelegs": 1, "held:Bronze Sword": 1}]]}
    done, how, when, m = r4.check_gear(rec, [])
    assert not done and "left_hand empty (target PL 3)" in how
    rec["inv"][2][1]["held:Bronze Shield"] = 1
    done, how, when, m = r4.check_gear(rec, [])
    assert done and when == 200 and m["gear_end"]["pl"] == 2


def test_fall_guard_ends_the_window_on_a_drop_near_a_recorded_hazard():
    class C:
        abort = None
        sent = []

        class cli:
            @staticmethod
            def request(tool, args, timeout=None):
                C.sent.append(tool)
    guard = r4.fall_guard([{"at": [44.4, 1745.0, -29.8], "n": 4}])
    guard(C, {"position": [100, 1850, -31]})
    guard(C, {"position": [101, 1850, -40]})  # a 9 m drop far from any hazard: not this guard's
    assert C.abort is None
    guard(C, {"position": [46, 1747, -30]})
    guard(C, {"position": [45, 1746, -33]})
    assert C.abort and "z dropped 3.0 m" in C.abort and C.sent == ["stop"]


def test_carry_check_is_done_when_under_his_max():
    rec = {"inv": [[0, {"carry:cur": 407.7, "carry:max": 400, "Stone": 77}], [5, {"carry:cur": 401, "carry:max": 400, "Stone": 70}],
                   [9, {"carry:cur": 330, "carry:max": 400}]]}
    done, how, when, m = r4.check_carry(rec, [])
    assert done and when == 9 and "-77 Stone" in how and "carry:" not in how.split("window")[-1]
