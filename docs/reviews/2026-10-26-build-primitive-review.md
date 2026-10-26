# Review: `docs/design/build-primitive.md` (build/place + container deposit/withdraw), 2026-10-26

Reviewer: a fresh-context agent. I did not write the note. I reviewed it before any code was written.

**Read:**
- `docs/design/PRINCIPLES.md`, CLAUDE.md §0, ARCHITECTURE §7 (risk register);
- `docs/design/client-spells.md`;
- `client_mod/scripts/spells.lua` (`W.inject`, `W.aim`, `W.preview`, `W.spots`, the `place_check` loop);
- `skills.lua` (the interact episode, `move_item`), `inventory.lua` (`move`, `drop`, UI API), `crafting.lua` (open station, external transfer, close);
- `arbiter.lua`, `hookhub.lua`, `client_bridge.lua` `contents_of`, `brain/interface.py` `Reason`;
- `dumps/26161880` `Dominion.hpp` l.8895, 16098-16600, 17770, 17975-17990, 25061-25116, 30856, 31245-31340, 37195, `Dominion_enums.hpp`, and the object dump (IA_Building_* and their modifiers).

**Also searched (web):**
- dragonwilds.runescape.wiki/w/Build_Menu;
- gamever.io build-menu categories;
- hostedgg base-building guide;
- xgamingserver admin and roles guides.

## Verdict: APPROVE WITH CHANGES

The core is right:
- B to open, then the menu's own `CallOnBuildingItemSelected`, aim, the game's own validity, then the real place input;
- verification from game state;
- `Server_SpawnBuilding` / `TrySpawnPieceAtLocation` rightly rejected;
- pieces read from game data.

Four things must change before code:
1. The note misses two game rules the dump shows and the repo already knows:
   - **build/chest privileges** (findings 1–2);
   - **materials from linked storage** (finding 3).
2. There is a **stray-input hazard**: a reflex's attack click can place a piece while build mode is open (finding 4).
3. The note **duplicates** spells' preview loop and crafting's container transfer instead of sharing them (findings 13–14).

## Answers to the note's open questions

**Q1. `CallOnBuildingItemSelected` or the slot widget?** Use `BuildingUIAPI:CallOnBuildingItemSelected(data)`.
- **Why:** it is the same layer as the `InventoryUIAPI` / `CraftingUIAPI` handlers that inventory.lua and crafting.lua already drive and that review accepted. The slot widget (`UBuildingUISlotBase.OnSlotSelected`, which holds `ContainedItemDataRow`) needs a headless widget lookup and adds nothing a player decides.
- **Two conditions:**
  - (a) Call it only while `CurrentBuildMode == Selection` (the menu is open, as a player's click would be).
  - (b) Treat the API as possibly unguarded. `UBuildingUIAPI` holds `ProgressComponent` but may not re-check unlocks, host-only status or privileges, so the preflight gates in finding 1 must hold first.
- **Optional read-only cross-check in P4:** confirm that a `UBuildingUISlotBase` whose `ContainedItemDataRow == data` exists on the open panel. That proves the menu actually offers the piece. If no panel exists headless, skip the check; it must not become a dependency.

**Q2. Validity: hook `OnValidityStateChange` or the MPC scalar?** **Poll the MPC as the source of truth, and use the hook only as corroboration.**
- **Why poll:** an event hook only says "it changed".
  - The first state after select can fire before hookhub's deferred native registration, and then it is never seen.
  - A "last seen" value goes stale across re-aims, spots and pieces.
  - The place decision needs the **current** state each check, which only a poll gives.
- **How to poll:** `UKismetMaterialLibrary:GetScalarParameterValue(world, BuildModeComponent.MaterialParameterCollection, PlacingValidityStateIndexMPN)`, mapped back through `ValiditySpawnStateToScalarIndex`. Read that TMap once and cache it.
- **The same MPC gives the preview position:** `CursorWorldPositionMPN` is a vector parameter. If the preview is not an `ABaseBuildingActor`, which is possible (finding 9), it is the only position source.
- **When to press place:** only when a poll **after the latest aim change** reads Valid. The `OnValidityStateChange` post-hook (hookhub, one native hook, never unregistered) may make a check sooner but may never authorise a press on its own.
- **Probe order:** test the MPC read first (P4a), and register the hook only after it (P4b).

**Q3. Leave build mode after success, or stay?** Leave, as proposed.
- One `build` call per piece. The model composes "4 walls" as 4 calls, using `near: <previous piece id>` so snapping works.
- The ~1 s spent leaving and reopening is small next to the model's own turn latency.
- A `count`/`pattern` compound is justified under PRINCIPLES 4b only if a measured live run shows the reopen cost matters. Leaving also keeps the mode from leaking into other skills (finding 4).

**Q4. Farm plots.** The wiki/gamever menu lists a **Farming** group under Crafting in the Build Menu, so plots are very likely ordinary build pieces. They would then appear in `buildables` with no code change.
- The dump shows that working a plot is another system:
  - `UFarmSlotComponent` (a scene component with its own `UFarmPlotInteractionComponent`);
  - `UFarmCommandComponent::Server_TryTillPlot / PlantSeed / ApplyWateringCharges / HarvestPlot`.
- Those are Server RPCs and must never be called. Tilling, planting, watering and harvesting have to go through interact/use on the slot as a later primitive.
- So: promise nothing until P1 lists the pieces; add no farm special-case; `buildables` shows plots if the data has them. `bFarmingUnlocked` is just one more unlock fact to report.

## Checks requested

1. **Real player inputs and UI handlers?** Mostly yes: B, the menu API select, `SetControlRotation`, the rotate key, the place key, Cancel, and the container UI drag handlers. There are no `Server_*` calls and nothing is emulated. Two gaps:
   - The note must state that the build loop **never** copies spells' "no readable preview → place on our own spot once" fallback (`spells.lua` ~l.1318). For building, no readable Valid means **no press** (finding 8).
   - The rejected `ForceEnterBuildMode`/`ExitAnyMode` stay rejected; finding 4 solves the safety case without them.
2. **Validity and verification from the game?** The intent is right, but three signals are unsound as written:
   - "spent exactly Requirements" from my own bag ignores linked storage (finding 3);
   - "XP rose by `ConstructionXPOnBuild`" assumes no multipliers (XP goes through `BuildXpEvent`);
   - "the counter rose" depends on the counter reaching the client.

   A server-sent signal is missing: `BuildModeComponent:Client_TelemetryOnBuildingPieceComplete(bWasPreviouslyGhosted, index)` (finding 6).
3. **Crash risks and probe order:** see findings 10–12. P1→P6 is ordered safest first in spirit. P1 should be split (scalar/object reads, then TMap/struct-array reads one per call), and P4 split (MPC before hook).
4. **Generic?** Yes, with two fixes: ambiguity handling and the `Category` match (finding 15). There are no per-piece lists.
5. **Failure reasons:** good use of `ValidityNotificationTextMap`. Missing: `no_permission`, `ambiguous_target` and the per-piece shelter text. Some codes are outside `brain/interface.py` `Reason` and would be retried blindly (finding 16).
6. **Shared with the spell preview loop?** No. "Reuse the preview-loop idea" means copying ~150 lines of `place_check`. Extract a shared module (finding 13). The container part ignores crafting.lua's existing external-inventory code (finding 14).
7. **Search record:** adequate on external prior art. It misses the game wiki's Build Menu page and the in-repo precedent that would have surfaced findings 1–3 (finding 17).

## Findings (numbered; **M** = must fix before code, **S** = should, **N** = nit)

1. **M: Build privilege.** `EPlayerPrivilege` has `Build = 2` and `OpenChests = 4`. The privilege lives in `PlayerState.PrivilegeComponent:HasPrivilege(p)`, which is already used live for Chat (8) (DISCOVERIES l.746). On a server where Claude's account lacks Build, every press fails with no reason the note can name.
   - Preflight `HasPrivilege(2)` for `build`, and `HasPrivilege(4)` for container transfers.
   - New reason `no_permission`, with detail such as "The server hasn't given me building rights, so I can't place anything here."
   - Add both reads to P1.
2. **M: `bOnlyAvailableToHost` on a dedicated server.** Read it together with `HasPrivilege(128 /*Owner*/)` rather than assuming "the host is nobody". Report `host_only` (or `no_permission` with `why=host_only`). Mark it [UNVERIFIED] until P1 shows such a piece.
3. **M: Materials come from linked storage too.** DISCOVERIES (crafting, l.677) shows the game passes `GetLinkedInventories(...)` (player inventory plus nearby chests) as `AvailableInventories`; `Server_SpawnBuilding` takes the same parameter. Consequences:
   - (a) A bag-only `missing_materials` preflight would wrongly refuse a build the game allows. Make it **advisory**: report have/missing from own and nearby-container counts (read-only `contents_of`). The blocking verdict comes from the game's preview state 6, `MissingMaterials`.
   - (b) Verification must sum the drop across own and linked inventories, require "each requirement item fell", and report the actual `spent` (with `from` when a container paid).
   - Do **not** call `GetLinkedInventories` from Lua: it takes and returns `TArray<UInventoryComponent*>` (R3/R15 marshalling).
   - This also keeps the "shared stations/items" rule: report what was used from whose chest.
4. **M: Stray input while build mode is open.** In Placement the place action is LMB (`IA_PrimaryAction` or `IA_Building_QuickInteract`, P2). `build` runs at level "command", so a defence reflex (level 4) pre-empts it and starts injecting `IA_PrimaryAction`. That click can **place the selected piece at wherever the camera points and spend materials**.
   - The same applies to the stay-fed reflex using items while the container screen is open.
   - Required: the build owner's `on_suspend`/`on_stop` leaves the mode at once. Then add one generic rule in the input layer, shared by combat, defence and inventory reflexes: **no gameplay input injection while `BuildModeComponent.CurrentBuildMode ~= None` or a world-inventory screen is open**; wait at most 1 s for the owner's cleanup.
   - Add a test: a reflex pre-empts during Placement, and place is never pressed by combat.
5. **M: `DW_PAUSE` contradiction.** §4 step 9 says "DW_PAUSE → leave (press Cancel)", but the pause rule (spells rev 2, hookhub, crafting) is **no game calls under DW_PAUSE**.
   - Under pause: drop the job without input.
   - On the next unpaused tick: one generic check in build.lua's service. If `CurrentBuildMode ~= None` and no build job runs, leave the mode (Cancel, read back, bounded).
   - Do the same for a leftover world-inventory screen (`WorldActorInventoryUIAPI:CloseCurrentInventory`).
6. **S: Verification signals.**
   - Primary: (each requirement fell in own+linked) **and** one of:
     - the `Client_TelemetryOnBuildingPieceComplete(…, index == data.BuildingPieceDataIndex)` post-hook (a Client RPC the server sends; read-only, like `Client_NotifySpellOnCooldown`; P5 confirms it is sent in shipping);
     - a new non-preview building actor of our data near the point;
     - Construction XP **rose** (any amount; report the delta; don't require `== ConstructionXPOnBuild`).
   - Use the counter only if P5 shows `GlobalBuildingManager.CounterComponent` replicates to clients.
   - A `Client_ShowValidityNotification` after the press means refused, as written. Also read `UBuildInteractionComponent.MinTimeBetweenBuildingPlacementRequests` and never press place twice inside it.
   - Reuse spells' L25 settle poll: spend and XP replicate separately and late.
7. **S: Toggle-safe open/leave.** `OnToggleBuildModeInput(HeldDuration)` means B **toggles**, so the "two tries" in step 4 can close a menu that was only slow to show. Press B again only after re-reading `CurrentBuildMode == None`. Leaving is likewise bounded (≤3 Cancels, each followed by a read): Cancel may go Placement → Selection → None. Inject IA_BuildMenu as a single-frame press so it stays a short tap (`HeldDuration` small).
8. **S: Never place blind.** Press place only when the polled state is Valid and the preview position is within `match_m`. "No readable preview/state" → `verification_failed`, `why=preview_unreadable` ("I can't see the building preview, so I didn't place anything"). Unlike spells, a wrong placement spends materials and leaves a structure behind.
9. **S: The preview may not be an actor.** `FLightweightBuildingPiece` has its own `bIsPreview`, and pieces may live as Mass/HISM instances (`bAllowLightweightRepresentation`, `ULightweightBuildingPieceManager`). P4 must find out which. Until then the design needs the MPC fallbacks for position (`CursorWorldPositionMPN`) and validity. Rotation read-back may then be impossible: report `rotation_verified=false` rather than trusting presses × `ModifyRotationStepDeg`. Note: `IA_Building_RotateZ` has a `DominionPulseInputModifier`, so one injected frame = one step is itself [UNVERIFIED]; P4 should test one press and read the yaw back.
10. **M (crash and perf): Don't scan building actors per check.**
    - `W.preview` does `find_all` each poll. For buildings, `find_all("BaseBuildingActor")` on a real base (Shockbyte later) is hundreds of objects per 0.35 s check, plus R5 zombies.
    - Find the preview once after select, cache it, and re-validate it (`U.valid`) each tick. Or use the MPC.
    - `get_state.structures` must be census-radius-limited and capped, refreshed at most every few seconds, never per frame.
    - Lightweight pieces have no actor. Do not walk `GlobalBuildingManager.BuildingPieces` (a large TMap of structs) per state; it is a P1b read-once probe at most.
11. **M (crash): Read TMaps, struct arrays and soft refs once, then cache.**
    - New reads: TMaps `ValidityNotificationTextMap` (enum → FText), `ValiditySpawnStateToScalarIndex`, `PieceTagToMaxCountMap` / `TagsToCountsMap` (FGameplayTag keys, a new key type for us), and `Requirements` (a TArray of structs) per piece.
    - Read each once per session, or per piece as static data (spells' `W.static` + `STATIC_V` pattern), with the owner validated in the same tick and never under pause (the `contents_of` 21:49:34 lesson).
    - Soft pointers (`BuildPieceCatalogueRef`, `DerivedData`, `BuildableActor`, `ConstructionSkillData`) must **not** be loaded (R9). Use only already-loaded objects. If the catalogue is not loaded, `buildables` omits category labels and says so.
    - `buildables` in the needs digest must use the cache, not re-read every unlocked piece per digest.
12. **S: Probe order.**
    - P1a (object/scalar reads: components, modes, privileges, `BuildingsUnlocked` names, settings scalars).
    - P1b (one TMap or struct-array read per call: the texts map, the scalar-index map, the count maps, one piece's `Requirements`).
    - P2 (IMC mappings, already done for spells).
    - P3 (B / Cancel, with mode read-back between presses).
    - P4a (select + MPC poll + preview discovery), then P4b (register the validity hook).
    - P5 (place; logged as harness `setup` when the fixture grants materials; the bench fixture is approved dev-only rig use, not companion behaviour).
    - P6 (deposit, then withdraw).
    - Each probe is gated on the previous one passing, one at a time, with main's slot.
13. **M (sharing): Extract the placement loop instead of copying it.** Move spells' `place_check` mechanics into a shared module, e.g. `client_mod/scripts/placement.lua`:
    - candidate spots (`W.spots`, parameterised by footprint radius instead of the fixed 1.5 m 3×3, and by the standoff);
    - `aim`;
    - the check loop (wait, read the preview, match distance, re-aim up to N, reject with the game's reason, next spot, budget);
    - the `rejects`/`tried` record;
    - `give_up` with a far-flat-spot hint.

    The preview reader and the place press are injected: spells pass `UtilitySpellPlacementVisualizer`; build passes the MPC/preview-actor reader with "unreadable = no press". Also move `W.inject` and the settle poll into it, or into a small `input.lua`. spells.lua then calls the module; its tests must stay green (a refactor with no behaviour change, done first in its own commit).
14. **M (sharing and 4b): Containers reuse crafting.lua, and become their own action.**
    - crafting.lua already does what §5 describes:
      - open via the interact episode and read the UI API's open object (`W.open_station`);
      - transfer into an external inventory (`W.move_into`, `HandleSplitToExternalSlot`);
      - collect (`HandleExternalQuickTransfer`);
      - close on every exit path, and never under pause.
    - Lift those into a shared helper used by both.
    - The open-state property the note marks [UNVERIFIED] is in the dump: `UWorldActorInventoryUIAPI.InventoryComponent` (with `SetInventory`/`ToggleInventory`/`CloseCurrentInventory`), and `UContainerUIAPI.CurrentContainer` + `UIActionsAllowed`. P1 should read which one is set after E on a chest.
    - Two contract problems to fix:
      - (a) `move_item` is a manifest **waiter** (`moves = false`, no pawn). Deposit/withdraw needs approach + open + transfer + close, and the open screen is modal state that must not leak (finding 4). Per 4b that is a legitimate coupled compound, but it must be **one separate action tool** (e.g. `store {item, count?, container}` / `take {item, count?, container}`, or one `transfer` tool with a direction), `kind = "action"`, `moves = true`. Don't overload a waiter.
      - (b) The current interact episode verifies a press by inventory gain, sleep or prompt change. It would report `verification_failed` for "a chest opened". Add "a world inventory is now open, and it is this container's" as a generic press signal in `W.press_signals`.
    - Report the gain from a shared chest (§0 shared-items rule).
15. **S: Piece resolution.** Follow spells rev 2 and crafting:
    - exact DisplayName/asset (case-insensitive) first;
    - then a unique typo match;
    - else `unknown_target` (with `close`) or **`ambiguous_target` with `candidates`**.

    Do not match on `Category` (a gameplay tag such as Storage or Crafting). "build a chest" would then match every storage piece; Category belongs in `buildables` as information for the model, not as a resolver key. Never spend materials on a guess.
16. **S: Reason vocabulary.**
    - `locked` → use the existing `not_unlocked` (combat, crafting and spells already do).
    - Use crafting's `missing` row shape `{item, name, need, have}`, not `{item: n}`.
    - `blocked`, `limit_reached`, `no_permission`, `host_only`, `container_full`, `not_a_container` and `not_in_container` are not in `brain/interface.py Reason`, so the executor treats them as transient and retries blindly. Add them to `Reason`: `limit_reached`, `no_permission`, `host_only`, `not_a_container` and `not_in_container` in `DETERMINISTIC`; `blocked` and `container_full` too (the model picks another spot or container). Reuse `inventory_full`.
    - Speech details:
      - for `ShelterCheckFailed`, use the piece's own `ShelterRequirementText`;
      - for `blocked`, name the commonest game reason across `tried` ("every spot I tried here needs a foundation");
      - for `not_unlocked`, give whatever unlock data is readable (Vault Core per the wiki, via the `DT_Progression_*` rows crafting already reads), else say plainly that the unlock condition is unknown;
      - no raw ids in details (spells L26).
    - Reflex pre-emption: `interrupted` with `why`, e.g. "a wolf attacked me, so I put the build away".
17. **S: Search record gaps.** Add:
    - (a) the game wiki's Build_Menu page (https://dragonwilds.runescape.wiki/w/Build_Menu: B, unlocks via Vault Cores, the Farming group) and gamever's category list;
    - (b) the in-repo precedent: crafting.lua's external-inventory transfer and close-on-every-exit, DISCOVERIES l.677 (linked inventories) and l.746 (privileges);
    - (c) mineflayer-builder (PrismarineJS) as the precedent for any future multi-piece blueprint compound (Phase 7 "place"), noted as deferred.

    The Mindcraft/Voyager lessons are well used.
18. **S: Standoff vs footprint.** "Stand 2.5–4 m from the spot" puts Claude inside large footprints (foundations, a house), which the game then reports as `Overlapping` on every spot. Use standoff = max(2.5 m, footprint radius + 1 m). If that exceeds the camera-to-preview reach (`MaxPlacementDistance`, measured from the **camera** as spells does), fail with `too_far` ("that piece is too big to place from where I can stand"). The footprint comes from the loaded `DerivedData` if present, else a conservative default refined from the preview's `BuildingPieceLocalBounds` after select.
19. **S: Count limit and player-in-spot are advisory, in our own words.**
    - Preflight count limits read settings plus a counter that may not reach the client. Pre-checks that might be stale never block (spells rev 2); the game's `ReachedCountLimit` state decides.
    - Skipping a spot because a player stands there is fine, but record it as our own `why=player_in_spot`, never as the game's `Overlapping`.
20. **N: Things to state explicitly.**
    - `rotation` is world yaw; with Basic/Advanced snapping the game may override it, and the reply reports the actual yaw (or `rotation_verified=false`).
    - `structures.mine` stays [UNVERIFIED]; omit it rather than guess from `PlayerControllerManagingPlacement`, which is likely set on previews only.
    - "Dev only, never Shockbyte" for `build`: enabling it on the group world needs Luis's explicit OK (it changes their save) and finding 1's privilege.
    - `ghost` stays out of the manifest until verified. Completing a ghost later is a separate "donate" interaction (`EBuildInteractionType.Donation`) through interact, never `Server_Interact`.
21. **N: Tests to add** (on top of §8):
    - a reflex pre-empts during Placement, and no place press occurs (finding 4);
    - pause during Placement → no calls, then leave on resume (finding 5);
    - B pressed while already open is not re-pressed (finding 7);
    - unreadable preview → no press (finding 8);
    - materials in a linked chest: the preflight is advisory, and the spend is verified across own and chest (finding 3);
    - no Build privilege → `no_permission` with no key press (finding 1);
    - an ambiguous piece name → `ambiguous_target` (finding 15);
    - the spells suite stays green after the placement extraction (finding 13);
    - the container action closes the screen on every exit (finding 14).

## Sources (web)
- https://dragonwilds.runescape.wiki/w/Build_Menu
- https://gamever.io/knowledge-base/the-dragonwilds-build-menu-every-structure-category-and-what-you-unlock
- https://hostedgg.com/blog/runescape-dragonwilds-base-building-guide
- https://xgamingserver.com/blog/runescape-dragonwilds-server-admin-guide/ (roles; it does not cover build rights, so the privilege facts come from the dump and DISCOVERIES)
