"""The job tree of the open ask (brain/job_tree.py): the copper chain expanded by code from game data to full depth,
each node's status from the game state, failures per node, kept on disk with the ask, rendered within a budget.

Why: copper rung V1 stood at 0 of 14 after about 16 changes, 9 of them one true fact added to a tool result per
failure (docs/research/2026-11-18-fix-audit.md); the facts scrolled out, and he took "copper needs a bronze pickaxe
first" (run 20261118-131725) or a Stone Pickaxe (run 145610) for the way. Fixture: a small recipe set shaped like the
game's (data/recipes_<build>.json rows), a stub knowledge (wiki nodes and build-menu costs), a bestiary and Bark to
Bones."""
import json

import pytest

from brain import job_tree as jt


def _r(rid, out, ins, stations, n=1):
    return {"id": rid, "outputs": [{"item": out[0], "name": out[1], "count": n}],
            "inputs": [{"item": i, "name": nm, "count": c} for i, nm, c in ins], "stations": stations}


ORE, TIN, BAR = ("ITEM_Resources_CopperOre", "Copper Ore"), ("ITEM_Resources_TinOre", "Tin Ore"), \
    ("ITEM_Resources_BronzeBar", "Bronze Bar")
BONE, ASH, LEATHER = ("ITEM_Resources_AnimalBone", "Animal Bone"), ("ITEM_Resources_Wood_Ash", "Ash Logs"), \
    ("ITEM_Resources_Leather", "Leather")
HIDE, SCRAPS = ("ITEM_Resources_Animal_Hide", "Animal Hide"), ("ITEM_Resources_Skin_Scraps", "Animal Hide Scraps")
THREAD, FUR, FLAX = ("ITEM_Resources_Thread_Coarse", "Coarse Thread"), \
    ("ITEM_Resources_Coarse_Animal_Fur", "Coarse Animal Fur"), ("ITEM_Resources_Flax", "Flax")
STONE, OAK, CHIT = ("ITEM_Resources_Stone", "Stone"), ("ITEM_Resources_Wood_Oak", "Oak Logs"), \
    ("ITEM_Chit", "Garou Chit")
P_BONE, P_STONE, P_BRONZE = ("ITEM_Pickaxe_Bone", "Bone Pickaxe"), ("ITEM_Pickaxe_Stone", "Stone Pickaxe"), \
    ("ITEM_Pickaxe_Bronze", "Bronze Pickaxe")

RECIPES = {r["id"]: r for r in [
    _r("RECIPE_Pickaxe_Bone", P_BONE, [(BONE[0], BONE[1], 8), (ASH[0], ASH[1], 6), (LEATHER[0], LEATHER[1], 4)],
       ["CraftingTable"]),
    _r("RECIPE_Pickaxe_Stone", P_STONE, [(ASH[0], ASH[1], 6), (STONE[0], STONE[1], 8)], ["CraftingTable"]),
    _r("RECIPE_Pickaxe_Bronze", P_BRONZE, [(BAR[0], BAR[1], 5), (OAK[0], OAK[1], 4), (LEATHER[0], LEATHER[1], 2)],
       ["ToolsMeleeBench"]),
    _r("RECIPE_Process_Leather_From_Hide", LEATHER, [(HIDE[0], HIDE[1], 1)], ["AdvancedTannery", "Tannery"]),
    _r("RECIPE_Process_Leather_From_scraps", LEATHER, [(SCRAPS[0], SCRAPS[1], 3)], ["AdvancedTannery", "Tannery"]),
    _r("RECIPE_Thread_From_Fur", THREAD, [(FUR[0], FUR[1], 3)], ["Spinning Wheel"]),
    _r("RECIPE_Thread_From_Flax", THREAD, [(FLAX[0], FLAX[1], 1)], ["Spinning Wheel"]),
    _r("RECIPE_Process_BronzeBar", BAR, [(ORE[0], ORE[1], 1), (TIN[0], TIN[1], 1)], ["Furnace"], n=2),
    _r("DA_Recipe_Vendor_Buy_Ore_Copper", ORE, [(CHIT[0], CHIT[1], 16)], ["UmS_Merchant_Smith"]),
]}
STATIONS = {"CraftingTable": {"display_name": "Crafting Table"}, "Tannery": {"display_name": "Tannery"},
            "AdvancedTannery": {"display_name": None}, "Spinning Wheel": {"display_name": "Spinning Wheel"},
            "Furnace": {"display_name": "Furnace"}, "ToolsMeleeBench": {"display_name": "Blacksmith's Bench"},
            "UmS_Merchant_Smith": {"display_name": "Beartach"}}
ITEMS = {i: {"name": n} for i, n in [ORE, TIN, BAR, BONE, ASH, LEATHER, HIDE, SCRAPS, THREAD, FUR, FLAX, STONE, OAK,
                                     CHIT]}
ITEMS.update({P_STONE[0]: {"name": P_STONE[1], "category": "pickaxe", "tier": 1},
              P_BONE[0]: {"name": P_BONE[1], "category": "pickaxe", "tier": 2},
              P_BRONZE[0]: {"name": P_BRONZE[1], "category": "pickaxe", "tier": 3}})
BESTIARY = {
    "dropped_by": {
        "Animal Bone": {"item": "Animal Bone", "rows": [{"from": "Cow", "amount": "2", "rate": "always"},
                                                        {"from": "Deer", "amount": "2", "rate": "always"}]},
        "Animal Hide": {"item": "Animal Hide", "rows": [{"from": "Deer", "amount": "1", "rate": "always"}]},
        "Coarse Animal Fur": {"item": "Coarse Animal Fur", "rows": [{"from": "Giant Rat", "amount": "1",
                                                                    "rate": "always"}]}},
    "creatures": {
        "Deer": {"variants": [{"power_level": "1"}], "locations": ["Temple Woods"], "aggressive": "no",
                 "behaviour": ["Deer can be alerted and will flee if the player is within 50 metres."]},
        "Cow": {"variants": [{"power_level": "2"}], "locations": ["Bramblemead Valley"], "aggressive": "no"},
        "Giant Rat": {"variants": [{"power_level": "1"}], "locations": ["Temple Woods"], "aggressive": "yes"}}}
SPELLS = {"USD_Treequipment": {"name": "Bark to Bones", "cost": {"Earth": 10, "Nature": 10},
                               "requirement": {"text": "Cast on a Tree"}, "unlock": {"skill": "Artisan", "level": 11}}}


class KB:
    NODES = {"copper ore": {"title": "Copper Ore Node", "location": "Fractured Plains, Stormtouched Highlands",
                            "tool": "Bone pickaxe or better"},
             "tin ore": {"title": "Tin Ore Node", "location": "Fractured Plains", "tool": "Bone pickaxe or better"},
             "flax": {"title": "Flax (plant)", "location": "Bramblemead Valley", "tool": None}}
    BUILDS = {"tannery": [("Ash Logs", 12), ("Animal Bone", 4), ("Coarse Thread", 2)],
              "spinning wheel": [("Ash Logs", 12), ("Flax", 4), ("Stone", 2)],
              "crafting table": [("Ash Logs", 4)], "furnace": [("Stone", 24)],
              "blacksmith's bench": [("Bronze Bar", 6), ("Ash Logs", 20)]}

    def node_facts(self, q):
        return self.NODES.get(q.lower())

    def build_facts(self, name):
        cost = self.BUILDS.get(name.lower())
        return {"title": name, "skill": "Construction", "cost": cost, "unlock": None} if cost else None


def data():
    return jt.GameData(recipes=RECIPES, stations=STATIONS, items=ITEMS, knowledge=KB(), bestiary=BESTIARY,
                       spell_makes={"animal bone": ["USD_Treequipment"]}, spells=SPELLS,
                       station_rules={"Spinning Wheel": {"note": "needs a roof"}})


LINE = "claude, we need thirty copper ore in the chest at your base"
BARK = {"name": "Bark to Bones", "castable": True}


def tree(state=None, spells=None, failures=None):
    d = data()
    return jt.build(d, jt.targets_from_words(LINE, d), state or {}, spells, failures)


def find(t, kind, name=None, item=None):
    """Every node of ``kind`` (and ``name`` / ``item``) in tree order."""
    return [n for r in t["roots"] for n, _, _ in jt.walk(r) if n["kind"] == kind
            and (name is None or n["name"] == name) and (item is None or n.get("item") == item)]


def kids(n, kind=None):
    return [c for c in n["children"] if kind is None or c["kind"] == kind]


# ------------------------------------------------------------------ the target and the chain


def test_the_target_is_the_game_item_his_words_name_with_its_count():
    d = data()
    assert jt.targets_from_words(LINE, d) == [{"item": ORE[0], "name": "Copper Ore", "count": 30}]
    two = jt.targets_from_words("put twenty five ash logs and 10 stone in a chest", d)
    assert [(t["name"], t["count"]) for t in two] == [("Ash Logs", 25), ("Stone", 10)]
    assert jt.targets_from_words("make me a bone pickaxe", d) == [{"item": P_BONE[0], "name": "Bone Pickaxe",
                                                                     "count": 1}]
    assert jt.targets_from_words("come here", d) == []


def test_the_copper_chain_from_game_data_and_its_alternatives_side_by_side():
    t = tree()
    root, = t["roots"]
    assert root["name"] == "Copper Ore" and root["need"] == 30 and root["have"] == 0
    ways = {c["kind"] for c in root["children"]}
    assert ways == {"gather", "trade"}  # OR: the node, or the trader
    gather, = kids(root, "gather")
    assert "Fractured Plains" in gather["found_in"]
    tool, = kids(gather, "tool")
    assert tool["name"] == "pickaxe tier 2+" and tool["best"] == "none" and tool["status"] == "blocked"
    alts = [c["name"] for c in kids(tool)]
    assert alts == ["Bone Pickaxe", "Bronze Pickaxe"]  # tier 2 and up, lowest first; not the Stone Pickaxe (tier 1)
    craft, = find(t, "craft", "craft Bone Pickaxe")
    req = {(c["kind"], c["name"], c.get("need")) for c in kids(craft)}
    assert req == {("item", "Animal Bone", 8), ("item", "Ash Logs", 6), ("item", "Leather", 4),
                   ("station", "Crafting Table", None)}  # AND: every input and the station
    leather = next(c for c in kids(craft) if c["name"] == "Leather")
    assert sorted(c["recipe"] for c in kids(leather, "craft")) == ["RECIPE_Process_Leather_From_Hide",
                                                                  "RECIPE_Process_Leather_From_scraps"]
    tannery = find(t, "station", "Tannery")[0]
    assert tannery["build"] and {(c["name"], c["need"]) for c in kids(tannery)} == {
        ("Ash Logs", 12), ("Animal Bone", 4), ("Coarse Thread", 2)}
    wheel = find(t, "station", "Spinning Wheel")[0]
    assert wheel["rule"] == "needs a roof"
    bone = next(c for c in kids(craft) if c["name"] == "Animal Bone")
    assert [c["name"] for c in kids(bone, "spell")] == ["Bark to Bones"]
    assert {c["name"] for c in kids(bone, "drop")} == {"Cow", "Deer"}
    deer = find(t, "drop", "Deer")[0]
    assert "flee" in deer["behaviour"]


def test_the_bronze_way_needs_the_copper_it_is_for():
    t = tree()
    cyc = [n for n in find(t, "item", item=ORE[0]) if n["status"] == "cycle"]
    assert cyc and cyc[0]["need"] == 3  # 5 bronze bars, 2 a craft: 3 crafts of 1 copper ore each
    assert jt.needs_itself(t) == ["Bronze Pickaxe 0/1 <- Bronze Bar 0/5 <- Copper Ore 0/3"]


# ------------------------------------------------------------------ status from the game state


V1 = {"inventory": {BONE[0]: 9, ASH[0]: 18, FUR[0]: 7, SCRAPS[0]: 7, STONE[0]: 6, P_STONE[0]: 1},
      "stations_nearby": [{"station": "CraftingTable", "name": "Crafting Table", "distance": 23.0}],
      "my_bases": [{"stations": ["Spinning Wheel"], "covered": True, "distance_m": 14, "direction": "SW"}]}


def test_status_is_read_from_the_bag_the_stations_and_his_bases():
    t = tree(V1, [BARK])
    tool = find(t, "tool")[0]
    assert tool["best"] == "Stone Pickaxe (tier 1)" and tool["status"] == "blocked"
    assert find(t, "item", "Animal Bone")[0]["status"] == "done"
    thread = find(t, "craft", "craft Coarse Thread")[0]
    assert thread["status"] == "ready"  # 7 fur of 6, his roofed wheel 14 m away
    assert "at Spinning Wheel (yours 14 m SW, roofed)" in jt._facts(thread)
    tannery = find(t, "station", "Tannery")[0]
    assert tannery["status"] == "blocked"
    assert [c["name"] for c in kids(tannery) if c["status"] != "done"] == ["Coarse Thread"]
    assert find(t, "craft", "craft Bone Pickaxe")[0]["status"] == "blocked"
    v = jt.compact(t)
    assert any(s.startswith("craft Coarse Thread") for s in v["nothing_blocks_now"])
    assert any(s.startswith("craft Bone Pickaxe") and "Leather 0/4" in s for s in v["blocked"])


def test_with_the_leather_the_bone_pickaxe_is_ready_and_with_it_the_ore_is_open():
    s = {**V1, "inventory": {**V1["inventory"], LEATHER[0]: 4}}
    assert find(tree(s), "craft", "craft Bone Pickaxe")[0]["status"] == "ready"
    s = {**V1, "inventory": {**V1["inventory"], P_BONE[0]: 1}}
    t = tree(s)
    tool = find(t, "tool")[0]
    assert tool["status"] == "done" and tool["best"] == "Bone Pickaxe (tier 2)" and not tool["children"]
    gather = find(t, "gather", "gather Copper Ore")[0]
    assert gather["status"] == "open"  # no tool blocks it; no copper rock in sight
    s["nearby_resources"] = [{"name": "Copper Rock", "item": ORE[0], "distance": 12.0}]
    assert find(tree(s), "gather", "gather Copper Ore")[0]["status"] == "ready"


def test_a_wheel_of_his_with_no_roof_blocks_it_and_the_gate_he_sees_beats_the_wiki():
    s = {**V1, "stations_nearby": V1["stations_nearby"] + [{"station": "Spinning Wheel", "distance": 3.0}],
         "my_bases": [{"stations": ["Spinning Wheel"], "covered": False, "distance_m": 3, "direction": "N"}]}
    wheel = find(tree(s), "station", "Spinning Wheel")[0]
    assert wheel["status"] == "blocked" and wheel["blocker"] == "no roof over yours"
    s = {**V1, "nearby_resources": [{"name": "Copper Rock", "item": ORE[0], "tool": "pickaxe", "tool_tier": 3}]}
    gather = find(tree(s), "gather", "gather Copper Ore")[0]
    assert gather["tool_from"].startswith("the node's own gate") and kids(gather)[0]["name"] == "pickaxe tier 3+"


def test_spell_status_his_or_not():
    bark = find(tree({}, [BARK]), "spell")[0]
    assert bark["status"] == "ready" and bark["his"] == "yours, castable now"
    bark = find(tree({}, []), "spell")[0]
    assert bark["status"] == "blocked" and "Artisan 11" in bark["his"]
    bark = find(tree({"spells": [{"name": "Bark to Bones", "castable": False, "reason": "on cooldown"}]}), "spell")[0]
    assert bark["status"] == "blocked" and "on cooldown" in bark["his"]


def test_a_claim_is_not_state():
    """He said "I have the bone pickaxe": nothing he says is read; only the bag is."""
    k = jt.Keeper(data)
    k.open(("Luis", LINE))
    t = k.tree({"inventory": {}, "said": "I made a Bone Pickaxe"})
    assert find(t, "tool")[0]["status"] == "blocked"


# ------------------------------------------------------------------ failures and the disk


def test_failures_are_kept_on_their_nodes_the_last_two():
    k = jt.Keeper(data, wall=lambda: 1000.0)
    k.open(("Luis", LINE))
    k.tree(V1)
    assert k.record("gather", {"resource": "copper", "count": 30}, True, None, None) == []  # an ok is no failure
    for why in ("nothing_in_range", "wrong_tool", "path_blocked"):
        ids = k.record("gather", {"resource": "copper", "count": 30}, False, why, f"detail {why}")
    assert ids == [f"gather:{ORE[0]}"]
    assert [f["reason"] for f in k.failures[ids[0]]] == ["wrong_tool", "path_blocked"]
    deer = k.record("attack", {"target": "BP_AI_Deer_Character_03_C_2147464711"}, False, "too_far",
                    "the Deer keeps moving away faster than I can catch it")
    assert deer and all(i.startswith("drop:Deer:") for i in deer)
    v = k.compact_view(V1)
    assert any("path_blocked" in s for s in v["failed_lately"]) and any("Deer" in s for s in v["failed_lately"])
    full = k.full_view(V1)
    assert "| failed: gather wrong_tool" in full and "gather path_blocked" in full


def test_the_job_survives_a_restart_beside_the_ask(tmp_path):
    k = jt.Keeper(data, wall=lambda: 1000.0)
    k.dir = tmp_path
    k.open(("Luis", LINE))
    k.tree(V1)
    k.record("craft", {"item": "Bone Pickaxe"}, False, "missing_materials", "I need 4 Leather and I have 0")
    rec = json.loads((tmp_path / jt.FILE).read_text(encoding="utf-8"))
    assert rec["ask"] == ["Luis", LINE] and rec["targets"][0]["count"] == 30 and rec["tree"]["roots"]
    new = jt.Keeper(data)
    assert new.attach(tmp_path, ("Luis", LINE))
    assert new.targets == k.targets and new.failures == k.failures
    assert find(new.tree(V1), "craft", "craft Bone Pickaxe")[0]["failed"][0]["reason"] == "missing_materials"
    assert not jt.Keeper(data).attach(tmp_path, ("Luis", "something else"))  # another ask: not this job
    new.close()
    assert not (tmp_path / jt.FILE).exists()


# ------------------------------------------------------------------ what is shown


def test_render_sizes_and_data_only_words():
    t = tree(V1, [BARK])
    v = jt.compact(t)
    full = jt.full_text(t)
    assert jt.size(v) < 1100, jt.size(v)
    assert len(v.get("nothing_blocks_now", [])) <= jt.COMPACT_READY and len(v["blocked"]) <= jt.COMPACT_BLOCKED
    assert all(len(s) <= jt.COMPACT_LINE + 40 for k in ("nothing_blocks_now", "blocked") for s in v.get(k, []))
    assert "or: craft Leather" in full and "or: Bronze Pickaxe" in full
    assert jt.size(v) < len(full) < 9000
    words = (json.dumps(v) + full).lower()
    for w in ("you should", "must ", " try ", "first,", "next step", "instead"):
        assert w not in words, w


def test_the_flag_is_off_by_default():
    assert not jt.enabled({}) and not jt.enabled({"DW_JOB_TREE": "0"}) and jt.enabled({"DW_JOB_TREE": "1"})


# ------------------------------------------------------------------ the agent with the flag on


@pytest.fixture
def tree_on(monkeypatch):
    monkeypatch.setenv("DW_JOB_TREE", "1")
    monkeypatch.setattr(jt.GameData, "default", classmethod(lambda cls, knowledge=None, places=None: data()))


def test_the_agent_shows_the_tree_in_the_facts_place_and_keeps_it_with_the_ask(tmp_path, tree_on):
    from conftest import Rig

    from brain.interface import CommandReceived
    from brain.llm import FakeLLM
    rig = Rig(tmp_path / "a")
    wd = tmp_path / "state" / "worlds" / "dev_x"
    rig.agent.attach_ask_store(wd)
    rig.controller_llm.push(FakeLLM.say(""), FakeLLM.say(""), FakeLLM.say(""))
    rig.agent._command(CommandReceived(player="Luis", text=LINE))
    first = json.loads(rig.controller_llm.calls[0]["messages"][1]["content"])
    o = first["open_request"]
    assert o["words"] == LINE and "known_facts" not in o
    assert o["job_tree"]["target"][0].startswith("Copper Ore: you carry 0 of 30")
    assert (wd / jt.FILE).exists()
    shown = [r for r in rig.log.read_all() if r.get("kind") == "job_tree_shown"]
    assert shown and shown[0]["where"] == "turn"
    new = Rig(tmp_path / "b")
    new.agent.attach_ask_store(wd)
    assert new.agent.jobs.active(("Luis", LINE)) and new.agent.jobs.targets[0]["count"] == 30


def test_flag_off_no_tree(tmp_path, monkeypatch):
    monkeypatch.delenv("DW_JOB_TREE", raising=False)
    from conftest import Rig
    rig = Rig(tmp_path / "a")
    assert rig.agent.jobs is None and rig.agent.controller.job_view is None


def test_a_thing_met_again_under_its_own_first_place_builds_over_the_repo_data():
    """A ref whose first place is an ancestor still being walked (Leather under the Tannery under Leather) has no
    status yet: read through status(), not the node (KeyError 'status' made every L1 and L2 ask get no tree,
    offline 2026-11-18 23:35Z)."""
    from brain.knowledge import open_knowledge
    data = jt.GameData.default(knowledge=open_knowledge())
    for words in ("put 30 copper ore in my chest", "make me a leather cowl, leather body and leather chaps and wear them"):
        t = jt.build(data, jt.targets_from_words(words, data), {})
        seen, todo = 0, list(t.get("roots") or t.get("children") or [])
        while todo:
            n = todo.pop()
            seen += 1
            assert n.get("status"), (words, n.get("id"))
            todo.extend(n.get("children") or [])
        assert seen > 10, words
        jt.full_text(t), jt.compact(t)
