# Vault reads: what a player's client can read about a Dragonkin vault (2026-11-17)

For the developer who builds the vault probes and, later, the perception of a vault. Not for the companion: nothing here goes into a prompt, a tool description or a recipe. This is perception only. It never tells him what to do with a lever. Offline research. Nothing was run against the server, the client or the brain, no model was called, and no file other than this one was edited.

Builds on `docs/research/2026-11-17-vault-capstone.md` (called "the capstone note" below).

## Searched

- Dump `dumps/26574459/`: `CXXHeaderDump/Dominion.hpp`, `Dominion_enums.hpp`, `Dungeon.hpp`, the BP headers (`BP_BinaryLever.hpp`, `BP_FinalDoor_vault_Refactored.hpp`, `BP_SwitchableDoor_Vault_4x4.hpp`, `BP_InteractablePlayerTeleporter*.hpp`, `BP_Seal_Switchable.hpp`), and `UE4SS_ObjectDump.txt` (instances). This dump was made on the **dev server** after the 26574459 update (`docs/PROGRESS.md` l. 943). It is not a client dump. No `.usmap` was found in the folder.
- Repo: `docs/DISCOVERIES.md` (door, lever, switch, teleport, dungeon, vault, instance, KillZ, Unstuck, LoadMap), `docs/ARCHITECTURE.md` section 7, `docs/BUGS.md` L37 and L40, `client_mod/scripts/sense.lua`, `client_bridge.lua` (look, inspect, interact, pause, travel hook), `lodestone.lua`, `places.lua`, `hookhub.lua`, `mod/body/util.lua` (`U.prop`), `client_mod/commands/places_dump.lua`, `data/places_26161880.json`.
- Web: the live wiki pages for Crasorak Kara and Vertentis Kara (2026-11-17); the UE4SS `RegisterHook` page; one search for Dragonwilds UE4SS mods that touch vaults, doors or levers.
- **Found nothing for:** any Dragonwilds mod (Nexus, CurseForge, GitHub) that reads or changes vault doors, levers or teleporters. CurseForge lists only cosmetic mods (NoVignette, a blueprint loader). Nothing in the repo reads `ASwitchBase`, `ASwitchableDoor`, `ASwitchableTrap`, `ADungeon`, `AGameplayObjectRegistry.Dungeons` or `ChestState` (grep of `client_mod`, `mod`, `brain`, `tools`). No vault class instance (chest, trap, creature) is in the server dump, because no player stood near a vault when it was made.

## 1. What is there

### 1.1 What the player meets, from the wiki

| | Crasorak Kara (Temple Woods) | Vertentis Kara (Whispering Swamp) |
|---|---|---|
| Entrance | A door outside. Inside: "Right side, locked boss door; Left side stairs to the rest of the dungeon" | The "blue-flame door" (capstone note). The live page describes no door. A Law anima vent at the entrance |
| Levers | 1. At the top of the barred stairs, "to open the final door" (the boss door). 2. In the fork room, optional: "pull it to open a gate that is past the fire traps". 3. Past the second core, reached with Windstep: "a lever which you can pull to open a shortcut" | A "lever room" on the route. No count given |
| Traps | 3 fire traps in the south hall ("Watch for fire, it burns"), 2 more on the optional path; spike rooms laid out in a diamond, with "a safe zone in the middle" | "Spikes in the water" |
| Chests | 4 (infobox). The walkthrough places more, including one after the boss | 1 listed ("Chest (Vertentis Kara)") |
| Vault cores | 3: by the dragonkin statue, in the Windstep area, after the boss. 50 kg each | 3: in the boss room, up the stairs opposite it, at the far end in the water |
| Boss | Vault Overlord, behind the door the main lever opens. The page does not say what starts the fight | Rat King, in the "rat boss room". No trigger described |

No page or guide mentions a loading screen. Wiki update 0.8.1 mentions "fade-in transitions" (capstone note l. 56).

### 1.2 The game's classes for each piece

Sure = the property exists in the dump and its meaning follows from its name and type, or from an enum. Guess = which class a vault actually uses is inferred, not seen.

| piece | class (dump line) | state properties (offset) | instances in the server dump | sure? |
|---|---|---|---|---|
| **Vault as a place** | `ADungeon : AActor` (Dominion.hpp 10714) | `BoxComponent` (the interior box), `DungeonUserVisibleName` FText, `DungeonEntrance` / `DungeonExit` soft actor refs, `DungeonTag`, `bNeedsToBeDiscovered`, `bIsDungeonUnsafeArea` (0x2C0 to 0x350) | **17** (`Dungeon_UAID_...`, object dump l. 276764 on) | Class and fields: sure. That one is a vault: strong inference (17 is near 10 vaults plus their sub-areas, and the name field is "user visible") |
| Vault registry | `AGameplayObjectRegistry.Dungeons` `TArray<FDungeonData>` (Dominion.hpp 11009); `FDungeonData` (2848): `Box` FBox, `EntranceLocation`, `ExitLocation`, `UserVisibleName`, `Identifier` FGuid, `DungeonTag`, `bIsDungeonUnsafeArea` | as listed | 1 registry | Sure that it exists. Whether it is replicated to the client: **unknown**. Its neighbour `Landmarks` (no OnRep either) is read on the client today (`places.lua` l. 134-148) |
| **"Am I inside a vault"** | `ULocalPlayerAudioSubsystem.bInDungeon` (Dominion.hpp 26506), a local-player subsystem of a **native** class | bool (0x58) | n/a (client only) | Exists: sure. That it turns true inside a vault: inference (the music changes there; `FMusicSettings.DungeonCombatToExploreBufferTime`, l. 4933) |
| Dungeon membership | `UDungeonSubsystem.PlayersInDungeonsData` (21597); the client tells the server through `ADominionPlayerCharacter::Server_UpdateDungeonState(bool, FDungeonData)` (10039) | | | Sure. **Never call either.** The RPC shows that the client itself decides "entered", which suggests it has the dungeon data |
| **Entrance and exit teleporter** | `ABP_InteractablePlayerTeleporter_C : AWorldActor` (BP header) | `Interaction` (UInteractionComponent, 0x408), `TeleportDestinationName` FName (0x420), `GraveyardRef` AGraveyard (0x430) | **21** (object dump l. 275055 area) | Guess, but a strong one: 21 is about two per vault (in and out), and `GraveyardRef` matches "the grave appears at the outside entrance" (capstone note l. 59). The dump also holds **16** `BP_PlayerGraveyard_8Slots_C` |
| Locked variant | `ABP_InteractablePlayerTeleporter_Locked_C` | adds `IsUnlocked` bool (0x430, `OnRep_IsUnlocked`) and conversation tags | 1 | Sure. A candidate for the Vertentis door that needs Dragon Slayer: guess |
| Quest variant | `ABP_InteractablePlayerTeleporter_RequiresQuestStep_C` | `ShouldTriggerQuestLogic`, `ConversationEntryTag`, `ParticipantTag` | 0 loaded | Sure (class only) |
| Native teleporter | `ASwitchableTeleporter : ASwitchableActor` (12520) | `InteractionComponent`, `TeleportDestinationName`, `TeleportOriginName`, `bForceDisplayLoadingScreen`, `TeleportInteractionAngleParams` | 0 | Sure (class only). The capstone note cited this class; no instance of it is loaded, so the vaults probably use the BP one above |
| Teleport destination | `ATeleportationTarget : ANavigationObjectBase` (12602) | `TargetName` FName (0x2E8) + its position | **222** | Sure. A teleporter's `TeleportDestinationName` names one of these. Reading both gives the arrival point **before** entering |
| **Lever** | `ABP_BinaryLever_C : AInteractableSwitch : ASwitchBase : AWorldActor` (BP header; Dominion.hpp 11351, 12481) | `SwitchState` FSwitchState {`ServerTimeOfInteraction` float, `SwitchPosition` uint8} (0x428, replicated: `OnRep_SwitchState`); `Switchables` `TArray<AActor*>` (0x418: what it drives); `HighestPosition`, `bLoopPositions` (0x470); `InteractionComponent` (0x468) | **3** (UAID suffixes 2098065060, 2098289214, 2098291215) | Fields: sure. That position 0 = up and 1 = pulled: guess (a binary lever, `HighestPosition` probably 1) |
| **Final (boss) door** | `ABP_FinalDoor_vault_Refactored_C : ASwitchableDoor : ASwitchableActor` | **No open/closed property.** `ASwitchableDoor` (12509) has `DoorComponentData` (TArray of {DoorComponent, OpenTransform, StartingTransform}), `OpenCloseDuration`; the state lives in unreflected memory (properties end at 0x42C, size 0x480). `BP_OnDoorStateChanged(EDoorState)` is an event (EDoorState: Closed 0, Closing 1, Open 2, Opening 3; enums l. 1543). It holds `SwitchForLight_01/_02` (two `ASwitchBase*` refs, 0x508, 0x510) | **1** (suffix 2098293216, the same placement batch as the 3 levers) | Sure that the state is not a property. Its two light switches are probably the two levers that open it (guess) |
| Inner gate | `ABP_SwitchableDoor_Vault_4x4_C : AWorldActor` | `Up`, `Down` bools (0x418), `Initial Relative Location` | 1 (suffix 2098073064, same batch) | Fields: sure. Meaning of Up/Down (raised = open?): guess |
| Pressure plate | `AOverlapSwitch : ASwitchBase` (11659) | `SwitchState`; `OverlappingActors`, `bPermanentActivation`, `DeactivationDelayTime`, `SavedDeactivationDelayRemaining` | 0 | Sure (class). Kalistrakthen Kara's plates, not Crasorak's |
| Other switches | `ACombinationSwitch` (9230: `CurrentComboIndex`, `bIncorrectComboEntered`), `ADamageableSwitch` (9276), `ALightBeamSwitch` (11421), `AGameplaySwitch` (11019, driven by triggers such as `UEnemyExistsGameplaySwitchTrigger` 21980, `UBossDefeatedWorldEventTrigger` 16202) | `SwitchState` on all | 1 `GameplaySwitch` | Classes sure; which vault uses which: unknown. An "enemy exists" or "boss defeated" switch is a candidate for what opens the way out after a boss: guess |
| **Trap** | `AAnimatingTrap : ASwitchableTrap : ASwitchableActor` (8883, 12546) | `UserReadableName` FText (0x540), `TrapDamage`, `CurrentAnimationTime`, `TelegraphTimeOffset`, `TrapTimelineEventData` (timing of its cycle), `TrapBehaviourModules` (each `UTrapBehaviourModule.bActive`, 36609); damage effects `GE_Damage_FireTraps`, `GE_AddBurn_FireTraps`, `GE_Damage_StaticSpikes`, `GE_Slow_StaticSpikes` | 0 loaded | Fields: sure. Whether vault fire jets and spikes are this class: strong guess (the only trap family with damage) |
| On or off (doors, traps, teleporters) | `ASwitchableActor` (12496): `IsSwitchableActive()`, `GetSwitchPosition()` are functions; no state property | | | Sure that there is no property |
| **Chest** | `AWorldChest` family (12808): `ChestState` EChestState (0x320; Unopened 0, Opened 1, Emptied 2; enums l. 895; `OnRep_ChestState`), `ChestRespawnProfile`, `RespawnTimerInGameTimeStartTicks`, `bRespawnDisabled`, `InventoryComponent` | | 0 loaded | Fields: sure. That vault chests are `AWorldChest`: strong guess (the 5-day respawn on the wiki matches `ChestRespawnProfile`). `ATreasureChest` (12632) adds `bUnlocked` and `RequiredItemsToAllowInteraction` |
| Vault core on its plinth | `ITEM_Resources_VaultCore` (object dump l. 225692) is only the item data. No plinth or pedestal class exists in the dump | | 0 | Unknown. Most likely a placed `AWorldItem` (12850) that respawns |
| Boss | `ADominionAICharacter`: `LoadedData.bIsBoss`, `PowerLevel`, health (DISCOVERIES l. 1003) | | | Sure (read today). Whether the Overlord and the Rat King have `bIsBoss` set: unknown (capstone A5) |
| Boss arena | `AFightArenaManager` (10832: `bIsFightArenaActive`, `CurrentWaveIndex`) and `ABossAltar` (9105: `bSummoned`, `bSpawned`) exist | | 0 | These belong to wave arenas and to Velgar's altar. Nothing ties either to a vault: no vault-specific arena class was found |
| Revive inside | `RevivedInDungeonNotificationTag` on the health components (6050, 30124) | | | Exists. Suggests a revive that knows it is in a dungeon; behaviour unknown |
| Teleport in progress | `ADominionPlayerCharacter`: `TeleportingGameplayTag` (9864), `TeleportLoadingScreenDelay`, `TeleportTimeout`, `TeleportInvulnerabilityLength` (9900-9902), `IsTeleporting()` (10090); Client RPCs the **server** sends: `Client_NotifyTeleportWithVFXDelayBegin(bool, float)`, `Client_NotifyTeleportWithLoadingScreenBegin()`, `Client_NotifyTeleportWithDelayComplete(bool)` (10192-10194), `Client_OnEveryCellsLoadedForTheFirstTime()` (10191) | | | Sure that they exist. That a vault door sends them: inference (the BP teleporter goes through `UTeleportationSubsystem::TeleportToNamedLocation(..., bShowLoadingScreen, ..., OptionalGraveyard)`, 36145) |

**One finding about loading.** The server dump has no creature, chest or tree instance at all, but it has the 17 `Dungeon` actors, 21 teleporters, 222 teleport targets, 16 graveyards, 31 `BP_MapRegion_C`, the levers and the final door. So these are **always-loaded** actors (World Partition non-spatial), not streamed cells. That also fits `places.lua`, which reads `BP_MapRegion_C` on the client from anywhere. Always-loaded actors are never streamed out, so their Blueprint classes are not the freed-and-reused kind that R17 is about. The client keeps the same always-loaded set (inference, probe P1 checks it). Traps, chests, creatures and cores are not in the dump, so they live in streamed cells, and R17 applies to them.

## 2. How he would read each

### 2.1 What today's reads already see

`look` is `sense.census` (`sense.lua` l. 788). Its interactables pass lists every owner of a `UInteractionComponent` within the radius, with `prompt` = `InteractionPrompt` (l. 899-923, 540). The name comes from `BuildingPieceData`, else `DisplayName` through `U.prop`, else the class word (l. 545). `kind` comes from the component families or from the actor families `WorldChest` and `WorldLodestone` (l. 47-57). `inspect` adds a description and container contents (`client_bridge.lua` l. 1240-1259, `contents_of` l. 1220). `interact` aims the game's detector and presses the interact key (DISCOVERIES l. 1010).

| piece | listed by `look` today? | what it shows | missing |
|---|---|---|---|
| Entrance teleporter (BP) | **Yes**, as kind `interactable` (it owns `Interaction`) | `prompt` (the game's own word, probably "Enter", unverified), position, distance, name (`DisplayName`, else "Interactable Player Teleporter") | That it is a way into the named vault, and where it leads |
| Locked teleporter | Yes, the same | prompt | `IsUnlocked` |
| Lever | **Yes**, kind `interactable` (owns `InteractionComponent`) | prompt (probably "Pull", unverified), name | `SwitchState.SwitchPosition` (pulled or not), and which door or gate it drives |
| Final door, inner gate | **No** (no InteractionComponent) | | open or closed, and where it is |
| Trap | **No** | | that it is there, its name, whether it is active, its cycle. Damage it deals already arrives in the vitals `damage` row with `class` and `instigator` (`sense.lua` l. 1049); a trap's instigator naming has never been seen |
| Pressure plate | **No** | | |
| Chest | **Yes**, kind `chest` (actor family `WorldChest`), prompt "Open" (seen on loot chests, DISCOVERIES l. 1005); `inspect` lists its contents | | `ChestState` (unopened, opened, emptied) |
| Vault core on a plinth | Yes, **if** it is a `WorldItem`: the items pass gives `ItemData.Name` (l. 429, 865) | | unverified |
| Creatures, boss | **Yes**: power level, health, `boss` from `bIsBoss` (l. 376-377) | | |
| "I am inside a vault, which one" | **No** | | `bInDungeon`, the vault's name and box |
| A teleport happening | **No** (only after the fact: a position jump of more than 10 m in navmem and in the recorder) | | the begin and end of the teleport |

### 2.2 The smallest read-only additions

All are property reads on live actors found with `U.find_all`, re-found each tick (R16), through `U.prop` for every Blueprint-class object (R17), never while `DW_PAUSE` is set. No UFunction calls on these actors, no RPCs, no structs built. Struct fields are read from engine-built structs only, the same way `places.lua` reads `Landmarks`.

| # | addition | reads | where it would show | crash risk (register) |
|---|---|---|---|---|
| A1 | **Where am I**: `in_vault` in get_state | `ULocalPlayerAudioSubsystem.bInDungeon` (native class: a plain read is safe); then the registry's `Dungeons` entry whose `Box` holds his position gives `UserVisibleName` | get_state, beside the region | Low. The subsystem is found with `FindAllOf("LocalPlayerAudioSubsystem")`; reading the `Dungeons` TArray is the `Landmarks` pattern (validate the registry in the same tick, R16; the Unstuck crash was a TArray read on an object being replaced, DISCOVERIES l. 952) |
| A2 | **Vaults as places** (offline data, like `places_<build>.json`) | `Dungeons[i]`: `UserVisibleName`, `Box.Min/Max`, `EntranceLocation`, `ExitLocation`, `DungeonTag.TagName`, `bNeedsToBeDiscovered`; fallback: the 17 `ADungeon` actors (`U.prop` on `DungeonUserVisibleName`, `BoxComponent` bounds) | `data/places_<build>.json` through `places_dump`, so `brain/places.py` can name "Crasorak Kara" and its door. A fact about the map, not a route | Low (once, at a quiet time) |
| A3 | **Teleporter rows say where they lead** | on a listed teleporter: `TeleportDestinationName` (FName), matched to the `ATeleportationTarget` whose `TargetName` is equal (its position), and that position tested against the A2 boxes; `IsUnlocked` when the class has it | `look` row: `leads_to` = the vault's name or "outside", `locked` | Low: FName and bool reads, always-loaded actors |
| A4 | **Switch state on lever rows** | `SwitchState.SwitchPosition` and `HighestPosition` on any listed actor whose class chain has `SwitchState` (`U.prop` declares it); `Switchables` short ids (a TArray of actor refs: count and `U.short` only) | `look` row: `position` n of `HighestPosition`, `drives` [ids] | Low to medium: a TArray read on a streamed actor; validate it in the same tick, never across the teleport |
| A5 | **Doors and gates as things** | a census pass over `SwitchableDoor` and `BP_SwitchableDoor_Vault_4x4_C`: position, class word. State from the switch that lists the door in its `Switchables` (A4), else `Up`/`Down` on the 4x4 gate. The final door: from its `SwitchForLight_01/_02` refs' `SwitchState` | `look` category `interactables`, kind `door`, `open` true, false or unknown, `opened_by` [lever ids] | Low. No door-state property exists, so "unknown" must be allowed. Never call `IsSwitchableActive()` before an offline check that it is safe |
| A6 | **Traps as hazards** | a pass over `SwitchableTrap`: `UserReadableName` (FText, `U.prop`), position, the active flag from `TrapBehaviourModules[i].bActive` (native `UTrapBehaviourModule`, plain read) | `look` category `hazards` (it already exists for creature ground effects in combat, `docs/design/velgar.md` 3b); in `look`: name, position, active | Medium: a streamed BP class (R17) and a TArray of UObjects. Read only through `U.prop`, re-find every tick |
| A7 | **Chest state** | `ChestState` via `U.prop` on `WorldChest` rows | `look` chest row: `opened` / `emptied` | Low. Note: L40 (R17) was a speculative `DisplayName` read on a `WorldChest`. `ChestState` is declared on the native `AWorldChest`, and `U.prop` checks that |
| A8 | **Teleport begin and end** | hookhub post-hooks (one per path, never unregistered, `hookhub.lua` l. 1-25) on `DominionPlayerCharacter:Client_NotifyTeleportWithVFXDelayBegin`, `...WithLoadingScreenBegin`, `...WithDelayComplete` and `Client_OnEveryCellsLoadedForTheFirstTime`. The callbacks write an event row and set `DW_PAUSE` with `DW_PAUSE_BY = "teleport"`, like `hook_travel`. They do not read the parameters | events `teleport_begin` / `teleport_end`; the running action ends `companion_down` with "I'm going through the door" (communication) | Low to medium. The same pattern already runs live on `BaseTeleportationComponent:Client_OnTeleportSuccessful` (`lodestone.lua` l. 31, 144-152). Those are scalar-parameter Client RPCs the game sends itself; we never send one (rule 3). The pause release needs care: `check_unpause` lifts it when the pawn has been in `L_World` for 3 s (`client_bridge.lua` l. 2093-2110), and in an in-map teleport he never leaves `L_World`. So the release must wait for `...DelayComplete` plus a settle time |

Not proposed: calling `IsTeleporting()`, `IsSwitchableActive()`, `GetSwitchPosition()`, `UDungeonSubsystem:IsPlayerInDungeon(FGameplayTag, ...)` (a struct parameter, R3/R15), `UDominionRuntimeBlueprintLibrary:IsLocationInsideDungeon(ctx, FVector)` (l. 21093), or hooking `Server_UpdateDungeonState` (its parameter is an `FDungeonData` struct). Each would need its own offline check first, and the property reads above cover the same ground.

## 3. Entering

**What the teleport is.** Very likely a **same-map teleport inside `L_World`**, not a level load and not a separate map:
- The interiors are off-map places in `L_World` (capstone note l. 57: Spitfoot at (-1653, 218) m, Velgar's arena at (991, 4285) m). Their teleporters, targets and `Dungeon` volumes are all always-loaded actors of `L_World`'s persistent level (object dump).
- The BP teleporters carry an FName destination and a graveyard, which is the `TeleportToNamedLocation` signature (Dominion.hpp 36145; `FPlayerTeleportParams` 6144 has `bShowLoadingScreen`). The player character gets the begin and complete Client RPCs (10192-10194).
- So the server moves his pawn. The client streams World Partition cells in around the arrival point and out around the door, behind a fade or a loading screen. There is no `UEngine::LoadMap`.

**What the client's code does across it today.**
- `client_boot.ps1` and `join_server.lua` / `disconnect.lua` handle joins and leaves. They set `DW_PAUSE` themselves (`join_server.lua` l. 15, `disconnect.lua` l. 6). None of them is involved in an in-map teleport.
- The front-end return is guarded by `hook_travel` (`client_bridge.lua` l. 2067-2077; R18). It is a `RegisterLoadMapPreHook`, so **it will not fire for a vault door**: no LoadMap happens. Nothing pauses the loops across a vault teleport today.
- What survives such a teleport live: lodestone teleports on the client (first model-chosen one on 10-28, then the CHAT runs 4 to 8; `docs/PROGRESS.md` l. 336, 369-373) and the death respawns behind every grave run. What did not survive: the game's Unstuck. That is also a server-side in-map teleport (`Server_TeleportToPlayerStart`), and the client died in `push_arrayproperty`, a Lua loop reading a TArray on an object being replaced (DISCOVERIES l. 951-953, 1597; dump `crash_2026_10_25_21_49_34`). The vault door is that same kind of teleport, and longer than a lodestone hop (about 2 km to the Vertentis interior).

**The two crash types the capstone note names** (capstone note l. 132-136):

| | what | recorded in |
|---|---|---|
| R17 | UE4SS 3.0.1's `FindProperty` cache never evicts. When World Partition streams a Blueprint class out and a new class is allocated at the same address, a by-name read uses the old offset and type. Seen as a `DisplayName` read on a `WorldChest` right after a fixture teleport streamed cells. Guard: `U.prop` | `docs/ARCHITECTURE.md` l. 375; `docs/BUGS.md` l. 128 (L40); `docs/DISCOVERIES.md` l. 2293 on; dump `crash_2026_11_01_00_08_24` |
| R18 | A map travel the game starts itself (connection lost, lobby 503): no pause was set, the loops ran on in the front end and a Lua UFunction call hit a world that was gone. Guard: the LoadMap pre-hook, never yet seen firing live | `docs/ARCHITECTURE.md` l. 376; `docs/DISCOVERIES.md` l. 3488 on; dump `crash_2026_11_16_21_15_33` |

For a vault door, the live risk is **R17 plus the Unstuck kind** (R16: stale refs and TArrays across the stream-out), not R18. A vault entry streams out the whole outdoor area at once. The always-loaded mechanisms (A2, A3, A4 levers) are not at risk. Creatures, chests and traps on both sides are. An R18 case only arises if the server drops him during the load, and the LoadMap hook covers that.

## 4. A first probe plan: offline, then live (dev world, read-only)

Rules for every step:
- a clone character, never ClaudeDev or Luis's character;
- the server's world restored from a named snapshot first (rule 9; the capstone note asks for a `vault_fresh` snapshot after P1 and before anyone enters);
- no brain;
- each probe is a `client_mod/commands/*.lua` run through the command runner, which writes a JSON reply and one `[DWClient] vault_probe ...` line to `logs/client/client.log`.

**Stop on any of:**
- a new `crash_*.dmp`;
- a client hang (heartbeat);
- `ue4ss_prop_guard stale` in the log (R17 caught; read it before going on);
- a probe's Lua error count above 0;
- a census over 200 ms;
- `client_paused` that does not clear within 30 s.

| # | where | what it reads | log line | stops if |
|---|---|---|---|---|
| P0 | offline | Unit tests with fakes for the A1 to A8 readers (as `test_places.lua`, `test_prop_guard.lua`): `U.prop` refuses an undeclared name; a missing registry gives nil; the A8 hook writes the flag and never reads a parameter | test output | any test touches a parameter or calls a UFunction |
| P1 | at home (Temple Woods), far from any vault | `Dungeons` (count; per entry the name, box, entrance, exit, tag); `FindAllOf` counts for `Dungeon`, `BP_InteractablePlayerTeleporter_C` (+ `_Locked`), `TeleportationTarget`, `BP_BinaryLever_C`, `BP_FinalDoor_vault_Refactored_C`, `BP_PlayerGraveyard_8Slots_C`; per teleporter: position, `TeleportDestinationName`, the matching target's position, `GraveyardRef` position, `Interaction.InteractionPrompt`; `bInDungeon` (expect false); `TeleportingGameplayTag` | `vault_probe P1 dungeons=<n> teleporters=<n> targets=<n> levers=<n> in_dungeon=false` + `logs/vault_probe_P1.json` | `Dungeons` is empty or unreadable on the client: then use the `ADungeon` actors, and if they are missing too, the client cannot place a vault and A1/A2 need another source |
| P2 | harness walk to Crasorak Kara's door (290 m), then still | `look` at 20 m, as today: is the teleporter listed, with which `name` and `prompt`? Then P1's per-teleporter read for the nearest one, its destination inside an A2 box, `IsUnlocked` if present | `vault_probe P2 door=<id> prompt=<text> leads_to=<name> dist=<m>` | the door is not an interactable row: find its class first (census of all actors within 5 m by class word) |
| P3 | the same spot | Arm the A8 hooks (flag and event only, no game call) and the pause release on `...DelayComplete` + 5 s. Then **one** press of interact on the teleporter by id: the player's own path, no brain. Pause the loops across it | `vault_probe P3 teleport_begin t=<s>`, `teleport_end t=<s>`, `client_unpaused`; then position, jump in m, `bInDungeon`, `prop_guard` counters | a crash: no second entry until the cdb stack is read (ProcDump and cdb are approved); a pause that does not clear |
| P4 | inside, at the arrival point, standing still | census at 20 m and 80 m; per `ASwitchBase` actor in range: class, position, `SwitchState`, `HighestPosition`, `Switchables` ids; doors (`SwitchableDoor`, 4x4) with position and `Up`/`Down`; traps (`SwitchableTrap`): `UserReadableName`, position, module `bActive`; `WorldChest`: `ChestState`; `WorldItem` named Vault Core; creatures with `boss` | `vault_probe P4 switches=<n> doors=<n> traps=<n> chests=<n> cores=<n> creatures=<n> boss=<n>` + `logs/vault_probe_P4.json` | guardians in combat range (leave by P5 at once); any stale entry |
| P5 | the exit teleporter (the nearest one from P4's census), same hooks | P3 in reverse; afterwards `bInDungeon` false, position at the outside door, `prop_guard` counters compared with P3's | `vault_probe P5 out=true jump=<m> stale=<n>` | as P3 |

Only after P1 to P5 hold: a second window of the same reads after a lever pull. That is an action, the real interact press, not a read, and it is out of this note's scope. The probes answer capstone questions A2 (P2: locked or not), A3 (P1 to P3), A4 (P4) and part of A5 (P4: `boss`).

## Limits

- The class-to-vault mapping is inferred from a **server** dump made with nobody near a vault. No vault chest, trap, core or creature instance has been seen. The client may hold a different set of actors.
- Whether the registry's `Dungeons` array and the switches' `SwitchState` replicate to the client is unknown until P1 and P4.
- The door's open state has no property, so A5 depends on the lever-to-door link in `Switchables`.
- The wiki pages are community-written. The Vertentis page says nothing about its door or levers. The prompts ("Enter", "Pull") are guesses until P2.
- `RegisterHook` on a Client RPC is documented only in general terms (UE4SS docs; native `/Script/` paths support pre and post callbacks, and delegates are not supported). Its live safety rests on the lodestone precedent.

## Sources

- Wiki, live 2026-11-17: https://dragonwilds.runescape.wiki/w/Crasorak_Kara , https://dragonwilds.runescape.wiki/w/Vertentis_Kara
- UE4SS `RegisterHook`: https://docs.ue4ss.com/lua-api/global-functions/registerhook.html
- Mod search (nothing relevant found): CurseForge Dragonwilds listings (https://www.curseforge.com/runescape-dragonwilds/blueprints/disable-vignette , https://www.curseforge.com/runescape-dragonwilds/pak-mods/blueprint-mod-loader); guides only for vault gates (https://www.gamepur.com/guides/how-to-open-temple-woods-vault-gate-runescape-dragonwilds , https://gamever.io/knowledge-base/every-dragonkin-vault-in-dragonwilds-in-order-with-power-levels)
- Game data: `dumps/26574459/CXXHeaderDump/Dominion.hpp`, `Dominion_enums.hpp`, BP headers named above, `UE4SS_ObjectDump.txt`.
