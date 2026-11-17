# Region travel: can he act on "copper is found in Fractured Plains"? (2026-11-17)

Offline study. No repo code changed and nothing was run live. Model spend: one replay of 3 Haiku 5.5 calls, $0.0043.

## The turn
`logs/brain-live-20261117-221939-19116.jsonl`, job L2 "thirty copper ore in the chest at your base", episode
`situation-0002-94ce`. He made a Stone Pickaxe, equipped it and ran `gather copper 30 radius 100`. The result was
`nothing_in_range`, "I can't find any copper within 90 m of me", with this knowledge line added (row 163):
`wiki, Copper Ore Node: found in Fractured Plains, Stormtouched Highlands, Dowdun Reach; tool: Bone pickaxe or better`.
On the next turn (row 167, then the check call at row 169) he only said: "no copper anywhere near here, and copper
needs a bone pick or better. where's the nearest copper you know of?" Then he stopped.

## What already exists
| Need | Exists? | Where |
|---|---|---|
| Which region he is in | **Yes, and he was shown it.** body_status `Where: in Temple Woods (Brynmoor); near Water Anima Vent 12 m SE, Doric 86 m NW` | `brain/broker.py` `_location` (row 133's first user message) |
| Region geometry | **Yes.** All 31 `BP_MapRegion_C` polygons, province mapping and landmarks are in the data file. The live `Where` line on build 26574459 still resolves Temple Woods correctly. | `data/places_26161880.json`, `brain/places.py` (`region_at`, `where`), `client_mod/scripts/places.lua`, DISCOVERIES l.586-641, 2261 |
| go_to by region name | **Yes.** The go_to `target` description says "a place name from the game's map (a region, NPC or landmark), even out of sight". go_to "Fractured Plains" resolves to the nearest known point inside it, the landmark Goblin Stove, 760 m away. | `brain/controller.py` `MAP_NAMES_NOTE`, `brain/executor.py` `_go_to_game_place` |
| Distance and direction from him to a named region | **Not shown.** `Places.where` computes it, but the only path to it is a go_to. `WHERE_TOOL` (`brain/places.py:590`) is written and tested, but neither brain offers it (only `tests/test_places.py` uses it). | |
| lookup "Fractured Plains" | Gives wiki text only ("power level 3 area ... just north of the Whispering Swamp"). It says nothing about how far it is from him. | `brain/knowledge.py` |
| explore | It searches outward from where he stands (6 legs of 30 m by default) and its description says it is not for a known place. That is correct for this case. | |
| teleport | The dev world has one lodestone, in Temple Woods (DISCOVERIES l.2212), so walking is the only way. | |
| Copper node positions | **None.** World Partition streams them in, so the object dump only has classes. map_memory has no copper sighting. The only placed facts are the wiki region names and the trader Beartach (Umbral Sands, paid in Garou Chit). | |

Computed from where he stood ([156, 1918]), using the same resolver go_to uses:

| Region | Province | PL | Nearest known point | Polygon edge |
|---|---|---|---|---|
| Fractured Plains | Ghornfell | 3 | 760 m N | about 708 m N |
| Stormtouched Highlands | Ghornfell | 4 | 848 m N | about 717 m N |
| Dowdun Reach (all of it) | Dowdun Reach | 6 | 2129 m NE | about 2044 m NE |

At his live walking pace of about 3 m/s, 760 m is roughly 4 minutes. He is PL 0.

## The pickaxe (a second blocker, and it is real)
- The game's own item text for the Bone Pickaxe: "hard enough to mine Copper and Tin deposits" (tier 2). The Stone Pickaxe is tier 1: "stone and rune essence". **Walking to Fractured Plains with the Stone Pickaxe would fail at the rock.**
- `RECIPE_Pickaxe_Bone` needs 8 Animal Bone, 6 Ash Logs and 4 Leather at a Crafting Table. He carried 4 bones, 4 Ash Logs (gatherable nearby), 0 Leather and 7 Animal Hide Scraps. Leather comes from 3 scraps or 1 hide at a Tannery, which needs fuel. No Tannery was in sight. So the pickaxe was **not craftable from what he had**. He needed 4 more bones and 5 more scraps (3 Kebbits were 30 m away), plus a Tannery.
- The live `craft` ambiguous result already told him the Bone Pickaxe was `missing_input`. `craft_plan` is offered to the Controller ("ordered steps: gather, craft at station, unlock, find station"), but it is the body's own planner and could not be run offline. No logged `craft_plan` result for a pickaxe was found, so **whether it names the Tannery step is unverified.**
- The Planner wrote a job that made a Stone Pickaxe for copper ("making one if needed"). It never checked the tier, even though `lookup "Bone Pickaxe"` states it.

## Replay (n = 1, 3 calls)
The two earlier calls of the episode were sent unchanged. Cache reads matched live: 19560 vs 19549 tokens and 23454 vs 23443. In the stopping call, one fact was appended to the gather result's knowledge line:
`; map (game data): you are in Temple Woods (Brynmoor); Fractured Plains 760 m N, Stormtouched Highlands 848 m N, Dowdun Reach 2129 m NE`

- Live: `say` "no copper anywhere near here, and copper needs a bone pick or better. where's the nearest copper you know of?"
- Replay: `say` "no copper anywhere near here, nearest is Fractured Plains about 760 m north. want me to head up there?"

**He did not set off.** With the fact, he stopped asking the player where copper is and instead asked permission to go. He also dropped the pickaxe tier from his line. Setting off would have been wrong anyway with only a Stone Pickaxe. One sample says little; a K=5 run would cost about $0.02. The last user message of that call ("A step did not work ... if you can't, tell the player in one short plain line what's wrong and what you need") invites a question to the player. Under rule 10, changing that wording is a one-time try at most.

Script: the scratchpad's `replay_region.py`. It uses `tools.replay_episode.episode_calls` and swaps one string in the gather tool message.

## What is missing, and the smallest change
1. **Distance and direction to the regions the knowledge line names** (a fact, not an instruction). In `brain/result_knowledge.enrich`, look up each region or province named in the `location` line with `Places.where(name, position)`. That is the same resolver go_to walks to, so the numbers agree with what go_to would do. Append `you are in <region>; <name> <d> m <dir>` for each, nearest first. Cost: about 15 lines in `result_knowledge.py`, plus passing `self.controller.places` and the state position at `brain/agent.py:912`. It adds about 110 characters, only to not-found gather or explore results. No new tool, no model calls, nothing in the client.
2. **The tool gap next to it:** append the node's minimum tool tier against what he carries, e.g. `you carry Stone Pickaxe (tier 1); Copper Ore Node needs tier 2`. `rock_gates.json` has `min_tier` and the item has `tier`. Without this, a successful region trip ends at the rock. Cost: about 5 more lines in the same function.
3. **Optional and larger:** offer the existing `WHERE_TOOL` to the Controller as a read tool. It is already written and tested. Cost: about 120 more cached tokens per call and one more read tool. It also answers "where is X" asks in general.

The replay shows that change 1 alone moves him from "where's copper?" to "want me to go?". It does not show that he sets off. Measure it with a K=5 replay of changes 1 and 2 together before a live window. The number to watch is how often the last call makes a world call: a gather or go_to to Fractured Plains, or a step towards the Bone Pickaxe. Live, that was 0 of 1.
