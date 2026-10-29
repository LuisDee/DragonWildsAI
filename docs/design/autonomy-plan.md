# Speed and long-horizon autonomy plan (2026-10-25, after the 21:00–21:16 session)

## Accepted steer — Luis, 2026-10-28

**Read this section first.** Luis explicitly approved this steer and requested
durable persistence because earlier decisions were diluted across context and
recovery notes. It controls implementation priorities over the historical task
lists below. The original M1-M6 objective, milestone order, approved judges,
evidence requirements and sign-off remain unchanged.

### Immediate priority — Luis, 2026-10-29

The active Goal now uses [the updated prompt](../NEXT-GOAL-PROMPT.md).
Reliable traversal, truthful perception and sustained tasks take priority over
the historical recovery/setup order below. First prove three unassisted complete
Sonnet/Haiku walking round trips: temple lodestone -> at least 200 metres outside
the temple -> the same lodestone on the correct floor. No temple-specific code,
hidden intermediate waypoints or teleportation. Verify a changed destination and
another slope/doorway. These are additional diagnostics; original M1-M6 judges
and completion requirements are unchanged.

Diagnose agent/NavData selection, projection/floor identity, coordinate units,
capsule feet/centre, collision/steps/slopes, streaming, waypoint authority and
moving targets before selecting a repair. A partial route is not proof of no
walkable route. Audit the actual headless observation -> target selection ->
native interaction -> UI state -> verified outcome loop. Follow with purposeful
exploration and sustained gather/return/deposit work, then original progression.

After each failed live experiment inspect its trace and search primary sources
before another experiment; do not keep repeating an unchanged failed attempt.
Persist evidence and reuse/adapt/build decisions. The initial source/tooling
survey is in [the research record](../research/2026-10-29-traversal-perception-direction.md).
Luis explicitly requested an Astra adversarial navigation review and a separate
Sol headless interaction/source review. Root owns integration and the one DEV
client; those reviewers do not operate it. No new autonomous pass is implied by
research, offline tests, manual help or a diagnostic probe.

### Terrain and traversal direction — Luis, 2026-10-29

Build one reusable terrain representation for seeing and routing over obstacles,
then gaps requiring single jump, double jump or Windstep. Current walking repair
comes first; the three walking round trips and original judges remain unchanged.
Keep nearby observed floor layers/elevation, capsule clearance, edges, candidate
takeoff/landing areas and unknown regions distinct. An unobserved/unloaded floor
is unknown, not proof of a gap or an impossible route. Retain sourced observations
and successful directed routes per world, with freshness and failed-attempt
feedback; recheck physical conditions before execution.

Generate ability-specific traversal candidates from measured horizontal/vertical
reach, available run-up, trajectory clearance, landing support and current
unlocks/cooldown/runes. Compare walking detours and traversal costs. Haiku/Sonnet
retain intent and route/ability choices; frame-rate services execute and observe
the selected move. Confirm actual landing before learning success. Do not infer
horizontal gap range from vertical jump height or count partial jump controls as
general obstacle-crossing capability. Research and current gaps are recorded in
[the grounding research](../research/2026-10-29-player-grounding-native-controls.md#terrain-and-gap-traversal-follow-up).

### Standing decisions

Luis reinforced validation and observability on 2026-10-29: offline checks ->
developer in the real client's driver seat -> unaided complete Sonnet Director
and Haiku Controller. For each behavior change, inspect what the body, developer,
Haiku and Sonnet actually receive. Expose relevant current geometry, object/UI
state, action ownership, specific failures, observed effects, provenance and
unknowns; verify delivery into model inputs rather than only adding log rows.
Bound and summarize the evidence without silently discarding the facts needed
to decide. Developer/simulated success remains diagnostic, not autonomous proof.

1. **Keep the reusable, two-speed architecture.** Sonnet researches and maintains
   the plan; Haiku selects and executes actions from current observations; native
   movement, interaction and reflex services handle frame-rate work. The models
   own intent, alternatives and sequencing. Do not add phrase-to-tool maps,
   crop/recipe-specific workflows, hidden hints or code that rewrites choices.
2. **Make the complete agent the primary live acceptance path.** Enable and verify
   the Sonnet Director, Haiku Controller, research access, persistent task board,
   execution and feedback together. Record actual model names and Director state
   before calls. A Director-off or all-Haiku experiment is a labelled component
   diagnostic; it cannot demonstrate the full research/planning agent. Do not
   silently substitute it when full-stack admission fails.
3. **Drive work from one end-to-end job and its evidence.** Select a job appropriate
   to the lowest unmet milestone and actual unlocks. Establish developer positive
   controls for its interactions, then let the full agent attempt it without
   operator hints. Classify failures as knowledge, planning, perception/memory,
   control/navigation or test-harness defects. Repair the demonstrated generic
   gap and remeasure the entire job. Tool count and passing offline tests alone
   are not capability progress. Preserve the existing offline -> developer ->
   deployment-model validation order, with the full Sonnet/Haiku system last.
4. **Complete research through reusable retrieval.** Prefer current game data,
   then sourced cached wiki knowledge; retrieve missing/stale pages on demand
   when needed. Retain source/version/confidence and cache useful findings.
   This is a requirement, not a claim that live page retrieval is implemented.
   Distinguish mandatory prerequisites from yield/efficiency optimizations and
   compare acquisition alternatives against the user's actual requested outcome.
5. **Provide sufficient truthful perception and controls.** Models need current
   inventory, task progress, relevant entity/station state and specific verified
   failures. Unknown is not empty, zero or success. A new UI/mechanic may require
   a reusable adapter; another crop using existing actions should be data and a
   model-generated plan. Keep historical/world memory while preventing stale
   observations from masquerading as current facts.
6. **Measure generalisation after freezing the integration.** Try unfamiliar job
   variations without adding task-specific code after seeing them. One diagnostic
   success is early evidence, not the formal held-out or repeat requirements.
   Keep the existing frozen goal criteria and negative controls intact.
7. **Keep the operating constraints.** DEV character/server only, one live
   operator/client/server, one heavy local workload, world memory preserved,
   at most two bounded Terra workers, shared $10 UTC-day model cap, and explicit
   driver/setup/model/call-count provenance. Stop workers and model spending at
   target end or pause; scheduled wakeups never undo a pause.

### Immediate work order on resume

- Persist this decision and its startup/handoff pointers before more feature work.
- Audit and prepare a bounded full-stack diagnostic using the existing Director
  and harness. Pick the exact M1-appropriate job after checking available state;
  advanced Desert Weed farming is an architectural example, not a new immediate
  milestone or permission to skip Brynmoor/M1 requirements.
- In parallel, perform one bounded navigation discrimination: agent/data selection,
  real connectivity and streaming coverage. Correcting elevation alone did not
  make the measured destination reachable. Do not implement a horizontal-goal
  interface as though that alone solves the observed partial route.
- Close only generic research, observation or interaction gaps required by the
  selected job. Farming's basic tools, compost handling and growth observation
  require live verification before any autonomous full-cycle claim.
- After reviewed offline checks and a frozen full gate, developer-drive the changed
  layer, then measure the complete Sonnet/Haiku job. Commit coherent checkpoints
  and update PROGRESS, BUGS, DISCOVERIES and the recovery handoff.

### Persistence and reporting contract

AGENTS.md and ARCHITECTURE.md point here. Every recovery handoff must start with
the current Goal status, this steer's path, current tested/deployed code, actual
runtime ownership and the next end-to-end experiment. Report developer, isolated
Haiku, simulated and full-stack outcomes separately. Explicitly say when no new
autonomous task passed. This steer remains in force across compaction/restarts
until Luis changes it; new implementation work must not quietly revert to a
sequence of disconnected tool repairs and controller-only demonstrations.

### Separate friend-server trial — planned while development is paused

Luis separately requested a supervised friend-server trial and paused the
development Goal. This does not change the original DEV-only M1-M6 objective
or authorize development benchmarks, grants or world changes on that server.
No join, character creation or map reveal has been performed for this trial.

- Reuse the established arrangement: companion client on the chosen remote
  server, local DEV server retained as the navigation-data backend. Inspect the
  existing join profile and verify navigation compatibility with the target;
  do not assume remote and local dynamic world state are identical.
- Create a separate fresh companion character. Preserve the existing DEV and
  other characters, their inventories, saves and progress. Requested exception:
  reveal this character's map exploration only, using a verified supported
  mechanism. No automatic skill, quest, equipment or progression unlocks.
- Goal is access to the friend's existing Lodestones, including Umbral Sands.
  Map visibility alone is not proof of teleport eligibility. Verify the actual
  destination registry, native availability, Law Rune cost, physical source
  interaction, real arrival and clean UI with the new character. Do not emulate
  teleportation or grant map/network state speculatively.
- Give the friend world a distinct stable memory identity and connection profile;
  do not reuse dev_director/dev navigation memories or carry DEV fixture stock.
- Obtain the hosting/join method and target address/port before configuring the
  connection. Keep passwords in the existing gitignored local secrets mechanism.
  Begin with controlled basic tasks and explicitly record this as a friend trial,
  not a goal benchmark or proof that long autonomous tasks are ready.

### Search record for the accepted steer

Reuse the same-problem primary research already examined and recorded in the
architecture audit and knowledge-lookup design. Anthropic's tool/agent feedback
guidance, Mineflayer's reusable goal abstractions, and Epic's explicit navigation
projection/path semantics support the architecture; they do not prove this game's
controls or this agent's live competence. Decision: reuse the existing Director,
controller, task board, retrieval and client services; adapt their integration
and verify the whole loop before building another framework.

- https://www.anthropic.com/research/building-effective-agents
- https://platform.claude.com/docs/en/agents-and-tools/tool-use/overview
- https://github.com/PrismarineJS/mineflayer-pathfinder
- https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/AIModule/FAIMoveRequest

The sections below preserve historical measurements and plans, not a substitute
for this accepted work order or current runtime evidence.

## 1. Where the time goes (measured from logs/brain-live-*.jsonl, last two sessions)
| Stage | Measured | Note |
|---|---|---|
| Chat line → first action or speech | **p50 5.0 s, p90 6.4 s** (n=41) | |
| ↳ "not named" burst debounce | ~2–3 s | Luis rarely says "claude", so most lines wait for the burst to end |
| ↳ game-state reads before each turn | **2.8 `get_state` per model turn** | each 0.1–0.4 s, and they're redundant |
| ↳ Haiku call | p50 1.9 s, p90 2.8 s; prompt ~13.3k tokens (≈65% cached) | |
| **Failing actions** (the real "slow") | Splinter: 22 s timeout × 2 executor attempts × 3 = **~2 min**; go_to from bed: 46 s + 125 s | slow failure + blind retries |
| Talk without action | "I'll try Splinter again now" with no tool call | the turn ends; nothing happens |

**Conclusion:** model thinking is about 2 s and isn't the main problem. He feels slow because of (a) the debounce, (b) actions that fail slowly and are retried blindly, and (c) turns that only talk. He looks stupid because the model lacks facts at decision time (what Splinter targets, the preview semantics) and because the body's primitives fail at things a player finds trivial (L14/L15).

## 2. Speed fixes (now, broker + skills agents)
1. **Debounce:** a line from the player he is with (the only player in range, or the last one he spoke with) counts as addressed; burst window ≤ 0.8 s. *Accept: p50 chat→first action ≤ 2.5 s.*
2. **One state read per turn** (cached ≤ 1 s), and a **trimmed digest**: only what's relevant (nearby top-N, held, vitals, the current goal). *Accept: prompt ≤ 8k tokens.*
3. **Fail fast:** every skill has a progress watchdog (no progress for N s → fail with a reason). Spells resolve or cancel within about 6 s. No executor retries; the result goes to the model.
4. **Act on the stream:** start the first tool call as soon as its input has streamed (the Anthropic streaming tool input) instead of waiting for the whole response. Precedent: speculative/streamed tool calling ([Stream blog](https://getstream.io/blog/speculative-tool-calling-voice/)), [Speculative Actions, ICLR 2026](https://arxiv.org/html/2510.04371v1). Only read-only tools are ever speculated.
5. **No talk-only promises:** if the reply promises an action and calls no tool, the model gets one continuation turn (information, not a veto). Regression test: the 21:02:56 and 21:15:01 replays.

## 2a. L27: the first dev measurement run (2026-10-25 23:32, `logs/evals/20261025/20261025-233253-dev-measure/`)

**Stages, from `python -m tools.obs episode --brain-log <case>/brain.jsonl -v` for all 6 cases:**

| Stage | Measured | Note |
|---|---|---|
| Burst wait | 0 s | the test lines are named ("Claude, ..."), so they run at once |
| State read + context build | 0.3–0.5 s | before the first model call |
| Model call (warm) | 0.7–1.7 s, 50–224 output tokens | effort `low` is applied (`make_llms` → `output_config.effort=low`); every prompt row now logs `effort` |
| **Model call (cold: the session's first)** | **11.2 s** (11.3k input tokens, 0 cached, 50 output) | the 12.8 s worst case |
| Brain → body start | about 0.2 s | `tool_call` → `bridge_send` |
| **The benchmark's own observer** | **about 2.2 s** | `evals/bench/observer.py:85` stamps `t0` AFTER its "before" probe, so `latency_s` includes the probe |

**What it means:**
- **Companion time** (heard → first tool call) is 1.0, 1.6, 2.06, 2.1, 2.1 s, plus 11.9 s for the cold start. The p50 is about 2.1 s, which meets the 2.5 s target.
- **The benchmark's p50 of 4.2 s** is that time plus the observer's own probe (a harness artefact; reported to the bench owner).
- **The biggest companion stage is the cold first call.**
  - Most of it is the litellm import: 5.8 s, done lazily inside the first `complete()`.
  - The rest is the TLS handshake and the first cache write.

**Fix:**
- `Controller.warm_up()` at session start. One tiny request (max 64 tokens) with the real persona and tools pays the import, TLS and cache write. It runs within the budget guard and is logged as `llm_warmup`.
- `LITELLM_LOCAL_MODEL_COST_MAP=True` by default (bundled cost map, no network fetch at import).
- Replay (`tests/test_latency_replay.py::test_l27_cold_start_before_and_after_the_warm_up`): the first line of a fresh session goes from 11.65 s to 2.15 s; the session max from 11.65 s to 3.3 s.

**Open:**
- The benchmark builds its own agent (`evals/bench/devrun.py`), so it must call `controller.warm_up()` before the first case.
- Its observer should stamp `t0` before the probe, or subtract the probe time.
- The cast tool itself (4–7 s per call: the wheel route) is the spells agent's.

## Search record (L27)
- **Need:** a cold first LLM call (11.2 s) in a fresh brain session.
- **Searched:** "litellm import slow startup", "LITELLM_LOCAL_MODEL_COST_MAP"; the Claude API skill on prompt caching (pre-warming) and on effort for Haiku 5.5.
- **Found:**
  - LiteLLM fetches its model cost map over the network at import unless `LITELLM_LOCAL_MODEL_COST_MAP=True` (CrewAI community thread, about 20 s with a slow route: https://community.crewai.com/t/crewai-cli-command-is-slow-to-respond/3359; LiteLLM issue on the offline fallback: https://github.com/BerriAI/litellm/issues/25062).
  - Measured here: the import is 5.8 s with the network fetch and 5.0 s with the local map, so the import itself dominates.
  - Claude API docs: pre-warm the prompt cache with a request on the stable prefix (tools → system); `max_tokens: 0` is the documented pre-warm, and we send 64 because LiteLLM needs a positive value (https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching). Effort `low` suits latency-sensitive routes; adaptive thinking stays on.
- **Decision:** adapt. A start-of-session warm-up request plus the local cost map. Nothing new to adopt; no library change.

## 3. Reliability first (autonomy grows only as fast as the primitives; CLAUDE.md risk 8)
- Open: L14/L15 preview spells, L7 interact on the right item, L8 go_to any id, L13 late-success detection.
- Each primitive gets a dev-server scenario in `tools/scenarios/dev_suite.json`, run before live sessions.

## 4. Long-horizon autonomy ("go get better gear, level skills of your choice, for hours")
Three loops at three speeds (as in PIANO and PUBG Ally, CLAUDE.md §10):

| Loop | Model | Cadence | Owns |
|---|---|---|---|
| Reflex | none (Lua) | frame | movement, combat defence, stay fed, verify |
| Controller | Haiku | on events (chat, results) | speech, interrupts, one step at a time, small fixes |
| **Director** | **Sonnet** | on goal start, subgoal done/failed, every ~5 min | the goal tree, choosing subgoals, replanning, research |

**What the Director needs (new infrastructure):**
1. **Goal tree, persisted** (`logs/state/worlds/<w>/goals.json`): goal → subgoals, each with a **success test checkable from state** (e.g. `equipped(Head).tier ≥ 4`, `skill(Mining) ≥ 60`, `inventory(ITEM_Bar_Iron) ≥ 20`), status, attempts and the last failure. Survives restarts (principle 5).
2. **Research tools** for the Director: `lookup` (wiki + game data, already built: 1207 game docs, 9138 wiki docs), a **recipe graph** from the game's crafting data (what makes X, where, with what), the **gear comparator** (`brain/item_stats.py`), and **map memory** (places, resource nodes and stations seen, lodestones; from the census and navmem).
3. **Curriculum** (Voyager): for an open goal ("level what you like"), the Director proposes the next achievable subgoal from current skills, gear, known resources and past failures, scored by value and feasibility.
4. **Executor bridge:** a subgoal runs as Controller turns with the subgoal as the "current task" in context, and the Controller reports done or failed. Done is decided by the success test on fresh state, never by the model's claim (principle 5).
5. **Replan on failure** (DEPS: describe → explain → plan), with an attempt cap. When stuck, the Controller asks Luis once, specifically (principle 8).
6. **Skill library** (Voyager, already scaffolded in `data/skills/<world>`): successful subgoal action sequences are saved and reused ("smelt iron bars at the base furnace").
7. **Interruptible:** Luis's chat preempts. The goal pauses and resumes. Progress reports at milestones (not on a timer): "Mining 52 → 55, 20 iron bars smelted".
8. **Budget:** Sonnet about 10–30 calls/hour (on subgoal boundaries), Haiku per step. State estimated cost per hour before the first long run.

**Acceptance ladder:**
1. "get a better pickaxe": mine ore → smelt → craft at a station → equip → compare stats. Dev server, then live.
2. "level Mining to N": a loop with re-stocking and food.
3. Open: "get better gear, level what you like" for 1 h without help; reported, interruptible.

## 5. Order
1. Speed fixes §2 and reliability §3 (in progress: broker, skills, spells agents).
2. Director + goal tree + success tests + research tools §4.1–4.5 (new agent, after the design review gate).
3. Curriculum + skill library reuse §4.3/4.6, then the acceptance ladder.

## Precedent
- PIANO / Project Sid: concurrent loops at different speeds (https://arxiv.org/abs/2411.00114).
- Voyager: curriculum, skill library, self-verification (https://arxiv.org/abs/2305.16291).
- DEPS: replanning (https://arxiv.org/abs/2302.01560).
- GITM: the LLM parameterises scripted skills (https://github.com/opengvlab/gitm).
- Mindcraft / MineCollab: tools and self-guided play; embodied collaboration is hard (https://arxiv.org/abs/2504.17950).
- ReAcTree: a tree of agent nodes per subgoal with working memory (AAMAS 2026, https://www.emergentmind.com/topics/reactree).
- HiMAC: planner/executor split for long horizons (https://arxiv.org/abs/2603.00977).
- Speculative actions for latency (https://arxiv.org/html/2510.04371v1).
