# Research: Dragonwilds dedicated server, UE4SS, chat, bridge, prior art (2026-10-25)

Method: web search and fetch only. Nothing was installed or modified. Several host KB pages (Shockbyte, SurvivalServers, BisectHosting, Nexus) returned HTTP 403 to the fetch tool, so their content is known only from search-result summaries (marked "snippet"). Confidence levels: CONFIRMED-PRIMARY (official/project primary source read directly), MULTI (several independent secondary sources), SINGLE (one source), UNKNOWN.

---

## Headline findings

1. A **Windows** dedicated server build exists (same Steam app 4019830). The hosting guides saying "UE4SS cannot work on the server because it is a Linux build" describe the **Linux** build that those hosts run. They do not apply to the Windows build we run.
2. A working server-side UE4SS setup exists in the wild: github.com/kevinw9092/RSE-Server runs the Windows server (under Wine, in Docker) with UE4SS and server-side Lua mods. The key trick: **the dedicated server does not load `dwmapi.dll`; copy the UE4SS proxy as `version.dll`.** Success is logged as `UE4SS enabled (as version.dll)`.
3. In-game text chat **exists** (public only, 256 chars). No known class or function names are published. We will have to find them in the dump.
4. Recommended bridge: file-based JSONL (portable, zero native deps), with LuaSocket as an optional later upgrade. Do not use a C++ mod.

---

## A. Dedicated server facts

### A1. Install layout and executables
- Steam app **4019830**, anonymous SteamCMD login, e.g. `+force_install_dir C:\GameServers\Dragonwilds +login anonymous +app_update 4019830 validate +quit`. Confidence: MULTI (tcno hub, Dragonwilds wiki Windows page, xgamingserver).
- Launcher exe in install root: `RSDragonwildsServer.exe` with `-log -NewConsole`. Confidence: MULTI (tcno hub, xgamingserver blog, wiki). tcno notes Jagex's March guide called it `RSDragonwilds.exe`, so check the folder.
- The **real shipping binary** is `RSDragonwilds\Binaries\Win64\RSDragonwildsServer-Win64-Shipping.exe`. RSE-Server states the small `RSDragonwildsServer.exe` launcher "doesn't start the server under Wine" so it runs the Shipping exe directly. Confidence: SINGLE (RSE-Server README). The client equivalent is `RSDragonwilds-Win64-Shipping.exe`. The UE4SS proxy DLL must sit next to the **Shipping** exe in `RSDragonwilds\Binaries\Win64\`.
- Port: UDP 7777 (game); secondary UDP 7778 (wiki, xgamingserver). The Docker image README (Linux) lists UDP 8888 as the beacon port, which contradicts 7778; the Windows value is unverified. Open 7777 and 7778 to be safe. Second instance on the same host is not documented.
- RAM: 2 GB + 1 GB per player, 6 player max (wiki). Docker README minimum is 4 GiB. Confidence: MULTI.
- Server and client builds must match exactly or the server vanishes from the list; the server version is at the top of its log (wiki). Every patch needs a restart. Confidence: MULTI.
- Sources: https://hub.tcno.co/games/dragonwilds/dedicated_server/ , https://dragonwilds.runescape.wiki/w/Dedicated_Servers , https://dragonwilds.runescape.wiki/w/Dedicated_Servers/Windows , https://xgamingserver.com/blog/how-to-set-up-runescape-dragonwilds-dedicated-server/ , https://github.com/kevinw9092/RSE-Server , https://github.com/runescape/rsdw-dedicated

### A2. DedicatedServer.ini
- Windows path: `<install>\RSDragonwilds\Saved\Config\WindowsServer\DedicatedServer.ini` (Linux: `...\Config\Linux\` or `LinuxServer`; sources disagree for Linux, agree for Windows). Confidence: MULTI.
- Section: `[/Script/Dominion.DedicatedServerSettings]`. Keys: `OwnerId`, `ServerName`, `DefaultWorldName`, `AdminPassword`, `WorldPassword` (optional, empty = public; overrides password in the save), `ServerGuid` (auto, do not edit), `PlatformPolicy=Crossplay` (written by the game since 1.0). Confidence: MULTI (tcno, xgamingserver, supercraft, gameserverkings).
- `OwnerId` = the in-game Player ID (bottom of the Settings menu), not the Steam ID (tcno; one source calls it SteamID64, and the Docker README calls it an "EOS Online ID"). Contradiction noted; use the in-game Player ID. A search summary says Jagex announced on 13 April 2026 that OwnerId is becoming optional with an admin password claim on first join. Confidence: SINGLE, unverified.
- Edits made while the server runs are overwritten: stop the server first. The server may create the file only after first launch. Confidence: MULTI.
- There is **no** "modded/vanilla/secure" key found in the ini. Vanilla vs moddable is described as two server *types* (see A5), not a documented ini setting. Confidence: UNKNOWN where it is set for self-hosting; probably nothing is needed, since the Windows build runs mods if the proxy DLL loads.
- Docker image env vars (Linux image, for reference only): `RSDW_OWNER_ID`, `RSDW_PORT`, `RSDW_BEACON_PORT`, `RSDW_SERVER_NAME`, `RSDW_WORLD_NAME`, `RSDW_PASSWORD`, `RSDW_ADMINS`, `RSDW_ADMIN_PASSWORD`, `RSDW_ADDITIONAL_ARGS`. `-port=1234` changes the port. Avoid `-FORCELOGFLUSH`, which can freeze the server. Source: https://github.com/runescape/rsdw-dedicated (CONFIRMED-PRIMARY, Jagex org).

### A3. World creation, selection, saves, logs
- On start, the server loads the **latest `.sav`** in its SaveGames folder; if none exists it creates a default Standard world named `DefaultWorldName`. A custom world is made in a local client and the `.sav` is copied in with the original filename (wiki). Confidence: wiki (primary-ish) plus tcno.
- Wiki says the folder is `C:\Users\<user>\AppData\Local\RSDragonwilds\Saved\Savegames`; tcno and xgamingserver say server saves are `<install>\RSDragonwilds\Saved\SaveGames\`. Contradiction: the wiki wording looks like the client path. Treat the install-relative path as correct for `-log` runs from the install dir, and verify after first run. Confidence: MULTI for the install-relative path.
- Log: `<install>\RSDragonwilds\Saved\Logs\RSDragonwilds.log` (tcno, xgamingserver, RSE-Server). Confidence: MULTI.
- 1.0 and patches had save-corruption bugs (1.0.0.4 fix, 1.0.0.5 fix for console players on modded servers); stop the server cleanly, back up saves before each update. Source: https://www.gameserverkings.com/blog/dragonwilds-1-0-what-changes-for-server-owners/ . Confidence: SINGLE.
- Roles: Owner (matches OwnerId), Admin (knows AdminPassword), regular. There is no RCON and no server console commands; management is the in-game Server Management screen (wiki, hosts). Confidence: MULTI.

### A4. Steam beta branch
- No source mentions a beta, public_test or experimental branch for app 4019830. Confidence: UNKNOWN. Check SteamDB (steamdb.info/app/4019830/depots) or `steamcmd +app_info_print 4019830` in the main session.

### A5. "Modded" vs vanilla servers; Shockbyte and other hosts
- xgamingserver and others state Jagex supports two server types: **Vanilla (Secure)**, cannot be modified; and **Moddable**, supports community mods "via UE4SS". One host says Jagex described this plan in December 2025; Jagex has no official mod API, only Community Modding Guidelines (do's and don'ts). Confidence: MULTI (secondary), no Jagex primary page found. Sources: https://xgamingserver.com/blog/runescape-dragonwilds-dedicated-servers-explained/ , https://www.gameserverkings.com/blog/dragonwilds-1-0-what-changes-for-server-owners/
- **Shockbyte** (official Jagex host): choosing the modded server type "automatically switches to a Windows-based version of RS Dragonwilds (required for UE4SS) and installs UE4SS"; you must re-enter the Owner ID and update configs. Optional "UE4SS Signatures" download only if a mod needs FText support. Mods enabled via `Mods.txt`. Confidence: MULTI (many language copies of one Shockbyte article, read via search snippet only). URL: https://shockbyte.com/help/knowledgebase/articles/how-to-add-mods-to-your-runescape-dragonwilds-server
- **LogicServers** (Windows-style layout): "Go to `RSDragonwilds/Binaries/Win64`, upload and extract the UE4SS files there. The UE4SS DLL should be in the same folder as the server executable. Restart once; UE4SS creates a `ue4ss` folder inside `RSDragonwilds/Binaries/Win64`." Mod Manager installs a package called "UE4SS for RSDragonwilds". Confidence: SINGLE, read directly. URL: https://my.logicservers.com/knowledgebase/665/How-to-install-UE4SS-on-your-Dragonwilds-server.html
- **CONTRADICTION**: Mint Servers, Flux (runonflux), SurvivalServers (post-1.0 pages) say UE4SS mods do **not** run on dedicated servers because "the server is a Linux build"; pak mods only, in `RSDragonwilds/Content/Paks/~mods` (three files: .pak, .utoc, .ucas). Resolution: those hosts run the Linux build. Shockbyte's modded type, LogicServers, BisectHosting (has a "How to Install UE4SS on a Dragonwilds Server" article, 403) and RSE-Server use the Windows build and do run UE4SS. Confidence in the resolution: MULTI for "Windows build + UE4SS works", single functional proof (RSE-Server) for the `version.dll` trick. URLs: https://mintservers.com/knowledgebase/dragonwilds-install-mods , https://runonflux.com/games/dragonwilds/guides/install-mods , https://help.bisecthosting.com/hc/en-us/articles/48745531031067-How-to-Install-UE4SS-on-a-RuneScape-Dragonwilds-Server
- Not verified whether Jagex's anti-cheat/"secure" mode affects a Windows server started without special flags. The Windows Steam depot is the same app; assume moddable.

---

## B. UE4SS on the Dragonwilds dedicated server

### B1. Which build
- Releases (read from GitHub API): stable **v3.0.1** (2024-02-14), asset `UE4SS_v3.0.1.zip`: https://github.com/UE4SS-RE/RE-UE4SS/releases/download/v3.0.1/UE4SS_v3.0.1.zip . Rolling **experimental-latest** (the API returned published_at 2024-12-29, asset `UE4SS_v3.0.1-1181-g83330635.zip`, which may be a stale cached view; the tag is rolling, so re-check): https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental-latest . Confidence: CONFIRMED-PRIMARY for the lists; the freshness of experimental-latest is uncertain.
- Release notes of that experimental build: new layout (`dwmapi.dll` or proxy in Win64, everything else in `ue4ss\` subfolder), **UE 5.4 to 5.8 support added**, Lua 5.4.7, delayed-action system, `DumpJMAP`, `ModsFolderPaths`, `ControllingModsTxt`. Stable v3.0.1 predates 5.4+ support.
- UE version of Dragonwilds: one source (runescape.wiki infobox) says UE **5.4**; Jagex/press say only "Unreal Engine 5". Confidence: SINGLE. Since UE4SS detects the version from the exe, check `UE4SS.log` on first run. Therefore use **experimental-latest**, not v3.0.1. Nexus's "UE4SS for RSDragonwilds" (https://www.nexusmods.com/runescapedragonwilds/mods/4) and the CurseForge guide ("extract the latest build into `RSDragonwilds\Binaries\Win64`") are what the community uses on clients; the page returned 403 so its exact build is unknown. https://blog.curseforge.com/how-to-mod-runescape-dragonwilds/
- Other games' Nexus pages show FText/GUObjectArray signature packs being needed for UE 5.4+ custom builds (e.g. MotorTownMods ships `FText_Constructor.lua` and `GUObjectArray.lua` in `UE4SS_Signatures`). Shockbyte's "UE4SS Signatures" is the Dragonwilds analogue, needed only for mods that construct FText. We do not need FText for the first milestones. Confidence: MULTI for the mechanism; the Dragonwilds-specific pack URL is UNKNOWN (403 on Nexus).

### B2. Location and proxy DLL
- Folder: `<install>\RSDragonwilds\Binaries\Win64\` beside `RSDragonwildsServer-Win64-Shipping.exe` (RSE-Server, LogicServers). Confidence: SINGLE functional proof plus consistent hosting guides.
- **Proxy DLL**: rename/copy `dwmapi.dll` to **`version.dll`**. RSE-Server: the dedicated server "never loads dwmapi.dll because it has no desktop window manager" but does load `version.dll`. A Nexus page for another game's dedicated server says the same ("replace dwmapi.dll with version.dll for dedicated servers"). Confidence: MULTI (two independent games). Caveat: RSE-Server ran under Wine; on native Windows Server `dwmapi.dll` may well load (Windows Server with Desktop Experience has DWM), so try dwmapi first, and fall back to version.dll, which loads on both. Simplest: use `version.dll` from the start. Do not place both.
- Also: layout with experimental is `Win64\version.dll` plus `Win64\ue4ss\UE4SS.dll`, `UE4SS-settings.ini`, `Mods\`, `Mods\mods.txt`. Confidence: CONFIRMED-PRIMARY (release notes) plus RSE-Server.

### B3. Settings for headless
From RSE-Server (single functional source) and the UE4SS default ini:
```
[Debug]
ConsoleEnabled = 0
GuiConsoleEnabled = 0
GuiConsoleVisible = 0
```
Also consider: `[General] EnableHotReloadSystem = 0`; keep `bUseUObjectArrayCache = true` unless startup crashes; leave `[CrashDump]` on. If startup crashes, try `bUseUObjectArrayCache = 0`. Success marker: `UE4SS.log` in `ue4ss\` contains `UE4SS enabled (as version.dll)`. Confidence: SINGLE for the 0/0 values; the key names come from the primary default ini (summarised by fetch tool; check exact spelling in the shipped file).
- Known issues: on Wine a Palworld hosting crash was tied to the proxy DLL (RE-UE4SS issue 1189, snippet only); Windows-path crashes in similar setups. No Dragonwilds-specific crash reports found. RSE-Server notes `steamclient64.dll` / `tier0_s64.dll` / `vstdlib_s64.dll` may be needed only under Wine. Confidence: single.

### B4. Existing server-side Dragonwilds Lua mods (proof)
- **RSE-Transmog** (relays looks between players, runs on dedicated servers), **RSE-Fixes** (logs what the server sees under arriving players; building fall-through bug), **RSE-Toolbag** (server mode adds inventory slots to 162, polls every 30 s). All from RSE-Server README. https://github.com/kevinw9092/RSE-Server . Confidence: SINGLE source, but a detailed one. The README says joining players with Toolbag server mode were "untested".
- Nothing found touching chat, NPC spawning or AI. The Nexus Dragonwilds mod listing could not be fetched (403), so a manual Nexus browse by Luis could still turn up more. RSHC (character customisation) is client-side: https://www.curseforge.com/runescape-dragonwilds/ue4ss-mods/rshc

---

## C. Generating reflection dumps headlessly

- The hotkeys (Ctrl+H CXX headers, Ctrl+J object dump, Ctrl+Numpad9 UHT headers, Ctrl+Numpad6 usmap) live in `Mods/Keybinds/Scripts/main.lua` and require an input window; they will not work headless. Confidence: CONFIRMED-PRIMARY (https://docs.ue4ss.com/feature-overview/dumpers.html).
- **UE4SS exposes the dumpers as Lua global functions** (docs dev/5.3.x list): `DumpAllObjects()`, `GenerateSDK()` (CXX headers, to `CXXHeaderDump\`), `GenerateLuaTypes()` (to `Mods/shared/types`), `GenerateUHTCompatibleHeaders()`, `DumpStaticMeshes()`, `DumpAllActors()`, `DumpUSMAP()`, `DumpJMAP()`. The docs show only RegisterKeyBind examples, but the functions are plain calls. Confidence: CONFIRMED-PRIMARY that they exist in the dev docs; UNKNOWN that each works headless and that all exist in a given build (dev docs track experimental, so use experimental-latest). Sources: https://docs.ue4ss.com/dev/toc.html , https://docs.ue4ss.com/dev/lua-api/global-functions/generatesdk.html , .../dumpallobjects.html , .../generateluatypes.html
- Output locations: `UE4SS_ObjectDump.txt` and `CXXHeaderDump\` appear in the folder beside `UE4SS.dll` (i.e. `Win64\ue4ss\`); Lua types in `Mods\shared\types`. Confidence: docs for names, location by convention (verify).
- Suggested headless trigger (our mod, e.g. `Mods/dumper/scripts/main.lua`), after the world has loaded so classes are resident:
```lua
-- enable by creating a flag file, or just run once N seconds after start
ExecuteWithDelay(120000, function()
  ExecuteInGameThread(function()
    DumpAllObjects()
    GenerateSDK()
    GenerateLuaTypes()
    print("[dumper] done")
  end)
end)
```
  `ExecuteWithDelay`, `ExecuteInGameThread` and `LoopAsync` are listed in the docs; `LoopAsync` is deprecated in favour of `LoopInGameThreadWithDelay`. Keep `LoadAllAssetsBefore...` options off (they can use GBs of RAM and crash). Run the dump while no players are connected.
- Alternative: `RegisterConsoleCommandHandler` / `RegisterProcessConsoleExecPreHook` exist, but with no console on a headless server there is no way to type a command; a flag-file or timer trigger is better. The ue4ss-bridge project (F3 below) even offers a `dump` operation with a 600 s timeout. Confidence: SINGLE.
- Also do the client-side dump? Not needed; server dump is what we hook.

---

## D. Text chat

- **Yes.** Multiplayer has in-game text chat: Enter opens it, **public only**, 256 chars, alphanumeric only, spam throttle (3 messages, 5 s lockout), unavailable while resting, in build menu or in cutscenes; the game also posts join/leave/death system lines. Source: https://dragonwilds.runescape.wiki/w/Chat (page revision of 6 April 2026). Confidence: CONFIRMED-PRIMARY (official-wiki, read directly). Whether it still behaves like this at 1.0 is not separately confirmed.
- Class/function names: **none published anywhere I could find.** No mod reads Dragonwilds chat. Confidence: UNKNOWN. Approach: dump, grep for `Chat`, `Message`, `Say`; hook `Server*` RPCs; use `RegisterHook` on candidates with Luis typing a line. Fallback reading approach from other games: Palworld chat-bridge mods scan the server log for chat lines (CurseForge: palchatbridge-discord-linux); a Subnautica 2 chat mod hooks `ServerExecRPC` / `ClientMessage` (https://www.nexusmods.com/subnautica2/mods/153). Check whether `RSDragonwilds.log` already contains chat lines (cheap test, no hooking needed).
- Commands in the wild: no official slash commands, no RCON; sources say `/give`, `/teleport` are not official and arrive only through mods (SML console, UE4SS console). No Discord bot for Dragonwilds found. Sources: https://help.sparkedhost.com/en/article/all-runescape-dragonwilds-console-commands-1hxkam/ , https://www.survivalservers.com/wiki/RuneScape_Dragonwild_Server_Admin_Commands_Usage . Confidence: MULTI that no official command channel exists.
- Command-channel plan: (1) chat hook (`!ping`), (2) if chat is not hookable, emotes or a Discord bot feeding the file bridge. Decide after the dump.
- Sending chat from the server (companion speech) is also unknown; may require calling the same chat RPC with a fake sender or a system-message function. Flag for Phase 2/3.

---

## E. Bridge options (Lua mod to Python)

1. **Lua socket library**: Possible but not turnkey. MotorTownMods (UE4SS Lua, dedicated server) runs an HTTP server in Lua using **LuaSocket 3.1 for Lua 5.4** placed in `Mods/shared`, optional LuaSec for TLS, plus a C++ helper DLL. So LuaSocket loads in UE4SS's Lua 5.4. Repo was archived on 2 Aug 2026. It also used a custom UE4SS fork or upstream experimental. Confidence: CONFIRMED-PRIMARY (README read). Source: https://github.com/drpsyko101/MotorTownMods . Gotcha: LuaSocket and Lua 5.3/5.4 `receive` issue (use `"*l"`; the repo has `MOD_SERVER_SEND_PARTIAL` for older versions); non-blocking sockets must be polled from `LoopInGameThreadWithDelay` or similar, never blocking the game thread. The binary is a `.dll` on Windows and `.so` on Linux: the Lua script ports, the library binary needs a Linux build (unlike C++ UE4SS mods this is a routine build).
2. **UE4SS C++ mod with sockets**: possible (template: https://github.com/UE4SS-RE/UE4SSCPPTemplate , guide https://docs.ue4ss.com/guides/creating-a-c++-mod.html ; build needs VS 2022 / CMake or xmake, Rust nightly-ish toolchain per the UE4SS dev docs; use the template's `dev` branch with experimental). No Dragonwilds example found. Windows only; violates the Linux-portability rule in CLAUDE.md; v3.0.1 notes say C++ mods must be rebuilt per release. Not recommended.
3. **File-based JSONL polling**: UE4SS Lua is standard Lua 5.4, so `io.open` works (MotorTownMods and ue4ss-bridge rely on file IO; I did not find a doc page that lists the stdlib, so confirm with a one-line test). Prior art: ue4ss-bridge (littleRabbit94, PyPI `ue4ss-bridge`) polls `ue4ss\bridge\request.json` every **50 ms** (floor), executes on the game thread via `ExecuteInGameThread`, writes `response.json`; no sockets. Cautions from it: reading `SoftObjectProperty` has hard-crashed games; calling a hooked function from eval in the same session has crashed. Confidence: CONFIRMED-PRIMARY (README). Source: https://github.com/littleRabbit94/ue4ss-bridge , https://pypi.org/project/ue-bridge/
4. **HTTP/IPC helpers**: nothing built into UE4SS Lua (no networking API, no pipes). The docs index shows no socket or http page. Confidence: CONFIRMED-PRIMARY by absence in the TOC.

**Recommendation**: Start with **file-based JSONL** with an append-only design: mod to Python `mod_out.jsonl` (events, state snapshots) and Python to mod `mod_in.jsonl` (commands), each line with a monotonically increasing `seq`; the mod tracks the byte offset of the last line read and polls with `LoopInGameThreadWithDelay(100..250 ms)`; writes flushed per line. Append-only avoids the read/write race of ue4ss-bridge's single-file request/response, and the Python side tails with a normal file watcher. Latency budget 100 to 300 ms, fine for an event-driven LLM brain (Controller seconds). Portability: pure Lua + Python, works under native Linux UE4SS and Wine. Later, if lower latency is wanted, add LuaSocket (loopback TCP) behind the same message schema and keep the file transport as fallback. Rotate files on server start to avoid unbounded growth.

---

## F. Prior art

- **Dragonwilds companion/NPC/bot mods**: none found (searches of Nexus, hosts, GitHub). Confidence: UNKNOWN to weak (Nexus listing was 403).
- **UE4SS spawning**: `UWorld:SpawnActor(UClass, FVector, FRotator)` in UE4SS Lua; it wraps `UGameplayStatics:BeginDeferredActorSpawnFromClass` + `FinishSpawningActor` (https://docs.ue4ss.com/dev/lua-api/classes/uworld.html ; scale support PR https://github.com/UE4SS-RE/RE-UE4SS/pull/864). Confidence: CONFIRMED-PRIMARY. Generic approach for AI: spawn a pawn class, make sure it has an AIController (class default `AIControllerClass` plus `AutoPossessAI = PlacedInWorldOrSpawned`, or call `SpawnDefaultController()` on the pawn), then call `AAIController:MoveToLocation` / `MoveToActor` or `UAIBlueprintHelperLibrary:SimpleMoveToLocation`. MoveTo fails silently without a NavMesh covering the area or with a null controller; call Super::BeginPlay (Epic forum answers, not UE4SS-specific): https://forums.unrealengine.com/t/how-can-i-spawn-aicontroller-pawn-and-make-it-move/284432 , https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/AIModule/AAIController/MoveToActor?lang=en-US . No UE4SS Lua repo combining spawn + AIController + MoveTo was found. Confidence: UNKNOWN for the UE4SS-specific combination; the engine behaviours are MULTI.
- **Closest adjacent tooling**: ue4ss-bridge exposes `call_function`, `set_property`, `eval_lua`, `hook_function` against a live game (verified on UE 5.5.4 and 5.8), a good way to prototype calls interactively. MotorTownMods is a mature server-side Lua mod with an HTTP API (vehicle and player control on a dedicated server). RSE-Server shows what Dragonwilds server-side Lua can touch (player appearance relay, inventories).
- Because no Dragonwilds specifics exist, Phase 4 depends on reflection discovery from our own dump.

---

## Contradictions summary
1. UE4SS on Dragonwilds dedicated server: "does not work (Linux build)" (Mint, Flux, SurvivalServers) vs "works (Windows build)" (Shockbyte, LogicServers, RSE-Server). Resolved by build platform; our Windows install should work, but only RSE-Server (Wine) proves it end to end.
2. Proxy DLL: guides say `dwmapi.dll`; RSE-Server and another game's dedicated server say it must be `version.dll`.
3. Server save path: wiki says `%LOCALAPPDATA%` (looks like client), tcno/xgamingserver say `<install>\RSDragonwilds\Saved\SaveGames`.
4. Secondary port 7778 (wiki, hosts) vs beacon 8888 (Docker README, Linux).
5. OwnerId format: in-game Player ID vs SteamID64 vs EOS online ID. Also possibly becoming optional (April 2026, single source).
6. Dragonwilds UE version: 5.4 (one wiki infobox) vs unspecified elsewhere.
7. experimental-latest release date seen by the API (Dec 2024) vs the rolling nature of the tag; re-check the actual asset timestamp on download.

---

## Recommended actions for the main session

1. **Server first, no mods**: install via SteamCMD to `C:\GameServers\Dragonwilds`, create `RSDragonwilds\Saved\Config\WindowsServer\DedicatedServer.ini` with the section `[/Script/Dominion.DedicatedServerSettings]` and `OwnerId` (Luis's in-game Player ID), `ServerName`, `DefaultWorldName`, `AdminPassword`, `WorldPassword`. Start via `RSDragonwildsServer.exe -log -NewConsole`. Open UDP 7777 (and 7778). Confirm the real exe (`dir RSDragonwilds\Binaries\Win64\*Shipping.exe`), the log at `RSDragonwilds\Saved\Logs\RSDragonwilds.log`, and the save dir, and record them in DISCOVERIES.
2. **Run `steamcmd +login anonymous +app_info_print 4019830 +quit`** and note build ID and any beta branches (A4).
3. **Download UE4SS experimental-latest**: https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental-latest , asset `UE4SS_v*.zip` (not zDEV, not zCustomGameConfigs). Fallback to stable https://github.com/UE4SS-RE/RE-UE4SS/releases/download/v3.0.1/UE4SS_v3.0.1.zip only if experimental fails (v3.0.1 lacks UE 5.4+ support). Check the UE version in `UE4SS.log`.
4. **Extract** into `...\RSDragonwilds\Binaries\Win64\` (next to `RSDragonwildsServer-Win64-Shipping.exe`) with the server stopped. Rename the proxy: copy `dwmapi.dll` to **`version.dll`** (remove `dwmapi.dll` so only one proxy exists). Mods folder lowercase-friendly: `ue4ss\Mods\<modname>\scripts\main.lua` plus `ue4ss\Mods\mods.txt` entries (`modname : 1`) or `enabled.txt`.
5. **Edit `ue4ss\UE4SS-settings.ini`**: `ConsoleEnabled = 0`, `GuiConsoleEnabled = 0`, `GuiConsoleVisible = 0`, `EnableHotReloadSystem = 0`; leave the rest. Verify the exact key names in the shipped file.
6. **Verify load**: start the server, then look for `UE4SS enabled (as version.dll)` or the equivalent in `Win64\ue4ss\UE4SS.log` plus a hello-world mod printing to a file via `io.open`. If nothing loads, try `dwmapi.dll` as the proxy name once, then report with evidence (CLAUDE.md decision point). Back up the server folder before this step.
7. **Trigger dumps headlessly** with a dumper mod (snippet in section C): `ExecuteWithDelay` 2 minutes after start, `ExecuteInGameThread(DumpAllObjects; GenerateSDK; GenerateLuaTypes)`, no players connected, flag-file gated. Outputs: `ue4ss\UE4SS_ObjectDump.txt`, `ue4ss\CXXHeaderDump\`, `ue4ss\Mods\shared\types\`. Verify with grep for `Chat`, `AIController`, `MoveTo`, `Inventory`.
8. **Chat**: first grep `RSDragonwilds.log` for chat lines after Luis types a message; then grep the dump for chat classes and `RegisterHook` the candidates (Phase 2 gate). If nothing works, propose emote or Discord-bot channel to Luis.
9. **Bridge**: implement append-only JSONL files (section E) with a 100 to 250 ms `LoopInGameThreadWithDelay`; defer LuaSocket. Do not build a C++ mod.
10. **Ask Luis (optional, cheap)** to browse the Nexus Dragonwilds mod list and Shockbyte article in a browser, since the fetch tool got 403 there: look for "UE4SS Signatures", chat/NPC mods, and the exact UE4SS build recommended for Dragonwilds.
