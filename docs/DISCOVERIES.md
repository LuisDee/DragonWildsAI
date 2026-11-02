# Discoveries

Each entry: what it is, the parameters, what it does, how it was verified, the build ID, and the sources.
Server build: **26161880** (Steam app 4019830, installed 2026-10-25). Engine **UE 5.6** (from UE4SS.log). Game module: `Dominion` (classes under `/Script/Dominion.*`).

Research notes with full source lists: `docs/research/2026-10-25-ue4ss-chat-bridge.md`, `docs/research/2026-10-25-phase4-body.md`.

**Code layout (2026-10-25):** the experiment modules named below as `mod/scripts/<name>.lua` now live in `mod/experiments/<name>.lua`, and `debug_run` still finds them by name. Proven code was promoted:
- `puppet_safe` became `mod/body/removal.lua`.
- `chat_relay`, `chat_as`, `name_register` and `names_probe` became `mod/body/speech.lua` (`DW_SAY_MODE=relay`).

See `docs/ARCHITECTURE.md`.

## Environment

### Client vs server version check (2026-10-25 22:25 UTC)
- Steam build ids are per app, so they never match. The client (app 1374490) is on **26162923** and the dedicated server (app 4019830) on **26161880**. Both logs report `LogInit: Build: ++dominion+hotfix-CL-254097` and `Net CL: 254097`, so it is the same game version.
- **Compare `Net CL` from the client and server logs, not Steam build ids**, to tell whether a patch needs a server update. `update_server.ps1` reported 26161880 -> 26161880, with nothing to update.

### Dedicated server install (verified 2026-10-25, build 26161880)
- **Install:** `winget install Valve.SteamCMD --source winget`, then `steamcmd +force_install_dir C:\GameServers\Dragonwilds +login anonymous +app_update 4019830 validate +quit`.
  - SteamCMD exits with code 7 after its first self-update without installing; run it again. About 5 GB.
- **Binaries:** `RSDragonwildsServer.exe` (230 KB launcher) and `RSDragonwilds\Binaries\Win64\RSDragonwildsServer-Win64-Shipping.exe`, the real server. We run the shipping exe directly with the working directory set to Win64.
- **Prerequisite:** the VC++ 2015–2022 x64 runtime (`winget install Microsoft.VCRedist.2015+.x64`). Without it, the server hangs at about 6 MB with no log and no visible error. Verified by installing it, after which the server ran.
- **Config:** `RSDragonwilds\Saved\Config\WindowsServer\DedicatedServer.ini`, section `[/Script/Dominion.DedicatedServerSettings]`.
  - Keys: `OwnerId` (the in-game Player ID), `ServerName`, `DefaultWorldName`, `AdminPassword`, `WorldPassword`, `PlatformPolicy=Crossplay`, `ServerGuid` (generated on first start, logged as `Generated missing ServerGuid`).
  - Sources: [TroubleChute](https://hub.tcno.co/games/dragonwilds/dedicated_server/), [XGamingServer config reference](https://xgamingserver.com/docs/runescape-dragonwilds/config-reference.md).
- **World:** on first start the server created `RSDragonwilds\Saved\SaveGames\CompanionDev.sav` from `DefaultWorldName` (log: `NewGame() ... WorldName[CompanionDev] ... MapName[L_World]`). It autosaves about every 5 minutes.
- **Log:** `RSDragonwilds\Saved\Logs\RSDragonwilds.log`.
- **Ports (from the log, not the guides):**
  - UDP 7777 for the game (`IpNetDriver listening on port 7777`).
  - UDP **8888** for the BeaconNetDriver. Guides say 7778; the RSE-Server Docker image agrees with 8888.
  - Windows Firewall rules for both are open to everyone.
- **Online:** Redpoint EOS. The log shows `CREATE SESSION - Success`, `START SESSION - Success` and `Session privacy set to [3] ... AdvertiseSession[1]`. The world is listed and has a password.
- **Navigation:** the server loads `RecastNavMesh-Default` and `RecastNavMesh-Gigantic` for `L_World`. Both log `Navmesh bounds are too large! Limiting requested tiles count` and are capped at 1,048,576 tiles. Navmesh coverage near the player still has to be checked (Phase 4).
- **Modded vs vanilla:** the ini has no "moddable" key, and no source documents one. "Modded" on hosts like Shockbyte means a Windows build with UE4SS. On our own Windows server, installing UE4SS is what makes it moddable. Clients stay vanilla.

### UE4SS on the dedicated server (verified 2026-10-25)
- **Version:** UE4SS `experimental-latest` (`UE4SS_v3.0.1-1181-g83330635`, assets dated 2026-10-17). Stable v3.0.1 predates UE 5.4. It detects `Using engine version: 5.6`, and the PS scan succeeds in about 2.7 s. [Release](https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental-latest)
- **Loader:** UE4SS's own proxy fails on native Windows.
  - That proxy is generated from `System32\dwmapi.dll` ([UE4SS build docs](https://docs.ue4ss.com/dev/installation-guide.html)).
  - The server never loads `dwmapi.dll`.
  - Renamed to `version.dll` (as [RSE-Server](https://github.com/kevinw9092/RSE-Server) does under Wine), it doesn't export the `GetFileVersionInfoW`, `GetFileVersionInfoSizeW` and `VerQueryValueW` that the exe imports. Windows then raises an invisible loader error, and the server hangs: 6 MB, one thread in `LpcReply`, `UE4SS.dll` never loaded. Verified with pefile and with a control run without the DLL.
  - **Fix:** use [Ultimate ASI Loader](https://github.com/ThirteenAG/Ultimate-ASI-Loader) x64 `version.dll` (v10.0.0), with `version.ini` set to `[GlobalSets] LoadFromScriptsOnly=1, LoadRecursively=0, LoadExtraPlugins=ue4ss\UE4SS.dll, DebugLog=1, ModernUI=0, DisableCrashDumps=1`.
  - UE4SS then loads from `Win64\ue4ss\`, and the ASI loader logs to `Win64\VERSION.log`.
  - Script: `tools/install_ue4ss.ps1`.
- **Headless settings:** the shipped `UE4SS-settings.ini` already has `ConsoleEnabled=0`, `GuiConsoleEnabled=0`, `GuiConsoleVisible=0` and `EnableHotReloadSystem=0`.
- **Lua mods load.** UE4SS's `Win64\ue4ss\UE4SS.log` shows `Starting Lua mod`. Our `DWCompanion` mod is enabled with an `enabled.txt` in its folder.
  - `os.getenv` sees variables set by `tools/start_server.ps1`, and `io.open` append works. Verified: `logs/mod/mod_*.jsonl` contained `mod_loaded`.
- **Hooks:** `RegisterHook("/Script/Engine.PlayerController:ClientRestart", ...)` registers at startup. It returns PreId and PostId; the first is 5.

## Bridge
- Decision: append-only JSONL files (protocol in `brain/BRIDGE_PROTOCOL.md`), with the Lua side in `mod/scripts/bridge.lua`. Rationale and alternatives (LuaSocket, C++ mod) are in the research note, section E.
  - Pure Lua and Python, so it ports to the native Linux UE4SS. LuaSocket stays a possible later upgrade behind the same `Transport` interface.
- Offline-verified: Lua 5.4.5 (`winget install DEVCOM.Lua`) runs the body against Python `BridgeClient` in `tests/test_lua_bridge.py`. The in-game `!ping` gate is still open.

## Chat
- Research says Dragonwilds has public text chat (256 characters, with a spam throttle). No class or function names are published and no mod reads it yet. Hook candidates come from the dump (below).

## Observed in the server log during Luis's first session (build 26161880, 2026-10-25)
- **Join sequence** (default log, no hooks needed):
  1. `LogNet: Login request: ?...Name=<epic name> userId: RedpointEOS:<id>`
  2. `Join succeeded: <name>`
  3. `Server_SetPlayerGuid_Implementation()`
  4. `SetPlayerCharacterInfo() ... Character Name[Zezima] Guid[DCG:<OwnerId>]`
  5. `LogDominionPlayerControllerBase: PlayerChar entered world`
  These lines are a reliable "player joined" signal that can be tailed from the log.
- **The character profile is client-owned.** Each client streams its character save to the server on join: `Remote Character load starting`, `Player profile stream completed ... Size[205758]`, `LoadStateFromJson`. Inventory and character persistence are tied to the client save. This matters for give and inventory skills.
- **Classes:** the player pawn is `BP_PlayerCharacter_C`. NPC example: `BP_NPC_Saradomin_Statue_C`.
- **Equipment:** `DominionPlayerEquipment` logs `HandleHeldBunchedRepd() : CurrentHoldable: <item id>` when the held item changes. Item IDs seen: `weap_mace_skullsplitter`, `tool_logging_axe_adamant`.
- **Woodcutting:** after a tree was cut, the log shows `DominionLog: DropItems() : No ItemDataClass specified; no items will be dropped`.
- **Actions are server-authoritative:** `DomNetActIntIds: AUTH : Action Validated ... Accepted : START : Evade`.
- **Chat:** typing `!ping hello` produced **no** line in the default server log. Chat must be hooked, using candidates from the dump.
- **Noise:** `LogNetPlayerMovement: Warning: ServerMove: TimeStamp expired` repeats constantly while a GFN player moves. Filter it when tailing.

## Phase 2 hooks: verified in game (build 26161880, 2026-10-25 12:23 UTC, Luis via GFN)
Hooks are registered 30 s after mod start, from `mod/scripts/hooks.lua`. Candidate analysis: `docs/research/2026-10-25-dump-chat-inventory.md`.

**Fired:**
- `/Script/JagexChatBackend.PlayerChatComponent:Server_SendChatMessage(FChatMessageData, FChatPlayerFilterData)`
  - Runs once per chat line. `self` is `BP_PlayerController_C_*.PlayerChat`.
  - Text: `params[1]:get().MessageBody:ToString()` gave `"!ping hello"`. Sender: `.SenderData.PlayerId` gave `256`.
  - **Text chat exists and the mod can read it.** The line is forwarded to the bridge as a `command_received` event. Verified in `bridge_io/body_to_brain.jsonl`.
- `/Script/JagexChatBackend.PlayerChatComponent:Server_SendPlayerEvent(FChatPlayerEventData)` fires on join.
- Item pickup (two `BP_Spawner_AshBranch_0x_C` sticks) fired, in order:
  1. `/Script/Dominion.PlayerInteractionManager:Server_RequestInteraction(InteractionComponent, Collider, bSecondary=false, bRelease=false)`. `self` is `BP_PlayerCharacter_C_*.BP_Components_InteractionManager`.
  2. The BP bound event `BP_BaseGatherableResource_C:BndEvt__..._OnInteraction__DelegateSignature(BP_PlayerCharacter_C)`.
  3. `/Script/Dominion.BaseInteractableResource:OnInteraction(BP_PlayerCharacter_C)`.
  4. `/Script/Dominion.PlayerInteractionManager:Multicast_AcknowledgeInteractionRequest(InteractionComponent, false, false)`.

**Did NOT fire** (called natively, so UE4SS hooks never see them):
- `DestructibleWorldActor:OnHealthChanged`. Two trees were each felled in one hit with an adamant axe.
- `BaseInteractableResource:DropItems`.
- `InventoryComponent:AddItem`, `AddItems` and `AddItemByData`.
- `DominionPlayerController:OnNewInventoryChangedLogEvent`.
- `PlayerController:ClientRestart`.

Inventory changes will have to be checked by reading inventory state (polling `GetInventory()`) instead of hooking. That fits CLAUDE.md principle 2 anyway.

## Debug trigger and hot reload (verified 2026-10-25)
- `debug_run {module, fn="run", args}` is a bridge command, implemented in `mod/scripts/debug_cmds.lua`.
  - It clears `package.loaded[module]`, requires the module again from disk, then calls `module[fn](log, args)` from the bridge poll, which runs on the game thread.
  - The workflow: `tools\deploy_mod.ps1` while the server is running, then `.venv\Scripts\python.exe -m tools.bridge_cmd debug_run "{\"module\":\"follower_test\",\"args\":{\"action\":\"status\"}}"`. **No server restart, so a connected player is not kicked.**
  - Verified with `body_probe` and `follower_test` on the live server. `main.lua`, `bridge.lua` and `hooks.lua` still need a restart to change.
- Idle world: `body_probe` found 1 game mode, `L_World`, 0 player controllers and **0 AI characters**. The AI director spawns creatures only around players, so Phase 4 experiments need Luis connected.
- **Phase 4 path:** the game has a native, server-side follower system.
  - `ADominionPlayerCharacter:GetFollowerComponent():ToggleFollower(UFollowerDataAsset*)`, with `DA_Kalphite_Friend` (the Pharaoh's Sceptre summon) as the data asset.
  - `ADominionAICharacter:Confuse(InConfuser, bShouldFollow)` makes an existing creature follow.
  - Details: `docs/research/2026-10-25-dump-body.md`. Experiment module: `mod/scripts/follower_test.lua`.

## ROUTE 1 WORKS: a server-driven player character (verified 2026-10-25, about 13:00 UTC, Luis via GFN)
Module `mod/scripts/puppet_test.lua`, run through `debug_run`.
1. `luis:GetWorld():SpawnActor(StaticFindObject("/Game/Gameplay/Character/Player/BP_PlayerCharacter.BP_PlayerCharacter_C"), {X,Y,Z}, {Pitch,Yaw,Roll})`, placed 3 m in front of Luis.
   - The server survived (1262 MB). **Luis saw a player character standing still.**
2. `puppet:SpawnDefaultController()` gave it a plain `/Script/AIModule.AIController`, with no PlayerController and no PlayerState.
3. `ai:MoveToLocation(luis_loc, 150, true, true, true, false, nil, true)` returned `2` (`EPathFollowingRequestResult::RequestSuccessful`).
   - **Luis confirmed it walked to him.**
- **Conclusion:** a `BP_PlayerCharacter_C` controlled by an AIController spawns, replicates, path-finds on the navmesh and animates on a vanilla client.
- **Next:** equipment and armour on the puppet, combat, loot, and how it looks (blank vs geared).

## BLOCKER (investigating): unpossessing an AI-controlled player character freezes the server (2026-10-25)
- **Symptom:** the game thread deadlocks. CPU use drops to 0, the log stops, and the bridge stops answering, right after `LogDominionPlayerCharacter: Character [BP_PlayerCharacter_C_*] unpossessed`.
- **Bisect results** (each run on a fresh server; `DW_NO_HOOKS=1` and `DW_NO_COMPANION=1` turn our hooks and companion loop off):
  - A: spawn, then destroy without possessing → **OK**.
  - B: spawn, possess (SpawnDefaultController → AIController), destroy, with hooks and companion off → **hangs**. So it is not our code.
  - C: possess, then `AIController:UnPossess()`, nothing destroyed → **hangs**.
  - D: possess, then destroy only the pawn (the controller is kept) → **hangs**.
  - E: possess via an AIController with `bWantsPlayerState=true` (the UE bot pattern), then destroy → **hangs**.
  - Both `K2_DestroyActor` and `SetLifeSpan` trigger it, because both unpossess.
- **Conclusion:** Dominion's unpossess path for `BP_PlayerCharacter_C` blocks when the controller is not a client-backed `DominionPlayerController`. Hypothesis: it waits on a client exchange such as the character-profile save stream.
- **Workaround:** keep one puppet alive for the server's lifetime and never unpossess it. Its death may trigger the same path; untested.
- **Next:**
  - Find the unpossess and death code paths in the dump (`ReceiveUnpossessed`, `OnUnPossess` and their overrides).
  - Optionally take a native stack dump of the frozen process, which needs Luis's OK (CLAUDE.md rule on native tooling).

## Route 1: puppet dressed and armed (verified 2026-10-25, about 13:15 UTC, Luis via GFN). Module: `mod/scripts/puppet_gear.lua`
- **Armour/cape:** write `puppet.PlayerEquipmentComponent.Current{Head,Body,Legs,Cape}Wearable = <UWearableEquipmentData>`, then call `OnRep_Current<Slot>Wearable(nil)` and `ForceNetUpdate()`.
  - **Luis saw the full Zamorak T6 set and the Attack skillcape on the puppet.**
  - Data assets: `/DowdunReach/Gameplay/Character/Player/Equipment/{Head,Body,Legs}/ITEM_Armour_T6_<Slot>_Zamorak...` and `/Game/Gameplay/Character/Player/Equipment/Cape/ITEM_Cape_Trimmed_Skillcape_Attack...`.
- **Appearance:** copy `PlayerCustomizationComponent.CustomizationSaveData.<Handle>.DataTable/RowName` field by field (Luis: `male_A_01`, `male_D_03`, `Preset15`, ...), then call `OnRep_PlayerCustomization()`. The calls returned OK. Luis did not separately confirm the face and hair; to check.
- **Held weapon:**
  1. Spawn the weapon's own held-actor class (`BP_Mace_Skullsplitter_C`) with `SpawnActor`.
  2. Set `w.HeldEquipmentData = ITEM_Mace_Skullsplitter`.
  3. `w:K2_AttachToComponent(puppet.Mesh, "prop_r", 2, 2, 1, false)`.
  4. Set `eq.HeldEquipmentActorRight = w`, call `eq:OnRep_HeldEquipmentActorRight(nil)`, then `ForceNetUpdate`.
  - **Luis saw the puppet holding the Skullsplitter.** `HeldEquipmentItem` is nil and the ID is 0; the item normally lives in the PlayerController's `BP_Components_Inventory`. It still renders.
- Luis's real held actor, for reference: class `BP_Mace_Skullsplitter_C`, socket `prop_r`, parent `CharacterMesh0`, ID 2.

## ROOT CAUSES of the "freezes" (crash-dump analysis, 2026-10-25). The freezes were crashes.
- **UE4SS's crash handler blocks.** `UE4SS CrashDumper.cpp` writes `ue4ss/crash_<ts>.dmp`, then calls `MessageBoxW("Crashdump written to ...")`. No setting, flag or debugger check skips it ([source](https://raw.githubusercontent.com/UE4SS-RE/RE-UE4SS/main/UE4SS/src/CrashDumper.cpp)).
  - On a headless server nobody clicks OK, so every crash looks like a deadlock: 0% CPU, the log stops, the bridge is dead, players can't connect.
  - Seen live with `cdb -pv`: thread 0 sits in `USER32!MessageBoxW` called from `UE4SS!UE4SSProgram` inside `UnhandledExceptionFilter`.
  - **Mitigation:** `tools/watchdog.ps1`, started with `tools/start_watchdog.ps1`. When a new dump appears it kills and restarts the server, and it restarts a missing process. `stop_server.ps1 -Hold` stops without an auto-restart.
- **Unpossess crash** (bisect runs B–E; dumps `crash_2026_10_25_13_5x/14_0x`):
  - Access violation in game code reading `0x1248`, which is null plus the offset of `ADominionPlayerController::LoadoutComponent` (CXXHeaderDump `Dominion.hpp:10214`, `// 0x1248`).
  - The call chain goes from our Lua `UnPossess()` / destroy into game code. Dominion's unpossess path reads `PC->LoadoutComponent` without a null check, and for an AIController that PC is null.
  - Any unpossess of an AI-possessed `BP_PlayerCharacter_C` crashes: destroy, SetLifeSpan or UnPossess, with or without bWantsPlayerState.
- **Damage-call crash** (`crash_2026_10_25_14_07_41`):
  - Access violation inside `UE4SS!LuaType::push_structproperty`, then `push_uint32property`, reading `0xffffffffffffffff`.
  - It happened while UE4SS converted our Lua table into the `TArray<FTypeDamage>` argument of `UDamageComponent:PredictDamage`. The cause is struct or array marshalling (a bad table shape, or a UE4SS bug). **`pcall` cannot catch native access violations.**
- **Debug toolkit:**
  - WinDbg `cdb.exe` (`winget install Microsoft.WinDbg`) is at `C:\Program Files\WindowsApps\Microsoft.WinDbg_*\amd64\cdb.exe`.
  - Live hang: `cdb -pv -p <pid> -c "~*kn; q"`.
  - Dump: `cdb -z <dmp> -c ".ecxr; .exr -1; kn 25; q"`.
  - Offsets: grep `// 0x<offset>` in `dumps/<build>/CXXHeaderDump`. The game ships without symbols, so we see module and offset only, and frames as `src_strerror+N` (meaningless names).
- **Combat (E3), seen by Luis:**
  - The puppet walked to a Kebbit (`MoveToActor`), and `BP_PerformAttack(BP_Player_Sword_Attack1_C, {Data=PA_Attack_Sword CDO, PlayerOwner=puppet, EquipmentHand=1, ActionInputType=0, DesiredActionTarget=kebbit})` **swung and did damage**.
  - The Kebbit fought back, treating the puppet as a player: `TryPerformAttack ... against player BP_PlayerCharacter_C`.
  - `HealthComponent:SetIsImmortal(true, puppet)` kept the puppet alive.

## Unpossess crash: fix bisect (build 26161880)
Run 2026-10-25, 14:17 to 14:40 local, with nobody connected. The spawn point was `{X=11597,Y=185837,Z=-3000}`. Each step went through `debug_run puppet_test` / `puppet_safe`. A crash was detected by counting new `ue4ss/crash_*.dmp` files.

**FIX (verified): destroy the pawn's `PlayerRangedAttackComponent` before any unpossess.** After that, `UnPossess`, `SetLifeSpan` and destroy all work. The reusable version is `M.safe_remove(puppet)` in `mod/scripts/puppet_safe.lua`.

**Root cause, from disassembly of the crashing function (image offset `+0x5AC3E60`, crash at `src_strerror+0x36712cb`):**
- The handler is `UPlayerRangedAttackComponent::OnPlayerControllerChanged(Pawn, OldController, NewController)`.
- It is called through the pawn's controller-changed delegate (frames 01-03: exec thunk, then ProcessEvent).
- It casts `OldController` to `ADominionPlayerController`. It then checks `IsValid(OldController)` (the uncast pointer, via `RF_MirroredGarbage` `0x40000000` at `[obj+8]`), and reads `Cast->LoadoutComponent` (`+0x1248`) from the cast result. That result is null for an AIController.
- How the handler was identified: the `this` register (`rdi=0x1e6616423b0`) in dump `crash_2026_10_25_14_22_23` matched the logged address of `BP_Components_PlayerRangedAttack`. The `addrs` action logs the address of every component before unpossess.
- All 8 unpossess dumps (13:52 to 14:22) crash at the same instruction. The 14:07 dump is the separate UE4SS marshalling crash.

| # | Experiment | Crash? | Dump / offset |
|---|---|---|---|
| 0 | (earlier) strip `PlayerActionPerformerComponent` with `comp:K2_DestroyComponent(comp)`, then unpossess | yes | 14_16_25, read `0x1248`, same rip. **Invalid test:** `K2_DestroyComponent(Object)` only destroys when `Object` is the owner, so it was a no-op. |
| 1 | strip all 5 (PlayerActionPerformer, PlayerEquipment, PlayerRangedAttack, PlayerMeleeAttack, Sprint) with `K2_DestroyComponent(pawn)`, then `UnPossess` | **no** | log shows "unpossessed"; same PID |
| 1b | after 1, destroy the unpossessed pawn | no | — |
| 2a | strip PlayerActionPerformer only (fixed call), then unpossess | yes | 14_22_23, read `0x1248`, same rip. `this` = BP_Components_PlayerRangedAttack. (A destroyed zombie puppet was also possessed in this run; see the note below.) |
| 2b | strip **PlayerRangedAttackComponent only**, then `UnPossess`, then destroy the pawn | **no** | — |
| 2c | `puppet_safe` (strip ranged, `UnPossess`, `SetLifeSpan` on pawn and controller) | no | — |
| 2d | `puppet_safe {unpossess=false}` (strip ranged, then `SetLifeSpan` only, so the destroy itself unpossesses) | no | — |
| 2e | armed puppet (`puppet_gear arm sword`), then `puppet_safe` (also removes the held weapon actor) | no | — |
| 2f | 3 back-to-back spawn → possess → `safe_remove` cycles | no | — |
| 2g | forced GC (`KismetSystemLibrary:CollectGarbage`, `puppet_test gc`) after 6 removals | no | all 6 garbage pawns and controllers purged |
| 3 | clear the pawn's `ReceiveControllerChangedDelegate` | not run | It is a sparse delegate (`FPawnReceiveControllerChangedDelegate`, `Engine.hpp:10642`, size `0x1`, stored in global sparse storage). UE4SS 3.0.1 has no Lua API to clear it. Not needed. |
| 4 | possess with a `BP_PlayerController_C` | not run | The fix made it unnecessary. The disassembly suggests it would pass the cast, but AI MoveTo would be lost. |
| 5 | parking fallback | not needed | — |

**Notes:**
- **Zombie actors.** After `SetLifeSpan`/destroy, a puppet stays in `FindAllOf` until GC runs (minutes on this server), at location 0,0,0. On it, UE4SS `IsValid()`, `IsActorBeingDestroyed()` and `KismetSystemLibrary:IsValid()` do not report it as dead. Only `HasAnyInternalFlags(0x200000)` (Garbage) is true. `puppet_test`, `puppet_gear` and `puppet_safe` now skip objects with `Garbage|Unreachable` (`0x10200000`). Before this, a "possess all puppets" step would possess the zombie too.
- Unpossessing without destroying the controller leaves an orphan AIController. `puppet_safe {orphans=true}` destroys plain AIControllers that have no pawn.
- **Untested:** the puppet's death or respawn path. It probably fires the same controller-changed handlers, so test it before letting a puppet die. The fix (strip ranged first) only applies at removal time. A puppet with the ranged component stripped probably cannot use ranged attacks.

## Client freeze from injected chat RPCs (2026-10-25, about 13:36–13:38 UTC). LESSON: client RPCs are dangerous
- `say` called `PlayerChat:Client_ReceiveChatMessage(FChatMessageData{SenderData={CharacterGuid, PlayerId, Color}, MessageBody})` with no `PrimaryNetId`/`SecondaryNetId`. Variant A added Luis's own GUID and PlayerId; variant B was `pc:Client_DisplayTextNotification({TagName=None}, FText)`.
  - The server-side calls returned OK, and **nothing displayed** on Luis's client.
  - Then **Luis's client froze**: NPCs stopped moving and the inventory would not open. The client closed the connection (`ControlChannelClose`, 13:38:25).
  - **The server stayed healthy.** Most likely cause: a malformed reliable client RPC broke the client's chat/UI or its channel.
- **Rules from now on:**
  1. No hand-built structs in Client_* RPCs to a live player. Speech defaults to `DW_SAY_MODE=log` (`start_server.ps1`).
  2. Untested native calls run offline (no players) first. Client-affecting calls can't be canaried without a client, so those need Luis's explicit go-ahead and a warning.
- **Hang detection added:** the mod writes `logs/state/heartbeat.txt` from the game thread every 10 s. `watchdog.ps1` restarts the server after 60 s stale (3 min grace after start), capturing `cdb` stacks to `logs/hang_*.txt` first.
- Puppet warning seen: `ADominionPlayerCharacter::OnWorldLoadedAroundCharacter - DominionPlayerState must be valid`. The puppet has no PlayerState, and the overhead name shows "Character Name Here" (Luis would like it to say "Claude").

## SPEECH WORKS AS "Claude" (verified 2026-10-25, 13:44 UTC, Luis via GFN)
1. **Route:** re-send a **genuine** client-built `FChatMessageData` through the server's own `PlayerChatComponent:Server_SendChatMessage`, from a post-hook on Luis's real message (`mod/scripts/chat_relay.lua` for the `!echo` test, `mod/scripts/chat_as.lua` for `!as`). Change only `MessageBody`, plus `SenderData.CharacterGuid` set to the bot's GUID.
   - `!echo hello` displayed `[Claude] hello` under Luis's name.
   - Hand-built structs with empty NetIds were dropped, and are suspected of freezing the client (see "Client freeze").
2. **Name:** the client resolves the sender name from `GameState.DisplayNameComponent.SanitizedCharacterNames`, keyed by **account string plus CharacterGuid**. Read-only probe: `mod/scripts/names_probe.lua`.
   - An entry registered with an empty account (`","`) displayed "Unknown Character".
   - **Fix:** `mod/scripts/name_register.lua` temporarily sets `Luis.PlayerState.OwnerGuid.CharacterGuid` to the bot GUID, calls `DisplayNameComponent:Server_RegisterCharacter(ps.OwnerGuid, "Claude")`, and restores the GUID in the same tick. Restore verified.
   - **Luis saw the line as "Claude".**
3. **Remaining for spontaneous speech** (the bot speaking without Luis's message as the template): still needs a way to send a well-formed message outside the hook. Options:
   - Cache a template at hook time, if UE4SS can copy the struct.
   - Find a server-side sender helper.
   - Have replies piggy-back on the triggering chat line.
   - Also: the puppet's overhead name ("Character Name Here") likely needs the same registry entry plus the puppet's character GUID set.
- **Performance check during "lag":** `FindAllOf` takes about 1 ms (15 AI, 1 pawn); VM CPU 5%; server about 15% of one core; 2.5 GB RAM free.
  - The lag is likely network jitter between GFN and the VPS (persistent `ServerMove: TimeStamp expired` on Luis's connection).
  - Possibly Defender scanning the hot files (`MsMpEng` high CPU time). Defender exclusions are pending Luis's OK.

## Performance telemetry (build 26161880, 2026-10-25). Is lag the server or the network?
**Three sources, joined by `tools/perf_report.py`:**
1. **Game-thread frame times:** `mod/scripts/perf_sampler.lua` writes to `logs/perf/mod_perf.jsonl`, one line per 10 s.
   - Arm it with `debug_run {"module":"perf_sampler"}`. It runs once per server run; arming again returns `already=true`. `args.action` can be `status` or `stop`.
   - `main.lua` auto-arms it 60 s after start. `DW_PERF=0` disables that.
2. **Host counters:** `tools/perf_counters.ps1 start|stop|status|recreate` creates the logman collector set `DWPerf`. It writes CSV every 10 s to `logs/perf/host_counters_<mmddhhmm>.csv`, with a new file per start and every 24 h.
   - It covers CPU (total and per core), queue length, available MB, pages/sec, disk % and latency, NIC bytes, UDPv4 datagrams and receive errors, the server process (CPU, working set, IO), MsMpEng, and python*.
   - It runs as SYSTEM and does **not** auto-start after a reboot. The CSV timestamps are local time; the header carries the UTC bias.
3. **Server log:** the report scans `RSDragonwilds.log` and its backups for:
   - `ServerMove: TimeStamp expired` lines, hitch lines, saturation and `ClientAdjust` lines.
   - `UNetConnection::Close` with its `Result=` (`ControlChannelClose` means the client closed the connection itself).
   - Autosaves (`SaveGameInternal() : Starting save` up to `Save completed`), and a **tick rate derived from the log's own frame counter** (`[hh.mm.ss:ms][frame%1000]`). That last one works on old logs, before the sampler existed.

**Run the report:** `.venv\Scripts\python.exe -m tools.perf_report` covers the last 60 min. `--minutes N`, `--since/--until` (UTC) and `--no-timeline` change that.
- It prints a per-minute timeline and a verdict, with the thresholds printed beside it.
- **Tick:** avg >= 27 Hz, <= 0.5% of frames > 50 ms, and <= 0.2 unexplained >100 ms hitches/min.
- **Host:** CPU > 80%, busiest core > 95%, RAM < 500 MB free, pages/sec > 1000, or disk > 20 ms. Any of these in >= 5% of samples counts as saturated.
- **Defender:** > 50% of a core, checked against slow-frame windows within ±15 s.
- **Network:** ping spikes (> 150 ms, or max minus p50 > 50 ms), TimeStamp expired, connection timeouts, and host UDP receive errors.
- **Hitch causes:** each > 100 ms hitch is matched to an autosave, or to a bridge command or `debug_run` (from `bridge_io/brain_to_body.jsonl` and the mod log) within -1..+5 s.

**Verified facts:**
- **Clock:** `Default__GameplayStatics:GetRealTimeSeconds(World)` costs about **5 µs** per call (200 calls timed with `os.clock`, about 1 ms resolution).
  - It returns `UWorld::RealTimeSeconds` as a double, so consecutive reads give exactly one world tick.
  - `World` comes from `FindFirstOf("GameModeBase"):GetWorld()`.
- **Frame loop:** `LoopInGameThreadAfterFrames(1, fn)` fires once per engine frame.
  - `EngineTickAvailable=true`, and `DefaultExecuteInGameThreadMethod = EngineTick`.
  - Checked against `KismetSystemLibrary:GetFrameCount()`: 15,240 frames sampled against 15,241 engine frames, with 0 duplicates.
  - Cost: one UFunction call plus a few Lua ops per frame. The 10-s flush (sort, `FindAllOf` for PlayerController and DominionAICharacter, ping reads) takes <= 10 ms.
- **Ping:** `PlayerState:GetPingInMilliseconds()` works server-side and matches `CompressedPing*4`.
- **Tick rate:** the server ticks at **30 Hz** (frame time 33.3 ms). The log-frame-counter estimate gives the same figure (29.6–30.0 Hz).

**Baseline: 2026-10-25, 13:53–14:00 UTC, 7.3 min, Luis connected from GFN until 13:58, 15–19 AI.**
- **Tick:** 29.8 Hz on average; p50 33.3 ms, worst p95 34.2 ms, worst p99 39 ms. 0.09% of frames were > 50 ms.
  - There were 9 hitches > 100 ms:
    - 5 were **our own `debug_run catalog` experiments**, at 126 to **611 ms**.
    - 3 were **autosaves**, at 116 to 202 ms. The save takes about 0.38 s and recurs every 5 min.
    - 1 was unexplained: 196 ms at 13:56:59. It might be UE garbage collection; this needs a longer run.
- **Host:** CPU averaged 27% and peaked at 58%; the busiest core peaked at 64%. Free RAM never fell below 2,218 MB, and disk latency peaked at 0.6 ms.
  - The server process used 15% of a core on average (24% at peak), with a working set of about 1.3 GB.
  - **Not saturated.**
- **Defender:** MsMpEng averaged 20% of a core and peaked at 84%, with about 10 MB/s of IO. Of the 6 slow-frame windows, **0** coincided with a Defender spike.
- **Network:** Luis's ping was p50 45 ms, p95 57 ms, max 60 ms. There were 0 TimeStamp expired lines, 0 UDP receive errors and 0 timeouts. His one close at 13:58:01 was `ControlChannelClose`, which he initiated.
  - Earlier (log-only, 13:07 UTC): one burst of 46 `TimeStamp expired` lines on one character within about 1.5 s. That is a client-to-server packet gap, while the log tick held at 29.6 Hz.
- **Verdict:** server-side OK, so a VM upgrade is not indicated.
  - The spikes players can feel from the server are (a) our live `debug_run` experiments (up to 0.6 s) and (b) the 5-minute autosave (about 0.2 s).
  - Any other lag Luis sees would be on the GFN-to-VM path. Next time he notices it, note the time and run the report over that window.

## Nameplate / identity (build 26161880)
Investigated 2026-10-25, about 13:50–14:10 UTC, with nobody connected (the world was paused: `LogDomGameMode: Requested pausing as we have no player connected`). The client-side result is **UNVERIFIED** until Luis looks.

**How the nameplate gets its text (from the dump):**
- `BP_PlayerCharacter_C.BP_Player_Nameplate` (`UBP_Player_Nameplate_C : UPlayerNameplateComponent : UDominionWidgetComponent`), the widget `WBP_Player_Nameplate_C : UPlayerNameplateWidget` and its `PlayerNameTextBlock` are all native. Neither Blueprint adds any logic or properties.
- No name property or setter exists on the pawn. The name must come from the pawn's **PlayerState**:
  - `ADominionPlayerState.OwnerGuid` (`FDomOwnerGuid` = `CharacterGuid.InnerGuid` + `FDomOnlineCapableAccountGuid`, replicated with `OnRep_OwnerGuidUpdated`);
  - resolved through `GameState.DisplayNameComponent.GetCharacterDisplayName(OwnerGuid, ExistingCharacterName)` against `SanitizedCharacterNames` (key: `AccountGuidSaveStr` + CharacterGuid);
  - and/or `APlayerState.PlayerNamePrivate` (`OnRep_PlayerName`).
- "Character Name Here" is the widget's default text. A puppet with no PlayerState never gets a name, which matches the server warning `ADominionPlayerCharacter::OnWorldLoadedAroundCharacter - DominionPlayerState must be valid`.
- The exact client path (which OnRep refreshes the plate) is native and was not disassembled.
- Probe results:
  - `GameMode.PlayerStateClass` = `/Script/Dominion.DominionPlayerState`; `DefaultPlayerName` = "".
  - The account string the server derives from Luis's AccountGuid is `RedpointEOS:000286bf...,STEAM:7656...` (NetIdPrimary,NetIdSecondary). An empty AccountGuid gives `","`.

**Why not the stock bot route:**
- `AController::InitPlayerState` is not reflected.
- `AAIController` only creates a PlayerState in `PostInitializeComponents` when `bWantsPlayerState` is already true. UE4SS `SpawnActor` is not deferred, so setting the flag after spawn is too late. puppet_test's `player_state=true` and bisect run E therefore probably never had a PlayerState.
- Re-possessing with a new controller unpossesses the old one, which is the crash path unless `PlayerRangedAttackComponent` is stripped.
- Not used (an alternative if the manual wiring misbehaves): set `Default__AIController.bWantsPlayerState=true`, spawn the controller, restore the CDO, then `safe_remove` the old puppet and respawn.

**What works server-side (verified, no crash; `mod/scripts/identity_attach.lua {action=attach}`, then `body/identity.lua`):**
1. `SpawnActor(/Script/Dominion.DominionPlayerState)` at the puppet.
2. `ps:SetOwner(aiController)` and `ps.bIsABot = true`.
3. Write the bot GUID into `ps.OwnerGuid.CharacterGuid.InnerGuid` with scalar A/B/C/D writes. AccountGuid is left empty.
4. Raw pointer writes: `ai.PlayerState = ps`, `puppet.PlayerState = ps` (replicated pawn property), `ps.PawnPrivate = puppet`.
5. `DominionGameMode:ChangeName(ai, "Claude", false)`, giving `ps:GetPlayerName()` = "Claude".
6. `ForceNetUpdate` on both.
- **Result:** `GameState.PlayerArray` = 1 (the bot PS); the puppet and controller report the same PS, with `PlayerId` 0 and `PlayerColor.PlayerId` -1. No crash dump, and the heartbeat kept ticking.
- **Registry:** `DisplayNameComponent:Server_RegisterCharacter(<the puppet PS's own OwnerGuid>, "Claude")` added the sanitized entry `"," | 0C0FFEE1-00C0DE00-0BADF00D-00000001 | Claude`. That is exactly the key a client builds from this PS. No hand-built struct is involved.
  - It **appends a duplicate** to SanitizedCharacterNames every time it is called, so `body/identity.lua` checks first.
  - Whether the registry survives a server restart is unknown; identity re-registers once per run.

**Shipped:**
- `mod/body/identity.lua` (`ensure(log, puppet, controller)`, idempotent).
- `body/puppet.lua` calls it right after possession and immortality, and from `ensure_spawned()` for an adopted puppet without a PS.
- `DW_PUPPET_IDENTITY=0` disables it.
- Debug: `identity_probe` (read-only, includes the registry dump); `identity_attach {action=status|attach|register|detach|module}`.

**Open / to verify (Luis):**
- The overhead name reads "Claude" after (re)joining.
- Clients are not affected by an extra bot PlayerState in `PlayerArray` (player list, chat).
- World save with a PC-less PlayerState: the first autosave with Luis connected.
- Removal with a PS attached: `UnPossess` clears the pawn's PS; destroying the controller destroys its PS (engine `CleanupPlayerState`); untested here.

## Item catalog run and melee combo timing (build 26161880, 2026-10-25, live server with Luis connected; no crash, no restart)
- **Catalog run** (`mod/scripts/catalog.lua` through `debug_run`, staged, with a ping and a crash-dump count after each step; 9 old dumps before and after):
  1. Property reads only (`registry=false, attacks=false, soft=false`): 466 items, 342 ms of game-thread CPU.
  2. `attacks=true`: 117 actions and 119 attack-data classes, 350 ms.
  3. Registry (`GetAssetsByClass`): 466 assets. **Every held and wearable item is already loaded at idle**, so `LoadAsset` is not needed for this build.
  4. Soft refs (`HeldEquipmentActorClass`) read fine, e.g. `BP_Mace_Skullsplitter_C`.
  - Output: `data/items_26161880.json`, with 466 items (232 held, 234 wearable), 0 missing and 0 errors. Command: `tools.build_catalog --no-load --notifies`.
- **Attack timing is readable as properties.**
  - `UPlayerAttackData.RootMotionAttackData.Montage` (`InPlaceAttackData.Montage` is null for the Club) gives `SequenceLength`, `RateScale` and `Notifies` (`TArray<FAnimNotifyEvent>`: `NotifyStateClass`/`Notify`, `LinkValue` = start in seconds, `Duration`). The struct-array reads via `ForEach` did not crash.
  - Per swing, the montage carries:
    - `AnimNotifyState_AttackInputWindow_C`: the combo input window.
    - `AnimNotify_AttackDamagePoint_C`.
    - `AnimNotify_AttackResetChain_C`: the chain resets here if there is no new input.
    - `AnimNotify_AllowMovementInput_C`.
    - Evade/Secondary input windows, `InputCancelWindow_*`, `HyperArmour_C`, `Invulnerability_C` (visceral).
  - Club Attack1, for example: window 0.367–0.805 s, damage at 0.501 s, reset at 1.702 s, montage 2.567 s.
- **Skullsplitter** (`ITEM_Mace_Skullsplitter`, Club set, not Sword):
  - Primary is `PA_Attack_Club_C`, a melee "Attack": `BP_Player_Club_Attack1 → 2 → 3 → 4 → 5`, damage 13.5/13.5/15/18/24, stamina 17 each.
    - Attack3 → Attack4 needs `PerkV2_Attack_MeleeExtendCombo`. Without it, Attack3 → `Attack4_ShortComboEnd`.
    - Attack5 → Attack1.
  - Special: `PA_Attack_Club_Special_C`, "Block Breaker": `BP_Player_Club_SpecialAction_C`, damage 20, `SpecialChargeCost` 33.
  - Also: sprint `PA_Attack_Club_Sprint` (SprintAttack → Attack2...), visceral `PA_Attack_Club_Visceral`, block `PA_Block_Club`, jump `PA_Spell_Club_JumpAttack` (a magic-kind action named "Dig").
- **Sword** (`ITEM_Sword_Mithril`, `PA_Attack_Sword_C`):
  - `BP_Player_Sword_Attack1 → 5`, damage 11/11/13/15/20. Attack2 → Attack3 needs the perk; without it, Attack2 → `Attack3_ShortComboEnd`.
  - Special: "Barge", `BP_Player_Sword_SpecialAction_C`, damage 24, cost 25.
- **Puppet special charge:** `puppet.SpecialChargeComponent:GetSpecialCharge()` / `GetMaxSpecialCharge()` (no-arg getters) returned 100 / 100 on the live puppet.
- **Live resolve check** (`debug_run catalog fn=check_attack_data`): all 26 melee attack sets and 71 steps in the generated `mod/body/attack_data.lua` resolve with `StaticFindObject`, including the CDO path `<pkg>.Default__PA_*_C`. The puppet was holding the Skullsplitter, which maps to the Club set.
- **UNVERIFIED (needs Luis):**
  - Whether `BP_PerformAttack` with combo steps 2–5 and with the special plays and damages like step 1 did.
  - Whether issuing step k+1 at step k's input-window end chains visibly.
  - Whether the server enforces the extend-combo perk, stamina or special charge on these direct calls.

### Nameplate attempt 1: NEGATIVE (Luis via GFN, after a full restart)
- Setup: `body/puppet.lua` ran `identity.ensure` at spawn. The log showed `puppet_identity linked=true ps=DominionPlayerState_... name=Claude registered=true`, so the client created the pawn with the PlayerState already linked.
- **Result:** the nameplate **still read "Character Name Here"**.
- **Conclusion:** none of these is enough to fill the nameplate:
  - a linked `DominionPlayerState`
  - `PlayerNamePrivate` / `GetPlayerName()` = "Claude" (via `GameMode:ChangeName`)
  - `OwnerGuid.CharacterGuid` = bot GUID, with matching registry entries (`","` + bot GUID, and Luis's account + bot GUID)
- The pawn and its components carry no name or GUID properties. In the dump, only `ADominionPlayerState` holds identity (`OwnerGuid`, `PlayerColor`, `PlatformData`). The character info set by `SetPlayerCharacterInfo()` (`FPlayerCharacterInfo`, unreflected beyond `DisplaySlotName`) lives on the PlayerController, which is never replicated to other clients, so it cannot be the nameplate's source.
- Luis's PlayerState vs the bot's, side by side:

| Field | Luis | Bot |
|---|---|---|
| PlayerId | 256 | 0 |
| PlatformData.DisplayName | "luisdeburnaybastos" | "" |
| PlatformName | "WIN" | "" |
| PlatformType | 2 | 0 |
| PlayerColor | {R .658, G .168, B .063}, "D47247FF", PlayerId 256 | defaults, PlayerId -1 |
| UniqueId (FUniqueNetIdRepl) | valid | empty (not writable from Lua) |
| AccountGuid | RedpointEOS + STEAM | empty |

### Nameplate attempt 2 (applied live 2026-10-25, Luis connected; `mod/scripts/identity_platform.lua {action=apply, player_id=999}`)
- Wrote `PlatformData.DisplayName="Claude"`, `PlatformName="WIN"`, `PlatformType=2`, `PlayerColor.Color` (Claude orange) / `HexString="D97757FF"` / `PlayerId=999`, and `PlayerId=999`, then ForceNetUpdate.
- All writes read back, and no crash. FString property writes from a Lua string work in this UE4SS.
- The server-side OnRep calls were not made (opt-in `onrep=true`), because native OnReps may touch client-only UI.
- Result: pending Luis.
- `{action=recycle}` sets the puppet's `NetCullDistanceSquared` to 1 for 9 s, then restores it, so clients drop and re-create the pawn as on a rejoin. Prepared, not run yet.

## Woodcutting timeline: W1, recorded live (2026-10-25 14:15–14:16 UTC, Luis chopped one oak with an axe)
Recorder: `mod/experiments/tree_watch.lua` (read-only, 1 s poll, 25 m radius).
1. **Standing tree:** `BP_BM_Tree_Oak_02_C`, HP **220**. One chop took it to 110, and at once `bIsStump=True`: the standing tree became the stump. A **`BP_FelledTree_Oak_C`** (HP 105) appeared next to it.
2. **Felled tree** (HP stays 105) spawns **`BP_SplittableLog_Oak_C`** pieces (HP 105) over about 4 s.
3. **Each splittable log** is chopped 105 → 21 → 0 (2 hits). At 0 it yields a **`BP_Log_Oak_C`** (HP 105) and further splittable pieces.
4. **Each `BP_Log_Oak_C`** is chopped 105 → 21 → 0. At 0 it bursts into **`BP_RuntimeSpawnedWorldItem_C` drops**: `ITEM_Resources_Wood_Oak`, **stack 1 each, 6 per log**.
5. **Pickup is by magnet:** drop distances shrink toward the player (1.1 m → 0.7 m, or 10 m → 0) and then the item is gone (collected). Players don't press interact for these.
6. **Stump:** HP 110, overhead swings took it 26 → 0. It disappears and drops **1 more oak log** item.
- So the bot's loop is: find a standing oak (`bIsStump=false`, HP>0) → chop → the felled tree splits on its own → chop every `SplittableLog_*` and `Log_*` within range until gone → collect `RuntimeSpawnedWorldItem` (ITEM_Resources_Wood_Oak) → optionally overhead-chop the stump (+1 log) → next tree.
- Progress check: the bot store count of ITEM_Resources_Wood_Oak. Each drop is a stack of 1, so a stack of 99 is built up in the store.
- Open: whether the **puppet's** magnet component pulls items (it has `BP_Components_ItemMagnet`), and where they go with no player inventory. Test W2 before relying on it; the bot may need to destroy and record items itself.

## Spells (build 26161880, 2026-10-25, live server; no crash, no restart caused)
Modules: `mod/experiments/spell_dump.lua` (X1), `spell_x3.lua` (X3), `spell_x4.lua` (X4, not run), service `mod/body/spells.lua`. Catalog: `data/spells_26161880.json` (52 `UtilitySpellData`, each with `usage` = role / preconditions / use_when / runes / cooldown / route). Crash dumps stayed at 9 throughout; `ping` OK after every step.

**X1, read-only dump (verified; run twice, 14:0x without players and ~14:12 UTC with Luis connected).**
- Reads that work under UE4SS experimental: `FindAllOf("UtilitySpellData")`; `spell.Modules.Modules[i].Module` (TArray of structs → object); `SpellDisplayName`/`PerkName` FText `ToString`; `CooldownDuration`; `CostItems.ItemsCostInfo[] {ItemData, Count}`; `GameplayEffect` TSubclassOf and its CDO fields; soft class `UtilitySpellClass` via `GetObjectID():GetAssetPathName()`; **TSet `ProgressComponent.SpellsUnlocked:ForEach`** (38 entries); TMap `PlayerUtilityMagicComponent.LastCastTimeBySpellData:ForEach` (empty: no cast yet this session).
- Costs/cooldowns (game data, wiki differs in places): Tempest Shield 15 Air / 45 s; Windstep 5 Air / 3 s (cost multiplier attribute `ATT_WindstepRuneCostMultiplierAttribute`); Enchant Weapon Fire/Air/Water/Earth 15 <element> + 5 Astral / **300 s** (wiki: 90 s); Spectral Arrows (`USD_CorruptionArrows`) 15 Astral + 5 Air / 300 s; Magical Mending 20 Earth + 10 Nature / 60 s; Axtral Projection 10 Air + 5 Astral / 45 s; Splinter 10 Earth + 5 Nature / 45 s; Trunk Totem (`USD_PileEmUp`, Woodcutting 50) 30 Nature + 10 Law / 180 s. Full table in the JSON.
- Name mapping confirmed from `SpellDisplayName`: `USD_PileEmUp` = Trunk Totem, `USD_Treequipment` = Bark to Bones, `USD_Harvest` = Uproot, `USD_FishCyclone` = Fishnado, `USD_SpeedupStation` = Overdrive, `USD_FerociousFurnace` = Superheat, `USD_DetectOre` = Summon Stone Spirits, `USD_DetectAnimaVents` = Summon Elemental Spirits, `USD_Farming_Compost` = Mucksplosion. No cost and no perk (internal/unreleased): CabbageRain, EnchantChefsTools, MagicFocus, WeaponBarbs, WeaponPoison, Whetstone; world-interaction: GetWaterFromWaterSource, SiphonAnimaCharge, SiphonRunes.
- Woodcutting spells: Axtral Projection is Aimed and spawns `BP_Spell_AxtralProjection_C` (Movement + Collision + `SpellModule_DamageByEquipment`, expires after 2000 cm; two extra axes with the upgrade perk). Splinter is Placed, a `BP_Magic_Splinter_C` utility spell with a 230 cm sphere and `DamageByEquipment` (`DamageType.Spell.Splinter`). Trunk Totem is Placed, a `SpellModule_Blueprint`. All three run in the spell module graph, so only the modular route (`TriggerModularAbilityForPlayer`, opt-in) can cast them today.
- Magical Mending: Placed; `SpellModule_UtilityMagic` → `/Game/Gameplay/UtilityMagic/PerkSpells/MagicalMending/BP_Magic_MagicalMending.BP_Magic_MagicalMending_C`; native `URepairSpellComponent` (`RepairEquipmentOfNearbyPlayers()`, no args; `SpellConfig{SpellRange, DurabilityTierPercentageMap, UsedItemsCollection}`, `bIncludeInventory/bIncludeLoadout/bIgnoreItemRequirements`). `UItem.Durability` is the per-item value. Not cast yet (catalogued, route `none`).
- Effects: `GE_TempestShield_C` health = `EffectHealthBase` 50 + `EffectHealthPerAttackSkillLevel` 7.5 × Attack level, duration 1 h in-game time (upgraded: 3 h), repulse 500, expiry burst `BP_TempestShieldExplosion_C` (wedge, force 1000, damage 0). Its instance class `BP_TempestShieldGameplayEffectInstance_C` is FX only in BP; MaxHealth is computed natively. Enchant HEEDs: `AdditiveDamageTypes` `DamageType.Magical.{Fire,Air,Water,Earth}`, +0.33 damage multiplier, 300 s time limit.
- **Windstep explosion** `BP_WindstepExplosion_C` template: `Damage 0`, `Force 1000`, Magical, sphere radius **700 cm**, `bDamageByOwner=false`, `bDamageByEquipment=false`, `PredictDamageDurationSeconds 0.125`.
- **Luis's mirror** (PC `BP_PlayerController_C_2147481363`): 38 spells unlocked (all wheel spells except Earth enchant, Fishnado and the internal ones); wheel 4 radials, 38 of 48 slots filled; perks include `PerkV2_Agility_Spell_Windstep_Upgrade` (Wind Stomp) and `PerkV2_Attack_TempestShield_Upgrade`; skill XP (Attack/Agility/Woodcutting/Runecrafting/Construction/Farming about 1,000,000 = max); runes Air 11030, Astral 15636, Fire 16673, Water 18616, Earth 15368, Nature 9669, Law 31545.

**X3, Wind Stomp emulation (spawn path verified safe; stun NOT yet observed).**
- Calls (`spells.lua` route `wind_stomp`): `World:SpawnActor(BP_WindstepExplosion_C, {X,Y,Z}, {0,0,0})` → `ex:SetOwner(puppet)` → optional `ex.DelayedDamageInfliction:StartDelayedDamage(0.0)` → `ex:SetLifeSpan(5)`.
- Runs: 2 canaries with nothing in range (no players connected), then 3 at a Kebbit (`BP_AI_Kebbit_Character_02_C`, 52–87 m from Luis), 2 of those forced. Server stayed up every time. BeginPlay runs on authority (it sets `ServerTimeOfCreation`); the owner reads back; the actor is garbage after 5 s. Log noise per spawn: `FNetGUIDCache::SupportsObject: DominionShape_Sphere ... NOT Supported` (harmless).
- **Effect:** none observed on the Kebbit: HP 39 → 39, `IsStumbling()` always false, no new gameplay tags in 3 s of 100 ms sampling, and `DelayedDamageInfliction.PendingDamage` empty at cast time and through the window. Kebbit `HitReactionConfig`: `bCanStumble=false`, light 100, heavy 9999, knockdown 1000 (Deer: heavy 200, knockdown 1000; Magpie 9999 everywhere). So either the explosion does not select passive critters, or force 1000 does not beat a threshold of 1000, or a 0 s delay applies and clears synchronously. **Still to do:** a Kalphite (hostile, stumble-capable) with Luis watching, plus a hook on `BP_DominionAICharacter_C:OnAIKnockdownState_Begin` or `AiHitReactionsComponent:Multicast_Stumble`.
- UE4SS gotcha: **returning true does not stop `LoopInGameThreadWithDelay`.** Cancel with `CancelDelayedAction(handle)`. One 10 Hz sampler (polls one Kebbit) leaked from the second stomp and runs until the next server restart; it is harmless.

**X4, Tempest Shield via `InstantiateGameplayEffect` on the puppet: NOT RUN (judged risky).** MaxHealth needs the Attack skill level, which lives on a PlayerController the puppet lacks (the null-PC crash class), and the instance replicates FX to clients (the client-freeze lesson). `spell_x4 apply` refuses unless `confirm="offline_canary"` and no player is connected. Run it only with nobody online and Luis's OK.

## Combos verified in game (2026-10-25, about 14:30 UTC, Luis via GFN)
- With `ITEM_Club_Wood` (held class `BP_Club_Wood_C`, equipped with an explicit actor_class), the `attack` handler (`body/combat.lua` BT, Club set `PA_Attack_Club_C`) killed a Kebbit (39 HP) in 4 swings. **Luis saw the combo chain** (different swings in sequence), where before only Attack1 repeated.
- The full 5-step chain and the special (Block Breaker) are not seen yet: the Kebbit died first. Next: a tougher or immortal target.
- The live Skullsplitter fix (`equip` with actor_class) is applied. The default-path fix (LoadAsset + catalog `held_class`, no generic fallback) is in `gear.lua` and takes effect at the next restart.

## NAMEPLATE FIXED: the bot shows "Claude" (verified 2026-10-25, about 14:40 UTC, Luis via GFN)
- **Cause:** clients resolve the nameplate (like chat senders) from the PlayerState's `OwnerGuid` = (AccountGuid, CharacterGuid), looked up in `GameState.DisplayNameComponent.SanitizedCharacterNames`.
  - The bot PS had an **empty AccountGuid** (keyed ","), so the lookup missed and the widget showed its default "Character Name Here".
  - Ruled out: PlayerState name (ChangeName), registry entries with an empty account, PlatformData/PlayerColor, push-model dirty marking, push model off, and client re-creation.
- **Fix:** `bot_ps.OwnerGuid.AccountGuid = host_ps.OwnerGuid.AccountGuid` (UE4SS struct-to-struct assignment = engine copy; never built in Lua), keep the bot CharacterGuid (0C0FFEE1-00C0DE00-0BADF00D-00000001), then make the client re-create the pawn.
  - "Claude" is registered under (Luis's account, bot GUID) (`name_register.lua` / `identity.register`).
  - **Luis: "He spawned in as Claude."** It is effectively like a second character on Luis's account.
- Built into `mod/body/identity.lua` (`copy_account` on spawn and on adopt; `is_registered` now requires an account with a platform id). Takes effect at the next restart; live puppet fixed via `mod/experiments/owner_account.lua`.
- Side effects to watch: the game may treat Claude as owned by Luis's account (claims, permissions). None observed yet.
- **Push model is now OFF** (`Saved/Config/WindowsServer/Engine.ini [ConsoleVariables] net.IsPushModelEnabled=0`, backup at `Engine.ini.bak-pushmodel`). It was not the nameplate fix, but it makes Lua property writes replicate. Keep it unless perf telemetry shows a cost.

## "This server might be modded" warning (2026-10-25)
- The server advertises the EOS session attribute **`ModDetection = 1`** (`LogNetSessionSettings: Setting ["ModDetection"] … value[1]`), alongside `BuildId=254097`, `ServerType=1`, `BetaHash=77`, `JoinCode`, `Vip_ServerName` and others. The client shows the warning when the attribute is set.
- **It is set by the game itself:** there is no ini key, and no reflected symbol in the dump, so the check is native. It most likely detects foreign code in the process (UE4SS via `version.dll`) or modified content. Pre-UE4SS logs have rotated away, so the 0 → 1 change is unconfirmed.
- **Policy:** leave it. The label is accurate and part of Jagex's vanilla-vs-moddable signalling. Don't try to hide it. If the companion ever runs on the group's real server, friends will see the warning.

## Item handling: world items, the puppet's magnet, spawning drops (build 26161880, 2026-10-25, 14:31–14:51 UTC)
Modules: `mod/experiments/item_probe.lua` (probe/canaries), `mod/body/items.lua` (world items), `mod/body/inventory.lua` (bot store), `mod/body/item_skills.lua` (pickup/drop/give). Crash dumps stayed at 10 throughout; the one new dump this period (14:45:24) came from the `speech_direct` experiment, not these modules.
- **World item reads (verified, census with Luis connected):** `BP_RuntimeSpawnedWorldItem_C` kebbit/tree loot: `w.ItemData` (e.g. `ITEM_Resources_Wood_Ash`, `ITEM_Resources_Coarse_Animal_Fur`, `ITEM_Resources_Weeds`), `w:GetStackSize()` = 1, `ItemData.MaxStackSize` = 99 for all three; `MagneticComponentGrantItem`: `bAllowAutoMagnetization=true`, `bAutoMagnetizationEnabled=true`, `AutoMagnetizationCategory=1` (Generic), `ContactRange=50`, `MinTimeBeforeMoving=1.0`, `bHasBeenGranted=false`, `Target=nil`; `SpawnedItem` (`UItem`): `Count`, `Durability=-1`, `GetMaxDurability()=-1`, `NumMasterworkUpgradesApplied=0`, `Guid`. `bCanExpire=true`, `bCacheInWorldItemRuntimeCache=false`.
- **The puppet's `BP_Components_ItemMagnet` is inert (read-only observation):** `MagnetRange=350`, the same as Luis's. Kebbit loot dropped about 2.5 m from the puppet (the attack at 14:29:19–30 killed a Kebbit 1.5 m from it) still lay there with `Target=nil` and `bHasBeenGranted=false` at 14:31. So items are not pulled into the puppet's missing (null) inventory, and the bot must take them itself (the `items.take_world_item` route). `IsActive()` is false on both magnets, so the magnetisation subsystem works natively and evidently picks only real players.
- **`UItemHelperLibrary:SpawnAndLaunchItem_Sync(world, FItemSpawnParameters, Out)` is SAFE to call (offline canary, 0 players, 4 calls, no crash):**
  - The struct goes in as a Lua table with **every** field set (`items.spawn_params`). Null object fields use UE4SS `CreateInvalidObject()` (it exists in 3.0.1, and `IsValid()` is false).
  - **UE4SS gotcha:** an `Out` parameter needs a Lua **table**. Passing `""` raises the Lua error "Tried storing reference to a Lua table for an 'Out' parameter ... no table on the stack" before the native call, so nothing happens. With `{}` the call works and writes `OutFailureReason` (empty) into the table.
  - The call returned `BP_RuntimeSpawnedWorldItem_NoExpiry_C` with the right `ItemData` (Oak Logs), stack 1 and 99, at the requested spot.
  - **With no player connected, the game destroys the spawned item within 50 ms**, in place and even with `bSkipFloorSafetyCheck=true`. It is Garbage-flagged at the first 50 ms sample and at the same location, and every other world item is gone too (`world_items_total=0`). So persistence and client view can only be tested with Luis online.
- **Still to verify with Luis (needs his go-ahead, warned):**
  - (1) `item_probe drop confirm="luis_ok"`: 1 oak log 3 m from him. Does he see it, can he pick it up, and is it +1 in his inventory?
  - (2) The `pickup` handler on a real drop. Does the item vanish on his client with no ghost, and does `inventory` show +1?
  - Flip `items.ROUTES.spawn_sync.verified` after (1).

## On-demand speech and the UE4SS nested-userdata crash (build 26161880, 2026-10-25, 14:35–14:50 UTC)
- **Net id sources (read-only, verified live, Luis connected):** `UDominionRuntimeBlueprintLibrary:ConvertUniqueNetIdToJsonString(FUniqueNetIdRepl)` on `/Script/Dominion.Default__DominionRuntimeBlueprintLibrary` turns a net id into a string. It is safe with a top-level struct userdata.
  - Luis's `PlayerState.UniqueID` (APlayerState, 0x2D0) = `OwnerGuid.AccountGuid.NetIdPrimary` = `RedpointEOS:000286bf...`; `NetIdSecondary` = `STEAM:7656...`.
  - The bot PS: `UniqueID` is empty, and its AccountGuid holds the copy of Luis's (identity).
  - `FChatPlayerSenderData` = {PrimaryNetId, SecondaryNetId (FUniqueNetIdRepl), CharacterGuid, PlayerId, Color}. `FChatPlayerFilterData` = {SenderId, `TArray<FUniqueNetIdRepl>` ReceiverIds}.
  - No reflected property anywhere holds an `FChatMessageData`/`FChatPlayerSenderData`, so there is no persistent template.
  - Not yet captured: a genuine line's PrimaryNetId/SecondaryNetId/SenderId and the ReceiverIds count. `speech_direct capture` records them on the next player line (the hook is registered once per run).
- **UE4SS marshalling (source read at the installed commit 83330635; main is identical):**
  - The UFunction call buffer is `Memzero`'d, never `InitializeValue`'d nor `DestroyValue`'d.
  - A table param goes through `convert_lua_table_to_struct`, which runs each field's pusher with `stored_at_index = -1`. Scalar pushers honour it.
  - **BUG: `push_structproperty`'s userdata branch calls `get_userdata<UScriptStruct>()` with the default `force_index = 1`, ignoring `stored_at_index`.** For a top-level param, index 1 is that param, so it works (the relay passes a whole genuine `FChatMessageData`). Property assignment (`a.B = ud`, `__newindex`) is also fine: self and key are removed first, so the value is at index 1 (identity's AccountGuid copy).
  - **A struct userdata nested inside a Lua table reads the wrong stack slot (the outer table) and dereferences garbage.** It is the only pusher with this bug (`LuaUObject.cpp:784`). UObject, FName, FString, FText, TArray and soft-pointer userdata use `stored_at_index` and are fine nested, which is why `BP_PerformAttack({Data=<UObject>, ...})` works.
  - Also: UE4SS `TArray` `__index`/`__newindex` past `Num` calls `AddZeroed` (reads past the end grow the array), and there is no `RemoveAt`.
- **CRASH (my test, 14:45:24 UTC, `crash_2026_10_25_15_45_24.3244819.dmp`):** `Server_SendChatMessage({SenderData={PrimaryNetId=<ps userdata>, ...}}, {SenderId=<ps userdata>})`.
  - Stack: UFunction call → `push_structproperty` → (table) → `push_structproperty` → (table) → `push_structproperty+0x71f` AV. This happened before ProcessEvent, so no message was sent.
  - Last breadcrumb: `speech_direct.Server_SendChatMessage`. The watchdog restarted the server at 14:45:39; Luis was disconnected and the puppet was gone (autospawn off).
  - **R3 (PredictDamage `TArray<FTypeDamage>`) has the same frames and is very likely the same bug.**
  - **Rule: never put a struct userdata inside a Lua table passed to UE4SS. Scalars-only tables are fine; copy structs only by property assignment or as a top-level param.**
- **Route v2 (built, UNVERIFIED in game):** `body/speech.lua` `send_direct` / `DW_SAY_MODE=direct`.
  - Call `Server_SendChatMessage` with SCALAR-ONLY tables.
  - A one-shot PRE-hook on the same function then copies `NetIdPrimary`/`NetIdSecondary`/`UniqueID` into the live param buffer by property assignment.
  - Evidence that pre-hooks fire for Lua-initiated calls and see the buffer: `hooks.lua`'s pre-callback logged the relay's re-sent text (`mod_20261025T133955Z.jsonl`, 13:41:42).
  - Still unproven: that the native implementation reads the edited buffer. `speech_direct prove` checks this read-only (`GetCharacterDisplayName` with an empty account, patched by a pre-hook → must equal the host's own name), and `send` refuses until it passes.
- **Map and compass presence (read-only, verified live):**
  - Players come from `AGameplayObjectRegistry.PlayerCharacters` (`TArray<FPlayerCharacterData>`, ReplicatedUsing `OnRep_PlayerCharacters`, not SaveGame). The element is {Location, RotationByte, OwningCharacterGuid, OwningPlayerUniqueID, OwningPlayerName, Color, Identifier}.
  - The registry is also `UGameplayObjectSubsystem.ObjectRegistry`. `UMapUIAPI` and `UCompassWidget` hold it, and compass icons are keyed by FGuid; `EMapIconType.OtherPlayerCharacter = 2`.
  - Live: **the bot PS is in `GameState.PlayerArray`** ("Claude", `bIsABot`), but **the registry had only Luis** ("Zezima", location tracking his pawn). The puppet has the registry pointer (`ADominionPlayerCharacter.GameplayObjectRegistry`).
  - Server log: the puppet's native `OnWorldLoadedAroundCharacter` runs at spawn (cells already loaded) and again in `PossessedBy`, both times before identity attaches the PS → `DominionPlayerState must be valid`. For Luis it runs about 5 s after possession, with no warning.
  - Hypothesis (UNVERIFIED): that function adds the registry entry, so linking the PS to the AIController before `Possess` (APawn::PossessedBy copies `Controller->PlayerState`) would let the game register the bot itself. That needs a puppet respawn (puppet.lua), and the native path may touch PlayerController-only state.
  - Built (UNVERIFIED): `body/presence.lua` appends one scalar-only entry (Identifier `0C0FFEE1-00C0DE00-0BADF00D-0000A11E`) and updates Location/RotationByte every second. Experiment: `presence_test add confirm=true`.

## Spells wired live + reflex rules (build 26161880, 2026-10-25, about 15:45-16:10 UTC+1; no crash caused, dumps stayed at 10)
- **Startup (run `mod_20261025T144539Z`):** `main.lua`'s SPELLS + REFLEX RULES block loaded. The catalog path came from `DW_MOD_LOG_DIR` (`C:\gameserver/data/spells_26161880.json`, 52 spells, because `DW_REPO_ROOT` is only set by `start_server.ps1` from now on). Policy `mirror_budget` (the inventory store was ready). Rules were installed as the first combat `on_tick` hook. Spells reflexes: Tempest Shield (`self_effect`) and Windstep (`wind_stomp`) are both **OFF**, because the catalog `routes[r].verified` is false.
- **Bridge handlers verified live (nobody online):** `capabilities` lists `cast`, `spells`, `spell_tactics`, `set_reflex_rule`, `list_rules` and `clear_rule`.
  - `spells {compact}` returns `[]`: all 52 spells answer `not_implemented` (route not verified).
  - `cast` with no puppet answers `companion_down`.
  - `set_reflex_rule` (kalphite, telegraph, evade + Windstep at self) returns the rule read back, `persisted=true`, and a warning that Windstep's route isn't verified. The bot state file kept `v`, `gear` and `inventory` and gained `reflex_rules {v, next_id, by_enemy}`.
  - An unknown trigger answers `cant_sense`.
  - `clear_rule {all}` emptied it again (`by_enemy` is `{}`, `next_id` is 2).
- **Telegraph source:** the server log line `DominionAiAttackComponent: AUTH ATTACK : TELEGRAPH ... TimeUntilEvent` and `EvadeAttack: OnTelegraphDamage / PredictPointDamage` are **native**. Neither name is in the CXX dump, so there is nothing to `RegisterHook`.
  - The reflected attack signals are `UAiAttackComponent:Multicast_PerformAttackOnSimulatedProxies(AttackClassId, AttackId, bFromCombo)` (NetMulticast, at attack start), `AiAttackTicketsManager:OnAiAttackStarted(AI)` (delegate handler), and the BP event `BP_AiAttackComponent_C:BP_PreemptParryWindowOpening(ParryWindowLength, AttackData)` (parry window, near the hit).
  - `body/rules.lua` **polls** `ADominionAICharacter.AiAttackComponent.CurrentAttack.AttackData` (`FAiAttack`, DOM:14612) instead, as a property read with no hook. A nil-to-set change is one telegraph event.
  - Kebbit log timing: `TryPerformAttack` at t, TELEGRAPH at t+1.335 s, damage at t+1.35 s. Attack start therefore gives about 1.3 s of warning.
  - **UNVERIFIED:** that `CurrentAttack.AttackData` is set on the server during an attack. No AI was loaded to read (nobody online).
  - Next: `debug_run rules_probe {action=watch, seconds=30}` while Luis fights. It logs `rules_probe_attack`.
- The player dodge (`UPlayerEvadeComponent`) has no reflected start function, only `Multicast_StartEvade(int32, bool, FRotator)`, which is visual and takes a struct argument (rule 4). So the rule action `evade` is a 4 m `MoveToLocation` away from the attacker.

## Gather: the puppet's tool swing, the emulated hit, resources (build 26161880, 2026-10-25, 14:31-14:38 UTC, Luis watching via GFN)
Modules: `mod/experiments/gather_probe.lua` (discovery), services `mod/body/sense.lua`, `watch.lua`, `hitcheck.lua`, data `mod/body/resource_profiles.lua`, loop `mod/body/gather.lua`. No crash from these steps (dumps 9 before and after; the 14:45 crash was `speech_direct`).
- **A puppet's hatchet swing reaches a tree but the tool gate reads it as UNARMED.** `BP_PerformAttack(BP_Player_Axe_Woodcut1, {Data=PA_Attack_Hatchet CDO, PlayerOwner=puppet, EquipmentHand=1, DesiredActionTarget=oak})` at 1.1 m, with the Adamant logging axe held (`gear.read` and the native `GetHeldEquipmentDataRight()` / `HeldEquipmentActor:GetHeldEquipmentData()` all return `ITEM_Logging_Axe_Adamant`, category `Item.Equipment.Tool.Hatchet`):
  - hooks on `BP_DamageModifier_SpecificWeapon_C` (DA_HatchetOnly_Tier3) fired `GetHeldEquipmentThatInflictedDamage` (Source = the puppet pawn, HeldEquipment = nil), `IsDamageCausedByUnarmedAttack` (true), then `ModifyDamage` (Amount 10, Instigator = puppet). `IsEquipmentOfSufficientTier` / `IsEquipmentCorrectCategory` were never called. HP stayed 220 (3 tries).
  - **Luis saw it:** the bot swung the axe at the oak with no effect, then killed a Kebbit with the same axe (11 chops + 2 overhead specials, `attack` handler). Creatures have no tool gate.
  - Cause (inference, strong): `FPlayerActionInstance.ActionGranter: UEquipment*` (DOM:5721) is nil in our call; the puppet has no `UHeldEquipmentItem`. At 3.8 m the swing never reached the pipeline (no contact).
  - UE4SS note: for these BP functions the Lua callback ran once, after the function (out params filled); the post callback never fired.
- **Emulated hit works:** `tree.HealthComponent:DecreaseHealth(84, "dw_gather")` (84 = attack damage 10 x Adamant damage multiplier 8.4, the exact per-hit damage Luis did on logs in W1) on a standing oak: 220 -> 136, then 136 -> 110 with the split: `bIsStump=true` (HP 110), `BP_FelledTree_Oak_C` (HP 105), `BP_SplittableLog_Oak_C` (HP 105, log type 1) and one `ITEM_Resources_Wood_Oak` world item (stack 1) next to the stump. A minute later the felled tree was gone and the splittable log remained. Luis's own chop went 220 -> 110 in one hit (crit or perk); ours needs 2.
- **Trees are foliage until converted:** `Default__InteractableFoliageFunctionLibrary:ConvertFoliageNearbyLocation(puppet, loc, r, true, false, puppet)`: 47 trees within 50 m in 28 ms, 323 within 150 m in 168 ms (30 -> 353 FellableTree actors). **Undamaged converted trees revert within seconds** (new actor ids on every conversion; a MoveToActor target vanished mid-walk); the damaged one stayed. Hence `sense.relocate` (convert at the remembered position, find the same species within 2 m).
- **Gates and HP (live census):** oak `BP_BM_Tree_Oak_0{1,2}_C` HP 220, `SplitDamageFraction` 0.5, `DamageModifiersWhenTree` = `DA_HatchetOnly_Tier3` (RequiredTier 3, `Item.Equipment.Tool.Hatchet`) + `DA_ResistantToSpecial` (`BP_DamageModifier_MultiplyBasedOnAttackProperties_C`); stump: `DA_HatchetOnly_Tier3`; the stump's `ItemDropOnDestructionComponent` = 1 x oak log. Ash `BP_BM_Tree_Ash_0{1,2,3}_C` HP 160, `DA_HatchetOnly` (tier 1), splittable ash log HP 80. Around Brynmoor: 335 ash vs 18 oak after converting 150 m.
- **Rocks:** `BP_OreNode_Stone_C` is a `DestructibleMiningRock` (136 loaded): HP 75, `DA_PickaxeOnly` (tier 1, `Item.Equipment.Tool.Pickaxe`), drops `ITEM_Resources_Stone` 10-16, `bDestroyActorOnZeroHealth=false`. `BP_MiningRock_RuneEssence_Static_A_C`: HP 60, 5 x `ITEM_Rune_Essence`. `BP_RuneEssenceGeyser_*_C` are `AOreNode`s (no HealthComponent; NodeHealth 1, 3/4 chunks). Details: `docs/research/2026-10-25-mining.md`.
- The puppet's `BP_Components_ItemMagnet`: `MagnetRange` 350, **inactive** (it never pulled the oak log lying 2 m away).

## Drop verified in game (2026-10-25, about 15:20 UTC, Luis via GFN)
- `UItemHelperLibrary:SpawnAndLaunchItem_Sync` (route `spawn_sync`; scalar-only params plus a Lua table for the Out param) dropped one `ITEM_Resources_Wood_Oak` as `BP_RuntimeSpawnedWorldItem_NoExpiry_C` near the bot. **Luis saw it and picked it up normally**; his client stayed responsive. `items.ROUTES.spawn_sync.verified = true`.

## Pick up + give verified; item-substitution bug (2026-10-25, about 15:25 UTC, Luis via GFN)
- `pickup` and `give` work live: the bot collected the dropped oak logs and gave 2 to Luis at his feet (`give` result: world item spawned at the player).
- **Bug:** "claude pick up the sticks". Sticks are ground gatherables (`BP_Spawner_AshBranch_*`, BaseInteractableResource), not in `nearby_items`, so Haiku picked up the only visible item (the logs it had just given Luis).
  - Fix (brain): `PickupArgs.item` must be set to what the player named; never substitute; say "I can't see any X".
  - Fix (body, gather agent): sense ground gatherables plus a pickup route for them.
- Luis's woodcutting observations of the gather agent's self-test:
  - The tree WAS felled. It used only Overhead Chop.
  - It ignored the felled trunk and logs and went to a new tree; it did chop the stump; then it idled far away.
  - All forwarded to the gather agent.

## On-demand speech v2: safe but not delivered (2026-10-25, about 15:35 UTC, Luis via GFN)
- `speech_direct prove` PASSED: the pre-hook patch of the net ids into the live `Server_SendChatMessage` call is read by native code (`patched=Zezima == control`).
- `send` returned ok and the server stayed healthy; **Luis's client did not freeze** (unlike the hand-built Client_* RPC case), but **no chat line appeared**.
- Prime suspect: `FChatPlayerFilterData.ReceiverIds` was empty (routing to nobody). The presence agent is capturing a genuine filter from a real message next.

## Melee hitboxes: why swings whiffed (2026-10-25, read live via `mod/experiments/hitbox_probe.lua`)
- Hits come from `UPlayerAttackData.TimedDamageShapes`: an array of {TimeOffset (s into the attack), DamageShape}. The shape is a `UDominionShape_{Arc,Box,Capsule,Sphere,Wedge}` with Offset/Pivot/Scale/RotationOffset plus shape fields, relative to the attacker. The melee component also has **camera-based aim assist** (`MaximumAngleAimAssist`, `ScreenSpaceRadius`), which the puppet lacks (no camera).
- **Axe Chop** (`BP_Player_Axe_Woodcut1_C`, primary): Wedge **Depth 115 cm**, TopAngle 80°, **AngleOffset 35°** (skewed to one side), ZHeight 200; hits at **0.55 s**; 10 dmg.
- **Axe Overhead Chop** (`BP_Player_Axe_Woodcut2_C`, special): Wedge Depth 170 cm, **TopAngle 15° (±7.5°)**, AngleOffset 0, Offset Z −40; hits at **0.84 s**; 10 dmg.
- Luis saw the bot "overhead chopping thin air". The target was outside the narrow wedge. **Fix (generic):** before each swing, read the chosen attack CDO's shapes, then rotate and step so the target's position (re-read each swing; logs roll) lies inside the shape at its TimeOffset. Verify the HP change afterwards (hitcheck). Applies to every weapon and tool.

## The bot counts as a player for the night skip (2026-10-25, Luis via GFN)
- Since the bot got a `DominionPlayerState` (in `GameState.PlayerArray`, nameplate "Claude"), **Luis confirms it counts as a character/player**, so it blocks "all players sleeping" from passing the night.
- Needed: a `sleep` skill (nearest bed via sense → go_to → `Claim/Sleep(puppet)`; else cast Summon Shelter on flat ground), plus a reflex to sleep when Luis sleeps, plus an interim debug flag so the bot doesn't count. Spells agent assigned.

## Speech: genuine filter captured (2026-10-25, about 15:55 UTC)
- A genuine `Server_SendChatMessage` from Luis carries `FChatPlayerFilterData` {SenderId = his RedpointEOS id, **ReceiverIds = [his RedpointEOS id] (1 entry)**}, and SenderData {Primary = RedpointEOS id, Secondary = STEAM id, PlayerId 256, CharacterGuid, Color}.
- The first direct send had **0 ReceiverIds**, so the server routed it to nobody. Second send: `receivers=true` (each connected player's PlayerState.UniqueID copied by array-element assignment in the pre-hook). No crash; awaiting Luis's visual result.

## ON-DEMAND SPEECH WORKS (2026-10-25, about 15:56 UTC, Luis via GFN)
- `speech_direct send` with `receivers=true` showed **"Claude: Claude here - can you hear me now?"** in Luis's chat with **no triggering message**. Luis: "Yes could see his message." No crash, no freeze.
- **Route:** `Server_SendChatMessage` on a connected player's PlayerChatComponent with scalar-only tables (bot GUID, PlayerId, colour, text). A one-shot pre-hook copies the live net ids (PrimaryNetId/SecondaryNetId from the host PS, SenderId) and fills **ReceiverIds with every connected player's PlayerState.UniqueID** (array-element assignment = safe property copy; not R15).
- The name resolves to "Claude" via the (host account, bot GUID) registry entry.
- Made the default: `start_server.ps1` sets `DW_SAY_MODE=direct` (relay remains the fallback). Effective at the next restart.

## Night skip and sleep (build 26161880, 2026-10-25, about 16:30-16:45 UTC+1, Luis online; no crash, dumps stayed at 10)
- **Luis confirmed in game that the bot blocks "all players sleeping".** It has a `DominionPlayerState` in `GameState.PlayerArray` (`bIsABot = true`). So `bIsABot` does **not** exclude it.
- **How the game decides (dump, read-only):** the skip is native.
  - `UPlayerSleepSubsystem` (a `UTickableWorldSubsystem` with no reflected members) and `ADominionGameMode.OnAllPlayersSleeping` (delegate).
  - Per player: `ADominionPlayerCharacter.PlayerRestComponent` (`UPlayerRestComponent`, BP `BP_Components_Rest_C`, held in the character property `BP_Components_Sleep`). It has `IsSleeping` (replicated, `OnRep_IsSleeping`), `CurrentRestingAreaActor/Component`, `IsInTimeframeForSleep()`, `IsWaitingForSleep()`, `StartSleeping()`, and `GetWaitingToSleepText(InstigatorName, bIsInstigator, NumPlayersInBeds, NumTotalPlayers)`. So the UI counts "players in beds / total players".
  - Beds: `UBedComponent : URestingAreaComponent` with `CanSleep / Sleep / StopSleeping / Claim (ADominionPlayerCharacter*)`, `IsClaimedByAnyPlayer`, `IsClaimedByPlayer`, `GetClaimingCharacterName`, and `bRequiresClaimingToSleepIn`. `URestingAreaComponent` adds `Rest / StopResting / CanRest`.
  - Time: `/Script/Dominion.Default__InGameTimeFunctionLibrary:IsNighttime(ctx)` and `GetInGameTime(ctx)` (FTimespan; `Ticks / 3.6e10` gives hours) both read fine live. `GetTimeOfDusk/Dawn` return nothing readable.
- **Live reads (`experiments/sleep_probe`):** in-game 07:11, then 11:18 in the next run. No `BedComponent` or `RestingAreaComponent` was loaded near Luis (his beds are elsewhere and unloaded). Both rest components were readable (`IsSleeping = false`). PlayerArray: Zezima (`bIsABot = false`) and Claude (`bIsABot = true`); `bIsSpectator`/`bOnlySpectator` are false on both.
- **Which per-bot flag lets Luis pass the night: NOT YET KNOWN.** It needs a night with Luis in bed. Candidates are built (`body/sleep.lua`, armed at startup since the 16:32 restart):
  1. Rest flag: the puppet's `PlayerRestComponent.IsSleeping = true` (property write, no OnRep). The sleep reflex does this automatically when Luis starts sleeping and no free bed is within 25 m.
  2. `night_skip {mode=spectator}`: the bot PlayerState's `bIsSpectator` and `bOnlySpectator` set to true.
  3. A real bed: `BedComponent:CanSleep(puppet)`, then `Sleep(puppet)`. It never takes a bed someone else claimed.
  - Record the result here.
- Summon Shelter (`USD_SummonShelter`): a Placed spell whose `SpellModule_UtilityMagic` spawns `BP_Magic_SummonShelter_C` (`AUtilitySpell`, caster from `GetCaster()`). It only runs through the module graph, so there is no safe route yet and the sleep skill's no-bed fallback is the rest flag.

## Cast route canary: self_effect with Fire Spirit (build 26161880, 2026-10-25 about 16:44 UTC+1; no crash)
- **Choice:**
  - `USD_FireSpirit` (`GE_FireSpirit_C` on SpellOwner, instance `UFireSpiritGameplayEffectInstance`, which drives an `AFireSpirit` light bound to `TargetCharacter`; 3 h in-game, no damage, nothing on others).
  - Cast through `GameplayEffectsComponent:InstantiateGameplayEffect(class, nil, false)`, the `self_effect` route. It takes plain args, skips the spell module graph (no `SpellModule_CostItems` null-PC inventory read, R8), and avoids Tempest Shield (MaxHealth reads the Attack level from a PlayerController the puppet lacks).
  - Tempest Shield now carries `needs_own_test` in `spells.lua`, so proving the route does not enable it.
- **Run (`experiments/cast_test cast`):** the puppet was walked about 14 m from Luis first. A `FireSpiritGameplayEffectInstance` appeared in the puppet's `ReplicatedInstances` (4 to 5 instances); the server stayed up and `ping` was fine.
  - No `AFireSpirit` actor was visible server-side after 5 s (it is probably a client-side cosmetic, spawned from the replicated instance).
  - **Pending: Luis's eyes**, whether a fire-spirit light is floating by Claude. Only after a "yes" set `routes.self_effect.verified = true` in `data/spells_26161880.json` (and `spells.USD_FireSpirit.verified_in_game = true`).
  - To remove it: `cast_test {action=remove, confirm=true}`.

## Lodestones, map regions and travel (build 26161880, 2026-10-25, about 15:35-15:50 UTC, read live via `mod/experiments/travel_probe.lua`; Luis connected; no crash, dumps stayed at 10)
- **Lodestones are world objects, not per-player unlocks.**
  - `AGameplayObjectRegistry.Lodestones` (`TArray<FLodestoneData>` {Location, RespawnLocation, Identifier}, OnRep, replicated for the map) lists every lodestone in the world.
  - This dev world has exactly one: `5E74232B4126EDE0BAEFF9856FFD03C6` at `[50.65, 1890.26, -36.33]` m (Temple Woods). Its RespawnLocation is the same point plus 1.45 m (Z): this is where a teleporting player arrives.
  - The loaded actor is `BP_WorldLodestone_C` (`AWorldActor.DisplayName` = "Lodestone", `InteractionComponent.InteractionPrompt` = "Teleport", `InteractionUnavailableAdditionalDescriptionText` = "Inactive"). It has the same `GameplayObjectRegistryIdentifier` and `TeleportLocationOffset` (0, 0, 145 cm).
  - Its `ULodestoneComponent.GameplayObjectRegistryIdentifier` reads all zeros. The wiki says most lodestones are player-built (32 Stone, 20 Rune Essence, 1 Vault Core, Construction 80), and that the Temple Woods one turns active when the first one is built.
- **Luis's side (READ ONLY):**
  - Luis's `BP_PlayerController_C` has `LodestoneTeleportationComponent` (`BP_Components_LodestoneTeleportationComponent_C`) with `bEnableTeleportationCost=true`, cost item `/Game/Gameplay/Items/Resources/Magic/ITEM_Rune_Law`, `bHideMapAfterTeleportationStarted=false` and `bShouldTryDamageOnTeleportComplete=false`.
  - The component's BlueprintPure `CanTeleport(FromId, ToId)`, `GetTeleportationCost` and `CanAffordTeleportationCost` all work from Lua with **scalar-only FGuid tables** {A,B,C,D} (R15-safe; verified).
  - With a single lodestone, `CanTeleport(x, x)` = false, cost = 1, afford = true. So the per-player gate is the game's own `CanTeleport` rule, and travel.lua counts a lodestone as unlocked when another registered lodestone can reach it. **Proving a true `CanTeleport` needs a second (built) lodestone.**
  - `CalculateTeleportationCost(Distance, Weight)` (const BlueprintNativeEvent) gives 8000 cm/400 → 2, 800000 cm/0 → 4, 800000/400 → 164, and is capped at 999. It is nonlinear and is not the wiki's formula.
  - Luis's `RevealedMapFogComponent`: `CurrentMapRegion` = Temple Woods (RegionID 1), and `RevealedMapRegionsBitmap` = 268435455 (0x0FFFFFFF, 28 bits). The bit-to-RegionID mapping is UNVERIFIED. `RevealedMapIconsComponent.RevealedLandmarkNames` (TSet) read back empty, probably because UE4SS has no TSet ForEach.
- **Map regions** come from `BP_MapRegion_C` actors in the persistent level, which are always loaded on the server. There are 31 of them, each with `RegionID`, `RegionName` (FText), `PowerLevel` and a closed `BoundarySpline` (6-90 points, read with `GetNumberOfSplinePoints`/`GetLocationAtSplinePoint(i, World=1)`/`GetLocationAtSplineInputKey`).
  - By id: 1 Temple Woods, 2 Bramblemead Valley, 3 Whispering Swamp, 4 Fractured Plains, 5 Stormtouched Highlands, 6 Bloodblight Swamp, 7 Bleakfields Valley, 8 Hope's Fall, 9 Lake of Lost Souls, 10 Coalridge Pass, 11 Silverthorn Keep, 12 Dragons' Run, 13 Witchwillow Range, 14 Emberwood, 15 Forgotten Temple, 16-25 the Dowdun Reach areas (The Approach, Library, Courtyard, Menagerie, Garrison, Nexus, Pastures, Cathedral, Bastion, Grand Hall), 26 Alcarrid Oasis, 27 Dunes of Uzzer, 28 Manafem Plains, 29 The Burning Spire, 30 Rasthin's Rest, 31 Scorned Wilderness.
  - **There is no "Fellhollow" region in this build.** It is named only in a wiki changelog, so it is probably a newer area or a sub-area name. **Corrected 2026-10-26:** Fellhollow is a *province*, not a map region; see "Provinces" below.
  - The polygons overlap, so the smallest one containing the point wins (`travel.region_at`). Live: `[2100, 400]` → The Library, `[2200, 1850]` → Manafem Plains, `[-7000, 7000]` → Scorned Wilderness, `[5000, 5000]` → none.
  - `BP_RegionLabelActor_C` (`MapRegionIconComponent.LabelText`) gives 33 map labels (with `\r\n`). Some of their positions are in map space and do not match the region polygons, so they are not used.
  - `AGameplayObjectRegistry.Landmarks` has 558 entries (category 3 = NPC/lore 248, 5 = anima vents 239, 6 = shrines/urns, 8 = kebbit burrows, 11 = agility courses such as "Tower Climb", "Fractured Ruins", 1 = the boss altar). Mostly `InternalName` = None; the useful text is `UserVisibleDescription`.
- **The server streams World Partition cells only around players.**
  - Only 2 `LandscapeStreamingProxy` tiles with bounds were loaded (252 m squares; `GetActorBounds(false, out origin, out extent, false)` works from Lua with empty tables as out params). There were 5-9 `_Generated_` cells, and all 18 AI characters were within 107 m of Luis.
  - A puppet teleported into an unloaded area would fall, and a fall death is the R1 unpossess path. So `travel` only teleports to loaded destinations, and a settle check rolls the teleport back on a fall.
  - Far teleports would need a `UWorldPartitionStreamingSourceComponent` on the puppet (UE5 docs: it makes any actor a streaming source). Not built; it needs an offline canary.
- **Puppet teleport, verified live (15:48:02 UTC):**
  - `K2_TeleportTo({X,Y,Z}, {Pitch=0, Yaw, Roll=0})` (scalars only) moved the puppet 104 m from `[107.39, 1803.25, -30.04]` to exactly the arrival point `[50.65, 1890.26, -34.88]`.
  - After 1 s it was standing at Z -35.05 (no fall). The nav probe `MoveToLocation` +1.5 m returned 2 (RequestSuccessful).
  - A concurrent gather_test loop then walked it 25 m from the pad: **AI nav keeps working after a teleport.** Later 2 m moves returned 2.
  - The puppet then stuck at `[65.8, 1870.3]` inside the Temple ruins (dense StaticMeshActors of the lodestone's own UAID family). `go_to` back to the open spot accepted the request but made only 6 m (path_blocked after 3 reissues). Some 10 m destinations there fail to project (0).
  - So walking out of the Temple Woods lodestone pad is blocked by geometry or navmesh there. That is a navigation issue at that spot, not a teleport issue.
  - Recovery: `travel_probe back` (puppet.teleport_near Luis). Separately, `MoveToActor(Luis)` fails (REQ 0) at Luis's own spot, so he is standing off-navmesh (on a structure?).
  - **Pending Luis's eyes:** did Claude vanish and appear at the lodestone? (At 15:48 Luis was about 75 m away.)
- **Route decision (search-before-building, 2026-10-25):**
  - Need: teleport the puppet to a lodestone like a player does.
  - Searched: the wiki (Lodestone page), Whisper of the House and Destructoid fast-travel guides, Nexus (no Dragonwilds teleport mod found), Epic K2_TeleportTo docs, UE World Partition streaming-source docs.
  - Decision: **adapt**. `K2_TeleportTo` to the registry's RespawnLocation, plus a crowd offset of 150 cm when a player stands on the pad.
  - `TeleportationSubsystem:TeleportWithParams` was rejected: it takes a delegate and drives a PlayerController's loading screen and client RPCs, which the puppet lacks (R1 class). `UBaseTeleportationComponent::Server_TryTeleport` was rejected too: it lives on a PlayerController.
  - Sources: https://dragonwilds.runescape.wiki/w/Lodestone , https://www.whisperofthehouse.com/runescape-dragonwilds/fast-travel , https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/AActor/K2_TeleportTo , https://docs.unrealengine.com/5.1/en-US/PythonAPI/class/WorldPartitionStreamingSourceComponent.html
- **Built:** `mod/body/travel.lua` (`travel`, `where`, `lodestones`; registered in main.lua's TRAVEL block, so it **needs a restart**). Tests are in `mod/tests/test_travel.lua` (22).

## Provinces: the 31 map regions are sub-regions of 6 provinces; NPCs have one copy per province (build 26161880, 2026-10-26; offline: dump + wiki mirror)
- **Luis's fact (2026-10-26):** NPCs such as Zanik and Vannaka exist as several copies, one in each big region (province). In Brynmoor you see only one copy, but they also exist in Ghornfell (e.g. Stormtouched Highlands), Fellhollow, Dowdun Reach and so on. This replaces the earlier unverified guess in brain/places.py and build_places.py that "an NPC moves between its spots with quest stages".
- **Province names = the game's own `EQuestRegion` enum** (`dumps/26161880/luatypes/Dominion_enums.lua`; used by `FQuestData.QuestRegion` and `QuestListItemTooltip.QuestRegionToTextMap`): 1 Brynmoor, 2 Ghornfell, 3 Fellhollow, 4 Dowdun_Reach, 5 Umbral_Sands, 6 Scorned_Wilderness. Asset folders match this split: `/Game/Gameplay/Quests/FH_Quests/` (Fellhollow), `UmS_Quests/` (Umbral Sands, e.g. `Quest_UmS_Vannaka`), `/Game/Gameplay/NPCs/Fellhollow_NPCs/`, the `/DowdunReach/` plugin, and `ScornedWilderness/`.
- **No reflected parent link:** `AMapRegion` has only RegionID, RegionName, PowerLevel, BoundarySpline, Day/NighttimeExposureValue, `MapRegionTag` and `QuestConversationEntryTag` (both FGameplayTag). There is no province, zone or parent property, and `UMapRegionIconComponent` (the map labels) has only label styling. The two tags have never been read; if `MapRegionTag` is hierarchical (`…<Province>.<Area>`), it is the game's own mapping. Live check `tools/live_checks/places_region_tags.json` (places.lua now reads both tags, read-only; dry-run valid, pending). `tools/build_places.py` prefers a province named in the tag over the wiki.
- **Sub-region → province mapping (from the wiki mirror, names only):**
  - Every region has its own infobox `location:` (for example https://dragonwilds.runescape.wiki/w/Temple_Woods), and the lists at https://dragonwilds.runescape.wiki/w/Ashenfall#Brynmoor (and #Ghornfell, #Fellhollow, #Dowdun_Reach, #Umbral_Sands) agree with them.
  - **Brynmoor:** Temple Woods, Bramblemead Valley, Whispering Swamp.
  - **Ghornfell:** Fractured Plains, Stormtouched Highlands, Bloodblight Swamp.
  - **Fellhollow:** Bleakfields Valley, Hope's Fall, Lake of Lost Souls, Coalridge Pass, Silverthorn Keep, Dragons' Run, Witchwillow Range, Emberwood, Forgotten Temple.
  - **Dowdun Reach:** The Approach, The Library, The Courtyard, The Menagerie, The Garrison, The Nexus, The Pastures, The Cathedral, The Bastion, The Grand Hall.
  - **Umbral Sands** (from the Ashenfall list; these pages have no infobox): Alcarrid Oasis, Dunes of Uzzer, Manafem Plains, The Burning Spire.
  - **Scorned Wilderness:** the region of that name (the region is named after the province; the wiki infobox says only "Ashenfall"), plus Rasthin's Rest. Rasthin's Rest is **inferred** from geometry: its polygon overlaps only the Scorned Wilderness polygon, both are power 8 and far off the main continent, and the wiki's Regicide page says that after the Scorned Wilderness gate you "speak to Zilyana in Rasthin's Rest".
  - **"Stormtouched Highlands" is a sub-region** (of Ghornfell), not a province, even though players name it alongside the provinces.
  - A cross-check web search agrees (https://dragonwilds.runescape.wiki/w/Brynmoor , https://dragonwilds.runescape.wiki/w/Ghornfell , https://gamever.io/knowledge-base/ashenfalls-five-regions-in-order-power-levels-hazards-and-what-gates-each-one). The wiki counts 5 regions; the game's enum adds Scorned Wilderness (the raid).
- **The data agrees with Luis:**
  - **Vannaka:** 4 registry spots, one per province: Temple Woods (Brynmoor), Stormtouched Highlands (Ghornfell), Bleakfields Valley (Fellhollow), The Courtyard (Dowdun Reach). The wiki's Vannaka infobox lists the same areas, except it says The Library.
  - **Zanik:** 6 spots: Brynmoor 2 (Temple Woods and Bramblemead Valley; the wiki lists both), Fellhollow 1, Dowdun Reach 1 and Umbral Sands 2. So a province can hold more than one spot with the same name. Which one he stands at is unknown until seen.
  - **Doric:** 4 spots, one each in Brynmoor, Ghornfell, Fellhollow and Dowdun Reach.
- **Built:**
  - `tools/build_places.py` writes `provinces` (name, quest_region_id, regions), each region's `province` and `province_source`, and each landmark's `region` and `province` into `data/places_26161880.json`. It was rebuilt from the live client dump `logs/places_raw_latest.json`: 31/31 regions now have polygons, and 31/31 have a province.
  - `brain/places.py`:
    - every spot and region carries its province; answers carry `you_are_in_province`;
    - NPC answers put the copy in his province first and add a `summary` ("Zanik: copy in Brynmoor (your province) at Temple Woods, 143 m; other copies in …"), `spots_by_province` and `other_provinces`, keeping the spot list nearest first;
    - province names are answerable ("Fellhollow" → its regions, power levels, the lodestones and points he knows in it, and its nearest known point);
    - a wiki page that names a province narrows the spots to that province.
  - All of it is data-driven: no NPC names in code.
- **Search-before-building:**
  - Need: a province level above the map regions.
  - Searched: the reflection dump (AMapRegion, MapRegionIconComponent, enums, asset paths), the local wiki mirror, and the web (wiki region pages, third-party guides).
  - Decision: **adapt.** Use the game enum for names, the wiki for the mapping (names only), and the game tag when it reads hierarchical. There was nothing to reuse beyond the data itself.

## NIGHT SKIP WORKS: the bot summons a shelter and sleeps (verified 2026-10-25, 15:51 UTC, Luis via GFN)
- The game counted the bot as a player ("waiting for players to sleep … waiting on Claude").
- **Not enough:** the `bIsSpectator`/`bOnlySpectator` valve (the game still waited on Claude) and the PlayerRestComponent.IsSleeping flag alone.
- **Works:**
  1. SpawnActor of the Summon Shelter class `/Game/Gameplay/UtilityMagic/PerkSpells/SummonShelter/BP_Magic_SummonShelter.BP_Magic_SummonShelter_C` (class taken from a live shelter; the bot can't cast the spell itself) 3 m in front of the bot (`mod/experiments/shelter_spawn.lua`).
  2. `BedComponent:Sleep(puppet)` directly from about 3 m, with no walking (`mod/experiments/bed_direct.lua`). Walking to the shelter fails with path_blocked because of the shelter's collision.
  - `CanSleep(puppet)` returned false, but Sleep still took effect: CurrentRestingAreaActor = shelter, and the watcher showed bot `true|shelter` at 15:51:49.
- **Night passed at 15:51:52** (3 s later), and both woke at 15:51:55. Luis: "Worked a treat."
- Productise: the sleep skill's shelter fallback = spawn shelter + direct Sleep. The reflex fires when Luis's rest state goes sleeping. The spectator valve is useless and should be removed or relabelled.

## Gather: hit calibration, the damage cache, fallen logs (build 26161880, 2026-10-25 15:25-15:50 UTC, Luis watching)
Modules: `mod/experiments/reach_calib.lua` (teleport + rotate + one swing per grid point, no emulated damage), `mod/body/reach.lua` (shape window + aim solution), `mod/body/hitcheck.lua` (gate hooks + damage-cache hook). No crash (dumps stayed 10).
- **Damage cache hook works:** `RegisterHook("/Script/Dominion.PlayerMeleeAttackComponent:Multicast_SendDamageCacheData")` fires once per puppet swing with `TArray<FTimedDamageInfo>`. Read-only nested reads are fine (R15 is about pushing). Per swing: `TimeOffset` (0.597 s Chop, 0.917 s Overhead), `DamageInfo.Location` (the attacker; for the overhead Z is 40 cm lower = the shape Offset), `AttackId`, `Shape` = `DominionShape_Wedge`, `DamagedActors[]` -> `PointDamageEvent.{Amount, VictimLocation, HitLocation, InstigatorLocation}`. `victims=[]` = whiff.
  - **`PointDamageEvent.Amount` was 0.0 on EVERY recorded victim, including kebbit hits that did damage (coordinator), so it is NOT the applied damage.** Use the target's HP for damage, the cache only for contact.
  - `VictimLocation` is the victim ACTOR's origin. For a rolled log this is stale (below), which explains a victim 6.7 m from its hit point.
- **Chop (`BP_Player_Axe_Woodcut1`) on a standing ash (`BP_BM_Tree_Ash_03_C`, 24-point grid; d = 2D distance pawn to trunk origin, delta = pawn yaw minus bearing to the trunk):** hits for delta -75..+15 at d 110-140, -45..+45 at d 80; misses for +45/+75 at d >= 110; at d 170 only 2 of 6. So the target must lie about **35 deg to the RIGHT (clockwise) of the pawn's forward** = AngleOffset +35 with UE yaw sign; TopAngle 80 is the FULL width (+-40, widened by the trunk); reliable to **~140 cm from the trunk centre** (Depth 115 + trunk radius). The aim is `yaw = bearing - 35`.
- **Overhead (`Woodcut2`) on the same ash:** hits for delta -15..+15 at d 80-160, 0..+15 at d 200; -30 always missed. Straight ahead; Depth 170 + trunk radius, TopAngle 15 widened by the trunk at short range.
- **Fallen logs: the actor origin is STALE.** The trunk meshes are physics-simulated and roll, while `K2_GetActorLocation` stays where the piece spawned. `BP_Log_Oak_C_2147472221`: origin [96.08,1822.71] but `GetMidPointWorldLocation` [107.47,1820.60] (11 m away, log type 10 = a quarter piece). Every swing aimed at the origin, or at an axis computed from it, whiffed (18/18 around the bad point). Around the MIDPOINT: hits at 1.1-2.1 m facing it within +-15 deg (teleports closer were pushed out of the log's collision to >= 61 cm). **Aim logs at `GetMidPointWorldLocation`.**
- **Aimed contact still does 0 damage (tree gate).** 32 contacting Chop/Overhead swings on the ash (each logged ModifyDamage on DA_HatchetOnly plus a damage-cache victim) left it at 160/160 HP. Hook results on a verified contact (oak, 14:36): GetHeldEquipmentThatInflictedDamage -> HeldEquipment nil; IsDamageCausedByUnarmedAttack -> true; IsEquipmentOfSufficientTier/Category never called; ModifyDamage Amount 10; HP unchanged. Caveat: these out-param values were read in the single UE4SS callback, which ran after the inner functions (call order inner-first); if UE4SS called it before the body, they would be unset values. The "tier/category never called" part does not depend on that.
- **Whiffs in the gather loop also came from MOVEMENT:** swings issued while the AI MoveTo was still running pointed the wedge along the path (orient-to-movement). Gather now stops movement and waits 400 ms before each swing (`SETTLE_MS`).
- **Live gather results:** 15:02, the live handler: oak felled (2 emulated hits), stump chopped, 2 logs collected, then path_blocked. 15:15, hot-loaded (`gather_test`): **6 oak logs gathered end to end in 134 s** (14 emulated hits: 2 leftover splittable logs, 3 `BP_Log_Oak_C`, the old stump, 7 drops picked up). Bot inventory now 14 oak logs (persisted across the 15:32 restart).

## Summon Shelter ownership (2026-10-25, build 26161880), partial
- Luis reported "Claude's shelter has no owner" (bot shelter spawned via SpawnActor, see shelter_spawn).
- `BP_Magic_SummonShelter_C` super = `/Script/Dominion.UtilitySpell` (AUtilitySpell: GetCaster(), Dispel(), CastID, StartingDuration/EffectDuration). BP members: Bed (BedComponent), Interaction, Bedroll, tent meshes, VFX. Not in dumps/ (loads late); probe with experiments/shelter_probe.lua.
- Live probe (experiments/shelter_caster.lua): Luis's own cast shelter ALSO reports GetCaster/Owner/Instigator = nil and bed claimant "Unknown Character", claimed=false. So the caster is not exposed through reflection after the cast; the owner text the client shows comes from somewhere not yet found.
- `BedComponent:Claim(bot)` runs without error but `IsClaimedByPlayer(bot)` stays false (likely needs a PlayerController/PlayerState path the puppet lacks). Summoned shelters have bRequiresClaimingToSleepIn=false, so ownership does not block the night skip.
- Spawned shelters expire (the bot's was gone within ~10 min), consistent with UtilitySpell EffectDuration.
- Gotcha: debug_run loads modules from the DEPLOYED mod dir, so run tools/deploy_mod.ps1 after editing an experiment (no restart needed).

## Client jump lock after night skip (2026-10-25), unconfirmed cause
- After the bot-assisted sleep/night skip Luis could not jump; a relog fixed it. Possibly a client-side rest/sleep state not cleared. Watch for it on the next sleep test.
- **Productised (2026-10-25, `mod/body/sleep.lua`; needs a server restart to load):**
  - **Shelter fallback:** the class comes from `StaticFindObject` by path, then a live shelter's `GetClass()`, then `LoadAsset(path)`. It is spawned 3 m from the bot, on the side away from the nearest player, skipping spots within 5 m of a player or 4 m of another bed, at the bot's own height (no traces: R15). Then a direct `Sleep(puppet)`, never walking inside. `CanSleep` is logged but does not gate.
  - **Bed route:** walk to within 3 m, or sleep from up to 4.5 m when the bed's own collision stops the walk. Then a direct Sleep.
  - **Reflex:** fires on Luis's `PlayerRestComponent.IsSleeping` going true. On false it wakes the bot (`StopSleeping` only if the bot is still asleep; live, the game woke both), removes the bot's shelter (`SetLifeSpan(0.1)`, R6) and resumes follow.
  - The rest-flag and spectator options are removed from the service; `sleep_probe` keeps them, labelled ineffective.
  - UNVERIFIED: whether a spawned shelter outlives a server restart in the save (the bot removes its own on wake).

## Crafting: recipes, stations and unlocks from live game data (build 26161880, 2026-10-25, about 15:44-16:00 UTC, Luis connected; no crash, dumps stayed at 10, no restart)
Modules: `mod/scripts/recipe_dump.lua` (read-only extractor), `tools/build_recipes.py` -> `data/recipes_26161880.json` + `mod/body/recipe_data.lua`; service `mod/body/crafting.lua`; drift check `mod/experiments/craft_drift.lua` + `tools/craft_drift.py`. Each extraction stage ran alone with a ping and a crash-dump count after it.
- **Recipes:** `FindAllOf("RecipeData")` returns all **1232** loaded at idle (1225 `RecipeData` + 7 `URuneRecipeData`; 0 errors, 0.5 s game-thread CPU). Struct arrays (`ItemsConsumed` etc., `FItemDataContainer{ItemData, Count}`) read via `ForEach`/`get()`. Every recipe has `CraftTime` 0.5, `MaxCraftTime` 1.5, `CraftQuantityMultiplier` 1.2 (one has 1.0); `Min/MaxProcessingTime` mostly 8/12 s (14 at 120 s). `ChanceToProduceExtraItems` is 0.05 on 41 recipes, else 0. 52 recipes have an `AlternativeItemCreated` (burnt food) behind a player attribute (`ChanceToBurnFoodLevel2`). No recipe uses `FuelConsumedOverride` or `bConsumeItemsIndividually`. **There is no "tool required but not consumed" field on `URecipeData`** in this build.
- **Iron Bar** (cross-check with the wiki Bucket table): `RECIPE_Process_IronBar` = 3 `ITEM_Resources_IronOre` -> 1 `ITEM_Resources_IronBar`; `RECIPE_Process_Bar_Iron_From_Salvage` = 9 `ITEM_Resources_Salvage_Iron` -> 1 Iron Bar; both at the **Furnace** = `BP_Station_Smelter_C` (processing). Matches the wiki exactly. Whole-table check: 619 of 739 comparable recipes match the wiki; most of the 120 differences are wiki naming, about 20 are quantity changes (game data wins, e.g. Black platebody Mystic Cloth 2 vs wiki 4).
- **UE4SS: `FindAllOf` skips archetype objects.** The station component templates (`/Game/Gameplay/World/Stations/BP_Crafting_WeaponBench.BP_Crafting_WeaponBench_C:CraftingStation_GEN_VARIABLE`, 28 of them in the object dump) return 0 from `FindAllOf("CraftingStationComponent")` but resolve with `StaticFindObject(path)`. So `tools/build_recipes.py` takes the template paths from `dumps/<build>/UE4SS_ObjectDump.txt`.
- **UE4SS `UDataTable` Lua API works on the installed build** (`ForEachRow(fn(name, row))`, read-only): `DT_CraftingStationsDataTable` (12 rows), `DT_ProcessingStationDataTable` (25 rows, 8 of them developer test rows such as `TestOnlyFuel`), `DT_VendorDataTable` (5), and 24 `DT_Progression_*` tables with recipe unlock rows. `TArray<TSoftObjectPtr<URecipeData>>` (`LabeledRecipes[].Collection`) reads as paths via `GetObjectID():GetAssetPathName()`.
- **Stations** (row -> class -> display name): CraftingTable `BP_Crafting_StartingBench_C`, ToolsMeleeBench `BP_Crafting_ToolsMeleeWeapons_C` "Blacksmith's Bench", ArmourBench, FletchingBenchv2, JewelersBench, MysticForge, RuneAltar, PotteryWheel, RangeBronze `BP_Crafting_CookingBench_C` "Cooking Range", RangeStone, BrewingCauldron (crafting `BP_Crafting_Cauldron_C` and processing `BP_Station_Cauldron_C` share the row name); processing: Furnace `BP_Station_Smelter_C`, AdvancedSmelter "Blast Furnace", Kiln `BP_Station_CharcoalKiln_C`, Campfire, Grinder "Grindstone", Loom, Spinning Wheel, Sawmill, Stonecutter, Tannery, FermentationBarrel "Imbuing Barrel"; vendors: Fellhollow `BP_NPC_Death_C` "Death's Exchange", DowdunReach `BP_NPC_PostiePete_Dowdun_C`. `BP_Crafting_Cauldron_C`, `_Stone_Range_C` and `_CookingBench_C` are subclasses of `BP_Crafting_WeaponBench_C`, so the bot matches the exact class word, never `IsA`.
- **Processing data:** Furnace accepts Charcoal (`FuelValue` 120) and Fuel Pellet (360), `ProcessingRate` 5.0, 2 resource slots, 1 fuel slot, outputs spawn as `BP_RuntimeSpawnedWorldItem_ProcessingStation_C` (`bStoreOutput` false). Campfire burns logs/planks too (Oak 90, Maple 180, Yew 210).
- **Unlock rules** are `FProgressionBundleRow.UnlockQueryString`, e.g. Iron Bar: `ALL ITEMS[ Iron Ore ] AND ALL ACTORS[ BP_Station_Smelter_C ]` (`DT_Progression_Core`, row `T4_Resource_Bar_Iron`). 856 recipes have a bundle.
- **Luis's unlock mirror:** `PC.ProgressComponent.RecipesUnlocked` (TSet) read live: **827** recipes. Read-only, same pattern as `SpellsUnlocked`.
- **Interaction ranges:** `pawn.InteractableDetector.InteractionRanges` (TMap) = Short 250, Medium 350, Long 650, Fishing 1200 cm; every station's `Interaction` component is Medium. The bot counts as in reach within 350 + 100 cm (2D) and 300 cm vertically (the slack is UNVERIFIED).
- **The dev world has no placed station of any catalogued class** (FindAllOf on all 25 classes = 0), so no live craft has been run yet. Luis must build one (a Crafting Table is enough) for the live test and the drift check.
- Cost note: the `items` stage (all reads in one call) took 1.6 s of game-thread CPU; the others 0.02-0.9 s. Fine for a once-per-patch tool; run it when nobody is mid-fight.
- **UNVERIFIED models, to be measured by the drift check:** the multi-count craft time (`min(MaxCraftTime, CraftTime*1.2^(count-1))`), processing seconds (`count * mean(min,max) / ProcessingRate`, i.e. 2 s per Iron Bar) and fuel burn (`ceil(seconds / FuelValue)`).

### Recipe extraction and crafting emulation (search-before-building record, 2026-10-25)
- Need: a recipe/station catalog from game data, and server-side crafting for a bot with no PlayerController.
- Searched: Dragonwilds datamines and recipe exports; UE4SS DataTable / TSet / soft-pointer Lua docs; the wiki's Bucket API; prior art in the research doc (Mindcraft `getDetailedCraftingPlan`, mineflayer-crafting-util, Plan4MC).
- Found: no public Dragonwilds recipe dump with game ids (metabot.gg has a browsable item list only; guides are hand-written). UE4SS ships a `UDataTable` Lua API (`ForEachRow`, `FindRow`, `GetRowNames`; docs.ue4ss.com/dev/lua-api/classes/udatatable.html) and it is present in our UE4SS.dll. The wiki's `recipe` Bucket table returns all 1655 rows in one request (api.php?action=bucket).
- Decision: **adapt** `catalog.lua`/`build_catalog.py` (live extraction, staged, raw -> normalised, generated Lua table like `attack_data.lua`); **reuse** the UE4SS DataTable API and the wiki Bucket API for the cross-check; **build** the strict emulation (no existing server-side crafting emulation for UE4SS bots was found; the game's own `Server_CraftRecipe` needs a PlayerController inventory, R1/R8).
- Sources: https://docs.ue4ss.com/dev/lua-api/classes/udatatable.html · https://dragonwilds.runescape.wiki/w/Iron_Bar · https://dragonwilds.runescape.wiki/w/Furnace · https://dragonwilds.runescape.wiki/api.php?action=bucket · https://metabot.gg/dragonwilds/items

## Crafting: the real player path (build 26161880, 2026-10-25; from the reflection dump; a live capture is still pending)
Luis's direction change (binding, `docs/design/real-player-remediation.md`): no emulation. The emulated craft in `mod/body/crafting.lua` (take inputs from the Lua store, wait, grant outputs) was **removed the same day before it ever ran live**; `craft` answers `not_implemented`. What stays is route-independent: the recipe catalog and generator, the pure `plan`, the read-only feasibility check (`craft_check`), the station census and Luis's unlock mirror.
- **What a player's craft sends to the server** (all on `UInventoryController`, the PlayerController's component, Dominion.hpp:24740; reflected Server RPCs, so server-side `RegisterHook` sees them):
  - crafting station (bench, table, anvil, range, forge, vendor): opening the station is the generic interaction `PlayerInteractionManager:Server_RequestInteraction` (the station BP then runs `ToggleCraftingUIVisibility(PlayerCharacter)` → `ADominionPlayerController:Client_ToggleCraftingMenu(CraftingStationComponent)`); the craft itself is **`Server_CraftRecipe(UCraftingStationComponent* CraftingStation, URecipeData* Recipe, int32 Count, int32 BonusCount, float XPMultiplier, float BonusXPMultiplier, TArray<UInventoryComponent*> Inventories)`**. `Inventories` is the crafter's inventories plus linked storage (`UCraftingFunctionLibrary:GetLinkedInventories(WorldContext, BuildingPieceLocation, DefaultInventories, Out)`), so a craft can consume from nearby chests. The result comes back as `Client_OnCraftingResultHandler(ECraftingResult, Recipe, Count)`; `UInventoryController:CraftRecipe(...)` is the same call's client-side (non-RPC) entry, and `OnCraftingResult` the delegate.
  - `ECraftingResult`: Success 0, FailureMissingConsumedItems 1, FailureNotEnoughSpaceForCreatedItems 2, FailureCarryingTooMuchWeightForCreatedItems 3, FailureInvalidRecipe 4, FailureInvalidCount 5, FailureRecipeNotUnlocked 6, FailureNotEnoughVendorReputation 7. The game also checks bag space and carry weight, which `craft_check` does not (the Lua store has no capacity).
  - Pre-checks the game exposes (BlueprintCallable on `UCraftingFunctionLibrary`): `CanCraftRecipe(Crafter PC, CraftableRecipes, Recipe, Count, Inventories)`, `HasRequiredConsumedItemsForRecipe(Recipe, Count, Inventories, CraftingCostScale)`, `GetMaxAmountCraftableOfRecipe`, `IsValidRecipeForProcessing(Recipe, Inventories, FuelInventories)`. On the real-client route these replace our feasibility check.
  - processing station (Furnace, Kiln, Campfire, ...): no craft RPC. The player moves items into the station's `ResourcesInventory` / `FuelInventory` (`Server_MoveItemBetweenInventories(Src, SrcSlot, Dst, DstSlot)`, or `Server_SplitAndPutStack`, `Server_MoveAllItemsBetweenInventories`, `Server_FillStacksBetweenInventories`), starts it with **`Server_ToggleProcessing(UProcessingStationComponent*)`** (unless `bAutoStartProcess`), and the outputs spawn as `BP_RuntimeSpawnedWorldItem_ProcessingStation_C` world items at the station (`bStoreOutput` false for the Furnace), which he picks up through the normal magnet/pickup.
  - related: `Server_RepairItem(Station, Item, Recipe, Inventories)`, `Server_UpgradeMasterworkEquipment(Station, Inventory, SlotIndex, Inventories)`, `Server_SellItemFromInventory(..., CraftingStationComponent, Instigator)` (vendors).
- **UNVERIFIED until captured:** which of these a craft from Luis's GFN client actually fires, in what order, and with what params (e.g. BonusCount, XPMultiplier, the Inventories count). `mod/experiments/craft_drift.lua` now hooks all of the above (pre + post, params logged scalar-only) and `tools/craft_drift.py run` reports them as `real.rpcs` next to the inventory/station deltas. It has not run on a real craft yet: **the dev world has no station**.
- **Pawn yaw drifts during a swing toward `DesiredActionTarget` (16:00-16:05 UTC, gather_test).** Facing was exact right after `K2_SetActorRotation` + `SetControlRotation` (error 0), but `yaw_drift_deg` read at the damage point was -30..-112 deg on fallen logs (identical drift on consecutive swings from the same spot), and all 36 swings missed. Hypothesis (UNVERIFIED, last change before the stop): the melee attack turns the pawn toward `DesiredActionTarget`'s ACTOR ORIGIN, which is stale for a rolled log. Trees were fine because their origin is the trunk. Built but not yet run live: logs swing with no `DesiredActionTarget`. In reach_calib the hits on a log came with the pawn teleported and `DesiredActionTarget` set, so the drift must be measured there too before trusting the hypothesis.
- **Ground gatherables (read-only `interact_probe`, 15:58 UTC):** Luis's "sticks" are `BP_Spawner_AshBranch_0{1,2}_C` (`ABaseInteractableResource` <- `AGatherableResource`): `ItemData = ITEM_Resources_Wood_Ash` (display name "Ash Logs"), empty `ItemDropComponent.ItemsToDrop`, `IsResourceAvailable()` true, RespawnComponent 1/1, `InteractionComponent.InteractionPrompt` "Collect", InteractionType 0, InteractionDistance 1, `PlayerHookToTriggerWhenMadeUnavailableDueToInteraction` = `BP_FTUENotificationPlayerHook_C` (a player-only hook: a crash risk if fired for the puppet), foliage-depicted. Stones: `BP_Spawner_Stone_C`, `ITEM_Resources_Stone`, "Collect". Not interacted with: no grant route was tried (route-independent research only).
- **Generic perception works live:** `sense.look` (census via `InteractionComponent`, `DestructibleWorldActor`, `OreNode`, `DominionAICharacter`) listed the branch gatherables ("Ash Logs", verb gather), the summoned shelter ("Rest", interact), trees and logs (name from the class + drop item, verb chop from the gate tag), ranked "branches" to the four branch spawners (match 1.0).
- **Two-handed axe held one-handed:** the client anim proxy picks the pose from `LeftWeaponPoseType`/`RightWeaponPoseType` (`EAnimationPoseType` Unarmed/Default/Ranged) and `bIsLeftDefault`...; the axe's `UEquipmentData.Slot` = HeldTwoHanded and `HandPreference` = Left (catalog). Not fixed: we set only `HeldEquipmentActorRight`. `gather_probe held` now reads both hands, sockets, Slot and HandPreference, to compare with Luis holding a 2H tool (not yet run with him holding one).

## REAL CLIENT ROUTE (R2): headless client joins the dev server (2026-10-25, client build 26162923, server 26161880)
- **Headless works on this VM (no GPU):**
  - Launch: `steam.exe -applaunch 1374490 -nullrhi -nosound -unattended -nosplash -log` (tools/client_headless_test.ps1, which kills the client if free RAM falls below 600 MB).
  - The log shows `RHIAdapterName: Microsoft Basic Render Driver` and "This UE instance does not render". Steam SDK 1.57 and Redpoint EOS initialise, and it boots to `L_FrontEnd`.
  - Measured beside the server, with the bot puppet loaded on the server:
    - main menu: client about 1.0 GB, about 0.3 core;
    - **in world: client 1.86 GB, 1.2 cores**; server 0.93 GB, 0.2 core;
    - total CPU 64% of 4 vCPU, **1.2 GB RAM free of 8 GB**. Feasible but tight; 16 GB recommended.
- **Client-side storage:**
  - Characters are stored on the client: `%LOCALAPPDATA%\RSDragonwilds\Saved\SaveCharacters\<name>.json`, synced by Steam Cloud. Luis's were downloaded at login and backed up to `C:\GameServers\backups\luis_characters_20261025-173417`.
  - The client log is `%LOCALAPPDATA%\RSDragonwilds\Saved\Logs\RSDragonwilds.log` (UTC timestamps).
- **UE4SS on the client:** the same ASI-loader install as the server (tools/install_client_ue4ss.ps1). Mod `DWClient` (client_mod/) runs `client_io/cmd/*.lua` on the game thread and writes `client_io/out/*.json` (tools/client_cmd.sh).
- **Menu driven through the game's own UI API**, with no rendering or input needed:
  - `MainMenuUIAPI` (`FindFirstOf`) with `NavigateToScreen(EMainSubMenuType)` and `GetCurrentScreenType` / `GetCurrentScreenWidget`. Types: 2 Landing, 7 CharCreate, 8 CharSelect, 10 Worlds, 20 ConsentForm, 41 Eula.
  - **Character create (verified, `Claude.json` written):** `NavigateToScreen(7)`, then `OnCharacterTypeSelected_Standard()`, then `EditableTextCharacterName.EditableText:SetText(FText)` and `OnCharacterNameInputChanged(FText)`, then `CheckNameAndCreate()`.
  - **Consent:** `RefuseAll(<live WBP_GenericDialog3Buttons_C>)` (declines optional data sharing).
  - **EULA screen:** `OnConfirmClicked` / ConfirmButton `HandleButtonClicked` / the BndEvt fired but did not advance. Under NullRHI the ScrollBox has no layout (`GetScrollOffsetOfEnd` = 0). Bypassed by navigating directly; not needed for joining.
  - **Sign-in is required before joining:** Landing (2) `OnLoginTriggered()`, after which `DomMatchmakerSubsystem:IsUserLoggedIn()` is true. Without it the server rejects the connection with *"Missing user ID during connection"* (RedpointEOSNetworking).
  - **Direct panel:** `WBP_MainMenu_Worlds_C.DirectPanel` with `IpAddress.EditableText`, `PasswordText.PasswordText` and `GoToNextScreen()`. It only selected an "Online Session" list item and did not travel. Not solved yet.
- **JOIN VERIFIED:**
  - After sign-in, `KismetSystemLibrary:ExecuteConsoleCommand(pc, "open 127.0.0.1:7777?p=<base64 WorldPassword>?pf=PC?cpx=1")`. These are the same URL options a real client sends (seen in the server's `Login request` lines).
  - The client loads `L_World`. The server logs `Join succeeded`, then **`PlayerChar entered world [Account[PP:76561199797634942] Character Name[Claude] Guid[DCG:6CBB5130467171BAD741B5B4CD00286E]]`**.
  - So Claude is a genuine player: real login, real PlayerController, real character save.
- **Joined the Shockbyte world as Claude's own account (2026-10-25, 17:17 UTC).** bootymaxer (SteamID 76561198614193617) joined 203.16.163.204:20921 headless from this VM. The full client sequence is in client_mod/commands:
  1. `create_char` (first run only).
  2. `consent`.
  3. Sign in: `pick_char` → Landing (2), `CharacterSelectorWidget:OnSelectionUpdatedUpdatePlayerCharacter(0)` + `OnLoginTriggered()`.
  4. `join_server`: `open <addr>?p=<b64 pw>?pf=PC?cpx=1`, with the address and password in gitignored `client_io/secrets/server.txt`.
  5. `skip_intro`.
  6. The pawn spawns.
- **PlayerGuid = the Steam profile (persona) name** (`SetNameAndPlayerIdFromLocalUsername` → `Server_SetPlayerGuid [<persona>]`). Two accounts with the same persona collide: the server rejects the second with `Connection Failed for reason [DuplicateChar]`. bootymaxer had persona "luisdeburnaybastos"; it is now "Claude".
- **A new character plays the narrative intro first** (input mode `DIM_NarrativeIntro`, a Bink video that never ends under NullRHI). The pawn only spawns after it. `WBP_NarrativeIntro_C:OnOutAnimationFinished()` completes it, and the `BP_PlayerCharacter_C` pawn appears within seconds.
- Before the intro: `Remote Character load complete slot[Claude]` → `Started player profile stream` → `Connection to server has completed [success]`.
- **Client locomotion (Shockbyte, 17:22 UTC):**
  - The headless client has **no NavigationSystem** (`FindFirstOf("NavigationSystemV1")` = nil), so `AIBlueprintHelperLibrary:SimpleMoveToLocation(pc, goal)` does nothing.
  - **`pawn:AddMovementInput(dir, 1.0)` called every frame** (`LoopInGameThreadWithDelay(1, …)`) plus `pc:SetControlRotation` walked 13 m to 2.9 m in about 3 s. Luis confirmed he "ran towards me".
  - A 50 ms cadence leaves most frames without input, and the character jitters on the spot.
  - `pawn:Jump()` + `StopJumping()` jump visibly (Luis confirmed). `IsLocallyControlled()` = true.

## Client chat (R2): send and receive as a real player (2026-10-25, 17:30 UTC, client build 26162923, Shockbyte world)
Module `client_mod/scripts/chat.lua` (`M.start(log)`, `M.say(log, text)`); commands `chat_start`, `chat_say`, `chat_status`, `chat_probe` (read-only).
- **Live objects on the client (read-only probe):**
  - HUD `WBP_Chat_C` (`UChatWidget`), owned by `BP_DominionGameInstance_C` under `/Engine/Transient`. Its `OpenedChatSubWidget` is a `WBP_OpenedChat_C` with `MessageSendBox` (`UEditableText`) and `PlayerChatComponent` = Claude's own `BP_PlayerController_C.PlayerChat`. A second `OpenedChatSubWidget` under `/Game/UI/Chat/WBP_Chat.WBP_Chat_C:WidgetTree` is the class archetype: skip it (it has no MessageSendBox).
  - `HUDUISubsystem.ChatUIAPI` exists, but `UChatUIAPI` has no reflected functions.
- **SEND (VERIFIED, Luis saw "Claude: Claude here - chat test"):**
  1. `MessageSendBox:SetText(FText(text))`.
  2. Call `/Script/Dominion.OpenedChatSubWidget:OnTextCommitted(const FText& Text, ETextCommit CommitMethod=1 /*OnEnter*/)`, the native handler bound to the chat EditableText's commit (what Enter in the chat box runs).
  - Native code builds `FChatMessageData` from Claude's real identity and sends `Server_SendChatMessage`. **No struct is built in Lua.**
  - Afterwards the box text is "" (consumed).
  - It works with the chat box closed and invisible (`IsVisible` false, headless).
- **RECEIVE (VERIFIED):** post-hook on `/Script/JagexChatBackend.PlayerChatComponent:Client_ReceiveChatMessage(FChatMessageData)`. It fires on the client for every line, **including the sender's own line echoed back by the server** (about 1 s round trip, 17:30:39 send → 17:30:40 echo).
  - Read with `msg:get().MessageBody:ToString()`, `.SenderData.PlayerId` and `.SenderData.CharacterGuid` (an FGuid A..D). The nested struct reads in the hook are safe.
  - Luis's "hey claude" arrived as PlayerId 258, guid AD09D558…, and resolved to "Zezima". Claude is PlayerId 262, guid D06CFBE3….
  - `ChatWidget:OnChatMessageReceived` also fired once per line (counter `ui` = `rx` = 2), so the chat box displayed both.
- **Sender name:** GameState/PlayerState `DisplayNameComponent.SanitizedCharacterNames`, matched on `CharacterGuid.InnerGuid` → `CharacterName` (what the chat box shows). Fallbacks: PlayerState `OwnerGuid.CharacterGuid.InnerGuid`, then `PlayerId`.
- **`bIsChatEnabled` / `IsChatEnabled()` are FALSE on Claude's client, yet sending and receiving both work.**
  - `bIsChatEnabled` is a plain local `UPROPERTY` (not replicated, UHT).
  - `BP_PlayerController` gates the `IA_UI_OpenChat` input (opening the chat box) on `IsChatEnabled()`, so a human at this client couldn't open chat with Enter. The commit handler itself is not gated.
  - The platform check passed: the log shows `DominionContentRestrictionSubsystem: Updating privilege CanCommunicateOnline ... Succeeded`. Claude's `PlayerState.PrivilegeComponent:HasPrivilege(8 /*Chat*/)` = true.
  - Why it is false (headless HUD init?) is still open. It is **not** written by us.
- **Limits:** `Default__ChatDeveloperSettings.MessageCharacterLimit` (fallback 256). `say` clamps to it, strips control characters, and rate-limits below `SpamDetectionMessageLimit` per `SpamDetectionDuration`.
- **Events:** `client_io/events/chat.jsonl`, one JSON line each:
  - `{"type":"chat","from","text","ts" (unix s),"iso","self","player_id","guid"}`
  - also `chat_event` (`Client_ReceivePlayerEvent`, tag) and `chat_error` (`ChatWidget:OnChatErrorMessageReceived`).
- **Hot reload:** hooks are registered once (state in `_G.DWChat`) and dispatch to the newest handler, so re-running `chat_start` is idempotent (verified: second run registered nothing).
- **Search (search-before-building):**
  - Found no existing Dragonwilds or UE4SS chat mod using these classes. The closest is the Subnautica 2 MultiplayerChat UE4SS mod (nexusmods.com/subnautica2/mods/153), which uses its own RPC transport, so it doesn't apply.
  - UE4SS `FText()` docs: docs.ue4ss.com/lua-api/global-functions/ftext.html.
  - The wiki confirms public chat with a 256-character limit: dragonwilds.runescape.wiki/w/Chat.
  - Decision: **build a thin wrapper over the game's own UI handler**, reusing vendored dkjson (copied to `client_mod/scripts/dkjson.lua`).

## Client locomotion (R2) (2026-10-25, client build 26162923, dev server 26161880)
Service: `client_mod/scripts/move.lua` (go_to / follow / stop / status). Commands: `client_mod/commands/move_*.lua`. Nav oracle: `mod/experiments/nav_oracle.lua` (dev server, debug_run) plus `tools/nav_oracle.py serve` (file glue). Offline test: `lua client_mod/tests/test_move.lua <empty_dir>` (10 checks).
- **Dev-server nav oracle works:**
  - Call: `Default__NavigationSystemV1:FindPathToLocationSynchronously(<GameState>, a, b, nil, nil)`. It returns a `UNavigationPath`; `PathPoints:ForEach` gives the waypoints.
  - Example: creature to creature, 101.9 m, 7 points, 2-5 ms on the server. The full file round trip, client request to `resp.lua`, takes **about 157 ms**.
  - A failed path is still a valid object, with `GetPathLength()` = -1 and 0 points.
- **The dev server streams navmesh only around streaming sources:**
  - Settings: `wp.Runtime.EnableServerStreaming` = 1 and `...StreamingOut` = 1. The base navmesh is in `NavigationDataChunkActor`s, about 252 m cells. `RecastNavMesh-Default` has radius 30, height 150, RuntimeGeneration 2 (Dynamic).
  - With no player connected to the dev server, the chunks near Claude's Shockbyte spot were **0**, and every query failed.
  - **Fix:** an "anchor" `ATargetPoint` spawned there, plus `AddComponentByClass(/Script/Engine.WorldPartitionStreamingSourceComponent, false, <scalar FTransform table>, false)`.
  - Result: chunks went 0 → 1 → 4 within about 10 s, and paths resolve. No crash.
  - The anchor is relocated by destroy and respawn when a query starts more than 80 m away. The oracle answers `reason="loading", retry=true` for 6 s after a respawn, and the helper retries for up to 15 s.
- **Projection is required, and its out param fills a flat table:**
  - `K2_ProjectPointToNavigation(ctx, p, out, nil, nil, extent)` writes into `out.X/Y/Z` when `out` is a flat `{X,Y,Z}` table. `out.ProjectedLocation` stays nil, which is why the old body_probe never saw a projection.
  - Raw pawn capsule-centre points (about 0.8 m above the mesh) failed to path. Projected points work.
- **The start-area lodestone pad is a navmesh island** (as at Temple Woods). Paths from Claude's spawn spot come back `partial`, ending about 15-25 m out. The reverse direction, into the pad, is a 102 m path.
  - The mover follows a partial path to its end, then goes straight with the unstuck ladder.
- **Enhanced Input marshalling:**
  - `FInputActionValue` has **no reflected fields** (CXX dump: empty struct, size 0x20), so `InjectInputForAction` cannot be fed from Lua. The Nexus forum thread "how to call function with InputAction parameter" hit the same wall.
  - Use `EnhancedInputLocalPlayerSubsystem:InjectInputVectorForAction(action, {X=1,Y=0,Z=0}, {}, {})` (an IEnhancedInputSubsystemInterface function).
- **Sprint facts on Claude's client:**
  - `pawn.SprintComponent` (BP_Components_Sprint_C) has `SprintInputAction` = `/Game/Gameplay/Inputs/Actions/Basic/IA_Player_Sprint`, with `MinimumMovementInputRequired` 0.2.
  - `DominionUserSettings.bPressToSprint` = **true** (toggle).
  - `CharMoveComp` (DominionMovementComponent): `MaxWalkSpeed` 450, `GetSprintingMaxSpeed()` 680, `JumpZVelocity` 808.
  - `pawn.JumpMaxCount` = **2** (double jump available). `pawn.JumpInputAction` = IA_Player_Jump.
- **Steering verified on Shockbyte:** `go_to` (straight, no sprint) moved Claude 2.0 m in 0.6 s and stopped at a 1.4 m tolerance. That is 62 frames in 0.6 s, so the game-thread loop runs at about 100 Hz.
- **Time source:** use `GameplayStatics:GetRealTimeSeconds(pawn)`, not `os.clock()`. `os.clock()` is process CPU time, which runs faster than wall time on a multithreaded process (old walk_to.lua timeouts used it).
- **Client-side navmesh (later, needs a client restart):**
  - The client already streams `NavigationDataChunkActor`s (3 near Claude), but has no NavigationSystem or RecastNavMesh, and `NavigationSystemV1.bAllowClientSideNavigation` = false on the CDO.
  - Setting `[/Script/NavigationSystem.NavigationSystemV1] bAllowClientSideNavigation=True` in the client's Engine.ini might give a local navmesh from the same chunks, which would remove the dev-server dependency.
  - Untested.
- **Search (search-before-building):**
  - Nothing UE4SS-specific exists for client locomotion, Enhanced Input injection from Lua, or `FindPathToLocationSynchronously` from Lua. The UE forums confirm client-side FindPath returns empty PathPoints (answers.unrealengine.com/questions/102126, forums "Find Path to Location Synchronously returning wrong path on client").
  - Mineflayer-pathfinder (GoalFollow) and the Bloog bot (repath every update) were followed for the repath policy. Waypoint advance-by-one with a radius smaller than the waypoint spacing follows bugnet.io's "patrol waypoint skipping".
  - Epic docs: InjectInputForAction / InjectInputVectorForAction, the World Partition streaming-source component, and the World Partitioned Navigation Mesh guide (chunk actors stream with cells).
  - Decision: **adapt** (repath-on-goal-move from mineflayer and Bloog bot; server-side pathfinding with client steering, the usual UE pattern) and **build** the thin Lua loop and file glue. A `watchdog` file watcher was not needed for one polled file.
- **Follow test 1 (Shockbyte, 17:42:51-17:43:38, follow Zezima at 3 m):**
  - Sprint worked: 498-582 cm/s in the clear (walk 450), and 6.79 m/s in a later go_to.
  - The 45-66 cm/s "sprinting" windows were the stuck windows, not a sprint slowdown.
  - The stuck spot is an alcove under an overhang by the start-area lodestone, at (71.6, 1862.0, -34.7) m. Every oracle path from there was partial with length 0.06-1.9 m. Luis's breadcrumbs were 3.4 m above him. After the path ran out, straight-line steering went into the gap.
  - Luis: "he was following me correctly but there was an undercover, I ran out, he tried to get to me as the crow flies and got stuck in a gap."
- **Give-up bug (fixed):** per-window movement reset the stuck counter (jump/strafe wobble of about 52 cm, and 3-4 cm jitters), so a stuck go_to ran 110 s.
  - Progress is now **net displacement toward the goal ≥ 1.5 m, or a waypoint/crumb reached**, within 5 s (planning time excluded). Otherwise it stops with `{status:"failed", reason:"stuck", at_m}`.
- **Client hang (17:53:54, client PID 6400):** the GameThread sat in `NtWaitForSingleObject` under engine frames called from a UE4SS hook frame (export-only symbols). Render, async-loading and IO threads were idle. Stack: `logs/client/stack_6400_175704.txt`, taken with a non-invasive `cdb -pv`. Cause not identified.
- **IA_Player_Sprint:** ValueType Boolean (0), one trigger `InputTriggerDown`, `bConsumeInput` true.
- **Claude's measured jump envelope (live client, read-only):**
  - `JumpZVelocity` 807.9, `GravityScale` **1.85** (`GetGravityZ` -1813).
  - `GetMaxJumpHeight()` = `GetMaxJumpHeightWithJumpTime()` = **180 cm**; `JumpMaxHoldTime` 0.
  - `MaxStepHeight` 45, `WalkableFloorAngle` 45.5, `MinFallDamageHeight` 1500, `MaxFallDamageHeight` 2860, capsule half-height 88.
  - `SkillPerkComponent:IsPerkUnlocked(pawn.DoubleJumpSkillPerk)` = false. JumpMaxCount 2 does NOT mean double jump; that is Agility 10 (traversal research).
- **Physics traces from UE4SS Lua work (dev server, then the client):**
  - Call: `Default__KismetSystemLibrary:LineTraceSingle(ctx, a, b, 0 (TraceTypeQuery1), false, {}, 0, out, true, {R,G,B,A}, {R,G,B,A}, 0.0)` returns a bool.
  - An empty `out` table is filled as **nested** tables: `out.ImpactPoint.Z`, `out.ImpactNormal.Z`, `out.Distance`, `out.Time`.
  - Cost: about **1 ms per trace** from Lua on both (FHitResult marshalling).
  - **`out.bStartPenetrating` is unreliable.** It is a bitfield sharing byte 0xAD with `bBlockingHit` and reads true on clean floor hits. Use `Distance == 0` for "started inside geometry".
  - `CharacterMovement:K2_ComputeFloorDist(loc, 2000, 2000, 30, out)` also works on the dev server (`bWalkableFloor`, `FloorDist`, nested `HitResult`).
  - A trace started 5 m above the alcove spot begins inside rock, which confirms the overhang.
- **Local planner** (`client_mod/scripts/localplan.lua`; offline test `client_mod/tests/test_localplan.lua`):
  - A 1 m grid within 9 m of Claude. Two downward traces per cell (from feet + 1 m and from feet + 7 m) give up to two floor layers.
  - Edges: walk (≤ step), jump (≤ 1.65 m), drop (≤ 10 m). A* toward the far goal; an off-grid goal gives a segment to the closest reachable node.
  - Walls are checked lazily: horizontal traces on the chosen path only, re-planning on a blocked edge.
  - Patterns adapted: A* Pathfinding Project GridGraph/LayerGridGraph scan (arongranberg.com/astar docs), mineflayer-pathfinder move types, Lazy PRM (Bohlin & Kavraki 2000), Baritone-style segmented planning.
  - `move.lua` triggers it from a forward knee-height wall probe (hit normal Z < 0.7) or when stuck.
- **Nav oracle heartbeat:** `tools/nav_oracle.py serve` writes `client_io/nav/alive.lua` (`return <unix time>`) every second. The mover uses the oracle only while that is under 5 s old, so a stopped dev server costs nothing.
- **Windows file-lock race:** `os.replace(resp.tmp, resp.lua)` raises PermissionError while the client has resp.lua open, which crashed the helper once. Fixed by retrying.
- **Client locomotion v2: follow test 2, VISUALLY VERIFIED (Shockbyte, 18:11:53-18:13:11 UTC):**
  - Luis: *"He followed me quite well and jumped over obstacles."*
  - Luis ran about 200 m east at sprint speed. Claude held 35-40 m behind and closed to 3-4 m when Luis stopped.
  - 0 stuck events. 3 local plans from the wall probe, one with a jump edge, each about 0.9 s of standing.
  - 45 oracle requests. Sprint 6.6-6.8 m/s.
- **Planning standstill cut (v3):**
  - A world-aligned 1 m cell cache (30 s TTL) is shared by plans and by prefetch. Prefetch samples a cone 2-8 m ahead while moving, 2 traces every 3 frames, about 21 traces/s live (427 cells in 40 s). Budget is 16 traces/frame while standing.
  - Offline: a re-plan near an earlier one costs 0-50 traces (0.07-0.33 s), versus about 730.
- **"Walls everywhere" (18:18):**
  - Luis stood on a ledge 6.4 m up, out of jump reach. Inside the 9 m window, A* kept handing back routes to the cliff base, and the lazy wall check rejected each one, 12 re-plans in all.
  - Fixed: `localplan` now returns `unreachable_in_window` when its best node is under 2 cells closer than the start. Any planner failure, or the leader being more than jump + 1 m above within 15 m, switches to his breadcrumb trail from a crumb at Claude's level.
  - A dry run at the same spot toward Luis's next position found a 15-point walk route (737 traces, 1.04 s).
- **Persistent follow (v4, Luis's requirement):**
  - When Claude can still move but can't get closer for 5 s, follow enters `status="unreachable"`: he stands, faces the leader and re-checks every 1.5 s. He resumes when the leader moves more than 3 m, comes within jump reach, or comes near.
  - One event per episode goes to `client_io/events/move.jsonl`: `{"type":"unreachable","reason","leader_pos","my_pos","detail","mode"}`, then `reachable_again`.
  - Reasons: `leader_windstepped` (the leader's airborne rise exceeds 2.5 m; his airborne crumbs are dropped and the trail is cut at his take-off, so Claude holds there), `leader_double_jumped` (his `ReplicatedJumpCurrentCount` ≥ 2), `leader_above_jump_height`, `no_route`.
  - go_to still fails, with `reason="unreachable"` plus `why`.
  - The game's Unstuck is used only when Claude is wedged, meaning a 2.5 s backtrack test can't move him 50 cm.
- **The game's Unstuck path (found; not yet run live):**
  - `IA_UnstuckCharacter_Held`: Boolean, `InputTriggerHold` 3.0 s. It has no active mapping context in the world, so it is bound by the pause menu.
  - UI route: `MainMenuUIAPI:NavigateToScreen(12)` (`EMainSubMenuType` Pause = 12), then `WBP_PauseMenuScreen_C.ProgressButton_Unstuck:HandleHeldActionCompleted()` (UDomHeldProgressBarButton), then `Resume()`.
  - Server side: `ADominionPlayerController::Server_TeleportToPlayerStart` (not called directly, per the R2 rule).
- **The lodestone pad is a navmesh island in every direction** on the dev navmesh. From the alcove (71.6, 1862.0, -34.7), the path west into the pad is complete (12.8 m). Paths east, north-east and west out of the pad are all partial: 0.12 m, 13.1 m and 24.0 m to the boundary.
- **Auto-generated nav links (UE 5.5 experimental) exist in this build:**
  - `ARecastNavMesh.bGenerateNavLinks` is false by default.
  - `NavLinkJumpDownConfig` defaults: bEnabled, JumpLength 150, JumpDistanceFromEdge 10, **JumpMaxDepth 150**, JumpHeight 50, JumpEndsHeightTolerance 80, SamplingSeparationFactor 1, FilterDistanceThreshold 80, LinkBuilderFlags 1, **Up = Down area class = NavArea_Default**. So links are bidirectional, and the 1.5 m depth is within Claude's 1.65 m jump.
  - Links are generated during tile generation (dev.epicgames.com "automatic-navigation-link-generation"). Experiment: dev-server ini `[/Script/NavigationSystem.RecastNavMesh] bGenerateNavLinks=True`, then a restart (results below).
- **Auto nav links, RESULT (dev server restarted 18:2x UTC with the ini; bGenerateNavLinks reads True):**
  - The cooked chunk tiles carry no links: after the restart, the pad and alcove paths were identical to the baseline.
  - **Dirtying the local tile columns** regenerates them with links. Method: a movable `StaticMeshActor` with `/Engine/BasicShapes/Cube`, scaled flat (60-160 m), spawned 30 m ABOVE the area so it obstructs nothing on the ground, then destroyed after 3 s. `IsNavigationBeingBuilt` reads true for a few seconds.
  - The pad → east query then went from 3 points / 18.96 m (ending at pad level) to **8 points / 27.06 m, with a +1.85 m rise over 1.5 m (an up-link) onto the upper level** where Luis stands. That is the jump players use to leave the pad.
  - The 3.4 m alcove ledge stays unlinked (JumpMaxDepth 1.5 m), which is correct for Claude's 1.8 m apex.
  - `nav_oracle.lua` now does the rebuild automatically, once per anchor placement after it has settled (`links_rebuilt: true` in the reply).
  - `move.lua` v5 marks oracle segments rising more than 60 cm over less than 3 m as link endpoints. It walks to the take-off point and jumps there; link endpoints need strict 3D arrival, while ordinary points get a slope-aware tolerance of 65 cm + 0.9 × horizontal distance.
- **World-teardown crash rule (client, 18:08:42 UTC):** an access violation came from a Lua UFunction call in a game-thread loop 2 s after `disconnect.lua`. My `move_plandry.lua` LineTraceSingle loop had started 2 s earlier in the same batch, a likely source.
  - Convention: `_G.DW_PAUSE = true` is set by disconnect/join and cleared by the bridge 3 s after a new pawn is stable.
  - `move.lua` (loop, prefetch, traces, planner, Unstuck callback) and `move_plandry.lua` make no engine calls while it is set, or while the controller/pawn is invalid. Any per-frame Lua loop must do the same.
- **Slopes vs steps in the local planner (18:34):**
  - Cells 1 m apart on a walkable slope (up to 45.5°) differ by more than the 45 cm step. Before, they became jump edges, so Claude jumped up a 30° ramp five times.
  - Now |dz| ≤ 0.9 × run is a provisional walk. The lazy check takes ONE downward trace at the edge midpoint: a profile within 30 % of linear is a slope; otherwise it is a step, and that edge is re-planned as a jump/drop.
  - Offline: the 30° ramp is walked and a 90 cm step is jumped (`test_localplan.lua`, 13 checks).
- **Self-collision of traces (19:22 live root cause):**
  - `bIgnoreSelf` ignores Claude's pawn but NOT his attached gear actors (platebody, cowl, axe), which block traces. Every lazy wall check leaving his own cell hit his gear ("walls everywhere" / verify_exhausted), and so did the forward probe that started at his centre (constant "wall_ahead").
  - Fixes: the probe starts 60 cm out; wall checks are clipped within 55 cm of him (80 cm hid real walls next to him and caused corner cutting); his own cell uses his feet height.
- **Traces now use the pawn capsule's own collision profile:** `LineTraceSingleByProfile(ctx, a, b, FName("Player"), ...)`. `CapsuleComponent:GetCollisionProfileName()` = "Player". It is identical to Visibility at the spot tested, but it is the right semantics.
- **Ramp over dead space:** two surfaces less than head clearance apart are one walkable surface, the UPPER one (the lower has no headroom). Before, the ground under a ramp won and the ramp was dropped.
- **Oracle projection:** ±1.5 m vertical first, then ±6 m. With ±6 m a start under the church floor snapped onto the floor above it. Afterwards the pit → Luis (57.6, 1880.6) path was complete (26.6 m).
- **Lazy-check refinements:**
  - the first segment is checked from Claude's real position, not the cell centre (it can clip corners);
  - a wall hit point blocks every nearby crossing edge (one hit, not one re-plan per edge);
  - the local waypoint arrival radius is 45 cm (70 cm cut corners).
- **Oracle as primary router (19:44 live):** a 20 m cliff at (440, 1820, -37) below the grave plateau (441.6, 1829.1, -16.7) saw nav_requests = 1. The local planner suppressed oracle requests and fought the cliff toward the final goal.
  - Now: goals beyond 10 m (or above jump height) always get oracle routes; the oracle is re-queried after every local-plan failure; the local planner aims at the oracle route's next waypoint.
- **Corridor streaming (dev oracle):** trips over 120 m spawn streaming-source anchors every 120 m to the goal (at most 5), answering "loading" while they settle (10 s; the helper retries for up to 25 s). The goal area also gets its link rebuild.
  - Start area (100, 1830, -30.7) → grave area (442.6, 1836.5, -15.6): **complete 346.6 m, 13-point path**.
  - The 19:22/19:39 "357 m no_path" was really the START: the church pit is a navmesh island, so every path from it is partial.
- **Church start pit (Luis):** "a ramp in the middle to exit; he goes round the side of it, under the floor". Under-floor feet level is about -35.5 m and the church floor -32.1 m. The dev navmesh connects pit → ramp → upper floor only via an auto-link (73.9, 1874.0, -33.95) → (74.26, 1875.46, -32.1), and the upper floor does not connect to the doorway (89.5, 1851.2, -31.4).
  - The trap is seeded as **provisional** in `data/nav/L_World_seeds.json` (with a taboo toward the alcove), pending a recorded demo walk.
- **Lesson (19:41):** Claude got out of the pit by FOLLOWING Luis's breadcrumbs where go_to failed. But the trail was lost when the next command reset the move. Trails are now flushed to memory whenever a move ends or is interrupted.
- **Human-proven hill route:** Claude's own trail while following Luis up the grassy hill to the grave plateau (19:45), 27 points, route `grave_hill_up` in the seeds.
- **Navigation memory (`client_mod/scripts/navmem.lua`, tests `test_navmem.lua` 21/21, integration scenarios in `test_move.lua` 46/46):**
  - Per-world routes (self trips; the leader's walked trail as `demo:<name>`) in `data/skills/<world>/nav_memory.json`, plus map seeds. Dijkstra over route points, join edges (4 m), learned links as one-way edges, and taboo penalties (×10).
  - Traps: inside one with the goal outside, its exit comes first. A stuck spot that is later left by 15 m becomes a learned trap whose exit keeps growing for 10 more metres. Teleports (a jump of more than 10 m between samples) and candidates over 10 min old are discarded. The failed direction is tabooed.
  - `move.escape_trap()` / `commands/move_escape.lua` is for respawn/rejoin.
- **Escape ladder (v10):** memory route → learned link → **Bug2 wall-following** (left-hand, then right-hand, 12 s / 35 m per side, probes every 3rd frame) → (wedged: the game's Unstuck) → unreachable.
  - With a player within 40 m: one `{"type":"stuck","ask":"lead_me","where","helper"}` event. A go_to then waits (`waiting_for_lead`, up to 60 s), follows the helper's trail out, and carries on to its goal (`led_out`).
- **Leader double-jump detection:** use CHANGES of `ReplicatedJumpCurrentCount` (the replicated value stays stale after landing; traversal agent).
- **Church respawn → doorway, learned live (20:21 UTC):** a go_to to Zezima from the respawn point (50.7, 1890.2, -35.9) arrived in 18 s via the local planner, then Luis's breadcrumbs.
  - Stored as a self route: 23 points along the church floor, then UP THE CENTRAL RAMP (points 8-12 rise 3.7 m over ~10 m, about 20°), then to the doorway (88.55, 1850.9, -32.25).
  - Now verified map seeds: trap `church_respawn` (10 m, exit = that route) and trap `church_start_underfloor` (pit → ramp base by a 16 m dev-oracle leg, then the ramp).
  - The bridge calls `escape_trap()` after every respawn and rejoin.
- **New character (Agility 99, 2026-10-25 ~20:19 UTC):** `IsPerkUnlocked(DoubleJumpSkillPerk)` = true. Single jump unchanged (apex 180 cm, GravityScale 1.85).
  - Double-jump EDGES are disabled until measured by `client_mod/commands/move_calib.lua`, which writes `data/envelopes/Claude.json`; move.lua prefers it.
  - The calibration checks the spot (flat ±30 cm within 1.5 m, open at knee and head 2.5 m round, no roof) and takes the pawn via the arbiter.
- **The leader proxy reads (0,0,0) while relevancy-culled or teleporting (20:25 live):** Claude "followed" to the world origin 1.8 km away.
  - An origin position now counts as not visible. A target jump of more than 50 m resets the route and trail.
  - A leader more than 300 m away means hold plus `{unreachable, reason:"leader_far"}` (the lodestone catch-up hook).
- **Luis's double jumps rise 2.6-3 m** and were misread as Windstep at 2.5 m, which cut his trail. Windstep is now only rises over 4.5 m.
- **Low obstacles (felled log, 20:30 live):** the forward probe checks at knee and at jump height minus 30 cm. Blocked low but clear high means jump at ≤ 1.2 m with no planning. The lazy wall check marks such edges as hop edges (jumps), not walls.
- **Water (20:30 live: "he went straight through the lake"):**
  - This build has no UE Water-plugin bodies and no water PhysicsVolumes client-side.
  - The game signal is `pawn.EnvironmentComponent:GetNormalizedWaterDepth()` (0 when dry; above 0.25 = wading) and `CharacterMovement.MovementMode` 4 (swimming).
  - Water cells (2 m) are learned and persisted per world in navmem. On the first wade, a "water sense" calibration tests which trace channel (Visibility/Camera/WorldStatic/WorldDynamic) sees the surface above the bed (the pawn profile passes through water). If one does, the planner samples water in its window.
  - Water cells cost ×8; segment targets prefer dry ground; known water ahead triggers a re-plan.
  - UNVERIFIED live: whether any channel sees the real water surface.
- **Wall-point blocking fix:** a recorded wall hit blocks an edge only if it lies ahead along the edge (projection 0.1-1). A hit at the start cell had blocked every edge leaving it.
- **Trace profile bug (2026-10-25 21:33+, fixed 23:09):** Claude's capsule reports `GetCollisionProfileName()` = **"Custom"** (per-channel responses). "Custom" is a label, not a preset, so `LineTraceSingleByProfile(..., "Custom")` logs `COLLISION PROFILE [Custom] is not found` and returns NO hit: 27k log lines, a blind local planner.
  - Now: try the game's preset **"Player"**, then the engine's "Pawn", each validated by one downward trace beside Claude against the Visibility floor. Otherwise use the Visibility channel. The choice is shared in `_G.DW_TRACE_PROFILE` and shown as `status().trace_profile`.
  - Live on the dev world (23:14-23:15): "Player" validated; 0 profile errors; a 15.9 m go_to with 775 traces arrived in 6.3 s.
  - The offline fake had ignored profile names, which hid the bug. It now rejects unknown names like the engine (regression scenario 20).
- **Main menu pawn:** in `L_FrontEnd` the controller owns a `DefaultPawn` at (0,0,0). A go_to issued during a relaunch "drove" it. move.lua now requires a pawn with CharacterMovement: start() refuses, and ticks pause.
- **Client hang L28 (2026-10-26 07:14:32 UTC):** the cdb stack (`logs/client/hang_7368_20261026_081432.txt`, UTF-16) has the GameThread in `NtReadFile` ← `ucrtbase!fgetc` ← UE4SS Lua. That is the DWClient runner's `io.popen('dir /b ...')` pipe read, every 2 s.
  - Fixed: the runner reads `client_io/cmd/queue.txt` from a saved offset (writers append the name after writing `<name>.lua`). No process is spawned on any poll; module mkdirs go through a probe-and-cache `ensure_dir`.
  - Live (07:39:54): `DWClient loaded (json=dkjson, runner=queue)`; client_cmd and watchdog probes round-trip; bridge OK.
  - Design: `docs/design/client-runner-queue.md`. Test: `client_mod/tests/test_runner.lua`.
- **Deployment gotcha:** the game loads DWClient's `main.lua` from the DEPLOYED copy (`C:/Program Files (x86)/Steam/steamapps/common/RSDragonwilds/RSDragonwilds/Binaries/Win64/ue4ss/Mods/DWClient/scripts/main.lua`, installed by `tools/install_client_ue4ss.ps1`), not from the repo. Every other client module is `loadfile`d from the repo by path. A `main.lua` change must be copied there, then the client restarted.
- **The game's Unstuck crashed the client (20:49:34 UTC):** move.lua requested it twice via the pause menu (20:49:25 and 20:49:33) while Claude was on top of the shelter.
  - Crash: an access violation in UE4SS `LuaType::push_arrayproperty` (a Lua loop reading a TArray on an object being replaced after the teleport). Same class as the 18:08 disconnect crash. Dump `ue4ss\crash_2026_10_25_21_49_34.5457439.dmp`, stack `logs/client/hang_unstuck_8712.txt`.
  - Unstuck is now DISABLED by default (opt-in per call only; if used, it holds `_G.DW_PAUSE` across the teleport).
  - A wedged Claude reports `{stuck, ask:"lead_me", reason:"wedged"}` instead: a follow waits "unreachable"; a go_to waits for a lead.
  - A perched Claude (floor more than 60 cm below his feet at 3 of 4 points 90 cm round) first steps off: a jump forward, then 8 short pushes.
- **Two reach failures from Director run 3 (2026-10-26, 16:05-16:09 UTC, diagnosed from `logs/client/client.log`):**
  - **Sticks on a ledge.** `BP_Spawner_AshBranch_01_C` pickups sat at z ≈ -3160 while Claude stood about 4 m lower (capsule -3496). Every local plan saw floors at about -3216 with walls on top ("walls everywhere", djump edges).
    - Cause: gather's `stand_point` sent the goal at Claude's OWN height (`Z = me.Z`). So move planned a level walk, its dz0-based reason could never be `target_above_jump_height`, and gather's 40 s approach timeout ended each try as a bare "timeout".
    - Fix: the goal takes the target's height when it differs by more than 1.5 m. Targets far off his level sort later, and a 2D "close" from under a ledge no longer counts. The failure uses move's progress why (a timeout's stall why now names the height), in words: "they're higher up than I can jump".
  - **Pond.** A `BP_WaterVolume_C`'s origin is about 3.1 m under the surface (cam surface -3171, origin -3495). Interact's 6 spots round the origin were all in the water, and every one ended too_far.
    - Fix: `move.shore_point(log, water_m)` traces the water's edge (the water channel against the Player profile floor, or navmem water cells): the bank point to stand on, plus the surface point to face, and alternatives along the bank.
    - skills.new_episode uses it for water volumes (the bank counts as not "on top").
    - move also no longer swaps a goal that is IN known water for nearby dry ground.
- **World id (2026-10-26):** one resolver, `mod/body/util.lua` `U.world_id(root, opts)`. The order is: explicit (`opts.world`, `_G` or env `DW_WORLD_GUID`, `client_io/world_guid.txt`), then the joined server (`logs/state/last_join.json` addr against the FIRST line of `client_io/secrets/server*.txt`; the password line is never read), then `server_<host>_<port>`, else "unknown".
  - traverse_learn and move's nav memory use it; before, they fell back to "shockbyte", so dev learning was filed there. Note: `data/skills/shockbyte/nav_memory.json` holds dev-world routes learned before this fix.
- **One approach-progress watchdog (2026-10-26, offline):**
  - Every go_to/follow fills `move.status().progress` = {verdict ok|stalled|unreachable, why, dist_m, best_dist_m, since_s, elapsed_s, target_moved_m}.
  - It is set through `opts.progress` = {stall_s=12, gain_m=0.5, budget_s, moving_m=3, to={x,y,z}}; `move.progress_reset(log[, opts])` restarts the window.
  - The whys are move's own reasons, plus cant_catch, too_long, blocked, no_progress and target_not_visible.
  - `move.why_words(why, thing)` is the one words table, with grammar for "you", "it" or a name. It replaces the separate stall timers and word tables in combat, skills and shoot.
  - It only reports; move never stops on its own verdict. Tests: test_move scenarios 37-44.
- **Avoid zones for combat hazards (2026-10-26, OFFLINE ONLY, not yet live; spec `docs/design/velgar.md` §3c):**
  - Files: `client_mod/scripts/avoidzones.lua` (pure geometry), the move.lua API `set_avoid_zones` / `escape_zones` / `status().avoid`, and `localplan.lua` (`cell_cost(x, y, floor_z)` plus `dry_slack`).
  - Tests: `client_mod/tests/test_avoidzones.lua` and `test_move.lua` scenarios 25-36. Live-check commands: `move_zonetest`, `move_zoneescape`, `move_zoneclear`.
  - **Units:** zone x/y/z are in metres, like every move API; `r_cm` is in cm; `until_s` uses the same clock as move and combat (`GameplayStatics:GetRealTimeSeconds`), or `ttl_s` is relative.
  - **Normalisation:**
    - scalars only (UE4SS R15), so a table field is refused;
    - |x| or |y| over 50 km is refused as "looks like centimetres";
    - the version (which triggers a re-plan) changes only when the geometry changes, so re-sending every frame is free.
  - **Design (adapt, not build):** zones are a planner cell COST, not walls (influence-map A*).
    - The cost is 20 cells, plus 2 per second still left, capped at 60. So with no other way, the route crosses the zone that ends soonest, and `status().avoid.crossing` and the log say so.
    - The local planner aims at a zone-free cell up to 6 m further from the goal.
    - A follow whose leader stands in a zone holds at its edge (`status = "near_zone"`); a follow standing in one steps out first.
    - Navmem/oracle routes are not zone-aware: zones are short-lived and local, so the 9 m local planner handles them as Claude approaches.
  - **`escape_zones`** is an EQS-like query:
    - Candidates: 32 rays, taking the first point on each outside every zone (+40 cm capsule, +60 cm), filtered by the bound and sorted nearest first.
    - Reachability, using real traces (at most 8 candidates): a knee-height wall trace, plus floor traces every 1.5 m (no drop over 2.5 m, no climb, no start inside geometry); known water is skipped.
    - eta = 0.25 s + distance / speed, where speed is the measured sprint (else 6.8 m/s) or MaxWalkSpeed. If eta > time_s, it answers `too_slow` and does NOT move.
    - Otherwise it does a sprint-forced go_to, which arrives as soon as Claude is out of every zone (`result.out_of_zones`). The reply carries `prev` (the snapshot) so the arbiter can `restore` afterwards.
  - **Search record:**
    - Critch & Churchill, influence-map A* (https://www.cs.mun.ca/~dchurchill/publications/pdf/cog2021sneak.pdf);
    - danger zones as a path cost (https://discussions.unity.com/t/how-to-create-temporary-danger-zones-on-ground-and-have-ai-characters-move-from-them/666329);
    - Unreal area-cost pitfalls (https://forums.unrealengine.com/t/making-unreal-ignore-certain-areas-when-pathfinding/412637);
    - Limited-Damage A* (damage as a feasibility budget, not adopted: a soft cost is enough here; https://avesis.metu.edu.tr/yayin/12fd2447-c287-40f0-bbf3-b62962cb2796/limited-damage-a-a-path-search-algorithm-that-considers-damage-as-a-feasibility-criterion).
    - The engine-side alternatives were not usable: a NavArea/NavModifier cost would need the server's navmesh, and the client has no navmesh (route R2); EQS needs a server AIController. A search for Unreal EQS "nearest safe point" returned only Unity NavMeshQueryFilter docs.

## Client perception + inventory (R2) (2026-10-25, 17:30-18:00 UTC, client build 26162923, Shockbyte world)
Modules: `client_mod/scripts/sense.lua` (census + me), `client_mod/scripts/inventory.lua` (list, collect, equip, unequip, drop). Commands: `client_mod/commands/sense_*.lua`, `inv_*.lua`. Both reuse the dependency-free `mod/body/util.lua` via `loadfile` (works unchanged on the client).
- **Search (search-before-building):** no Dragonwilds or UE4SS mod drives inventory/hotbar/interaction from Lua (Nexus Dragonwilds list has only storage-slot mods; a Gothic 1 Remake UE4SS mod uses items from inventory, other game). UE4SS docs: `FindAllOf` returns nil or a table; a UFunction found by `StaticFindObject` is called as `fn(context, ...)` (docs.ue4ss.com/lua-api/classes/ufunction.html). Epic docs: `InjectInputForAction` / `InjectInputVectorForAction` "run modifiers and triggers as if the input came through the input system" (dev.epicgames.com .../IEnhancedInputSubsystemInterface/InjectInputForAction). Nothing found on calling interface functions from UE4SS. Decision: **build** thin wrappers over the game's own UI handlers and input actions (the MainMenuUIAPI pattern already proven on the menus).
- **Perception (read-only, verified):** on Claude's client `FindAllOf` returns only replicated (net-relevant) actors.
  - Players: `DominionPlayerCharacter` minus the local pawn. Luis's pawn appears only within relevancy range (it was absent at 300 m and present at 8 m); **PlayerStates are always present** (`players_online` = Claude, Zezima).
  - Creatures: `DominionAICharacter.LoadedData` (`UAIDataAsset`): `AIName` (FText: "Magpie", "Kebbit"), `Archetype` (`AI_ARCHETYPE`: 0 Aggressive, 1 Defensive, 2 Passive, 3 Bird, 4 NeutralUntilAttacked; Kebbit = 4, Magpie = 3), `bIsBoss`, `GameplayTags`; `CurrentAlertnessState` (`EAlertnessState`, 4 = COMBAT); `PowerLevel`. Health `HealthComponent:GetAuthoritativeHealth()`; **`HealthComponent.MaxHealth` is 0 on players and some AI, use `GetMaxHealth()`** (Kebbit 78/78, Magpie 2/2, Zezima 250/250). `GetAttitude` (DominionAiFunctionLibrary) was not called on the client (it may need the AI controller, which clients lack).
  - World items: `WorldItem` -> `ItemData.Name`, `GetStackSize()`. **Items a player drops have `MagneticComponentGrantItem.bAutoMagnetizationEnabled = false`** (`bAllowAutoMagnetization` true, category 1): the magnet never pulls them; Luis's drops lay 2.6-3.4 m from Claude (MagnetRange 350) untouched. They must be collected with interact ("Collect").
  - Resources: `DestructibleWorldActor` / `OreNode` / `BaseInteractableResource`. Tool gate from `DamageModifiersWhenTree` (trees) or `DamageComponent.DamageModifiers`: `RequiredCategory.TagName` + `RequiredTier` (Stone Boulder Pickaxe tier 1 HP 75; Ash splittable log Hatchet tier 1 HP 80; Ash Sapling HP 25, prompt "Uproot"). Names: `AWorldActor.DisplayName` / `StumpDisplayName`. Standing trees are foliage ISM on the client too (none listed at the spawn); `sense` does not convert foliage (state change).
  - Interactables: owners of `InteractionComponent` (prompt `InteractionPrompt`), typed by actor family (`WorldChest`, `WorldLodestone`) then component family (`CraftingStation`, `ProcessingStation`, `EnchantingStation`, `RestingArea` = bed, `Lodestone`, `Container`, `Inventory` = storage). Seen: Wise Old Man ("Talk"), Lodestone ("Teleport", `BP_WorldLodestone_C`), Lore Item ("Read"), loot chests ("Open"), Rememberance Shrine.
  - Census cost: 50-90 ms on the game thread at 40-300 m.
  - Me: `pawn.StaminaComponent:GetStamina()/GetMaxStamina()/IsExhausted()` (100/100); `pc.SkillComponent.Skills` (`TArray<FSkill{CurrentXP, SkillData}>`, `SkillData.Name`) + `SkillComponent:GetSkillLevel(SkillData)` + `GetTotalSkillLevel()`: 12 skills at level 1, total 12.
- **Inventory layout (verified):** `pc.InventoryComponent` = `BP_Components_Inventory_C` (`UPagedInventoryWithLogComponent`), 176 raw `ItemSlots`: raw 0-7 = hotbar (`NumberOfQuickActionSlots` 8), then `InventoryPages` in order: InventoryItems 32 (raw 8-39), InventoryRunes 32, InventoryAmmunition 32, InventoryQuestItems 72. The UI's `(SlotType, SlotNum)` = `EInventorySlotType` (0 QuickAction, 1 Items, 2 Runes, 3 Ammo, 4 Quest, 5 Loadout) + index within the page. `pc.LoadoutComponent` = 12 slots in `ELoadoutSlot` order. Fresh character: Torch (hotbar 1), Adventurer's Tunic + Leggings worn.
- **Live UI objects on the client:** `InventoryUIAPI` (in `HUDUISubsystem`, its `PlayerController` = the local PC; `GetInventorySlots(t)` returns a Lua table: 8/32/32/32/72); the hotbar widget `WBP_Inventory_QuickAccesBar_C` under `/Engine/Transient...WBP_Inventory_MainPanel_C` (the other instance is the widget-tree archetype) whose `QuickAccessSlotInputActions` = `IA_Inventory_QuickAccess_SelectSlot1..8`, context `IMC_GameplayUI`.
- **Collect = the interact key (verified, 7 items):** `pawn` InteractableDetector (`BP_Components_InteractionDetector`) picks `CurrentInteractable` itself (DetectionRange 900, CharacterTraceDistance 600). One frame of `StaticFindObject("/Script/EnhancedInput.EnhancedInputSubsystemInterface:InjectInputVectorForAction")(EnhancedInputLocalPlayerSubsystem, IA_Interact, {X=1,Y=0,Z=0}, {}, {})` (IA from `PlayerInteractionManager.InteractAction`) collected the targeted item; the detector then moved to the next one. Shield, pickaxe, axe, platebody, dagger in 5 presses; the cowl 3.4 m away was not targeted until the locomotion agent stepped him to 1.4 m facing it. Items landed in the first free hotbar slots (equipment) with **Luis's own instances** (durability kept: Bronze Shield 982/1050, Mithril Pickaxe 2124/2400, Mithril Logging Axe 2240/2400, Bronze Platebody 870/1250). No crash; interface UFunction called on the implementing subsystem works.
- **Equip = the hotbar number key (verified):** `WBP_Inventory_QuickAccesBar_C:UseItemInSlot(i)` (0-based):
  - Mithril Logging Axe (slot 3, key 4): Loadout HeldRight (7) **and** HeldLeft (8) both = the axe (two-handed); pawn `PlayerEquipmentComponent:GetHeldEquipmentDataLeft()` = `ITEM_Logging_Axe_Mithril`, `HeldEquipmentActorLeft` = `BP_Logging_Axe_Mithril_C`, `GetHeldEquipmentDataRight()` nil. The axe stays listed in its hotbar slot (the loadout references it).
  - Bronze Platebody (key 5): Loadout Body = platebody, the worn Adventurer's Tunic moved into that hotbar slot (the game's swap); pawn `CurrentBodyWearable` = Bronze Platebody. Hard Leather Cowl (key 7): Loadout Head, `CurrentHeadWearable`.
  - **Luis confirmed visually ("Yep looks good!", ~17:45 UTC):** platebody, cowl and Mithril axe all show correctly on Claude from his GFN client.

## R2 brain bridge on the client: live, hot-started without a restart (2026-10-25, about 17:47 UTC, client build 26162923, Shockbyte world)
- **Hot start through the command runner works.** `client_mod/commands/bridge_start.lua` `loadfile`d `client_mod/scripts/client_bridge.lua` into the running DWClient. That file in turn loaded a fresh instance of `mod/scripts/bridge.lua` and the four client modules (chat, move, sense, inventory: all `ok`). It then started a 100 ms `LoopInGameThreadWithDelay`. No errors in `logs/client/mod_20261025T174657Z.jsonl`. `chat.start` was re-run harmlessly (idempotent).
- **Round trip, brain to client and back** (`client_io/bridge/brain_to_client.jsonl` → `client_to_brain.jsonl`):
  - `ping` over 10 calls: 64–169 ms (mean about 115 ms, mostly the 100 ms poll);
  - `get_state`: 215 ms including census and inventory.
- **`get_state` read live** (read-only; no movement, no chat):
  - position, health 100/100, name `Claude`, skills, stamina;
  - `players` = Luis's character **`Zezima`** at 20.9 m; `players_online` `["Claude","Zezima"]`;
  - 2 Kebbits (passive);
  - stones, an ash sapling and dropped loot (ash logs, hide, antler, raw meat) in `nearby_items`;
  - `inventory` (hotbar + bag) and `gear` (Head Hard Leather, Body Bronze, Legs Adventurer's, HeldRight and HeldLeft Mithril Logging Axe);
  - `not_implemented` = only `places` and `structures`.
- **Capabilities** (dynamic, from the loaded modules):
  - `get_state, say, follow, stop, go_to, drop`, plus the debug tools `bridge_status, me, census, inventory, move_status, equip, unequip`;
  - `discover()` gives planner skills `go_to, follow, stop, drop`;
  - absent: attack, gather, craft, give, pickup, cast, sleep, wake, look, interact, place, and the rule tools.
- **Implications for the brain:**
  - On this world Luis's chat sender name is his character name `Zezima`, so `command_received.player` is `Zezima`.
  - An equipped item that came from the hotbar stays in its hotbar slot (see the equip entry above), so it appears in both `inventory` and `gear`.
- **Not yet exercised live:** say, follow, go_to, stop and drop through the bridge. Their owners' modules are being tested separately, and the brain was not started. **UNVERIFIED** until a supervised run.
- **Death and the gravestone (verified 17:43-17:50 UTC):** Claude died while standing still after a follow test. On death the hotbar and bag go into a **`BP_PlayerGravestone_C`** (`AGravestone : AWorldActor`). Its contents are a `BP_Components_WorldItemInventory_C` (`GetInventory()`; read from the client: Torch, Bronze Shield, Mithril Pickaxe, Mithril Logging Axe, Adventurer's Tunic, Bone Dagger). The **worn armour stays on**. The grave was placed at the death spot, 28 m from the respawn point at the start-area lodestone. `CanPlayerAccessGravestone(pc)` returned false on the client, but that did not matter. Recovery: walk within 1.2 m (move.lua go_to). The game's detector then targets the grave with prompt **"Take All"**, and **one plain IA_Interact press** puts every item back in its original hotbar slot, durability unchanged. The grave actor then disappears. No hold and no UI were needed. Respawn re-uses the same pawn object.
- **Cause of death = dehydration (verified):** the pawn's `BP_Components_PlayerDamage` (`DamageComponent`) `FatalDamageInfo` held `KilledBy` = his own pawn, `KilledByPowerLevel` -1 and `KilledByStatusEffectFlags` = 64. The flags are a bitmask with bit n = `EStatusEffectType` n (5 Starvation, 6 Dehydration), so 64 = dehydration. The vitals watcher then recorded it live: once hydration reached 0 (about 17:52:58), the server multicast **1.0 damage per second**, class None, `TypeDamages[].StatusEffect` = Dehydration, `Instigator` = himself. He went from 100 to 45 HP in 55 s. **The wiki's "0 hydration cannot kill" does not hold in this build:** he died of it twice (Luis saw the second death). Survival data (live, pawn components):
  - `HydrationComponent`: Start 50, `DecayRatePerHour` 5.5 (in-game hours: about 1.4 points per real minute), `HydrationRemovedOnDeath` 10, `LastQuarterDecayRateMultiplier` 0.5. `HydrationEffectLevels` at 0/25/50/75/100 apply `GE_Hydration_Damage` (at 0 only) plus the stamina-regen scale and delay GEs.
  - `SustenanceComponent`: Start 50, decay 4.15/h, RemovedOnDeath 10. Levels at 0 apply `GE_Sustenance_Damage` plus health-regen GEs.
  - `EnduranceComponent` (rest): its levels at 0/25/50 scale max stamina, carry weight and max sustenance/hydration.
  - Getters: `GetCurrent{Hydration,Sustenance,Endurance}()` / `GetMax*()`.
  - A fresh character starts at 50/50 and is dry in about 35 real minutes.
- **Max health:** `HealthComponent.MaxHealth` reads 0 on players (`BP_Components_Health_C`, a `UPlayerHealthComponent : UHealthFromAttributeComponent`, max comes from an attribute). Use `GetMaxHealth()` (100 for Claude, 250 for Zezima).
- **Vitals watcher (`sense.vitals_start`, verified):**
  - A post-hook on `/Script/Dominion.DamageComponent:Multicast_ApplyDamageFromGameplayEffect` **fires on the client** for each damage event the server multicasts. Read-only param reads of `FDominionDamageEvent` work: `Amount`, `AmountAbsorbedByShield`, `DamageClass`, `TypeDamagesArray.TypeDamages[].StatusEffect` / `.Types`, `Instigator`, `Source`, `bIsFatalHit`.
  - The point-damage variant and `OnRep_FatalDamageInfo` are hooked too, but no event has been seen on them yet.
  - **`HealthComponent:OnRep_AuthoritativeHealth` never fired** for these changes (it may not be routed through ProcessEvent, or health is predicted locally). A 1 s poll of `GetAuthoritativeHealth()` catches every change.
  - Output: `client_io/events/vitals.jsonl`.
- **Food and drink in item data:** `UFoodItemData` (`StatSustenance`, `StatSoulScourge`, `AmountToHealOnConsume`, `SustenanceRowHandle`) and `UDrinkItemData` (`StatHydration`, `StatSoulScourge`, `bAllowConsumptionWhenHydrationFull`, `HydrationRowHandle`), both `UBuffItemData : UConsumableItemData` (`UseVerb`, `ItemUsageDelay`, `GameplayEffectsToApply`). Drinks in the dump: `ITEM_Consumable_Water_{Clean,Dirty,Cactus,Wither}`. `inventory.describe_item` now tags `consumable = food | drink | potion` from the data class.
- **Water from a source (RESEARCH, not yet tried):**
  - The wiki and guides say interacting (E, repeatedly) with a pond, lake or river adds **Dirty Water** to the inventory with no container needed. Dirty Water gives +10 hydration and +20 Soulscourge (toxicity: damage over time at 100). A Campfire turns Dirty Water plus fuel into **Clean Water** (+25 hydration).
  - In the dump, the PlayerController's `UFluidController` has `Server_TryTakingInstantly`, `Server_TryStartTaking`, `Server_TryFillingInstantly`, `Server_OnTransferPanelOpen(FluidContainer)` and `TakeSpeed` / `FillSpeed` curves. That is probably what the water interaction drives.
  - No water-source actor class was found in the server dump (water bodies are probably streamed level actors).
  - Plan: near water, the census lists the `InteractionComponent` with the water prompt; press interact once per Dirty Water; drink only when needed; boil at a campfire when one is built.
  - Sources: dragonwilds.runescape.wiki/w/Hydration, /w/Dirty_Water, /w/Clean_Water; primagames.com/tips/how-to-get-clean-water-in-runescape-dragonwilds.
- **Client hang (17:53:54 UTC):** the game thread stopped (game log ends 17:53:34, mod log 17:53:54, 0.03 s of CPU in 3 s, process alive at 1.98 GB) with **478 MB of free RAM** on the VM. A RAM-pressure stall is the likely cause; it is reported to main and was not restarted by this agent.

## Traversal (R2) (2026-10-25, from the reflection dump of server build 26161880 + the client UE4SS.log; client build 26162923 not dumped; no live calls made)
Research and design: `docs/research/2026-10-25-traversal.md`.
- **There is no mantle, ledge-grab, climb, vault or glide.** The dump has 0 classes or actions for Mantle, Climb or Glide; the "Vault" hits are the Vault Core item. Traversal is jump-based: jump, coyote time, double jump, Air Dash, Phase Dash, Windstep, Breakfall, swim, kebbit burrows.
- **Input actions** (`/Game/Gameplay/Inputs/Actions/`):
  - `Basic/IA_Player_Jump`, `IA_Player_Sprint`, `IA_Player_Evade`, `IA_Movement`, `IA_VerticalMovementUp/Down` (purpose UNVERIFIED), `IA_Mount`;
  - `Spellcasting/IA_Spellcasting_QuickAccess0..7` (the cast route for Windstep and Phase Dash);
  - `UI/IA_UnstuckCharacter_Held` (the game's own unstuck; the pause menu `UPauseMenuScreen` has `ProgressButton_Unstuck`, `TeleportToStart()`, `RestartAgilityCourse()`);
  - `Agility/IA_AgilityCourse_Banner_*`.
- **`UDominionMovementComponent` (Dominion.hpp:20581):**
  - Dash: `DashDistance`, `DashStaminaCost`, `DashCooldownDuration`, `MaxFallDistanceForDash`, `DashDistanceToVelocityCurve`, `DashPerkData`, `DashBlockingTags`, `DashMontage`, `bWantsToDash`, delegate `OnDash(bool bWasPhaseDash)`.
  - Phase Dash: `MaxPhaseDashCharges`, `PhaseDashEffectDuration`, `MaxPhaseDashesMidAir`, `EnablePhaseDashes()`, delegates `OnPhaseDashActivated/Deactivated`.
  - Double jump: `GravityToDoubleJumpVelocityCurve`, `DoubleJumpBlockingTags`, `MaxFallDistanceForDoubleJump`, `MinimumAccelerationForDirectionalDoubleJumpAndDash`, `DoubleJumpMaxHorizontalSpeedDuringDash`.
  - Falls: `MinFallDamageHeight`, `MaxFallDamageHeight`, `FallDamageBlockingTags`, `BreakfallMontage`, `BreakfallPerkData`, NetMulticast `Multicast_ApplyFallDamage(float, bool bShouldPlayRollAnim)`, `SetFallDamageImmune`.
  - Jump gating: `bJumpBlocked` (Replicated), `JumpInhibitors`, `JumpBlockingTagQuery`, `IsJumpEnabled()`.
  - Windstep: `OnLandedWindstepEvent`.
  - Attribute classes (GE-modified, e.g. by Windstep): `JumpHeightAttributeClass`, `GravityScaleAttributeClass`, `AirControlAttributeClass`, `RunSpeedAttributeClass`.
- **`ADominionPlayerCharacter` (Dominion.hpp:9779; UHT DominionPlayerCharacter.h):**
  - Perk and curve fields: `DoubleJumpSkillPerk`, `GravityToMaxUpwardsVelocityForDoubleJumpCurve`.
  - Coyote time: `LedgeForgivenessTime`, `IsInLedgeForgivenessTimeWindow()`.
  - Jump events: `PlayerCharacterJumpedEventDynamic`, `OnDoubleJump()` (BlueprintImplementableEvent).
  - **`ReplicatedJumpCurrentCount` (int8, `ReplicatedUsing=OnRep_ReplicatedJumpCurrentCount(int8 PreviousJumpCount)`)**: the per-jump signal other clients receive.
  - `bIsRunningAgilityCourse` (ReplicatedUsing); `DoDash()` (BlueprintCallable, **Exec**); `WindstepTag`, `WindstepXPEvent`, `JumpXPEvent`.
- **ACharacter (engine, reflected):**
  - `ReplicatedMovementMode`, `bProxyIsJumpForceApplied`, `ProxyJumpForceStartedTime`, `JumpMaxHoldTime`, `JumpMaxCount`, `JumpCurrentCount`;
  - `OnJumped`, `OnLanded(FHitResult)`, `K2_OnMovementModeChanged`, `OnWalkingOffLedge`, `LaunchCharacter`, `CanJump`.
- **UCharacterMovementComponent (engine, reflected):**
  - `K2_FindFloor(FVector CapsuleLocation, FFindFloorResult& out)` and `K2_ComputeFloorDist(...)`: the CMC's own capsule floor sweep at any location.
  - `GetMaxJumpHeight()`, `GetMaxJumpHeightWithJumpTime()`, `GetGravityZ()`, `IsFalling/IsMovingOnGround/IsSwimming`;
  - `CurrentFloor` (FFindFloorResult {bBlockingHit, bWalkableFloor, bLineTrace, FloorDist, LineDist, FHitResult}), `MaxStepHeight`, `WalkableFloorAngle`, `LedgeCheckThreshold`, `PerchRadiusThreshold`, `AirControl`, `GravityScale`.
- **Traces:**
  - `KismetSystemLibrary:LineTraceSingle/SphereTraceSingle/CapsuleTraceSingle` (bool return + `FHitResult&` out). `FHitResult` nests `FVector_NetQuantize`, `TWeakObjectPtr` and `FActorInstanceHandle`, so **out-param marshalling from UE4SS is UNTESTED** (risk register R15 class).
  - `GameplayStatics:Blueprint_PredictProjectilePath_Advanced` (struct params: avoid).
  - Dev server: `NavigationSystemV1:NavigationRaycast(ctx, start, end, FVector& HitLocation, filter, querier)` (flat FVector out, the same pattern as K2_ProjectPointToNavigation).
- **Navmesh link machinery in this build:**
  - `ARecastNavMesh.bGenerateNavLinks` + `FNavLinkGenerationJumpDownConfig` {bEnabled, JumpLength, JumpDistanceFromEdge, JumpMaxDepth, JumpHeight, JumpEndsHeightTolerance, SamplingSeparationFactor, FilterDistanceThreshold, LinkBuilderFlags, Down/UpDirectionAreaClass, LinkProxyClass} (UE 5.5+ experimental auto links); `K2_ReplaceAreaInTileBounds`.
  - `ANavLinkProxy` {PointLinks `TArray<FNavigationLink>`, SegmentLinks, SmartLinkComp, OnSmartLinkReached, ResumePathFollowing}.
  - `UNavigationPath` exposes only `PathPoints` (FVector), so link segments can't be identified from a path.
- **Perks** (`/Agility/Gameplay/Character/Player/PerksV2/`): `PerkV2_Agility_DoubleJump`, `_AirDash`, `_Spell_PhaseDash`, `_Breakfall`, `_GreaterBreakfall`, `_Hopper`, `_Spell_Windstep_Upgrade` (Wind Stomp), `_KebbitBurrows_{Common,Wild,Dark,Desert,Razorbacked}`, `_Spell_Recall(_Upgrade)`; `PerkV2_Attack_JumpAttack`, `PerkV2_Attack_SprintAttack`.
  - `USkillPerkData.InputActionDisplay` (`FPerkUnlockInputActionDisplay` {InputAction, InputActionMappingContext, ActionDescription}) names the input that triggers a perk. Read it for Air Dash.
  - Query: `pc.SkillPerkComponent:IsPerkUnlocked(USkillPerkData)`.
  - Levels (BisectHosting guide, not the game): Windstep 5, Double Jump 10, Hopper 22, Common Burrower 27, Air Dash 32, Breakfall 35, Wind Stomp 40, Phase Dash 44.
- **Windstep is a super-jump, not a dash** (data/spells_26161880.json): Instant cast, `allow_while_falling=false`, 5 Air, 3 s cooldown.
  - It applies `GE_Windstep` (jump height, gravity scale, air control and fall-damage modifiers), which is removed on landing; module `InhibitJumpOnLanding`.
  - Wiki: "jump up to 16 m, slow fall, 7 s to use".
- **Observing other players on the client (simulated proxy), from the dump:**
  - `ReplicatedJumpCurrentCount` (OnRep) and `ReplicatedMovementMode` (→ `IsFalling`).
  - `UPlayerEvadeComponent:Multicast_StartEvade(int32 MontageIndex, bool bSurge, FRotator)` (NetMulticast).
  - `Multicast_ApplyFallDamage`; `GameplayTagsComponent.ReplicatedGameplayTagStackContainer` (Replicated).
  - `USprintComponent` replicates only `bMovementBlocked`, so infer sprint from speed.
  - None of these has been read live on the client yet.
- **Caution: `JumpMaxCount = 2` on Claude is not proof of double jump.** Claude's character is Agility 1, and Double Jump is Agility 10 (`DoubleJumpSkillPerk`). Verify with `IsPerkUnlocked` and the Z velocity after the second `Jump()`.
- **Stuck-in-gap evidence (client UE4SS.log, 2026-10-25 18:52-18:54 UTC, follow test on Shockbyte):**
  - Claude's capsule was fixed at about (71.6, 1862.0, -34.6) m for over 90 s. The nav path was partial, ending at Z -35.2 m beside him.
  - The goal and the breadcrumbs he aimed at were at Z about -31.3 m, 3.3 m above him.
  - The trail index jumped 2 → 21 in about 2 s because breadcrumb advance is 2D.
  - The jump/double-jump ladder repeated every ~6 s with 0-7 cm progress.
- **Fed and watered, then recovered the grave again (verified 18:00-18:05 UTC, after the client restart):**
  - Luis dropped Forager's Sandwich x49 and Pumpkin Spice Infusion x49. Claude walked 8.7 m to them (move.lua go_to) and collected both with 2 interact presses, landing in hotbar 1 and 2.
  - **Drink:** hotbar key 2 (`UseItemInSlot(1)`) took hydration from 18.6 to 95.8.
  - **Eat:** the stay-fed reflex (`inventory.reflex_start`, a game-thread loop) fired by itself at 18:01:46 and used hotbar key 1. Sustenance went from 18.5 to 98.0.
  - **Item data classes:** the live classes are Blueprint subclasses (`/Game/Gameplay/Items/Consumables/BP_Consumables_Drink.BP_Consumables_Drink_C`), so food and drink are recognised by the presence of the `StatSustenance` / `StatHydration` properties, not by class name. Their categories are `Item.Food` and `ItemFilter.Type.Consumable.Drink`.
  - **Second grave:** `BP_PlayerGravestone_C` at (71.63, 1862.03, -35.48) m, straight-line go_to arrived at 0.6 m, and one "Take All" press returned all 6 items. They went to the first free hotbar slots: the Torch and Shield moved to slots 7-8 because food and drink now occupy 1-2.
  - Re-equipped the axe with hotbar key 4.
  - **The grave spot is a dead end toward the open ground east:** two straight go_to attempts to Zezima from there failed "stuck" after about 1 m. Backtracking to the lodestone (straight, 0.98 m) and then go_to Zezima reached 2.98 m from him at (89.48, 1851.2, -31.42) m.
- **Measured live by the locomotion agent (Claude's client, 2026-10-25):**
  - Physics: JumpZVelocity 807.9, GravityScale 1.85 (`GetGravityZ` −1813), `GetMaxJumpHeight` = `GetMaxJumpHeightWithJumpTime` = 180 cm, `JumpMaxHoldTime` 0.
  - Limits: `MaxStepHeight` 45, `WalkableFloorAngle` 45.5, `MinFallDamageHeight` 1500 / `MaxFallDamageHeight` 2860 cm, capsule half-height 88.
  - **`IsPerkUnlocked(DoubleJumpSkillPerk)` = false**, so the caution above is confirmed: no double jump at Agility 1.
  - `LineTraceSingle` from Lua works on the dev server and the client (about 1 ms). The out table fills nested (`ImpactPoint.Z`, `ImpactNormal.Z`, `Distance`, `Time`).
  - `bStartPenetrating` reads junk (it shares bitfield byte 0xAD with `bBlockingHit`); use `Distance == 0`.
  - `K2_ComputeFloorDist` works on the dev server.

## Raising Claude's stats via Claude.json: RESOLVED, the edit is NOT active (investigated 2026-10-25 19:15-19:26 UTC, client build 26162923, Shockbyte world "The Goochlands" GUID 78BEF9BB90BD45109AB14AC58AE159BE; read-only)
History:
- 19:10: a local merge of Zezima's skills into `Claude.json` had no effect (backup `C:\GameServers\backups\claude_char_20261025-190851.json`).
- 20:07 local: Luis's edited copy came down from Steam Cloud: SaveCount 17, 12 642 bytes, XP 1 000 000 in six skills. A pre-launch copy is at `C:\GameServers\backups\claude_local_before_cloud_200726.json`.
- After that, Claude joined at 19:08 UTC, the watchdog restarted the client, and it rejoined at 19:18 UTC.

**Actual live levels** (`client_mod/commands/stats_skills.lua`, read-only, `pc.SkillComponent`, 19:19 UTC):
- **Every skill is level 1 with 0 XP, except Agility, which is level 3 with 70 XP.** Total level 14.
- Power level `BP_GetPowerLevel()` is 2. There are 0 perk runtime states, and `IsPerkUnlocked(DoubleJump)` is false.
- `sense.me`'s total_level is correct: it is `GetTotalSkillLevel()`, which equals the sum of the per-skill `GetSkillLevel` (11 × 1 + 3 = 14).

**The XP curve** (`GetTotalXPNeededForLevel`):

| Level | 2 | 3 | 5 | 10 | 20 | 30 | 40 | 50 | 60 | 70 | 80 | 90 | 99 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| XP | 33 | 70 | 156 | 463 | 1 798 | 5 367 | 14 929 | 40 594 | 86 998 | 147 842 | 223 122 | 312 838 | 1 000 000 |

- `MaxLevel` is 99, so the edited XP values were valid: 1 000 000 = 99, 40 594 = exactly 50, and the rest are about 73-91.
- Skill ids in the JSON are each `USkillData.PersistenceID`, for example `4zYUGF5u_0KbMLkWJmmBbQ` = skill_woodcutting and `pJggvotwOkuoc98igUn7xA` = skill_agility.

**Where the live character comes from: the Shockbyte server's own copy, not Claude.json.**
1. **The client does send the edited file.**
   - Client log at 19:08:22: `Remote Character load complete … slot[Claude]`, then `Data Buffer compressed [LZ4] was[12642]Bytes`, then `Started player profile stream. Handle[242] Size[12642]`.
   - 12 642 bytes is exactly the size of the edited SaveCount-17 file.
   - On the dev server the receiving side is visible: `PLAYER - CLIENT SAVE`, `Player profile stream completed`, then `LoadStateFromJson`. Examples: Zezima at 13:35-15:54 and the dev-account Claude at 16:51:54.
2. **The live state matches neither stream.**
   - Join 1 streamed 1M XP and an empty inventory (the edited copy was taken after the 18:21 death, with the items in the grave). The result was 0 XP and a 13-item inventory.
   - Join 2 streamed the game's own 19:11 save, which had Agility 83 XP. The result was **Agility 70**. XP only goes up, so the live state is an older server-held snapshot.
   - The live position and playtime also continue from neither file. So the server replaced the client's JSON with a state it kept itself.
3. **The server writes the local file, not the other way round.**
   - `ADominionPlayerControllerBase::Client_SaveToDisk(FDomClientDiskSave)` is a server→client RPC. `FDomClientDiskSave` has no reflected fields.
   - A read-only post-hook (`client_mod/commands/stats_savehook.lua`, output in `client_io/events/savehook.jsonl`) fired at **19:25:39Z, the same second `Claude.json` was rewritten** (SaveCount 25, XP still 0 / Agility 70, `worlds_playtime[78BEF9BB…]` = 1792956339 = 19:25:39 UTC).
   - The siblings are `Client_LoadFromDisk(Handle, FPlayerCharacterInfo)` and `Client_SetHasEditedProfile(bool)`.
   - The game therefore **overwrote the edited Claude.json** (SaveCount 18-25, every few minutes), and Steam Cloud re-uploaded it (`steam_autocloud.vdf` at 20:17).
   - `Claude.json.backup` rotated at 19:20 UTC. The only surviving copy of the 1M edit on this VM is `C:\GameServers\backups\claude_local_before_cloud_200726.json`.
4. **The server-side copy mechanism** (from the dump, plus Jagex's notes):
   - The world has a SPUD-persisted `ACachedCharacterStates` actor. Its field is `TArray<FCachedCharacterState{FDomCharacterGuid CharacterGuid; FString State; float LastUpdated}>`, with the `SaveGame` flag. `UWorldSaveUpgradeHelper` also carries `CachedCharacterStates`.
   - On Claude's client this actor is a non-replicated level actor with 0 entries (`stats_cache.lua`). On the dev server it is also empty right now, with no players connected (`mod/experiments/charcache_probe.lua`). So the **Shockbyte server's** contents could not be read; that file is the group's world, so it was not touched.
   - Jagex's 1.0.0.7 patch note (2 Oct 2026): progress was "not carrying over between worlds"; "Your most frequently visited world will override on login"; "The save data will pull the world that you have spent the most time in (specifically the world with the most save states logged in it)".
   - Jagex's 0.11.0.8 note (7 Apr 2026): "Players connecting to a dedicated server should not experience rollbacks on progress from previous sessions".
   - Together these mean that a world keeps per-character states, and on login they override the client's file.
   - In `meta_data.worlds_playtime`, the value is the Unix time of the last save in that world, not a playtime. In the edited file it was 18:23:40 UTC, older than the server's copy.
5. **Ruled out:**
   - Steam Cloud re-sync: the 19:08 stream was the edited file itself.
   - A different slot or the `.backup`: the slot is Claude, and the size matches.
   - A different XP-to-level conversion: the curve tops out at 1M = 99.
   - `sense.me` reading stale data: the live read agrees.
   - The client log has no cheat/invalid/sanitise lines. The only flags are `SetPawn: bHasLoadedCharacterState [false], bCharacterSaveDataIsValid [false]`, and those print false on every client join; on the server they become true.
   - Validation that clamps XP is not excluded, but it cannot explain the inventory or the Agility 83 → 70 change.

**What would make an edit take effect (not done, needs Luis):**
- (a) Edit or remove Claude's `CachedCharacterStates` entry in the Shockbyte world save, with the server stopped. Claude's character GUID is `D06CFBE34D95AB743CE28EBE2C0DBBC7`. **That is the group's real world**, so it is Luis's call, with a backup first.
- (b) Untested: an edited Claude.json whose `worlds_playtime[78BEF9BB…]` timestamp (and maybe SaveCount) is newer than the server's copy, uploaded while the client is closed. This applies only if the override is "newest wins"; the 83 → 70 rollback suggests the server copy may win regardless.
- (c) Prove the mechanism on the dev server first. Join a character there with a 1M-XP file (a fresh world has no cached state, so `LoadStateFromJson` should apply it), read `GetSkillLevel` on the server, then rejoin with a lower file and check which one wins.

## R2 client perception for the brain: look / inspect / get_state digest live (2026-10-25, about 18:11-18:20 UTC, Shockbyte world, read-only)
- **Setup:** `client_bridge.lua` was hot-reloaded live (`bridge_start.lua`), with no client restart. Capabilities now add `look`, `inspect` and `interact`, so the brain's planner skills become `go_to, follow, stop, drop, interact` once the brain restarts.
- **`get_state`** (262 ms) now carries:
  - `hydration` 48.7/100, `sustenance` 63.5/100;
  - `held` "Mithril Logging Axe";
  - an `interactables` list.
- **The brain's digest from it, live:**
  - `You: HP 100%, water 49%, food 64%, holding Mithril Logging Axe`
  - `Creatures: Kebbit x5 (19 m, ..., HP 60/60)`
  - `Around: Stone x16 (9 m); Ash Log x3 (9 m, chop, needs Hatchet T1, HP 80/80); ...`
  - `Usable: Crafting Starting Bench x2; Base Building Crate x3; Doric (NPC, prompt "Talk"); Loot ...`
- **`look`:** about 200 ms for 52 things within 30 m.
  - `about="tree"` matched only "Ash Tree Seed". **Standing trees are foliage instances, not actors, so the client census does not see them.** Felled ash logs, stones and saplings are seen. A foliage census on the client is the open item (the server body converted foliage).
  - `about="grave"` found none: the grave had already been taken.
- **`inspect`** of a stone returned `{kind: gatherable, verb: gather, prompt: "Collect", item: ITEM_Resources_Stone, available: true}`.
- **Not exercised live:** `interact` (offline tests only: approach, aim, wait for the detector to target the actor, one IA_Interact press, then verify the target is gone or the inventory grew), `attacked` and `vitals_low`. Gravestone Take All by one press at 0.6-1.2 m was verified by the inventory agent; see its entry above.
- **Background services:** `bridge_status.services` reports chat, vitals and fed_reflex as `running`. Main had started them by hand at 19:13 local; the bridge now supervises them, so a client boot starts them (offline-tested; first live boot pending).

## Client combat (R2) (2026-10-25, client build 26162923, Shockbyte world; server build 26161880 dump for class layouts)
Modules: `client_mod/scripts/arbiter.lua` (pawn ownership), `client_mod/scripts/combat.lua` (fight-or-flight, weapon choice, engage, defend, flee, loot, re-equip), `client_mod/scripts/weapons_data.lua` (generated by `tools/gen_weapon_profiles.py` from `data/items_26161880.json`). Commands: `combat_probe` (read-only), `combat_probe_live` (read-only), `combat_start`/`combat_stop` (reflex), `combat_status`, `combat_test` (commanded attack on the nearest Kebbit). Offline: `lua client_mod/tests/test_combat.lua` (70 checks: arbiter, pure decisions, whole fights against a fake engine).
- **Combat input actions on Claude's pawn (read live, read-only, `combat_probe`):**
  - `pawn.PlayerInputBufferInputActions` (`FPlayerInputBufferInputActions`, Dominion.hpp:6006; the same struct feeds `UPlayerInputBuffer`): `PrimaryAction` = **IA_PrimaryAction** (attack), `SecondaryAction` = **IA_SecondaryAction** (block; the catalog's `secondary.kind = block`), `SpecialAction` = **IA_SpecialAction**, `EvadeAction` = **IA_Player_Evade**, `MountAction` IA_Mount, `MovementAction` IA_Movement.
  - Primary/Secondary/Special: `ValueType` 0 (Boolean), `bConsumeInput` true, one trigger **`InputTriggerDown`** (fires every frame while held: a tap = a few frames of injection, a block = inject every frame). Evade: Boolean, no triggers.
  - Lock-on: `pawn.LockOnTargetingComponent` (`BP_Components_LockOnTargeting`): `ToggleLockOnInput` = **IA_ToggleLockOnTargeting** (Boolean, **`InputTriggerPressed`**: inject one frame, then nothing), `SwitchTargetInput` IA_TargetSwitchLockOnTargeting, `MaxTargetDistance` 3200, `TraceDistance` 3000, `TraceRadius` 500, `ScreenSpaceAngleTolerance` 110; its `LockOnCameraActor` (`BP_LockOnCameraActor_C`) and `TargetingWidgetInstance` (`WBP_LockOnTargetOrb_C`) exist on the headless client. `FLockOnTarget CurrentTarget` has **no reflected fields** (CXX: empty struct), so the locked target cannot be read.
  - `BP_Components_PlayerMeleeAttack_C`: `InputBufferingDuration` 0.5 s (presses up to 0.5 s early are buffered, so a human-like cadence chains combos), `EarlyOutActions` = IA_Movement, IA_Player_Evade, IA_Player_Jump, IA_Player_Stealth (these cancel a swing), aim assist `MaximumAngleAimAssist` 45, `ScreenSpaceRadius` 0.2 (camera based).
  - `BP_Components_PlayerBlocking`: `BlockingAngle` 120, `ParryWindowLength` 100 (ms?), `MinimumBlockDuration` 0.75 s, `BareHandsBlockingDamageNegation` 5. `BP_Components_Evade`: `InputAction` IA_Player_Evade, `IsEvadeEnabled()` true.
  - Rotation: `bUseControllerRotationYaw` false, `CharacterMovement.bOrientRotationToMovement` **true**, `RotationRate.Yaw` 540: the body turns only toward movement, so facing a target while standing needs a short movement nudge (or lock-on).
  - Power level: **`pawn:BP_GetPowerLevel()` = 2**; `DominionRuntimeBlueprintLibrary:GetCurrentEquipmentPowerLevel(pc)` = 1 (nothing held at that moment). Creatures: `PowerLevel` / `GetAIPowerLevel()` (Kebbit 1). `SpecialChargeComponent:GetSpecialCharge()/GetMaxSpecialCharge()` 100/100; stamina 80/80 (60/60 later, after endurance dropped).
  - Kebbits nearby: `BP_AI_Kebbit_Character_02_C`, HP 60 (`GetMaxHealth` 60), Archetype 4 (NeutralUntilAttacked), PL 1, `AiAttackComponent` = `BP_Kebbit_AiAttackComponent`. **`AIAttributesComponent.DamageTypeAffinities` is empty on the client** for Kebbits (not replicated, or none): weaknesses must come from hit outcomes or priors.
- **Signals combat listens to (hooks, read-only):** `DamageComponent:Multicast_Apply[Point]DamageFromGameplayEffect` (who hit whom, `TypeDamagesOutcome` per type for weakness learning; a second Lua hook beside sense.lua's vitals hook) and `AiAttackComponent` / `AiRangedAttackComponent:Multicast_PerformAttackOnSimulatedProxies(AttackClassId, AttackId, bFromCombo)` (NetMulticast: an AI attack starting, used as the telegraph). Live firing of the AI-attack multicast on this client: UNVERIFIED (Kebbits do not attack).
- **Weapon data:** catalog profiles per item id: Bone Dagger PL 2, 7-step chain mean 11.6 dmg, press every ~0.77 s (input-window end), 10 stamina per swing, special Lacerate 21 dmg / 25 charge; Mithril Logging Axe PL 6, Chop 10 dmg every ~1.29 s, 4 stamina; Mithril Pickaxe 10 dmg every ~1.53 s; Bronze Shield block 39; Torch block 26. The catalog's `damage_multiplier` (axe 6.8, pickaxe 8.2, dagger 1.9) is unexplained, so the score does not use it.
- **Search (search-before-building):**
  - Arbitration: Behavior Multi-Queues (Cutumisu & Szafron, AIIDE 2009, webdocs.cs.ualberta.ca/~duane/publications/pdf/2009aiideMC.pdf: interruptible and *resumable* behaviours by priority, used in Neverwinter Nights); subsumption (MIT 6.189 arbitration lecture, courses.csail.mit.edu/6.189/fall2005/pub/lectures/Releases/2005_10_12_lecture10_arbitrationv4.pdf); BT lower-priority observer aborts (docs.unity3d.com/Packages/com.unity.behavior@1.0/manual/observer-abort-mechanics.html); Game AI Pro 360 "Behavior Selection Algorithms" (TOC only). No Lua library for this. Decision: **adapt** (priority slot + suspended stack + leases), build ~250 lines.
  - Fight or flight: utility AI with time-to-die comparison (gamedev.net/forums/topic/686840-help-me-understand-utility-ai); nothing more specific found. Decision: **adapt** (hard vetoes + utility + hysteresis).
  - Engage loop: mineflayer-pvp (npmjs.com/package/mineflayer-pvp: followRange / attackRange / viewDistance) and the nxg-org advanced fork (shield handling). Decision: **adapt** the shape.
  - Dragonwilds combat rules: parry = block pressed just before the hit; block, dodge, attack and sprint all cost stamina; specials use their own meter; neutral evade is short with i-frames, directional rolls go farther (mobalytics.gg/gamebase/guides/runescape-dragonwilds-combat, deltiasgaming.com/?p=205876, games.gg combat guide). No source describes lock-on.
  - Enhanced Input: Epic docs for InjectInputForAction / InjectInputVectorForAction / StartContinuousInputInjectionForAction (the continuous variant takes FInputActionValue, which UE4SS cannot build, so holds are per-frame vector injections). No UE4SS-specific example found.
- **UE4SS pitfall (verified 18:23 UTC): a missing property is NOT nil.** Reading a property an object does not have (e.g. `WearableEquipmentData.StatSustenance`) returns a non-nil invalid `TrivialObject` userdata (`IsValid()` false). So `obj.Prop ~= nil` is no existence test. Use `obj:IsA(StaticFindObject("/Script/Dominion.FoodItemData"))` (works from Lua) or `U.valid(...)` on object-typed fields.
  - **Live bug this caused:** the stay-fed reflex classed the Mithril Pickaxe as "food" and pressed its hotbar key repeatedly from 18:20:46. Claude never drank, and a Giant Rat killed him at 18:21:04 with hydration at 10.9.
  - **Fix:** class-based detection (`inventory.consumable_kind`). Before each press, `inventory.use` re-checks the exact slot (same item, not equipment, the required class). The reflex verifies the stat rose 4 s later and marks the item bad otherwise.
- **Client hangs and crash, triage (18:30 UTC, no game PDB; frames are export-relative):**
  - **17:53:54 hang** (cdb stack `logs/client/stack_6400_175704.txt`):
    - The GameThread is in `WaitForSingleObject`, about 13 frames deep inside game code. Above that sits a UE4SS frame (`UE4SS!…StartCallbackGarbageCollector+0x675`), which is UE4SS's engine-tick hook calling the original tick. Above that are only 7 frames to the thread start.
    - **No Lua frame is on the game thread.** So the wait is inside the engine's own tick: a task or fence that never completes. It is not inside one of our Lua calls or hooks.
    - The RenderThread and FAsyncLoadingThread also wait idle. VM free RAM was 478 MB.
  - **18:27:42 hang:** the last mod line (an `inv_list` command run) came 2 s after the reflex's bag "use" (`InventoryUIAPI:HandleInternalUseItem`, 18:27:40), so the game thread was still alive after that call. No stack was captured (main killed the process).
    - Mitigation: the reflex now uses **hotbar items only** (`REFLEX_CFG.allow_bag = false`). It logs `no_hotbar_<kind>` when food or drink is only in the bag.
  - **18:08:42 crash** (UE4SS dump `…/Win64/ue4ss/crash_2026_10_25_19_08_42.7381637.dmp`, local time):
    - An access violation in game code, called from a **Lua UFunction call inside a game-thread callback**: the same UE4SS hook site `+0x65a` → `Lua::call_function` → `process_lua_function` → game native → AV.
    - It came 2 s after `disconnect.lua` (18:08:40). The likely cause is a game-thread loop (vitals poll, reflex, move or bridge) touching objects during world teardown.
    - Mitigation: the vitals poll and the reflex tick return immediately while `_G.DW_PAUSE` is set. Disconnect and travel commands should set it, or stop the loops, first, and clear it after the pawn exists again.

## Client ops: boot_and_join, watchdog, smoke test (R2.15, R2.16) (2026-10-25, client build 26162923)
Files: `tools/client_lib.ps1` (shared), `tools/client_boot.ps1`, `tools/client_watchdog.ps1` + `tools/start_client_watchdog.ps1`, `tools/stop_client.ps1`, `tools/client_smoke.ps1`, probe `client_mod/commands/boot_probe.lua`, `smoke_*.lua`; offline tests `tests/test_client_ops.py` (fake client: copied PING.EXE + a Python thread that plays the command runner). Runbook: RUNBOOK-patch.md §10.
- **Read-only probe (verified live, 1.9 s round trip):** the map comes from the local PlayerController's path (`... /Game/Maps/World/L_World.L_World:PersistentLevel.BP_PlayerController_C_...`). The probe also reads `MainMenuUIAPI:GetCurrentScreenType()` (0 in the world), `DomMatchmakerSubsystem:IsUserLoggedIn()`, `pc.Pawn`, the count of live `NarrativeIntroWidget`s, and `_G.__dwc_bridge.status().services`, where chat, vitals and fed_reflex report `running`.
- **`boot_and_join` against the running client (verified 19:21 local):** it detected "in world, services running" and did nothing (0 actions, 1.7 s). It wrote `logs/state/client_status.json`. The menu, sign-in, join and intro paths have been exercised only against the fake runner; **live cold boot UNVERIFIED** (main has the client on hold).
- **Steam state is readable without the UI:** `HKCU\Software\Valve\Steam\ActiveProcess.ActiveUser` is the logged-in account's 32-bit id. It reads 653927889 = 76561198614193617 − 76561197960265728 (bootymaxer), and 0 when nobody is logged in.
- **The client game log contains the world password, base64-encoded:** the `Browse:` and `LoadMap:` lines carry `?p=<b64>`. The tools redact `?p=...` and the plain password from everything they log, and never copy those lines.
- **Join failures that the log names:** `Connection Failed for reason [DuplicateChar]`, which a fast rejoin after a crash can hit while the server still holds the old connection (so boot retries with a 30/60/120 s backoff), and `PendingConnectionFailure ... Missing user ID` (not signed in).
- **Hang signals:**
  - The client's game log is chatty in the world: EOS lobby websocket lines every ~30 s.
  - The UE async log writer buffers, so after a game-thread stop the game log ends a few seconds *before* the Lua runner's last line. That happened at 17:53 (log 17:53:34, mod 17:53:54) and again at 18:27 UTC (game log 18:27:37, runner's last `inv_list` 18:27:42; then `inv_equip` and `disconnect` timed out). The 18:27 instance had no stack taken: the client was closed on purpose.
  - The only stack we have (`logs/client/stack_6400_175704.txt`) shows the GameThread in `NtWaitForSingleObject` beneath a UE4SS hook frame (frame 10). Its symbols are export-only.
  - `RemoveInvalidLockers ... invalid locks` precedes both hangs but appears 5–10 times per session, so it is not diagnostic.
  - The watchdog therefore treats as a hang: no runner answer while game log and client.log are both stale for 60 s with CPU < 0.05 core, or 3 probes in a row unanswered (about 90 s). It takes a `cdb -pv` stack before killing.
  - The UE4SS crash handler writes `ue4ss\crash_*.dmp` beside the client exe, then blocks. One was written at 19:08:42 local. The watchdog treats a new dump as a crash.
- **Search (search-before-building):**
  - Supervisors: NSSM and WinSW run programs as Windows services in session 0. Steam and the game client must run in the logged-on user's session, so a service can't drive them. Task Scheduler "at logon, interactive" is the idiomatic way to start a per-user supervisor (alternativeto.net/software/winsw, forum.syncthing.net/t/21512, discourse.nodered.org/t/10149). `start_client_watchdog.ps1 -Register` creates that task; it was not registered.
  - Steam `-applaunch <id> <args>` forwards the arguments to the game (developer.valvesoftware.com/wiki/Command_line_options_(Steam)). Nothing documents a second `-applaunch` while the game runs, so boot only launches when the process is absent.
  - Hang detection: the usual pattern is a heartbeat plus a sustained-CPU threshold with a grace period (thwack.solarwinds.com/discussion/32093, administrator.de/forum/161071). `Process.Responding` doesn't help: the client's only window is the `-log` console.
  - No game-client or bot watchdog fitting a UE4SS client was found.
  - Decision: **adapt** `tools/watchdog.ps1` (dump/heartbeat/cdb pattern), use the DWClient runner itself as the game-thread heartbeat, and **build** the thin boot state machine over the existing command files.
- **Teardown pause:** `join_server.lua` and `disconnect.lua` set `_G.DW_PAUSE` (commit 78ac755), and so far nothing clears it automatically. So boot runs `unpause.lua` once the pawn exists, the probe reports `paused`, the watchdog treats a pause that lingers more than 30 s in the world as degraded (it reruns boot_and_join), and the smoke test's `services` step fails while it is set.
- **First live fight (19:13:40-19:14:19 UTC, Shockbyte, commanded, force=true, lock-on off): INCOMPLETE, the client hung.**
  - Live state before it: Luis's stats edit had NOT reached the game: `BP_GetPowerLevel` 2, every skill level 1 (Agility 3), total 14. The only Kebbit nearby (73 m south) was inside a goblin camp (6 Goblin Runts, Aggressive, PL1, 120 HP; 2 Giant Rats, Aggressive, PL2, 200 HP), so the target was a lone Cow (NeutralUntilAttacked, PL2, 240 HP shown, 312 HP when read in the fight) 63 m north.
  - Worked: the arbiter suspended a stand-in task (`test_task`) for `combat:attack`; weapon choice from his own inventory (Bone Dagger, score 15.0, plus the Bronze Shield because the dagger is one-handed); equip by hotbar keys 6 and 8; `move.follow` of a creature by entity id (sprint, local planner) closed 63 m to 2.9-3.0 m; phase engage; one IA_PrimaryAction tap injected (3 frames).
  - Not verified: whether that swing played or hit (no stamina-spent or damage check had run yet), the Kebbit/Cow HP drop, loot, re-equip, resume.
  - **Bug found and fixed offline:** the cow's capsule keeps him about 3.0 m away centre to centre, beyond the fixed 2.2 m reach, so he stopped pressing. Reach and follow distance now grow with the target's `CapsuleComponent:GetScaledCapsuleRadius()` beyond 40 cm.
  - **Hang:** the game thread stopped about 19:14:19 (0 CPU, process alive). The game log's last line was `FlushAsyncLoading(9245): 1 QueuedPackages` at 19:14:11, after the first-ever dagger and shield equip and the first dagger swing. The cdb stack shows the GameThread waiting (`WaitForSingleObjectEx`) under a UE4SS hook frame (`logs/client/stack_8452_201705.txt`), identical to the 17:53 hang. Prime suspect (main): a synchronous asset load under NullRHI. Owned by the hang-investigation agent; combat retries wait for it. `BP_GetPowerLevel` (a Blueprint event) is now read at most every 10 s, as a precaution.
  - Also fixed: AI pawns have a `PlayerState` property that is a null object, so the never-attack-players check now requires a *valid* PlayerState.

## Client gathering (R2) (2026-10-25, client build 26162923, Shockbyte world; read-only probes `client_mod/commands/gather_probe.lua`, about 19:20 UTC)
Modules: `client_mod/scripts/gather.lua` (the job), `client_mod/scripts/gather_profiles.lua` (data), `sense.foliage` in `client_mod/scripts/sense.lua`. Commands: `gather_probe` (read-only), `gather_scan` (read-only), `gather_status`, `gather_stop`, `gather_ash2` (live). Offline: `lua client_mod/tests/test_gather.lua` (60 checks: profiles, the whole oak chain against a fake world, tool and tier failures, widening then nothing_in_range, unreachable, swings with no effect, an aim search, dead inputs, combat-reflex suspend and resume, inventory full, interact-collect, mining, ground pickups, pause, death, cancel, and the foliage maths over fake ISM components).
- **Why the client census could not see STANDING trees (VERIFIED live):**
  - On Claude's client every tree, sapling, bush, branch and ground stone is an instance of an `InteractableFoliageISMComponent`. There were 198 such components around him: `BP_InteractableFoliageISMC_Tree_C`, `_PickUps_C` and `_Sapling_C`.
  - Each component's `ActorClass` names the actor its instances turn into. Trees: `BP_BM_Tree_Oak_01_C`, `BP_FH_Tree_Oak_02_C`, `BP_Tree_Oak_01_C`, `BP_BM_Tree_Ash_0x_C`, `BP_FH_Tree_Ash_0x_C`, `BP_FH_Tree_Ash_Bare_0x_C` (dead ash), `BP_FH_Tree_Willow_0x_C`, `BP_DR_Tree_Maple_0x_C`, `BP_YewTree_0x_C`, and `BP_Cactus_*` (cacti also use the Tree ISMC). Pickups: `BP_Spawner_Stone_C`, `BP_Spawner_AshBranch_0x_C`, `BP_Spawner_Flax_C`, `BP_Spawner_Mushroom_C`, `BP_Spawner_Pumpkin*_C`, `BP_Spawner_Cabbage_C`, `BP_Spawner_Onion_C`, `BP_Spawner_Marrentil_C`, `BP_RedberryBush_C`, `BP_CadavaBush_C`, `BP_Weed_Desert_C`. Saplings: `BP_*Sapling_Ash_0x_C`.
  - Flags: Tree components have `bDamageable` true; PickUps components have `bInteractable` true; `FoliageType` was 2 on the pickups.
  - **The pawn's `NearbyFoliageConverterComponent`** (`BP_Components_NearbyFoliageConverter`) has `Range` **300 cm**, converts damageable and interactable foliage, and has `bStartEnabled` true. `GetEnabled()` reads **false on the client**, so the converting is done by the server.
  - So the server turns an instance into a real, replicated actor only within about 3 m of a player, or when a swing's trace converts it (`ConvertTracedFoliage` in the dump). A tree further from every player is foliage, and `FindAllOf` can't see it. That matches the bridge agent's "no standing trees" and the felled ash logs it did see.
- **Instance positions without a struct out-param (VERIFIED live):**
  - `ism:GetInstancesOverlappingSphere({X,Y,Z}, r_cm, true)` returns a **plain Lua table** of `RemoteUnrealParam` ints (use `:get()`), not a TArray (`ForEach` is nil). It is a bounds test, so filter by distance afterwards.
  - The reflected property `ism.PerInstanceSMData[i + 1].Transform` is an `FMatrix` of `FPlane`s: `WPlane.{X,Y,Z}` = the instance's local translation, `|XPlane|` = its scale. World position = component `K2_GetComponentLocation()` + yaw-rotated scaled translation (the tile components read rotation 0, scale 1).
  - Example: component at (126, 1890, -126) m, instance 7 local (-97.87, 12.49, 94.11) m → oak at (28.1, 1902.5, -31.9) m, 24 m from Claude, on the ground.
  - A zero-scale instance is treated as hidden (felled or converted). **UNVERIFIED** whether the client hides a converted instance that way.
  - `GetInstanceTransform` (an `FTransform&` out param) was not needed, so it was not called.
  - Cost: the whole 198-component pass with the sphere query took 33 ms on the game thread; the full probe took 55 ms.
- **`sense.foliage` live (VERIFIED, `gather_scan.lua`, about 19:36 UTC):** Ash Trees at 29.7-39 m and an Oak Tree at 38.9 m, found in 14-17 ms.
  - Name, gate and HP come from the actor class's default object: `cls:GetCDO()` → `DisplayName`, `DamageModifiersWhenTree` → Hatchet tier 1 (ash) / 3 (oak), `HealthComponent.MaxHealth` 160 / 220. These match the server census.
  - Pickup spawner CDOs carry the placeholder name "DEFAULT DISPLAY NAME", so their name comes from the CDO's `ItemData` instead ("Stone").
  - The census caps trees and pickups separately, because ground stones are everywhere and crowded the trees out.
  - The census grew from about 50-90 ms to about 105 ms (40 m radius).
  - `StaticFindObject` (no load) shows `AM_Player_Axe_OnSpot_Woodcut1` and `BP_Player_Axe_Woodcut1_C` already in memory on the client, so a first swing needs no synchronous asset load (the suspected hang pattern).
- **Rocks are level actors, not foliage (VERIFIED):** `BP_OreNode_Stone_C_UAID_*` HP 75 and `BP_MiningRock_RuneEssence_Static_C_UAID_*` HP 60 (`DestructibleMiningRock`), plus `BP_RuneEssenceGeyser_B_C_*` (`OreNode`, no HP). All replicate at 21-27 m. Felled-tree pieces (`BP_SplittableLog_Ash_C`, HP 80) were present 40-45 m away.
- **Pitfall:** `a.bIsStump` on a log or rock returns a `TrivialObject` (truthy; see "missing property is NOT nil"), so compare `== true`.
- **The gather job (offline-verified; live UNVERIFIED until the first supervised run):**
  - Phases: equip (the best `axe`/`pickaxe` he OWNS by `weapons_data` tier, hotbar key, verified from the held item) → scan → approach (`move.go_to` to a stand point at reach) → aim → swing → settle (step back and wait for the felled tree) → collect (magnet, then the interact key) → pick (pickups: walk up, wait for the detector, press interact).
  - **Scan order:** drops of the counted item near our sites; then pieces of OUR felled trees; then the nearest root (a converted actor or a foliage instance). The radius widens ×1.5 from 30 to 90 m.
  - **Aim:** `SetControlRotation` (the camera) plus a short `AddMovementInput` nudge, because the body turns only toward movement. The aim prior is the chop wedge 35° right of forward, from the server-puppet calibration. After 3 verified no-damage swings it tries the next offset (0, 20, -20), then another side.
  - **Swing:** IA_PrimaryAction through `combat._inject` / `combat.actions` (the same Enhanced Input path as fights). It uses the standard chop on every stage, because Overhead Chop needs Woodcutting 4 and Claude is level 1 (wiki).
  - **Verify:** stamina sampled 0.35 s after the press (the swing ran), and target HP after the damage point. A foliage target is adopted when a matching actor appears within 2 m. An undamaged adopted tree that reverts is chased as foliage again.
  - **Progress** = his inventory count of the item (bag + hotbar). For pickups with no known item id, the item is learned from the converted actor's `ItemData` or from the first inventory rise.
  - **Stumps are left by default:** chopping a stump stops the tree regrowing (wiki Woodcutting), and this is the group's world. Use `stumps=true` to take them.
  - Arbiter level `task`, lease 5 s. When suspended it does no input; on resume it re-checks the tool and rescans. Suspended time does not count toward the timeout.
- **Search (search-before-building):**
  - mineflayer-collectblock (src/CollectBlock.ts: nearest target first, `bot.tool.equipForBlock` with requireHarvest, drops within 0.5 blocks become new targets, a 10-tick wait for drops, `GoalFollow` to collect, cancel = stop the pathfinder).
  - Baritone MineProcess (counts the inventory each tick and stops at `desiredQuantity`; blacklists the closest location when a path fails; rescans; cancels when nothing is known).
  - The RuneLite/Microbot woodcutting search found nothing directly reusable: only the RuneLite WoodcuttingPlugin API (statistics, not automation).
  - Epic docs for `GetInstancesOverlappingSphere` (returns indices, bounds based), UE-149109 and forum reports that it over-reports by bounds (hence the distance filter).
  - Dragonwilds wiki Woodcutting / Overhead Chop: tier per tree, Overhead Chop at level 4 does about 10% damage to standing trees, stumps regrow in 72 h unless cut.
  - Nothing on Dragonwilds' melee aim assist (`MaximumAngleAimAssist` 45, camera-based); whether it helps against resources is a live question.
  - Decision: **adapt** (the collectblock / Baritone loop shapes, the legacy server profiles and chain) and **build** the thin client loop over move/inventory/combat/arbiter.
- **First live runs (2026-10-25, about 19:36-19:37 UTC, Shockbyte):**
  - `gather_ash2` answered at once with `wrong_tool` / `no_tool`, "I need a logging axe for ash and I don't have one." This was correct: after the 19:14 cow-fight death his axe, pickaxe, dagger, shield and torch were in a gravestone. Inventory: armour, food, drink, bolts. Nothing moved and the pawn was not taken.
  - `gather_stones2` (ground stones, interact key):
    - The arbiter granted `gather:stone` (task). The foliage scan picked a Stone pickup at 23.1 m (`fol:BP_InteractableFoliageISMC_PickUps_C_10:112`).
    - `move.go_to` failed `unreachable` / `no_route`: the local planner found only drop edges ("walls everywhere") from the lodestone-pad island. Gather blacklisted that stone and moved on to the next one at 12.7 m, as designed.
    - **The client then hung** (last mod line 19:37:01, move's local plan #3). The watchdog took a stack (`logs/client/hang_9728_20261025_203801.txt`), killed the client at 19:38:06 and rebooted it, back in the world at 19:38:59.
    - No interact press, swing or equip had happened. Gather was only polling `move.status`, `FindAllOf` and `inventory.list` (1 Hz) while move.lua planned. That run had `t.MaxFPS=30`.
  - Still **UNVERIFIED live**: a swing's hit on a tree, the felled chain on the client, magnet or interact collection, and the inventory delta.

## Traversal learning (R2) (2026-10-25, 19:24-19:45 UTC, client build 26162923, Shockbyte world, read-only)
Module: `client_mod/scripts/traverse_learn.lua` (task R2.12; design `docs/research/2026-10-25-traversal.md` 3.5). Commands: `client_mod/commands/learn_start.lua`, `learn_status.lua`, `learn_stop.lua`, `learn_rebuild.lua`. Offline test: `lua client_mod/tests/test_traverse_learn.lua <empty_dir>` (39 checks).
- **What it is.** A read-only recorder: one `LoopInGameThreadWithDelay(1)` loop, about 120 Hz live.
  - It never moves the pawn or presses input.
  - Per frame and per tracked pawn (every other player via PlayerState `PawnPrivate`, plus Claude himself), it reads `CharacterMovement.MovementMode`, `.Velocity`, `ReplicatedJumpCurrentCount` (and `JumpCurrentCount` on the local pawn) and `K2_GetActorLocation`.
  - An event opens on falling (mode 3) or a jump-count change, and closes on landing.
  - It honours `_G.DW_PAUSE` and an invalid controller/pawn: verified offline, no UObject reads while paused.
- **Proxy reads VERIFIED live.** On Luis's simulated proxy, `CharacterMovement.MovementMode` reads 3 in the air and 1 on the ground, and `ReplicatedJumpCurrentCount` reads 1 then 2 within the jump.
  - Luis's double jump: the count went 1→2 at **0.31-0.33 s** after take-off, with vz 201→670 cm/s (second impulse). That matches move.lua's 0.35 s second Jump.
  - Measured double-jump rise (take-off to the dash at the apex) **2.7-3.3 m**, sprinting at 6.0-6.8 m/s. These are NOT ledges: the "landing" was the dash entry (MOVE_Custom, below).
  - So a rise of 2.5-3.3 m is a double jump, not Windstep. The recorder calls it Windstep only on a Windstep cast since the last landing, a rise > 2.5 m on a single jump, or a rise > 4.5 m.
- **`ReplicatedJumpCurrentCount` is STALE on proxies after landing.** It stayed 2 through Luis's walk-off drop 1 s after a double jump (19:40:48), so that drop was first misclassified as double_jump. It reads 0 again at other times.
  - **Rule:** only a *change* from the grounded baseline is a jump signal, never the absolute value.
  - Fixed, with the fake leader in the test now keeping a stale count.
- **The 9-12 m/s "walk-off take-off speeds" were the air dash** (MOVE_Custom, mis-read as ground), not proxy smoothing. Explained below.
- **MOVE_Custom (6) is the AIR DASH. VERIFIED live (19:44:14).** Dominion's `ECustomMovementMode` has a single value, `CMOVE_Dash = 1` (dump `Dominion_enums.hpp:1055`).
  - Luis's proxy went mode 3 → **6** at the apex of his double jump (vz ~0, Z flat), the dash carried him ~5 m in mode 6, then mode 3 again until landing.
  - He travels this way constantly: a double jump (second jump at 0.31-0.33 s) plus a dash every ~12 m.
  - The first recorder version treated mode 6 as grounded and split each flight into "double_jump up" + "drop down". The 9-12 m/s "walk-off speeds" were the dash velocity.
  - **Rule:** modes 3, 5 and 6 are airborne. Entering mode 6 is recorded as a dash (`custom[]`, `dashes[]`), and the event's move becomes `air_dash`.
  - The live raw events were repaired: 16 split pairs merged, marked `repaired: split_by_custom_mode`; backup `traversal_events.jsonl.bak_before_custom_fix`. The store was rebuilt.
  - The evade multicast is **not** how the air dash replicates. Whether it fires for a ground evade is still unseen.
- **Multicast hooks** `PlayerEvadeComponent:Multicast_StartEvade`, `PlayerMagicComponent:Multicast_SendPayloadForSpellCasting` and `DominionMovementComponent:Multicast_ApplyFallDamage` register on the client (`ok=true`). No hit was seen yet (hook_hits 0). **Windstep detection on live data is UNVERIFIED** (offline only). Hooks that fail at the main menu are retried from the tick every 10 s.
- **Walkable-terrain filter (after the dash finding):** every flight ≥ 1.5 m within **80 m of Claude** gets downward probes under its line, every ~0.5 m, max 12, none within 0.7 m of the landing.
  - With no gap and every segment |dz| ≤ 45 cm + 0.3 × its length, the flight was over walkable ground. It stays a raw event (`why: walkable_terrain`), not a link. This drops Luis's dash-hops over rolling ground.
  - Flights farther than 80 m from Claude are not probed (client collision streams around Claude, so "no floor" there may just be unloaded). A far flat flight stays a hop, and a far up/down flight is kept with `gap_probe.unprobed`.
- **Live store after the repair** (data/skills/shockbyte/traversal_links.json, 10 links; feet-level endpoints, metres):
  - Luis's drops L1 (3.05 m at (114.4,1838.2)) and L4 (5.7 m at (223.8,1797.9)).
  - 7 Luis `air_dash` links (dz -3.1..+1.3 m over 11.8-14.8 m). They predate the walkable filter and are `usable=false` for Claude (`needs:AirDash`).
  - **L10 = Claude's own sprint_jump up 1.54 m, `verified`, source self** (local-planner crossing at (442.7,1800.3)→(444.3,1804.5)).
  - The first double-jump demos (3.03 m and 2.53 m ledges) turned out to be double jump + dash flights that the repair merged.
  - Claude's own step-ups of 0.61-0.63 m were seen and correctly not made links (self threshold 1.0 m).
- **Live cost:** about 120 Hz loop. A trace count of 59 over ~60 events (traces happen only after a landing). No `last_error` after the `try()` fix (an early `tonumber()` of a failed read raised once per tick until then).
- **Classification:**
  - shape: up (dz ≥ 0.6 m), down (dz ≤ -1.5 m), gap (a flat flight ≥ 1.5 m with downward traces under it finding no floor within 1 m below the lower end), else flat (a hop: raw event only, no link);
  - move: drop | jump | sprint_jump (take-off > 5.2 m/s) | double_jump | air_dash (MOVE_Custom mid-air, an evade multicast mid-air, or a horizontal speed rise > 3 m/s in 0.2 s) | windstep. The easiest move seen to cross a link is what it needs.
- **Clustering:** leader clustering. A new event merges into a link when from is within 1.5 m, to within 2.0 m and the heading is within 25°. Endpoints are a member-weighted running mean, and `n_seen++`. Self crossings within 2 m of both endpoints mark the link **verified** (`n_ok++`) and never move it. `record_attempt` failures 3 times in a row → `disabled`.
- **Traces hit attached gear:** `LineTraceSingle`'s bIgnoreSelf skips only the context pawn, not its attached armour or held actors (locomotion agent). Gap probes therefore skip points within 1 m of the landing, where the jumper stands.
- **Files:**
  - raw events `logs/state/worlds/<world>/traversal_events.jsonl` (one line per airborne event, with up to 120 airborne samples `[dt,x,y,z(capsule),mode,jc,vz]` for replay fixtures);
  - links `data/skills/<world>/traversal_links.json` (git-tracked; this module is the single writer; `rebuild` re-clusters from raw events).
  - World id: `DW_WORLD_GUID` (global or env), else `client_io/world_guid.txt`, else `shockbyte`.
- **move.lua consumes it (locomotion agent, move.lua v6):** `best_link(me, goal, {env, max_detour=3})` at the unreachable give-up, then `record_attempt`. A nil result with `needs:X` becomes the unreachable reason. Not yet in localplan A* edges.
- **Search (search-before-building, 2026-10-25):**
  - Queries on learning off-mesh/jump links from player trajectories, CS bot learn modes, trajectory/flight-phase segmentation and online leader clustering.
  - **No source turns recorded human jumps into navmesh links.** Unity, UE and Recast generate links from geometry: docs.unity3d.com nav-BuildingOffMeshLinksAutomatically; dev.epicgames.com automatic-navigation-link-generation; Utrecht thesis studenttheses.uu.nl/handle/20.500.12932/22818.
  - CS bots use hand-placed jump hints (developer.valvesoftware.com Nav_Mesh_Editing; RealBot learns without human guidance).
  - The closest prior art is a patent family building route links from aggregated player telemetry, dropping rarely used links (USPTO 10406437 / 11235241). That supports our `n_seen`-based confidence.
  - Phase segmentation in the flight-trajectory literature is rule- or HMM-based on altitude and vertical rate (arxiv.org/abs/2203.09033; TU Delft JOAS HMM flight phases). We adapt the rule-based form, since the engine gives us the movement mode directly.
  - Leader (threshold) clustering with member-weighted merges is the standard online pattern (arxiv.org/abs/1506.07208; arxiv.org/abs/2006.01117).
  - Decision: **adapt** (off-mesh link model, rule-based phase segmentation, leader clustering) and **build** the thin recorder. No library was needed.

## Client hang (R2): GameThread deadlock in ULightFlickeringWorldSubSystem (2026-10-25, client build 26162923; diagnosed from cdb stacks + static reading of the shipped exe, read-only)
- **Symptom:** six hangs between 17:53 and 19:38 UTC (17:53:54, 18:27:42, 19:14:19, 19:26:35, about 19:30:07, 19:37:01). The process stays alive at about 0 CPU; the GameThread sits in `NtWaitForSingleObject` and every worker is idle.
  - All five GameThread stacks taken (`logs/client/stack_6400_175704.txt`, `stack_8452_201705.txt` + `stack_all_8452_201730.txt`, `stack_9064_202831.txt`, `hang_9712_20261025_203310.txt`, `hang_9728_20261025_203801.txt`) are identical return address for return address.
  - The last game-log line varies (FlushAsyncLoading, EOS lobby, QuickAccessBar), so it is not the cause.
- **Method:** the exe has export-only symbols and no PDB (Jagex and Epic publish none for a shipping game). Live module base 0x7ff710650000 vs preferred base 0x140000000.
  - Frames were mapped by disassembling the on-disk image with `cdb -z <exe>` (`ub`/`uf` at the image addresses).
  - Callee identities came from argument patterns (ENamedThreads values, vtable slots), string xrefs, and `.rdata` vtable/name neighbourhoods (scratch scripts: PE pointer search, lea/call xref scan).
- **Mapped GameThread stack, outermost first:**
  1. `FEngineLoop::Tick` → `GEngine->Tick` (vtable +0x2F0) → game engine Tick wrapper → `UGameEngine::Tick` (0x143fe4020, the function UE4SS's EngineTick detour wraps; UE4SS is only the pass-through frame) → `UWorld::Tick(LEVELTICK_All=2, dt)` (0x1441be850).
  2. `RunTickGroup(TG_DuringPhysics=2, bBlock=false)` → `FTaskGraphInterface::ProcessThreadUntilIdle(GameThread=1)` → GameThread named-queue task → `FTickFunctionTask::DoTask` → `ExecuteTick` (vtable slot 3, tail call).
  3. **`ULightFlickeringWorldSubSystem::Tick`** (0x1468f8ab0). Identity:
     - its `this` fields start at 0x68 = sizeof(UJgxTickableWorldSubsystem); the class is 0x2D0;
     - the adjacent `.rdata` holds the `LightFlickeringWorldSubSystem` name and its native function table (AddLightFlickering, RemoveLightFlickering, UpdateLightBaseIntensity).
  4. 0x1468f9970: `if (PendingTask /*this+0x1A8*/) FTaskGraphInterface::Get().WaitUntilTasksComplete({PendingTask}, AnyThread)` (vtable +0x60) → task-system wait → `FEvent::Wait(MAX_uint32)`.
- **What the subsystem does each frame:**
  - It waits for last frame's task, swaps its three result sets (this+0x68/0x108/0x1A8 ↔ +0x1E0..) and reads the first local player's view location.
  - It launches `FFunctionGraphTask::CreateAndDispatchWhenReady(lambda, ..., ENamedThreads 0x2FF = AnyBackgroundThreadNormalTask)` and stores it at this+0x1A8.
  - The background body (0x1468f6660) accumulates time, computes flicker for the registered lights, then **dispatches a follow-up task to `ENamedThreads::GameThread` (1) and calls `MyCompletionGraphEvent->DontCompleteUntil(thatTask)`**.
- **Root cause:** the background task's completion depends on a GameThread task. Next frame, the subsystem waits for it from inside a GameThread tick task.
  - The GameThread is already "processing tasks" (inside ProcessThreadUntilIdle), so `WaitUntilTasksComplete` takes the stall-on-event branch instead of draining the GameThread queue.
  - Whenever the background task plus its GameThread follow-up has not finished by the next frame's TG_DuringPhysics tick, the GameThread waits forever for work only it can run. That is a self-deadlock and a timing race.
- **Why our client hits it** (a normal player probably never does):
  - **about 115 fps** (GameFrameRateLimit=120, NullRHI makes frames cheap), so the window is about 8 ms;
  - only **2 background workers** (4 vCPU) at below-normal priority, shared with item and asset streaming. This explains the correlation with equips, pickups, eats and new meshes;
  - CPU contention from the dev server and brain on the same VM;
  - heavy GameThread Lua bursts (hang 6: LineTrace bursts, no asset load).
- **Ruled out:** a NullRHI render fence or flush (the render thread is idle in its task loop, and no RHI wait is on the stack); UE4SS (pass-through tick detour only; the wait is engine plus game code); the async-loading thread (idle).
- **Fix (live 19:40 UTC, pid 4488): `client_mod/scripts/tickguard.lua`.**
  - It writes the reflected `UJgxTickableWorldSubsystem.PrimarySubsystemTick.TickInterval` (FTickFunction at +0x30, float at +0x3C) = **3600 s** on every live `LightFlickeringWorldSubSystem`, then reads it back.
  - The tick then runs about once an hour, so the wait always finds the previous task long done.
  - Effect: client-local light-intensity animation only, which a -nullrhi client never draws. Server and players are unaffected. FTickTaskLevel re-reads TickInterval every frame, so no re-registration is needed.
  - Supervised as `client_bridge.SERVICES` "tickguard" (healthy = every live instance has the interval; re-applied within 10 s on each new world, from the next bridge start).
  - Commands: `tickguard_apply.lua`, `tickguard_status.lua`. Read-back verified: 0.0 → 3600.0.
  - The guard table (`M.GUARDS`) is generic: add a row for any other tick function found to deadlock.
- **Defence in depth: 30 fps cap.**
  - `t.MaxFPS=30` in Engine.ini `[SystemSettings]` is **overridden** by the game: it applies `DominionUserSettings.GameFrameRateLimit` (t.MaxFPS read back 120 at runtime).
  - Effective: `GameFrameRateLimit/FrontendFrameRateLimit/FrameRateLimit=30` in `Saved/Config/Windows/GameUserSettings.ini` (next boot), or at runtime `client_mod/commands/fps_cap.lua` (game settings object: SetFrameRateLimit + ApplyNonResolutionSettings).
  - Measured: 28–29 fps (was 99–116); client CPU 0.53 cores (was about 1.2). `fps_probe.lua` reads the limiter state.
  - Prefer the game's own user setting over `-ExecCmds` or an Engine.ini CVar, which the game's settings re-apply overwrites.
- **Not chosen:** WARP/D3D12 software rendering (it costs CPU and RAM and doesn't remove the race); `-onethread` (changes all task semantics, slow); more workers (`-foregroundworkers=` exists; it only narrows the race); patching the wait (binary patching not approved).
- **Watchdog:** the 5th hang was caught late because `GraceS=240` counts from process start. `tools/client_watchdog.ps1` now ends the grace once a probe has seen this pid in L_World (`$script:inWorldPid`).
- **Search (search-before-building):**
  - "UE5 WaitUntilTaskCompletes game thread deadlock DontCompleteUntil", "nullrhi client hang uncapped framerate", "UE4SS engine tick hook deadlock": nothing specific to this pattern.
  - Epic's Tasks docs say waiting "should be avoided" and that busy-waiting "caused deadlocks regularly"; UE 5.5 oversubscription only wakes extra workers, so it cannot help a GameThread-only dependency (dev.epicgames.com/documentation/en-us/unreal-engine/tasks-systems-in-unreal-engine).
  - The FTaskGraphInterface API docs: WaitUntilTaskCompletes "requests that a named thread, which must be this thread, run until a task is complete" (dev.epicgames.com/documentation/unreal-engine/API/Runtime/Core/FTaskGraphInterface).
  - t.MaxFPS caps by sleeping the GameThread (dev.to/feed/adbhut).
  - Decision: **reuse** the engine's own tick-interval mechanism and the game's frame limiter; build only the thin guard.
- **Open:** an hour-long soak is needed to confirm no hang (the base rate was 1 per 5–40 min). An interval tick still fires once an hour; if a hang ever recurs with this stack, raise the interval or add a guard row.
- **FIRST REAL FIGHT WON, VISUALLY VERIFIED (2026-10-25, 19:50:19-19:51:14 UTC, Shockbyte, after the hang fix; Luis watched from GFN: "he is blocking correctly and using some combos - proud of him").**
  - Setup: no Kebbit or Cow within 80 m of the plateau, so the target was a lone **Goblin Runt** (`BP_AI_RuntGoblin_Character_C`, Aggressive, PL1, 156 HP), 34-42 m away; the next hostiles were 64 m or more away. Commanded `attack` **without force**: the fight-or-flight check rated it winnable (u_fight 0.79 at the start, rising to 0.98), Claude PL2, level-1 skills, 100 HP.
  - Equip from his own inventory: Bone Dagger (hotbar key 6) + Bronze Shield (key 8), in under 1 s.
  - Approach: `move.follow` of the creature by entity id, 26 s (sprint plus local planner up the slope), reach 2.2 m.
  - Engage: **17 IA_PrimaryAction taps** injected; **10 of them verified by stamina spent** (the others fell during blocks, or the stamina had already regenerated). Luis saw **combos**: the 0.5 s input buffer turns a jittered cadence (the weapon's own input-window timing, 0.77 s + 40-200 ms) into chains.
  - **Telegraph hook verified:** `AiAttackComponent:Multicast_PerformAttackOnSimulatedProxies` fires on Claude's client for every goblin attack (10 events in the fight). Each one triggered **a block** (IA_SecondaryAction held about 1.2 s, after a 150-300 ms reaction delay): 6 blocks, stamina 56 → 29 at its lowest, **Claude took 0 HP damage** (hp_frac 1.0 throughout).
  - Goblin HP (replicated `GetAuthoritativeHealth`, read at about 2.5 s intervals): 156 → 142 → 112 → 98 → 68 → 10 → 0. Killed at +49 s.
  - Loot: one IA_Interact press at the kill spot (19:51:09); the targeted world item vanished (looted 1); the bag afterwards held GoblinPack x2 and Bone Bolts x3 among others (the before/after delta was not captured).
  - **Bugs found live, fixed offline (80 checks pass):**
    - (1) **Our hits never matched**: 0 of the damage multicasts on the goblin named Claude's pawn as `Instigator`. Now the pawn or the PlayerController counts, and every damage event on the target is kept in `combat_status.on_target` (instigator and source class) to settle this on the next fight.
    - (2) **Re-equip skipped**: a two-handed tool is reported in the LEFT hand only (`held.right` nil, `left` = Mithril Logging Axe), so `prev_right` was nil. Now the main held item (right, else left) is restored. The axe was re-equipped by hand afterwards (hotbar key 4; held left = axe).
- **Reflex + arbiter verified live (19:43:49-19:44:04 UTC, while Luis led Claude up the hill):** the guard saw a **Giant Rat** (Aggressive, PL2, 260 HP) at 2.3 m (`hostile_near`). It suspended the bridge's unregistered `go_to` (adopted as `move:go_to`), rated the fight `losing` (equal power level, 260 HP), **fled toward Zezima**, ended safe after about 14 s, released, and the arbiter **resumed the go_to**.
- **Arbiter bug (live, 20:05-20:07 UTC), fixed:** main's manual `go_to` drove move.lua directly; the arbiter adopted it as the implicit owner `move:go_to` (when the reflex suspended it). After the move ended, the owner was never released, so `gather` was refused `pawn_busy` while Claude stood still. Fix: an implicit owner is released as soon as `move.status()` is idle, has a 30 s lease renewed while its move runs, and a refusal returns the owner's name, level, age and move status. gather's canned "busy with something more important" line is replaced by structured data (`why`, `owner`, `busy_with`, `busy_move`).

### Defence, perks and held-item actions (2026-10-25, read live, read-only, client build 26162923)
- **Parry needs a perk Claude lacks.** The block actions' CDOs (`/Game/Gameplay/Character/Player/Abilities/Block/PA_Block_*`):
  - Shield (`PA_Block_Shield_Kite_Iron_C`, also the Bronze Shield's): `bCanParry` true, `SkillPerkRequiredToParry` = **`PerkV2_Attack_Parry`**, Block/Parry stamina 10, `ParryRefundMultiplier` 5, `bRequiresHolding` true.
  - Dagger (`PA_Block_Dagger_C`): can parry with the same perk, 35 stamina, refund ×1.4.
  - Pickaxe (`PA_Block_PickAxe_C`): `bCanParry` false, 20 stamina.
  - `SkillPerkComponent:IsPerkUnlocked(PerkV2_Attack_Parry)` = **false** for Claude. Community sources put Parry at Attack 5 (gamever.io "Parry at 5, Specials at 8, Tempest Shield at 11"; dragonwilds.runescape.wiki/w/Melee; esports.gg skills list).
  - `PlayerBlockingComponent`: `ParryWindowLength` 100 (ms), `ParryDamageMitigationPercentage` 100, `MinimumBlockDuration` 0.75, `ParryAnims` = `DA_Player_ParryAnims`. Parry montages: `AM_PlayerM_Shield_Parry`, `AM_PlayerM_Dagger_Parry`, ...
- **Weapon specials need a perk too:** `PA_Attack_Dagger_Special_C.RequiredPerk` = **`PerkV2_Attack_MeleeSpecialAttacks`**, not unlocked (wiki: Attack 8). The first Goblin fight's unverified presses included specials; combat now gates the special on the action's `RequiredPerk`.
- Evade: `PlayerActionPerformer.DefaultEvadeAction` = `PA_Evade_Default_C`, no RequiredPerk. Ping: `PlayerState:GetPingInMilliseconds()` ≈ 50 ms.
- **The game's own signals used for defence** (dump; hooks registered, live firing still to verify):
  - At the telegraph, `AiAttackComponent.CurrentAttack.AttackData` (`UAiAttackData`) gives `GetDamageTime()`, `GetLastDamageTime()`, `GetDuration()`, `AttackPropertyFlags` (`EAttackProperties`: Unblockable 1, Unparryable 2, Special 4, ComboFinisher 8, ForceBlast 16) and `Damage[]` {Time, Shape (`UDominionShape_*`), Force, DamageClass}.
  - The verdict on Claude's block: `PlayerBlockingComponent:Multicast_NotifyActorsToDamagePendingParriedAttack` / `...BlockedAttack`; `FBlockOutcome {Result EBlockResult, bParried, ParryRefund}`. The AI also has `PreemptParryWindowOpening(ParryWindowLength)`.
- **Held-item actions (live, `combat.held_actions`):** `UHeldEquipmentData.{Primary,Special,Secondary,PrimarySprint,PrimaryJump,PrimaryVisceral}ActionClass`. Each class's CDO (`UPlayerAction`) has `ActionName` (FText), `RequiredPerk` and `bRequiresHolding`. Mithril Pickaxe (held left, 2H): primary "Attack" (`PA_Attack_Pickaxe_C`), secondary "Block" (`PA_Block_PickAxe_C`, holding). These are offered to the model as styles (`attack.style`, `gather.style`, `use_action`); the model chooses, nothing is hard-coded per resource.
- **Design (search-before-building):** parry = an input inside a few-frame window before the hit, and input lag shrinks it (bugnet.io/blog/bug-reporting-for-games-with-parry-and-block-timing). Melee lag compensation splits the one-way latency off the wind-up (gamedev.net/forums/topic/634003). Dragonwilds: dodge cancels most animations; stamina regenerates only after 3 s without stamina actions (dragonwilds.runescape.wiki/w/Stamina). Nothing found on bots that learn parry timing, so built `client_mod/scripts/defense.lua`:
  - The press is sent at `T - 2L - window/2 + offset`. T is the attack data's damage time, replaced by an EMA of observed telegraph→verdict times; L is the one-way latency.
  - The offset adapts: blocked-not-parried means too early, so press later; hit means too late, so press earlier.
  - Too fast for a 150-300 ms reaction → plain block. Unblockable → dodge, or jump if the shape is low or a centred area attack. No stamina → retreat.
  - The policy comes from the model's `combat_orders`.

## Client crafting (R2) (2026-10-25, client build 26162923; reflection dump 26161880; task R2.19, design `docs/design/r2-crafting.md`)
Module `client_mod/scripts/crafting.lua`; offline tests `client_mod/tests/test_crafting.lua`; read-only probe `client_mod/commands/craft_probe.lua`; read-only capture of the UI call chain `client_mod/commands/craft_capture.lua` (writes `client_io/events/craft_capture.jsonl`).
- **The crafting UI has its own API object, like the inventory** (dump, Dominion.hpp:18170), the real player path for a bench:
  - `UCraftingUIAPI` {`CurrentStation` (UCraftingStationComponent), `StandbyStation`, `CurrentCraftRecipe`, `InventoryAPI`, `PlayerController`, `ProgressComponent`};
  - its handlers: `ShowCraftingUI(Station, EWidgetType)`, `ToggleCraftingUIVisibility`, `HideCraftingUI(EWidgetType)`, `SelectRecipe(URecipeData*)`, `SelectCraftingAmount(int)`, **`SendCraftRequest(int Amount)`**, `SendRepairRequest`, `SelectRepairItem`.
  - EWidgetType: Crafting 6, Processing 15, WorldInventory 26, Container 33.
  - **[UNVERIFIED until craft_capture runs]:** `SendCraftRequest` → `InventoryController:CraftRecipe` → `Server_CraftRecipe` with the game's own BonusCount, XP multipliers and `GetLinkedInventories`.
- **Processing stations have `UProcessingStationUIAPI`** (Dominion.hpp:31161):
  - fields: `ProcessingStationComponent`, `StationIngredientsInventory`, `StationFuelInventory`, `ValidIngredients`;
  - handlers: `ToggleProcessingStationStarted()` (the start button), `SetCurrentProcessingStation(Comp, IngredientsInv, FuelInv)`, `UnsetCurrentProcessingStation`, `ClearProcessingStation(PC)`.
  - Items go in through the inventory UI's external-slot handlers (`UInventoryUIAPI`, Dominion.hpp:25045): `HandleSplitToExternalSlot(FromSlot, FromSlotType, Amount, ToSlot, OutsideTargetInventory)`, `HandleDragAndDropToExternal`, `HandleExternalQuickTransfer(Slot, OutsideSourceInventory)`, `HandleDragAndDropFromExternal`.
- **`UProcessingStationComponent`** (Dominion.hpp:30943), live-readable state:
  - `bStationRunning`, `bReadyToProcess`, `RemainingProcessingTime`, `RemainingFuelTime`, `CurrentRecipe`, `LastValidRecipe`;
  - inventories `Resources`, `Fuel`, `OutputInventory`; `bStoreOutput`, `StorageType`;
  - `AcceptedResources`, `RecipesCache`, `ProcessInstigator` (FDomCharacterGuid).
  - `UCraftingStationComponent`: `ValidRecipes`, `DisplayName`, `bIsVendor`, `bHaveRepairOption`.
- **Unlocks are item/actor discoveries, not skill levels.** `FProgressionBundleRow.UnlockQueryString` uses only `ITEMS[...]` (815 recipes), `ACTORS[...]` (252), `ALL [entitlement]` (10) and `GOLD[agility courses]` (1). So holding an item and being near a station unlocks most recipes. The catalog's Lua now carries them as `uq`, and the planner shows them with station names (e.g. `ALL ITEMS[ Iron Ore ] AND ALL ACTORS[ Furnace ]`).
- **Claude's own unlocks** are read from `pc.ProgressComponent.RecipesUnlocked` (the TSet, as on the server). `UProgressComponent:IsRecipeUnlocked(URecipeData*)` exists too.
- **Server verdict:** `InventoryController:Client_OnCraftingResultHandler(ECraftingResult, Recipe, Count)` is a Client RPC. A read-only post-hook on Claude's client gets the result code; the codes map to speech in `crafting.RESULTS`, and an unknown code becomes `craft_failed`.

## Claude's stats raised (2026-10-25 21:19 local, client build 26162923)
- Luis's edited character file (`edited.json`, max XP, 48 selected spells) **loaded unchanged on the dev server**, which had never seen Claude (total level 1076). So the file format and our login path are fine.
- On Shockbyte the server keeps its own per-character copy (CachedCharacterStates), keyed by character GUID. That copy overrides the uploaded file for a character it has seen before (DISCOVERIES "Raising Claude's stats…").
- **Fix that worked:** give the edited file a **fresh `meta_data.char_guid`** (`A8642C53AD2F422CA02FD23615387E10`, with worlds_playtime cleared), keeping the name "Claude".
  - Shockbyte has no copy for the new GUID, so it took the file: **total level 1076 live on Shockbyte** (Woodcutting/Attack/Construction/Farming/Runecrafting/Agility 99, Magic 89, Mining 93, Ranged 93, Artisan 84, Cooking 73, Fishing 50).
  - The old level-1 GUID `D06CFBE3…` stays unused in the world save.
- Files: `edited.json` / `edited_newguid.json` are gitignored. Backups are in C:\GameServers\backups\claude_before_devtest_*, claude_after_devtest_*.
- Power level read 2.0 right after join (a gear-based value?); recheck.
- **Live read-only probe (20:20 UTC, Shockbyte, Claude at the church respawn; `craft_probe.lua`):**
  - `CraftingUIAPI`, `ProcessingStationUIAPI` and `InventoryUIAPI` each exist once on the headless client.
  - Claude's `RecipesUnlocked` = **46** recipes, still 46 after Luis's stat edit (total level 1076): unlocks don't come from skill levels. They include the Community Cape (0 inputs, Crafting Table), the Compost Bucket (5 Ash Logs), the Ash Rod, the Whetstone, the Magic Focus, potions, teas, rune-altar runes and the skillcapes (Mystic Forge).
  - The census typed a **Crafting Table** (`BP_Crafting_StartingBench_C`, 75 recipes at that station type, 6 of them unlocked for Claude) at 72 m, [107, 1845, -32].
  - The bridge lists `craft`, `recipes`, `craft_plan` and `stations` in its capabilities.
- **FIRST REAL CRAFT through the UI path (verified 20:22:17 UTC, Shockbyte, debug-channel `craft {recipe: RECIPE_Armour_T0_Cape_Community}`):**
  - Claude walked about 18 m to the Crafting Table and pressed E once; the game opened its menu (`CraftingUIAPI.CurrentStation` became that bench).
  - He ran `CraftingUIAPI:SelectRecipe` + `SendCraftRequest(1)`, and the server answered **`Client_OnCraftingResultHandler(0 = Success, RECIPE_Armour_T0_Cape_Community, 1)`**.
  - The **Community Cape** arrived in his bag (slot 1). He closed the menu with `HideCraftingUI(6)`.
  - Result: `{ok, recipe_chosen, gained 1, result_code 0, detail "I made 1 Community Cape at the Crafting Table."}`.
  - No `Server_*` call was made by us.
- **Capture lesson (`craft_capture.lua`): a UE4SS `RegisterHook` on a `Server_*` RPC does NOT fire on the SENDING client.**
  - The capture logged only SelectRecipe, SendCraftRequest, Client_OnCraftingResultHandler and HideCraftingUI.
  - Not logged: `Server_CraftRecipe`, `InventoryController:CraftRecipe`, `PlayerInteractionManager:Server_RequestInteraction` (the E press that did open the menu), `ShowCraftingUI` or `Client_ToggleCraftingMenu`. All of them must have run.
  - Explanation: a hook runs when the UFunction body executes locally. On a client, a Server RPC is only forwarded (`CallRemoteFunction`), and functions called C++-to-C++ (not through ProcessEvent) bypass the hook. Client RPCs do execute on the client, so they are hooked.
  - So the client cannot prove the internal chain with hooks. The proof that the UI handler is the real path is the outcome: the server's own verdict (code 0) plus the inventory gain.
  - **We never call CraftRecipe or Server_CraftRecipe**, so the reviewer's fallback conditions (a)-(d) never come up.

## Client spells (R2) (2026-10-25, client build 26162923; reflection dump 26161880; task R2.20, design `docs/design/client-spells.md`)
Module `client_mod/scripts/spells.lua` (tools `spells`, `cast`). Read-only probes: `client_mod/commands/spell_probe.lua`, `spell_inputs.lua`, `spell_baseline.lua`, `spell_slices.lua`. Offline: `lua client_mod/tests/test_spells.lua` (65 checks).

**Where things live on the client (read live, 20:05 UTC and after the 21:19 local (20:19 UTC) character swap):**
- **Unlocked spells:** `pc.ProgressComponent.SpellsUnlocked` (TSet `ForEach(a, b)`). Before the swap there was 1 (Windstep); after it, 38.
- **The wheel:** `pc.SpellcastingComponent.SelectedSpells`, a flat array of `NumSpellRadials` 4 × `NumSpellSlotsPerRadial` 12 = 48. Page p, key k is index (p-1)·12 + (k-1).
  - `GetCurrentlySelectedSpellData()` (BlueprintPure) works.
  - `MaxDistanceFromCameraToPlaceSpell` is 1500 cm.
- **Static spell data, readable from Lua on the client:** `UtilitySpellData.SpellDisplayName`, `CastType` (0 Instant, 1 Placed, 2 Aimed, 3 AllowMovementThenCastInstant), `CooldownDuration`, `bAllowCastingWhileFalling`, `SpecialRequirementsText` (e.g. "Logging Axe", "Cast on a tree").
  - Costs: `Modules.Modules[].Module` → `SpellModule_CostItems.ItemsCostInfo[] {ItemData, Count}`. `ItemData.Name` gives "Air Rune".
  - `OwningPerk.PerkDescription` is the game's own description, e.g. "Summons the power of Air Magic to Jump higher and Descend slower.".
  - `OwningPerk.PerkUnlockInfo {AssociatedSkill, RequiredSkillLevel}`. Windstep = Agility 5, Summon Shelter = Construction 20.
  - `SpellIcon` (soft pointer: `GetObjectID():GetAssetPathName()`) is the same texture the wheel slice shows.
- **UI truth per slot:** `HUDUISubsystem.SpellcastingAPI:GetSpellDisplayInfo(slot)` (BlueprintPure, struct return → Lua table). Read for slot 0: `SpellName`, `DescriptionText`, `bIsUnlocked`, `CooldownDuration`. Nested `SpellItemCost[]` entries came back unreadable from the table form, so costs are read from the spell data instead.
- **Pawn:**
  - `PlayerUtilityMagicComponent`: `CastingTag` `Player.Status.Casting.UtilitySpell`, `SpellBeingPreparedOrCast.SpellBeingPreparedOrCastData`, `LastCastTimeBySpellData` (TMap, empty before any cast), `OurSpellActors`.
  - `pawn.WindstepTag` = `Player.Spell.WindStep`.
  - `GameplayEffectsComponent.ReplicatedInstances` / `NonReplicatedInstances` were empty at rest.
  - Server clock: `GameStateBase:GetServerWorldTimeSeconds()` (58109.8 at 20:12).
  - **UNVERIFIED:** that `LastCastTimeBySpellData` values use that clock. Check it after the first cast.
- **Runes:** they are ordinary inventory items (`ITEM_Rune_<Element>`) in `pc.InventoryComponent.ItemSlots` (the runes page). Luis dropped Air 821 / Astral 5452 / ... at about 20:00. After that swap the inventory was empty, so every spell answers `not_enough_resources`.

**Key path (mapping contexts read live; key names from `EnhancedActionKeyMapping.Key.KeyName`):**

| Context | Mappings |
|---|---|
| `IMC_GameplayUI` | Q = `IA_SpellMenu` (action trigger **Released**, `bConsumeInput` false), P = `IA_SpellBook`, R = `IA_QuickAccessRadialToggle` |
| `IMC_SpellsUI` | **1–8 = `IA_Spellcasting_QuickAccess0..7`** (trigger Pressed), Q, P, H = emotes |
| `IMC_RadialSelection` | LMB = `IA_SpellsMenu_AcceptSelection` (Pressed), **F/G = `IA_SpellsMenu_SwitchRadialLeft/Right`** (previous/next wheel page), Gamepad_Right2D = `IA_SpellsMenu_SelectSlot` (Axis2D) |
| `IMC_SpellcastingMode` | **LMB = `IA_Spellcasting_PlaceSpell` (Released)**, Esc = `IA_Spellcasting_Cancel` (Pressed), mouse wheel = `IA_Spellcasting_AdjustSpell` (Axis1D), Q |

- Input modes (`pc.CurrentInputMode`): `DIM_Gameplay` at rest; `DIM_RadialMenu`, `DIM_SpellcastingMode`, `DIM_SpellPlacementMode` and `DIM_SpellPlacementModeAdvancedMovement` are in the PC properties of the same names.
- The live panel is `WBP_Spellcasting_MainPanel_C` under `/Engine/Transient...BP_DominionGameInstance_C` (the copy under `WidgetTree` is the archetype). It exposes:
  - its own input actions (`TriggerSpellRadialInputAction` = IA_SpellMenu, `ChangeSpellRadialRightInputAction`, ...);
  - `SpellRadialWidget` (`WBP_SurvivalSorcery_RadialSelector_C`), whose `QuickAccessInputActions` = QuickAccess0..7 and whose 12 `Slices` each have `SpellSlotNum` 0–11 (**within the page**) and `SliceIcon.Brush.ResourceObject`, the texture of the spell shown.
  - So **which page is open = compare slice icons with `SpellIcon`**. That is how `cast` checks that the open page shows the wanted spell before pressing its key, so it never casts another spell.
- Slots 9–12 of each page have no key (QuickAccess covers 8). Those spells answer `not_on_wheel` "sits in a spell wheel slot I can't reach yet". After the swap that includes **Windstep (index 35 = page 3, slot 12)** and the Enchant Weapon spells.
  - Phase C idea: the gamepad path, i.e. inject an `IA_SpellsMenu_SelectSlot` direction, read the radial's `SpellName` text, and Accept only when it names the wanted spell.

**After the 21:19 swap (`spells {all}` live):**
- 38 unlocked; Fishnado is locked.
- Reachable by key, among others:
  - page 1: Axtral Projection 1, Splinter 2, Trunk Totem 3, Bark to Bones 4, Superheat 5, Overdrive 6, Magical Mending 7, **Tempest Shield 8**;
  - page 2: **Summon Shelter 1**, Personal Chest 2, Internal Alchemy 3, Bones to Peaches 4, Uproot 5, Humidify 6, Rapid Growth 7, Mucksplosion 8;
  - page 3: Rocksplosion 1, ... Fire Spirit 8;
  - page 4: Phase Dash 1, Recall 2.

**Search (search-before-building):** no Dragonwilds or UE4SS spellcasting automation found. Game controls: allthings.how "how the spellbook menu and wheel work" (Q wheel, P spellbook, 4 loadouts of 12) and dragonwilds.runescape.wiki/w/Spells (costs, skill levels). Decision: adapt our verified Enhanced Input injection (combat/inventory) and build the state machine.
- **After the character swap (21:19 UTC; Attack 99, Agility 99, total level 1076), read live:** `PerkV2_Attack_Parry` unlocked = **true**, `PerkV2_Attack_MeleeSpecialAttacks` unlocked = **true**. `BP_GetPowerLevel` is still **2**: power level follows the gear, not the skills. Max HP 100, max stamina 60. Hands were empty (inventory being refilled).
- **North Star change (cold review):** a commanded `attack` is never refused for strength any more. Its reply carries `data.assessment {verdict likely_win|likely_lose|too_strong|boss|outnumbered, u_fight, est_s_to_kill, est_s_to_die, pl_gap}` as information. Mid-fight, a commanded fight flees only below the model's `combat_orders.flee_hp`. The reflex keeps its own vetoes, with its policy set by the model. Never-attack-players is the only hard gate.

**Live findings, Shockbyte world at night (about 20:35–20:45 UTC):**
- **The wheel input path works live.**
  - One injected frame of Q (`IA_SpellMenu`, Released) opens the wheel (`DIM_RadialMenu`).
  - G (`IA_SpellsMenu_SwitchRadialRight`) turns the page. The slice icons refresh about 0.4 s later, **not immediately**. Reading them at 0.3 s caused a run of page turns that never matched (the first scripted cast: `page_not_found`, safely refused). `cast` now waits until the icons actually change, up to 1.5 s.
  - **A page turn also changes the game's selected spell** (`GetCurrentlySelectedSpellData`) to that page's slot 1. No cast happens.
  - Q again closes the wheel.
  - `IA_RadialSelection_SwitchRadial` flips the panel's `WidgetSwitcher` to index 1, the **emote** radial. Don't use it. Q does not close the wheel while the emote radial is showing.
- **Placed spells:** the number key enters `DIM_SpellPlacementMode` (brain run, Summon Shelter page 2 key 1). Cleanup Esc (`IA_Spellcasting_Cancel`) left it cleanly, and no runes were spent.
  - The game's own preview is `AUtilitySpellPlacementVisualizer.bCurrentPlacementValid` plus the `CurrentAdditionalValidationInfo` tag (green/red). `cast` aims the camera at each candidate spot and releases LMB only on green.
  - **Lesson:** don't pre-filter spots strictly with traces. Ground near the start area has a 0.6–0.75 m spread over 3 m, so a 0.6 m limit dropped all 24 candidates (`no_spot` twice in the brain run). Traces now only rank and drop hopeless spots; the game decides.
- **Brain side:** `brain/spells.py MAX_ROWS = 12` cut Summon Shelter from `castable_spells` (14 castable after the swap). The model then said "isn't in my castable spells". The body now sorts castable rows first, and MAX_ROWS is now 40.
- **Sleep prerequisites (read-only `rest_probe.lua`):**
  - `IsNighttime` true, in-game 00:14, `PlayerRestComponent.IsInTimeframeForSleep()` true.
  - `pc.RestingInputMode` = `DIM_Resting`. `IMC_Resting` maps only E / Gamepad_FaceButton_Left to `IA_Interact` (Pressed), i.e. **E again leaves the bed**.
  - Rest texts: "Resting. Waiting for {PlayersNotInBed}/{TotalPlayers} players to sleep." and "Taking a nap to recover Rest, since it's too early to sleep through the night.".
- **Side bug (skills.lua fetch, reported):** in a pile of rune stacks, `fetch {item: "Earth Rune"}` failed with "keeps picking Air Rune", and `fetch {item: "Air Rune"}` with "keeps picking Water Rune". The detector targets the nearest stack. Fetching in the detector's order worked.
- **SUMMON SHELTER CAST BY CLAUDE (live, 20:44 UTC, brain-chosen `cast {spell: "Summon Shelter"}` with no target; Luis saw it):**
  - Path: Q → page turn → key 1 → `DIM_SpellPlacementMode`. The preview was green at a spot 1.5 m from the chosen one (spread 0.0). Then LMB (Released).
  - **The game then plays the cast animation in `DIM_SpellcastingMode`, and runes (Earth −10, Astral −10) are spent only after more than 4 s.** `cast` now waits up to 12 s while a spell input mode is open.
  - The result was `BP_Magic_SummonShelter_C_2147450308`.
  - The earlier attempts' preview tags: `UI.Notification.SpellPlacement.GroundNotFlatEnough` (trace spread ≥ 0.52 m over 3 m was rejected) and `UI.Notification.SpellPlacement.Blocked`.
- **`LastCastTimeBySpellData` uses the client's own world clock.** It read 1503.27 for Summon Shelter about 25 min after the client joined (`UGameplayStatics::GetTimeSeconds`). `GetServerWorldTimeSeconds` read 58000+ at the same time.
- **`PlayerUtilityMagicComponent.OurSpellActors` reads empty on the client** even with Claude's shelter standing (not replicated). `cast` matches the new `UtilitySpell` actor nearest its preview point instead.
- **Summoned shelter (client reads):**
  - One `InteractionComponent` ("Interaction", a SceneComponent) sits at the actor origin at ground level inside the tent.
  - Prompt: "Sleep" at night, "Rest" in daytime. Bed `LeaveActionText` is "Leave Bed"; `bRequiresClaimingToSleepIn` false.
  - Actor forward (-1, 0, 0) is the entrance side.
  - Approaching the actor origin walked Claude onto the roof (z +4 m), and the detector targeted nothing. Approach the entrance (origin + forward × about 1.5 m) and face the component instead.

## Capability contract + interact engine on the client (R2) (2026-10-25, 19:35-21:10 UTC, client build 26162923, Shockbyte world)
- **The interact "timeout" at 19:25 was a tooling foot-gun**, not a body bug. The `interact` cmd was in `client_io/bridge/brain_to_body.jsonl`: the SERVER body's file name. `tools/bridge_cmd.py` defaulted to `--body server` while DW_BRIDGE_DIR pointed at the client dir, so nobody read it. bridge_cmd now defaults to client and refuses a directory where that body never answered.
- **Summoned shelter geometry (live read, `client_mod/commands/skills_detector.lua`, read-only), BP_Magic_SummonShelter_C_2147461184:**
  - actor origin (398.89, 1746.96, -42.29); `GetActorForwardVector` (-0.996, 0.088);
  - `Interaction` (the InteractionComponent) sits AT the origin;
  - `InteractionCollider` sits at the ENTRANCE, (397.32, 1747.08, -41.0), 1.6 m out along forward;
  - `Bed` is valid (a component with no location).
  - Walking to the actor origin puts him on the roof (the 20:46 photo).
- **Sleeping in a shelter works through the real path (verified 20:57:40-47):**
  - the interact engine stood 1.5 m out from the collider along forward, faced the collider, the game's detector targeted the shelter with prompt "Sleep", and one IA_Interact press was made;
  - result `changed: "sleeping"`: PlayerRestComponent `CurrentRestingAreaActor` = the shelter, `CurrentRestingAreaComponent` = Bed, CharacterMovement `MovementMode` 0 (None), `IsSleeping` false afterwards;
  - Luis: "now its day" (the night passed).
- **Getting up = one plain IA_Interact press while resting** (verified 20:59:5x). The detector targets nothing while he lies there. After the press, MovementMode is 1 and the resting area is cleared; a straight go_to then walked him out of the entrance.
  - Movement input alone does nothing while resting: move.lua reported "walls everywhere" / self-stuck.
  - Movement tools now answer `resting` at once.
- **In-game clock reads on the client:** `UInGameTimeFunctionLibrary.IsNighttime(pawn)` / `GetInGameTime(pawn).Ticks / 3.6e10` returned hour 15.7 at 20:48 and 5.7 at 20:59, across a slept night. `PlayerRestComponent:IsInTimeframeForSleep()` read false (day). The hour formula is UNVERIFIED against the in-game clock UI.
- **Crash 21:49:34 (UTC+1 dump name; 20:49:34 UTC):** UE4SS `push_arrayproperty` right after move.lua's pause-menu Unstuck (teleport) fired twice while he stood on the tent roof.
  - The interact engine now always passes `allow_unstuck = false`.
  - sense/inventory/bridge array reads check the owner's IsValid in the same tick, and do nothing under DW_PAUSE.
- **Vitals damage hooks registered at the main menu never delivered a damage row:** rows exist only from the 17:53 in-world start, none after the 19:29/19:33/19:38 boot-time starts, despite a 36 HP hit at 19:43:53. The supervisor now re-registers them once `hooked_pawn` differs from the current pawn. This is a hypothesis fix, UNVERIFIED until a damage row appears after a boot.
- **Who dropped a world item:** `AWorldItem.NameOfPlayerCharacterThatDroppedItem` (FString), also `GuidOfPlayerCharacterThatDroppedItem` (reflection dump 26161880). It is read into census rows as `dropped_by`, UNVERIFIED live.
- **Collect-all exists in game data:** `UItemDeveloperSettings.CollectAllRadius` / `bCollectAllCollectsOnlySameType`, and `PlayerInteractionManager.SecondaryInteractAction` + `UInteractionComponent.SecondaryInteractionPrompt`. `interact {secondary=true}` presses the secondary action, UNVERIFIED live.
- **Real-model eval of the manifest tool list** (`evals/manifest_eval.py`, claude-haiku-5-5, 11 cases, **11 model calls**, 21:46 local; logs/evals/manifest_eval_20261025-214600.json): 9 PASS, 1 PARTIAL, 1 FAIL.
  - Pass: grave → interact(grave id); drink (hotbar) → consume; drink (on the ground) → interact + consume; "grab those" and "food and water in front of me" → interact on both dropped stacks; "give me the logs" → go_to(Zezima) + drop(Ash Logs); "come to me" → go_to; platebody → equip; bag food → move_item + consume.
  - Partial (fight prep at 29 % food): attacked without eating.
  - Fail (38 % HP after a fight): it asked "want me to eat some meat to heal?" instead of acting.
  - Both are judgement calls, left to the model and the vitals policy.
  - Speech was null on every action response: the model returned tool calls without text.
- **Spell special requirements (L1, live read 20:05 UTC+1):**
  - `UDominionSpellData.SpecialRequirementsStrategy` (TSubclassOf) → its default object (`cls:GetCDO()`) → `AreSpecialRequirementsMet(local PC)` (BlueprintNativeEvent, const) returns an FGameplayTag read as a Lua table with `TagName`, "None" when met. It was safe on all 14 classes Claude has.
  - Live tags: `UI.ConsumeItem.RequiresHeldMeleeWeapon` (enchants), `Item.Requirement.50uWater` (Humidify), `Item.Requirement.Compost` (Mucksplosion), `UI.ConsumeItem.RequiresHeldRangedWeapon` (Spectral Arrows), `UI.ConsumeItem.RequiresClaimedBed` (Home Teleport), `Item.Requirement.HeldFishingRod` (Infernal Rod).
  - The texts come from `SpecialRequirementsText`.
- **Keyless wheel slots (9–12):**
  - Injecting `IA_SpellsMenu_SelectSlot` (the Axis2D stick) does nothing to the radial: CachedSectionId stayed 0 in 12 directions.
  - The radial's own BlueprintCallable `HighlightSlice(9)` does set CachedSectionId 9 and SpellName "Enchant Weapon: Air", and it holds over later frames. The radial's `OffsetDegree` is 15 and `RadialMenuStickinessType` is 1.
  - So `cast` highlights the slot, checks that the name equals the requested spell, then presses `IA_SpellsMenu_AcceptSelection`.
- **Placement preview, live tags:** `UI.Notification.SpellPlacement.NoTarget.RequiresLog` (Splinter aimed off the log), `…GroundNotFlatEnough`, `…Blocked`.
  - **A splittable log's actor origin is stale.** Aim at `ATreeLog::GetMidPointWorldLocation` (here 7 m from the origin), and the preview turns valid at once.
  - **Splinter on a log, verified live:** `BP_Magic_Splinter_C` spawns at the preview, Earth −10 and Nature −5 are spent, and the log splits into "Ash Logs" world items.
  - After a placed cast the game may stay in `DIM_SpellcastingMode` for a moment. Don't press Esc then.
- **The bridge clock `api.now()` is `os.time`, in 1 s steps.** Sub-second waits in `spells.lua` use `UGameplayStatics::GetTimeSeconds`.
- **Spell demo, live (21:27–21:35 UTC, debug channel, arbiter idle before each cast):**
  - **Windstep** (index 35 = page 3, slot 12, keyless):
    - Presses: menu, next_page ×2, highlight + **accept**, place.
    - Air −5, cooldown started, `DominionStatusEffect` and tag `Player.Spell.WindStep` on the pawn.
    - **Jump apex 1.80 m → 7.38 m** (`smoke_jump.lua` before and after).
    - So the HighlightSlice + name check + Accept path is verified live.
  - **Tempest Shield** (page 1, key 8; the wheel opened on page 3 and wrapped round): Air −15, cooldown started, `BP_TempestShieldGameplayEffectInstance_C` replicated instance and tag `Player.Status.TempestShield`.
  - **Phase Dash** (page 4, key 1; the wheel remembers its last page): Astral −10, Air −20, cooldown started, no GE or tag (a Blueprint module plus ExpireAfterDuration).
    - Effect measured with `client_mod/commands/air_dash_test.lua` (jump, then one `IA_Player_Evade` press while falling).
    - Without the spell: 3.2 m peak horizontal, then the server **snapped him back to the start** (0 m net).
    - Right after casting: **8.4 m dash, kept**.
  - **Runes survive death.** Claude starved at 21:25:56. The hotbar and bag went to the gravestone, but the rune page stayed (Air 6589 …).

### Ranged aim: crossbows, bows and projectile spells (from the dump, build 26161880; NOT yet read live). Design: docs/design/ranged-aim.md
- **Flight parameters:** `URangedAmmoData.ProjectileData` (`FProjectileData`: `LaunchSpeed`, `OverrideGravityZ`, **`TimeWithoutGravity`** (a straight segment first), `MaxSimulationTime`, `LookAhead`). The equipped ammo comes from `PlayerRangedAttackComponent:GetEquippedRangedAmmoDataForCurrentWeapon()`. Charge: `PlayerRangedAttackCollection.LaunchSpeedCurve` / `OverrideGravityZCurve` (UCurveFloat by charge), `MaxChargeUpDuration`, `TimeBeforeFullAccuracy`.
- **Accuracy:** `BaseInaccuracy`, `GetCurrentArrowInaccuracy()`, `HasReachedFullAccuracy`, `IsAimModeActive()`, `HasRequiredAmmoEquipped()`. The aim is a camera trace (`AimOffsetTraceChannel`, `MaxProjectileTraceDistance`). The shot leaves the weapon actor's `ProjectileSocketName` (`AHeldRangedEquipmentActor`, `OwnedProjectiles`, `LoadedProjectile`).
- **Fired projectile:** `ADominionProjectile` (replicated `LaunchInfo {StartPosition, StartDirection, LaunchSpeed, OverrideGravityZ, LaunchTime}`, `ParentEquipmentActor`, `Multicast_OnProjectileHit`). Spell projectiles: `ADominionSpellProjectile.ProjectileMovement` (`InitialSpeed`, `ProjectileGravityScale`).
- **Catalog:** Adamant Crossbow primary "Shoot", special "Heavy Bolt" (32 damage, 50 charge), reload 2.0 s, ammo `CrossbowBolts`, projectile class `BP_Arrow_Base_C`. Crossbow `max_charge_up` 0.75 s; bow 1.55 s.
- **Engine helpers reflected:** `UGameplayStatics:BlueprintSuggestProjectileVelocity`, `SuggestProjectileVelocity_CustomArc`, `SuggestProjectileVelocity_MovingTarget`, `Blueprint_PredictProjectilePath_ByTraceChannel`. Not used: no straight segment, no learned parameters.
- **Built offline** (`client_mod/scripts/ranged.lua`, combat ranged engage; 29 + 8 checks):
  - The solver is a 1-D root search on flight time with lead and the straight segment.
  - The camera is aimed so its ray passes through `muzzle + dir·50 m`.
  - Firing: hold aim, wait for full accuracy, fire, reload.
  - Each real bolt is fitted (speed, gravity, straight time); learning keeps a capped pitch/yaw bias; hit/miss comes from our damage multicast.
  - Metrics by distance and target speed.
  - Fake-game result: 2 misses, then 5 hits, against a goblin strafing at 3 m/s at 20 m, starting from wrong seeds.

### Defensive abilities and telegraphs (2026-10-25, game data + offline; live proof owed). Design: docs/design/defense-abilities.md
- **Spell data (`data/spells_26161880.json`):**
  - **Phase Dash** `USD_PhaseDash`: Instant, 20 Air + 10 Astral, 45 s cooldown. Modules: PlayMontage, CostItems, Cast, Blueprint, `ExpireAfterDuration` 2 s, so it opens a 2 s window in which the evade is the dash. Owning perk `PerkV2_Agility_Spell_PhaseDash` (wiki: Agility 44).
  - **Windstep** `USD_Windstep`: Instant, 5 Air, 3 s cooldown, applies `GE_Windstep`. Its Wind Stomp landing (with `PerkV2_Agility_Spell_Windstep_Upgrade`) is a 700 cm, force-1000 stagger.
  - **Tempest Shield** `USD_TempestShield`: Instant, 15 Air, 45 s cooldown, `GE_TempestShield` (upgraded with `PerkV2_Attack_TempestShield`).
- **Readable at the AI attack telegraph** (`AiAttackComponent.CurrentAttack.AttackData`): damage times, montage and `GetPlayLength`, `MaximumRootMotionScaling`, `bLeaveNavMesh`, `NextAttack` (combo), flags (Special 4, ComboFinisher 8, ForceBlast 16). combat.lua now records all of these. The lunge distance and the attack's damage are learned per attack key.
- **The spells module's cast refuses while fighting** ("I can't cast while I'm fighting yet"), and its wheel route takes about 0.5-1.5 s. Combat needs `spells.ability_status` / `spells.cast_now` (contract in the design doc). Until then the abilities are reported unavailable.
- **Pre-casting (offline, 2026-10-25):** the spells contract is live (`ability_status` / `cast_now`, latency 0.7–2.05 s; Phase Dash 2.05 s). Combat now has a per-frame cast manager, learns each creature's attack rhythm, pre-casts Phase Dash so its 2 s window covers the next expected impact (one dash per cast, so used up by the dash) and Tempest Shield against dangerous attackers. Pre-cast and reactive answers are learned as separate bandit arms. Offline: a lunge every 3 s with a 1.6 s wind-up is dashed through after 3 hits (8 seeds stable). Live: still owed.

## Benchmark observer probe on the dev world (2026-10-25 ~22:47 UTC, client build 26162923, dev server 127.0.0.1:7777, character ClaudeDev; Eval agent)
- **What:** `client_mod/commands/bench_probe.lua` (read-only; uses only `mod/body/util.lua`) run through the DWClient command runner (`tools.scenario_run.run_client_cmd`). The client had joined the LOCAL dev server: game log `UPendingNetGame::SendInitialJoin ... RemoteAddr: 127.0.0.1:7777` and `LoadMap: 127.0.0.1/Game/Maps/World/L_World?...` (22:32 UTC). No live brain was running.
- **Result (0.5 s round trip, twice):** `ok`; the reads that work on the client pawn:
  - `GameplayStatics:GetTimeSeconds(pawn)` client world clock (864.98 s, then 877.44 s);
  - position `K2_GetActorLocation` (62.6, 1881.5, -35.4 m: the church start area);
  - health `HealthComponent:GetAuthoritativeHealth()` = 100, max `HealthComponent:GetMaxHealth()` = 100 (the property `HealthComponent.MaxHealth` reads **0.0**: don't use it);
  - vitals `SustenanceComponent:GetCurrentSustenance()` 30.8, `HydrationComponent:GetCurrentHydration()` 24.8;
  - inventory `pc.InventoryComponent.ItemSlots` -> {ITEM_Torch: 1} (a fresh character);
  - skills `pc.SkillComponent.Skills[].SkillData` + `GetSkillLevel` + `CurrentXP`: all 12 skills of the game data present by display name (Agility, Artisan, Attack, Construction, Cooking, Farming, Fishing, Magic, Mining, Ranged, Runecrafting, Woodcutting), level 1, xp 0;
  - GE instances, gameplay tags, `LastCastTimeBySpellData` and UtilitySpell actors: empty (nothing cast yet). An empty Lua table JSON-encodes as `[]`: the Python side normalises `cooldowns` to a dict.
- **Not read by probe v1 (they evaluate null, never pass):** held-item effects, ground items, creatures, other players' inventories. Those come from the dev referee (server side) once it is verified.
- **Build note:** the client and dev server report build **26162923**, while the data catalogs (`data/*_26161880.json`) were generated at 26161880. RUNBOOK-patch says to regenerate the catalogs after a patch. The benchmark's `game_build` is read from the catalogs, so a regeneration re-opens validity (by design).

## Benchmark referee + fixtures on the dev server (2026-10-25 22:50-23:00 UTC, server build 26161880 / Net CL 254097, DW_SERVER_ROLE=dev, ClaudeDev; Eval agent)
- **Entry:** `debug_run {"module":"bench","args":{"part":"referee"|"fixtures",...}}` (`mod/scripts/bench.lua` loads `mod/bench/*.lua` from the deployed mod root). Both parts refuse unless `DW_SERVER_ROLE=dev`.
- **Referee probe (read-only):** players from `FindAllOf("BP_PlayerCharacter_C")` with `PlayerState:GetPlayerName()` = "ClaudeDev", health 100, server `pc.InventoryComponent.ItemSlots` readable. Character GUID read as `U.guid_hex(ps.OwnerGuid.CharacterGuid.InnerGuid)` = `E71C5DC146F0A55B69FF52A881255DEF`. **Creature base class `BP_DominionAICharacter_C`** (`FindAllOf` returns subclasses): 8 `BP_AI_Kebbit_Character_02_C` (30 HP) and 4 `BP_AI_Magpie_Character_C` near the start area.
- **Referee polling (250 ms, LoopInGameThreadWithDelay, verified):**
  - `item_change` from the server inventory: torch drop -1 (client `drop`), pick-up +1 (client `interact` "Collect"), Coarse Animal Fur +1 (kebbit loot).
  - `damage` from creature health deltas: 8, 8, 8, 6 = 30 HP.
  - `death` with `kind_id = BP_AI_Kebbit_Character_02_C`.
  - Not covered by polling: damage type and attacker (polling can't see either), parry/dodge, projectiles, teleport (untested).
- **Fixture spawn (verified):** `World:SpawnActor(<class of a live BP_AI_Kebbit_Character_02_C instance via GetClass()>, pawn location + 4 m)` spawned a working kebbit on the server. It replicated to the client (`look` saw it at 4.03 m, 30 HP, alive), and Claude killed it with the real client attack path. No crash.
- **UDominionCheatManager (the game's dom* cheats) is reflected but INERT in this shipping build:**
  - The class is loaded (`/Script/Dominion.Default__DominionCheatManager`).
  - The PC has no `CheatManager`, and `pc:EnableCheats()` is a no-op.
  - `StaticConstructObject(DominionCheatManager, pc)` assigned to `pc.CheatManager` works.
  - But `domAddItem("ITEM_Resources_Stone", 3, 100)` added nothing, and `domModifySustenance(20)` left sustenance at 9.0. The cheat bodies are compiled out, so fixtures can't use them.
- **ClaudeDev survival:** server reads hydration **0.0**, sustenance 9.0 at 22:59 UTC (fresh character, no drinks).

## Client crash 2026-10-25 22:31:35 UTC after a disconnect (BUGS L24) + the game log that stopped at 22:04 (client build 26162923; read-only cdb)
- **Dump** `ue4ss\crash_2026_10_25_23_31_35.6102217.dmp`, `.ecxr; kn`: access violation `mov rax,[rcx]` with rcx = 0x250 (a null object + 0x250) in game code. Below it, two nested `UE4SS!...+0xcc7` frames separated by game frames, then the game-thread tick and the ProcessEvent path (`UE4SS+0x675`). No Lua frames.
  - "StartCallbackGarbageCollector" is only the nearest exported symbol. The installed UE4SS v3.0.1 release has no PDB, and the zDEV v3.0.1 build is a different binary (hash differs), so its PDB doesn't apply.
  - The +0xcc7 frames are UE4SS's native-hook trampolines: one for each RegisterHook'd UFunction in the call chain, calling the original.
- **What preceded it (logs/client/client.log, UE4SS.log):**
  - join_server 22:31:22, then disconnect 22:31:34;
  - two pause→re-arm cycles (22:25:03, 22:29:33). The vitals re-arm called UnregisterHook and then RegisterHook again on Multicast_ApplyDamage* / OnRep_*. In the UE4SS log only ONE of the four unregisters actually logged.
  - combat.lua hooked the same Multicast_* functions a second time.
  - UE4SS issue #484 reports UnregisterHook crashing games, depending on the hooked function, in v3.0.1 builds.
- **Decision (hookhub.lua):** one native post-hook per UFunction per process, never unregistered. Handlers are swapped in Lua; callbacks return before touching anything while DW_PAUSE is set; registration waits until a pawn is out of the front end. The ChatWidget UI hooks are dropped: they only counted, and widgets are the first thing torn down.
  - This fix is a reasoned inference, UNVERIFIED until repeated join/disconnect cycles on the dev world stay up.
- **The vitals re-arm (2026-10-25 evening) did deliver damage rows:** vitals.jsonl has 486 damage rows through 22:16. So hooks registered once in the world work. The hub keeps that property without re-registering.
- **The game log (RSDragonwilds.log) stopped at 22:04:11 UTC** in a session that ran until the 22:31 crash. Its backup file (`RSDragonwilds-backup-2026.10.25-22.04.11.log`, 2.9 MB) holds **27,162 lines of `LogPhysics: Warning: COLLISION PROFILE [Custom] is not found`** from 21:33 on.
  - Source: `move.lua` `raw_trace` traces with `LineTraceSingleByProfile(capsule:GetCollisionProfileName())`. On Claude's capsule the name is "Custom" (per-component collision, not a named profile), so EVERY trace warns and returns no hit.
  - Why the file stopped is UNPROVEN: the engine kept running (client.log continues), and the trace spam is the obvious anomaly.
  - Suggested fix for move.lua's owner: treat "Custom" (or any name the profile table lacks) as invalid, and trace by the capsule's object channel (ECC_Pawn) or fall back to the Visibility trace.
- **Server-side grant WORKS (verified 2026-10-25 23:0x UTC):**
  - The call is `pc.InventoryComponent:AddItemByData(ItemData, Count, 100.0, tags)`, where `ItemData = StaticFindObject(<catalog asset path>)` and `tags` is a COPY of a live, empty `FGameplayTagContainer` (`UItem.GameplayTags` of an item already in that inventory: the torch's `HeldEquipmentItem`). No struct is built in Lua (CLAUDE.md principle 4).
  - Stone 0 → 1, Air Rune 0 → 20; both replicated to the client (`bench_probe` inventory). No crash.
  - The game's `domAddItem` cheat is inert, so this is the fixture route (`mod/bench/fixtures.lua` verbs `grant` / `grant_runes`).
  - Limitation: it needs at least one item with empty tags already in the inventory.
- **Server-side spell unlock WORKS:** `pc.ProgressComponent:UnlockSpells({<UtilitySpellData object>})`, with a Lua array of a `StaticFindObject`'d `USD_Windstep`. The client's `spells` tool went from 0 unlocked to 1 (Windstep, castable). Fixture verb `unlock`.
- **Dev positive control (T0 Windstep) PASSED, judged by the harness probe:**
  - Claude's real `cast` (wheel: menu, quick0, place) spent Air 20 → 15 and set `LastCastTimeBySpellData` `USD_Windstep = 699.29`.
  - The tag `Player.Spell.WindStep` appeared on the pawn; GEs `DominionStatusEffect` and `HydrationDamageGameplayEffect` (the second is thirst, not the spell).
  - The cast reply agrees with the probe (no `sensor_mismatch`), so `spell_effect` passes on the specific tag. The base GE class is rejected as generic evidence.
- **A/B result (2026-10-25 23:16–23:30 UTC, dev world; driver `ab_cycles.ps1`: disconnect.lua → 12 s → client_boot -Target dev → 25 s):** every arm crashed on the **3rd** disconnect, right after `LoadMap(/Game/Maps/L_FrontEnd)` completed, with the identical AV (null + 0x250 in game code).
  - **hooks ON:** main's run at 23:04.
  - **hooks OFF:** the hookhub flag `client_io/state/hooks_off.flag` was set, and hookhub_status showed 0 native hooks. Crash dump crash_2026_10_26_00_19_49.
  - **UE4SS engine hooks OFF:** HookProcessInternal, HookProcessLocalScriptFunction, HookInitGameState, HookLoadMap, HookCallFunctionByNameWithArguments, HookBeginPlay, HookEndPlay, HookLocalPlayerExec, HookAActorTick, HookGameViewportClientTick and HookProcessConsoleExec were set to 0. Crash dump crash_2026_10_26_00_29_48.
    - In this arm the two `UE4SS+0xcc7` frames vanished from the stack. They were UE4SS's ProcessInternal/ProcessLocalScriptFunction detours: blueprint execution passing through, not a cause.
    - The ini was restored from `UE4SS-settings.ini.bak-20261026-L24` afterwards.
  - So it is a **game-side crash on the 3rd front-end return within one client process**: blueprint UI code dereferences a null object.
  - Each front-end load also logs `UMainMenuUIAPI::MainMenuWidget Called but a MainMenuWidget is already registered!`, so a menu widget is apparently re-registered every visit.
  - The 19:08 and 21:49 crashes are different: both are Lua-side (a UFunction call and a TArray read during teardown).
- **Probe v2 (client, read-only, verified live 2026-10-26 ~00:2x UTC on ClaudeDev):**
  - gear from `pawn.PlayerEquipmentComponent`: `CurrentBody/Legs/Head/CapeWearable` give `ITEM_Armour_T1_Body_Adventurers` and `ITEM_Armour_T1_Legs_Adventurers`; held items from `GetHeldEquipmentDataRight/Left()`;
  - held effects from `HeldEquipmentActorRight.Magical/PhysicalHeldEquipmentEffectInfo.EffectData` (empty: nothing held);
  - quests from `pc.QuestProgressComponent.Quests[]` (`Data` asset, display name, `State` EQuestState 0 Ungiven / 1 Given / 2 Complete, `CurrentObjective`). Example: First Steps (`Quest_FTUE_GS`) state 1 at Objective1; Dragon Slayer, Withering Heights and Black Knight Fortress state 0;
  - creatures from `FindAllOf("BP_DominionAICharacter_C")` within 40 m (3 seen);
  - world items from `FindAllOf("BP_RuntimeSpawnedWorldItem_C")` (`ItemData`, `GetStackSize()`);
  - other players: none.
- **Fixture `set_health` (verified):** `HealthComponent:SetHealth(80, "bench_fixture")` read back 80 server-side. It replicated (the client probe saw 66 seconds later, after starvation damage).
- **Fixture `teleport` (verified):** `pawn:K2_TeleportTo({X,Y,Z},{Pitch,Yaw,Roll})` returned true and moved ClaudeDev 5 m server-side; the client probe read the new position.
  - The earlier attempts returned false while he was at 1 HP and starving, so a near-dead pawn refuses to teleport.
- **Referee hooks (dev server, verified 2026-10-25 23:39–23:42 UTC with a spawned kebbit and Claude's real attack):**
  - **Doesn't work: `DamageComponent:BP_OnDamageReceived` never fires.** It isn't called through ProcessEvent. `FDominionPointDamageEvent` also has no Target field.
  - **Works: `PlayerMeleeAttackComponent:Multicast_SendDamageCacheData(TArray<FTimedDamageInfo>)`.** The component owner is the attacking player. Each `DamageInfo.DamagedActors[].PointDamageEvent` gives `Amount` (15.0), `TypeDamagesArray[].Types` (`DamageType.Physical.Slash`), `TypeDamagesOutcome` ([0] = neutral), `AttackId`, `bIsFatalHit` and `VictimLocation`; the victim is the actor nearest that point. The result is `damage {by: self, damage_type, ...}`, and a fatal hit gives `death {by: self}`.
  - **Works: `AiAttackComponent:Multicast_PerformAttackOnSimulatedProxies(AttackClassId=365, AttackId)`.** This is the telegraph: the kebbit's attacks on Claude, AttackIds 1..10.
  - **Works: `AiAttackComponent:Multicast_SendDamageCacheData(FAiAttackOutcome)`.** It gives damage BY the creature (`by: BP_AI_Kebbit_Character_02_C`, 7.0 Slash to self).
  - **Registered, not yet seen firing:** `PlayerBlockingComponent:Multicast_NotifyActorsToDamagePendingParried/BlockedAttack` (parry/block). For dodge, the pawn's `InvulnerableEvadeTag` is checked at the AI outcome (not yet seen).
  - **Hook callbacks dispatch** through `_G.__dw_bench_ref_dispatch`, so a redeployed referee.lua takes effect without re-hooking. RegisterHook can't be undone, and the v1 callbacks are silenced by a state flag.

## Foliage ids go stale when he walks up to a tree (BUGS L26; client build 26162923; offline fix 2026-10-26)
- **Observed** (dev run T0, debug channel lines 250-263): `go_to fol:BP_InteractableFoliageISMC_Tree_C_12:59` arrived 1.4 m from the Ash Tree, and then the same id resolved to nothing.
- **Cause:** the server's `NearbyFoliageConverterComponent` (Range 300 cm) converts the instance into its `ActorClass` actor (e.g. `BP_BM_Tree_Ash_03_C_2147454756`) and hides the instance (instance scale 0). gather.lua logs the same "adopted <actor> (was fol:...)" on every approach (client.log 2026-10-25 20:01, 20:03, 21:05, 21:16).
- **Also:** an instance index is not an identity (ISM/HISM RemoveInstance swap-removes), and a foliage component's name repeats per World Partition cell.
- **Decision:** a foliage id is `fol:<ActorClass>@<x>,<y>,<z>` (decimetres). `sense.resolve_foliage` maps it to:
  - the same instance;
  - the nearest same-class instance within 1 m (reindexed);
  - the converted actor of that class within 2 m (converted);
  - or reports felled_or_picked / not_found.
- All id-taking tools resolve through it (`client_bridge.lua` find_thing). See `docs/design/stable-target-ids.md`.
- **Cast settle, verified live (dev world, 2026-10-26 07:1x UTC):** Summon Shelter at (89, 1882):
  - Timeline: preview valid → LMB → the `BP_Magic_SummonShelter_C` actor 0.4 s later → the rune spend and the `LastCastTimeBySpellData` change about 6 s later.
  - So the actor replicates first and the spend and cooldown last. A cast reply must wait for both (L25).
  - Near the dev spawn lodestone (at 13–25 m from it) every shelter preview said `UI.Notification.SpellPlacement.Blocked`, even on flat ground; 40 m away it was accepted. Probably a no-build radius around lodestones (not confirmed in the data).
- **Referee v1.2 hooks REGISTERED on dev (2026-10-26 ~07:10 UTC; not yet seen firing).** Client→server RPC post-hooks for Luis's redefined long tasks: `InventoryController:Server_MoveItemBetweenInventories` / `Server_SplitAndPutStack` / `Server_MoveAllItemsBetweenInventories` (container deposits; "his" container = absent at referee start), `InventoryController:Server_CraftRecipe` (craft), `BuildModeComponent:Server_SpawnBuilding` (built), `FarmCommandComponent:Server_TryPlantSeed` / `Server_TryHarvestPlot` (planted / harvested). Live verification waits for a container, a station and plots on dev. Building needs the body build tool (capability agent).

## Build probes P1a/P1b (2026-10-26, dev world, client build 26162923; read-only, `client_mod/commands/build_probe_p1a.lua` / `build_probe_p1b.lua`)
- **Owners exist on the PC:** `BuildModeComponent` (bUseNewComponent=true, CurrentBuildMode 0=None, Prev 1, SnappingMode 0=Basic), `BuildPlacementComponent`, `BuildInteractionComponent`, `BuildValidationComponent`. The input mode was `DIM_Gameplay`; the spells agent reports Oculus is another build-like mode, `DIM_OculusBuildMenu`.
- **Actions** (read from the component, not asset paths):
  - `CancelAction` = IA_Building_Cancel, `ModifyRotationAction` = IA_Building_RotateZ, `GhostModifierAction` = IA_Building_GhostPiece_Modifier;
  - `BuildingMappingContext` = IMC_BuildingGeneral;
  - BuildInteractionComponent `InteractAction` = IA_Interact, `QuickInteractAction` = IA_Building_QuickInteract.
- **Limits:**
  - placement: `MaxPlacementDistance` = `SelectionMaxPlacementDistance` = 700 cm, `MaxDistanceModifier` 350, `MaxHeightModifier` 300;
  - interaction: `MinTimeBetweenBuildingPlacementRequests` = 0.25 s, `DetectionRange` 1500;
  - settings CDO: `ModifyRotationStepDeg` = 15, height step 0.05, distance step 0.4, `MaxNumPieces` 8192;
  - `PieceTagToMaxCountMap` = {BaseBuilding.PieceType.Prop.ProtectionTotem: 8}; `TagsToCountsMap` on the client = {} (empty: the counter does not replicate, or there is nothing here).
- **Catalogue:** `BuildPieceCatalogue` is loaded (`DA_BuildPieceCatalogue_Default`).
- **MPC:** `MPC_BuildingPieceGhost`, with params `PlacingValidityStateIndex` and `CursorWorldPosition`.
- **`ValiditySpawnStateToScalarIndex` is NOT one-to-one:**

  | Scalar | States |
  |---|---|
  | 2 | Valid (0), NeedsSnapping (4) |
  | 1 | Overlapping, Floating, NeedsFoundation, Unstable, MissingMaterials, InsideVault, InsideProtectedArea, ReachedCountLimit, InsideBlockedRegion |
  | 0 | WrongPhysicalSurface (7), None (13) |

  ShelterCheckFailed (11) is absent. **So the MPC scalar cannot tell Valid from NeedsSnapping, or WrongPhysicalSurface from None.** It is a colour index, not the state. The exact state needs the `OnValidityStateChange` / `OnValiditySpawnStateChanged` post-hook, or another property (P4).
- **The game's own words** (`BuildInteractionComponent.ValidityNotificationTextMap`):

  | State | Text |
  |---|---|
  | 1 Overlapping | "Blocked" |
  | 2 Floating | "You can't place this in the air." |
  | 3 NeedsFoundation | "You need a foundation to build this." |
  | 5 Unstable | "Unstable" |
  | 6 MissingMaterials | "You require more materials to build this." |
  | 7 WrongPhysicalSurface | "You can't build here" |
  | 8 InsideVault | "You can't build here" |
  | 9 InsideProtectedArea | "Only the Host can build here." |
  | 10 ReachedCountLimit | "Placement limit reached for this piece." |
  | 11 ShelterCheckFailed | "You can only place this outside" |
  | 12 InsideBlockedRegion | "Cannot be placed in this region" |

  There is no text for 0 or 4.
- **Privileges** (`PlayerState.PrivilegeComponent:HasPrivilege`): Build=true, OpenChests=true, Chat=true, Owner=false.
- **Unlocks:** `ProgressComponent.BuildingsUnlocked` holds 42 entries **with duplicates** (the 16 Deluxe Edition decorations appear twice), 26 unique. Useful ones:
  - `BUILDPIECE_CraftingStation_Basic` "Crafting Table" (4 Ash Logs, 20 xp, idx 433);
  - `BUILDPIECE_Campfire` "Campfire" (6 Stone, 20 xp, idx 26, `ShelterRequirementText` "Must Be Exposed");
  - `BUILDPIECE_Interior_BedRoll` "Bedroll" (20 xp);
  - `DA_BaseBuilding_Building_Protection_Totem` (**bOnlyAvailableToHost = true**, 0 xp);
  - decorations (1 xp).

  `bFarmingUnlocked` = false. `Category` reads "None" on Campfire and Crafting Table. Requirements read cleanly as `TArray<FResourceRequirement>` via `ForEach` + `:get()`. **No chest, no farm plot, no rune altar is unlocked on dev.** Unlocks come from item/actor discoveries (DISCOVERIES crafting).
- **`HUDUISubsystem.BuildingAPI` exists headless:** 1 `BuildingUIAPI` object. `GlobalBuildingManager`: 1, with a `CounterComponent`.

### Dev-world combat diagnosis (2026-10-26, from logs; docs/design/combat-basics-live.md)
- **Server evidence (dev server log, category `EvadeAttack` Verbose):** `TryPerformAttack ... starting attack on authority against player`, `PredictPointDamage ... will receive D damage` / **`evaded 0.000000 damage`** (a successful dodge), `DomNetActIntIds: AUTH : Action Accepted : START : Evade|Block`, `DominionBlockComponent AuthorityApplyBlocking : BlockDelay [0.117] for REMOTE player`.
- **Client:**
  - The AI attack multicast arrives about 40 ms after the server starts the attack.
  - `Multicast_SendDamageCacheData` ("received damage event on client") arrives at the impact: Kebbit +1.30 s; its data says 1.35 s.
  - No `DamageComponent` damage multicast reached the client for the Kebbit's hits; only HP polls showed −7.
  - Client log: `Player_AckRequestStartBlocking: BlockTime = Now + ~0.10`.
- **Results:**
  - 22:56, 3/3 dodges evaded (server-verified).
  - 23:39, 8/8 hits landed through "blocks": a stale `DIM_OculusBuildMenu` input mode delayed the input, and the blocks arrived inside the server BlockDelay.
- **ClaudeDev:** total level 12 (Attack 1), so `PerkV2_Attack_Parry` (Attack 5) and the specials (Attack 8) are locked.
- **The Stone Logging Axe's block action (`PA_Block_PickAxe`) cannot parry.**

### Dev-world combat live M1 (2026-10-26 07:55-08:21 UTC, client build 26162923, server build 26161880, ClaudeDev vs spawned Kebbits; combat agent; docs/design/combat-basics-live.md §4)
- **Equip check:** shield goes to the left hand; dagger to the right, actor `BP_Dagger_Bone_C`; the Stone Logging Axe (two-handed) shows in **HeldLeft**, actor `BP_Logging_Axe_Stone_C`. `unequip {slot = HeldRight}` was verified. `unequip {item}` through the bridge hit the bridge's own `R.unequip` route, not skills' verified `HANDLERS.unequip`.
- **Dodges (server `PredictPointDamage ... evaded`):** run 1 evaded 2/4 (both directions measured: left gives right_cm about -250, right about +200), run 5 evaded 23/24, run 7 evaded 10/14. Runs 2-4 had too few attacks, or he retreated when stamina ran low (max stamina 40). Fixed by `defence_reserve`, which keeps stamina for the next dodge, plus the learned swing cost.
- **Disengage + eat (orders `{defense="auto", disengage=true, heal_hp=0.5, reengage_hp=0.8}`, HP set to 40%), 3 passes:**
  - 08:0x: healed 33 -> 63 -> 93 and re-engaged.
  - 08:17: a telegraph arrived mid-disengage, so he defended, went back to the disengage, ate, and the heal 33 -> 63 was verified during the loot phase.
  - 08:20: healed 40 -> 63, then won.
  - **Bug found and fixed:** live at 08:11, a defence started from the disengage cleared `F.dis`, so the bite was never verified. Now the disengage survives a defence, and a pending bite is verified on every tick in any phase (test 11b).
  - On a Kebbit, the disengage usually ends with `enemy_closed_in`, because a chasing Kebbit keeps up.
- **First server-confirmed block:** `will receive 0.000000 damage` at 08:20 (the Tempest Shield follow-up). Tempest Shield was cast live through `spells.cast_now` (abilities `{tempest_shield: 1}`) in runs 1 and 3.
- **Reach underestimate:** a "none (out_of_reach)" plan was hit twice while retreating, because the Kebbit chases. `defense.feedback` now records `hit_from_cm`, and `threat.reach_cm` is at least that distance.
- **Parry perk:** `PerkV2_Attack_Parry` read as unlocked at 08:16 (total level 32).
- **Parry, k=3 passed (09:33-09:44 UTC, Bronze Shield in the left hand, right hand empty, orders `{defense="parry"}`, 4 Kebbits):** 4 of 4 Kebbit attacks were parried. Each has three pieces of evidence:
  - the client's `PlayerBlockingComponent:Multicast_NotifyActorsToDamagePendingParriedAttack` verdict (combat logs `defence parry -> parried`);
  - the server's `PredictPointDamage ... will receive 0.000000 damage`;
  - the server's block timing. The block was active (`START : Block` plus `BlockDelay` 0.116) **0.060 / 0.034 / 0.071 / 0.097 s before the impact**. The impact is the server `AUTH ATTACK : TELEGRAPH` line plus its `TimeUntilEvent`.
  - For comparison, the plain block at 08:20 went active 0.365 s early and was not a parry. So the parry window is at least about 0.10 s, and the press-time formula `T - 2L - block_delay - window/2` lands inside it.
  - The server logs no parry line of its own (no "parr" text anywhere). The scratchpad driver's `parry_evidence()` computes the lead from the lines above.
  - With the Bone Dagger in the right hand, a 30 HP Kebbit dies in 2 hits before it can attack, so the trials fought bare-handed with the shield.
  - `BP_AI_RuntGoblin_Character_C` is still `unknown_class` to the spawn fixture (not loaded on the dev world).
  - A Kebbit spawned 5 m in +X was behind a wall, so the approach was stuck until the fight timeout (the local plan reported `unreachable_in_window`). Spawning at -4 m worked.
- **Hit while looting (09:41):** a second Kebbit hit him 4 times (7 damage each) during the loot and restore phases, and nothing answered it. No damage multicast reaches the client for AI hits, so nothing recorded the Kebbit as an attacker. Fixed:
  - an HP drop within 0.8 s after a creature's `Multicast_SendDamageCacheData` impact event now records that creature as the attacker;
  - loot and restore check every 0.5 s for an `attacked_me` threat and fight back;
  - a commanded fight now also retargets a creature that is hitting him. Self-defence only; a target that is merely near is still not engaged.
  - Covered by offline test 11a. The live repeat could not reproduce it (the second Kebbit stayed passive).
- **False "hangs" (ops, not combat):** the client watchdog (pid 4228, started 2026-10-25 23:09 UTC) kept the **old** `Invoke-ClientCmd` in memory. That version writes `wd_boot_probe.lua` but never appends it to `client_io/cmd/queue.txt`; the queue runner went live at 07:41 UTC. So every watchdog probe timed out, and about 4 minutes after each boot it declared a hang and killed a healthy client: 08:04-08:08, 08:13:10 and 08:17:54, with `mod_log_age_s` 0-2 s. Evidence: no `ran wd_boot_probe` in client.log between boots, while `m1_*` commands ran. Fix: restart the watchdog (`tools/start_client_watchdog.ps1`) so it loads the current `client_lib.ps1`.

## Skills probe P1: fishing, agility, runecrafting actors (2026-10-26 ~08:45 UTC, dev world, client build 26162923, ClaudeDev; read-only `client_mod/commands/skills_probe_p1.lua`; design `docs/design/every-skill-coverage.md`)
**Fishing nodes.**
- 11 `FishingNodeV2` actors were in client relevance. Classes are `BP_FishingNodeV2_Net_Brynmoor_C` / `BP_FishingNodeV2_Rod_Brynmoor_C`; the nearest was 27 m from the spawn area.
- `DisplayNameText` reads "Net Fishing Spot" / "Rod Fishing Spot". `PowerLevel` is 2.
- `CompatibleToolCategory.TagName` is `Item.Equipment.Tool.Fishing.Net` / `...Fishing.Rod`. This is **identical to the item `Category` tag** of the nets and rods (items catalog `category_tag`), so tool ↔ spot matching by tag is verified.
- `IsDepleted()`, `IsBlocked()` and `IsInUse()` are callable from the client: all false here. They agree with `NodeState.bDepleted`.

**Pawn `FishingComponent`** (`BP_PlayerFishingComponentV2_C`).
- `Settings.TimeToFullyChargeRod` = 3.0 s and `RodCastLaunchAngle` = 30.
- `RodChargeFractionToProjectileSpeed` = `Curve_Float_RodChargeFractionToCastSpeed`. `GetFloatValue` is callable: 0 → 800, 0.5 → 1460.5, 1 → 1800.
- `RodFishingInputActions` are `IA_FishingMiniGame_MoveLeft`, `IA_FishingMiniGame_MoveRight`, `IA_Fishing_Reeling` and `IA_FishingMiniGame_Exit`.
- Idle `InternalState`: CurrentActivity 0, CastResult 4 (None), FishingResult 3 (None), SessionId 0, TimeOfLastActivityChange 0. These are all readable.
- `PlayerInputBufferInputActions.PrimaryAction` = `IA_PrimaryAction`.

**Agility.**
- `Default__AgilitySettings.WalkingXPEventTriggerDistance` = 602 (cm), event "Walking". Passive Agility XP is roughly one event per 6 m walked.
- No `AgilityCourseStarter`, `AgilityCourseManager` or `AgilityOrb` was within relevance of the spawn. Chasm Dash is NW of Bramblemead Valley (wiki).

**Runecrafting.**
- 3 `BP_AnimaVent_C` at 64–106 m. `HasAvailableCharges()` is true on all three; one has `IsConcentrated()` true.
- 5 `RuneEssenceGeyser` at 17–106 m (`BP_RuneEssenceGeyser_{B,C,J}_C`).
- No farm slots and no kebbit burrows in range.

## Benchmark: raise_skills route, server-log dodges, judge-side spell signals (2026-10-26 07:35-07:55 UTC, server build 26161880, DW_SERVER_ROLE=dev, ClaudeDev; Eval agent)

**Raising skills (fixture `raise_skills`, verified, QUICK variants only).**
- Route: on the server, `pawn.Controller.SkillComponent:AddXpFromEvent(SkillData.DamageXPEvent, "bench_fixture", Multiplier, true)`. The `FDataTableRowHandle` is read from the live `USkillData.DamageXPEvent` property; it is never built by hand.
- **The XP lands on a later tick.** A read of `SkillComponent.Skills[i].CurrentXP` in the same call shows no change. This is probably because of `SkillComponent.XPBatches`.
- Attack amounts: ×1 gave +1 XP and ×10 gave +8 XP (bIgnoreModifier = true), so about 0.8 XP per multiplier unit.
- `GetTotalXPNeededForLevel(L)` works. The fixture is therefore one step per call: add `(needed − current) × 1.15` units. The harness repeats it (up to 6 rounds, 1.5 s apart) until the level is ≥ the target.
- Verified: Attack 2 → 3 at 71 XP. Level 2 is reached at XP 33.
- **Side effect:** ClaudeDev's Attack went from level 1 at 32 XP to level 3 at 71 XP during verification.
- The XP leaves gain `CurrentXP` and level through `GetSkillLevel(SkillData)`. Wrapper objects of one SkillData do not compare equal with `==`, so match on the short name.

**Dodges are server-authoritative in the dev server log.**
- The source is `RSDragonwilds.log`, category EvadeAttack, Verbose. Timestamps are UTC.
- `TryPerformAttack() : [..] <AI> starting attack on authority against player <pawn> with id N` marks a telegraph.
- `PredictPointDamage() : [..] <pawn> evaded 0.000000 damage at T from <AI>` marks a successful dodge.
- `... <pawn> will receive D damage ...` marks a hit.
- `<pawn>` is the object name, for example `BP_PlayerCharacter_C_2147373968`. The referee's `start` reply now returns it.
- `evals/bench/serverlog.py` tails the log. On dev it is the source for `telegraph` and `defended how=dodge`; the client-hook versions of those are dropped.
- **Blocks:** the server logs only `DomNetActIntIds: AUTH : Action Accepted : START/STOP : Block` and `AuthorityApplyBlocking() : BlockDelay`. Neither names the player, and no outcome line was seen. The blocks in the logs so far were made without a shield, and every one of those hits did full damage. The wording for a blocked or parried hit is still to be captured on the first shield fight.

**Judge-side spell signals.** The probe reads them (`bench_probe.lua`) and never trusts the cast reply.
- `pc:GetViewTarget()` returns a class word, and `pc.CurrentInputMode` a DIM_* asset. The spells agent verified both live.
- Eye of Oculus leaves its view inside the cast, after about 3–5 s (L29). The referee therefore also polls `BP_OculusCamera_C`; it has not yet been confirmed that this actor exists on the server.
- Transient signals (view target, input mode) evaluate to null when absent, never to fail.
- Enchant Weapon (Fire) is checked by `held_item_effect` on the probe's `held.effects`, which reads `HeldEquipmentActorRight.MagicalHeldEquipmentEffectInfo.EffectData`, for example `HEED_EnchantWeaponFire`.
- **Referee v1.4 (registered on dev at 07:58 UTC; not yet seen firing):** RegisterHook succeeded for `/Script/Dominion.OculusPawn:Multicast_OnOculusActivated`, `/Script/Dominion.PersonalInventoryComponent:OpenPersonalInventory` (EPersonalInventoryOpenMethod Manual=0, Spell=1) and `:Client_TogglePersonalInventory`. It also polls `pawn.OculusComponent:IsOculusActive()` every 250 ms. All of these emit `spell_state`.

## Director live smoke, run 1 (2026-10-26 07:46-07:52 UTC, dev world, client build 26162923, server build 26161880; Director agent; docs/design/director.md §14)
- **Setup:** `DW_DIRECTOR=1 DW_DIRECTOR_CALLS_PER_HOUR=10 tools\start_brain.ps1 -Body client -World dev_director`. `session_start` showed world=dev_director and director=true. The job came in by CLI: `tools/board.py add "chop 5 ash logs, then drop them on the ground next to you" --world dev_director`. Log: `logs/brain-live-20261026-084634-10200.jsonl`.
- **What worked:**
  - Inbox ingest happened on the next tick.
  - Real Sonnet researched (recall, map_memory, look) and planned explore → chop → drop with checkable core predicates.
  - Board runs verified each step from state, e.g. "Ash Logs +6/5" and "Ash Logs -5/5 left the inventory".
  - A failed step (no progress twice) became a DEPS replan ("trees here depleted, explore further"), which then worked.
  - The hourly window held: 7 Sonnet requests, then the job went to `waiting_budget` and a notice was voiced.
  - There were no director_error or board_quarantined rows.
  - Step-to-step gaps were p50 3.0 s, almost all Haiku thinking (`tools.obs task`).
- **Job did not finish (Director bug, fixed offline):** Sonnet's done test was `all[gained Ash Logs 5, lost Ash Logs 5]` since the job began. Both read the same net delta, so it can never pass. The tally reached 13 logs collected, with three drops of 5. The Validator now sends this back for repair with the reason, and suggests tally + on_ground (`director.net_conflicts`, test `test_gained_and_lost_of_one_item_in_one_test_go_back_for_repair`).
- **Controller ran ahead:** in the first step ("explore to find ash trees") Haiku did the whole job (gather + drop), so the later steps counted nothing. STEP_INSTRUCTIONS now say "do this step only: the job's later steps come to you as their own steps". This is information, not a veto.
- **Voice bugs (controller/voice owners):**
  - Haiku's content "EMPTY" was **said in chat** 3 times; the rest were suppressed only as near-duplicates.
  - "hey! what we up to?" was said at the start of a body-initiated board run, twice.
- **Survival:** hydration fell to 18.7/75 with no drink; the reflex Clean Water use failed (`reflex_use_failed`).
- **Spend:** Sonnet 7 requests ($0.11). Haiku made **38** Controller calls ($0.024), **over the 20 I had stated**. That is 12 board runs at 2–4 turns each plus notices. A future smoke needs a hard Controller-call stop, not only an estimate.

## Build probes P2–P5 (2026-10-26 ~08:2x–08:3x UTC, dev world, client build 26162923)
- **P2, the place key:** `IMC_BuildingMode` maps **`IA_Building_QuickInteract` = LeftMouseButton** (the place / quick-interact click). `IA_PrimaryAction` is NOT mapped in build mode: a press of it placed nothing (P5 attempt 2).
  - Also in `IMC_BuildingMode`: RotateZ / OffsetZ / OffsetDistance = MouseWheelAxis, Cancel = Escape, BuildMenu = B, FreePlacement = Y, GhostPiece_Modifier = F, DestroyObject = MMB.
  - `IMC_BuildingUI`: SelectPiece = LMB, GenericBack = B, tabs Q/E.
  - Build input modes: `DIM_BuildMenu` (Selection), `DIM_BuildMode` (Placement), and DIM_OculusBuildMenu / DIM_OculusBuildMode / DIM_OculusRepairMode.
- **P3, B toggles the menu:** IA_BuildMenu, one injected frame → `CurrentBuildMode` 1 (Selection), input mode DIM_BuildMenu. **One Cancel from Placement goes straight to None.**
- **P4a, selecting a piece:** `BuildingUIAPI:CallOnBuildingItemSelected(<UBuildingPieceData>)` while in Selection → Placement (2), DIM_BuildMode.
  - `CurrentlyPlacingPieceData` is a **TWeakObjectPtr**: read it with `:Get()`.
  - The preview is a real **actor** (`BP_Station_Campfire_C`, `bIsPreview` = true, `PlayerControllerManagingPlacement` = our PC). Its location equals the MPC `CursorWorldPosition` (the vector's R, G, B = X, Y, Z in cm).
  - `SetControlRotation` moves the preview: aiming works.
- **MPC `PlacingValidityStateIndex`:** 1 with 0 stone (MissingMaterials). After 6 stone were granted (dev fixture, harness setup) it read 2 at every ground spot ~4–6 m away.
- **The validity hooks NEVER fire.** These stayed silent across the 1→2 change, re-selects and aim changes, although both registered natively: `BuildModeComponent:OnValidityStateChange` and `BaseBuildingActor:OnValiditySpawnStateChanged`. They are called from C++, not ProcessEvent, and no validity property is reflected. → Press rule changed (main approved): MPC == 2 AND the preview within match_m of the spot AND a fresh read after the latest aim plus wait.
- **Snap pieces:** colour 2 also covers NeedsSnapping. The data signal is the preview actor's loaded `BuildingPieceDerivedData.PlacementProfileRowHandle`, read with UE4SS `DataTable:FindRow(RowName)`, then `.bCanOnlyBeSnapped`.
  - Campfire → `FloorPropNonOverlapProfile`: bCanOnlyBeSnapped = false, bCanOnlyBePlacedOnDefinedSurface = true.
  - Snap-only or unreadable → no press (`preview_ambiguous`), a known limit until a positive snap signal is found.
  - The preview's `BuildingSnapComponent.Plugs` is NOT a usable discriminator: the Campfire has plugs.
- **P5 PASSED:** `build {piece: "campfire"}` → presses menu, select, place (QuickInteract), cancel → ok.
  - spent `{ITEM_Resources_Stone: 6}`.
  - evidence = **telemetry**: `Client_TelemetryOnBuildingPieceComplete` is a Client RPC and its post-hook DOES fire.
  - Construction XP **+12** (not ConstructionXPOnBuild = 20: multipliers apply, as the review said).
  - Build mode was None afterwards.

## Live checks: fishing, talk P1, talk P2 attempt (2026-10-26 09:00-09:28 UTC, dev world, client build 26162923, ClaudeDev; skills-coverage slot)
Quick fixtures, logged as quick and not M3 cases: Coarse Net and Ash Rod were granted through `DevTarget.setup("grant")`.

**Net fishing works end to end.**
- `fish {count: 2, method: "net"}`: walked to the nearest net spot, equipped the Coarse Net, held the trawl once, and caught 2 Raw Shrimp. Fishing XP rose by 8 (the SkeletalComponent rows). Took 17.8 s.

**Rod fishing is partly working.** Casting, the landing correction, bites and reeling work; fights are lost to stamina.
- **Input modes.** With the rod in hand the PC sits in `DIM_SpellcastingMode` (the rod's cast is a magic-attack action). The bite/fight runs in `DIM_Fishing`.
  - Both are this action's own input modes.
  - Fix in fishing.lua: the tool's baseline mode, and any mode once fishing has begun, no longer gate our own hold. Build, container and conversation screens still block.
  - Before this fix, every cast restarted ("cast N" loops), and one run ended with a false `screen_open`.
- **Casting.**
  - Charge 0.45 landed at 19.4 m; the model predicted 12.6 m.
  - The learned correction settled at k ≈ 0.61–0.67 (`landed / predicted`), after which casts hit the node.
  - `CastResult` values seen: Missed_HitWater (2) and Hit_ValidNode.
- **Junk.** Junk (Weeds, Stone, Goblin Pack) arrives without a fight. A late junk item was once miscounted as a fish; now only `FishingResult == CaughtFish` counts as a fish.
- **Fight trace** (fishing_status.fights):
  - while the fish swims, his `PlayerStaminaFraction` falls about 12 %/s and the fish's only about 2 %/s;
  - while it rests, holding `IA_Fishing_Reeling` moves ReelProgressFraction from 0 to about 0.74 in about 5 s, and the fish's stamina falls about 12 %/s;
  - his stamina hits 0 at about 12 s, and the fish escapes.
- **Pull experiments.**
  - The same-side pull drained him about 30 %/s, so the opposite pull (wiki) is the right direction. A stamina-drain swap rule was tried and rejected.
  - Pulling nothing at all drained him at the same ~12 %/s. So either the drain comes from the fight itself (Ash Rod = lowest tier; wiki: better rods drain less), or the injected `IA_FishingMiniGame_MoveLeft/Right` presses do not reach the minigame. **[UNVERIFIED which]**
  - He now rests to 95 % stamina before each cast.
- **Fishing XP.** It rose on escapes and junk too (+12 over one run with 0 fish).

**Talk P1 (read-only, hooks registered).**
- `ConversationComponent` = `BP_Components_PlayerConversation_C`. Its `DomConversationParticipant` lives on the PAWN (`...BP_PlayerCharacter_C_*.DomConversationParticipant`). Idle: ConversationsActive 0.
- `WBP_Conversation_MainPanel_C` exists on the headless client: `ContinueInputAction = IA_UI_ContinueConversation`, `CancelInputAction = IA_UI_GenericBack`, 4 `OptionSelectInputActions`, `OptionSelectMappingContext = IMC_Conversation`.
- With no conversation open, the panel's participant is unset. talk.lua now accepts an unset participant.
- Both count-only hooks registered natively: `ConversationParticipantComponent:ClientUpdateConversation` and `PlayerConversationComponent:BP_HandleConversationUpdated`. The client stayed healthy.
- Quests read: First Steps state 1 (Objective2), and the others Ungiven.
- NPCs in relevance: `BP_NPC_WiseOldMan_FTUE_C_*`, `BP_NPC_Doric_FTUE_C_*`, Vannaka (`SkeletalMeshActor_*`), all with prompt "Talk".

**Talk P2 blocked by perception.**
- The census row for the Wise Old Man reports a position near the world origin (look distance 1865 m). His actor is at (61.3, 1873.6, -35.5) m, 8 m from Claude.
- The shared interact episode, used by both `interact` and `talk`, walks toward that point (water_ahead / no_route) and times out without pressing E.
- Reported to the capability agent (sense owner). No conversation opened; talk was disabled again after the attempt.

**Starvation.**
- ClaudeDev died of hunger and thirst at 09:24:08 UTC (sustenance and hydration 0) during this slot. He carried no edible food: the Raw Shrimp are not edible.
- He respawned at the FTUE start area with 25/75 food and drink.
- **Fixture `set_time` (verified on dev at 10:4x UTC):** on the server, `BP_InGameTimeActor_C` (`AInGameTimeActor`, implements `IInGameTimeProvider`) provides `GetInGameTime()` → FTimespan `{Ticks}` (1 tick = 100 ns) and `SetInGameTime({Ticks=n})`.
  - The value is TOTAL in-game time (day 53 at hour 1.1), not the hour of the day. Crop timers are stamped in it, so the fixture only moves the clock forward.
  - Measured 01:07 → 01:30: `SetInGameTime` took effect immediately, and the clock read 01:35 five seconds later.
  - The server log at 2026-10-25 22:47 showed `DominionInGameTimeSubsystem: Failed to find an actor that implements IWorldTimeProvider` (a different interface).
  - Not yet checked: whether the change replicates to the client (`bench_probe.game_hour`).
- **Slot results, 2026-10-26 09:45–09:55 UTC (dev, Eval agent):**
  - **Axtral Projection T0 passed** at the standing-trees spot `evals/bench/dev_places.json` `[100, 1892, -31]`: two Ash Trees about 8 m away, the lodestone 49 m away. Evidence: `spell_actor BP_Spell_AxtralProjection_C`, 3.9 s, 2 Haiku calls.
  - **Route A (fresh character per case) verified live.** `CD_m3w05d8_sure0` was created through `create_char.lua`: first boot stops at the menu, create, second boot picks it by name and joins dev with the client relaunched (L24). The server GUID `F201088A…` came from the referee probe.
  - **`raise_skills`, all-but-Woodcutting to 10, on that character:**
    - 8 skills reached 10.
    - Mining overshot to 19: its DamageXPEvent gives about 3 XP per multiplier unit, against Attack's about 0.8.
    - Fishing, Magic and Agility stayed at 0 XP, because their DamageXPEvent gives NO XP.
    - Fixed offline, not yet re-run live: an adaptive step (a quarter of the gap first, then the measured ratio, aiming at 97%), plus skill-specific live row handles: Magic `PlayerMagicComponent.SpellDamageXpEvent`, Agility `SprintComponent.SprintXpEvent`, Fishing `CatchableFishSpeciesData.Info.NormalDrop.OnFishingXpEvent`.
  - **Enchant Weapon (Fire) T0:** the hold setup (the body's `equip` on the granted sword) succeeded. The cast then answered "couldn't find Enchant Weapon: Fire on my spell wheel's pages" (verification_failed) after the unlock. That is a body/spell-wheel issue.
  - **Runt spawn (M1):** the spawn fixture now loads a not-yet-loaded class with UE4SS `LoadAsset(<full path>)` + `StaticFindObject`. The paths are in `evals/bench/spawn_classes.json` (runt: `/Game/Gameplay/AI/GoblinFaction/MeleeGoblin/RuntGoblinVariant/BP_AI_RuntGoblin_Character.BP_AI_RuntGoblin_Character_C`). It is deployed but not verified: the fixture needs the character in the world, and the client is down (BUGS L35).

## Client lodestone fast travel (design + offline build, 2026-10-26; dump 26161880; NOT yet live)
- **Route (the player's path, never a position write):**
  1. Use the lodestone (`BP_WorldLodestone_C`, prompt "Teleport") through the shared interact episode. The map opens: `UMapUIAPI:IsShowingMap()`.
  2. `UBaseTeleportationComponent:TryTeleport(FromId, ToId)` on his PC's `LodestoneTeleportationComponent`. This is the local function the map's lodestone click calls; it sends `Server_TryTeleport`.
  3. Verified by the `Client_OnTeleportSuccessful(TargetLocation)` Client-RPC post-hook AND his position within 25 m of the destination's RespawnLocation.
- **The ids passed are the LIVE `FGuid` structs** read from `AGameplayObjectRegistry.Lodestones` (`FLodestoneData` {Location, RespawnLocation, Identifier}), never built in Lua.
- **Gates are read before any walk or press:** `CanTeleport` false → `not_unlocked`; `CanAffordTeleportationCost` false → `missing_materials` (Law runes, with `GetTeleportationCost`).
- **The retired server-puppet route is NOT used:** `mod/body/travel.lua` K2_TeleportTo.
- **Built:** `client_mod/scripts/lodestone.lua` (tools `lodestones` read, `teleport` action with `llm=false` until live) and `client_mod/tests/test_lodestone.lua` (13).
- **UNVERIFIED live:**
  - that the press opens the map headless;
  - that TryTeleport from Lua starts the teleport;
  - that the success RPC hook fires;
  - that IA_UI_GenericBack closes the map;
  - that two lodestones are both unlocked anywhere on dev (DISCOVERIES l.584: proving CanTeleport true needs a second built lodestone).

## Director live smoke, run 2 (2026-10-26 14:54-14:57 UTC, dev, ClaudeDev fresh, client build 26162923; Director agent)
- **Setup:**
  - bridge_start first; build is listed.
  - World dev_director_r2; job "make yourself a wooden shield" via the CLI.
  - Hard guard at 20 Haiku / 10 Sonnet. The guard stopped the brain at 20 Haiku calls; Sonnet made 7 requests.
  - Log: `logs/brain-live-20261026-155436-3456.jsonl`.
- **Not finished (no shield).** The task is still active at "Gather 14 Ash Logs".
- **What Sonnet got right from data:**
  - Wooden Shield = 10 Ash Logs at a Crafting Table, unlocked by holding ash logs with a table near;
  - the Crafting Table costs 4 Ash Logs (buildables);
  - the trader route (30 Garou Chit per log) was rejected;
  - his near-death state (0.5 HP, hydration 0) came first.
  - On the replan it found the real chicken-and-egg: no axe; Stone Logging Axe = 8 Ash Logs + 6 Stone at a Crafting Table, which itself needs ash logs.
- **Findings:**
  1. **The client crashed** at 14:56:19 (crash dump `crash_2026_10_26_15_56_19.0234266.dmp`, pid 7080) during `explore`. Free RAM was about 1.5 GB. The watchdog relaunched it (boot ok 14:57:10). The board run got `body_restarted` on explore and go_to, and said so truthfully.
  2. **Hallucinated fact:** the first plan listed "I have a Stone Logging Axe" as known. He carried no tools; the replan corrected it.
  3. **Steps tested only by elapsed time** ("Recover the gravestone", "Set vitals policy") passed although their tools failed. Fixed offline: the Validator now gives one advisory for a working step tested only by time (information; the model may keep it).
  4. **The first-axe bootstrap:** the answer is already in this file ("Ground gatherables", interact_probe 15:58 UTC). Ground "sticks" are `BP_Spawner_AshBranch_0x_C` with `ItemData = ITEM_Resources_Wood_Ash` ("Ash Logs"), prompt "Collect", and no tool is needed. But gather_profiles `sticks` still has item nil, so `gather ash` resolves to the trees (wrong_tool without an axe). For run 3, the body needs that profile item set, or the model must use interact/gather "sticks".
- **obs task:** wall 183 s, idle 7%, longest idle 3.8 s. Lead-in 26 s (25 s of Sonnet thinking). Gaps p50 0.13 s, p90 0.56 s, all dead time, under 1 s each.

## Live checks 2026-10-26 15:05–15:40 UTC (ClaudeDev, dev world, skills slot)

- **Survival root cause:** at 15:06 hydration reached 0 and HP fell because he **carried no drink or food at all**. The stay-fed reflex was running (no error, nothing marked bad) but emitted nothing, since it only warned about bag-only items. The 14:59:37 "blocked: build Placement" event fell inside a live build, released at 14:59:39, so it was not the cause.
  - Fix: `reflex no_drink`/`no_food` events. Seen live at 15:37:47: "no drink carried, hotbar or bag".
  - Fix: a safety-floor exit from build/container screens, `input.leave_modal_step`.
- **skill_routes, M3** (`logs/skills/routes_20261026-161533.json`): 0 passed, 4 failed, 8 skipped.
  - **Loose stones give no Mining XP.** `gather stone` resolved to the ground pickup, returning "Got 2 stone" with Mining 3 → 3. The profiles are now split: `stone_boulder` (Mining) vs `loose_stones` (`trains=false`), and a bare "stone" resolves to the category.
  - **Lock-on is a gameplay mode.** Combat's own lock-on puts the PC in `DIM_Gameplay_LockOnTargeting`; it was read as a blocking mode. `input.is_gameplay_mode` now accepts `DIM_Gameplay_*`.
  - **Campfire targeting.** The craft at the Campfire failed: the interact focus kept picking an adjacent `BP_BM_Sapling_Ash_01_C` (handed to the capability agent).
- **First-axe bootstrap, verified live:** `gather {resource:"ash", count:2}` with no axe collected 2 `ITEM_Resources_Wood_Ash` from `BP_Spawner_AshBranch_03_C` ("Collect", interact key, no tool, 5.7 s). The reply was "Got 2 ash from sticks (no usable logging axe for ash)". The fallback is profile data: the same item, a tool-free source, in range. Floor logs = these branch pickups; felled-tree logs still need an axe.
- **Rod fight trace (Ash Rod, Brynmoor rod spot; 3 fights, all lost):**
  - **Pulls do reach the minigame.** `FightingFishPlayerInputValues.PullingRodValue` reads ±1 matching the pressed direction.
  - **While the fish swims (L/R):** the reel stays at 0.00; HIS stamina falls about 8.5 %/s and the fish's about 2.5 %/s.
  - **While it rests (r) and he reels:** the reel rises about 14 %/s, the fish's stamina falls about 12 %/s, and his falls only about 2 %/s.
  - **Outcome:** the reel peaks at 0.72–0.76 when the second swim starts, and his stamina reaches 0 about 16 s in, so he loses.
  - **The earlier `pull_mode="none"` experiment was void:** the override was applied after the hold was set, so it still pulled. Fixed, and `pull_mode="reel"` was added. A real A/B is still pending: the one "none" try got junk, then the Goblin Runt killed him mid-fishing with the rod in hand (combat reflex: 4 presses, 0 hits).
- **talk P2 (Wise Old Man FTUE):**
  - **First try:** the dialogue DID open (`DIM_ConversationUI`, his first line in `LastMessage`), but `ConversationsActive` stayed 0 and `CurrentNPC` was unset on the client. talk therefore said "no conversation opened", leaving the panel up and the reflex blocked.
  - **Fix:** the conversation input mode also counts as active.
  - **Retry:** it opened, read 3 lines, and `hook_count` went 1 → 4 with content changes (counter proven). `leave` ended it (node inactive, no input owner left).
  - **Options:** the node offers "Yes please [Begin Tutorial]" / "I can work it out [Skip Tutorial]". Both change quest state, so no "harmless choose" exists here; that is left for P3 on a fresh devchar. The reply's `options` list was empty while the node signature listed both (to check).

## Director live smoke, run 3 (2026-10-26 16:05-16:10 UTC, dev, ClaudeDev; Director agent)
- **Setup:** bridge_start first; the sticks profile fix (18a2626) was in. World dev_director_r3; job "make yourself a wooden shield". The guard stopped the brain at 20 Haiku calls; Sonnet made 7 requests. Log: `logs/brain-live-20261026-170459-9940.jsonl`. memory_low 0; free RAM about 1.27 GB; no client crash.
- **Not finished.** The job is active; 0 Ash Logs.
- **The bootstrap route resolved correctly:** `gather {resource: ash, count: 14}` with no axe went to `resource: sticks`, item ITEM_Resources_Wood_Ash.
- **But he could not reach the branches:** `path_blocked` after 120.9 s. The phase log shows 3 approaches (21.8 m, 11.8 m, 16.3 m), each `scan unreachable timeout` after 40 s ("I can't get to the sticks (timeout), and the last 3 I tried were blocked too"). This is a locomotion gap at that spawn (for the move/locomotion owner).
- **Survival took over:**
  - Hydration was low. He found a pond (BP_WaterVolume) and tried `interact` on it 4 times, always `too_far`.
  - He said truthfully that he had no bottle or bucket and asked the player for a waterskin.
  - He fought a Kebbit, and that fight looked well (dodge, Tempest Shield, hits).
- **Replan:** "find a woodcutting tool" first. The Director did not learn that the sticks route exists, because gather's failure said "can't get to the sticks" and the plan read it as "no hatchet". Information for the model: the gather detail now names sticks.
- **obs task:** wall 317 s, idle 2%, longest idle 0.7 s. Lead-in 15.6 s (14.6 s of Sonnet thinking). Only one step ran, so there are no step gaps.

## Drinkable water for a fresh character (research 2026-10-26, game data build 26161880 + wiki + our live logs; Director run 3 question)
- **No container is needed, and there is no direct "Drink" from water.**
  - Water bodies are interactables `BP_WaterVolume_C` / `BP_WaterVolume_NoSlow_C`, and the census reads their prompt as **"Collect Water"** (live 2026-10-25, e.g. `BP_WaterVolume_NoSlow_C_UAID_00BE4395530E3F5202_1116071179`, 14 m from the start crate).
  - Game data lists "Get Water" as a world interaction (filling from a source), not a wheel spell.
  - The wiki: Dirty Water "can be collected from ponds or any accessible body of water" (dragonwilds.runescape.wiki/w/Dirty_Water, /w/Hydration).
  - No other water prompt has been seen. No waterskin, bottle or water bucket exists in the item or recipe data: the only "containers" are farming Watering Cans (`RECIPE_Tool_WateringCan_Wood`: 4 Ash Logs + 1 Coarse Thread) and Compost Buckets.
- **The water itself:**
  - `ITEM_Consumable_Water_Dirty` (DrinkItemData, stacks to 99): +10 hydration, +20 Soulscourge (damage over time at 100), so a few are fine and many are not.
  - Clean Water (+25 hydration, no Soulscourge) comes from `RECIPE_Consumable_Water_Clean_From_Water_Dirty`: 1 Dirty Water at a **Campfire or Grill** (processing station: load + fuel, 4 s, collect), Cooking XP.
  - The recipe is unlocked by owning Dirty Water (`ALL ITEMS[ Dirty Water ]`, DT_Progression_Food_Drink), so it appears after the first collect.
  - The Campfire is buildable from the start (build primitive verified live 2026-10-26), and crafting.lua's processing path already handles campfire recipes.
- **Bootstrap chain:** collect Dirty Water ("Collect Water", interact key, one per press), then drink one only if desperate (Soulscourge), then build or use a Campfire with fuel, boil, and drink Clean Water.
- **Body gap: water-source interact fails.**
  - Every live `interact` on a Water Volume (2026-10-25/26, about 10 tries) ended `too_far`, "I can't get close enough to the Water Volume", at **0.88–0.97 m** from the chosen spot after 6 spots.
  - Cause (skills.lua go_to/near check): the approach spots for the volume's surface point lie at or in the water. move.lua's water avoidance ("entered water, re-planning round it") stops him at the edge, and `near` requires `d <= spot tol + 0.3`.
  - **SPEC (skills.lua, capability owner):** a target whose census kind is a water volume (data: class/prompt from the census, no name list):
    - **(1) Approach:** the nearest DRY standing point within `reach_m` (2 m) of the surface point; arrival = 2D distance to the surface point <= reach_m (`tight` off).
    - **(2) Face** the surface point with the camera pitched down (W.face(ipoint)), so the interaction detector targets the volume (check `interact_target` reads the volume / "Collect Water" before pressing).
    - **(3) Press** interact once and verify a +1 `ITEM_Consumable_Water_Dirty` within verify_s.
    - **(4)** `count` > 1 repeats the press (the source never depletes, per the wiki), stopping at inventory_full.
    - **(5) Failure reasons stay truthful:** `not_interactable` ("the water doesn't take", with what the detector targets), and `too_far` only when no dry point within reach exists.
  - **Stay-fed reflex:** it should NOT drink Dirty Water above the safety floor (Soulscourge); below the floor, Dirty Water beats death. The brain gets `no_drink` and decides to collect and boil.

## Spell re-run findings + multi-step mechanics (2026-10-26, offline from logs/evals/20261026/20261026-163357-dev-measure)
- **The case errors were the model-call budget**, not the body: Fire Spirit and Vengeance cast ok and verified, then the model went on (consume, re-cast into the cooldown) until the cap hit. An ok cast carried no sentence, so the body now adds one ("I cast Vengeance: used 20 Astral Rune; it's recharging now.").
- **Fishnado / Fishing Frenzy:** cast on a fishing node id from `fishing_spots` returned "I can't see what you want me to aim at". The bridge census (sense) doesn't list `FishingNodeV2` actors, and go_to answered `target_not_visible` for the same id. spells.lua now resolves any actor id the census lacks through the live actor (class = id up to `_C`, one FindAllOf). The census gap itself belongs to sense/go_to (capability).
- **no_valid_aim "requires multiple logs" / "requires rune" / "requires fishing node"** are the game's own placement tags, and they are truthful. Trunk Totem and Runes to Rune Essence then succeeded after the model prepared the ground (dropped a rune, moved to logs).
- **Recall** (Luis + wiki "place a temporary beacon ... return to it within a limited time"; the game's only `AllowMovementThenCastInstant`): one cast leaves it PREPARED (`SpellBeingPreparedOrCast` = USD_Recall), no runes, no cooldown = the beacon is down. A second cast returns. The time limit is not found (wiki and metaforge are silent). The body treats it as two steps, from data/spell_mechanics.json `two_step`:
  - step 1 answers "beacon placed at [x,y,z]";
  - step 2 is verified by arriving within 4 m of the beacon.
- **Divine Rock / Enfeeble / Rapid Growth were declined by the model, correctly:** no ore on the ground, nothing hostile in sight, no crops. ClaudeDev was also at 1% HP with 0 hydration, so it put survival first. The tool list wasn't misleading; the cases lack their world preconditions.
- **Multi-step / conditional mechanics, from the wiki snapshot:** written to `data/spell_mechanics.json` (35 spells, non-judge, with sources) and exposed as `how` in state.spells:
  - drop-then-cast: Runes to Rune Essence (drop the runes), Divine Rock (drop 5 ore), Magical Mending (drop the damaged items), Bones to Peaches (bones on the ground);
  - cast-on-a-thing: fishing node (Frenzy, Fishnado plus a tool of the node's power), fallen trees (Trunk Totem, Splinter), standing tree (Bark to Bones), plots (Rapid Growth, Mucksplosion with 150 compost, Humidify with a 50-water can), fire stations (Superheat), mechanical stations (Overdrive);
  - equipped tool: Infernal Rod (rod), Spectral Arrows (two-handed bow, not a crossbow);
  - carried tool: Rocksplosion (pickaxe), Axtral Projection (axe);
  - timed charges: Surge (3 dodges, 2 min), Windstep (7 s), Phase Dash (3 air dashes);
  - Internal Alchemy only refreshes ACTIVE food/drink buffs.

## Recall, live 2026-10-26 17:35–17:39 UTC (ClaudeDev) + sources
- **Live behaviour:**
  - Selecting Recall opens `DIM_SpellPlacementModeAdvancedMovement`, a placement mode he can move in (move.lua isn't input-gated).
  - The place press spends 30 Air + 15 Law, starts the 75 s cooldown and plays a ~1 s DominionSpellActor. Pressed at once, he stays put (0 m).
  - A place press on an invalid spot does nothing; the mode stays open 12 s until cancelled. spells.lua now puts this mode through the validated spot search.
  - During the cooldown the game refuses it.
  - A cast after the cooldown, 11 m from the previous one, cast again with no teleport.
- **Sources:**
  - Wiki revision https://dragonwilds.runescape.wiki/?diff=58751: "Leaves a runic marker on the ground; recasting teleports you back to it. Taking a fatal fall while tethered teleports you back safely and consumes the tether."
  - The marker's lifetime is not stated anywhere found (wiki, metaforge 403).
- **Next live test** (prepared in the scratchpad, applied after the freeze): `cast {spell: "Recall", walk_to}` opens it, walks while it is held, then finishes it, judged by position. It tests whether the mark is where the cast is opened and finishing it brings him back.

## Recall hold-and-walk, live 2026-10-26 19:38–19:41 UTC (dev, Claude's client, build 26162923; probe `client_mod/commands/recall_probe.lua`, 0.5 s samples)
- **The mechanic, verified:** the mark is where he stands when Recall is **opened**; finishing the same cast teleports him back to it.
  - 0–2 s: the wheel (`DIM_RadialMenu`), page turn, quick key.
  - 3.2 s: `DIM_SpellPlacementModeAdvancedMovement`, `SpellBeingPreparedOrCast` = `USD_Recall`, runes untouched (Air 380, Law 1460). The preview sits at his feet: `[97.97, 1865.76, -29.46]` with him at `[97.94, 1865.61, -30.69]`.
  - 3.7–6.4 s: he walks (`move.go_to`) while the mode stays open: 10.8 m to `[100.67, 1876.04, -30.59]` (`walk_result` arrived).
  - 6.9 s: the place press. Air 380 → 350, Law 1460 → 1445, the 75 s cooldown starts, `DominionSpellActor_2147465313` appears for ~1 s, the mode is `DIM_SpellcastingMode`. He is at `[97.95, 1865.68, -30.59]`, 0.1 m from the opening point. That is the teleport back.
  - 8.0 s: `DIM_Gameplay`. He stays at the opening point for the rest of the 40 s.
  - Result: `cast {spell: "Recall", walk_to: [100.5, 1877.3, -31.6]}` → ok, `returned: true`, `from_opened_m` 0.1, `walked_m` 10.8, presses menu, next_page, quick0, hold_walk, place.
- **A later recast does not return:** after the cooldown he walked 11 m away to `[100.65, 1876.02]` and cast plain Recall (menu, quick0, place). It spent 30 Air + 15 Law, started the cooldown and moved him **0 m**. A finished Recall leaves no lasting marker, so the wiki's "recasting teleports you back" is the place press of the same cast. spells.lua's hold-and-walk model matches. Recall is not `two_step` in `data/spell_mechanics.json` (updated `how`/`observed`).
- Result fields (spells.lua, after 20:00 UTC): `landed_at` = where he ended up (the snapshot after the cast); `placed_at` = where the place press and its spell actor were (the walk's end). `from_opened_m` / `returned` judge the return. `cast` without `walk_to` on this cast type is refused up front (`walk_to_required`): opened and finished on the spot it moves him 0 m and still spends the runes. The two-cast beacon code is removed.

## Item-name resolution and station-output pickup (2026-10-26, Claude's client, dev)
- **consume name matching, live-verified 19:38 UTC:** only a Water Rune on the hotbar, no Clean Water. `consume {"item":"Clean Water"}` and `{"item":"water"}` → `not_in_inventory`: "I don't have any Clean Water on me, and I can't see one nearby. (Water Rune isn't something I can eat or drink.) I have nothing to eat or drink on me." (`carried_consumables` []).
  - Before the fix it answered `not_consumable` "I can't eat or drink the Water Rune". The cause: `skills.find_carried` took any partial `match_score` overlap (the word "water") as a match.
  - The shared rule is `client_bridge.M.resolve_name` (`api.resolve_name`). A match is an exact id or name, the whole words inside the name or id, or every word matching. A partial overlap is only `near`, never a match. consume lets only consumables match fuzzily. `inventory.find(list, what, prefer_kind)` prefers the requested consumable kind among substring hits.
- **Station output pickup** (live failure 19:3x: "the game targets BP_Station_Campfire_C…, not the Clean Water"):
  - The detector (`UInteractableDetectorComponent`) casts a camera ray (`CameraRayLength`) and a forward character trace (`CharacterTraceDistance`), so whatever lies *behind* a small item on his line of sight wins a near miss.
  - crafting's collect step hand-built its episode. It had no `ipoint`, so `W.face(nil)` never aimed, and no `small` flag, so other sides were never tried.
  - It now uses `skills._new_episode(..., {avoid = station position})`. Standing spots are 0.9 m from the item, in this order: beside it (±90°), between the item and the station, the far side last.
  - The other-sides retry for any small item now avoids whatever the detector picked instead. It also fixes a mirror bug that dropped the far side rather than his own.
  - `client_bridge.aim_at` now aims from `PlayerCameraManager:GetCameraLocation()` (like `spells.W.aim`), not from the pawn's centre.
  - Live re-check of the Campfire pickup: **not yet done** (needs Dirty Water and fuel).

## HUD screens and the input mode: InputManagerUIAPI (2026-10-26 19:02–19:18 UTC, dev, ClaudeDev; BUGS B-stuck-focused-ui)
Builds: client 26162923, dump 26161880.

### The API
- **`UInputManagerUIAPI`** (Dominion.hpp l.24430) owns HUD widgets by `EWidgetType` (Dominion_enums.hpp: Crafting 6, Inventory 11, Map 13, Processing 15, LorePopup 31, Runecrafting 36, …).
  - `IsOpen(PC, Type)` → bool.
  - `CloseWidgetIfOpen(PC, Type, bIsTriggeredByOutsideWidget, bShouldCheckPauseBlock)` and `OpenWidgetIfClosed(...)`. Plain enum/bool arguments, no structs.
  - `CurrentlyActiveWidgetForController` names the focused panel.
  - The PC's input mode (`CurrentInputMode`, DominionInputMode assets under `/Game/Gameplay/Inputs/Modes/`) follows the open widgets.

### Verified live
- **The stuck state:** after a Campfire craft, IsOpen gave {10 InteractionPrompt, 11 Inventory, 15 Processing}, active = `WBP_Inventory_MainPanel_C`, mode `DIM_FocussedInGameUI`.
  - `CraftingUIAPI:HideCraftingUI(15)` changed nothing.
  - IA_UI_GenericBack/Accept/UnFocusRequirements and `RefreshInputMode()` did nothing either (earlier agent).
- **The close:** `CloseWidgetIfOpen(PC, 15, false, false)` closed 15 AND 11 (coupled), and the mode read `DIM_Gameplay` in the same call.
- **Opening Inventory:** `OpenWidgetIfClosed(PC, 11, false, false)` gives `DIM_MainInventoryMenu`, and `CloseWidgetIfOpen(PC, 11, …)` returns to `DIM_Gameplay`.
- **Screen input modes** (object dump): DIM_FocussedInGameUI, DIM_UnfocussedInGameUI, DIM_FullScreenUI, DIM_FullScreenUIMap, DIM_MainInventoryMenu, DIM_CraftingMenu, DIM_AgilityCourseUI.
- **Used by:** `input.lua` (`close_screens`, `open_screens`, the `"screen"` modal, `after_action`), `crafting.W.close` and `lodestone.W.close_map`.
- **CommonUI idiom** (the Epic "Input fundamentals for CommonUI" doc): close or deactivate the widget through its owner and let the input config follow. Never call SetInputMode directly.

## Client crash L38: -nullrhi makes every Niagara spawn NULL; the player character stores and dereferences it (2026-10-26 19:30–20:35 UTC, client build 26162923, dev, ClaudeDev; cdb on the UE4SS dumps + static reading of the shipped exe + live reflection; read-only except the fix)
- **All 8 dumps of the family are one bug.** They are the 2026-10-26 18_08_10, 18_26_17, 19_04_07, 19_11_08, 19_20_03 and 19_24_52 dumps (local time, `Win64/ue4ss/crash_*.dmp`), plus the repros 20_24_07 and 20_25_57. Each shows the AV at `exe+0x64AEC4A`: `mov rax,[rcx]` with rcx=0, then `call [rax+2C0h]`.
  - The function (`exe+0x64AEAE0`) is **`ADominionPlayerCharacter::RemoveNiagaraSystemWithLocalTag(Tag)`**. It looks Tag up in `LocalFX` (`TMap<FGameplayTag, UNiagaraComponent*>` at pawn+0x1748; the CXX dump gives that offset), then calls the component's virtual (Deactivate), `DestroyComponent` (dl=1) and `Remove`. It has no null check.
  - Its caller (`exe+0x64AEE40`) is the tag-changed handler. It looks the changed tag up in `TaggedLocalNiagaraSystems` (`TMap<FGameplayTag, FDominionTaggedLocalNiagaraSystem>` at +0x1798, 0x38-byte elements) and calls Remove with the row's `LocalVFXTag`. It runs from a delegate thunk inside a multicast broadcast during the world tick.
  - In every dump, LocalFX holds exactly one element whose value is NULL. TaggedLocalNiagaraSystems holds one row whose key FName index (0x1f737) is the same across all runs.
- **The adder never checks.** `AddNiagaraSystemAttachedWithLocalTag(System, Tag, AttachPointName)` is at `exe+0x648D450`. It returns early when the tag is already held, or when the net mode is a dedicated server. Otherwise it calls `UNiagaraFunctionLibrary::SpawnSystemAttached(System, Mesh, AttachPoint, 0, 0, KeepRelativeOffset, bAutoDestroy=false, bAutoActivate=true, Pooling None, bPreCullCheck=true)` and does `LocalFX.Add(Tag, result)` **unconditionally**, even when the result is NULL.
- **The row (live read, `client_mod/commands/l38_fx_probe.lua`):** `Environment.SoulScourge` → `{LocalVFXTag = Player.Vfx.SoulScourge, System = /Game/Art/VFX/Library/Character/StatusEffect/NS_SoulScorge_PlayerEffect_Buildup, AttachPointName = spine_03}`. This is the Soulscourge build-up glow. Dirty Water (+20 Soulscourge) is the only consumable used so far that raises Soulscourge, and that is why only it crashed (0 of 31 other uses did).
- **Why the result is NULL (a headless client):** on Claude's -nullrhi client, `SpawnSystemAttached(NS_SoulScorge…Buildup, Mesh, "spine_03", …)` returns **NULL both with bPreCullCheck=true and with false** (`client_mod/commands/l38_spawn_test.lua`, live). So scalability pre-culling is not the cause. `fx.Niagara.Scalability.VisibilityCulling 0` did not help either (repro 2 still crashed).
  - In the shipped exe, `SpawnSystemAttachedWithParams` (`exe+0x50B96C0`) reaches `CreateNiagaraSystem` (`exe+0x50A09D0`). That function returns NULL before it creates anything, on `if (A && !B) return null; if (C) return null`, where A, B and C are three global bytes. That is the shape of `FApp::CanEverRender()`: `(!IsRunningCommandlet() || IsAllowCommandletRendering()) && !GUsingNullRHI`. The engine docs describe CanEverRender as the check for apps that never render or run headless with NullRHI.
  - Conclusion: with -nullrhi, **every** Niagara spawn returns NULL on this client.
  - Players (who render) and dedicated servers (Add returns early) never store a NULL, which is why this is a Claude-only crash.
- **Repro (dev, slot `l38`, 20:22–20:26 local):** fixture grant of Dirty Water, then `client_mod/commands/l38_drink.lua`, which runs inventory.lua's use path with crash_refusal bypassed in its own module instance only. A per-frame watcher (`client_mod/commands/l38_fx_watch.lua`) recorded:
  - the drink GE;
  - within 30 ms, `LocalFX = {Player.Vfx.SoulScourge = NULL}` with **no NiagaraComponent created** (NotifyOnNewObject saw none);
  - then the crash in the next frame.
  - Result: 2 of 2 crashed (dumps 20_24_07, 20_25_57). Why the Remove sometimes follows at once (the 16:55 and 16:58 drinks did not crash) is UNPROVEN, and the fix makes it irrelevant.
- **Fix (`client_mod/scripts/fxguard.lua`, client_bridge service `fxguard`, built like tickguard):** empty `TaggedLocalNiagaraSystems` on every live `DominionPlayerCharacter` on Claude's client: his own pawn and other players' pawns, whose tag events also run on his client. The tag handler then finds no row and never adds or removes a NULL. This covers every row, including any a patch adds. It is client-local and cosmetic, since a -nullrhi client never draws the effect. New pawns (respawn, join, other players) are caught by the 10 s service check.
  - Verified live: `fxguard_apply` emptied 1 row (`Environment.SoulScourge`) on `BP_PlayerCharacter_C_2147473178`. Then **3 Dirty Water drinks in a row on the same process (pid 1412) did not crash**, LocalFX stayed empty, and the Soulscourge status GE applied as normal. After a bridge restart, boot_probe shows `fxguard: running`.
  - Offline test: `client_mod/tests/test_fxguard.lua` (14/14).
- **Alternatives weighed:**
  - Rendering for real (dropping -nullrhi, e.g. -RenderOffScreen on WARP, since there is no GPU) would make CanEverRender true and fix every such site at once. It was not tried: it needs a software-rendered UE5.6 scene on a 4-vCPU VM with ~1.5 GB free.
  - Patching the NullRHI flag in memory would make the renderer call an RHI that does not exist, and needs approval anyway.
  - Culling cvars do not help: the NULL comes before culling.
- **The general rule this exposes:** on Claude's client, *any* game C++ that keeps a spawned VFX component without a null check is a latent crash. Native holders of UNiagaraComponent* from the CXX dump that are at risk:
  - `UTagActivatedFX.ActiveFXMap/ParticleSystems` (the same tag-driven pattern; the next guard candidate: its `FXSettingsMap`);
  - `AHeldEquipmentActor.FXSourceToAppliedFX` (enchant FX on held gear);
  - `UDominionStatusEffect.SpawnedVFX`;
  - `UDrainEffectManagerComponent.DrainVFX/BeamVFX` (spells);
  - `UDetectOreGameplayEffectInstance` ping VFX map and set (ore detection);
  - `UPlayerEnvironmentFXExtension.MoveThroughWater/PassThroughVFXComponent` (wading has been fine so far);
  - `ADominionProjectile` arrow head and trail;
  - `AFelledTree.CanopyCollapseVFXComponent` (woodcutting has been fine so far);
  - `UFarmSlotComponent` state VFX;
  - `ASwitchableTrap`, `ASaplingBase`, `ALightSourceBase`, `ADelayedDamage`, `AFireSpirit`/`UFireSpiritGameplayEffectInstance`, `UStationUpgradeComponent.NearbyCandidates`, `UAIBlockingComponent`, `APoolablePersistentVFXActor`.
  - Blueprint-only holders (e.g. BP_ScarabVolume) log "Accessed None" instead of crashing.
  - A new crash whose stack has a null `this` right after an effect or VFX trigger should be checked against this list first. Then add a `fxguard.GUARDS` row (the trigger table to empty), with a live repro.
- **Search (search-before-building):**
  - Searched "UE5 nullrhi Niagara spawn null", "RequestAsyncLoad null assets" and "CanEverRender Niagara": nothing documents this exact crash.
  - The `RequestAsyncLoad() called with empty or only null assets!` line comes in the same frame as the Dirty Water drinks (probably a soft-asset request of the Soulscourge status). It is not the crash: the NULL is the Niagara spawn, as the spawn test proves directly. Its origin is unverified.
  - Sources: dev.epicgames.com/documentation/unreal-engine/API/Runtime/Core/FApp/CanEverRender; docs.unrealengine.com/4.27/en-US/API/Plugins/Niagara/UNiagaraFunctionLibrary/SpawnSystemAttached; dev.epicgames.com/documentation/unreal-engine/API/Plugins/Niagara/FNiagaraWorldManager/ShouldPreCull; noesisengine.com/bugs/view.php?id=4987 (another NullRHI crash for want of a CanEverRender/GUsingNullRHI check).

## Creature spawns, power level and quest objectives for the GOAL draft cases (2026-10-26 ~19:50–20:10 UTC, dev server build 26161880, client 26162923, ClaudeDev in Temple Woods; live checks `tools/live_checks/pin_*.json`, evidence in `logs/live_queue/2026-10-26.jsonl`)
- **Asset paths offline:** the server's IoStore directory index (`RSDragonwilds-WindowsServer.utoc`) is plaintext and lists all 74 076 packages. `tools/utoc_list.py <utoc> --grep ... --game-paths` prints `/Game/...X.X_C` paths (Content/ = /Game/). There is NO `BP_AI_DireWolf_Character` and no *Thug* AI class.
- **Spawned creature classes (verified, loaded by the bench spawn fixture, `GetClass():GetFullName()` read back, AIName):**
  - Dire Wolf = `/Game/Gameplay/AI/Wolf/WolfEliteVariant/BP_AI_WolfElite_Character.BP_AI_WolfElite_Character_C`
  - Wolf = `/Game/Gameplay/AI/Wolf/BP_AI_Wolf_Character.BP_AI_Wolf_Character_C`
  - Goblin Runt = `/Game/Gameplay/AI/GoblinFaction/MeleeGoblin/RuntGoblinVariant/BP_AI_RuntGoblin_Character.BP_AI_RuntGoblin_Character_C`
  - Terrorbird = `/Game/Gameplay/AI/Terrorbird/BP_AI_Terrorbird_Character.BP_AI_Terrorbird_Character_C`
  - Ram = `/Game/Gameplay/AI/Ram/BP_AI_Ram_Character.BP_AI_Ram_Character_C`
  - Garou Berserker = `/Game/Gameplay/AI/BeastFaction/MediumBeast/BP_AI_MediumBeast_Character.BP_AI_MediumBeast_Character_C`; Garou Hunter = `.../BeastFaction/RangedBeast/BP_AI_RangedBeast_Character.BP_AI_RangedBeast_Character_C`
- **Power level of a spawned creature comes from neither the class nor the region:** a plain `World:SpawnActor` is always PL 1 (`PowerLevel` = `GetAIPowerLevel()` = 1, damage multiplier 1.0), in Temple Woods (PL 1) AND in Bramblemead Valley (PL 2, `pin_pl2_region_spawn`). PL1 HP: Dire Wolf 240, Wolf 60, Runt 60, Terrorbird 60, Ram 50, Garou Berserker 90, Garou Hunter 80. Natural spawners pass the level in `FAISpawnInfo.PowerLevel` (`ADominionAICharacter.SpawnInfo`, dump).
- **Spawn at a power level (verified):** `GameplayStatics:BeginDeferredActorSpawnFromClass(ctx, cls, {Translation, Rotation, Scale3D}, 1, nil, 0)` → write `SpawnInfo.PowerLevel` and `PowerLevel` → `FinishSpawningActor(actor, xf, 0)` (the same two calls UE4SS's own `World:SpawnActor` makes, docs.ue4ss.com UWorld). At 3: Dire Wolf 780 HP (wiki PL3: 780), Runt 195 HP (wiki PL3: 195), damage multiplier 1.6, the client census reads PL 3. Now the bench spawn fixture's `power_level` option (pending judge patch).
- **Cleanup without destroy:** `HealthComponent:DecreaseHealth(hp + 1, ctx)` kills a spawned creature through the game's own health path (no unpossess of an AI pawn); a dead Runt's corpse is gone a few seconds later. `mod/experiments/bench_creatures.lua` (read / kill / regions / spawn_pl, dev only) + the live queue's new `server` step and `cleanup` list.
- **Regions (BP_MapRegion_C.PowerLevel):** Temple Woods 1, Bramblemead Valley 2, Whispering Swamp 2, Fractured Plains 3, Bloodblight Swamp 3, Stormtouched Highlands 4, ... (31 regions). The dev world has one lodestone (Temple Woods).
- **Quest objectives (asset data, `client_mod/commands/quest_objectives.lua` → `client_io/out/quest_objectives.json`):** objective keys are FNames that are sometimes words ("Claim a bed") and sometimes numbered ("Objective2", "DR_Main_Objective_4_3"); `brain.situation.tokens` drops digits, so a `quest_step {step}` on a numbered key would match every objective of that quest. Dragon Slayer: 1 `Claim a bed` ("Construct a base of operations in Bramblemead village. Build a shelter and claim a bed."), 2 `Return to the Wise old man after claimed bed`, 3 `Find and hunt a deer`, ... 10 `Challenge Velgar`, 11 `Return to the Wise old man after killing velgar`. On ClaudeDev: First Steps given at Objective2, Shrimp Catcher given at SpeakToWom, the rest ungiven.

## Codex-period facts, consolidated 2026-10-31 (build 26161880)
Rewritten from the Codex audit (`docs/audit-2026-10-31/code_audit.md` §5). Where older Codex entries above lost their spaces, these supersede them.


1. **Player movement constants.**
   - Capsule radius 34 cm, half-height 88 cm, collision profile `Player`.
   - MaxStepHeight 45 cm, WalkableFloorAngle 45.5°.
   - Walk speed 450 cm/s; about 7 cm drift after releasing input; input callback about every 33 ms.
   - Source: Codex DISCOVERIES entries on native controls; PROGRESS around 10-28.
2. **Jumps.** Single jump 1.64 m; double jump 3.07 m (0.4 s delay between presses); a live djump edge rose 2.80 m (`client_io/events/traversal.jsonl`). The Windstep rise is unmeasured. Source: the `move_calib` run on 10-28 00:05Z.
3. **`K2_FindFloor` behaviour.**
   - +100 cm above the floor gives no floor; −20 cm gives walkable with negative FloorDist; −100 cm gives penetration.
   - The full-capsule return value distinguishes clear from blocked; the copied Distance does not.
   - The search start matters: hits at 43–47 cm, and a miss one step higher at FloorDist 47.4.
   - Source: `docs/research/r26-floor-observations-20261028.md`.
4. **KillZ death.** Steering at the raw goal after `no_path` walked into a `KillZVolume` and killed him; the player revived naturally. This is the reason for the route-authority rule. Source: DISCOVERIES "Grave-directed KillZ".
5. **Temple ramp.**
   - Normal player input climbs it (4.2 m in 3.1 s), but the default NPC navmesh routes behind it.
   - The oracle returns `no_path` for the same XY plus 50 m of Z.
   - A partial native path does not mean "no route".
   - Reading PathPoints by index works.
   - Source: DISCOVERIES "Temple ramp supports normal player walking"; `docs/research/2026-10-29-astra-navigation-review.md` evidence.
6. **Arbiter recompilation.** Ownership checks recompiled move.lua through the arbiter; fixed by reusing the active mover (3e95e40).
7. **Native item counts.** `pc.InventoryComponent:GetNumItemsByData(ItemData) -> int` gives native per-item counts for the main inventory (live 10-28, 20261028-115703).
8. **Water sources.** Water volume actors expose `WaterItemData` (the produced item); use it to verify collect_water (5913e5e; BUGS R8).
9. **Consumables.**
   - Only hotbar items can be consumed (`in_bag`), and `move_item` to the hotbar fails when it is full.
   - A second use pressed during the about-6 s use animation is ignored and the stat does not rise (20261027-203109).
10. **Lodestone.**
    - Build: `BUILDPIECE_Lodestone` costs 32 Stone, 20 Rune Essence and 1 Vault Core, and unlocked on receiving the materials. It gave 80 Construction XP (the catalog says 750).
    - Teleport: costs 2 Law Runes (5E74… → D0DF…, 20261028-191640). `TryTeleport(from.guid, to.guid)` after a real use triggers the success RPC.
    - Map UI: `MapUIAPI:IsShowingMap` can be false while the Map(13) / TopBar(29) widgets and `DIM_FullScreenUIMap` remain; `MainMenuUIAPI:NavigateBack(GetCurrentScreenWidget())` closes them.
11. **Crafting unlocks and costs.**
    - Interacting with the Crafting Table unlocked the Stone Logging Axe (native recipe count 83→90). Picking up Ash Logs and Stone alone did not (`IsRecipeUnlocked` false).
    - `RECIPE_Weapon_Hatchet_Stone` unlock rule: "ANY ITEMS[Ash Logs, Stone] AND ALL ACTORS[Crafting Table]".
    - Measured live:

      | Piece | Cost | XP |
      |---|---|---|
      | Crafting Table | 4 Ash Logs | +12 Construction |
      | Stone Logging Axe | 8 Ash Logs + 6 Stone | +20 Artisan |
      | Campfire | 6 Stone | +12 Construction (catalog says 20) |

    - Source: `logs/recovery/progress-native-cde2.json`; 20261028-182010.
12. **Crafting UI race.** The orphan-UI cleaner can close `DIM_CraftingMenu` before verification, giving a false `verification_failed`.
13. **Item categories.** recipe_data `category` holds the game's filter tags (e.g. `Item.Equipment.Weapon.2H.Axe`, `ItemFilter.Type.Consumable.Potion`).
14. **Provinces.** `AMapRegion.MapRegionTag` is hierarchical (`Location.Region.<Province>`); the provinces are `EQuestRegion` 1–6 (`dumps/26161880/luatypes/Dominion_enums.lua:3151`); all 31 region polygons are in `data/places_26161880.json`. NPCs have one copy per province (Luis).
15. **Windstep cast.** Costs 5 Air; shows tag `Player.Spell.WindStep` plus a `DominionStatusEffect` GE (`logs/recovery/no-axe-pilot-20261028-114914-c1fdfcc8.json`). Phase Dash showed zero horizontal displacement under the old probe.
16. **FX guard.** New pawns copy `TaggedLocalNiagaraSystems` from the class default objects. These were audited and are not needed: UTagActivatedFX, HeldEquipmentActor FX, StatusEffect SpawnedVFX, Drain/Beam (`fxguard.lua` header).
17. **Foliage conversion.** `NearbyFoliageConverterComponent` turns foliage instances into actors as he approaches (client.log "adopted", 82 hits).
18. **Model and harness behaviour.**
    - **Haiku 5.5** (thinking off) writes its reasoning into free text, hence the say-only channel. It still sometimes writes its chat line into the note.
    - **Sonnet 5.5 Director at 2048 max_tokens** truncated 4 plans. Use 4096 and reject `finish_reason=length`.
    - **LiteLLM 1.106 + Anthropic:** `tool_choice="none"` with the tools still defined stops further research calls; `auto` does not.
    - **Cost of a temple round trip:** about 40 calls (23 Haiku, 17 Sonnet), about 503 s. The Director needs about 5 hourly budget slots per trial. The day's spend was $2.42 for 152 calls.
    - **Truthfulness:** Haiku under-reported distance travelled ("only 40 m" after 200 m). Board and route records are the truth source.
    - **Log size:** full-request logging makes prompt rows about 83 KB.

### More Codex-period facts (kept from the dropped entries, 2026-10-31; build 26161880, client 26162923, dev world)
The ~70 original Codex entries (process evidence with stripped spaces) and the research notes they cite (`docs/research/r26-*`–`r29-*`, the astra/sol reviews) were deleted on 2026-10-31; read them at commit 41fa4cc. Raw evidence stays under `logs/recovery/` (gitignored).

19. **Spell effects (native probe, developer-cast).** Fire Spirit: 10 Fire Runes, adds `FireSpiritGameplayEffectInstance` and tag `Player.Status.FireSpirit`. Tempest Shield: 15 Air Runes, adds `BP_TempestShieldGameplayEffectInstance_C` and `Player.Status.TempestShield`. Windstep in the temple (a885) consumed 5 Air and moved him 0 m: a cast is not traversal. The loaded spell dump has the same 52 IDs as the catalog.
20. **Phase Dash.** With Agility 22 there is no Air Dash in `active_perks` (wiki: Air Dash at Agility 32; Phase Dash is an extra air dash); a directional evade after a fresh Phase Dash moved no further than without it (1.04 m vs 1.22 m). Likely prerequisite gap, unproven.
21. **Summon Shelter and daytime rest.** 10 Astral + 10 Earth Runes; places a shelter with `BedComponent` / `RestingAreaComponent`. Resting in it by day: `IsResting` true, `IsSleeping` false, `IsInTimeframeForSleep` false; endurance 33 → 54 in 20 s. Dehydration damage removed the first bed (consistent with "damage dispels"). `interact` returns `path_blocked` when already resting (BUGS R24).
22. **Felling and mining.** One Ash tree with the Stone Logging Axe: about 9 s, 4 swings / 3 hits, +13 Woodcutting XP, leaves an Ash Stump actor. A crafted Stone Pickaxe holds as `BP_Pickaxe_Stone_C`; one stone node gave 13 Stone (Mining 22 → 35).
23. **Clean Water.** Pond water collects as Dirty Water; the Campfire's real crafting UI turns 2 Dirty Water into 2 Clean Water (+1 Cooking XP each). Collect 2 + return + process took 81 s.
24. **Lodestones.** The sensed Lodestone has `kind=lodestone` and an `interact` affordance but no static prompt. `CanTeleport` is dynamic: for the same pair it read false about 19 m from the source and true about 1 m away, so a distant false is not "not unlocked". Observed teleport costs were 2 Law (129 m) and 1 Law (152 m to the Temple stone), so read the cost at use. Dev Temple lodestone `5E74232B4126EDE0BAEFF9856FFD03C6` at [50.65, 1890.26, -34.88] m.
25. **Death and graves.** `FatalDamageInfo` names the cause (`KillZVolume`, dehydration). `GameplayObjectRegistry.Gravestones` lists graves with an owner GUID matching `GetCharacterGuid`; the grave can be far from the remembered death point (46 m above it after a fall), so path to the registry grave, not the death position.
26. **Navigation data.** For the temple ramp, nil and explicit Default nav agents return the same partial path; Gigantic returns a complete path whose start is about 3.1 m off the real start, so switching agent is not a fix. Native route points are sparse: the walked floor differed by about 1.2 m from the straight line between two route points.
27. **UE4SS marshalling.** Packed bool fields copied out of a hooked function's output table can read true when false (the installed UE4SS's unmasked `GetNonTrivialLocal` bool branch); trust the native return value, not copied packed flags. Game time is latched inside a callback (durations read 0); use a wall clock.
28. **Pawn input getters.** `APawn.GetLastMovementInputVector` and the pending-input getter work read-only on the client.
29. **Ops.** Server about 0.46 GB resident / 1.2 GB private; client about 1.9 GB; the Codex desktop app about 1.6 GB. The dev server loads its own copy of `mod/experiments/*.lua`: after editing, verify the deployed copy, not the repo file. Deep worktree paths fail at 271 characters on Windows.

## Map compass: north = -Y, east = +X (2026-10-31, offline, game data build 26161880 + wiki mirror)
- **Fact:** on the world map, north is world **-Y** and east is **+X** (Unreal's left-handed axes seen from above: facing +X, +Y is to your right = south). `brain/geom.direction` used to assume +X = north, which turned every compass word 90° (map memory "direction", and the new "Where:" line).
- **How verified:** the centroids of the game's own region polygons (`data/places_26161880.json`) against the wiki's geography sentences (`data/wiki`): "Bramblemead Valley ... south of the Whispering Swamp and west of the Fractured Plains", "the Fractured Plains ... east of the Stormtouched Highlands and north of the Whispering Swamp", "[Umbral Sands] directly east of Ghornfell", "[Dowdun Reach] south of Silverthorn Keep, but north-east of Ghornfell", "Bleakfields Valley ... the southern part of the Fellhollow region", and Emberwood as the "most western part of Fellhollow". All of them hold with north = -Y, east = +X; most fail with +X = north. Pinned in `tests/test_places.py::test_compass_matches_the_wikis_geography_on_the_real_map`.
- **Not yet checked live:** the in-game compass widget (`UCompassWidget`) itself.

## UE4SS FindProperty cache: stale entries after a Blueprint class address is reused (client crash 2026-11-01 00:08:24 local; UE4SS 3.0.1 @83330635, game build 26161880 / client 26162923; cdb on `crash_2026_11_01_00_08_24.9751798.dmp` + UE4SS.dll disassembly; read-only)
- **Signature:** AV `or dword ptr [rax+2Ch],10h` with rax=0, i.e. `Package->SetPackageFlags(PKG_CompiledIn)` on the null result of `CreatePackage`, inside `UObjectBase::DeferredRegister` (rip exe+0x172b688; module bases in this dump: exe 0x7ff7b6da0000, UE4SS.dll 0x7ffe91b80000). It is called from `FTextProperty::DestroyValueInternal` (return exe+0x15c5217, loop over ArrayDim, `call [[TextData]+0x10]` = `ITextData::Release`). Chain: `UE4SS!FProperty::DestroyValue` ← `FText::~FText` (`FText::ValueOpsProperty`) ← `LuaType::FText::construct` ← `push_textproperty` (Get) ← UObject `__index` ← `process_lua_function` ← 8 Lua frames ← `Lua::call_function` ← UE4SS game-thread hook. The game log's last line, at the crash ms, is `LogUObjectGlobals: Warning: Attempted to create a package with a short package name: 襈⑜䠐沉… Outer: NullOuter`: UTF-16 of `48 89 5C 24 10 48 89 6C 24 18`, a function prologue passed as the package name. That line is the fingerprint, and no other crash log has it.
- **What was read:** the Lua key in r13 is `"DisplayName"`. The FTextProperty at 0x1286a426590 has Offset_Internal 0x300 (+0x44), ElementSize 0x10, and is owned by a native class. The container 0x1284b4d6df0 is a live, level-loaded actor (flags `0x00280008`, `PrimaryActorTick` vtable at +0x28) of a Blueprint class with **PropertiesSize 0x390**. Every `AWorldActor` subclass is ≥ 0x400 bytes, so the actor is not one. Its +0x300 holds `{UObject* asset (RF_Public|RF_Standalone), FName 0x79305c}`, which is `AWorldChest::ChestRespawnProfile` (`FDataTableRowHandle`@0x300, dump Dominion.hpp:12701). `AWorldActor::DisplayName` is `FText`@0x300 (Dominion.hpp:12657). The "FText" copy's TextData was therefore the UDataTable. Its vtable slot 1 (`RegisterDependencies`, a no-op) served as AddRef, and slot 2 (`DeferredRegister(UClass*, PackageName=garbage, …)`) as Release.
- **Mechanism:** UE4SS 3.0.1 `RC::Unreal::UStruct::FindProperty` (exported; UE4SS.dll+0x419890) first probes a function-static `unordered_map<{UStruct*, FName}, FProperty*>`: keys compared at node+0x10/+0x18, value at node+0x20, max load factor 1.0, 8 initial buckets. On a miss it walks the chain and inserts on a hit; misses are not stored. **Nothing evicts on class destruction.** UE4SS's `__index` (`LuaUObject.hpp` `prepare_to_handle`: `Cast<UStruct>(obj)` or `GetClassPrivate()` → `FindProperty`) and `Reflection():GetProperty` both use it. A World-Partition-streamed BP class (here an `AWorldActor` subclass whose `DisplayName` the census had read) was GC'd, and the chest's BP class was allocated at the same address (0x12889f99190; same-size UClass allocations reuse binned-malloc slots). The census's speculative `a.DisplayName` on the chest, normally a harmless miss, hit the old entry. `IsChildOf`/`IsA` are plain `SuperStruct` walks, and `GetFunctionByNameInChain` walks `Children` (its static is only an offset int), so only property reads are affected.
- **Why that journey:** the chat ladder's `go_to {"target": "Zanik"}` (a name) runs `client_bridge.find_thing(name, 500)`, which is a full `sense.census` at 500 m / 100 per category, right after the fixture teleport streamed cells out and in (game log 23:07:35 "Streaming performance changed: Good -> Critical"). The body-only ladder sends coordinates, so no census runs (`tools/travel_ladder.py` sends `P[goal]`). The crash came ~1 s after the go_to was sent (brain 23:08:23.98Z).
- **Upstream:** RE-UE4SS #1377 (open; Palworld; `FindProperty` + `FPropertyCacheKey` in the stack). The maintainer's view there was "a reloaded struct gets a new address → miss". This dump shows the opposite case: a **different** class at a **reused** address. No upstream fix found. UEPseudo, which holds `UStruct.cpp`, is private, so the fix (evict on `FUObjectDeleteListener`, which UE4SS already has for its object cache, #315) can't be built here.
- **Fix (Lua side, mechanism-level):** `U.prop(obj, name)` in mod/body/util.lua (risk register R17). It reads only when the class chain, walked live, declares the name and `obj:Reflection():GetProperty(name):GetFullName()` equals that declaration's full name; otherwise it returns nil without reading. Verified pairs are memoised by class full name + `GetAddress()`. Used by the census describers, `U.health`/`U.max_health` and bridge `inspect`/`contents_of`. Counters are in `census().prop_guard`, and stale hits print `[DWClient] ue4ss_prop_guard stale …` to UE4SS.log. Test `client_mod/tests/test_prop_guard.lua` (a fake UE4SS with the address-keyed cache; the raw read faults, U.prop does not).
- **Dump-reading notes:** FNamePool = exe+0xcd24c80 (Blocks at +0x10; found via `FName::ToString` exe+0x14d7410, which UE4SS.log prints as an absolute address). The minidump lacks exe .data and the permanent object pool (0x7ff4…), so names can't be resolved from it. Heap objects referenced from the stack are present, so match offsets and sizes against `dumps/26161880/CXXHeaderDump`. UE 5.6 FProperty: ArrayDim +0x30, ElementSize +0x34, PropertyFlags +0x38, Offset_Internal +0x44; UStruct: SuperStruct +0x40, Children +0x48, ChildProperties +0x50, PropertiesSize +0x58.

## Inventory drop amounts, the split handler, and pickup targeting (2026-11-01 12:01-12:25 UTC, dev, ClaudeDev; game build 26161880, client 26162923; probes in the pickups agent's scratchpad, results below)
- **`UInventoryUIAPI:HandleDropItem(SlotNum, SlotType, AmountOverride)` drops part of a stack** (verified live): an 18-stack at InventoryItems slot 1 with AmountOverride 2 left 16, and 2 stone landed at his feet.
- **An AmountOverride larger than THAT stack drops nothing, silently** (verified live: 20 from the 16-stack left 16; the pcall succeeded). This was the co-play failure, not a missing split: `inventory.drop` sent the whole count to the FIRST stack it found (Stone was 99 + 21; "drop 40" went to the 21-stack ×3; "drop 120" to the 99-stack). Fix: `inventory.drop_plan` uses the smallest stack that holds the whole count (bag before hotbar), else whole stacks largest first plus part of the next; one HandleDropItem per stack. Live: Stone 114 → drop 40 → 74 (from the 99-stack), drop 60 → 14 (a whole 59 + 1 from the 15), each verified by the count in 0.3 s; drop 500 → `not_enough_resources` "I only have 14 Stone."
- **Splitting a stack inside his own inventory = `HandleInternalSplitToSlot(FromSlotNum, FromSlotType, Amount, ToSlotNum, ToSlotType)`** (verified live: InventoryItems slot 1, 21 stone, Amount 3, to free slot 21 → 18 + 3; the new stack then dropped whole with HandleDropItem(21, InventoryItems, 3)). Scalars only. The same class also has `SplitStack` / `QuickSplitStack(UInventorySlotDragPayload*, Count)` (they need a drag payload object: not used) and `StartSplitSelection` / `StopSplitSelection` (UI state).
- **The interaction detector** (`pawn.InteractableDetector`, `BP_Components_InteractionDetector_C`): `PrimaryComponentTick.TickInterval` 0.1 s, `CameraRayLength` 2000 cm, `CharacterTraceDistance` 600, `CharacterTraceCapsuleSizeMultiplier` 1.1, `CharacterTraceDownwardsAdjustment` 50, `DetectionRange` 900. The camera boom (`CameraBoom`, TargetArmLength 700 cm) has location lag on (`bEnableCameraLag`, speed 10) and rotation lag off.
  - So an aim from the camera (client_bridge `aim_at`) converges over ~0.5-1.5 s: each re-aim swings the 7 m boom and the lagged camera. Aim probe on a mixed pile of 2 stone + 2 ash 1.1-2.0 m away, standing still: every item was highlighted by aim alone within ~1.8 s, and the first 1-2 reads after a re-aim still named the previous item.
  - In a pile, the highlight sits on whatever the ray meets first: often the nearer one, or another of the same item. Pressing then takes THAT one, as for a player. skills.lua presses a same-kind highlight (same item id, else the same class family) and names it (`took`, plus a detail line); the count is verified from the inventory.
- **Pickup timings, `interact` through the bridge, in reach:**
  - Before: 0.7-1.3 s when the exact one was highlighted, 5.5 s when it wasn't, and a **100.9 s timeout** on an ash branch 2.9 m away. move.go_to's local planner fired `wall_ahead` and spent ~10 s per plan on a 2.5 m walk; every go_to ended `stopped`.
  - After (aim-only look 1.5 s of a 2 s dwell; a straight `local_plan = false` walk for small things within 4 m; same-kind press): **0.6-0.9 s for 8 of 10 in a mixed pile, farthest first, 5 of them a named neighbour.** `fetch` of 3 Ash Logs took 1.7 s, and `fetch` of 100 Stone (3 stacks) 1.7 s.
- **A just-taken item can linger client-side for a moment:** `interact` on a stone he had taken 0.8 s earlier (as "the one beside it") still found its actor, so he pressed the highlighted neighbour, verified +1 Stone and named it. Three stones in a pile took 2.2 s in total. A census row whose actor is already gone is refused at once (`why = gone`; offline test).
- **Picked spawners and bushes read `available = false`** (census, `IsResourceAvailable`). The co-play session spent 18 s and 43 s on such ones. They are now refused at once (`why = depleted`, with the nearest available ones of the same kind), and `fetch` by name skips them.
- **Water holds the prompt only at the waterline** (consistent with "Drinkable water" above). A small item at a pond's edge, with him standing at the waterline, read `BP_WaterVolume_C` / "Collect Water" from all 5 spots. skills.lua now steps out to the item's far side first, then its sides, and refuses with "lies at the water's edge…" when every spot reads water. **Not yet verified live** (offline test only; no water within 120 m of where the client was during the test window).

## Combat self-defence and the 9-11 s navmem freeze (2026-11-01 12:36-12:39 UTC, dev, ClaudeDev; game build 26161880, client 26162923; combat agent)
- **The co-play "stood still while a runt hit him" (11:27Z) had three causes, all in client_mod/scripts/combat.lua:**
  - Spells ate the fight: `cast tempest_shield (ahead: dangerous attacker)` and two reactive Windsteps, each 0.7-2.2 s through the real spell inputs with no swing meanwhile (`F.casting` blocks presses). Both Windsteps went off after the hit had landed. Result: `fight end ok=true presses=0 hits=1`.
  - The odds were dishonest. The react-phase assessment scored him bare-handed (dps 5) before the equip phase drew the sword. The enemy rate `c.taken` was lifetime damage / (last hit - first hit ever), so one early burst froze it high. On the Rung 1 night a runt read "losing" at 82 HP and a Giant Rat at 100 HP.
  - The flee ran to Luis, who stood beside the runt (`move: follow d=958cm`, eats at 22/4/6/26 HP under its blows). Other flees ran 134-200 m (flee_timeout 45 s, unbounded legs).
- **Now:**
  - Spells only in a hard fight: the latest verdict is not likely_win, or a boss; `combat_orders.abilities = {name = true}` allows one in every fight.
  - Odds: from the weapon he will fight with (`F.pre_profile` before equip), his learned per-weapon hit damage (`c.hit_dmg`, persisted), and defense.lua `D.expected_dps(creature)` = learned damage x the share of its attacks that landed / its attack rhythm.
  - The flee is bounded by a leash (25 m from where it began, 15 s). One that keeps up with him (within 8 m at the leash) is fought (`flee_failed` activity, "it kept up with me for N m", next "fighting back"). A creature he ran from in the last 30 s is no new reason to run while it only stands near; if it hits him again he fights ("cornered").
  - He runs to the protected player only when that player is within 30 m and at least 8 m from every threat. He eats only with every threat at least 5 m away.
  - Low HP is no flee when he kills it in under half the time it needs to kill him ("finishing").
- **Live check (3 runts, Bronze Sword + Bronze Shield, parry perk):**
  - 12:36:32Z `why=hostile_near` at 8.1 m: react -> equip -> approach in 0.37 s, `parry -> parried`, 1 swing, killed, 0 damage.
  - 12:37:48Z the same at 9.2 m: `parry -> blocked`, killed, 0 damage. `combat_started` said decision fight, likely_win, weapon Bronze Sword, est 1 s to kill / 38 s to die (at 100 HP).
  - 12:38:52Z `why=attacking_me` at 2.2 m (the new telegraph-based threat, before its hit landed): `dodge -> hit` 18 dmg (key `?:unknown`: that swing had not been read, since no fight existed yet; now read between fights too), killed. 1 press = 60 damage dealt each time (`damage_dealt` 60).
- **lease_expired on a commanded `attack` = a 9-11 s game-thread freeze in `navmem.lua NM.plan`.**
  - move.lua `memory_once` calls it on the first tick of any go_to/follow over `mem_min_trip_cm` (30 m). The fight's arbiter lease (5 s) expires during the freeze.
  - Live: 12:38:26.715 `phase approach`, then no log line at all for 9.8 s, then `move: follow d=3391cm ... traces=1` and `fight end ... interrupted`. The co-play run had the same: 12:29:03.399 -> 12:29:11.966 (`follow d=3579cm`).
  - Reproduced offline on the real data/skills/dev/nav_memory.json (209 routes, 4560 points, 963 water cells): 9.3 s and 10.7 s for the two exact positions.
  - Cause: an O(n^2) join over every pair of route points, plus Dijkstra by linear scan, plus `cost()` re-converting every taboo per edge (~10^5 edges).
  - Fix: a grid bucket for the join (same edges), a binary-heap Dijkstra, and taboos converted once. Now 0.42 s (join 0.33 s), with identical cost_cm and point count on 8 old/new pairs (incl. no_connection and a learned link).
  - Remaining scaling risk: the memory grows; duplicate routes make the join dense.
- **Sources (search before building):** leash pattern from Don't Starve Together `Leash`/`LeashAndAvoid` behaviours (https://vietnd69.github.io/dst-api-webdocs/docs/game-scripts/behaviours/leashandavoid) and the MMO leash (https://warcraft.wiki.gg/wiki/Leash). mineflayer-pvp has no flee to reuse (https://github.com/TheDudeFromCI/mineflayer-pvp/blob/master/docs/api.md). No published Goblin Runt attack timings were found (https://dragonwilds.runescape.wiki/w/Monster), so they are learned per attack key. Grid-bucket neighbour search and heap Dijkstra are textbook.

## Players out of sight: the game map's registry on Claude's client; "near him" censuses (2026-11-01 12:20–12:55 UTC, game build 26161880, client 26162923, dev server, ClaudeDev; probes `client_mod/commands/map_players_probe.lua`, `map_guid_probe.lua`, `near_self_probe.lua`; retro 2026-11-01 root causes 3 and 4)
- **The registry replicates to the client.** `AGameplayObjectRegistry.PlayerCharacters` (one `GameplayObjectRegistry_UAID_…` actor) lists every player at any distance. Claude's own row "ClaudeDev" sat exactly at his pawn's position (113.77, 1848.69, -31.15), and later (440.11, 1807.76, -28.43) with RotationByte 219. Luis's row sat 330–435 m away while his PlayerState had **no pawn** (`PawnPrivate` nil: culled by net relevancy, ~150 m). Rows move as players move (re-read every 0.5 s).
- **The registry's name can be masked:** `OwningPlayerName` = `"luisdeburnayb***t"` (the game's name filter; the run of `*` is not always as long as the hidden letters). The PlayerState says `"luisdeburnaybast"`. **The join key:** the row's `OwningCharacterGuid.InnerGuid` equals `ADominionPlayerState.OwnerGuid.CharacterGuid.InnerGuid` (both B0E56055497E9F8CA6003C955B47A47F for Luis, both E71C5DC146F0A55B69FF52A881255DEF for Claude). So `mapplayers.lua` names each row after its PlayerState and keeps the masked name as `map_name`. Name matching (Lua `mapplayers.same_name`, Python `situation.same_player`) also treats `*` runs as wildcards and accepts a long name cut short (character "luisdeburnaybast" vs account "luisdeburnaybastos"; the shorter must be ≥ 8 chars).
- **Census cost on the live client:** full census (50 m, 20 per category) ≈ 203 ms; items + resources at 15 m ≈ 97 ms; the new `lean` items+resources census at 15 m = 62–86 ms. Hence get_state's `near_players` is a cached lean census (5 s, or when he moves more than 2 m), only for players in sight within 150 m.
- **Live census results:**
  - `map_players` = `[{name "luisdeburnaybast", distance 434.71, direction "W", bearing_deg 272, in_sight false}]`, with totals `players_online 2, map_players 1`.
  - The Players line: "luisdeburnaybast 435 m W (out of sight; go_to/follow go by his map marker)".
  - `near` with Claude as the anchor (pawn_of overridden in the probe): rows such as "Rune Essence 5.71 m behind", "Cabbage 6.09 m in front", with `from_me` = `distance`.
  - `near="NoSuchPlayer"` → `target_not_visible` "No player called NoSuchPlayer is in sight or on the map."
- **go_to to a far player (live 12:54:59):** `go_to luisdeburnaybastos` (the account name) at 353–362 m → "move: go_to luisdeburnaybast is out of sight; going by his marker on the game map at (40527,175699,-4149)"; the oracle route came back ~11 s later (src=nav) and he walked 48 m in 25 s until stopped. **A bug found and fixed:** `move.lua` drops a pending oracle request when the goal drifts more than 3 m (`repath_goal_move_cm`, line ~1842) and resets the wait clock. With a moving marker and an oracle answer that takes 2–11 s, it never got a route: "Moved 0 m in 12 s … planning" (12:45, 435 m). Now a map-marker goal re-asks only after drifting `M.MAP_REPATH_FRAC` = 15 % of the distance (≥ 3 m). The offline repro is in `test_move.lua` "a moving marker still gets its route and walks": without the fix, `planning x=0 requests=10`.
- **Directions:** compass words use north = -Y, east = +X ("Map compass" above). A thing's side of a player uses his actor yaw (UE yaw 0 = +X, +Y to his right): "in front" within ±50°, "behind" 130–230°.
- **Search (search-before-building):**
  - Found the idiomatic UE answer to minimap players beyond relevancy: replicate a lightweight location array instead of making pawns always-relevant. The game already does this (https://forums.unrealengine.com/t/is-it-ok-to-have-always-relevant-replication-option-set-to-true-on-lots-of-actors/716939).
  - Adapted mineflayer-pathfinder's dynamic `GoalFollow` (keep the same target, re-aim as it moves: https://github.com/PrismarineJS/mineflayer-pathfinder).
  - Used the UE4SS TArray/FString docs (https://docs.ue4ss.com/lua-api/classes/tarray.html, https://docs.ue4ss.com/lua-api/classes/fstring.html).
  - Found no existing Dragonwilds mod or tool that does this. The decision was to adapt (read the registry as lodestone.lua/places.lua already do; nothing built or written).
- **Follow-ups the same afternoon:**
  - 12:57Z: a commanded attack on a Kebbit 59 m away, after the navmem fix: `approach` 13:57:05.33 -> `move: memory: remembered route, 28 pts` 13:57:06.13 (0.8 s incl. the plan; was 9.8 s). He sprinted the route and killed it. No lease_expired.
  - 12:52Z, bare-handed after a 12:46 death (dehydration + poison from dirty water, not combat): a dodge-only fight became a loop. Each dodge carried him 2.5-3.3 m out of reach, and move.follow's stuck detector + local planner stood ~2 s per gap (`stuck n=1 ... local plan #1`), so the next swing came first (out_of_reach 36.7 s, 7 presses in a minute). Losing fast -> flee -> leash at 25 m -> cornered -> fought -> died at 12:53:56.
  - Now a gap of at most 5 m on his level is closed with the movement input in combat.lua (`step_in`), and the follow is kept for longer gaps and ledges.

## Survival mechanics, verified live (2026-11-01 13:00-13:40Z; build 26161880, client 26162923, dev world, ClaudeDev; survival agent)
- **Hunger and thirst alone don't kill; they leave him at about 1 HP.**
  - Starvation: at sustenance 0 he took 1 HP/s (status `starvation`) from 100 down to exactly 1.0. HP then stayed at 1.0 for 60 s (13:07:44-13:08:45) until he ate.
  - Dehydration: at hydration 0 he took 1 HP/s (status `dehydration`) down to 0.5, and stayed there (13:36:10-13:38:11+).
  - At that HP any hit kills him. This explains the co-play start at 0.5/100 HP (B12).
- **Environmental poison killed him twice** (`PoisonEmitterBox`, a Dominion `UPoisonEmitterBox` component, a `UTrackedStatusEmitterBox`). It deals 4 HP/s, status `poison` (EStatusEffectType 1).
  - 13:26:28-13:26:53 at [445.1, 1813.0, -30.5]: 100 to 0 in 25 s while another agent walked him. The damage row's `source` was `PoisonEmitterBox`.
  - 12:45:50-12:46:20 at [566.5, 1884.7, -47.5]: the same 4/s poison. He had been stuck there 12 s ("Moved 0 m"), and no source was logged then.
  - This is not Soulscourge. Dirty Water's build-up is the toxicity component (status `toxicity`, type 7). So the earlier "12:46 died of dehydration + poison from dirty water" is wrong about the cause.
  - `FindAllOf("PoisonEmitterBox")` found none from the respawn point (streamed out 350 m away), so the emitters' owners are still unknown. `client_mod/commands/poison_emitters_probe.lua` lists them when near. Damage rows now carry `source.owner`, `owner_class` and `at` for emitters (sense.lua).
- **Rest = the endurance component** (`BP_EnduranceComponent`). Live read with `client_mod/commands/survival_probe.lua`:
  - `EnduranceEffectLevels` are 0/25/50/75/100.
  - `EnduranceRemovedOnDeath` is 15, and `EnduranceRemovedFromSpellCast` is 0.15 per cast.
  - At endurance 14.8 his `StaminaComponent` max was 60, and his hydration and sustenance maxes were 75. This is the wiki's "Knackered" step (dragonwilds.runescape.wiki/w/Rest: max stamina 80 under 50, 60 under 25, 40 at 0; food and water capped at 75 under 25; a day nap +1/s; night sleep refills it and clears poison and Soulscourge).
  - A death at endurance 12.6 respawned him at 25.0 (13:26:53 to 13:27:00). The death penalty can't take him under 25, and here it raised him to 25.
- **Toxicity (the Soulscourge bar):** `pawn.BP_Components_Toxicity.CurrentToxicity` is readable (it read 0 at 13:2x after 3 Dirty Waters at 13:03). Its `ToxicityEffectLevels` is a single level at 100. The wiki gives 10 damage/s for 5 s when the bar fills.
- **Measured values:**
  - Collecting Dirty Water: `collect_water` 3 took 20 s, and 6 took about 30 s.
  - Boiling: one Campfire run turned 6 Dirty Water + 1 Ash Log into 6 Clean Water in 33 s (13:10:03-13:10:36), so it is 1:1 here.
  - Clean Water: +25 hydration (36.6 to 61.6).
  - Pumpkin Spice Infusion: +74.6 (0 to 74.6).
  - Forager's Sandwich: +57.9 (16.9 to 74.7).
  - Redberries: +4.8 each.
  - An empty-looking Redberry Bush (`fol:` id) gave 3 Redberries on interact.
  - `consume` eats even at full sustenance (74.7/75: 2 sandwiches wasted).
- **Spells for food:**
  - Bark to Bones on an Ash Tree worked (5 Animal Bones, 10 Earth + 10 Nature).
  - Bones to Peaches failed 5 of 5 tries: 4 times "RequiresBone", with the placement preview landing 1-3 m short of the bones on the ground, including bones dropped at his feet; once it ended `still_preparing` with no runes spent. **Open:** its aim can't reach a ground bone yet.
- **Respawn vitals vary:** hydration 41.3/75 and sustenance 25.0/75 at 12:46:27; 26.1 and 61.9 at 13:27:00. He respawns with nothing to eat or drink, so the first minutes after a death are a survival task.
- **Drain at rest under 25, standing still:** hydration 2.8/min, sustenance 4.2/min (13:31:41-13:33:11). Earlier, at rest above 25: sustenance 2.08/min.
- **Grave recovery, timed:** the brain's own path is `go_to my_grave` (the newest unrecovered death), then `look`, then `interact` (Take All).
  - The newest grave (12:53Z) took 70 s from the order to Take All (13:11:16.8 to 13:12:26.5; 218 m at 4.1 m/s).
  - The gear grave (12:46Z) took 72 s to Take All and 90 s to the Bronze Sword back in his hand (13:12:38.6 to 13:14:08.8; 259 m at 5.2 m/s).
  - The newest death was correctly next each time: commit b70292f holds.
  - The `recover_grave` compound (a debug tool, not offered to the model) instead looted the NEAREST own grave in sight, a week-old one 79 m away (bones, essence, a stone axe). He was starving to 1 HP on the way. It now prefers the newest death's grave and says when it took an older one (skills.lua).
- **Hot-reload hazard (13:24-13:36Z):** `walltime.lua` gained `stamp()`, but the running client's `require` cache still held the old module. Every `walltime.stamp(ev)` raised "attempt to call a nil value (field 'stamp')". That killed the vitals watcher (no rows from 13:33:11) and aborted every fed-reflex tick, so he could not drink.
  - Fixed with a guarded call in sense.lua and inventory.lua, plus `package.loaded.walltime = nil; require` in the live client.
  - gather.lua, chat.lua, combat.lua and spells.lua have the same unguarded call, but they are fine now that the cache is reloaded.

## Movement ladder: following a moving human, encumbrance, sprint drops (2026-11-01 13:20-14:53Z; game build 26161880, client 26162923, dev world, ClaudeDev; movement agent; tools/travel_ladder.py --follow)
- **Encumbrance (read-only, live):**
  - `pawn.PlayerEncumbranceComponent` exposes `IsEncumbered()`, `GetCurrentCarryWeight()` and `GetMaxCarryWeight()`. Measured at 13:2x: true, 446.5 / 300 (he carried 59 Ash Logs and more).
  - Effects observed live: about 0.6x walk (2.7 m/s), sprint and jumps fail. `CharacterMovement.MaxWalkSpeed` still reads 450, so speed alone does not show it.
  - Probe: `client_mod/commands/encumbrance_probe.lua`.
- **Claude's envelope this session:** double jump unlocked and measured (`env.double_jump` true, dj_delay 0.4 s), single-jump reach 164 cm, apex 180 cm, step 45.
- **Why the follow fell behind (ghost of Luis's 13:01:23-13:02:12 run, 182 m in 53 s):**
  - (1) Past 10 m the old code required an oracle route. Each 3 m the leader moved dropped the pending request, so Claude stood "planning" while the gap grew from 9 to 21 m.
  - (2) Sprint switched on only beyond 10 m: 4.5 m/s behind a 6.8 m/s sprint.
  - (3) Luis hops onto and along crates and wall tops 2.3-2.8 m up. His recorded track shows 0.2 s ground touches between air runs. Walking that trail exactly wedged Claude under the crumbs.
  - (4) **A jump ends the sprint.** IsSprinting reads false from take-off: 8 of 10 drops at 14:52 had jump=true, and most were airborne.
- **Human bar for following:** a perfect human follower (his path, 3 m behind, 0.5 s reaction, his speed) scores only 60-86% within 6 m on these tracks. At equal speed the gap peaks at 6.4 m right after each of his starts. A 90% bar is therefore stricter than a human on sprint-start-heavy tracks.
- **Sources (search-before-building):**
  - mineflayer-pathfinder GoalFollow re-paths to a moving entity (dynamic goal; thinkTimeout 5 s, tickTimeout 40 ms). This is exactly what stood still here, because each re-path waited for a slow planner.
  - The breadcrumb-follow companion pattern (Unity "Breadcrumb AI" asset; bugnet.io companion-stuck guide).
  - Detour `dtPathCorridor::optimizePathVisibility` (string-pulling shortcut; recastnav.com, dev.epicgames.com).
  - Decision: **adapt**. Breadcrumbs lead while the leader is in sight; the trail is re-entered by the shortest way to him; segments he took over obstacles above Claude's reach are skipped. The full visibility shortcut is not built (crumbs at 0.5 m with a 1.2 m advance radius already track his path).

## Survival, second live window (2026-11-01 13:53-14:04Z; build 26161880, client 26162923, dev world, ClaudeDev; survival agent)
- **The floor reflex works live.** He started at 0.5 HP, water 0/75 and food 0/75, carrying nothing.
  - `collect_water` 6 (13:53:50-13:54:15) put Dirty Water in his bag. At 13:54:14 the reflex drank one by itself ("water 0/75 is under the 10% safety floor and Dirty Water is all I have (+20 Soulscourge, toxicity 0/100)"), +9.8. Above the floor it held the rest back ("kept for the safety floor").
  - `craft Clean Water` x5 with Ash Logs at a Campfire made 4 (one Dirty Water was already drunk).
  - Under the floor, the reflex left the open Processing screen (`floor_leave`) to drink Clean Water: 8.2 to 32.8, then 29.7 to 54.4 (40% policy).
  - The bag-to-hotbar fetch under the floor is not verified live yet: every drink was already on the hotbar. It passes the Lua tests only.
- **The 13:26 grave was recovered in 40 s.** `go_to my_grave` took him to the newest grave (BP_PlayerGravestone_C_2147228791, at the poison death site): 49 m in 21 s (14:00:30.3-14:00:51.7). Take All finished at 14:01:10.1.
  - The reflex ate a Forager's Sandwich 1 s later (food 0 to 74.9). HP climbed +1.5/s from 0.5 to 100 (the sandwich's healing over time).
  - Bronze Sword equipped at 14:01:21.8: 51.5 s from the order to gear on.
  - A Goblin Runt attacked at 14:01:34 (one hit, 18 damage). The combat guard killed it in about 3 s.
  - At 0.5 HP that hit would have killed him, so a starving or dehydrated Claude near a camp is one hit from death.
- **No PoisonEmitterBox was loaded** 49 m from the 13:26 poison death site, nor near the 12:45 site. `FindAllOf("TrackedStatusEmitterBox")` (subclasses included) found 35 emitters: BurningEmitterBox on campfires, SlowEmitterBox on water volumes, and BP_QuickSandVolume boxes.
  - So the poison was transient, not a fixed zone. Both poison deaths were near an enemy camp: [445,1813] is 32 m from a BP_Enemy_Campfire_InGameTime at [414.6,1802.1], and [566,1884] is 20 m from one at [578.0,1868.2].
  - **[UNVERIFIED]** It looks like an enemy's poison attack or cloud (goblin camps). A damage row's `source.owner` will name it next time.
- **Sleep in his own Summon Shelter refilled rest at once.**
  - The cast's first try was refused ("ground not flat enough"); the second found a spot itself (10 Astral + 10 Earth, 8.9 s).
  - `interact` on BP_Magic_SummonShelter_C (prompt "Sleep") at 14:02:36.6 put him in `DIM_Resting`. By 14:02:41: endurance 11.8 to 100, maxes 75 to 100, HP 100.
  - The sleep cost 15.8 water (43.2 to 27.4) and 11.9 food (70.8 to 58.9): the cost of the skipped hours.
  - This was a full sleep, not a +1/s nap, even though `needs` had said "sleep timeframe closed" at 13:56, so check the time of day before saying which rest applies.
  - After waking, rest drained about 0.6/min while standing.
- `tools/preflight.py` read READY at 14:03:58: health 100%, water 52%, food 59%, rest 99%, food 12 / drink 20 carried, Bronze Sword, Adventurer's Tunic and legs.
## Food and drink values, and the options digest (2026-11-01 13:30-14:15Z; build 26161880; needs-options agent)
- **Where the values live (game data, from the dump `dumps/26161880`):**
  - Food: `UFoodItemData` (`SustenanceRowHandle`, `VitalShieldRowHandle`, `ToxicityRowHandle`, `AmountToHealOnConsume`).
  - Drink: `UDrinkItemData` (`HydrationRowHandle`, `ToxicityRowHandle`, `WitherRowHandle`, `EnduranceRowHandle`).
  - Both are `UBuffItemData : UConsumableItemData` (`Duration`, `ItemUsageDelay`, `UseVerb`).
  - Rows:
    - `FFoodSustenance` (StatText, Sustenance, DecayBuffer) in `/Game/Gameplay/Items/Consumables/Food/DT_FoodSustenance`;
    - `FDrinkHydration` (Hydration, DecayBuffer) in `.../Food/DT_DrinkHydration`;
    - `FToxicityTableRow.Toxicity` in `.../Consumables/DT_Toxicity_V2`;
    - `FWitherTableRow.Wither` in `DT_Wither_V2`;
    - rest in `.../Food/DT_RestEndurance`.
  - Read-only probe: `client_mod/commands/food_values_probe.lua` (FindAllOf the item data, then FindRow through each handle's own DataTable). **Verified live 14:57Z, 0.8 s, no errors:**
    - 137 food and 23 drink item datas were loaded.
    - Rows: DT_FoodSustenance 120 (`FoodSustenance`), DT_DrinkHydration 21 (`DrinkHydration`), DT_Toxicity_V2 8 (`ToxicityTableRow`), DT_RestEndurance 2 (`SurvivalBuffDataRow`), DT_Wither_V2 1.
    - Row names look like `v3_Redberry` and `Sandwhich_Veggie` (sic). `ItemUsageDelay` is 0.01. Forager's Sandwich `Duration` is 600 s (its HP comes over time).
    - **Redberries heal 10** (the wiki gives none).
    - **Burnt food carries +20 Soulscourge** (`ToxicityRowHandle` "+20" on Burnt Redberries and others), and its values differ from the wiki's: Burnt Redberries +5 (wiki 10), Burnt Bread +20.
    - Meat Stew's `AmountToHealOnConsume` is 0 (wiki 50: probably a buff, **[UNVERIFIED]**).
    - Not loaded on the client, so absent from the probe: Goblin Pack (an `ItemEmitter`), Bird Nest, Steak.
  - `data/food_values_26161880.json` now has 156 of 158 items from live rows (live wins, with the wiki revid kept as a fallback `src`).
- **Values now used (wiki, per-page revid kept as `src`; `tools/gen_food_values.py` -> `data/food_values_26161880.json`, where a live probe row wins):**

  | Item | Food | HP | Water | Other |
  |---|---|---|---|---|
  | Redberries | +5 | | | |
  | Dried Redberries | +15 | +20 | | |
  | Fillet, Fried Egg, Rat Roast | +20 | +20 | | |
  | Steak | +20 | +30 | | |
  | Forager's Sandwich | +80 | +70 | | |
  | Meat Sandwich | +85 | +80 | | |
  | Glazed Pumpkin Sandwich | +100 | +80 | | |
  | Clean Water | | | +25 | |
  | Dirty Water | | | +10 | +20 Soulscourge |
  | Pumpkin Spice Infusion | | | +80 | |

  - These agree with the survival agent's live deltas above: Redberries +4.8; Clean Water +25; Forager's Sandwich and Pumpkin Spice both stop at the 75 max.
  - Drops (wiki):
    - Chicken: Raw Bird Meat + Egg (+ Feathers).
    - Cow PL2: 2 Raw Farm Meat (+75% one more).
    - Giant Rat: Raw Rat Meat.
    - **Kebbit: Coarse Animal Fur + 50% Animal Hide Scraps, no meat** (Luis, co-play).
  - Redberry Bush: 3 Redberries, respawn 0.5 days. Cooking burn = wiki Culinary Confidence (no-burn 50% at a tier's start level, +2-4.55% per level, cap 100%).
- **No datamined food table was found online.** Searched: "dragonwilds food values datamine", "DT_FoodSustenance", and the Nexus and GitHub Dragonwilds repos. metabot.gg/en/dragonwilds/items lists items with weight, stack size and skill, but no food or water values (checked 14:15Z). The wiki infoboxes are the only public copy found.
- **The vitals drain rate counted the fall across a death as drain.** At 11:19:45 the rate read 41.2 food and 54.5 water per minute, 59 s after a respawn. The real rate is about 2-4/min. The death removes 10 water (`HydrationRemovedOnDeath`), and respawn vitals vary. The brain was told "empty in ~1 min" at 42% food.
  - `skills.lua` now skips falls before `DW_LIFE.died_at/respawned_at` (test_skills 74/74). It is live at the client's next skills reload.
- **Decision: utility-style options, not GOAP or rules (search-before-building).**
  - Searched:
    - GOAP / utility AI for need satisfaction in survival games (gamedev.net "help me understand utility AI");
    - mineflayer-auto-eat (it picks food by `foodPoints` / `saturation`, a fixed priority);
    - the Dragonwilds wiki pages on Food, Cooking, Dried Redberries, Culinary Confidence and Dirty Water;
    - docs.ue4ss.com UDataTable (FindRow, ForEachRow).
  - Decision: **adapt**.
    - The UE4SS FindRow pattern (as in build.lua) and the wiki generators (`tools/gen_*`) supply the data.
    - The digest scores nothing, so the model does the utility comparison. Each option carries the same considerations a utility AI would weigh: gain, time, level after, how long it lasts, place and risk.
    - auto-eat's fixed priority is the "prefer X" rule Luis ruled out.
  - Sources: https://docs.ue4ss.com/lua-api/classes/udatatable.html, https://dragonwilds.runescape.wiki/w/Food, https://dragonwilds.runescape.wiki/w/Culinary_Confidence, https://dragonwilds.runescape.wiki/w/Dried_Redberries, https://github.com/link-discord/mineflayer-auto-eat, https://www.gamedev.net/forums/topic/686840-help-me-understand-utility-ai/, https://metabot.gg/en/dragonwilds/items.
- **Eval (Haiku 5.5, controller effort low, 10 calls, $0.02):**
  - Raw berries at 3% food: 2/2. Boiling dirty water: 2/2.
  - Grave food: 0/3. Hunt and cook: 0/3. He took the nearest berries for +15 every time, saying "starving".
  - Two causes were found and fixed in the digest and persona:
    - persona example 2 primed "starving" + berries;
    - the option text buried the outcome.
  - Every option now leads with `[~time -> +gain, level after, lasts ~N min]`. Not re-evaluated: the 10-call budget was spent.
- **Live check 1 (14:57Z, the real brain, dev world):** water 44% with Clean Water on the hotbar. The stay-fed reflex drank one at 40% on its own (+25, about 37 s into the window). No model call was needed: the body handles carried hotbar items.
- **Live check 2 (15:17-15:21Z, fixture, restored):** his one hotbar food (Forager's Sandwich) went to the bag, and the eat-below line went to 90% so the reflex could not eat.
  - At food 48% the vitals_low event came in. The model saw the digest (two blocks; the food one: bag Redberries, Sandwich and Fillet x18; the grave with 45 sandwiches at 453 m; a Redberry Bush 9 m away; Dried Redberries; cook the Egg at the Campfire 16 m away).
  - He picked **move_item Fillet + consume Fillet**: the LLM answered in 2.0 s, and food went from 47.9 to 67.9 4.8 s after the event. The next turn drank Clean Water (39.6 to 64.6). Then he was silent.
  - No berries, so the berries bias is gone here. He kept his last sandwich, which is a defensible choice.
  - **The event came 175 s after the brain started.** The body's vitals_low repeats every 180 s (client_bridge VITALS_REPEAT_S). The first one went out before the brain had connected and was lost **[likely, not verified]**. A brain (re)start does not re-read low needs until the next repeat.
- **Fixed: a low need at brain start is raised at once.** After warm_up, `LiveSession.raise_standing_lows` reads get_state once. `needs_options.startup_lows` raises the body's own VitalsLow for each need under his policy line with no hotbar consumable of that kind. Live 15:48-15:52Z: the event came 13.9-19.4 s after the brain started (warm-up), not up to 180 s.
- **The drain rate was bogus after a nap or a harness step (fixed in `skills.lua`).**
  - The rate was the *steepest* fall between samples. A nap in the Summon Shelter fast-forwards the clock, and the rate read 16.6 water/min (awake 5.2-5.7 water and 4.2-4.3 food per minute, 8 logs). The digest then said "empty in ~4 min" at 66% water. A `set_stat` fixture step would have read about 200/min.
  - Now samples taken while lying in a bed or shelter (`W.resting_in`) are left out, and the rate is the *upper median* of the falls (test_skills 77/77). Live after the fixture steps: 5.52 water and 4.15 food per minute.
- **The stay-fed reflex and the brain race for the same need** (live 15:49Z and 16:20Z).
  - The reflex (inventory.lua) runs a 2 s tick. Under the line it uses the first clean hotbar item of the kind, by slot (`best()`), at most once per kind per 6 s (`cooldown_s`).
  - When the model moves a drink to the hotbar and then queues `consume`, the reflex drinks it within about 2 s. His own consume then runs on a full bar.
    - 15:49Z: a Pumpkin Spice Infusion went 99.5 -> 99.7, and the body said "wasted".
    - 15:51Z: another went 98.2 -> 100.
    - 16:20Z: he drank a Clean Water that the reflex had already covered, which delayed his second Fillet by about 6 s.
  - The body now reports `vitals_policy.reflex_on` and `reflex_every_s` (skills.lua, read from `inventory.reflex_status()`). The brain tells the model what the reflex will do:
    - the situation's Reflex line gains "Below a line your body uses food/drink from your hotbar by itself, one per kind every ~6 s (from the bag only under 10%)";
    - for a bag item that the reflex will be the one to use, the digest step reads "move_item to the hotbar: under your line your reflex drinks one by itself within ~2 s, nothing more to do";
    - on the reflex's own hotbar pick it reads "your reflex is already eating these by itself, one every ~6 s, until you're over your 40% line".
  - Live 16:35Z, with the note in his prompt: he still queued the Clean Water, now to fill up to 100%, at the cost of his second Fillet. The information is there, and Haiku at low effort still doubles up.
- **One use locks the next for ~6 s.** Every food or drink use seems to wait out the ~6 s use animation (consumables #9). The consume tool takes 2.8-6.0 s per use, and up to 8.8 s when the reflex's use runs first. In Luis's recording `evals/baselines/rec_luis_20261101T123634Z.jsonl.gz`, gaps between uses of the same slot cluster at 6.09-6.14 s. **[UNVERIFIED]**: the recording does not say whose rpcs they are, and the reflex's cooldown is also 6 s.
  - So from 12% food and 12% water with Fillets and Clean Water (+20 and +25), any player needs 4 uses, about 24 s. With Vegetable Soup and Pumpkin Spice from the bag it needs 2 uses, about 12 s plus the moves.
  - The Rung 1 gate's eat_drink T_h is 1.5 + 2 x 1.5 s (`standard_score.PROVISIONAL["eat_drink"] = 1.5` per use_item rpc). Its 6.75 s bar is below what the game allows.
- **Live runs (dev world, the real brain, no supply top-up; his hotbar restored after each run).**
  - Scratch harness, raised line (15:36-15:41Z): food 94% with the line set to 95%. That is not a need, and he slept instead because he was tired at 29% at night. Water: consume from the bag failed `in_bag` once, then move_item + consume took 6.1 s. Binned: a raised line is not a real need.
  - Scratch harness, `set_stat` to 20-30% under his own 40% line, the need's hotbar items moved to the bag (15:48-15:52Z, before the reflex notes):
    - 25/25: Pumpkin Spice and 3 Fillets, 18.4 s, one Pumpkin wasted in the race;
    - 20/30: Pumpkin Spice, while the reflex ate the Fillets, about 18 s. He said "then i'll sort a fire" and never did; the fire line was heading both blocks, because options now open with the bracket and the "after carried" check missed them. Also one 5.6 s stand while the reflex ate;
    - 30/20: Pumpkin Spice and 4 Fillets, 18.8 s, one Pumpkin drink 98 -> 100. He said "starving and parched" at hungry 28% and thirsty 19%.
  - Rung 1 gate `tools/rung1_gate.py --only eat_drink` (12%/12%, hotbar as he had it), 16:10-16:21Z: 12.9 s, 13.2 s and 25.8 s. **Fails on time only**, against T_h 4.5 s. Misses 0, stands 0, truthful 3/3. Run 3 had only Fillets and Clean Water, so 4 uses plus the race. Second batch, 16:34-16:41Z, with the reflex notes:
    - 27.9 s: a Fillet, then a Clean Water to fill up while the reflex drank, then go_to his grave at 31% food;
    - 45.3 s: FAIL on time, misses and truth. Run 4's go_to was still running ("stop left-over jobs: failed: busy"), so he was at the grave, and he died there 13 s in. The cause is not in his events. He said "starving got me" at 12% food, a made-up cause;
    - 19.9 s: two Fillets while the reflex took the water, no double-up. Fails on time only.
    - Under a T_h built on the game's use lock, 1.5 + (fewest uses) x 6.1 s, the clean runs (12.9, 13.2, 25.8, 27.9 and 19.9 s) are all within 1.5x.

### Deconstruct: taking down built pieces the player's way (2026-11-01, server build 26161880, client 26162923)
- **Path (the real client input; no RPC built by us):**
  1. `IA_BuildMenu` (B) puts `BuildModeComponent.CurrentBuildMode` in Selection.
  2. `BuildModeComponent.ToggleRepairAndEditModeAction` (T) switches it to `RepairAndEdit`.
  3. Aim the camera (`SetControlRotation`).
  4. `BuildInteractionComponent.DestroyBuildingAction` (MMB, Pressed trigger) is injected through `build.W.press`.
  5. The game itself sends `Server_Interact(PieceID, EBuildInteractionType Destroy = 3, inventories, location)`.
  6. The server answers with the `Client_TelemetryDestroyPlacedPiece` post-hook; `CurrentRes` = the refund amounts, e.g. `[8]` for a crate and `[1, 1]` for a torch.
  - `DestroyBuildingHoldAction` was not needed.
- **Refund:**
  - It is 100% of the cost; e.g. the Crate refunds 8 Ash Logs, the Wall-mounted Torch 1 Ash Log + 1 Coarse Animal Fur.
  - It spawns as `BP_RuntimeSpawnedWorldItem_NoExpiry_C` beside the piece. The game's item magnet takes it into the bag about 1 s later when Claude is within about 1.5 m.
  - So the job total is the bag's gain over the whole job in the cost's items, plus anything the census still shows on the ground. Summing the bag gain and the drops double-counted it (14:2xZ).
- **Target signal: `BuildInteractionComponent.TargetedPieceHandle` (FBuildingPieceHandle {PieceResolver, Context}).**
  - **Instance pieces** (foundation, wall, roof, tile; no client actor):
    - The resolver is `LightweightBuildingPieceManager` and `Context` = the pid.
    - This was 0 in the first crate session only because a crate is an actor piece.
  - **Actor pieces** (crate, torch, stations):
    - `Context` stays 0 and the resolver reads nil.
    - The pre-press signal is our own camera view-ray `KismetSystemLibrary.LineTraceSingle` (channel 0). It hits the actor's `Mesh` (profile `BuildingPlaced`, object type 27), and its owner's `BuildingPieceID` gives the pid.
  - `Server_RegisterTargetPiece` never shows on the client (client-side hooks on Server_ RPCs don't fire).
- **The camera hangs ~5.8 m behind the pawn and swings round it when the view turns:**
  - camera at x 89.03 vs pawn 94.86, `PlayerCameraManager.CameraCachePrivate.POV`;
  - so a rotation computed from the camera's old spot missed a 0.2 m torch by 0.27 m and highlighted the wall behind it (14:27Z, 14:31Z, "not_interactable");
  - fix: aim from the point of the camera ray nearest the head, then re-aim until the ray passes within 0.06 m (`W.aim`, `W.aim_miss`). Live 14:34Z: the torch came down on the first aim.
- **Line of sight:**
  - The game highlights the first piece the view ray meets, so a torch on a wall's inner face must be aimed at from inside.
  - The stand picker tests eye → aim point against every other piece's box (slab test, `M.blocker`) and refuses stands inside a box (`M.clear_stand`).
  - Boxes come from `BuildingPieceLocalBounds` (actor) or `BuildingPieceDerivedData`. Walls are 1.0 m thick in this data, so 0.25 m of entry before the aim point is ignored.
  - A foundation's location is its top, with the box hanging below.
- **Refusals:** the game's own words come from `DestroyRequestNotificationTextMap` (EBuildingDestroyRequestResult), e.g. CantDestroyWhileNotEmpty and CantDestroyProtected. The per-actor pre-check is `ABaseBuildingActor:CanBeDestroyedByPlayer(pc)`.
- **Contents:**
  - `inventory.inventory_of` returns nil for buildings.
  - A container's or station's items are in `InventoryComponent` subobjects, found with `FindAllOf("InventoryComponent")` + `GetOwner()` == the actor, then `ItemSlots`.
  - The Campfire held 77 items and the Spinning Wheel 2. Both were left.
- **Ownership:** no per-piece owner is readable on the client.
  - "Mine" = the ledger `data/skills/<world>/my_pieces.json` (piece + position, since pids renumber on reload).
  - It is filled from `Client_TelemetryOnBuildingPieceComplete`, which fires only for the builder.
- **Support:**
  - `FBuildingPieceState` stability: ground foundations 1515 (max), walls 1290/965, roofs ~808, stations on a floor ~1514.
  - Every foundation of Luis's house read 1515, i.e. ground-supported on its own, so removing some does not drop the ones a station stands on.
  - Guides confirm that removing a supporting piece takes its dependents with it, hence the top-down order and the collateral stop.
- **Decision (search-before-building): adapt.**
  - Searched: "Dragonwilds delete/remove/destroy structures", "repair mode middle mouse", refund/ownership, Nexus and GitHub for a Dragonwilds build or deconstruct mod, and Valheim PlanBuild / mineflayer / Mindcraft "dig/break block" skills.
  - Found: player guides (B → T → aim → MMB, full refund dropped on the ground, connected pieces collapse). No mod or tool drives it. The bot-framework pattern is approach → look at → break → verify gone → collect drops.
  - Built only the glue in `client_mod/scripts/deconstruct.lua`, on build.lua's input/aim/trace helpers and the arbiter/input-claim pattern.
  - Sources:
    - https://primagames.com/tips/how-to-delete-building-structures-runescape-dragonwilds
    - https://www.sportskeeda.com/mmo/runescape-dragonwilds-move-remove-delete-structures-building
    - https://thebackdash.com/?p=26707
    - https://deltiasgaming.com/?p=205159
    - https://raw.githubusercontent.com/kolbytn/mindcraft/main/src/agent/library/skills.js
- **Verified live (dev world):**
  - 14:2xZ: Claude's own Crate in 10 s (+8 Ash Logs).
  - 14:34Z: a Wall-mounted Torch of Luis's house in 9 s (+1 Ash Log, +1 Coarse Animal Fur).
  - 14:34:55-14:38:25Z: `deconstruct {target: BuildingPiece_27, whole: true}` took down the other 28 pieces of Luis's house in 207 s, at 2.7-20 s per piece and one destroy press per piece. Top first: 2 torches, a tile, 8 roofs, 12 walls, then 5 foundations. There was no collateral and no collapse.
  - Refund: 114 Ash Logs + 2 Coarse Animal Fur went into the bag via walk-over. 8 Ash Logs (2 drops) stayed on the ground and were picked up with `fetch`. Total for the house: 123 Ash Logs + 3 Coarse Animal Fur, exactly its cost.
  - Left as planned:
    - Crafting Table and Tannery: not Claude's;
    - Campfire (holds 77 Ash Logs) and Spinning Wheel (2 Fur);
    - 3 Ash farm plots;
    - foundations 19/20/21 and 23, which those stations stand on.

## Pick up on the move: the sweep (2026-11-01 14:05-14:52Z, dev, ClaudeDev; game build 26161880, client 26162923; pickup agent; tools/pickup_ladder.py, scored from the server recorder)
- **Pressing E (one IA_Interact frame) while walking picks up ground spawners** (sticks `BP_Spawner_AshBranch_0x_C`, stones `BP_Spawner_Stone_C`, cabbage, flax, `BP_RedberryBush_C`): 70 presses in 4 runs, most at 1.5-4.5 m/s, and every one gained an item (the recorder's few "miss" rows are two presses 0.2 s apart whose gains it credits to the later one). No stop, no aim: move.lua steers with camera pitch 0, and the game's detector still offers a ground item **1.2-3.5 m ahead** (3D, capsule centre to actor) on the move, so the forward character trace is enough. Luis's own presses: 1.0-3.0 m.
- **The detector moves to the next item as soon as one is taken**; a taken one is gone in ~0.1 s (`IsResourceAvailable` false, logged "picked" 0.09-0.14 s after the press).
- **A straight move.go_to under ~1 m does not move him** (live 14:08:45Z: goal 0.98 m away, tolerance 0.5 m, stood 3.5 s until the stuck ladder's local plan). move.lua's waypoint radius is 1.2 m (`wp_radius_cm`), which is the likely cause (not read further). gather now creeps at a target closer than 1.3 m (camera aimed at it, movement input 0.5) instead.
- **Foliage adoption must take the NEAREST actor:** a converted pickup spawns at its instance's spot; "the first matching actor within 2 m" adopted a neighbour in a dense patch, and the neighbour was then faced for 8 s ("detector never targeted it").
- **Over the carry weight he walks at 2.7 m/s** (see the movement ladder entry): the first sticks run (470/400) moved at a flat 2.7 m/s. The ladder unloads its own kinds at a dump spot before a leg when he is encumbered.
- **Lua trap:** `cond and false or nil` is always nil, so `local_plan = false` never reached move (found by the movement agent). Build it with an if.
- **The client's inventory count lags a pickup press by 0.4 to ~1.2 s** (rocks leg 14:4xZ: the 6th stone's gain was not yet in `inventory.list` 0.6 s after its press, so the stop-and-press fallback pressed a 7th; the recorder saw 7 presses and 7 stones). Count a press as owed until it gains or 2.5 s pass (gather.lua `sweep_owed`), and stop pressing while the owed presses cover the ask. One redberry bush press gives up to 3 berries, so a berry ask can end over its count, as it does for a player.
- **Some picks yield a second kind** (recorder, sweep-r3 16:13Z): a `Spawner_Cabbage` press gave +1 Cabbage, and once +2 Cabbage (two presses credited together) with +2 Cabbage Seeds (`ITEM_Farming_Seed_Cabbage`); a `Spawner_Flax` press gave +1 Flax +1 Flax Seeds (`ITEM_Farming_Seed_Flax`). gather names them in its result ("with them"), from the inventory deltas.
- **It holds over 3 runs** (sweep-v2 14:48Z, sweep-r2 15:26Z, sweep-r3 16:13Z): 27 of 28 legs within 1.5x Luis, 152 items, **0.73 s per item, 0.97 presses per item, 93 % on the move** (Luis 1.12 s, 1.04, 88 %); per-leg median 0.76 s, worst 1.4 s. Mixed clusters (cabbage, flax, berries) 0.36-0.93 s per item whenever they had respawned. Crop patches take longer than an hour to respawn; sticks and stones are back within ~40 min.
- **Result (pickup ladder, 10 natural patches where Luis picked, unencumbered, label sweep-v2):** 53 items, **0.64 s per item, 0.96 presses per item, 96 % of presses on the move**, every patch within 1.5x Luis (his pickup unit 1.12 s, 1.04 presses, 85/97 on the move). Before (same patch, the old stop-and-press, encumbered both times): 2.45 s per item and 0 % on the move vs 1.49 s and 88 % with the sweep.
- **Decision (search-before-building):** adapt. mineflayer-collectblock collects a target list nearest-first, re-picking the closest each step and awaiting each `goto` (https://github.com/PrismarineJS/mineflayer-collectblock, src/CollectBlock.ts `collectAll`); Minecraft's pickup is automatic on contact, so it can stop at each target. Dragonwilds needs a press per item, and a player presses on the move (Luis's recorder), so the press runs every 0.1 s on whatever the game's own prompt highlights, during the walk. Path order: open-path TSP from his position over the nearest k (k = min(8, still wanted)); nearest-neighbour + 2-opt was tried first and kept a zig-zag local optimum (2-opt is ~5 % from optimal on average, but not always: https://arxiv.org/pdf/2008.09367), so the small set is solved exactly by Held-Karp dynamic programming (2^8 x 8 x 8 steps). Searches for a Dragonwilds "collect all nearby" or pickup-on-the-move mechanic found only a player request for one (https://steamcommunity.com/app/1374490/discussions/0/604153636037130814) and a note that the ground-item clickbox was made larger in July 2025.

## Giving, splitting and dropped piles (2026-11-01 14:51-15:05 UTC, dev, ClaudeDev; game build 26161880, client 26162923; split-give agent)
- **There is no trade or give action between players.**
  - The dump has no trade class and no player give RPC. The only "give" is `UDominionRuntimeBlueprintLibrary.TryGiveItemToPlayer(PlayerController, ItemData, Count)` (Dominion.hpp:20915), a server-side Blueprint library call (quests, scripts), not a player action.
  - The wiki's Inventory page says items "can be dropped, moved, or split via a key-bound user hot-key"; nothing on trading. Control guides: Shift = Grant Split Stack, Ctrl = Grant Quick Transfer, X = Destroy Item; on a controller, tap LT = drop/transfer, hold a face button = split, the D-pad drives the split widget (`USplitStackButtonUIInput`, `bHalfStackDefaultSplit`).
  - So a player gives by dropping at the other's feet (player drops are not magnetised: he collects them with E, or F for all) or through a shared chest (skills.lua `store` / `take`).
- **Split = the inventory screen's `HandleInternalSplitToSlot`, the same server RPC as Luis's.**
  - Luis (recorder, 12:42:45Z): `split_put` = `InventoryController:Server_SplitAndPutStack` (his inventory, raw slot 8, amount 2), then a whole-stack drop 0.84 s later. His task took 10 s, with 6.2 s before the first RPC (open the screen, Shift-drag, pick the amount).
  - Claude, new `split` tool (inventory.lua): the server logged `split_put` (raw slot 30 = bag slot 22, amount 40) at 14:51:55.7Z. The listing showed 80 → 40 + 40 (new stack in bag slot 6), verified in **0.28 s** round trip (request → verified result).
- **Drops:**
  - `drop 1` took 0.37 s round trip; the server logged `drop` (raw slot 14, AmountOverride 1).
  - The world item lands **~1.4 m in front of the dropper, along his actor yaw**: Claude at (363.05, 1735.54) with yaw -168 put it at (361.65, 1735.21).
  - **Every drop is its own world item; the game never merges them.** Two 1-Stone drops made two `BP_RuntimeSpawnedWorldItem_C` (count 1 each) 0.15 m apart.
  - Luis's "pile" (8 drops of 1 Stone, 12:42:12-12:42:16Z) was taken by ONE `PlayerInteractionManager:Server_RequestInteraction` with **`bIsSecondaryInteraction = true`** (the secondary "collect all"; his split pickup used `false`), +8 Stone in one press. So the pile bar is one secondary press over 8 world items, not one world item. This is the first live evidence that the secondary collect-all works.
  - `AWorldItem.NameOfPlayerCharacterThatDroppedItem` reads empty (`dropped_by` nil) on Claude's client for his own drops, so the dropper can't be read client side.
- **Collect-all, verified on Claude (15:33-15:41Z, pickup agent, `tools/pickup_ladder.py --piles`, recorder-scored):**
  - The game's values, read from the `Default__ItemDeveloperSettings` CDO (client_mod/commands/collect_all_probe.lua): **`CollectAllRadius` = 200 cm**, `bCollectAllCollectsOnlySameType` = **false** (it takes every kind within 2 m), `bCollectAllIgnoresNonMagnetizingItems` = false. A player's dropped world item offers the secondary prompt **"Collect All"** (`UInteractionComponent.SecondaryInteractionPrompt`); the press is `PlayerInteractionManager.SecondaryInteractAction` = **IA_SecondaryInteract**, one injected frame, the same route as E.
  - 8 drops of 1 Stone (8 world items within ~1 m): `interact {target: one drop, secondary: true}` took **all 8 in one press, 1.9 s** request to result (the first try took 16: the earlier pile still lay within 2 m). `gather loose_stones x8` took them with **one secondary press made on the move**, 4.9 s.
  - **A small item at his feet is offered only with the camera aimed at it.** With the camera level he walked onto a dropped stone and stood there for 12 s without the detector ever offering it, so gather's non-magnet drop collection had never worked live. Aiming the camera at the item (yaw and pitch from the camera, as `W.aim_cam` does) from 2 m in fixed it.
  - The census can still list a collected pile for a few seconds after the press, so verify the inventory, not the census.
- **give (skills.lua, now offered to the model):**
  - It walks with come_to (by sight, or his map marker when out of sight), then steps to a spot 1.9 m in front of him along his facing (facing unread: on the line from him to Claude).
  - It turns toward him with movement-input nudges (to within 25°, at most 1 s), drops with `inventory.drop`, and checks that the bag shrank.
  - It then looks for the NEW world items of that item within 3 m of his feet, until two looks agree. A stack flies for a moment: the first read was 1.1 m from him, at rest 0.44 m.
  - It reports the resting distance and the number of stacks. If the pile is seen and then gone in two looks running, it says "you picked them up".
  - **Live, against a stand-in receiver** (ghost_leader.lua at a fixed spot; no second player was on):
    - give 3 Stone from ~10 m: **3.3 s** request → verified result (walk 2 s); give 7 after a 4.4 s walk away: **6.1 s** (walk 4 s).
    - Piles at rest lay 0.38-0.67 m from his feet; the reports said 0.4 m (true).
    - give 50 = a 40 + a 10 stack: "in 2 stacks side by side", 0.61 and 0.67 m from him.
    - Claude stood 1.7-1.8 m from him.
- **Bug found and fixed:** give's inner come_to restarted its follow without the give job's arbiter token, which was refused "busy: skill:give (command) is using my legs" (live 14:57Z).
  - Cause: the first follow starts before the job owns the pawn, and the arbiter adopts it. The job's acquire then replaces that owner and the follow stops. The restart had no token.
  - Fix: come_to takes `opts.token()` (the owning job's token).
- **Not verified live:** give to a real player (his facing from his actor yaw, the census row, the map-marker walk). That needs Luis.
- **Sources (search before building):** https://dragonwilds.runescape.wiki/w/Inventory; https://www.bisecthosting.com/blog/runescape-dragonwilds-controls-guide-keyboard-mouse-gamepad-controller; https://gamever.io/knowledge-base/controller-support-keybinds-in-dragonwilds-what-works-and-what-doesnt. Searches for a Dragonwilds trade or give mechanic found none (the results were older RuneScape trade windows and storage guides: https://allthings.how/runescape-dragonwilds-how-linked-chests-and-crafting-stations-work/). Decision: reuse the game's own client paths (the drop and split handlers); adapt MINDcraft's `!givePlayer` (go to the player, then toss) for the step in front, the facing and the pile check.

## NPC talk on Claude's client, loaded for the brain (2026-11-01 15:22Z-, dev, ClaudeDev; game build 26161880, client 26162923; quests agent)
- **talk.lua is loaded normally now** (client_bridge MODULES; the `_G.DW_ENABLE_TALK` gate is gone from the bridge, input.lua's sweep and skills.lua). The re-review's blocker (sweep_orphan recursing through the input gate) was already closed in rev 3: talk presses as the conversation modal's owner (input's sweep skips an owned modal) and `sweep_orphan` has a re-entrancy guard; test_input 6c drives a sweep that presses through the gate and sees depth 1.
- **Why the options came back empty (P2, 2026-10-26):** the panel's `AllOptions[i].DisplayName` (UConversationAnswerItemData, a UDomListItemData FText) reads nil on the headless client, while the payload (`DomConversationParticipant.LastMessage.Options[i].ChoiceText`, FClientConversationOptionEntry) holds the texts. Evidence: the P2 node signature `...|Yes please [Begin Tutorial]:1|I can work it out [Skip Tutorial]:1|p:nil|p:nil`. Fix: a panel row with no text takes the payload's user option (ChoiceType != ServerOnly) at the same position; the row keeps its own InputAction (the key that picks it).
- **Live 15:25:46Z, `talk {target: "Wise Old Man"}` by name** (new: a name resolves to the nearest perceived thing whose prompt is "Talk", via the bridge's resolve_name): episode 3 s, opened, Continue pressed through 2 choice-less lines, **4.3 s** round trip. It returned all 3 lines in order with the speaker, and options `1) Yes please [Begin Tutorial]; 2) I can work it out [Skip Tutorial]` (both available).
- **Live 15:26:17Z, `talk {choose: 1}`: the option's own key (OptionSelectInputActions[1]) both selects AND confirms on this panel** (`picked_via = "key"`, no Continue needed, no highlight-only step). 0.6 s round trip: 3 more lines read through Continue ("Doric can help you with that... outside the temple... only dwarf on the continent"), then the conversation ended by itself; `quests_changed` First Steps Objective2 -> Objective3 ("Speak to Doric outside the temple.").
- **A dialogue survives walking away:** between the two calls another agent ran a 49 m go_to and a Crafting Table build with the WOM dialogue still open (the modal did not block them), and the choose still worked from ~30 m away.
- **No hand-in node exists in the game's dialogue data:** the conversation task nodes are QFT_GiveQuest, QFT_SetQuestObjective, QFT_SetQuestBool, QFT_CompleteQuest, QFT_GiveItemToPlayer, QFT_GiveCraftingRecipe, QFT_PromptMessage, QFT_Blank and ModifyQuestInt; the requirement nodes test quest state/bools, world progress and free bag space (dump CXXHeaderDump QFT_*/QFR_*, Dominion.hpp l.17861). No dialogue node takes items, so a "hand-in" should be talking to the NPC once the step is done (whether the quest code itself removes the items is to be seen live). talk now reports `items` (gained/lost during that call) so rewards and any taken items show.

## Dev fixture set_stat: rest, food and water to a value on the server pawn (2026-11-01 15:48Z, dev, ClaudeDev; game build 26161880; rung1 gate agent)
- **Route:** the server pawn's own survival components, `ADominionPlayerCharacter.EnduranceComponent` / `SustenanceComponent` / `HydrationComponent` (dump: Dominion.hpp, properties at 0x15E0 / 0x15C8 / 0x15D0), each with `GetCurrent<Stat>()`, `GetMax<Stat>()` and `Add<Stat>(float ToAdd, float DecayBufferToAdd)`. `set_stat {stat, value | pct}` calls `Add<Stat>(want - current, 0.0)`: two floats, a server-local reflected call, no struct (CLAUDE.md principle 4). Endurance is the game's Rest bar.
- **Verified live 15:48:49-51Z** (the needs agent's run through this verb): sustenance 67.63 -> 25.0 and hydration 46.78 -> 25.0, both read back exactly (`ok`, max 100). It replicates to his client at once: the brain's next get_state read 24.9 / 24.9.
- The game's cheat manager has the same thing (`UDominionCheatManager.domModifyEndurance / domModifySustenance / domModifyHydration / domFullyRestoreSurvivalUpkeep / domPause*Drain`, dump), but the fixture's CheatManager route is unverified; the component call needs none. A web search found no public doc of the dom* commands (Dragonwilds has no developer console by default; hosts' command lists don't mention them).
- In-game time at 15:48Z was 13:39 (day 429): rest by day is a nap, +1/s (wiki https://dragonwilds.runescape.wiki/w/Rest).
- **Doric (Getting Started) checks what you already have:** with Dirty Water in the bag and Crafting Tables built nearby, his first conversation said "I see you've already got some water" and gave the quest straight at Objective3 "Bring the Stone Club to Doric outside the temple." (`quests_changed`: First Steps given -> complete, Getting Started ungiven -> given). The water and table steps are skipped when already met, so a fresh character's run is longer than this one.
- **Hand-in is talking, verified:** after `craft Stone Club`, `talk {target: Doric}` completed Getting Started (state complete), gave Ratcatcher (Objective1 "Speak to Vannaka near the windmill.") and **1 Vegetable Soup** (`items.gained`); the Stone Club stayed in his bag (nothing taken).
- **Getting Started from one chat line, live 15:41Z** (tools/quest_run.py, Haiku Controller, no Director): "claude, go and see Doric outside the temple and do whatever he asks you to" -> **quest complete in 26.7 s, 5 Haiku calls, $0.0025, no idle stretch over 5 s.** Timeline: first tool 3.4 s after the line (talk + say "on it"); talk 4.3 s (6 lines, ended by itself); craft_plan read; craft Stone Club 8.6 s at the nearby Crafting Table (8 Stone + 6 Ash Logs); talk 4.9 s -> complete. One false claim: his closing line said "Doric gave me a stone club and a veg soup" (he made the club). Fix: every talk result now ends with the outcome in plain words ("Quest Getting Started is complete. New quest Ratcatcher: ... Given to you in this conversation: 1 Vegetable Soup.").

## Travel speed: where a trip's time goes, trace cost, false water and false traps (2026-11-01 15:20-15:58Z; game build 26161880, client 26162923, dev world, ClaudeDev; movement agent)
- **Lua line traces are cheap.** Measured live with 200 traces each: `LineTraceSingleByProfile` (profile "Player") costs 0.080 ms, and `LineTraceSingle` (Visibility) 0.065 ms. Probe: the movement scratchpad `trace_cost.lua`.
  - The local planner's 16 traces per frame (written as "~1 ms each") left it frame-bound: ~1,000-1,100 traces per plan meant ~2.5 s standing.
  - At 64 traces per frame a plan stands 0.6-0.8 s.
- **Standing to plan dominated the slow trips.** Today's client log had 458 standing local plans, totalling 993 s:

  | Reason | Plans | Standing |
  |---|---|---|
  | wall_ahead | 142 | 378 s |
  | water_ahead | 124 | 299 s |
  | stuck | 132 | 210 s |
  | water | 43 | 83 s |
  | drop_ahead | 14 | 24 s |

  - The oracle's route for 150+ m trips arrives 10.6-11.2 s after the request (corridor streaming). Before the provisional walk he stood through that wait.
- **The water channel ('cam', Camera channel 1) also stops on solids.**
  - A roof or a bench above the floor reads as a "water surface". The pawn profile passes through water to the bed, so water is where 'cam' stops more than 15 cm above the floor and the pawn trace does not stop at that height.
  - The 11 cells marked "water" at the church door, (40-48, 923-933) in 200 cm cells, now read as floor on every channel: cam = pawn = Visibility = floor Z (landscape or StaticMeshActor). Probe: the scratchpad `water_cells_probe.lua`.
- **False traps in nav memory, and how they were learned:**
  - t161 at the ladder start (249.9, 1790.8) came from a go_to whose goal was 11.8 m above him. He stood under it (unreachable: target_above_jump_height). The next trip's first 15 m became the "exit".
  - t178 and t265 came from failing to stand on the Water Anima Vent (d = 2.4 m, no_route). t226 came from a goal 439 m away and 12.6 m up. t158, t197 and t217 had straight 20-22 m exits.
  - `n_ok` was not evidence. It was bumped on every tick while an exit kept growing, and on every walk of a stored exit (church_respawn 780, t158 696).
  - Rules now:
    - a candidate needs a no_route failure more than 3 m from the goal, or a wedge;
    - a teleport before the first sample drops it;
    - walking straight out the very way that failed is "not a trap";
    - `n_ok` counts once per escape, and `n_used` counts walks of a stored exit.
- **Ratcatcher, two live runs (tools/quest_run.py, Haiku, no Director):**
  - Run 1, 15:51Z ("claude, go and see Vannaka near the windmill and do his quest"): go_to Vannaka 44.5 s, talk 1.9 s -> Objective2 "Kill rats and successfully cook one rat roast from their meat." Vannaka's own words: "Behind me, up that little hill, is a windmill infested with rats." Then `explore {about: rat}` walked WEST and fell 29 m off a cliff (companion_down); the rest of the 480 s deadline went on two unreachable graves (all his gear and items). Handed to movement (lethal drops) and Rung 1 (graves).
  - Run 2, 16:24Z ("claude, carry on with Vannaka's rat quest"; fixture: 1 Stone Club granted, because both graves were unreachable: "the walkable map ends 7 m short" and "64 m below"): **complete in 204.6 s, 10 Haiku calls, $0.0071, no idle stretch over 5 s.** go_to Vannaka 53 s (145 m, 2.7 m/s); equip club; attack a Giant Rat -> path_blocked 12 s (miss 1); go_to the rat 70 s -> unknown_target (miss 2) but 54 s of it the combat reflex fought the rats and the meat was picked up; build Campfire 5.8 s; craft Rat Roast 27.2 s (cooking); talk Vannaka 15.5 s -> complete, Rune Mysteries given ("Speak to Zanik, near the river, down the road from the temple."), rewards 1 Stone Dagger + 1 Stone Logging Axe. One roast was enough; nothing was taken.
- **The game's quest map markers are readable on the client** (probe `client_mod/commands/quest_locations_probe.lua`, 16:1xZ): `UQuestWorldSubsystem.QuestLocations` lists all **174** AQuestLocation actors (World Partition does not stream them out), each `{Type Target|Area|NPC, Radius (cm), Quest, bShownByDefault, QuestLocationName}`. His `QuestProgressComponent.VisibilityTrackers` switch them per player (e.g. `Windmill_Area_FTUE_RC` visible, `Vannaka_Objective_FTUE_RC` hidden until the step is done) and `TrackedQuestMap` held Ratcatcher. The FTUE markers sit at z 201.6 m, ~230 m above the ground, so the ground height comes from one downward LineTraceSingle (misses at ~200 m are retried every 10 s; later reads at 233 m hit). Ratcatcher's rats marker: "Windmill Area", an 80 m-radius area at (156.1, 1713.4), i.e. SOUTH of Vannaka (152.5, 1787.1) — run 1's explore went west. quests.lua now gives each active quest `where = [{name, kind, radius_m, position, distance_m, inside}]` (shown markers only), and the brain's quest line says "on the map: Windmill Area (area 80 m radius), 207 m away at [...]".

## Lethal drops, steep ground and where the grave lands (2026-11-01 15:56-16:30Z; game build 26161880, client 26162923, dev world, ClaudeDev; movement agent)
- **Safe fall and walkable slope, read live from his own CharacterMovement:** `MinFallDamageHeight` is 1500 cm (falls at or under it cost nothing), `MaxFallDamageHeight` is 2860 cm, and `WalkableFloorZ` is about 0.70 (WalkableFloorAngle 45.5 deg). move.lua reads them once per walk, with defaults 1500 / 0.70 when a read fails.
- **The cliff at dev (44, 1745), west of Vannaka's road:**
  - The top is at z about -30 m and the floor at -66 to -70 m.
  - Above it runs a shoulder of steep cells (y 1744.5-1746; hit normals 0.29-0.46 at x 37-47; 0.38-0.68 at x 37-40 on y 1746). Cell to cell they read nearly level along the contour, so a planner that checks only dz takes them as walkable.
  - Flat ground (normal 0.99) is 1.2 m north, at (45, 1746, -30.4).
  - Probe: `cliff_grid.lua` in the movement scratchpad, LineTraceSingle on the camera channel with ImpactNormal.
- **Two deaths there**, both read from the server recorder (`kind:"pos"`, mode 1 = walking, 3 = falling):
  - 15:56:07, explore. He walked west at 4.5 m/s, his last grounded sample was (45.02, 1744.93, -29.76), he fell, and HP read 0 at about -65 m.
  - 16:01:39. He walked straight at the recorded death point 64 m below and off the same edge.
- **The grave lands at the last grounded spot, not where the body ends up:**
  - The grave actor is at (45.02, 1744.92, -30.64), on the cliff top. It matches the last mode-1 sample within 0.1 m in xy.
  - `last_death.json` recorded the falling body, (38.62, 1740.25, -93.96), 63 m below and 8 m away. That puts the grave just outside GRAVE_MATCH_M (15 m) in 3D, though inside it in 2D, and makes go_to "my_grave" aim at the cliff floor.
  - move.lua now keeps `_G.DW_LAST_GROUND = {X, Y, Z, t}`, updated on each walking sample, so a death record can use it.

## Building a house on Claude's client: the census, the cursor, snaps and rotation (2026-11-01 14:50-16:35Z, dev, ClaudeDev; game build 26161880, client 26162923; build agent; client_mod/scripts/build.lua, probes client_mod/commands/build_probe_pieces.lua / build_probe_preview.lua)
- **Census of built pieces:** structural pieces (foundations, walls, frames, tiles) have NO actor on the client; they are HISM instances. The truth is `GlobalBuildingManager.BuildingPieces` (TMap<uint32 id, FBuildingPieceState>); `.ClientVisible` holds BuildingPieceDataIndex, Location (cm), Yaw, bGhosted, StabilityValue, FractionalHealth. Props/stations/doors also have a BaseBuildingActor (joined by its BuildingPieceID). Ids "BuildingPiece_<id>".
- **Piece sizes:** the piece data's DerivedData -> BuildingPieceLocalBounds (cm): Square Foundation extent 150^3 origin z -150 (its location = its top); Wall extent (151.5, 50, 151.5) origin z +151.5 (location = its bottom centre on the edge line); Doorframe (150, 50, 150) origin +150; Square Tile (150, 150, 18.75) origin z -18.75 (location = its top); 45° Roof (168.7, 150, 168.7) origin 0; 45° Hip Roof (159, 159, 168.7) origin (9.3, -9.3, 0). PlacementZOffset 0.5 m on the foundation (the census location sits that much above the preview).
- **No preview actor for instance-only pieces:** only BP_BuildingHelper_C (BuildModeComponent.BuildingHelperActor) sits at the cursor; MPC CursorWorldPosition = the helper location. The cursor glides ~1 m/s after each aim and settles ~0.6 m short / 0.2 m aside of the camera aim. BuildPlacementComponent.MaxPlacementDistance = 700 cm, MagnetizeExtentsMultiplier 1.2, SnappingMode 0 (Basic).
- **Snaps (Basic mode)** happen when the cursor hovers a built piece at the target: a wall aimed 0.3 m inside a foundation's edge ON its top face lands exactly on the edge line, on top (4 walls 16:11Z, gap/offset/level 0, snap 0.3 m); aimed at the foundation's SIDE face it snaps to the BOTTOM edge, 3 m low (frame 65, 15:42Z). A door aimed at its frame's lintel snaps into the frame (aimed into the opening, the ray passed through and the cursor landed 6-9 m away). A Square Tile aimed at a wall's inner face 0.2 m under its top lands as a ceiling over the cell: its edge on the wall line, top 0.03 m under the wall top (BuildingPiece_71, 16:12Z, pulled 1.29 m from the cursor).
- **Rotation:** the ghost keeps the rotation of the LAST placement (not the view's yaw), across pieces and sessions; each rotate press = 15°. build.lua tracks it (mem().ghost_yaw) and re-syncs from the census after each wall.
- **The camera swings after an aim:** SetControlRotation is worked out from the camera's position; the spring arm then turns round the pawn and hits walls, so a big turn inside a walled cell left a tile's cursor wandering 1-7 m (16:33Z). build.lua now re-aims while the camera moves (reaim_cam_m).
- **The cursor IS the camera ray's hit, and a running go_to owns the camera** (17:44-18:2xZ, probe client_mod/commands/build_probe_helper.lua with camera/ray fields): the MPC cursor equals a LineTraceSingle from PlayerCameraManager's location along its rotation, to the centimetre (97.3787, 1848.8451, -29.7077 both). Idle, SetControlRotation sticks (set (20, 90): read back (20, 90) 1 s and 3 s later). But through the ceiling/roof windows the camera stayed at pitch 0 and a yaw that wasn't ours: the build's approach go_to had a stand point at the WALL TOP's height (2.1 m above the floor), so it never arrived; the job went on to the build screen at 1.2 m in xy while move.lua kept steering (pitch 0, yaw to its goal) every frame, over every aim, for minutes (client log 18:44 local: "stuck n=15 ... goal z -2878" after the build had ended). Every cursor read sat level with the camera on whatever wall it faced. Fixed in build.lua: a ceiling/roof stand point is on the floor (the wall's bottom + 0.88 m), and the approach stops a still-running go_to before opening the build screen.
- **Ceiling and 45° roofs live (18:27Z, after that fix):** Square Tile 76 on wall 72:W (cell 62) square, 11.7 s; 45° Roof 77 on wall 68:N and 78 on 70:S square, 5.2 s and 8.8 s (78 placed from where he stood), at (96.2113, 1853.1378 / 1850.1378, -27.3092): exactly Luis's roof height. Each snapped 0.9-1.3 m from the cursor on the wall's face onto the wall-top plug. Luis's census has 45° Roofs + 45° Hip Roofs and NO roof support (gable) walls.
- **Batch speed (`pieces`, the build screen kept open):** 18:57Z a 4-piece batch (3 walls + a door into its frame) all square in 35 s; recorder build_spawn gaps 18.8 s (the walk round the house to the first), then 3.0 s and 4.1 s per piece (Luis 3.81 s); unit_s 8.07. 18:34Z a 7-piece batch stopped at #6 after 3 (truthfully): a wall's cursor trembled 4-10 cm a read 0.01 m from the flush spot and never counted as settled; now two reads on target within tremble_m (0.15 m) are settled.
- **Stations:** Crafting Table, Crate and Campfire (the game's firepit, 6 Stone) placed with near: me, 6.6-8.0 s each. store on his crate 13.7 m off failed "I can't see that chest anywhere near me": find_thing's census (the 100 nearest things, resources first) and its actor lookup both missed a crate that get_state.structures lists; find_thing now falls back to build.find_structure (the building census + the pieces' actors). store/take already walk (the interact episode's approach); their replies now say what moved and the walk ("Put 8 Oak Logs in the Wooden Chest (I walked 30 m to it).").
- **A built actor's name changes; its piece id doesn't** (19:40Z): his crate was `BP_BaseBuilding_Crate_C_2147144746`, then `_2147480402`, then `_2147480379` after client reboots (the game re-creates piece actors). The census pid (`BuildingPiece_<pid>`, `ABaseBuildingActor.BuildingPieceID`) stayed 83. build.find_structure resolves an old actor name (via the pid it had) and `BuildingPiece_<pid>` to the current actor; live: store with the brain "Put 13 Ash Logs in the Crate (I walked 6 m to it)."
- **No owner per building piece** (dump 26161880): FBuildingReplicatedEntry (ID, Location, YawRotation, BuildingPieceDataIndex, bIsGhosted, StabilityValue, HealthPercentage), FClientVisibleBuildingPieceState, FServerOnlyBuildingPieceState (CompletionStatus, bForceMaxStability, NeighborBuildingPieceIDs) and ABaseBuildingActor carry no placer/owner (only the transient PlayerControllerManagingPlacement of a preview). Whose a piece is comes from his own ledger (deconstruct.lua `data/skills/<world>/my_pieces.json`): the build-complete telemetry had noted 18 of his ~30 pieces (it misses pieces placed in quick succession); a verified build reply now notes its piece too, and get_state.structures sets mine true/false ("yours" / "not placed by you" in the digest; nil = unchecked). Backfilled 10 of his pieces (pids 68-70, 77, 79, 84-88) from the build windows' verified replies.
- **First scored brain run (19:42Z, "build yourself a small house ... here", 10 Haiku):** no house. The spot (112, 1856) stood among other runs' crates, campfires and tables 13 m from his own house, and the model said "we already got most of it up here" (no ownership in perception then). It aimed a 30° Roof and a 45° Roof at a foundation's `:top` twice ("the closest its preview came was 1.68 / 1.73 m"): roof pieces snap onto wall tops (Luis's house; community guides: the wall-top rim is what roof pieces snap against, allthings.how roofs tutorial, gamever.io stability). A failed `:top` attach of a cell-sized piece on a floor now says so and names the on that works ("on 'BuildingPiece_85:S' ... puts it over this floor"). store worked from the brain. The run never went "quiet": a call later in a turn that stopped at its first failure never gets a result; build_run counts only calls after the last model reply. build_run --fresh now picks the spot from the census (40+ m from all 57 pieces, on walked ground, near his base) and logs it with the nearest piece.
- **Scored runs 2 and 3 (fresh spots 40.8 / 41.4 m from any piece, 11 / 10 Haiku, $0.014 / $0.013):** run 2 (20:25Z) gathered 44 ash himself (124 s), batch Crafting Table + Campfire + Crate 21 s, Square Foundation, a batch of 4 WALL WITH DOOR FRAME all square 38 s, Door in its frame, a 30° Hip Roof on the foundation's `:top`: built, but ON the floor inside the walls (z = floor + 0.75; the reply said only "NOT flush ... 0.19 m lower"); stored 10 Ash Logs. Spawn gaps in the wall batch 8.5-9.1 s (approach 7.7 s, check 21.3 s for 4). Run 3 (20:50Z) chose a Medium Square Foundation: its MEDIUM WALL box is 150 x 100 x 150 cm (extent 0.75 x 0.5 x 0.75), which `thin_axis` (thin <= 0.4 x long) read as a tile, so the flush spot was 0.5 m out: the N wall the game put exactly on the edge read NOT flush, the E wall snapped 1.5 m east on the N line; the batch reply hid both as "It stands at [...]" (the fit sentence was cut out of the line by a pattern that stopped at the dot in "0.73 m"). A Crafting Table he placed "near me" stood in the middle of the 1.5 m foundation and kept the S wall red. Fixed: wall-like also = thin <= 0.7 x long and as tall as long (medium walls); the fit is the attach sentence itself; a roof built on a floor says "That puts it on the floor inside the walls, so it doesn't cover the room" and names the wall-top `on` (gated by the game's placement profile: RoofProfile / BaseProfile, never FloorProp*); a red attach names the built pieces within 0.6 m of where the piece would go; the house line says which frames are open doorways / window openings and which hold a door (the edge's wall is the tallest piece on it, a smaller one stands in it).
- **Scored runs 4 and 5 (2026-11-01, fresh spots from the census, $0.012-0.014 each, both ended quiet):** run 4 (spot (80.7, 1913.1)): he gathered 31 m away and built THERE (the request's "here" was lost once he moved), 4 pieces; the Door failed 3 times on the frame's N/S edges instead of `:in`; unit_s 42.3. Fixes: a door aimed at a door frame's side is told "A door goes into the frame's opening: on '<id>:in'"; a failed batch piece keeps its preview reads / ghost offset / what stands in the way; a station or furniture placed without `on` says "It stands on your <name> (<id>), N m from its centre (the floor is A x B m)" (`W.floor_under`), and the census marks each piece yours or "not placed by you" (the game keeps no owner per piece: FBuildingReplicatedEntry / ClientVisible / ServerOnly state and ABaseBuildingActor have none, only the transient PlayerControllerManagingPlacement; ownership = his ledger `data/skills/<world>/my_pieces.json`); the situation keeps `Asked: "<request>" when you stood at (x, y, z), N m from where you are now; <player> was at (...)` while the request is open (brain/agent.py `_asked`, situation.asked_line). Run 5 (21:39Z, spot (32.7, 1861.1), 13 Haiku, wall 286.5 s): 10 pieces, all true in the census: table, campfire, crate, foundation, 3 door-frame walls, the Door via batch `:in` (worked first time), Ash Pallisades, a Medium 30 deg Roof on wall 112:S (he followed the roof hint); unit_s 23.57 vs Luis 3.81. Free-form piece-by-piece aiming found a new aiming/edge bug each run (pieces right 7, 3, 2, 10) and is not converging: switched to blueprints.
- **Blueprints (CLAUDE.md phase 7, `data/blueprints/*.json`, build.lua `build_blueprint {blueprint, at, facing}`):** a house is relative pieces: the first foundation `at` the spot, every other piece `on = "<earlier key>:<side>"` (compass sides for the blueprint's own `door_side`; `in` = into a frame, `top` = the top face), turned at run time so the door faces `facing`. The tool reads the game's own costs (buildables) for every piece first, refuses with the whole bill when short ("needs 46 Ash Logs (I have 12). Nothing was placed.") or names a piece not unlocked, then runs one `pieces` batch with keep_going (build screen kept open, each piece placed by the verified attach primitives and checked in the census; a piece the game won't take is reported and whatever goes on it is listed "Not tried"). `small_house` (11): f1, f2 on f1:S, walls f1:N/W/E + f2:E/S, door frame f2:W + Door on its `:in`, two Large Diagonal roofs on wn:S and ws:N (his own 61-78 house). `luis_house` (29, from the census of Luis's house, pids 15-45): a 3x3 of Large foundations (centre, its N/S/E/W neighbours, the corners on n/s's E/W), 12 edge walls (4 plain at NW/NE/SE/SW corners' outer edges, 6 window frames, the door frame on e:E), 4 hip roofs on the corner cells from the outer wall toward the cell (h_ne on the NE window frame's W side, etc.), 4 roofs on the edge-middle cells from their outer wall (r_n on w_n:S ...); all at wall top + 1.5, yaw = atan2(-axis) of the wall side, as flush_spot computes. The centre ceiling tile is left out.
- **Scored run 6, the first blueprint run (2026-11-01 22:5xZ, fresh spot (180.7, 1865.1), 14 Haiku, $0.016, quiet after 276 s):** he gathered 35 ash, placed table, crate and campfire, called `build_blueprint small_house` (refused up front: "needs 46 Ash Logs (I have 23). Nothing was placed."), gathered 23 more and built it: 10 of 11 pieces in 82 s (8.2 s/piece; spawn gaps 5.2-9.7 s; whole run unit_s 17.0 vs Luis 3.81), all 13 pieces true in the census. The Door into the frame failed: for `:in` he stood "on my side" of the frame, which was inside the closed room, and every cursor read sat on the far (N) wall's inner face 2.8 m from the S frame (the camera boom pressed into that wall). Fixed: for `:in` he stands on the frame's side that is off every floor (`W.floor_under` read 0.75 m across the frame, not at the 3.5 m stand spot: that is past a 3 m room's far wall, retest 23:02Z failed so). Retest 23:5xZ: the Door sits squarely in BuildingPiece_128 from outside. Also: `spent` per cost item is capped at the game's cost (the storage read is around where he stands, so walking away from a stocked crate read as "15 Ash Logs" for a 2-log door). He passed `at: me` after gathering, so the house stood ~50 m from the asked spot; the `at` description now says 'here' = the Asked line's (x, y, z), 'me' = where he stands now.
- **Luis's building pace (rec_20261101T123634Z):** 11 walls/frames placed from one spot (0-0.3 m apart), 0.8-2.9 s apart; 8 roof pieces from ~1 m of one spot, 2-3 s apart; switching piece types ~3-8 s. Claude at 16:11Z: 18.7 s/piece (105.7 m walked for 5 pieces, the menu closed and reopened per piece).
- **Deconstruct refunds** of a piece hanging below a foundation dropped out of reach (65, "got nothing back").
- **Rune Mysteries, window 1 (17:42 local / 16:42Z, "claude, go and see Zanik and do her quest", 300 s window, 11 Haiku, $0.0066):** go_to Zanik 50 s (249 m at 6.4 m/s), talk 1.8 s -> "Bring 50 Ash Logs to Zanik." His inventory (read at 63.7 s) had no axe: he had died at 16:37:25Z (KillZVolume, fell 31 m in Temple Woods, between my windows), so "I've got no axe on me, my gear's in my grave" was true. Walked 275 m to the graves (4.3 m/s); the lethal-drop guard stopped both `go_to my_grave:<ts>` calls ("the goal is 64 m / 41 m below me", drop_ahead, fell only 3.5 m). Then interact on his gravestone 1.7 s -> 27 Ash Logs + Stone Club + the rest; gather ash x23 in 94.8 s; go_to Zanik 47.9 s; window ended before the hand-in talk. One stand of 16.9 s (after saying why: "the path down to my graves is blocked").
- **A KillZ death's gravestone is NOT where he died** (live, same run): `graves_remembered` / `my_grave:<ts>` hold the pawn's death position (the bottom of the fall, z -70.9 and -93.9), but the game put both newest `BP_PlayerGravestone_C` actors on the ledge top he fell from, (41.7, 1746.8, -30.7) and (45.0, 1744.9, -30.6), 1.4 m and 3 m from him, census `owner_check: verified`, from 130.5 s. The chain turns after the failed go_to carried only tool results, so he stood 17 s believing the graves were out of reach; the next full situation ("YOUR gravestone is 2 m away (id ...)") made him take it at once. A remembered grave should resolve to the verified census gravestone when one is in sight (grave owner: Rung 1).
- **Rune Mysteries, window 2 (16:5xZ, "claude, carry on with Zanik's quest", 3 Haiku, $0.0020, no stand over 5 s):** another agent's window had moved him 190 m away; go_to Zanik 52.6 s (4.5 m/s), talk 1.7 s: the 50 Ash Logs went with the talk (no item hand-over step, as with Doric's soup), Zanik gave 1 Stone Pickaxe, 5 lines (mine essence from the geysers with floating rocks; craft air or astral runes at a rune altar you build, or siphon from Anima vents), step -> "Return to Zanik.".
- **Two quests in his log share the name "Rune Mysteries"** (live read 16:5xZ: listed under complete AND active, step "Return to Zanik."). talk.lua's quest diff matched rows by name, so the hand-in read as "Quest Rune Mysteries is complete" and the brain told the player "Rune Mysteries done" (false). Fix: rows carry the quest asset (quests.lua `asset = U.short(QuestData)`) and the diff matches by asset (test_talk 58/58).

## Rung 3 (self-sufficient): how Luis did each task, and what Claude's dev character can use (2026-11-01; game build 26161880, client 26162923; dev world; rung3 agent; server recorder rec_20261101T123634Z, read-only, and a live read-only probe 16:56Z, logs/evals/rung3_probe.jsonl)
- **Luis's RPC sequences (recorder, his own client):**
  - **Craft at the Crafting Table** (axe 11 s, pickaxe 6 s): one `interact` on `BP_Crafting_StartingBench_C` (104.91, 1852.71), then one `craft` rpc 2-4 s later; the inventory delta (inputs out, tool in) lands with it. He stood 4-8 m from the bench at the start.
  - **Boil water** (14 s): `interact` Campfire (107.22, 1848.48) at 1.8 s -> `move` bag slot -> `ResourcesInventory` 0 (14 Dirty Water) at 3.0 s -> `move` -> `FuelInventory` (31 Ash Logs) at 3.5 s -> `toggle ProcessingStation` at 4.4 s -> first Clean Water in his bag at 9.8 s (4 s recipe) -> a second `interact` at 10.8 s -> drank one (`use_item`). "done" after 2 Clean Water; the other 10 came out over the next ~40 s.
  - **Cook** (23 s): the same shape at Campfire (89.57, 1847.79): 14 Raw Farm Meat + 80 Ash Logs in, `toggle` at 6.4 s, the first Steak at 18.2 s, eaten at 20.7 s.
  - **Spinning wheel** (make thread 56 s for 13; fur to thread 21.8 s for 2): `interact` -> `move` flax/fur -> `ResourcesInventory` 0 -> `toggle`, then **Overdrive** (Air 15 + Water 5 spent 10 s later; the recorder's ability hook does not see casts): thread arrived in his bag one at a time while he walked 30 m away, so a running station's output reaches the starter without a collect press.
  - **Make spade** (47 s): he BUILT a Spinning Wheel first (`build_spawn` 653: 12 Ash + 4 Flax + 2 Stone), spun 2 Flax, then crafted `RECIPE_Tool_T1_Spade_Wood` at the bench.
  - **Farm** (176 s): crafted a Compost Bucket and a Wooden Watering Can, built a Compost Bin (`build_spawn` 76: 8 Ash + 4 Stone), planted from hotbar slots (`use_item` on the seed slot, the seed spent ~1 s later), pressed the water volume 4x (`SingleSourceContainerInteraction`, the 4th a secondary press), and worked the Composter (`ContainerInteraction`, weeds into its `ResourcesInventory` 3, secondary presses to take compost).
- **Game data:** Spinning Wheel `max_resource_slots` 1, no fuel, `processing_rate` 5.0; Campfire 1 resource + 1 fuel slot. Coarse Thread = 1 Flax or 3 Coarse Animal Fur; it unlocks on `ALL ITEMS[ Flax ] AND ALL ACTORS[ Spinning Wheel ]` (fur route: `ALL ITEMS[ Coarse Thread ]`), the Wooden Spade on `ALL ITEMS[ Ash Logs, Coarse Thread ]`. Wiki (mirror): the Spinning Wheel needs a roof to run; ash farming plots need open sky and a Wooden Spade (5 digs of 10 stamina per weed stage, 3 stages); the Compost Bin and Compost Bucket need Farming 10; a watering can fills only at a water source (not from water items); Overdrive (Artisan 48) speeds mechanical stations.
- **Burnt food is real for ClaudeDev (live 17:07Z, Campfire (107.22, 1848.48), Cooking 7):** 2 Raw Farm Meat gave 2 Burnt Steak (`ITEM_Consumable_Farm_Steak_Burnt`, the recipe's `AlternativeItemCreated`, gated by `ChanceToBurnFoodLevel2`), 0 Steak. The burnt items drop at the station like the good output and count as the station finishing. Wiki (Culinary Confidence): 50 % not-burnt at the ingredient's power level, rising per Cooking level to 100 % ([Culinary Confidence](https://dragonwilds.runescape.wiki/w/Culinary_Confidence), [Burnt Steak](https://dragonwilds.runescape.wiki/w/Burnt_Steak)). The catalog now carries each recipe's `alt` + `alt_chance` (tools/build_recipes.py), and crafting.lua waits for, collects and reports them (all burnt -> `craft_failed` "nothing came out right: I got 2 Burnt Steak and no Steak").
- **"Stone Axe" is not a name in the game:** the item is "Stone Logging Axe". The brain asked for "Stone Axe" (unknown, then 24 axes by substring) and asked the player which one. crafting.resolve_item now matches when every word said is a word of the name (offline: stone axe, stone pickaxe, wooden spade each resolve to one item; "axe" stays ambiguous).
- **The Spinning Wheel needs a roof to RUN and to be PLACED:** `UBuildingShelterComponent` (`bShelterCheckedOnPlacement`, `RequiresRoofText`, `RoofRays`); build.lua already turns placement code 11 `ShelterCheckFailed` into the piece's `ShelterRequirementText`. Guides: 12 Ash Logs + 4 Flax + 2 Stone ([esports.gg](https://esports.gg/guides/runescape-dragonwilds/how-to-get-coarse-thread-in-runescape-dragonwilds/), [Destructoid](https://www.destructoid.com/how-to-get-coarse-thread-in-runescape-dragonwilds/)), matching Luis's `build_spawn` 653.
- **What "ALL ITEMS[...] AND ALL ACTORS[...]" counts (verified live 18:22-18:25Z):** `UProgressComponent.ItemsPickedUp` (TSet<UItemData*>) and `ActorsInteractedWith` (TSet<TSubclassOf<AActor>>), both readable on Claude's client. A fixture-granted Flax counts as picked up. A Spinning Wheel standing next to him does not count until he USES one. At 18:22Z the craft said "used a Spinning Wheel: not yet", so the model pressed use on his own wheel. The interact tool reported "nothing changed" (it opened the station's menu). By 18:25Z `recipes` listed RECIPE_Process_Thread_Linen_From_Flax as **ready** ("used a Spinning Wheel: yes"). The fur recipe stays locked until he has picked up Coarse Thread. crafting.lua `W.discovered` + `M.unlock_status` now spell this out per term.
- **Building a Spinning Wheel needs no roof** (18:03Z, `build` from one chat line: placed at (93.33, 1857.72), open sky). **Using one does (verified live 18:40-19:05Z):**
  - Pressing use on a wheel under open sky does nothing: "its menu didn't open". This happened 6 times on Claude's two wheels and once on Luis's. Luis's wheel lost its cover when his house was torn down (Rung 2).
  - The actor's `BuildingShelter` component (UBuildingShelterComponent) reads `InteractionRequirements` 0 = InteractInShelterOnly. `RequiresShelterText` = " needs more surrounding shelter." (a tail after the name).
  - A Campfire is the opposite: rule 1 = InteractExternallyOnly, " is too sheltered. ".
  - An upward trace (2.2-10 m over the station) read open sky over all three wheels.
  - crafting.lua `W.shelter` reads all of this. The stations tool and the open failure say it.
  - buildables already shows a piece's `ShelterRequirementText` ("Requires Shelter"), but the model built outside twice anyway.
- **ClaudeDev on dev (probe 16:56Z):** Farming 1, Artisan 4, Cooking 7, Construction 9, Woodcutting 12, Mining 2. 39 spells unlocked, Overdrive castable (page 4, key 1; 51 Air Runes = 3 casts), Rapid Growth castable; Humidify not (needs 50 water units). 109 recipes unlocked; Coarse Thread and Wooden Spade are **not** (he has never held Flax). No farming plot piece in buildables (Growing Pains active at "Speak to the Wise Old Man"). Stations within 40 m of the base: Crafting Tables (104.91, 1852.71) and (89.6, 1850.09); Campfires (98.38, 1867.12), (107.22, 1848.48) with 30 Ash Logs and (89.57, 1847.79) with 77; Luis's Spinning Wheel (89.39, 1853.33) holding **his 2 Coarse Animal Fur in its only slot** (and roofless since his house came down); Luis's 6 plots, harvestable. A wheel holding someone else's fur cannot take Claude's flax without taking his items out, so Claude's thread needs a wheel of his own (under a roof).
- **A felled tree has finished falling when `AFelledTree.CollapseState` is set (verified live 19:59:19-23Z, window 10 chop):**
  - EFelledTreeCollapseState: 0 None, 1 CollapsedNormal, 2 CollapsedSkillcape. It is replicated (OnRep_CollapseState).
  - The trunk actor lingers for `LifeSpanAfterCanopyCollapse` after that. gather's settle wait ("while a FelledTree exists near the site") therefore always ran to max_s = 10 ("scan settle timeout" after every tree; ClaudeQ2 19:14Z and rung 3 19:30Z).
  - The tree profile now has `settle.done_prop = "CollapseState"`. Live, settle went from 10 s to 4 s (2c1a008).
- **A swing's stamina cost reaches the client late:**
  - On every swing in window 10, gather's +0.35 s sample read the same stamina as at the press, HIT or not ("92.0->92.0 HIT"). Each press still read 4 less than the press before (100, 96, 92, 88, 84; the axe's cost is 4).
  - So a run of misses on a split log (19:59:27-34Z, hp 80 -> 80) counted as "unverified". After 6 it ended with a false body_error inputs_not_reaching_game.
  - gather now counts a press that reads less than the press before as a swing that ran. A miss then goes through the aim and side search.
- **The stand bar and the held say (rung 3 gate 19:03Z, 19:33Z, 20:03Z):**
  - The model often says "on it, cooking ..." beside a read (recipes or inventory), then acts with no new say.
  - The controller held that line ("only the say in the reply that ends your turn is heard") and it was never said, so he stood 5.8-7.2 s from the chat line in silence.
  - Now a held say is spoken when the turn then acts without a new say (`say_released` in the brain log). It is spoken only once the bridge sees the action accepted (`ACCEPTED_AFTER_S` = 2.0 s), or at once for go_to, come_to and gather.
  - The reads came from perception. Situation "Carrying" was cut at 12 items and hid his 4 Dirty Water, so it now lists every item (900 chars). Cooking needed the output's name, so craft now takes `input` = a carried item: the recipe that takes it, as a player loads raw meat on a fire.
- **Lying in a bed blocks stations too:** in a Summon Shelter (`PlayerRestComponent.CurrentRestingAreaActor`), pressing use on the Crafting Table did nothing ("I can't get the game to let me use the Crafting Table", 6 sides; window 10, 19:56Z). craft now fails at once with reason `resting`, naming the bed, as go_to does.
- **A taken world item lingers on the client (w12, 21:05:02-07Z; build 26161880 / client 26162923):**
  - One interact press on a ground Stone (BP_RuntimeSpawnedWorldItem_C_2147463333) put it in the bag at once (gather_progress have=1 at 21:05:02).
  - The client's copy of the actor stayed valid until 21:05:07. gather's collect waited for the actor to go, so he stood 5 s.
  - gather now ends a collect on the bag's gain after a press, and skips that key for 10 s.
- **A walk that ends in a sprint or a hop carries on (w11 mine, 20:33:51Z):**
  - move reported "stopped, 0 m left" 1.59 m from the rock at 4.7 m/s, after a hop.
  - He then slid 5.3 m in about 2 s (97.86,1840.62 -> 94.48,1836.57), and gather's first swing press found him out of reach.
  - gather's aim now waits until he is still (40 cm/s) before the settle counts.
- **A new log piece's first HP read is not its own.**
  - Every split log's first press read the previous thing's last HP:
    - the felled tree's 85 ("hp 85->80 HIT" at the first press on 2147466602 and on 2147462190);
    - or the previous piece's 5 ("hp 5->80 no effect").
  - Only from the second press on is it the piece's own 80. So the unhittable split log 2147462190 (w12, 21:03:00-46Z, 28 presses, 80 hp throughout) never took any damage at all.
  - Its census row: position (110.39, 1875.27, -30.14), max 80, unchanged at 21:04:15Z. He stood at (116.39, 1873.85) with gather's aim point 1.48 m from him.
  - Healthy pieces show the same origin-to-stand gap (5-6 m), because a split log's origin is not its middle. That gap is not the cause.
  - The mechanism is open: gather's `diag` snapshots (dz, the aimed point vs now, pitch, collision, physics, traces) fire on the next occurrence.
  - **Baseline from 2 split logs that did take damage (w14 21:29:38Z and 21:29:54Z, "gather: diag hit"):**
    - Root is a StaticMeshComponent: profile BlockAllWorldActor, object type 1 (WorldDynamic), collision 3 (QueryAndPhysics).
    - One was still simulating physics at 5 cm/s; the other was asleep and not simulating.
    - Mid point 64 / 40 cm below his capsule centre, 1.12 / 1.36 m away; the aimed point was 0-2 cm from the mid. Pitch 0, body yaw 35 deg off the piece (the +35 aim).
    - The chest line hit the piece at 128 of ~155 cm.
    - The camera sits 120 cm above the capsule and ~8 m from the piece. Its line hit another split log first once.
    - These are the numbers an unhittable piece's "diag nohit" is compared against.

## Lethal drops (continued) and built doors (2026-11-01 16:37-16:55Z; game build 26161880, client 26162923, dev world, ClaudeDev; movement agent)
- **Third death at the same edge, 16:37:21-25:**
  - An `interact` on his grave walked a straight 6.3 m go_to from (40.84, 1747.31) SE toward the grave.
  - His last walking sample was (44.40, 1744.99, -29.75). He was falling by (45.45, 1744.30), and his HP read 0 at -65.8 m. The body came to rest at (48.62, 1740.40, -70.93), on the cliff floor there.
  - The drop probes found floor a little below his feet: the steep shoulder itself. He slid down it and over the edge.
  - cliff_guard now follows ground that is too steep to stand on (hit normal under WalkableFloorZ, going down) for 2-6 m ahead. If it ends in a fall over the safe height, he holds: "a slope too steep to stand on ahead, down to a 40 m drop".
  - On 16:01:35-44 he fell from (39.64, 1745.90) at -40 m/s, past -300 m, then respawned. West of x 40 there is no floor within reach.
- **Built doors (probe `door_probe.lua` in the movement scratchpad, 16:5xZ, dev):**
  - Class chain: `BP_T1_Door_C` -> `BP_BaseBuilding_BaseActor_C` -> `BaseBuildingActor` -> Actor.
  - BP properties: `HingeInteraction`, `Hinge`. The interaction prompt reads "Open Door" when shut (get_state interactables: Claude's house door, BP_T1_Door_C at (94.71, 1853.14, -30.31), yaw -90, 1.5 m above the floor top).
  - `FindAllOf("BP_BaseBuilding_BaseActor_C")` returns the doors among the base's built actors.
  - The house as built at 16:50Z:
    - foundations 61 (96.21, 1850.14) and 62 (96.21, 1853.14), top -31.81;
    - walls on every edge, except the door's frame on 62's west edge;
    - ceiling tile 71 over 61. A teleport to the old ladder start (95.14, 1850.23, -30.91) was 0.43 m from the inside of 61's west wall, and he ended up standing on that tile.

## Rung 1 gate: fight back, rest, eat/drink timing (2026-11-01 16:04-17:01Z; game build 26161880; dev world, ClaudeDev; rung1 gate agent)
- **A fixture-spawned Goblin Runt does not attack at once.** Spawned 6 m from him (`bench spawn`), it wandered to 12-13 m for 20 s (16:04Z) and 35 s (17:00Z), then came at him.
  - The body's guard starts the fight on `hostile_near`, about 1.6 s before the runt is within 3 m (17:00Z: combat_started at 9 m and closing).
  - So the gate times "fight back when hit" from engagement (the runt within 3 m, or his HP falling), not from the spawn.
- **Bare-handed vs. armed (same runt, 60 HP):**
  - 16:04Z, bare hands (his sword and shield were in graves from earlier deaths in other agents' tests): 6 presses and 34 damage in 38 s; he took 120 damage and died.
    - The guard's estimate said `likely_win`, 8 s to kill, 36 s to die. The 8 s kill estimate was wrong for bare hands.
    - `held_back_s`: defending 8.3, fleeing 11.0, out of reach 4.9.
  - 17:00Z, Stone Club: dead 12.0 s after engagement, no damage taken (HP 100 throughout). Bar 1.5 x 21.3 s (Luis 19.84 s per kill + 1.5 s reaction).
- **Summon Shelter in Temple Woods fails.** At the respawn point (51.2, 1905.9, -33.9), 16:07Z, every automatic spot (rings 3-9 m) read "blocked".
  - Both "flattest ground" hints, (77.2, 1890.9) at 30 m and (86.7, 1885.4) at 15 m, were off his walkable map: `go_to` failed `path_blocked` / no_route after 49 s and 53 s, walking 170 m and 144 m for 30 m and 15 m goals.
  - The hint (spells.lua `placement_failure`, `far_rings_m` traces with `los = false`) does not check that the spot is reachable.
  - Luis said "sleep" at (101.24, 1868.4, -30.69) and set his shelter at (98.1, 1858.7) (recorder 12:46:52Z). The gate's rest item starts there.
- **"Exhausted" news latency.** With `REVIEW_SAMPLE_S` 30 s, the situation_review came 27 s after rest fell to 5 % (16:07Z). With 10 s it came about 6 s after (17:01Z), and the model chose `cast Summon Shelter` 2.7 s later.
  - His false claim at 16:10Z, "resting where I am", was flagged by the truth judge: rest only rises in a bed or a shelter.
- **The food/drink use lock is per kind.** Luis ate a Farm Steak and drank Clean Water 0.06-0.83 s apart, five times (recorder 12:47-13:19Z: a `use_item` rpc, then -1 of each item).
  - The same item back to back: 31 ClaudeDev pairs, min 5.12 s, p10 5.41 s, median 6.08 s.
  - So a player's eat/drink time is 1.5 + max(food uses, water uses) x 6.1 + 0.8 s (coordinator decision, `rung1_gate.USE_S` / `BOTH_KINDS_S`).
  - **Verified from Claude's client (build 26161880, 17:02-17:03Z, dev world).** `client_mod/commands/use_overlap_probe.lua` presses the hotbar keys (`QuickAccessBar:UseItemInSlot`) without the body's busy gate. Three variants, each from 50 % food and water (37.5/75): a Fillet and a Clean Water in one frame; the food, then the drink 0.5 s later; the drink, then the food 0.26 s later. Every time, both stats rose by the 1.05-1.27 s poll (+19.4 food, +24.2 water) and one of each item was spent (logs/evals/use_overlap.jsonl).
  - The body now keeps one use lock per kind (`inventory.consume_busy(kind)`, 6.0 s on `os.clock`, which is wall time with ms under the MSVC CRT). A potion or any other kind waits for, and blocks, every kind; that case is not measured.
  - Live (17:24-17:25Z), the stay-fed reflex alone, both at 33 % (under the 40 % line): one tick pressed a Clean Water and a Fillet 0.01 s apart, and both stats rose by 0.84 s and 1.45 s.
  - Live, his own consume tool from 60 %: Fillet done at 0.41 s (44.7 -> 64.7), Clean Water sent at 0.41 s and done at 0.82 s (44.7 -> 69.7, no wait), a second Fillet waited out the food lock and was done at 6.36 s (64.3 -> 75.0, the max). Each result reports its own before/after.
- **What killed him, for the brain.** The vitals watcher writes a `fatal` row about 1 s before the `death` row (15:56, 16:01, 16:04, 16:37Z). A fall off the Temple Woods cliff (29.5-31 m) ends in the game's kill zone: `killed_by {id "Default__KillZVolume", class "KillZVolume"}`, `status []`, `status_flags 1`. A creature's kill names it (`Goblin Runt`, `BP_AI_RuntGoblin_Character_C`, `status_flags 0`). The death row carries the bars (`survival {sustenance, hydration, endurance}` = [value, max]).
  - Run 5 (16:37Z): he fell into the kill zone at food 12 %, water 61 %, rest 87 %. The interact result was `companion_down: character is dead` 0.8 s after the fatal row, before the death row, so the follow-up turn saw only that result and food 12 %. He said "starving got me".
  - Now the bridge sets `get_state.last_death` at the fatal row: `killed_by` in words (KillZVolume reads "falling into a kill zone (a drop the game kills anything in)"), `killed_by_class`, `fell_m`, and `bars {food, water, rest}` in percent from the last survival row; the death row replaces the bars. A death with no fatal row within 10 s before it has `killed_by` nil, so an older death's cause is never carried over.
  - The brain says "cause unknown (the game didn't say)" when nothing names the cause, and for bars with neither food nor water at 0 it adds "food and water above 0, so not hunger or thirst". This goes in the Recent line and, for 5 min, in each follow-up turn's observation (`last_death`).
- **Rune Mysteries COMPLETE, window 3 (17:0xZ, "claude, carry on with Zanik's quest", 78.2 s, 4 Haiku, $0.0023, no stand over 5 s):** moved 281 m away again by other windows; go_to Zanik 67.7 s (4.9 m/s), talk 1.7 s -> "Quest Rune Mysteries is complete. New quest First Steps: Speak to the Wise Old Man in Bramblemead village. Given to you in this conversation: 1 Tome of Woodcutting - Vol 1, 10 Air Rune, 10 Astral Rune." (true; matched by asset, a second First Steps asset is the new quest). The essence / rune altar / rune crafting that Zanik describes was never asked for as a step: "Return to Zanik." was met by talking (he was carrying 51 Air + 1979 Astral fixture runes, so whether the game checks for runes is unknown). Whole quest over 3 windows: 443 s in-window, 120 s of it re-walking to Zanik after other agents' windows moved him (322 s of play), 18 Haiku calls, $0.011, 3 misses (the remembered-grave go_tos), longest stand 16.9 s.
- **The second "First Steps" (given by Zanik), one window (17:2xZ, "claude, carry on with your quests", 302.6 s to the deadline, 11 Haiku, $0.0062): NOT done.** Step "Speak to the Wise Old Man in Bramblemead village." go_to Wise Old Man 21 s and talk 1.1 s reached the FTUE Wise Old Man by the temple (61, 1874), whose only options were small talk ("Who are you?" ...). The brain worked out "this one's not the quest guy, the real one is in Bramblemead" (true: the step's markers, and Growing Pains' / Shrimp Catcher's, sit at (485, 1776), 397 m east). `go_to Bramblemead` -> unknown_target (the places data only has the region "Bramblemead Valley", offered back as map_names_like_it); `go_to [485,1776,-33.5]` (the marker) -> path_blocked after 118 m: "the walkable map ends 414 m short of the goal", endurance 0 (movement). He cast Summon Shelter "to rest", then the brain's chain stopped on its 8-turn budget and he stood **194 s** to the deadline with no episode (the brain's chain budget; only the vitals reflex drank and ate).
- **Three talk misses in that run, all one cause: `ConversationComponent.CurrentNPC` reads nil on the client.** (1) `talk {target, choose}` on an open dialogue was refused as mixed args; (2) `talk {target}` said "I'm already talking to nil"; (3) meanwhile input.lua's orphan sweep, whose ownership test was `conv.npc == CurrentNPC` (nil), pressed Cancel on OUR open dialogue between the brain's calls (after orphan_s = 1 s), so `talk {choose}` then said "I'm not talking to anyone". Fixes (talk.lua): a recorded conversation owns an open dialogue unless CurrentNPC plainly names another NPC; `{target}` while talking re-reads it unless it is plainly another NPC's; `{target, choose|leave}` answers / leaves an open dialogue, and with none open starts it and says so (test_talk 62/62).
- **Quest markers keyed by name mixed two same-named quests:** the new First Steps' `where` listed the finished First Steps' "Doric Objective" (19 m) first. quests.lua markers now carry the quest asset and attach by asset (test_quests 21/21).
- **Brain chain stands, two causes fixed (quests agent, 2026-11-01 ~18:0xZ; offline tests/test_chain_hand_on.py 4/4).**
  - **(a) Follow-up turns were blind to perception.** After a tool result, a turn got only `current_observation`: position, vitals, inventory, stations, needs and the last death. It had no census and no situation lines, so the gravestone 1.4 m away (in the "Usable:" line) was invisible to him. `Controller.next_turn` now adds `situation`: the same `sit.summary` lines as the first turn, or "unchanged since you last saw it". The summary is at most 10 lines.
  - **(b) The turn budget left him idle and silent.** When the 9th turn ran tools, the chain stopped on "budget" without the model seeing the results, and nothing followed (he stood 194 s). `Agent._hand_on` now queues a `chain_budget` body situation: {request, from, hand_on n of 2, last_results}. The next pump gives the model a fresh run in which it decides.
    - Capped at 2 hand-ons per request.
    - Not inside board runs, whose budget is the board's.
    - Never when the player spoke or the deadline passed.
    - If the model stays silent in a hand-on run, code doesn't talk over it.
    - Only when the last hand-on also runs out with nothing said does the template "I've stopped partway through '<request>': I ran out of steps before finishing" tell the player.
- **Place names by their leading words (places._match "leading"):** a query that is a map name's first words ("Bramblemead" -> the region "Bramblemead Valley") names it. go_to takes it only when exactly one map name starts that way; "Bramble" in the test data (Valley, Village) stays the model's call via map_names_like_it. This uses the game's own place data, with no alias table.
- **Human time bar for quests (tools/quest_run.py `human_bar`; Luis has no quest baseline).**
  - **What counts:** the successful steps only. A failed call costs nothing, and its walk counts only as far as the next step needed.
  - **Walking:** the straight line between where each step ended, from the brain's get_state reads, at his 6.25 m/s.
  - **Work, from data/baselines/luis-2026-11-01.json:**
    - craft 9.61 s; a craft at a fuelled station (`fuel_used`) uses his cook time, 15.75 s;
    - kill 19.84 s per creature, including reflex `combat_end` kills;
    - build 3.81 s per piece;
    - chop and mine per item, from his windows' `gained` (chop 40.94 s / 13 Ash Logs = 3.15 s per log; mine 0.91 s per stone), chosen by the gather result's `trains`;
    - one press (interact/equip/consume) 1.12 s; spell 8.85 s.
  - **Reading:** an NPC's lines at 238 words/min (Brysbaert 2019).
  - **Reaction:** REACT_S 1.5 s per chat line and per step.
  - **Ratios of past runs** (Claude active time / bar):
    - Getting Started 26.7 / 72.9 s = 0.37x (Doric's lines take a reader 53 s);
    - Ratcatcher run 2: 204.6 / 157.1 s = 1.3x;
    - Rune Mysteries windows: 1.58x, 1.5x, 1.38x;
    - second First Steps (failed walk): 8.3x.
- **Quest-cleared clones of ClaudeDev load on dev (main + Luis's recipe; tools/quest_clone.py; live 18:46-18:57Z, ClaudeQ1).** The dev server caches characters by `char_guid` (CachedCharacterStates), so a fresh guid makes a character the server has never seen. It loads from the client's `SaveCharacters/<name>.json`, at the file's `LastAccessibleLocation`, with level, gear, spells and bag as in the file. The dev referee listed ClaudeQ1 with its new guid 58 s after the switch began.
  - **Quest ids:** `QuestProgress.Quests[].QuestId` is the QuestData's `UDominionDataAsset.PersistenceID`, read live by `client_mod/commands/quest_ids_probe.lua`:
    - Quest_FTUE_GS (First Steps 1): AmuXOUitB08PYDCmdVA_Ug
    - Quest_FTUE_RtftJ (Getting Started): xa8o60AbJZ23FymQeiH3bg
    - Quest_FTUE_RC (Ratcatcher): SDcUrkVqRiTKKEyzEh5DWw
    - Quest_FTUE_LO (Rune Mysteries part 1, `ftue_rm_prt1`): TgVnb0NCLvmEVRed59IgsQ
    - Quest_FTUE_RM (part 2): zrqqFUNmx3lcF6umysJfvQ
    - Quest_FTUE_FS (First Steps 2, Bramblemead): luaLQEzPXjx9_ICiz5zkNg
    - Dragon Slayer: yrRZnkmro-IvH_OmZ3f-5A
  - **QuestLocations** are named `<NPC>_<Objective|NPC|Area>_FTUE_<quest suffix>`. The save also keeps `Zanik_Objective_NPC_RM`, which has no live actor.
  - **Dragon Slayer** holds the bool `WOMTempleHidden = true` once the chain is done. Characters fresh out of the temple (Claude.json, ClaudeGuest.json) have no bools there.
  - **What a character fresh out of the temple holds,** as the game saved it in both those files: First Steps 1 at state 1, Objective2, with bools `HasTriggeredEntryVolume` and `HasTriggeredExitVolume`; QuestLocations `WOM_Objective_FTUE_GS` true and `Doric_Objective_FTUE_GS` false; no QuestTrackedMain.
  - **What a clone holds:**
    - First Steps 1 reset to that state. It is not removed, because the game gives it from the temple's entry volume, which a clone never crosses.
    - The other five FTUE quests, their QuestLocations and `WOMTempleHidden` removed.
    - QuestTrackedMain set to First Steps.
    - Every other byte as the game wrote it: the file is edited as text, and the QuestProgress block is written in the game's own JSON layout (tabs, CRLF, an object opening on the next line), checked by a byte-exact round trip of the original block. There are no per-item GUIDs in the file, only `char_guid`.
    - The `Backup` int is copied unchanged and was not checked by the game.
  - Each clone's pristine copy is kept in `logs/quests/clones/`.
  - **ClaudeQ1 run, one window of 634 s (switch there 58 s, back 44 s), from one chat line per quest: 20 Haiku calls, $0.019, no fixture grants.** The bag was ClaudeDev's, including his leftover fixture runes.
    - **First Steps: 33.2 s, 0.36x.** The Wise Old Man was back in the temple: talk, then `choose 1` "Yes please [Begin Tutorial]", then Doric. That completed it and gave Getting Started at "Build a Crafting Table and craft a Stone Club", because tables stood nearby and he had water. He crafted the club inside this run.
    - **Getting Started: 7.3 s, 0.38x.** Doric gave a Vegetable Soup and Ratcatcher.
    - **Ratcatcher: 159.2 s, 1.11x** (human bar 143.8 s). One miss: `attack` too_far, the first rat outran him. He killed a second rat, cooked a Rat Roast at a campfire in 26.9 s, and handed it in.
    - **Rune Mysteries part 1: 191.5 s, 0.87x.** 11 Ash Logs in the bag plus 39 chopped in 129.5 s. Zanik gave a pickaxe and part 2.
    - **Part 2 NOT done.** He said "Rune Mysteries done, Zanik gave me a pickaxe. Next is mining rune essence from the geysers" and stood 40 s, until the run ended quiet.
  - **Cause:** the talk result read "Quest Rune Mysteries is complete. New quest Rune Mysteries: Mine Rune Essence...". The game names both parts alike, so "complete" read as the whole job done. `talk.outcome_words` now says "Rune Mysteries goes on as a new quest of the same name: <step>" when a finished quest's namesake is given in the same call (test_talk 63/63).

## Graves as storage, the temple-pit route, raised NPC platforms and the shared camera (2026-11-01 18:00-19:10Z; game build 26161880, client 26162923, dev world, ClaudeDev; movement agent)
- **A grave whose contents won't all fit is storage.** Its prompt reads "Open" (not "Take All"). The press opens the game's container screen for it (`W.open_container(api).owner == grave id`), and the rows move with the same `UInventoryUIAPI::HandleSplitToSlotFromExternal(from_slot, inv, amount, to_slot, slot_type)` as a chest. `HandleTakeAllFromWorldInventory` also exists on the same API (unused).
- **A press on a crafting or processing station opens its screen, and a second press shuts it** (build 26161880, live 2026-11-02 04:22-04:33 local, Crafting Table BP_Crafting_StartingBench_C).
  - The open screen reads as `CraftingUIAPI.CurrentStation:GetOwner()` (processing: `ProcessingStationUIAPI.ProcessingStationComponent`) = the station actor, the same read as `crafting.W.open_station`.
  - interact's verify now counts it as `changed = "opened"`.
  - The take-all handlers for world containers are `UWorldActorInventoryUIAPI::HandleTakeAllByPlayer()` (the screen's Take All button; also HandleFillStacksByPlayer, HandleSortByPlayer, CloseCurrentInventory) and `UInventoryUIAPI::HandleTakeAllFromWorldInventory()` (CXXHeaderDump/Dominion.hpp). They are unused: the grave's ordered take keeps gear first (Luis).
  - Row data read from each `UItemData` (dump Dominion.hpp:25279): `Category` (FGameplayTag, `.TagName`), `MaxStackSize`, `Weight`, `PowerLevel`. Gear: `Item.Equipment.*` (minus `*Ammo*`) and the Torch's `ItemFilter.Type.Equipment.Tool`; seeds `ItemFilter.Material.Seed`.
  - The carry limit: `PlayerEncumbranceComponent` `GetCurrentCarryWeight` / `GetMaxCarryWeight` read 309.4 of **400** at 18:08Z (250 earlier in the day).
  - Live 18:08:04-11Z: 142 of 145 items in 6.6 s over 31 moves; the bag filled and Animal Bone, Feathers and Vault Core stayed in the grave.
- **The temple pit is a navmesh island: the oracle's route from it is partial, and it can end behind him.** He walks on toward the goal while the oracle answers (the provisional walk); for a 434 m trip the answer took 11-12 s and ended 13-16 m behind where he had got to, at the island's edge. Joining it ended the trip ("walkable map ends 414 m short", quests 17:20Z). Asked again from where he then stood, the oracle gave a full route every time (18:11Z: 19 points; 18:29Z and 19:00Z: 20).
- **The quests' 2.7-4.9 m/s walks (17:14-17:37Z) were exhaustion:** every one of those trips read endurance 0 (no sprint, jumps fail).
- **The Bramblemead Wise Old Man stands on a raised platform** (floor -35.3 m, the ground under it -41.8 m; trace grids around (485, 1776), 18:16-18:32Z, scratchpad `floor_grid.lua` / `mv_gapline.lua`). The way up is a switchback east of the house:
  - ramp B rises east along y 1773.5-1776.5 from the ground at x ~485 (under the platform's edge) to a landing at -38.0 m (x 493-496.5, y 1772.2-1775.5);
  - landing A at -38.0 m (x 489.5-496.5, y 1768.5-1770.6), then ramp A rises west along y 1768.5-1769.5 (0.5 m per m) onto the platform at x 487;
  - **the two landings are 1.6-1.8 m apart over a 3.6 m drop** (fine traces at x 493.5/494.5/495.5), so a player jumps that gap; the landings end at x 496.5 in a 3.6-4.2 m drop;
  - the dev navmesh does not join them: oracle queries from the ground, landing B and landing A to the platform all came back partial, ending on the ground under the goal.
- **The local planner had no gap jump.** It now has a leap edge (mineflayer-pathfinder's parkour move): from a run-up cell, through a take-off cell at the same level, over 1-2 hole cells, to a floor at that level. The landing counts within 1.3 m.
  - Live 19:01:14Z the planner (13 m window, goal overhead) found a 28-point route up, but chose a double jump of 3.0 m from the gap's ground onto landing A, which missed twice. A jump that misses is now left out of that trip's next plans.
- **A go_to goal above him at his x,y** (the build's spot 2.1 m over the house floor, 17:25-17:44Z, "stuck n=159"; the Wise Old Man 3-6.5 m up): one downward trace at the goal says which. Live 19:01:26Z: "goal above: the spot is on a floor 6.5 m above me, higher than I can jump, and I see no way up from here", 2 s after the last plan.
- **The camera is shared.** In move.lua, every control-rotation write now goes through one choke point (cam_write). It compares `GetControlRotation` with move's own last write.
  - Live 18:59:19Z: a foreign aim written every frame for 45 frames during a go_to was overwritten once (the first frame), then left alone while he walked on (73 m in 15 s), and move took the camera back afterwards.
  - Live 18:50:53Z and 18:51:02Z: combat's parry turned the camera during a chase follow; move yielded and walked on.
- **The water channel lasts for a client run only.** A wade where no channel saw the surface sets `DW_WATER_CH = false`, and every remembered water cell is then trusted all run ("cannot check: no water channel": a false church-door water plan cost the grave walk 13 s). The calibrated channel ('cam', Camera channel 1) is now kept in `client_io/state/water_channel.lua` per client build.
  - **ClaudeQ2 run, one window of 1039 s (switch there 44 s), 18:58-19:24Z, 41 Haiku calls, $0.040, no fixture grants.**
    - **First Steps: 55.2 s, 0.67x.** He walked to Doric (37 s) this time, and talked to him in 1.9 s.
    - **Getting Started: 7.1 s, 0.38x.** The clone's bag (ClaudeDev's) already held a Stone Club, and Doric took it, so no craft was needed. The game checks the bag.
    - **Ratcatcher: 180.4 s, 1.07x.** One miss: `go_to windmill` was unknown_target, because the windmill is not a map name. He walked to the hill by coordinates, the combat reflex killed 2 rats, he cooked a Rat Roast in 32 s and handed it in.
    - **Rune Mysteries: NOT done, deadline 595.6 s, 1.89x.**
  - **Rune Mysteries part 1, and what went wrong in it:**
    - Part 1 took 317 s. The first `gather ash` was `body_error` `inputs_not_reaching_game` ("My swings aren't doing anything at all"): 15 swings and 4 hits in 39 s, then 1 log.
    - The second gather took 214 s for 47 logs, 4.6 s per log against his 3.15.
    - The new wording worked: "Rune Mysteries goes on as a new quest of the same name: Mine Rune Essence...". He said "Quest step done, got the stone pickaxe. Next up is mining rune essence" and went on.
  - **Rune Mysteries part 2:**
    - He mined 20 Rune Essence in 68.7 s.
    - He `interact`ed with an Anima Vent in 6.7 s: 10 Astral Runes, the vent's own `gained`. He said "got a pile of astral runes off the vent" (true).
    - **Then he was stuck in a hole beside the vent at (276.68, 1812.94, -41.35).** Every go_to, to the Air Anima Vent 88 m off, to Zanik 15 m off, and to points, "walked" 17-20 m and ended where it began, with "fell 3.2-3.3 m (stuck)". Windstep and Phase Dash each reported `moved_m` 0.0.
    - He said so truthfully three times ("can't get to Zanik, keep getting stuck by the vent and falling. might be a pit, can you help me out?"), then stood 18.6 s and 14.7 s waiting for help. Both stands came with a stated reason.
  - **Why a clone's part 2 is real work:** ClaudeDev's part 2 jumped straight to "Return to Zanik" because his save already held the part 2 bools (`HasCollectedAirRune`, `HasCollectedAstralRune`, `HasApproachGeyser`; the game records them even while a quest is ungiven, as in Claude.json). A clone has none of those bools. So the objective needs new Air and Astral runes collected (from a vent, or crafted at a built altar) and the geyser approached. The runes already in the bag do not count.

## Anima Vents are Hold interactions; go_to edge cases; stale traps; follow hops (2026-11-01 19:25-21:10Z; game build 26161880, client 26162923, dev world, ClaudeDev; movement agent)
- **Siphoning an Anima Vent is a Hold interaction, and it roots him until the key is let go.** This is what the quests run's "pit" at the Astral vent was (ClaudeQ2, 19:20Z).
  - Every `BP_AnimaVent_C` (`AAnimaVent`, Dominion.hpp:8760) has `InteractionComponent.InteractionType` = 1. `EInteractionType`: PrimaryAndSecondary 0, Hold 1. Read live on 4 vents near the base.
  - The vent has `Interact(PlayerCharacter)` and `InteractStop(PlayerCharacter)`. `UPlayerInteractionManager` has `InteractAction` = IA_Interact and `InteractActionStop` = `/Game/Gameplay/Inputs/Actions/Basic/IA_InteractHold.IA_InteractHold`, the release. `Server_RequestInteraction(..., bIsRelease)`.
  - **Held (live 20:23:26Z, one frame of IA_Interact with no release):**
    - `UInteractionComponent.PlayersCurrentlyInteracting` lists his pawn. It replicates to the client.
    - The montage is `AM_PlayerM_Sorcery_Spellcast_AnimaRuneSiphoning` (root motion while it plays).
    - The vent kept siphoning: `PercentageChargesAvailable` went 90 -> 70 -> 0 in 2.5 s.
    - A 4 m go_to: "Moved 0 m in 8 s", stuck. Throughout, `IsMoveInputIgnored` = false and MovementMode = 1 (walking), so no generic signal shows it.
  - **Released (20:23:43Z, one frame of IA_InteractHold):** he dropped off the list, and the go_to walked 3 m in 1 s.
  - **The fixed interact (20:23:19-21Z):** press, then +10 Air Runes, then release at the job's end. Charges 100 -> 90; he was not on the list afterwards.
  - The ClaudeQ2 "pit" was this hold. xy stayed exactly (276.68, 1812.94) for 5 min, and Z moved +3 m and back every 2 s: his own stuck hops. These were summed as "walked 17-20 m" and read as "fell 3.2 m".
- **move's trip numbers:**
  - `walked_m` is ground covered (2D).
  - A fall is the drop from where he left the ground, not his own jump's apex.
  - `net_m` is the start-to-end distance. When it is under half of walked_m, the sentence says so: live 20:05:13Z, "Walked 140 m in 60 s ...; I ended up 8 m from where I started" (wall-following round his house for a 4 m go_to; see the next item).
- **The dev base house blocks short walks west of (101, 1850).**
  - Local plans fail "walls everywhere", and "a shut door at (101,1853) ... didn't open: it stayed shut after 2 presses" (20:04:14Z).
  - Bug2 wall-following took 140 m and 60 s, and did not arrive.
- **A go_to to a spot in the air beside him** (1 m off, 2.6 m up) arrived "right under it", but only after the oracle's "invalid_route", 17 s later. The overhead check now runs before any route.
- **The water channel is loaded from client_io/state/water_channel.lua, and false water cells are forgotten.**
  - The "cannot check: no water channel" lines with the channel loaded came from `x and water_at() or nil`, which turns a dry `false` into nil.
  - Live after the fix (20:04:22Z, 20:04:57Z): "no water at (9700,184700) after all (a roof or a bench fooled the probe); forgotten".
- **Bramblemead platform, live 19:26-19:27Z:**
  - The local plan went up ramp B and leapt the 1.6-1.8 m landing gap (`[...l...]`, a 130 cm landing radius). He arrived on the platform: 99.2 s against the human 76.7 s (x1.29).
  - 18 s were lost at the ramp foot (483.5, 1779), where a double jump "never left the ground" twice.
- **The hold let-go, live 20:39Z at the Water vent (vent3 window):**
  - A walk started while a hold he pressed was still on let go first: "I let go of the Water Anima Vent first (holding it kept me in place)", then 3 m in 1 s.
  - A hold pressed with no bookkeeping (a raw IA_Interact) was found by the stuck check, which scans the detector's Hold target `PlayersCurrentlyInteracting` for his pawn. He let go and walked on, 9 s in all through wedged(). This now happens at the first stuck (n == 1).
- **The combat approach's false no_route was move's follow, not combat (ClaudeQ4 Ratcatcher, client_io/events/move.jsonl 20:09:02Z and 20:09:07Z).**
  - The events read follow "unreachable", reason no_route, detail "jump landing missed".
  - combat's approach is a move follow, and `approach_blocked` reads move's progress verdict.
  - In follow mode, one missed landing on a planned djump edge went straight to unreach = no_route; a go_to re-plans after the same miss, which is why the go_to then got there.
  - Now a follow re-plans like a go_to and gives up as no_route only on the 3rd failed jump of the trip. The failed edge (any landing or "unavailable" fault) is avoided in the next plan.
- **Trap t227 (8 m round (99.23, 1854.91), the base) was a stale trap that nothing could disprove.**
  - It was learned at 13:29:45Z. A 13:27Z go_to failed "unreachable: no_route ... blocked by walls" at that spot, which was a real confinement between house walls then, and the next walk away (a follow, local plan round the walls) became its exit.
  - The base was rebuilt later, but on every start inside its 8 m, memory_once walked the exit FIRST and counted it as n_used. Result: n_used 128, n_ok 1.
    - rung3's cook walked 18 m to end 4 m away, and boil 26 m in 9 s to end 5 m away.
    - The 20:05Z ts is just a refresh: learn_trap rewrites ts and the exit on every use. The 37-point exit was the 140 m wall-following of a 20:04Z go_to that had started inside it.
  - Others with the same pattern: church_respawn (n_ok 1, n_used 779), t5 (1, 183), t6 (1, 240), t103 (1, 120). t7 has n_ok 3.
  - The rule now (navmem `trap_trusted`, `trap_miss`; move `trap_evidence`):
    - A trap's exit is walked first only once the trap shut him in at least twice, and more than twice as often as he walked out of it. Otherwise he walks his own way, and the exit is only the stuck-ladder rung (memory_retry).
    - Counts against: a start inside that took no stuck and did not use the exit, and then arrived at least 2 m away or left the trap area.
    - Counts for: a stuck on a start inside, then an escape (n_ok).
    - Once the walks against outnumber n_ok, the trap is forgotten: a tombstone that keeps a map seed of the same id off.
- **The leader's hops and Windsteps on open ground were the main follow loss.**
  - Luis bunny-hops and Windsteps on the flat. The recorder marks the Windstep glide as not falling: flat z 2.7 m up, air 0.
  - Each copied jump dropped him to 2-3 m/s for 1-3 s. Behind a 6.8 m/s ghost (his own top sprint), that gap never closed: church_loop 20:19:24Z, 10.5 m behind for 5 s, and the same at doric 13.5 s.
  - Now a trail jump is not copied when the straight line to where the leader lands on our level, or to below him while he is still up, is clear at knee height with floor all the way (`escape_line_clear`). Over a wall, a gap or a ledge it is copied as before.
  - **Live (rung1 gate proxy, 20:58Z, follow_church_loop):** 99.3 % within 6 m, against 84.4 % at 20:19Z and the human model's 83.2 %; max gap 6.2 m, longest stand 1.3 s, within_human 1.0.

## Rung 1 gate: bag pages, built crates, eat/drink choice (2026-11-01 18:20-19:25Z; game build 26161880; dev world, ClaudeDev; rung1 gate agent)
- **Runes and ammo don't take bag slots.** The raw inventory (`inventory {raw=true}` -> `pages`) lists each page with its slot count: `QuickAction:8`, `InventoryItems:32`, `InventoryRunes:32`, `InventoryAmmunition:32`, `InventoryQuestItems:72`.
  - The compact `inventory` lumps every non-hotbar page into `bag`; only rows with `slot_type == "InventoryItems"` count against the 32 bag slots.
  - `empty_slots` (`GetNumEmptySlots`) counts all pages (133), so it is no measure of bag room.
  - Verified 18:4xZ: 28 of 35 "bag" rows were InventoryItems (6 rune stacks, 1 ammo).
- **A full bag makes fixture grants fail with `not_added`** for a new item kind (a new stack needs a slot), while a grant that merges into a stack he carries still works.
  - 18:19Z with InventoryItems 32/32: Dirty Water +1 merged; ITEM_Resources_Meat_Bird and ITEM_Consumable_Fruit_Redberry were not_added.
  - Every hotbar->bag `move_item` answered inventory_full, and the stay-fed reflex then ate from the hotbar.
- **Built crates (`BP_BaseBuilding_Crate_C`): `store` failed with not_a_container**, because `inventory.inventory_of` found no inventory.
  - Fix: `inventory.owned_inventory`, the one InventoryComponent whose `GetOwner()` is the crate (FindAllOf), as in `deconstruct.W.contents`.
  - Offline tests pass. Not yet exercised live (the next run's bag had room).
- **His crates at the dev base** (my_pieces.json, census 18:4xZ, kind `storage`):
  - BP_BaseBuilding_Crate_C_2147144746 at [103.81, 1857.77, -31.71], built 18:35Z;
  - 2147266572 at [108.24, 1848.1, -32.11];
  - 2147266357 at [112.54, 1849.09, -31.92].
  - The campfire nearest LUIS_SLEEP is BP_Station_Campfire_C_2147145659 at [98.38, 1867.12], 3 m off.
- **Eat and drink by comparing options, live 19:24Z** (r1-20261101T190024Z): 9.8 s vs T_h 9.1 s.
  - Setup: food and water at 25 %, everything edible in the bag.
  - On offer: Vegetable Soup +50, Fillet +20, Rat Roast +20, Redberries +5, Burnt Steak (Soulscourge), Pumpkin Spice Infusion +80, Clean Water +25, Dirty Water +10 (Soulscourge), Raw Rat Meat with a fire 3 m off.
  - He moved Vegetable Soup and Pumpkin Spice Infusion to the hotbar and used both: two move_item calls, then two consumes, each pair overlapped.
  - Food went 25 -> 74 % and water 25 -> 99 %, with 3 Haiku calls. The choice judge (Haiku, from the digest he saw) said sensible.
  - **The failed first gather, for the gather/input owner.**
    - When and where: ClaudeQ2, `gather {resource ash, count 45}`, 19:14:13-19:14:52Z (39.2 s). He started at (265.71, 1824.14, -41.21), near Zanik on the river road.
    - Result: `body_error`, `why inputs_not_reaching_game`, 15 swings, 4 hits, 1 log, 1 tree broken.
    - Phase log: approach root Ash Tree 17.7 m; aim 1.15 m; swing at 5.4 s; "settle felled" at 10.8 s; "scan settle timeout" at 20.9 s; approach splittable log 5.2 m; swing at 23.2 s. The rest of the log is not in the result.
    - The retry at once from (266.13, 1808.91, -41.57) worked: 47 logs, 72 swings, 61 hits, 213.8 s.
    - In that retry, every felled tree also waited about 10 s on "scan settle timeout" (143.7 to 153.7 s, 160.4 to 170.4 s). That is part of why his chop rate was 4.6 s per log against Luis's 3.15.
- **go_to a quest map marker by its name (brain/executor.py `_quest_marker`, tests/test_places.py; after the ClaudeQ2 miss).** Ratcatcher's step reads "Speak to Vannaka near the windmill", and Vannaka says the windmill is up the hill. The step's own map marker `Windmill_Area_FTUE_RC` reaches the model as "Windmill Area" (an area of 80 m radius at (156.1, 1713.4, -3.5), in the quests tool's `where`). Yet `go_to windmill` was unknown_target, because the map data has no windmill.
  - When a name matches no map name, the go_to/talk fallback now reads the active quests' markers through the body's `quests` tool. It matches the name like a map name: the same words, every word of the marker, or the leading words of exactly one marker.
  - A match walks to the marker: "'windmill' is not in sight; walking to the game map's Ratcatcher quest marker Windmill Area, 158 m away: an area of 80 m radius on the quest map".
  - When two markers fit, the model decides. No word list: the names come from the game's own marker ids.
  - **ClaudeQ3 run, window of 413.5 s, 19:34-19:42Z, 15 Haiku calls, about $0.013.** Back on ClaudeDev at (105.89, 1849.7, -31.44).
    - **First Steps: 53.4 s, 0.64x, 0 misses.**
    - **Getting Started: done in the First Steps run's last few seconds,** about 5 s after it was given at 51.4 s. Its own run then read complete at 0.0 s. One miss: `give {player Doric, item Stone Club}` came back unknown_target, worded as if Doric were a player ("I can't see where you are from here, Doric"). The hand-in happened through the talk that followed.
    - The brain was stopped while that talk was in flight, so Doric's dialogue stayed open. Ratcatcher's first `talk Vannaka` read it back ("Doric says: ..."). The model left it and talked again: 2 calls, 2 s.
  - **Ratcatcher: NOT done, an artefact of the harness.**
    - The commanded `attack Giant Rat` killed one rat in 15.4 s.
    - The next attack came back `interrupted`, "busy: combat:reflex (reflex) is using my legs". The reflex had started on a second rat, and the chat request ended "superseded".
    - The combat_end situation attacked again, and was interrupted by a third rat.
    - Then the reflex fought, fled at 29 HP, healed with the Vegetable Soup and fought back, from 107 s to past 150 s.
    - quest_run counted only brain activity, so it ended the run "quiet" at 150.8 s mid-fight and booked a 40.6 s "stand".
  - **Fix in tools/quest_run.py `timeline`:** the body's own activity events (`<x>_started` up to the next `<x>_*`: combat, flee) are busy intervals. A run does not end quiet while one is open, and a fight is not a stand. tests/test_quest_run.py 4/4.
  - **ClaudeQ4 run, window of 808.8 s, 20:05-20:19Z, 23 Haiku calls, $0.020, no vent visited (no hold release needed).** Back on ClaudeDev at (94.16, 1849.61, -31.32).
    - **First Steps: 34.9 s, 0.36x, 0 misses.**
    - **Getting Started: done in the First Steps run's tail,** given at 32.0 s and complete at 35.4 s (one talk; the clone's bag held a Stone Club). 0 misses.
    - **Ratcatcher: 155.9 s, 0.9x, but 3 misses,** over the bar of 1. Two `attack Giant Rat` calls came back path_blocked ("there's no way through to the Giant Rat from here", 12.7 s and 3.0 s, on the windmill hill). One `go_to <rat id>` was unknown_target after the combat reflex had killed that rat ("paused 11 s while combat:reflex had my legs"). He then cooked the Rat Roast from the reflex kill's meat and handed it in.
    - Doric's post-quest dialogue was open again when Ratcatcher began: the first `talk Vannaka` read "Doric says: Gathering resources..." He left it and talked again, 2 extra calls, 2 s.
  - **Rune Mysteries: part 1 in 359.8 s, 1.57x** (human bar 229.5 s). The chop was 40 logs in 259 s (6.5 s per log, 106 swings, 57 hits, a `swing_no_effect` and an `unreachable stuck`).
  - **Then he stood again with part 2 open**, even with "Rune Mysteries goes on as a new quest of the same name: Mine Rune Essence...". His 4th turn only said "Rune Mysteries done, Zanik gave me a stone pickaxe. Next is mining rune essence from the geysers for air and astral runes.", and the request ended "done" (31.9 s then 40.1 s idle to the quiet end).
  - **The wording is now led by the fact:** when a quest is completed and its namesake given in one call, the result reads "One part of Rune Mysteries is complete, but Rune Mysteries is not over. It goes on as a new quest of the same name, now given: <step>". No "Quest X is complete" sentence is shown for it (test_talk 63/63).
  - **The two windmill-hill `attack Giant Rat` path_blocked results (ClaudeQ4 Ratcatcher, run 20261101-200805, started 20:08:05Z; logs/brain-live-20261101-210800-10992.jsonl). Handed to movement; not fixed here.**
    - Attack 1 at 45.1 s, target BP_AI_GiantRat_Character_C_2147465669. He stood at (150.86, 1789.62, -26.32); the rat was at (158.71, 1724.89, -3.21) (move.unreachable.leader_pos). The result at 57.8 s was path_blocked, why `no_route`: best_m 22.2, dist_m 21.8, chased_s 11.4, held_back_s {closing_in: 10.0}, target_moved_m 0.0, phase_log "0.0 react commanded", "0.4 equip", "0.8 approach". So the rat sat still while he got no closer than 22 m.
    - Attack 2 at 59.9 s, the same rat. He stood at (157.91, 1746.69, -8.58), the rat at (158.36, 1725.33, -3.26). The result at 62.9 s was path_blocked, why `no_route`: best_m 19.7, dist_m 19.4, chased_s 2.2, target_moved_m 0.2.
    - Then `go_to <rat id>` at 65.0 s from (157.6, 1744.81, -5.58). The combat reflex took his legs for 11 s and killed that rat. The walk ended at (152.78, 1729.81, -3.56), within 5 m of where the rat had stood, so the ground between was walkable. The go_to came back unknown_target target_not_visible at 90.9 s, and the reflex's combat_end "killed" for that id reached the brain at 91.4 s.
  - **A target that is gone because a fight killed it is now named in the result** (brain/broker.py `killed`, brain/agent.py `_killed_note`; tests/test_killed_target.py 3/3). On any unknown_target with a string target, the agent checks the episodic memory, plus events still queued (up to 1 s for a creature id or a detail that names combat), for a combat_end "killed" of that id, else of that name, within 120 s. It then puts this first in the detail: "That Giant Rat is dead: your combat reflex killed it 11 s ago." (or "A Giant Rat is dead: ... killed one ..."; "you killed" for a brain-commanded fight). The reason stays unknown_target: this informs, it does not veto. `attack` has the same gap (combat.lua answers unknown_target for a dead or missing id), and the same agent-level note covers it.
  - **quest_run now leaves an open dialogue the way a player does** (tools/quest_run.py `leave_dialogue`). Before each quest run, and after the brain is stopped at its end, it reads get_state.conversation; if one is open it sends talk `{target: <npc>, leave: true}` and checks again, up to 3 times. The run record holds `dialogue_left: {before, after}`. This ends the Doric dialogue carry-over seen in Q3 and Q4 (tests/test_quest_run.py 6/6).

## Rung 4 (gear and combat): staff and bow fights, the longbow profile, getting up for a fight, leather unlocks (2026-11-01 19:30-20:40Z; game build 26161880, client 26162923; dev world, ClaudeDev; rung4 agent; model-free probe logs/evals/rung4_probe.jsonl, gate tools/rung4_gate.py)
- **A staff fight works as built.** ClaudeDev has an Ash Battlestaff with Air Runes in MagicAmmo1 (Magic 1). `attack` with `weapon` set to the staff killed a spawned Goblin Runt (60 HP) at 20:20Z in 5.5 s: 3 casts, 3 hits, 3 Air Runes spent, 0 damage taken. The attack then waited about 9 s for loot ("loot target dead" at 5.5 s, "restore no loot" at 14.4 s) before it returned.
- **The Adventurer's Longbow was profiled as a melee weapon.** Its unaimed primary is a melee bash (damage_class Melee), so tools/gen_weapon_profiles.py gave it kind "melee", and combat clubbed with it. The fix: a weapon whose secondary is `aim` gets kind "ranged". client_mod/scripts/weapons_data.lua was regenerated, and only the 10 longbow rows changed.
- **Lying down blocks every fight input.** If the last lock holder left him resting (DIM_Resting, e.g. a nap and then a teleport), combat's Back/Cancel press is swallowed: 3 presses each with a bow and a staff at 19:56Z, then "stuck in DIM_Resting". The game ends a rest on a plain interact press (skills.lua's get-up path). combat.lua now presses interact in DIM_Resting; verified, the next probe's fights ran normally.
- **Wooden Arrows are prototype ammo and almost harmless.** The wiki says they are not in the game: an old spell prototype, with no recipe and no base damage. ClaudeDev's came from a dev grant. With the Ash Shortbow they took a kebbit (30 HP) down by about 3 HP per hit: 14 presses, 10 hits, 89 s (20:21Z). The real tier-1 arrow is the Stone Arrow: base damage 5-12 (Ash Shortbow 15), 33 per batch from 1 Stone + 2 Ash Logs + 1 Feathers at the Crafting Table. Its unlock is ALL ITEMS[Stone, Ash Logs, Feathers] AND ALL ACTORS[BP_Crafting_StartingBench_C]. Luis used Stone Bodkin arrows.
- **In that bow fight he dodged every kebbit bite instead of shooting.** The bite is learned at 14.4 damage, with a 3.43 s cadence and 1.32 s from telegraph to impact. step_ranged gives up the aim for a defence whenever an attacker's telegraph is within telegraph_m, and the aim restarts afterwards (ranged_aim_s 1.0 s when TimeBeforeFullAccuracy reads nil, then the reload_s default of 1.0 + 0.3 s). The result: 24 dodges, 34.7 s held back defending, and a shot every 6-7 s. The aim fit learned the Ash Shortbow with Wooden Arrows at 3293 cm/s and gz -119 (19 samples).
- **Bow data** (data/items_26161880.json ranged_collections): the shortbow collection has max_charge_up 0.75 s, the longbow 1.55 s, and the crossbow 0.75 s (allow_move_quick). Per the wiki, the shortbow's unaimed primary is its "Quick Action" and needs Ranged 3; ClaudeDev is Ranged 1.
- **Leather is "not unlocked" until a Tannery is used, so crafting.assess now counts unlock-on-use.** RECIPE_Process_Leather_From_Hide needs ALL ITEMS[Animal Hide] AND ALL ACTORS[Tannery]. ActorsInteractedWith grows when he uses the station, so a brand-new tannery read "used a Tannery: not yet" and the recipe read not_unlocked. Now `M.unlocks_on_use` treats a recipe as makeable when every unlock term is met except ACTORS terms naming a station type in the recipe's stations that is near him; the assessment says `unlock_on_use`. Offline: test_crafting 165/165. **Live: not verified yet.**
- **The gate counts the loadout's ammo.** The compact `inventory` reply keeps only the names of Ammo / MagicAmmo stacks, so a shot or cast spent from there was invisible to a bag-count check. rung4_gate reads `inventory {raw: true}` and counts those stacks by name.
  - **ClaudeQ5 window, 21:41-21:51Z local (20:41-20:51Z), 582 s, 15 Haiku calls, about $0.012.** Back on ClaudeDev at (167.19, 1927.0, -30.74) with his pawn in the world before the lock went. No dialogue was open before or after any run (`dialogue_left` empty).
    - **First Steps: 39.4 s, 0.48x (bar 82.0 s), 0 misses, no stand.** Honest: it has no hand-in.
    - **Getting Started: 7.4 s, NOT COUNTED.** One talk to Doric, because the clone's bag already held 2 Stone Clubs inherited from ClaudeDev.
    - **Ratcatcher: 7.5 s, NOT COUNTED.** One talk to Vannaka completed it: the bag held 4 Rat Roasts (and 2 Raw Rat Meat) from ClaudeDev.
    - **Rune Mysteries part 1: 247.2 s, 1.15x, NOT COUNTED.** He started with 16 Ash Logs and gathered the other 34 (35 in 167.8 s, 4.8 s per log). Then he stood 41.1 s with part 2 given, as in Q1 and Q4.
  - **Carried deliverables were the cause of the GS and RC "passes" since Q2.** Only ClaudeQ1 crafted its Stone Club; Q2-Q5 inherited one. The clones copy ClaudeDev's bag, and his bag holds what other agents' runs left in it. Main corrected the goal row (9cae089): Getting Started has 1 honest pass (Q1), Ratcatcher 2 (Q1, Q2).
  - **Fix, tools/quest_clone.py + data/quest_deliverables.json:** a clone's bag loses the cleared quests' deliverables: Stone Club, Rat Roast, Raw Rat Meat, Ash Logs, Rune Essence, Air and Astral Runes. Tools, weapons, gear and other runes stay.
    - **The save's GameProgress.Inventory slot keys are the InventoryComponent ItemSlots index** (get_state's `raw`). Joining the Q5 kept copy against his first live bag read gives the item persistence ids; the counts agree in every slot.
    - The slots are cut out as text, because the game's floats do not survive a Python re-dump (6.3928642787232998e+17 comes back 6.3928642787233e+17). A dry run on the Q5 copy removes slots 5, 8, 9, 29, 32, 38, 40 and 42, and the result parses back to the expected save.
  - **Fix, tools/quest_run.py:** each run records `carried_at_start` (that quest's deliverables in get_state.inventory at its start) and, when any is held, `not_counted: "deliverable carried: ..."`, printed as NOT COUNTED in the run's output and in `report`.
  - **The vent-hold guard is gone** (client_mod/commands/quest_hold_release.lua deleted, its call removed), now that 16653dc lets go of holds in the body. A run records `holds` only from the body's own results: a reason `rooted`, or a detail saying it let go of a hold.
  - **Why he stood after Rune Mysteries part 2 was given (Q1, Q4, Q5):** the model's turn after the talk only said "next up is mining rune essence from the floating rocks". The controller skips its talk-only check after a turn whose actions worked ("a talk-only reply is the report"), so the request ended "done".
    - **Fix, brain/controller.py:** the check is not skipped when a result in that turn gave him a quest step (`gave_quest_work`: quests_changed has a quest now "given"). It is read from the result data only, never the line's words. The model gets TALK_ONLY_NOTE once and decides (tests/test_talk_only_followup.py 13/13).
- **Runes stay on him through a death.** Live 20:59Z (fixture set_health 0, respawn at the church): after the respawn his inventory held exactly his 7 rune stacks, 8537 items (Water 660, Air 153, Law 1585, Astral 1939, Earth 1695, Nature 2040, Fire 465). The other 209 items, gear, food and resources, went into the grave.
  - So a grave-recovery check must count what went INTO the grave (carried at death minus what was kept), not the whole bag.
- **`store` into his own built crate works** with `inventory.owned_inventory`. Live 20:58Z: Stone Club and Bronze Shield went into BP_BaseBuilding_Crate_C_2147480439, bag 4 -> 6 free. The crate's id renumbered after a reload, so his crates are matched by position from my_pieces.json.

  - **ClaudeQ6 did not load: the server refused it 3 times with `Connection Failed for reason [CharCantLoad]`** (logs/client/boot.log, 21:18:26Z, 21:19:07Z and 21:21:00Z, after a relaunch). The window went back to ClaudeDev, in the world at (111.72, 1901.55, -29.63) with his pawn, before the lock was released (262 s, 0 model calls).
    - **Most likely cause: a dangling loadout reference.** The save's GameProgress.Loadout slots either hold an item themselves, or point at a bag slot by index: `"6": {"PlayerInventoryItemIndex": 40}` (his Air Runes), and `"7"`/`"8"` -> 4. Stripping bag slot 40 left loadout slot 6 pointing at nothing. Those are the only three such references in the save (no item GUID is referenced elsewhere).
    - **Fix (offline, tools/quest_clone.py):** a loadout entry whose PlayerInventoryItemIndex is a stripped slot is cut out with it, as the empty loadout slots 3-5 already are. A dry run on ClaudeDev's current save removes bag slots 5, 8, 40 and 42 and loadout slot 6, leaves no dangling reference, and parses back to the expected save. Not yet proven live: the next clone confirms it.
    - ClaudeQ6.json stays in SaveCharacters as the refused evidence (its kept copy is logs/quests/clones/ClaudeQ6.json).
- **Rung 4 gate runs 1 and 2 (21:00Z and 21:33Z; r1-20261101T203737Z and r1-20261101T211446Z; logs/evals/rung4_gate.jsonl).**
  - **Bow, run 1: nothing made.** "bow" resolved to 41 ambiguous names (crossbows and vestiges first). The Ash Shortbow he could make never showed; he tried the locked Adventurer's Longbow (a vestige recipe) and gave up.
    - Fix: crafting.lua `item_resolution_failure(..., ctx)` ranks the candidates by their best recipe's status, adds each one's `status`, and names the makeable ones in the detail ("I can make now: Ash Shortbow").
    - Run 2: he made an Ash Shortbow and 33 Stone Arrows (craft x2, equip) in 24 s.
  - **The bow kill on the kebbit (30 HP), 21:37Z: 68 s from the attack to the kill.**
    - 11 shots, 8 hits, about 4 HP per hit at Ranged 1 with Stone Arrows.
    - 17 dodges (all avoided, 0 damage taken); 23.6 s held back defending, one dodge per bite (its cadence about 3.2 s).
    - At most one shot per bite cycle: the dodge, then re-aiming 1.0 s plus the reload.
    - Arrows read as -22 because the loadout's Ammo slot references the bag stack: the gate now counts that stack once.
  - **Spells, both runs: he fought with his axe or pickaxe, not the staff.**
    - Run 1: "no proper attack spells at Magic 1". Run 2 still said "no damage spells ready, my magic is too low". This was after the situation began to read "Ash Battlestaff (...; casts magic attack spells, paid with the runes in your magic ammo slot)" and "Air Rune (magic ammo: a staff or wand casts with it)".
    - The model reads "attack spells" as spellbook entries; at Magic 1 his spells are utility ones.
    - Run 2's melee attack also timed out: 102.9 s held back "out_of_reach" from a runt 2 m away, then the reflex took over (not a rung 4 cause; handed on).

## Death to a Giant Rat in front of Luis: the PL-gap flee and the handed-back legs (2026-11-01 21:50-21:51Z; game build 26161880; dev world, ClaudeDev; Luis on as Zezima; rung4 agent; logs/brain-live-20261101-224952-3652.jsonl, logs/client/client.log 75454-75532)
- **The decision.** combat_started reflex: hp 100, target Giant Rat pl=2, target_hp 130, decision flee, because "too_strong". His own power level reads 0 (BP_GetPowerLevel; situation "PL 0", T1 Adventurer's gear), so the gap was 2 = `pl_gap_flee`. M.assess vetoed on the gap before its own numbers: est_s_to_kill 17, est_s_to_die 40, a win. The weapon was the Stone Logging Axe (score 4.7), his best melee; he carries no melee weapon (Stone Pickaxe, Ash Battlestaff).
- **The flee.** 15 s and 19 m, with the flee holding his legs (the arbiter suspended go_to). 21:50:39-47: the flee leg was stuck (moved 38/44/13 cm, local plans, bug2 wall-following). The rat bit him from 100 to 40 HP; he ate a Fillet at 40. step_flee never defends: telegraphs are answered only in approach/engage/disengage.
- **The hand-back.** At the 15 s limit the rat was more than `cornered_m` (8 m) away, so the flee ended "unsafe" (still_chased) and released his legs. The suspended go_to resumed and walked him 7 s on to Zezima with the rat following. The guard skips a creature he fled from (refled_s 30) until it attacks again; at 21:50:59 it did ("cornered: it came after me again 7 s after I ran from it"). He died 5 s into that fight at 60 HP: 1 press, a dodge that whiffed, a reactive Windstep too late.
- **Fix** (combat.lua; test_combat 444/444):
  - a PL gap is "too_strong" only when the win estimate is below fight_enter (gap >= 2) or the gap is >= `pl_gap_hard` 4;
  - a flee in which threats take >= `flee_caught_frac` 0.2 of max HP turns into a fight;
  - at the flee's time limit or leash, any threat still chasing within safe_m turns it into a fight, not an "unsafe" hand-back.
  - **Live: not verified yet** (rung1 gate fight_back, after Luis's session).

## World-edge deaths, kept items, under-water goals (2026-11-01 22:00-22:35Z; game build 26161880, client 26162923; dev world; movement agent)
- **What stays on him through a death: `UItemData.bDropOnDeath`** (Dominion.hpp, `UItemData` +0x17C). A live read-only probe (`FindAllOf("ItemData")`, 2139 definitions) found 262 with `bDropOnDeath == false`: every `ITEM_Rune_*` (`MagicAmmoData`), every arrow and bolt (`RangedAmmoData`), all capes and postbox items. `ITEM_Club_Stone` (`HeldEquipmentData`) and `ITEM_Resources_Wood_Ash` (`FuelItemData`) are true (they drop).
  - **Luis, 2026-11-01:** "you keep ammo, runes and any armour you're wearing; you lose weapons and everything in your inventory and hotbar." That matches the flag. Worn armour is in the loadout, not the bag/hotbar the death memory reads.
  - skills.lua `keep_on_death()` reads the flag once per client run. `record_death` files kept items as `kept_by_rule`, not `lost`. After the respawn, `death_reconcile` diffs the real bag/hotbar and logs any disagreement with the flag ("death: what I lost at ... disagrees with the item flags").
  - A death with nothing droppable on him is closed `nothing_lost` and never listed (22:10:01 and 22:11:04Z: runes and ammo only).
- **World-edge kill (Temple Woods lip, about (38-45, 1744-1747), z -30):** 5 deaths (15:56, 16:01, 16:37, 22:10, 22:11Z), `killed_by Default__KillZVolume`.
  - The body ends 41-63 m below. Luis: "an edge where you can walk off the world; past it is the map's kill volume."
  - Read-only probe `killz_read.lua`: the persistent level's `DominionWorldSettings.KillZ` is -100000 cm (the generated sub-levels -1048575), and the client has **no `KillZVolume` actors**. The kill happens far above that KillZ, so it is server-side or streamed; the client has no geometry to test against.
  - Game graves for these deaths sit on the lip itself, at (45.02, 1744.93, -30.64), so interact's approach walks onto the lip.
  - **Mechanism, 22:10/22:11Z:** interact's short go_to used a 2-point remembered route. The look-ahead drop guard fired once, late (22:09:58), or not at all (22:11:01). He stopped 0.5-2 m short of the grave on the slope, slid off, and was dead about 2-3 s later.
  - **Rule now:** a fatal fall (KillZVolume, or the body ≥ 8 m below its last ground) marks its last-ground spot as a **hazard** in nav memory (navmem `mark_hazard`, merged within 3 m, n = deaths). `move.cliff_guard` never steps toward a hazard closer than `hazard_standoff_cm` (2 m), whatever routes the walk; go_to then fails `why = known_drop` with "a drop that killed me N time(s)". The grave entry gets `danger`.
- **The fall correction must be a fall:** `record_death` moved a death to `DW_LAST_GROUND` when the body was lower. At 21:00Z a fixture teleport 145 m away read as a fall, the death was filed at the church doorway, and its grave was at (249.9, 1790.8). The ground spot must now be within 30 m sideways.
- **A goal under water:** go_to to a pond bed (22:12:07Z) put him 1 cm from it on the surface, 3 m above it. That is not "arrived" (vertical tolerance 1.76 m), so he spent 21 s circling, with bug2 wall-following in the water. Now swimming or wading over it within tolerance is arrived (`in_water`, `below_m`), and bug2 never starts in water.
- **Trap exits from failed walks:** bug2 excursions out of t7 and back (21:51-21:53Z, both walks no_route) overwrote its exit twice. A learn on a walk that fails within 20 m of its start is now taken back (`trap_undo_cm`). Live 22:09:49Z: t227 was forgotten after its second clean walk ("not a trap any more").

  - **ClaudeQ7 loaded (the first stripped clone): the loadout fix works live.** The window ran 22:25-22:39Z, 812.5 s, 24 Haiku calls, about $0.021. Bag stripped: 2 Rat Roasts, 15 Ash Logs, 1 Stone Club, 23 Rune Essence, 123 Air Runes, 1939 Astral Runes. Loadout 6 and 7 were cut with them, and the load check found nothing dangling. Back on ClaudeDev at (49.13, 1890.59, -35.13) with his pawn before the lock went.
    - **First Steps: 30.4 s, 0.38x (bar 80.4 s), 0 misses.** Counts.
    - **Getting Started: 66.2 s, 1.0x (bar 66.5 s), 0 misses, no stand, nothing carried.** The first honest pass since Q1. He talked to Doric, gathered 5 ash in 28 s, crafted a Stone Club at the standing Crafting Table, walked back and handed it in. His line "Getting Started's finished. next he sent me to Vannaka by the windmill" matches the recording.
    - **Ratcatcher: FAIL, deadline at 481.1 s (bar 173.0 s), nothing carried.**
      - `go_to "the windmill"` at 35.7 s came back unknown_target ("not in sight, and no player of that name"); the quest-marker match did not catch it. He then walked to [156.1, 1713.4, -3.5].
      - `attack Giant Rat` 84.2-180.1 s killed the rat (95.6 s; healed twice, with Vegetable Soup and a Fillet).
      - `craft Rat Roast` at the Campfire, from 182.8 s: at night another Giant Rat attacked. The combat reflex judged "likely_lose", fought anyway, and dealt 0 damage in 22.7 s (out_of_reach 8.6 s, defending 6.5 s; it took 21 damage). He died, and the craft returned companion_down "character is dead".
      - His line was true ("got jumped by a pack of giant rats at night and died. gear's in my grave, heading back for it"), and the grave walk ran to the deadline. Rune Mysteries was not reached.

## Combat in Luis's session, 2026-11-01 22:00-22:40Z (build 26161880; rung 1/4 agent)

- **Player summons are not marked on the client.** Example: Luis's "Buddy" (BP_AI_KalphiteFriend_Character_C, summoned from DA_Kalphite_Friend by the Pharaoh's Sceptre) reads `IsFollower()` false and `IsConfused` false, and the player's `.Follower` is invalid. No replicated ownership was found.
  - What does name a summon: the loaded `FollowerDataAsset`s list the summonable classes in `FollowerClass:GetObjectID():GetAssetPathName()`. `sense.is_summon(a)` checks the actor's class against that set (cached 10 s).
  - Effect: summons are out of the threat pick, the fight assessment and the flee threats, and `attack(<summon>)` returns unsafe "a player's follower".
  - Before this fix he fled from Buddy (PL 7) at 22:03:24 and retargeted onto it at 22:05:50.
- **Kill and hit attribution.** The HP-poll fallback used to count any HP drop on his target as his hit: "hits=7" with 0 presses while Buddy and Luis did the damage. It now counts a drop only within 1.2 s of his melee press, or 2.5 s of a shot.
  - The fatal-hit multicast (`bIsFatalHit`, instigator) records who killed what: "me", the player's name, or the creature's AIName.
  - A kill counts only when it is his; otherwise `target_killed_by` is reported.
  - `unknown_target` now reads "already dead: killed by X N s ago; I hit it k time(s) / I never hit it".
- **Staff casts are not projectile actors on the client.** Since 2026-10-26, every Ash Battlestaff cast logged "no projectile seen": no new DominionProjectile or DominionSpellProjectile appeared. This held even in a 3-cast / 3-hit runt kill.
  - After 6 unseen casts, the fight used to end "body_error shots_not_firing" while the staff was firing and missing. Luis saw it fire.
  - The "projectiles" the aimer did track on 22:07 were someone else's (Luis's sceptre, Buddy's spit), 10 m off, and they taught a wrong speed (2078 vs 4000).
  - Fixes:
    - only a projectile whose instigator or owner is his pawn or controller is his;
    - a magic cast's outcome is the target's HP within 1.6 s;
    - each cast logs distance, target speed and facing;
    - a run of misses ends with reason `missed`; `body_error casts_not_firing` is reported only when no runes were spent.
  - Hit rate on cows at 23-28 m (wandering): 1 of 17 casts confirmed, for 52 damage.
- **Player power level = mean PL of worn head, body and legs armour, rounded down** (wiki "Power level"). It matches the live reading: PL 0 in T1 body and legs (PL 1 each) with no helmet. Weapons and shields do not count.
  - Brynmoor creatures are PL 1-2 (cow, rat and goblin warrior are PL 2), so a full T2 armour set brings him to PL 2 and closes the gap that made the reflex call them too_strong.
- **Recipe auto-unlocks are item queries** in recipes data `unlock.bundles[].query`. Examples:
  - Reinforced, Leather Shield and Bone Club: "ALL ITEMS[ Leather, Animal Bone ]";
  - Leather armour: "ALL ITEMS[ Leather, Coarse Thread ]";
  - Leather: "ALL ITEMS[ Animal Hide ] AND ALL ACTORS[ BP_Station_Tanner_C ]".
  - So holding the inputs unlocks the next tier. `brain/gear_plan.py` reads this.
- **Creature damage-type affinities:** `UAIAttributesComponent.DamageTypeAffinities` (TMap<GameplayTag, EDamageTypeAffinity>) is the authoritative map. It is empty on the client (server-only).
  - `UAIDataAsset` has no affinity field; its `AIDataTableRowHandle` row (FAIDataTableRow) holds only MaxHealth.
  - The client sources remain, in order: his own hit outcomes (`TypeDamagesOutcome` on his damage multicasts), the in-game journal Weaknesses, then the wiki snapshot (creature_wiki.lua). They are now attached to every creature's fight_odds row (`known`), not only to hard fights.
- **Held-weapon enchant expiry is readable.** `AHeldEquipmentActor.MagicalHeldEquipmentEffectInfo` = {EffectData (HEED_EnchantWeapon<Element>), ServerExpirationTime}. Compared with `GameStateBase:GetServerWorldTimeSeconds()`, it gives the seconds left. get_state `held_enchant` = {effect, adds = DamageType.Magical.<Element>, left_s}.
- **Deaths in the session.**
  - Cow (PL 2), 22:08: fled from an adjacent cow mid-swing and took 36 in 0.4 s. Then a "none, out_of_reach" defence let a 36 hit through while the cow came back in. Tempest Shield was cast only at 28 HP, and he died with the cow at 2.5/156 HP.
  - Goblin Warrior, 22:24: a 25 m flee in which it kept up and hit him, then 9 dodges and 1 press, killed by a 44 hit.
  - Fixes (combat/defense):
    - no flee from a threat that is within its reach and at least as fast as his sprint (or has caught him before);
    - eat in the gap right after a defended swing when below heal_hp;
    - Tempest Shield before engaging a fight that is not a likely win, once per fight;
    - the out-of-reach check adds the attacker's closing speed x impact time.
  - Live at 22:32:18 (ClaudeQ7, Giant Rat): "no flee: it is on me (1 m) and I can't outrun it (6.0 vs my 5.8 m/s)", then "cast tempest_shield (before engaging: likely_lose)".

## Luis's co-play session scored (2026-11-01 21:49-22:23Z; game build 26161880; dev world, ClaudeDev and Zezima; rung1 gate agent; logs/brain-live-20261101-224952-3652.jsonl, logs/recorder/rec_20261101T132138Z.jsonl)

- **Unnamed lines waited for the running tool.** chat_heard delay (brain log ts minus the line's ts) over his 52 lines: median 1.5 s, p90 42 s, max 162 s. Every late one had mentions_me=false and arrived when a go_to/attack/collect ended. The chat decision (`LiveAgent._with`: his conversation partner, or the only player around) already treated them as addressed, but `LiveAgent._addressed_line` (the bridge's `interrupt_check`, which detaches a wait) only knew named or prefixed lines. It now uses `_with` too.
- **An offer and its action in one reply.** "do you have any logs?" -> say "want them?" + give 25 in the same reply; the second give 25 on "claude" re-attached to the running one (one drop of 25 at 22:20:36.9). Nothing in the persona said an offer waits for his answer. Replay of the logged prompt (Haiku): 0/3 without the new persona line, 3/3 with it.
- **A reflex use beside a model consume.** The stay-fed reflex drank the last Clean Water at 22:16:25.9; the model's consume at 22:16:27.7 failed not_in_inventory ("I don't have any Clean Water on me"), and the reflex_use event reached the next prompt at 22:16:28.3, so "drank the water" was true. The consume failure detail does not mention the reflex's use (client_mod/scripts/skills.lua consume, not-carried branch).
- **Kill loot reaches the model as one pile name.** The cow's combat_end said loot "Animal Hide x1" (`F.loot_names` is the picked world item's first stack); the recorder shows +3 Raw Farm Meat, +3 Animal Hide, +2 Animal Bone at 22:17:15.7. The attack result carries only `looted` (a count). By 22:18:51 that combat_end was out of recent_activity, and notes keep only the newest combat_end (the goblin's), so "what did the cow drop?" got the goblin pack.
- **go_to no_route says nothing about cliffs.** "the walkable map ends 26 m short of the goal, 0 m below it" (why=no_route); the model said "cliffs between us" and later "on the other side of a cliff".
- **give to an adjacent player: 6.3 s.** give 10 at 22:20:55.4 -> the drop at 22:21:01.7 (recorder), after a 5.2 m walk with face_off 125 deg; his line to the drop took 13.1 s (pickup of the 25 first).

  - **Quest markers (offline, 2026-11-01/02, Luis's question "can he resolve quest markers?").**
    - **The Q7 `go_to "the windmill"` miss was not the label or the article.** The name resolved to "Ratcatcher quest marker Windmill Area", but he stood at Vannaka inside its 80 m area, and that case returned unknown_target "you are in it now". The body's own name search had already spent 10 s first (movement's).
    - **Fix (brain/executor.py):** go_to a quest area he is already inside walks to the area's centre (the marker spot) and says so. Regions keep their old answer. tests/test_places.py covers "the windmill", "windmill" and "Windmill Area".
    - **Marker labels (client_mod/scripts/quests.lua):** marker keys abbreviate the NPC ("WOM_Objective_FTUE_GS" read just "Objective"). A capitals code is now spelled out from the initials of capitalised words in the quest's own step text ("Speak to the Wise Old Man" -> "Wise Old Man Objective"); the raw codes are not shown.
    - **Marker positions are accurate.** Marker vs where the NPC stood (look results, 30 brain logs): Zanik 0.1 m, Wise Old Man 0.6 m across the map (but the marker is 31 m above the ground: z -4.4 vs -35.5), Vannaka 1.6 m, Doric 1.9 m. The windmill-hill rats were about 12 m from the Windmill Area centre (80 m radius). There are two Essence Areas of 25 m each.
  - **Wiki use (Luis: "is he pulling wiki info on that quest?"): no, not once.** That night's quest brain logs hold 0 lookup calls.
    - The snapshot has walkthroughs for First Steps, Getting Started, Ratcatcher (+ Quick guide), Rune Mysteries (+ Quick guide) and Dragon Slayer. But lookup(quest) returned only the page lead and Overview: the rune altar and geyser steps never came back.
    - **brain/knowledge.py `walkthrough`:** a lookup that names a quest now also returns `data.walkthrough`, from the "/Quick guide" page when one exists, else the step sections between Overview and Rewards. Map templates are skipped, and it is capped at 1600 characters (tests/test_knowledge_quests.py). The lookup tool description now mentions quest walkthroughs.
    - **Offline eval (tools/quest_lookup_eval.py, 6 recorded "step just handed to him" prompts, Haiku, blind Haiku judge 0-2):**

      | Variant | Lookups | Judge mean (0-2) | Cost |
      |---|---|---|---|
      | live tools | 0/12 | – | – |
      | today's lookup wording | 0/12 | 1.04 (live + today, n=24) | $0.038 |
      | walkthrough attached to the talk result | 0/12 | 1.25 (n=12) | $0.018 |

      The wording alone does nothing. The walkthrough in context is within noise: two more direct talk/go_to answers, but the Rune Mysteries part 2 answers are still say-only, and Getting Started still crafts before gathering.
    - **Judged weakness, not wiki-shaped:** most answers right after a step is handed over are a say with no action (the live talk-only check now covers that turn shape).
- **After a stop at speed his position can jump forward (kin trace, 10 Hz in the game thread: Velocity, `CharacterMovement:GetCurrentAcceleration()`, mode; scratchpad `drift_test.py`, 22:55-23:01Z, flat ground by the church door):**
  - A plain `stop` at 6.6 m/s: the next sample, 0.12 s later, was **2.66 m further on**, with v down to 0.6 m/s and acceleration 0. That is no braking (BrakingDecelerationWalking 2048, GroundFriction 8, BrakingFrictionFactor 2; read-only probe). It looks like a position correction in the direction of travel.
  - A guard stop at 6.8 m/s 2 min later: no jump.
  - At the 22:46Z lip death he moved 3.8 m in about 1.5 s after the stop, with nothing of ours driving him: the bridge log has only `me` and `stop` commands, and no move or skill was active.
  - Acceleration was 0 after both stops, so it is not our input left held.
  - Smaller AddMovementInput scales do NOT slow him: at 0.3 input he held 6.8 m/s, because UE keeps a speed above the analog max. So near a known hazard move.lua now lets go of the input until he is under 2.5 m/s, then walks at 0.3 input, with no sprint. At a walk, guard stops drifted only 0.1-0.3 m (22:43Z, six stops).

## Farming data profile, the game clock, and Claude's first farm plot (2026-11-01 23:02-23:10Z; game build 26161880; dev world, ClaudeDev; farming agent; probes client_mod/commands/farm_data_probe.lua, farm_plot_probe.lua, farm_time_probe.lua; logs/farm/*-20261101T23*)
- **The game's own farming data, read live from the loaded native assets** (read-only probe; profile `data/farming_26161880.json` by `tools/build_farming.py`; served by `lookup` as the "Farming mechanics" and "Compost" cards, and each crop's growing facts on its seed's item card):
  - 25 `FarmPlantDataAsset`s, 24 seeds (`SeedHeldEquipmentData.FarmPlantData`). Every crop: 3 stages x 1 `CyclesToGrow` (3 x 3 in a plot tier it doesn't prefer), base yield 5 (Flax 3), `PlantableIn` tags `Farming.Tiers.Tier1_Brynmoor` ... `Tier4_UmbralSands`. Tier-1 crops: Cabbage, Flax, Potato, Wheat, Redberries (berry bush), Harralander, Marrentill, Kwuarm. Weeds: 3 stages x 2 cycles.
  - `Default__FarmingSettings`: CyclePeriod 720, WaterNeededForWatering 50, CompostNeededForFertilizing 50, DiggingChargesNeededForTilling 5, WeedsCycles 1, DiseaseCycles 0.2, PlantingGracePeriodHours 2, GrowthTimes [4.5], UnlockingRecipe RECIPE_Tool_T1_Spade_Wood, ShovelCategory Item.Equipment.Tool.Shovel, CompostItemCategory Item.Equipment.Tool.Bucket.Compost.
  - `FarmCompostData`: Regular yield x1.5 / disease x0.5, Super x1.75 / x0.25, Ultra x2.5 / x0.125. `FarmWaterData`: Dirty and Clean water yield x1.15, disease x0.3 / x0.2; no water x0.8 disease.
  - **Compost tiers are item tags**: `Item.Farming.Compostable` (148 items: weeds, wheat, flax, bones, feathers, raw meat and fish ...), `CompostableSuper` (49: corpse cotton, hollow bark, undead bone, maple sap ...), `CompostableUltra` (29: desert weed, cactus, monkfish, beltfish ...). `ItemData.CompostAmount` is 1 on 1301 items (a default) and 10 on 244.
  - One composter loaded: `BP_Station_Composter_New_C_2147480285` at (81.7, 1847.2), accepts Item.Farming.Compostable, makes CC_Compost_Regular, rate 5, capacity 1000. It sits by Luis's plots: treat it as his.
- **The game clock** (`BP_InGameTimeActor_C`): `RealTimeMinutesPerInGameDay` 24, `TimeOfDawn` 4.5, `TimeOfDusk` 22.0, not paused; `UInGameTimeFunctionLibrary::ConvertRealTimeSecondsToInGameTime(720)` = 12.0 in-game hours, so **one growth cycle = 12 in-game hours** and a crop's 3 cycles are 36 real minutes (1.5 in-game days) on a normal clock. The night (22:00-04:30) is 6.5 real minutes.
  - Each plot's next growth update is an in-game `FTimespan` (`FFarmPlotServerOnlyState.NextUpdateTime`; UHT dump), which is why a sleep (the clock fast-forwards: DISCOVERIES "Sleep in his own Summon Shelter", 3x vitals drain) should advance crops. Luis's tip (2026-11-01): "crops grow fast when he sleeps the night". Live check: see below.
  - `FFarmPlotVisibleState` (GrowthStage, WateringProgress, TillingProgress ...) is not reachable from Lua. **A growth-stage proxy that is:** the slot's `PlantMeshComponent:GetStaticMesh()` (e.g. `SM_Potato_Plant_01`, `SM_BM_Weeds_01`) and its `GetInstanceCount()`.
- **Plot reads** (`farm_plot_probe`): Luis's 6 plots are `BP_FarmPlot1x1_T1_C` (tier `Farming.Tiers.Tier1_Brynmoor`, PlotName "Ash Farming Plot"); `GetInteractionPrompt(pawn)` gives "Harvest" on a ripe plot. `PlotStatusDisplayText` is the template "{Name} {Stage} - {Status}\n{ItemNeeded}" (useless as a read), and the information widget (`WBP_FarmPlot_InformationWidget_C`) has no text on the headless client.
- **Recipes:** Wooden Spade (6 Ash Logs + 1 Coarse Thread) and Wooden Watering Can (4 Ash Logs + 1 Coarse Thread) are already unlocked on ClaudeDev (Crafting Table). Coarse Thread is spun at a Spinning Wheel from Coarse Animal Fur (kebbits). ClaudeDev carried no Ash Logs or thread at 23:02Z.
- **The Ash Farming Plot is already buildable on ClaudeDev** (no Growing Pains needed for it): the brain built his own at (177.2, 1912.3, -31.2), `BP_FarmPlot1x1_T1_C_2147454043`, plot id 133, 8 Ash Logs, +8 Construction XP (the first spot's preview was red; the second, `at` a spot 6 m away, held). A new plot starts with a weed layer (soil 0, mesh SM_BM_Weeds_01).
- Wiki sources for the farming rules players use: https://dragonwilds.runescape.wiki/w/Farming , /w/Growing_Pains , /w/Compost_Bin , /w/Super_Compost_Bin , /w/Ultra_Compost_Bin .
- **Growth stage IS readable (live 2026-11-02 00:0xZ):** each `UFarmPlantStageData` has `Healthy/Diseased/Dead.Mesh` (`FFarmPlantStageVisData`), so the plot's plant mesh names the plant and stage. `farm_plots` now returns `growth = {plant, stage, of}` (Luis's 6: Potato, Flax x2, Cabbage x2, Redberries, all stage 3 of 3; his own plot: Weeds 3 of 3) and `mine` (true for his plot, false for Luis's 6; from deconstruct's ledger of pieces he built, matched within 1.5 m).
  - Ripe meshes are the plain names (`SM_Potato_Plant_01` is stage 3; stages 1-2 are `..._01v2`, `..._01v3`). Healthy and diseased stages mostly share a mesh, so disease comes from `CanHealDisease`, not the mesh.
  - Gotcha: on the plot's `InstancedStaticMeshComponent`, `GetStaticMesh()` returned an invalid wrapper (`IsValid` false); the `StaticMesh` property read is valid. And `U.find_all` (alive filter) returns no data assets: use `valid_only`.
- **Weeds on a new plot grow on the normal clock:** his plot (built 23:04:53Z) read `SM_BM_Weeds_01` at 23:09Z and `SM_BM_Weeds_03` (fully grown, 3 of 3) by 23:55Z, with no sleep. That is about 4 cycles (48 real min), which matches Weeds' 3 stages x 2 cycles.
- **Game clock, sampled every ~24 s (23:55-00:07Z):** exactly 1 in-game hour per real minute. `IsInTimeframeForSleep` opened at in-game ~21:4x, before `IsNighttime` (dusk 22:00).
- **Luis's sleep tip: NOT yet measured on a crop.** In the window no plot had growth left to show (Luis's ripe, his weeds at max), and Summon Shelter would not place anywhere near his base. Three tries, 00:07-00:09Z: "ground not flat enough" by the house, "blocked" on his own foundation and at both suggested flat spots 15-30 m away. To measure it: plant a crop, read `growth.stage`, sleep the night, then read it again.

## Perks, water and wedging (2026-11-02 00:00-01:20Z, game build 26161880, client 26162923)
- **Claude's movement perks, read live** (`pc.SkillPerkComponent:IsPerkUnlocked(...)`):
  - Unlocked: `PerkV2_Agility_DoubleJump` (Agility 10; pawn field `DoubleJumpSkillPerk`) and `PerkV2_Agility_AirDash` (Agility 32; `DominionMovementComponent.DashPerkData`).
  - Locked: `PerkV2_Agility_Breakfall` (Agility 35; `BreakfallPerkData`).
  - All 30 unlocked of 202 loaded `SkillPerkData` definitions: MeleeExtendCombo, Parry, MeleeSpecialAttacks, SprintAttack, EnchantWeapon_Fire, TempestShield, OverheadChop, BirdNest, WoodcuttingCriticalHitChance, AxtralProjection, FancyCookware, ChanceToBurn T1, AstralRunes, AirRunes, Windstep, AirMagic, BarkToBones, FineDetails/MiddleGround/SacredGeometry (Ash), EyeOfOculus, Fishing Whirlwind, FishingRods, CourseUnlock Brynmoor/Fellhollow/Ghornfell, Hopper, KebbitBurrows_Common.
- **Air dash numbers** (CMC): `DashDistance` 600 cm, `DashStaminaCost` 15, `DashCooldownDuration` 1 s, `MaxFallDistanceForDash` 1500 cm, `MaxPhaseDashesMidAir` 1, `MaxFallDistanceForDoubleJump` 1500 cm, `JumpMaxCount` 2. So Luis's water crossing (jump, double jump, air dash) is available to Claude. Not built yet.
- **`SkillPerkComponent.SkillPerkRuntimeStates` is empty on a client** (0 states: server-side state). `sense.perks` read only that, so `get_state` said `perks: []`. `IsPerkUnlocked` does answer on the client (12 ms for all 202 definitions). `sense.perks` now falls back to it.
- **Swimming:** `CharacterMovement.MaxSwimSpeed` = 300 cm/s (`MaxWalkSpeed` 450, sprint ~680 observed), `Buoyancy` 1.0, `JumpOutOfWaterPitch` 11.25, `OutofWaterZ` 420.
- **No UE Water plugin bodies and no water nav area.**
  - `FindAllOf` WaterBody/WaterBodyLake/River/Ocean/Custom/WaterBodyComponent/WaterZone = 0. The dump has no `NavArea` for water (only Default/LowHeight/Null/Obstacle and BP_NavArea_Foliage).
  - Water is overlap-detected by `UEnvironmentComponent.WaterCollisionChannel`.
  - So the navmesh oracle cannot avoid water. The client's own water map (navmem 2 m cells plus water-channel looks) is the only source.
- **The Doric pond, mapped from traces** (camera channel 1 surface above the `Player` profile floor): X ~123-151+, Y 1884-1930 (it runs on NE). Bed -33 m, surface ~-31 m, banks -31 m.
  - Remembered water cells there also include a false strip at X 114-122 (dry ground).
- **The doric_pond follow crawl was not water.** At t 15.5 s Claude pushed at 1 m/s into the face of a 1.8-2.4 m ledge Luis had hopped onto. The hop rule had "run on" toward Luis because the landing was above step height. Now a jump that lands above our step is always copied.
- **Wedged among placed pieces** (near_doric leg, 23:42Z, start [88.77,1852.10]): every input moved 0 cm and no jump left the ground.
  - Placed pieces' bounds (`GetActorBounds`) at that spot: Luis's Spinning Wheel `..._2147480387` at (89.39,1853.33) ±(0.58,1.01) overlapping his capsule, his Starting Bench at (89.60,1850.09) ±(0.59,1.14), and farm plots `BP_FarmPlot1x1_T1_C` at (87.21,1853.14) and (87.21,1850.14) ±(1.73,1.68).
  - The wedged reason now names the pieces from bounds, and he tries one walk-out away from them first.
- **Unnamed-line interrupt, live (2026-11-01 23:14-23:17Z):** with `_addressed_line` using `_with`, three lines without "claude" from the chat partner during a 223 m go_to were heard in 1.3-1.9 s and each detached the wait (still_running); the body kept walking and arrived.
- **go_to of a lodestone id:** the body's go_to answered unknown_target "not in sight" for "lodestone:5E74..." (an id from the lodestones tool); the brain executor now resolves it to that lodestone's position.
- **A pending situation change can be stale by minutes:** broker `_pending` held "health 100 -> 0" from a death at 23:35:47 until 23:39:48 (busy/fight gates), while he read 64-76 HP. Changes are now re-read against the current bands at delivery.
- **The chat ladder's near_doric start [88.77, 1852.10] is inside Luis's base** (his Spinning Wheel 89.39,1853.33; bench 89.6,1850.09; plots at x 87.2): the body was wedged in the wheel's collision (movement, live). get_state.structures plus census interactables give the nearest placed piece's distance for a clearance check.
- **The Doric pond is wading depth** (kin trace 00:24-00:27Z, 100 ms): normalized water depth 0.3-0.6, and `MovementMode` stayed 1 (walking, never 4 swimming).
  - Wading speed equalled dry speed there (270 cm/s), but he was encumbered (403/400: walk only), so the run-versus-wade cost is not measured yet.
  - Dry routing live: S (131,1878) -> N (127,1922) went round the pond's west side, 47 m on dry ground instead of 41 m with 28 m in water, with no water entry.

## Dev server crash 2026-11-02 (UE4SS Lua hook) (build 26161880, UE4SS v3.0.1 Beta SHA 83330635; crash 00:50:02Z; offline dump analysis, crash agent)
- **Not a hook param and not a bad UObject: two OS threads ran Lua on one lua_State.** The fault is in the game thread's `player_recorder` 200 ms loop. The async push came from nav_oracle's link-cube cleanup.
- **Exception:** c0000005 read of 0xffffffffffffffff at `UE4SS+0xc69ef8` (`test byte ptr [rax+8],0Fh`, rax=0x656d61472f656d61 = ASCII "ame/Game").
  - Dumps: `ue4ss/crash_2026_11_02_01_50_02.3134263.dmp` (has the exception record) and the full hang dump `logs/dumps/server_hang_20261102_0051.dmp`.
- **Native frames, mapped to UE4SS source at that SHA:** frame 0 is `lua_rawgeti(L,-2,1)` (lua_lock + index2value + luaH_getint, from the disassembly).
  - It is called from `transfer_stack_object` (LuaMadeSimple.hpp:648) inside `RemoteUnrealParam::construct` (LuaUObject.cpp:2316).
  - That is reached from `push_objectproperty` (case `Operation::GetParam`) and from `TArray:ForEach` (LuaTArray.cpp:121-150).
  - UE4SS's own TODO at that very push (LuaTArray.cpp:141-143) reads: "Fix crash that occurs here. It appears that the Lua stack is getting corrupted somehow". The "StartCallbackGarbageCollector / HookUStructLink / FCallbackOptions" frame names are wrong export symbols. That part is UE4SS's game-thread delayed-action runner, not a RegisterHook callback.
- **Lua stack**, walked from the full dump with the `minidump` PyPI reader and Lua 5.4 struct offsets (scripts in the crash agent's scratch: luawalk.py, luamem.py). The chain is `player_recorder.lua:230 pcall(step)` → `:136 counts_of` → `:110 inv_counts(pc.InventoryComponent)` → `:93 pcall` → `:94 inv.ItemSlots:ForEach(...)`, at element 162.
- **The smoking gun is on that lua_State's stack (`m_hook_lua`).** Slot 4 is the intact `RemoteUnrealParam` metatable, the same pointer as the registry entry, and slot 5 is the new userdata.
  - Above those sit two foreign values: a closure from `experiments/nav_oracle.lua:121` (`function() pcall(function() a:K2_DestroyActor() end) end`) and the integer 639. 639 is the registry free-list value that `luaL_ref` reads.
  - So `-2` was that closure, read as a Table. The "ame/Game" was the stale `gclist` field of the closure, not freed memory.
- **Mechanism (UE4SS bug, upstream issues #1345 and #1445, both open):**
  - `nav_oracle.rebuild_links_around` calls `ExecuteWithDelay(3000, function() ExecuteInGameThread(...) end)`. `ExecuteWithDelay` runs its callback on the mod's async thread (`LuaMod::update_async` → `async_lua()->call_function`).
  - `ExecuteInGameThread` then does `lua_xmove` + `luaL_ref` onto the shared `hook_lua` (LuaMod.cpp:4368-4374) under `m_thread_actions_mutex`.
  - Meanwhile the game thread runs `LoopInGameThreadWithDelay` callbacks on that same `hook_lua` **outside** that mutex (LuaMod.cpp:4016-4029). `lua_lock` is one process-wide critical section, so each API call is atomic but sequences interleave.
  - Maintainer narknon on #1345 (2026-07-17): "You shouldn't be using any of our async lua functions, they're inherently unsafe and it's recommended to use the executeingamethreadwithdelay type functions instead."
- **Timing:** mod log `nav_oracle_links_rebuild` at 00:49:59Z (a far go_to's corridor goal), plus 3000 ms, gives 00:50:02Z, the crash dump's timestamp.
  - Earlier rebuilds (00:48:42, 00:48:46, 00:49:55) got lucky. The armed recorder's 5 Hz ForEach over every player's inventory kept the game thread inside Lua most of the time, which made the window wide.
- **Why it hung for ~10 min:** UE4SS's CrashDumper always ends in `MessageBoxW(MB_OK)` (known; see ROOT CAUSES 2026-10-25 above), and the server watchdog (`tools/watchdog.ps1`, which restarts on a new `crash_*.dmp`) was not running. Only `client_watchdog.ps1` was.
  - There is still no ini switch for the dialog at SHA 83330635: `[CrashDump]` has only `EnableDumping` and `FullMemoryDump`.
  - `EnableDumping = 0` removes UE4SS's filter and its IAT hook on SetUnhandledExceptionFilter, so the crash falls to the game and WER and the process exits. Pair it with WER `LocalDumps` for the exe (DumpType 2) to keep a dump. [UNVERIFIED live: what the game's own handler does then.]
- **Rule:** never use `ExecuteWithDelay`, `LoopAsync` or `ExecuteAsync` (async-thread Lua) in `mod/` or `client_mod/`; use `ExecuteInGameThreadWithDelay` / `LoopInGameThreadWithDelay`.
  - Remaining offenders: server `experiments/nav_oracle.lua:120`, `experiments/navlink_probe.lua:59`; client `commands/jump.lua:10,13`, `commands/smoke_jump.lua:13`, `scripts/move.lua:4769,4774`. Proposed patches and a grep guard test are in the crash agent's report.
- **Side finding:** `U.try` returns zero values on failure (it falls off the end), so `tonumber(U.try(...))` raises "bad argument #1 to 'tonumber' (value expected)". This is the likely source of the 22:51:30 server error at `player_recorder.lua:98`; it is inside a pcall, but it drops the rest of that inventory's ForEach. Unverified, because the pre-restart UE4SS.log was overwritten.

### Farming: beds and flax (build 26161880, live 2026-11-02 02:44-03:05Z, ClaudeDev)
- `buildables {about:"bed"}`: **Bedroll** `BUILDPIECE_Interior_BedRoll` (3 Ash Logs + 3 Coarse Animal Fur, "sleep in and skip the night") is unlocked and buildable now; **Bed** `BUILDPIECE_Interior_Bed` (8 Ash Plank + 4 Rough Cloth) is unlocked but missing materials. Both have shelter_text "Requries Shelter" (sic): they must go under a roof, like the Spinning Wheel.
- Wild flax (`BP_Spawner_Flax_C`, gather profile `flax`) near (313,1787): three roots within 60 m; once picked they stay gone for at least an hour (02:44Z hunt found 1 left within 90 m after the 01:47Z run picked one). gather says so in seconds: "I got 1 but there's no more flax within 90 m of me."
- The 01:44-01:47Z 40 s stands (explore legs, flax approaches) were move.lua's oracle wait with the nav helper unresolved (01:01Z server restart until main re-armed it at 02:18Z); a 40 m leg is not > prov_min_cm 4000, so no provisional walk. With the helper up the route comes in 0.2 s.

## Processing-station output when overloaded; the station menu blocks pickups (2026-11-02 03:09-03:41Z; build 26161880, client 26162923, dev world, ClaudeDev; rung4 agent; scratchpad leather_repro.py)
- **Over the carry weight, a station's output does not come to his bag.** It stays on the ground by the station as `BP_RuntimeSpawnedWorldItem_ProcessingStation_C` (prompt "Collect"), one actor per item.
  - Under the limit (277/400) the Tannery's Leather arrived in his bag by itself.
  - At 424/400 (bag full) and at 447.5/400 (a free bag slot), all of them stayed on the ground. So weight is the blocker, not slots.
- **A manual pickup works while overloaded:** `interact` on one of them at 424/400 and at 447.5/400 took it (+1 Leather).
- **With the station's Processing menu open, the game offers no pickup at all.**
  - The craft's collect walked 4 spots round the Tannery with the menu still open: the detector showed nothing ("no use from where I can stand").
  - After the fix (crafting.lua closes the menu first, `InputManagerUIAPI:CloseWidgetIfOpen`), at 417.9/400 it collected both Leather. Menu closed 03:40:52, presses 03:40:53 and 03:40:57, done 03:41:05.
- **`processing_rate` (5.0 on most stations) does not divide `processing_time`.**
  - The Tannery takes ~10 s a Leather ([8, 12]).
  - Dividing by the rate gave a 29 s wait for 3, which timed out at "2 of 3" with both left on the ground.
- **The old collect failure ("couldn't pick up what it made") was half true.** It never said the items were still lying there, or why they never reached his bag.
