# Player-like bots for Dragonwilds: research notes (2026-10-25)

Scope: web research only. Nothing here was tested on our server. How to read it:

- **Confidence:** High = primary source (Epic docs, game wiki, repo/README) seen directly. Medium = consistent secondary or forum sources, or my own UE knowledge that fits the sources. Low = a single secondary source, a search-engine summary I could not open, or inference.
- **"[own knowledge]"** means the claim comes from my memory of UE source, not from a page fetched in this session. Treat it as a hypothesis to check against the Dragonwilds dump.
- Many sites (Nexus Mods, Survival Servers, Shockbyte, the Epic AnswerHub/forums) returned 403 or redirects to the fetcher. For those I only had search-result summaries, and I mark them Low.
- Project context: server-side only, vanilla GFN clients, UE 5.6, UE4SS Lua on the dedicated server, reflected API only (CLAUDE.md sections 1, 2, 4).

---

## 1. How UE games build server-side bots that look like players

### 1.1 The standard pattern: AIController plus optional PlayerState

| Claim | Confidence | Source |
|---|---|---|
| `AAIController` has a public flag `bWantsPlayerState` ("Specifies if this AI wants its own PlayerState"). It is editable and Blueprint read/write. | High | https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/AIModule/AAIController |
| Default AIControllers have no PlayerState. The usual fix was a subclass with `bWantsPlayerState = true` in the constructor. From UE 4.20 it is also settable in Blueprint class defaults. | Medium (forum answers, 2016-2022) | https://forums.unrealengine.com/questions/168533/how-can-i-have-proper-bot-players-with-a-playersta.html |
| The UE4 ShooterGame sample's `AShooterAIController` constructor sets `bWantsPlayerState = true`. Its `Possess` override then starts a behaviour tree. | Medium (2014 forum post quoting source) | https://forums.unrealengine.com/t/ue4-ai-shootergame-ai/1320 |
| ShooterGame stores a bot's team on its PlayerState (`ShooterPlayerState`), not on the controller. Bots can be spawned from Blueprint with `Spawn AI From Class`, which creates the pawn and its AIController and possesses it. | Medium | https://forums.unrealengine.com/t/ai-bot-spawning/369876 |
| In engine code, `AAIController::PostInitializeComponents` calls `InitPlayerState()` when `bWantsPlayerState` is true and the net mode is not client. The PlayerState is then replicated like a human's, and `bIsABot` is set. | Medium [own knowledge] | no URL fetched; check the UE 5.6 source or the Dragonwilds dump |
| AIControllers exist only on the server. Clients never see the controller, so anything clients need to see (name, team, score) must live on the pawn or PlayerState. | Medium | https://answers.unrealengine.com/questions/237668/view.html (search summary) |

Net result: the engine-sanctioned "bot that looks like a player" is a pawn driven by an AIController with its own PlayerState. Clients see the PlayerState (name, scoreboard entry) and the replicated pawn. They never see a controller.

### 1.2 Lyra (UE5 reference)

| Claim | Confidence | Source |
|---|---|---|
| Lyra bots are created server-side by `ULyraBotCreationComponent` (the `B_ShooterBotSpawner` Blueprint, injected into `LyraGameState`). It has "Num Bots to Create" (default 3) and a "Bot Controller Class" (`B_AI_Controller_LyraShooter`, derived from `ULyraPlayerBotController`). Each bot gets a random name. | High | https://x157.github.io/UE5/LyraStarterGame/ShooterCore/ |
| The spawn functions are `ServerCreateBots` and `SpawnOneBot`. | Low (Japanese blog via search summary) | https://yagigame.blogspot.com/2023/05/ue5-lyra-2playerstart.html |
| In Lyra the Ability System Component lives on the PlayerState, "AI needs the PlayerState", and the PlayerState fetches pawn data from the GameMode once the Experience loads. | Medium | https://forums.unrealengine.com/t/lyra-ue5-1-spawn-different-ai-pawns-setpawndata/740673 |
| **What breaks when a bot bypasses the PlayerState path.** A pawn spawned with plain `SpawnActor` and no Lyra PlayerState flow had no working ability system. Health could not be reduced, MaxHealth was 0, and init state stuck at "spawned". The same AI worked when spawned via the bot spawner. | Medium (one thread, two reporters) | same thread as above |
| Epic's dedicated-server tutorial for Lyra says to set bots to 0 so they don't attack clients on connect. Bot count is set in `B_ShooterBotSpawner`. | High | https://dev.epicgames.com/documentation/en-us/unreal-engine/setting-up-dedicated-servers-in-unreal-engine |

Lesson for Dragonwilds: if its player character gets its stats, abilities, inventory or equipment from a PlayerState or a PlayerController-owned component, a pawn spawned without that wiring will look right but be inert. Where each lives is the first thing to find in the dump.

### 1.3 What breaks when gameplay code assumes a PlayerController

| Assumption in game code | Effect on a bot | Confidence | Source |
|---|---|---|---|
| `Client*` RPCs on controller/pawn | With no owning connection, a Client RPC called on the server runs on the server. A Server RPC called from a client is dropped. So client-only side effects (UI, camera, input mode) run on the server with no widget, or not at all. | High (Epic RPC table: Client RPC, called from Server, owner None, executes on Server) | https://dev.epicgames.com/documentation/en-us/unreal-engine/remote-procedure-calls-in-unreal-engine |
| Server RPCs (`ServerEquip`, `ServerCraft` and so on) | These can only be called by the owning client, so a bot cannot call them "as a client". Lua has to call the server-side implementation (`*_Implementation` or the inner function) directly, which may skip validation. | Medium (inference from the RPC table; the Epic page also notes that Server RPCs from a client with no owner are dropped) | same |
| Inventory/equipment components on the PlayerController | AIControllers have none unless added. Common workarounds: keep inventory on the pawn, forward via PlayerState, or override `GetNetConnection`. | Medium (forum summary) | https://answers.unrealengine.com/questions/745173/view.html (301s to the forum home, so I could not read it; Low in practice) |
| `Cast<APlayerController>(GetController())`, `GetPlayerController(0)`, "for each PlayerController" loops | Null or skipped for bots. This is also why a bot may not be targeted or counted by systems that iterate PlayerControllers (aggro, XP share, party, respawn). | Medium [own knowledge] | none |
| HUD, widgets, camera | Don't exist on a dedicated server. Code that touches them from a pawn event can crash if the pawn is "locally controlled". `IsLocallyControlled` is false for AI-controlled pawns on a dedicated server (the controller is not a PlayerController). | Medium [own knowledge] | none |
| Anything keyed on the player's save/"character" record | A bot has no saved character. Dragonwilds uses per-player character save data (see 4). A bot given a PlayerState could be saved or loaded as a player. Needs checking on the throwaway world. | Low | none |

### 1.4 Techniques for a server-created PlayerController with no real client

No first-class UE feature does this. Findings by technique:

| Technique | What it is | Usable for us? | Confidence | Source |
|---|---|---|---|---|
| `USimulatedClientNetConnection` and `net.SimulateConnections` | Engine "fake connection that will absorb traffic and auto ack every packet", added at runtime, "useful for testing scaling". It is a `UNetConnection` subclass whose `DestroyOwningActor` destroys "generally a PlayerController", so it models fake clients with a controller. I found no source showing it yields a controllable pawn or inventory. | Unknown. A console command could run through UE4SS, but the pawn is likely uncontrolled. It is a stress-test tool. | High on what the class is; Low on whether the spawned controllers are usable | https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/USimulatedClientNetConnection |
| `UDemoNetDriver` and `UDemoNetConnection` | Simulated connection for recording and playing back replays. The spectator controller is a local PlayerController. | No. Replay playback, not a live server. | Medium | https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/UDemoNetConnection |
| `UChildConnection` (splitscreen) | Secondary split-screen connection "that reroutes calls to a parent connection". It needs a parent client connection. | No. It still needs a real client. | Medium (docs plus my inference) | https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/UChildConnection |
| `ULocalPlayer` and `UGameplayStatics::CreatePlayer` on a dedicated server | Epic docs: "There will be 0 spawned on dedicated servers". `CreatePlayer` is a reflected, Blueprint-callable function that creates a local player and (optionally) its PlayerController. Nobody documents calling it on a dedicated server. I expect it would create a PlayerController with no net connection, which you could possess a pawn with and drive from Lua. That is the only candidate here that stays inside the reflected API. | **Worth one experiment**, with high crash risk (viewport/HUD assumptions on a server with no local player) | Low (inference; docs only confirm that none exist by default) | https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/Engine/ULocalPlayer ; https://docs.unrealengine.com/4.26/en-US/API/Runtime/Engine/Kismet/UGameplayStatics/CreatePlayer/index.html |
| Manually fabricating a connection and calling the GameMode login path from native code | How Minecraft "FakePlayer" mods and Source/GMod `CreateFakeClient`/`player.CreateNextBot` do it: a fake client the engine treats as real. In UE it would mean C++/native calls (`UNetDriver::AddClientConnection`, `AGameModeBase::Login`). `SpawnPlayerController` is, as far as I recall, not a UFUNCTION. | Out of scope: not reflected, so it needs native work and Luis's sign-off (CLAUDE.md section 2) | Low [own knowledge for the UE side]; Medium for the other engines | https://wiki.facepunch.com/gmod/player.CreateNextBot ; https://www.player.games/en-US/creator-hub/minecraft/community/fakeplayer |
| Gauntlet / automation "bots" | Gauntlet orchestrates real client and server processes in one session (its example: four clients and a server). The optional `TestController` "puppeteers" a game instance. These are real clients. | Only as a template for technique C | High | https://dev.epicgames.com/documentation/en-us/unreal-engine/gauntlet-automation-framework-in-unreal-engine |
| `-nullrhi` headless clients | The Epic forum shows `-nullRHI` proposed for load-test clients, with conflicting reports ("does not work", then "does work"). No engine version or details. | See section 3 | Low | https://forums.unrealengine.com/t/building-headless-client/381318 |

Bottom line for question 1: Epic's own answer to "a fake player" is an AIController-driven pawn with its own PlayerState (ShooterGame, Lyra). Making a real PlayerController without a client needs engine-level fake connections, and I found no documented route. The only reflected-API candidate is `CreatePlayer` on the dedicated server, and that is an unproven guess.

---

## 2. UE4SS / modding precedents for fake players and bots

Honest summary: I found no documented UE4SS mod that spawns a player-clone bot on a dedicated server. The precedents are all "friendly or extra AI using the game's existing AI/companion classes".

| Game | What exists | What it implies | Confidence | Source |
|---|---|---|---|---|
| Ready or Not | "More SWAT Teammates" (UE4SS Lua plus a small C++ component) raises the AI squad from 4 to 6. A "Spawn Police" mod is described as "the only thing allowing AI in co-op", client-side, so the host must run it. | Extra AI teammates come from the game's own AI class. Needs a specific UE4SS build or it crashes at launch. I don't know if the first works online. | Low (search summary; Nexus pages blocked) | https://www.nexusmods.com/readyornot/mods/7966 ; https://steamcommunity.com/app/1144200/discussions/0/599638390296546086 |
| Abiotic Factor | "ExtendedPets" (UE4SS) adds companions that behave like the game's companions (feeding, save persistence, combat). The author admits the combat AI is weak and they "had to coax" the AI controller into fighting. `PetSpawner` spawns pets from a menu but adds no follower AI. | A mod can spawn a native companion class. The hard part is combat behaviour. A direct precedent for our "follows but fights badly" risk. | Low-Medium | https://www.nexusmods.com/abioticfactor/mods/253 ; https://www.nexusmods.com/abioticfactor/mods/245 |
| Palworld | Human NPCs (including bosses) are added through PalSchema JSON spawners, not live UE4SS spawns. No player-bot or fake-player mod found. Palworld only simulates the world while a player is connected, which is why people look for keep-alive tricks. | Spawning existing character classes via data works. A player-clone bot did not turn up. | Low | https://www.nexusmods.com/palworld/mods/4589 ; https://www.nexusmods.com/palworld/mods/3660 |
| Bodycam | Hobbyist bot spawner on UE4SS. It must spawn only after the level finishes loading or the game crashes. Single-player. | Spawn timing matters. Don't spawn during map load. | Low | https://www.nexusmods.com/bodycam/mods/23 |
| Motor Town | `MotorTownMods` is a Lua toolset aimed at dedicated servers, with a Lua HTTP server on port 5001 (needs luasocket), webhooks (needs luasec) and a forked UE4SS. It has no bots. AI drivers are a built-in game feature. | **Not a bot precedent, but a bridge precedent**: UE4SS Lua with luasocket on a dedicated server is a proven route for Phase 5. | High on what the repo is | https://github.com/drpsyko101/MotorTownMods |
| Conan Exiles thralls, V Rising servants, Enshrouded | Native game features (follower NPCs built into the games). Not mods, and not verified in this session. | Shows the genre expects follower AI, but gives no technical route for us. | Low (not researched) | none |
| Deep Rock Galactic | No AI teammate mod found. The official solo helper is the Bosco drone. | None. | Low | https://steamcommunity.com/app/548430/discussions/1/3729575504111615733 |
| UE4SS API | `UWorld:SpawnActor(UClass, FVector, FRotator)` exists in Lua. It wraps deferred spawn plus finish-spawning. Scaling is awkward. No documented Possess example for NPCs. | We can spawn pawns and controllers and call reflected functions such as `Possess` from Lua. | High | https://docs.ue4ss.com/dev/lua-api/classes/uworld.html ; https://github.com/UE4SS-RE/RE-UE4SS/pull/864 |
| Standard UE pawn plus controller recipe | Spawn the Pawn, spawn the AIController separately, call `Possess`. `Spawn AI From Class` does all three. A dedicated-server thread reports bot movement failing until controller spawn parameters were right. | Matches what we already did with creatures. | Medium | https://forums.unrealengine.com/t/how-to-programatically-spawn-some-pawns-and-attach-controllers-to-them/29581 |

Trade-offs of the "spawn a player pawn + AIController" family: it works exactly as far as the player pawn's logic is self-contained. Ready or Not and Abiotic Factor show that existing AI/companion classes work but their combat is weak. No example shows the player character class itself being AI-driven.

---

## 3. Headless or second real client as the companion

### 3.1 Can a UE5 client run headless on a CPU-only VM?

| Claim | Confidence | Source |
|---|---|---|
| `-nullRHI` is the standard flag for a client with "no graphics, no windows". Reports conflict on whether it works for game clients, and the thread gives no version. | Low | https://forums.unrealengine.com/t/building-headless-client/381318 |
| `-nullrhi` renders no frames, so camera and screenshot-based sensors are unavailable. That is incompatible with a pixel-based agent, though fine for an API-driven one. | Medium | https://pterosimdocs.readthedocs.io/en/latest/headless.html |
| One CI report: a render target was never created under `-nullrhi`, causing a crash (commandlet, not a game client). Some code paths assume rendering exists. | Low | https://forums.unrealengine.com/t/building-lightmaps-on-a-headless-box/433035 |
| Dragonwilds PC minimums: GTX 1060 class GPU, 8 GB RAM, DirectX 12, Windows 10 64-bit (2025 early-access figures). A CPU-only VM with no GPU fails the minimum. Software rendering of a UE5.6 game would be far too slow for a pixel agent. | Medium (figures dated) | https://destructoid.com/all-runescape-dragonwilds-minimum-and-recommended-system-requirements |
| Nobody has publicly run Dragonwilds, or a comparable UE5 survival game, as a headless bot client. I found nothing. The 28 repos under the GitHub topic include trainers (some are likely malware), OCR auto-clickers, and planners. | Medium (absence of evidence) | https://github.com/topics/runescape-dragonwilds |
| Dragonwilds clients can run UE4SS (Shockbyte's guide says to install it on both server and client). A second real client with UE4SS could be driven by Lua rather than pixels. That is speculative for a nullrhi client. | Low | https://shockbyte.com/help/knowledgebase/articles/how-to-add-mods-to-your-runescape-dragonwilds-server (blocked; via search summary) |

### 3.2 Licence and account constraints

| Claim | Confidence | Source |
|---|---|---|
| Steam logs out a session when the same account signs in on another computer. Forum posts say a game cannot be played on two machines at once with one account. Family Sharing allows one user per shared library at a time. Not confirmed against Valve docs. | Low | https://steamcommunity.com/discussions/forum/0/3729575504106569515 |
| The dedicated server tool is a separate free Steam app (4019830), distinct from the game (1374490). It installs anonymously. | Medium | https://www.survivalservers.com/wiki/How_to_Create_a_RuneScape_Dragonwild_Server_Guide (search summary) |
| A second real client therefore means a second account that owns the game (CLAUDE.md already notes this as Luis's call). I found no information on Dragonwilds anti-cheat (no EAC hits) or whether it checks for automated input. | Low | none |
| Jagex's modding guidelines forbid mods that "cheat in multiplayer or any shared gameplay" or give "unfair advantages in shared spaces". They don't mention bots or AI. A private-server companion that helps one friend is arguably outside the intent, but it is a judgement call. A hosted paid service would breach the "no charging" rule. | High on the text; Low on how it applies | https://legal.jagex.com/docs/policies/runescape-dragonwilds-community-modding-guidelines |

### 3.3 LLM agents that play commercial games from pixels

| System | Result | Latency / cost | Confidence | Source |
|---|---|---|---|---|
| Cradle (BAAI) | Screenshot in, keyboard/mouse out. Played RDR2 for 40-minute missions, Stardew Valley, Cities: Skylines, Dealer's Life 2. Needs per-game modules. | For real-time games the README says to **pause the game while waiting for the model**, then unpause to act. That is impossible on a multiplayer server. Supports OpenAI and Claude. | High | https://arxiv.org/abs/2403.03186v3 ; https://github.com/BAAI-Agents/Cradle |
| Lumine (ByteDance Seed) | A trained VLA (Qwen2-VL based) that plays Genshin Impact at human pace and transfers to other games. 5 Hz input and 30 Hz output. Beats frontier LLMs via Cradle. Fails on hard terrain and puzzle tasks. About half of errors are perception errors. | Needs four H20 GPUs for inference. First action chunk about 114 ms (234 ms with reasoning). Frontier-LLM baselines via API can take up to 30 s per call, and the game was paused. | High | https://arxiv.org/html/2511.08892v1 |
| SIMA 2 (DeepMind) | Gemini-based agent for 3D worlds. Research preview only. SIMA 1: 31% success on complex tasks versus 71% for humans. Struggles with long-horizon tasks and has a short context. | Not stated. | Medium | https://techcrunch.com/2025/11/13/googles-sima-2-agent-uses-gemini-to-reason-and-act-in-virtual-world ; https://www.infoq.com/news/2025/12/sima-2-gemini-agent |
| Generic computer-use agents | Screenshot, reason, act loop. Blogs report 2-5 s per action and roughly $0.10 for a 10-step task. A 2026 paper measures a 567 ms p50 perceive-reason-act round trip against a 600 ms window and says agents fail from "late understanding". | Seconds per step. Not credible for combat. | Low (blogs) / Medium (paper) | https://tianpan.co/blog/2026/04/10/computer-use-agents-when-pixels-replace-apis ; https://arxiv.org/pdf/2607.28399 |
| NVIDIA ACE Game Agent SDK | Local-RTX-GPU character agent, beta June 2026 per a secondary blog. | Needs the game integration; it is not an external bot. | Low | https://www.creativeainews.com/blog/nvidia-ace-game-agent-sdk-unreal-engine-5-2026/ |

Cost I could not source: a GPU VM capable of running the game (a typical cloud GPU instance is a few tenths to over a dollar per hour; my estimate, unsourced) plus a second game licence plus model calls. Lumine-class models are not available to us. Pixel agents using an API model would be seconds per decision, so they would be a poor fighter even with a perfect harness.

Bottom line for question 3: a headless CPU-only second client is not credible. A GPU VM with a second licence is feasible but slow, unreliable (31-80% task success on research agents, zero on hard cases) and expensive to run continuously. Its only real advantage is that it genuinely is a player.

---

## 4. Dragonwilds specifics

### 4.1 Game state and chat

| Claim | Confidence | Source |
|---|---|---|
| Chat exists: Enter opens it, public only (no private messages), 256-character limit, spam limit of 3 messages then 5 s wait, unavailable while resting, in the build menu, or in cutscenes. | High | https://dragonwilds.runescape.wiki/w/Chat |
| **The game already posts automatic server-origin chat lines**: "USER has joined", "USER has left", "USER has died". So a system-message path exists (hook candidates). The wiki lists no admin message or chat command beyond these. | High | https://dragonwilds.runescape.wiki/w/Chat |
| Admin is granted by entering an admin password in the in-game Server Management screen. Third-party guides say there are no console commands and no RCON. I found no RCON or announce command. | Medium | https://www.gameserverkings.com/knowledge-base/runescape-dragonwilds/admins-bans-and-player-management/ |
| Game left Early Access at 1.0 on 15 September 2026, with crossplay and a dedicated-server crossplay option. The 1.0 notes mention "a Buddy" and pet perches. Latest content update was 0.12.0 "Eye on Ashenfall" (23 June 2026, Umbral Sands). Scorned Wilderness is the next major update. | Medium | https://www.bisecthosting.com/es-es/blog/runescape-dragonwilds-1-0-update-patch-notes-scorned-wilderness-kuldra-the-god-eater-combat-rework-new-items ; https://dragonwilds.runescape.wiki/w/Buddy ; https://dragonwilds.runescape.com/news/dragonwilds-summit-wrapup |
| Hosting guides conflict on UE4SS on the server. Shockbyte and others say server-side UE4SS works. One post-1.0 guide says UE4SS does not load on the dedicated server and that only pak mods run there. Our own project has already proven that UE4SS runs and that AI creatures can be driven, so ignore this conflict, but re-run the smoke test after each patch. | Low (hosting wikis; marketing-flavoured) | https://www.survivalservers.com/wiki/RuneScape_Dragonwilds_Mods_After_the_1.0_Update (403; via search summary) |

### 4.2 Existing companions, allies and AI in the game

| Item | What it tells us | Confidence | Source |
|---|---|---|---|
| **Buddy**: a "power level 7 summonable kalphite" (825 HP) summoned with the Pharaoh's Sceptre special ("Sworn Servant"). Lasts up to 3 min, 5 min respawn, released 23 June 2026. Fights and distracts enemies. A wiki note says it may not respawn or spawn in an online world (the bug text is from a search summary; the wiki page I opened did not cover it). | **The game already has a server-spawned, player-friendly, combat AI ally that replicates to vanilla clients.** Its spawn function, faction/attitude setup and AI controller are the best template for a friendly humanoid. Reverse-engineer the Sceptre special first. | High on existence; Low on the online-spawn bug | https://dragonwilds.runescape.wiki/w/Buddy ; https://dragonwilds.runescape.wiki/w/Pharaoh%27s_Sceptre |
| Pets: 1.0 added "pet-related building pieces, beginning with Perches for Birds". | Some pet system exists. Details unknown. | Low | the BisectHosting 1.0 notes above |
| Official future plans for followers, pets or NPC helpers | **None announced.** Roadmap pages mention friendly NPCs (2 new NPCs in Fellhollow, Garou nomads in Umbral Sands) and "muster your allies" in the Kuldra finale, with no companion mechanic stated. A Steam thread asks whether an AI companion is planned for solo play; there is no dev reply. | High (absence) | https://dragonwilds.runescape.com/news/the-road-to-2026 ; https://steamcommunity.com/app/1374490/discussions/0/570417058359192764/ |
| Jagex mod stance: "mods are definitely on the table" (April 2025). They publish community modding guidelines and run a Nexus/CurseForge ecosystem. The guidelines allow new characters and quests that don't break existing content. | | High | https://www.pcgamesn.com/runescape-dragonwilds/mods ; https://legal.jagex.com/docs/policies/runescape-dragonwilds-community-modding-guidelines |

### 4.3 Community mods and frameworks

| Item | Notes | Confidence | Source |
|---|---|---|---|
| **Pet Rock** (Nexus 703): mining a rock can produce a companion that trails the player and responds to commands. Requires UE4SS. No combat. | Evidence that a follower can be created by mod in Dragonwilds. Nexus blocked the fetch, so how it spawns and replicates is unknown. | Low | https://www.nexusmods.com/runescapedragonwilds/mods/703 (search summary) |
| **Summoning Skill** (CurseForge UE4SS mod): summonable lesser dragons that fight for you, plus follower familiars that never fight. "Every player in the world needs the same version of this mod", so it is client-visible content, not vanilla-client friendly. It needs RuneSchema. | Shows follower and combat allies are doable through the game's AI. Parity with clients is a problem for them but not for us if we reuse existing classes only. | Medium | https://www.curseforge.com/runescape-dragonwilds/ue4ss-mods/summoning-skill |
| **Dragon Mounts** (Nexus 726): rideable dragons plus an NPC questline. | Not a companion. | Low | https://www.nexusmods.com/runescapedragonwilds/mods/726 |
| **RuneSchema** (framework forked from PalSchema, JSON add-ons over UE4SS, docs site): its NPC loader creates "persistent, interactable actors" of types AI, human, resource and merchants, e.g. `BP_BaseInteractableNPC`, with `Equipment` slots, `HideWeapon`, `DialogueID`, `VendorID`. In multiplayer "the server creates NPCs and clients prepare the replicated presentation". The spawns loader places AI by class, `PowerLevel`, `TimeOfDay`, `SpawnRadiusMeters`. **Neither page mentions followers or companion behaviour.** Its parity page says gameplay mods with authoritative content need matching PAKs on clients and does not say whether vanilla clients can join. | Strong evidence that **human NPC actors with equipment exist as spawnable native classes** in the game and replicate. No follow or friendly-faction AI is documented. | Medium-High (README and docs read directly) | https://gh0sted5456-us.github.io/RuneSchema/reference/loaders/npc/ ; https://gh0sted5456-us.github.io/RuneSchema/reference/loaders/spawns/ ; https://gh0sted5456-us.github.io/RuneSchema/servers/mod-parity/ ; https://github.com/smashedbanan/RuneSchema |
| **RSDW Dev Kit** (kits, mods, fields; not official) | Possible data source for class names. I could not find its repo. | Low | https://macmyths.com/how-to-create-a-mod-for-runescape-dragonwilds/ |
| **Many GitHub "trainers"** under the `runescape-dragonwilds` topic are likely malware or cheat tools. | Don't download or run any of them. Use only as a signal that a memory-hacking scene exists. | Medium | https://github.com/topics/runescape-dragonwilds |

---

## Recommendation (ranked)

Ranking is for "a humanoid that acts like another player, server-side only, vanilla clients, reflected API only, throwaway world".

### 1st: (B) a friendly humanoid AI, using Buddy as the template

- **Feasibility: highest.** We already proved server-spawned AI creatures replicate and follow. RuneSchema's docs show human NPC actors with equipment slots are native, spawnable and replicated. Buddy proves the game already has a player-friendly combat ally that works on vanilla clients, so the faction/attitude mechanism exists and is findable (hook the Pharaoh's Sceptre special).
- **Fidelity: medium.** Looks humanoid and can wear gear, but fights through NPC/creature combat logic, not the player's skill and weapon-switch system. Hurt, death and loot will follow NPC rules, not the player's. Abiotic Factor's ExtendedPets shows the typical failure: spawning is easy and combat behaviour is the weak part.
- **Latency/cost: lowest.** Server tick speed, no extra licence, no GPU. LLM cost is the same as any design.
- **Key unknowns to resolve in the dump:** which human NPC classes exist; how Buddy sets allegiance so hostile mobs target it and it doesn't hit players; whether a human NPC can be given a follow/fight AI controller (reuse Buddy's controller class); whether it can pick up loot and equip items (probably via set-equipment functions, not player inventory).

### 2nd: (A) the player pawn plus AIController (with PlayerState)

- **Feasibility: unknown and gated by one question.** Where do the player character's inventory, equipment, abilities and stats live (pawn component, PlayerController, or PlayerState)? Lyra shows a pawn without its PlayerState wiring is inert. If they live on the pawn, it is feasible: spawn the player class, attach an AIController with `bWantsPlayerState = true` (the flag is read in `PostInitializeComponents` [own knowledge], so it must be set via the controller class defaults or on a deferred spawn before finishing; otherwise try calling `InitPlayerState` afterwards, which is untested), drive it with `MoveTo` and the same server functions players trigger. If they live on the PlayerController, you need the `CreatePlayer` experiment (section 1.4) or you are stuck. Check this before spending more effort.
- **Fidelity: highest for what the server can offer.** Same mesh, animations, equipment visuals, weapon switching and combat code as a real player, and it appears in the player list (and probably in chat as "joined"). A fake PlayerState also gives it a name and nameplate on clients.
- **Risks:** the PlayerState may make the game treat it as a real player (autosave of a character, player counts, join messages, party and XP logic, "all players dead" logic). The player class may crash when `GetPlayerController()` or HUD calls return null. Client RPCs run on the server (Epic table), so some UI-driven calls will misbehave silently.
- **Latency/cost:** same as (B).
- **Suggested probe order (no native work):** (1) dump the player character class and find its components; (2) spawn it with a plain AIController and see if it replicates and animates; (3) set `bWantsPlayerState` and check the nameplate; (4) only if inventory fails, try `CreatePlayer`.

### 3rd: (C) a second real client driven by an agent

- **Feasibility: low.** CPU-only headless is not credible (GPU minimum, `-nullrhi` unproven for this game, no public precedent). It needs a GPU VM, a second game licence and account (Luis's call, per CLAUDE.md), and possibly UE4SS inside the client to avoid pixel control.
- **Fidelity: highest by definition** (it is a player, with real inventory, chat and animations).
- **Latency/cost: worst.** Pixel agents take seconds per step, and Cradle pauses the game, which a shared server forbids. Lumine-class latency needs multi-GPU infrastructure we don't have. Generic API-model agents succeed 30-80% of the time on research tasks and collapse on hard ones.
- **Use only as a fallback** if both A and B are proven impossible, and treat the nullrhi-plus-client-UE4SS hybrid as a research spike, not a plan.

### Decision summary

| | Feasibility | Acts like a player | Latency | Cost |
|---|---|---|---|---|
| B humanoid AI | High | Medium | Tick speed | Lowest |
| A player pawn plus AIController | Unknown (one dump question) | High | Tick speed | Lowest |
| C second client | Low | Highest | Seconds per action | GPU VM plus licence plus API |

A and B share most of the work (spawn, possess, follow, state exporter, bridge), so start with B and its Buddy template, then test A's probe order. The Phase 4 gate ("visible, walks to Luis, consistent after rejoin") is already met by creatures, so the next experiment is whether a human class meets it.

## Gaps and things I could not verify

- No UE 5.6 source was read. The `AIController`/`InitPlayerState` and `GameModeBase` points are marked [own knowledge].
- Nexus Mods, Survival Servers, Shockbyte and Epic AnswerHub pages returned 403 or redirects. Anything attributed to them came from search summaries.
- I found no source on how Pet Rock and Buddy spawn, whether Dragonwilds uses Steam or EOS for session auth, or whether it has anti-cheat.
- Nothing here has been tested on the server. Treat every "feasible" as a hypothesis for the dump to confirm.
