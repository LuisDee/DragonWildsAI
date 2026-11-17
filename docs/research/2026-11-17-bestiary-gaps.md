# Bestiary gaps: what the game dump, the repo and the web hold for attacks, weaknesses and vault chests (2026-11-17)

Follow-up to `docs/research/2026-11-17-bestiary.md`. Before this note, the wiki mirror lacked attacks for 93 of 129 creatures, weaknesses for 21 and every vault chest's items. Question: can any of these be read from the game dump, from data already in the repo, or from a community export? Offline only. No live window, no model calls, no Lua edits.

## Answer in one table

| Gap | Game dump (26574459, 26161880) | Repo data with values | Community | Merged now |
|---|---|---|---|---|
| Creature attacks (names, damage, style) | Names and schemas only | Combat memory: 12 attacks of 5 creatures, as he met them | None found | Yes, as `observed_attacks` (src `own fights`) |
| Weak / resist / immune | Names and schemas only | None (affinities are empty on the client, `DISCOVERIES.md` line 3146) | metabot.gg datamined bestiary (159 cards) | Yes, but only into fields the wiki left empty (src `metabot.gg`) |
| Vault chest items | Names and schemas only; the roll tables were not even loaded | None | None: metabot gives chest counts per vault, not contents | No: nothing exists to merge |

## The game dump: names and schemas, no row data

`UE4SS_ObjectDump.txt` lists each live object as address, class and path. It holds no property values. `CXXHeaderDump/` gives the struct layouts. `index.json.gz` is an index of names and classes (23,918 assets, 1,135 BP classes). The older dump `26161880` is the same kind of file (315 DataTables, the same AI and loot table names).

DataTables that were loaded in the client at dump time (305 in all), with their row structs:

| Table | Row struct (Dominion.hpp) | What a row would give |
|---|---|---|
| `DT_AIAttackDamage_BG`, `_Fellhollow`, `_DowdunReach` | `FAiAttackDamageDataTableRow { float Damage }` (line 642) | Base damage per attack row |
| `DT_AIData_BG`, `DT_AIData_UmbralSands` | `FAIDataTableRow { float MaxHealth }` (line 82) | Health (the wiki already has it) |
| `DT_ATK_DragonVelgar`, `DT_ATK_DragonFuzan`, `DT_DAA_*` | Attack lists of the two dragons | Dragon attack sets |
| `DT_EnemyLootDropTable` (+ `_DowdunReach`, `DT_CompositeEnemyLootDropTable`) | `FLootDropEnemyTableRow { TArray<FLootDropPowerLevelTableList{MinimumPowerLevel, TableHandles}> }` (line 4598) | Each creature's drop tables per power level |
| `DT_LootDropTable` (+ `_DowdunReach`) | `FLootDropTableRow { Conditions, DropChance, TArray<FSpawnableResource> Resources, Recipes }` (line 4611); `FSpawnableResource { UItemData*, Min/MaximumDropAmount, DropChance, ... }` (line 7212) | Drop items, amounts and chances |
| `DT_AISpawnData_*` (3 regions) | `FAISpawnDataTableRow` (line 179) | Spawn groups and rarity |

Per-attack data is not in a table. Each attack is a Blueprint class `ATK_<Stem>_<Name>_C : UAiAttackData` (line 14753). Its fields: `Damage[]` of `FAiAttackDamageData { Time, Shape, FDataTableRowHandle DamageDataTableRowHandle, FGameplayTagContainer Types, Directionality, Force, EDamageClass DamageClass }` (line 630), `AttackPropertyFlags` (Unblockable 1, Unparryable 2, ...), `AiAttackType` (a gameplay tag) and `GameplayEffects` (poison and the like). Only the 15 `ATK_DragonVelgar_*` classes were loaded at dump time. A creature's ATK classes load with its AI class, that is, when one spawns near the client.

- **Affinities:** `UAIAttributesComponent.DamageTypeAffinities: TMap<GameplayTag, EDamageTypeAffinity{Weakness, Resistance, Immunity}>` (line 13679). It is empty on the client (`DISCOVERIES.md` lines 1213 and 3146).
- **The game's journal:** `UJournalEntryWorldData { TArray<FText> Weaknesses, Locations, Materials, int32 PowerLevel }` (line 25881). **232 journal world entries were loaded in the client at dump time**, among them goblins and Kalphites. It is the one client-side place where weakness text is held for every creature. `combat.lua` `_journal_weaknesses` already reads it live, one creature at a time.
- **Vault chests:** `AWorldChest.ChestRespawnProfile` (`FDataTableRowHandle` at 0x300, line 12815) leads to `FChestRespawnSettings.LootRollHandle` (line 1907). That leads to `FLootItemSetRoll { GuaranteedItemSets, GuaranteedStandaloneItems, Min/MaxAdditionalSetRolls, AdditionalItemSets{handle, DropChance} }` (line 4626), then to `FLootItemSet.SpawnableItems` (line 4620). **None of the respawn, roll or item-set tables was loaded at dump time.** The Dungeon plugin's `FDungeonChestConfig/ItemsInChest` (Dungeon.hpp line 53) belongs to `FBossRoomConfig` and `FTreasureRoomConfig` of the procedural dungeon generator. It is not known whether the vaults use that generator.

Repo tools that read DataTables live:

| Tool | What it reads |
|---|---|
| `tools/build_recipes.py` stage 3 | Recipes, live |
| `client_mod/commands/food_values_probe.lua` + `tools/gen_food_values.py` | `StaticFindObject` + `FindRow`, verified (`DISCOVERIES.md` line 2450) |
| `client_mod/scripts/build.lua` | `FindRow` |
| `client_mod/scripts/combat.lua` `read_attack` | `UAiAttackData` at the telegraph: flags, damage time, shape. Not the damage row handle and not `Types` |

`DISCOVERIES.md` line 688 confirms that UE4SS `ForEachRow` / `FindRow` work on this build, read-only.

## Repo data with values: his combat memory

`data/skills/<world>/combat_knowledge.json` and `combat_memory_<character>.json` are gitignored and written by `client_mod/scripts/defense.lua`. Under `defense.attacks` they hold `"<Creature>:ATK_<Stem>_<Attack>"` records with `n`, hits, `impact_s` (an EMA of telegraph to impact), `lunge_cm` (EMA) and `damage` (an EMA of what he took, biased high). These are the game's own attack asset names plus measurements on his body. The damage depends on the armour he wore then. It is not the attack's base damage.

Found (106 files, all worlds): Giant Rat 3 attacks, Goblin Runt 3, Goblin Warrior 4 (from the build-26162923 file), Cow 1, Kebbit 1. Goblin Archer has only dodge and `class23` keys, so it is left out.

## Community exports (web search, 2026-11-17)

- **No FModel, CUE4Parse or other raw data-table export of Dragonwilds was found** (searches: "Dragonwilds datamine data tables FModel export", "Dragonwilds github datamined json creatures weaknesses drop tables"). `DISCOVERIES.md` line 2481 found the same for food tables.
- [metabot.gg Dragonwilds bestiary](https://metabot.gg/en/dragonwilds/bestiary): "extracted directly from the latest RuneScape: Dragonwilds game files" ([metabot.gg/en/dragonwilds](https://metabot.gg/en/dragonwilds)). 159 cards, each with a faction, a Weak/Resists/Immune line and, on some, journal lines ("Weakness: Stab / Resistance: Crush / Immune: Poison"). It has no attacks, damage or drops. Terms ([llms.txt](https://metabot.gg/llms.txt), [/en/ai](https://metabot.gg/en/ai)): free to use with a credit link to the page the data came from.
  - **Quality:** where both are positive, it agrees with the wiki. Its "No notable affinities" is unreliable: on 11 cards its own journal line names a weakness (Goblin Runt, Goblin Archer, Dire Wolf, Garou Berserker, Garou Druid, Garou Hunter, Garou Thane, Plague King, Rat King, Vault Archon, Vault Overlord). Some names are internal ("Melee Goblin", "Ranged Beast", 20 unnamed "BOSS" cards). Kalphite resist lists name spells ("Axtral Projection", "Rocksplosion"), so these appear to be raw affinity tags.
- [metabot.gg vault pages](https://metabot.gg/en/dragonwilds/map/vaults/skeklac): chest counts and positions ("5 loot chests"), not contents.
- [Nexus mod 46](https://www.nexusmods.com/runescapedragonwilds/mods/46) (loot multiplier): enemy and chest loot use roll tables with iterations and quantities. It describes the mechanism, not the data.
- Earlier, `docs/research/2026-10-25-spells-and-weaknesses.md` already cited gamever.io and metaforge.app weakness lists (MEDIUM confidence, sources disagree).

## What was merged (`tools/build_bestiary.py`)

- **`observed_attacks`** (src tag `own fights`): per creature, the attacks from the combat memory files. A record is kept per attack: the one seen most often, because forked characters copy memories and summing them would count the same fights twice. Fields: name, asset, seen, hits_on_him, impact_s, lunge_m, damage_to_him, build. The text reads "Attacks seen in his own fights (the game's attack names; damage is what he took through his armour): Attack 01 (seen 137, impact 1.07 s after the wind-up, lunge 2.4 m, about 13 damage to him per hit); ...".
- **metabot.gg** (src tag `metabot.gg`, snapshot `data/bestiary_external.json`, refreshed with `python -m tools.build_bestiary fetch-metabot`): fills `weak`, `resist` or `immune` only when the wiki and the Boss table left the field empty. Its journal line comes first, then its affinity line. "No notable affinities" is never used.
- The Sources line now names the outside sources and their fields, for example "Sources: wiki pages 1328, 2128, 3516; metabot.gg datamined bestiary (weak to, resistant to, immune to)". `counts` adds `immune`, `*_wiki` (the wiki alone) and `observed_attacks`.

Coverage, creatures missing a field (of 129):

| | Weak to | Resistant to | Immune | Attacks (any) | Attacks from the wiki | Vault chest items |
|---|---|---|---|---|---|---|
| Before | 21 | 14 | 80 | 93 | 93 | 10 of 10 vaults |
| After | **19** | **11** | **79** | **88** | 93 | 10 of 10 vaults |

Filled: Goat (weak Slash, resist Fire), Vault Archon (weak Crush, resist None, immune Poison, Bleed, Burning, from the journal line), Black Dragon (resist Fire). Observed attacks: Giant Rat, Goblin Runt, Goblin Warrior, Cow, Kebbit (none of the five had a wiki attack). The longest text is 1,446 characters (Giant Rat), under the 1,500 limit. Lookup eval (tuned half): still 15/15, entry-only still 14/15. The held-out half was not run.

Limits: `observed_attacks` depends on the gitignored combat memory files. A build on a machine without them drops the field. The damage is what he took, not the base damage. The metabot fills are a third-party reading of the game files, labelled as such, and never override the wiki.

## Read-only probe plan for the live client (not written; no Lua edits in this task)

Pattern: a command file like `client_mod/commands/food_values_probe.lua`. It is copied to `client_io/cmd/` and queued with `client_lib.ps1 Invoke-ClientCmd`, its JSON lands in `client_io/out/`, and a merge stage in `build_bestiary.py` reads that JSON. Allowed calls: property reads, `StaticFindObject`, `FindAllOf`, `DataTable:ForEachRow` and `FindRow` only. No RPC, no hand-built struct, no `LoadAsset`. Run it between windows (the rule-7 lock) on `ClaudeDev` at home.

1. **Journal (all weaknesses, one call; lowest risk).** `FindAllOf("JournalEntryWorldData")` and, per entry: `DisplayName:ToString()`, every `Weaknesses[i]:ToString()`, `PowerLevel`, `Locations[]`, `Materials[]`, the asset path. These are the same reads `combat.lua _journal_weaknesses` already makes live. Expected: about 230 entries, which covers the 19 remaining weakness gaps and gives a game-sourced check of the wiki and metabot values. Check: count the entries with a non-empty `Weaknesses`.
2. **Attack damage rows.** `StaticFindObject` on each `DT_AIAttackDamage_{BG,Fellhollow,DowdunReach}`, then `ForEachRow(name, row)` gives `name -> row.Damage`. The row names should carry the creature stem (to confirm on the first read).
3. **Attack definitions (names, style, flags).** Per loaded `ATK_*_C` class, read its CDO (`/Path/ATK_X.Default__ATK_X_C`, the same object `read_attack` reads at the telegraph). From `Damage[i]` read `DamageDataTableRowHandle.DataTable`/`RowName` (this joins to step 2), the `Types` tags (`DamageType.Physical.Slash` and so on, which give the style), `DamageClass`, `Force`, and also `AttackPropertyFlags`, `AiAttackType` and the class names in `GameplayEffects`. Limit: only loaded classes are visible, which means creatures that have spawned near him. So run it at home (rats, goblins, kebbits), then in each region or vault he visits, and merge the union. A cheaper first step is to log `RowName` and `Types` in `read_attack`, which every fight then fills in.
4. **Creature drop tables.** `ForEachRow` on `DT_EnemyLootDropTable` (+ `_DowdunReach`, Composite) gives the row name and `TablesByPowerLevel[] {MinimumPowerLevel, TableHandles[] (DataTable path, RowName)}`. Then `FindRow` through each handle's own table gives `DropChance`, `Conditions[]`, and `Resources[] {SpawnedItemData path, Min/MaximumDropAmount, DropChance}`. This gives the drops per power level, which the wiki has for one level only. All three tables were loaded at dump time.
5. **Vault chests.** These need a loaded `WorldChest` actor (in or near a vault). Read its `ChestRespawnProfile` handle and `FindRow` it to `FChestRespawnSettings`. Then follow `LootRollHandle` with `FindRow` to `FLootItemSetRoll`, and each item-set handle with `FindRow` to `FLootItemSet.SpawnableItems`. Risk: if the roll tables are server-only, they are not loaded on the client. Then the same read has to run on the dev server's UE4SS (installed, `SERVER-SETUP.md`), where the chest actors and tables live, which makes it a dev-server command and not a client command. Check first with one `StaticFindObject` of the chest's handle `DataTable` on the client.
6. **Affinities (authoritative map).** The client copy is empty. The only route is the dev server: on spawned AI, read `AIAttributesComponent.DamageTypeAffinities` (TMap `ForEach`). Do this only if step 1's journal text is ambiguous.

Crash notes: `ForEachRow`, `FindRow` and `FText:ToString` are verified on this build. TMap iteration on the server is not yet verified, so try it offline first (CLAUDE.md section 4). Nothing here touches Luis's character or sends anything to the server.

## Files

- `tools/build_bestiary.py`: `observed_attacks`, `parse_metabot`, `fetch_metabot`, `apply_external`, the Sources line, counts, and the `fetch-metabot` subcommand.
- `data/bestiary_external.json`: metabot.gg snapshot (140 named cards; 28 with journal lines, 50 with an affinity line). Credit: [metabot.gg/en/dragonwilds/bestiary](https://metabot.gg/en/dragonwilds/bestiary).
- `data/bestiary.json`: rebuilt.
- `tests/test_build_bestiary.py`: 4 new tests (18 pass). The fixture stubs the combat memory and the snapshot.
