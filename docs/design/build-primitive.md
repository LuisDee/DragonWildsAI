# Build primitive: `build {piece, at|near, rotation?}` (design, pre-review)

Status: DESIGN, 2026-10-26. Nothing is implemented. Next: a fresh-context review (main arranges it), then offline tests, then dev live probes one at a time (client slot from main). **Dev only, never Shockbyte.**

Goal (Luis, via main): Claude builds his own base, crafting stations, chests and farm plots like a player. This also unblocks M3 Construction XP. Real player paths only: the game's build mode, its build menu, its own placement preview, and the real confirm input. Verification comes from game state, and every failure carries a truthful reason.

Items marked **[UNVERIFIED]** come from the reflection dump (build 26161880) and must be confirmed by the live probes in §7 before the code relies on them.

## 1. What the game has (dump 26161880, `dumps/26161880/CXXHeaderDump/Dominion.hpp`)

### Owners
- `ADominionPlayerController`:
  - `BuildModeComponent` (0x0D60);
  - `BuildPlacementComponent` (0x1280);
  - `BuildInteractionComponent` (0x1288);
  - `BuildValidationComponent` (0x1290);
  - `ProgressComponent` (already read by crafting.lua and spells.lua).
- `UHUDUISubsystem.BuildingAPI` is the `UBuildingUIAPI`, the build menu's own API object (like `InventoryUIAPI`, which inventory.lua already drives).
- `AGlobalBuildingManager.CounterComponent` is the `UBuildingCounterComponent`, with `BuildingPieceCounts` and `TagsToCountsMap`.

### Build mode
`UBuildModeComponent` (l.16126):
- **State:** `CurrentBuildMode` / `PrevBuildMode`. `EBuildMode` is None=0, Selection=1 (the menu is open), Placement=2, RepairAndEdit=3.
- **What is being placed:** `CurrentlyPlacingPieceData` (a weak `UBuildingPieceData`).
- **Snapping:** `SnappingMode` (Basic / Advanced / Free).
- **Input actions it owns:** `CancelAction`, `ModifyRotationAction`, `ModifyHeightAction`, `ModifyDistanceAction`, `GhostModifierAction`, `FreePlacementModifierAction`, and the context `BuildingMappingContext`.
- **Handlers the UI and input call:**
  - `OnToggleBuildModeInput(HeldDuration, bShouldCheckPauseBlock)`
  - `OnPieceSelected(UBuildingPieceData*)`
  - `OnPieceHovered`
  - `OnCancelInput`
  - `OnValidityStateChange(EValiditySpawnState)`
- **Other reflected functions:**
  - `ForceEnterBuildMode` and `ExitAnyMode`;
  - `TrySpawnPieceAtLocation(data, FVector, FRotator)`, a client function;
  - `Server_SpawnBuilding(int32 index, FTransform, bool ghost, TArray<UInventoryComponent*>)`, the RPC.

### Building UI API
`UBuildingUIAPI` (l.16531) has:
- `CallOnBuildingItemSelected(UBuildingPieceData*)`. This is what a click on a menu slot calls, and it broadcasts `OnBuildingItemSelected` to `BuildModeComponent.OnPieceSelected`.
- `CallOnBuildingItemHovered` and `CallOnBuildingItemUnhovered`.
- `OnBuildingsUnlocked`.

### Placement limits and settings
- `UBuildPlacementComponent`: `SelectionMaxPlacementDistance`, `MaxPlacementDistance`, `MaxHeightModifier`. These are the reach of the preview from the camera.
- `UBuildingSettings` (a developer settings CDO):
  - `ModifyRotationStepDeg`: one rotate press;
  - `BuildPieceCatalogue` (pages → collections → pieces), the menu's own structure;
  - `PieceTagToMaxCountMap` and `MaxNumPieces`: count limits;
  - `GhostPlacementMaterial`.

### The preview
`ABaseBuildingActor` (l.8895):
- `bIsPreview`, `bIsGhosted`, `PlayerControllerManagingPlacement`;
- `BuildingPieceData`, `BuildingPieceDataIndex`, `BuildingPieceID`;
- `OnValiditySpawnStateChanged(EValiditySpawnState)`.

The placement preview is a local `ABaseBuildingActor` with `bIsPreview` set **[UNVERIFIED]**. Its location is the placement point.

### Validity
`EValiditySpawnState` (`Dominion_enums.hpp`):

| Value | State |
|---|---|
| 0 | Valid |
| 1 | Overlapping |
| 2 | Floating |
| 3 | NeedsFoundation |
| 4 | NeedsSnapping |
| 5 | Unstable |
| 6 | MissingMaterials |
| 7 | WrongPhysicalSurface |
| 8 | InsideVault |
| 9 | InsideProtectedArea |
| 10 | ReachedCountLimit |
| 11 | ShelterCheckFailed |
| 12 | InsideBlockedRegion |
| 13 | None |

The game's own words for each state are in `UBuildInteractionComponent.ValidityNotificationTextMap` (`TMap<EValiditySpawnState, FText>`). The server tells a refused placement through `UBuildInteractionComponent:Client_ShowValidityNotification(EValiditySpawnState)`.

### Piece data
`UBuildingPieceData` (l.16298):
- `DisplayName`, `Description`, `Category` (tag);
- `BuildableActor` (soft class);
- `Requirements: TArray<FResourceRequirement{Amount, ItemData}>`;
- `ConstructionXPOnBuild`, `PieceTag`, `bOnlyAvailableToHost`;
- `BuildingPieceDataIndex`, `RepresentationCategory`.

`UBuildingPieceDerivedData`: `BuildingPieceLocalBounds` (the footprint) and `PlacementZOffset`.

### Unlocks
`UProgressComponent.BuildingsUnlocked` (a `TArray<UBuildingPieceData*>`, hard refs), `IsBuildingUnlocked(data)`, `BuildingsUnlockedThatShouldNotPersist`, `Client_OnBuildModeUnlocked`.

### Input actions
`/Game/Gameplay/Inputs/Actions/...`:
- `UI/IA_BuildMenu` opens the menu (B on keyboard per the community controls guide);
- `Building/IA_Building_SelectPiece`;
- `IA_Building_RotateZ` / `_Negative`;
- `IA_Building_OffsetZ` / `_Negative`;
- `IA_Building_OffsetDistance` / `_Negative`;
- `IA_Building_FreePlacement`;
- `IA_Building_GhostPiece_Modifier`;
- `IA_Building_Cancel`;
- `IA_Building_Repair`;
- `IA_Building_QuickInteract`;
- `IA_Building_DestroyObject`.

The mapping contexts are `IMC_BuildingMode`, `IMC_BuildingGeneral` and `IMC_BuildingUI`. Which action **places** is **[UNVERIFIED]**. The guide says LMB ("Place / Quick Interact"), which is `IA_PrimaryAction` or `IA_Building_QuickInteract` inside `IMC_BuildingMode`. Probe P2 reads the IMC's mappings.

### Containers
`UInventoryUIAPI` has:
- `HandleDragAndDropToExternal(fromSlot, fromType, toSlot, UInventoryComponent*)`
- `HandleDragAndDropFromExternal(fromSlot, UInventoryComponent*, toSlot, toType)`
- `HandleExternalQuickTransfer`
- `HandleSplitToExternalSlot`
- `HandleTakeAllFromWorldInventory`

These are the container screen's own handlers (scalars plus object refs, no hand-built structs).

### Pieces in the dump
- `BUILDPIECE_Campfire`, `BUILDPIECE_Chest`, `BUILDPIECE_Chest_Small`, `BUILDPIECE_Chest_Iron`, `BUILDPIECE_PersonalChest`;
- `Structures/Crafting` (28: smelter, loom, armour bench, jewellery bench ...);
- `Furniture/Comfort` (66).

These are only the ones loaded on the server at dump time. Farm plot pieces are not in the loaded set **[UNVERIFIED name]**. They come from data at run time anyway.

## 2. Decision: the real player path

Do what the player does, in order:
1. Press B (`IA_BuildMenu`, injected like every other key: `EnhancedInputLocalPlayerSubsystem:InjectInputVectorForAction`, the shared helper spells.lua uses).
2. Click the piece in the menu (`BuildingUIAPI:CallOnBuildingItemSelected(data)`, the slot click's own call, exactly how inventory.lua uses `InventoryUIAPI` handlers).
3. Look at the spot (`SetControlRotation`, as move.lua and spells.lua aim).
4. Rotate with the rotate key (`IA_Building_RotateZ`, presses of `ModifyRotationStepDeg`).
5. Read the game's own preview: position and validity state.
6. Press place.
7. Verify from game state.

Rejected:
- **`Server_SpawnBuilding` / `TrySpawnPieceAtLocation`.** These are an RPC or a direct spawn with a hand-built `FTransform`, `TArray` and inventories. They break CLAUDE.md §0 ("never send hand-built structs in Client_*/Server_* RPCs", "no emulation of player systems").
  - `TrySpawnPieceAtLocation` stays a documented last resort only with Luis's approval.
  - `ForceEnterBuildMode` / `ExitAnyMode` are not used either: B and Cancel are what a player presses.

## 3. Tool contract (brain-facing, through the manifest)

```
build {piece, at?: [x,y,z] | id, near?: id | "me", rotation?: deg (0-360, world yaw), ghost?: false}
  async, arbiter level "command", moves = true, honours DW_PAUSE, cancel = leave build mode
  ok  {piece, piece_id, structure (actor id | null for a lightweight piece), position, rotation,
       spent {item: n}, xp {construction: +n}, validity: "Valid"}
  fail reasons (protocol codes; data.why = the game's state; data.detail = a speakable sentence, from
       ValidityNotificationTextMap when the game has words for it):
    unknown_target    why=unknown_piece (no unlocked piece matches; data.close = up to 3 names)
    locked            why=not_unlocked (data needs = what the game's unlock data says, when readable)
    missing_materials data.missing {item: n}; before any key press; also the game's MissingMaterials
    blocked           why=Overlapping|Floating|NeedsFoundation|NeedsSnapping|Unstable|WrongPhysicalSurface|
                          InsideVault|InsideProtectedArea|InsideBlockedRegion|ShelterCheckFailed,
                          data.tried = spots tried
    limit_reached     why=ReachedCountLimit
    too_far / path_blocked (approach), interrupted, timeout, verification_failed (pressed, valid, and
                          nothing appeared or nothing was spent)
buildables {about?, can_build_now?}   read-only: unlocked pieces from data (ProgressComponent.BuildingsUnlocked
       x DisplayName/Description/Category/Requirements) with have/missing per piece and the catalogue's own
       category labels (BuildPieceCatalogue pages). Feeds the needs digest like craft_plan.
```

Rules:
- `piece` is matched against the **game data**: `DisplayName`, the asset name (`BUILDPIECE_...`) and `Category`. There is no hand list and no phrase map; the brain picks from `buildables`.
- Positions are in metres on the wire, as for every other tool.
- `at` = the exact point (the preview must land within `match_m` = max(1 m, footprint/2)). `near` = anywhere within 6 m of the thing (spots chosen as below). With neither, the default is in front of me at 3 m.
- `ghost: true` places a ghost piece (`IA_Building_GhostPiece_Modifier` held). It is phase 2, so the manifest omits it until it is verified.

## 4. The state machine (`client_mod/scripts/build.lua`, a new module in `M.MODULES`)

It is the same shape as spells.lua's cast loop and skills.lua's episode. It reuses `W.inject`, the preview-loop idea, the spot ranking, `arbiter.request`, `api.counts` and `api.find_thing` (which resolves foliage and structures).

1. **preflight** (no key pressed):
   - resolve the piece from data;
   - check it is unlocked (`IsBuildingUnlocked` or membership in `BuildingsUnlocked`);
   - check `bOnlyAvailableToHost` (on a dedicated server: the host is nobody) **[UNVERIFIED semantics]**;
   - check materials (`Requirements` against hotbar+bag counts);
   - check the count limit (`PieceTagToMaxCountMap` against `GlobalBuildingManager.CounterComponent.TagsToCountsMap`).
   
   Each failure is a specific reason.
2. **spots**:
   - With `at`: the point first, then 8 points on a 1.5 m ring.
   - With `near`: a ring around the thing at footprint radius + 1 m, ranked by the shared downward traces (flatness, clearance) from spells.lua `W.spots`.
   - Never a spot containing my own capsule: spots within footprint + 0.6 m of me are skipped, and I stand off.
3. **approach**: `move.go_to` to a standing point 2.5 to 4 m from the spot (inside `MaxPlacementDistance` **[UNVERIFIED value]**), facing it.
4. **open**: inject `IA_BuildMenu`, then wait for `CurrentBuildMode == Selection` (1.5 s, two tries).
5. **select**: `CallOnBuildingItemSelected(data)`, then wait for `CurrentBuildMode == Placement`, `CurrentlyPlacingPieceData == data` and a preview actor (§1) to exist.
6. **aim** (per spot, at most 3 re-aims):
   - `SetControlRotation` toward the spot (pitch from eye height), then wait `preview_wait_s`.
   - Read the preview: position, and the validity state from (a) the last `OnValidityStateChange` seen by a hookhub post-hook, else (b) the MPC scalar `PlacingValidityStateIndexMPN` mapped back through `ValiditySpawnStateToScalarIndex`. Probe P4 decides which.
   - **Rotation:** press `IA_Building_RotateZ` n times, n = round(delta / ModifyRotationStepDeg) (read the preview yaw back).
7. **place**: only when the state is Valid and the preview is within `match_m` of the spot, press place (probe P2 decides which action). Otherwise use the state as the spot's verdict, keep it in `tried`, and move to the next spot.
8. **verify** (up to 6 s), success when ALL of these hold:
   - the inventory dropped by exactly `Requirements` (the authoritative sign: the server spent them);
   - AND one of:
     - a new non-preview `ABaseBuildingActor` whose `BuildingPieceData` is ours stands within 2 m of the preview point (`structure` = its id; stations and chests);
     - the Construction XP rose by `ConstructionXPOnBuild`;
     - the counter for the piece's tag rose (lightweight pieces such as walls may have no actor: `FLightweightBuildingPiece` / `UBuildingHISMC` **[UNVERIFIED]**).
   
   A `Client_ShowValidityNotification(state)` post-hook firing after the press means the server refused: report that state with the game's text.
9. **leave**: press `IA_Building_Cancel` until `CurrentBuildMode == None` (it also runs on cancel, failure and DW_PAUSE). After a success the game may stay in Placement for the next piece; we always leave, so nothing else reads a half-open mode.

Timeouts: the whole action takes about 60 s (approach included). The brain waits for the manifest's `timeout_s`.

### Perception that comes with it
- **`get_state.structures`** (today `not_implemented`): census rows of `ABaseBuildingActor` within the census radius, not previews. Fields: name (`DisplayName` / `GetBuildingName`), kind (station / storage / bed / ... from the existing families), `ghosted`, position, distance, and `mine` when `PlayerControllerManagingPlacement` or the building piece's state names my PC **[UNVERIFIED which field carries the owner]**.
- **`buildables`** (above) in the needs digest, as options with what's missing. This is how "build a chest" becomes a plan (gather planks → build) without phrase maps.

## 5. Containers: deposit and withdraw (small addition to `move_item`)

Today `move_item` is hotbar ↔ bag only. The addition:

```
move_item {item, count?, to: "container", container: id}     deposit
move_item {item, count?, from: id, to?: hotbar|bag}            withdraw
```

1. **interact** with the container. This uses the existing episode, which opens the container screen like E, verified by the UI's world inventory being set **[UNVERIFIED property: `InventoryUIAPI` world inventory / `ContainerAPI`]**.
2. **Transfer:**
   - a whole stack: `HandleDragAndDropToExternal(fromSlot, fromType, freeSlot, containerInv)` or `HandleDragAndDropFromExternal(...)`;
   - part of one: `HandleSplitToExternalSlot` / `HandleSplitToSlotFromExternal` with Amount.
3. **Verify:** both inventories' counts changed by `count` (`contents_of` already reads container `ItemSlots` safely under the DW_PAUSE rule).
4. **Close:** cancel the screen.

Reasons: `container_full`, `inventory_full`, `not_in_container`, `not_a_container`, plus the interact reasons. `inspect` already lists container contents. Crafting at his own stations already works: `craft` finds stations through the census, and a placed station is just another station.

## 6. Risks and how they are kept small

| Risk | Mitigation |
|---|---|
| Native crash in UI calls on a headless client (nullrhi) | Every call first in a read-only probe (§7), one at a time; `pcall` cannot catch native crashes, so the probes come before any loop |
| The build menu UI may not exist headless | P1 checks `HUDUISubsystem.BuildingAPI` and the panel; spells' wheel and inventory UI APIs work headless, so it is likely fine |
| Left in build mode after an error | Leave in every exit path; the bridge `busy`/restart rule (L20) waits for it; DW_PAUSE → leave |
| Placing where Luis walks / inside his base | `at`/`near` are the brain's choice; code never vetoes (Luis's rule), but spots that contain a player capsule are skipped as `Overlapping` before any press |
| Spending materials on a wrong piece | Preflight resolves one exact piece; ambiguity → `unknown_target` with `close` |
| Hooks | hookhub only (one native hook per UFunction, deferred until in world, no-op under DW_PAUSE) |
| Count limits / protected areas on dev vs Shockbyte | Read from data; dev only for now |

## 7. Live probes (dev only, one at a time, each read-only unless marked; client slot from main)

- **P1 (read):**
  - PC build components exist;
  - `CurrentBuildMode`;
  - `BuildingsUnlocked` count and names;
  - `HUDUISubsystem.BuildingAPI` valid;
  - `UBuildingSettings` CDO: `ModifyRotationStepDeg`, catalogue pages;
  - `BuildPlacementComponent.MaxPlacementDistance`;
  - `ValidityNotificationTextMap` texts.
- **P2 (read):** the mappings of `IMC_BuildingMode` / `IMC_BuildingGeneral` (`Mappings[].Action` / `Key`). This tells which action places.
- **P3 (acts, reversible):** press `IA_BuildMenu` → Selection, then `IA_Building_Cancel` → None.
- **P4 (acts, reversible):**
  1. select a cheap unlocked piece → Placement plus a preview actor;
  2. aim at flat ground and read the validity (hook vs MPC);
  3. aim into a rock and read Overlapping;
  4. cancel.
- **P5 (acts, spends materials, dev):** place one campfire or small chest (materials granted by the bench fixture on dev) → verify actor, spent and XP.
- **P6:** deposit 1 log into it, then withdraw it.

## 8. Tests (offline first)

- `client_mod/tests/test_build.lua`: a fake build world with:
  - a BuildModeComponent with modes;
  - a UIAPI whose select sets Placement;
  - a preview actor following the aim, with a scripted validity per spot;
  - the inventory and server spend;
  - an XP rise;
  - a counter;
  - `Client_ShowValidityNotification`.

  Cases:
  - happy path (actor, spent, xp);
  - missing materials before any press;
  - locked piece;
  - unknown piece with `close`;
  - Overlapping at the first spot → second spot;
  - every spot Floating → `blocked` with `tried`;
  - server refusal via notification → reason with the game text;
  - lightweight piece verified by spent+xp without an actor;
  - rotation presses = round(delta/step);
  - cancel/DW_PAUSE → leaves build mode;
  - never presses place on an invalid preview;
  - always leaves the mode.
- `test_client_bridge.lua`: `buildables` and `get_state.structures` shapes.
- `test_skills.lua`: deposit/withdraw with fake container inventories (full, partial, not a container).
- Manifest contract: `brain/capabilities.py` picks up `build` / `buildables` from the manifest (no brain code beyond the existing generic path).
- A small real-model eval after live verification (about 10 Haiku calls, stated first): "build a chest by the campfire", "put the logs in the chest", "make me a workbench", with the state lacking materials → the model gathers or says what's missing.

## Search record

| Question | Source | Finding | Used how |
|---|---|---|---|
| How does the game itself model building? | Reflection dump 26161880 (`Dominion.hpp` l.8895, 16098-16560, 31245; `Dominion_enums.hpp` EValiditySpawnState/EBuildMode) | Build mode component with modes; a UI API whose slot click selects a piece; a preview actor; a validity enum with 13 reasons and the game's own texts; unlocks in ProgressComponent; container drag-drop handlers | The whole design: real handlers and inputs, data-driven pieces, truthful reasons |
| Which keys does a player use? | BisectHosting controls guide, https://www.bisecthosting.com/blog/runescape-dragonwilds-controls-guide-keyboard-mouse-gamepad-controller ; MagicGameWorld controls, https://www.magicgameworld.com/?p=148196 | B opens the build menu; LMB places / quick-interacts; Q/E switch tabs; Y free placement; Esc cancels; MMB destroys; T repairs (rotate not listed) | IA_BuildMenu to open, the place action probe (P2), IA_Building_Cancel to leave |
| How do LLM agents place blocks? | Mindcraft `skills.js placeBlock`, https://github.com/mindcraft-bots/mindcraft/blob/main/src/agent/library/skills.js | Picks a supporting face, walks within reach, looks, places; success is "no exception", with no re-read of the world (its own comment says errors happen even when placed) | Lesson: verify from game state (spent + actor/xp), never from "the call returned" |
| | Voyager `placeItem.js`, https://raw.githubusercontent.com/MineDojo/Voyager/main/voyager/control_primitives/placeItem.js | Refuses floating placement up front ("You cannot place a floating block"), verifies by the inventory count changing, caps retries (10) and tells the model to pick another position | Inventory-spent check as primary evidence; a bounded spot list with per-spot reasons; failures name the next step |
| Do UE4SS / community mods drive Dragonwilds building? | Shockbyte UE4SS mod guide, https://shockbyte.com/nl/help/knowledgebase/articles/how-to-add-mods-to-your-runescape-dragonwilds-server ; web search for building mods (none found) | No public mod automates building; UE4SS mods are installed client- or server-side | Nothing to reuse; we build the state machine on our own verified helpers |
| Input injection precedent | spells.lua (prior art header: Epic `InjectInputVectorForAction`), combat IA_PrimaryAction, inventory IA_Interact (DISCOVERIES) | Verified live for spells/combat/interact | Reuse `W.inject` (move it to a shared helper module) |

**Choice: adapt** our own verified pieces (injection helper, preview loop, spot ranking, the episode and arbiter, inventory UI handlers) and **build** `build.lua`'s state machine. There is no external library to reuse.

## 9. Open questions for the reviewer

1. Is `CallOnBuildingItemSelected` the right "click" path, or should selection go through the menu widget, i.e. `UBuildingUISlotBase` on the build panel (closer to the pixels, but needs widget lookup headless)?
2. Validity: hook `OnValidityStateChange` (an event per change) or the MPC scalar (polling, no hook)? Both are read-only.
3. Should `build` leave build mode after success, or stay for "build 4 walls" (one tool call per piece; leaving costs about 1 s per piece)? The proposal is to leave, and maybe add `count`/`pattern` later as a compound.
4. Farm plots may be "pieces" or items placed by another path (the Farming unlock is `ProgressComponent.bFarmingUnlocked`). That needs P1 data before promising them.

## Rev 2 (2026-10-26): after the review (`docs/reviews/2026-10-26-build-primitive-review.md`) and live P1a/P1b

**Built (offline, tests green, not deployed):**
- **`client_mod/scripts/input.lua`**: the shared input layer and **modal gate** (finding 4). `gate()` blocks gameplay input while:
  - build mode is open (`CurrentBuildMode ~= None`);
  - a world-inventory screen is open;
  - the PC's input mode is not `DIM_Gameplay` (spell wheel/placement, `DIM_OculusBuildMenu`);
  - or `DW_PAUSE` is set.

  Owners use `claim`/`release`. An orphan build mode or chest screen is cleaned up after 1 s (Cancel or `CloseCurrentInventory`, one step per second, at most 3, then reported `stuck`). Input modes are never auto-exited. Handles are cached.
  - **Adopted by combat** (combat agent: every combat inject is gated; test_combat 182/182).
  - Tests: `client_mod/tests/test_input.lua` (17).
- **store / take** (`skills.lua`, finding 14): separate **action** tools (`kind = action`, `moves = true`), replacing the `move_item` overload. Each one:
  - checks the OpenChests privilege, then opens the container with the shared episode (verified by "this container's screen is open", a new generic `W.press_signals.container` signal that interact also reports as `changed = "opened"`);
  - moves one stack per press through the screen's own handlers (`inventory.to_external` / `from_external`, shared helpers that crafting's code path also uses), verified on both sides;
  - closes the screen on every exit path, claimed in input.lua. A reflex pre-empt closes it at once, and on resume it reopens.

  Tests: test_skills store/take ×5.
- **`buildables`** (`build.lua`):
  - unlocked pieces from `ProgressComponent.BuildingsUnlocked` (deduplicated, per P1a);
  - static data cached per session (finding 11);
  - cost and missing in crafting's row shape; advisory `in_storage` from nearby chests (finding 3);
  - privileges Build/Owner and `host_only` (findings 1–2); never matches on Category (finding 15).

  Tests: `client_mod/tests/test_build.lua` (13).
- **`brain/interface.py` Reason:** `no_permission`, `host_only`, `limit_reached`, `blocked`, `not_a_container`, `not_in_container` and `container_full`, all DETERMINISTIC (finding 16).
- **Bridge:** modules `input`, `build` and `fishing` are registered. `M.is_action_tool` takes action tools from module manifests (`kind = action`, `moves = true`).

**Live P1a/P1b results that change the design** (details in DISCOVERIES "Build probes P1a/P1b"):
- **`ValiditySpawnStateToScalarIndex` is a 3-colour index, not the state.**
  - Valid and NeedsSnapping both map to 2.
  - Most invalid states map to 1.
  - WrongPhysicalSurface and None map to 0.

  So the review's Q2 answer (poll the MPC as the source of truth) cannot authorise a press. **Proposal:** the exact state comes from the `OnValidityStateChange` (BuildModeComponent) / `OnValiditySpawnStateChanged` (preview actor) post-hook, recorded with a sequence number. Press place only when:
  - (a) the hook's last state is Valid,
  - (b) it was received after the latest aim change, and
  - (c) the MPC poll agrees (scalar 2).

  If the hook never fires after selection (deferred registration), re-aim once to force a change. Still nothing → `verification_failed why=preview_unreadable`, and no press. P4a/P4b test exactly this (MPC read first, then the hook).
- **Facts from P1a/P1b:**
  - reach 700 cm from the camera, plus 350 distance and 300 height modifiers;
  - rotation step 15° (rotation via `IA_Building_RotateZ`);
  - `MinTimeBetweenBuildingPlacementRequests` 0.25 s;
  - the client counter map is empty, so count limits are advisory only (finding 19);
  - Category reads "None" for Campfire and Crafting Table, so it gives no useful grouping;
  - the catalogue asset is loaded (category labels can come from its pages later).
- **Unlocked on dev:** only Crafting Table (4 Ash Logs), Campfire (6 Stone, "Must Be Exposed"), Bedroll, a host-only Protection Totem and decorations. P5 will place a **Campfire** (6 Stone, granted by the bench fixture as harness setup).

**Still to build:**
- `placement.lua` (finding 13: spots, aim, check loop, rejects, with an injected reader and press; the spells agent migrates spells.lua to it);
- the `build` action (findings 5–9, 15–19 and §21 tests);
- probes P2 → P6, one at a time, with the client slot.

### Search record additions (review finding 17)

| Source | Finding | Used how |
|---|---|---|
| Game wiki Build Menu, https://dragonwilds.runescape.wiki/w/Build_Menu, and gamever's category list, https://gamever.io/knowledge-base/the-dragonwilds-build-menu-every-structure-category-and-what-you-unlock | B opens the menu; pieces unlock through progression (Vault Cores); there is a Farming group under Crafting | Farm plots are ordinary pieces when unlocked: no special case; unlocks are the Director's job, not a fixture |
| In-repo: crafting.lua external-inventory transfer (`HandleSplitToExternalSlot` / `HandleExternalQuickTransfer`), its close-on-every-exit, DISCOVERIES l.677 (linked inventories: player + nearby chests as `AvailableInventories`), l.746 (privileges via `PrivilegeComponent:HasPrivilege`) | The transfer path, the linked-storage rule and the privilege read already existed | store/take use the shared inventory helpers; buildables/build count storage (advisory) and verify the spend across it; privilege preflights |
| mineflayer-builder (PrismarineJS), https://github.com/PrismarineJS/mineflayer-builder | A blueprint-driven multi-block builder over a single place primitive | Deferred: a future "build from blueprint" compound (Phase 7 place) composes `build` calls with `near: <previous piece>` |
