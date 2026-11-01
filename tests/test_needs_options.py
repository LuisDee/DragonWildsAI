"""Options with costs for food and water (brain/needs_options.py; rung 1 "eat and drink by comparing options").

The states are the real co-play ones (evals/fixtures/needs_options/*.json, built by evals/needs_options_eval.py from
logs/brain-live-20261101-115554-7128.jsonl). The digest is information only: the tests check that every option carries
its value, place, steps, time and risk, that it is bounded, and that nothing ranks or prescribes.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

from brain import needs, needs_options as no
from tools import gen_food_values as gen

FIX = Path(__file__).resolve().parents[1] / "evals" / "fixtures" / "needs_options"


def case(name: str) -> dict:
    return json.loads((FIX / f"{name}.json").read_text(encoding="utf-8"))["state"]


def block(state: dict, need: str) -> str:
    return next(line for line in needs.lines(state) if line.startswith(f"Need {need}"))


def test_values_come_from_game_data_with_a_source():
    fv = no.values()
    berry, dried = fv["items"]["ITEM_Consumable_Fruit_Redberry"], fv["items"]["ITEM_Consumable_Fruit_Dried_Redberry"]
    assert berry["sustenance"] == 5 and dried["sustenance"] == 15 and dried["heal"] == 20
    assert fv["items"]["ITEM_Consumable_Water_Clean"]["hydration"] == 25
    assert fv["items"]["ITEM_Consumable_Water_Dirty"]["soulscourge"] == 20
    assert all(rec.get("src") for rec in fv["items"].values())  # every value says where it came from (live or wiki rev)
    kebbit = {d["name"] for d in fv["creatures"]["Kebbit"]["drops"]}
    assert kebbit == {"Coarse Animal Fur", "Animal Hide Scraps"}  # Luis: kebbits drop no meat
    assert {d["item"] for d in fv["creatures"]["Chicken"]["drops"]} >= {"ITEM_Resources_Meat_Bird", "ITEM_Resources_Egg"}
    assert fv["cooks"]["ITEM_Resources_Meat_Bird"][0]["output"] == "ITEM_Consumable_Meat_Fillet"


def test_grave_food_the_newest_grave_with_its_sandwiches_is_an_option():
    """D2: after the 11:18:46 death he went for berries; his newest grave held 16 Forager's Sandwiches."""
    food = block(case("grave_food"), "food")
    assert "your grave (go_to 'my_grave:1793531926')" in food
    assert "Forager's Sandwich x16 (+80 food +70 HP each)" in food
    assert re.search(r"- \[~\d+ s -> \+58 food, to 100%\] your grave \(go_to 'my_grave:1793531926'\).*"
                     r"\| 138 m away \| walk 138 m, Take All .*\| risk: you died there 59 s ago \(fell 29 m\)", food)


def test_hunt_cook_chickens_carry_their_cooked_value_and_kebbits_say_no_food():
    food = block(case("hunt_cook"), "food")
    hunt = next(line for line in food.split("\n") if "] hunt Chicken" in line)
    assert re.match(r"- \[~[\d.]+ min -> \+75 food, to 100%, lasts ~\d+ min\] hunt", hunt)  # the comparable outcome first
    assert "Fillet +20 food +20 HP, Fried Egg +20 food +20 HP = +40 food" in hunt
    assert "kill 2 (~20 s each)" in hunt and "odds now likely win" in hunt and "burn ~32% each at your Cooking 5" in hunt
    assert re.search(r"~\d", hunt)  # a time estimate
    assert "- no food from: " in food and "Kebbit x" in food
    assert "- the fire: Campfire 3 m (id BP_Station_Campfire_C_2147341079); fuel: Ash Logs x10 on you" in food


def test_boil_water_dirty_carries_its_soulscourge_and_boiling_its_value():
    drink = block(case("boil_water"), "drink")
    assert "carried Dirty Water x6 (hotbar): +10 water +20 Soulscourge each" in drink
    assert "5 fill the bar for 50 damage" in drink
    assert "cook your Dirty Water x6 -> Clean Water: +25 water each | the fire | cook 4 at the fire, drink 4" in drink


def test_urgent_raw_the_clock_and_the_raw_option_are_there():
    food = block(case("urgent_raw"), "food")
    assert "starving, [3%]" in food and "97 to full" in food
    assert "Redberries x3 to pick" in food and "raw +5 food" in food
    assert "fuel: none on you, Ash Logs to pick up" in food  # the cook needs fuel he must pick up first: a step, said


@pytest.mark.parametrize("name", ["grave_food", "hunt_cook", "boil_water", "urgent_raw"])
def test_bounded_and_every_option_has_gives_where_steps_risk(name):
    for line in needs.lines(case(name)):
        if not line.startswith(("Need food", "Need drink")):
            continue
        assert len(line) <= no.DIGEST_CHARS
        for opt in line.split("\n")[1:]:
            assert len(opt) <= no.OPTION_CHARS
            if opt.startswith(("- the fire", "- no food from", "- ask a player", "- carried: nothing", "- (")):
                continue
            assert opt.count(" | ") >= 3 and "risk: " in opt, opt  # gives | where | steps ~time | risk


def test_raw_berries_say_they_last_no_time_and_the_cooked_options_say_how_long():
    """At 25% food raw berries reach only the 40% eat line again: the lead says so, as numbers (no rule)."""
    food = block(case("hunt_cook"), "food")
    assert "[~19 s -> +15 food, to 40%, lasts ~0 min] Redberries x1 to pick" in food
    assert "[~42 s -> +45 food, to 70%, lasts ~12 min] Dried Redberries from them" in food


def test_no_ranking_groups_keep_a_fixed_order():
    """The order is the group order, never by value: a better option is not moved up (the model compares)."""
    st = case("hunt_cook")
    food = block(st, "food").split("\n")
    order = [i for i, ln in enumerate(food) if re.match(r"- (\[[^]]*\] )?(Redberries|hunt Chicken|ask a player)", ln)]
    assert order == sorted(order) and len(order) == 3
    st["nearby_entities"] = [e for e in st["nearby_entities"] if e.get("name") != "Chicken"]
    assert "hunt Chicken" not in block(st, "food")


def test_exhausted_uses_his_walking_pace_and_says_why():
    st = case("grave_food")
    st["endurance"], st["exhausted"] = 0.0, True
    food = block(st, "food")
    assert "walking pace 2 m/s: you are exhausted" in food
    fast = block(case("grave_food"), "food")
    t = lambda s: int(re.search(r"\[~(\d+) s -> \+58 food", s).group(1))  # noqa: E731
    assert t(food) > 2 * t(fast)


def test_wiki_parsers():
    wt = ("{{Infobox Monster\n|name = Chicken\n|health = 20\n|power_level = 1\n|aggressive = no\n}}\n"
          "{{DropsLine|name=Raw Bird Meat|quantity=1|rarity=Always}}\n{{DropsLine|name=Weeds|quantity=2|rarity=15/100}}")
    f = gen.fields(gen.template(wt, "Infobox Monster"))
    assert f["name"] == "Chicken" and gen.versions(f, "power_level") == [1] and gen.versions(f, "health") == [20]
    assert gen.drops(wt) == [{"name": "Raw Bird Meat", "qty": 1, "chance": 1.0}, {"name": "Weeds", "qty": 2, "chance": 0.15}]


def test_live_rows_win_over_the_wiki():
    cat = {"items": {"ITEM_X": {"name": "X", "class": "BP_Consumables_Food_C", "weight": 0.1}}}
    wiki = {"ITEM_X": {"sustenance": 5, "wiki": {"revid": 1}}}
    live = {"items": {"ITEM_X": {"kind": "food", "heal": 10.0, "sustenance_row": "X", "sustenance_table": "DT_FoodSustenance",
                                 "sustenance": {"Sustenance": 6.0, "DecayBuffer": 2.0}}}}
    rec = gen.merge(cat, wiki, live)["ITEM_X"]
    assert rec["sustenance"] == 6.0 and rec["heal"] == 10.0 and rec["decay_buffer"] == 2.0
    assert rec["src"]["sustenance"].startswith("live DT_FoodSustenance") and rec["live"] is True


def test_food_options_read_tool_answers_on_demand_without_a_phrase_table(tmp_path):
    """'what can we eat?' at 80% food: no Need line is pressing, so the model may ask for the digest itself."""
    from conftest import Rig
    from brain.llm import FakeLLM
    rig = Rig(tmp_path)
    st = case("hunt_cook")
    st["sustenance"] = 80.0
    rig.controller_llm.push(FakeLLM.say("", FakeLLM.call("food_options", need="food")),
                            FakeLLM.say("chickens over there, or berries"))
    rig.controller.decide("Luis", "what can we eat round here?", st, None)
    second = rig.controller_llm.calls[1]["messages"]
    tool_msg = next(m for m in second if m["role"] == "tool")
    data = json.loads(tool_msg["content"])["data"]
    assert data["food"].startswith("Need food (") and "hunt Chicken" in data["food"]
    assert "food_options" in {t["function"]["name"] for t in rig.controller_llm.calls[0]["tools"]}
    assert not any(ln.startswith("Need food") for ln in needs.lines(st))  # not pressing: on demand only
