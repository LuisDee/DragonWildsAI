# Independent Astra review brief: delivered behaviour, architecture and iteration failure

Requested by Luis on 2026-10-29. Run as GPT-6 Astra at maximum reasoning effort,
with fresh context. This is an independent investigation and plan, not approval
to implement the plan or resume the paused development Goal.

## Your assignment and authority

Inspect the actual repository, relevant history, recorded live evidence and
primary web sources. Explain why this project has repeatedly failed to produce
the requested autonomous behaviour. Critique both the technical approach and
Sol/root's engineering/validation process. Produce a comprehensive, executable,
evidence-based plan that targets realised gameplay, not code production.

Do not accept the explanations below as established causes. They are leads from
the responsible implementer, who has repeatedly overclaimed engineering activity
as progress. Confirm, reject or qualify them against actual evidence. Give the
current architecture its strongest fair case, then try to falsify it. Identify
what you would keep, simplify, replace or stop, and why.

The development Goal is PAUSED. Luis separately authorizes THIS review and web
research. Do not implement, alter candidate code, run tests/benchmarks, operate
the game, launch/restart processes, invoke game-model APIs, change task boards,
modify memories/saves, publish/deploy, or resume the Goal. Do not spawn workers.
Read-only file/Git inspection and web research are authorized. You own ONLY the
new report path specified below. Root owns integration and the one live client.
Do not read or reproduce secrets, private credentials, .env values or SSH keys.

## Current locations and baseline

- Source F: `C:/Users/Administrator/.codex/worktrees/feedback-loop/gameserver`.
- Deployed runtime R: `C:/gameserver`.
- Last published/deployed checkpoint: `8b49235`.
- F has an UNCOMMITTED candidate in `client_mod/scripts/move.lua`,
  `client_mod/tests/test_move.lua` and documentation. Inspect both HEAD and diff.
  Do not treat F candidate as deployed or fully validated.
- Last full GREEN: R `logs/recovery/adg-g-a742/check-all.log`, reported
  1279 passed / 1 skip; verify scope. Latest candidate full gate
  `R/logs/recovery/por-g-a760/check-all.log` was INTERRUPTED by Luis's pause.
  It is NOT GREEN and has no publication.json. Do not restart it.
- Client is OFF. Server/Steam/one oracle were retained. No game brain is active.
  Do not operate or diagnose those processes; this review is static/evidence-only.
- Read `R/logs/recovery/ACTIVE-HANDOFF.txt`, especially its final PAUSED entry.
  Earlier chronological ACTIVE entries do not authorize resumption.

## Binding goal and constraints

Read `AGENTS.md`, then **Accepted steer** at the top of
`docs/design/autonomy-plan.md`. Carry that steer into your report and plan.
Read `docs/GOAL.md`, `docs/goal_targets.json`, `docs/NEXT-GOAL-PROMPT.md`,
`docs/RECOVERED-GOAL.md`, `docs/ARCHITECTURE.md`,
`docs/design/PRINCIPLES.md`, and the recovery document
`docs/SESSION-RECOVERY-2026-10-26.md`. Original M1-M6 and frozen judges must remain
unchanged; inspect `evals/bench/hashes.py:JUDGE_PATHS` without editing them.

The original objective is an autonomous companion that works tasks out using
truthful tools, research, memory and feedback. Milestones are Foundation; spell
use/tactics/crafting; every skill trains; Director jobs; long-horizon progression;
Brynmoor progression and Vel'gar SOLO. Exact thresholds, repeats, case validity,
held-out requirements and Luis's sign-off are defined in the goal files. Do not
substitute a smaller objective or rewrite criteria to fit existing achievements.

Immediate priority: reliable traversal, truthful perception and sustained tasks.
First acceptance: three consecutive unassisted complete **Sonnet Director + Haiku
Controller** walking round trips from the DEV temple spawn lodestone, outside
the temple and at least **200m FROM THAT LODESTONE**, back to the same lodestone
on the correct floor. Verify actual motion, elevation, survival and arrival.
Another slope/doorway and changed destination must demonstrate generality.
No operator steering, hidden intermediate hints, teleportation or temple code.
Do not silently change the distance origin to the temple boundary.

Luis additionally requires unfamiliar-route discovery without a recorded path,
operator demonstration or hidden hints. Preserve real memories; choose a held-out
case rather than erasing history. Taught temple replay is not discovery.

Then purposeful exploration; sustained gather -> return -> deposit; station use,
crafting, rune essence, useful unlocked spells and quests in original milestone
order. Food/water replenishment must be self-sufficient, not supplied by players.
Models choose destinations and plans; do not encode a workflow per crop, recipe,
enemy, area or benchmark. Use real client inputs/UI/game paths, not emulated
inventory/crafting/damage outcomes. DEV-only fixture assistance must be disclosed.

Constraints for a FUTURE implementation plan: DEV/ClaudeDev only; preserve all
per-world memories; one live operator/client/server; one heavy local workload;
at most two bounded development workers within account allowance; shared $10
UTC-day game API cap. Offline -> developer real controls -> unassisted complete
agent. Developer, Haiku-only and simulated runs are diagnostics. Required gates
remain binding, but assess how to avoid redundant/poorly timed runs. Current
game API spend was $1.1906 / 76 calls on 2026-10-29 (31 Haiku,45 Sonnet); no new
game-model calls occurred during the latest candidate work. Do not call APIs.

## Luis's correction of our success metric

Luis explicitly rejected my phrase "code progress": until quantified in a live
run, a code change is only a candidate. Goal advancement is realised behaviour
proved against its criteria. Tests, reviews, documentation, research and commits
are inputs and release checks, not capability gains. Temple acceptance remains
0/3. No new autonomous task passed during the latest repair sequence.

Our reports must distinguish hypotheses, static findings, fake-world evidence,
native stationary probes, developer control and complete-agent acceptance. A
model's claim is not game-state evidence. Do not present your review or plan as
achieving gameplay. No deadline promises without a measured basis.

## History and evidence to independently reconstruct

This index is deliberately detailed so you do not repeat shallow earlier reviews.
Read the actual source/results and distinguish association from causation.
Use Git chronology/diffs to understand changes; do not trust stale doc headers.

### Friend trial and physical traversal failure

Luis saw the companion repeatedly circle behind a temple ramp rather than walk
up it, stall in doorways, struggle to follow the player's route, fail grave
recovery, stop open-ended work, and complain about food/water. Read relevant
observations/routes/chat under `R/logs/recovery/friend-trial-20261028/`, especially
`live-observations.jsonl`, `OBSERVER-INSTRUCTIONS.txt` and route-comparison files.
Do not touch that world's state. The friend trial ended; no reconnection is allowed.

The character can physically walk a successful ramp line. This does not prove
normal navigation chooses it. Raw developer driving sometimes deliberately used
nav=false/local_plan=false and skipped route memory: inspect driver scripts.
Those outcomes cannot be attributed to the production planner or Haiku.

### Earlier reviews and why their recommendations may not have closed the gap

Read these fully, then verify whether their findings were implemented, superseded,
left untested, or diluted by later work:
- `docs/research/2026-10-29-astra-navigation-review.md`
- `docs/research/2026-10-29-sol-headless-interaction-review.md`
- `docs/research/2026-10-29-traversal-perception-direction.md`
- `docs/research/2026-10-29-player-grounding-native-controls.md`
- `docs/research/2026-10-29-planner-input-friction.md`
- `docs/research/2026-10-29-compound-completion.md`
- `docs/research/2026-10-29-survival-self-sufficiency.md`
- `docs/research/2026-10-29-unfamiliar-route-selection-gap.md`

Prior reports suggest inconsistent native/feet/centre/floor contracts, incomplete
NPC navigation coverage, multiple route authorities, object identity collisions
in map memory, interaction-point/standing-pose differences, duplicate UI/approach
state machines, lost information before model prompts, and local-wiki-only research.
These are leads, not permission to assert they all remain current or caused a
particular live failure. Confirm the actual latest state and source-to-model path.

### Relevant published navigation sequence

- `3ff9496`: resolve observed floor heights rather than interpolate support origins.
- `7ccecf6`: give completed walking scans a usable execution window.
- `b13793e`: lexical match truth and generic directed remembered-route proposals
  when native routing is partial/unavailable. No temple coordinates, but routes
  can contain operator demonstrations. Complete native paths retain preference.
- `a5b6867`: explicitly separate taught replay from independent discovery.
- `7142526`: measure stalls during admitted active input, excluding guard holds;
  account for frame-clock anchoring; retain thresholds/deadlines.
- `8b49235`: refine a blocked ground chord into freshly supported midpoint
  subsegments using the same capsule, bounded depth and query/sample budgets.
  The original blocked chord stays recorded; unknown/overlap is not called clear.

Read associated design notes: `navigation-route-authority.md`,
`player-grounded-route-admission.md`, `short-local-route-authority.md`,
`terrain-feedback.md`, `waypoint-and-route-progress.md`, `walk-scan-timing.md`,
`player-route-proposals.md`, `active-guard-progress.md`, `adaptive-ground-chords.md`.

### Developer and complete-agent evidence

- `R/logs/recovery/wt-trial-a716/`: developer physically climbed ~4.2m, crossed an
  upper doorway, went >207m FROM spawn lodestone and returned with health100.
  Operator-selected routing and granted nutrition/health were disclosed. Automatic
  route records from this run carry developer provenance, not independent discovery.
- `R/logs/recovery/rfp-trial-a709/full-agent-result.json` and accompanying actual
  model inputs/outputs, body calls/results and native route traces: complete
  Sonnet/Haiku failure. Reported 18 Sonnet +6 Haiku calls, maximum19.11m from the
  lodestone, interaction/search distractions and support-height failure. Verify.
- `R/logs/recovery/rp-trial-a719/live-lexical-controls.json`: old exit/opening
  queries now match=false; Ash Logs positive control matches=true. This proves
  lexical discrimination, not visual detection of exits or absence of a doorway.
- `original-connector-a730*.json*` / `entry-probe-a730.jsonl`: normal guarded
  route followed recorded points and climbed, then rejected an upper sweep.
- `actual-query-then-input-a735.json`: same actual stationary start, full Player
  capsule straight sweep blocked; subsequent real input crossed and ended grounded
  with no driver jump/teleport command. This demonstrates collision chord versus
  actual ground trajectory, not general StepUp or autonomous route discovery.
- `sampler-segment-a737.json`, `midpoint-native-a738.json`,
  `candidate-native-a740.json`: stationary controls, supported midpoint paths,
  query costs and retained original collision evidence. Candidate replay was not
  actual-entry movement admission; verify these limits.
- `normal-ramp-doorway-a747.json`, `*-samples.jsonl`, `*-console.log`: latest
  deployed normal public go_to attempt failed after23.468s. It climbed the upper
  ramp, advanced remembered waypoint5->6, discarded the path, then chose a lower
  native point. Downstream water_ahead replanning led to sensor_unavailable.
  Native logs are `R/logs/client/client.log` at19:01:26-19:01:48 UTC.
  Sparse evidence does NOT prove the original discard trigger. Source review
  says silent guarded-stall recovery is the branch matching retained mwp/msrc.

The last four bullet groups are inside `R/logs/recovery/rp-trial-a719/`.
Read fixtures/setup too; do not mistake granted supplies for self-sufficiency.
Idle validation time exhausted supplies in earlier sessions; root twice found
depleted health during diagnostics. This is an operational failure, not a pass.

### Current uncommitted candidate, not yet a gameplay outcome

Read `docs/design/partial-route-observation.md`, current diff and actual focused
tests. Private initial evidence lives in
`R/logs/recovery/unfamiliar-prototype-a744/` and the source fake-world comparison
under F logs/recovery/unfamiliar-selection-private-20261029-a.

1. Partial native routes suppressed independent original-goal terrain observation,
   unlike no-path. Candidate permits existing bounded observation, keeps partial
   fallback/complete-native preference and handles late replies/rejected attempts.
2. That integration exposed an actual fake-world 30m failure: novel waypoint poses
   entered dedup history before guard/prefix early returns applied progress credit.
   History reached2205cm but prog_pos stayed at0, then false no-progress started
   an unbound backtrack while local authority remained active.
3. Candidate credits existing physical novelty under exact selected local/bound
   memory/native bindings before relevant returns. Native credit waits for final
   source selection and post-callback path/goal/owner/life checks. No credit for
   inactive native paths, repeated poses, new path tables or mere planning.
4. True local no-novel expiry reports bounded failure/persistent follow-unreachable
   rather than installing unbound backtracking. Guard recovery retains primitive
   causal evidence in trace/status, without new sensor queries.

Focused tests and narrow Astra code reviews passed. The local-only intermediate
whole mover `R/logs/recovery/partial-observe-mover-a761.log` passed. Final shared
candidate focused tests `partial-observe-focus-a768` passed; its final full gate
was stopped on pause. No current-candidate developer or complete-agent live run.
The pending changes may be useful, insufficient, unnecessary or the wrong
direction; assess independently. No obligation to preserve sunk-cost code.

## Questions your investigation must answer

1. What exact causal chain explains each major live failure? Give an evidence
   table with facts, hypotheses, contradictions, unknowns and the cheapest decisive
   experiment. Do not attach a fake-world cause to a live trace without proof.
2. Is the current architectural approach capable of the goal? Audit axes/units,
   feet/centre/floor identity, nav agent/data choice and coverage, collision/steps/
   slopes, sensed geometry, route source arbitration, waypoint reach, clock/query
   costs, recovery, action ownership, stale targets and persistence.
3. Does the agent actually receive enough truthful information to choose and
   revise plans? Follow perception -> memory -> prompt/tool schema -> action ->
   native control -> observed result -> Director/Controller input. Distinguish
   "data exists somewhere" from delivery in actual captured model requests.
4. How should an unfamiliar ramp, stacked floor, doorway, away-first detour or
   later jump/gap be discovered and traversed generically? Is existing local
   planning/memory enough, or is a different terrain/map/navigation substrate
   required? Explain tradeoffs and compatibility, not a reflex rewrite.
5. How can nearby/same-name/stacked chests, resources, stations and menus be
   reliably identified and used headlessly? Evaluate native semantic geometry,
   reflection, UI state/tree/action observation and rendered fallback. What is
   absent and how would a live measurement establish that absence matters?
6. What prevents sustained purposeful exploration, self-care replenishment and
   gather/return/deposit? How much is navigation, perception, task/feedback or model
   reasoning? Are Sonnet research/planning, wiki access and Haiku execution working
   together in actual runs? What should models infer versus deterministic code?
7. Why has Sol failed to deliver despite repeated repairs? Audit experiment design,
   attribution, route demonstration contamination, reproducibility, observability,
   changing variables, acceptance ownership, repeated full gates, review/delegation
   overhead and lack of decisive architecture falsification. Distinguish verified
   elapsed-time evidence from estimates; do not invent a daily percentage breakdown.
8. Which current code/checks/investigations should stop or be removed? Which are
   essential? Is complexity serving the live outcome or becoming its obstacle?

## Required web research

Apply `.claude/skills/search-before-building/SKILL.md` for proposed approaches.
Search repository research FIRST, then actually web-search and OPEN primary
documentation/source. Seek established and recent work, including relevant work
from the past several months where verified. Record exact queries, dates, direct
links, findings, limitations and reuse/adapt/build decisions.

Investigate Unreal/Recast/Detour player traversal and motion validation; robotics
terrain representation/local-global planning/recovery where applicable; embodied
game agents (e.g. Mineflayer/Mindcraft/Voyager and comparable primary projects);
headless semantic game/UI control, accessibility/computer-use and visual grounding.
These are search leads, not endorsed solutions. Prefer fewer deeply verified,
compatible sources to a long list of fashionable names. Inspect source or APIs
and account for engine/version, UE4SS, Windows, headless/rendering, licence,
latency/memory and integration constraints. A paper or MCP wrapper is not proof
that its features can be called in this game. Do not promise screenshots, navmesh
generation or UI introspection without checking what this runtime can expose.

For every recommended technology: state exactly what could be reused, what
requires adaptation, what remains unknown, and the smallest compatibility test.
Also name attractive approaches you reject and the reason.

## Your deliverable and persistence

Write the full report directly to:
`docs/research/2026-10-29-astra-independent-reset-review.md` in F.
This is your ONLY writable artifact. Keep secrets/raw private logs outside Git;
reference local evidence paths and source file/function/line locations instead.
Do not commit/push; root will inspect and present the report. Use an actual
complete report, not merely a summary plus a promise to continue.

Organize it so Luis can understand the verdict and an implementer can execute:

- Executive verdict: goal status, strongest conclusions, uncertainties, whether
  you recommend continuing, narrowing an approach, substantial replacement or
  stopping a particular line. Do not redefine the goal itself.
- Verified baseline and capability/evidence matrix; current vs pending code.
- Root-cause and architecture analysis, with concrete code/evidence references.
- Research record and comparison of compatible alternatives.
- Prioritized plan with dependencies and minimal coherent changes. Each phase
  needs specific observable behaviour, exact experiment/setup, positive/negative
  controls, required telemetry, pass/fail rule, assistance disclosure, preservation
  rules and stop/reconsider criteria. Tests/reviews are prerequisites, not success.
- First executable experiment after explicit development resume; explain why
  its result would change the next decision. Include what to do for each outcome.
- Route to the three temple passes AND held-out route discovery, then sustained
  self-care/gather/deposit and original M1-M6. No endpoint hints or task scripts.
- A practical iteration process and reporting contract that optimizes accepted
  live outcomes. Give measured prerequisites or conditional estimates rather than
  inventing deadlines. Identify true external dependencies versus agent execution.
- Explicit keep/change/remove/stop list and unresolved risks.

In your final message to root: report the saved path, headline verdict, top
priorities, strongest evidence and any important limitation. Root will read the
FULL report and explain it to Luis, including disagreements and uncertainty.

## Verified timing addendum while review starts

Root parsed the recorded a709 result and JSONL without invoking game/models:
24 actual model outputs, 18 planner and6 controller, from
2026-10-29T14:59:27.471711Z to15:02:32.693863Z;43 body requests recorded.
Result task3fccd0b3 remained active; no exception field. Compare this with the
later code/release/developer-test chronology when assessing iteration throughput.
Do not infer a complete daily time allocation from this one interval.
