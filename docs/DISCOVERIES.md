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
