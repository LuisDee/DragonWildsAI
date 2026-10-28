# Independent Sol architecture audit — 2026-10-28

## Navigation follow-up: measured route failures (2026-10-28)

Need: recover model-selected travel/build/return without inventing terrain
heights, substituting model decisions or relaxing exact arrival checks.
Actual searches: `site:dev.epicgames.com UNavigationPath IsPartial ProjectPointToNavigation FindPathToLocationSynchronously partial path end goal`;
`site:dev.epicgames.com Unreal navigation invoker runtime navmesh partial path world partition navigation`.
Opened primary [World Partitioned Navigation Mesh](https://dev.epicgames.com/documentation/en-us/unreal-engine/world-partitioned-navigation-mesh),
[ProjectPointToNavigation](https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/NavigationSystem/UNavigationSystemV1/ProjectPointToNavigation),
and [IsPartial](https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/NavigationSystem/UNavigationPath/IsPartial).
The last page returned no useful API text. Epic documents streamed navmesh
chunks, loaded-space limits and explicit point projection. These are relevant
concepts/APIs, not proof of this run's terrain or streaming cause.

Correlating existing server bridge request/reply IDs recovered thirteen raw
pairs without another oracle query/world load. Private evidence:
R/logs/recovery/lodestone-20261028/recorded-nav-raw-pairs.json. The300m target
[50.65,1590,-35.05] loaded its corridor then returned no_path,
goal_projected=false and no points. Alternate[120,1800,-35] returned partial=true,
goal_projected=true, five points ending[67.2,1857.6,-35.5]. Later construction
repositioning to[192,1797,-22] was unprojectable/no_path; [180,1797,-33] returned
partial=false, goal_projected=true and endpoint[180,1797,-28.38]. The pawn reached
that XY at Z=-27.59, but its requested underground-height goal remained unmet.
These distinguish route exhaustion and projection/height mismatch; they do not
establish why the first point was off-navmesh or how to cross that terrain.

Decision: reuse the oracle, native projection/partial evidence and strict
arrival checks. Adapt result feedback after a reviewed bounded design; no new
navigation implementation has started. Give Haiku measured facts to choose a
different target; never silently replace its XYZ goal with a projected floor.
Oracle.run is not wholly read-only: it moves/creates streaming anchors and can
rebuild links. The adopted helper retains its lock; do not start a second one.
Distinct explore behavior is entity text search: Open in a chest prompt matched
'open flat ground', which is not a terrain-flatness measurement.

## Verdict and scope

Keep the existing two-speed architecture. Repair three contracts before buying more planning: **the model's valid arguments survive dispatch; every decision sees fresh relevant state; completion means the action and its owned children have ended.** The evidence establishes useful model-selected chains alongside serious interface/body defects. It does not establish reliable autonomous play, nor that a stronger model is the principal missing component.

This is a read-only audit plus this report. No game, client, server, live reservation, model API, judge, source, or state changes were made. No regression suite was run. Root remains sole live operator. W denotes the isolated development worktree; R denotes `C:/gameserver`. At inspection R was the tested e9200ff body / 9345dec metadata / a43c429 tools. W's movement/skills/crafting ownership candidate was dirty and **not deployed**. The reviewed Python files controller, agent, situation, broker, capabilities, executor, director and persona matched R byte-for-byte. Candidate Lua line numbers are not used to attribute pre-fix behavior.

Read: AGENTS, GOAL, goal_targets, RECOVERED-GOAL, PRINCIPLES, ARCHITECTURE, the newest recovery entries, r27/r28, search-before-building, production source, captured runtime prompts/results and native pilot evidence. Approved judge paths were inspected in `evals/bench/hashes.py`; this report changes none. Formal M1–M6 certification remains absent. The $0.0546/52 Haiku UTC spend is the recorded pre-audit checkpoint, not a fresh account query.

## Ranked findings

### 1. P0: the published tool schema is not the executed schema

`brain/capabilities.py:145–160` validates against the body's manifest, then passes the valid arguments through the older `brain/interface.py` model. Those Pydantic models default to ignoring extra fields. A read-only comparison of every offered tool in the water episode's actual deployed manifest against `TOOLS[name][0].model_fields` found:

| Tool | Published fields silently discarded | Additional mismatch |
|---|---|---|
| attack | force, style, weapon | Chosen equipment/style cannot reach this dispatch path |
| craft | fuel, recipe, station | Manifest supports recipe selection; typed CraftArgs additionally requires item |
| gather | stumps, style | Acquisition options disappear |
| inventory | raw | Requested listing mode disappears |

This is not speculation about a possible alias. In `R/logs/brain-live-20261028-134140-12220.jsonl`, **line 150** the model chose `go_to(campfire-ID)` and `craft(item="Clean Water", count=2, station=campfire-ID)`. **Line 170** dispatches craft with only item/count. `CraftArgs` at `brain/interface.py:131–133` contains only those two fields. The successful default-nearest craft masks the error; another nearby station could make it consequential. Recipe-only choices can instead be rejected after passing the authoritative manifest.

Separately, `function_schema` at `capabilities.py:111–119` forwards description/args but omits the manifest's preconditions, reasons, duration and timeout. The actual craft manifest says a station must be within **60 m**; its model-visible description only says “nearby.” The model can discover the limit through failure, but it was already available and withheld.

**Change:** for a manifest-backed tool, make that schema authoritative end-to-end. Preserve every accepted field, apply only its declared defaults, and report unsupported fields explicitly rather than silently deleting them. Keep typed models for legacy/mock tools or generate compatible types from the same schema. Log requested and dispatched arguments with any explicit mechanical normalization. Preserve intent and choices; do not add semantic vetoes.

**Gate:** property/contract tests cover every published field and manifest-valid variant, including recipe-only craft, selection of one of two stations, nondefault weapon/style, and ordinary defaults. Assert model args equal dispatch args except documented schema defaults. This requires no provider call and no judge edits. Live controls must then prove nondefault native choices actually take effect before asking Haiku to choose among them.

### 2. P1: fresh state is read, but continuation inference usually does not receive it

`Agent._command_run` refreshes state at `brain/agent.py:605–612`. `Controller.next_turn` at `brain/controller.py:796–827` copies the old `d.messages`, appends action results and a generic continue/fix instruction, and assigns the new state only to `_state_for_reads` and `_collect`. It does **not** regenerate or append current situation/body status for the model. The continuation identity/death/budget checks at `agent.py:364–420` protect execution but do not themselves inform the model.

The water episode makes the consequence concrete. Prompt **line 16** says thirsty 17%, campfire 2 m away; first craft takes about 42 s. Subsequent prompts **40, 50, 60, 78, 107, 130, 147, 187** contain tool results and generic instructions, retaining the original observation in history. Successful collect-water explains what was collected but not the character's new position or distance from the station. The next craft fails no-station; the model then correctly returns to its remembered campfire. That avoidable failed attempt is partly a context contract problem, not evidence that Haiku cannot reason about walking back.

**Change:** append a bounded, timestamped observation update on every inference, including continuation calls: current identity/world, position, vitals and read confidence, action/owner status, relevant available interactions and explicit changes since the previous observation. Retain the exact root request and model-authored unfinished intent separately from volatile observations. Do not replace the request with an inferred task label or inject a task solution. Reuse the already performed fresh read, broker digest and situation renderer; this should need no additional game call in the ordinary path.

**Gate:** deterministic captured-transcript test moves the character, changes hydration/inventory/station range during an action and asserts the *next provider input* contains those new facts while preserving the original request and previous failure. Also test unavailable reads, death/world change, newer chat during inference and continuation expiry. Then compare a few matched developer controls and unchanged natural requests on tested deployments; measure redundant attempts, success, first-action/inter-subtask latency and total tokens. More tokens are justified only if useful behavior improves.

### 3. P1: action result, resource lifetime and model-visible status disagree

The water pilot correctly returned RED: `final_ping.action=null`, no waiters, no arbiter owner/suspended work, but `final_move.mode=go_to`, distance 1.09 m, 879 ticks; `terminal_idle=false`. Two successful crafts did not imply the subordinate mover was settled. Plain stop had previously failed; the operator's supported replacement recovered idle **after** evidence capture. Keep this recorded assistance separate from the unassisted episode.

Confirmed pre-fix source defects are documented in r28 and the ownership design: processing pickup omitted its parent token; a near-to-face transition could forget a live child; parent finalization could release before child cleanup. Exact original gen7 creation remains a hypothesis. These defects justify the narrow ownership repair already assigned; they do not justify rewriting planning around the campfire.

Consumption exposes another mismatch. The model receives `busy / consumable verification pending` at trace **46, 56, 74** but no responsible action ID, owner, expected end, completion notification, or supported wait affordance. It spends three controller attempts before success at **86**. The model's retry choice contributed, but the body gives insufficient information to choose an intelligent alternative. The initial prompt's `body_status` and `recent_activity` were empty, despite surviving background state existing outside this newly started brain.

**Change:** extend the existing action/result path with a small lifecycle record, not a new scheduler: action ID, parent ID, actual owner/driver, phase, accepted/running/suspended/terminal status, progress age, blocking reason and outcome evidence. A terminal result must distinguish objective achieved from cleanup pending/failed; an ownerless active child is an explicit invariant failure. Surface a safe compact status automatically and offer focused read/wait on known actions. Do not expose raw mutable Lua tables or force a particular model response.

**Gate:** actual-module composition tests for normal finish, cancel, suspension, successor generation, timeout and owner loss; independent native idle/owner/UI observations after real controls. Repeat the unchanged water request with live hydration/reserve/output evidence and strict cleanup. A correct item outcome plus orphan remains a failed overall episode.

## What the model actually controls

Haiku genuinely chooses tools in the inspected episode. Raw `llm_response` choices align with tool dispatch, except the silent argument loss above. Trace **17** chooses craft2; **41/51/67/79** choose consumption attempts; **111** collects2; **134** tries craft2; **150** chooses go_to then craft2. No controller_alias or controller_safety_refusal events occurred. Sonnet/Director were off. The initial Dirty Water2, pre-existing campfire and prior developer setup are assistance; no episode grants, teleport or solution prompt occurred. The model used supplied feasibility facts, not an independent recipe discovery or new-base construction.

The implementation nevertheless constrains the loop in several ways that should be disclosed:

- `grounding.py` supplies fuzzy candidate references only. The old phrase-grounding veto is gone. Controller's opening docstring still claims such a veto exists; it is stale documentation, not executable policy. `safety` at controller.py:962–971 enforces the explicit never-attack-player rule.
- Actual captured aliases contain `pickup -> interact`. `capabilities.py:137–143` and controller.py:895–899 can translate an unoffered legacy tool and arguments. This is a compatibility rewrite, not a natural-language phrase map. It should be visible in logs and removed from model-facing compatibility when no longer needed; it did not cause this water run.
- `controller.py:649–707` skips read calls in a response that also acts, and after the bounded read loop offers an action-only final pass. The read descriptions disclose this. These policies can bias toward premature action; “no tool suppression” would be an inaccurate architecture claim. Test a more faithful sequential read/result/next-decision contract before changing it; never execute a later action with arguments chosen before an essential read and call that result-informed planning.
- Agent executes multiple chosen actions in order, stops after the first failure, and returns results. Executor mechanically retries some transient failures and adjusts count-based work (`executor.py:251–260,286–332`). Therefore distinguish provider choice, wrapper retries and native reflex activity in attribution.
- A general talk-only check requests one more model response, even after a factual completion report; water **193–196** shows that extra inference. It does not map words to tools, but costs latency/calls. Measure its value rather than layering more promise policing.
- Director `first_call` (`director.py:1439–1472`) can dispatch the Director model's proposed action without a fresh Haiku selection. That is model choice by the planner, not “Haiku independently chose every action.” Full-stack reports must name both drivers.

No phrase-to-tool policy or benchmark-specific plan was found in the inspected paths. This is a bounded source/trace review, not a proof about every repository string. Prompt examples and recipe-derived options do shape behavior; the distinction is whether they describe general capabilities/facts or prescribe a hidden solution. The current needs renderer enumerates data-derived alternatives and is defensible information support.

### Model, body, harness and evaluation failures must stay separate

The new-axe request is a genuine counterexample to a purely infrastructure explanation. In `R/logs/brain-live-20261028-123103-7084.jsonl`, response **17** requests recipes/stations; recipes **21** explicitly reports ambiguity and `unlock_status=unknown` for many candidates. Response **27** asserts “only stone axe unlocked,” chooses attack on the name Ash Tree, then after unknown_target **33**, response **38** gathers with the existing axe. It never produces a new axe. The exact request asked for a new axe first; successful chopping does not satisfy it. This is a model interpretation/epistemic error with adequate original intent retained, even though better tool/state contracts may help. Preserve this negative result and compare captured-context model trials before further body fixes aimed at it.

Conversely, the earlier own-grave/axe/equip/chop chain and the water sequence establish useful composition, not universal task success. Wrong addressed-chat injection in the historical survival diagnostic was a harness routing failure (zero calls); later native death was a real self-care failure. Phase Dash activation without displacement and missing base perk is an unresolved capability/prerequisite diagnostic, not a demonstrated reasoning defect. Missing control validity, full runs, correct build provenance and current-hash exposure are certification gaps. They must not erase real partial abilities or be softened to manufacture a milestone.

## Perception and memory: useful information, uneven delivery

| Information | Present today | Gap that matters |
|---|---|---|
| Root intent/previous choices | Exact request and accumulating tool transcript within the chain | No compact model-authored unfinished intent across independent controller episodes; turn/deadline policy may end work |
| Inventory uncertainty | Controller digest says partial/lower bound; inventory result preserves read_status | Director `_compact_state:416–418` sends positive counts without their read_status/count semantics; verifiers also need separate uncertainty review |
| Space/stations | IDs, distances, nearby structures; remembered locations include ages | Initial summary often omits stations/places/coordinates; fresh continuation location absent; 60 m capability limit is discarded |
| Effects/perks | Spell result effects, spell castability/cooldown and richer combat tools exist | No guaranteed general fresh active-perk/effect/charge view in controller digest; Phase Dash prerequisite was found by operator native diagnostic, not established model perception |
| Action/interrupt state | Broker reports movement/progress/failures; heartbeat/waiters track wire work | Owner/move/input probes are not offered (`llm=false`); generic busy and empty fresh-session broker cannot explain existing native work |
| UI | Input module knows modal/mode/owners and tools return some UI failures | `input_status` has no model manifest; no guaranteed safe current UI snapshot. Input submission is not proof of accepted gameplay input |
| Goals/world memory | Task board, notes, per-world map and top3 learned skills | Notes lack freshness/provenance in prompt; bounded retrieval can foreground irrelevant/old failure history |

Concrete prompt budget evidence: `situation.py:25–28,329–334,699–803` limits 18 lines, six groups/line and usually 240 characters; creatures can use 640, needs use 560. The water initial prompt allocates four lines to graves, lists six dominant rune stacks with “+6 more,” truncates a food-options line mid-location, and loses the dedicated stations/around/places/extras lines. A stale note says body bridge restarting, 0 water, 1% HP while current state says healthy100. It is not timestamped or explicitly marked historical. Memory should preserve the experience while separating it from current state; do not erase world progress to fix prompt pollution.

Read-result compaction is comparatively careful: `_model_read_view` (`controller.py:46–100`) compresses only repeated simple inventory read gaps into count/sample/omitted, retaining uncertainty; do not undo this useful improvement. Recent events are newest5, notes newest20, learned skills top3; broker digest up to8. Progress events are consumed live and not inserted into `Controller.events` (`controller.py:476–481`); the broker can retain a progress line. `BridgeClient` buffers events during blocking calls and returns early for addressed chat while explicitly saying the body may still run (`bridge_client.py:138–226`). Broker drops duplicate synchronous action events and stale vitals; trace **92–103** records legitimate deduplication/staleness, not evidence of hidden failures.

Director has genuine background work, snapshot/plan-key checks and research tools. Its compact input cuts spells30, creatures8, interactables12, structures15, quests8; history15. These limits are not inherently wrong. The missing requirement is a declared coverage/freshness contract, including what was omitted and how to request it. A separate bigger memory system or Director concurrency increase is premature. Existing declarative skill memory is safer than importing generated programs: retain it, label 1/1 successful procedures as single-context experience and record setup/build/world. Several initial retrieved water skills were all 1/1 variants; retrieval availability is not proof of transfer or necessity for this run.

## Red-team of the growing ownership candidate

At review the three Lua files had **283 inserted /45 deleted lines**, before the proposed finalization-fence expansion. The observed defect warrants parent-token propagation, generation-bound child cleanup at approach/face and terminal boundaries, missing-token admission rejection, and truthful unresolved cleanup. These are general ownership invariants. Keep them.

Distinguish that production evidence from proposed adversarial cases where `W.close`, `verify_final`, cleanup callbacks or input release synchronously create a successor. Callback reentry is a credible programming hazard, but the report contains no native trace proving those particular callbacks caused the observed orphan. Do not present every injected case as a discovered gameplay failure, or insist that a campfire fix requires a general transaction framework.

Recommended scope decision before further code:

1. List the exact side effects added/changed by the patch and the concrete callbacks they invoke. For each ownership fence, state the invariant it protects and whether the callback can actually reenter production. Require real-module tests for reachable callbacks. Retain synthetic tests as adversarial tests with that label.
2. Use one small exact-child stop/status contract and one terminal boundary. After any real callback that can start a move, recheck raw generation and token immediately before releasing the parent. If a same-parent successor exists, preserve it and retain/report cleanup pending. A foreign successor must survive untouched. Do not replace this with a global stop or “assume idle.”
3. The old unconditional screen-owner release and multi-panel `W.close` are a distinct UI ownership concern. An exact uniquely owned screen-release fix can be an orthogonal, separately reviewed patch **if the movement patch neither broadens that path nor relies on it for its safety claim**. Existing uncertainty must be documented. A wrapper cannot promise to fence individual native closes hidden inside an unfenced multi-close helper. If that guarantee is required for the current patch, either narrowly change that helper under explicit ownership or hold publication; do not certify a known incomplete fence.
4. Avoid capturing the identity of every global table as an architecture requirement without a demonstrated mutation path. Favor explicit lifecycle identity, exact resource generation and side-effect boundaries. Retaining a parent forever is not a safe terminal policy: timeout/cancel must produce a bounded, truthful cleanup-unconfirmed outcome and preserve the successor, rather than retrying indefinitely or hiding the problem behind admission failures.

This is a scope recommendation, not approval of the current candidate. Root's independent safety review remains binding. Splitting patches is useful only when each independently preserves its stated invariant; splitting must not defer a newly introduced ownership violation. The interface/fresh-state repairs are independent high-value work and need not wait for speculative UI redesign.

## Small target contract and staged evidence

Adapt existing components; do not add a new orchestrator. A decision input should have four explicit parts: unchanged `request` (ID/text/constraints); model-authored `intent` (unfinished objective/commitments, never a code-authored recipe); timestamped `observation` (world/character, read status, relevant state and omitted coverage); `actions/events` (IDs, driver, phase, progress, terminal evidence/interrupt reason). Tools publish one authoritative schema plus factual prerequisites and dynamic availability with reasons. Capability unavailable means report what was observed, not silently choose another action. Transient busy should identify ongoing work and expose completion/wait; the model chooses its response.

| Phase | Bounded work | Evidence before expansion |
|---|---|---|
| A: restore execution truth | Finish/review the observed child-lifetime fix; preserve all manifest-valid arguments | Offline all-field contract tests and composed lifecycle tests; full gate; developer native nondefault-action/cleanup controls; exact natural water repeat |
| B: restore decision truth | Fresh continuation observation; minimal lifecycle/UI/confidence view; mark historical notes | Captured-input tests; matched natural task trials with identical assistance accounting, total calls/tokens, redundant errors and native terminal state |
| C: test planning need | One bounded full-stack prerequisite/progression job with Director enabled, alongside matched controller-only diagnostic | Same resources/driver attribution; native progress and interruption latency. Stop if no benefit; no new plan framework |
| D: certify foundations | Stable tested hash, remaining native controls, active exposure and frozen M1 measurements | Existing original judges/control validity and real current-code evidence; no relabeling partial diagnostic success |

Use several distinct natural tasks, not endless repeats of water: equipment selection with nondefault weapon, processing at one of two stations, gather mode selection, and a task interrupted by player correction. Keep task choices model-owned, disclose grants/setup, and keep scientific diagnostic comparisons separate from frozen goal scoring. Existing body/input/observer, JSONL, task board and per-world stores already supply most machinery. Native primitives should remain bounded player actions (move/look, directional evade/jump, hold/release, focus/interact, station/container operations), with actual accepted input/effect and terminal mode observed. Do not add task-specific compounds or a universal raw-input escape hatch that bypasses ownership.

Budget/resource tradeoffs: reuse the fresh state already fetched; send changes plus a small current core rather than another entire world dump. Cost is extra prompt tokens and potential cache churn, balanced against redundant calls. Preserve stable schema/persona prefixes. Do not infer that today's cheap small Haiku traces imply cheap 2h/full-stack tests. One client/server, one live operator, one heavy workload and the $10 UTC cap still apply. No local VLM, new DB service or research-model training fits this VM without separate resource evidence.

Falsification: schema preservation may reveal native options that are unimplemented; prove them through controls rather than treating forwardability as capability. Fresh state may not improve intent failures; if matched trials show the same choices despite accurate inputs, measure model/effort alternatives next. Rich status may increase latency/noise; prune by demonstrated decision value, preserving uncertainty. Lifecycle hardening may only move stalls into cleanup-pending; require bounded terminal evidence. A Director may add stale plans and cost; keep it only when matched trials improve long-job completion. More architecture earns its place through those comparisons.

## Search record

Actual searches on 2026-10-28 included:

- `LLM game agent asynchronous memory real time 2026 2025 SIMA 2 Mindcraft embodied agents`
- `2026 game playing language agent asynchronous actions perception interruptions July August September October`
- `site:github.com mindcraft agent modes self prompter interrupt`
- `"game agent" "2026" "asynchronous" "memory" embodied July August September October`
- `site:arxiv.org "2609" "game" "agent" perception tools`
- `Voyager Minecraft agent skill library 2023 GitHub Cradle 2024 general computer control`

Primary pages/papers/source opened and date checked:

1. **Recent, directly relevant: PUBG Ally**, submitted **24 September 2026**, revised25 September. [Paper](https://arxiv.org/html/2609.29837v2), especially sections3.2/3.3 and appendixB. It uses event-triggered high-level model control above persistent tick-rate behavior; refreshed status and bounded carried intent link loops. Adapt those contracts. Its distilled/on-device, trained production system and developer game integration are not available Dragonwilds APIs. Its use of event reactivity policies does not authorize copying game-specific decision suppression into this project.
2. **Recent, adjacent: Gander**, submitted **8 September 2026**, revised12 September; project report9 September. [Paper](https://arxiv.org/abs/2609.08977), [full report](https://arxiv.org/pdf/2609.08977), [source](https://github.com/Omni-Interaction-Gander/Omni-Interaction-Agent). Section3.2 makes background task creation, steering, cancellation and progress explicit. Adapt lifecycle separation; do not adopt its multimodal training stack or extra coordinator. This is interactive task orchestration, not evidence of native survival-game mastery.
3. **Older recent-era foundation: SIMA2**, paper **4 December 2025**, announcement13 November2025. [Paper](https://arxiv.org/html/2512.04797v1). It conditions on recent frames/history and emits action chunks through keyboard/mouse. This supports grounded observations and bounded control; it does not show a stock small chat model can inherit trained visual motor skill. Dragonwilds currently uses structured instrumentation and real input rather than this pixel-only interface.
4. **April2026, outside the last handful of months: AgenticCache**, submitted **27 April2026**. [Paper](https://arxiv.org/abs/2604.24039). Cached plan transitions with asynchronous model updates are a precedent to evaluate later. Do not adopt automatic plan replay now: stale/game-specific replay and benchmark locality could violate this project's decision ownership. Reuse retrieval of factual experience first.
5. **Older implementation precedent, inspected current source rather than claiming a new release: Mindcraft.** [Agent](https://raw.githubusercontent.com/mindcraft-bots/mindcraft/develop/src/agent/agent.js), [ActionManager](https://raw.githubusercontent.com/mindcraft-bots/mindcraft/develop/src/agent/action_manager.js), [History](https://raw.githubusercontent.com/mindcraft-bots/mindcraft/develop/src/agent/history.js). It has explicit action interrupt/stop, behavior logs and persistent history. Its ten-second kill fallback and aggressively clipped summary are not designs to import. Mineflayer APIs cannot drive this Unreal client. No dated late2026 release claim was established.
6. **Foundational Voyager, 2023.** [Project](https://voyager.minedojo.org/), [repository](https://github.com/MineDojo/Voyager). Retain verified reusable skill/feedback principles already adapted here; importing generated JavaScript skills or replacing deterministic native evidence with a model critic would be inappropriate. Do not market this as new2026 research.
7. **Long-running action contract, older engineering precedent:** [ROS2 Actions](https://design.ros2.org/articles/actions.html), written2019/modified2020. Goal ID, feedback, terminal result and cancellation are separable concerns. Adapt the contract atop JSONL; installing ROS2 would be unnecessary.
8. **Exact-runtime API boundary:** [UE4SS delayed actions](https://docs.ue4ss.com/dev/lua-api/global-functions/delayedactions.html) and [Epic Enhanced Input](https://dev.epicgames.com/documentation/en-us/unreal-engine/enhanced-input-in-unreal-engine). Timers execute on the game thread and expose handles; input trigger phases/context matter. Documentation is not proof of what this game accepted or that cancel preempts an executing callback. Reuse r27's pinned source/native observations; verify each primitive in the actual installed runtime.

The September papers are genuinely recent verified sources; the older systems are explicitly dated foundations. Search did not establish a production-ready open-source replacement for this exact Dragonwilds/UE4SS setup, nor a verified October2026 embodied-game architecture that removes these integration obligations. Cradle surfaced in search but was not used as a substantive basis without a deeper primary-source inspection. Search ranking/crawl dates were not treated as publication dates.

**Reuse > adapt > build decision:** reuse existing bridge, manifest, broker, observer, arbiter, board and per-world memory; adapt authoritative schemas, current observation updates and explicit lifecycle contracts; build only the small missing adapters/regressions. This follows real-player paths, model decision ownership, generality, truthful failure and one resource owner. The proposed evidence gates preserve original M1–M6 requirements and frozen judges.
