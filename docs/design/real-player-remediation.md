# Real-player remediation (2026-10-25)

Luis's decision (binding): **Claude must act like a real player, through the same code paths a player
uses. No more shortcuts or emulation.** Workarounds only delay work: each emulated capability
(inventory store, magnet, emulated axe damage, spawned shelter, emulated crafting, speech relay,
nameplate account copy) produces its own bugs and has to be redone for every new capability.

## Root cause

- Claude's body is a `BP_PlayerCharacter_C` possessed by an **AIController**.
- Everything that makes a player a player lives on the **PlayerController**, which Claude does not
  have (CXX Dominion.hpp:10139, `ADominionPlayerController`): `InventoryController`, `InventoryComponent`,
  `PersonalInventoryComponent`, `LoadoutComponent` (hotbar/equipped), `ProgressComponent` (XP),
  `SkillPerkComponent` (perks, e.g. double jump), `SpellcastingComponent`, `LodestoneTeleportationComponent`,
  `Build*Component`, `PlayerChatComponent`, `RevealedMap*`, quests and journal.
- So the game's own equip path cannot run: there is no item object behind the held axe.
  `FPlayerActionInstance.ActionGranter` is null, so every swing counts as unarmed and does 0 damage
  (gather agent, DISCOVERIES).

## Why "just give him a PlayerController on the server" is not enough

- On a server-only build `APlayerController::IsLocalController()` is always false
  (`FPlatformProperties::IsServerOnly()`), so a connectionless PC's pawn is treated as remotely
  controlled. It waits for client move packets and stands still. This is engine behaviour, not yet
  verified on this build.
- A real player's actions (attack, sprint, block, dodge, player actions) travel **inside the movement
  stream** (`Character:ServerMovePacked`, `EDomMoverActionTypeIndex`). The server validates them and
  acks them with `Client_ConfirmActionId` / `Client_PlayerActionAcks`. There is **no
  `Server_PerformAttack` RPC** (research/2026-10-25-humanoid-companion-dump.md A.4).
- Dominion's login is client-driven (`Server_SetPlayerGuid`, `Server_SetPlayerCharacterInfo`,
  `Server_BeginPlayerProfileStream`, `Server_AllowPlayerCharacterToSpawn`). A spawned PC never becomes "ready".
- So the "same path a player uses" begins on the **client** side of the connection. To be on it,
  Claude must either be a client or impersonate one inside the server.

## Options

| | Route | What it is | Faithfulness | Cost / risk |
|---|---|---|---|---|
| **R2 (recommended)** | **Real game client** | A second copy of the Dragonwilds client, on its own Steam account, joins the dev server as a normal player. UE4SS runs on that client, and our Lua body mod drives the local player through the game's own input (Enhanced Input `InjectInputForAction` / `InjectInputVectorForAction`, BlueprintCallable) and its own UI-level functions. | 100%: it *is* a player. The server sees a real connection, real login, real save, real movement and action packets. | Needs a second licence and Steam account (Luis). Needs a machine that can run the client: try `-nullrhi -nosound -unattended` on this CPU VM first (8 GB RAM is tight beside the server, so a 16 GB resize may be needed); otherwise a GPU VM or a home PC. NullRHI can crash on UI init (a Noesis UE5.7 report). Jagex modding rules forbid unfair advantage in shared spaces, which a private server is fine under. |
| R1 | Fake client connection inside the server | Native C++ UE4SS mod: create a `UNetConnection`, run the GameMode login, then the Dominion profile stream, then feed `ServerMove*`-equivalent move and action data each tick (GMod `CreateFakeClient`-style). | High, but we would be re-implementing the client's networking half. | Native work outside the reflected API (needs Luis's sign-off), Windows-only C++, fragile on every patch. Not recommended. |
| R3 | Keep emulating (status quo) | AIController body plus hand-made substitutes for each controller system. | Low. | **Rejected by Luis.** |

## What R2 changes

**Retired (each replaced by the game's real path):**
- puppet spawn/possess/removal (the unpossess crash class disappears);
- gear dressing (real equip from his real inventory);
- nameplate account copy (his own account name);
- speech relay and direct mode (his own chat box);
- the Lua inventory store and magnet (real inventory and magnet);
- emulated axe damage (real tier check, XP and durability);
- shelter spawn plus direct sleep (he casts Summon Shelter and lies down);
- emulated crafting (real stations);
- lodestone emulation (his own teleport component).

**Kept:**
- the brain and `GameInterface`;
- the bridge;
- data catalogs (items, spells, recipes, attack data) and resource profiles;
- the server-side perception census (`sense`, `watch`);
- navmesh path queries on the server, sent to the client body as waypoints. Clients may have no navmesh, so this is to be checked.

**Navigation becomes player navigation:** sprint, jump, double jump (his own perk) and Windstep are
just input actions, which answers Luis's traversal question.

**New decision for Luis:** Claude's character becomes a real save with real progression. Either he
levels up, or he is started from an existing high-level character on the throwaway world.

## Gates (each go/no-go, in order)

0. **Luis:** second Steam account plus licence; where the client runs.
1. **Client runs and joins.** Install the client, launch it headless (`-nullrhi`) on this VM, and join the
   dev server. Pass: Luis sees "Claude has joined" and the character in the world.
   - If it fails on CPU: try a GPU VM, or Luis's spare PC.
2. **UE4SS on the client.** The mod loads, reads the local PlayerController's inventory and loadout,
   and injects one input (jump). Pass: Luis sees him jump.
3. **Real axe.** He equips an axe from his own inventory through the game's equip path and chops a
   standing oak. Pass: tree HP drops natively, the logs land in his real inventory via the real magnet,
   and he gains woodcutting XP.
4. **Bridge.** The client mod talks to the brain over the same JSONL protocol. Port the skills one by one
   (follow, attack, gather, give, sleep, craft, travel), each with a test, and delete the emulation it
   replaces.

## Sources

- Enhanced Input injection: https://dev.epicgames.com/documentation/unreal-engine/API/Plugins/EnhancedInput/IEnhancedInputSubsystemInterface/InjectInputForAction
- Headless clients (`-nullRHI`): https://forums.unrealengine.com/t/building-headless-client/381318 ; https://pterosimdocs.readthedocs.io/en/latest/headless.html ; NullRHI UI crash: https://www.noesisengine.com/bugs/view.php?id=4987
- Dragonwilds client UE4SS installs: https://deltiasgaming.com/?p=207256 ; https://shockbyte.com/help/knowledgebase/articles/how-to-add-mods-to-your-runescape-dragonwilds-server
- RPC ownership rules (Client RPCs with no owning connection run on the server): https://dev.epicgames.com/documentation/en-us/unreal-engine/remote-procedure-calls-in-unreal-engine
- Prior research: docs/research/2026-10-25-player-like-bots.md (sections 1.3, 1.4, 3), docs/research/2026-10-25-humanoid-companion-dump.md (A.4, A.5)
