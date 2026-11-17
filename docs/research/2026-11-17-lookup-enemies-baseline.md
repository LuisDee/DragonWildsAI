# Lookup for enemies and vaults: the baseline (2026-11-17)

Step 1 of `docs/GOAL-2026-11-17-long-jobs.md` section 3. What the `lookup` tool answers today about enemies and vaults, before any change. Offline: the eval calls `Knowledge.lookup` directly. No model, no game. Index build 26574459, `data/wiki/knowledge.sqlite` (1250 game docs, 10009 wiki docs).

## The scores

| Half | Hits | In mirror only | Mean size | Max size | Mean time |
|---|---|---|---|---|---|
| Tuned (`evals/lookup_enemies_cases.jsonl`) | **10/15** | 10/14 | 1901 chars | 3170 chars | 184 ms |
| Held-out (`evals/lookup_enemies_heldout.jsonl`) | **13/15** | | | | |
| All 30 (both untuned today) | 23/30 | | | | |

Tuned, by kind: level 3/3, attacks 1/3, weakness 2/2, location 2/2, vault 1/3, drops 1/2.

The held-out half is reported as one number only. Its per-case results are not read and not used to choose a fix. Size is the JSON the model reads. Time includes a cold first query (up to 750 ms); warm queries take 20 to 450 ms.

Run: `.venv\Scripts\python.exe evals\lookup_enemies_eval.py` (add `--json <file>` for the tuned cases as JSON). Tests: `tests/test_lookup_enemies_eval.py`, 12 tests.

## How the cases were made

- 30 questions a player asks before a fight or a vault, as short queries the model would pass. Spread: level 6, attacks or mechanics 5, weak to 5, where it lives 4, vault enemies and boss 5, drops 5.
- Each case has answer groups. A hit needs every group to have one alternative in the returned text (titles, sections, texts, walkthrough). Matching ignores case and punctuation and needs word boundaries.
- Every answer was read from the wiki mirror (`data/wiki/pages/*.json`), cited per case in `source`. One case is marked `"answer_in_mirror": false`: the Vertentis Kara chest contents (see the gap below).
- Split 15/15 with `random.Random(20261117)`, shuffled within each kind. Odd kinds alternate which half gets the extra case. The generator stayed outside the repo so the held-out cases are only in their own file.

## How `lookup` works (read end to end)

| Step | What it does | Where |
|---|---|---|
| Tool | `lookup(query <= 120 chars, kind?)`, answered by the brain, never the body. The result goes to the model untrimmed. | `brain/interface.py:182`, `:354`; `brain/controller.py:493`, `:990`, `:1025` |
| Index | SQLite FTS5, porter stemming. Tier 0: game docs from `data/items_*`, `recipes_*`, `spells_*`, `farming_*` (items, recipes, stations, spells, perks). Tier 1: one doc per wiki page section. No creature or vault docs of its own. | `brain/knowledge.py:190`, `:488`, `:657` |
| Search | Query words OR-ed, BM25 weights title 12, aliases 8, tags 2, body 1, 200 candidates per tier. | `brain/knowledge.py:691` |
| Rank | Title coverage of the query first, a page's lead before its other sections, then a section whose heading the query names, then the most `key=value` facts, then BM25. | `brain/knowledge.py:707`, `:720` |
| Cut | 3 game docs (only those whose title is half covered by the query), 2 wiki snippets, at most 2 sections per page. Game cards clipped to 900 chars by whole fields, wiki snippets to 520 chars. | `brain/knowledge.py:39`, `:43`, `:771`, `:776`, `:784` |
| Wiki text | The mirror converts wikitext: infoboxes to `key: value`, templates to `Name: k=v`, tables to one row per line, cells split by a pipe; short stand-alone templates are dropped; sections chunked at 1800 chars. | `tools/wiki_mirror.py:10`, `:56` |

## The tuned misses

| Case | Query | What came back (first 300 chars, shortened) | Likely cause |
|---|---|---|---|
| atk-zogre | `zogre attacks` | `Attack Cape` (game data: "Congratulations! Reaching level 99 in Attack..."), then `Zogre` lead (Multi Infobox), then the `Attack` skill page | **Ranking.** The query word "attacks" is the title of the skill page `Attack` and half the title of the item `Attack Cape`. Both score as "the thing named", so they take one game slot and the second wiki slot. The Zogre "Attacks" section, which has all three answers, is ranked after them. |
| atk-velgar | `Velgar attacks` | `Attack Cape`, `Velgar` lead (Multi Infobox), `Attack` skill page | **Ranking**, as above. The attack list is on another page, `Velgar/Strategies` ("His main attacks are Claw Slam, Claw Strike, Bite, Head Swing, and Dragon Breath"), in a long section that would also be cut at 520 chars. |
| vault-skeklac | `Skeklac Kara` | `Skeklac Kara` lead ("name: Skeklac Kara, location: Fractured Plains ... unlocked by interacting with 4 dragonkin statues"), then `Skeklac Kara` / `Location`: `Map: width=250px; height=250px; center=75700,137500; zoom=3` | **Ranking, the fact count.** With two sections per page, the second one is chosen by the number of `key=value` facts. The map template's parameters count as 4 facts; the Enemies table (rows such as "Putrid rat, 8") counts as 0. So a map wins over the enemy list on every vault page. |
| vault-crasorak-boss | `Crasorak Kara boss` | `Crasorak Kara` lead, then `Crasorak Kara` / `Location` (the map template) | **Ranking**, the same map rule. "boss" names no heading. The answer is in the page's Enemies table, on the `Vault Overlord` lead ("the boss of the Crasorak Kara vaults") and in the `Boss` page's "Vault bosses" table; none of them outranks the named page's map. |
| drop-vertentis-chest | `Vertentis Kara chest loot` | `Personal Chest` (perk), `Personal Chest` (spell), `Obsidian Chest` (armour), then `Chest (Vertentis Kara)`: "Several chests are found ... rune essence, runes, blueprints, and other types of materials" and "An additional 2-3 drops will be rolled." | **Not in the mirror's text.** The chest page's drop tables are templates only (`{{RunesDropTable}}`, `{{SkillTomesV1DropTable}}`, `{{WeakPotionsDropTable}}`, `{{VaultMaterialsDropTable}}`...). The converter drops them with their sections; the template pages are not mirrored (0 `Template:` titles in `manifest.json`). Only the raw `wikitext` field names them. Also: any game item with "Chest" in its name fills the 3 game slots. |

Weaknesses that the hits hide:
- A drops question hits only because the second slot of the page happens to be the drops section. The converter keeps the subsection heading (`100%`, `Other`), not the parent `Drops`, on 143 of the 167 monster sections that hold `DropsLine` rows. And `DropsLine` is one token, so the word "drops" in a query matches nothing in them.
- A reverse drops question ("what drops hard leather") has no page to land on. The item pages carry no drop sources; only monster pages list the item in `DropsLine` rows.

A fact the goal doc should check: it names Velgar as the boss of Vertentis Kara. In the mirror, Velgar is the Dragon Slayer world boss at Velgar's Rise (Fractured Plains, power level 4, 6,000 HP). Vertentis Kara (power level 2, Whispering Swamp) is the vault where Spitfoot is met in Dragon Slayer; its boss is the Rat King, and the Plague King is listed there too (`Vertentis Kara`, `Boss` "Vault bosses", `Dragonkin Vault` "Other monsters").

## What the game data holds that the wiki mirror lacks

| Source | What it holds | Used by lookup? |
|---|---|---|
| `data/items_26574459.json` `attacks`, `attack_sets` | The player's attacks only (damage, stamina, timing). No creature attacks. | yes, as item cards |
| `data/places_26161880.json` | Regions, 514 landmarks with positions. No vault is among them (no "Kara" name). | no |
| `client_mod/scripts/creature_wiki.lua` (from `tools/gen_creature_wiki.py`) | 107 creatures: power levels, health, race, weak, resist, immune, inflicts, as structured fields. Derived from the mirror; no locations, attacks or drops. Read only by `combat_brief` with the creature in sight. | no |
| `dumps/26574459/UE4SS_ObjectDump.txt` | Names only, no rows: `DT_EnemyLootDropTable`, `DT_CompositeEnemyLootDropTable`, `DT_LootDropTable` (+ `_DowdunReach`), row struct `LootDropTableRow {Conditions, DropChance, Resources, Recipes}`; `DT_AIData_BG`, `DT_AIData_UmbralSands`; per-attack damage `DT_AIAttackDamage_BG`, `_DowdunReach`, `_Fellhollow`; Velgar's attack and action tables `DT_ATK_DragonVelgar`, `DT_DAA_DragonVelgar` (also Fuzan); three `DT_AISpawnData_*` spawn tables; `AISpawnVolume.SpawnTable`. | no |
| `docs/DISCOVERIES.md:1002`, `:3146` | Live on the client: `UAIDataAsset` (AIName, Archetype, bIsBoss, PowerLevel); the AI data row holds only MaxHealth. Weaknesses (`AIAttributesComponent.DamageTypeAffinities`) are server-only. | no |
| `docs/research/2026-10-25-humanoid-companion-dump.md:360` | Loot path: `ULootDropComponent.EnemyTableRowHandle` to `FLootDropEnemyTableRow.TablesByPowerLevel` to `FLootDropTableRow`. | no |

So the repo holds no creature stats, loot rows or vault spawn lists from the game itself. The tables exist and are named; reading their rows needs a live, read-only stage like the one `tools/build_recipes.py` already runs for `DT_CraftingStationsDataTable` and `DT_Progression_*` (stage 3, `recipe_dump.lua` on the dev server).

The best source not used today is the wiki mirror's own structure: monster infoboxes, `DropsLine` rows, Attacks sections, and the vault pages' Enemies tables with the `Boss` and `Dragonkin Vault` tables. It is all on disk and none of it reaches the model as one entry per enemy or vault.

## Three candidate fixes, ranked

Each changes what the tool can read or return. None tells him what to do with it.

1. **A structured entry per enemy and per vault, built at index time from the mirror.** One card per creature: power levels, health, weak, resist, immune, locations, attack names (from Attacks, Combat mechanics, Moveset, Strategy sections), drops (from `DropsLine`), and the vaults it appears in. One card per vault: area, power level, enemies with counts, boss (from `Boss` "Vault bosses" and `Dragonkin Vault` "Other monsters"), recipes, nodes. Add a "Dropped by" line to item docs from the reverse of `DropsLine`. Reuse the infobox parsing of `tools/gen_creature_wiki.py`. The card's title is the creature or vault name and its fields are labelled, so "attacks", "drops" and "boss" land on it. Expected to move atk-zogre, vault-skeklac, vault-crasorak-boss and reverse drop questions; atk-velgar needs the Strategy section's attack sentence. The `lookup` tool stays as it is (goal step 2).
2. **Ranking fixes in the index.** (a) When the query names a page title plus another word ("zogre attacks"), rank that page's sections above pages that match only the other word (`Attack`, `Attack Cape`); today both count as "the thing named" (`brain/knowledge.py:707`). (b) Stop counting map template parameters as facts, and count table rows (`brain/knowledge.py:544`). (c) Keep the parent heading on subsections ("Drops / 100%") in the converter. Cheaper than fix 1 and helps every wiki page, but it does not answer reverse drops or join a vault to its boss.
3. **Game tables, read live and read-only, as authoritative docs.** A stage after `tools/build_recipes.py`'s pattern for `DT_EnemyLootDropTable` (+ composite, Dowdun Reach), `DT_AIAttackDamage_*`, `DT_AIData_*`, the spawn tables, and server-side `DamageTypeAffinities`, written to `data/creatures_<build>.json` and indexed in tier 0. Authoritative and patch-proof, but it needs a live window on the dev server (crash-risk review first), and rows hold asset ids that must be joined to names. For the chest gap only: mirror the drop-table template pages (`tools/wiki_mirror.py --titles "Template:RunesDropTable|..."`) and expand them during conversion.

Order: fix 1 first (offline, no body, all from the mirror), with fix 2 (b) alongside it because the map rule hurts every vault and many monster pages. Fix 3 later, when a dev-server window is free.
