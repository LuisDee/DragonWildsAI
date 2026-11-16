# Placement without camera servoing: what others do (2026-11-16)

Research only. Nothing here was run against the game. Anything not confirmed from a primary source is marked **UNCONFIRMED**.

**The question.** Our build skill swings the camera, watches the game's placement cursor glide, corrects, waits and presses. It costs 10 to 12 s per piece against a human's 3.8 s, and batches fail. What is the idiomatic way, and has someone already done it for Dragonwilds?

**The short answer.**

1. Three independent open-source Dragonwilds mods place pieces from client-side UE4SS Lua by calling `BuildModeComponent:Server_SpawnBuilding(index, transform, bGhost, {inventory})` with an explicit transform. None of them drives the camera. One of them (WildPlans) documents this working from an unmodded-server client on a dedicated server, 464 pieces in one run.
2. Snap points exist as data: `BuildingSnapComponent.Plugs[]` on each piece, a published `Snaps.json` for 796 pieces, and a 150 cm lattice.
3. Every comparable game and every mature bot does the same thing: compute the target transform as data, hand it to the engine in one call, verify from state. Nobody servoes on a lagging cursor.
4. That route conflicts with our own rule as written in `docs/design/build-primitive.md` (no hand-built structs in `Server_*` RPCs). Section 6 ranks the options, including two that stay inside the rule.

How the research was done: about 40 distinct web searches, plus reading source in repositories and one release zip (read as text, never executed). The list of query themes is at the end.

---

## 1. Dragonwilds open-source tooling

### 1.1 Building mods (the ones that matter)

| Tool | Licence | What it does | Game classes, functions and properties it touches |
|---|---|---|---|
| [kaedon78/WildPlans](https://github.com/kaedon78/WildPlans) (v0.1.4, source in the [release zip](https://github.com/kaedon78/WildPlans/releases/download/v0.1.4/WildPlans-v0.1.4.zip)) | MIT | Client-only UE4SS Lua blueprint mod: capture a build, replay it as ghosts or real pieces, undo. | `FindFirstOf("DominionPlayerController")`, `pc:GetBuildModeComponent()`, `bmc:Server_SpawnBuilding(...)`, `FindFirstOf("GlobalBuildingManager")`, `GlobalBuildingManager.BuildingPieces` (`TMap<uint32, FBuildingPieceState>`, `.ClientVisible` and `.ServerOnly`), `pc.InventoryComponent`, each piece's `_DerivedData`, `pc:HasAuthority()`. |
| [adamspiteri/RSDWCustomBuilds](https://github.com/adamspiteri/RSDWCustomBuilds) | MIT | UE 5.6 modder kit for custom building pieces. | `bmc.PreviewPiece` (weak pointer), `preview:K2_SetActorLocation` / `K2_SetActorRotation`, `bmc:Server_SpawnBuilding(idx)`, `bmc:TrySpawnPieceAtLocation(da, loc, rotator)`, the building subsystem catalogue. |
| [ThePaulAdams/RSDragonwilds-Tools](https://github.com/ThePaulAdams/RSDragonwilds-Tools) (`CustomBuilds/scripts/main.lua`) | MIT | Places custom models, and can commit them as native pieces. | `RegisterHook("/Script/Dominion.BuildModeComponent:Server_SpawnBuilding", ...)`, `comp.CurrentlyPlacingPieceData`, `comp.BuildingHelperActor`, `KismetSystemLibrary:LineTraceSingle` from the camera, `comp:Server_SpawnBuilding(pieceIdx, xf)`, `Default__BuildingSettings.LoadedGhostMaterial`. |
| [RSDWArchive/RSDWBaseBuilder](https://github.com/RSDWArchive/RSDWBaseBuilder) | none listed | Blender add-on for planning bases offline. Ships extracted game data. | Data only: `addon/data/Snaps.json` (snap plugs per piece), `PieceDataMap.json`, `StabilityMap.json`, `StabilityProfileMap.json`, `BPMap.json`, built by `tools/ModelData/BuildSnaps.py` from CUE4Parse dumps. |
| [Kein/RSDragonwilds](https://github.com/Kein/RSDragonwilds) | MIT | A UProject with reflected headers (an older build, last updated April 2025). | Headers for `UBuildModeComponent`, `UBuildPlacementComponent`, `UBuildingSnapComponent`, `FPlacementProfile`, `UBuildInteractionComponent`, `UBuildingSettings`, `EValiditySpawnState`. |

**What WildPlans proves.** Its README says "the mod runs on your client only; nothing is installed on the server" and that on a dedicated server it tested "capture, ghost and real placement, a 464-piece placement, undo, and all of it again after a server restart" ([README](https://github.com/kaedon78/WildPlans)). The placing call in `Scripts/replay.lua` is:

```lua
ctx.bmc:Server_SpawnBuilding(live, {
    Rotation    = t.rot,
    Translation = { X = t.pos.X, Y = t.pos.Y, Z = z_traced or t.pos.Z },
    Scale3D     = t.scale,
}, (ghost or t.ghost) and true or false, { inv })
```

The same file records the signature it calls and a caveat:

```
-- Server_SpawnBuilding takes only a transform, no supporting-piece handle
-- (the game's own build path carries PreviewSupportingPieceHandle):
--     void Server_SpawnBuilding(int32 InBuildingPieceDataIndex,
--                               const FTransform& SpawnTransform,
--                               const bool bSpawnGhost,
--                               const TArray<UInventoryComponent*>&);
```

Facts the WildPlans source measured and wrote down (all from the [release zip](https://github.com/kaedon78/WildPlans/releases/download/v0.1.4/WildPlans-v0.1.4.zip), files `replay.lua`, `placemode.lua`, `registry.lua`, `util.lua`):

- The call must run on the game thread (`ExecuteInGameThread`); keybind callbacks and `ExecuteWithDelay` do not, and spawning off the game thread crashes the game.
- The server rejects a piece that nothing supports, so order matters: lowest Z first, then by piece type, then nearest the anchor, with up to five retry passes.
- Pacing: 300 ms per piece, a 2 s pause after each 25. "50 ms/piece crashed large solo replays."
- Results stream back throttled, so it polls the registry until it is stable (1 s polls) and does not use a fixed wait.
- The inventories array must hold the player's inventory: "An empty AvailableInventories silently destroys every piece after creating it."
- Reach is about 175 m ("175 m stood, 200 m arrived absent").
- Props must be sunk 4.5 cm or the stability pass destroys them even though the state was `Valid`.
- A foundation's origin must be above its own ground "with no tolerance": 4 cm below was torn down as Unstable.
- Every piece type's `_DerivedData` must be loaded first, and an index the game does not have crashes the game.
- `GlobalBuildingManager.BuildingPieces` "populates on a client with no authority, and TMap:ForEach works there". Reading UPROPERTYs inside the iteration callback hard-crashes the game, so it collects handles first.
- Snapping is computed as pure data in `placemode.lua`: a 150 cm lattice (`M.GRID = 150.0`, "Building snaps to a 150-unit (1.5 m) grid in X and Y"), nearest quarter-turn yaw, edges aligned to the neighbour's lattice using half-extents from a bounds table, ground from its own downward trace.
- Real (paid) placement in normal worlds existed and was removed from the key bindings in v0.1.1; the current release offers real placement in Creative worlds and ghosts elsewhere ([changelog in the README](https://github.com/kaedon78/WildPlans)).

**What the other two add.**

- RSDWCustomBuilds moves the game's own preview actor (`bmc.PreviewPiece`, then `K2_SetActorLocation`), and then says in `Mod/Scripts/build.lua`: "Do not use the game's native confirm path here: it leaves placed pieces as construction ghosts and keeps the player in continuous build mode. Use the working mod's direct-spawn style instead: preview for aiming, E/click Server_SpawnBuilding once, then exit build mode." ([repo](https://github.com/adamspiteri/RSDWCustomBuilds)). That comment is about its custom pieces. Whether the native confirm honours a moved preview for vanilla pieces is **UNCONFIRMED**.
- ThePaulAdams hooks `Server_SpawnBuilding` on the client and reads the transform the game itself sent when the player places a piece normally ([main.lua](https://github.com/ThePaulAdams/RSDragonwilds-Tools/blob/main/CustomBuilds/scripts/main.lua)). This is evidence that the game's own click ends in this RPC. Our own referee already registers a post-hook on the same function (`docs/DISCOVERIES.md`, "Referee v1.2 hooks").
- The same file runs its own camera trace (`LineTraceSingle` from the camera location along the camera forward vector, ignoring the pawn) to find the surface under the crosshair. It does not wait for the game's cursor.

**Snap points as data.** `UBuildingSnapComponent` carries `TArray<FPlug> Plugs`, `SnappingRadius` and `SnappingRadiusInBasicSnappingMode` ([Kein headers](https://github.com/Kein/RSDragonwilds)). RSDWBaseBuilder publishes the extracted plugs for 796 pieces as `{piece_tag, plugs:[{piece_tag, plug_tag, piece_ign[], plug_ign[], pos[x,y,z cm], rot[quaternion]}]}` and states the rule: two plugs connect when neither plug's tag is in the other's `PlugIgnoringTypes` and neither piece's tag is in the other's `PieceIgnoringTypes` ([BuildSnaps.py and Snaps.json](https://github.com/RSDWArchive/RSDWBaseBuilder)). Plug tags in that file: BaseBeam 1891, Base 1151, Surface 371, Beam 280, Hinge 39, WindowStatic 10, HingeLarge 6.

**Placement rules as data.** `FPlacementProfile` (a data table row) holds `bCanOnlyBeSnapped`, `bForcePlugRotation`, `bCanOnlyBePlacedOnDefinedSurface`, `SurfacePlacementNormal`, `AcceptedPhysicalSurfaces`, `bAllowOverlappingWithBuildingPieces`, `MagnetizingMultiplier`, `OverlappingBoundsMultiplier` and the user-modifier flags ([Kein headers](https://github.com/Kein/RSDragonwilds)). `UBuildModeComponent` also owns the input actions `ModifyRotationAction`, `ModifyHeightAction`, `ModifyDistanceAction`, `FreePlacementModifierAction` and a `SnappingMode` (Basic, Advanced, Free). The header set is from an older build; confirm each name in our dump.

### 1.2 Other tooling (not about placement)

| Tool | Licence | What it does | Touches |
|---|---|---|---|
| [Ashenfall Renovator](https://www.curseforge.com/runescape-dragonwilds/ue4ss-mods/ashenfall-renovator) | MIT, no source link | Swaps the material tier of up to 20 placed pieces. UE4SS scripts plus a native DLL. | Not published. **UNCONFIRMED**. |
| [Camera Offsets](https://www.curseforge.com/runescape-dragonwilds/ue4ss-mods/camera-offsets) | All rights reserved | Changes the third-person camera. | States the game's camera defaults: distance 700 cm, left/right 20 cm, height 0, look-at height 120 cm. Useful for section 4. |
| [More world settings](https://www.curseforge.com/runescape-dragonwilds/pak-mods/more-world-settings-more-standard-custom-creative) | see page | Adds world settings, including building stability. | Pak data. |
| [gh0sted5456-us/RuneSchema](https://github.com/gh0sted5456-us/RuneSchema) | MIT | Runtime schema and data editing framework (C++, installs as a UE4SS mod). | Data tables. |
| [dkoz/RSDWServerAPI](https://github.com/dkoz/RSDWServerAPI) | MIT | REST API for Linux dedicated servers (players, kick, broadcast, give, ban). | Server-side, LD_PRELOAD. No building endpoints. |
| [joaophi/rsdw-server-patches](https://github.com/joaophi/rsdw-server-patches) | MIT | Binary hotfixes for the server. | Not usable under our rules. |
| [BirdRa1n/DragonwildsServerKit](https://github.com/BirdRa1n/DragonwildsServerKit) | MIT | Server set-up kit. | Ops only. |
| [brucestarlove/Dragonwilds-UE4SS-AI-devkit](https://github.com/brucestarlove/Dragonwilds-UE4SS-AI-devkit) | MIT | Devkit for writing UE4SS mods with AI help. | General. |
| [Djassie18698/dragonwilds-resource-map](https://github.com/Djassie18698/dragonwilds-resource-map), [weisuoyuzai/RSDragonwilds-LiveMap](https://github.com/weisuoyuzai/RSDragonwilds-LiveMap) | GPL-3.0 / see repo | Resource and live maps. | Map data. |
| [RSDWArchive/RSDWArchive](https://github.com/RSDWArchive/RSDWArchive) | see repo | Archive of the game's JSON and textures per version. | A data source for plugs, bounds and profiles after each patch. |

Notes:

- No Dumper-7 style SDK dump for the current build turned up. The Kein headers are the nearest thing and are old.
- Nexus mod 49 (longer support distance) returned HTTP 403, so its details are **UNCONFIRMED**.
- Several GitHub repositories copy WildPlans' name or advertise "trainers" with inflated stars. Treat them as malware lures and do not download them.
- Jagex's [Community Modding Guidelines](https://legal.jagex.com/docs/policies/runescape-dragonwilds-community-modding-guidelines) ban paid mods and cheating in shared play. The game has an official [Creative Mode](https://dragonwilds.runescape.com/news/creative-mode).

---

## 2. How building mods in other games place pieces

The three styles: (a) a place function or server RPC with an explicit transform; (b) set the preview's transform, then confirm through the game's own path; (c) drive the camera.

| Game | Engine | Style | Evidence |
|---|---|---|---|
| Dragonwilds (WildPlans, CustomBuilds, RSDWCustomBuilds) | UE 5.6 | (a), with (b) used only for aiming | Section 1. |
| Satisfactory | UE5 | (b) inside the engine, (a) on the wire | The hologram is positioned from the build gun's hit result by `SetHologramLocationAndRotation(const FHitResult&)`; snapping is `TrySnapToActor(const FHitResult&)`, and "if the method returns true, the hologram location and rotation will not be updated automatically" ([Buildable Holograms](https://docs.ficsit.app/satisfactory-modding/latest/Development/Satisfactory/BuildableHolograms.html), [FGHologram.h](https://github.com/satisfactorymodding/SatisfactoryModLoader/blob/master/Source/FactoryGame/Public/Hologram/FGHologram.h)). The click then sends the hologram's own data: `UFUNCTION(Server, Reliable) void Server_ConstructHologram(FNetConstructionID, FConstructHologramMessage data)`, "RPC to construct from hologram data" ([FGBuildGunBuild.h](https://github.com/satisfactorymodding/SatisfactoryModLoader/blob/master/Source/FactoryGame/Public/Equipment/FGBuildGunBuild.h)). Holograms also have `NudgeHologram` and `ScrollRotate`, so the pose can be set without the camera. |
| Valheim PlanBuild | Unity | (a) | `PlaceBlueprint` takes the ghost's transform as the frame and instantiates each piece directly: `entryPosition = transform.TransformPoint(entry.GetPosition())`, `entryQuat = transform.rotation * entry.GetRotation()`, `Instantiate(prefab, entryPosition, entryQuat)` ([PlacementComponent.cs](https://github.com/sirskunkalot/PlanBuild/blob/master/PlanBuild/Blueprints/Components/PlacementComponent.cs)). Snap points are saved with the blueprint as data (`SnapPointEntry.cs` in the [same folder](https://github.com/sirskunkalot/PlanBuild/tree/master/PlanBuild/Blueprints)). |
| Valheim Infinity Hammer | Unity | (b) | Freezes the ghost, then moves it with `hammer_move` (forward, up, right offsets), restricts it with `hammer_grid`, and places with `hammer_place` ([Thunderstore page](https://thunderstore.io/c/valheim/p/JereKuusela/Infinity_Hammer/), [source](https://github.com/JereKuusela/valheim-infinity_tools)). |
| Palworld Perfect Placement | UE5 | (b) | "Perfect Placement only edits the temporary preview. Final construction remains on Palworld's normal validation and placement path." ([Nexus](https://www.nexusmods.com/palworld/mods/3884)). |
| Palworld Better Base Building and others | UE5 | relax validation | These loosen checks (height, slope, overlap) and do not change how the pose is chosen ([CurseForge](https://www.curseforge.com/palworld/lua-code-mods/better-base-building)). The related Better Base Range page warns that on a dedicated server the client can show a valid preview and the server still rejects the piece. Palworld's build request RPC names are **UNCONFIRMED**; no source surfaced. |
| Windrose BetterBuildingTools | UE5, UE4SS | (b) | Adds rotation steps to the game's own rotation cycle and a "Copy Angle" that sets the preview's rotation; the placed piece uses the set angle even when the ghost has not redrawn ([CurseForge](https://www.curseforge.com/windrose/ue4ss-mods/betterbuildingtools-bbt)). |
| Enshrouded, Sons of the Forest | not Unreal | n/a | Out of scope for code-level comparison. No open-source placement mod was found. **UNCONFIRMED**. |
| Icarus, Abiotic Factor, Nightingale, Grounded, ARK, Conan Exiles, Smalland | UE | **UNCONFIRMED** | Searches found mod pages that relax placement rules, and no open source showing the placing call. |

**The pattern.** No mod found in any game drives the camera to place. They either call the engine's place function with a transform, or set the preview's transform and let the game confirm. Snapped transforms are computed from data: the neighbour's transform composed with a socket or plug transform, or a grid lattice. Satisfactory's design is the clearest statement of why this works: the preview is the client's own object, the pose is whatever the client says it is, and the server validates the pose it receives. A dedicated server never sees the camera.

---

## 3. How bots aim and interact without a feedback loop

**Minecraft, mineflayer.** `bot.lookAt` is closed-form: `yaw = Math.atan2(-delta.x, -delta.z)`, `pitch = Math.atan2(delta.y, groundDistance)` from the eye to the target. With `force` it sets the sent angles at once and returns; without it the sent yaw steps towards the target at a capped rate and the promise resolves when the sent yaw matches ([physics.js](https://github.com/PrismarineJS/mineflayer/blob/master/lib/plugins/physics.js)). The steps exist "so that notchian clients (not the server) can keep up", so the smooth turn is for onlookers.

**Placing is not aiming.** `placeBlock(referenceBlock, faceVector)` names the target: the block to build against and the face. The packet carries the reference position, the face and a cursor offset computed as `0.5 + faceVector * 0.5`. Looking is a separate, optional step: `forceLook: 'ignore'` skips it ([generic_place.js](https://github.com/PrismarineJS/mineflayer/blob/master/lib/plugins/generic_place.js)).

**Baritone: predict the engine's own trace.** `calcRotationFromVec3d` computes yaw and pitch with `atan2`. `reachableOffset` then runs the game's own ray trace with that rotation (`RayTraceUtils.rayTraceTowards`) and accepts it only `if (result.getBlockPos().equals(pos))`. `reachable` tries the block centre first, then each face offset ([RotationUtils.java](https://github.com/cabaletta/baritone/blob/master/src/api/java/baritone/api/utils/RotationUtils.java)). It never looks first and reads back where the crosshair ended up. It asks the engine, in advance, what a given rotation would hit.

**LLM agents on top.**

- Voyager's `placeItem(bot, name, position)` finds a non-air neighbour as the reference block, paths with `GoalPlaceBlock`, calls `placeBlock`, and reports plain reasons: "No block to place X on. You cannot place a floating block." ([placeItem.js](https://github.com/MineDojo/Voyager/blob/main/voyager/control_primitives/placeItem.js)).
- Mindcraft's `placeBlock(bot, blockType, x, y, z, placeOn)` picks `buildOffBlock` and `faceVec` from a direction list, steps out of the way if the bot stands in the target, walks into range if further than 4.5 blocks, then `lookAt` and `placeBlock` ([skills.js](https://github.com/kolbytn/mindcraft/blob/main/src/agent/library/skills.js)).
- In both, the model gives a position and a preferred side. The model never aims.

**Unreal automation frameworks.**

- The Automation Driver finds a UI element by id (`Driver->FindElement(By::Id("Submit"))->Click()`), then moves a virtual cursor to it ([Epic docs](https://dev.epicgames.com/documentation/unreal-engine/automation-driver-in-unreal-engine)). The target is named; the cursor is a detail of execution.
- UnrealCV exposes objects and the camera as commands: `vget /objects`, `vget /object/[name]/location`, `vset /camera/[id]/rotation` ([command reference](https://unrealcv.readthedocs.io/en/latest/reference/commands.html)). State is read and set directly.
- The Unreal MCP servers ([chongdashu/unreal-mcp](https://github.com/chongdashu/unreal-mcp), [ChiR24/Unreal_mcp](https://github.com/ChiR24/Unreal_mcp)) give the model tools that spawn actors and set their transforms in the editor. They are editor tools, not gameplay clients, but the tool shape is the same: named object, explicit transform.

**The accepted pattern, in four steps.**

1. Compute the action's target as data (which piece, which socket or face, what transform).
2. If the engine insists on a look direction, compute it in closed form and check it with the engine's own trace before acting.
3. Send one action that names the target.
4. Verify from world state.

A loop that observes a lagging cursor and corrects is not found in any of these projects.

---

## 4. Why an Unreal placement preview lags the aim, and the fixes

### 4.1 Engine causes

- **Camera cache is a frame behind for early readers.** The controller applies rotation in `TG_PrePhysics`; `APlayerCameraManager::UpdateCamera` fills the camera cache in `TG_PostPhysics`. Code that reads camera-derived values earlier in the frame gets last frame's view ([forum analysis](https://forums.unrealengine.com/t/convertworldlocationtoscreenlocation-frame-lag/348453)). The control rotation itself is updated at once. The order is one developer's reading of the source, so treat the exact groups as **UNCONFIRMED** for UE 5.6.
- **Spring arm lag.** `USpringArmComponent` has `bEnableCameraLag`, `bEnableCameraRotationLag`, `CameraLagSpeed`, `CameraRotationLagSpeed`, and `bUseCameraLagSubstepping` with `CameraLagMaxTimeStep` ([API page](https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/Engine/USpringArmComponent)). Substepping exists because the lag is frame-rate sensitive; with it on and a max step of 1/60 the camera should behave as at 60 fps even when the frame rate is lower ([UE-216449](https://issues.unrealengine.com/issue/UE-216449), [forum](https://forums.unrealengine.com/t/spring-arm-stuttering/2682588)). With rotation lag on, a ray from the camera trails the control rotation.
- **`FInterpTo` is frame-rate dependent.** The engine code is `DeltaMove = Dist * FMath::Clamp(DeltaTime * InterpSpeed, 0, 1)` ([quoted in this thread](https://forums.unrealengine.com/t/finterpto-over-time/402124)). Each frame closes a fraction of the remaining distance, so the approach is exponential, and the time to arrive depends on the frame time ([forum](https://forums.unrealengine.com/t/how-to-make-vinterp-to-fps-independent/614764)). `VInterpToConstant` moves at a fixed speed instead.
- **Tick intervals.** Any actor or component can tick slower than the frame (`PrimaryActorTick.TickInterval`, `PrimaryComponentTick.TickInterval`). A preview that updates on a slow tick looks like a cursor that moves in steps.
- **Unfocused and headless windows.** "Use Less CPU when in Background" is an editor setting and does not apply to packaged games. `t.IdleWhenNotForeground` defaults to 0; set to 1 it stops an unfocused app updating. Reports on whether packaged games throttle when unfocused are mixed ([thread 1](https://forums.unrealengine.com/t/packaged-game-drops-fps-when-not-focused/580679), [thread 2](https://forums.unrealengine.com/t/framerate-drop-when-packaged-game-out-of-focus/420348)).
- **Render-gated logic.** Code gated on `WasRecentlyRendered` or on visibility-based tick options runs less or not at all when nothing is drawn ([API](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/UPrimitiveComponent/WasRecentlyRendered), [forum](https://forums.unrealengine.com/t/visibilitybasedanimtickoption-not-working-as-expected/450700/4)). Whether Dragonwilds gates its placement helper this way is **UNCONFIRMED**.

### 4.2 What this suggests about our numbers (hypotheses, all UNCONFIRMED)

- **The 0.2 m sideways miss.** The Camera Offsets mod states the game's camera sits 20 cm to the side by default ([page](https://www.curseforge.com/runescape-dragonwilds/ue4ss-mods/camera-offsets)). If the placement trace starts at the camera and our aim is computed from the pawn, a 20 cm lateral error is expected. That is parallax, and it is closed-form.
- **The 1 m/s glide.** A constant-speed glide is what `VInterpToConstant` produces; an exponential ease would be `VInterpTo`. Either way the helper is interpolating towards a target the game already knows. The target is the thing to read, or to compute ourselves.
- **Updates every 0.5 to 1.4 s.** At 30 fps a per-frame update would come every 33 ms. A cadence of half a second or more points at a tick interval, a timer, or throttling, not at the frame cap. Our own `tickguard.lua` raises one subsystem's tick interval to 3600 s; check that nothing else on the build path has a long interval.

### 4.3 The standard way to make an aim change count next frame and to know where the ray lands

- Set the control rotation (`SetControlRotation`). It takes effect on the controller at once. If the spring arm uses pawn control rotation with no rotation lag, the camera has it at the next camera update.
- Wait one full frame, then read the camera from the camera manager (`GetCameraLocation`, `GetCameraRotation`, or `GetPlayerViewPoint`). Epic's docs point at `GetPlayerViewPoint` as the call to prefer ([GetCameraViewPoint](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/APlayerCameraManager/GetCameraViewPoint)).
- Run our own `LineTraceSingle` from that point along that direction, ignoring the pawn. This is what CustomBuilds does in Lua ([main.lua](https://github.com/ThePaulAdams/RSDragonwilds-Tools/blob/main/CustomBuilds/scripts/main.lua)). `DeprojectScreenPositionToWorld` and `GetHitResultUnderCursor` give the same ray for a screen point, and need a viewport, which a headless client may not have in a useful form.
- Better still, do the trace before turning: for a candidate rotation, compute the ray from the known camera offset and trace it. That is Baritone's `reachableOffset` pattern.

---

## 5. Perception for LLM agents without pixel or camera servoing

- **SayCan.** The model scores which skill is useful; a learned affordance function scores which skill is possible in the current state; the product picks the action ([paper](https://arxiv.org/abs/2204.01691)). The lesson: feasibility comes from the body, per candidate.
- **Set-of-Mark.** Regions get numbered marks, and the model answers with a number ([paper](https://arxiv.org/abs/2310.11441)). The lesson: give candidates ids and let the model pick an id.
- **SayPlan.** The model receives a JSON scene graph, expands and contracts it to find the relevant part, and its plan is checked in a scene-graph simulator and corrected before execution ([paper](https://arxiv.org/abs/2307.06135)). The lesson: a text graph of the scene scales, and a cheap dry run catches impossible steps.
- **Grasp candidates in robotics.** A generator proposes many grasps with confidence scores, and a later stage filters and picks ([Contact-GraspNet](https://arxiv.org/abs/2103.14127), [code](https://github.com/NVlabs/contact_graspnet)). The lesson: generate, filter for collision and reach, then choose.
- **Mindcraft and Voyager.** The tool takes a position and a preferred side; the body finds the reference block, moves, and reports a specific reason on failure (section 3).

**A reusable pattern for us: candidates in, id out, one step.**

1. **Enumerate.** The body lists every free plug within reach, from live `BuildingSnapComponent.Plugs` on nearby pieces (or `Snaps.json` composed with each piece's location and yaw from `GlobalBuildingManager.BuildingPieces`). For ground pieces it lists lattice cells (150 cm) with a ground height from a downward trace.
2. **Filter.** For each candidate and each piece the agent holds materials for, apply the plug compatibility rule and the piece's `FPlacementProfile` (snap-only, surface normal, accepted surfaces). Mark support (is there a piece under or beside it), overlap from bounds, and reach.
3. **Present.** Give the model a short list: `id`, what it attaches to in plain words ("top edge of the north wall", "floor cell east of the door"), which pieces fit, and `reachable: yes/no` with a reason. No coordinates are needed in the prompt.
4. **Pick.** The model answers with an id and a piece. No phrase tables, no code veto: an infeasible id returns the reason.
5. **Execute.** The body turns the id into a transform and places in one deterministic step (section 6).
6. **Verify.** Read the registry until the piece appears at the expected place, as WildPlans does, and report the truth.

The same shape fits stations, chests and targets: the body lists interactables with ids and reach, the model picks an id, the body does one call and reports. Our earlier note `docs/research/2026-11-01-autonomous-building.md` covers the planning side; this adds the candidate list and the one-step execution.

---

## 6. Ranked recommendation, with the smallest experiment for each

The rule conflict first. `docs/design/build-primitive.md` rejected `Server_SpawnBuilding` because it is an RPC with a hand-built `FTransform`. The rule came from a `Client_*` RPC freezing Luis's client. The evidence now is that three public mods send exactly this RPC with a Lua-built transform, one of them 464 pieces on a dedicated server. That lowers the crash risk; it does not settle whether the call counts as "what the client does on a click". Experiment 0 answers that, and options 1 and 2 are ordered so that the first one stays inside the rule as written.

**Experiment 0 (do first, 10 minutes, no risk): hook the game's own click.** Register a hook on `/Script/Dominion.BuildModeComponent:Server_SpawnBuilding` on Claude's client (CustomBuilds does this, and our referee already has a post-hook). Place one piece with the current skill. Log the index, the transform, the ghost flag and the inventories. This tells us: whether the click path is this RPC; what the transform looks like for a snapped piece (lattice-aligned or not); which inventories the game passes; and how long after the press the call is made. Every option below uses these facts.

### Rank 1. Set the game's preview, then press the game's own place input (style b)

- **What.** Enter build mode and select the piece as now. Compute the target transform from plug data. Move the preview with `PreviewPiece:K2_SetActorLocation` and `K2_SetActorRotation` (what RSDWCustomBuilds does), or use the game's own modifier inputs (`ModifyRotationAction`, `ModifyHeightAction`, `ModifyDistanceAction`, `FreePlacementModifierAction`). Press place. Verify from the registry.
- **Why first.** No RPC is called by us, and no struct is sent. The game's own confirm path runs, with its own validation and its own supporting-piece handle. It is how Palworld Perfect Placement, Infinity Hammer and Satisfactory's nudge work.
- **Risk.** The game may overwrite the preview on its next placement tick, or validate against its own cursor and ignore the moved actor. RSDWCustomBuilds chose not to use the native confirm for its custom pieces.
- **Smallest experiment.** In build mode with a wall selected, aim at open ground, move the preview 1.5 m to a known foundation edge, read it back after 0.1 s, 0.5 s and 1.5 s, then press place. Pass: the piece appears at the moved pose in the registry. If the pose is overwritten, note the period; that period is the placement tick, which also explains the 0.5 to 1.4 s cadence.

### Rank 2. Call `Server_SpawnBuilding` with a transform the engine built (style a, rule-compatible form)

- **What.** As rank 1 up to the moved preview. Then read the transform back from the engine (`PreviewPiece:GetTransform()`), and pass that live struct, the live index, `false`, and `{pc.InventoryComponent}` (or the inventories seen in experiment 0) to `bmc:Server_SpawnBuilding` on the game thread. No camera, no cursor, no settle wait.
- **Why.** It is the route all three Dragonwilds mods use, proven on a dedicated server from a client. The transform is a copy of a live engine struct, which is what CLAUDE.md asks for. If experiment 0 shows the click sends this RPC, we are sending what a click sends.
- **Cost to expect.** WildPlans paces at 300 ms per piece. A human takes 3.8 s. Ordering (supports first), a non-empty inventories array, preloaded `_DerivedData`, the 4.5 cm prop sink and foundation origin above ground all apply.
- **Risk.** A decision for Luis: it changes the design doc's rule. The server remains the judge (materials, support, stability), so it is not an emulation of a player system, but it does skip the client's preview validation. Never run the first trial on Shockbyte.
- **Smallest experiment.** On the dev world, one ghost piece (`bSpawnGhost = true`), transform copied from the preview. Pass: the registry shows a ghosted piece with that index at that location within a few seconds. Then one real foundation, then a wall on it, then the batch of seven.

### Rank 3. Keep the camera, but predict instead of observe (style c, done properly)

- **What.** For a target point, compute the control rotation in closed form from the real camera position (include the 20 cm side offset and the arm length), run our own `LineTraceSingle` along that ray, and adjust until our trace hits the wanted point. Set the rotation once, wait for one placement tick, press. Do not read the gliding helper at all, except once to confirm validity.
- **Why.** It needs no new permission and removes the correct-and-wait loop. It is Baritone's pattern.
- **Limit.** It still pays one placement tick per piece, and it depends on reproducing the game's snapping from an aim point.
- **Smallest experiment.** Log, for ten aims, three numbers: where our own camera trace lands, where the helper settles, and the time to settle. If our trace predicts the settled helper to within a few centimetres, the feedback loop can go.

### Rank 4. Find and fix the cadence

- **What.** Read `PrimaryComponentTick.TickInterval` on the build mode and build placement components and `PrimaryActorTick.TickInterval` on `BuildingHelperActor`; read the spring arm's lag flags; compare the helper's update cadence with the client focused, unfocused and at a different frame cap.
- **Why.** If a tick interval or background throttling causes the 0.5 to 1.4 s steps, every skill that waits on a client-side cursor (stations, chests, targets) gets faster at once.
- **Smallest experiment.** One read-only Lua probe that prints those properties and timestamps ten helper position changes.

### Rank 5. The candidate list for the brain (independent of 1 to 4)

- **What.** Section 5's enumerate, filter, present, pick. Build it from live `Plugs` where the client has the component, falling back to `Snaps.json` for structural pieces that have no client actor.
- **Smallest experiment.** Offline: load `Snaps.json`, take the dev base's registry snapshot, list free compatible plugs for "stone wall", and check by eye against five positions where Luis placed walls. Then one small real-model eval: given the list, does the model pick the id a human would?

### Decision record

- Need: place building pieces at a human's speed without servoing on the cursor.
- Searched: Dragonwilds mods and tools on GitHub, CurseForge and Nexus; building mods for Satisfactory, Palworld, Valheim, Windrose and others; mineflayer, Baritone, Voyager, Mindcraft; Unreal camera, interpolation and tick behaviour; SayCan, Set-of-Mark, SayPlan, grasp candidates.
- Found: WildPlans, RSDWCustomBuilds, CustomBuilds (all MIT) and RSDWBaseBuilder's snap data.
- Decision: adapt. Reuse WildPlans' measured constraints and the published plug data; choose between rank 1 and rank 2 after experiment 0. Rank 2 needs Luis's say on the rule.

---

## Search log (themes)

About 40 distinct queries. Themes: Dragonwilds mods on GitHub, CurseForge, Nexus and Thunderstore; Dragonwilds SDK and reflection dumps; Dragonwilds building, blueprint and creative mods; Dragonwilds server tools and maps; Satisfactory holograms and the build gun RPC; Palworld build mods and build request functions; Valheim PlanBuild and Infinity Hammer; Conan Exiles and ARK placement; Abiotic Factor, Grounded, Nightingale and Icarus UE4SS building mods; mineflayer `placeBlock` and `lookAt`; Baritone `RotationUtils`; Mindcraft and Voyager place primitives; Unreal Automation Driver; UnrealCV commands; Unreal MCP servers; spring arm camera lag and substepping; `FInterpTo` source and frame-rate dependence; `GetPlayerViewPoint` and camera update order; unfocused packaged-game throttling; `WasRecentlyRendered` gating; multiplayer building system patterns; Set-of-Mark; SayCan; SayPlan and scene graphs; grasp candidate generation.

Searches that found nothing useful: Palworld's build RPC names; Conan Exiles and ARK placement RPCs; open-source placement code for Icarus, Abiotic Factor, Nightingale, Grounded, Smalland, Enshrouded and Sons of the Forest; a current SDK dump for Dragonwilds; a tutorial-level statement of the Unreal multiplayer building pattern.
