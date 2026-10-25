# Discoveries

Each entry: what it is, the parameters, what it does, how it was verified, the build ID, and the sources.
Server build: **26161880** (Steam app 4019830, installed 2026-10-25). Engine **UE 5.6** (from UE4SS.log). Game module: `Dominion` (classes under `/Script/Dominion.*`).

Research notes with full source lists: `docs/research/2026-10-25-ue4ss-chat-bridge.md`, `docs/research/2026-10-25-phase4-body.md`.

**Code layout (2026-10-25):** the experiment modules named below as `mod/scripts/<name>.lua` now live in `mod/experiments/<name>.lua`, and `debug_run` still finds them by name. Proven code was promoted:
- `puppet_safe` became `mod/body/removal.lua`.
- `chat_relay`, `chat_as`, `name_register` and `names_probe` became `mod/body/speech.lua` (`DW_SAY_MODE=relay`).

See `docs/ARCHITECTURE.md`.

## Environment

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
  - **There is no "Fellhollow" region in this build.** It is named only in a wiki changelog, so it is probably a newer area or a sub-area name.
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
