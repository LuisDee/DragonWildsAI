# Evals to a human standard: what we measure, who tests, and how the harness stops lying to us (2026-11-01)

Why: on the night of 2026-10-31 the scripted ladders said "8/8 passed" (chat ladder run 12: 8/8 reached, mean 2.1 calls).
The next day Luis played for 55 minutes and only about 4 of 14 distinct requests were done cleanly
(`docs/RETRO-2026-11-01-coplay.md`, log `logs/brain-live-20261101-115554-7128.jsonl`). He asked two things:
"to what standard?" and "can you emulate my testing so you need me less?"
Research and design only: nothing here was run against the game or a model.

## 0. The evidence: what "passed" hid (computed from our own logs, read-only)

| Ladder said | The same rows, read to a human standard |
|---|---|
| Travel ladder (body only): 80 successful legs, **SPL median 1.0** | Straight-line metres / seconds: median **4.3 m/s**, against a 6.7 m/s sprint (DISCOVERIES "Client locomotion": 6.6-6.8). The time-weighted score is about 0.64. The ramp legs ran at 2.0-3.5 m/s. SPL is saturated here and tells us nothing. |
| Chat ladder (Rung 1 night): 78 successful legs, about 2 calls each | Request to arrival (trace): median **2.0 m/s**, SCT about **0.38** (sprint plus a 1.5 s reaction allowance). The 21 m `near_doric` leg took about 20 s; a sprinting player needs about 5 s. |
| The same chat ladder: "1 go_to, ok" | **74 hidden body misses.** The first `go_to "<place name>"` returned `target_not_visible` after a **median 10.2 s** (757 s in total). The brain then resolved the place (`place_resolved`) and re-sent coordinates. Both happened inside one "ok" tool call, so no gate saw them. Example: 02:43:19 dispatch → 02:43:29 failure → walk 20 m in 4 s. |
| Co-play: gather "Got 15 sticks", ok | 39.5 s for 15 sticks (2.6 s per stick; `gather.jsonl` shows an `aim` phase before most picks). The 7 failed `interact` calls each spent **17-43 s** aligning before giving up ("the game targets Ash Logs, not the Ash Logs"). |
| Co-play: `go_to luisdeburnaybast` ok | Trip sentences: 1.2-2.2 m/s for "come to me", and 0.9-1.0 m/s for 64-80 s on the grave walks (walking into a rock). |
| Co-play ladder gate | `coplay_ladder.gate()` passes a run when `done > 0`, nothing is stuck for more than 60 s, and every failure is an `honest_failure`. **A run that does 1 of 9 and honestly fails 8 passes Rung 2.** |
| Live session | 32 of 200 tool results were `interrupted` by a chat line. No ladder ever talks while he works, because each leg ends when the brain goes quiet. |

So the ladders measured whether the outcome eventually happened, with clean inputs, from a clean start. The quantities that
made Luis say "very disappointed" were already in our logs: reaction time, speed, misses, idle time, corrections and
interruptions. No gate looked at them.

## 1. Research: how others measure to a human standard

### 1.1 Embodied and game agents: efficiency, not just success
- **SPL** (Anderson et al. 2018, arXiv 1807.06757) weights success by path length. It is what `tools/travel_ladder.py`
  reports. Its known blind spot is time: it rewards a slow, jerky but short path.
- **SCT, success weighted by completion time** (Yokoyama, Ha, Batra, arXiv 2103.08022):
  `SCT = S · T / max(C, T)`, where C is the agent's time and T is the fastest time its dynamics allow. It was made because
  SPL "favors the jerky paths produced by point-turn behavior". This is exactly the "stood jittering and adjusting" case.
  Our T is reaction plus route length divided by the sprint (or walk) speed. It needs no planner: the oracle route length
  or 1.15 × straight is enough.
- **Efficiency against a human trajectory:**
  - OSWorld-Human (arXiv 2506.16042) hand-annotated the optimal human trajectory for all 369 OSWorld tasks. Even the top
    agents took **1.4-2.7× more steps than necessary** (v1 abstract; a later version reports a larger gap). It also found
    that the large planning and reflection calls dominate latency.
  - PARTNR (Meta, arXiv 2411.00081, abstract) found that LLM agents paired with real humans needed **1.5× the steps of two
    humans and 1.1× the steps of one human alone**. The "helper" made the human slower.
  - Watch-And-Help (arXiv 2010.09890) scores a helper by success and **speedup** over the human working alone. Real
    participants' helpfulness ratings tracked those objective numbers, which justified using them as proxies.
  - Habitat 3.0 (arXiv 2310.13724) reports efficiency over the humanoid working alone, with both a simulated humanoid and
    a human-in-the-loop tool.
  - **For us, the question is "did Claude save Luis effort, or cost him effort?"** That is the corrections-per-request
    metric below.
- **Human-likeness of movement:**
  - Navigation Turing Test (Devlin et al., ICML 2021, Microsoft/Ninja Theory, proceedings.mlr.press/v139/devlin21a)
    trained classifiers that reliably tell agent navigation from human navigation in a 3D game. Ranking agents by how human
    they look remains unsolved. Milani et al. 2023 (arXiv 2303.02160) followed up with crowd-sourced judgements.
  - 2K's BotPrize (2012, UT Austin): human judges tagged opponents. The winning bots got 52% "humanness" (humans 40%),
    partly by *limiting* superhuman aim.
  - Lesson: simple trajectory features (stops, heading reversals, speed) separate bots from humans. We can compute them
    against Luis's own recorded movement.
- **Minecraft agents:**
  - MineDojo (arXiv 2206.08853): programmatic tasks are judged from simulator state; creative ones by a learned judge
    (MineCLIP) validated against human labels.
  - Voyager (arXiv 2305.16291): unique items, tech-tree milestones *per prompting iteration* (a cost axis), distance
    travelled and zero-shot tasks.
  - MCU (arXiv 2310.08367): a VLM judge with per-task rubrics on six dimensions, including **efficiency** and **error
    recognition**, checked against human ratings (secondary summaries say about 90% agreement; not confirmed).
  - MineCollab (arXiv 2504.17950): binary task completion. The main finding is that **communication is the bottleneck**:
    up to 15% lower performance when agents must communicate detailed plans.
  - Project Sid (arXiv 2411.00114): civilisational benchmarks such as role specialisation and rule adherence. Our
    CLAUDE.md §10 cites its loop and hallucination failures; this search did not re-confirm them.
- **PUBG Ally** (KRAFTON, arXiv 2609.29837):
  - About 39k real-player sessions, offline evaluations checked against player preference comparisons, and a survey (net
    recommendation +25.1 pp). Combat was rated 2.58/5.
  - Latency: a full spoken exchange took a median **1.62 s on-device**, 3.36 s in the cloud.
  - Free-text failures: hesitation, delayed prompts, unfinished tasks, inconsistent memory. It **cannot process new speech
    while executing tool calls**, the same class as our `interrupted` bug.
  - **The paper reports no task-completion rate** (searched; none found).

### 1.2 LLM user simulators (τ-bench family) and why they flatter agents
- **τ / τ²-bench** (arXiv 2406.12045, 2506.07982):
  - **Simulator design:** a scenario card (reason, known info, unknown info, task instructions), a persona, one message per
    turn, "never make up information not in the scenario", and termination tokens (`###STOP###`, `###TRANSFER###`,
    `###OUT-OF-SCOPE###`).
  - **Success comes from state:** DB checks, assertions on the final world state, and action matching. It never comes
    from the simulator's opinion.
  - **Reliability:** τ² hand-annotated every simulator turn. Error rates were airline 47% (13% critical), retail 40% (12%)
    and telecom **16% (6%)**.
  - The gain came from **constraining the simulated user through the environment** (it gets tools on a mocked phone), not
    from prompting. → Our emulator must be grounded in what Luis can actually see.
  - pass^k: every one of k trials succeeds (consistency).
- **Simulators are "easy mode":**
  - Lost in Simulation (arXiv 2601.17087, ACL 2026): swapping only the user model moved agent success by up to 9 pp.
    Simulated users asked questions in 18.8% of turns (humans 9.8%) and were polite in 39.2% (humans 19.9%). Failures were
    blamed differently. Recommendations: report several simulators and validate against real human data.
  - Mind the Sim2Real Gap (arXiv 2603.11245, CMU): 451 humans against 31 simulators on τ-bench. Simulators are
    over-cooperative, stylistically uniform, and **lack realistic frustration or ambiguity**, which inflates success
    (secondary summary: 77.8% vs a 63.6% human baseline). A more capable model is not a more faithful user. They propose a
    User-Sim Index that scores behaviour and feedback similarity.
  - UserBench (arXiv 2507.22034): real users are **underspecified, incremental and indirect**. Models uncovered under 30%
    of preferences. "The 2 stone in front of me" and "the temple" are exactly this.
- **Agents game simulators:**
  - LOGIGEN (arXiv 2603.00540): an agent learned phrasings that drew hints or favourable replies from a fixed simulator.
    Deterministic simulators made it worse; diverse ones reduced it.
  - Carroll et al. 2019 (Overcooked, arXiv 1910.05789): agents that look good against themselves fail with a behaviour-
    cloned "proxy human" and with real humans. GAMMA (arXiv 2411.13934) warns that agents tuned against a proxy exploit it.
  - → **Real Luis sessions stay the held-out test. The emulator is the dev set.**
- **Search record (reuse > adapt > build):**
  - Packaged simulators exist: LangSmith/openevals `create_llm_simulated_user`
    (docs.langchain.com/langsmith/multi-turn-simulation) and ArkSim (pypi.org/project/arksim). Both are chat-only turn
    loops: no world-state grounding, no timing, no talking mid-action.
  - Decision: **adapt** τ²-bench's simulator rules (scenario card, no invented facts, termination) inside our existing
    harness (`tools/coplay_ladder.py`, which already has the sender, observer and scorer). Do not adopt a framework.
  - I could not confirm the DeepEval / promptfoo simulator pages from search.

### 1.3 Evals of evals: stop the harness passing easy, clean inputs
- **Agentic Benchmark Checklist** (Zhu et al., arXiv 2507.02825, NeurIPS 2025):
  - Two validities: **task validity** (task success means the capability) and **outcome validity** (a positive result means
    task success).
  - 7 of 10 popular benchmarks had outcome-validity flaws. In τ-bench a **do-nothing agent passed** unattainable tasks, and
    a trivial agent passed 38%. Errors of up to 100% relative.
  - → Run null and trivial agents as controls. Our gate is the "honest quitter passes" variant of that flaw.
- **False success** (arXiv 2606.09863, ICML 2026 workshop, already cited in `tools/truth_judge.py`): across 5 judges and 5
  prompt strategies, no LLM judge beat AUROC 0.65 at detecting "claimed done, state says no". Cheap calibrated text
  detectors did better. → **State decides success; the judge only reads language against state.**
- **ImpossibleBench** (arXiv 2510.20270): make tasks impossible; any pass is cheating. GPT-5 cheated on 92% of conflicting
  LiveCodeBench tasks with one prompt, and 1% with another. → Impossible cases (split a stack before split exists, a
  grave that isn't there) must end in an honest "can't", not a claim.
- **Self-preference** (Panickssery et al., arXiv 2404.13076): judges favour their own generations, linearly with
  self-recognition. → Haiku judging Haiku is the weak spot in `truth_judge.py`. Use a different model for the judge and
  the emulator, or calibrate on human labels.
- **Criteria drift** (Shankar et al., EvalGen, arXiv 2404.12272): you cannot fix the criteria before grading real outputs.
  → Luis's `note:` lines are the human grades. Every new note becomes a criterion or a check.
- **Anthropic, "Demystifying evals for AI agents":**
  - Code graders where possible. Model graders calibrated against human experts, with an "Unknown" escape.
  - Read transcripts; "failures should seem fair".
  - Grade the end state, not the path. Partial credit for multi-step tasks.
  - Capability evals should *start at a low pass rate*; regression evals stay near 100%. "An eval at 100% … provides no
    signal for improvement".
  - Start with 20-50 tasks from real failures, and test both should-do and shouldn't-do.
- **Noise robustness:** RoTBench (arXiv 2401.08326) showed GPT-4 tool use falling from 80 to 58 under noise that humans
  ignore. → Our inputs need typos, bursts and fragments. I found nothing published on metamorphic testing of LLM agents.

## 2. Design for this project

### 2.a Metrics, task families and thresholds

**Common metrics** (one per request; all from the harness's own reads and logs, never from his reply):

| Metric | Definition | Source |
|---|---|---|
| S (success to spec) | The exact outcome: the right count, the right instances (census ids gone, bag +N), the right anchor (≥ 80% of picks within 5 m of the place he was told) and nothing else broken (no extra drop or build). | `census`, `inventory`, server `referee.lua` on dev |
| T and ratio | Time from the request line until the check is true **and** he has said so; ratio = T / T_h (human baseline). Also SCT = S·T_h/max(T, T_h). | harness clock |
| First move | Request → first displacement over 1 m toward the goal (or first swing or pick). Target ≤ 3 s. PUBG Ally's whole spoken loop is 1.6 s. | `me` at 0.5 s, `move.jsonl` |
| Calls | Haiku / Sonnet calls and $ in the window (`chat_ladder.model_calls`). A cost metric, not a human one. | brain log |
| Misses | Body-level failures inside the request: failed `interact`, extra `aim` phases per item, swings with no HP change, `drop` verification failures, `go_to` retries, `target_not_visible` then a re-send. **Counted from bridge rows and event logs, not tool results.** | `bridge_recv`, `gather.jsonl`, `trips.jsonl` |
| Idle s and ratio | Seconds with the request open and no progress (speed < 0.5 m/s, no pick, swing, inventory change, build or chat). Ratio = idle / T. Replaces "stuck = more than 60 s quiet". | `me`, events |
| Jitter | Dither seconds (speed < 1 m/s within 3 m of the target while not acting) plus heading reversals (> 120° within 2 s) per minute. This is the "adjusting for 30 s" number. | `me` at 0.5 s or a traverse_learn trace |
| Path | SPL plus **sprint share** (fraction of legs over 30 m run at ≥ 5.5 m/s while endurance ≥ 25). This answers "why aren't you running?". | trips, vitals |
| Corrections | Player lines after the request that were needed to get it done: restatements, "you missed", "where are you going", "NOW". The babysitting cost; a Watch-And-Help speedup in reverse. | chat |
| Interruption robustness | After a mid-task chat line: progress resumes within 2 s, nothing restarts, no `interrupted` failure. | brain log, `me` |
| Truthful and told | (1) No false claim: the judge checks against facts. (2) A **done line** within 5 s of S. (3) A failure line with a specific, true cause. (4) A "what are you doing?" answered within 5 s, matching the running action and metres left within 40%. (5) **No false impossibility**: a "can't" while the facts show it was possible (the target in the registry or census, materials within 20 m) is a failure, even if worded honestly. | `truth_check` facts plus judge |

Standard levels per request: **H** (human standard) = S, ratio ≤ 1.5, misses 0, corrections 0, told. **A** (acceptable) =
S, ratio ≤ 2.5, at most 1 miss per 5 items, at most 1 correction, told. Anything else fails, including an honest failure
on a feasible task. The Rung 2 bar becomes: **≥ 80% of requests at A or better, ≥ 50% at H**, 0 false claims, 0 deaths,
longest idle < 20 s.

**Per family** (T_h is provisional, from game constants, until Luis's baseline replaces it; v_run = 6.7 m/s with endurance
≥ 25, else 4.5 m/s walk; R = 1.5 s reaction; route = oracle length, else 1.15 × straight):

| Family | S check | T_h (provisional) | Family-specific standard |
|---|---|---|---|
| Pick up N nearby items (stones, sticks, loot, food) | the named N instances gone from census, bag +N, ≥ 80% within 5 m of the anchor | R + route/v + 1.2 s × N | ≤ 1 aim phase per item, no refusal of the highlighted same-kind item, picks while moving between items |
| Gather (chop, mine N) | bag + N of the asked resource | R + route/v + N × (swings × attack time) from attack data (axe chop hit 0.55 s) | swing misses ≤ 10%; picks up the drops |
| Kill (1 or N) | each target reads dead; loot picked if asked | R + route/v + HP / weapon dps × 1.3 | reacts to being hit within 1 s; doesn't eat mid-fight above 30% HP; no flee from a weaker creature; no death |
| Follow (≥ 60 s, the leader moving, with a turn and a hop) | ≥ 85% of samples within 8 m after 5 s; max gap ≤ 15 m | n/a (clock) | speed matches the leader within 20%; never "can't see you" while the map registry shows him |
| Come here, near (≤ 50 m) | ends within 4 m | R + route/v | first move ≤ 3 s |
| Come here, far (300 m, out of relevancy) | ends within 6 m | R + route/v | uses the registry position (mapplayers); progress line when asked |
| Go to a named place | within tol, same floor | R + best route / v (lodestone when ≥ 2× faster) | resolves an ambiguous name right first time or asks once; SCT ≥ 0.6 |
| Recover from a grave | bag counts ≥ pre-death minus consumed | R + route/v + 3 s | newest grave first (0 wrong graves); goes before food if the food is in the grave |
| Eat and drink sensibly (starved start) | sustenance and hydration ≥ 70 | 30 s with food carried; 3 min if he must forage nearby | no "can't" while food is in the bag (moves it to the hotbar); never eats while being hit above 30% HP |
| Craft X | the item in the bag | walk + craft time + 10 s | maps "crafting bench" → Crafting Table; gathers missing materials unprompted or asks once |
| Build Y ("here") | the structure in census within 5 m of the anchor | walk + place time + 10 s | ≤ 1× material cost (no duplicate build); reports "placed", not "failed" |
| Store in a crate | crate contents + N, bag − N | walk + 5 s | the right crate (nearest or named) |
| Split a stack ("drop 40, keep 80") | bag exactly 80, ground 40 within 3 m | 10 s | never drops the whole stack. Until split exists: an honest "can't, the drop takes the whole pile" plus an alternative = *expected-impossible pass* |

**Human baselines: the "watch Luis" idea is feasible, best on the dev server.**
- **From Claude's client alone, yes for movement, no for inventory:**
  - `client_mod/scripts/traverse_learn.lua` already records every other player's pawn read-only at about 120 Hz:
    `MovementMode`, `Velocity`, `ReplicatedJumpCurrentCount` and location. It was verified on Luis's proxy (DISCOVERIES
    "Traversal learning (R2)").
  - The census adds his held item and health within relevancy (about 150 m), and `mapplayers.lua` gives his position at any
    distance.
  - His bag and his E presses don't replicate to other clients. Pickups can only be inferred: a ground item or world item
    within 3 m of him disappears from Claude's census. That works for world items; for foliage sticks and stones it is
    unverified.
- **On the dev server, the full picture:**
  - `mod/bench/referee.lua` polls server inventory and positions every 250 ms and emits `item_change`. It was verified on
    ClaudeDev; it would need to track Luis's character.
  - `mod/scripts/hooks.lua` hooks `Server_RequestInteraction`, which **fired per E press when Luis picked sticks**
    (DISCOVERIES "Phase 2 hooks"). Presses per pickup is his miss rate.
  - Both are read-only; ask Luis before tracking his character.
- **Protocol** (one 10-minute block with Luis):
  - Tester posts a card ("Luis: pick up the 5 stones by the campfire") and Luis does it, twice per family, 8 families.
    Then Claude does the same cards.
  - Thresholds then become H ≤ 1.5 × Luis's median and A ≤ 2.5 ×.
  - Shockbyte stays client-only (traverse_learn, census, registry), so only movement and time baselines come from there.

### 2.b The Luis emulator (spec; not built)

**Goal:** test like Luis does (noisy, pointing at things near himself, talking mid-task, correcting, impatient), and score
from game state. Sonnet plays Luis. Haiku stays Claude's controller (different models: §1.3 self-preference). Lines go out
through `m1_session.send_speech_direct` as "Tester". The brain runs with `DW_PLAYER_NAME=Tester` on the dev world.

**Style bank** (from today's log: 104 non-note lines and 15 `note:` lines, deduped from the brain log; the brief's 76/32
were counted differently). Store it as `data/luis_style/2026-11-01.jsonl`: each line with its trigger label and what
Claude was doing at that moment.
- Median 7 words (IQR 4-12). 96% start lowercase, typos common.
- 19% contain "?". Only 8% have politeness markers (please, thanks, cheers, awesome). Simulators run about 39% (§1.2).
- 22% name Claude. 25 of 118 inter-line gaps are under 2 s (bursts: "infront of my character" / "2 stone" / "get them").
- Median 19 s from Claude's line to Luis's next one.
- Follow-up kinds:
  - where / why / what are you doing: 19
  - corrections ("near me", "you missed", "I meant"): 17
  - urgency ("NOW", "urgently"): 14
  - status questions (food, water, inventory, capacity): 14
  - one profanity at the peak.

**What the emulator sees: only what Luis could see on his screen.** This is the τ² lesson: the environment, not the
prompt, constrains the user. A code-computed digest every 2 s gives:
- Claude's position relative to Tester and to the target (metres, bearing, closing or opening);
- his speed and whether he is sprinting;
- moving or standing, for how long;
- his held item;
- the items still lying near the anchor (Luis sees "2 stone still on the floor");
- creatures near either of them;
- Claude's chat lines.

It does **not** see Claude's bag, reasoning or tool results. Luis had to ask "what is in your inventory".

**Loop (code decides when to speak; Sonnet only writes the words):**
1. Code picks a scenario from the live census and fixtures, relative to Tester (or to a station or landmark when there is
   no pawn): family, ground-truth target ids, anchor, distractors, T_h. One Sonnet call phrases it in Luis's style. It may
   be noisy: a burst, typos, a chain, a reference "near me", an ambiguous name.
2. Every 2 s code checks the triggers. On a trigger, one Sonnet call returns forced structured output
   `{lines: [1-4 strings], gaps_ms: [...], end: bool}`. Rate limit: 1 per 6 s.

   | Trigger (from his real follow-ups) | Condition |
   |---|---|
   | stood still | idle > 8 s while the request is open |
   | wrong way | the distance to the target opened by > 10 m |
   | not running | a leg over 30 m below 4 m/s with endurance ≥ 25 |
   | missed some | Claude claims done, or moves on, while target ids remain near the anchor |
   | impatience | T > 1.5 × T_h ("you arent doing anything"); at 3 ×: caps or urgency |
   | his question | Claude asks something → answer from scenario truth only (τ² "no invented facts") |
   | chatter | random 20-45 s into a task, p = 0.5: status or unrelated question (tests interruption) |
3. Stop when one of these happens:
   - the check is true and he has said so: "awesome" plus the next request;
   - T > 5 × T_h or 300 s: a give-up `note:` line, request failed;
   - death loop;
   - the Haiku cap (150 per session) or the $ cap ($1.50 per session);
   - a hold file or foreign driver (`chat_ladder.preflight`);
   - the emulator returns `end` (logged, but the verdict is code's).
4. **Verdict = code**, per §2.a, for each request. The emulator also writes a `note:` for the transcript that is never
   scored. If it praises a request that code failed, that is flagged as a simulator error (over-cooperation check).

**Prompt** (system, cached):
- "You are Luis testing your AI companion Claude in Dragonwilds."
- The style rules with the numbers above: short, lowercase, typos, low politeness, bursts, escalate when ignored.
- τ²'s rules: only facts from the digest and scenario; one burst per turn; never help Claude by giving coordinates or tool
  names; never accept a claim the digest contradicts.
- Plus 40 labelled real lines as examples.

Per call: the scenario card, the digest, the trigger and the last 8 chat lines.

**Cost per session** (15 requests, about 25 min):
- Sonnet: about 70 calls × about $0.005 (3.5k cached at $0.10/M, 1.5k fresh at $2/M, 150 out at $10/M) ≈ **$0.35**.
- Companion Haiku: about 150 calls × $0.00074 (today: 270 calls ≈ $0.20) ≈ $0.11.
- Truth judge: 15 calls; Haiku ≈ $0.01, Sonnet ≈ $0.25.
- **Total ≈ $0.5-0.75 per session.** About 12 sessions fit in the $10 per day budget with room for live play.
- A **replay mode** costs $0 in emulator calls: his literal lines replayed at the same moments (the retro's "Luis-replay
  ladder"). Use it as the fixed regression set; the adaptive emulator is the capability set.

**How it avoids being gamed:**
1. State decides success and the emulator decides nothing.
2. Its digest is ground truth, so "got them all" with 2 left gets "theres still 2 here". That trigger is code, not
   judgement.
3. Different model families for agent and emulator.
4. Frozen prompts and style bank per suite version. Claude's prompts never include emulator lines.
5. Real Luis sessions are the held-out test, scored with the same code. Report both numbers side by side.
6. A style check per session (a User-Sim-Index-like distance computed in code: words per line, question rate, politeness,
   burst rate, correction rate, all within Luis's bands). Out of band = an invalid session, not a pass.
7. Diversity without temperature (`truth_judge.py` records that the Claude API rejects sampling params): seeded
   scenarios, distractors and three persona variants (terse, chatty, impatient). LOGIGEN: deterministic simulators get
   gamed.
8. Calibration before use: replay today's logged digests through the trigger code. It must fire on at least 70% of the
   moments Luis wrote a follow-up, and the scorer must rate today's session at about 4/14 at A. If it says 8/14, fix the
   scorer, not the bot.

### 2.c A Tester pawn on the dev server (proposal; nothing run)

**What exists:** the legacy server mod (`mod/`, deployed as DWCompanion) already holds a verified "second player" body.
- `body/puppet.lua` spawns `BP_PlayerCharacter_C` with `SpawnDefaultController` → an AIController. It replicates, walks
  the navmesh (`MoveToLocation`) and animates on vanilla clients (DISCOVERIES "ROUTE 1 WORKS").
- `body/identity.lua` gives it a DominionPlayerState with a nameplate name.
- `body/removal.lua` handles safe removal.
- `body/items.lua` `spawn_sync` drops a world item; Luis picked one up (DISCOVERIES "Drop verified").
- `items.take_world_item` picks up (verified).
- `body/skills.lua` has follow and go_to handlers.
- `bench/fixtures.lua` already reserves the verb `spawn_tester` (unimplemented).

**What it would take (about 200 Lua lines, mostly reuse):**
1. A `spawn_tester` fixture:
   - Spawn 5 m from Claude and set `SetIsImmortal(true)`.
   - **Strip `PlayerRangedAttackComponent` immediately**. That is the verified fix that makes UnPossess, destroy and
     SetLifeSpan safe (bisect 2b-2g).
   - Identity name "Tester": make identity.lua's `M.NAME` read `DW_COMPANION_NAME`, as speech.lua and presence.lua already
     do. Use the same GUID as the speech_direct sender, so the chat speaker and the pawn are one player in census.
2. Verbs:
   - `tester_move {to | path | follow_claude}` (AIController MoveTo, or reuse the skills.lua handlers);
   - `tester_face {yaw | toward}` (for "in front of me"; `mapplayers.side` already reads facing);
   - `tester_drop {item, count}` (spawn_sync at its feet);
   - `tester_status`;
   - `tester_remove` (removal.safe_remove).
   - "Receives a give" = the item lands within 3 m of Tester (that is what a Dragonwilds give is: a drop at the feet), and
     optionally `take_world_item`.
3. Guards:
   - `fixtures.guard` currently refuses when another `BP_PlayerCharacter_C` exists, so it must skip the bot GUID.
   - Refuse to spawn while Luis is connected unless he agrees.
   - `DW_SERVER_ROLE=dev` only. The server needs a restart with `DW_NO_BODY` unset (R12: body changes are not
     hot-reloaded).
4. Harness: `coplay_ladder --target-player Tester` then stops skipping follow, come_here and give. The emulator anchors
   "near me" on the real pawn.

**Risks** (crash register, ARCHITECTURE §7):

| Risk | Status | Mitigation |
|---|---|---|
| R1 unpossess crash (any unpossess of an AI-possessed player pawn: destroy, SetLifeSpan, likely death and KillZ fall-out) | death and respawn path **untested** | strip the ranged component at spawn (makes every removal path safe in the bisect); immortal; an **offline canary first** (0 players: spawn → strip → teleport below KillZ → count dumps); routes on navmesh away from cliffs until then |
| Survival decay (dehydration kills at 0 on players, verified) | DoT on an immortal pawn untested | `tester_status` HP check; with the strip, even a death is crash-safe; respawn on low HP |
| Night skip | the bot PS **blocks sleep** (verified 10-25) | `tester_remove` before sleep cases |
| Far cases: the puppet is **not** in `GameplayObjectRegistry.PlayerCharacters` (verified), so `mapplayers` can't see it beyond relevancy | known | `presence.lua` (built, UNVERIFIED; scalar-only, R15) or run the 300 m case only with Luis |
| Navmesh or cells far from the only real player | unverified for Dragonwilds. UE default: a dedicated server loads all World Partition cells unless `wp.Runtime.EnableServerStreaming` is set (Epic forum knowledge base) | read-only probe `K2_ProjectPointToNavigation` 300 m out before walking far |
| R5 / R16 zombies and stale refs | known | store ids; `U.find_all` skips Garbage; `U.valid` every tick |
| Creatures aggro the Tester (kebbits fought the puppet) | seen | immortal; noise in combat cases; spawn creatures away from Tester |
| Fidelity | by design | no real inventory, magnet, compass or E presses. It tests Claude's perception and movement around a pawn, not Luis's own actions |

**Alternatives:**
- A second real headless client on another Steam account: most faithful (registry, inventory, real input), but it needs
  a second licence and the RAM sits at the commit-charge wall.
- Luis himself, for the pawn cases only: scarce, and the reason this exists.

### 2.d What today's ladders get wrong, and the adversarial version

| # | Today | Adversarial fix |
|---|---|---|
| 1 | The co-play gate passes honest failures (`done > 0`) | Rung 2 = ≥ 80% at A; an honest failure on a feasible task is a failure; truthfulness is reported separately |
| 2 | "Any change" checks: chop = any log, pickup = count up by ≥ 1, drop = count down by any amount, give = count down within 8 m | Exact N, specific census ids, anchor correctness, no collateral change ("drop 40 keep 80" checks 80 exactly) |
| 3 | No time standard: deadlines of 150-420 s, "stuck" only after 60 s quiet, SPL saturated at 1.0 | T / T_h, SCT, first move, idle ratio, jitter, sprint share (§2.a) |
| 4 | Misses hidden inside one "ok" result (74 failed name lookups of about 10 s; 17-43 s interact dances) | Misses counted from `bridge_recv`, `gather.jsonl` and `trips.jsonl` |
| 5 | The target is the nearest thing in **Claude's own** census within 40 m, named exactly | Targets relative to the speaker; **distractors nearer to Claude than the target**; things out of his view; ambiguous names ("the temple", "crafting bench", "club") |
| 6 | One clean line, then silence until the brain goes quiet | Bursts, typos, fragments, chains; scheduled mid-task lines; metric: progress continues after chat |
| 7 | Clean start: teleported, healthy, clean brain store (`dev_ladder`, no old notes) | Start fixtures: starved (wait for decay; the cheats are compiled out), endurance 0, low HP (`set_health`), full bag, night, **stale memories** (week-old graves and notes in the store) |
| 8 | One kind per leg | Chains with partial credit: "come to me, pick up this food, eat until full", "kill 3 kebbits then show me the loot", "go to the temple, find your grave within 100 m" |
| 9 | follow, come_here and give skipped (Tester has no pawn): the requests Luis used most (about 12 "come to me") | The Tester pawn (§2.c), or these cases only with Luis |
| 10 | Distances of 40-150 m at most | 300 m and out-of-relevancy cases; a lodestone-or-walk choice |
| 11 | Haiku judges Haiku; silence and vague promises count as "truthful"; an honest wrong "can't" passes | A different-model judge calibrated on Luis's notes; the "told" checks; the false-impossibility check |
| 12 | n = 1 per case per run; 3 runs in a row mix cases | pass^3 per family plus Wilson bounds (reuse `evals/bench` report code) |
| 13 | No controls | Synthetic and live controls that must fail: null (does nothing), quitter (always "can't, sorry"), liar (claims done), slowpoke (correct at 0.3× speed), wrong anchor (picks nearest himself). Each is a `coplay_ladder validate` Synth leg, offline at $0 |

### 2.e First suite (14 cases from his real lines)

`pawn` = needs the Tester pawn or Luis. Without one, the anchor becomes a station or landmark and Claude starts 30-60 m away.

| id | His line (as sent) | Setup | Pass (A; H = ratio ≤ 1.5, 0 misses, 0 corrections) |
|---|---|---|---|
| L1 stone_front | "infront of my character" / "2 stone" / "get them" (burst) | pawn; 2 loose stones ≤ 3 m in front of Tester; distractor stones 10-40 m from Claude | those 2 ids picked, none elsewhere first; T ≤ 2.5 T_h; done line |
| L2 sticks_overlap | "grab these sticks near me" | pawn; a cluster of 5 overlapping stick spawners | all 5; ≤ 1 aim per item; no not_interactable loop; idle ≤ 15% |
| L3 reclaim_drop | "pick up the ash and stone" | he dropped 2 stacks at his feet | both stacks back in ≤ 8 s |
| L4 split | "drop 40 stone keep 80" | 120 stone (`grant`) | bag 80 and ground 40, or the expected-impossible honest reply; **never** bag 0 |
| L5 kill3_loot | "go kill 3 kebbits then show me what loot you got" | 3 kebbits spawned 15-25 m away on flat ground; a ledge 30 m off | 3 dead, loot picked, a true loot list; 0 deaths; no explore drop |
| L6 kill_near_me | "theres two kebbits near me come klill them" | pawn 60-100 m away; 2 kebbits by Tester | comes, then kills both; no "where are they?" |
| L7 come_near | "claude come to me" | pawn 40 m | ≤ 4 m; first move ≤ 3 s; sprint share ≥ 0.8 |
| L8 come_far | "come to my person NOW" | pawn 300 m (Claude teleported) | ≤ 6 m; 0 "can't see you"; T ≤ 2.5 T_h |
| L9 mid_walk | "where are you going?", then "why arent you running?" 10 s into a 150 m go_to | go_to Doric from 150 m | no restart and no `interrupted`; true destination and metres within 5 s; sprints, or gives a true reason (endurance) |
| L10 grave | "get your stuff from your grave" | killed 150 m off (`set_health`); 2 older graves as distractors; stale death notes in the store | the newest grave first; bag restored; 0 wrong graves |
| L11 starved | "eat/drink until you are full" | natural low vitals (precondition < 30/30); food in the bag, not the hotbar | ≥ 70/70 in ≤ 60 s; moves food to the hotbar; no "can't" |
| L12 table_fire_here | "build a crafting table and campfire here" / "do not wander off" | pawn; materials carried | both within 6 m of Tester; 1× cost; truthful "placed" |
| L13 crate | "can you build a crate please" | materials carried | 1 crate in census; says placed; no second crate |
| L14 club_bench | "craft yourself a weapon - maybe a club or other on the bench" | 2 of 8 stone carried; loose stone within 20 m | maps bench → table; gathers the missing stone unprompted; crafts; says done; ≤ 1 clarifying question |

Extras for the second wave:
- "go to the temple" (ambiguous; lodestone 400 m);
- "follow me" (the pawn walks a 120 m loop with a sprint and a log hop);
- "claude stop" (stops within 1.5 s and holds).

**Order of work:**
1. Rescore today's log with the §2.a metrics. It must reproduce Luis's verdict, which validates the scorer.
2. The controls (§2.d #13), offline.
3. Replay mode for L1-L14.
4. The emulator.
5. The Tester pawn canary.

## Sources
- SPL: https://arxiv.org/abs/1807.06757 · SCT: https://arxiv.org/abs/2103.08022 · NTT: https://proceedings.mlr.press/v139/devlin21a.html, https://arxiv.org/abs/2303.02160 · BotPrize: https://news.utexas.edu/2012/09/26/artificially-intelligent-game-bots-pass-the-turing-test-on-turings-centenary/
- OSWorld-Human: https://arxiv.org/abs/2506.16042 · PARTNR: https://arxiv.org/abs/2411.00081 · Watch-And-Help: https://arxiv.org/abs/2010.09890 · Habitat 3.0: https://arxiv.org/abs/2310.13724
- MineDojo: https://arxiv.org/abs/2206.08853 · Voyager: https://arxiv.org/abs/2305.16291 · MCU: https://arxiv.org/abs/2310.08367 · MineCollab: https://arxiv.org/abs/2504.17950 · Project Sid: https://arxiv.org/abs/2411.00114 · PUBG Ally: https://www.alphaxiv.org/abs/2609.29837
- τ-bench: https://arxiv.org/abs/2406.12045 · τ²-bench: https://arxiv.org/abs/2506.07982 · Lost in Simulation: https://arxiv.org/abs/2601.17087 · Sim2Real gap: https://arxiv.org/abs/2603.11245 · UserBench: https://arxiv.org/abs/2507.22034
- Overcooked proxy human: https://arxiv.org/abs/1910.05789 · GAMMA: https://arxiv.org/abs/2411.13934 · LOGIGEN simulator hacking: https://arxiv.org/abs/2603.00540
- ABC checklist: https://arxiv.org/abs/2507.02825 · False success: https://arxiv.org/abs/2606.09863 · ImpossibleBench: https://arxiv.org/abs/2510.20270 · Self-preference: https://arxiv.org/abs/2404.13076 · EvalGen: https://arxiv.org/abs/2404.12272 · RoTBench: https://arxiv.org/abs/2401.08326
- Anthropic, Demystifying evals for AI agents: https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents
- Simulator libraries looked at: https://docs.langchain.com/langsmith/multi-turn-simulation, https://pypi.org/project/arksim/
- UE World Partition server streaming: https://forums.unrealengine.com/t/knowledge-base-world-partition-server-streaming/688971, https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/WorldPartition/EWorldPartitionServerStreamingMo-?application_version=5.4
- **Searches that found nothing:**
  - task-completion metrics for PUBG Ally (the paper has latency and a survey only);
  - quantitative Project Sid metrics in its abstract;
  - metamorphic testing of LLM agents;
  - direct evidence of a simulated user accepting an agent's false claims (LOGIGEN is the closest);
  - the DeepEval and promptfoo simulator pages.
- Secondary-only figures, unconfirmed against the paper: Sim2Real 77.8% vs 63.6%; MCU about 90% agreement.
