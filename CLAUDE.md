# Dragonwilds AI Companion — Project Brief

Read this whole file before doing anything. It is the single source of truth for goal, constraints, architecture, phase gates and prior research. Items marked **[UNVERIFIED]** are assumptions from research that you must confirm before relying on them. **Section 0 overrides anything older below it.**

---

## 0. Current state and standing decisions (updated 2026-10-25, end of session 1)

**Read next:**
- `docs/ARCHITECTURE.md`: layers, module APIs, rules, the "how to add X" recipes and the crash risk register.
- `docs/DISCOVERIES.md`: everything verified, with build ID and evidence.
- `docs/design/robustness-and-item-catalog.md`: the design decisions and Luis's requirements, sections 1–14.
- `docs/PROGRESS.md`, `docs/tasks.json`.
- `docs/research/*`.

### The goal, clarified by Luis
The companion ("Claude") is a **humanoid that is basically another player**.
- It equips armour and weapons, uses combos, specials and **all spells**, kills enemies, loots, gathers (woodcutting, mining …), picks up, drops and gives items, teleports via lodestones, and talks in chat.
- It **only equips what is in its own inventory**, and items are **instances** (level, ascension, enchants), not bare types.
- A following creature is not the goal.
- Voice via Discord comes later (`docs/research/2026-10-25-voice-discord.md`).

### What is proven (build 26161880; details in DISCOVERIES)
- **Server and loader:** the dedicated server on this VM; Luis joins from GFN; UE4SS loads via **Ultimate ASI Loader** (`version.dll` plus `version.ini`). UE4SS's own dwmapi proxy hangs the server.
- **Mod and brain link:** a hot-reload `debug_run` trigger; a JSONL bridge (about 170 ms round trip); in-game chat is readable.
- **Body = route 1:** a server-spawned `BP_PlayerCharacter_C` possessed by an AIController. It walks via navmesh, wears and holds real gear (exact held-actor class required, with no generic fallback), chains each weapon's own combo, kills creatures, and is immortal. It has a `DominionPlayerState` whose `OwnerGuid.AccountGuid` is copied from the host, so the **nameplate reads "Claude"**.
- **Speech:** works as "Claude" by relaying a genuine chat message; on-demand speech is in progress.
- **Brain:** live on Claude Haiku 5.5 (Controller) and Sonnet 5.5 (Planner) via LiteLLM. Phase gates 1, 2 and 6 passed, and Phase 4 by its original wording.
- **Ops and diagnostics:** watchdog (crash dump or stale heartbeat → restart); perf telemetry (the server is healthy: 29.8 Hz, about 45 ms ping); patch delta pipeline (`docs/RUNBOOK-patch.md`).
- **Server setting:** push-model replication is OFF (`Engine.ini`), so Lua property writes replicate.

### Overrides of the rules below (Luis's explicit decisions)
- **Subagents and parallel work are approved and expected.** This overrides section 2's "one session" rule. Give each agent its own files, and keep commits in the main session.
- **Native diagnostics are approved:** ProcDump/cdb stacks and dump analysis. Still ask before patching binaries or memory.
- Restarts while Luis is connected are fine, **announced first**. Agents may test live freely, but must never touch Luis's own character, inventory or saves.
- Model API spend is approved for live play (key in the user env var `ANTHROPIC_API_KEY`, never in files). Still state the call counts before batch eval runs.

### Route R2 decisions (Luis, 2026-10-25 evening) — override older text below
- **Claude is a real game client**: headless Dragonwilds client on this VM, Steam account `bootymaxer` (persona "Claude"), UE4SS + `client_mod/` (DWClient). No emulation of player systems; use the game's own client paths (UI handlers, Enhanced Input actions, character input calls). Design: `docs/design/real-player-remediation.md`; research: `docs/research/2026-10-25-client-side-botting.md`; architecture section 8.
- **Target world is the group's Shockbyte server** (Luis's explicit choice; overrides "throwaway world only" for the client). The server stays vanilla: nothing is installed server-side. Keep risky experiments short; never touch other players' characters.
- **The local dev server is retired** (stopped with `stop_server.ps1 -Hold`; watchdog and nav oracle stopped). The server-side puppet mod (`mod/`) is legacy, to be deleted skill by skill as client replacements are verified.
- Boot Claude's client with **`tools/client_boot.ps1`** (idempotent boot_and_join: launch headless → pick_char/sign-in → `join_server.lua` (secrets in gitignored `client_io/secrets/server.txt`) → skip_intro if needed → pawn → chat/vitals/fed-reflex services; `-DryRun` to only look; honours `logs/client.hold`, `-Release` clears it). Supervision: `tools/start_client_watchdog.ps1`; after patches `tools/client_smoke.ps1` (RUNBOOK-patch.md §10). Brain: `tools/start_brain.ps1 -Body client` with `DW_PLAYER_NAME=Zezima`, `DW_WORLD_GUID=shockbyte`.
- **Communication is paramount** (Luis): Claude always tells the player what he is doing, what he can't do and *why* (e.g. "can't get in there, you Windstepped over and I can't yet"). Every skill/movement failure must surface a specific, truthful reason to the brain so it can say it in chat; follow never silently ends.
- **No phrase→skill mappings** (Luis): the brain must infer intent from a truthful tool list (generated from the body's capabilities), honest perception (incl. own gravestone, nearby items) and recent context (deaths, task, last chat). Fix those, never add keyword tables, and never let code veto or rewrite the model's decisions (code informs, reports outcomes, and enforces only Luis's safety rules). Validate with small real-model evals.
- **Client freeze fix (keep!):** Claude's headless client deadlocks in Dominion's LightFlickeringWorldSubSystem tick when frames are tiny. Keep `client_mod/scripts/tickguard.lua` (bridge service; TickInterval→3600) and the 30 fps cap (GameUserSettings.ini GameFrameRateLimit/FrontendFrameRateLimit/FrameRateLimit=30; runtime `fps_cap.lua`). Watchdog: `tools/start_client_watchdog.ps1`. DISCOVERIES "Client hang (R2)".
- **Shared stations/items** (Luis): Claude may use any shared station, furnace, fuel or item in the world; he must report what he used or collected.
- Claude has real survival needs (hydration/sustenance kill at 0); the stay-fed reflex must be running.

### Building principles (Luis's, binding)
1. **Don't hand-roll** what an open-source or managed tool already does, and **web-search before building**. That includes ops plumbing (e.g. service supervision: NSSM/WinSW). Follow the project skill **`search-before-building`** (`.claude/skills/search-before-building/SKILL.md`), and paste its subagent-brief paragraph into every build brief.
2. **Every capability leaves reusable foundations:**
   - shared services: `sense` (census), `watch` (state watcher), `hitcheck`, tool/weapon chains, collect+verify;
   - **data profiles**: items, spells, enemies, resources.
   - So the next capability is faster. "Add mining" should be mostly a profile.
   - Run `/simplify` after each wave and keep the ARCHITECTURE.md recipes current. The end state is that the brain can draft a profile for an unknown thing from watch data.
3. **Persist everything learned** (DISCOVERIES, design doc, research) so nothing is lost to context compaction.
4. **Safety rules learned the hard way** (see the ARCHITECTURE.md risk register):
   - `pcall` can't catch native crashes, so test risky calls offline first.
   - **Never send hand-built structs in Client_* RPCs** (that froze Luis's client).
   - Removing the puppet requires stripping `PlayerRangedAttackComponent` first (otherwise the unpossess crash).
   - Prefer property reads and copies of live engine structs over building structs in Lua.

---

## 1. Goal

Build an LLM-driven companion that plays **RuneScape: Dragonwilds** alongside Luis like another player:

- **Co-play in real time:** follows him, fights alongside him, joins in with what he is doing (gathering, building), chats naturally.
- **Autonomous multi-step tasks:** can be sent off on long jobs ("gather materials and build a storage hut by the lake") and complete them, replanning when steps fail and asking for help when stuck.

### Hard constraints

- **Server-side only.** Luis plays on a Mac via **GeForce Now (GFN)**, which cannot run client mods. Everything must work with **vanilla clients**: no custom meshes, items, UI or data changes that clients would need to know about. The companion must use existing classes and existing game actions so it replicates to clients like any other character.
- **Throwaway world only.** Never touch the group's real world (hosted on Shockbyte). Use a dedicated dev world on this VM. Crashes and half-working mods can corrupt saves.
- **Dragonwilds only.** No Minecraft prototype. Use the mock game (Track M) to develop the brain before the real body exists.

---

## 2. Operating rules for Claude Code

### Session and token budget

- **One interactive Claude Code session. Do not spawn subagents, parallel sessions, or run `claude -p` in a loop.** If you believe fan-out would genuinely help, stop and ask Luis first, stating the number of sessions, the model, and estimated tokens, and wait for explicit approval.
- **Model API spend** (brain evals, live game loop): before any batch run, state the number of API calls and the model, and keep eval sets small. The live loop must be event-driven, never on a fast timer.

### Working with Luis

- You cannot see or play the game. **Luis is your eyes and hands.** When you need an in-game action (pick up an item, craft, place a block, chat a command), ask him to do it in a single clear instruction, then read the result from **log files**. Never ask him to paste logs; write hooks to log to files you can read.
- When asking Luis to verify something visual ("did the companion appear and walk to you?"), ask a yes/no question plus anything odd he noticed.

### Engineering discipline

- **Phase gates are hard.** Each phase ends with a go/no-go test (section 6). Do not start a later phase on a failed gate; report to Luis with evidence and options.
- **Record every discovery** in `docs/DISCOVERIES.md`: class, function or property, parameters, what it does, how it was verified, and the game/server build ID.
- **Progress continuity lives in files, not context:**
  - `docs/PROGRESS.md`: append-only log of what was done, what was learned, what is next.
  - `docs/tasks.json`: task list with `status` and `passes_test` booleans. Keep it JSON and do not restructure the format; only flip flags or append tasks.
  - At the start of every session: read this file, then `docs/PROGRESS.md`, then `docs/tasks.json`.
- **Prefer Unreal's reflected API** (UClass/UFunction/UProperty, visible through UE4SS). **Stop and consult Luis before any native disassembly** (Ghidra/IDA). If something essential is not reflected, that is a decision point, not a rabbit hole.
- **Commit to git** after every meaningful step. Never commit API keys; use environment variables.
- **Game patches:** GFN auto-updates Luis's client, and server and client versions must match. After any patch: update the server via SteamCMD, record the new build ID, and run the smoke tests (section 8) before other work.

---

## 3. Environment

### VM

- Windows Server 2022/2025, 2–4 vCPU, 8 GB RAM, ~80 GB disk, no GPU, UK/West Europe region.
- Firewall: inbound **UDP 7777** open (game); **TCP 22/3389** restricted to Luis's IP; outbound HTTPS allowed.
- Installed: OpenSSH Server, **Git for Windows** (Claude Code uses Git Bash for its shell tool), Python 3, Claude Code.
- Windows Update: configured so it does not auto-reboot during active hours.
- **This VM's actual state** (what is installed, how it is locked down, how Luis's Mac reaches it): see `SERVER-SETUP.md` beside this file. Where it differs from the list above, it is the truth.

### Dedicated server

- Free Steam tool, **App ID 4019830**, installable via SteamCMD with **anonymous login**:
  `steamcmd +force_install_dir C:\GameServers\Dragonwilds +login anonymous +app_update 4019830 validate +quit`
- Launch (from a community guide, **[UNVERIFIED]**): `RSDragonwildsServer.exe -log -NewConsole`
- RAM guidance: ~2 GB base + 1 GB per player.
- Default port UDP 7777; a second instance on the same machine uses 7778.
- Dedicated servers support **vanilla (secure)** and **moddable** modes. Use moddable. Where this is set is **[UNVERIFIED]**; find it in the server config.
- World saves and character data are stored separately. Locate the server's save directory and document it.

### UE4SS

- Get it from the official UE4SS GitHub releases (Windows build). It is the standard Unreal mod loader: Lua scripting, reflection dumps (C++ headers / Lua type stubs), object finding, UFunction calling and hooking.
- Installing into the **dedicated server** binary directory (likely the `Win64` folder beside the server executable) is **[UNVERIFIED]**. Confirm the correct location and the loader method that works for the server binary.
- Shockbyte's modded server type runs a Windows build with UE4SS, which suggests UE4SS works on the dedicated server, but confirm it here.
- The Live View GUI is not usable on a headless server. Rely on dumps, Lua hooks and file logging.

### Linux portability (the server may later move to Linux, natively or under Wine)

Source: CurseForge.

- **Match Linux conventions from the start.** The native Linux UE4SS port requires the mod folder to be called `scripts` in lowercase, because Linux filenames are case-sensitive. Use lowercase now and avoid hard-coded Windows paths, so moving over is mostly a copy.
- **Keep C++ mods separate from Lua mods.** The native port cannot load Windows `.dll` files. Lua mods move over directly. Any C++ mods will either need Linux builds or keep the server on Wine. This affects the Phase 5 bridge: a UE4SS C++ socket mod would be Windows-only.

### Model API

- Provider and model are undecided. The brain must call models through a thin adapter (`brain/llm.py`) so the provider can be swapped (Anthropic, xAI, etc.).
- Use a **fast, cheap model for the Controller** and a **stronger model for the Planner**. API key comes from an environment variable.

---

## 4. Architecture

```
GFN clients (vanilla, Luis + friends)
        ⇅  UDP 7777
Dedicated server (Windows VM)
  └─ UE4SS Lua mod  ── BODY (game-tick speed, no LLM in the loop)
       • primitives: move_to, follow, attack, gather, craft, place, give, say
       • always-on reflexes: follow at distance, self-defence, loot pickup, unstuck
       • state exporter: position, health, inventory, nearby entities/resources, players
       • event emitter: task_done / task_failed(reason), attacked, command_received
        ⇅  BRIDGE (localhost socket, or file-based JSONL fallback)
Python agent ── BRAIN (event-driven)
  • Controller  (fast model): interprets chat/commands, decides interrupts,
                 owns ALL speech (single voice so words match actions),
                 idle "join in" tick when near Luis
  • Planner     (strong model): goal → JSON task list using ONLY registered skills;
                 on failure: describe what happened → explain the cause → replan
  • Executor    (deterministic code): runs tasks one at a time, verifies each step
                 against fresh game state, retries with a hard cap, reports
  • Shared state store: current task tree (JSON, done flags), progress log,
                 notes.json (places, preferences), skill registry
```

### Design principles (all derived from prior art, section 10)

1. **Two speeds.** The LLM never acts at tick speed. It chooses and parameterises hand-written skills; the mod executes them.
2. **Verified state only.** A step is done only when the game state confirms it (inventory changed, arrived within range, target dead). The model's own claims never become state.
3. **Skills are code.** Each reverse-engineered action becomes a tested skill function. Complex skills compose simpler verified ones. Add one skill at a time.
4. **Bounded context per call.** Each call contains: persona and rules, tool definitions, notes, current goal and progress, fresh game state, and the last N events. No raw transcript of the whole session. Long-term facts go into `notes.json` via a `remember()` tool.
5. **Continuity in files.** Task tree with done flags plus a progress log, so the agent survives restarts and context resets.
6. **Single voice.** Only the Controller produces speech, after the action decision is made, to avoid saying one thing while doing another.
7. **Abstract interface.** The brain talks to `GameInterface`. The mock game and the real bridge both implement it and are interchangeable.
8. **Fail loudly.** When retries are exhausted, the companion says it is stuck and why, and asks Luis for help, rather than looping.

---

## 5. Tool interface (v0, extend as skills are verified)

Define in `brain/interface.py`. Every action returns `{"ok": bool, "reason": str | None, "data": dict}`.

| Tool | Purpose |
|---|---|
| `get_state()` | position, health, inventory, nearby entities/resources/players |
| `follow(player, distance)` | continuous follow until stopped or interrupted |
| `stop()` | cancel the current action |
| `go_to(target)` | target is coordinates, a named place from notes, or an entity |
| `attack(target)` | engage a target (reflexes keep fighting until it is resolved) |
| `gather(resource, count)` | harvest until count reached or failure |
| `craft(item, count)` | craft using available materials and stations |
| `place(blueprint, location)` | build from a saved blueprint (later phase) |
| `give(player, item, count)` | hand items to a player |
| `say(text)` | chat output (Controller only) |
| `remember(key, value)` | write to notes.json |

Events from body to brain: `command_received(player, text)`, `task_done(task_id, data)`, `task_failed(task_id, reason)`, `attacked(by)`, `player_nearby_activity(player, activity)`.

---

## 6. Phases and go/no-go gates (in dependency order)

The riskiest test (body) runs as early as possible. Track M runs in parallel from the start.

### Phase 1 — Environment
- Install SteamCMD and the server, create a throwaway world, start the server.
- **Gate:** Luis joins the world from GFN. This also confirms GFN can reach a self-hosted server **[UNVERIFIED until this passes]**.

### Phase 2 — UE4SS on the server
- Install UE4SS for the server binary, generate the reflection dump, write a minimal Lua mod.
- **Gate:**
  - The mod writes to a log file at server start.
  - The dump is generated and searchable.
  - A `RegisterHook` logs function calls and parameters when Luis picks up an item.
- **Also answer:** does Dragonwilds have **text chat**, and can the mod receive chat messages? If not, agree an alternative command channel with Luis (for example a Discord bot feeding the bridge) before Phase 5.

### Phase 4 — Body (MAKE-OR-BREAK; run before Phase 3)
- Spawn a character on the server and drive it with Unreal AI movement (AIController + navmesh `MoveTo`).
- Attempt in order: (a) player character class possessed by an AIController; (b) an existing NPC/creature class.
- **Gate:** the companion appears on Luis's GFN client, walks to him, and is still visible and consistent after he leaves and rejoins.
- **Kill criterion:** if neither (a) nor (b) can be spawned, possessed, moved and replicated, **stop and report to Luis** with evidence. The only remaining fallback (a second full game client on a GPU VM with its own licence) is Luis's call.

### Phase 3 — Control
- **Gate:** a trigger (chat or debug) makes the server teleport Luis or give him an item. This proves you can call gameplay functions with correct parameters and authority.

### Phase 5 — Bridge
- Mod ⇄ Python over localhost. Try sockets first (UE4SS Lua has no networking built in **[UNVERIFIED]**; options are a UE4SS C++ mod, which needs Visual Studio Build Tools, or a Lua socket library). Fall back to file-based JSONL message passing, which is guaranteed to work.
- **Gate:** `!ping` in game reaches Python, and the reply appears in game. Measure round-trip latency and record it.

### Phase 6 — Brain on the real body
- Swap the mock for the real bridge.
- **Gate:** natural-language "follow me", "wait here", "come here", "kill that wolf" and "stop" all work correctly from chat or the agreed channel.

### Phase 7 — Skills, one at a time
For each skill (order: gather → give → craft → place/build):
1. **Discover:** hook candidate functions, ask Luis to perform the action, read the logs, identify the authoritative server-side calls (look for `Server*` RPCs and inventory/crafting components).
2. **Implement** the skill as a Lua state machine with explicit success and failure conditions checked from game state.
3. **Test** via a debug trigger that bypasses the LLM; assert the verified outcome.
4. **Register** the skill in the tool interface and skill registry, and record it in DISCOVERIES.
- Building is expected to be hardest (placement validation). Blueprints are saved as relative coordinate lists.

### Phase 8 — Autonomy
- Planner, executor, replanning, and the idle "join in" behaviour on the real game.
- **Gate:** a multi-step task (for example "gather 20 logs and 10 stone, then bring them to me") completes end to end. When a step is made to fail deliberately, the agent replans or asks for help.

### Track M — Mock game and brain (parallel from day one)
- `brain/mock/`: a small Python simulation implementing `GameInterface`, with positions, inventory, resources, hostile mobs, and scriptable failures (path blocked, nothing in range, interrupted).
- Build the Controller, Planner, Executor and state store against it.
- **Gate:** the scripted scenarios in section 8 pass on the mock.

---

## 7. Reverse-engineering method

- Unreal's reflection system exposes Blueprint-visible classes, functions and properties with real names at runtime. Most of the work is detective work over named APIs, not reading assembly.
- Workflow: **dump → grep → hypothesise → hook → act (Luis) → read log → call from Lua → verify → record.**
- Useful grep targets in the dump: `Inventory`, `Item`, `Craft`, `Recipe`, `Build`, `Placement`, `Character`, `Pawn`, `AIController`, `Navigation`, `MoveTo`, `Chat`, `Message`, `Damage`, `Harvest`, `Gather`, `Spawn`.
- **Server-side hooks capture the authoritative versions of actions Luis performs from GFN.** These are exactly the calls the companion needs to make.
- Expect crashes from wrong parameters. Restart the server, check logs, adjust.
- Reflected names survive patches better than memory offsets. Never rely on offsets.

---

## 8. Testing strategy

| Layer | How it is tested | Needs Luis? |
|---|---|---|
| Body skills | Debug trigger calls the skill directly (no LLM); assert on game state read back through the mod | Only to confirm visuals |
| Bridge | `!ping` round trip; malformed-message handling; reconnect after server restart | For the in-game step |
| Brain: Controller | `evals/controller_cases.jsonl` holds (utterance, state) → expected tool call(s). Run offline against the model and report pass rate | No |
| Brain: Planner | `evals/planner_cases.jsonl` holds goal + state → plan must use only registered skills, in a valid order, with preconditions met | No |
| Executor / integration | Scripted mock scenarios: happy path, path blocked, resource missing, interrupted by Luis, mid-task attack; assert retries cap, replans, asks for help | No |
| Smoke (after patches) | Server starts, mod loads, companion spawns and follows, one gather, `!ping` | Yes, briefly |

- Keep eval sets small; state call count and model before each run.
- Log every event, prompt, tool call and result as JSONL in `logs/` so sessions can be replayed and debugged.

---

## 9. Known risks and unknowns

1. **Possession/replication of a server-spawned character** (Phase 4). The make-or-break risk.
2. **Text chat may not exist** (Phase 2), which would require an alternative command channel.
3. **Bridge networking from UE4SS** (Phase 5). File-based fallback exists.
4. **Building placement validation** may be hard to satisfy programmatically.
5. **Game patches** may rename or restructure classes; smoke tests catch this.
6. **GFN reaching a self-hosted server** (Phase 1).
7. **Collaboration quality ceiling:** even with mature tooling, current LLM agents are imperfect collaborators (see MineCollab). Expect a capable but imperfect teammate.
8. **Autonomy grows only as fast as skill coverage.** The planner can only plan with verified skills.

---

## 10. Prior art (research summary and why it shapes the design)

- **PUBG Ally (KRAFTON + NVIDIA ACE, shipped beta 2026):** a co-playable AI teammate. An event-driven language-model layer receives player speech and selected game events, over a separate fast gameplay layer, because LLM deliberation cannot run at game-tick speed. Uses a 2B on-device model and a prompt structure designed for KV-cache reuse. Beta players reported hesitation, delayed prompts, unfinished tasks and inconsistent memory, which are the failure modes to design against.
  https://developer.nvidia.com/blog/how-krafton-built-pubg-ally-a-co-playable-character-powered-by-nvidia-ace/ · https://www.alphaxiv.org/abs/2609.29837
- **Project Sid / PIANO (Altera):** concurrent modules (cognition, planning, motor, speech) run at different speeds and read/write a shared agent state. A cognitive controller acts as an information bottleneck so speech and actions stay coherent. Documented failures: agents get stuck in repetitive loops or accumulate cascading hallucination errors. → design principles 1, 6, 8.
  https://arxiv.org/abs/2411.00114
- **GITM (Ghost in the Minecraft):** LLM Decomposer → Planner → Interface. The LLM sets parameters for hand-written script interfaces rather than controlling directly, and successful action lists are summarised into text memory. First agent to unlock the full Minecraft overworld tech tree. → principles 1, 3.
  https://github.com/opengvlab/gitm
- **DEPS (Describe, Explain, Plan, Select):** describe the plan's execution, explain the cause of a failure, then refine the plan. → Planner replanning.
  https://arxiv.org/abs/2302.01560
- **Voyager (NVIDIA):** iterative prompting with environment feedback and error traces, repeated until a self-verification module confirms completion, then the program is committed to a skill library. Complex skills compose simpler ones. → principles 2, 3.
  https://arxiv.org/abs/2305.16291
- **Mindcraft / MineCollab:** an LLM-agent platform with 47 in-game tools. Its benchmark found state-of-the-art agents struggle with embodied reasoning and communication in collaborative tasks. → risk 7, and the reason skill coverage matters.
  https://arxiv.org/abs/2504.17950
- **Claude Plays Pokémon (Anthropic):** knowledge-base notes plus summarisation when context fills. Summaries lose detail, so tracking what has been tried over long periods is hard and long-term planning is weak. → keep goals and progress in code and files, not in the model's memory.
- **Anthropic, "Effective harnesses for long-running agents":** continuity lives in artifacts: a task list in JSON with pass flags (JSON because models rewrite Markdown), a progress file, git history, and small bounded units of work. → section 2 file discipline, principle 5.
  https://anthropic.com/engineering/effective-harnesses-for-long-running-agents
- **mc-agents (community):** a reflex/strategy split inspired by "System 1/System 2" thinking, with a persistent memory file updated each cycle.
  https://github.com/jblemee/mc-agents

---

## 11. Hosting notes (context, not dev work)

- The group's real world stays on Shockbyte during development. Shockbyte's modded server type runs a Windows build with UE4SS, so it could host the finished mod. Open questions for Shockbyte: are custom (non-Nexus) Lua mods allowed, and are outbound network connections from the server allowed? This affects the bridge design if production moves there (the agent would run elsewhere and the bridge would cross the network).
- Moving to this VM is the alternative, at the cost of ongoing ops: SteamCMD updates every patch, backups, auto-restart, OS patching, uptime.
- Decide only after Phase 4 passes and the companion works.

---

## 12. Suggested repo layout

```
dragonwilds-companion/
├── CLAUDE.md                # this file
├── docs/
│   ├── DISCOVERIES.md       # every verified class/function/param + build ID
│   ├── PROGRESS.md          # append-only session log
│   └── tasks.json           # task list with status + passes_test flags
├── mod/                     # UE4SS Lua mod (deployed into the server's UE4SS Mods dir)
│   ├── scripts/main.lua     # lowercase: the Linux UE4SS port needs it (section 3)
│   ├── body/                # spawn, possession, movement, reflexes
│   ├── skills/              # one file per verified skill
│   ├── state/               # state exporter, event emitter
│   └── bridge/              # socket or JSONL transport
├── brain/
│   ├── interface.py         # GameInterface + tool schema
│   ├── llm.py               # provider-agnostic model adapter
│   ├── controller.py
│   ├── planner.py
│   ├── executor.py
│   ├── state_store.py       # task tree, notes.json, skill registry
│   ├── bridge_client.py     # real game implementation of GameInterface
│   └── mock/                # mock game implementation of GameInterface
├── evals/                   # controller_cases.jsonl, planner_cases.jsonl, runner
├── tools/                   # server update script, log tailer, deploy-mod script
└── logs/                    # JSONL event/prompt/tool logs (gitignored)
```

---

## 13. First session checklist

1. Read this file. Create the repo and `docs/` files; seed `tasks.json` from section 6.
2. Verify the toolchain: Git Bash, Python, SteamCMD reachable, outbound HTTPS working.
3. Install the server via SteamCMD, configure moddable mode, create the throwaway world, start the server, and write `tools/update_server.sh` and a start script.
4. Ask Luis to join from GFN → **Phase 1 gate**.
5. Install UE4SS for the server, write the hello-world Lua mod logging to file, generate the dump → begin the **Phase 2 gate**.
6. In parallel, scaffold `brain/interface.py` and the mock game (Track M).
7. Update `PROGRESS.md` and `tasks.json` before ending the session.
