# Judge walking stalls after an admitted input opportunity

## Goal and observed evidence

Follow Accepted steer in autonomy-plan.md, including the distinction between
operator-taught replay and independent discovery. Preserve original M1-M6,
judges, world memories and real controls. No temple handling or route hints.

The developer normal-ramp trial on b13793e selected an eight-point forward
memory proposal, with its first point about25cm from the current pose. The first
sampled corridor was clear; then the remembered route disappeared, a partial
native route became active, and a water_ahead plan targeted that native route.
The45s operator bound stopped it below the requested floor, health100. This is
a failed developer diagnostic, not an autonomous outcome.

An isolated stationary-input fake reproduces the guarded stall branch discarding
the short-entry proposal, followed by native/water planning. It does not prove
why the live first input produced little displacement. Water avoidance explicitly
excludes memory steering; its observed replan was downstream, not the initial
cause. The separate inactive-native far_goal priority remains an open issue.

A later mid-ramp native-input recording has139samples,33while go_to was active.
Pending/last world input vectors and velocity were read successfully. Correctly
directed inputs moved about2.4m and climbed1.18m during an8s bounded attempt,
with substantial initial planning/guard wait and memory retained. This confirms
movement there, not the original connector's cause. The earlier sampler attempt
failed because Lua io.open does not accept mode wx; its ordinary trace is not a
high-frequency record. A subsequent setup refused movement when dehydration
lowered health below75; client was stopped at59HP. Supplied diagnostic water was
exhausted, and independent acquisition remains unproved. Private evidence:
R/logs/recovery/rp-trial-a719; no model calls in these diagnostics.

## Approach and review

The guarded stall decision currently precedes WALK.check and its pending-time
exclusion. Adapt execution-progress accounting: evaluate guarded stalls only
after a clear guard result, before further input. Establish the owned execution
window only after an actual input call returns with the same captured binding.
Exclude guard-held time without crediting progress. Cache expiry, refresh and
resampling do not reset accumulated active-input stall time. Reset only for a
new execution context. Preserve the1s/50cm thresholds, actual displacement,
command deadline, cumulative query spending, waypoint and arrival verification.

Astra approved this narrow control-flow correction with these conditions. Root
integrates and owns the only DEV operator; Terra owns move.lua/test_move.lua.
Do not bundle water-map changes, route-target priority, tolerance increases or
a scheduler replacement. The live original-entry hypothesis remains unproved
until an instrumented rerun on the tested candidate.

## Search record

Repository precedents: walk-scan-timing.md, player-route-proposals.md, the saved
Astra navigation review, existing guarded-stall/pending branches and native
game-thread timer usage. Root actually queried `site:docs.nav2.org route execution
path invalidated local planner path blocked observed route`; the worker queried
`site:docs.nav2.org progress checker required movement radius time navigation
controller` and `site:docs.nav2.org path following controller waypoint progress
checker robot stuck`. Opened primary sources:

- https://docs.nav2.org/jazzy/getting_started/nav2_behavior_trees/trees/navigate_on_route_graph_w_recovery/
- https://docs.nav2.org/jazzy/configuration_and_development/configuration_guide/core_servers/controller_server/controller_server_plugins/simple_progress_checker/
- https://raw.githubusercontent.com/PrismarineJS/mineflayer-pathfinder/master/index.js

Nav2 separates route/freespace planning and execution with progress checks;
Mineflayer separates path selection/reset and input execution. Adapt the existing
progress checker and guard ordering; no external framework or game API is
claimed compatible. Do not grant progress for stationary or oscillating input.

For the private read-only recorder, root searched `site:dev.epicgames.com APawn
GetLastMovementInputVector GetPendingMovementInputVector` and opened:

- https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/GameFramework/APawn/GetLastMovementInputVector?application_version=5.5
- https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/GameFramework/APawn/GetPendingMovementInputVector?application_version=5.5

These distinguish processed versus pending world-space input. Actual read calls
were verified in this client; neither consumes or resets the input. Timer APIs
reuse existing production LoopInGameThreadWithDelay/CancelDelayedAction paths.
Game time is latched within a synchronous callback: forward_search.duration_s=0
is not evidence of zero CPU/wall search cost. Keep that telemetry limit explicit.

## Generality and principles

The change concerns whether any guarded movement had an execution opportunity,
independent of place, task, item or model. No supplied paths or fabricated
outcomes. PRINCIPLES1/2/3/4/5/6/8/9 remain intact. It cannot establish unassisted
discovery, food/water self-sufficiency or the temple200m round trip by itself.

## Acceptance test

Reproduce more than1s guard-held time before a clear short-entry input; no
premature discard. Include long search/first-frame delay. Stationary actual input
and oscillation still fail in bounded time across repeated pending/clear cycles.
Owner/world/life/goal/deadline changes cannot input. Preemption during the input
call must not initialize or mutate a successor window. Preserve all current
stall, arrival and guard-budget assertions. Run focused then whole mover before
the required gate. Then instrument the original connector through real controls,
followed by full Sonnet+Haiku only after developer execution is positive. A taught
replay remains separate from the required unfamiliar-route discovery test.

## Cold-review first-frame correction

Astra found a source counterexample: a clear-producing callback can consume time
before AddMovementInput while native game time remains latched. Charging the
entire following tick delta counts pre-input work as execution. Use a one-time
first-observation anchor per execution context, retaining the displacement
baseline, then accumulate normal sent intervals. Never re-arm it on cache
refresh or pause. A focused case advances the frame clock2s inside the first
clear callback, permits the next input, and still requires eventual stalled
recovery under sustained blocked input. This is a reproduced timing contract;
it is not a claim that the original live25cm failure has been causally settled.
Pause clears the submitted-interval marker so paused time is held time; ordinary
stuck recovery cannot race the guarded walking checker. Deadline/spend remain.
