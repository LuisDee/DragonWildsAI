# Discoveries

Each entry: what it is, the parameters, what it does, how it was verified, the build ID, and the sources.
Server build: **26161880** (Steam app 4019830, installed 2026-10-25). Engine **UE 5.6** (from UE4SS.log). Game module: `Dominion` (classes under `/Script/Dominion.*`).

Research notes with full source lists: `docs/research/2026-10-25-ue4ss-chat-bridge.md`, `docs/research/2026-10-25-phase4-body.md`.

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
