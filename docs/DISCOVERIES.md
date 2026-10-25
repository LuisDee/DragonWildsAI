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
