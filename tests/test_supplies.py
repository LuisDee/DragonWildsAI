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


# ------------------------------------------------------------------------------------------------ fishing spots
# The L3 state's own get_state (row 20) had these in sight: fishing.lua's fishing_spots_nearby, no position on a row.
NET = "BP_FishingNodeV2_Net_Brynmoor_C_UAID_DC97BA249CD4FDC402_1131309019"
ROD = "BP_FishingNodeV2_Rod_Brynmoor_C_UAID_DC97BA249CD4FDC402_1155627020"
NET2 = "BP_FishingNodeV2_Net_Brynmoor_C_UAID_DC97BA249CD4FCC402_2104746842"
IN_SIGHT = [{"name": "Net Fishing Spot", "distance_m": 4.5, "id": NET, "level": 2, "method": "net"},
            {"name": "Rod Fishing Spot", "distance_m": 21.3, "id": ROD, "level": 2, "method": "rod"},
            {"name": "Net Fishing Spot", "distance_m": 23.6, "id": NET2, "level": 2, "method": "net"}]


def fishing_memory(tmp_path):
    """He stood near (113,1850) in Temple Woods for 6 s with a net spot 1.2 m and a rod spot 9 m from him (the body's
    rows as they come today: no position), then walked back to the L3 spot (151,1912) 10 min later."""
    t = [2000.0]
    m = mm.MapMemory(tmp_path / "map_memory.json", clock=lambda: t[0], debounce_s=1e9)
    for _ in range(3):
        m.observe({"position": [113.0, 1850.0, -30.0], "fishing_spots_nearby": [
            {"name": "Net Fishing Spot", "id": "BP_FishingNodeV2_Net_Brynmoor_C_UAID_AA_1", "distance_m": 1.2,
             "level": 2, "method": "net"},
            {"name": "Rod Fishing Spot", "id": "BP_FishingNodeV2_Rod_Brynmoor_C_UAID_AA_2", "distance_m": 9.0,
             "level": 2, "method": "rod"}]})
        t[0] += 3
    t[0] += 600
    return m, t


def test_fishing_spots_reach_map_memory_through_the_census_with_an_honest_fix(tmp_path):
    """fishing_spots_nearby rows carry no position and their distance is cached 5 s (fishing.lua extras_ttl_s), so a
    spot is kept by id at his own position within its distance plus how far he moved in those 5 s."""
    t = [0.0]
    m = mm.MapMemory(tmp_path / "m.json", clock=lambda: t[0], debounce_s=1e9)
    row = {"name": "Net Fishing Spot", "id": NET, "distance_m": 4.5, "level": 2, "method": "net"}
    m.observe({"position": [151.42, 1912.1, -31.6], "fishing_spots_nearby": [row]})
    assert not m.sightings  # the first read: how old the distance is cannot be known yet
    t[0] = 3.0
    m.observe({"position": [152.42, 1912.1, -31.6], "fishing_spots_nearby": [row]})
    assert not m.sightings
    t[0] = 6.0
    m.observe({"position": [152.42, 1912.1, -31.6], "fishing_spots_nearby": [row]})
    rec = m.sightings[f"fishing_spot|{NET}"]
    assert rec["position"] == [152.42, 1912.1, -31.6] and rec["extra"]["within_m"] == 5.5  # 4.5 + the 1 m he moved
    assert rec["class"] == "BP_FishingNodeV2_Net_Brynmoor_C" and rec["extra"]["method"] == "net"
    t[0] = 12.0  # standing in it: the fix tightens
    m.observe({"position": [150.0, 1909.0, -31.6], "fishing_spots_nearby": [{**row, "distance_m": 0.8}]})
    t[0] = 18.0
    m.observe({"position": [150.0, 1909.0, -31.6], "fishing_spots_nearby": [{**row, "distance_m": 0.8}]})
    assert rec["position"][:2] == [150.0, 1909.0] and rec["extra"]["within_m"] == 0.8
    t[0] = 21.0  # a respawn 500 m off with the cached row: no fix, the old one stays
    m.observe({"position": [460.7, 1607.4, 0.0], "fishing_spots_nearby": [{**row, "distance_m": 0.8}]})
    assert rec["position"][:2] == [150.0, 1909.0] and rec["extra"]["within_m"] == 0.8
    t[0] = 24.0  # a row with its own position (when the body sends one) is exact
    m.observe({"position": [460.7, 1607.4, 0.0], "fishing_spots_nearby": [{**row, "position": [149.5, 1910.0, -32.0]}]})
    assert rec["position"] == [149.5, 1910.0, -32.0] and rec["extra"]["within_m"] == 0.0
    assert rec["count_seen"] == 5  # every read once it was kept (from t 6)
    m.flush()
    again = mm.MapMemory(tmp_path / "m.json", clock=lambda: t[0])
    assert again.sightings[f"fishing_spot|{NET}"]["position"] == [149.5, 1910.0, -32.0]  # kept by id across loads


def test_fishing_row_with_position_is_used_exactly_from_the_first_read(tmp_path):
    """fishing.lua's rows now carry the node's own position (U.to_wire(U.loc(node)): [x,y,z] metres). Such a row is
    kept on the first read, at that position exactly, and no later position-less row or distance fix moves it."""
    t = [0.0]
    m = mm.MapMemory(tmp_path / "m.json", clock=lambda: t[0], debounce_s=1e9)
    rows = [{"name": "Net Fishing Spot", "id": NET, "distance_m": 4.5, "level": 2, "method": "net",
             "position": [149.53, 1910.07, -32.0]},
            {"name": "Rod Fishing Spot", "id": ROD, "distance_m": 21.3, "level": 2, "method": "rod",
             "position": [170.2, 1905.88, -33.41]}]
    m.observe({"position": [151.42, 1912.1, -31.6], "fishing_spots_nearby": rows})
    net, rod = m.sightings[f"fishing_spot|{NET}"], m.sightings[f"fishing_spot|{ROD}"]
    assert net["position"] == [149.53, 1910.07, -32.0] and net["extra"]["within_m"] == 0.0
    assert rod["position"] == [170.2, 1905.88, -33.41] and rod["extra"]["within_m"] == 0.0
    assert net["extra"]["method"] == "net" and rod["extra"]["method"] == "rod" and net["count_seen"] == 1
    for k in range(1, 4):  # later rows without a position (an older body) give only looser fixes: the exact one stays
        t[0] = 3.0 * k
        m.observe({"position": [150.0, 1909.0, -31.6], "fishing_spots_nearby": [{**rows[0], "position": None,
                                                                              "distance_m": 0.8}]})
    assert net["position"] == [149.53, 1910.07, -32.0] and net["extra"]["within_m"] == 0.0
    assert net["count_seen"] == 4
    m.flush()
    again = mm.MapMemory(tmp_path / "m.json", clock=lambda: t[0])
    assert again.sightings[f"fishing_spot|{ROD}"]["position"] == [170.2, 1905.88, -33.41]


def test_catch_per_province_from_the_wiki_pages_split_and_the_spot_facts():
    from brain import fishing_facts as ff
    net, rod = ff.catch_tables("Net Fishing Spot"), ff.catch_tables("Rod Fishing Spot")
    # the page's own "===<Province>===" headings (rev 66829 / 74795): the flattened sections lose them, wikitext keeps them
    assert list(net) == ["Brynmoor", "Ghornfell", "Fellhollow", "Dowdun Reach", "Umbral Sands"] == list(rod)
    assert [(r["name"], r["qty"], r["chance"]) for r in net["Brynmoor"]] == [
        ("Raw Shrimp", 1, 0.6), ("Raw Shrimp", 2, 0.3), ("Raw Shrimp", 3, 0.1)]
    assert {r["name"] for r in net["Ghornfell"]} == {"Raw Anchovies"}
    assert [r["name"] for r in rod["Brynmoor"]] == ["Raw Sardine", "Raw Trout", "Pristine Sardine", "Pristine Trout"]
    assert ff.catch("Rod Fishing Spot", "Brynmoor")[1] == "wiki Rod Fishing Spot rev 74795"
    assert ff.catch("Net Fishing Spot", None) is None and ff.catch("Net Fishing Spot", "Nowhere") is None
    assert ff.spot_prose("Net Fishing Spot") == {"src": "wiki Net Fishing Spot rev 66829", "catches": "10-15",
                                                  "respawn": "72 in-game hours"}
    assert ff.spot_prose("Rod Fishing Spot")["gates"] == [("Fishing", 17, "catch a pristine one")]
    assert "catches" not in ff.spot_prose("Rod Fishing Spot")  # the rod page gives no count: none is claimed
    # where: the map region at its position; without one, the province its class names (map data's province names)
    assert ff.where([113.0, 1850.0]) == {"region": "Temple Woods", "province": "Brynmoor", "by": "position"}
    assert ff.where(None, ff.class_of(ROD)) == {"province": "Brynmoor", "by": "class"}
    assert ff.where(None, "BP_FishingNodeV2_Net_C") == {}


def test_the_tool_a_spot_needs_by_category_tag_and_the_recipe_that_makes_one():
    from brain import fishing_facts as ff
    st = l3()  # recipes_unlocked has RECIPE_Tool_FishingNet_Coarse and RECIPE_Tool_FishingRod_Ash
    cat = supplies._cat()
    assert ff.tool_words(st, "net", cat) == "net: none on you; Coarse Net from 2 Coarse Thread at a Crafting Table (unlocked)"
    st["skills"] = [{"skill": "Fishing", "level": 1, "xp": 0}]
    st["recipes_unlocked"] = [r for r in st["recipes_unlocked"] if "FishingRod" not in r]
    # the gate is the recipe's own unlock query: "ALL ITEMS[ Ash Logs, Coarse Thread ] AND SKILL LEVEL 3[ Fishing ]"
    assert ff.tool_words(st, "rod", cat) == ("rod: none on you; Ash Rod from Ash Logs, Coarse Thread at a Crafting Table "
                                             "(needs Fishing 3, you are 1; not unlocked)")
    st["inventory_items"].append({"where": "bag", "name": "Coarse Net", "item": "ITEM_FishingNet_CoarseNet", "count": 1,
                                  "category": "Item.Equipment.Tool.Fishing.Net"})
    assert ff.tool_words(st, "net", cat) == "net: Coarse Net on you"
    assert ff.tool_words(st, "rod", cat).startswith("rod: none on you")  # a net does not fit a rod spot's tag


def test_sources_line_fixture_with_a_net_and_a_rod_spot_near_113_1850(tmp_path):
    m, t = fishing_memory(tmp_path)
    st = l3()
    st["skills"] = [{"skill": "Fishing", "level": 3, "xp": 80}, {"skill": "Cooking", "level": 15, "xp": 1051}]
    mm.annotate(st, m)
    rows = [(r["name"], r["kind"], r["province"], r["region"], r["distance"], r.get("within"), r.get("direction"))
            for r in st["food_sources"]]
    assert rows == [("Net Fishing Spot", "fish", "Brynmoor", "Temple Woods", 73, 1, "NW"),
                    ("Rod Fishing Spot", "fish", "Brynmoor", "Temple Woods", 73, 9, "NW")]
    line = supplies.sources_line(st)
    assert line.startswith("food and water you have seen (nearest first, as seen then): Net Fishing Spot ~73 m (±1 m) "
                           "NW, Brynmoor, seen 10 min ago (Raw Shrimp x1-3 -> at a fire (not unlocked): Sauteed Shrimp "
                           "heals 20, +10 food, 2 HP per food, 40 HP/kg; at a Cooking Range or Stone Range (not unlocked): "
                           "Shrimp Omelette (+Fried Egg) heals 50, +15 food, 3.3 HP per food, 71 HP/kg; net: none on you; "
                           "Coarse Net from 2 Coarse Thread at a Crafting Table (unlocked))")
    assert ("Rod Fishing Spot ~73 m (±9 m) NW, Brynmoor, seen 10 min ago (Raw Sardine, Raw Trout, Pristine Sardine 1.5%, "
            "Pristine Trout 1.5% -> at a fire (not unlocked): Fried Sardine heals 30, +15 food, 2 HP per food, 60 HP/kg; "
            "Grilled Trout heals 40, +15 food, 2.7 HP per food, 57 HP/kg; at a Cooking Range or Stone Range (not "
            "unlocked): Sauteed Sardines (+Dried Redberries) heals 70, +25 food, 2.8 HP per food, 100 HP/kg; Herb Baked "
            "Trout (+Baked Potato) heals 100, +35 food, 2.9 HP per food, 143 HP/kg; rod: none on you; Ash Rod from Ash "
            "Logs, Coarse Thread at a Crafting Table (needs Fishing 3, you are 3; unlocked))") in line
    assert line.endswith("| fishing (wiki Net Fishing Spot rev 66829: 10-15 catches a spot, each fish or junk, respawn 72 "
                         "in-game hours after it runs out; Rod Fishing Spot rev 74795: Fishing 17 to catch a pristine one "
                         "(you are 3))")
    assert len(line) <= supplies.SOURCES_CHARS and not ADVICE.search(line)
    assert line in supplies.lines(st)


def test_spots_in_sight_without_a_fix_still_show_with_the_live_distance_and_no_direction(tmp_path):
    """The real L3 state's rows on the first read: no fix yet, so no direction; the province from the class."""
    st = l3()
    st["fishing_spots_nearby"] = [dict(r) for r in IN_SIGHT]
    m = mm.MapMemory(tmp_path / "m.json", clock=lambda: 100.0, debounce_s=1e9)
    m.observe(st)
    mm.annotate(st, m)
    fish = [(r["name"], r["n"], r["distance"], r.get("direction"), r["province"], r["in_sight"])
            for r in st["food_sources"] if r["kind"] == "fish"]
    assert fish == [("Net Fishing Spot", 2, 4, None, "Brynmoor", True), ("Rod Fishing Spot", 1, 21, None, "Brynmoor", True)]
    line = supplies.sources_line(st)
    assert "Net Fishing Spot x2 4 m, Brynmoor, seen just now (Raw Shrimp x1-3 -> " in line
    assert "Rod Fishing Spot 21 m, Brynmoor, seen just now (Raw Sardine, Raw Trout" in line


def test_the_nearest_fishing_spot_is_kept_when_nearer_sources_fill_the_rows(tmp_path):
    m, t = fishing_memory(tmp_path)
    me = [151.42, 1912.1, -31.6]  # back at the L3 spot, 73 m from both fishing spots
    m.observe({"position": me, "nearby_resources": [
        {"name": "Redberry Bush", "item": "ITEM_Consumable_Fruit_Redberry", "position": [153.0, 1912.0, -31.0]}],
        "nearby_entities": [{"name": "Chicken", "id": "C1", "position": [151.0, 1911.0, -31.0]}]})
    got = supplies.sources(list(m.sightings.values()), me, t[0], n=2)
    assert [g["kind"] for g in got] == ["creature", "fish"]  # the Redberry Bush gives way, the nearest spot stays
    # whole rows only: a row that would pass SOURCES_CHARS is left out, never cut in the middle
    st = {**l3(), "position": me, "food_sources": supplies.sources(list(m.sightings.values()), me, t[0])}
    line = supplies.sources_line(st)
    assert len(line) <= supplies.SOURCES_CHARS and not line.endswith("…")
