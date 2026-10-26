"""M2 combat_tactics:prep_before_hard_fight: does the brain SEE that a fight is hard, and his own level, from
get_state alone (before any combat_brief call)? Information only: the digest states the body's estimate
(combat.fight_odds, the same estimate combat_brief gives) and never tells him what to do."""
import re
from pathlib import Path

from brain.situation import summary

ROOT = Path(__file__).resolve().parents[1]

# a get_state as the client body sends it: census rows + combat state_extras (power_level, fight_odds)
STATE = {
    "health": 100, "max_health": 100, "power_level": 1,
    "nearby_entities": [
        {"id": "BP_AI_GreyDrake_C_7", "name": "Grey Drake", "kind": "Grey Drake", "distance": 30, "hostile": True,
         "hp": 900, "max_hp": 900, "power_level": 6, "boss": None, "alive": True},
        {"id": "BP_AI_Kebbit_Character_02_C_3", "name": "Kebbit", "kind": "Kebbit", "distance": 6, "hostile": False,
         "hp": 30, "max_hp": 30, "power_level": 1, "alive": True},
    ],
    "fight_odds": {
        "BP_AI_GreyDrake_C_7": {"verdict": "too_strong", "kill_s": 75, "die_s": 20, "pl_gap": 5,
                                "known": {"Stab": {"v": "weak", "src": "journal"}},
                                "prepared": {"verdict": "likely_lose", "kill_s": 50, "die_s": 41,
                                             "uses": ["Iron Dagger vs stab-weak (journal)", "Tempest Shield (+57 shield)", "4 food (+120 HP)"]}},
        "BP_AI_Kebbit_Character_02_C_3": {"verdict": "likely_win", "kill_s": 3, "die_s": 60, "pl_gap": 0},
    },
    "inventory": {"ITEM_Consumable_Fish_Anchovies": 4, "ITEM_Staff_Fire": 1},
}


def lines():
    return summary(STATE)


def line(prefix):
    return next((l for l in lines() if l.startswith(prefix)), "")


def test_a_hard_creature_shows_its_level_and_the_odds():
    c = line("Creatures")
    assert "Grey Drake" in c and "PL 6" in c
    assert "odds now: much stronger (PL +5; kills you ~20 s; you it ~75 s)" in c


def test_known_weakness_and_prepared_odds_with_sources():
    c = line("Creatures")
    assert "known: weak to Stab (journal)" in c
    assert ("odds prepared: likely lose (kills you ~41 s; you it ~50 s) with Iron Dagger vs stab-weak (journal), "
            "Tempest Shield (+57 shield), 4 food (+120 HP)") in c


def test_an_easy_creature_shows_easy_odds():
    assert "odds now: likely win" in line("Creatures")


def test_the_odds_say_what_they_assume():
    """Truthful scope: the estimate counts only what he holds now (no shield, buff, enchant, food)."""
    assert line("Creatures").startswith("Creatures (the body's odds, you alone: 'now' = as equipped; 'prepared' = with what you own and can cast; blocking, dodging and armour not counted): ")


def test_his_own_level_is_beside_them():
    assert "PL 1" in line("You:")


def test_the_options_he_carries_are_listed():
    s = "\n".join(lines())
    assert "Anchov" in s  # food on the Food/drink or Carrying line


def test_information_only_no_advice():
    """No directive words in what the odds add (the model decides what to do about them)."""
    c = line("Creatures").split("): ", 1)[1]  # the notes (the title only states what the odds count)
    assert not re.search(r"\b(should|must|prepare|enchant|flee|avoid|don't)\b", c, re.I), c
    assert not re.search(r"\b(should|must|prepare|flee|avoid|don't)\b", line("Creatures"), re.I)


def test_state_extras_keys_are_not_dumped_raw():
    s = "\n".join(lines())
    assert "Fight odds:" not in s and "Power level:" not in s  # rendered in place, not as generic extras


def test_a_hard_creature_is_never_cut_off_the_line():
    """The line has a character budget: a creature the body rates hard comes before easy ones, hostile or not."""
    st = dict(STATE)
    ents = [dict(e) for e in STATE["nearby_entities"]]
    ents[0]["hostile"] = False  # a not-yet-aggressive drake
    st["nearby_entities"] = ents + [{"id": f"k{i}", "name": f"Rabbit {i}", "distance": 2 + i, "hp": 10, "max_hp": 10,
                                     "power_level": 0, "alive": True} for i in range(8)]
    c = next(l for l in summary(st) if l.startswith("Creatures"))
    assert c.index("Grey Drake") < c.index("Rabbit 0") and "much stronger" in c, c


def test_without_the_extras_nothing_breaks():
    st = dict(STATE)
    st.pop("fight_odds"); st.pop("power_level")
    c = next(l for l in summary(st) if l.startswith("Creatures"))
    assert "PL 6" in c and "odds" not in c


def test_combat_brief_is_offered_as_the_prep_facts_tool():
    """The tool the model calls for the details (weaknesses, weapons vs it, buff/defence spells, food)."""
    lua = (ROOT / "client_mod/scripts/combat.lua").read_text(encoding="utf-8")
    m = re.search(r"combat_brief = \{ kind = \"read\", llm = true.*?description = (\".*?\")\s*\.\.\s*(\".*?\")", lua, re.S)
    assert m, "combat_brief manifest entry"
    desc = (m.group(1) + m.group(2)).replace('"', "")
    for w in ("prepare", "weaknesses", "weapons", "spells", "food", "estimate"):
        assert w in desc, w
