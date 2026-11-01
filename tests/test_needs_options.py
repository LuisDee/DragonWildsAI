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


def test_a_need_already_low_at_brain_start_raises_the_body_event_once():
    """Live 15:17:44-15:20:40Z: the body's vitals_low went out before the brain listened and repeats every 180 s."""
    from types import SimpleNamespace
    from brain.interface import VitalsLow
    from brain.run_live import LiveSession
    st = case("hunt_cook")  # food 25 % under the 40 % line, no food on the hotbar; Dirty Water on the hotbar
    evs = no.startup_lows(st)
    assert [(e.stat, e.value, e.has_food, e.has_drink) for e in evs] == [("sustenance", 25.0, False, True)]
    st2 = dict(st, hydration=10.0)  # water low too, but a drink IS on the hotbar: the reflex has it, no event
    assert [e.stat for e in no.startup_lows(st2)] == ["sustenance"]
    assert no.startup_lows({"unavailable": "offline"}) == [] and no.startup_lows(None) == []
    logged = []
    fake = SimpleNamespace(client=SimpleNamespace(get_state=lambda: {"ok": True, "data": st}),
                           agent=SimpleNamespace(_stash=[]), log=SimpleNamespace(log=lambda k, **kw: logged.append(k)))
    LiveSession.raise_standing_lows(fake)
    assert len(fake.agent._stash) == 1 and isinstance(fake.agent._stash[0], VitalsLow) and logged == ["startup_vitals_low"]


def test_the_graves_line_always_has_the_newest_grave():
    """11:19:45: the line ranked by value left out the newest grave (16 Forager's Sandwiches, 138 m)."""
    from brain import situation
    from brain.item_stats import graves_for_line
    line = next(ln for ln in situation.recent_life(case("grave_food")) if ln.startswith("Graves of yours"))
    assert "your newest, 138 m away, from 2026-11-01T11:18:46Z (go_to target 'my_grave:1793531926')" in line
    assert line.count(" | ") == 2  # still 3 graves: the two most valuable and the newest
    rows = [{"iso": f"2026-10-0{i}T00:00:00Z", "lost_items": 1} for i in range(1, 6)]
    top = graves_for_line(rows)
    assert len(top) == 3 and rows[4] in top and graves_for_line([]) == []


def test_a_bag_item_moved_under_the_line_is_used_by_the_reflex_and_the_digest_says_so():
    """Live 15:49Z: he moved Pumpkin Spice to the hotbar and drank it; the reflex had drunk one in between, so his
    was wasted. The digest now says what the reflex will do; the fire line no longer leads the block (15:50Z he
    promised "then i'll sort a fire" with two carried options in hand)."""
    from brain import situation
    st = json.loads(json.dumps(case("hunt_cook")))
    st["hydration"], st["sustenance"] = 24.0, 24.0
    st["inventory_items"] = [r for r in st.get("inventory_items") or [] if r.get("where") != "hotbar"] + [
        {"kind": "Item", "id": "Inventory:20", "slot": 20, "count": 13, "item": "ITEM_Consumable_Tea_Pumpkin",
         "name": "Pumpkin Spice Infusion", "where": "bag", "slot_type": "Inventory"},
        {"kind": "Item", "id": "Inventory:21", "slot": 21, "count": 13, "item": "ITEM_Consumable_Meat_Fillet",
         "name": "Fillet", "where": "bag", "slot_type": "Inventory"}]
    st["vitals_policy"] = {"eat_below_pct": 40, "drink_below_pct": 40, "safety_floor_pct": 10, "heal_below_pct": None,
                           "reflex_on": True, "reflex_every_s": 6}
    drink, food = block(st, "drink"), block(st, "food")
    assert "Pumpkin Spice Infusion x13 (bag)" in drink
    # he uses what he moves (the move holds the reflex for that kind): no "the reflex does it, nothing more to do"
    assert "move_item to the hotbar, then drink 1" in drink and "reflex drinks one by itself" not in drink
    assert "move_item to the hotbar, then eat 4" in food
    for blk in (drink, food):
        opts = blk.split("\n")[1:]
        assert not opts[0].startswith("- the fire"), opts[0]
    pol = situation.vitals_policy(st)
    assert "Below a line your body uses food/drink from your hotbar by itself, one per kind every ~6 s (from the bag only under 10%)" in pol
    off = dict(st, vitals_policy=dict(st["vitals_policy"], reflex_on=False))
    assert "move_item to the hotbar, then drink 1" in block(off, "drink")
    assert "The reflex is OFF" in situation.vitals_policy(off)


def test_the_reflex_pick_on_the_hotbar_says_the_reflex_is_already_using_it():
    """Live 16:20Z (rung1 gate eat_drink 3): the reflex drank Clean Water while he queued one too; his ran ~6 s later,
    over the line already, and held up his second Fillet. The reflex's own pick (first clean one by slot) says so."""
    st = json.loads(json.dumps(case("hunt_cook")))
    st["hydration"], st["sustenance"] = 12.0, 12.0
    st["inventory_items"] = [r for r in st.get("inventory_items") or [] if r.get("where") != "hotbar"] + [
        {"kind": "Item", "id": "Hotbar:2", "slot": 2, "count": 3, "item": "ITEM_Consumable_Water_Clean", "name": "Clean Water",
         "where": "hotbar", "slot_type": "Hotbar", "consumable": "drink"},
        {"kind": "Item", "id": "Hotbar:4", "slot": 4, "count": 2, "item": "ITEM_Consumable_Water_Dirty", "name": "Dirty Water",
         "where": "hotbar", "slot_type": "Hotbar", "consumable": "drink"}]
    st["vitals_policy"] = {"eat_below_pct": 40, "drink_below_pct": 40, "safety_floor_pct": 10, "reflex_on": True}
    drink = block(st, "drink")
    clean = next(ln for ln in drink.split("\n") if "carried Clean Water" in ln)
    dirty = next(ln for ln in drink.split("\n") if "carried Dirty Water" in ln)
    assert "your reflex is already drinking these by itself, one every ~6 s, until you're over your 40% line" in clean
    assert "reflex" not in dirty  # Soulscourge: not the reflex's pick
    st["hydration"] = 55.0  # over his line: the reflex leaves them
    assert "reflex" not in next(ln for ln in options_block(st, "drink").split("\n") if "carried Clean Water" in ln)


def options_block(state: dict, need: str) -> str:
    return no.options_for(state, need)
