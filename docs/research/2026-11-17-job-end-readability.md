# Can the game state each job end reads be read today? (2026-11-17)

CLAUDE.md section 2 rule 4: before a second fix on one item, the game's own state for it must be readable. This audit checks every end predicate of `data/jobs.json` (L1 to L3, and only the END definitions of the held-out H1 to H3) and every interruption I1 to I5 against what `tools/job_run.py` reads and against real logs.

Offline only. Nothing was run, no repo file was changed except this one. Sources:
- `logs/brain-live-2026111[67]-*.jsonl`: 267 files, 4 760 `get_state` replies, every store/take/inspect/craft result.
- The one job record so far: `logs/evals/job_runs.jsonl` run `20261117-195219-L2` (brain log `brain-live-20261117-205205-24152.jsonl`).
- `logs/client/client.log`.
- The scratchpad scan scripts (`scan.py`, `pl.py`, `last.py`, `ids.py`) are not in the repo.

## Verdicts

| item | predicate | readable | the gap that matters |
|---|---|---|---|
| L1 | `worn_made_in_run` | **yes** | Not a read gap: every L1 trial from ClaudeDev is NOT COUNTED. He wears a Leather Cowl, which matches `not_carried_at_start` `ITEM_Armour_T*_*Leather` |
| L2 | `in_own_chest` | **partly** | No end read of the chest; "mine" comes from a client ledger capped at 30 m and 15 rows; the store result has no `mine` |
| L3 | `gear_target` | **partly** | The game's PL is read, but a failed read falls back to catalog PLs with no durability; kit PL ignores durability; the target comes from a gear_plan with no broken handling |
| L3 | `consumables_carried` | **yes, loose** | Dirty Water counts as a drink |
| H1 | `made_in_run`, `carried_gain`, `near_start_m` | **yes, but over-counted** | The loadout's Ammo and Held slots are counted again on top of the bag and hotbar: 33 arrows equipped read as 66 |
| H2 | `in_own_chest` | **partly** | As L2, plus a station he built counts as "his chest" |
| H3 | `next_tier_tools` | **yes** | (definition only) ClaudeDev's 19:52Z bag held none of the three tool families, so the predicate is false whatever he does |
| I1 | hunger, thirst | **yes** | none |
| I2 | a fight | **partly** | `combat_started` is emitted only by the reflex. A fight he starts with `attack` reads "did not take" (void) |
| I3 | death, grave | **yes** | Edge case: a respawn within 20 m of the death never clears |
| I4 | a full bag | **no** | `empty_slots` counts every page (164 live), so `took` (left == 0) can never be true |
| I5 | brain restart | **yes** | none (it is the harness's own process) |

Cross-cutting (every job): a failed `get_state` (`ok: false`, "no local player controller") is read as an empty character. 78 of 4 760 replies were like this. At the start of a run that overstates every gain and skips the head-start check (see the last section).

## Per job

### L1: `worn_made_in_run` (yes)
- **Worn:** `get_state.inventory_items` loadout rows (`loadout_slot`, `durability`, `max_durability`, `broken`) and `gear`. Present in 4 682 of 4 760 replies (16 and 17 Nov). Example from the last get_state of `brain-live-20261117-205205-24152.jsonl`:
  - `Head` = Leather Cowl, 636 of 1000.
  - `Body` and `Legs` = Adventurer's pieces, `broken: true`, 0 of 500.
- **Made:** `craft` results carry `data.item` as an item id in 324 of 324 ok crafts. In the L2 run, `crafted` = `ITEM_Pickaxe_Stone`, `ITEM_Logging_Axe_Stone`, and so on.
  - Armour has never been crafted in a trial, so its craft reply shape is assumed to be the same.
- **Ids:** the 9 leather ids exist in `data/items_26574459.json` (T2 Leather, T3 HardLeather, T4 StuddedLeather × Head, Body, Legs).
- **Armour is not double-counted:** a worn piece shows only in the loadout (the cowl: `carried` 1).
- **Durability is ignored.** A piece made in the run and broken by the end still passes "worn". This is unlikely, and it is a false pass only in that case.
- **Blocker (not a read):** the start state of run `20261117-195219-L2` carries `ITEM_Armour_T2_Head_Leather: 1` (worn).
  - `not_counted` (`job_run.py` near the end of the predicates) matches it against `ITEM_Armour_T*_*Leather`, so every L1 trial forked from ClaudeDev today is recorded NOT COUNTED.
  - A start without leather armour has to be made by a run (rule 8).

### L2 and H2: `in_own_chest` (partly)
What is read:
- **Contents:** the body's read of the game's open container screen, taken from `store` / `take` / `inspect` results (`job_run.chests_seen`, line 124).
  - Live: 8 of 8 `store` results on 16 and 17 Nov carry `container`, `contents` and `inside_now`. Example, `brain-live-20261116-003803-20116.jsonl` 1794786155: "Put 61 Ash Logs in the Crate", `contents ["61 Ash Logs"]`, `inside_now 61`.
  - A failed `take` also lists the contents ("it has 13 Ash Logs, 1 Stone Club, 1 Bronze Shield", `brain-live-20261101-224952-3652.jsonl`).
  - This is a game read, not memory. The names resolve to ids: "Copper Ore" → `ITEM_Resources_CopperOre`, "Clean Water" → `ITEM_Consumable_Water_Clean`, "Rat Roast" → `ITEM_Consumable_Meat_Rat_Roast`.
- **Ownership:** `get_state.structures[].mine`.

What is missing:
1. **No read at the end.** The contents are as of his last open of that chest. `inspect` on a built crate still returns nothing: `client_bridge.lua:1224-1230` `contents_of` has no fallback to `inventory.owned_inventory`, and the long-job-harness diff 4 is not in. The server `contents` fixture (diff 5) is not built either. `take` and `inspect` results on a crate: none on 16 and 17 Nov.
2. **"Mine" is not game state.** The game keeps no owner per piece (`build.lua:1862`). `mine` comes from the client ledger `data/skills/dev/my_pieces.json` (`deconstruct.lua:28-30`, `:839`):
   - Every fork on the dev world writes to that one file, so a crate built by any Claude character counts as his.
   - `world_snapshot` does not save or restore the ledger.
3. **The `store` result carries no `mine`** (0 of 8), so `_own_chests` (line 192) depends entirely on the `structures` rows of the start and end `get_state`. Those rows are capped at **30 m and 15 rows** (`build.lua:2855` `cfg.structures = {radius_m = 30, max = 15}`).
   - In run `20261117-195219-L2` the start read had exactly 15 rows (benches, campfires, door, walls), and no crate among them, although the same brain log marks `BP_BaseBuilding_Crate_C_2147473013` `mine: true`.
   - The end read had `own_containers: []` (he was 180 m away).
   - So a real success can read "no container of his was opened in the run" (a false fail).
4. **False-pass route:** `own_containers` takes every `mine` structure, stations included. Meals left in his own campfire or range, then read by a `take` result there, count as "in his chest" (H2).
5. The crates' ids change after a reload (DISCOVERIES 20:58Z note: "matched by position"). Within one run this does not matter.

### L3: `gear_target` and `consumables_carried` (partly)
- **The game's PL is readable.**
  - `get_state.power_level` (`combat.lua:600` `pawn:BP_GetPowerLevel()`, read at most every 10 s) is present in 4 682 of 4 760 replies.
  - Every one reads **0.0** on 16 and 17 Nov. That agrees with a broken tunic and broken leggings under a PL 2 cowl ((2+0+0)/3, rounded down).
  - `job_run.p_gear_target` (line 298) uses it for armour.
- **The 78 replies without it** are all `ok: false`, "no local player controller" (`brain-live-20261116-211427-13140.jsonl` 1794860182).
  - `snapshot` then gives `power_level: None`, and `p_gear_target` falls back to `gear_on`'s catalog PLs, which **ignore durability**.
  - At the end of a run that is a route to a false pass on a broken set.
- **Fallback value:** `combat.lua:600` `... or c.pl or 1` would show an invented 1 before any good read. This was not seen in these logs.
- **Staleness:** up to about 13 s after an equip, according to the power-level note. The end read comes right after the trial stops, so an equip in the last 13 s may not be counted yet.
- **Kit slots** (HeldRight, HeldLeft) are judged on catalog PL only, with no durability. A broken weapon passes.
- **The target itself:**
  - It is `rung4_gate.gear_target` → `gear_plan.plan` on main.
  - `brain/gear_plan.py` on main has **no broken handling** (grep "broken": none). The fix f956297 and its note `docs/research/2026-11-17-power-level.md` are only on branch `worktree-agent-ac55fb7d78eeed444`, not on main. The power-level doc cited in this audit's brief is not in the main tree.
  - The target looks at enemies in sight, not at a vault's.
  - It counts "reachable" items from `logs/state/worlds/<world>/containers.json`. That is a remembered chest, not a game read, and it affects the target, not the end read.
- **Consumables:**
  - `inventory_items[].consumable` is read by class (`inventory.lua:114`). Food rows: 4 955; drink rows: 3 465. Raw meat correctly has none.
  - **Dirty Water reads `consumable: "drink"`** (236 rows on 17 Nov), so 5 Dirty Water pass "drink 5".
  - Burnt food is likely `FoodItemData` too. This was not verified.

### H1 (definition only): `made_in_run`, `carried_gain`, `near_start_m` (yes, over-counted)
- **Position:** read in 4 682 replies.
- **Ids:** bows (`ITEM_Shortbow_*` 10, `ITEM_Longbow_*` 10) and arrows (`ITEM_Ammo_Arrows_*` 30) exist.
- **Over-count:** `snapshot` (line 98) sums hotbar, bag and loadout rows. The loadout's Ammo slot references the bag stack (DISCOVERIES "Arrows read as -22 because the loadout's Ammo slot references the bag stack"), and the Held slots reference hotbar slots.
  - Live, last get_state of the L2 run: Stone Arrow bag 20 + loadout Ammo 20 = `carried` 40. One Stone Pickaxe in hotbar + HeldRight + HeldLeft = 3.
  - One craft of Stone Arrows (33 a batch) that he equips gives a gain of 66 against the "40 arrows" bar: **a false pass.**

### H3 (definition only): `next_tier_tools` (yes)
- **Ids and tier words:** Pickaxe ×8, Logging_Axe ×7, WateringCan ×5 exist. The last word of each id is a tier in the order.
- **Start state:** the 19:52Z ClaudeDev start carried no pickaxe, axe or watering can (lost to graves). The predicate then answers "carried none of the tool families" whatever he does.
- Recorded as a fact about the start; nothing is proposed.

## Per interruption

- **I1 (yes):**
  - `set_stat` is in `fixtures.VERIFIED`.
  - `get_state` carries `sustenance`, `hydration` and their maxima.
  - There were 96 `vitals_low` events and 160 `reflex_use` activities.
  - It clears at once, so no read is needed to clear it.
- **I2 (partly):**
  - `spawn` is verified. The clear signal is `combat_started` then `combat_end` after the spawn (`fight_cleared`).
  - `combat_started` is emitted only with `by = "reflex"` (`combat.lua:4029`); there were 160 of them against 250 `combat_end` on 16 and 17 Nov.
  - If he attacks the goblin with the `attack` tool before the reflex takes it, no `combat_started` comes, and after 40 s the trial reads "did not take" (void), although he fought.
  - Any `combat_started` after the spawn (a rat) also counts as the I2 fight.
- **I3 (yes):**
  - `me` reads `dead` (`sense.lua:261`) and `position`. There were 31 `dead: true` get_state readings.
  - Graves are read as `interactables` `BP_PlayerGravestone_C` with `owner_check: verified` (149 readings) and as `graves_remembered`.
  - It clears only when he respawns more than 20 m from the death. A death within 20 m of the lodestone never clears and reads "no respawn" (void).
- **I4 (no):**
  - `io.empty_slots()` is `inventory {raw}`.`empty_slots` = `GetNumEmptySlots`, which counts every page: QuickAction 8, Items 32, Runes 32, Ammo 32, Quest 72 (DISCOVERIES "empty_slots ... counts all pages (133), so it is no measure of bag room"). Live: 164 (`brain-live-20261117-181801-22264.jsonl`).
  - `apply_interruption` (lines 575-581) grants that many nets. Once the 32 item slots are full, grants of a new kind fail `not_added` (DISCOVERIES, rung 1 gate). The Runes, Ammo and Quest slots never fill, so `took = left == 0` is never true, and every I4 trial is void.
  - The readable figure exists: `get_state.bag {used, capacity}` counts the InventoryItems page only (`skills.lua:2378-2390`). Live: capacity 32, used 5.
  - Note: the body's own full-bag test `gather.lua:1299` (`J.empty_slots == 0`) has the same flaw. With a full item page he may never get `inventory_full`.
- **I5 (yes):**
  - The harness stops and starts its own brain. `Live.restart_brain` appends the new log to `files`, so `rows()` reads both brains.
  - The new brain's start is logged (`session_start`, `llm_warmup`).

## Any predicate: a failed read taken as empty
- `Live.state` (`job_run.py:793-795`) returns `data` even when `ok` is false.
- `run_job` reads `raw0 = io.state()` (line 631) after the brain starts, separately from the per-fork `body_unfit` check.
- A start read with `ok: false` gives `carried {}`, `worn {}`, `power_level None`. Then:
  - every `_gain` equals the whole end count (L1, H1 false pass);
  - `not_counted` sees nothing (the L1 head start passes unseen);
  - H3 reads "carried none".
- At the end, the same failure gives false fails, except L3: there `power_level None` falls back to the catalog PLs.
- A sample with `ok: false` should be re-read, never scored.

## The one gap to close before a whole-job window
**The chest end read for L2.** L2 is the only whole job that can count today: L1 is not counted from ClaudeDev, and L3's target is soft. Its predicate already fails a real success:
- the store reply carries no `mine`;
- the 30 m and 15-row cap dropped his crate from both reads in run `20261117-195219-L2`;
- nothing reads the chest at the end.

The smallest closing step:
1. Make `contents_of` fall back to `inventory.owned_inventory`. That read path is already proven live by `store` into a built crate (DISCOVERIES 2026-11-01 20:58Z).
2. Have `job_run` inspect each `mine` crate (storage only, not stations) at the end.
3. Keep the crate ids seen during the run in `own_containers`, not only those in the two capped `structures` reads.

Next in line: I4's room read (`bag.capacity - bag.used`), and the `ok: false` guard on the start and end reads.
