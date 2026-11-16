# Placement interfaces: what the game exposes for building (2026-11-16)

Local read-only analysis for issue B16 (`docs/ISSUES-2026-11-01-coplay.md:59`): the build skill takes 7-12 s per piece against Luis's 3.81 s, and batches fail where singles pass. The question is what the game exposes so that the body can know where a piece will go and place it in one step.

Sources: the UE4SS dumps of build 26574459 (`dumps/26574459/`), the client mod, DISCOVERIES, the player recorder log and two live brain logs. No live client call was made. Paths under "UHT" are relative to `dumps/26574459/UHTHeaderDump/Dominion/Public/`, paths under "CXX" to `dumps/26574459/CXXHeaderDump/`. Anything not backed by a file is marked **UNVERIFIED**.

## Summary

1. Placement is one client-to-server RPC: `UBuildModeComponent::Server_SpawnBuilding(int32 index, FTransform, bool bSpawnGhost, TArray<UInventoryComponent*>)`. The client decides the final transform in native code and sends it. Luis's own client sent exactly this 45 times in the recorder log, as fast as 0.57 s apart.
2. No reflected function computes the preview, the snap or the validity. `UBuildPlacementComponent` has no UFUNCTION at all, and `BP_BuildingHelper_C` is a cone mesh with no logic. The only reflected outputs are the material parameter collection (cursor position, validity colour) and a few properties.
3. The cursor is the camera ray's hit. The glide the skill fights is the camera moving after each aim, not a property of the helper. `W.aim` works the rotation out from where the camera is now, on a 7 m boom that then swings round the pawn.
4. Snap plugs exist as data (`FPlug`: profile plus transform), readable today only on actor pieces. For walls, floors and roofs they sit in unreflected containers; one read-only probe would say whether Lua can reach them.
5. The `check` phase (aim, settle, re-aim) is 49% of a successful single (4.8 of 9.9 s) and 54-63% of a failure. Every failure in the two logs was an aim-loop failure with the ghost 0.01-0.20 m from the flush spot, not a refusal by the game.
6. `tickguard.lua`, `fxguard.lua` and the fps cap do not touch the building components.

## 1. The reflected building API

### 1.1 Classes

| Class | Where it lives | Reflected functions | Notes |
|---|---|---|---|
| `UBuildModeComponent` | PlayerController | 20 (below) | Owns the mode, the piece being placed, the helper actor and the MPC names. Size 0x420; the last reflected property ends near 0x340, so about 0xE0 bytes are unreflected (CXX `Dominion.hpp:16272-16332`). |
| `UBuildPlacementComponent` | PlayerController | **none** | Distances and collision profiles only (UHT `BuildPlacementComponent.h:16-40`). Size 0x148, reflected properties end at 0xF8: 0x50 bytes of native state (CXX `Dominion.hpp:16342-16354`). |
| `UBuildInteractionComponent` | PlayerController | 6 (below) | Place and destroy inputs, the targeted piece, the destroy RPCs (UHT `BuildInteractionComponent.h:26-101`). |
| `UBuildValidationComponent` | PlayerController | none | `AllowedDungeonTags` :15, `PlayerController` :19 (UHT `BuildValidationComponent.h`). |
| `ABP_BuildingHelper_C` | spawned at the cursor | none | `Cone` (static mesh) and `DefaultSceneRoot` only, size 0x2D0, no event graph (CXX `BP_BuildingHelper.hpp:4-9`). |
| `UBuildingSnapComponent` | on building actors | none | `Plugs`, radii (UHT `BuildingSnapComponent.h:15-28`). |
| `ABaseBuildingActor` | actor pieces and the preview | `IsPreview()` and getters | `PlayerControllerManagingPlacement` :67, `bIsPreview` :77, `bIsGhosted` :80, `BuildingSnapComponent` :89, `BuildingPieceID` :120 (UHT `BaseBuildingActor.h`). |
| `AGlobalBuildingManager` | world | none used | `TMap<uint32, FBuildingPieceState> BuildingPieces` :41, `BuildingReplicationArray` :44 (UHT `GlobalBuildingManager.h`). The census. |
| `ACellBuildingManager` | world | 2 multicasts | Construction and destruction sounds with index, location and player (UHT `CellBuildingManager.h:42-46`). |
| `UBuildingSubsystem` | world subsystem | none | `bCenteredPlacement`, `BuildableVolumes`, `PieceIDToBuildingPieceActor`, `BuildingPieceActorSpawnService`, `bCheatAlwaysAllowBuilding` (CXX `Dominion.hpp:16625-16635`). |
| `ULightweightBuildingPieceManager` | world | none | No reflected member at all, size 0x5B0 (CXX `Dominion.hpp:26293-26295`). It holds the structural pieces. |
| `UBuildingUIAPI` | UI API object | 3 | `CallOnBuildingItemSelected(UBuildingPieceData*)` :70, `CallOnBuildingItemHovered` :73, `CallOnBuildingItemUnhovered` :67 (UHT `BuildingUIAPI.h`). |
| `UBuildingSettings` | settings CDO | none | `ModifyRotationStepDeg` :30, `ModifyHeightStep` :33, `ModifyDistanceStep` :36, `BuildingPieceArray` :46 (UHT `BuildingSettings.h`). No lag, interpolation or update-rate field. |
| `UDominionRuntimeBlueprintLibrary` | static | 2 for building | `DoesBuildingPieceHaveCategory` :221, `DoesAnyBuildingPieceHaveCategory` :230. Nothing about placement. |

### 1.2 `UBuildModeComponent` functions (UHT `BuildModeComponent.h`)

| Line | Signature | Specifiers |
|---|---|---|
| :152-153 | `EValiditySpawnState TrySpawnPieceAtLocation(const UBuildingPieceData* BuildingPieceData, const FVector& InLocation, const FRotator& InRotation)` | BlueprintCallable, **BlueprintAuthorityOnly** |
| :156-157 | `void Server_SpawnBuilding(int32 InBuildingPieceDataIndex, const FTransform& SpawnTransform, const bool bSpawnGhost, const TArray<UInventoryComponent*>& AvailableInventories) const` | BlueprintCallable, Reliable, **Server** (protected) |
| :160 | `OnValidityStateChange(EValiditySpawnState)` | called natively; hooks never fire (`docs/DISCOVERIES.md:1926`) |
| :163 | `OnToggleRepairAndEditModeInput(const FInputActionValue&)` | input handler |
| :166 | `OnToggleBuildModeInput(const double& HeldDuration, bool bShouldCheckPauseBlock)` | input handler |
| :169-187 | `OnSoulRiftedEnabledChanged(bool)`, `OnSelectionMenuVisibilityUpdated(bool)`, `OnPieceUnhovered()`, `OnPieceSelected(UBuildingPieceData*)`, `OnPieceHovered(UBuildingPieceData*)`, `OnInventoryChanged(...)`, `OnCancelInput(const FInputActionValue&)` | delegate and input handlers |
| :191, :194 | `GetPrevBuildMode()`, `GetCurrentBuildMode()` | BlueprintCallable getters |
| :197 | `ForceEnterBuildMode()` | BlueprintCallable, no parameters |
| :200 | `ExitAnyMode()` | BlueprintCallable, no parameters |
| :204 | `Client_TelemetryOnBuildingPieceGhostPlaced(int32)` | Client |
| :208 | `Client_TelemetryOnBuildingPieceComplete(bool, int32)` | Client; its post-hook fires (`docs/DISCOVERIES.md:1933`) |
| :211 | `Client_TelemetryDestroyPlacedPiece(FBuildingPieceHandle, bool, const TArray<int32>&)` | Client |

Properties worth knowing (same file): `bShowBuildingHelpers` :37, the input actions :41-62 (`CancelAction`, `ModifyRotationAction`, `ModifyHeightAction`, `ModifyDistanceAction`, `GhostModifierAction`, `FreePlacementModifierAction`), `EBuildSnappingMode SnappingMode` :65, `MaterialParameterCollection` :90, the MPC parameter names :93-117 (`PlacingValidityStateIndexMPN`, `PlacingStabilityRangeMPN`, `StabilityProviderRangeMPN`, `CursorWorldPositionMPN`, `CursorWorldDirectionMPN`, `ToggleDrawInFrontMPN`, `MinPieceDepthMPN`, `MaxPieceDepthMPN`), `CurrentBuildMode` :135, `CurrentlyPlacingPieceData` :138, `BuildingHelperActor` :144, `FWeakBuildingPieceHandle PreviewSupportingPieceHandle` :147.

`FWeakBuildingPieceHandle` has no reflected member (CXX `Dominion.hpp:8131-8133`, size 0x18), so `PreviewSupportingPieceHandle` (the piece the preview is resting on) cannot be read field by field from Lua. **UNVERIFIED** whether its raw bytes are of any use.

### 1.3 `UBuildInteractionComponent` functions (UHT `BuildInteractionComponent.h`)

| Line | Signature | Specifiers |
|---|---|---|
| :75-76 | `Server_RegisterTargetPiece(uint32 InTargetID, uint32 PieceID)` | Reliable, Server |
| :79-80 | `Server_InteractActor(EBuildInteractionType, FBuildingPieceHandle BaseBuildingActor, ADominionPlayerController*, const TArray<UInventoryComponent*>&)` | BlueprintCallable, Reliable, Server |
| :82-83 | `Server_Interact(uint32 PieceID, EBuildInteractionType InteractionType, const TArray<UInventoryComponent*>& AvailableInventories, const FVector& TargetedPieceLocation)` | Reliable, Server. The deconstruct and repair RPC. |
| :87 | `OnTargetedPieceRepaired` | delegate handler |
| :97-98 | `Client_UpdateTargetedPieceInspectionInfo(uint32, const FBuildingCompletionStatus&)` | Client |
| :100-101 | `Client_ShowValidityNotification(EValiditySpawnState)` | Client: the server's reason for refusing a placement |

Properties: `DetectionRange` :26, `InteractAction` :35, `QuickInteractAction` :38, `DestroyBuildingAction` :41, `DestroyBuildingHoldAction` :44, `MinTimeBetweenBuildingPlacementRequests` :53, `ValidityNotificationTextMap` :60, `DestroyRequestNotificationTextMap` :63, `TargetedPieceHandle` :66, `AuthorityTargetedPieceHandle` :69.

### 1.4 The RPC parameter types

| RPC | Parameters | What they are |
|---|---|---|
| Place: `Server_SpawnBuilding` | `int32` | `UBuildingPieceData.BuildingPieceDataIndex` (Transient, UHT `BuildingPieceData.h:69`); the index into `UBuildingSettings.BuildingPieceArray` (`BuildingSettings.h:46`). |
| | `FTransform` | The final world transform, already snapped by the client. 0x60 bytes: rotation quat, translation, scale. |
| | `bool bSpawnGhost` | True when the ghost modifier is held (place a blueprint without materials). |
| | `TArray<UInventoryComponent*>` | The inventories that pay. Luis's client sent 4 (recorder, below). |
| Deconstruct: `Server_Interact` | `uint32 PieceID` | The census key (`GlobalBuildingManager.BuildingPieces`). |
| | `EBuildInteractionType` | `None, Repair, Donation, Destroy` (Destroy = 3). |
| | `TArray<UInventoryComponent*>` | Where the refund goes. Luis's client sent 3. |
| | `FVector` | The targeted piece's location. |
| `Server_InteractActor` | `FBuildingPieceHandle` | `{ TScriptInterface<IBuildingPieceResolver> PieceResolver; uint32 Context }`, size 0x18 (CXX `Dominion.hpp:1588-1593`). An interface pointer pair: not something to build in Lua. |

Enums: `EBuildMode {None, Selection, Placement, RepairAndEdit}`, `EBuildSnappingMode {Basic, Advanced, Free}`, `ESnapStateShaderValue {Hidden, Socket, Plug, SnappedPlug}`, `EValiditySpawnState {Valid, Overlapping, Floating, NeedsFoundation, NeedsSnapping, Unstable, MissingMaterials, WrongPhysicalSurface, InsideVault, InsideProtectedArea, ReachedCountLimit, ShelterCheckFailed, InsideBlockedRegion, None}` (UHT `EValiditySpawnState.h:6-21`).

### 1.5 What the recorder saw Luis's client send

`logs/recorder/rec_20261101T123634Z.jsonl` (server-side hooks from `mod/experiments/player_recorder.lua:28-29`) has 45 `build_spawn` rows and 1 `build_interact` row.

- A placement: `{"kind":"rpc","rpc":"build_spawn","who":"BuildModeComponent","params":[663,"Transform",false,"TArray[4]"]}`. The recorder did not unpack the transform.
- A deconstruct: `{"rpc":"build_interact","who":"BuildInteractionComponent","params":[53,0,"TArray[3]","Vector"]}`.
- Gaps between Luis's placements of the same piece: 0.57, 0.57, 0.64, 0.74, 0.83, 1.28, 1.32, 2.17 s (index 663); 1.07-2.18 s (615); 1.13-2.87 s (478). The fastest, 0.57 s, is above the 0.25 s `MinTimeBetweenBuildingPlacementRequests` (`docs/DISCOVERIES.md:1757-1765`).

So a human places a snapping piece every 0.6-2 s once the screen is open and the type is chosen. The cost of a placement in the game itself is one click.

## 2. What decides where the preview goes

### 2.1 What is known

- The cursor equals a line trace from the `PlayerCameraManager` location along its rotation, to the centimetre (`docs/DISCOVERIES.md:2719`; confirmed by `client_io/out/build_probe_helper.json`, where `cursor`, `ray_hit` and the helper's location are the same point).
- The helper actor has no logic of its own (section 1.1). Native code in `UBuildModeComponent` / `UBuildPlacementComponent` moves it and writes the MPC.
- Reflected distances: `SelectionMaxPlacementDistance` :25, `MaxPlacementDistance` :28, `MaxDistanceModifier` :31, `MaxHeightModifier` :34, `MagnetizeExtentsMultiplier` :37, and the two collision profile names `PlacementCollisionProfileName` :16 and `MagnetizingCollisionProfileName` :19 (UHT `BuildPlacementComponent.h`). Live values: 700, 700, 350, 300 cm and 1.2 (`docs/DISCOVERIES.md:1757-1765`, `client_io/out/build_probe_preview.json`).
- In `build_probe_helper.json` the cursor was 7.5 m from the camera and 2.3 m (horizontally) from the pawn while the camera was 5.0 m behind the pawn. So the 700 cm limit is not measured from the camera. **UNVERIFIED** whether it is measured from the pawn or from the boom's pivot.
- Per piece type, the placement profile row decides the rest: `bCanOnlyBeSnapped` :23, `bForcePlugRotation` :26, `bCanOnlyBePlacedOnDefinedSurface` :35, `SurfacePlacementNormal` :38, `bOverrideRotationFromHitSurface` :47, `bCanOnlyBePlacedOnGround` :50, `bShouldOffsetFromNonBuildingSurface` :59, `MagnetizingMultiplier` :62, `OverlappingBoundsMultiplier` :65, `bOverrideSnappingMode` :80, `SnappingModeOverride` :83 (UHT `PlacementProfile.h`). The rows are readable with `DataTable:FindRow` (`client_mod/scripts/build.lua:409-422`).

### 2.2 No reflected lag in the building code

A grep for `Interp|Smooth|Lag|TickInterval|UpdateRate|UpdateInterval` over the `Build*.h`, `Plug*.h`, `Snap*.h` and `Placement*.h` UHT headers returns nothing. `UBuildingSettings` has no such field either (UHT `BuildingSettings.h:16-100`). If the placement code smooths the cursor, it does so in the unreflected native bytes.

### 2.3 The glide is the camera

`W.aim` (`client_mod/scripts/build.lua:364-372`) sets the control rotation so that a ray from the camera's **current** location passes through the target. The camera is on `CameraBoom`, a 700 cm spring arm with location lag on (speed 10) and rotation lag off (`docs/DISCOVERIES.md:2306`). When the control rotation changes, the boom turns round the pawn, the camera moves to a new place, and the ray from there no longer passes through the target. DISCOVERIES already says so in words (`:2307` "an aim from the camera converges over ~0.5-1.5 s: each re-aim swings the 7 m boom and the lagged camera"; `:2718`). The preview reader then re-aims when the camera has moved more than `reaim_cam_m` and waits again (`build.lua:1380-1389`), up to `reaims_max` times. That is a fixed-point iteration with a slow plant in the loop, which is why the reads decay geometrically: row 255 of `logs/brain-live-20261115-235756-19752.jsonl` shows cursor x = 173.47, 173.27, 173.14, 173.07, 173.02, 172.99, 172.97 with the aim unchanged.

The camera has more moving parts than the boom lag. `UDominionPlayerCameraController` holds `Lerpables` :91, `DefaultCameraTransitionSpeed` :63, `DefaultCameraTransitionDelay` :66 and switches profiles (UHT `DominionPlayerCameraController.h`); a `UCameraProfile` can override `ArmLength` :39, `SocketOffset` :33, `TargetOffset` :27, `CameraPositionLagSpeed` :54 and `CameraLagMaxDistance` :60 with a `TransitionSpeed` :12 and `TransitionDelay` :15 (UHT `CameraProfile.h`). The spring arm also shortens when it hits a wall and recovers afterwards.

**UNVERIFIED:** which of these gives the slow tail. A lag speed of 10 alone settles in about 0.3 s, so the multi-second glide at ~1 m/s (`docs/DISCOVERIES.md:2715`) needs a slower term: a profile transition, the boom recovering from a collision, or native smoothing in the placement component. The probe in candidate A separates them.

### 2.4 The 0.5-1.4 s stepping

`client_mod/scripts/placement.lua:172-176` records that the preview's position updates in steps 0.45-0.6 s apart on flat ground and 1.26 s apart on a slope, while Lua reads at 10 Hz (`client_mod/scripts/client_bridge.lua:53` `M.POLL_MS = 100`, `:2115`). Nothing in the dumps explains this. **UNVERIFIED** candidates: a non-zero `PrimaryComponentTick.TickInterval` on `BuildModeComponent` or `BuildPlacementComponent`, a native timer, or the MPC being written less often than the helper moves. The interaction detector on the same controller does tick at 0.1 s (`docs/DISCOVERIES.md:2306`), so components with a tick interval exist in this game. `FTickFunction.TickInterval` is a reflected float (`client_mod/scripts/tickguard.lua:14-15`), so one property read settles it.

### 2.5 The guards are not involved

- `client_mod/scripts/tickguard.lua:25-28`: one row, `LightFlickeringWorldSubSystem.PrimarySubsystemTick` set to 3600 s. No building class.
- `client_mod/scripts/fxguard.lua:34-37`: empties `DominionPlayerCharacter.TaggedLocalNiagaraSystems`. No tick is changed.
- The 30 fps cap is a frame-rate limit in `GameUserSettings.ini` (CLAUDE.md). At 30 fps a per-frame update would step every 33 ms, not every 500 ms, so the cap does not explain the stepping.

### 2.6 What the failing reads show

In the two failed batches (rows 208 and 255 of `brain-live-20261115-235756-19752.jsonl`) all 12 cursor reads have y constant to the centimetre (1872.73 and 1872.26). That is the foundation's centre y minus 1.5 m, and z was 0.1-0.4 m below the foundation's top. The camera ray was hitting the foundation's vertical north face just under the top edge, not the top face. DISCOVERIES says what a wall does there: aimed at the side face it snaps to the bottom edge, 3 m low (`:2716`). The loop could not see this because it compares x and y distance to the flush spot. One line trace along the intended ray, with the hit normal checked, would have said so before the first wait.

## 3. Snap data as data

### 3.1 The structures

| Struct | Fields | Source |
|---|---|---|
| `FPlug` | `FPlugProfile PlugProfile`, `FTransform PlugTransform` | UHT `Plug.h:12-15` |
| `FPlugProfile` (a data table row) | `PieceTag` (Transient), `PlugTag`, `PieceIgnoringTypes`, `PlugIgnoringTypes` | UHT `PlugProfile.h:13-22` |
| `FPlugInfo` | `PlugProfile`, `bIsBeamFace`, `PlugName`, `AllowedRotation`, `Owner`, `RelativeTransform`, `SecondaryRelativeTransform` | CXX `Dominion.hpp:6168-6178` |
| `UPlugComponent` | `PlugProfileRowHandle`, `bIsBeamFace`, `PlugDirection`, `PluggedSecondaryRotation` | UHT `PlugComponent.h:14-24` |
| `UBuildingSnapComponent` | `TArray<FPlug> Plugs`, `bUseSocketsForPlugGeneration`, `PlugProfileDataTable`, `SnappingRadius`, `SnappingRadiusInBasicSnappingMode` | UHT `BuildingSnapComponent.h:15-28` |
| `FBuildingSnapNativeComponent` | the same five fields, as a native component | CXX `Dominion.hpp:1653-1661` |
| `FLightweightBuildingPiece` | `NativeComponents`, `BuildingPieceData`, `BuildingPieceDerivedData`, `Transform`, `LocalBounds`, `TArray<FPlug> SnappingPlugs`, `StabilityValue`, `PieceID` | CXX `Dominion.hpp:4394-4406` |
| `UBuildingPieceDerivedData` | `FJgxNativeComponentHost NativeComponents` :21, `PlacementProfileRowHandle` :57, `PlugVisualizationComponentTemplate` :60, `BuildingPieceLocalBounds` :66, `PlacementZOffset` :69 | UHT `BuildingPieceDerivedData.h` |
| `FJgxNativeComponentHost` | `TArray<FInstancedStruct> ComponentContainers`, `World`, three flags | CXX `JagexEngine.hpp:21-29` |

The plug profile table is `/Game/Gameplay/BaseBuilding_New/DT_PlugProfile` (`dumps/26574459/UE4SS_ObjectDump.txt`; `UBuildingSnappingSettings.PlugProfileDataTable`, UHT `BuildingSnappingSettings.h:13`).

### 3.2 What is readable today

| Route | Covers | State |
|---|---|---|
| `actor.BuildingSnapComponent.Plugs` | Actor pieces (stations, props, crates) and a preview that is an actor | **Works.** `client_mod/commands/build_probe_plugs.lua:63-75` reads tag names and transforms. `client_io/out/bprobe_crate.json`: 1 plug `BaseBuilding.PlugType.Surface`, radius 80 cm, Basic radius 200 cm, not from sockets. |
| Class-default snap component of `UBuildingPieceData.BuildableActor` (UHT `BuildingPieceData.h:35-36`) | Possibly structural pieces | **UNVERIFIED.** The object dump has 98 `BuildingSnapComponent` objects, all class defaults or templates. Whether a wall's class default has its plugs filled, or generates them from mesh sockets at run time (`bUseSocketsForPlugGeneration`), is not known. |
| `DerivedData.NativeComponents.ComponentContainers[i]` as `FBuildingSnapNativeComponent` | Structural pieces | **UNVERIFIED.** The plugs are inside `FInstancedStruct`s. Whether UE4SS Lua can walk an `FInstancedStruct` to its inner struct is not known; `build_probe_profile.lua` does not try. |
| `FLightweightBuildingPiece.SnappingPlugs` | Placed structural pieces, in world space | **Not reachable.** The only owner, `ULightweightBuildingPieceManager`, has no reflected member. |
| `PlugVisualizationHost` (UHT `BuildPlacementComponent.h:40`) with `PlugVisualizationComponentTemplate` instances | The plugs the game is showing near the cursor, with `ESnapStateShaderValue` per instance | **UNVERIFIED.** The host exists (a plain `Actor` at the origin in both probe outputs) but both probes listed no components. The listing itself is unreliable: the same call returned no components for the helper, whose blueprint has two. Whether the headless client creates the instances is unknown. |
| `DT_PlugProfile` rows through `DataTable:FindRow` | Which plug accepts which piece | **UNVERIFIED** but the same call already works for `DT_PlacementProfile` (`build.lua:409-422`). |
| Census location and yaw plus piece bounds | Every placed piece | **Works.** `FClientVisibleBuildingPieceState { BuildingPieceDataIndex, Location, Yaw, bGhosted, StabilityValue, FractionalHealth }` (UHT `ClientVisibleBuildingPieceState.h:11-26`); bounds in `client_io/out/bprof_*.json` (wall extent [151.5, 50, 151.5], foundation 150 cubed with `PlacementZOffset` 50, roof [168.73, 150, 168.73]). |

### 3.3 No snap function is reflected

There is no `FindSnap`, `GetSnapTransform`, `GetClosestPlug` or similar anywhere in the UHT dump for the building classes. `UBuildingSnapComponent` and `UBuildPlacementComponent` have no functions. The snap result can only be observed: as the preview actor's transform when the piece has one, or as the transform argument of `Server_SpawnBuilding` when the press goes out.

### 3.4 The empirical rules already recorded

`docs/DISCOVERIES.md:2716` and `:2720`: in Basic mode a wall aimed 0.3 m inside a foundation edge on its top face lands on the edge line; aimed at the side face it snaps to the bottom edge; a door aimed at the lintel snaps into the frame; a floor tile aimed 0.2 m under a wall's top on its inner face becomes a ceiling, pulled 1.29 m from the cursor; roofs snap 0.9-1.3 m from the cursor onto the wall-top plug. These are large capture radii (compare the crate's 200 cm Basic radius). The game is forgiving about where the cursor is, as long as it is on the right face. The skill's `snap_tol_m 0.06` and its 2 m correction cap (`build.lua:232-268`) ask for more precision than the game needs.

## 4. Direct paths

| Path | Call | Parameter types | Where it runs | Risk |
|---|---|---|---|---|
| The game's own press | inject `IA_Building_QuickInteract` (`build.lua:285-287`, `:333-346`, `:2183`, `:2202`) | none | client | None. In use today. |
| Select a piece | `BuildingUIAPI:CallOnBuildingItemSelected(data)` (`build.lua:348-356`) | one object pointer | client | None. In use today. |
| Enter and leave build mode | `ForceEnterBuildMode()`, `ExitAnyMode()` (UHT `BuildModeComponent.h:197`, `:200`) | none | client | Low. BlueprintCallable, no parameters. Not used anywhere in `client_mod`, `mod`, `tools` or `brain`. **UNVERIFIED** which mode `ForceEnterBuildMode` lands in and whether the input mode follows. |
| Select without the UI object | `OnPieceSelected(UBuildingPieceData*)` (UHT `BuildModeComponent.h:178`) | one object pointer | client | Low. A delegate handler; calling it skips whatever else listens to the UI event. |
| Aim | `SetControlRotation` on his own controller (`build.lua:364-372`) | one rotator | client | None. In use today. |
| Move the cursor without the camera | none exists | - | - | There is no reflected setter for the cursor, the helper's target or the preview transform. Moving `BuildingHelperActor` by hand would be overwritten by native code on its next update. **UNVERIFIED**, and it would not change what the press sends. |
| Distance, height and rotation modifiers | inject `ModifyDistanceAction`, `ModifyHeightAction`, `ModifyRotationAction` (UHT `BuildModeComponent.h:50-56`) | axis value | client | None. Rotation is used; distance and height are not. They move the preview along and off the ray without moving the camera, in steps of 0.4 and 0.05 (`docs/DISCOVERIES.md:1757-1765`), when the placement profile allows it. |
| Place at a transform, client | `Server_SpawnBuilding(index, FTransform, false, inventories)` | **FTransform and a TArray built in Lua** | client to server | High. See below. |
| Place at a location, server | `TrySpawnPieceAtLocation(data, FVector, FRotator)` | safe types | **server only** (BlueprintAuthorityOnly) | Usable only on a server we run. Not on Shockbyte, which stays vanilla. |
| Deconstruct | `Server_Interact(pieceId, 3, inventories, FVector)` | uint32, enum, TArray, FVector | client to server | `deconstruct.lua:11`, `:66-67`, `:1043` hooks it and uses the game's own press; it does not call it. |

### About calling `Server_SpawnBuilding` directly

It is what the game's own click ends in, so it is one call per piece with no camera at all. Three things stand against it.

1. **Struct risk.** CLAUDE.md: "Never send hand-built structs in Client_* RPCs" and "prefer property reads and copies of live engine structs over building structs in Lua". This is a Server RPC, not a `Client_*` one, but the transform and the array would still be built in Lua. A safer form exists: pre-hook the game's own call during a normal press and change only the translation and rotation of the live `FTransform` in place. That keeps the array and the struct layout the game's own.
2. **The rule against emulation.** CLAUDE.md, route R2: "No emulation of player systems; use the game's own client paths (UI handlers, Enhanced Input actions, character input calls)". Sending the RPC with a transform the client's placement code did not produce is exactly that. The server may or may not re-validate (overlap, snapping, distance, stability). **UNVERIFIED.** A piece the client could not have placed, on the group's Shockbyte world, is the kind of thing that rule exists to prevent.
3. **It is not needed for the speed.** Luis reaches 0.6-2 s per piece through the normal path. The slow part is our aiming, not the game's placement.

It belongs on the list as a decision for Luis, after a dev-server test, and not as the first thing to try.

## 5. Where the time goes

Source: `kind = tool_result`, `tool = build`, `result.data.phase_s` in `logs/brain-live-20261115-235756-19752.jsonl` and `logs/brain-live-20261116-002006-3844.jsonl`. The phases are timed in `client_mod/scripts/build.lua:2370-2396`; the order is approach, open, select, rotate, check, verify, leave (`build.lua:1748-1800`). The two logs hold 10 build results; 9 carry `phase_s` (the tenth was refused as `ambiguous_target` in 0 s).

### 5.1 Every result (seconds)

| Log:line | Call | Outcome | approach | open | select | rotate | check | verify | leave | sum |
|---|---|---|---|---|---|---|---|---|---|---|
| 235756:208 | batch of 8, 1 built | settling (0.05 m off) | 3.4 | 0.4 | 0.6 | 1.4 | 7.8 | 1.2 | 1.1 | 15.9 |
| 235756:255 | batch of 8, 1 built | preview_off_target (0.17 m) | 15.3 | 0.4 | 0.6 | 0.6 | 8.9 | 0.8 | 1.0 | 27.6 |
| 235756:273 | batch of 5, 0 built | Overlapping (ground rises 3.4 m) | 0.5 | 0.3 | 0.4 | 1.3 | 2.6 | 0.1 | 1.1 | 6.3 |
| 002006:92 | batch of 5, 1 built | ambiguous_target on item 2 | 0.5 | 0.3 | 0.3 | 0.5 | 18.9 | 0.4 | 1.1 | 22.0 |
| 002006:112 | batch of 4 walls, 0 built | settling (0.20 m) | 4.2 | 0.2 | 0.3 | 0.9 | 9.2 | - | 1.2 | 16.0 |
| 002006:126 | single wall :N | ok | 0.5 | 0.3 | 0.3 | 0.1 | 7.6 | 1.1 | 1.1 | 11.0 |
| 002006:138 | single wall :E | ok | 2.2 | 0.3 | 0.3 | 1.0 | 3.4 | 0.9 | 1.1 | 9.2 |
| 002006:150 | single wall :S | ok | 2.3 | 0.3 | 0.4 | 0.9 | 3.4 | 1.0 | 1.1 | 9.4 |
| 002006:170 | single door frame :W | preview_off_target (0.01 m) | 2.9 | 0.3 | 0.3 | 0.9 | 9.4 | - | 1.1 | 14.9 |

### 5.2 Means per group

| Group | n | approach | open | select | rotate | check | verify | leave | total | check share |
|---|---|---|---|---|---|---|---|---|---|---|
| Successful singles (two logs) | 3 | 1.67 | 0.30 | 0.33 | 0.67 | **4.80** | 1.00 | 1.10 | 9.87 | 49% |
| Failed single (two logs) | 1 | 2.9 | 0.3 | 0.3 | 0.9 | **9.4** | - | 1.1 | 14.9 | 63% |
| Stopped batches (two logs; 30 items asked, 3 placed) | 5 | 4.78 | 0.32 | 0.44 | 0.94 | **9.48** | 0.50 | 1.10 | 17.56 | 54% |
| Failed singles, all 24 logs of 15-16 Nov | 4 | 7.70 | 0.30 | 0.33 | 1.18 | **9.72** | - | 1.05 | 20.28 | 48% |
| One complete batch, 7 of 7 (`brain-live-20261116-003803-20116.jsonl:76`), per piece | 7 pieces | 5.1 | 0.14 | 0.23 | 0.47 | **6.1** | 1.0 | 0.16 | 13.2 | 46% |

The complete batch took 92.6 s in total: approach 35.5, check 42.8, verify 7.3, rotate 3.3, select 1.6, open 1.0, leave 1.1.

### 5.3 Reading

- **`check` dominates everywhere:** 3.4-7.6 s when it works, 8-19 s when it does not. This is the aim, settle and re-aim loop of section 2.3.
- **`approach` is second** and the most variable (0.5-15.3 s, one case of 26.7 s in the wider set). The skill walks to a stand point for each piece (`build.lua:1748-1800`). Luis placed 11 walls from one spot (`docs/DISCOVERIES.md:2731`).
- **A fixed 2.7 s per single call** goes on open, select, verify and leave. A batch pays open and leave once but still pays about 1 s of verify per piece (a census poll).
- **The failures are ours.** Reasons across the failed rows: settling 3, preview_off_target 2, not_snapped 2, Overlapping 1, ambiguous_target 1. In the settling and off-target cases the ghost was 0.01-0.20 m from the flush spot when the skill gave up. Only the Overlapping case was the game saying no.
- Successful runs log no `preview_reads`, so the trace of a good aim is not kept. The probe in candidate A should record it.

A human-standard budget would be: no approach when the next spot is in reach, about 1 s to aim, one press, and a confirmation that costs nothing. That is 1-2 s per piece in a batch, which matches the gaps in section 1.5.

## 6. Perception the client holds that the body does not use

Usage was checked by grepping `client_mod/scripts` and `client_mod/commands` for each name.

| Signal | Class and member | Evidence | Used today? | What it would give |
|---|---|---|---|---|
| The component the crosshair would interact with | `UInteractableDetectorComponent.CurrentInteractable` | UHT `InteractableDetectorComponent.h:56` | Yes (`inventory.lua`) | - |
| The exact collider hit | `.CurrentInteractableCollider` | :59 | **No** | Which part of an actor is focused. |
| The world actor in focus (non-interactable too) | `.CurrentWorldActor` | :62 | **No** | "What am I looking at" for free, at the detector's 0.1 s tick. |
| Focus-change events | `OnCurrentInteractableActorChanged`, `OnCurrentWorldActorChanged` | :22, :25 | **No** | An event in place of polling. Multicast delegates; binding from Lua is **UNVERIFIED**. |
| Detector ranges | `CameraRayLength`, `CharacterTraceDistance`, `InteractionRanges` | :35, :38, :32 | Read once (`docs/DISCOVERIES.md:2306`) | Predicting whether a thing is in reach before walking. |
| Whether an interaction is allowed, and why not | `UInteractionComponent.K2_IsInteractable(Player)`, `K2_ShouldShowInteractionPrompt(Player)` | UHT `InteractionComponent.h:142-143`, `:124-125` | **No** | A yes or no from the game's own conditions before pressing. |
| The prompt text for this player | `GetInteractionPrompt(const ADominionPlayerCharacter*)` (BlueprintPure), `InteractionPrompt`, `SecondaryInteractionPrompt` | :158-159, :65, :71 | Property yes; the function in one command only | The words the HUD would show ("Open", "Harvest"). |
| HUD prompt widget text | `UInteractionPromptWidget.ItemNameTextBlock`, `InventoryStateTextBlock`, `ItemAdditionalDescriptionTextBlock`, `SkillRequirementLevelTextBlock`, `InventoryFullText`, `InventoryEncumberedText` | UHT `InteractionPromptWidget.h:20-47` | **No** | What a player reads on screen, including "inventory full" and the skill level needed. |
| The server said no to an interaction | `UPlayerInteractionManager.Client_DeniedInteraction(UInteractionComponent*, bool)` | UHT `PlayerInteractionManager.h:45-46` | **No** | A truthful failure reason for chat. A Client RPC, so a post-hook should fire like the telemetry one. **UNVERIFIED.** |
| The server said no to a placement | `Client_ShowValidityNotification(EValiditySpawnState)` with `ValidityNotificationTextMap` | UHT `BuildInteractionComponent.h:100-101`, `:60` | The text map is read (`build.lua`); the hook is the `validity` hook, which DISCOVERIES `:1926` says does not fire for the local validity functions. Whether this Client RPC fires is **UNVERIFIED.** | The exact refusal reason after a press. |
| Build validity as a boolean on the tooltip | `UBuildingWorldTooltip.UpdateBuildingValid(bool)`, `UpdateSufficientResources(bool)`, `UpdateDestroyPossible(bool)` | UHT `BuildingWorldTooltip.h:91`, `:85`, `:88` | **No** | A valid or invalid signal separate from the MPC colour. Probably called natively, so a hook may not fire (**UNVERIFIED**); the widget's resulting state may be readable instead. |
| Tooltip texts | `GenericBuildModeText`, `CycleSnappingText`; `FBuildingWorldTooltipData.PieceName`, `RequirementList`, `ShelterRequirementText` | `BuildingWorldTooltip.h:57`, `:60`; `BuildingWorldTooltipData.h:13-25` | **No** | The piece name and what is missing, as the player sees them. |
| Snapping mode label | `WBP_Building_WorldTooltip_C.SetSnappingModeText(EBuildSnappingMode)`, `CycleSnappingModePressed()` | CXX `WBP_Building_WorldTooltip.hpp` | **No** | A UI path to change the snapping mode (Basic, Advanced, Free). |
| The piece under the preview | `UBuildModeComponent.PreviewSupportingPieceHandle` | UHT `BuildModeComponent.h:147` | **No** | Which piece the ghost will attach to. No reflected fields (section 1.2), so **UNVERIFIED** whether usable. |
| More MPC parameters | `CursorWorldDirectionMPN`, `PlacingStabilityRangeMPN`, `StabilityProviderRangeMPN`, `MinPieceDepthMPN`, `MaxPieceDepthMPN` | UHT `BuildModeComponent.h:99-117` | **No** (only position and validity index are read, `build.lua:375-388`) | The surface direction at the cursor and the stability range; a stability figure before placing. |
| Every placement by anyone | `ACellBuildingManager.NetMulticast_PlayConstructionSFX(int32 BuildPieceIndex, const FVector_NetQuantize& Location, const ADominionPlayerController* ConstructingPC, bool bIsGhost, bool bCompletingPiece)` and `NetMulticast_PlayDestructionSFX(...)` | UHT `CellBuildingManager.h:42-46` | **No** | An event with piece index, location and who placed it: an instant "it landed here" in place of the census poll, and a way to watch Luis build. |
| Own placement confirmed | `Client_TelemetryOnBuildingPieceComplete(bool, int32)`, `Client_TelemetryOnBuildingPieceGhostPlaced(int32)` | UHT `BuildModeComponent.h:204-208` | Hook proven (`docs/DISCOVERIES.md:1933`); not the verify path | Confirmation in one frame. |
| Materials still needed on a targeted ghost | `Client_UpdateTargetedPieceInspectionInfo(uint32, const FBuildingCompletionStatus&)`; `FBuildingCompletionStatus { ItemsNeeded, AmountNeeded, CurrentAmount }` | UHT `BuildInteractionComponent.h:97-98`; CXX `Dominion.hpp:1537-1543` | **No** | What a blueprint ghost still wants. |
| Where building is allowed | `UBuildingSubsystem.BuildableVolumes`, `bCenteredPlacement`, `PieceIDToBuildingPieceActor` | CXX `Dominion.hpp:16625-16635` | **No** | Legal build areas before trying. |
| The reticle type | `UReticleUIAPI.UpdateCurrentReticle()`, `HandleBuildingModeChanged()`; `EReticleType {Default, Stealth, RangedADS, Magic, Repair, AimedUtilityMagic, EquippedContainer, Fishing, PilotableTurret, Off}` | UHT `ReticleUIAPI.h:24-43`, `EReticleType.h:7-16` | **No** | The mode the HUD believes the player is in. |

The general limit stands: functions that C++ calls directly do not pass through `ProcessEvent`, so hooks on them stay silent (`docs/DISCOVERIES.md:1926`). RPCs (Client, Server, NetMulticast) do pass through it, which is why the telemetry hook works. The rows above that are RPCs are the ones most likely to work as events.

## Smooth path candidates

Ranked by expected speed-up against risk. Each has the smallest probe that would prove or kill it. All probes are read-only unless stated.

### A. Predict the camera and aim once (no feedback loop)

**Design.** Stop computing the aim from the camera's current position. Read the boom once (pivot world location, `TargetArmLength`, `SocketOffset`, `TargetOffset`), and solve for the control rotation at which the **settled** camera's ray passes through the aim point. This is a small closed-form or two-step numeric solve, since the camera position is a known function of the rotation. Before turning, do one line trace from the predicted camera position: check that it hits the intended piece on the intended face (hit normal up for a top face). If it does not, pick another stand point or aim point without waiting. After turning, wait for the camera to arrive (its position is known in advance, so "arrived" is a distance test, not a guess), read the MPC once and press on green. Optionally set `bEnableCameraLag` to false on his own boom while building; it is a client-local property on his own camera.

**Expected gain.** `check` from 4.8 s to about 1 s on singles; the settling and off-target failures go away because nothing is corrected by the miss. The side-face hits of section 2.6 are caught by the pre-trace.

**Risk.** Low. Property reads, one property write on his own camera component, line traces. No RPC, no struct in an RPC. Native-crash risk: none known.

**Probe.** One command, in build mode with a piece selected: call `SetControlRotation` once, then for 3 s log every frame the camera location and rotation, the boom's `TargetArmLength`, `SocketOffset`, `TargetOffset`, `bEnableCameraLag`, `CameraLagSpeed`, the MPC cursor, and a Lua line trace along the camera ray. It answers four things at once: whether the settled camera position matches the closed-form prediction, how long the camera really takes, whether the cursor lags the ray (native smoothing) or follows it exactly, and how often the cursor updates (section 2.4). Add reads of `PrimaryComponentTick.TickInterval` on `BuildModeComponent` and `BuildPlacementComponent`.

### B. Snap spots as data

**Design.** Build a table per piece type of its plugs (local transform, plug tag) and use `DT_PlugProfile` for which piece fits which plug. With the census (location and yaw of every piece) this gives, for any anchor, the list of free snap spots and the exact transform a new piece would take on each. The skill then aims anywhere inside the capture radius on the right face (section 3.4: 0.3 m to over 1 m of slack) and expects one known final transform. The census after the press is checked against that transform. This replaces most of the tolerance constants in `build.lua:232-268` with one question: is the cursor on the right face, within the radius.

**Expected gain.** Removes the door-on-frame and roof-on-wall-top failures if their plugs are simply somewhere the current geometry guess does not look. Makes batches plannable: all spots are known before the first press, so the skill can choose one stand point that reaches several.

**Risk.** Low. Reads only. If the plugs of structural pieces cannot be read, the table can be measured once per piece type from the census of Luis's base (`client_io/out/build_pieces_all.json`) and kept as a data profile, which is slower to make but has no risk.

**Probe.** One command on a loaded wall's piece data: (1) `DerivedData.NativeComponents.ComponentContainers` length and whether any element exposes `Plugs`; (2) the class default object of `BuildableActor` and its `BuildingSnapComponent.Plugs` length; (3) `DT_PlugProfile` row names and one row through `FindRow`; (4) `PlugVisualizationHost`'s components read through its `BlueprintCreatedComponents` / `InstanceComponents` arrays in place of `K2_GetComponentsByClass`, with the instance count. Then compare any plugs found with the offsets between adjacent pieces in the census.

### C. Cut the fixed overhead and the walking

**Design.** Four small changes that copy what Luis does. (1) Keep build mode open across a batch and across consecutive calls of the same piece; consider `ForceEnterBuildMode()` and `ExitAnyMode()` in place of key presses and waits. (2) Stand still and turn: choose a stand point that reaches as many of the batch's spots as possible (700 cm limit, section 2.1) and only walk when none is in reach. (3) Confirm by event: the post-hook on `Client_TelemetryOnBuildingPieceComplete` or on `NetMulticast_PlayConstructionSFX` (which carries the location) in place of a census poll of about 1 s. (4) Press at the game's own rate limit of 0.25 s, not after a settle timer.

**Expected gain.** About 2-3 s per single (open, select, verify, leave) and most of `approach` in batches (5.1 s per piece in the one complete batch).

**Risk.** Low. Parameterless BlueprintCallable functions and post-hooks on RPCs. `ForceEnterBuildMode` is untested: try it offline first, since `pcall` cannot catch a native crash.

**Probe.** Register post-hooks on the two functions during one ordinary placement and log the time of each against the time the census shows the piece. Separately, with no piece selected, call `ForceEnterBuildMode()` then read `CurrentBuildMode` and the input mode, then `ExitAnyMode()`.

### D. Send `Server_SpawnBuilding` with a known transform

**Design.** With the plug table from B, compute the final transform and place with one RPC per piece, no camera. The safer form is a pre-hook on the game's own call that edits the live transform in place; the riskier form builds the transform and the inventory array in Lua.

**Expected gain.** The largest: well under 1 s per piece, independent of camera and stand point.

**Risk.** The highest of the four, on three counts (section 4): a struct built or edited in Lua inside an RPC; unknown server-side validation; and it is emulation of the client's placement, against Luis's R2 rule, on the group's own world. It needs Luis's decision and a dev-server trial first. It should not be started while A to C are untried, because Luis's own pace shows the normal path can be fast enough.

**Probe.** Read-only and useful for B as well: a pre-hook on `Server_SpawnBuilding` during a normal UI placement that logs the index, the transform's translation and rotation, `bSpawnGhost` and the classes of the inventories in the array. It shows exactly what the client sends (including the four inventories), and it gives the snapped transform for every piece the skill places, which is ground truth for the plug table. No call is made by us. On the dev server only, `TrySpawnPieceAtLocation(data, FVector, FRotator)` is the safe-typed way to learn what the server accepts.

### Suggested order

A's probe first: it is one command, and it also settles the two UNVERIFIED points of section 2 (the slow tail and the stepping). Then B's probe and D's read-only hook together, since the hook validates B. C can be done in parallel; it does not depend on the others.
