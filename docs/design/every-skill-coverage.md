# Every skill trains (M3): coverage audit and the missing primitives

Status: BUILT offline, with probe P1 read live, 2026-10-26 (skills-coverage agent). fishing.lua, agility.lua and farm.lua are registered in client_bridge.MODULES by the capability agent. Not deployed live yet. Build 26161880. Dev world only (ClaudeDev); Shockbyte forbidden.
Items marked **[UNVERIFIED]** come from the reflection dump, the wiki mirror or guides, and need a live probe before code relies on them.

## 1. Goal (what Luis will see)
For each of the 12 released skills (`goal_targets.json` `every_skill.skills_frozen`), Claude:
- (a) gains XP when asked in chat with no tool or method named;
- (b) gains XP on his own initiative under an open "level up" task;
- (c) gains +5 levels, or reaches the next gate, unaided.

The harness observer reads the XP from `SkillComponent` (`sense.me().skills`). Everything goes through the real client: `client_mod/scripts`, plus tools published by the manifest.

What has to be true for (a) and (b) to work at all, given that the model infers and code never maps phrases (PRINCIPLES 2):
1. A truthful tool exists for the skill's XP action.
2. Its description says what the action trains, as a fact, not a phrase match.
3. Perception shows the resource or station.
4. The model can look up how a skill is trained (`lookup` over game data plus the wiki: the "<Skill> training" pages are mirrored).

## 2. How each skill gains XP (game data + wiki) and what the body has

Sources:
- recipes: `data/recipes_26161880.json` (`skill`, `xp` per recipe);
- items: `data/items_26161880.json` (tool category tags, primary actions);
- dump: `dumps/26161880/CXXHeaderDump/Dominion.hpp` (`l.` = line);
- wiki: `data/wiki` (page titles).

| Skill | XP actions (Brynmoor) | Primitives needed | Body today | Status / gap |
|---|---|---|---|---|
| **Attack** | Melee hits on creatures. XP scales with max HP, not damage (wiki "Attack"). Unarmed counts too. | `attack` (melee) | `combat.lua` `attack`, verified live. Picks the best melee weapon. | **Covered.** Needs creatures in range; `explore` finds them. |
| **Ranged** | Hits with a bow or crossbow (wiki "Ranged/Experience mechanics": 0.25 × enemy max HP; weak points give more). Needs ammo. | `equip` (bow) + `attack` (ranged engage) + ammo | `combat.lua` ranged engage (`ranged.lua` lead/drop) runs when he is holding a ranged weapon. Fails `not_enough_resources/no_ammo`. | **Covered, with preconditions:** a bow/crossbow + ammo, both craftable at the Fletching Bench. The model must `equip` the bow first, since `attack` only keeps a held ranged weapon. Hit rate is tracked under the M2 target. |
| **Magic** | Combat spells and staff/wand attacks on enemies (wiki "Magic"). Whether utility casts give Magic XP is **[UNVERIFIED]** (`goal_drafts.INCIDENTAL` assumes yes). | `cast` (aimed combat spell at a creature) + runes; staff attack | `spells.lua` `cast` (aimed/placed, verified for several spells). `combat.lua` never uses `kind = "magic"` weapons (`score_weapon` is melee-only). | **Covered via `cast`** (needs runes, so Runecrafting feeds it). **Gap (combat agent):** a staff/wand engage in `attack`. |
| **Mining** | Pickaxe on ore/stone/clay/rune-essence rocks; floor stones (wiki "Mining"). | `gather` (rock profiles) | `gather.lua` + `gather_profiles.lua`: stone_rock, rune_essence, copper, tin, iron, coal, clay (`verified` flags differ), plus the floor-stone pickup. | **Covered** for verified profiles. Copper/tin/iron/coal/clay are `verified=false` and need one live run each (gather agent). |
| **Woodcutting** | Chop trees, logs and saplings; floor logs. | `gather` (tree profiles) | Verified live (oak/ash chains). | **Covered.** |
| **Artisan** | Crafting recipes with `skill = SKILL_Artisan`: 222 with no station, ArmourBench 163, ToolsMeleeBench 100, FletchingBench 72, CraftingTable 58, ... (real `xp` values 8–125). | `craft` (+ `craft_plan`, `recipes`, `stations`) | `crafting.lua` (bench + processing station paths). | **Covered** where a station exists. A Crafting Table is buildable on dev (`build`, capability agent). |
| **Cooking** | Recipes with `skill = SKILL_Cooking` at Campfire (58, processing + fuel), Stone Range (25), Cooking Range (57). Wiki: 10 XP per ingredient, 20 per meal. The JSON `xp` is 1 because the real value is an `OnCraftXpEvent` row. Fishing also gives 30 Campfire/Grill recipes (fish cooking credits Fishing). | `craft` at a Campfire (processing: resources + fuel + start) | `crafting.lua` processing path (fuel, ToggleProcessingStationStarted, collect). | **Covered once a Campfire exists.** No world campfire was found. He builds one with `build` (unlocked on dev: Campfire = 6 Stone, per the capability agent's live P1a). |
| **Construction** | Building pieces (`UBuildingPieceData.ConstructionXPOnBuild`, l.16310; wiki: Open Book 20 XP / 1 log, Wooden Bin 20, Campfire 12, ...); repairs (`RepairXPEvent`, l.16107); Sawmill/Stonecutter recipes (3). | `build {piece, at}` (+ repair later) | `build.lua` (capability agent, docs/design/build-primitive.md): any unlocked piece from game data. | **Owned by the capability agent.** In progress offline/live. Repair is not built. Note the wiki XP suppression: deleted pieces suppress later XP. |
| **Farming** | Weed/till 3 XP per layer, plant 5, water 15–60 per stage, compost 10, cure 3, harvest ~8–128 (wiki "Farming"). Tools are crafted at 50 XP each (spade, watering can, compost bucket). Prerequisites: the plot pieces (`DA_FarmPlot_T1_Brynmoor`, built) and the quest "Growing Pains" (start: craft a spade or watering can, then talk to the Wise Old Man). On dev `bFarmingUnlocked=false` (capability agent). | `craft` (tools); `build` (plot); a plot **tending** loop: equip the stage's item (spade "Dig", seed "Scatter Seeds", can "Pour", bucket "Fertilize" = the held item's primary), face the plot, press, verify `FFarmPlotVisibleState`; harvest/cure = interact; filling the can at water (interact "Collect Water" **[UNVERIFIED]**) | `craft` covers the tools (50 XP each, so Farming XP is reachable today by crafting a spade/can/bucket). `use_action` presses a held primary but neither faces a plot nor verifies the plot state. Quest dialogue has no primitive. | **Partly covered** (tool crafting XP). **Gaps:** (1) `build` of a plot (capability agent; needs the unlock); (2) **built: `farm.lua`** (`tend`, `farm_plots`, §5; 23 offline tests); (3) quest dialogue primitive (talk + choose, for Growing Pains): Director/capability backlog. |
| **Fishing** (built) | Net: hold the trawl inside a net spot (10 stamina each; wiki "Fishing/Net Fishing"). Rod: cast from the bank, then the bite/fight minigame (pull opposite the swim, reel when it rests; wiki "Fishing/Rod Fishing"). Coarse Net = 2 Coarse Thread at the Crafting Table (15 Artisan XP; unlock: Coarse Thread + StartingBench). Ash Rod at Fishing 3. Quest "Shrimp Catcher" from the Wise Old Man (guide). Cooking fish = `SKILL_Fishing` recipes (30 Campfire). | Find spots; equip the right tool; net trawl hold; rod charge + cast + fight minigame; verify catch | **None before this note.** Fishing spots weren't perceived: `AFishingNodeV2` has no InteractionComponent, so census misses it. | **Built: `fishing.lua`** (`fish`, `fishing_spots`, `fishing_status`, get_state `fishing_spots_nearby`). 83 offline tests. Probe P1 verified the tags, settings and input actions (§4). Trawl and catch are still to run live (P2/P3). |
| **Runecrafting** | Rune Altar (a player-built crafting station `BP_Crafting_Rune_Altar_C`, `BUILDPIECE_CraftingStation_Rune_Altar`, wiki: 12 Stone + 4 Rune Essence). Air (1), Astral (3), Earth (15), Fire (25), Nature (38), Law (50) rune recipes, 1 essence → 5 runes. Auto Craft gives 25% of the XP; Attune (an aim/crack-sealing minigame) gives full XP. Anima vents give 10 essence → 100 runes + 40 XP, at any level. Essence: rune-essence rocks (`gather rune_essence`; that is Mining XP). | `gather rune_essence`; `build` the altar; craft at the altar; anima vents: interact | `gather` has a `rune_essence` profile. `crafting.lua` drives `CraftingUIAPI:SelectRecipe` + `SendCraftRequest`, but the altar opens its **own** panel (`URunecraftingMainPanel`, l.32462, with `AutoCraftRunes()`, `TransitionToFindAttunementPhase()`). Whether `SendCraftRequest` works at the altar is **[UNVERIFIED]**. `interact` on an `AAnimaVent` (`Interact`/`InteractStop`: a hold?) is **[UNVERIFIED]**. | **Gap.** (1) The altar needs `build` plus its unlock (first rune essence, wiki "Rune Essence"). (2) Live probe: does `craft {item = "Air Rune"}` work at an altar? If not, a small `runecraft.lua` that opens the altar and presses the panel's own Auto Craft button (`AutoCraftRunes`). The Attune minigame comes later. (3) Probe `interact` on an anima vent. |
| **Agility** | Passive XP from walking on foot (`UAgilitySettings.WalkingXPEventTriggerDistance`, l.14539; wiki: 50 XP per event at level 1); perfect dodges (`PerfectDodgeXPEventName`); courses: **Chasm Dash in Brynmoor** (Agility 1; orbs give `XPGainedByPickup`; finish gives 200/110/50 first-run medals, 50/35/25 repeats). The wiki puts levels 1–15 at about 20 gold laps. Kebbit burrows from Agility 27. | Any walking (`go_to`, `explore`, `follow`) for passive XP; a **course runner**: interact the starter (`AAgilityCourseStarter`), press the start banner's button, then run the orb chain (`AAgilityCourseManager.NextOrbInSequence`, touch = overlap) with jumps; `Client_ValidatedTime` = done | Passive: `go_to`/`explore` already earn it, so (a)/(b) are reachable by walking, slowly. The traversal (jumps, Windstep at 5, double jump at 10) is in move.lua (locomotion agent) and spells. | **Partly covered** (passive walking XP). **Built: `agility.lua`** (`agility_course`, `agility_courses`, §6; 25 offline tests). Running a live course depends on move.lua jumping across the chasm (locomotion agent). Live walking XP trigger: 602 cm. |

### Cross-cutting gaps (not one skill)
- **G1. Perception of skills in the Controller's digest.** `sense.me().skills` (level, xp) reaches the Director curriculum (`brain/director.py skills_progress`), but the Controller's `situation.summary` has no skills line. For (b) "level up whatever needs it" the model must see the levels. **Owner: broker/main** (brain). One line: `Skills: Fishing 1 (0 xp), Mining 3 ...`, lowest first.
- **G2. get_state extras rendering.** `fishing_spots_nearby` (new) is not drawn by `brain/situation.py`, which renders known keys only (`stations_nearby`, `held_actions`). Either add a line or, better, render any `*_nearby` extra generically. **Owner: broker/main.** Until then the model reaches spots through the `fishing_spots` read tool and the `fish` description.
- **G3. Unlocks gate everything early.** Altar, plots and chests appear only after item/actor discoveries (capability agent's live P1a). The model needs `buildables` (capability agent's new read tool) plus `lookup` for unlock rules. No code path should hard-code an unlock order.
- **G4. Quest dialogue.** Growing Pains (Farming) and Shrimp Catcher (Fishing) start from the Wise Old Man. Whether the quests gate the actions or only the tutorial is **[UNVERIFIED]**. Recipes show the Coarse Net unlock = Coarse Thread + StartingBench (no quest), and Farming needs `bFarmingUnlocked`. **Now designed and built offline: `talk.lua`** (`talk {target?, choose?, leave?}`; docs/design/talk-primitive.md, under review; 37 offline tests).
- **G5. The pytest collection is broken right now** by a circular import in brain/ (situation → needs → map_memory → predicates → situation). Not mine; reported to main 2026-10-26.

## 3. Search record
- **Has this been done?**
  - mineflayer `bot.fish`: equip the rod, look at water, activate, await the bobber event, verify the collected item. The ADAM wrapper times out at 60 s with a "stand near and look at water" reason, and minecraft-fishermen goes to the nearest water first. Adapted: find the spot, equip, approach, act, verify from game state, and give a truthful reason on timeout.
    - https://huggingface.co/OpenCausaLab/ADAM/blob/main/env/mineflayer/lib/skillLoader.js
    - https://github.com/wooneusean/minecraft-fishermen
  - Palworld UE4SS fishing mods skip the minigame (some call the fishing-success RPC). Rejected: PRINCIPLES 1, real inputs only.
    - https://www.nexusmods.com/palworld/mods/3850
    - https://www.nexusmods.com/palworld/mods/3798
- **Idiomatic way / game controls:**
  - Dragonwilds fishing guide: nets work only in net spots (hold LMB inside); rods cast to the larger far ripples; on a bite press A/D against the fish, then hold LMB to reel; Ash Rod at Fishing 3; Coarse Net from 2 Coarse Thread. https://www.bisecthosting.com/blog/runescape-dragonwilds-fishing-guide-how-to-fish-skill-tree-leveling-spells-more
  - The wiki mirror: "Fishing" (Mechanics / Net Fishing / Rod Fishing), "Fishing training", "Runecrafting" (Rune Altar / Attunement / Infusion / Auto Craft / Anima Vents), "Agility" (Courses / Passive XP), "Agility Course" (Chasm Dash), "Farming", "Cooking", "Construction training". https://dragonwilds.runescape.wiki/w/Fishing
- **Docs/source:** reflection dump 26161880:
  - `UPlayerFishingComponentV2` (l.29822): InternalState, FightingFishInternalState, Settings with RodFishingInputActions, the replicated result;
  - enums `EFishingComponentInternalActivity`, `EFishingRodCastResult`, `ECatchableFishResult`, `ECatchableFishSwimmingState`;
  - `AFishingNodeV2` (l.10840): CompatibleToolCategory, IsDepleted/IsBlocked/IsInUse;
  - `ADominionPlayerCharacter.FishingComponent` (l.9947);
  - `URunecraftingMainPanel` (l.32462); `AAgilityCourseManager`/`Starter`/`Orb` (l.8428-8508); `UFarmSlotComponent` (l.22338).
- **Decision:** adapt (the mineflayer act → verify shape) and build the minigame driver on the game's own input actions and replicated state. No reusable library exists for Dragonwilds; a search for Dragonwilds bots/mods with fishing automation found nothing.

## 4. Fishing primitive (built): `client_mod/scripts/fishing.lua`
- **Goal:** asked to fish, or to train Fishing, he walks to a spot he has a tool for, takes the net or rod out, catches N, and says what he caught and the XP. Every failure is one truthful sentence.
- **Approach:**
  - **Spots.** `FindAllOf("FishingNodeV2")` (C++ base class) → id, name (`DisplayNameText`), method = the last segment of `CompatibleToolCategory` ("net"/"rod"), level, depleted/blocked/in use.
  - **Tool.** A carried item whose `Category` tag equals (or is a child or parent of) the spot's tag; highest PL (`weapons_data`). Equipped through `inventory.equip` and verified held.
  - **Net.** Approach the node centre (1 m), hold the held item's primary input (`PlayerInputBufferInputActions.PrimaryAction`, injected each frame) for 2.5 s, then wait for the bag delta. After two silent trawls with no stamina spent, he walks in once more and then fails `trawl_not_running` ("I may not be standing inside the spot").
  - **Rod.**
    - Stand on a circle point 10 m from the node, nearest side first, trying 8 candidates.
    - Face the node. Hold primary for `frac × TimeToFullyChargeRod`.
    - `frac` comes from ballistics over the component's own `RodChargeFractionToProjectileSpeed` curve and `RodCastLaunchAngle`, times a per-rod learned correction `k` (landed / predicted, from `InternalState.HitLocation`).
    - Misses (`CastResult` Missed_*) re-aim; 3 misses → the next bank spot.
    - Wait for the bite (activity 2 → 3). Fight: each frame, hold `PullRodRight` when the fish swims left, `PullRodLeft` when it swims right, `Reel` while it rests (the component's Settings input actions, never key names). It self-checks the pull direction once: if the reel progress falls while pulling, it swaps.
    - The verdict is `InternalState.FishingResult` + `AwardedItemData`, plus the bag delta.
  - **Result.** data {caught, junk, escaped, casts, trawls, gained {item = n}, xp {skill = +n} from the SkillComponent rows before and after, spot, method, tool}.
  - **Arbiter** level `task`, resumable after a reflex fight. `DW_PAUSE` → `interrupted/world_teardown` with no game calls.
- **Failure codes** (data.why, with the detail spoken as is):
  - `no_spot`, `all_depleted`, `no_tool` (names the method needed), `unknown_spot`, `inventory_full`;
  - `cant_reach_spot` (distance), `trawl_not_running`, `nothing_caught`, `no_stamina`;
  - `no_bank_spot`, `cast_not_running`, `no_bite`, `fish_escaped`, `fight_too_long`;
  - `depleted` mid-job (ok = true with what he got, if anything), `equip_failed`, `preempted`, `timeout`.
- **Generality check:** no item, spot or place names in logic (the test asserts no `ITEM_` in the module). Methods and tools come from gameplay tags, so a new net or rod tier, a new spot type or a new region needs nothing.
- **Principles:** real inputs only. The component sends its own Server_Notify* RPCs from our inputs; we never call them. Read-only state. The model decides when, where and how many (PRINCIPLES 2, 4b).
- **Acceptance:**
  - offline `client_mod/tests/test_fishing.lua`: 83 checks (pure functions, net/rod whole jobs, learning a 1.35× cast bias, inverted controls, no bite, unreachable spot, outside spot, depleted, cancel, pause, read tool, manifest);
  - **live:**
    - P1: the read-only probe (nodes, tags, Settings, input actions);
    - P2: a net trawl at a dev spot with a granted Coarse Net (harness fixture);
    - P3: a rod catch.
- **Verified live by P1** (DISCOVERIES "Skills probe P1"):
  - the node tag equals the item category tag (`Item.Equipment.Tool.Fishing.Net`/`.Rod`);
  - Settings: charge 3.0 s, angle 30, speed curve 800→1800, which throws about 6–29 m (cfg fallbacks updated);
  - the input actions `IA_FishingMiniGame_MoveLeft`/`MoveRight`, `IA_Fishing_Reeling` and `IA_FishingMiniGame_Exit`;
  - the replicated InternalState is readable when idle.
- **[UNVERIFIED] to probe live:**
  - nets need standing inside the node's collider (1 m tolerance);
  - the rod distance band of 6–18 m;
  - the launch angle being relative to a 0-pitch camera;
  - holding `ReelInputAction` reels, and pull = inject X=1 on the pull actions;
  - the replicated InternalState updates on the owning client.

## 5. Farm tending (built; the capability agent agreed I own it): `farm.lua` `tend {plot, item?, times?}`, `farm_plots`
- Read the plot (`UFarmSlotComponent`: `GetSoilState`, `CanHarvest`, `CanHealDisease`, `IsFullyWatered`, `IsFullyFertilized`, `AreWeedsFullyGrown`; `FFarmPlotVisibleState.PlotStage`/`GrowthStage`/`WateringProgress`) and report the next step. The model picks the step, or omits it and takes the reported one.
- Revised while building: there is **no stage → item table**. `farm_plots` reports the game's own reads, the MODEL picks the carried item (its held_actions/prim names show Dig / Scatter Seeds / Pour / Fertilize), and `tend` equips it, faces the plot, presses its primary through `input.gate`, and verifies that the plot reads or the bag changed. `times` re-presses while nothing has changed yet, e.g. weeds needing several digs.
- Harvest and cure: the interact press.
- Never `UFarmCommandComponent.Server_Try*`.
- Blocked live on `bFarmingUnlocked=false` and on a built plot.

## 6. Agility course runner (built): `agility.lua` `agility_course {course?}`, `agility_courses`
- Find `AAgilityCourseStarter` actors (class family), interact, then press the start banner's own button (`UAgilityCourse_StartBanner.OnStartCourseButtonClicked`, the widget click handler **[UNVERIFIED]**).
- Then go to `AAgilityCourseManager.NextOrbInSequence` repeatedly through move.lua (with its jumps/links). Each orb is collected by overlap.
- Done = `Client_ValidatedTime`, or `bIsRunningAgilityCourse` going false with an XP rise. Failure = the left-zone or died notifications.
- Reasons say which orb and why (e.g. "the next orb is across the chasm and I can't jump that far yet").
- Depends on move.lua traversal (locomotion agent); verify on dev.

## 6b. Tool-choice check with the real model (Haiku 5.5, 13 calls)
- Script: scratchpad `skill_tool_eval.py`, built on `evals.manifest_eval`. Result: `logs/evals/skill_tool_eval_20261026-084226.json`.
- **7/8 PASS.** The lines name the skill only, never a tool or method:
  - "level up your fishing for a bit" → `fish`;
  - "can you get some fishing xp in?" → `fish`;
  - "catch us some shrimp from that water" → `fish`;
  - "work on your agility" → `agility_course`;
  - "train farming on that plot over there" → `tend {item: Wooden Spade, times: 3}`;
  - "get your woodcutting up" → `gather oak`;
  - "do some mining training" → `gather "ore"` (a generic word the gather resolver may not know; gather owner);
  - **FAIL**: "go level up whatever's lowest" → no tool and no speech, which confirms **G1**: the digest has no skills line, so he can't see what is lowest.

## 7. What remains per skill (summary)
- Attack, Woodcutting: none. Mining: live-verify the ore profiles. Artisan, Cooking: a station via `build`. Ranged: bow + ammo crafted, `equip` before `attack`. Magic: runes (Runecrafting) for `cast`; staff engage (combat agent).
- Construction: `build` (capability agent) + repair.
- Farming: plot unlock + `build` + `tend` (§5) + quest talk (G4).
- Fishing: live probes P1–P3. A Coarse Net needs Coarse Thread (flax → spinning wheel; `craft_plan` shows the chain).
- Runecrafting: altar unlock + `build` + a probe of `craft` at the altar (else `runecraft.lua` Auto Craft) + anima vent interact.
- Agility: course runner (§6); passive walking already gives XP.
- All: G1 (skills line in the digest) and G2 (render the extras) are brain-side, owned by main/broker.

## 10. M5 `brynmoor_quest_chain` audit: Rune Mysteries → Goblin Diplomacy (2026-10-26)

Sources:
- wiki mirror "Rune Mysteries", "Goblin Diplomacy", "Ratcatcher", "Zanik";
- dump: `UQuestProgressComponent` l.31595, `FQuestProgress` l.6450, `UQuestData` l.31475;
- live P1: ClaudeDev's quest list has First Steps given (Objective2), with Rune Mysteries, Dragon Slayer and others ungiven.

### Prerequisites
Rune Mysteries requires **Ratcatcher**, which requires Getting Started (the "First Steps" chain).
- ClaudeDev is still on First Steps Objective2, so the chain begins earlier than Rune Mysteries.
- Ratcatcher: talk to Vannaka, kill 4 giant rats (raw rat meat), build a campfire (4 ash logs + 4 stones), cook 2 rat roasts, bring them to Vannaka.

### Rune Mysteries (wiki)
| Step | Body needs | Have? |
|---|---|---|
| Talk to Zanik (east of Vannaka) | find her; `talk` | `talk` built (P2 pending live); she is perceived as an interactable with prompt Talk. Locating her beyond perception relies on `lookup`/wiki plus `explore`/`go_to`. |
| Gather 50 ash logs | `gather ash` | yes (verified) |
| Talk to Zanik again; receive a stone pickaxe | `talk` | built |
| Mine rune essence (shoot the floating rocks down with ranged or magic, or mine the ground rocks) | `gather rune_essence`; `attack`/`cast` at floating rocks | gather profile exists, unverified live. Shooting floating essence down: an `attack`/`cast` at a non-creature target is **a gap** (combat targets creatures). |
| 12 stone + 4 rune essence → build a Rune Altar | `gather stone_rock`; `build` (capability agent) | build exists. The altar unlocks on getting essence [UNVERIFIED]. |
| Craft air + astral runes at the altar | `craft` at RuneAltar | covered offline (crafting.lua altar support plus closing its own screen, 2026-10-26); live unverified |
| Talk to Zanik → quest complete | `talk` | built |

### Goblin Diplomacy (wiki)
| Step | Body needs | Have? |
|---|---|---|
| Talk to Zanik on the ridge (Bramblemead Valley) | travel + `talk` | `talk`; travel by `go_to`/lodestones. A **lodestone teleport** primitive is a gap (GOAL §4 item 9). |
| Get a Bandosian amulet from the Outlook Ruins reliquary (or the Adventurer's Guild one, behind thorny vines that need Woodcutting 20) | find and open a reliquary: `interact` (Take); clear goblins: `attack` | `interact` covers open/take if the reliquary is a container/interactable [UNVERIFIED]. Cutting the vines: `gather`, or `use_action` with an axe [UNVERIFIED class]. |
| Optional: bribe a caged goblin (one steak) | `talk` + an item hand-in through dialogue | `talk`. Whether the hand-in is a dialogue option is [UNVERIFIED]. |
| Clear the goblins near the other caged goblin, talk to it | `attack`, `talk` | yes |
| Go down into the Whispering Swamp, find the cave, kill the Garou Druid (strong, poison; ranged/magic advised) | traversal down; `attack` (+ `cast`), anti-poison, food | combat yes; a ranged weapon needs ammo. Navigating down into the swamp is move.lua's job. Anti-poison crafting goes through `craft` (brewing). |
| Return to Zanik → complete | travel + `talk` | yes |

### How quest state is read (built)
- `client_mod/scripts/quests.lua` (new) reads the controller's `QuestProgressComponent.Quests`, read-only:
  - each quest's `UQuestData.QuestName`;
  - its state (ungiven / given / complete);
  - the current step **in the game's own words**: `Objectives[CurrentObjective]` gives Description, SubobjectiveDescription and Hint;
  - QuestInts / QuestBools as counters and flags.
- It publishes the read tool `quests {all?}` and get_state extras `quests = {active, complete, counts}`, the same rows the harness probe's `quests` field reads.
- `talk` replies also carry `quests_changed`.
- Tests: `client_mod/tests/test_quests.lua`, 17 checks: the REAL reader over TArray/TMap wrappers.

### Gaps (owner)
1. **Lodestone teleport** (Goblin Diplomacy's back-and-forth; the wiki recommends one at Zanik). Capability/locomotion; the lodestone is an interactable with prompt "Teleport" (DISCOVERIES R2 census).
2. **Hitting a non-creature target** (floating rune essence over a geyser; also Pure Essence rocks at anima vents). Combat/spells: `attack` and aimed `cast` at an actor that isn't a creature.
3. **Brain rendering**:
   - the `quests` extras line in the digest, so the model sees the current step every turn (broker; same as G2);
   - a quest-chain goal for the Director: next step = the active quest's step. No quest-specific code; the step text comes from the game.
4. **Live verification**: talk P2/P3, reliquary interaction, the altar craft, rune essence profile.
5. **Earlier chain** (First Steps → Ratcatcher): needs a Campfire build plus cooking (both covered), rat kills (attack), and a hand-in through talk.

## 11. M2 every-spell stress: the body's side, spell by spell (2026-10-26)

Source: `data/spell_effects.json` (52 entries, build 26161880), the T0 dev-measure runs (`logs/evals/20261026/*dev-measure*/cases.jsonl`, read only), and `client_mod/scripts/spells.lua`.

**How the body casts:**
- Every cast opens the wheel (Q), turns pages until the slot's slice shows the spell, then selects it. Page turns are tested up to page 3/4, with wrap-around and the shorter direction.
- The slot is matched by icon. A mismatched icon on the right page is matched by the radial's own name instead (fixed 2026-10-26 for Enchant Weapon: Fire).
- Selection uses the number keys 1-8. Keyless slots 9-12 use the radial's own highlight, a name check, then accept.
- **instant**: selecting casts it.
- **placed**: the placement preview, aimed at a target or ground spot, released when valid.
- **aimed**: the aim preview, re-aimed until valid and on target.
- **instant_after_move**: handled as instant (Recall) **[UNVERIFIED semantics]**.
- The game's special requirement (held weapon, rod, axe, claimed bed, ...) is checked before any press.
- Every cast is verified by runes spent + cooldown (settled), plus the effect evidence the bench reads.

**Runes:**
- He crafts them at a Rune Altar he builds himself (1 Rune Essence → 5 runes). Unlock levels: Air RC 1, Astral 3, Earth 15, Fire 25, Nature 38, Law 50; Water is crafted at the altar too.
- He can also siphon anima vents (10 essence → 100 runes of the vent's type, any level).
- Dev-world fixtures grant runes for T0.
- Unlocks are skill levels in the named skill (the `unlock` column). The bench unlocks them as setup.

Status column: **live** = cast with its effect observed on dev; **T0** = the latest dev-measure result; **ready** = the body path exists and offline tests cover its cast type, but nothing has run live yet. Empty-cost rows are n/a (13 in the data: hidden/system spells, not on the wheel).

| Spell | Type | Unlock | Runes | Requirement | Effect proof (bench) | Status | Gap |
|---|---|---|---|---|---|---|---|
| Axtral Projection | aimed | Woodcutting 11 | Air 10, Astral 5 | Logging Axe | spell_actor, target_health_drop | ready | live T0 run |
| Bark to Bones | placed | Artisan 11 | Earth 10, Nature 10 | Cast on a Tree | spell_actor | ready | placed on a specific station/tree: target must be that thing |
| Bones to Peaches | placed | Cooking 28 | Earth 5, Nature 10 | - | spell_actor | ready | live T0 run |
| Cabbage Rain | placed | -  | - | - | spell_actor | n/a | hidden/system spell (no runes, not on the wheel) |
| Confuse | aimed | Magic 30 | Astral 25 | - | needs_live_observation | ready | effect proof undefined: needs one live observation |
| Detect Ore (Alt) | instant | -  | Fire 5 | - | ge_added | ready | live T0 run |
| Divine Rock | placed | Mining 80 | Earth 100, Nature 100 | - | needs_live_observation | ready | effect proof undefined: needs one live observation |
| Enchant Chef's Tools | placed | -  | - | Cast on Cooking Range | spell_actor | n/a | hidden/system spell (no runes, not on the wheel) |
| Enchant Weapon: Air | instant | Attack 30 | Astral 5, Air 15 | A held melee weapon | held_item_effect | ready | live T0 run |
| Enchant Weapon: Earth | instant | -  | Earth 15, Astral 5 | A held melee weapon | held_item_effect | ready | live T0 run |
| Enchant Weapon: Fire | instant | Attack 20 | Fire 15, Astral 5 | A held melee weapon | held_item_effect | live |  |
| Enchant Weapon: Water | instant | Attack 50 | Water 15, Astral 5 | A held melee weapon | held_item_effect | ready | live T0 run |
| Enfeeble | aimed | Magic 61 | Water 20, Astral 20 | - | needs_live_observation | ready | effect proof undefined: needs one live observation |
| Eye Of Oculus | instant | Construction 11 | Astral 3 | - | spell_state, view_target, spell_actor, input_mode, ge_added | live |  |
| Fire Spirit | instant | Runecrafting 42 | Fire 10 | - | tag_added, ge_added | ready | live T0 run |
| Fishing Frenzy | placed | Fishing 10 | Water 15, Astral 5 | - | spell_actor | ready | live T0 run |
| Fishnado | placed | Fishing 55 | Nature 5, Air 15 | Fishing Rod | spell_actor | ready | live T0 run |
| Home Teleport | instant | Runecrafting 27 | Law 15 | Claimed Bed | needs_live_observation | ready | effect proof undefined: needs one live observation |
| Humidify | aimed | Farming 28 | Water 15, Astral 10 | 50 units of water (clean or dirty) | spell_actor, world_module | ready | live T0 run |
| Infernal Rod | instant | Fishing 30 | Fire 50 | Fishing Rod Equipped | held_item_effect | ready | live T0 run |
| Internal Alchemy | instant | Cooking 20 | Nature 10 | - | world_module | ready | live T0 run |
| Magic Focus | instant | -  | - | - | needs_live_observation | n/a | hidden/system spell (no runes, not on the wheel) |
| Magical Mending | placed | Artisan 56 | Earth 20, Nature 10 | - | spell_actor | ready | live T0 run |
| Mucksplosion | placed | Farming 80 | Earth 20, Astral 15 | 150 units of compost | spell_actor, world_module | ready | live T0 run |
| Overdrive | placed | Artisan 48 | Water 5, Air 15 | - | spell_actor | ready | live T0 run |
| Personal Chest | instant | Construction 40 | Law 20, Astral 15 | - | spell_state, input_mode, ge_added | live |  |
| Phase Dash | instant | Agility 44 | Astral 10, Air 20 | - | air_dash_m | live |  |
| Rapid Growth | placed | Farming 74 | Earth 30, Nature 30 | - | world_module, spell_actor | ready | live T0 run |
| Rapid Growth | placed | -  | - | - | spell_actor | n/a | hidden/system spell (no runes, not on the wheel) |
| Recall | instant_after_move | Agility 57 | Law 15, Air 30 | - | needs_live_observation | ready | effect proof undefined: needs one live observation |
| Rocksplosion | placed | Mining 11 | Earth 30, Fire 15 | Pickaxe | spell_actor | ready | live T0 run |
| Runes To Rune Essence | placed | Runecrafting 61 | Water 5, Astral 5 | - | spell_actor | ready | live T0 run |
| Shadow Veil | instant | -  | Astral 20 | - | ge_added | ready | live T0 run |
| Snare | instant | Ranged 12 | Earth 15, Nature 10 | - | spell_actor | ready | live T0 run |
| Spectral Arrows | instant | Ranged 25 | Air 5, Astral 15 | 2-Handed Bow. | held_item_effect | ready | live T0 run |
| Splinter | placed | Woodcutting 27 | Earth 10, Nature 5 | - | spell_actor, target_gone, drops_spawned, target_health_drop | live |  |
| Summon Elemental Spirits | instant | Runecrafting 19 | Earth 5, Astral 5 | - | needs_live_observation | ready | effect proof undefined: needs one live observation |
| Summon Shelter | placed | Construction 20 | Earth 10, Astral 10 | - | spell_actor | live |  |
| Summon Stone Spirits | instant | Mining 24 | Earth 5, Astral 5 | - | spell_actor, input_mode | live |  |
| Superheat | placed | Artisan 20 | Fire 15, Air 5 | - | spell_actor | ready | live T0 run |
| Surge | instant | Magic 11 | Law 10, Astral 10 | - | dodge_distance_gain_m | live |  |
| Tempest Shield | instant | Attack 11 | Air 15 | - | tag_added, ge_added | live |  |
| Trunk Totem | placed | Woodcutting 50 | Law 10, Nature 30 | - | needs_live_observation | ready | effect proof undefined: needs one live observation |
| USD_GetWaterFromWaterSource | instant | -  | - | - | needs_live_observation | n/a | hidden/system spell (no runes, not on the wheel) |
| USD_SiphonAnimaCharge | instant | -  | - | - | world_module | n/a | hidden/system spell (no runes, not on the wheel) |
| USD_SiphonRunes | instant | -  | - | - | world_module | n/a | hidden/system spell (no runes, not on the wheel) |
| Uproot | instant | Farming 15 | Earth 10, Astral 10 | - | world_module, spell_actor | ready | live T0 run |
| Vengeance | instant | Magic 80 | Earth 10, Astral 20 | - | tag_added, ge_added, spell_actor | ready | live T0 run |
| Weapon Barbs | instant | -  | - | - | needs_live_observation | n/a | hidden/system spell (no runes, not on the wheel) |
| Weapon Poison | instant | -  | - | - | needs_live_observation | n/a | hidden/system spell (no runes, not on the wheel) |
| Whetstone | instant | -  | - | - | needs_live_observation | n/a | hidden/system spell (no runes, not on the wheel) |
| Windstep | instant | Agility 5 | Air 5 | - | tag_added, ge_added, jump_apex_gain_m | live |  |
