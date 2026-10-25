# R2.19 design note: crafting at real stations through the game's own UI path

Status: rev 2 after review aa990d09b7e96fb65 (crafting agent, 2026-10-25). Template: `docs/design/PRINCIPLES.md`.

## Goal (what Luis sees)
- Luis says "make me a stone axe" or "smelt that ore". Claude walks to the right station in the base and opens it the way a player does.
  - **Bench:** he crafts, and the axe shows up in his inventory.
  - **Furnace, kiln or campfire:** he loads ore and fuel, starts it, waits, then picks up the bars.
- When he can't, he says exactly why: "I haven't unlocked that yet, I need to hold Iron Ore near a Furnace first", "I'm 2 Oak Logs short", "there's no Blacksmith's Bench near here" or "my bag is full".
- The brain can ask what he can make right now and what a goal needs, as a tree of craft and gather steps. The model decides what to make; the body never chooses.

## Approach (layers, files)
**New module `client_mod/scripts/crafting.lua`, owned by me.** It is pure planning plus a thin game layer `W` that the tests replace.
- **Data:** it loads `mod/body/recipe_data.lua` (generated, cached in `_G`). `tools/build_recipes.py` adds one field per recipe, `uq` (the unlock query text, e.g. `ALL ITEMS[ Iron Ore ] AND ALL ACTORS[ BP_Station_Smelter_C ]`), regenerated with `--merge-only` from the existing raw logs (no live run).
- **Unlocks:** Claude's own `pc.ProgressComponent.RecipesUnlocked` (a TSet read, as `SpellsUnlocked` is) on his local PC, cached for 10 s.
- **Stations:** found generically. Each census interactable of kind `crafting_station` or `processing_station` is matched to its station type through the catalog's exact class word (`stations[sid].classes`). It is also read from its components:
  - crafting: `CraftingStationComponent.ValidRecipes`, `DisplayName`;
  - processing: `ProcessingStationComponent`: `bStationRunning`, `bReadyToProcess`, `RemainingProcessingTime`, `RemainingFuelTime`, `CurrentRecipe`, `bStoreOutput`, and the contents of `Resources`, `Fuel` and `OutputInventory`.
  - None of this is hard-coded per station.
- **Planner (pure, read-only), ported from the legacy `mod/body/crafting.lua` `plan`/`check`:**
  - `craftable(here)` gives the recipes that are unlocked, whose inputs he carries, and whose station type is nearby.
  - `plan_tree(goal, count)` recurses over the catalog. At every node it lists **all** candidate recipes with their status, ranked only as information; the first ranked is expanded, the others are shown as `alternatives`. A missing input becomes a sub-craft, a `gather` step (an item that a `gather_profiles` entry yields, matched on the data's `item` field) or an `obtain` leaf. Each node carries its status: `have`, `craftable`, `locked {unlock: uq}`, `no_station {need}`, `missing`. There is a depth cap and a cycle guard.
- **Craft at a bench (`kind = crafting`):**
  1. Take the arbiter at level `command`.
  2. Approach and face the station, then press interact once. This reuses the skills.lua episode (approach → face → press). Only the verify step differs: done means `CraftingUIAPI.CurrentStation` is this station's component, i.e. the game opened the menu (`Client_ToggleCraftingMenu` → `ShowCraftingUI`).
  3. **The UI's own handlers:** `CraftingUIAPI:SelectRecipe(recipe)`, then `CraftingUIAPI:SendCraftRequest(count)`. This is what the craft button runs **[UNVERIFIED: from the dump; live step 2's capture hooks confirm it, recorded in DISCOVERIES]**. Internally it is `InventoryController:CraftRecipe` → `Server_CraftRecipe`, with the station, multipliers and linked inventories that the game computes itself. **We never call `Server_*`.**
  4. Read the result from a read-only post-hook on `InventoryController:Client_OnCraftingResultHandler(ECraftingResult, Recipe, Count)`, i.e. the server's own verdict, mapped to reasons (1 missing inputs, 2 bag full, 3 too heavy, 6 not unlocked …).
  5. Then verify against the inventory: the outputs went up and the inputs went down.
  6. Close with `CraftingUIAPI:HideCraftingUI(Crafting = 6)` so gameplay input works again, and release the arbiter.
- **Processing station (`kind = processing`):**
  1. Approach and press interact, as for a bench. This time the verify step is `ProcessingStationUIAPI.ProcessingStationComponent` = this station.
  2. Load it with the inventory UI's own drag handlers: `InventoryUIAPI:HandleSplitToExternalSlot(slot, slotType, amount, toSlot, station.Resources)` for inputs, and the same into `station.Fuel` for fuel. The fuel is chosen as in **Fuel** below: the `fuel` arg, or the single accepted fuel he carries, else `ambiguous_target`; with none he fails with `missing_input` (fuel). Each move is verified (his count fell, the station inventory rose).
  3. Start with `ProcessingStationUIAPI:ToggleProcessingStationStarted()`, the UI's start button, unless `IsProcessStartedAutomatically`. He then waits while `bStationRunning` holds, up to the catalog time model + 50%, and checks `CurrentRecipe` is the wanted recipe.
  4. **Collect:**
     - when `bStoreOutput` is set: `InventoryUIAPI:HandleExternalQuickTransfer(slot, OutputInventory)`;
     - otherwise the outputs spawn as world items at the station, so he picks them up with the skills.lua fetch engine (interact presses), **filtered to the recipe's output item ids, to world items that appeared after he pressed start, and to no more than the amount he produced**.
  5. Verify the outputs are in his inventory. Close with `HideCraftingUI` (or the processing UI's own close).
- **Shared stations (Luis's rule: never touch his items):** he loads only a station that is idle, with empty `Resources` and `OutputInventory` (and empty `Fuel`, unless `use_station_fuel` is set), or one whose contents he loaded himself in this episode. He collects only what he produced, counted against what he loaded. Otherwise he fails with `station_busy`: "The Furnace is busy with someone else's stuff (Copper Ore x3)."
- **Fuel:**
  - `craft` takes a `fuel` arg. Without it, he burns the one accepted fuel he carries. If he carries more than one kind, he fails with `ambiguous_target` and lists the candidates.
  - He never burns an input of this recipe; if that is the only fuel he has, he says so.
  - The result always carries `data.fuel_used`.
- **Recipe choice is the model's:**
  - `item` that maps to exactly one viable recipe (unlocked, inputs held, station present) proceeds, and the result says `data.recipe_chosen` and lists the `alternatives`.
  - If more than one is viable and no `recipe` was given, he fails with `ambiguous_target` and `data.candidates` {recipe, station, missing}.
  - If none is viable, he fails with the most specific reason, and every candidate is listed with its own reason.
  - Without a `station` arg he uses the nearest station of the recipe's type, and returns it as `data.station`.
- **`craft` never runs the plan tree on its own:** no hidden sub-crafts and no gathering. It crafts one recipe from what he carries, and the model or Planner sequences the steps it read from `craft_plan`.
- **Speech for every outcome:**
  - every `ECraftingResult` maps to a reason plus a `detail` sentence (`detail_is_speech`): 1 `missing_input`, 2 `inventory_full`, 3 `too_heavy`, 4/5 `invalid_args`, 6 `not_unlocked`, 7 `not_unlocked` (vendor reputation);
  - an unknown value surfaces as `craft_failed` "result <n>";
  - no result within the craft time + 5 s gives `timeout`;
  - a processing wait over the catalog time + 50% gives `timeout`, "the Furnace stopped or took too long (X s)".
  - The UI is closed on every exit path (success, failure, cancel, interrupt).
- **Bridge tools:**
  - module `HANDLERS` plus a `MANIFEST` in crafting.lua (no route edits);
  - `craft {recipe | item, count, station?, fuel?, use_station_fuel?}`, kind action (`use_station_fuel`: "only when the player said to use the fuel already in it (it may be someone else's)"; default false), async `{pending}`;
  - `recipes {item? | station? | craftable?}` and `craft_plan {item | recipe, count}`, kind `read`, offered to the LLM;
  - `stations {radius}`, kind `read`.
  - **Needs from main:** add `"crafting"` to `client_bridge.M.MODULES`. One small generic addition to sense.lua's `describe_interactable` would give census rows `station = {type, running, progress, contents}`; that is a sense-owner decision, otherwise `stations` covers it.

## Precedent (search-before-building)
- **Mineflayer/Mindcraft:** the craft command takes a recipe that `bot.recipesFor(item)` resolved from game data, walks to a crafting table, then calls the client's own window click; it fails with the missing items. Mindcraft adds a crafting-plan text (`getDetailedCraftingPlan`) for the LLM.
- **Plancraft:** the goal is the root of a dependency tree, the materials are the leaves.
- **Minecraft autocraft mods (CraftFlow, EMI):** a recursive ingredient search that reports "missing / intermediate / available".
- **We reuse:**
  - the legacy `mod/body/crafting.lua` plan and check (ported, not reinvented);
  - skills.lua's approach/face/press episode;
  - the UI-API pattern already proven for inventory (`InventoryUIAPI:HandleDropItem`, `HandleInternalDragAndDrop`) and the menus (`MainMenuUIAPI`);
  - craft_drift's hook list for capture.
- **Searched with nothing found:** no Dragonwilds UE4SS mod that drives `CraftingUIAPI`. The "Linked Storage Stations" mod on CurseForge pulls from chests into stations, but its source is not public.
- **Sources:**
  - https://sites.uci.edu/kolbynottingham/2024/10/30/mindcraft
  - https://arxiv.org/html/2412.21033v1 (Plancraft)
  - https://www.curseforge.com/minecraft/mc-mods/craftflow
  - https://www.curseforge.com/runescape-dragonwilds/ue4ss-mods/linked-storage-stations
  - https://docs.ue4ss.com/lua-api/global-functions/registerhook.html

## Generality check
- A new recipe, item or station type needs no code: it is data in the catalog. The station type comes from the class word to catalog join, the inputs and outputs from the recipe, and the fuels from the station row.
- Vendors (`is_vendor`) use the same `CraftingUIAPI` path, but they are refused for now with `not_implemented` (they need reputation and gold).
- Recipe choice is the model's. The ranking (unlocked, station present, inputs held, fewest missing) is information only. `craft` proceeds only when exactly one recipe is viable; otherwise it answers `ambiguous_target` with the candidates. The model can pin one with `recipe`.

## Principles touched
- **No `Server_*` call:** `SendCraftRequest` and `ToggleProcessingStationStarted` are UI handlers.
- **Hooks are read-only.** `Client_OnCraftingResultHandler` is a post-hook, and it is not the call path.
- **One owner of the pawn** (the arbiter). It honours `DW_PAUSE`.
- **Open risk:** whether the UI API objects exist and work under NullRHI. Inventory and main-menu UI APIs did, but if the crafting widget is never created, `SelectRecipe` may no-op. In that case I stop and report; there is no fallback to `Server_CraftRecipe`.
- **Bent:** none. If the UI API no-ops headless, I stop and report.
  - Calling `InventoryController:CraftRecipe` directly is NOT a fallback. Its parameters (BonusCount, the XP multipliers, the Inventories TArray) would be values we choose and a hand-built array sent into a Server RPC.
  - It would only be in bounds if ALL of these hold:
    (a) a hook proves the UI's craft button calls exactly that;
    (b) every argument is the game's own value (the array from `GetLinkedInventories`, the multipliers from the UI's own function or a captured real call; no constants);
    (c) it is tested offline and on the dev server first, with the capture showing one matching `Server_CraftRecipe`;
    (d) Luis explicitly OKs it.

## Acceptance tests
- **Offline:** `client_mod/tests/test_crafting.lua` with a fake world (stations, inventory, unlocks, UI API, result hook). It covers:
  - the planner: craftable now, a tree with gather leaves, locked with its unlock text, cycle and depth guards, and held-out items absent from the fixtures' hand lists (the real catalog);
  - a bench craft: success, and failure on each ECraftingResult;
  - a furnace: load, start, wait, collect, both for world-item outputs and stored outputs;
  - pause, suspend/resume and timeout;
  - an ambiguous recipe answers candidates; a single viable recipe answers `recipe_chosen` plus the alternatives;
  - ambiguous fuel; never burning a recipe input;
  - `station_busy` with the contents named;
  - output pickup ignores a pre-existing world item of the same id near the station;
  - an unknown ECraftingResult answers `craft_failed`;
  - the UI is closed on each exit path.
- **Bridge:** manifest and capabilities via `test_client_bridge.lua` / `tests/test_client_bridge.py`.
- **Live, only when main clears it, one at a time:**
  1. A read-only `stations` and `recipes {craftable}` near Luis's base: station types, recipes, processing state.
  2. With Luis's OK and materials, one cheap bench craft that Claude has unlocked. The capture hooks on Claude's own client (`CraftRecipe` / `Server_CraftRecipe` pre-hooks, read-only) confirm the UI path sends exactly one craft RPC with the expected params.
  3. Later, one furnace or campfire run.
