"""brain/supplies.py: his food and water against the job, for the Planner (and the Controller's Food/drink line).

L3 "gear up for a vault" (21 Nov): 10 of 44 failed runs died first, on 4 Dried Redberries (heals 20 each, max HP 100);
0 of 48 runs carried food healing 80+; food stored in a chest was never taken back out. The heal values reached him
only once HP was low. The state is the real one before that plan (fixtures/state_l3_20261121_berries.json, from
logs/brain-live-20261121-025927-36848.jsonl row 20). The block is facts only: values from game data, nothing ranked
or prescribed.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

from brain import situation, supplies
from brain import map_memory as mm
from brain.jsonl_log import JsonlLogger
from brain.llm import FakeLLM
from brain.planner import Planner
from brain.stash import Stash
from brain.state_store import MOCK_SKILLS, SkillRegistry, Task, TaskTree

FIX = Path(__file__).parent / "fixtures"
PLAN = json.dumps({"description": None, "explanation": None, "ask_help": None, "tasks": [{"skill": "stop", "args": {}}]})
ADVICE = re.compile(r"\b(should|must|recommend\w*|better|best|you need to|consider)\b", re.I)
CRATE = "BP_BaseBuilding_Crate_C_2147472971"


def l3() -> dict:
    return json.loads((FIX / "state_l3_20261121_berries.json").read_text(encoding="utf-8"))["state"]


def test_carried_food_shows_its_values_from_the_food_data_and_the_totals():
    line = supplies.carried_line(l3())
    # HP per food point and per kg: the wiki's Food page (rev 72760) on Over Eating and carry weight
    assert line == ("carried: Dried Redberries x4 on the hotbar (each: heals 20, +15 food, 1.3 HP per food, 200 HP/kg) "
                    "= 80 HP of healing, +60 food, no water in all, 0.4 kg in 1 slot")
    st = l3()
    st["inventory_items"] = [r for r in st["inventory_items"] if not r.get("consumable")]
    assert supplies.carried_line(st) == "carried: no food or drink"


def test_how_long_the_bars_last_at_his_drain_then_at_the_games_decay_rate():
    line = supplies.lasts_line(l3())
    # 75.9 / 4.4 = 17 min; (75.9 + 60) / 4.4 = 31 min; 68.1 / 5.6 = 12 min (needs.pressing's arithmetic)
    assert "food 76/100, empty in ~17 min (~31 min with all you carry eaten as needed)" in line
    assert "water 68/100, empty in ~12 min (you carry none)" in line and "at your drain now" in line
    st = l3()
    del st["vitals_rate"]  # not measured yet: the components' DecayRatePerHour, one in-game hour per real minute
    line = supplies.lasts_line(st)
    assert "the game's decay rate (food 4.15/min, water 5.5/min)" in line
    assert "empty in ~18 min" in line  # 75.9 / 4.15


def test_fights_the_hits_his_healing_covers_from_the_games_attack_data():
    where = {"gear_for_vault": [{"vault": "Crasorak Kara",
                                 "enemies": ["Giant Rat x9 PL 2", "Vault Guardian Hulk x4 PL 2", "Vault Overlord x1 PL 2"]}]}
    enemies = supplies.vault_enemies(where)
    assert enemies == ["Giant Rat", "Vault Guardian Hulk", "Vault Overlord"]
    line = supplies.fight_line(l3(), enemies)
    # Kebbit in sight: 80 / 18 = ~4 hits; the body's odds die_s 231 at 100 HP -> 80 x 231 / 100 = 185 s
    assert "Kebbit 22 m: ~4 of its hits (18 each, up to 18), ~185 s more at its rate" in line
    assert "in the vault: Giant Rat ~4 (18 each, up to 26)" in line and "Vault Overlord ~2" in line
    assert "no attack data for Vault Guardian Hulk" in line  # said, never guessed
    assert ("in the first 30 s of a fight your carried healing gives 80 HP (4 eats at your measured ~6 s per use, "
            "hotbar first by slot; at the wiki's 2 s between foods: 80 HP); Over Eating (wiki: 200 food over your 100 cap "
            "locks eating 15 s) comes after 224 more food points from your food 76") in line
    st = l3()
    st["inventory_items"] = []
    assert supplies.fight_line(st, enemies).startswith("fights: you carry no healing; the vault's enemies hit for: Giant Rat 18 each")


def pizzas(n: int, food: float = 76.0) -> dict:
    st = l3()
    st["sustenance"] = food
    st["inventory_items"] = [{"where": "hotbar", "slot": 1, "name": "Meat Pizza", "item": "ITEM_Consumable_Iconic_Pizza_Meat",
                              "count": n, "consumable": "food"}]
    return st


def test_over_eating_caps_the_healing_he_can_take_in_a_fight():
    """Wiki Food rev 72760: 200 food over the 100 cap locks eating for 15 s. Meat Pizza heals 90 for +100 food, so from
    food 76 the third pizza (300 eaten, 276 over the cap) triggers it: 270 HP in the window, nothing after the lock."""
    w = supplies.fight_window(pizzas(6), supplies.EAT_S)
    assert (w["hp"], w["eats"], w["room"], w["locked"]) == (270.0, 3, 224.0, 12.0)
    w = supplies.fight_window(pizzas(6, food=0.0), supplies.WIKI_EAT_GAP_S)
    assert (w["hp"], w["eats"], w["locked"]) == (270.0, 3, 4.0)  # 300 points of room from empty: still the third
    w = supplies.fight_window(pizzas(9, food=0.0), 100.0)  # one use per 100 s: one eat in the window
    assert (w["hp"], w["eats"], w["locked"]) == (90.0, 1, None)
    assert "Over Eating locked you at 12 s" in supplies.window_words(pizzas(6))
    line = supplies.carried_line(pizzas(6))
    assert "(each: heals 90, +100 food, 0.9 HP per food, 129 HP/kg, Duration 600 s)" in line
    assert line.endswith("4.2 kg in 1 slot")  # 0.7 kg each (food data), stacks of 50 (recipe catalog)
    assert supplies.DURATION_NOTE in supplies.lines(pizzas(6))  # what Duration is, said once, with what is not known


def test_home_stock_counts_and_age_from_what_he_saw_in_his_crate(tmp_path):
    clock = [1000.0]
    s = Stash(tmp_path / "containers.json", clock=lambda: clock[0])
    s.observe_state({"structures": [{"id": CRATE, "name": "Crate", "mine": True, "position": [168.8, 1887.8, -30.6]}]})
    assert s.observe_result("store", {}, {"ok": True, "data": {"container": CRATE, "container_name": "Crate",
                                                               "contents": ["30 Meat Sandwich", "12 Clean Water", "5 Stone"]}})
    clock[0] += 600
    st = l3()
    s.observe_state(st)  # the real feed: run_live hooks the stash onto every state read
    assert st["containers_stock"]["your Crate at (169,1888)"] == {
        "items": {"ITEM_Consumable_Sandwich_Meat": 30, "ITEM_Consumable_Water_Clean": 12, "ITEM_Resources_Stone": 5},
        "ago_s": 600.0}
    line = supplies.home_line(st)
    assert line == ("home stock (what you saw when you last opened them): your Crate at (169,1888), 10 min ago: "
                    "30 Meat Sandwich (2400 HP of healing), 12 Clean Water (+300 water)")
    assert "home stock as last seen: your Crate at (169,1888), 10 min ago: 30 Meat Sandwich" in situation.food_line(st)
    st["containers_stock"] = {"your Crate at (1,2)": {"items": {"ITEM_Resources_Stone": 5}, "ago_s": 5}}
    assert supplies.home_line(st) == "home stock: none of the 1 containers you have opened held food or drink"


def test_cook_recipes_his_unlocked_ones_with_values_and_how_many_are_locked():
    st = l3()
    st["inventory"]["ITEM_Resources_Meat_Farm"] = 2
    line = supplies.recipes_line(st)
    assert re.match(r"you can cook \(your unlocked recipes; \d+ other food and drink recipes not unlocked yet, healing up "
                    r"to 220; value each: item \(inputs\)\): at a Campfire or Grill: ", line)
    assert ("heals 30, +20 food, 1.5 HP per food, 60 HP/kg: Haunch (Raw Game Meat), Steak (Raw Farm Meat; inputs on you)"
            in line)
    assert "+25 water: Clean Water (Dirty Water)" in line
    assert "Burnt" not in line  # burning food on purpose gives less than it takes: not a way to get food
    assert "Meat Sandwich" not in line  # not among his unlocks in this state
    del st["recipes_unlocked"]  # unlocks unknown: only what he can make from what he carries
    assert supplies.recipes_line(st).startswith("you can make now from what you carry (unlocks unknown")


def test_sources_from_map_memory_with_what_each_yields(tmp_path):
    t = [2000.0]
    m = mm.MapMemory(tmp_path / "map_memory.json", clock=lambda: t[0], debounce_s=1e9)
    me = [0.0, 0.0, 0.0]
    m.observe({"position": me, "nearby_resources": [
        {"name": "Redberry Bush", "item": "ITEM_Consumable_Fruit_Redberry", "position": [120.0, 0.0, 0.0]},
        {"name": "Ash Logs", "item": "ITEM_Resources_Wood_Ash", "position": [5.0, 0.0, 0.0]}],
        "nearby_entities": [{"name": "Chicken", "id": "C1", "position": [0.0, -60.0, 0.0]},
                            {"name": "Kebbit", "id": "K1", "position": [3.0, 0.0, 0.0]}],
        "interactables": [{"name": "Water Volume", "kind": "interactable", "class": "BP_WaterVolume_C",
                           "prompt": "Collect Water", "position": [0.0, 300.0, 0.0]}]})
    t[0] += 300
    st = {"position": me}
    mm.annotate(st, m)
    rows = st["food_sources"]
    assert [(r["name"], r["kind"], r["distance"], r["direction"]) for r in rows] == [
        ("Chicken", "creature", 60, "N"), ("Redberry Bush", "resource", 120, "E"), ("Water Volume", "water", 300, "S")]
    assert all(r["age_min"] == 5 for r in rows)  # Kebbit (no meat) and Ash Logs are no food source
    line = supplies.sources_line({**st, "recipes_unlocked": []})
    # Fillet unlocks by itself on the first Raw Bird Meat (the game's ALL ITEMS bundle, needs_options._locked)
    assert "Chicken 60 m N, seen 5 min ago (Raw Bird Meat -> at a fire: Fillet heals 20, +20 food; Egg -> " in line
    assert "Redberry Bush 120 m E, seen 5 min ago (Redberries heals 10, +5 food; at a fire: Dried Redberries heals 20" in line
    assert "Water Volume 300 m S, seen 5 min ago (collect_water: Dirty Water +10 water, +20 Soulscourge" in line
    # the nearest water is kept when nearer food fills the rows
    assert [r["kind"] for r in supplies.sources(list(m.sightings.values()), me, t[0], n=1)] == ["water"]


def test_the_block_is_facts_bounded_and_says_no_should():
    st = l3()
    rows = supplies.lines(st, ["Giant Rat"])
    assert [r.split(" ", 1)[0] for r in rows] == ["carried:", "lasts:", "fights:", "you", "(Duration:"]
    assert all(len(r) <= supplies.LINE_CHARS for r in rows)
    assert not any(ADVICE.search(r) for r in rows), rows
    assert supplies.lines({"unavailable": "x"}) == [] and supplies.lines({"position": [0, 0, 0]}) == []


def test_the_planner_gets_the_block_at_plan_and_replan_and_logs_it(tmp_path):
    llm = FakeLLM([PLAN, PLAN])
    log = tmp_path / "b.jsonl"
    planner = Planner(llm, SkillRegistry(MOCK_SKILLS), JsonlLogger(log))
    planner.plan("claude, gear up for the vault", l3(), {})
    user = json.loads(llm.calls[0]["messages"][1]["content"])
    assert user["supplies"][0].startswith("carried: Dried Redberries x4 on the hotbar (each: heals 20, +15 food")
    tree = TaskTree(goal="gear up", tasks=[Task(skill="stop", args={})])
    planner.replan(tree, tree.tasks[0], "blocked", l3(), {})
    user = json.loads(llm.calls[1]["messages"][1]["content"].split("\n\n")[0])
    assert "supplies" in user
    rows = [json.loads(x) for x in log.read_text(encoding="utf-8").splitlines()]
    shown = [r for r in rows if r.get("kind") == "planner_supplies"]
    assert [r["mode"] for r in shown] == ["plan", "replan"] and shown[0]["heads"][0] == "carried"


def test_the_controller_food_line_has_the_values_not_the_label():
    line = situation.food_line(l3())
    assert line == ("Food/drink: Dried Redberries x4 (food, hotbar, heals 20, +15 food each); in all 80 HP of healing, "
                    "+60 food, no water")
    assert "Sustenance" not in line  # the body's row gave the label "Sustenance" as its food value
