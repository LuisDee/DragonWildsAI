# The vault capstone: what it takes, whether it can be trialled, how to grade it (2026-11-17)

For the developer who builds the Rung 6 trial and its grader. Not for the companion: nothing here goes into a prompt, a tool description, a hint or a recipe (CLAUDE.md section 3, "the model decides"). Offline research only; nothing was run against the server, the client or the brain, and no model was called.

## Need

`docs/GOAL-2026-11-17-long-jobs.md` section 4: "from one ask he prepares for a vault, clears it and kills its boss", first vault "Vertentis Kara, boss Velgar, power level 4, 6,000 HP, four phases, poison". Nobody had written down what that takes in the game, whether the dev world and its checkpoints can stage it, how a trial is graded from the game's own state, or what a human takes.

## Searched

- Repo: `docs/DISCOVERIES.md`, `docs/ARCHITECTURE.md` (crash register), `docs/BASELINES-2026-11-01-luis.md`, `docs/PROGRESS.md` (vault, Velgar, boss, poison, lever, Bramblemead), `docs/design/velgar.md`, `docs/research/2026-11-01-competence-map.md`, `docs/research/2026-11-01-quest-backbone.md`, `docs/research/2026-11-17-long-job-harness.md`, `brain/gear_plan.py`, `tools/rung4_gate.py` (`gear_target`), `tools/quest_run.py`, `tools/quest_clone.py`, `tools/world_snapshot.py`, `client_mod/scripts/combat.lua`, `client_mod/scripts/creature_wiki.lua`.
- Game data: `dumps/26574459` (headers and object dump of build 26574459), `data/places_26161880.json` (regions, landmarks), `data/items_26574459.json`, `client_io/out/quest_ids_probe.json`.
- Read only, never edited or copied: `ClaudeDev.json` (his save), the `base` world snapshot's manifest, the newest brain log (`logs/brain-live-20261117-182835-26604.jsonl`) for his live skills and gear, `logs/client/client.log` and the brain logs for combat events.
- Wiki mirror `data/wiki/pages` (fetched 2026-10-25): Dragonkin Vault, all ten named vaults, Velgar, Velgar/Strategies, Velgar's Rise, Dragon Slayer, Rat King, Plague King, Giant Rat, the eight guardian pages, Spitfoot, Gravestone, Death, Power level, Vault Core, Chest (Vertentis Kara), Steam Achievements.
- Live wiki (2026-11-17): Vertentis Kara, Crasorak Kara, Chest. Same facts as the mirror.
- Web, eight phrasings: the Vertentis Kara route and its door; vault resets, respawns and instancing; Crasorak Kara and the Vault Overlord; entering Vertentis Kara before Dragon Slayer; clear times and walkthrough videos. Fetched: allthings.how (two guides), clawsomegamer, hostedgg, gamever, a Steam discussion. metaforge, gamepur, game8 and deltiasgaming refused the fetch (403, 402, 405).
- **Found nothing for:** a clear time for any vault (no guide or video length in any result); whether the Vertentis Kara door is locked before Dragon Slayer; a guardian respawn timer; a Steam achievement for any vault (the only boss achievement is "Dragon Slayer: Defeat Velgar").

## Found

### 0. The goal doc's facts, corrected

| goal doc says | the game says | source |
|---|---|---|
| first vault Vertentis Kara | Vertentis Kara is the storyline vault (Dragon Slayer part II, the "blue-flame door"), but 3rd in the wiki's standard order. Crasorak Kara (Temple Woods, order 1) is "the shortest vault and has the weakest enemies". | Dragonkin Vault (rev 2026-10-12), Vertentis Kara (2026-10-06, live same), Crasorak Kara (2026-09-20, live same) |
| boss Velgar | **Wrong.** Velgar is not in any vault. He is fought on top of Velgar's Rise (Fractured Plains, Ghornfell), summoned by placing a crafted Challenge Horn on the Dragonkin Altar, at the end of Dragon Slayer. Vertentis Kara's boss is the **Rat King**; the wiki also lists Plague King(s) there. | Velgar (2026-09-27), Velgar's Rise (2026-08-27), Dragon Slayer (2026-10-16) |
| power level 4 | Velgar: PL 4, right. Vertentis Kara and everything in it: **PL 2**. | same |
| 6,000 HP | Velgar 6,000, right. Rat King PL 2: **280 HP**. | Rat King (2026-09-25) |
| four phases | Velgar: right in effect. He flies up at about every 25 % of health lost and rains poison barrages, so four ground phases and three flights. The Rat King has no phases on the wiki. | Velgar/Strategies (2026-10-13), Dragon Slayer |
| poison | Velgar: poison breath, poison barrages (about 4 HP/s until cured), and he is immune to Poison and Burning. Vertentis Kara: the Plague King is a putrid rat ("veins pulse with poison"), poison-immune; its infobox lists no inflicted effect, so its poison is unconfirmed. | Velgar, Plague King (2026-08-17) |

The 6,000 HP, four phases and poison came into the goal from `docs/design/velgar.md` and `docs/research/2026-11-01-quest-backbone.md` step 9, which are about Velgar, correctly. The error is only in pairing him with the vault.

### 1. The vaults

Coordinates: game metres, converted from the wiki map centres as game x = wiki y / 100, game y = wiki x / 100. The rule is inferred, and it puts all 11 points I checked inside the right region's box in `data/places_26161880.json` (for example Velgar's Rise lands at (990, 980), 77 m from the Fractured Plains Wise Old Man at (993, 1057)). Each point is a map view centre, so expect it within about 50 m of the door, not at it.

| order | vault | region, approx. game (x, y) m | opens by | enemies (amount) | boss | rewards beyond chests and 3 vault cores |
|---|---|---|---|---|---|---|
| 1 | Crasorak Kara | Temple Woods, SE; (380, 1935) | open door; boss door by a lever up the stairs; an optional gate by a second lever reached with Windstep | PL 2: Giant Rat 9, Vault Guardian Hulk 4, Sentinel 3, Goblin Runt 2 | Vault Overlord | none (no recipe); 4 chests |
| 2 | Thishepen Kara | Bramblemead Valley, near the Runecrafting Guild; (250, 1495) | Windstep jump at the SW path, or drop from rock platforms NE | PL 2: Giant Rat 16, Hulk 10, Sentinel 5; PL 1 Giant Rat 5 | Vault Archon (PL 2, 3,100 HP, ranged) | the Highlighting the Problem password |
| 3 | Vertentis Kara | Whispering Swamp, east; (1025, 1435) | blue-flame door behind a tree on the easternmost island; levers inside; whether it opens before Dragon Slayer is unconfirmed | PL 2: Giant Rat 12, Hulk 7, Sentinel 5, Plague King (count unknown) | Rat King (with 2 Giant Rats in its room) | Anti-Dragon Shield recipe; Spitfoot (Dragon Slayer); clay nodes, Law/Nature/Air vents |
| 4 | Takla Kara | Fractured Plains, W mesa; (715, 1200) | mine rocks to reach the entrance; a lever for the boss area | PL 3: Giant Rat 5, Hulk 4, Sentinel 6 | Vault Incinerator (PL 3, 2,112 HP) | Paladin set, Wild Scout's Shortbow; blurite ore |
| 5 | Skeklac Kara | Fractured Plains, NE; (1375, 757) | 4 dragonkin statues at Ashien's Watch | PL 4: Putrid Rat 8, Hulk 7, Sentinel 4; exploding plant traps | Vault Corruptor (PL 4, 2,925 HP, poison) | Granite Maul (Granite Mauled quest) |
| 6 | Kletterbuja Kara | Bloodblight Swamp, S; (1170, 1680) | levers | PL 3: Putrid Rat 8, Hulk 8, Sentinel 6 | Plague King (PL 3, 488 HP) | Wild Archer set; Abyssal Whip with an Abyssal Spine |
| 7 | Chaktan Kara | Stormtouched Highlands; (150, 800) | cut vines, clear boulders; levers | PL 4: Giant Rat 7, Hulk 7, Sentinel 4 | Vault Pyroclast (PL 4, 2,925 HP, fire) | Dragonbone Dagger, Dragonkin Mage set |
| 8 | Kalistrakthen Kara | Emberwood, far W; (344, -516) | pressure plates, shock traps, active vault shards, dormant guardians | PL 5: Giant Rat 9, Hulk 13, Sentinel 4, Rat King 1; PL 4 Giant Rat 3 | Vault Striker (PL 5, 3,738 HP, shock) | Fallen Hoplite's Chest |
| 9 | Skekven Kara | Fellhollow, Lake of Lost Souls E; (1979, -424) | 4 dragonkin effigies (Windstep, mining) | PL 5: skeletons (warriors, archers, marauders, hoplite, necromancer), rats, guardians | Vault Overlord (PL 5, 2,875 HP) | Fallen Hoplite's Tassets, Undead Ranger's Bow |
| 10 | Vekchenven Kara | Lake of Lost Souls W, under a waterfall; (1440, -577) | soul rifting; wither, fire jets | PL 5: dragon wolves, rotridden rats, zogre, soulstone sentinels | none named | Necromancer's Staff, Fallen Hoplite's Helm, Curse Fragment (Rage) |
| 11, 12 | unnamed (Umbral Sands, two pyramids) | Umbral Sands | not documented | PL 7 | not documented | not documented |

What holds for every vault (sources in brackets):

| | |
|---|---|
| Entering | A door that fades or loads you into the interior (wiki update 0.8.1, "fade-in transitions when entering/leaving a vault"). The game data has `ASwitchableTeleporter` (`TeleportDestinationName`, `bForceDisplayLoadingScreen`) and `ATeleportationTarget`. Discovery only puts a vault on that player's map; it is not a lock. |
| Instanced? | Guides say "instanced". The game data says the interiors are places in the one world map `L_World` at coordinates off the playable map: Spitfoot's landmark is at (-1653, 218, -426) m with no region, and Velgar's arena altar at (991, 4285, 1051) m with no region (`data/places_26161880.json`). So on a server, everyone in one vault shares it (inferred, not seen). |
| Inside | Fire, spike, spear and electric traps, poison rocks, exploding plants (by vault), levers, hidden ways, Windstep ledges. No climbing exists in the game (DISCOVERIES l. 1060). Building is refused inside (`InsideVault`, DISCOVERIES l. 1788). |
| Death inside | The grave appears at the outside entrance, not inside (Gravestone, 2026-09-27; the same for Velgar's Rise). Respawn at his claimed bed, else the Temple of Saradomin lodestone (Death, 2026-04-13). Normal mode keeps any number of graves; ClaudeDev is not hardcore (`Hardcore.IsHardcore` false). Worn items and runes stay on him. A guide says killed enemies stay dead, so you resume where you stopped (allthings.how, 2026-09-16). The Gravestone page notes a bug where the grave does not appear where it should. |
| Resets | Chests respawn after 5 in-game days, about 2 hours (Chest, live 2026-10-13). Vault cores respawn on their plinths every 3 in-game days (Vault Core, 2026-09-23). Guardian respawn: no source; players disagreed in April 2025 (Steam thread). Fixes in 0.9.0.2 and 0.9.2 say lever and boss doors once stayed sealed when a player left between lever pulls, so door state persists across leaving. |
| Solo | All are soloable at their power level per the guides; none needs a second player. Kalistrakthen's pressure-plate timers and Vekchenven's soul rift are the hardest solo parts. |
| Gear and level | Match the vault's power level with armour (player PL = mean of head, body, legs armour PL, rounded down; Power level, 2026-10-24). PL 2 armour is the Leather set. There is no skill level gate. |
| Weight | A vault core weighs 50 kg; three in one run can over-encumber (Crasorak Kara page). |

The vault enemies of the first three vaults:

| creature | PL, HP | weak, resists, immune | attacks | drops |
|---|---|---|---|---|
| Giant Rat | PL 2: 100 | weak Stab, resists Crush | melee bite | 1 rat meat, fur, hide scraps, fang |
| Goblin Runt | PL 2 variant in Crasorak | (`creature_wiki.lua`) | melee | goblin pack |
| Vault Guardian Hulk | PL 2: HP "TBA" (PL 3: 390) | weak Crush; immune Poison, Bleed, Burning | rapid spin (drains a block's stamina: dodge), single slam (blockable, a parry makes it collapse), double slam (breaks a block: dodge, then hit while it is stunned) | 5 Stone; chance of essence, vault shards |
| Vault Guardian Sentinel | PL 2: HP "TBA" (PL 3: 325) | weak Crush; immune as Hulk | ranged: magic missile that tracks slightly; an underground projectile that erupts spikes under you (dodge) | 15 Stone; chance of essence, shards |
| Vault Overlord (Crasorak boss) | PL 2: 1,300 (wiki); 650 (metaforge, via search snippet) | none (wiki, PL 2 version); Crush (hostedgg); immune Poison, Bleed, Burning | a bigger Hulk: spin, slam, double slam that stuns it whether it hits or not | 15 Stone; chance of essence, shards |
| Rat King (Vertentis boss) | PL 2: 280 | weak Stab, resists Crush | melee, "higher attack accuracy" | always 3 rat meat, 3 fur, 3 hide scraps, 3 fangs |
| Plague King | PL 2: 300 | weak Crush, resists Stab, immune Poison | melee; poison unconfirmed | always 3 rat meat, 3 swamp tar, 3 hide scraps, 3 fangs, 1 poison ichor |

`client_mod/scripts/creature_wiki.lua` has every one of these except the Vault Overlord (its infobox has two versions with per-version weakness; the generator likely skipped it). That is for the lookup work, not this note.

### 2. The first vault to trial

**Recommendation for the developer: Crasorak Kara (boss Vault Overlord) first; Vertentis Kara (Rat King) second, as the storyline's vault; Velgar is a separate item, the end of Dragon Slayer, not Rung 6's "vault".** Reasons: Crasorak is about 290 m from ClaudeDev's saved position (101.5, 1857.5), has no quest gate on any source, and its boss path needs no Windstep (the wiki and allthings.how agree the boss lever is up the stairs; the Windstep lever opens an optional gate). Vertentis is about 1,000 m away across swamp water and sits in the middle of Dragon Slayer. Which vault Rung 6 means is Luis's call (open question 1).

Where ClaudeDev stands (save and brain log of 2026-11-17 18:28Z): First Steps, Getting Started, Ratcatcher and both parts of Rune Mysteries are done (state 2), and all four are at standard in `quest_run rates` (the chain gate passed 3 sittings in a row on 2026-11-17). The second First Steps (`ftue_fs2`) is in progress at Objective1. Dragon Slayer is not started (state 0). Growing Pains and Shrimp Catcher are started. Skills: Attack 27, Agility 39, Construction 27, Woodcutting 21, Artisan 18, Cooking 14, Mining 9, Ranged 4, Magic 3, Runecrafting 3, Fishing 3, Farming 1. Worn: Adventurer's Tunic and Leggings (PL 1 each), Leather Cowl (PL 2), Bronze Sword and Bronze Shield (PL 3 each), stone bodkin arrows, bone bolts. By the wiki formula that is PL 1; the brain's situation line printed "PL 0" in the same log (open question A9).

**Prerequisite chain, ClaudeDev to the Vertentis Kara door, storyline route** (status from PROGRESS and the status table):

| # | step | status | evidence |
|---|---|---|---|
| 1 | Walk to the Bramblemead Wise Old Man (433 m route) and finish the second First Steps | walk at standard once; the quest step untried | PROGRESS 2026-11-01 19:25Z `quest_bramblemead` x1.29 |
| 2 | Start Dragon Slayer (talk) | untried | |
| 3 | Shelter: foundation, 3 walls, ceiling | at standard | Rung 2 house 3 in a row, 2026-11-16 (on a fixture stand-in site) |
| 4 | Bed roll: make, place inside, claim | untried | no claim in PROGRESS |
| 5 | Antlers from a deer that flees (ranged) | untried (bow kills at standard, never a deer) | Rung 4 bow 3 in a row |
| 6 | Hand antlers to the Wise Old Man | at standard (talk and hand-in) | four-quest chain 2026-11-17 |
| 7 | Keep of Blue Flames: many goblins, read Cathan's Journal, Velgar strafes the keep | untried; groups and goblin archers are known killers | PROGRESS 2026-11-16 21:15Z (outnumbered deaths), 2026-11-02 run 1 (Goblin Archer) |
| 8 | Walk about 1 km to the swamp's easternmost island | untried (longest walk passed: 678 m) | Rung 1 come_here 2026-11-01 |
| 9 | Go through the door | untried; native crash risk (below) | |
| 10 | PL 2 body and legs (Leather): leather, coarse thread, craft, wear | known broken: thread needs a Spinning Wheel under a roof (parked); armour never made in a trial; `gear_up` 0 of 5 | status table; goal doc L1, 2026-11-02 |
| 11 | Food and clean water to carry | at standard (cook, boil) | Rung 3, 5 in a row |
| 12 | A weapon and shield | done (owned, PL 3) | brain log 2026-11-17 |
| 13 | A cure for poison (Lesser Antipoison: pottery wheel, kiln, brewing cauldron) | untried; only if the Plague King poisons | |

Count: 5 done or at standard (3, 6, 11 cook, 11 boil, 12), 8 untried (1, 2, 4, 5, 7, 8, 9, 13), 1 known broken (10).

**For Crasorak Kara** the chain is the gear and supply rows only, plus a 290 m walk (untried route, walks at standard) and the door (untried): 4 done (cook, boil, weapon, shield as one kit), 2 untried (walk, door), 1 known broken (armour, row 10). Without row 10 he enters at PL 1 against PL 2, "one level below" in the game's own icon.

**For Velgar** (if Luis means him): all of the Vertentis chain, then back to the Wise Old Man, Ghornfell (PL 3 to 4), Cathan's ghost, a Dragon Tooth (iron pickaxe) in the Stormtouched Highlands and Bloodwood Sap (iron axe) in Bloodblight Swamp, 5 Bronze Bars (a Furnace needs 8 Vault Shards; the Blacksmith's Bench needs a Vault Core, both vault loot), a PL 4 kit, 20+ food and antipoison. Every step past row 9 is untried.

### 3. Can it be trialled on the dev world?

**Checkpoints that exist** (`logs/quests/checkpoints/`): `gs_start`, `gs_chain`, `rc_start`, `rc_chain`, `rc_chain2`, `rm_start`, `rm_part2`, `rm_p2_runes_made`. All are inside the four tutorial quests in Temple Woods. None is at "ready to prepare" for a vault, at Bramblemead, or at a vault door. Clones of the three gate sittings exist as saves (`ClaudeQ171250`, `ClaudeQ171309`, `ClaudeQ171327`, likely the sittings of 12:50, 13:09 and 13:27Z).

**What must come from real runs (rule 8):**

| start | how it is made |
|---|---|
| "ready to prepare" | `quest_clone keep` of the last gate sitting's clone after Rune Mysteries (a real run that ended done). This is ClaudeDev's state without the edits of a hand-built bag. |
| "at the door, geared" | `--save-as` from the first trial that reaches the door after preparing. `tools/job_run.py` has `--save-as` and `--until first_step`; it has no "until he stands at a place" end yet. Until then this checkpoint cannot be made by the rule. |
| Vertentis route | a `--save-as` after each storyline step above (rows 1, 4, 5, 7), each from its own trial. |

**Dev fixtures for a first look, never a pass:** a new clone (never ClaudeDev) with a bag edit (the PL 2 Leather set and food, as `quest_clone` already edits bags) and a harness walk or a `K2_TeleportTo` to the door (verified on the puppet, DISCOVERIES l. 597). Use it only for a harness look with no brain: probes of the door, levers, chests and creatures. A brain run in a fixture would spend the first three held-out trials of "anything new".

**Is the vault's state in the world save?** Probably yes, not verified:
- The interiors are places in `L_World` (section 1), and the server saves `L_World` as World Partition cells in `SpudCache/RSACell12800_X<i>_Y<j>.lvl` (cell = floor(metres / 128)), backed up by `world_snapshot`.
- The `base` snapshot (2026-11-17 17:12Z) holds cell X7_Y33. That is the cell of Velgar's arena altar (991, 4285 m), so an off-map arena cell is part of the dev world save.
- It holds no cell near Spitfoot (X-13_Y1), so no one has loaded or changed the Vertentis interior on this world, or the server saves only changed cells.
- Crasorak's interior coordinates are unknown (no landmark inside it in `places`).
- Character-side: `GameProgress.Progress.KilledOnceAIs` in the character save (6 ids on ClaudeDev today) is per character, not per world.

So `world_snapshot restore` should put the vault back as it was when the snapshot was kept. It cannot make the vault fresh: a `vault_fresh` snapshot must be kept before anyone enters, and only if the look shows the vault uncleared on this world. Chests come back after about 2 hours and cores after 3 in-game days, so two windows a few hours apart without a restore would meet different vaults (rule 9 already voids that).

**Crash risk at the door.** The entry and the exit are a teleport into a part of the world that streams in while the old one streams out. Two entries of the crash register apply:
- R17: the stale property cache when World Partition frees a class.
- R18: a map travel the game starts itself. The travel hook 61c6870 has never fired live.

The game's own Unstuck teleport crashed the client before (`push_arrayproperty`, DISCOVERIES l. 952). Death and respawn teleports are survived routinely (the grave runs), which is the closest evidence that this will hold. The first entry should be a harness look with the loops paused across the fade, as Unstuck now does.

### 4. What he can and cannot do today

| the vault demands | today | evidence |
|---|---|---|
| Walk 290 m to 1 km to the door | can: 678 m and 499 m walks at standard; Bramblemead 433 m x1.29 | PROGRESS 2026-11-01 |
| Jumps (ledges, stairs, rubble) | weak: 36 % of paths with a jump up had a landing judged missed (14 to 17 Nov) | goal doc section 2 |
| Windstep as a jump (Thishepen entry, Crasorak optional gate) | never tried; Windstep only as a combat stomp | DISCOVERIES l. 406 |
| Climbing | does not exist in the game | DISCOVERIES l. 1060 |
| Swim or wade (Vertentis water room, swamp) | partly: arriving over a pond bed is checked (62d7fc7, tests only) | PROGRESS 2026-11-16 |
| **Go through a vault door (teleport)** | **never tried; crash risk R17, R18** | section 3 |
| **Pull a lever; read a door or lever state** | **never tried: no lever, switch or door-state code in `client_mod` or `brain`** | grep, 2026-11-17 |
| See and pass traps (fire jets, spikes, timed) | never tried: `ASwitchableTrap` is not read; the hazard census covers creatures' ground projectiles, meteors and poison clouds only | `docs/design/velgar.md` 3b |
| Darkness | no effect on him: perception reads actors, not pixels. Inside navigation (a navmesh in the interior) never tried | |
| Fight a group (3 Hulks in one room; 3 Sentinels at range) | weak: deaths with two attackers (Ratcatcher, 2026-11-16); target swap 5d07a74; Ratcatcher alone 5 of 5 after it (s9); never against PL 2 guardians | PROGRESS 2026-11-16 21:15Z, 23:25Z |
| Block, parry, dodge a telegraph | can against rats and goblins (1,458 parry lines in client.log); a block-breaking slam never met | client.log; velgar.md 2 |
| Dodge a ranged projectile or underground spikes (Sentinel) | built offline (hazard census, escape zones); never seen live | velgar.md 3b; no `hazard` combat event in any log |
| Read a creature's ability as it starts | works live (`creature_ability` events, e.g. 2026-10-28, 2026-11-01) | brain logs |
| A boss with phases (flight hold, phase line) | built offline; never live (no `boss_phase` event in any log). The Overlord and the Rat King have no phases on the wiki | velgar.md 3b |
| Poison: read it, cure it | read live (Poison 16.6 of 100, `have_cure` false, 2026-11-02); a cure never used (no `cured` event) | brain log 2026-11-02 06:59Z |
| Eat in a fight | can (disengage, eat, re-engage; `heals` above 0 in 22 brain logs) | velgar.md 2; brain logs |
| Ranged against melee | can: bow kills and staff kills at standard (Rung 4) | status table |
| Match a weakness (Crush against guardians, Stab against rats) | the weakness is shown in `combat_brief` once the creature is in sight; whether he switches weapon never measured | goal doc section 3 |
| Loot a chest, a plinth core, "Learn" a plan on the loot screen | partly: a grave's "Take All" works (at standard); a chest, a plinth and a loot-screen "Learn" never tried; 50 kg cores against his carry | Rung 1 grave |
| **Survive a death inside and go on** | **grave recovery at standard in Temple Woods; but the job does not survive his death (two re-plans, then stuck; nothing brings the ask back after the grave)** | goal doc section 1 table |
| Over weight after cores | known failing the same way as death | goal doc section 1 table |

**The three most likely to block the first run**, in order:
1. **The door and the interior's mechanisms:** an untried teleport with a crash class behind it, then levers and doors he has no read or act for, and traps nothing perceives.
2. **Group fights against PL 2 guardians**, at PL 1 if row 10 stays broken: three Hulks with block-breaking slams in one room, Sentinels at range. His deaths so far came from two attackers.
3. **The job not surviving his death:** the grave lands outside, and the ask is lost after the grave run today. A first run will likely include a death.

### 5. Grading from game state

| verdict | readable today | file, function or line | not readable today |
|---|---|---|---|
| **Prepared**: worn and carried gear against the target | Worn gear per slot (`gear` in get_state); bag counts and consumable kinds; the target from `tools/rung4_gate.py` `gear_target(state, stash)`, which calls `brain/gear_plan.py` `plan()` | brain log `"gear": {...}`; `inventory.consumable_kind`; `job_run` L3 `gear_target`, `consumables_carried` | The vault's enemies: `plan()` caps by `nearby_entities` in sight (`enemy_pl`), so at home the target ignores the vault (long-job-harness "missing read 2"). The grader can pass the vault's enemy list from the wiki mirror as its own input to `plan()`: grader-side, never shown to him. `plan()` has no food, drink or cure targets, and does not weigh weakness against damage type. |
| **Inside** | His position: the interior lies at off-map coordinates (Vertentis near x = -1653 m); the 5 Hz recorder pose shows the teleport as a jump of hundreds of metres | `mod/experiments/player_recorder.lua` (`logs/recorder/rec_*.jsonl`) | Crasorak's interior box (a look) |
| **Cleared** | Creatures within the perception list with alive, `PowerLevel`, `bIsBoss` (DISCOVERIES l. 1002); vault cores in the bag (`ITEM_Resources_VaultCore`, 3 per vault, one in the boss room); kills reported in `combat_end` | get_state `nearby_entities`; inventory; brain log `combat_end` | Doors and levers: `ASwitchBase.SwitchState` (replicated, `OnRep_SwitchState`) and `BP_FinalDoor_vault_Refactored` (`BP_OnDoorStateChanged(EDoorState)`) exist in the dump but no probe reads them. Chests opened: no field found yet (`ADungeonChest` is the procedural dungeon's class; the vault chest's class is unknown). A full enemy count needs the vault's spawn list; the wiki counts are the only one. |
| **Boss killed** | `combat_end` naming the boss with a kill; `record_boss_attempt` when `bIsBoss` is set; the boss's fixed drop as a bag delta (Overlord: 15 Stone always; Rat King: 3 meat, 3 fur, 3 scraps, 3 fangs always); the boss-room core | `client_mod/scripts/combat.lua` `record_fight`, `record_boss_attempt`; recorder inventory deltas | Whether the game sets `bIsBoss` on the Overlord or the Rat King (a look). `KilledOnceAIs` in the character save gains an id on a first kill, but the ids have no names yet: a read like `quest_ids_probe.lua` would map them, and the save is written only at autosave. No Steam achievement exists for a vault. |
| **Death inside, recovered** | The grave registry and its contents; "USERNAME has died" in chat; respawn position | grave run tools (Rung 1) | |
| Velgar (if chosen) | Dragon Slayer quest state and objective (`quest_objectives`); Velgar's Head in the bag; the arena's `PhaseRuntimeData` (built offline) | `client_io/out/quest_objectives.json` | the arena read is unverified live |

A server-side truth for "boss killed" that needs no client mod: the recorder's inventory delta of the boss's fixed drop plus the boss-room core, read together with his position inside the interior box.

### 6. A human's time

`docs/BASELINES-2026-11-01-luis.md` has no vault, no boss and no dungeon. Its longest fights are a goblin (11 s) and a herd of cows (74 s). No wiki page, guide or video found gives a clear time for any vault. The wiki only calls Crasorak "the shortest vault".

**The one thing to ask Luis, once:** on the dev world, with the recorder armed and a world snapshot kept just before, play Crasorak Kara from its outside door until the Vault Overlord is dead and its chest is looted, at his normal pace, then walk out. The recorder gives the time from the entry teleport to the exit, each kill's time from his swings and loot, his deaths, and his bag on the way in (his own "prepared"). His run clears the vault on that world, which is why the snapshot comes first. Restoring it afterwards rolls back his character's copy in the world save, which he allowed on 2026-11-17 (decision 3; `--others-ok`).

Fallback if he cannot: a composed bar as for the quests (walking at 6.25 m/s over the route, plus his unit times per kill). It is weaker because his fight units are rats and goblins, not guardians.

## Proposal

1. The goal doc's section 4 sentence is wrong (Velgar is not a vault boss) and should be corrected in the main session (I edited nothing). The choice of vault is Luis's (question L1). Crasorak Kara is the shortest honest Rung 6.
2. Before any brain trial, a harness look on the dev world with no brain (questions A1 to A9). The first entry runs with the loops paused across the teleport. Only then keep `vault_fresh` with `world_snapshot`.
3. Split the capstone into items, each worked alone (rule 1): V-prep (L3 against the vault's enemy list), V-door (walk to the door), V-clear (door to the boss dead and the boss chest looted), then V-whole from one ask. Checkpoints: `vault_ready` (a keep of the last gate sitting's clone), `vault_door` (`--save-as` from V-door, which needs a place end in `job_run`).
4. Grader reads to add, read-only: a vault-state probe (door and lever `SwitchState`, chest state, his position against the interior box, the creature census with `bIsBoss`), and a `KilledOnceAIs` name map. Every one is a property read, no RPC.
5. The first three V-clear runs are held-out scores, run from `vault_door` on `vault_fresh`.

## Open questions

**For Luis**
- L1. Does Rung 6 mean a vault and its boss (Crasorak Kara and the Vault Overlord, or Vertentis Kara and the Rat King), or Velgar, who ends Dragon Slayer and is not in a vault?
- L2. Will he play Crasorak Kara once on the dev world for the time bar (section 6)?

**Answerable by a look on the dev world (harness, no brain)**
- A1. Is Crasorak Kara (and Vertentis Kara) uncleared on this world: guardians alive, cores on plinths, chests closed?
- A2. Does the Vertentis Kara door open for a character with Dragon Slayer at state 0?
- A3. Where does each door teleport to (`TeleportDestinationName`, the target's position, its SPUD cell), and does the client survive the fade with the loops paused?
- A4. Are the lever and door states readable on the client (`SwitchState`), and what class is a vault chest?
- A5. Is `bIsBoss` set on the Vault Overlord and the Rat King? What is the Overlord's HP at PL 2 (1,300 or 650)?
- A6. Do killed guardians stay dead after leaving, after a relog, and after `world_snapshot restore`?
- A7. Is there a navmesh inside (`MoveToActor` from the entry to the first room)?
- A8. What names do ClaudeDev's six `KilledOnceAIs` ids have?
- A9. What PL does the game itself report for him (the save says PL 1 by the formula; the situation line printed PL 0)?

## Not taken

- **Velgar as the first trial:** about 20 untried steps before the fight, and the bronze tier itself needs vault loot (8 Vault Shards for a Furnace, a Vault Core for the Blacksmith's Bench). A vault comes first either way.
- **Thishepen Kara:** its entry needs a Windstep jump or a drop from rock platforms, on top of the 36 % missed landings.
- **The pedestal trick** for Velgar (teleport out and back so the horn holder stays): it reads as an exploit; `docs/design/velgar.md` already left it to Luis.
- **A checkpoint from a fixture** (bag edit plus teleport to the door): rule 8 forbids it; kept for a no-brain look only.
- **Adding the Vault Overlord to `creature_wiki.lua`, or vault entries to `lookup`:** that is the lookup agent's work (goal section 3), and this note must not become something he reads.
- **Walkthrough steps per room:** the wiki and guides have them, and they are deliberately not copied here as a route. A route would be a recipe.

## Limits

- The vault facts are from the community wiki and guides, which disagree in places: the Overlord's HP, its weakness, the chest count (4 against 6), whether vaults "reset". Only three wiki pages were checked live today; the mirror is from 2026-10-25 and server build 26574459 is current to the wiki's 1.0.1 notes.
- The coordinates are map view centres converted by an inferred rule, good to about 50 m. The doors' exact positions are unknown.
- "Interiors are part of `L_World` and saved in SPUD" is inferred from two off-map landmarks and one saved cell, not from a vault entered on the dev world.
- His abilities come from logs and PROGRESS, not from a new trial. "Never tried" means no log line or PROGRESS entry was found.
- The prerequisite counts depend on how the steps are cut; the table shows the cut.
- Nothing about a human's vault time was found; the bar does not exist until Luis plays one.

## Sources

Wiki (CC BY-NC-SA; the date is each page's last revision as mirrored on 2026-10-25, live re-checks on 2026-11-17 where marked):
- Dragonkin Vault, 2026-10-12: https://dragonwilds.runescape.wiki/w/Dragonkin_Vault
- Crasorak Kara, 2026-09-20 (live 2026-11-17, same): https://dragonwilds.runescape.wiki/w/Crasorak_Kara
- Vertentis Kara, 2026-10-06 (live 2026-11-17, same): https://dragonwilds.runescape.wiki/w/Vertentis_Kara
- Thishepen Kara, 2026-10-11: https://dragonwilds.runescape.wiki/w/Thishepen_Kara
- Takla Kara, 2026-08-27: https://dragonwilds.runescape.wiki/w/Takla_Kara
- Skeklac Kara, 2026-08-25: https://dragonwilds.runescape.wiki/w/Skeklac_Kara
- Kletterbuja Kara, 2026-09-21: https://dragonwilds.runescape.wiki/w/Kletterbuja_Kara
- Chaktan Kara, 2026-08-09: https://dragonwilds.runescape.wiki/w/Chaktan_Kara
- Kalistrakthen Kara, 2026-10-09: https://dragonwilds.runescape.wiki/w/Kalistrakthen_Kara
- Skekven Kara, 2026-09-23: https://dragonwilds.runescape.wiki/w/Skekven_Kara
- Vekchenven Kara, 2026-10-24: https://dragonwilds.runescape.wiki/w/Vekchenven_Kara
- Velgar, 2026-09-27: https://dragonwilds.runescape.wiki/w/Velgar
- Velgar/Strategies, 2026-10-13: https://dragonwilds.runescape.wiki/w/Velgar/Strategies
- Velgar's Rise, 2026-08-27: https://dragonwilds.runescape.wiki/w/Velgar%27s_Rise
- Dragon Slayer, 2026-10-16: https://dragonwilds.runescape.wiki/w/Dragon_Slayer
- Rat King, 2026-09-25: https://dragonwilds.runescape.wiki/w/Rat_King
- Plague King, 2026-08-17: https://dragonwilds.runescape.wiki/w/Plague_King
- Giant Rat, 2026-09-19: https://dragonwilds.runescape.wiki/w/Giant_Rat
- Vault Guardian Hulk, 2026-08-27: https://dragonwilds.runescape.wiki/w/Vault_Guardian_Hulk
- Vault Guardian Sentinel, 2026-08-27: https://dragonwilds.runescape.wiki/w/Vault_Guardian_Sentinel
- Vault Overlord, 2026-08-27: https://dragonwilds.runescape.wiki/w/Vault_Overlord
- Vault Archon, Incinerator, Corruptor, Pyroclast, Striker, 2026-08-27 to 2026-09-22: https://dragonwilds.runescape.wiki/w/Vault_Guardians
- Spitfoot, 2025-12-19: https://dragonwilds.runescape.wiki/w/Spitfoot
- Gravestone, 2026-09-27: https://dragonwilds.runescape.wiki/w/Gravestone
- Death, 2026-04-13: https://dragonwilds.runescape.wiki/w/Death
- Power level, 2026-10-24: https://dragonwilds.runescape.wiki/w/Power_level
- Vault Core, 2026-09-23: https://dragonwilds.runescape.wiki/w/Vault_Core
- Chest, live 2026-11-17 (last edited 2026-10-13): https://dragonwilds.runescape.wiki/w/Chest

Guides and forums (untrusted; used only where they agree with the wiki or are marked):
- allthings.how, Temple Woods vault final gate, updated 2026-09-16: https://allthings.how/runescape-dragonwilds-how-to-open-the-temple-woods-vault-s-final-locked-gate/
- clawsomegamer, the blue flame door, 2025-08-19: https://clawsomegamer.com/how-to-investigate-the-blue-flame-door-in-runescape-dragonwilds
- hostedgg, vaults guide, undated: https://hostedgg.com/blog/runescape-dragonwilds-vaults-guide
- gamever, every vault in order, undated (image paths suggest 2026-08): https://gamever.io/knowledge-base/every-dragonkin-vault-in-dragonwilds-in-order-with-power-levels
- Steam discussion "Vault Guardians/Enemies not respawning", 2025-04-20: https://steamcommunity.com/app/1374490/discussions/0/604154053014861164
- Seen in search results only (fetch refused): metaforge Whispering Swamp and Temple Woods walkthroughs and Vault Overlord entries (https://metaforge.app/runescape-dragonwilds/whispering-swamps-vault-walkthrough, https://metaforge.app/runescape-dragonwilds/temple-woods-vaults-walkthrough), gamepur (https://www.gamepur.com/guides/how-to-open-temple-woods-vault-gate-runescape-dragonwilds), game8 vault walkthroughs, deltiasgaming (https://deltiasgaming.com/?p=206444).

Repo and game data: as listed under Searched; class names from `dumps/26574459/CXXHeaderDump/Dominion.hpp` (`ASwitchBase`, `ASwitchableDoor`, `ASwitchableTeleporter`, `ASwitchableTrap`, `AFightArenaManager`) and `BP_FinalDoor_vault_Refactored.hpp`.
