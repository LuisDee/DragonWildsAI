# How competent game bots avoid no-progress loops (research, 2026-10-31)

Scope: web research only, no code changed. The question: why our companion burns about 40 model calls on a 200 m round trip and fails, while other bots don't. Context: the audit (`docs/audit-2026-10-31/code_audit.md` §0) shows go_to success falling from 56–58% to 14–21%. Most failures were refusals from our own gates (`route_ended_before_goal`, `no_path`, owner token, walk_guard). The root cause underneath, a temple ramp the NPC navmesh does not cover, was never fixed.

Source key: **[P]** is a primary source I read this session (paper, repo source, official blog). **[S]** is a secondary source or search summary. **[K]** is from memory and was not fetched.

---

## 1. How the competent bots actually work: what the LLM decides, what code does, how loops are stopped

| System | LLM decides | Code does | Loop / failure control |
|---|---|---|---|
| **mineflayer-pathfinder** (no LLM) [P] [index.js](https://raw.githubusercontent.com/PrismarineJS/mineflayer-pathfinder/master/index.js), [readme](https://raw.githubusercontent.com/PrismarineJS/mineflayer-pathfinder/master/readme.md) | — | A* over the block grid. There is no navmesh: the graph is built on the fly from a `Movements` model of what a *player* can do (`maxDropDown` 4, `allowParkour`, `allowSprinting`, `canDig`, 1×1 towers). Planning is incremental: `thinkTimeout` 5000 ms, `tickTimeout` 40 ms per tick, `partial` paths are walked while search continues. | `path_reset('stuck')` fires if no path node is reached within **3500 ms**, then it re-plans. It also re-plans on `block_updated`, `chunk_loaded`, `goal_moved`, `dig_error` and `place_error`. Failure surfaces as the events `noPath` / `timeout`. The caller never sees retries. |
| **Mindcraft** (the MineCollab platform) [P] [modes.js](https://raw.githubusercontent.com/kolbytn/mindcraft/main/src/agent/modes.js), [self_prompter.js](https://raw.githubusercontent.com/kolbytn/mindcraft/main/src/agent/self_prompter.js), [action_manager.js](https://raw.githubusercontent.com/kolbytn/mindcraft/main/src/agent/action_manager.js), [actions.js](https://raw.githubusercontent.com/kolbytn/mindcraft/main/src/agent/commands/actions.js) | Picks one of about 47 parameterised commands (`!goToCoordinates`, `!collectBlocks`, `!rememberHere`…), or writes JS. `!goal` turns on self-prompting. | Each command runs to completion as a code action on mineflayer. **Modes** are code reflexes that interrupt actions without the LLM: self_preservation, unstuck, self_defense, item_collecting… | **unstuck**: moved < 2 blocks in **20 s** → says "I'm stuck!" and runs `moveAway(5)`. The self-prompter stops after **3** consecutive replies with no command. The action manager cancels a resume after more than 3 actions less than 20 ms apart, and kills the process after more than 5. Actions time out at 10 min. Output is clipped to 500 chars. **I found no detector for "same command, same failure, repeated"** in these files. |
| **MineCollab** (benchmark paper) [P] [arXiv 2504.17950](https://arxiv.org/html/2504.17950v1) | As in Mindcraft | As in Mindcraft | The paper does not describe stuck detection. Errors come back as command output. The main failures it names are communication and embodied reasoning (undoing finished work, duplicating work). Success fell from about 90% to under 30% going from 2 to 5 agents. |
| **Voyager** [P] [paper](https://arxiv.org/html/2305.16291), [voyager.py](https://raw.githubusercontent.com/MineDojo/Voyager/main/voyager/voyager.py), [exploreUntil.js](https://raw.githubusercontent.com/MineDojo/Voyager/main/voyager/control_primitives/exploreUntil.js) | Curriculum (next task), code for the task, critic verdict | mineflayer primitives. `exploreUntil` picks a random 10–29-block `GoalNear` every 2 s along a direction until a callback succeeds or `maxTime` (default 60 s, cap 1200 s) runs out. | **Hard cap: 4 rounds per task** (`action_agent_task_max_retries=4`). After that the task is marked failed and the curriculum gets it back as "too hard" and moves on. A GPT-4 critic checks success against state. Only verified programs enter the skill library. 160-iteration run cap. |
| **GITM** [P] [arXiv 2305.17144](https://arxiv.org/html/2305.17144v2) | Decomposer (sub-goals from wiki text), Planner (lists of structured actions, plus an "explanation" of the last failure) | 9 hand-written actions. `explore` is BFS over a **20×20 "chessboard" of cells** (DFS underground) and fails after 10,000 steps. `approach` is A* with jump/fall, applied iteratively toward the nearest reachable point when the target is out of range. | Execution stops at the failed action and the planner replans from there. A **30-LLM-query cap per sub-goal** counts as failure. Successful action lists are stored per sub-goal; after 5, an LLM merges them into one reference plan. **No RGB at all**: it uses LiDAR rays plus a 10-unit voxel cube. ObtainDiamond 67.5%. |
| **PUBG Ally / NVIDIA ACE** [P] [NVIDIA blog](https://developer.nvidia.com/blog/how-krafton-built-pubg-ally-a-co-playable-character-powered-by-nvidia-ace/) | 2B SLM: whether to speak or act, which observation tools to call | A behaviour tree ("System 1") does movement, aiming and combat at tick rate. Reflexes never wait on the model. | The blog gives no runtime failure handling. Validation is offline: protocol, tool use, and speech/action consistency. Facts must be re-queried from the engine, not recalled. |
| **Project Sid / PIANO** [P] [arXiv 2411.00114](https://arxiv.org/html/2411.00114v1) | The Cognitive Controller (a bottleneck) makes deliberate decisions and broadcasts them to the talk modules | Concurrent modules; reflexes are small non-LLM networks | Documented failures: hallucinations that compound, and "stuck in action loops". The **action-awareness** module compares expected and observed outcomes. Navigation is listed as a limitation, not described. |
| **SIMA 2** [P] [arXiv 2512.04797](https://arxiv.org/html/2512.04797v1) | One Gemini Flash-Lite model: pixels in, keyboard/mouse plus dialogue out. An optional Gemini Pro gives instructions every k steps. | — | Agents mostly fail through **suboptimal exploration**; humans mostly fail by running out of time. A self-improvement loop has a Gemini task setter and a 0–100 rubric reward model (≥ 50 counts as success). |
| **Lumine** [P] [arXiv 2511.08892](https://arxiv.org/html/2511.08892) | A 7B VLM: pixels at 5 Hz, 30 Hz action chunks, reasoning only when needed | — | The main bottlenecks are navigation and combat. It "more often returns to the same spot, repeatedly drawn by the quest marker and constrained by limited memorization". **This is our temple loop.** |
| **CRADLE, JARVIS-1, Optimus-1, Odyssey** [P] [CRADLE](https://arxiv.org/html/2403.03186v2), [JARVIS-1](https://craftjarvis-jarvis1.github.io), [Optimus-1](https://arxiv.org/html/2408.03615v2), [Odyssey](https://arxiv.org/html/2407.15325v3) | Plan and reflect; skill curation (CRADLE); a planner–actor–critic over 40 primitive and 183 compositional skills (Odyssey) | Code skills (Odyssey) or learned controllers (JARVIS-1, Optimus) | Memory of *outcomes*: Optimus-1's AMEP keeps both successes and failures for reflection, and removing it costs about 12%. Odyssey checks skill prerequisites recursively before running. None of them is a navigation-reliability paper. |
| **Gemini Plays Pokémon** [P] [jcz blog](https://blog.jcz.dev/the-making-of-gemini-plays-pokemon), [arXiv 2605.09998](https://arxiv.org/pdf/2605.09998) | The main agent | A **fog-of-war minimap of explored tiles**, plus a **Pathfinder sub-agent**: a fresh-context model given only A→B and the map | An "explore every tile" directive was "transformative": it "almost never said it was stuck". Summary resets and a critic helped, though the critic sometimes hallucinated. Continual Harness (2026) mines trajectories for "navigation loops, tool-call failures, stalled objectives" and rewrites skills and memory. |
| **Claude Plays Pokémon** [S] [Latent Space](https://latent.space/reading/claude-plays-pokemon/) | Button presses, knowledge base (about 8k-token cap) | A `navigator` tool | Reminders when there has been no movement for about 30 steps. It was still stuck in Mt Moon for about 78 h. I found no official Anthropic write-up. |

**The common pattern.** In every reliable system the LLM issues **one goal-level call per journey**. A code skill then owns every retry, re-path and unstuck manoeuvre on wall-clock timers: 3.5 s in mineflayer, 20 s in Mindcraft, 2 s replanning in exploreUntil. The model hears back only on a **terminal outcome**. Failure caps sit *above* the model: 4 rounds per task (Voyager), 30 queries per sub-goal (GITM), 3 no-command turns (Mindcraft). When a cap is hit the task is marked failed and the agent moves on. It does not retry forever.

Our stack inverts this. go_to returns early with a refusal (`route_ended_before_goal`), so every partial route becomes a model call.

---

## 2. Semantic maps and perception: what helps navigation

| Technique | Who uses it | Evidence that it helps |
|---|---|---|
| Explored-area grid with visit counts, and exploration toward the least-explored area | GITM 20×20 chessboard BFS [P]; MrSteve count-based "least-visited" goal selector plus **Place Event Memory** (what/where/when) [P] [arXiv 2411.06736](https://arxiv.org/html/2411.06736v5); Gemini fog-of-war [P] | Strongest anecdotal effect: Gemini's stuck reports nearly vanished. MrSteve's ablations favour place-event memory over FIFO memory. |
| A precomputed area graph with **typed reachabilities** (walk, barrier jump, jump, walk-off-ledge, ladder, teleport, elevator, jump pad) and travel times | Quake III AAS [P] ([be_aas_reach.c](https://raw.githubusercontent.com/ioquake/ioq3/main/code/botlib/be_aas_reach.c)) | Shipped bots navigated every map with no LLM. Jump links are validated with `AAS_PredictClientMovement`, a simulation of the real player physics, and accepted only if the predicted landing lies in the target area. |
| A walkable-tile map plus a **transport table** (origin, destination, option, skill/item/quest requirements, duration) from the wiki and in-game testing | RuneLite Shortest Path (OSRS) [P] ([Transports wiki](https://github.com/Skretzo/shortest-path/wiki/Transports)) | About 225k active installs. Teleports and shortcuts are just edges. A direct analogue for lodestones and Windstep ledges. The Pathfinding wiki page did not load. |
| Reusing past successful paths as a graph that biases search ("experience graphs") | E-Graphs, Phillips et al. RSS 2012 [S] ([RSS](https://roboticsproceedings.org/rss08/p43.html)) | Complete. Falls back to planning from scratch when no experience applies. Accepts human demonstrations as bootstrap. |
| Teach-and-repeat: record a route once, re-drive it | Furgale & Barfoot 2010 [S] ([JFR pdf](https://furgalep.github.io/sbib/furgale_jfr10.pdf)) | 32 km at 99.6% autonomy, abstract-level numbers. |
| Named places | Mindcraft `!rememberHere` / `!goToRememberedPlace` [P] | Cheap; gives the model goals, not reachability. |
| Vision (VLM over pixels) | SIMA 2, Lumine, CRADLE, JARVIS-1, Optimus | These systems report **navigation and exploration as their top failure**. Vision buys generality, not navigation reliability. |

**Cheapest effective option for us.** No vision: GITM reached its results with rays and voxels only. We already hold better-than-vision state: positions, actor lists, navmesh queries, line traces, `navmem` trajectories, `traversal_moves` (djump measured at 3.07 m), lodestones and province polygons. The highest-value missing piece is a **single persistent traversal graph**:

- **Nodes:** places, lodestones, and recorded-route waypoints.
- **Edges:** typed `walk | jump | djump | windstep | teleport`, each with observed success/failure counts and time.

Pair it with a coarse **explored-cell grid**, roughly 10–20 m cells with visit counts and "failed from here" marks. Plan over the graph plus the navmesh. Show the model one line, for example `known route: yes (3 legs, 2/2 past successes) | frontier: NE unexplored`, not floor columns. (`terrain.lua` added 4.6–5.9 KB per result and changed no outcome, per the audit.)

---

## 3. Breaking no-progress loops, and navigating where the navmesh is incomplete

### 3a. Loop detection and escalation (all [P] unless marked)

- **Reflexion's heuristic** ([arXiv 2303.11366](https://arxiv.org/html/2303.11366v4)): "same action and … same response for more than 3 cycles, or … actions … exceeds 30" → reflect, or reset the trial.
- **OpenHands StuckDetector** ([docs](https://docs.openhands.dev/sdk/guides/agent-stuck-detector), [SDK source](https://github.com/OpenHands/software-agent-sdk/blob/main/openhands-sdk/openhands/sdk/conversation/stuck_detector.py)):
  - Thresholds: 4+ identical action–observation pairs; 3+ identical action–error pairs; 3+ monologue turns; 6+ A/B ping-pong cycles.
  - Events are compared semantically (tool plus content, ignoring ids and timestamps).
  - When stuck, it goes to ERROR or emits a `LoopRecoveryAction`.
  - Issue #4331 notes it had no "corrective nudge" step before termination. **We should add that step.**
  - The raw `stuck.py` URL on the old repo returned 404, so I used the docs and the SDK search snippet.
- **Hard per-unit caps:** Voyager 4 rounds per task; GITM 30 queries per sub-goal; Mindcraft 3 no-command turns.
- **Progress, not activity:** mineflayer uses time since the last path node; Mindcraft uses displacement over 20 s; Claude Plays Pokémon uses about 30 steps without movement [S]; PIANO compares expected and observed outcomes.
- **Escalate or give up:**
  - Voyager returns failed tasks to the curriculum as "too hard", to retry later.
  - Lumine shows what happens without memory of failure: it keeps returning to the same spot.
  - Gemini's fresh-context Pathfinder sub-agent and its critic are a "second opinion" escalation.

### 3b. Navigation where the navmesh is incomplete

- **Why NPC navmesh and player can disagree.** Navmesh agent parameters (`AgentMaxSlope`, `AgentMaxStepHeight`, radius, cell size) are configured separately from the `CharacterMovementComponent` (`WalkableFloorAngle`, `MaxStepHeight`). Forum guidance says they should match, with the navmesh value no higher than the movement component's [S] ([forum](https://forums.unrealengine.com/t/ai-refuse-to-navigate-steps-despite-having-a-valid-nav-mesh/639300)). A ramp just over the navmesh slope, or a mesh flagged not to affect navigation, gives exactly our temple ramp [K].
- **UE 5.5 can auto-generate jump-down NavLinks** (experimental `FNavLinkGenerationJumpDownConfig`) [P] ([Epic docs](https://dev.epicgames.com/documentation/en-us/unreal-engine/automatic-navigation-link-generation)). That runs at navmesh build time, so it is unusable on vanilla Shockbyte. The design is still the one to copy: edge-by-edge sampling of drop and jump candidates, validated before acceptance.
- **Player-capsule planners without a navmesh:** mineflayer's grid A* over a player `Movements` model; GITM's voxel A* "toward the nearest reachable point"; Quake AAS's predicted-movement validation of jumps. Our `localplan` trace grid is this pattern, so keep it as the *fallback*, not a gate.
- **Recorded trajectories as reusable routes:**
  - E-Graphs and teach-and-repeat (above), OSRS transports (edges with requirements), GITM memory (merge 5 successful plans into one).
  - Our a902/a903 finding fits: the basin had COMPLETE native paths to the entries of the r132/r138 routes, 58–81 m away, but `navmem` only attached within 4 m.
  - The standard fix is a **connector search**: query native paths from the current position to the K nearest graph nodes and run Dijkstra over (native leg + graph). Do not widen the straight-line attach radius.
- **Exploration when nothing is known:** frontier-based exploration toward the boundary between explored and unexplored space (Yamauchi 1997 [K]); GITM BFS; MrSteve least-visited.

---

## 4. What successful projects measure

| Project | Goal metric |
|---|---|
| Voyager | Unique items (63 in 160 iterations); iterations to each tech-tree tier (wood 15.3× faster … diamond once in 3 runs); **distance travelled** (2.3×) |
| GITM | Success over the 262-item Overworld tech tree; ObtainDiamond 67.5% within a 10-min limit |
| JARVIS-1 / Optimus-1 | Success rate per task group (wood, stone, iron, gold, diamond, redstone, armor), plus **average steps and time** (Optimus-1) |
| Odyssey | Long-term planning tasks, dynamic-immediate (combat) tasks, and one autonomous-exploration task |
| PIANO | Unique items per agent over 30 min and 4 h |
| MineCollab | Binary task success; edit distance for construction |
| SIMA 2 | Task success on held-out games against humans; how far up the tech tree it gets (an ASKA shelter within 1 h) |
| Lumine | Wall-clock completion of a 5-hour main story, against human time |
| PokeAgent | Speedrun-to-completion. The milestone scheme itself was not found in the abstracts. |

What they share: **outcome milestones read from game state, with a time or step budget, over repeated trials**. None of them gate on internal infrastructure.

---

## Recommendations for us (ranked by expected impact ÷ effort)

1. **Make go_to a terminal-outcome skill and delete the refusal gates.** *Impact: very high. Effort: low (mostly deletion, per the audit's DELETE/SIMPLIFY map).*
   - The model calls go_to once. In Lua, the skill cycles native path → recorded-route connector → `localplan` capsule walk → bounded "move away and re-path". Use mineflayer/Mindcraft-style timers: about 3–5 s without node progress triggers a re-path; about 20 s without displacement triggers an unstuck manoeuvre.
   - Keep only the KillZ guard.
   - Return exactly one terminal result: `arrived`, or `stuck at X after {native partial 62 m, trail, local plan}; nearest unreached: ramp at Y; needs: Windstep?`. The model can say that verbatim.
   - Target: at least the 56–58% baseline, and ≤ 2 model calls per journey leg, against about 40 today.
2. **Brain-side stuck detector with nudge, then report, as an advisory.** *Impact: high (tokens). Effort: low.*
   - Hash `(tool, normalised args such as goal rounded to 5 m, outcome reason)` over the episode.
   - On the 2nd identical failure, inject a "STUCK" note into the next prompt: what was tried, why it will fail again, and the untried alternatives from the graph and frontier.
   - On the 3rd, the turn must end in a `say()` to the player stating the reason and what would help, and the sub-goal is marked failed back to the Director, as with Voyager's "too hard" list.
   - Add a per-sub-goal model-call budget (GITM uses 30; about 8 fits us).
   - This *informs* and enforces budget only; it never rewrites the model's choice. That keeps within Luis's "code informs, doesn't veto" rule and his communication rule.
3. **One persistent traversal graph from verified trajectories, with a connector search.** *Impact: high (fixes ramp-class gaps permanently). Effort: medium; `navmem` exists.*
   - Build it E-Graph / OSRS-transport style.
   - Record every completed own or leader segment as typed edges with success counts. Demote an edge after k failures.
   - Make lodestones teleport edges.
   - Plan with Dijkstra over native legs to the K nearest nodes plus graph edges. This fixes a902 directly.
   - One Luis-walked (or self-walked) pass up the temple ramp then becomes a permanent edge, not a per-move gate.
4. **Explored-cell grid and frontier exploration as the "no known route" behaviour.** *Impact: medium. Effort: low–medium.*
   - Visit counts and "failed from here" marks per cell.
   - Exploration targets the least-visited reachable frontier toward the goal, not the original goal again. That is Lumine's failure, and our a885 "returns to the failed basin".
   - Expose it to the model as one line.
5. **Learn traversal edges at navmesh boundaries, AAS-style.** *Impact: medium. Effort: medium.*
   - When the native path ends short, sample ledge and ramp candidates, attempt the real input (walk, jump, djump, later Windstep), and verify the landing from state.
   - Store successes as graph edges. This is offline or idle-time learning, not inline gating.
   - Also log the navmesh agent parameters against the CMC parameters once, to know which terrain classes to expect [K].
6. **Reframe the goal around outcomes with budgets** (proposals for Luis):
   - **G1 Travel reliability:** a fixed set of 20 dev-world journeys (25 / 100 / 200 m, including the temple ramp, a lodestone hop and one cross-province trip), run k = 3. Metrics: Wilson-lower-bound success, **model calls per 100 m**, time against a scripted or human baseline, and **0 silent failures**. This is the Voyager-distance and GITM-approach analogue, and it gates everything else.
   - **G2 Fresh-character progression ladder:** from a new character, unaided, measure **time and model calls to each milestone**: stone tools → workbench and base chest → first copper/tin smelt → bronze gear equipped → iron. Read from game state, like the Voyager and GITM tech tree. A plateau of no new milestone in 20 min counts as a failure signal.
   - **G3 Co-play session score:** a 30-min session with about 15 natural chat requests (follow, come, gather, kill, give, travel). Metrics: fulfilment rate, chat → first action p50, share of failures reported truthfully with a reason, and tokens per hour. This is the MineCollab and PUBG Ally analogue.
   - Keep M1–M6 as the long-range map. Report G1–G3 weekly, because they move with real fixes and expose infrastructure that doesn't help.
7. **Don't add vision or more guard layers.** *Impact: avoids regressions.* The vision agents' top failure is navigation, and our guards caused most of the 10-28 to 10-30 failures.

### Searches that found nothing or were incomplete
- The OpenHands `stuck.py` raw URL returned 404; I used the docs and the SDK source summary instead.
- The Quake III thesis PDF links returned 404; I used the ioq3 `be_aas_reach.c` source instead.
- The dhewm3 AAS wiki blocked the fetcher (Anubis).
- MineCollab and PUBG Ally describe no runtime stuck or failure handling.
- PIANO does not describe navigation.
- The RuneLite Pathfinding wiki page did not load.
- I found no official Anthropic write-up of Claude Plays Pokémon.
- I could not find the PokeAgent milestone metric.
- The Tavily search hit a rate limit (429) partway through; I used WebSearch and WebFetch after that.
