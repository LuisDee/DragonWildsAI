# Crasorak Kara: the door, the way there, what is inside, and the probe window (2026-11-17)

For the developer who runs the vault probes (steps P2 to P5 of `docs/research/2026-11-17-vault-reads.md`) and later the Rung 6 trial (`docs/GOAL-2026-11-17-long-jobs.md` section 4). Not for the companion: nothing here goes into a prompt, a tool description or a recipe. Offline research only. Nothing was run against the server, the client or the brain, no model was called, and no repo file other than this one was written.

Builds on `docs/research/2026-11-17-vault-capstone.md` ("the capstone note") and `docs/research/2026-11-17-vault-reads.md` ("the reads note").

## Searched

- Dump `dumps/26574459/UE4SS_ObjectDump.txt` (a server dump, no positions in it), the client UE4SS log (`...\RSDragonwilds\Binaries\Win64\ue4ss\UE4SS.log`), `logs/client/client.log` (no `vault_*` line: `sense.vault_note` prints to the UE4SS log only), all brain logs `logs/brain-*.jsonl` of 2026-10-25 to 11-17 (739 MB, scanned for teleporter rows, creature rows and lodestone rows), `client_io/bridge/client_to_brain.jsonl`, `logs/state/worlds/dev_farm/map_memory.json`, `logs/world_snapshots/base/manifest.json`.
- Wiki mirror `data/wiki/pages/` (the one `tools/build_bestiary.py` builds from, l. 37): Crasorak Kara (3515), Dragonkin Vault (1315), Vault Overlord (1331), Vault Guardian Hulk (1329), Vault Guardian Sentinel (1330), Vault Guardians (3359), Giant Rat (169), Goblin Runt (1323), Chest (Crasorak Kara) (5462), Power level (181), Lodestone (405), the PL 2 armour pages, the crush weapons, the food pages. `data/bestiary.json`.
- Repo: `docs/DISCOVERIES.md`, `data/places_26161880.json` and `brain/places.py` (regions), `evals/bench/dev_places.json`, `client_mod/scripts/sense.lua` (vault reads, 6d78811), `client_mod/scripts/client_bridge.lua` (teleport hooks), `mod/bench/fixtures.lua` and `evals/bench/devtarget.py` (the teleport fixture), `tools/travel_ladder.py` (`place`), `tools/quest_run.py` (`clone_window`), `tools/world_snapshot.py`, `tools/quest_clone.py`.
- **Found nothing for:** the door's position in the dump (the object dump has names, not transforms); a lodestone near the door (none in the game's landmarks, none on the wiki mirror's lodestone page, none seen live); the interior's coordinates (no read has been made inside); any client read of a `TeleportationTarget` (no `vault_targets` line in the UE4SS log).

## 1. The door

### Its position: read live, not estimated

The door is the actor `BP_InteractablePlayerTeleporter_C_UAID_18C04D97CB3D30D401_1397338720`. Its `look` row, seen by his body in 23 reads between 2026-11-01 13:12Z and 11-02 08:19Z:

| field | value |
|---|---|
| name (the game's `DisplayName`) | **Crasorak Kara** |
| prompt (`InteractionPrompt`) | **Enter** |
| actor_position | **(374.58, 1918.74, -2.76) m** = (37458, 191874, -276) game units (cm) |
| position (the interaction point) | (374.58, 1918.74, -0.33) m |
| kind | interactable |

Sources: `logs/brain-20261101.jsonl` l. 8973 (seen from (363.34, 1901.64, -2.52) at 20.5 m), `logs/brain-20261102.jsonl` l. 23602, 23618, 26925, `logs/brain-live-20261102-062524-17740.jsonl` l. 42, `logs/brain-live-20261102-091736-5076.jsonl` l. 81, `logs/state/worlds/dev_farm/map_memory.json` (seen 13 times). Those runs were on the dev server under the world label `dev_farm` (`session_start` row, l. 10 of the 062524 log). The door is an always-loaded actor of `L_World`'s persistent level (object dump l. 275023), so its place is the same on every world of this map.

Check against the wiki: the Crasorak Kara page's map centre is `center=193500,38000` (page 3515, rev 69708, l. 13 of its wikitext). With the capstone note's rule (game x = wiki y / 100, game y = wiki x / 100) that is (380, 1935), **17 m** from the live door. The rule holds here.

What else stands at it: a Fire Anima Vent at (400.14, 1927.7), 27 m east (`data/places_26161880.json`; the same actor in the look rows). Region: Temple Woods, power level 1, province Brynmoor (`brain/places.py` `region_at`). The Bramblemead Valley border (power level 2) is about **60 m north-east**, near (421, 1880). Compass: north is -Y, east is +X (DISCOVERIES l. 2288).

The door's family in the object dump (same UAID prefix `18C04D97CB3D30D401`, same placement batch):

| object | line | likely role (inference) |
|---|---|---|
| `BP_InteractablePlayerTeleporter_C_..._1397338720` | 275023 | the outside door (read live, above) |
| `BP_InteractablePlayerTeleporter_C_..._1545295722` | 275025 | its pair: the way out, inside |
| `TeleportationTarget_..._1454414721` | 282616 | one arrival point |
| `TeleportationTarget_..._1602976723` | 282618 | the other arrival point |

No `BP_PlayerGraveyard_8Slots_C` carries this prefix (16 graveyards listed, none `18C04D97...`), so which graveyard the door's `GraveyardRef` names is open.

**A probable match for the inside mechanisms.** The only always-loaded vault mechanisms in the dump form one batch, `A036BC08BFCE9ECF02_7c311a62294e3e8c`: 3 `BP_BinaryLever_C` (object dump l. 274787, 274791, 274795), 1 `BP_FinalDoor_vault_Refactored_C` (274938), 1 `BP_SwitchableDoor_Vault_4x4_C` (275914), 1 `GameplaySwitch` (276995). The Crasorak walkthrough has exactly 3 levers (the boss lever up the barred stairs, the optional gate lever south of the fork, the shortcut lever behind the Windstep opening), one boss door and a gate that opens back to the starting room (page 3515, "Walkthrough"). That this batch is Crasorak's is an inference; probe P1b below settles it by testing the actors' positions against Crasorak's box.

**What the client already reads (live, today).** UE4SS.log l. 1928: `[2026-11-17 19:45:10] [DWClient] vault_list n=32 source=registry complete=false`: the client reads `AGameplayObjectRegistry.Dungeons`, 32 entries, at least one without a usable box or name (the server dump has 17 `ADungeon` actors). The next lines (1929 to 1931 and later) are `vault_read in_vault=false vault=nil teleporters=0 ...` at radii 8, 30 and 50 m near home. No `vault_targets` line exists yet: `teleport_targets()` runs only when a teleporter row is in range (`sense.lua` l. 829-858, 860-875).

### Distances (straight line, metres, x-y plane)

| from | to the door | note |
|---|---|---|
| his usual home area (150, 1910) | **224.8** | due east (dx +224.6, dy +8.7) |
| ClaudeDev's saved place (101.52, 1857.51) | **279.8** | the capstone note's "about 290 m" |
| the standing-trees spot (100, 1892, -31) | 275.9 | `evals/bench/dev_places.json` |
| **nearest lodestone**: the built one at (182.12, 1814.69, -30.23) | **218.8** | `BP_BaseBuilding_Lodestone_C_2147466337`, seen live up to 2026-11-17 15:19Z (`logs/brain-live-20261117-151932-23576.jsonl`); its twin at (181.68, 1797.16) is 228.0 m |
| the Temple lodestone (50.65, 1890.26, -34.88) | 325.2 | the start area's stone and the respawn without a bed (DISCOVERIES l. 2281) |
| the Temple of Saradomin (wiki centre (10, 1845)) | about 372 | page "Temple of Saradomin", map centre 184500,1000 |
| Brynmoor | 0 | Brynmoor is the province (the game's `EQuestRegion` 1: Temple Woods, Bramblemead Valley, Whispering Swamp; DISCOVERIES l. 615-619); the door is inside it, 60 m from its Bramblemead Valley part |

A lodestone gains nothing for this trip: the nearest one is as far from the door as his home is (219 m against 225 m). The wiki's cost rule is law runes = (distance / 1000) x (weight / 1000), minimum 1 (Lodestone page 405).

**The way has been walked.** On 2026-11-02 he walked from (174.60, 1919.40, -30.90) to (397.85, 1893.22, -6.22): "Walked 235 m in 42 s (5.6 m/s)" (`logs/brain-live-20261102-062524-17740.jsonl`, the grave walk after his death there). The ground rises about 25 m from home to the door.

## 2. What lives there

### On the way and at the door (seen live by his body)

Every creature row with a position within 60 m of the straight line from (150, 1910) to the door, in all brain logs of 2026-10-25 to 11-17 (distinct actor ids; script in the scratchpad, not kept). Levels are the game's `PowerLevel`; HP from the bestiary (`data/bestiary.json`).

| stretch | creature (PL, wiki HP at that PL) | aggressive | seen where, when |
|---|---|---|---|
| near home, x 115-180 | Goblin Runt (PL 1, 60) | yes, weak to Fire | 13 sightings, 2026-10-27 to 11-16, e.g. (168.0, 1912.2), (116.9, 1869.7) |
| middle, x 274-300, 40-60 m south of the line | Giant Rat (PL 1, 50) | yes, weak to Stab, resists Crush | 12 distinct, 2026-10-31 to 11-17, e.g. (282.3, 1866.4), (291.1, 1866.2) |
| x 320-370, south | Deer (PL 2, 172), Cow (PL 2, 120) | no | 2026-11-01 to 11-17 |
| x 359-370, 50-58 m south | Goblin Runt (PL 1); **Giant Rat (PL 2, 100)** x2 | yes | 2026-11-17 05:19Z, (364.4, 1861.1), (369.8, 1861.2) |
| **at the door** | Giant Rat packs: PL 1 x3 at (349-359, 1943-1946), 25-30 m south of it (11-01 13:12Z); PL 1 x2 at (352.9-354.8, 1903.2), 25 m west (11-02 04:48Z); **PL 2 x3-4 at (399-403, 1893-1907)**, 30-35 m north-east (11-02 04:48-04:49Z) | yes | `logs/brain-20261101.jsonl` l. 8973; `logs/brain-20261102.jsonl` l. 23602, 23618 |
| 60-70 m north-east, in Bramblemead | Goblin Runt (PL 1) x2 at (434-445, 1876-1886) | yes | 11-02 05:26Z, same log l. 26925 |
| everywhere | Kebbit, Magpie, Chicken (PL 1), Deer (PL 1) | no | many |

**He died there once.** `last_death`: killed by a Giant Rat (`BP_AI_GiantRat_Character_C`) at (399.1, 1893.0, -6.3), about 04:50Z on 2026-11-02, 35.5 m north-east of the door; food 69, water 50 (`logs/brain-live-20261102-062524-17740.jsonl` l. 7 on). The PL 2 rat pack above stood on that spot a minute before. The bestiary lists only Chicken, Deer, Giant Rat, Goblin Runt and Magpie for Temple Woods (`data/bestiary.json`, `locations`), and the live rows agree.

### Inside (the wiki)

Page "Crasorak Kara" (3515, rev 69708, 2026-09-20; checked live 2026-11-17 by the capstone note, same): "Power level 2 variants of the following". Bestiary entry `data/bestiary.json` l. 11628 (text l. 11731).

| enemy | count | PL 2 HP | weak / resists / immune | attacks | source |
|---|---|---|---|---|---|
| Giant Rat | 9 | 100 | weak Stab; resists Crush | melee bite ("Attacks: not in the mirror") | page 169; bestiary l. 3246 |
| Vault Guardian Hulk | 4 | "TBA" (PL 3: 390) | weak Crush; immune Poison, Bleed, Burning | rapid spin (wears down stamina; dodge, blocking drains it), single fist slam (blockable; a parry makes it collapse), double-fisted slam (breaks a block; stuns the hulk) | page 1329 (rev 66503); bestiary l. 9800 |
| Vault Guardian Sentinel | 3 | "TBA" (PL 3: 325) | weak Crush; immune Poison, Bleed, Burning | ranged: Magic Missile (tracks slightly), an underground projectile that erupts spikes under you (dodge) | page 1330 (rev 66504); bestiary l. 9946 |
| Goblin Runt | 2 | not on the page (PL 1: 60, PL 3: 195) | weak Fire | melee; "much weaker enemies" (the vault page) | page 1323 (rev 71111); bestiary l. 3691 |
| **Vault Overlord (boss)** | 1 | **1,300** | **weakness None** at PL 2 (Crush only for the PL 5 Skekven version); resistance None; immune Poison, Bleed, Burning; aggressive | "a vault hulk but with much more health and damage": rapid spin (dodge; blocking drains stamina fast), standard fist slam (blockable; a parry makes it collapse), double-fisted slam (breaks your block and stuns you; it also stuns the Overlord whether it hits or not) | page 1331 (rev 66508); bestiary l. 10190 |

- **Boss level: 2.** Its drops: 15 Stone always; 15 Stone 25/100; 9 Rune Essence 75/100 and 46/100; 6 Vault Shards 25/100; 9 Vault Shards 15/100. Melee XP 430 (page 1331 infobox).
- The 650 HP of metaforge (capstone note) is half the wiki's 1,300. The Power level page's rule "Hitpoints = Region Power Level x Monster's Base Hitpoints" (page 181, rev 76399) would make 650 the base and 1,300 the PL 2 value. An inference; probe P4 or a fight reads the real number.
- The layout, in the page's order: entry; to the right (north) the locked boss door; south, barred stairs with the boss lever at the top, a **patrolling Hulk in the entry hallway**; south hall room with 2 rats and a chest behind the stairs; a large multi-level room with **3 Hulks** (a chest below its entrance); 3 fire traps in a hall; a spike room ("a safe zone in the middle"), a rat to the west; 2 rats in a dead end; **3 Sentinels** ("they can be lured out one at a time as they are spaced far apart"); vault core 1 at a dragonkin statue, a chest left of it; spike and fire traps east (spikes in a diamond, thinnest at the walls); a fork: stairs up to the boss lever, south to optional treasure (a lever, 2 fire traps, a gate, 2 Goblin Runts, spikes, treasure), north a spike room with 4 rats; core 2 with treasure and a shortcut lever behind a Windstep opening; pull the boss lever at the top of the stairs, go through the gate to the starting room, the large door opens on the Overlord; core 3 and a chest after him.
- 4 chests (`Chest (Crasorak Kara)`, page 5462: runes, rune essence, decoration plans, plus 2-3 extra rolls). 3 vault cores, 50 kg each.
- Death inside: the grave appears at the outside entrance (page 1315, rev 74247).

## 3. What a player brings at this level (wiki facts, not a plan for him)

- **Armour sets the player's power level**: "starting at power level 0 while wearing no armour"; pieces of different levels are averaged and rounded down (page 181). The vault is PL 2, so PL 2 armour on head, body and legs puts a player "at" the enemies; PL 0 or 1 shows "more than one level below" or "one level below" (page 181, icon table).
- **The PL 2 sets** (all at a Crafting Table, Artisan 40 XP each):

| set | pieces and materials | stats (body) | set bonus | pages |
|---|---|---|---|---|
| Reinforced (melee) | Helmet: 4 Animal Bone + 2 Leather. Body: 10 Animal Bone + 8 Leather. Legs: 8 Animal Bone + 6 Leather | melee def +15, ranged +9, magic +8 | -33 % block stamina cost, +50 % crit chance after blocking, +25 damage to staggered targets | 758, 988, 997 |
| Leather (ranged) | Cowl: 4 Leather + 2 Coarse Thread. Body: 10 Leather + 8 Coarse Thread. Chaps: 8 Leather + 6 Coarse Thread | melee +9, ranged +13, magic +9 | +40 stealth speed, -33 % ranged attack stamina cost, +25 % weak-point damage | 837, 838, 839 |
| Apprentice (magic) | Robe: 10 Coarse Thread + 8 Rune Essence (hat and leggings likewise from thread) | melee +8, ranged +9, magic +15 | -50 % stamina regen delay, +17.5 % magic attack speed, +15 % magical crit | 835 |

  Leather comes from a Tannery: 1 Animal Hide, or 3 Animal Hide Scraps, per Leather (page 282). **The Reinforced set needs no thread**, so the spinning wheel the goal doc names as the blocker (parked item 5) blocks only the Leather and Apprentice sets. Every rat drops 1 hide scrap (page 169).
- **Weapons by damage type**: Hulks and Sentinels are weak to Crush; rats are weak to Stab and resist Crush; runts are weak to Fire; the PL 2 Overlord has no weakness. Crush weapons on the wiki: Stone Club (PL 1, 14-24 dmg; 8 Stone + 6 Ash Logs), Bone Club (PL 2, 26-46; 8 Animal Bone + 6 Ash Logs + 4 Leather), Bronze Mace (PL 3, 38-68; 8 Bronze Bar + 6 Oak Logs + 2 Leather at a Blacksmith's Bench) (pages 392, 757, 1354). The Bronze Sword is PL 3, Slash, 31-56 dmg, special Barge (page 1261).
- **Spells and tactics the page names**: Tempest Shield and Enchant Weapon: Fire before the large room; ranged or a shield with counters against the Sentinels; buffs before the boss and stamina kept for blocks and dodges (page 3515). Note: Enchant Weapon: Fire is advised although the guardians are immune to Burning (page 1329); that is the wiki's own text. Tempest Shield costs 15 Air Runes (DISCOVERIES l. 2276).
- **Food**: food has a power level too (page 181): PL 1 Fillet, Rat Roast, Fried Egg; PL 2 Steak, Haunch, Fried Cabbage, Baked Potato, Grilled Mushrooms. Fillet heals 20 HP and 20 sustenance; Steak and Haunch heal 30 HP and 20 sustenance (pages 1194, 1246, 1231).
- **Weight**: each vault core is 50 kg (page 3515).

**Where he stands today** (his last get_state in `logs/brain-live-20261117-182835-26604.jsonl` l. 92, 2026-11-17 17:29:47Z): power level 0 (no armour worn; a Community Cape), HP 100/100, Bronze Sword and Bronze Shield held, 6 Fillets, 5 Clean Water, 4 Animal Bone, 1 hide scrap; runes Fire 465, Earth 1,615, Water 660, Nature 2,040, Law 1,584, Astral 1,809 and **no Air Runes**; Attack 27, Agility 39, Artisan 18, Magic 3, Ranged 4. Unlocked perks include TempestShield and EnchantWeapon_Fire (DISCOVERIES l. 3219). So against this vault he is PL 0 against PL 2: "more than one level below".

## 4. The probe window: P2 to P5 on the dev world

### What exists and what is missing

- Exists: the vault fields on `look` and `get_state` (6d78811: teleporter rows `destination`, `arrives_at`, `leads_to`, `locked`; lever rows `switch_position`, `switch_highest`, `drives`; chest rows `chest_state`; the `hazards` category; `in_vault` and `vault`); the teleport hooks, off until `_G.__dwc_bridge.hook_teleport({ force = true })` is run from a command (`client_bridge.lua` l. 2084-2131; `bridge_status.lua` shows the `__dwc_bridge` global); the `teleport` fixture (server `K2_TeleportTo`, nudged up to 2.5 m when blocked, refused while another player is on: `mod/bench/fixtures.lua` l. 25-37, 403-433; Python `evals.bench.devtarget.DevTarget.setup("teleport", purpose=..., at=[x, y, z])`, l. 377); the settle wait of `tools/travel_ladder.py` `place` (l. 241-284); `tools.bridge_cmd` for `look`, `get_state`, `go_to`, `interact`; the clone window with its "never release the lock off ClaudeDev" rule (`tools/quest_run.py` `clone_window`, l. 579-609); `world_snapshot` with the `base` snapshot (2026-11-17 17:12Z; it holds the door's cell `X2_Y14`, 128 m cells).
- Missing (harness only, to be written by the main session; neither is the companion's): **(a)** a read command `client_mod/commands/vault_probe_p1.lua` for the always-loaded reads below; **(b)** a small window script (the `quest_run step` pattern: lock, clone switch, fixtures, bridge calls, back to ClaudeDev). There is no CLI that switches to a clone and holds it for arbitrary calls.

### Window A: outside only (P1b and P2). ClaudeDev may be used: nothing in it enters the vault

Brain stopped (DevTarget refuses with a running brain), no other player on the dev world, code committed (rule 7), API spend 0.

1. Announce in text. `tools\stop_server.ps1 -Hold`, then **`.venv\Scripts\python.exe -m tools.world_snapshot restore base --confirm`**, `tools\start_server.ps1`, `tools\client_boot.ps1 -Target dev` (rule 9).
2. **P1b at home, standing still** (always-loaded actors, readable from anywhere; reads note l. 145-149): for the two teleporters of family `18C04D97CB3D30D401`: position, `TeleportDestinationName`, `GraveyardRef`'s position, `Interaction.InteractionPrompt`; for the two `TeleportationTarget`s of that family: `TargetName`, position; the 32 `Dungeons` entries: `UserVisibleName`, `Box`, `EntranceLocation`, `ExitLocation`, `bNeedsToBeDiscovered`, and which entry fails to read (complete=false); which box holds each target; the positions of the six `A036BC08BFCE9ECF02_7c311a62294e3e8c` actors and whether they lie in Crasorak's box; `bInDungeon` (expect false). Expect: one target near (374, 1918), the other inside a box named Crasorak Kara; the inside teleporter's destination names the outside target. **Stop** on any Lua error, any `ue4ss_prop_guard stale`, a read over 200 ms.
3. **Arm the hooks at home** (`hook_teleport({ force = true })` from a command) and stand 60 s. **Stop** on a crash, a `client_teleport_hook_error` event or a hookhub error in the log. This is the first time those hooks run on this client.
4. **P2**: teleport fixture to **(363.3, 1901.6, -2.0)**, a spot he stood on (2026-11-01 13:12Z, 20.5 m south-west of the door; `logs/brain-20261101.jsonl` l. 8973), half a metre above his recorded z. Wait until still (`place`). Note whether `teleport_begin` fired for the fixture teleport (it should not: the fixture is a bare `K2_TeleportTo`, not `TeleportToNamedLocation`; if it does, the pause ends after `TELEPORT_MAX_PAUSE_S` = 60 s). Then `get_state` and `look {"radius": 30}`. Record the door row: `name` "Crasorak Kara", `prompt` "Enter", and the new `destination`, `arrives_at`, `leads_to`, `locked`; expect UE4SS lines `vault_targets n=<about 222>` and `vault_read in_vault=false ... teleporters=1`. **Stop and teleport back** (to the standing-trees spot (100, 1892, -31)) on: a fall (z drops more than 3 m within 5 s: a teleport into cells not yet streamed, DISCOVERIES l. 595); a hostile within 20 m (rat packs of PL 1 and PL 2 stand within 35 m of the door, and one killed him there); HP under 60 %; a fight reflex starting. A trial that met a fight is void, not failed (rule 3).
5. Teleport back to the standing-trees spot; `world_snapshot restore base` before the next window if anything outside changed (a kill, a grave).

### Window B: through the door and out (P3 to P5), on a clone

Only after window A holds.

1. Same world start as A.1. Inside `clone_window`: a fork, never ClaudeDev (`.venv\Scripts\python.exe -m tools.quest_clone fork --from <checkpoint> --name ClaudeV<ddhhmm>`; rule 8 does not apply because this is a harness look, never a scored trial). Vitals full by `set_stat`. Fixture grants allowed for a look (capstone note l. 121): food and a PL 2 set, because a Hulk patrols the entry hallway (page 3515). Optional and approved: ProcDump on the client process for the entry, so a native crash leaves a full dump.
2. Arm the hooks (A.3). Teleport to (363.3, 1901.6, -2.0); `go_to` the door's id with a 1.5 m circle; `look` to confirm the row in reach.
3. **P3**: one `interact {"target": "BP_InteractablePlayerTeleporter_C_UAID_18C04D97CB3D30D401_1397338720"}`, never a second press. Expect, in order: `bridge: teleport_begin`, `client_paused by=teleport`, the interact ending `companion_down` "client paused: I'm being teleported", a position jump to the inside target from P1b, `teleport_end`, `client_unpaused` about 5 s after it (`TELEPORT_SETTLE_S`), then `get_state` with `in_vault=true` and `vault="Crasorak Kara"`. **Stop**: a new `crash_*.dmp` (no second entry until the cdb stack is read); a pause not lifted within 90 s; no position jump of more than 50 m within 15 s of the press; a `locked` row or a refusal message.
4. **P4 at the arrival point, standing still**: `look` at 20 m, then 80 m. Record the switches (`switch_position`, `switch_highest`, `drives`), doors, `hazards`, chests (`chest_state`), creatures with `power_level`, health and `boss`, and the inside teleporter row (`leads_to` should read "outside"). Save the replies as JSON. **Stop and go to P5 at once** if a Vault Guardian is within 25 m in combat alertness, on any damage row, or on a stale read. If he dies inside: read where the registry puts the grave (the wiki says at the outside entrance) and end the window.
5. **P5**: one `interact` on the inside teleporter (the P4 row whose `leads_to` is "outside"); the same expectations in reverse; afterwards `in_vault=false`, his position at the outside target, the `prop_guard` counters compared with P3's.
6. The window ends back on ClaudeDev (`clone_window`), then `world_snapshot restore base`.

**What the two windows answer**: A1 of the capstone note in part (from P4: guardians alive, chests unopened), A3 (where the door leads, and whether the client survives the fade with the loops paused), A4 (lever and chest states on the client), A5 in part (`boss` on any creature in range); and which graveyard the door names. The time cost is about 10 minutes for A and 15 for B, with no API spend.

## Limits

- The door's position is a live read from 2026-11-01/02 under the world label `dev_farm`. It is an always-loaded `L_World` actor at a fixed UAID, so it is the same on the current dev world, but no read of it was made on the `base` world.
- The creature table is what his body happened to see, mostly while doing other work. It shows who roams there, not a census. Creatures respawn and wander; the PL 2 rats probably come from Bramblemead Valley, 60 m away.
- The inside facts are the community wiki's (mirror of 2026-10-25). The Hulk and Sentinel PL 2 HP are "TBA" there. The Goblin Runt page has no PL 2 version although the vault page says PL 2.
- That the `A036BC08BFCE9ECF02_7c311a62294e3e8c` levers and door are Crasorak's, and that `..._1545295722` is the way out, are inferences from names and counts. P1b settles both.
- The built lodestones were last seen at 15:19Z today; whether they stand in `base` (kept 17:12Z) was not checked.

## Sources

- Live reads: `logs/brain-20261101.jsonl` l. 8973; `logs/brain-20261102.jsonl` l. 23602, 23618, 26925; `logs/brain-live-20261102-062524-17740.jsonl` l. 7-106 (death, grave walk, door row); `logs/brain-live-20261102-091736-5076.jsonl` l. 81, 87; `logs/brain-live-20261117-151932-23576.jsonl` (built lodestones); `logs/brain-live-20261117-182835-26604.jsonl` l. 92 (his state); `logs/state/worlds/dev_farm/map_memory.json`; UE4SS.log l. 1928-1931.
- Dump: `dumps/26574459/UE4SS_ObjectDump.txt` l. 274787, 274791, 274795, 274938, 275013-275040, 275914, 276764-276796, 276995, 282616-282619.
- Repo: `docs/DISCOVERIES.md` l. 575-602, 615-619, 1036, 2276, 2281, 2288, 3140, 3219; `client_mod/scripts/sense.lua` l. 730-935; `client_mod/scripts/client_bridge.lua` l. 2084-2175, 2236-2247; `mod/bench/fixtures.lua` l. 25-37, 403-433; `evals/bench/devtarget.py` l. 377-420; `tools/travel_ladder.py` l. 241-284; `tools/quest_run.py` l. 563-609; `tools/world_snapshot.py` l. 1-33; `logs/world_snapshots/base/manifest.json`; `data/places_26161880.json`; `brain/places.py`; `evals/bench/dev_places.json`; `data/bestiary.json` l. 3246, 3691, 9800, 9946, 10190, 11628-11731.
- Wiki mirror (`data/wiki/pages`, CC BY-NC-SA 3.0, fetched 2026-10-25), by page id and revision: Crasorak Kara 3515 r69708; Dragonkin Vault 1315 r74247; Vault Overlord 1331 r66508; Vault Guardian Hulk 1329 r66503; Vault Guardian Sentinel 1330 r66504; Vault Guardians 3359 r66505; Giant Rat 169 r69535; Goblin Runt 1323 r71111; Chest (Crasorak Kara) 5462 r76539; Power level 181 r76399; Lodestone 405 r73804; Leather 282 r63418; Leather Cowl 837, Leather Body 838 r63419, Leather Chaps 839; Reinforced Helmet 758 r65119, Reinforced Body 988 r65118, Reinforced Legs 997 r65121; Apprentice Robe 835 r66785; Stone Club 392, Bone Club 757, Bronze Mace 1354, Bronze Sword 1261 r75440; Fillet 1194, Haunch 1231, Steak 1246; Temple of Saradomin 3966. Live: https://dragonwilds.runescape.wiki/w/Crasorak_Kara
