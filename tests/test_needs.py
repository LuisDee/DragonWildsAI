"""Needs -> options digest (companion-quality N, BUGS L16): perception from game data, not a mapping.

Replays the live 21:17 UTC moment (state captured from logs/brain-live-20261025-214057-8860.jsonl): food
at 11 %, a Redberry Bush 11 m away, a Raw Stringy Meat carried, Zezima 4 m away, a Crafting Table 40 m away.
The live model said "I'll look for a fire to cook raw meat" and considered nothing else.
"""
import json
from pathlib import Path

import pytest

from brain import needs
from brain.controller import Controller
from brain.interface import GameInterface, ok
from brain.jsonl_log import JsonlLogger
from brain.llm import FakeLLM
from brain.situation import summary, world_line
from brain.state_store import StateStore

FIX = Path(__file__).parent / "fixtures" / "state_2117_hungry.json"


def state() -> dict:
    return json.loads(FIX.read_text(encoding="utf-8"))


def test_kinds_come_from_item_data_not_names():
    assert needs.item_kind("ITEM_Consumable_Fruit_Redberry") == "food"
    assert needs.item_kind("ITEM_Consumable_Tea_Pumpkin") == "drink"
    assert needs.item_kind("ITEM_Resources_Meat_Bird") is None  # raw meat is an ingredient, not food (class ItemData)
    assert needs.item_kind("ITEM_Logging_Axe_Steel") is None


def test_2117_hungry_options_list_berries_cooking_and_zezima():
    lines = needs.lines(state())
    food = next(l for l in lines if l.startswith("Need food"))
    assert "Redberry Bush" in food and "fol:BP_InteractableFoliageISMC_PickUps_C_9:1" in food  # the bush 11 m away, with its id
    # cooking the carried stringy meat, with its value; no fire near is a fact with its cost (brain/needs_options.py)
    assert "cook your Raw Rat Meat x1 -> Rat Roast: +20 food +20 HP each" in food and "Campfire" in food
    assert "ask a player: Zezima" in food
    assert "carried: nothing that restores food" in food  # he carries no food (the infusions are drinks)


def test_nothing_pressing_no_lines_and_policy_respected():
    st = state()
    st["sustenance"] = 80.0
    assert not any(l.startswith("Need food") for l in needs.lines(st))
    st["sustenance"], st["vitals_policy"] = 45.0, {"eat_below_pct": 20}
    assert not any(l.startswith("Need food") for l in needs.lines(st)), "45 % is not pressing under a 20 % policy"


def test_unlocks_filter_craft_options_when_known():
    st = state()
    st["recipes_unlocked"] = ["RECIPE_Consumable_Bread_From_Flour"]
    food = next(l for l in needs.lines(st) if l.startswith("Need food"))
    # the carried meat's recipe is locked: no cook option for it; the Giant Rat's would unlock on its own first drop
    assert "cook your Raw Rat Meat" not in food and "craft Bread" in food and "unlocks unknown" not in food


def test_rest_and_health_needs():
    st = state()
    st["endurance"], st["endurance_max"] = 10.0, 100.0
    st["interactables"] = [{"id": "BP_Magic_SummonShelter_C_9", "name": "Magic Summon Shelter", "kind": "bed", "prompt": "Sleep",
                            "distance": 5.0, "owner": "Zezima"}]
    st["time_of_day"] = {"sleep_allowed": True}
    rest = next(l for l in needs.lines(st) if l.startswith("Need rest"))
    assert "Magic Summon Shelter" in rest and "owner Zezima" in rest and "sleep timeframe open" in rest
    st["health"] = 30.0
    assert any(l.startswith("Need health") for l in needs.lines(st))


@pytest.mark.parametrize("raw,expected", [(True, "open"), (False, "closed"), (None, "unknown"),
                                         ("false", "unknown"), (0, "unknown")])
def test_sleep_timeframe_is_not_rest_availability_or_recovery(raw, expected):
    st = {"endurance": 0, "endurance_max": 100, "time_of_day": {"sleep_allowed": raw}}
    world = world_line(st)
    rest = next(line for line in needs.lines(st, cat={}) if line.startswith("Need rest"))
    for line in (world, rest):
        assert f"sleep timeframe {expected}" in line
        assert all(text not in line for text in ("too early to sleep", "sleeping is possible",
                                                  "resting still restores", "restored by sleep",
                                                  "no bed or shelter near"))
    assert "rest: exhausted [0%]" in summary(st)[0]  # endurance is a vital: on the You: line (2026-10-31)
    assert "at 0 you can't sprint and your jumps fail until you rest in a bed or a Summon Shelter" in rest


def test_rest_perception_keeps_actual_prompts_and_resting_state():
    st = {"endurance": 20, "endurance_max": 100,
          "time_of_day": {"sleep_allowed": False, "resting_in": "object-7"},
          "interactables": [{"id": "object-7", "name": "Covered place", "kind": "resting_area",
                             "prompt": "Rest", "distance": 2, "owner": "Dev"}]}
    world = world_line(st)
    rest = next(line for line in needs.lines(st, cat={}) if line.startswith("Need rest"))
    assert "lying in object-7" in world and "rest: tired [20%]" in summary(st)[0]
    assert "Covered place" in rest and "prompt Rest" in rest and "owner Dev" in rest
    assert "sleep timeframe closed" in world and "sleep timeframe closed" in rest


def test_low_rest_says_what_it_costs_him_and_what_restores_it():
    """B8 (co-play 2026-11-01): rest 0 all session, slow, never said why. The line names the game's own caps from his
    maxes (live 2026-11-01 at rest 14.8: max stamina 60, food/water maxes 75) and what restores rest."""
    st = {"endurance": 14.8, "endurance_max": 100, "max_stamina": 60.0, "hydration_max": 75.0, "sustenance_max": 75.0,
          "hydration": 70, "sustenance": 70}
    rest = next(line for line in needs.lines(st, cat={}) if line.startswith("Need rest"))
    assert "max stamina 60/100: less sprint and jump" in rest
    assert "max food 75, water 75 (capped under 25 rest" in rest
    assert "+1 rest/s" in rest and "a night's sleep refills it" in rest
    full = {"endurance": 20, "endurance_max": 100, "max_stamina": 100.0, "hydration_max": 100.0, "sustenance_max": 100.0}
    assert "effect now" not in next(line for line in needs.lines(full, cat={}) if line.startswith("Need rest"))


def test_a_pond_is_a_drink_option():
    st = {"hydration": 10, "hydration_max": 75,
          "interactables": [{"class": "BP_WaterVolume_C", "name": "Water Volume", "id": "BP_WaterVolume_C_1", "distance": 17.2}]}
    drink = next(line for line in needs.lines(st, cat={}) if line.startswith("Need drink"))
    assert "collect Dirty Water at Water Volume (id BP_WaterVolume_C_1)" in drink and "| 17 m |" in drink
    assert "at 0 you lose 1 HP a second down to 1 HP" not in drink  # no drain rate known: no time-to-zero clause


def test_missing_sensors_do_not_claim_any_rest_object_or_endurance():
    st = {"endurance": 0, "endurance_max": 100}
    assert "sleep timeframe unknown" in world_line(st)
    rest = next(line for line in needs.lines(st, cat={}) if line.startswith("Need rest"))
    assert "sleep timeframe unknown" in rest and "no bed" not in rest
    assert "endurance" not in world_line({"time_of_day": {}})


class _Body(GameInterface):
    def __init__(self, st): self.st = st
    def get_state(self): return ok(**self.st)
    def follow(self, player, distance=3.0): return ok()
    def stop(self): return ok()
    def go_to(self, target): return ok()
    def attack(self, target): return ok()
    def gather(self, resource, count, radius=None): return ok()
    def craft(self, item, count=1): return ok()
    def place(self, blueprint, location): return ok()
    def give(self, player, item, count): return ok()
    def pickup(self, target, item=None, limit=1): return ok()
    def drop(self, item, count, at="feet", player=None): return ok()
    def say(self, text): return ok()
    def poll_events(self): return []


def test_2117_replay_the_model_sees_the_options(tmp_path):
    """Fake-model replay: the Controller's prompt at 21:17 carries the needs line with all three paths."""
    st = state()
    llm = FakeLLM([FakeLLM.say("Starving. Grabbing some redberries.", FakeLLM.call("interact", target="fol:BP_InteractableFoliageISMC_PickUps_C_9:1"))])
    c = Controller(llm, _Body(st), StateStore(tmp_path / "s"), JsonlLogger(tmp_path / "b.jsonl"), name="Claude", player="Zezima",
                   available_tools={"interact", "consume", "go_to", "look", "inventory"})
    d = c.decide("Zezima", "", st, None, addressed=True, body_event={"type": "vitals_low", "stat": "sustenance", "value": 11.3})
    ctx = json.loads(llm.calls[0]["messages"][1]["content"])
    digest = "\n".join(ctx["situation"])
    assert "Need food" in digest and "Redberry Bush" in digest and "Rat Roast" in digest and "Zezima" in digest
    assert d.actions and d.actions[0].name == "interact"


def test_digest_stays_compact():
    """The needs line is bounded; the whole situation digest stays small (prompt budget, workstream N)."""
    from brain.needs_options import DIGEST_CHARS
    s = summary(state())
    assert all(len(line) <= (DIGEST_CHARS if line.startswith(("Need food", "Need drink")) else 600) for line in s)
    assert len(json.dumps(s)) < 6000  # the food options digest (bounded) replaced a 560-char cut line


# --------------------------------------------------------------------------- BUGS L17: the 21:17-21:25 starvation replay
# Live samples (logs/brain-live-20261025-220403-6472.jsonl): food 13.6 at 21:17:43, 8.2 at 21:20:21, 4.8 at
# 21:21:57, 1.1 at 21:23:45, 0.1 at 21:24:14; HP 100 -> 6 by 21:25:51; dead at 21:25:56. Drain ~2.1 / min.
REPLAY = [("21:17:43", 13.6), ("21:20:21", 8.2), ("21:21:57", 4.8), ("21:23:45", 1.1), ("21:24:14", 0.1)]


def test_2117_to_2125_every_turn_shows_the_options_and_the_clock():
    for when, food in REPLAY:
        st = state()
        st["sustenance"], st["sustenance_max"] = food, 100.0
        st["vitals_rate"] = {"sustenance_per_min": 2.1, "hydration_per_min": 1.4}
        line = next(l for l in needs.lines(st) if l.startswith("Need food"))
        mins = round(food / 2.1)
        assert f"empty in ~{mins} min at the current drain; at 0 you lose 1 HP a second down to 1 HP, where any hit kills you" in line, (when, line)
        assert "Redberry Bush" in line and "-> Rat Roast" in line and "Zezima" in line, (when, line)
        assert "building one takes 6 Stone" in line  # the fire is a building piece: its cost, so he knows what it takes


def test_death_memory_is_always_in_the_digest_until_recovered():
    st = state()
    st["death_memory"] = {"iso": "2026-10-25T21:25:56Z", "ago_s": 120, "position": [400.0, 1745.0, -42.0], "distance": 95,
                          "lost_items": 12, "lost": ["Steel Logging Axe x1", "Iron Pickaxe x1", "Pumpkin Spice Infusion x3"]}
    digest = "\n".join(summary(st))
    assert "Graves of yours not in sight, newest first: 95 m away, from 2026-10-25T21:25:56Z (go_to target 'my_grave')" in digest
    assert "Steel Logging Axe x1" in digest


def test_activity_lists_the_skills_own_spells_and_the_rate_vs_best():
    st = {"activity": {"skill": "Mining", "window_min": 6.0, "xp_per_min": 140, "best_xp_per_min": 190,
                       "items": [{"item": "ITEM_Resources_Stone", "per_min": 3.5, "best_per_min": 4.2}]},
          "held_actions": {"item_name": "Iron Pickaxe", "actions": [{"name": "Attack"}, {"name": "Block"}]}}
    line = needs.activity_lines(st)[0]
    assert "Rocksplosion" in line and "needs Pickaxe" in line  # from data/spell_effects.json unlock.skill = Mining
    assert "140 XP/min (best 190)" in line and "3.5/min (best 4.2)" in line and "Iron Pickaxe: Attack, Block" in line
    assert "Axtral Projection" not in line  # a Woodcutting spell
    assert needs.activity_lines({}) == []


def test_a_summon_shelter_he_knows_is_a_rest_option():
    st = {"endurance": 5, "endurance_max": 100,
          "spells": [{"id": "USD_SummonShelter", "name": "Summon Shelter", "castable": True}]}
    rest = next(line for line in needs.lines(st, cat={}) if line.startswith("Need rest"))
    assert "Summon Shelter (your spell, castable now)" in rest and "at 0 you" not in rest
