# Streamline plan (2026-10-25, after the 19:14–19:26 episode)

## What happened (from chat.jsonl + brain log + client logs)
1. **19:14:** the client froze (deterministic engine wait, the same stack as 17:53). The server kept his body with no defence, and he died (cow/rat fight) → his items, including all drinks, went into the gravestone.
2. **19:18:** the watchdog/boot rejoined him at spawn with hydration 13.7.
3. Trips to the grave area failed **4×** in the start-area lodestone pit/church (`no_route`, `leader_above_jump_height`, `verify_exhausted`). Main hand-drove legs, and the dev oracle returned `no_path`.
4. Luis came to him and dropped food and water. The brain:
   - spoke **contradictory, stale** lines: "can't find a way to you" and "higher up than I can jump" right after arriving, "really thirsty" ×3, several in the same second;
   - called **`pickup`, which the client body doesn't implement** ("Sorry, I can't pick things up yet");
   - turned unmatched words into item names ("I can't see any **dsgrab** / **look then** / **smh** around here");
   - had **no "drink X" tool**, so it couldn't act on "drink the pumpkin spice infusion".
5. **Rescued only by reflexes:** the stay-fed reflex collected and ate the sandwiches, and main stepped him onto the drink (detector needs facing). He drank at **0.8** hydration.
6. **Stats:** the edit never applied. The server keeps a per-character state store in the world save (`CachedCharacterStates`) and overwrites the local file (DISCOVERIES).

## Root causes (six, cross-cutting)
| # | Cause | Symptoms |
|---|---|---|
| R1 | **Platform unstable**: a deterministic client freeze under NullRHI (sync asset load suspected) | deaths while frozen, grave cycles, lost items/food |
| R2 | **Brain and body disagree on tools.** The brain's tool list is hand-written and doesn't come from the body's real capabilities. | `pickup` called but missing; no drink/consume/fetch tool |
| R3 | **No event hygiene.** Every body event goes to the LLM: no coalescing, no staleness check, no one-line-per-episode rule. | stale/contradictory/repeated speech |
| R4 | **Grounding fallback is wrong**: unmatched words treated as item names instead of asking or using chat context | "can't see any dsgrab/smh" |
| R5 | **Navigation has no memory**. Every trip re-solves from scratch and the same trap repeats: no route cache, no learned exits, no taboo on failed approaches. The oracle doesn't stream remote areas. | church/lodestone pit ×4+, hand-driven legs |
| R6 | **Process**: integration tested live in Luis's real world, several moving parts at once, main hand-driving recoveries, no scenario suite | every bug found by Luis, slow loops |

## Precedents (searched)
- **MINDcraft** keeps 47 parameterised tools that wrap the bot API, and agents query observations on demand. The tool surface is a *designed contract* with the body library. https://arxiv.org/pdf/2504.17950
- **ToolFailBench taxonomy:** Tool-Skip / Result-Ignore / Output-Fabrication. Our "pickup not implemented" and "dsgrab" are contract and fabrication failures. https://arxiv.org/pdf/2607.04686
- **LLM + behaviour trees:** the LLM proposes and repairs, while the BT executes with sensor feedback at its own rate. The LLM is consulted on failure, not on every tick or event. https://arxiv.org/pdf/2508.09621 ; https://alphaxiv.org/abs/2409.13356
- **Debouncing expensive LLM work:** reuse or merge matching events per work key before triggering a run. https://bubus.sweeting.me/features/event-debouncing
- **Bot navigation memory:**
  - FFXIV bot: stuck detection learns obstacles permanently, plus Dijkstra over recorded waypoints. https://github.com/Syraxius/FFXIVSyraxiusBot
  - Pogamut (UT2004): time/position/oscillation stuck detectors, taboo the failing nav point, choose an alternative. https://diana.ms.mff.cuni.cz/pogamut_files/lectures/2015-2016/Pogamut_3-2016-Lecture-05-Slides-Navigation.pdf

## Plan (in order; each step has an acceptance test)
1. **Stabilise the platform (R1). Blocks everything.**
   - The hang agent finds the cause and tests a software render path (WARP) instead of NullRHI.
   - Until fixed: the watchdog auto-rejoins; on rejoin, the brain is told "I froze and died, recovering"; no first-time equips in risky spots.
   - *Acceptance:* 2 h of play without a freeze, including equipping new gear.
2. **One capability contract (R2).**
   - The client bridge publishes a manifest: tool name, args schema, preconditions, description.
   - The brain builds its tool list from that manifest only, so a tool the body lacks can't be offered.
   - Add **composite skills** that do the whole job and return one verified result:
     - `fetch(item|id)`: find → approach → face → interact → verify;
     - `consume(item)`: hotbar use, verify the stat rose;
     - `come_to(player)`, `recover_grave()`, `give(item, player)`.
   - Map legacy names (`pickup` → `fetch`).
   - *Acceptance:* "grab those / drink the infusion / come to me" in chat each produce one correct verified action.
3. **Event hygiene and a single voice (R3).**
   - An event broker between body and brain. Coalesce by work key (movement episode, vitals kind) and drop events superseded by newer state (e.g. "unreachable" after arrival).
   - Rate-limit speech: one line per episode, no repeats within N s.
   - Only *state changes that need a decision* go to the LLM. Reflexes handle the rest and report afterwards.
   - *Acceptance:* the 19:22–19:25 replay produces no contradictory or duplicate lines.
4. **Grounding (R4).** If words don't match an item, use the chat context (Luis said "food and water in front of me") and the census (nearby food/drink), or ask one short clarifying question. Never echo the user's words as an item name.
   - *Acceptance:* the "dsgrab / look on the floor / smh" replay, as a fake-model test.
5. **Navigation memory (R5).**
   - Per-world **route cache**: every successful trip stores its waypoints, reused and joined into a graph (Dijkstra), as in the FFXIV bot.
   - **Known-trap memory**: a failed approach is tabooed with the exit that worked (as in Pogamut).
   - Seed it with the start-area pad exit.
   - Make the oracle stream remote areas (move the anchor along the route).
   - Learned jump links feed the same graph.
   - *Acceptance:* spawn → grave area 5× in a row without help, from the pit.
6. **Process (R6).**
   - **Dev-server scenario suite:** Claude's client joins the dev world (nav-only server, same map) for scripted scenarios: spawn-pit escape, fetch and consume, grave recovery, a follow course, a Kebbit fight. Run before every live session.
   - **One integration owner (main).** Agents deliver offline-tested modules; main runs the suite, then a short live acceptance with Luis.
   - **One timeline viewer** (chat, brain decisions, body events, vitals) so diagnosis takes minutes.

## Not changing
- The real-client architecture (R2 route), the brain design (LLM chooses skills; deterministic layers execute), and the per-world memory/skill library. Today's failures are contract, hygiene, memory and stability problems, not architecture ones.

## Step 6 tooling: search record (2026-10-25)
- **Need:** a scripted scenario suite on the dev server, and one merged, filterable timeline across about 10 log formats.
- **Searched:**
  - "lnav merge multiple log files JSON lines timeline custom format"; lnav docs (formats, cli); lnav on Windows / winget.
  - "Unreal Engine Gauntlet automation framework multiplayer client server tests".
  - "game bot scenario test harness mineflayer tests integration server scripted scenarios"; logmerger (GitHub).
- **Found:**
  - **lnav** (BSD-2) merges files by time. JSON-lines formats are declared in a JSON file (`timestamp-field`, `line-format`, `level-field`). It offers filters, a histogram and SQL. There is a Windows build on winget (`tstack.lnav` 0.14.1-rc1 only), and headless `-n -c` works.
    - https://docs.lnav.org/en/latest/formats.html
    - https://docs.lnav.org/en/latest/cli.html
  - **logmerger** (MIT, a Textual TUI) merges text, CSV and JSONL with `--start/--end` and `--output`. Its docs do not say how it finds a JSONL timestamp field or whether epoch floats work.
    - https://github.com/ptmcg/logmerger
  - **Gauntlet** launches and checks Unreal sessions (multi-client + server). Its test logic lives in the game (a TestController plugin) and it needs our own cooked build. We have neither for a shipped game, so it does not apply. The pattern (orchestrate sessions, assert from logs and state, report) is what we adapted.
    - https://dev.epicgames.com/documentation/en-us/unreal-engine/gauntlet-automation-framework-overview-in-unreal-engine
  - **mineflayer-test-api / mineflayer's own suite**: start a throwaway server, load the bot, do quick actions, validate them, disconnect. That is the shape of our runner (dev server = throwaway world). Nothing in it is reusable code for a UE client.
    - https://github.com/PrismarineJS/mineflayer (test/externalTests)
- **Decision:**
  - **Timeline = adapt + reuse.** We need semantic one-line summaries per record kind, noise rules, per-source zones and redaction. Neither lnav's `line-format` nor logmerger can express those (there are 9+ ad-hoc schemas, epoch floats and local-time file names). So a small normaliser (`tools/timeline.py`) writes the text timeline, and **lnav is reused** for interactive browsing and SQL over its `--jsonl` output (`tools/lnav/dw_timeline.json`).
  - **Scenario suite = build** a thin runner over the existing bridge and command runner, following the mineflayer-test pattern. No harness fits a UE4SS-driven shipped client.
