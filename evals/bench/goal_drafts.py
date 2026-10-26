"""DRAFTS of the GOAL-required cases, rev 2 after docs/reviews/2026-10-26-goal-cases-review.md.

Hand-specified by the Eval agent from GOAL.md, the wiki mirror, the catalogs and dev facts, for main's and Luis's review.
Nothing is scored until Luis approves a case and its hash is pinned (goal_targets.json goal_cases.pinned_by_hash).

  .venv\\Scripts\\python.exe -m evals.bench.goal_drafts      # writes evals/bench/goal_cases/*.json (status draft)

Rev 2 rules applied to every case (review C1-C10):
- scored chat names no method or answer (C8); forbid_terms list the answer words (C9);
- every predicate reads harness evidence (probe / dev referee); missing evidence is a perception gap, never a pass;
- kills, damage and delivery are attributed to him (C1, C3); gathering is proven by XP, crafting by Artisan XP;
- controls: alt_means / wrong_action / partial per case, with `na` reasons; a dev oracle named `scripted:<file>`
  (evals/bench/oracles/, written when the case is validated on dev);
- open questions for Luis are in docs/proposals/2026-10-26-goal-targets-changes.md.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

from .spec import Case, dump_cases

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "evals" / "bench" / "goal_cases"
WIKI = "https://dragonwilds.runescape.wiki/w/"
P = "Tester"  # the harness's test-player body on dev (review C4; spawn_tester, pending verification)
RUNT = "BP_AI_RuntGoblin_Character_C"
VELGAR = "BP_AI_DragonVelgar_Character_C"
FIRE = "DamageType.Magical.Fire"
DEATH_GUARD = {"no_event": {"kind": "death", "who": "self"}}
# a brand-new dev character per case (main 2026-10-26, route A; evals/bench/devchar.py): M3 and capstone stage 1
FRESH = {"state_snapshot": "fresh_dev_v1", "character": "fresh"}
NA_ORACLE = {"partial": "one outcome; cutting the oracle short is do_nothing"}


def _c(**kw) -> Case:
    base = {"authored_by": "human", "status": "draft", "targets": ["dev"]}
    base.update(kw)
    return Case.model_validate(base)


def _catalog() -> dict:
    f = sorted((ROOT / "data").glob("items_*.json"))
    return json.loads(f[-1].read_text(encoding="utf-8")).get("items") or {} if f else {}


def entitlement_items() -> list[str]:
    """Data-derived n/a for gear upgrades: items that need an entitlement (review L-11)."""
    return sorted(k for k, v in _catalog().items() if (v.get("requirements") or {}).get("entitlement_required"))


def gear_upgrade_predicate() -> dict:
    """Any armour slot better EQUIPPED, or any weapon/tool category better CARRIED, than at the start (review L-10),
    generated from the catalog's slots and categories (no item names)."""
    cat = _catalog()
    slots = sorted({v.get("slot") for v in cat.values() if v.get("role") == "armour" and v.get("slot") in ("head", "body", "legs")})
    cats = sorted({v.get("category") for v in cat.values() if v.get("role") in ("weapon", "shield")
                   and v.get("category") not in (None, "test")})
    alts = [{"gear_better": {"slot": s, "stat": "power_level", "where": "equipped", "than": "start"}} for s in slots]
    alts += [{"gear_better": {"category": c, "stat": "power_level", "where": "carried", "than": "start"}} for c in cats]
    return {"any": alts}


ORES = ["ITEM_Resources_CopperOre", "ITEM_Resources_TinOre", "ITEM_Resources_IronOre"]  # Brynmoor ores (Luis, 2026-10-26)


def long_tasks() -> list[Case]:
    """Self-directed Brynmoor play (Luis 2026-10-26, goal_targets long_tasks.definitions): nothing is delivered to a
    player; he builds his own base, stations, chests and plots and crafts his own gear. Brynmoor resources only."""
    k3 = {"repeat": 3}
    ent_guard = [{"not": {"have": {"item": i, "at_least": 1}}} for i in entitlement_items()]
    # build is live (capability agent, referee-proved 2026-10-26 14:59:39Z: built piece 26 = Campfire, 6 Stone, +12 XP)
    return [
        _c(id="goal_mining_run_home_chest", tier="T3", family="long_task", long_task="mining_run_home_chest",
           tags={"skills": ["Mining", "Construction"], "evidence": ["referee:built", "referee:container_change", "probe:skills"]},
           chat=[{"text": "set yourself up a proper home with a chest, then go stock it up with ore from round here"}],
           phrasing_heldout="build a base with some storage and fill it with ore, take as many trips as you need",
           forbid_terms=["copper", "tin", "iron", "pickaxe", "lodestone"],
           fixtures={"state_snapshot": "fresh_dev_v1"},
           success={"all": [{"built": {"at_least": 1}},
                            {"deposited": {"items": ORES, "into": "own", "at_least": 40, "trips_at_least": 2}},
                            {"xp_gained": {"skill": "Mining", "at_least": 300}}]},
           guards=[DEATH_GUARD],
           controls={"alt_means": [{"setup": "grant", "item": "ITEM_Resources_CopperOre", "count": 40},
                                   {"note": "then deposit them: Mining XP and the trips must fail it"}],
                     "partial": [{"note": "one trip only"}], "na": {"wrong_action": "n/a"}},
           limits={"wall_s": 7200, "hints_max": 1, "idle_s": 300, **k3},
           hints={"ladder": ["how's the base coming along?", "you'll want a chest at home and a pickaxe",
                             "there's copper and tin around the valley, iron further out"]},
           oracle={"dev": "scripted:home_chest_mining_v1"},
           provenance={"definition": "goal_targets long_tasks.definitions.mining_run_home_chest",
                       "notes": ["Mining XP threshold 300 is a placeholder: calibrate on dev",
                                 "his chest = a container that did not exist at referee start (built in the case)"]}),
        _c(id="goal_farm_mob_drop", tier="T3", family="long_task", long_task="farm_mob_drop",
           tags={"uses": ["weakness"], "evidence": ["referee:damage.by", "referee:damage.damage_type", "referee:death.by",
                                                    "referee:container_change"]},
           chat=[{"text": "farm 20 goblin packs off the goblin runts and keep them at home"}],
           forbid_terms=["fire", "burn", "weak", "flame"],
           fixtures={"state_snapshot": "fresh_dev_v1"},
           success={"all": [{"killed": {"kind": "Goblin Runt", "kind_id": RUNT, "at_least": 20}},
                            {"damage_type_dealt": {"target_kind_id": RUNT, "types": [FIRE], "min_share": 0.6}},
                            {"any": [{"deposited": {"items": ["ITEM_Consumable_GoblinPack"], "into": "own", "at_least": 20}},
                                     {"have": {"item": "ITEM_Consumable_GoblinPack", "at_least": 20}}]}]},
           guards=[DEATH_GUARD],
           needs_fact={"kind": "weakness", "truth": "Fire"},
           controls={"alt_means": [{"setup": "grant", "item": "ITEM_Consumable_GoblinPack", "count": 20}],
                     "wrong_action": [{"note": "the oracle with a non-fire weapon"}], "partial": [{"note": "19 packs"}], "na": {}},
           limits={"wall_s": 5400, "hints_max": 1, "idle_s": 240, **k3},
           hints={"ladder": ["how's the farming going?", "check what they're weak to", "fire works on them"]},
           oracle={"dev": "scripted:runt_farm_fire_v1"},
           provenance={"definition": "goal_targets long_tasks.definitions.farm_mob_drop", "sources": [WIKI + "Goblin_Runt"]}),
        _c(id="goal_gear_upgrade_self_initiated", tier="T3", family="long_task", long_task="gear_upgrade_self_initiated",
           tags={"evidence": ["probe:gear", "referee:craft"]},
           chat=[{"text": "go level up and sort yourself out, I'll be back in a bit"}],
           forbid_terms=["gear", "armour", "armor", "weapon", "pickaxe", "upgrade", "craft", "smelt", "bronze", "iron"],
           fixtures={"state_snapshot": "fresh_dev_v1"},
           success={"all": [gear_upgrade_predicate(), {"crafted": {"roles": ["armour", "weapon", "shield", "tool"], "at_least": 1}},
                            {"xp_gained": {"skill": "Artisan", "at_least": 1}}]},
           guards=ent_guard + [DEATH_GUARD],
           controls={"alt_means": [{"setup": "grant", "item": "ITEM_Armour_T3_Body_BronzeMed", "count": 1},
                                   {"note": "a given item must fail: no craft by him"}],
                     "partial": [{"note": "crafts the better item but never equips or carries it"}], "na": {}},
           limits={"wall_s": 7200, "hints_max": 1, "idle_s": 300, **k3},
           hints={"ladder": ["how's it going?", "your kit's pretty basic", "a bronze pickaxe or some bronze armour would help"]},
           oracle={"dev": "scripted:bronze_upgrade_v1"},
           provenance={"definition": "goal_targets long_tasks.definitions.gear_upgrade_self_initiated",
                       "notes": ["start gear: Adventurer's T1 body + legs (probe)", "entitlement items excluded (data-derived)",
                                 "crafted 'any gear' = a referee craft by him whose recipe outputs an armour/weapon/tool item"]}),
        _c(id="goal_brynmoor_quest_chain", tier="T3", family="long_task", long_task="brynmoor_quest_chain",
           tags={"evidence": ["probe:quests"]},
           chat=[{"text": "let's do the Brynmoor quests, start with Goblin Diplomacy"}],
           forbid_terms=["Zanik", "wiki", "Rune Mysteries"],
           fixtures={"state_snapshot": "fresh_dev_v1"},
           success={"all": [{"quest": {"name": "Rune Mysteries", "completed": True}},
                            {"quest": {"name": "Goblin Diplomacy", "completed": True}}]},
           guards=[DEATH_GUARD],
           needs_fact={"kind": "quest_step", "truth": "Rune Mysteries first; Zanik on the ridge in Bramblemead Valley"},
           controls={"partial": [{"note": "Rune Mysteries only"}], "na": {"alt_means": "quest state has no other means",
                                                                      "wrong_action": "no sibling quest action"}},
           limits={"wall_s": 7200, "hints_max": 1, "idle_s": 300, **k3},
           hints={"ladder": ["how far along are you?", "Goblin Diplomacy needs Rune Mysteries done first",
                             "Zanik is on the ridge in Bramblemead Valley, over the Whispering Swamp"]},
           oracle={"dev": "scripted:quest_chain_v1"},
           provenance={"definition": "goal_targets long_tasks.definitions.brynmoor_quest_chain",
                       "sources": [WIKI + "Goblin_Diplomacy", WIKI + "Rune_Mysteries", WIKI + "Quests"]}),
        _c(id="goal_farm_and_process_crop", tier="T3", family="long_task", long_task="farm_and_process_crop",
           tags={"skills": ["Farming", "Artisan", "Cooking"], "evidence": ["referee:built", "referee:planted", "referee:harvested",
                                                                          "referee:craft"]},
           chat=[{"text": "get a little farm going at home and bake us some bread from what you grow"}],
           phrasing_heldout="grow your own wheat and turn it into bread",
           forbid_terms=["plot", "seed", "grinder", "kiln", "flour", "ground wheat"],
           # Luis 2026-10-26 (b): start from a snapshot with the recipes and quests unlocked but NOTHING built (he must
           # build his own plots and stations); the case measures farming + processing, not the whole tech tree
           fixtures={"state_snapshot": "farm_v1", "character": "snapshot:farm_v1"},
           success={"all": [{"built": {"at_least": 1}}, {"planted": {"at_least": 1}}, {"harvested": {"at_least": 1}},
                            {"crafted": {"item": "ITEM_Resources_Ground_Wheat", "at_least": 1}},
                            {"crafted": {"item": "ITEM_Consumable_Bread", "at_least": 1}},
                            {"xp_gained": {"skill": "Farming", "at_least": 1}}]},
           guards=[DEATH_GUARD],
           controls={"alt_means": [{"setup": "grant", "item": "ITEM_Resources_Wheat", "count": 5},
                                   {"note": "bread from given wheat: no planting/harvest -> must fail"}],
                     "partial": [{"note": "harvest but never process"}], "na": {"wrong_action": "n/a"}},
           limits={"wall_s": 7200, "hints_max": 1, "idle_s": 900, **k3},
           hints={"ladder": ["how's the farm?", "you'll need somewhere to plant and some seeds",
                             "wheat goes through a grinder, then the kiln makes bread"]},
           oracle={"dev": "scripted:wheat_bread_v1"},
           provenance={"definition": "goal_targets long_tasks.definitions.farm_and_process_crop",
                       "recipes": ["RECIPE_Process_Ground_Wheat (Grinder, Artisan)", "RECIPE_Consumable_Bread_From_Flour (Kiln, Cooking)"],
                       "notes": ["idle_s 900: crop stage times to be measured on dev"]}),
    ]


def foods() -> list[str]:
    """Every food item (catalog category Item.Food): data-derived, so the leaf credits whatever food he made or found."""
    f = sorted((ROOT / "data").glob("recipes_*.json"))
    items = (json.loads(f[-1].read_text(encoding="utf-8")).get("items") or {}) if f else {}
    return sorted(k for k, v in items.items() if v.get("category") == "Item.Food")


def quick(main: Case, *, setup: list[dict], chat: list[dict] | None = None, wall_s: int | None = None,
          note: str = "") -> Case:
    """The quick variant of a main case (Luis 2026-10-26): grants that isolate the one skill, for development only.
    Tagged quick and never counted for GOAL (goal_check drops variant=quick)."""
    d = main.model_dump(by_alias=True)
    d.update(id=main.id + "_quick", variant="quick", tier="T1",
             tags={**(main.tags or {}), "quick": True},
             fixtures={**d["fixtures"], "setup": setup, "state_snapshot": "empty"},
             provenance={**(main.provenance or {}), "variant": f"quick of {main.id}: {note}".rstrip(": ")})
    if chat is not None:
        d["chat"] = chat
    if wall_s is not None:
        d["limits"] = {**d["limits"], "wall_s": wall_s}
    return Case.model_validate(d)


def combat_basics() -> list[Case]:
    """Main variants grant NO items (Luis 2026-10-26): the chat states the end objective and his Director must plan
    the prerequisites (a shield from logs, food) and do them. Spawned creatures are the scene, not a grant; they stand
    40 m off so preparing is possible. Each grant-using case has a `_quick` twin for isolating the skill."""
    r3 = {"repeat": 3}
    FOOD = foods()
    dodge = _c(id="goal_basic_dodge_directional", tier="T1", family="combat_basic", basic="dodge_directional",
               tags={"evidence": ["referee:defended", "referee:telegraph"]},
               chat=[{"text": "watch out for its big swings"}], forbid_terms=["dodge", "roll", "evade"],
               fixtures={"setup": [{"verb": "spawn", "as": "foe", "class": RUNT, "offset_m": [6, 0, 0]}],
                         "state_snapshot": "fresh_dev_v1"},
               success={"defended": {"kind": "dodge", "against": "telegraph", "at_least": 3, "min_rate": 0.5}},
               guards=[DEATH_GUARD],
               controls={"alt_means": [{"note": "walk out of range: attacks miss, no dodge"}],
                         "wrong_action": [{"note": "block instead of dodging"}], "na": NA_ORACLE},
               limits={"wall_s": 300, "idle_s": 60, **r3}, oracle={"dev": "scripted:dodge_runt_v1"},
               provenance={"notes": ["no prerequisites: a dodge needs no item, so there is no quick twin",
                                     "check on dev that the runt telegraphs >= 3 times in 300 s (no weapon: it survives)"]})
    parry = _c(id="goal_basic_parry", tier="T2", family="combat_basic", basic="parry",
               tags={"evidence": ["referee:defended", "referee:telegraph"],
                     "prerequisites": ["ITEM_Shield_Wood", "Attack 5 (PerkV2_Attack_Parry)"]},
               chat=[{"text": "let's practise parrying on those goblins over there"}],
               forbid_terms=["shield", "log", "wood", "craft", "make", "block"],
               fixtures={"setup": [{"verb": "spawn", "as": "foe", "class": RUNT, "offset_m": [40, 0, 0]}],
                         "state_snapshot": "fresh_dev_v1"},
               success={"defended": {"kind": "parry", "at_least": 3, "min_rate": 0.4}}, guards=[DEATH_GUARD],
               controls={"wrong_action": [{"note": "hold block the whole time"}],
                         "partial": [{"note": "makes the shield, never parries"}],
                         "na": {"alt_means": "no other means of a parry"}},
               limits={"wall_s": 5400, "idle_s": 300, "hints_max": 1, **r3},
               hints={"ladder": ["how's the practice going?", "you'll want something to parry with, and the know-how",
                                 "ten ash logs make a wooden shield; parrying comes with Attack 5"]},
               oracle={"dev": "scripted:parry_runt_v1"},
               provenance={"source": WIKI + "Wooden_Shield",
                           "notes": ["parry needs an off-hand shield: RECIPE_Shield_Wood = 10 Ash Logs (recipes catalog)",
                                     "and the PerkV2_Attack_Parry perk at Attack 5 (combat-basics-live.md §1-2): he levels "
                                     "Attack himself first",
                                     "dev fact: the runt at 40 m must not aggro before he engages (measure the aggro radius)"]})
    dis = _c(id="goal_basic_disengage_heal", tier="T2", family="combat_basic", basic="disengage_heal",
             tags={"evidence": ["probe:creatures", "referee:damage.by", "referee:item_change"], "prerequisites": ["food"]},
             chat=[{"text": "let's take on that pack of runts over there, and don't you dare die on me"}],
             forbid_terms=["eat", "food", "run", "retreat", "heal", "cook", "fish", "berr"],
             fixtures={"setup": [{"verb": "spawn", "as": "foe", "class": RUNT, "offset_m": [40, 0, 0]},
                                 {"verb": "spawn", "class": RUNT, "offset_m": [41, 2, 0]},
                                 {"verb": "spawn", "class": RUNT, "offset_m": [41, -2, 0]}],
                       "state_snapshot": "fresh_dev_v1"},
             success={"disengaged": {"target_kind_id": RUNT, "aggro_m": 15, "food": FOOD, "reengaged": True}},
             guards=[DEATH_GUARD],
             controls={"alt_means": [{"note": "eat in place without disengaging"}], "partial": [{"note": "no re-engage"}], "na": {}},
             limits={"wall_s": 1800, "idle_s": 180, "hints_max": 1, **r3},
             hints={"ladder": ["how are you holding up?", "three at once will hurt, have something to fall back on"]},
             oracle={"dev": "scripted:disengage_runts_v1"},
             provenance={"notes": ["food = every catalog Item.Food (data-derived): whatever he cooked, picked or looted",
                                   "measure: does 15 m break runt aggro? do three runts take a fresh character low?"]})
    return [
        dodge, parry,
        quick(parry, setup=[{"verb": "raise_skills", "skills": {"Attack": 5}, "purpose": "quick: the parry perk level"},
                            {"verb": "spawn", "as": "foe", "class": RUNT, "offset_m": [6, 0, 0]},
                            {"verb": "grant", "item": "ITEM_Shield_Wood", "count": 1, "purpose": "quick: isolate the parry"}],
              chat=[{"text": "parry its swings, don't just tank them"}], wall_s=300,
              note="Attack raised to 5 and shield granted, runt at 6 m (check on dev that XP-raised Attack 5 grants the perk)"),
        dis,
        quick(dis, setup=[{"verb": "spawn", "as": "foe", "class": RUNT, "offset_m": [4, 0, 0]},
                          {"verb": "spawn", "class": RUNT, "offset_m": [5, 2, 0]},
                          {"verb": "spawn", "class": RUNT, "offset_m": [5, -2, 0]},
                          {"verb": "grant", "item": "ITEM_Consumable_Fish_Anchovies", "count": 5, "purpose": "quick: food"},
                          {"verb": "set_health", "pct": 40}],
              chat=[{"at_s": 30, "text": "you're getting hammered, sort yourself out"}], wall_s=300,
              note="food granted, health set to 40% so the chat is true when said"),
    ]


def tactics_and_knowledge() -> list[Case]:
    return [
        _c(id="goal_tactics_prep_hard_fight", tier="T2", family="tactics_prep",
           chat=[{"text": "that one over there is nasty, take it out when you're ready"}],
           forbid_terms=["shield", "enchant", "fire", "food", "potion"],
           fixtures={"setup": [{"verb": "spawn", "as": "boss", "class": "<a creature PL >= gear PL + 2 near the start (data)>",
                                "offset_m": [30, 0, 0]}], "state_snapshot": "fresh_dev_v1"},
           success={"prepared": {"target_kind_id": "<the boss class>", "at_least": 2,
                                 "any": [{"tag": "Player.Status.TempestShield"}, {"enchant_type": "<the boss weakness damage type>"},
                                         {"items_any": ["ITEM_Consumable_Fish_Anchovies", "ITEM_Consumable_BerryDrizzle_Pan-Seared"],
                                          "at_least": 3},
                                         {"predicate": {"gear_better": {"slot": "body", "stat": "power_level", "where": "equipped",
                                                                        "than": "start"}}}]}},
           guards=[DEATH_GUARD],
           controls={"partial": [{"note": "fight without preparing"}], "na": {"alt_means": "preparation is the capability"}},
           limits={"wall_s": 1200}, oracle={"dev": "scripted:prep_fight_v1"},
           provenance={"notes": ["GOAL: a dragon-class fight; a runt (PL1) is not hard (review T-1): pick from the data"]}),
        _c(id="goal_tactics_damage_trend", tier="T2", family="tactics_trend",
           chat=[{"text": "keep fighting these until you've got them figured out"}],
           fixtures={"setup": [{"verb": "spawn", "class": "<a creature that hurts a fresh character, with telegraphs>",
                                "offset_m": [8, 0, 0]}], "state_snapshot": "fresh_dev_v1",
                     "respawn_between": {"count": 5, "note": "the next spawn only after the previous died (memory kept in the case)"}},
           success={"killed": {"kind": "<creature>", "kind_id": "<class>", "at_least": 5}}, guards=[DEATH_GUARD],
           controls={"na": {"alt_means": "kills are the capability", "wrong_action": "n/a", "partial": "4 kills"}},
           limits={"wall_s": 1800}, oracle={"dev": "scripted:trend_fights_v1"},
           provenance={"notes": ["process metric: damage_taken per fight (referee damage to self), slope over 5 fights"]}),
        _c(id="goal_tactics_telegraph_dodges", tier="T2", family="tactics_telegraph",
           chat=[{"text": "that thing hits hard, don't let it touch you"}], forbid_terms=["dodge", "dash", "roll", "evade"],
           fixtures={"setup": [{"verb": "spawn", "as": "foe", "class": "<a creature with >= 2 distinct telegraphed attacks>",
                                "offset_m": [10, 0, 0]}], "state_snapshot": "fresh_dev_v1"},
           success={"defended": {"kind": "dodge", "against": "telegraph", "at_least": 5, "min_rate": 0.7}}, guards=[DEATH_GUARD],
           controls={"alt_means": [{"note": "stay out of range"}], "na": NA_ORACLE},
           limits={"wall_s": 600}, oracle={"dev": "scripted:telegraph_dodges_v1"},
           provenance={"notes": ["telegraph_dodge_success_pct = dodged/telegraphs per attack_id (process fields)"]}),
        _c(id="goal_knowledge_recipe", tier="T1", family="knowledge",
           chat=[{"text": "make yourself a bronze pickaxe"}], forbid_terms=["bar", "smelt", "furnace", "copper", "tin"],
           needs_fact={"kind": "recipe", "truth": "Bronze Bar"}, fixtures={"state_snapshot": "fresh_dev_v1"},
           success={"all": [{"have": {"item": "Bronze Pickaxe", "at_least": 1}}, {"xp_gained": {"skill": "Artisan", "at_least": 1}}]},
           controls={"alt_means": [{"setup": "grant", "item": "ITEM_Pickaxe_Bronze", "count": 1}], "na": NA_ORACLE},
           limits={"wall_s": 1800}, oracle={"dev": "scripted:bronze_pickaxe_v1"}),
        _c(id="goal_knowledge_weakness", tier="T1", family="knowledge",
           chat=[{"text": "kill that one, use whatever hurts it most"}], forbid_terms=["fire", "burn", "flame"],
           needs_fact={"kind": "weakness", "truth": "Fire"},
           fixtures={"setup": [{"verb": "spawn", "as": "foe", "class": RUNT},
                               {"verb": "grant", "item": "ITEM_Staff_Ash", "count": 1, "purpose": "minimal: a caster (not what the case is about)"},
                               {"verb": "grant_runes", "runes": {"Fire": 100, "Water": 100, "Air": 100},
                                "purpose": "minimal: three elements so the choice is his"}],
                     "state_snapshot": "fresh_dev_v1"},
           success={"all": [{"killed": {"kind": "Goblin Runt", "kind_id": RUNT, "at_least": 1}},
                            {"damage_type_dealt": {"target_kind_id": RUNT, "types": [FIRE], "min_share": 0.6}}]},
           controls={"wrong_action": [{"note": "the oracle with water runes"}], "na": {**NA_ORACLE, "alt_means": "n/a"}},
           limits={"wall_s": 600}, oracle={"dev": "scripted:runt_fire_v1"},
           provenance={"notes": ["grants kept minimal (Luis 2026-10-26): the case is about the weakness fact, not "
                                 "runecrafting or making a staff; the sword grant was dropped (fists are the non-fire option)"]}),
        _c(id="goal_knowledge_location", tier="T1", family="knowledge",
           chat=[{"text": "go get some clay"}], forbid_terms=["swamp", "Whispering"],
           needs_fact={"kind": "location", "truth": "Whispering Swamp"},
           fixtures={"setup": [{"verb": "teleport", "at": [100.0, 1892.0, -31.0],
                                "purpose": "a Brynmoor start-area spot (dev_places standing_trees); clay is only in the Whispering Swamp (unverified on dev)"}], "state_snapshot": "fresh_dev_v1"},
           success={"all": [{"gained": {"item": "Clay", "at_least": 5}}, {"xp_gained": {"skill": "Mining", "at_least": 1}}]},
           controls={"alt_means": [{"setup": "grant", "item": "ITEM_Resources_Clay", "count": 5}], "na": NA_ORACLE},
           limits={"wall_s": 1800}, oracle={"dev": "scripted:clay_v1"},
           provenance={"notes": ["confirm clay is only in the Whispering Swamp (wiki Clay Node lists only it)"]}),
        _c(id="goal_knowledge_no_lookup_needed", tier="T1", family="knowledge",
           chat=[{"text": "grab those logs over there"}], needs_fact={"kind": "none"},
           fixtures={"setup": [{"verb": "ground_item", "item": "ITEM_Resources_Wood_Ash", "count": 3, "at": [7, 0, 0]}]},
           success={"gained": {"item": "Ash Logs", "at_least": 3}}, limits={"wall_s": 300, "idle_s": 60}, targets=["mock", "dev"],
           controls={"na": {**NA_ORACLE, "alt_means": "n/a", "wrong_action": "n/a"}},
           oracle={"mock": [{"pickup_all": "ITEM_Resources_Wood_Ash"}], "dev": "scripted:pick_logs_v1"},
           provenance={"notes": ["logs at 7 m: beyond the loot-pickup reflex radius, so ambient must fail"]}),
    ]


def skill_names(root: Path = ROOT) -> list[str]:
    """The frozen M3 skill list (proposal item 2); data scan only as a cross-check."""
    return ["Agility", "Artisan", "Attack", "Construction", "Cooking", "Farming", "Fishing", "Magic", "Mining", "Ranged",
            "Runecrafting", "Woodcutting"]


INCIDENTAL = {"Agility", "Mining", "Woodcutting", "Magic", "Attack"}  # wiki: XP from walking, floor pickups, any cast, any hit


def every_skill() -> list[Case]:
    """M3: per skill x {asked, initiative, plus5}; method-free chat; thresholds to calibrate vs ambient (review M-1)."""
    out = []
    for s in skill_names():
        low = s.lower()
        thr = 100  # placeholder: calibrated per skill on dev against an ambient run of the same wall_s
        ctl = {"na": {"partial": "XP is continuous", "alt_means": "XP has no other source"},
               "wrong_action": [{"note": "train a different skill"}]}
        out += [
            _c(id=f"m3_{low}_asked", tier="T1", family="skill_train", skill=s, mode="asked",
               chat=[{"text": f"can you get some {s} levelling done?"}], fixtures=FRESH,
               success={"xp_gained": {"skill": s, "at_least": thr}}, controls=ctl, limits={"wall_s": 1200, "idle_s": 120},
               oracle={"dev": f"scripted:train_{low}_v1"},
               provenance={"source": f"{WIKI}{s}", "incidental_xp": s in INCIDENTAL}),
            _c(id=f"m3_{low}_initiative", tier="T2", family="skill_train", skill=s, mode="initiative",
               chat=[{"text": "go level up whatever you think needs it, I'll check back later"}], forbid_terms=[s],
               fixtures={"setup": [{"verb": "raise_skills", "except": s, "level": 10,
                                    "purpose": f"scene: every skill but {s} to 10 so {s} is the clear lowest"}],
                         **FRESH},
               success={"all": [{"xp_gained": {"skill": s, "at_least": thr}}, {"xp_top": {"skill": s}}]},
               controls=ctl, limits={"wall_s": 2400, "idle_s": 300}, oracle={"dev": f"scripted:train_{low}_v1"},
               provenance={"note": f"{s} stays at its fresh level; the others are raised to 10 (main 2026-10-26: allowed as "
                                   "scene setup; the target skill is never touched - devtarget refuses a reply that names it)",
                           "gap": "raise_skills is verified for one skill (Attack 2 -> 3); the all-but-one form to level 10 "
                                  "is not yet run live (each case runs on its own fresh character, devchar.py): until then a fixture gap"}),
            _c(id=f"m3_{low}_plus5", tier="T3", family="skill_train", skill=s, mode="plus5",
               chat=[{"text": f"get your {s} up five levels, take your time"}], fixtures=FRESH,
               success={"skill_gain": {"name": s, "levels": 5}},
               controls={**ctl, "partial": [{"note": "+4 levels"}], "na": {"alt_means": "XP has no other source"}},
               limits={"wall_s": 7200, "idle_s": 300}, oracle={"dev": f"scripted:train_{low}_v1"},
               provenance={"note": "min(5, next gate) once the per-skill gates are confirmed (proposal item 2)"}),
        ]
    return out


def capstone() -> list[Case]:
    neutral = "let's keep going with the Velgar stuff, what's next?"
    stages = [
        ("shelter", {"quest": {"name": "Dragon Slayer", "stage": "<the shelter objective key from quest data>"}}),
        ("growing_pains", {"quest": {"name": "Growing Pains", "completed": True}}),
        ("shrimp_catcher", {"quest": {"name": "Shrimp Catcher", "completed": True}}),
        ("restless_ghosts", {"quest": {"name": "Restless Ghosts", "completed": True}}),
        ("highlighting_the_problem", {"quest": {"name": "Highlighting the Problem", "completed": True}}),
        ("iron_tools", {"all": [{"have": {"item": "Iron Pickaxe", "at_least": 1}}, {"have": {"item": "Iron Logging Axe", "at_least": 1}},
                                {"xp_gained": {"skill": "Artisan", "at_least": 1}}]}),
        ("challenge_horn", {"all": [{"have": {"item": "ITEM_Masterworks_Challenge_Horn", "at_least": 1}},
                                    {"xp_gained": {"skill": "Artisan", "at_least": 1}}]}),
        ("pl4_gear", {"all": [{"gear_better": {"slot": s, "stat": "power_level", "where": "equipped", "than": 3, "op": ">"}}
                              for s in ("head", "body", "legs")]}),
    ]
    out = []
    for i, (sid, pred) in enumerate(stages):
        prev = f"capstone_after_{stages[i - 1][0]}" if i else "fresh_dev_v1"
        # stage 1 starts on a brand-new character; later stages continue the character that verified the previous
        # stage (route B, a dev-save snapshot/restore, is not built yet: until then a chained stage is a fixture gap)
        who = "fresh" if not i else f"chain:capstone_stage_{i}_{stages[i - 1][0]}"
        out.append(_c(id=f"capstone_stage_{i + 1}_{sid}", tier="T3", family="capstone_stage", capstone="brynmoor_progression",
                      chat=[{"text": neutral}], fixtures={"state_snapshot": prev, "character": who}, success=pred,
                      guards=[DEATH_GUARD],
                      controls={"na": {"alt_means": "stage state", "wrong_action": "n/a", "partial": "the stage's own progress"}},
                      limits={"wall_s": 7200, "idle_s": 300}, oracle={"dev": f"scripted:capstone_{sid}_v1"},
                      provenance={"sources": [WIKI + "Dragon_Slayer", WIKI + "Quests", WIKI + "Brynmoor"],
                                  "note": "chained snapshot: starts from the previous stage's verified end state (review V-8)"}))
    out.append(_c(id="capstone_slay_velgar_solo", tier="T3", family="capstone", capstone="slay_velgar_solo",
                  tags={"evidence": ["referee:damage.by", "referee:death.by", "referee:defended", "probe:held_effects"]},
                  chat=[{"text": "Velgar's next. Get yourself ready and take him on by yourself"}],
                  forbid_terms=["antipoison", "poison", "shield", "enchant", "air", "food", "potion"],
                  fixtures={"state_snapshot": "capstone_v1", "character": "chain:capstone_stage_8_pl4_gear"},
                  success={"all": [{"killed": {"kind": "Velgar", "kind_id": VELGAR, "at_least": 1}},
                                   {"solo": {"target_kind_id": VELGAR}},
                                   {"prepared": {"target_kind_id": VELGAR, "all": [
                                       {"item": "ITEM_Consumable_Potion_T2_Lesser_Antipoison", "at_least": 1, "gained_since_start": True},
                                       {"items_any": ["ITEM_Consumable_BerryDrizzle_Pan-Seared", "ITEM_Consumable_Fish_Anchovies"],
                                        "at_least": 3},
                                       {"predicate": {"gear_better": {"slot": "body", "stat": "power_level", "where": "equipped",
                                                                      "than": 3, "op": ">"}}},
                                       {"any_of": [{"tag": "Player.Status.TempestShield"},
                                                   {"enchant_type": "DamageType.Magical.Air"}]}]}},
                                   {"defended": {"kind": "dodge", "against": "telegraph", "at_least": 5}}]},
                  guards=[DEATH_GUARD],
                  needs_fact={"kind": "weakness", "truth": "no weakness; immune to poison and burning; poison breath -> antipoison"},
                  controls={"partial": [{"note": "fight unprepared"}], "na": {"alt_means": "the kill is the capability",
                                                                              "wrong_action": "n/a"}},
                  limits={"wall_s": 5400, "idle_s": 300, "hints_max": 0, "repeat": 3}, oracle={"dev": "scripted:velgar_v1"},
                  provenance={"sources": [WIKI + "Velgar", WIKI + "Velgar/Strategies", WIKI + "Dragon_Slayer"],
                              "notes": ["SOLO on dev; PL4, 6000 HP; telegraphed: poison spray, puddle bombs, leg-stomp spikes, bite, "
                                        "head swipe; flies off at 3/4, 1/2, 1/4 HP", "'levelled gear' not checkable (proposal 5.5)"]}))
    velgar = out[-1]
    out.append(quick(velgar, setup=[
        {"verb": "grant", "item": "ITEM_Masterworks_Challenge_Horn", "count": 1, "purpose": "quick: skip stages 1-8"},
        {"verb": "teleport", "at": "<Velgar's Rise on dev>", "purpose": "quick: start at the arena"}],
        note="horn granted and teleported to the arena; preparation still his"))
    return out


def pinnable(c: Case) -> bool:
    """A main-variant case that lints clean as a suite case (no dev-fact placeholder, every snapshot has a manifest)."""
    from .spec import lint
    return c.variant != "quick" and not lint(c.model_copy(update={"status": "suite"}))


def write(out: Path = OUT, pin: bool = True, root: Path = ROOT) -> list[str]:
    """Luis 2026-10-26 (standing yes): every pinnable main case becomes a suite case, its hash goes into
    docs/goal_targets.json goal_cases.pinned_by_hash, and the GOAL manifest (manifests/<build>/goal_v1.json, its
    own full runs, separate from the 202-run spell suite) lists it with its trials. Quick twins are never pinned."""
    from . import hashes
    from .spec import case_hash
    groups = {"long_tasks.json": long_tasks(), "combat_basics.json": combat_basics(),
              "tactics_knowledge.json": tactics_and_knowledge(), "m3_every_skill.json": every_skill(),
              "m6_capstone.json": capstone()}
    lines, pins, fams, trials = [], {}, {}, {}
    for name, cases in groups.items():
        if pin:
            cases = [c.model_copy(update={"status": "suite"}) if pinnable(c) else c for c in cases]
            for c in cases:
                if c.status == "suite":
                    pins[c.id] = case_hash(c)
                    fams.setdefault(c.family, []).append({"id": c.id, "hash": pins[c.id]})
                    trials[c.family] = max(trials.get(c.family, 1), int(c.limits.repeat or 1))
        dump_cases(cases, out / name)
        holes = sum(bool(re.search(r"<[^<>]+>", json.dumps(c.model_dump(exclude={"provenance"})))) for c in cases)
        lines.append(f"{name}: {len(cases)} cases, {sum(c.status == 'suite' for c in cases)} pinned "
                     f"({holes} still need a dev fact)")
    if pin:
        tp = root / "docs" / "goal_targets.json"
        t = json.loads(tp.read_text(encoding="utf-8"))
        t.setdefault("goal_cases", {})["pinned_by_hash"] = dict(sorted(pins.items()))
        t["goal_cases"]["_note"] = ("pinned 2026-10-26 under Luis's standing yes (evals/bench/goal_drafts.py write): every "
                                    "main-variant case that lints clean as a suite case; quick twins never")
        tp.write_text(json.dumps(t, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        mdir = root / "evals" / "bench" / "manifests" / str(hashes.game_build())
        mdir.mkdir(parents=True, exist_ok=True)
        man = {"schema": "dw_bench_manifest/1", "version": 1, "build": hashes.game_build(), "name": "goal_v1",
               "families": fams, "trials_per_case": trials,
               "denominators": {f: len(v) * trials[f] for f, v in fams.items()}, "approved_by": "Luis (standing yes, 2026-10-26)"}
        (mdir / "goal_v1.json").write_text(json.dumps(man, indent=1), encoding="utf-8")
        lines.append(f"pinned {len(pins)} GOAL cases -> docs/goal_targets.json + {mdir / 'goal_v1.json'}")
    return lines


if __name__ == "__main__":
    for line in write():
        print(line)
