# Quest backbone: every quest, what it needs from Claude, and what blocks it today (2026-11-01)

Research only: no code changed, no model calls, no game client. Game build 26161880.

**Sources:**
- the wiki mirror `data/wiki/pages` (fetched 2026-10-25), checked against the live wiki on 2026-11-01: same quest list;
- the dump `dumps/26161880/CXXHeaderDump`;
- the game's quest asset data in `client_io/out/quest_objectives.json` (probe `client_mod/commands/quest_objectives.lua`);
- `data/places_26161880.json`;
- our docs and logs.

**Related:** [`2026-11-01-competence-map.md`](2026-11-01-competence-map.md) already holds:
- the quest competence table and the main-chain summary (§2.6);
- the proposed ladder L0-L8 that uses these quests as its tests (§5);
- the foundations, of which F5 "Quests usable" and F8 popups/time are the quest ones (§6).

This file adds what the map does not hold:
- the full list of all 37 quests, with steps, prerequisites and rewards;
- the blockers, quest by quest;
- the tool audit, tool by tool;
- the quest-data and marker facts from the dump.

**Codes:**

| code | meaning | code | meaning |
|---|---|---|---|
| T | talk | Ch | choose a dialogue option |
| H | hand items in | Go | travel to a named place |
| Gth | gather | Cr | craft at a station |
| Bld | build | K | kill |
| Boss | a boss fight | Int | use a world object (well, statue, lever, door, chest) |
| Rd | read a book or note | Dig | dig with a spade |
| WS | Windstep traversal | Nt | night only |
| Fn | net fishing | Fr | rod fishing |
| Fm | farming | Pz | puzzle or answer |

## 0. Summary

1. **Claude has completed no quest and advanced none.**
   - His live log on Shockbyte today: First Steps "Speak to the Wise Old Man in the temple." (main), Growing Pains and Shrimp Catcher active, 0 complete, 6 ungiven (`logs/brain-20261101.jsonl` row 7619; DISCOVERIES l. 1961, 2206).
2. **Every quest is blocked at its first step today.** Each quest starts or ends with T or Int:
   - `talk` is not loaded for the brain (`client_bridge.lua` l. 1217-1218, `_G.DW_ENABLE_TALK`);
   - its `options` list came back empty (DISCOVERIES l. 2044);
   - `choose` and hand-in have never run live;
   - `interact` "Talk" fails (BUGS L41).
3. **The cheapest full quests after talk is fixed** are Getting Started and Ratcatcher. All their other steps are already verified live:
   - water collection;
   - Crafting Table and Campfire builds;
   - the Stone Club craft;
   - rat kills;
   - Campfire cooking.
4. **The game gives the current objective in its own words.** The read is live.
   - It also holds objective map locations (`AQuestLocation` + per-player `VisibilityTrackers`), but nothing reads them yet. See §4.
5. **The hard blockers further up:**
   - bosses;
   - Windstep jumping puzzles;
   - reading books and notes;
   - digging;
   - rod fishing;
   - night-only content;
   - hitting non-creatures (floating rune essence, spectral tangles);
   - killing fleeing deer (ranged);
   - the soul rift and scorch mechanics.

## 1. The quests in story order

### 1.1 The main chain: Kuldra's Saga

Each quest needs the one before it. In the wiki's words, the main quests "are required to open up some new areas and regions".

| # | quest | giver, place (map names) | steps in brief | needs | reward / unlock |
|---|---|---|---|---|---|
| 1 | **First Steps** | auto-started. Wise Old Man (WOM) in the temple, Temple Woods; ends with WOM upstairs in a ruined building, Bramblemead Village | dialogue "Yes please [Begin Tutorial]" / "I can work it out [Skip Tutorial]"; Begin leads to the 3 tutorial quests, then back to WOM | T, Ch, Go | Tome of Runecrafting I (XP) |
| 2 | **Getting Started** | Doric, outside the temple | 1 Dirty Water from the pond; build a Crafting Table (4 Ash Logs); craft a Stone Club (6 logs + 8 Stone); report back | Gth (water), Bld, Cr, T | Vegetable Soup |
| 3 | **Ratcatcher** | Vannaka, south of the windmill | kill 4 Giant Rats for 4 Raw Rat Meat; build a Campfire (4 logs + 4 Stone) plus fuel; cook 2 Rat Roasts; hand in | K, Bld, Cr, H | Stone Logging Axe, Stone Dagger |
| 4 | **Rune Mysteries** | Zanik, "near the river, down the road from the temple" (game text) | 50 Ash Logs; receive a Stone Pickaxe; rune essence at a geyser; build a Rune Altar (12 Stone + 4 essence); craft Air and Astral runes; return | Gth, Bld, Cr, T | Stone Pickaxe, 50 Air + 50 Astral runes, Tome of Woodcutting I |
| 5 | **Dragon Slayer** | WOM, Bramblemead Village; needs First Steps | see the parts below | Bld (multi-piece + claim), ranged K, Int, Rd, Go (vault), Gth (iron tools), Cr (bench), Boss | Noxious Draconic Visage, Anti-Dragon Shield, Tome of the Dragon Slayer; the way to Fellhollow |
| 6 | **Withering Heights** | WOM near Ashien's Watch (Fractured Plains); needs Dragon Slayer | see the parts below | T, Ch/Pz, Go, Int, K (dragons), soul-rift survival, Boss | Tome of the Undying, Dragoncurse Shield (+ recipe); permanent Fellhollow access |
| 7 | **Black Knight's Fortress** | Death, Forgotten Temple; needs Withering Heights | see the parts below | Int, Dig, WS, Pz, K, Gth, Fr?, Boss | Titan's Wrath (+ recipe) |
| 8 | **Icthlarin's Little Helper** | Door to Umbral Sands (The Bastion); needs Black Knight's Fortress | see the parts below | everything, plus scorch survival | Dragonfire Shield; the Fight Caves; Magic Carpet mount |
| 9 | **Regicide** | Dragon Gate, north-west of Velgar's Rise (Fractured Plains); needs Icthlarin's Little Helper | build a base at Rasthin's Rest; talk to Zilyana; clear the Scorned Wilderness raid (Rat King, Abyssal Demon, black dragons) → **boss Kuldra** | everything, plus raid endurance | Dragon Kiteshield, Dragonslayer's Cape; the raid; Lougrim's Staff |

**Rune Mysteries:** the essence step.
- Ground rocks at a geyser can be mined.
- Floating rocks must be shot down with ranged or magic.
- The game text also allows "Siphoning Anima Vents" for the runes, but they still need essence.

**Dragon Slayer, step by step:**
1. Build a shelter: foundation, 3 walls, ceiling, bed roll; claim the bed.
2. Bring a deer's antlers. The deer flees, so it needs ranged or magic.
3. Keep of Blue Flames: goblins; read Cathan's Journal; Velgar strafes the keep.
4. The blue-flame door in the Whispering Swamp (vault Vertentis Kara): talk to Spitfoot.
5. Back to WOM.
6. Ghornfell, Velgar's Rise: Cathan's ghost gives the horn recipe.
7. Gather a Dragon Tooth (dragon skull, Stormtouched Highlands, iron pickaxe) and Bloodwood Sap (Bloodblight Swamp castle, iron axe).
8. Craft the Challenge Horn: tooth + sap + 5 Bronze Bars, at the Blacksmith's Bench (`docs/design/velgar.md`).
9. Put the horn on the altar → **boss Velgar**: PL 4, 6,000 HP, 4 phases, poison (`velgar.md` §1).
10. Give the head to WOM.

**Withering Heights, step by step:**
1. WOM gives the password to the strange door, which leads to the Forgotten Temple.
2. Talk to Death, then Postie Pete.
3. Cross the wither river: you enter the soul rift. Go through the spectral door into Bleakfields Valley.
4. Purify at a fountain (blue beacons on the compass) after hitting the spectral tangles.
5. Find Cathan at the standing stones.
6. Collect three curse fragments:
   - **Grief, Emberwood:** 4 god shrines.
     - Guthix: kill a green dragon.
     - Saradomin: find the symbol in the water.
     - Armadyl: the ghost whodunit, answered in dialogue.
     - Zamorak: enter through the roof; a lever lets you out.
   - **Rage:** the Vekchenven Kara vault; kill the zogre.
   - **Despair:** Silverthorn Keep, guarded by a green dragon.
7. The Shattered Spire → **boss Imaru**, who phases in and out of the soul rift.
8. Bring the head to Death (needs 1 free slot).

**Black Knight's Fortress.**

Requirements: Cooking 41 (Maple Syrup) or a Maple Toastie; a steel spade or pickaxe; a mithril axe; a fishing rod; 5 Maple Sap.

1. Cathan, at the gatehouse south of Silverthorn Keep.
2. The Approach, then WOM in The Courtyard.
3. Make a base camp.
4. Doric at the Dreaming Stone (The Nexus).
5. Collect **13 shards**, marked on the map with yellow circles:
   - cut vines;
   - kill shardbound lesser demons;
   - click the library books in order (Empty Throne, Eye of Oculus, Taking the Crown, Zamorak's Rebellion);
   - dig up the glass owl for Valerius;
   - pull 3 levers reached with Windstep;
   - a beam-jumping puzzle;
   - a granite node;
   - dig graves (the shard's spot is random per world);
   - trade 5 Maple Sap to Spittletoe.
6. The Bastion → **boss Black Knight Titan**.
7. Talk to the stone.

**Icthlarin's Little Helper:**
1. Moon Garou reputation tasks:
   - Domri: 3 moonstones under gypsum;
   - Valas: 3 Adamant Bars;
   - Lagra: 3 each of raw farm meat, kalphite shell and cactus steak;
   - then the Manafem and Uzzer clan chains.
2. Repair the mirrors.
3. The Fight Caves: 10 waves. The activity is unsafe: you lose your items on death.
4. **Boss Fuzan.**

Since 0.12.0, primary quests also spawn **Tasks** (the game files call them "Tertiary").

### 1.2 Side quests

**Brynmoor**

| quest | start | prerequisite | steps | needs | reward |
|---|---|---|---|---|---|
| **Growing Pains** (active) | craft a Wooden Spade or Watering Can, then WOM in Bramblemead | - | build an ash farming plot; dig it 5× with the spade; plant 3 wheat seeds (given); water 5× (6 game-hours without water and it sickens); harvest about a day later; WOM | Cr, Bld, Fm, time | Plant Cure, Tome of Farming II, Farming 3. **This quest unlocks farming** (live `bFarmingUnlocked=false`) |
| **Shrimp Catcher** (active) | craft a Coarse Net, then WOM in Bramblemead | - | net-fish shrimp to Fishing 3; craft an Ash Rod and shrimp bait; rod-catch a sardine (charged cast, then fight with strafe A/D within stamina); WOM | Fn, Cr, **Fr** | Tome of Fishing I, 3 Feather Bait |
| **Restless Ghosts** | the Crumbling Well, Bramblemead Valley (a map landmark) | First Steps; Woodcutting 20 | get the ghostspeak amulet; find 4 ghosts, **visible only sunset to sunrise** (ruined village; south-east of the windmill; a cave reached by Windstep, behind thorny vines; Whispering Swamp); then the Remembrance Shrine (Temple Woods): pick each option | Int, Nt, WS, Gth (vines), Ch | 4 tomes; ghost speech (needed by Even More Restless Ghosts) |
| **Goblin Diplomacy** | Zanik on the ridge, Bramblemead Valley | Rune Mysteries | a reliquary at the Outlook Ruins (or the Adventurer's Guild, behind vines); kill the goblins round the caged goblin and talk to it (optional steak bribe); kill the Garou Druid in a cave at the swamp's bottom (poison; ranged advised); Zanik | Int, K, T, Go (descent), antipoison | Goblin War Banner |
| **Highlighting the Problem** | the wizard statue, Runecrafting Guild (cliffs north of Temple Woods) | First Steps | the password from a statue in the Thishepen Kara vault (a Windstep room): "pthentorok"; the orb; 3 tower pedestals via Windstep; back to the statue | Int, Pz, WS | Staff of Light recipe |

**Ghornfell**

| quest | start | prerequisite | steps | needs | reward |
|---|---|---|---|---|---|
| **A Room With A Garou** | Caratacus the Elder, Fractured Plains | none | build 4 walls and a roof around him (about 20 Ash Logs); talk | Bld (multi-piece), T | furniture recipes |
| **Cook's Assistant** | Slopfinger, cabin in the south-west Fractured Plains | farming + wheat | 4 eggs (chickens or bird nests), 7 wheat, milk: talk to the cow through all options and feed it 1 wheat | Gth, K, Fm, T/Ch, H | Victoria Sponge recipe |
| **Animal Magnetism** | Manktongue, same cabin | - | **read** the message in a bottle, then talk again (required); an undead chicken in an iron ore node (Highlands); undead twigs; a magnet (Iron Bar + 5 Law Runes) | Rd, T, Int, Cr | Ava's Accumulator |
| **Granite Mauled** | Doric, south of Ashien's Watch | First Steps | Windstep or build a bridge; activate 4 statues; the Skeklac Kara vault (poison gas, putrid rats); a lever; a vault boss; the blueprint back to Doric | WS/Bld, Int, K, Boss (vault) | Granite Maul recipe |
| **Heartstrings** | the memorial stone by the Crystal Tree, Crystalline Mesa (Windstep up) | Getting Started | 7 memorial stones heading east; "sing" at each | WS, Int, Go, K (garou) | Crystal Bow (+ recipe) |
| **Dog Days** | Vannaka, Stormtouched Highlands | - | **read** the lore book (sneak past a thane); kill the Garou King (Highlands Castle); 2 Ram Horns + 3 Shocking Plant Bulbs | Rd, K, Boss-ish, Gth | Garou Highborn's Cloak |
| **A Melody Remembered** | the Jewellery Box, Stormtouched Highlands (a map landmark) | Dragon Slayer | hand in an Inspiring Ring of Runecrafting and an Amulet of Magic (Jeweller's Bench: silver and gold bars, opals, sapphires, vault shards) | Cr (jewellery), Int/H | Ravanna's Ring |
| **The Great Body Robbery** | Doctor Fenkenstrain, Bloodblight Swamp tower | Dragon Slayer (partial) | dig 3 graves with a spade; open the coffins; weak Antipoison, Focused Attack and Lumberjack potions | Dig, Int, Cr (brewing) | Zombie Arm, Lightning Rod recipe |

**Fellhollow** (all need Withering Heights started)

| quest | start | needs | reward |
|---|---|---|---|
| Even More Restless Ghosts | Zanik, Bleakfields Valley (Restless Ghosts started + all 4 shrines) | Bld (small house), Gth (mining), Int, K | Dorgeshuun Crossbow recipe |
| The Wild Hunt | Vannaka, Bleakfields Valley | K: 3 nature spirits in willow groves | terrorbird mount |
| Things That Go Boom In The Night | Vannaka (after The Wild Hunt) | K fast: 10 spectral chinchompa skulls (they vanish) | Spectral Chinchompa Cape |
| Seeking Salvation | Doric, cave east of the Lake of Lost Souls | Int: 4 dragonkin statues (WS or stairs, a torch); Skekven Kara vault bosses | Salve Amulet recipe |
| Doric's Quest | Doric (after Seeking Salvation) | recipes from vault effigies; craft 3 weapons; H | Zombie Axe recipe |
| Letters for the Dead | Postie Pete, Forgotten Temple | find the thief; deliver letters | Postbox; a repeatable activity |
| What Remains is Written | Abraxus The Eternal, Coalridge Pass | wear the full necromancer set; collect tomes | Abraxus Ring |
| Mirror Mirror | the Mirror west of Emberwood Village (a map landmark) | dragon blood, a spellbook, spectral thread, a Silver Bar, sacred oil, 6 soul fragments | Ulv's Longbow |

**Dowdun Reach** (needs Black Knight's Fortress started)

| quest | start | needs | reward |
|---|---|---|---|
| Biohazard | Zanik under The Approach, or loot a corrupted raven | 10 samples, dragon blood, unholy water, twilight lily | Zamorak Cape |
| Wanted! | Vannaka, The Courtyard | 3 beast-tamer group fights | Unholy Symbol vestige |
| What's Theirs is Mine! | Doric, The Nexus | portals in order; nodestones | Zamorak Staff recipe + 4 tomes |

**Umbral Sands** (needs Icthlarin's Little Helper started)

| quest | start | needs | reward |
|---|---|---|---|
| Contact! | Avisk Crystal, Dunes of Uzzer | 3 crystal helix pieces from vault guardians | Pharaoh's Sceptre vestige |
| Brink of Extinction | Zi, The Burning Spire | 3 raw beltfish + a cactus steak; touch 4 fire pedestals (blue map circle) | Obsidian |
| Mapping The Sands I / II | Anamcara, Alcarrid Camp | climb to the moon sprites on tall spots (8 in II) | Blue Desert Cape / Bow of Elidinis recipe |

### 1.3 Patch status
- **Last quest added:** Regicide, in 1.0 (2026-09-15).
- **1.0.1 (2026-10-14):** added quest summaries only.
- **1.0.1.2 (2026-10-23):** the wiki lists only its title.
- **Coming:** monthly side quests; the December "Luminance" update (Elves, Prayer) opens the Blood Crystal Saga (Pocket Tactics, RuneFest 2026).
- **Stale wiki text:** the Rune Mysteries page still sends you to "Warding Off Danger", which was removed in 0.12.0.

## 2. Quests blocked today, and why

**Common to all:** talk is off for the brain (§0 item 2). Once it works, the extra blockers per quest are:

| quest | extra blocker today | type |
|---|---|---|
| First Steps | none beyond talk + `choose`; the finish needs go_to to reach an upstairs NPC in a ruined building | B |
| Getting Started | hand-in through dialogue never proven | B |
| Ratcatcher | hand-in; cooking Rat Roast specifically never run | B |
| Rune Mysteries | Rune Altar build and rune crafting never run; floating essence needs a non-creature hit (`shoot` is offline and llm=false); ground rocks are the way round | B / T |
| Growing Pains | `tend` / `farm_plots` offline only; Dig with a spade is `use_action`, offline only; waits across a game day | T / B |
| Shrimp Catcher | rod fights always lost to stamina (DISCOVERIES l. 2034-2039); the brain has never called `fish` | B |
| A Room With A Garou | multi-piece snapped building unproven (snap-only pieces refused, DISCOVERIES l. 1922) | B |
| Cook's Assistant | needs farming; talking to a cow; egg sources | B / K |
| Restless Ghosts | no time-of-day perception (UNVERIFIED client-side; DISCOVERIES l. 1975 is server side); Windstep as traversal unproven (gated at `move.lua` l. 567); cutting thorny vines unproven | P / B |
| Goblin Diplomacy | reliquary interaction unverified; the descent into the swamp; the poison druid; flees fights (HANDOVER-2026-11-01 l. 49-51) | B |
| Highlighting the Problem | the password (dialogue input?, UNVERIFIED); Windstep onto towers | Pz / B |
| Animal Magnetism, Dog Days | **reading** is missing: popups are only closed (`input.lua` l. 117) | T + P |
| The Great Body Robbery, Black Knight's Fortress | **dig** missing | T |
| Dragon Slayer | the multi-piece shelter; ranged for the deer; reading the journal; the vault; iron and bronze tiers (furnace and bench never run); **boss** never tried | everything |
| Withering Heights and later | bosses, dialogue puzzles, soul rift, dragons; Black Knight's Fortress jumping puzzles; Icthlarin's Little Helper's 10 unsafe waves | Boss / Pz / B |

## 3. Audit: each tool's live status (2026-11-01)

From a subagent pass over the manifests, docs and 104 brain-live logs. The talk and quests lines were spot-checked by me.

**Citation key:**

| key | file |
|---|---|
| D | `docs/DISCOVERIES.md` |
| B | `docs/BUGS.md` |
| P | `docs/PROGRESS.md` |
| I | `docs/ISSUES-2026-11-01-coplay.md` |
| R | `docs/RETRO-2026-11-01-coplay.md` |
| H | `docs/HANDOVER-2026-11-01.md` |
| S | `docs/design/every-skill-coverage.md` |
| G | `docs/research/2026-10-26-m3-skill-gaps.md` |
| LOG | counts over `logs/brain-live-*.jsonl` and `client_io/bridge/*` |

| tool | status | evidence | caveats that matter for quests |
|---|---|---|---|
| go_to / follow / stop | verified live | H:16, P:162, P:376 | the temple ramp is off the navmesh (B:107); chat cuts it (I:64) |
| look / inspect | verified live | D:1185 | 80 m cap; one wrong NPC position (D:1965) |
| interact | partly | LOG: 78 ok (Collect, Take All, Collect Water, chest Open); sleep D:1582 | "Talk" fails (B:129); doors, levers, statues, wells, mirrors never tried; `secondary` never used |
| drop / give / recover_grave | partly; give is llm=false | D:512, D:515 | whole stacks only (R:62-64) |
| consume / equip / collect_water | verified live | P:165, P:140, B:91 | hotbar only for consume |
| store / take | offline only | build-primitive.md:386 | 0 live calls |
| explore | partly | B:31 | walked off a 29 m cliff (R:68-70) |
| gather | verified live (ash, oak, sticks, stone) | P:166, D:2033 | ores never run (S:33) |
| attack | partly (kebbit, chicken, runt, rat, wolf) | LOG, P:167 | flees runts "losing" (H:49-51) |
| use_action / shoot | offline only (`shoot` llm=false) | shoot.lua:358 | no dig, no non-creature hits |
| craft | partly: Crafting Table, Campfire | P:335, D:2273 | Rune Altar, furnace, bench, kiln never run (S:164) |
| build | verified live: Campfire, Crafting Table, Crate | D:1924-1928 | snap-only pieces refused (D:1922); can't see water (I:38) |
| cast / spells | verified live, 17 spells incl. Windstep, Fire Spirit, Axtral Projection | S:221-268, D:2082-2118 | Fishnado failed on spots (D:2083) |
| lodestones / teleport | verified live | D:2236-2239 | - |
| fish | net partly (2 shrimp, D:1933); rod fails (D:2034-2039) | G:36 | debug channel only |
| tend / farm_plots | offline only | S:114, G:43 | farming locked until Growing Pains |
| agility_course | offline only | G:35 | none found within 200 m live |
| talk | partly, not loaded for the brain | client_bridge.lua:1217-1218; D:2040-2044 | `options` empty; `choose` never live; hand-in UNVERIFIED (S:172) |
| quests | verified as state; the tool has never been called | D:1961, D:2206 | no location, no tracked quest; numbered keys ("Objective2") carry no meaning |
| places | missing from the bridge's modules | research/2026-10-31-dogfood-live.md:65 | quest NPCs reach the model only through `map_names` / `go_to` |
| lookup | live, 16 calls | B:76 | misses quest prerequisites; no coordinates |

**Never seen in any log:**
- a quest-item pickup;
- a book or note read;
- a dig;
- a boss fight (`docs/design/velgar.md` l. 3: no live data).

## 4. Does the game tell him "what" and "where"?

### What: yes, live today
`client_mod/scripts/quests.lua` reads `QuestProgressComponent.Quests`:
- `FQuestProgress {Data, State, CurrentObjective, QuestInts, QuestBools}` (Dominion.hpp l. 6450);
- the step text from `UQuestData.Objectives[CurrentObjective]` (l. 31475, `FQuestObjectiveData` l. 6440).

The text names places, for example:
- "Speak to Zanik near the river, down the road from the temple."
- "Construct a base of operations in Bramblemead village. Build a shelter and claim a bed."

**Hint and subobjective fields are empty** in the asset data (`client_io/out/quest_objectives.json`).

**Limits:**
- `Quests` holds only *initialised* quests: 7 on ClaudeDev, 9 live on Shockbyte. So `quests all=true` is not the full catalogue.
- `UQuestDataSubsystem.NetIdToData` (l. 20164) may list every quest asset. UNVERIFIED.

### Where: in the game, not read yet (dump only, nothing live)

| fact | location in the dump |
|---|---|
| `UQuestWorldSubsystem.QuestLocations` is a `TArray<AQuestLocation*>` | Dominion.hpp l. 31638 |
| `AQuestLocation {Type, Radius, Quest, bShownByDefault, QuestLocationName, bOverrideDefaultQuestIcons, MapIconTypeOverride}`; the position is the actor's own | l. 12018 |
| `Type` is `EQuestLocationType` Target / Area / NPC | Dominion_enums.hpp l. 2838 |
| Per player: `QuestProgressComponent.VisibilityTrackers` (`TArray<FLocationVisibilityTracker{LocationName, bLocationVisibility}>`, OnRep) | l. 31595, 4468 |
| Quest progression reveals markers through `FProgressionQuestLocationData{Name, bRevealed}` | l. 6241 |
| `QuestProgressComponent.TrackedQuestMap` (EQuestType → quest); `Server_NotifyQuestTracked` | l. 31595 |
| The compass widget holds the QuestProgressComponent and the GameplayObjectRegistry | l. 17316 |
| Map icon types QuestMain / QuestSecondary / ...Area / ...Npc | Dominion_enums.hpp l. 2326-2331 |

The wiki confirms these markers in play: "marked on your map with yellow circles", "the map and compass will direct you", "a blue circle will be added to your map", "blue beacons".

### Already usable
`data/places_26161880.json` (`AGameplayObjectRegistry.Landmarks`) names many quest NPCs and objects with positions:
- WOM ×5, Doric ×4, Vannaka ×4, Zanik ×6;
- Caratacus, Slopfinger, Manktongue, Fenkenstrain, Death, Postie Pete, Abraxus;
- Crumbling Well, Jewellery Box, Mirror, Remembrance Shrine;
- Dreaming Stone and 9 Dreaming Stone Shards;
- 3 Moonstones; the Alcarrid NPCs.

### Proposal (foundation F5 in the competence map)
Add `where = [{name, type, radius, position}]` to each active quest row. Take the `QuestLocations` whose `Quest` is that quest, and which are either `bShownByDefault` or visible in `VisibilityTrackers`.
- **Reuse:** the read-only `FindAllOf` pattern already used by `places.lua` and `lodestone.lua`.
- **Search-before-building:** no Dragonwilds quest-helper mod exists on Nexus (search 2026-11-01).
- **Risk:** World Partition loads cells only near players (DISCOVERIES l. 593), so far `AQuestLocation` actors may not exist on the client. A first probe should count them near and far.

## 5. Unverified (check live before relying on it)
- The `AQuestLocation` / `VisibilityTrackers` read, and whether it streams with World Partition.
- `UQuestDataSubsystem.NetIdToData` as the full quest catalogue.
- Whether Getting Started and Ratcatcher are separate assets given after "Begin Tutorial". On ClaudeDev only Rune Mysteries was listed; First Steps' 3rd objective is "Speak to Doric outside the temple."
- Hand-in through dialogue.
- A password typed or chosen at the Highlighting statue.
- Reading the time of day on the client.
- The 1.0.1.2 patch contents.

## Sources
- **Wiki** (CC BY-NC-SA), `https://dragonwilds.runescape.wiki/w/<Title>`:
  - [Quests](https://dragonwilds.runescape.wiki/w/Quests) (list, rewards, update history);
  - [Game updates](https://dragonwilds.runescape.wiki/w/Game_updates);
  - each quest page named above, e.g. [First Steps](https://dragonwilds.runescape.wiki/w/First_Steps), [Getting Started](https://dragonwilds.runescape.wiki/w/Getting_Started), [Ratcatcher](https://dragonwilds.runescape.wiki/w/Ratcatcher), [Rune Mysteries](https://dragonwilds.runescape.wiki/w/Rune_Mysteries), [Dragon Slayer](https://dragonwilds.runescape.wiki/w/Dragon_Slayer), [Withering Heights](https://dragonwilds.runescape.wiki/w/Withering_Heights), [Black Knight's Fortress](https://dragonwilds.runescape.wiki/w/Black_Knight%27s_Fortress), [Icthlarin's Little Helper](https://dragonwilds.runescape.wiki/w/Icthlarin%27s_Little_Helper), [Regicide](https://dragonwilds.runescape.wiki/w/Regicide);
  - [Wise Old Man](https://dragonwilds.runescape.wiki/w/Wise_Old_Man), [Windstep](https://dragonwilds.runescape.wiki/w/Windstep), [Rune Essence](https://dragonwilds.runescape.wiki/w/Rune_Essence), [Anima Vent](https://dragonwilds.runescape.wiki/w/Anima_Vent);
  - local mirror files via `data/wiki/manifest.json`.
- **Roadmap:** [Pocket Tactics, RuneFest 2026 roadmap](https://www.pockettactics.com/runefest-2026-roadmap).
- **UE4SS:** [UE4SS FindAllOf](https://docs.ue4ss.com/release/lua-api/global-functions/findallof.html), [FindFirstOf](https://docs.ue4ss.com/release/lua-api/global-functions/findfirstof.html).
- **Nexus:** the only result was [Vortex UE4SS extension](https://nexusmods.com/site/mods/1273), not a quest mod.
- **Dump:** `dumps/26161880/CXXHeaderDump/Dominion.hpp`, `Dominion_enums.hpp`, `MinimapPlugin.hpp` (line numbers above).
- **Game data:** `client_io/out/quest_objectives.json` (2026-10-26); `data/places_26161880.json`; `logs/brain-20261101.jsonl`.
- **Docs:** the D/B/P/I/R/H/S/G citations in §3; `docs/design/velgar.md`; `docs/design/every-skill-coverage.md` §10; [`2026-11-01-competence-map.md`](2026-11-01-competence-map.md).
