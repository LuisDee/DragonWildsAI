# Driving a real game client programmatically: precedents and decisions (2026-10-25)

Context: route R2 (docs/design/real-player-remediation.md). Claude now plays through his own real
client: headless, with UE4SS and the DWClient mod. This note records what established bot frameworks
do on the *client/input* side, and what we adopt.

## Precedents

| Project | How actions reach the game | Navigation | Perception | Source |
|---|---|---|---|---|
| **Mineflayer** (Minecraft; used by Voyager and Mindcraft) | A high-level JS API (dig, place, equip, attack, craft) over a real client protocol connection. AI acts through code, not pixels. | mineflayer-pathfinder (its own A* over world blocks, with goals) | world/entity state from the protocol | https://80.lv/articles/voyager-gpt-4-powered-lifelong-learning-agent-for-minecraft/ ; https://sites.uci.edu/kolbynottingham/2024/10/30/mindcraft |
| **Mindcraft** | The LLM emits **parameterised commands** (`!collectBlocks("oak_log", 1)`), which became more reliable than generated code. A code-gen path is kept for novel tasks. The loop runs per chat message. | via Mineflayer | text summaries | same |
| **Voyager** | The LLM writes programs against the API, with game feedback and errors fed back. Verified programs go into a **skill library** (vector-retrieved) and compose. | via Mineflayer | text | same |
| **Microbot** (OSRS, a RuneLite fork) | An always-on plugin inside the *real client*. Helper classes (`Rs2Player`, `Rs2Npc`, …) expose every client object, with queryable entity caches (`api/QUERYABLE_API.md`). There is an **agent server** for driving a running client (`agentserver/`, `docs/MICROBOT_CLI.md`). | (walker docs not retrieved) | in-client caches | https://github.com/chsami/Microbot |
| **RuneLite-based CV bot** | A custom plugin exposes game state over a local HTTP server to Python scripts. | — | plugin server | https://github.com/jacobbrown0192/OSRS-Computer-Vision-Bot |
| **WoW "Bloog Bot"** | Hooks into the client. Moves with the game's **click-to-move**, recalculating the path to the target **every update** (25 ms loop). | **Recast/Detour navmesh generated offline** from the game's static terrain (MaNGOS extractors → `.mmap/.mmtile`), loaded by a native DLL. No explicit stuck handling. | memory reads | https://drewkestell.us/Article/6/Chapter/20 |
| Recast/Detour in general | — | The standard toolset. Meshes can be built offline from static colliders. **Off-mesh links** model jumps, ledge drops and ladders. TileCache handles dynamic obstacles. | — | https://www.npmjs.com/package/recast-navigation ; https://docs.recast-navigation-js.isaacmason.com/ |
| UE client navigation | `bAllowClientSideNavigation` exists, but UE4-era threads report it broken (UE-24188) and **SimpleMoveToLocation unsupported on clients**. The usual pattern is pathfinding on the server, results sent to the client. | — | — | https://issues.unrealengine.com/issue/UE-24188 ; https://forums.unrealengine.com/t/how-can-i-use-navmeshes-with-clients/299929 |
| UE4SS client mods | Only single-player auto-walk and walk-speed toggles were found. No UE4SS multiplayer client-bot precedent. | — | — | https://www.nexusmods.com/hogwartslegacy/mods/765 |
| LLM game agents (research) | API-mediated agents beat pixel agents on reliability, but need engineered interfaces (SAG-Agent critique). Pixel agents are seconds per step. | — | — | https://arxiv.org/pdf/2510.15259 ; https://arxiv.org/html/2503.13356v1 |

Verified ourselves (DISCOVERIES):
- On Claude's headless client there is **no NavigationSystem**, so `SimpleMoveToLocation` does nothing.
- `AddMovementInput` **every frame** walks correctly. A 50 ms cadence jitters on the spot.
- `Jump()` works.

## Decisions

1. **Shape = Microbot/Mineflayer.** DWClient grows into a **client-side game API**:
   - queryable entities: players, creatures, resources, items;
   - inventory and loadout;
   - interact, input, walker;
   - plus an **agent server**, which is our JSONL bridge, extended to the client.

   The brain keeps Mindcraft-style **parameterised tools** plus the Voyager-style skill library it already has. Nothing in the brain's design changes; only the body moves to the client.
2. **Actions go through the game's own client paths, highest level first:**
   1. UI/interaction handlers the buttons call (proven on the menus);
   2. Enhanced Input injection of the game's own actions (`IA_Player_Jump`, `IA_Player_Sprint`, attack/interact actions) via `InjectInputForAction`;
   3. engine character calls the input handlers make (`AddMovementInput`, `Jump`).

   Never call server RPCs directly from the client, and never emulate an outcome.
3. **Navigation:**
   - **Now:** use our **dev server (same map) as a path oracle**. Its navmesh answers `FindPathToLocationSynchronously` and returns waypoints, and the client steers along them every frame. This is "pathfinding on the server", the usual UE pattern, as offline data.
   - **Later:** export the navmesh tiles once per patch and run Detour locally (the Bloog-bot model), so play on Shockbyte doesn't depend on the dev server being up.
   - Repath every update toward moving targets.
   - Add what Bloog bot lacks: **stuck detection**, then jump, then double jump, then Windstep, then repath.
   - Model known jump/Windstep spots as **off-mesh links**.
   - Player-built structures aren't in the dev navmesh, so local avoidance plus unstuck covers them.
4. **Two speeds stay:** per-frame loops (steering, combat reflexes) run in the client mod; the LLM chooses and parameterises skills.
5. **Perception** is what replicates to Claude's client (net relevancy, nearby), queried like Microbot's caches.

## Not yet researched / open

- Microbot `docs/ARCHITECTURE.md`, `AGENTS.md` and `MICROBOT_CLI.md`: `AGENT_SERVER.md` was read (see the decision below); the rest are still unread.
- Whether UE4SS can call `InjectInputForAction` (`FInputActionValue` marshalling; R15 struct-in-table bug). Test offline on the dev server first.
- Whether `bAllowClientSideNavigation` plus cooked navmesh data works in UE 5.6 with World Partition on the client: one cheap test before building the exporter.

### Decision: the client's agent server = our JSONL bridge, reused (2026-10-25)
- **Need:** the brain must drive the real client body over the protocol it already speaks (BRIDGE_PROTOCOL.md v1), with client modules that hot-reload.
- **Searched:**
  - Microbot's agent server docs (`docs/AGENT_SERVER.md`, fetched from GitHub raw), plus mirrors for `MICROBOT_CLI.md`;
  - "UE4SS Lua hot reload module loadfile";
  - the UE4SS Lua mod guide;
  - Lua module hot-reload patterns (Defold, LuaRocks `hotfix`);
  - the repo's own `mod/scripts/bridge.lua`, whose prior-art header covers ue4ss-bridge and MotorTownMods.
- **Found:**
  - **Microbot** serves HTTP on localhost with GET for state and POST for actions. Every game read or write runs on the client thread. A long walk is non-blocking with `wait`/`timeout`, and `/observe` returns event streams with cursors. Our protocol already has the same shape: actions on the game thread, async results with ids, and an event stream. UE4SS Lua has no sockets, and the JSONL bridge is proven, so we keep JSONL rather than adopting HTTP.
  - **UE4SS hot reload:**
    - Built in, it is a whole-mod restart (a hotkey or the GUI), which is unusable headless.
    - Nexus "Lua Mod Reloader" (single-mod reinstall) is manual.
    - The general Lua idiom is to drop `package.loaded` and `require` again, keeping state elsewhere. We use `loadfile`/`load` with a content check and keep state in `_G`, as chat/move already do.
- **Decision:** reuse + adapt.
  - The client loads the server's `bridge.lua` unchanged. Its tail was made reusable (`new_tail`, per-instance file names).
  - On top sits a thin dispatcher (`client_bridge.lua`) with the server body's action-slot semantics (pre-empt, interrupted, `task_done`/`task_failed`), plus waiters for client-side confirmation.
  - Nothing was vendored and no new protocol was introduced.
- **Sources:** https://raw.githubusercontent.com/chsami/Microbot/main/docs/AGENT_SERVER.md ; https://tomevault.io/tome/chsami/Microbot ; https://docs.ue4ss.com/guides/creating-a-lua-mod.html ; https://www.nexusmods.com/windrose/mods/520 ; https://defold.com/manuals/modules ; https://luarocks.org/modules/jinq0123/hotfix

## Addendum: how working agent systems do pathfinding (2026-10-25 evening)
- **No shipping system uses the LLM for path-level navigation.** The LLM picks the goal, and a deterministic planner moves the body.
  - PUBG Ally: an SLM for intent, plus a separate fast gameplay layer that handles "route navigation". Cloud LLM latency was too slow even for squad chat. Sources: https://developer.nvidia.com/blog/how-krafton-built-pubg-ally-a-co-playable-character-powered-by-nvidia-ace/ ; https://labs.invenglobal.com/articles/22889/nvidia-announces-pubg-l-ai-support-at-unreal-fest ; https://www.invenglobal.com/articles/22987/ai-pubg-teammate-raised-through-tens-of-thousands-of-matches-at-internet-cafes-krafton-reveals-development-story
- **Minecraft agents (Voyager/Mindcraft) call mineflayer-pathfinder.** It is A* over the bot's *own perceived world* (blocks), with per-move costs and toggleable movements (sprint, parkour, dig/place). It re-plans when the world changes, and its goals (GoalNear, composite) are modelled on Baritone. https://npmjs.org/package/mineflayer-pathfinder
- **Baritone:** A* in **segments** (the world beyond render distance is unknown), so it plans to the edge of known space, executes, and pre-plans the next segment. Its cost model includes hazards (lava, fire, magma) and **parkour moves** (sprint-jump 1-3 block gaps, place-a-block mid-jump). https://raw.githubusercontent.com/cabaletta/baritone/1.19.4/FEATURES.md
- **LLMs are weak at grid pathfinding:**
  - SPaRC: o4-mini solves 15.8% (1.1% on hard) versus 98% for humans, and often outputs invalid paths.
  - PPNL and others: performance degrades with grid size.
  - So the LLM belongs at strategy level (where to go; what to try when stuck), not at cell level.
  - Sources: https://arxiv.org/pdf/2505.16686v2 ; https://arxiv.org/html/2310.03249v3
- **Implication for Claude:** his client sees the real collision through physics traces. So build a Baritone-style local A* over a trace-sampled grid around him, with movement costs and parkour moves from the measured envelope, planned in segments toward a far goal from the nav oracle. The LLM is consulted only when the planner reports failure, with a compact text map to choose a strategy (try another approach, ask Luis, wait).
