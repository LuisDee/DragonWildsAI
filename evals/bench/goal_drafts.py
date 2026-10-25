"""DRAFTS of the GOAL-required cases (review finding 10a): hand-specified by the Eval agent from GOAL.md, the wiki
mirror and the game data, for main's and Luis's review. Nothing here is scored until Luis approves a case and its
hash is pinned in docs/goal_targets.json goal_cases.pinned_by_hash.

  .venv\\Scripts\\python.exe -m evals.bench.goal_drafts      # writes evals/bench/goal_cases/*.json (status draft)

Placeholders "<...>" are values that need a dev-world fact (a class id, a place) before the case can run; the lint
keeps such cases at status draft. Wiki sources are in each case's provenance.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

from .spec import Case, dump_cases

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "evals" / "bench" / "goal_cases"
WIKI = "https://dragonwilds.runescape.wiki/w/"
P = "Tester"  # the harness's test player on dev


def _c(**kw) -> Case:
    base = {"authored_by": "human", "status": "draft", "targets": ["dev"]}
    base.update(kw)
    return Case.model_validate(base)


def long_tasks() -> list[Case]:
    k3 = {"repeat": 3}
    return [
        _c(id="goal_gather_coal_multitrip", tier="T3", family="long_task", long_task="gather_coal_multitrip",
           tags={"skills": ["Mining"], "uses": ["wiki", "lodestone", "storage"]},
           chat=[{"text": "can you get me 50 coal? check the wiki for where it is, and use the lodestones if it's far"}],
           phrasing_heldout="need a load of coal for the blast furnace, fifty-ish, sort it out?",
           fixtures={"setup": [{"verb": "grant", "item": "ITEM_Rune_Law", "count": 30},
                               {"verb": "grant", "item": "<pickaxe that mines coal (tier from data)>", "count": 1}],
                     "state_snapshot": "fresh_dev_v1", "player_body": True},
           success={"all": [{"delivered": {"to": P, "item": "Coal", "at_least": 50}},
                            {"trips": {"deposits_at_least": 2}}, {"teleports": {"via": "lodestone", "at_least": 1}}]},
           guards=[{"no_event": {"kind": "death", "who": "self"}}],
           needs_fact={"kind": "location", "truth": "coal node regions from the wiki (Fellhollow, Dowdun Reach, Umbral Sands)"},
           controls={"alt_means": [{"setup": "grant_to_ground", "item": "ITEM_Resources_Coal", "count": 50}]},
           limits={"wall_s": 5400, "hints_max": 1, "idle_s": 180, **k3},
           hints={"ladder": ["any luck with the coal?", "coal's in rocky places, the wiki lists the regions",
                             "Fellhollow has coal nodes; there's a lodestone near there"]},
           provenance={"sources": [WIKI + "Coal", WIKI + "Coal_Node", WIKI + "Lodestone"]}),
        _c(id="goal_farm_mob_drop", tier="T3", family="long_task", long_task="farm_mob_drop",
           tags={"uses": ["wiki", "weakness", "trips"]},
           chat=[{"text": "I need 20 <a drop only <creature> drops>, can you farm them for me? they're tough, gear up for them"}],
           fixtures={"state_snapshot": "fresh_dev_v1", "player_body": True},
           success={"all": [{"delivered": {"to": P, "item": "<the drop item>", "at_least": 20}},
                            {"damage_type_dealt": {"target_kind_id": "<creature class>", "types": ["<weakness damage type from the wiki>"]}},
                            {"trips": {"deposits_at_least": 2}}]},
           guards=[{"no_event": {"kind": "damage_to_player"}}],
           needs_fact={"kind": "weakness", "truth": "<the creature's wiki infobox weakness>"},
           controls={"alt_means": [{"setup": "grant_to_ground", "item": "<the drop item>", "count": 20}]},
           limits={"wall_s": 5400, "hints_max": 1, "idle_s": 180, **k3},
           hints={"ladder": ["how's the farming going?", "check what they're weak to", "<the weakness> works on them"]},
           provenance={"note": "pick a creature whose drop has a single source (wiki Drop sources) and a weakness", "sources": [WIKI + "Monsters"]}),
        _c(id="goal_gear_upgrade_self_initiated", tier="T3", family="long_task", long_task="gear_upgrade_self_initiated",
           chat=[{"text": "go level up and sort yourself out, I'll be back in a bit"}],
           fixtures={"setup": [{"verb": "reset_gear", "tier": 1}], "state_snapshot": "fresh_dev_v1"},
           success={"any": [{"gear_better": {"slot": "body", "stat": "power_level", "where": "equipped", "than": "start"}},
                            {"gear_better": {"category": "pickaxe", "stat": "tool_tier", "where": "equipped", "than": "start"}},
                            {"gear_better": {"category": "sword", "stat": "power_level", "where": "equipped", "than": "start"}}]},
           limits={"wall_s": 7200, "hints_max": 1, "idle_s": 300, **k3},
           hints={"ladder": ["how's it going?", "your gear's pretty weak", "a bronze pickaxe would help"]},
           provenance={"note": "his own initiative: the chat never names gear; one tier up on any slot or tool counts"}),
        _c(id="goal_brynmoor_quest_chain", tier="T3", family="long_task", long_task="brynmoor_quest_chain",
           chat=[{"text": "let's do the Brynmoor quests, can you start on Goblin Diplomacy? the wiki has the steps"}],
           fixtures={"state_snapshot": "fresh_dev_v1"},
           success={"quest": {"name": "Goblin Diplomacy", "completed": True}},
           limits={"wall_s": 7200, "hints_max": 1, "idle_s": 300, **k3},
           hints={"ladder": ["how far along are you?", "Zanik starts it in Bramblemead Valley", "<the next quest step>"]},
           provenance={"note": "quest{} evaluates null until quest perception lands (a perception gap, never a pass)",
                       "sources": [WIKI + "Goblin_Diplomacy", WIKI + "Quests"]}),
        _c(id="goal_farm_desert_weed", tier="T3", family="long_task", long_task="farm_desert_weed",
           chat=[{"text": "can you farm some desert weed at our farm? we need a stack of it"}],
           fixtures={"setup": [{"verb": "place", "name": "our farm", "at": "<farm plots position on dev>"}],
                     "state_snapshot": "fresh_dev_v1", "player_body": True},
           success={"all": [{"gained": {"item": "Desert Weed", "at_least": 20}}, {"near": {"place": "our farm", "within_m": 30}}]},
           controls={"alt_means": [{"setup": "grant_to_ground", "item": "<Desert Weed item id>", "count": 20}]},
           limits={"wall_s": 7200, "hints_max": 1, "idle_s": 300, **k3},
           hints={"ladder": ["how's the farm?", "you need desert weed seeds and a plot", "<where seeds come from>"]},
           provenance={"sources": [WIKI + "Desert_Weed_(Farming)", WIKI + "Desert_Weed_Seeds"]}),
    ]


def combat_basics() -> list[Case]:
    return [
        _c(id="goal_basic_dodge_directional", tier="T1", family="combat_basic", basic="dodge_directional",
           chat=[{"text": "watch out for its big swings"}],
           fixtures={"setup": [{"verb": "spawn", "as": "foe", "class": "<a creature with a telegraphed attack>", "offset_m": [6, 0, 0]}]},
           success={"defended": {"kind": "dodge", "against": "telegraph", "at_least": 3}},
           guards=[{"no_event": {"kind": "death", "who": "self"}}], limits={"wall_s": 300, "repeat": 3},
           provenance={"note": "referee: telegraphed attacks resolved as dodged (needs the referee defence events)"}),
        _c(id="goal_basic_parry", tier="T1", family="combat_basic", basic="parry",
           chat=[{"text": "block its hits, don't just tank them"}],
           fixtures={"setup": [{"verb": "spawn", "as": "foe", "class": "<a melee creature>", "offset_m": [6, 0, 0]},
                               {"verb": "grant", "item": "<a shield>", "count": 1}]},
           success={"defended": {"kind": "parry", "at_least": 3}}, limits={"wall_s": 300, "repeat": 3}),
        _c(id="goal_basic_disengage_heal", tier="T1", family="combat_basic", basic="disengage_heal",
           chat=[{"text": "you're getting hammered, sort yourself out"}],
           fixtures={"setup": [{"verb": "spawn", "as": "foe", "class": "<a creature stronger than him>", "offset_m": [4, 0, 0]},
                               {"verb": "grant", "item": "<food>", "count": 5}, {"verb": "set_health_pct", "pct": 35}]},
           success={"disengaged": {"target": "$foe.id", "aggro_m": 15, "reengaged": True}},
           guards=[{"no_event": {"kind": "death", "who": "self"}}], limits={"wall_s": 300, "repeat": 3}),
    ]


def tactics_and_knowledge() -> list[Case]:
    return [
        _c(id="goal_tactics_prep_hard_fight", tier="T2", family="tactics",
           chat=[{"text": "that thing over there is nasty, take it out when you're ready"}],
           fixtures={"setup": [{"verb": "spawn", "as": "boss", "class": "<a creature 2+ PL above his gear>", "offset_m": [30, 0, 0]}]},
           success={"prepared": {"any": [{"tag": "<Tempest Shield tag>"}, {"enchant_type": "<the boss weakness damage type>"},
                                         {"item": "<antipoison or food>", "at_least": 1}]}},
           limits={"wall_s": 900}, provenance={"sources": [WIKI + "Velgar/Strategies"]}),
        _c(id="goal_tactics_damage_trend", tier="T2", family="tactics",
           chat=[{"text": "keep fighting these until you've got them figured out"}],
           fixtures={"setup": [{"verb": "spawn", "class": "<a mid creature with telegraphs>", "offset_m": [8, 0, 0]}]},
           success={"killed": {"kind": "<creature>", "at_least": 1}}, limits={"wall_s": 600, "repeat": 5},
           provenance={"note": "process metric damage_taken per repeat (referee), slope over 5 fights"}),
        _c(id="goal_knowledge_recipe", tier="T1", family="knowledge",
           chat=[{"text": "make yourself a bronze pickaxe"}], needs_fact={"kind": "recipe", "truth": "Bronze Bar"},
           success={"have": {"item": "Bronze Pickaxe", "at_least": 1}}, limits={"wall_s": 1800}),
        _c(id="goal_knowledge_weakness", tier="T1", family="knowledge",
           chat=[{"text": "kill that one, use whatever hurts it most"}],
           needs_fact={"kind": "weakness", "truth": "<the creature's weakness from the wiki>"},
           fixtures={"setup": [{"verb": "spawn", "as": "foe", "class": "<a creature with a wiki weakness>"}]},
           success={"damage_type_dealt": {"target_kind_id": "<class>", "types": ["<weakness type>"]}}, limits={"wall_s": 600}),
        _c(id="goal_knowledge_location", tier="T1", family="knowledge",
           chat=[{"text": "find us some clay"}], needs_fact={"kind": "location", "truth": "<clay node region>"},
           success={"gained": {"item": "Clay", "at_least": 5}}, limits={"wall_s": 1800}),
        _c(id="goal_knowledge_no_lookup_needed", tier="T1", family="knowledge",
           chat=[{"text": "pick up those logs next to you"}], needs_fact={"kind": "none"},
           fixtures={"setup": [{"verb": "ground_item", "item": "ITEM_Resources_Wood_Ash", "count": 3, "at": [2, 0, 0]}]},
           success={"gained": {"item": "Ash Logs", "at_least": 3}}, limits={"wall_s": 300}, targets=["mock", "dev"],
           oracle={"mock": [{"pickup_all": "ITEM_Resources_Wood_Ash"}], "dev": [{"pickup_all": "ITEM_Resources_Wood_Ash"}]}),
    ]


def skill_names(root: Path = ROOT) -> list[str]:
    names: set[str] = set()
    for f in sorted((root / "data").glob("*_*.json")):
        if re.fullmatch(r"(spells|recipes)_\d+\.json", f.name):
            names.update(re.findall(r"SKILL_([A-Za-z]+)", f.read_text(encoding="utf-8", errors="replace")))
    return sorted(names)


def every_skill() -> list[Case]:
    """M3: per skill x {asked, initiative, plus5}. The chat never names a method (no "mine copper")."""
    out = []
    for s in skill_names():
        low = s.lower()
        reset = [{"verb": "reset_skills", "skill": s, "level": 1}]
        out += [
            _c(id=f"m3_{low}_asked", tier="T1", family="skill_train", skill=s, mode="asked",
               chat=[{"text": f"can you get some {s} levelling done?"}], fixtures={"setup": reset},
               success={"xp_gained": {"skill": s, "at_least": 1}}, limits={"wall_s": 1200, "idle_s": 120},
               provenance={"source": f"{WIKI}{s}"}),
            _c(id=f"m3_{low}_initiative", tier="T2", family="skill_train", skill=s, mode="initiative",
               chat=[{"text": "go level up whatever you think needs it, I'll check back later"}],
               fixtures={"setup": reset + [{"verb": "raise_other_skills", "except": s, "level": 10}]},
               success={"xp_gained": {"skill": s, "at_least": 1}}, limits={"wall_s": 2400, "idle_s": 300},
               provenance={"note": f"{s} is reset to 1 and the others raised to 10: the open task should pick it by itself"}),
            _c(id=f"m3_{low}_plus5", tier="T3", family="skill_train", skill=s, mode="plus5",
               chat=[{"text": f"get your {s} up five levels, take your time"}], fixtures={"setup": reset},
               success={"skill_gain": {"name": s, "levels": 5}}, limits={"wall_s": 7200, "idle_s": 300}),
        ]
    return out


def capstone() -> list[Case]:
    stages = [
        ("shelter", "build a shelter with a bed and claim it", {"quest": {"name": "Dragon Slayer", "stage": "shelter"}}),
        ("growing_pains", "do the Growing Pains quest", {"quest": {"name": "Growing Pains", "completed": True}}),
        ("shrimp_catcher", "do Shrimp Catcher", {"quest": {"name": "Shrimp Catcher", "completed": True}}),
        ("restless_ghosts", "do Restless Ghosts", {"quest": {"name": "Restless Ghosts", "completed": True}}),
        ("goblin_diplomacy", "do Goblin Diplomacy", {"quest": {"name": "Goblin Diplomacy", "completed": True}}),
        ("highlighting_the_problem", "do Highlighting the Problem", {"quest": {"name": "Highlighting the Problem", "completed": True}}),
        ("iron_tools", "get yourself an iron pickaxe and an iron logging axe",
         {"all": [{"have": {"item": "Iron Pickaxe", "at_least": 1}}, {"have": {"item": "Iron Logging Axe", "at_least": 1}}]}),
        ("challenge_horn", "make the challenge horn for Velgar", {"have": {"item": "Challenge Horn", "at_least": 1}}),
        ("pl4_gear", "gear up to power level 4 before Velgar",
         {"gear_better": {"slot": "body", "stat": "power_level", "where": "equipped", "than": 3, "op": ">="}}),
    ]
    out = [_c(id=f"capstone_stage_{i + 1}_{sid}", tier="T3", family="capstone_stage", chat=[{"text": text}],
              success=pred, limits={"wall_s": 7200, "idle_s": 300},
              provenance={"sources": [WIKI + "Dragon_Slayer", WIKI + "Quests", WIKI + "Brynmoor"],
                          "note": "stage order from the wiki (Dragon Slayer walkthrough, Brynmoor secondary quests); "
                                  "quest stages evaluate null until quest perception lands"})
           for i, (sid, text, pred) in enumerate(stages)]
    out.append(_c(id="capstone_slay_velgar_solo", tier="T3", family="capstone", capstone="slay_velgar_solo",
                  chat=[{"text": "time to take on Velgar. read up on him, get ready properly, and do it on your own"}],
                  fixtures={"setup": [{"verb": "grant", "item": "Challenge Horn", "count": 1}], "state_snapshot": "capstone_v1"},
                  success={"all": [{"killed": {"kind": "Velgar", "kind_id": "<Velgar class id from the dev census>", "at_least": 1}},
                                   {"prepared": {"any": [{"item": "<Lesser Antipoison potion>", "at_least": 1},
                                                         {"tag": "<Tempest Shield tag>"}, {"enchant_type": "DamageType.Magical.Air"}]}}]},
                  guards=[{"no_event": {"kind": "death", "who": "self"}}],
                  needs_fact={"kind": "weakness", "truth": "immune to poison and burning; poison breath -> antipoison"},
                  limits={"wall_s": 5400, "idle_s": 300, "hints_max": 0},
                  provenance={"sources": [WIKI + "Velgar", WIKI + "Velgar/Strategies", WIKI + "Dragon_Slayer"],
                              "note": "SOLO on dev: no player help; PL 4, 6000 HP; telegraphed attacks: poison spray, poison "
                                      "puddle bombs, leg stomp spikes, bite and head swipe; flies off at 3/4, 1/2, 1/4 HP"}))
    return out


def write(out: Path = OUT) -> list[str]:
    groups = {"long_tasks.json": long_tasks(), "combat_basics.json": combat_basics(),
              "tactics_knowledge.json": tactics_and_knowledge(), "m3_every_skill.json": every_skill(),
              "m6_capstone.json": capstone()}
    lines = []
    for name, cases in groups.items():
        dump_cases(cases, out / name)
        lines.append(f"{name}: {len(cases)} draft cases")
    return lines


if __name__ == "__main__":
    for line in write():
        print(line)
