# M3 skill-route gaps (2026-10-26, build 26161880 / client 26162923)

Scope: GOAL.md M3. For each of the 12 frozen skills (`docs/goal_targets.json` `every_skill.skills_frozen`), this note covers five things:
- the body's XP route;
- whether a precondition fixture exists;
- whether XP is read from game state;
- live evidence for the route;
- whether the model can find the route by itself, from its tool list and perception (needed for the `_initiative` cases).

**Sources used:**
- `tools/skill_routes.py`, plus its only run `logs/skills/routes_20261026-161533.json` (0 pass, 4 failed, 8 skipped);
- `docs/design/director.md` §15;
- DISCOVERIES (build primitive P5, live fishing checks, the 15:05–15:40 slot);
- `logs/live_queue/2026-10-26.jsonl`;
- `evals/bench/goal_cases/m3_every_skill.json` and `state_snapshots/fresh_dev_v1`;
- the real client manifest (`client_mod/tests/dump_manifest.lua`) passed through `brain.director.skills_progress`. This is the `curriculum.skills` block the Director shows the model.

## How XP is read (applies to all rows)
- **The body reads XP itself:** `get_state.skills`, from the SkillComponent rows. skill_routes and the Director use it.
- **The harness reads it independently:** `bench_probe.lua` `skills.<Name>.{level,xp}` gives a sensor that doesn't depend on the body. The new live checks assert on this probe.
- **The M3 observer** uses `xp_gained` / `skill_gain`.

So "XP read from game state" is **yes for every skill**. The gaps are in the routes, not in the reading.

## Table

"Fixture" means a harness grant or teleport that a live check may use. M3 main cases are fresh characters with **no grants** (fresh_dev_v1 `grant_policy`). So in the real cases every prerequisite must be bootstrapped by him.

"Model can find it" is what `skills_progress` gives him per skill: the wiki's in-game "how" line, the cheapest makeable recipes that award that skill, and the body tools whose description names the skill. The before/after columns are this change.

| Skill | Body route (tool call) | Fixture for a live check | Live-verified on the client? | Model can find it (before → after) | New live check |
|---|---|---|---|---|---|
| Woodcutting | `gather {resource: ash\|oak…}` with a logging axe. With no axe, gather falls back to `sticks`. | grant `ITEM_Logging_Axe_Stone`; teleport standing_trees | **No.** 16:15 skipped (no axe). Sticks collected live without an axe at 15:xx, but Woodcutting XP was not read. Axe chop was proven on the retired server puppet only. | gather didn't name the skill → **gather now lists "Trains Woodcutting: ash, maple, oak, willow, yew"** | `m3_route_woodcutting_sticks` (does sticks give XP? `trains` is nil), `m3_route_woodcutting_axe` |
| Mining | `gather {resource: stone_boulder\|copper…}` with a pickaxe | grant `ITEM_Pickaxe_Stone` | **No.** 16:15 failed: loose stones gave no XP (fixed: profiles split). The boulder route has never run. | **gather now lists "Trains Mining: clay, coal, copper, iron, rune_essence, stone_boulder, tin; no XP: loose_stones".** This also corrects the wiki line ("gather stones from the floor"), which the live run disproved. | `m3_route_mining_boulder` |
| Agility | `agility_course` (none within 200 m of the dev spawn); walking also gives XP (`WalkingXPEventTriggerDistance` 602 cm) | none needed | **No.** 16:15 skipped (no course). The amount per walk has not been measured. | Yes: agility_course/agility_courses descriptions name Agility and say that walking also gives XP | `m3_route_agility_walk` (go_to out 35 m and back; asserts the XP rose and records the gain) |
| Fishing | `fish {count, method}` with a net or rod | grant `ITEM_FishingNet_CoarseNet` | **Yes:** 09:00 UTC, net, +8 XP for 2 shrimp (rod fights still lost) | Yes (fish/fishing_spots name Fishing) | none needed |
| Cooking | `craft {item: <a Campfire recipe>}` (e.g. Clean Water from Dirty Water, which needs only collect_water) | grant Dirty Water; teleport 3 m from the dev campfire | **No.** 16:15 not_interactable (a sapling took the focus). 19:46 `craft_campfire_input_mode` nothing_in_range: the station was 76 m away and craft did not walk there. | Recipes awarding Cooking are listed. Before: ordered by highest XP, with raw ids ("ITEM_Consumable_Beltfish_Broth"). **After: cheapest first, display names, inputs** ("Baked Potato", "Bread", …). | `m3_route_cooking_clean_water` |
| Artisan | `craft {item}` at a CraftingTable / Kiln / Spinning Wheel … | grant 40 Ash Logs + 30 Stone, then build a table | **No.** It never ran: there is no table near the dev spawn. | Recipes are listed. Before: led by vendor items and capes. **After: makeable at a station, not vendor, cheapest first.** | `m3_route_artisan_table` (buildables → build table → craft Wooden Shield) |
| Attack | `attack {target}`, best melee by default | grant `ITEM_Sword_Bronze`; spawn a Goblin Runt (PL1, spawn verified 19:55) | **No.** 16:15 failed: stuck in `DIM_Gameplay_LockOnTargeting` (fixed since). The `raise_skills` fixture proves only the AddXp row, not fighting. | Before: only combat_brief matched. **After: attack says "the kill trains the skill of the weapon you hold (wiki skill pages: melee Attack, bows Ranged, staffs Magic; `weapon` picks it)".** | `m3_route_attack_fight` |
| Ranged | `attack {target, weapon: <bow>}` (ammo carried) | grant `ITEM_Shortbow_Wood` + 40 `ITEM_Ammo_Arrows_Wood`; spawn runt | **No.** 16:15 skipped. | Before: none. **After: attack** (see above). Bow and arrow recipes appear under Artisan. | `m3_route_ranged_fight` |
| Magic | `attack {weapon: <staff>}` or `cast {spell: <damage spell>, target}`. Data: `PlayerMagicComponent.SpellDamageXpEvent`. | grant `ITEM_Staff_Ash` + runes; spawn runt | **No.** 16:15 skipped. Spell casts are verified (Fire Spirit etc.), but Magic XP has never been read. | Before: none. **After: attack** (staffs). `cast` still doesn't name Magic: its description is in spells.lua (owned by the spells agent, not edited; see "For main"). | `m3_route_magic_fight` |
| Construction | `build {piece}` | grant 6 Stone | **Yes:** P5, a Campfire, +12 XP (DISCOVERIES "build") | Before: only the plank recipes (Sawmill). **After: build says "Trains Construction"** (from that live fact). | none needed |
| Farming | `farm_plots` → `tend {item: spade\|seeds\|…}` | grant `ITEM_Spade_T1_Wood`. **No plot fixture or known dev plot.** | **No.** 16:15 skipped (no spade). There are no plots in relevance at the spawn. | Yes (tend names Farming; Farming recipes listed) | `m3_route_farming_spade` (blocked when there's no plot within 120 m) |
| Runecrafting | gather `rune_essence` (floating rocks: knock them down first) → `craft {item: Air Rune}` at a RuneAltar | grant 3 `ITEM_Rune_Essence`. **No known dev altar.** | **No.** 16:15 skipped. Unknown whether craft drives an altar. | Recipes are listed ("Air Rune" … at RuneAltar); the gather list shows rune_essence trains Mining | `m3_route_runecrafting_altar` (blocked when there's no altar within 120 m) |

**Summary:**
- 2 of 12 routes are live-verified on the client: Fishing and Construction.
- 10 now have a queued live check (11 files, because Woodcutting has two). All pass `live_queue run --dry-run`. Owner `m3-skill-gaps`; each asserts that the probe's `skills.<Skill>.xp` delta is > 0.
- Expected blocks:
  - Farming and Runecrafting block if no plot or altar is within 120 m. That is honest: the dev world has none known near the spawn.
  - Artisan blocks if `buildables` has no crafting table.

## Offline fixes made (with tests)
1. **`client_mod/scripts/gather.lua`:**
   - new pure `M.trains_summary(profiles)`;
   - the gather manifest description now ends with the per-skill profile list built from `gather_profiles` `trains` data. It names no skill or resource in code, and unmeasured profiles (e.g. sticks) are not claimed.
   - Test: `client_mod/tests/test_gather.lua` (+5 checks, 94 pass).
2. **`client_mod/scripts/build.lua`:** the build description adds "Trains Construction (live 2026-10-26: a Campfire gave +12)".
3. **`client_mod/scripts/combat.lua`:** the attack description says the kill trains the held weapon's skill (from the wiki skill pages) and that `weapon` picks it.
4. **`brain/director.py`** (`recipes_by_output`, `skills_progress`). The "recipes awarding XP" rows:
   - are only recipes the craft tool can make: they have a station (a station-less recipe answers `no_station_type`) and are not vendor purchases (`vendor_reputation`);
   - are ordered cheapest first (input-free rows last), then by most XP;
   - use display names, not asset ids;
   - carry `needs` (inputs).

   Before, the Artisan list began "Abysmal Whip, Abyssal Whip" and the Cooking list showed raw ids.
5. **`tests/test_m3_skill_perception.py`** (new, 4 tests, uses the real client manifest):
   - every frozen skill has a visible route (a tool naming it, or makeable recipes awarding it);
   - gather names its Woodcutting / Mining / no-XP profiles;
   - recipe rows are makeable, named, and cheapest first;
   - vendor rows are flagged.

**Tests run, all green:**
- the Lua suites gather, build, combat, crafting, manifest_flags, client_bridge;
- pytest: test_principles, test_lua_client_suites, test_client_bridge, test_gather_data, test_live_queue, and `-k "director or manifest or skill or situation or capab or gather or build or combat or craft"`: 240 passed, 1 skipped.

**Search-before-building:** reuse over build. The fix follows the existing pattern that fish, tend and agility_course already use ("Trains X" in the tool's own description; MCP `tools/list` and MINDcraft-style capability text, ARCHITECTURE §8.6). The summary is generated from the existing profile data. No new mechanism was built.

**No phrase maps, no spoon-feeding:**
- Every added word states a fact about a tool: what it trains, from profile data, a live measurement, or the wiki.
- Nothing tells the model which skill to raise. The initiative choice still comes from `skills_progress` (lowest first, from game state).

## Open gaps for owners (not fixed here)
- **Cooking (crafting owner):** `craft` at a known Campfire 76 m away answered `nothing_in_range` rather than walking there (19:46). The 16:15 run hit the sapling focus. The live check teleports to 3 m, so it isolates the XP route from that locomotion bug.
- **Magic (spells owner):** `cast`'s description (spells.lua, not mine) could say that damage spells train Magic (`PlayerMagicComponent.SpellDamageXpEvent`). Utility casts' XP is unmeasured.
- **Woodcutting bootstrap:** if `m3_route_woodcutting_sticks` shows no XP, set `sticks.trains = false` in gather_profiles. A fresh character then needs a Stone Logging Axe (CraftingTable: 6 Stone + 8 Ash Logs) before any Woodcutting XP.
- **Station-less recipes** (e.g. `RECIPE_Weapon_Club_Wood`, 1 Ash Log, Artisan 5; `RECIPE_Consumable_Wardstone_Small`, Runecrafting): the data lists no station. How the game crafts them (hand or inventory crafting?) is unresearched. They might be the cheapest first Artisan route for a fresh character.
- **Recipe card XP:** `mod/body/recipe_data.lua` (generated) does not carry `skill` / `xp`, so the body's `recipes` / `craft_plan` replies can't show XP per recipe. The brain-side `skills_progress` has it from `data/recipes_*.json`. Adding it means changing the `tools/build_recipes.py` Lua emitter (generated file, so main's call).

## For main: judge-side items (evals/, DevTarget, case specs). Not edited.
1. **The XP threshold is a flat 100 in every M3 case.** goal_targets says `xp_threshold: calibrated per skill on dev vs an ambient run (evals/bench/manifests/<build>/skill_thresholds.json)`, but that file does not exist (the manifests dir has only goal_v1 / suite_v1).
   - Measured rates differ a lot: Construction +12 per Campfire, Fishing +8 per 2 shrimp, recipe base XP 1 for Clean Water and Air Rune, Agility per 6 m walked (unmeasured).
   - Proposal: once the `m3_route_*` checks report gains, write skill_thresholds.json as the spec says (ambient run vs a deliberate run), and point the cases at it.
   - Not a weakening: it implements the frozen judge text, and a calibrated threshold that is *above ambient* is stricter than a flat 100 for slow skills that ambient play already reaches.
2. **Agility is incidental to every case** (walking gives XP; the case provenance already says `incidental_xp: true`).
   - Every other skill's `_initiative` case asserts `xp_top` for the target skill. With raise_skills levelling the others to 10, relative gain is still meaningful, but a long walk to a station can make Agility out-gain a slow skill (Runecrafting / Cooking at 1 XP per craft).
   - Proposal: `xp_top` should exclude skills flagged incidental (Agility), or compare against the calibrated ambient baseline from item 1.
   - Not a weakening: it removes a false failure caused by unavoidable walking, without crediting any XP he didn't earn.
3. **raise_skills for Magic and Agility:** the live run (09:45) left them at 0. The fix (live row handles `SpellDamageXpEvent` / `SprintXpEvent`) is offline-only. Until it is re-run live, `m3_agility_initiative` and `m3_magic_initiative` start with two skills tied at level 1, so "lowest" is ambiguous. Proposal: one live re-run of the fixture before scoring those two cases (a scene fix, not a criterion change).
4. **Dev-world facts missing from `evals/bench/dev_places.json`:**
   - the nearest CraftingTable, RuneAltar, farm plot, agility course and stone boulder to the fresh spawn. Today only `standing_trees` exists.
   - This is a harness fact (never companion knowledge), needed to (a) point the blocked live checks at the right spot and (b) judge whether a 1200 s asked case is reachable from the fresh spawn at all. Proposal: one `places_dump`-style observe check that records them.
5. **Fresh-character bootstrap length:**
   - From a torch-only character, Fishing (net craft), Ranged (bow and arrows), Magic (staff or runes), Runecrafting (essence and altar) and Farming (spade and plot) each need a multi-step craft chain before the first XP.
   - The `_asked` wall of 1200 s may be too short for some. Measure it first: run one Director case per skill with the existing budget (≤ 10 Sonnet requests per batch, director.md §15), before changing any wall.
   - If a wall changes, the bar should be "the wiki route's bootstrap time + margin, measured", which keeps the case equally hard relative to the game.
