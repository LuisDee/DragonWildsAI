# Competence map: what a competent Dragonwilds player does, and what Claude can do today (2026-11-01)

Research only: no code changed, no model calls, no game client. Game build 26161880 (client 26162923). Sources:
- the game data in `data/` (`recipes_26161880.json`, `items_26161880.json`, `places_26161880.json`, spell files);
- the reflection dump `dumps/26161880`;
- the wiki mirror `data/wiki` (fetched 2026-10-25; CC BY-NC-SA, URLs below);
- our docs and logs;
- the web.

Three parallel research passes (ranged/magic, quests, crafting/farming) fed sections 2.3-2.6 and 4. Their claims are marked UNVERIFIED where nobody checked them live.

Labels used throughout:
- **Status:** **can** (verified live, with where), **partly**, **can't**.
- **Gap type:** **T** missing tool, **P** missing perception, **K** missing knowledge in the model's context, **B** body skill unreliable.
- **Tests:** they use the H/A levels of `docs/research/2026-11-01-evals-human-standard.md` §2.a. **H** = to spec, time ≤ 1.5× the human time, 0 misses, 0 corrections, and he says so. **A** = to spec, time ≤ 2.5×, at most 1 correction.

## 0. Summary

**The biggest gaps.** The pattern is not missing intelligence: it is missing numbers and sources in front of the model.
1. **No value or cost data for the model to compare options with.**
   - Food sustenance reads as the word "Sustenance": the FText label, not the `DT_FoodSustenance` row.
   - Armour defence numbers are never read.
   - Nothing carries a time or risk estimate.
   - So "low food → berries" is the only plan he can see. The fix is perception (an options-with-costs digest), not a rule. See section 3.
2. **No "where does X come from" index.** Flax, feathers, meat, fur and hide all plan as "obtain". The wiki mirror already has the drop tables: 257 pages, 633 items. Kebbits drop no meat at all, so Luis's "kill animals and cook them" needs rats or chickens.
3. **`craft_plan` never says "build the station first"**, and never mentions the roof rule. The Spinning Wheel, Stone Range and Fletching Bench need a roof, so a bow from flax needs walls and a roof first.
4. **Quests are blocked at step one.**
   - `talk` is opt-in only (`client_bridge.lua` l. 1217-1218), and its `options` came back empty.
   - `choose` and hand-in have never run live.
   - Quest markers (`AQuestLocation`) are in the game but not read.
5. **Rung 2 basics are still open** (2026-11-01 retro): pickups that refuse the highlighted stick, chat that cuts the running action, and far players that can't be found. Every rung below stands on these.
6. **Combat assessment ignores armour**, and he flees PL1 goblins. His power level is the average of his worn armour, so "is my armour good enough" means "my PL vs the region or target PL".

**The proposed ladder, top 6** (section 5):
- L0: Rung 2 co-play basics.
- L1: a self-sufficient day (efficient food, clean water, rest; 60 min, no help).
- L2: the tutorial quests First Steps → Getting Started → Ratcatcher. They teach exactly Luis's list: a camp, first tools, killing rats, cooking.
- L3: Rune Mysteries plus the First Steps finish.
- L4: melee at his level plus PL1 armour from kebbit fur.
- L5: walls and a roof (A Room With A Garou) → Spinning Wheel → bow and arrows → ranged.

**Ranged and magic verdict: feasible, not blocked.**
- **Bow: moderate work.** Arrow drop is small: 5000 cm/s, -600 cm/s², 0.3 s straight, so about 27 cm at 30 m. Lead dominates. The existing solver is sound. Its inputs are wrong:
  - it taps instead of drawing;
  - it tracks the next nocked arrow, then mis-learns from that;
  - it aims at the capsule centre, not the head.
- **Crossbow: probably the easiest bow-type option** once its held block is removed.
- **Staff: probably the easiest to hit with.** The game's own targeting and homing modules do most of the work. Today the projectile scan never matches the staff projectile class.
- **Lock-on:** a camera aid (`IA_ToggleLockOnTargeting`, 32 m). Keep direct aim, and measure lock-on once as a baseline.

## 1. What "seamless" means (answering "question me")

Quests are a good acceptance test but a poor training order. Even the early quests chain dialogue, travel, a camp, crafting and fights, so one weak link fails the whole quest and says little about which link it was. Examples of a weak link: a pickup that refuses the highlighted stick, or a fight he flees at once. What a mate who "just plays" does without being asked, roughly in the order a new player learns it:

1. **Never be a burden.** He stays fed, watered and rested on his own, eating the most efficient food for where he is. He never dies to hunger, a fall or a PL1 goblin, and he gets his grave back.
2. **Do what's asked the first time, in the asker's words.** All of these failed in the retro: "the 2 stone in front of me", "come here" from 300 m, "drop 40 keep 80", and "where are you going?" mid-walk without stopping.
3. **Have a camp.** His own campfire, crafting table, chest and bed near where the group plays, and he knows what each station makes.
4. **Haul and process.** Chop, mine and pick; carry it home, store it, smelt it and cook it; say what he used and what he collected.
5. **Fight at his level.** He:
   - picks a weapon and style for the target;
   - keeps his armour in step with the region;
   - defends when hit;
   - kites what he can't tank;
   - never runs 200 m off.
6. **Progress his gear.** He knows the next tier and plans its whole ingredient tree, including the stations he must build first.
7. **Know the world.** Map and wiki names resolve to places he can walk or teleport to, and he recognises a place from its description.
8. **Plan ahead.** "I'll need more flax, so I'll plant some" needs two things: memory of demand (what upcoming recipes need) and the time cost of foraging against farming.
9. **Then quests.** They combine all of the above with dialogue choices, quest items, puzzles and bosses.

## 2. The map, by group

**Tools the model has today.** These are the `llm = true` entries in `client_mod/scripts/manifest.lua` and the modules' own `M.MANIFEST` blocks:
- **Moving and items:** go_to, follow, stop, interact, drop, look, inspect, inventory, consume, move_item, collect_water, store, take, equip, unequip, set_vitals_policy, explore.
- **Combat:** attack, use_action, held_actions, combat_orders, combat_brief.
- **Skills:** gather, fish, fishing_spots, tend, farm_plots, craft, recipes, craft_plan, stations, buildables, build, cast, spells, lodestones, teleport, quests, agility_course, agility_courses.
- **Brain-side:** lookup, remember, run_skill, and the reflex-rule tools.

Not offered to the model:
- `shoot`: llm=false, and it has never run live;
- the fetch, come_to, give and recover_grave composites: llm=false;
- `places`: llm=false; places reach the model through `map_names` and `go_to`;
- `talk`: the module is not loaded unless `_G.DW_ENABLE_TALK` is set.

Sleeping is `interact` on a bed or a Summon Shelter cast.

### 2.1 Survival

| competency | status (evidence) | gap | how the model discovers it | test |
|---|---|---|---|---|
| Eat when hungry | **can**: the stay-fed reflex eats hotbar food below 40 % (`inventory.lua` `REFLEX_CFG`; the model sets the policy with `set_vitals_policy`); `consume` verified live (DISCOVERIES l. 2121; 16 Redberry uses on 10-26, BUGS L38) | B: bag food needs `move_item` first | tool descriptions say so | never below 25 % food in a 60 min solo run |
| Pick the most efficient food | **can't** (section 3): no value numbers, no hunting option, berries primed by the persona | P + K | options-with-costs digest built from food data, drop tables and the map (section 3.3) | replay eval of the 11:00 co-play state; live 20 % -> 70 % food in 3 min (H) |
| Drink clean water | **can**: `collect_water` live-verified (`skills.lua` MANIFEST comment: 2 Dirty Water at (157, 1914) m); 2 Dirty -> 2 Clean Water at a Campfire, 81 s (DISCOVERIES Codex fact 23); the dirty-water crash fixed by fxguard (BUGS L38) | - | `collect_water` says "boil it at a Campfire" | hydration never below 25 % in 60 min |
| Know the vitals are lethal | **can**: the needs line gives the time to zero and "at 0 it hurts until you die"; dehydration and starvation killed him in this build (DISCOVERIES l. 1037, 1970). The wiki's "cannot die at 0" is wrong for this build. | - | needs line | no survival death in 3 sessions |
| Rest / endurance | **partly**: Summon Shelter sleep works live (retro; Codex fact 21); endurance sat at 0 all co-play session (retro 8) | P: the needs line flags rest only below 30 %, and states what endurance 0 costs (no sprint, failed jumps) only at exactly 0. Lower max sustenance and carry weight, and faster hunger at rest ≤ 25 (wiki Rest), are not in the line. | needs line + the wiki Rest page (a nap restores 1 point/s; a night refills it) | endurance never 0 in a 60 min session; he sleeps when night falls near a bed |
| Heal | **partly**: `heal_below_pct` exists but is off by default (nil); carried food shows its heal | K: the model doesn't see that dried berries heal 20 and raw ones 10 | the same digest | below 30 % HP after a fight, he eats healing food before the next fight |
| Recover his grave | **partly**: interact "Take All" verified (DISCOVERIES l. 1036); the grave-memory bug fixed in b70292f; in co-play it failed for 15 min (retro 5) | B (memory) | registry `Gravestones` + death memory | after a death, back with his gear within 3 min, no help |
| Avoid lethal terrain | **partly**: 29 m cliff fall in co-play (retro 9); the explore drop cap (39e8493) is not yet live | B | trip record "fell H m" | no falls > 10 m in 3 sessions |

### 2.2 Base

**Station facts** (L = live, W = wiki, D = game data):
- **Crafting Table:** 4 Ash Logs (L, Codex fact 11). Makes 75 things: stone tools, T1-T2 armour, ash bows, stone and fang arrows, the spade, watering can and compost bucket.
- **Campfire:** **6 Stone** (L). The wiki's 4 Ash + 4 Stone is out of date. It needs open sky above it.
- **Stone Range:** 8 Ash + 12 Stone + 3 Animal Bone (L). Needs a roof.
- **Spinning Wheel:** 12 Ash + 4 Flax + 2 Stone (W). **Needs a roof.** Unlocks with the first Flax.
- **Tannery:** 12 Ash + 4 Animal Bone + 2 Coarse Thread (W).
- **Kiln:** 8 Ash + 20 Stone + 6 Clay + 10 Fire Rune (W).
- **Furnace:** 24 Stone + 8 Clay + 4 Charcoal + 10 Fire Rune + 8 Vault Shard (W).
- **Blacksmith's, Armour and Fletching Benches:** each 6 Bronze Bar + 20 Ash + 8 Coarse Thread + 1 Vault Core (W). The Fletching Bench needs a roof.
- **Sawmill:** 18 Ash + 4 Bronze Bar + 8 Stone (W). It is the only source of planks (`RECIPE_Resources_Plank_Ash`).
- **Storage:** Small Chest 16 Ash + 2 Coarse Thread, plus the Construction perk Creature Comforts; Crate 10 Ash (PROGRESS l. 306-307).
- **No longer reachable:** the Smithing Anvil was removed in 0.12.0; the Advanced Tannery, Advanced Spinning Wheel and Grill have no loaded actor class.

**Unlocks happen on events, not levels:** the first pickup of an item, or the first use of a station (`DT_Progression_*` queries). His recipe count did not move when his stats were raised to total level 1076 (DISCOVERIES l. 1478). Building costs and unlock rules exist offline only in wiki text. The live `buildables` read is the truth once a piece is unlocked.

| competency | status (evidence) | gap | how the model discovers it | test |
|---|---|---|---|---|
| Build a campfire and crafting table | **can**: Campfire built in P5, +12 XP; Crafting Table and Stone Logging Axe measured live (Codex fact 11). In co-play he refused the first ask (he searched "crafting bench" literally) and built both on the second. | K: name resolution; nothing says he *should* own them | `buildables {about}`; craft_plan's `find_station` step should name the build piece (F4) | fresh character: table and fire within 5 min of spawn, unasked |
| Know he wants his own camp | **can't** | K | when no Campfire is within 60 m, craft_plan says it is a 6-Stone build piece; the wiki station pages; the tutorial quest Getting Started asks for exactly this | Rung 3 run: he sets up a camp before his first cook, without being told |
| Storage | **partly**: `store` / `take` tools exist (offline-tested; no live verification found in DISCOVERIES); a Crate was built in co-play | B; K: the Small Chest needs a perk | buildables | "put your logs in the chest": stored, verified, and he says what |
| Stations that need a roof (Spinning Wheel, Stone Range, Fletching Bench, Loom, Cooking Range) | **can't**: walls and roof are the autonomous-building plan (`docs/research/2026-11-01-autonomous-building.md`), not done | T (multi-piece build) + K (the roof rule is wiki-only) | the build piece's notes from the wiki; placement validity comes from the game's own preview | a working spinning wheel under a roof he built |
| Fuel and processing | **partly**: Clean Water at a Campfire works live; `stations` reads a furnace's state | K: fuel values (1 Ash Log = 1 min, Charcoal 2 min; wiki Cooking) are not in context | lookup | cooks 6 items on one fuel load |

### 2.3 Gathering and crafting chains

| competency | status (evidence) | gap | how the model discovers it | test |
|---|---|---|---|---|
| First tools from nothing | **can**: sticks without an axe (DISCOVERIES l. 2040); table -> Stone Logging Axe -> fell a tree; Stone Pickaxe -> 13 Stone (Codex facts 11, 22); a stone club in co-play (~12 min, heavy steering) | B (pickups, retro 1) more than K | craft_plan | fresh spawn -> axe, pickaxe and club in ≤ 10 min, unaided |
| Chop, mine | **can**: one ash tree in 9 s; a stone node gave 13 Stone (Codex fact 22) | copper and tin need a tier 2 pickaxe: the Bone Pickaxe, 8 Bone + 6 Ash + 4 Leather, not run live | gather `trains` + wiki | 20 logs + 20 stone in ≤ 6 min |
| Pick plants (flax, berries) | **partly**: interact/fetch work. But flax plans as "obtain", not "gather", because the pickup profiles have no item id (`gather_profiles.lua` l. 102; `crafting.lua gather_for` l. 782). | P (data) | set the profile's `item` (F4) | "get 7 flax" in Bramblemead: 7 in ≤ 4 min |
| Flax -> thread -> bow | **can't** end to end. Ash Shortbow = 12 Ash Logs + 3 Coarse Thread at the Crafting Table (`RECIPE_Weapon_Shortbow_Wood`). Coarse Thread = 1 Flax, or 3 Coarse Animal Fur, at a Spinning Wheel. There is no bowstring item. From nothing: 7 flax, 24 ash, 2 stone, and a roof. | T (roof) + K (station-build step, flax source) | craft_plan + the station-build step + the sources index | ash shortbow from nothing in ≤ 25 min |
| Arrows | **never run**: Stone Arrow ×33 = 1 Stone + 2 Ash Logs + 1 Feathers at the Crafting Table. Feathers come from Chickens (1, always) and Bird Nests (3-5). | K: "Feathers: obtain" | sources index (F2) | 33 arrows in ≤ 5 min near chickens |
| Ore -> bar -> tool/armour | **can't**: Bronze Bar = 3 Copper + 3 Tin -> 2 bars at a Furnace (which needs 8 Vault Shard); the Blacksmith's Bench needs a Vault Core | T/K/B; a long chain | craft_plan with build steps; the Director's board | Bronze Pickaxe from scratch, unaided (an M5-sized task) |
| Plan the whole tree | **partly**: craft_plan expands the tree with alternatives and unlock steps (`crafting.lua` l. 368) | K: no station-build step, no raw-material source, weak times (an [8, 12] s default, `crafting.lua` l. 231). lookup misranks: "how do I make a bow" returns Bow of Elidinis / Crystal Bow, and "farming plot" returns the Farming Cape. | F2, F4, F6 | "make a bow": the plan lists every leaf with its source and every station to build |
| Armour from ingredients | **can't**: PL1 Adventurer's Tunic = 9 Coarse Animal Fur and Leggings = 6, both at the Crafting Table (game data). PL2 Leather set = 22 Leather + 16 Coarse Thread; in raw terms 22 Animal Hide, 22 Flax, 4 Bone, 32 Ash. | K + B | craft_plan + sources | PL1 set from kebbit or rat fur within 20 min |

### 2.4 Farming

**Facts** (wiki unless marked):
- **Gate:** farming is locked behind the side quest **Growing Pains**. It starts when you craft a spade or watering can; then you talk to the Wise Old Man, who gives 3 wheat seeds. `bFarmingUnlocked` was false on dev (DISCOVERIES l. 1796).
- **Plot and spade:** an Ash Farming Plot costs 8 Ash Logs and must be outdoors. The Wooden Spade costs 6 Ash + 1 Coarse Thread; it takes 5 digs per weed layer at 10 stamina each.
- **Seeds:** from wild plants (flax 15 %), harvests and traders; no recipe makes them.
- **Water:**
  - Wooden Watering Can: 4 Ash + 1 Coarse Thread;
  - Rain Catcher: 6 Ash + 4 Stone, Farming 6;
  - Water Barrel: 8 Ash, Farming 24;
  - Well: 32 Stone + 6 Ash + 1 Vault Core, Farming 32;
  - rain also waters plots.
- **Compost:** Compost Bin = 8 Ash + 4 Stone, Farming 10. It halves disease and gives ×1.5 yield.
- **Growth:** 2 in-game days; a day is 24 real minutes. Flax yields 3 per plot, 6 when watered and composted.

| competency | status (evidence) | gap | how the model discovers it | test |
|---|---|---|---|---|
| Unlock farming | **can't** (it needs the quest, and talk) | T/B: dialogue | quest log + talk | Growing Pains complete |
| Plot, dig, plant, water, harvest | **partly, never run live**: `farm_plots` reads the game's plot state; `tend` presses a carried item's main action on the plot and checks it changed (`farm.lua` l. 444-463). `docs/design/every-skill-coverage.md` says it is not deployed live; filling a watering can is unverified. | B (unverified) | farm_plots shows what each plot needs | 1 plot: dig -> plant flax -> water -> harvest ≥ 4 flax |
| Decide farming is worth it | **can't** | K + P: no memory of demand (what future recipes need); no time comparison against foraging | the board/Director plus the sources index, e.g. "flax: wild, 1 per plant, 1-day respawn, ~N m away; a plot gives 3-6 per ~48 min" | asked for a leather set (22 flax), he plants flax as part of the plan |
| Compost, rain catcher, well | **can't** | T (build) + B | buildables + farm_plots `fertilized` / `watered` | ×1.5 yield recorded |

### 2.5 Combat

| competency | status (evidence) | gap | how the model discovers it | test |
|---|---|---|---|---|
| Melee a PL1 animal | **can**: Kebbits killed live; dodges 23/24 in one run; parry 4/4 with a shield; disengage + eat + re-engage (DISCOVERIES "Dev-world combat live M1", l. 1812-1830); 2 of 3 of Luis's kebbits in co-play | - | attack, combat_brief | 5 kebbits or rats: 5/5 killed, HP never < 50 % |
| Melee a PL1 humanoid (Goblin Runt) | **partly**: he flees "losing" from the first second and gets dragged 134-200 m off route; a runt killed him (HANDOVER-2026-11-01, open item 1). He stood still while a goblin hit him (retro 8). | B (the assessment, and defending when hit) | combat_brief's estimate. Its `not_counted` already admits it leaves out armour, blocking and dodging (`combat.lua` l. 4244, 4265). | 3 runts one at a time with a stone club and starter armour: 3/3, no flee, ≤ 60 s each |
| Weapon and style for the target | **partly**: `attack {weapon, style}`, `held_actions`, weaknesses from creature_wiki (Giant Rat: weak to Stab, resists Crush), `combat_brief` "your weapons vs it" | K: weakness tags are shown; damage per style is not compared | combat_brief | carrying both, he picks a stabbing weapon over a club for a rat |
| Armour vs his level | **can't** reason about it | P + K: he reads his PL (`BP_GetPowerLevel`, `combat.lua` l. 543), but the situation shows worn names only, with no PL per slot (`situation.py` l. 411). Defence numbers sit in `DT_WearableEquipment` rows that are never read (the wiki Armour page has them: Bronze Platebody 23/17/15 melee/ranged/magic). His PL is the floor of his worn armour's average PL (wiki Power level), so the useful comparison is his PL against the region's (`BP_MapRegion_C.PowerLevel`: Temple Woods 1, Bramblemead 2, Fractured Plains 3, Stormtouched 4) or the target's. | show PL per worn slot and region PL in context; armour defence into the catalog (F1) | asked "is my armour good enough for Fractured Plains?", he answers from the numbers; he upgrades the lowest slot first |
| Defend when hit, then decide | **partly**: self-defence retargets an attacker (the l. 1830 fix); in co-play a goblin hit him while he stood still | B | attacked events | hit from behind while gathering, he fights back within 1 s |
| Spells in a fight | **partly**: Tempest Shield cast in fights; reflex rules exist; 52 spells, most of them utility. Enchant Weapon is blocked at the spell wheel (DISCOVERIES "Slot results 2026-10-26"). | B | castable_spells `how` | when runes allow, he casts a buff before engaging |
| Lock-on, ranged, magic | **partly**: see section 4 | B | | |

### 2.6 Quests

Claude has completed no quest. His live log today has First Steps at "Speak to the Wise Old Man in the temple.", with Growing Pains and Shrimp Catcher active and 0 complete (DISCOVERIES l. 1961, 2206). The wiki lists 9 main and 28 side quests; the last main quest, Regicide, came in 1.0 (2026-09-15).

**The main chain (Kuldra's Saga).** Wiki quest pages. Codes: T talk, Ch choose an option, H hand in, Go travel, Gth gather, Cr craft, Bld build, K kill, Int use an object, Rd read, WS Windstep traversal, Pz puzzle.

| # | quest | giver, place | steps in brief | demands |
|---|---|---|---|---|
| 1 | First Steps | Wise Old Man (WOM), the temple in Temple Woods; ends with him upstairs in Bramblemead Village | tutorial dialogue: "Begin / Skip Tutorial" | T, Ch, Go |
| 2 | Getting Started | Doric, outside the temple | collect dirty water; build a Crafting Table; craft a Stone Club; report back | Gth, Bld, Cr, T |
| 3 | Ratcatcher | Vannaka, south of the windmill | kill 4 giant rats; build a Campfire; cook 2 Rat Roasts; hand in. Reward: stone axe and dagger | K, Bld, Cr, H |
| 4 | Rune Mysteries | Zanik, "near the river, down the road from the temple" | 50 ash logs; a stone pickaxe; rune essence (mine the ground rocks; floating rocks must be shot down); build a Rune Altar (12 Stone + 4 essence); craft Air and Astral runes. Reward: 50 of each | Gth, Bld, Cr, T |
| 5 | Dragon Slayer | WOM, Bramblemead Village | a shelter (foundation, 3 walls, ceiling, bed roll, claim it); a deer's antlers (it flees: needs ranged or magic); Keep of Blue Flames; a vault; Velgar's Rise; a dragon tooth (iron pickaxe), bloodwood sap (iron axe) and 5 bronze bars; **boss Velgar** (PL4, 6,000 HP, 4 phases) | Bld (multi-piece), ranged, K, Int, Rd, boss, Cr (bronze) |
| 6 | Withering Heights | WOM, near Ashien's Watch | a password door, the soul rift, 3 curse fragments (dragons, a zogre, a ghost whodunit answered in dialogue); **boss Imaru** | Pz, Ch, K, boss |
| 7 | Black Knight's Fortress | Death; needs Cooking 41, a spade, steel pickaxe, mithril axe and rod | 13 shards: vines, books in order, digging, Windstep levers, beam jumps; **boss Titan** | Int, Dig, WS, Pz, boss |
| 8 | Icthlarin's Little Helper | the door to Umbral Sands | clan reputation tasks; the Fight Caves (10 waves, items lost on death); **boss Fuzan** | everything |
| 9 | Regicide | the Dragon Gate | a base at Rasthin's Rest, a raid; **boss Kuldra** | everything |

**Side quests that matter early:**
- **Growing Pains** (active): it unlocks farming. Ash plot, dig 5×, plant 3 wheat seeds, water 5× within 6 game-hours, harvest a day later.
- **Shrimp Catcher** (active): net shrimp to Fishing 3, craft an ash rod and bait, rod-catch a sardine. He loses the rod fight to stamina today (DISCOVERIES l. 2034-2039).
- **A Room With A Garou** (Caratacus, Fractured Plains, no prerequisite): build 4 walls and a roof around an NPC. It is the dry run for Dragon Slayer's shelter and for any roofed station.
- **Cook's Assistant:** eggs, wheat and milk.
- **Goblin Diplomacy** (needs Rune Mysteries): a Garou druid that poisons; ranged is advised.
- **Restless Ghosts:** night only; needs Windstep and Woodcutting 20.

| competency | status (evidence) | gap | how the model discovers it | test |
|---|---|---|---|---|
| Talk, read lines, choose | **partly, and off for the brain**. talk.lua loads only with `_G.DW_ENABLE_TALK` (`client_bridge.lua` l. 1215-1218: "stays OUT until its re-review passes"). On the debug channel it opened the WOM dialogue, read 3 lines and left (DISCOVERIES l. 2040-2044). `options` came back empty while the node had two; `choose` has never run live; `interact` "Talk" fails (BUGS L41). | B + T | the talk reply: lines plus numbered options | First Steps: talk, choose, and the quest log advances, in ≤ 3 calls |
| Know the current objective | **can**, as state: `quests` reads `QuestProgressComponent.Quests` with the step in the game's own words, which often name the place. The tool itself has never been called. | - | the quests line in context | - |
| Know where the objective is | **can't** today, but the game has it. `UQuestWorldSubsystem.QuestLocations` holds `AQuestLocation` actors {quest, `QuestLocationName`, type Target/Area/NPC, `Radius`, `bShownByDefault`, position} (Dominion.hpp l. 31638, 12018). The per-player `VisibilityTrackers` (l. 4468) say which ones he can see: the map's yellow circles. UNVERIFIED live; World Partition may stream far ones out. | P | add `where = [{name, type, radius, position}]` to each active quest row; go_to takes it (F5) | reaches the marker of 3 quest steps without looking up a name |
| Hand in items | **unverified** | B | talk reply + inventory change | Ratcatcher hand-in |
| Read a book or note | **can't**: popups are only closed (`input.lua` l. 117) | T + P | put the popup text in the result | Animal Magnetism's message in a bottle |
| Use world objects (doors, levers, statues, wells) | **partly**: collect, Take All, water and chest work; doors and levers never tried | B | interact + inspect | Restless Ghosts' Crumbling Well |
| Dig | **can't**: `use_action` is offline only | B | tend / use_action | the graves in The Great Body Robbery |
| Time of day | **can't**: nothing reads it | P | the in-game clock (`GetInGameTime`, DISCOVERIES l. 1975, server side; client side unverified) | ghosts appear only at night |
| Bosses | **never tried** (`docs/design/velgar.md`: no live data) | B | combat_brief + learned attacks | Velgar |

### 2.7 Navigation

| competency | status (evidence) | gap | how the model discovers it | test |
|---|---|---|---|---|
| Walk to a place or thing | **can**: Rung 1 chat ladder 8/8 reached, mean 2.1 calls (HANDOVER-2026-11-01) | B on cliffs and drops (retro 9) | go_to | Rung 1 stays ≥ 80 % |
| Go to a map name | **can**: go_to takes the 514 landmark and 31 region names (`data/places_26161880.json`, `brain/places.py`). He reached "the temple" by lodestone on his own idea (retro). | P: one-word names; 39e8493's `map_names` candidates helped | `map_names` context; places.py (game data first, the wiki only to connect names) | 10 named places from Luis's own lines: ≥ 9 reached |
| Fast travel | **can**: lodestones and teleport live (Codex facts 10, 24: 1-2 Law Runes, cost read at use) | - | the lodestones read | uses a lodestone on a far leg when it saves > 60 s |
| Find a far player | **partly**: `go_to <player>` failed 6 times beyond ~150 m (retro 3). `mapplayers.lua` (the registry's `PlayerCharacters`) is written but uncommitted and not live. | B/P | the compass registry, as a human uses it | "come to me" from 300 m arrives within 1.2× the walking time |
| Recognise a wiki place in game | **partly**: places.py maps wiki region and NPC sentences to game regions and landmarks. A description like "the cave behind the waterfall" has no route. | P: no semantic map of features inside a region | lookup -> places -> map memory; later a feature layer (PLAN-2026-10-31 item 6) | 5 quest location sentences from the wiki: within 30 m of each |
| Find a resource he hasn't seen | **partly**: `explore {about}` (least-visited legs) and map memory. The wiki says which regions have it (Redberry Bush: Temple Woods, Bramblemead, Dowdun Reach). | K: the region list isn't joined to explore | lookup's regions -> the places polygon -> explore inside it | "find flax" from spawn: one in sight within 3 min |

### 2.8 Co-play: Rung 2, the base everything stands on (from `docs/RETRO-2026-11-01-coplay.md`)

| competency | status | gap | test |
|---|---|---|---|
| Pick up what the player points at | **partly**: 28 `not_interactable` refusals when the highlighted actor was another stick of the same kind (retro 1) | B | Luis-replay "the 2 stone in front of me": H, ≤ 2 calls |
| Keep working while chatting | **can't** yet: every chat line returned `interrupted` (retro 2); `tests/test_chat_mid_action.py` is in progress | B (bridge) | "where are you going?" mid-walk: the walk continues and he answers |
| "Near me" means near the speaker | **partly**: `look near=` and `gather near=` exist, but the context doesn't list what lies near the speaker (retro 4) | P | "grab these sticks near me" from 20 m apart: the right sticks |
| Split a stack | **can't** (retro 7); the split handler was found (DISCOVERIES l. 2295) | T | "drop 40 keep 80", exact |
| Truthful build results | **fixed** at 12:10Z (PROGRESS l. 381) | - | "build a crate": says done once, builds one crate |

## 3. The food example in depth

### 3.1 What the game says food is worth

Food is not just "+X hunger". Per item, the game stores (dump `Dominion.hpp`):
- **`UFoodItemData`:**
  - `SustenanceRowHandle`: a row of `DT_FoodSustenance` (`FFoodSustenance`, l. 3387: `Sustenance`, `DecayBuffer`, `StatText`);
  - `VitalShieldRowHandle`: an extra shield (`FVitalShieldTableRow`);
  - `ToxicityRowHandle`: Soulscourge;
  - `AmountToHealOnConsume` and `BlockEatingTags`;
  - the food perk (`UBuffItemData.GameplayEffectsToApply`).
- **`USustenanceComponent`** (l. 35802): `AddSustenance(SustenanceToAdd, DecayBufferToAdd)`, `ActiveFoodBuff` (one food perk at a time) and `OverEatenGE`.
- **Live behaviour:**
  - The maximum is 100, or 75 after a death.
  - Decay is about 1 point per 14.5 s above 25 and half that below (wiki Sustenance); `DecayRatePerHour` is 4.15 (DISCOVERIES l. 1040).
  - Eating more than 100 builds Over Eating (wiki).
  - **At 0 it kills in this build** (DISCOVERIES l. 1037).

Values per item come from the wiki's Food table and infoboxes (https://dragonwilds.runescape.wiki/w/Food, rev 72760). Weights are from `data/recipes_26161880.json`, which wins where the two differ (e.g. Haunch 0.5 in game data vs 1.0 on the wiki).

| food | sustenance | health | weight | made from | gate |
|---|---|---|---|---|---|
| Redberries (raw) | 5 | 10 (live `AmountToHealOnConsume`; the wiki says none) | 0.1 | Redberry Bush: 3 per Collect, regrows in half a day (Temple Woods, Bramblemead, Dowdun Reach) | - |
| **Dried Redberries** | **15** | **20** | 0.1 | 1 Redberries at a Campfire (processing: load + fuel, 8-12 s, collect) | some burn below Cooking 12 (`ChanceToBurnFoodLevel1`) |
| Rat Roast | 20 | 20 | 0.5 | 1 Raw Rat Meat, from a Giant Rat (PL1, aggressive, 50 HP) | Cooking 1 |
| Fillet + Fried Egg | 20 + 20 | 20 + 20 | 0.5 | a Chicken (PL1, passive, 20 HP) always drops Raw Bird Meat + Egg + **Feathers** (arrows) | Cooking 1 |
| Haunch | 20 | 30 | 0.5 | 1 Raw Game Meat, from a Deer (it flees; "should be killed via ranged or magic") | **Cooking 12** (a power level 2 ingredient) |
| Fried Cabbage / Baked Potato | 20 | 20 | | 1 Cabbage / Potato (farm or world) | Cooking 1 |
| Bread | 30 | 20 | 0.2 | Bag of Flour (grinder chain) | |
| Redberry Roast Rat | 45 | 30 | | Rat Roast + Dried Redberries, at a Stone or Cooking Range | range (needs a roof) |
| Meat Stew / Vegetable Soup | 50 | 50 / 40 | | Fillet + Haunch / Fried Cabbage + Baked Potato | range |
| Fruit Pie | 85 | 90 | | Dried Redberries + Dried Dwellberries + Bread | range |
| Meat / Steak / Forager's sandwiches | 80-85 | 70-90 | 2.0 | 3-4 cooked parts + Bread, with perks | range |

**Kebbits drop no meat:** always Coarse Animal Fur, sometimes Animal Hide Scraps (wiki Kebbit). "Kill kebbits and cook them" would have been a wasted trip. Their fur makes the PL1 Adventurer's armour (9 + 6 fur) and Coarse Thread (3 fur), though. At the 11:00 co-play moment Claude had:
- Cooking 5;
- two Chickens 35 m away ("odds now: likely win");
- a Giant Rat 44 m away;

all in his own perception, and **none of them appeared in his food options.**

**What this means for Luis's example.** He is right on two counts:
- cooked meat fills 4× a raw berry (20 vs 5);
- comparing options is the method.

But next to a campfire, the cheapest big win is **drying the berries he is already picking**. One berry becomes 15 sustenance and 20 HP: three times the raw value, at the same 0.1 weight. One bush dried (45) is worth about one chicken (Fillet + Fried Egg = 40, plus feathers) and twice a rat. Meat pulls ahead in three cases:
- when the berries run out;
- when the kill pays twice (feathers for arrows, fur for armour);
- as an input to stews and sandwiches (50-85 per item) once he has a range.

Deer are never worth it without a bow or staff and Cooking 12. The game itself teaches the meat route in quest 3, Ratcatcher (kill 4 rats, build a campfire, cook rat roasts).

### 3.2 What the brain saw when hungry (co-play log 2026-11-01)

The needs line (`brain/needs.py lines()`), from `logs/brain-live-20261101-115554-7128.jsonl`:

> Need food (hungry, [17%], empty in ~6 min at the current drain; at 0 it hurts until you die) -> carried: none | nearby: Redberries (gives Redberries) (1 m, id ...); Redberries (1 m); Redberries (9 m) | players who could help: luisdeburnaybast (4 m) | craft/cook (estimate; craft_plan confirms): Fried Cabbage (missing 1 Cabbage; at Campfire (5 m, ...)); Dried Redberries (missing 1 Redberries; at Ca

The line ends there: it is 560 characters. A carried item showed as `Redberries x2 (food, hotbar, food Sustenance, heals 10.0)`.

Gaps, in order of cost:
1. **No value numbers anywhere.** `inventory.describe_item` reads `StatSustenance`, an FText that live holds the label "Sustenance", not a number. The amount is in the `DT_FoodSustenance` row. Nearby and craft options carry no value at all, so the model cannot know that drying triples a berry.
2. **Craft options are sorted by fewest missing inputs, in catalog order** (`needs._craft`), cut to 3 and then truncated at `LINE_CHARS` = 560. The best option (Dried Redberries: campfire 5 m, berries 1 m) was listed second and cut mid-word.
3. **No hunting option.** `needs._nearby` lists only ground items and pickups whose item is food. A creature that drops a cookable ingredient is never an option: `creature_wiki.lua` has no drops, and the `lookup` game card says "No crafting recipe makes it (gathered, dropped or found in the world)" without saying by what.
4. **No cost.** Nothing says how long an option takes or what it risks. The ingredients exist: walking 4.5 m/s, an interact ~6 s, an eat ~6 s of use animation (Codex fact 9), processing 8-12 s per item, a fight from `combat_brief`, and a fight at 0.5 HP as the risk.
5. **Misleading knowledge.** The `lookup` game card labels Raw Rat/Game/Bird Meat "Type: Food". Their category tag is `Item.Food`, but their class is `ItemData`: not edible. BUGS L17 found he didn't know raw meat isn't edible.
6. **The wording primes begging and berries.**
   - When the model says nothing, the broker's fallback line is "I'm really ... and have nothing left. Could you bring me ...?" (`brain/broker.py` l. 209-214).
   - Persona example 2 models "starving though, grabbing berries first" as the good answer (`brain/persona.md` l. 15).
7. **No size of the gap.** The line never says how many points he is short. From 17 %, full is ~83 points: about 6 dried berries or 17 raw.

### 3.3 What would let the model reason "cooked meat is worth the detour"

An **options-with-costs digest**: perception with numbers and no ranking rule. For each pressing need it lists every way the game offers, with value, time and risk, computed from data:

```
Need food 17% (~83 to full; empty in ~6 min) -> options (value | time | risk):
- carried: none
- Redberry Bush x3 (1-9 m): 3 Redberries each; raw +5 food +10 HP each | ~10 s per bush
- dry them at Campfire (5 m; fuel 1 Ash Log per min): Dried Redberries +15 food +20 HP each | +8-12 s each; some burn at your Cooking 5
- Chicken x2 (35 m, PL1, passive, likely win): Raw Bird Meat + Egg + Feathers -> Fillet +20/+20 and Fried Egg +20/+20 at a Campfire | ~10 s walk + a short fight
- Giant Rat (44 m, PL1, hostile): Raw Rat Meat -> Rat Roast +20/+20 | fight ~20 s (combat_brief); you are at 1 HP
- Deer: flees on foot, needs a bow or staff (you have none); Haunch needs Cooking 12 (you are 5)
- ask luisdeburnaybast (4 m)
```

Where each field comes from (no hand-written food table, no phrase map):

| field | source | work |
|---|---|---|
| sustenance, decay buffer, shield, heal, perk | Authoritative: each food's `SustenanceRowHandle` -> `DataTable:FindRow(RowName)` (UE4SS `UDataTable`, https://docs.ue4ss.com/dev/lua-api/classes/udatatable.html; `build.lua` l. 373-383 already uses `FindRow` live), plus `AmountToHealOnConsume`. Fallback: the wiki infobox `sustenance` / `health`. `tools/gen_consumable_wiki.py` already parses `sustenance` (KEYS, l. 26) but only writes `heal`. | one catalog pass adds `food: {sustenance, decay_buffer, heal, shield, perk}` to the items of `data/recipes_<build>.json`; the wiki fallback is a small generator change |
| what makes it | recipe data (exists) | - |
| who drops an ingredient | wiki `DropsLine` rows on creature pages (in the mirror: Giant Rat, Chicken, Deer, Kebbit, ...) | the sources index (F2) |
| where it is | the census (in sight), map memory (seen before), the landmarks in `places_<build>.json` (Chicken, Cow, ...), wiki region names -> region polygons (`brain/places.py`) | exists; needs joining |
| time | walking 4.5 m/s, measured interact and eat times, the recipe's processing span (`knowledge.py` l. 236 already renders it), the combat estimate | constants in data |
| gates | the ingredient's power level vs his Cooking level (the recipe's `chance_attribute` `ChanceToBurnFoodLevelN`; wiki Culinary Confidence); station needed or buildable | data |
| risk | the `combat_brief` estimate vs his current HP | exists |

Haiku, or the Director for a multi-step plan, then picks. "Drying triples the berry" is never written down anywhere: it falls out of two numbers side by side.

This follows the GOAP idea of actions with preconditions, effects and a cost (Orkin, F.E.A.R.; Ubisoft's AC Odyssey postmortem). The difference is that the code computes the costs and the model does the choosing, which keeps CLAUDE.md's rule that code informs and never decides. Plancraft (arXiv 2412.21033) scores LLM agents against a handcrafted optimal planner and includes deliberately unsolvable tasks. Our replay eval can do the same: compute the cheapest plan in code for scoring only, never to steer him.

**Tests:**
- **Replay eval:** the 11:00 co-play state (17 % food, 0.5 HP, berries 1 m, campfire 5 m). Pass = the first plan dries or cooks before eating raw (or eats one raw, then dries) in ≤ 2 calls. 10 Haiku runs; state the call count before running.
- **Live:** a character at 20 % food next to berries and a campfire. Pass = food ≥ 70 % and HP rising within 3 min, with no question to the player. A human does this in about 90 s.
- **Counter-case:** no campfire, no wood, berries 1 m, 5 % food. Pass = he eats raw berries first (right when there is no fire), then builds the fire.

## 4. Ranged and magic feasibility (research only)

**A. Lock-on.**
- **The component:** `pawn.LockOnTargetingComponent` (`BP_Components_LockOnTargeting_C : ULockOnTargetingComponent`, Dominion.hpp l. 26452-26487).
  - Inputs: `ToggleLockOnInput` = `IA_ToggleLockOnTargeting` (InputTriggerPressed: inject one frame) and `SwitchTargetInput` = `IA_TargetSwitchLockOnTargeting`.
  - Live values: `MaxTargetDistance` 3200 (32 m), `TraceDistance` 3000, `TraceRadius` 500, `ScreenSpaceAngleTolerance` 110 (DISCOVERIES l. 1208).
  - Functions: `HandleToggleLockOnInput`, `HandleOnCurrentTargetDied`, and the delegate `OnNewTargetAcquired(FLockOnTarget)`.
- **The camera actor:** `ALockOnTargetCameraActor` (l. 11417) has `RangedAimMax/MinPitchByDistance` curves.
- **Verified live:** the melee path entered `DIM_Gameplay_LockOnTargeting` (DISCOVERIES l. 2031; `combat.lua` l. 2763).
- **What can't be read:** which target is locked. `FLockOnTarget` has no reflected fields.
- **What it gives a bot (UNVERIFIED, inferred from the names):** the camera and control yaw follow the target, perhaps with a pitch-by-distance aid; no lead is evident. It is selected by a camera trace, so he must face the target first, and it fights our own `SetControlRotation`.
- **Use:** keep direct aim, and measure lock-on once as "the game's own assist" baseline.
- **Luis's X key:** no default binding was found (a Nexus page says the Controls menu leaves Target Lock out; snippet only). It doesn't matter for Claude, who injects the action.

**B. Projectiles.**
- **Bows and crossbows** fire `BP_Arrow_Base_C : ADominionProjectile`.
  - It is custom-simulated (path segments, `LookAhead`, `Server_InformOfHit`), not a ProjectileMovementComponent.
  - Its flight comes from the ammo's `URangedAmmoData.ProjectileData` (`LaunchSpeed`, `OverrideGravityZ`, `TimeWithoutGravity`, `MaxSimulationTime`; Dominion.hpp l. 6248).
  - **Read live once** (Ash Shortbow + wood arrows, client.log): **5000 cm/s, -600 cm/s², 0.3 s straight.** DISCOVERIES l. 1628 still says "NOT yet read live" and is out of date.
  - So drop is ~0 at 15 m, 3 cm at 20 m, 27 cm at 30 m and 75 cm at 40 m. Lead dominates: 1.6 m for a target moving 4 m/s at 20 m.
- **Per-shot data:** each fired actor replicates `LaunchInfo` {`StartPosition`, `StartDirection`, `LaunchSpeed`, `OverrideGravityZ`, `LaunchTime`, `bFullyCharged`} (l. 6311).
- **Charge and accuracy:** `UPlayerRangedAttackCollection` (l. 30260) holds `LaunchSpeedCurve`, `DamageMultiplierCurve`, `MaxChargeUpDuration` (shortbow and crossbow 0.75 s, longbow 1.55 s), `TimeBeforeFullAccuracy` and `VerticalLaunchAngleOffset`. The component holds `BaseInaccuracy` / `MinimumInaccuracy` (a random cone), `GetChargeUpProgressNormalized()`, `bIsInTrickShotWindow` and `RangedWeaponActor.LoadedProjectile`.
- **Staffs and wands** fire `BP_Spell_Projectile_Parent_C : AActor`, not `ADominionSpellProjectile`. Their spell data (e.g. `DA_Spell_Primary_Air_01`) contains:
  - `SpellModule_Targeting`: a screen-space trace, i.e. aim assist;
  - `SpellModule_Movement`;
  - **`SpellModule_Homing`**;
  - `ExpireAfterDistance`.

  So magic shots acquire a target and home on it.
- **Knowable offline:** names and layouts only. Default values need a live read: `StaticFindObject` on the data asset, `GetCDO()` on the class, curve `GetFloatValue`.

**C. Hits and crits, observable on Claude's client.**
- **Already hooked and working live:** `DamageComponent:Multicast_Apply[Point]DamageFromGameplayEffect` (`combat.lua` l. 603-683). It recorded the bow's hits.
- **Not read yet:**
  - `DamageClass` (Ranged 3, Magical 2);
  - the `DamageProperties` bitmask (`EDamageProperties`: HitPoint 1 = weak point, CriticalHitPoint 2, CriticalHit 4, Evaded 8, TrickShot 64);
  - on point damage, `HitLocation` and `WeakPointEventName`.
- **Wiki:** crits are 10 % base chance at ×1.25; the weak point is the head on most creatures.
- **Per-shot verification method:**
  1. Snapshot the projectile ids before release.
  2. After release, take the new actor whose `HasLaunched()` is true and that is not `LoadedProjectile`; read its `LaunchInfo` once.
  3. Track it to impact (`Multicast_OnProjectileHit` / `OnImpactPointReached`, UNVERIFIED live, or until it stops).
  4. **HIT** = our damage multicast on the target, with the right `DamageClass`, before impact + 0.3 s. Record the weak-point, crit and trick-shot bits.
  5. **MISS** = the impact point minus the target's position at impact, split into vertical and lateral.
  6. For magic, do the same over `BP_Spell_Projectile_Parent_C`, plus the drop in rune count.

**D. Current code and live results.**
- **The code:**
  - `ranged.lua`: a root search on flight time with lead and the straight segment. It aims by `SetControlRotation` so the camera ray crosses `muzzle + dir × 5000 cm`, learns a bias from sampled projectile positions, and keeps metrics.
  - `combat.lua`'s ranged engage (l. 2573-2724): keeps 4-25 m, holds the secondary, taps the primary for 3 frames, verifies by damage, aims at the capsule centre.
  - `shoot.lua`: for things that aren't creatures; llm=false, 0 live runs.
  - Design: `docs/design/ranged-aim.md`.
- **The only live bow fight** (2026-10-26 20:20, a mostly idle Goblin Runt at ~11 m; `logs/live_queue/2026-10-26.jsonl` `m3_route_ranged_fight`):
  - 9 presses, 2 verified hits, 4 with no projectile seen.
  - The 3 tracked "misses" fitted speeds of 10-68 cm/s, so the tracker latched onto the next nocked arrow (inference). `R.learn` then accepted those fits and corrupted the stored profile.
  - He died. The check "passed" only because Ranged XP rose.
- **Staff, 2 × 6 presses:** "spawned no projectile". `R.projectile_ids()` (`ranged.lua` l. 448) scans only DominionProjectile and DominionSpellProjectile, which never matches the staff class (SESSION-RECOVERY-2026-10-26 l. 43).
- **Bugs found by reading (UNVERIFIED live):**
  - The crossbow's secondary is a block (`PA_Block_Crossbow`), but the code holds the secondary for every non-magic weapon (`combat.lua` l. 2694, `shoot.lua` l. 221).
  - A 3-frame tap is about 0.1 s, so bow shots are probably under-drawn.
  - Quick Action (firing without aiming) needs Ranged 3.

**E. Aiming method.**
- Keep the root-search solver. It is the standard intercept-time method, and better than mineflayer-hawkeye's pitch scan with a one-step lead (https://github.com/sefirosweb/minecraftHawkEye).
- Change what feeds it:
  - take speed, gravity and charge from `LaunchInfo` instead of fitting a 30 fps trace;
  - calibrate the launch direction from `StartDirection`;
  - cross the camera ray at the game's trace end, not a fixed 50 m;
  - aim at the head;
  - hold the primary until the charge reaches 1;
  - fire on `bIsInTrickShotWindow`.
- **Engine helpers:** `UGameplayStatics.BlueprintSuggestProjectileVelocity` and `SuggestProjectileVelocity_MovingTarget` (Engine.hpp l. 15660-15661; https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/UGameplayStatics/SuggestProjectileVelocity_Moving-) take flat `FVector&` outputs, a pattern that works from UE4SS Lua here (`K2_ProjectPointToNavigation`, `LineTraceSingle`). They model no straight segment, so use them as a cross-check only.

**F. Evaluating against a human standard.**
- **Static targets:** the Archery Target (6 Ash Plank + 3 Flax, unlocked at Ranged 5, can show crits) and the Training Dummy (Attack 37, 20 Ash Plank, 400 HP). Planks come only from a Sawmill, which needs bronze, so on dev these are fixture grants. Whether they emit damage multicasts is UNVERIFIED.
- **Moving targets:** fixture-spawned Goblin Runts, and fleeing deer.
- **Grid:** 10 / 20 / 30 m × still / walking / running, 10 shots per cell.
- **Metrics:** hit rate, weak-point rate, miss vector, time to first release, shots per kill, time-to-kill vs melee on the same creature, damage taken, deaths.
- **Human baseline:** Luis plays the same cards on dev; his hits are read from the same multicasts, read-only (ask him first).
- **Bar:** hit rate within 10 points of Luis's per cell up to 30 m, time-to-kill ≤ 1.5× his, 0 deaths.

**G. Verdict.**
- **Bow: feasible, moderate work.** Fix the draw input, the projectile identification, the head aim point and the spacing.
- **Crossbow: feasible, likely the easiest bow-type weapon.** No draw, 2.0 s reload, one-handed so a shield fits. Never run live; remove the held block first.
- **Staff: feasible, likely the easiest to hit with,** thanks to the game's targeting and homing. Today it is blocked by the projectile-class bug, and maybe by tap vs hold.
- **Main risks:**
  - an unknown input model (hold to draw; maybe a hold to conjure);
  - camera/trace parallax;
  - 30 Hz aim updates;
  - AI kiting;
  - the L38 class of null-Niagara crashes on arrow effects (DISCOVERIES ~l. 2182): 9 plain shots did not crash, but trick shots and effect arrows are untested.
- **Smallest next live experiment** (dev, ClaudeDev, read-only probes, ~15 shots, no model calls):
  1. Fire an Ash Shortbow at a spawned stationary Runt at 15 m in three ways: (a) the current tap; (b) hold until the charge reaches 1; (c) lock-on with no `SetControlRotation`. Log the charge, `LaunchInfo`, impact point, `DamageProperties` and pitch.
  2. Then 5 staff presses, tap vs hold, watching `BP_Spell_Projectile_Parent_C` and the rune counts.
- **When ranged is needed:**
  - Rune Mysteries' floating essence (optional: the ground rocks work);
  - Dragon Slayer's deer antlers (required);
  - Goblin Diplomacy's druid (advised);
  - deer meat.

## 5. A proposed competence ladder

Each rung proves usefulness on its own, uses the one below, and uses quest steps as its tests where a quest matches.

| rung | what it proves | quest backbone | needs (from section 2) | pass (live, dev world) |
|---|---|---|---|---|
| **L0 Co-play basics** (Rung 2) | does what he's asked first time while Luis talks | - | the retro fixes 1-7 and 9 | the Rung 2 bar: ≥ 80 % of requests at A, ≥ 50 % at H, 0 false claims, 0 deaths |
| **L1 A self-sufficient day** | never a burden; efficient survival | - | F1 food values + F3 options digest; rest in the needs line | fresh-ish character, 60 min alone: food and water never < 25 %, at least one cook or dry, endurance > 0, 0 deaths, 0 requests for food |
| **L2 Tutorial chain** | talk, choose, a camp, first tools, kill and cook | First Steps (start) -> Getting Started -> Ratcatcher | talk enabled + `options` fixed + `choose` + hand-in live; F5 quest markers | 2 quests complete in ≤ 25 min, ≤ 1 correction each |
| **L3 Runes and the tutorial finish** | a long gather (50 logs), a built station that crafts (Rune Altar), travel to an upstairs NPC | Rune Mysteries -> First Steps finish | mine the ground essence (no ranged needed); interiors and stairs for go_to | both complete unaided |
| **L4 Melee at his level + PL1 armour** | fights runts without fleeing; turns kebbit fur into armour | (prepares Goblin Diplomacy, Dragon Slayer) | fight-assessment fix; PL per slot and region PL in context; sources index for fur | 3/3 runts at H; Adventurer's Tunic + Leggings worn (PL1) |
| **L5 Walls, roof, bow** | multi-piece building, a roofed station, a 3-station chain, ranged at a human standard | A Room With A Garou -> (Dragon Slayer's deer) | autonomous building plan; F4 station-build steps; flax item ids; the ranged fixes in 4.E | a roofed Spinning Wheel; Ash Shortbow + 33 Stone Arrows from scratch in ≤ 30 min; the 4.F grid at A; one deer killed |
| **L6 Farming** | a long-horizon investment chosen for a reason | Growing Pains | talk; tend live; demand memory on the board | Growing Pains complete; then, asked for a leather set, he plants flax himself |
| **L7 Metal tier** | furnace, bars, bench, bronze gear | Dragon Slayer prep (5 bronze bars, iron tools) | Vault Shards/Core sources; Bone Pickaxe; furnace fuel | Bronze Pickaxe crafted unaided |
| **L8 Dragon Slayer** | the first boss and the full main-quest loop | Dragon Slayer | the shelter, ranged, reading a journal, the vault, boss tactics (`docs/design/velgar.md`) | Velgar killed, quest complete |

**Where I disagree with Luis's ordering:**
1. **Food: dry the berries first, then meat.** His instinct (compare options, not a reflex) is right, but the data says drying berries at a campfire gives 3× the raw value, about what a chicken gives. Kebbits give no meat at all, and deer need ranged plus Cooking 12. Fix the perception and the right choice follows; don't wire "hunt" in.
2. **The tutorial quests before any self-taught progression.** Getting Started and Ratcatcher are the game's own lesson plan for exactly his list: camp, tools, rats, cooking. They cost little new work beyond talk, and they score themselves (the quest log advances). Dragon Slayer is the capstone, not the start.
3. **Building with a roof comes before the spinning wheel and the bow.** He didn't mention it, but the Spinning Wheel (and the Stone Range, Fletching Bench, Loom and Cooking Range) need a roof. A Room With A Garou is the cheap, self-scoring test of that skill.
4. **Ranged after melee is solid, and it needn't wait for perfection.** Lock-on is not the key: it is a camera aid, and direct aim with correct inputs is better for a bot. The staff (homing) or crossbow (no draw) may reach the bar before the bow. Ranged becomes necessary at Dragon Slayer's deer.
5. **Farming after Growing Pains, and later than it sounds.** The game locks farming behind that quest. A crop takes ~48 real minutes, and the first bow needs only 7 wild flax. Farming is the right call when demand is large, e.g. 22 flax for a leather set. That is the test of "plan for the future", and it needs demand memory, not a farming script.
6. **"Armour low for my power level" is circular.** His power level is his armour's average PL. The meaningful check is his PL against the region's or the target's PL, plus defence numbers we don't read yet.

## 6. Foundations that unlock many rows (ranked by rows unlocked ÷ effort)

All of these give the model more truthful data or tools. None maps phrases to skills.

| # | foundation | unlocks | reuse > adapt > build |
|---|---|---|---|
| F1 | **Item value data:** food (DT row via `FindRow`: sustenance, decay buffer, shield, heal, perk); armour defence (`DT_WearableEquipment` rows, wiki Armour as fallback); weapon damage (already in the catalog) | 2.1 efficient food, healing; 2.5 armour | reuse UE4SS `UDataTable:FindRow` (already used live in build.lua) + the wiki infobox fields the generator already parses |
| F2 | **Sources index:** item -> who drops it (wiki `DropsLine`: 257 pages, 633 items), where it grows or is gathered (wiki regions + `gather_profiles` item ids), which vendor sells it (recipe data), confirmed later by our own loot and pickup events | food options, flax, feathers, fur, hide, bone; craft_plan "obtain" steps; lookup cards ("Raw Rat Meat: dropped by Giant Rat, always") | adapt: generate it like `tools/gen_creature_wiki.py`; Mindcraft keeps a fixed item->animal table (`mcdata.js`), we generate ours from the wiki |
| F3 | **Options-with-costs digest** for needs, and the same fields on craft_plan alternatives: value, time (walking speed, processing span, measured interact/eat/fight), gates (Cooking level vs ingredient PL; unlocks), risk (combat estimate vs HP) | section 3; every "how should I get X" choice | build (small): it joins existing data; GOAP-style costs, but the model chooses |
| F4 | **craft_plan station-build steps:** the build piece, its live cost when unlocked or the wiki unlock sentence when locked, and the roof/open-sky rule; flax and the other pickup profiles get item ids | camp, spinning wheel, bow, armour chains | adapt craft_plan (`crafting.lua` l. 399 `find_station`) |
| F5 | **Quests usable:** talk loaded for the brain (the re-review gate), `options` fixed, `choose` and hand-in proven live, `where` from `AQuestLocation` markers in the quest rows | every quest | reuse the game's own markers (no Dragonwilds quest-helper mod exists on Nexus) |
| F6 | **Lookup fixes:** rank tier 1 first for "how do I make X"; raw meat "Raw ingredient (not edible)"; drop the "+ fuel" wording for fuel-less stations (`knowledge.py` l. 236); costs on station cards | fewer wrong plans | edit `knowledge.py` |
| F7 | **Ranged pipeline fixes** (4.E): hold to draw, the right projectile, staff class, no crossbow block, head aim, `LaunchInfo` | L5, Dragon Slayer, deer | adapt `ranged.lua` / `combat.lua` |
| F8 | **Smaller perception:** time of day; popup text (books, notes); PL per worn slot + region PL; endurance costs in the needs line | quests, rest, armour | read existing properties |
| F9 | **Demand memory:** what the board's open goals still need, summed over their craft_plan trees | farming decisions, "I'll need more flax" | the Director's board already holds the plans |

## 7. Unverified: check live before relying on it

- The DT_FoodSustenance row values via `FindRow` (the read pattern is proven in build.lua; this table is not).
- `AQuestLocation` markers and `VisibilityTrackers` on Claude's client (World Partition may stream far ones out).
- talk `choose` and hand-in.
- The roof requirements (wiki only), and the wiki building costs (the Campfire's was wrong).
- Lock-on behaviour for bows and staves; staff projectile data; bolt flight values; whether the Archery Target or Training Dummy emit damage multicasts.
- `tend` on a real plot; filling a watering can.
- `store` / `take` live.
- Bone Pickaxe and Hard Leather routes (the Advanced Tannery has no class in this build).

## Sources

**Local:**
- `client_mod/scripts/manifest.lua`; the `M.MANIFEST` blocks in skills, crafting, build, combat, spells, farm, fishing, gather, lodestone, quests, shoot, talk and agility;
- `brain/needs.py`, `brain/broker.py`, `brain/persona.md`, `brain/knowledge.py`, `brain/interface.py`;
- `docs/DISCOVERIES.md` (line refs above), `docs/RETRO-2026-11-01-coplay.md`, `docs/HANDOVER-2026-11-01.md`, `docs/PLAN-2026-10-31.md`;
- `docs/research/2026-11-01-evals-human-standard.md`, `docs/research/2026-11-01-autonomous-building.md`, `docs/research/2026-10-26-m3-skill-gaps.md`;
- `docs/design/ranged-aim.md`, `docs/design/every-skill-coverage.md`, `docs/design/velgar.md`;
- `logs/brain-live-20261101-115554-7128.jsonl`;
- `dumps/26161880/CXXHeaderDump/Dominion.hpp` (`UFoodItemData`, `FFoodSustenance`, `USustenanceComponent`, `ULockOnTargetingComponent`, `UPlayerRangedAttackCollection`, `FProjectileLaunchInfo`, `UQuestWorldSubsystem`, `AQuestLocation`);
- the data files in `data/`.

**Wiki** (https://dragonwilds.runescape.wiki/w/<Title>, mirrored 2026-10-25):
- **Survival and food:** Food, Sustenance, Hydration, Rest, Over Eating, Soulscourge, Cooking, Culinary Confidence, Burnt food.
- **Food items and creatures:** Redberries, Redberry Bush, Dried Redberries, Haunch, Raw Game Meat, Raw Rat Meat, Rat Roast, Raw Bird Meat, Giant Rat, Chicken, Kebbit, Deer.
- **Stations:** Campfire, Crafting Table, Spinning Wheel, Furnace, Kiln, Tannery, Blacksmith's Bench, Armour Bench, Fletching Bench, Loom, Sawmill, Stone Range, Cooking Range, Smithing Anvil.
- **Farming:** Farming, Farming Plot, Ash Farming Plot, Compost Bin, Rain Catcher, Well, Wooden Spade, Wooden Watering Can, Flax, Coarse Thread.
- **Combat:** Power level, Armour, Archery Target, Training Dummy, Ranged, Critical Strike, Quick Action, Trick Shot.
- **Quests:** Quests and every quest page named in 2.6; Game updates.

**Web:**
- UE4SS UDataTable: https://docs.ue4ss.com/dev/lua-api/classes/udatatable.html, and the DataTables devlog: https://docs.ue4ss.com/devlogs/datatables-in-ue4ss.html.
- UE4SS FindAllOf: https://docs.ue4ss.com/release/lua-api/global-functions/findallof.html.
- Epic `SuggestProjectileVelocity_MovingTarget` (URL above).
- minecraftHawkEye: https://github.com/sefirosweb/minecraftHawkEye.
- Mindcraft `mcdata.js`: https://raw.githubusercontent.com/kolbytn/mindcraft/main/src/utils/mcdata.js.
- Plancraft: https://arxiv.org/abs/2412.21033.
- GOAP: Orkin's paper (https://alumni.media.mit.edu/~jorkin/goap.html) and the Ubisoft AC Odyssey postmortem: https://www.gamedeveloper.com/programming/postmortem-AI-action-planning-on-Assassins-Creed-Odyssey-and-Immortals-Fenyx-Rising-.
- Ranged build guide: https://hacktheminotaur.com/runescape-dragonwilds/best-runescape-dragonwilds-ranged-build/.
- Eye on Ashenfall 0.9.3: https://dragonwilds.runescape.com/news/eye-on-ashenfall-0-9-3.
- Nexus Infinite Lock-On Distance (snippet only): https://www.nexusmods.com/runescapedragonwilds/mods/362.
- RuneFest 2026 roadmap: https://www.pockettactics.com/runefest-2026-roadmap.
- Food guides, which disagree with each other and with the wiki on numbers: https://www.sportskeeda.com/mmo/runescape-dragonwilds-cooking-recipes, https://destructoid.com/all-cooking-recipes-in-runescape-dragonwilds.

**Searches that found nothing:**
- a Dragonwilds quest-helper mod;
- any source on lock-on behaviour for bows and staves, or its default key;
- a published LLM + GOAP game hybrid;
- the processing time per thread;
- any study of human vs bot aim accuracy.
