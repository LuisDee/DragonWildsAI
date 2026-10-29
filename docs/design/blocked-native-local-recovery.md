# Owned local recovery after a blocked native walking corridor

## Goal and observed evidence

Follow [Accepted steer](autonomy-plan.md#accepted-steer--luis-2026-10-28),
[PRINCIPLES](PRINCIPLES.md), and the
[Astra execution plan/reset review](../research/2026-10-29-astra-independent-reset-review.md).
Original M1-M6, frozen judges, three unassisted temple round trips and complete
Sonnet Director + Haiku Controller acceptance remain unchanged (temple 0/3).
This is DESIGN ONLY, awaiting fresh review; no implementation or gameplay pass.

Published `a98de42` passed the combined gate (1311 passed/one skipped). Developer
return a832 failed after 64.313 s, health 100, at centre
`[75.5051,1857.7797,-30.8510]` m, `walking terrain: sweep_blocking`.
Private evidence: `C:/gameserver/logs/recovery/npg-trial-a832/`:

- `return-spawn-a832.json` and samples: trace 14 rejects memory waypoint 31,
  trace 15 chooses a fresh partial native route, then native guard blocks.
- `navigation-audit.md`: the memory edge joins r95 point 22 to r14 point 1,
  365.2 cm apart. Proximity joins are proposals, not witnessed continuous edges.
- `collision-memory-a834.json` / `collision-native-a834.json`: repeated
  support-following full-capsule side hits in both attempted directions;
  smaller subdivisions still block, cleanup succeeds. No guard relaxation.
- `local-alternative-a835.json`: the existing walking-only local planner returns
  a different 22-point ray-verified proposal (786 rays, .412 CPU seconds).
  Snapped source cell is not the actual pose or a validated connector.
- `lateral-a836.json`: ordinary developer controls physically reach proposal
  executor point 2, `[75,1858,-30.851]` m, in .515 s, health 100. This validates
  that connector under disclosed assistance, not the whole detour.
- `local-detour-a837.json` / samples: subsequent short-goal ordinary movement
  fails after 14.203 s, `invalid_route`, health 100. It takes legacy local then
  memory steering, not strict local authority. Whole detour remains unproved.

## Approach

Adapt one transition: an actual **native** guarded ordinary walking failure
whose sampled status is `blocked`, reason `sweep_blocking`, may request the
existing strict local-observation path toward the unchanged original goal.
Do not turn unknown/sensor/cleanup errors into permission to move. Limit the
initial repair to fixed coordinate go_to, enabled local planning, valid current
native binding and no active jump/link/Windstep/local transaction. Other modes
retain their truthful existing outcomes; no new traversal capabilities.

Before mutation, retain a bounded primitive trace of actual pose, original
goal, native aim/partial endpoint, first/last blocked subsegment, source,
generation/token/world/life and cumulative attempt/query counters. Revalidate
binding and exact actual pose after native cleanup callbacks. Close the guard
lease successfully, invalidate the rejected native executor and pending reply
identity, then set a specific native failure/recovery marker that makes the
existing `not st.path` strict observation branch eligible, even for a long
original command. Do not reset command start/deadline, progress baseline,
novelty history, life/owner/world or cumulative sensing and local attempt limits.

The marker owns recovery while sampling and executing. No fresh native request,
late reply or remembered proposal may replace that observation. Use existing
`local_binding`, `lp_observe`, `local_authority` and callback validations;
do not invoke unguarded legacy `lp_begin` or route short-goal straight steering
through it. After admission, `lwp=2` is the first commanded waypoint; the guard
must validate **actual pose→point 2**, independent of snapped point 1. Every
ordinary local input retains the existing fresh full-capsule guard. A ray-valid
plan alone grants neither input nor endpoint arrival.

No immediate re-query/replay of the rejected native or memory corridor while
recovery is unresolved. Failed strict observation or blocked local execution
ends with the specific verified reason (plus original blockage context), not
the same route packaged in a new table. A successfully executed local prefix
may hand off through the existing fresh-pose replan path only after its existing
novel physical movement/prefix conditions; it cannot merely reset the budget.
Recovery attempts remain bounded by existing cumulative local limits and the
original deadline, including across prefixes. Do not mark a distant waypoint
unreachable just because an earlier connector hit a wall; do not poison whole
successful world-memory records or clear memory to avoid the failure.

## Are existing strict-local protections sufficient?

They provide the right executor, but the entry transition needs explicit work:

- Current native admission cancels `lp_observe`; currently a nonempty partial
  path prevents strict local observation. Invalidate the pending native request
  at blocked recovery entry and suppress replacement requests during owned
  sampling, so no late partial/complete response cancels the selected recovery.
- With `nav_required` retained and `forward_checked`/memory retry consumed,
  ordinary memory selection is bypassed; selected strict `local_authority`
  must retain the existing source invariant and fail closed on a competing aim.
- Existing copied path binding, actual-start drift check, original-goal/prefix
  qualification, guarded inputs, early physical credit, no-progress ownership
  and pause/death/world/owner invalidation are reused. They are not proof of a
  particular route; callbacks and the first actual connector still need tests.
- Existing local-prefix qualification requires movement closer to the original
  destination. Away-first exploration outside its window remains a separate
  limitation. No claim this wave solves arbitrary discovery or all terrain.

**Measured budget caveat:** a835's diagnostic wrapper allowed 96 verification
rounds and needed 19. Production `lp_work` only replans while `lp_rounds<=12`.
Consequently a835 is not evidence the production strict planner can find this
detour within its unchanged budget. Dispatch-only sufficiency is unproved.
Before any candidate is frozen, replay the exact same start/goal and actual
production `lp_begin`/`lp_work` limits while stationary or in the actual-mover
fixture. Record rounds, queries, reason, first connector and selected authority.
If it exhausts at the current limit, report that measured constraint and return
for design review; do not enlarge limits or call the route repaired. Reusing
blocked-edge feedback to reduce redundant search is a separate evidence-led
option only if that discriminator demonstrates the need.

**a840 measured decision — implementation HOLD:** the fresh stationary
`exact-production-plan-a840.json` uses extracted production observation-trace
semantics, cfg radius9/cell100/budget16, copied actual environment with the
production long-goal walking override, shared Player profile, unchanged local
planner and 12 allowed blocked replans. It fails on blocked outcome13 with
`verify_exhausted / verification_budget_exhausted`: 758 raw rays, .431 CPU
seconds, four wall rejections and nine distinct midpoint slope rejections.
Pawn/DEV/life/generation/idle ownership guards remain unchanged. It reproduces
the production planner algorithm and parameters, not controller frame timing.
Historical query origin is separate from the current stationary pawn/gear.

Thus the reviewed recovery-entry design is CLEAR, but its dispatch-only
implementation is held: unchanged production verification cannot reach a835's
proposal. This is not evidence of no physical route. Initial immutable-trace
analysis finds no repeated or reversed duplicate among the nine rejected slope
edges; blindly optimizing symmetric keys is not a supported fix. Five midpoint
queries returned zero-distance hits, while all nine failed the existing
midpoint-versus-linear-height test. Do not weaken that test on this evidence.
Next compare bounded candidate-path verification strategies or an explicitly
reviewed finite query/time search budget. Candidate replays must fail closed on
unrecorded geometry; additional native queries, if needed, belong to root's
bounded read-only collection. No production planner/limit changes yet.

The knee ray is not a substitute: it skips memory and starts 60 cm ahead; the
native side collision was within about 12 cm. Its exact miss is not recorded.
The full-shape guard's blocked result should trigger this bounded planning
transition directly, rather than rely on that earlier ray seeing the obstacle.

## Regression and acceptance

Use actual mover plus existing local planner, guard and sampler in an independent
fake supported world containing a near-body side obstruction. Baseline should
select native, encounter real sampled `sweep_blocking` and finish without trying
strict local observation. Candidate must retain the same requested goal and
deadline, acquire strict local authority, find and physically execute a guarded
detour, and arrive only under the existing original-goal/floor predicate.
No forced helper successes, progress, local paths or expected result injection.
The discriminator must exercise the unchanged production observation and
verification budgets; a generous diagnostic wrapper cannot substitute for it.

Negative controls: no local route; ray-valid but capsule-blocked first connector;
unknown/blocked/cleanup failure; repeated rejected route with new table identity;
late native partial/complete replies while sampling and executing; memory
proposal attempted during recovery; no novel motion and multiple prefixes;
wrong-floor endpoint; owner/life/world/goal/pose mutation during observation or
cleanup; actual-start coast drift; cumulative local/query/deadline exhaustion.
Use focused tests only, then freeze for source cold review and root's one full
gate. Root runs developer ordinary controls from the natural failing route
context before the full Sonnet/Haiku attempt. a835/a836/a837 are diagnostic,
never autonomous completion. No production code until fresh design review.

## Generality and principles

The transition is selected by observed native corridor collision, not by place,
phrase, entity or supplied route. It reuses the game's input path and validated
local executor, preserves one owner, truthful failure and memory, and provides
observable evidence to developer/model result traces. No judge or principle
exceptions; no hidden intermediate model waypoints or temple rules.

## Search record

2026-10-30: repository source audit of `move.lua`, `navmem.lua`, `localplan.lua`,
`walk_guard.lua`, `sampled_ground_walk.lua`, prior strict-local/crossing/progress
notes and raw a832–a837 evidence. Fresh actual queries:

- `site:dev.epicgames.com UCharacterMovementComponent MoveAlongFloor StepUp SlideAlongSurface Sweep capsule walking`
- `site:dev.epicgames.com UCharacterMovementComponent StepUp CanStepUp hit blocking obstacle`
- `site:docs.nav2.org controller collision local costmap replanning obstacle path`

Opened primary sources:

- https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/GameFramework/UCharacterMovementComponent/MoveAlongFloor?application_version=5.5
  — native walking follows CurrentFloor; a straight sweep is not equivalent to
  the character controller. API semantics only, not new callable UE4SS controls.
- https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/GameFramework/UCharacterMovementComponent/StepUp?application_version=5.5
  — a blocking hit can precede conditional stepping; blockage does not prove
  destination impassability. Do not invoke StepUp directly or emulate it here.
- https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/GameFramework/UMovementComponent/SlideAlongSurface?application_version=5.5
  — impact-driven sliding differs from a Boolean capsule sweep. No native
  sliding success has been measured for these particular blocked directions.
- https://docs.nav2.org/rolling/configuration_and_development/configuration_guide/core_servers/controller_server/
  — separates control, progress and local environmental observations.
- https://docs.nav2.org/jazzy/getting_started/navigation_concepts/environmental_representation/
  — local observed obstacle representation supports planning/control alternatives.

Decision: **reuse/adapt** existing strict local observation, planner and guarded
executor after observed native collision. Nav2 is conceptual precedent only;
no APIs or thresholds imported. Build neither a new planner nor a StepUp/slide
emulator. Preserve direct source URLs near any later adapted code.
