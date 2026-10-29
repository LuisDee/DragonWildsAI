# Player-grounded route admission

**Current decision:** use the sampled local-control reassessment below. The
original full-edge certificate proposal is retained as review history and is
not the production admission contract. Original goal judges are unchanged.

## Goal and current evidence

Follow [Accepted steer](autonomy-plan.md) and [the active Goal](../NEXT-GOAL-PROMPT.md).
The three unassisted full Sonnet/Haiku temple round trips remain unmet. Preserve
M1-M6, judges, all world memory and the real client input path.

Native Default/Gigantic both miss the measured ramp connection. A physically
walked short segment has collision floors consistent with capsule feet, yet its
endpoints fail tight Default projection. Separately trap t7's first remembered
exit is over three metres below the current upper floor; unconditional memory
selection led to step-off and a failed landing. Source453e543 fixes unrelated
corner/progress defects, not either of these admission failures.

## Approach and ownership

Reuse localplan as a bounded candidate generator, existing world/owner/life/goal
bindings, floor_read's typed posthook/lease and hookhub's single registration.
Memories are route proposals, not certificates of current connected walkability.
A fully verified local route to the actual nearby goal should precede a trap
exit. Memory entry and subsequent segments must use the same validation as
recovery, so a fallback cannot bypass a failed connector.

Implement one reusable player-edge verifier with injected observation backends
and bounded per-poll work. Candidate node Z is feet; query capsule centre at
feet + actual half-height. Require known walkable support on the intended floor,
known non-penetration, continuity/step/slope evidence and actual collision
clearance. A downward ray is a candidate surface, not capsule passage. Unknown
does not authorize input. For the first integration, ordinary walking only;
unproven jump/drop edges retain separate traversal requirements, not a silent
reinterpretation as a walk or a ban on the explicit movement tools.

First validate the native adapter, separately from planner authority. One
stationary query per synchronous invocation, no delayed callbacks, anchors,
position writes or physics-setting edits. Check DEV target externally, then pin
world/controller/pawn/component/shape and a permanently latched lifecycle inside
the invocation. Copy primitive observations, exact callback cardinality and
cleanup status; no wrapper escapes. A retained factory may reacquire its own
closed lease. Never adopt a closed marker with a new factory, unregister a native
hook or retry ambiguous ownership. Unsupported ABI leaves the adapter disabled.

CapsuleTraceSingle's return Boolean and profile semantics require an independent
clear/blocked control. Contact with a walkable floor must not be called a wall;
any reduced upper-body sweep intended to permit native stepping must preserve
actual top clearance and be justified against full-body/step controls before
use. No arithmetic-only clearance claim or guessed bitfield is acceptable.

After native validation and offline regressions, integrate lazy verification of
candidate paths and memory connectors in move/localplan. A bounded freshly
verified local prefix may advance toward a far goal when native coverage ends;
prefix completion is not goal arrival. Reobserve/requery at the endpoint, require
measured progress and finite attempts, and keep current three-dimensional arrival
and goal/owner/world/life invalidation. No temple coordinate or phrase branch.

Root owns this design, native adapter experiments and integration. A bounded Terra
worker may own the pure verifier/tests after fresh review; other files require
an explicit assignment. Candidate code stays in the isolated worktree; only a
frozen explicit diagnostic copy is loaded for native compatibility measurement.
Full regression gate/cold review precede production publication. Developer real
controls precede unassisted full-stack acceptance.

## Reassessment: sampled local control, not a continuous-support proof

Root's 2026-10-29 follow-up replaces the proposed production requirement for a
mathematical full-edge support certificate. That requirement was our design
choice, not Luis's frozen acceptance criteria. Finite native floor samples and
capsule sweeps do not prove continuous support or the exact future physics
trajectory; adding a `validated=true` label cannot change this. Do not wire the
pure `player_grounding.lua` certificate combiner into steering on that premise.

Use the established sampled, receding-horizon approach instead: bounded fresh
floor observations and the real full-size capsule sweep assess a short local
candidate; native character physics executes input; subsequent observations
check actual position, support, health and progress before further input.
Report sampled evidence and its resolution honestly, never a geometric proof.
Unknown/blocked observations hold or replan, memory is a proposal, and an invalid
entry cannot return through recovery. Initial non-overlap needs its own native
shape control; a floor hit alone is insufficient. Keep finite query, horizon,
retry and no-progress limits, current ownership/life/world checks and actual
three-dimensional arrival. The original judges and full-agent requirements do
not change. Native-positive/negative controls still precede deployment.

Additional actual search: `site:docs.nav2.org regulated pure pursuit collision
detection forward simulation time collision` and
`site:github.com/ros-navigation/navigation2 collision_checker.cpp regulated_pure_pursuit resolution`.
Opened primary Nav2 [controller description](https://github.com/ros-navigation/navigation2/blob/main/nav2_regulated_pure_pursuit_controller/README.md)
and [collision checker source](https://github.com/ros-navigation/navigation2/blob/main/nav2_regulated_pure_pursuit_controller/src/collision_checker.cpp).
Their finite forward projection and refreshed collision checking support this
control pattern, not a drop-in UE implementation or a floor-continuity theorem.
Decision: adapt the bounded feedback pattern, reuse native character movement
and existing planner; avoid expanding the isolated proof-combiner experiment.

### Diagnostic sampled walk observer

The isolated observer samples raised capsule-centre floor queries, resolves
centres using the applicable native floor distance and the observed standing
clearance, then sweeps the full capsule along the sampled polyline. The raised
query is a floor search, not an overlap test at the actual pawn position; a
separate full-shape overlap observation is needed for that claim. Missing or
malformed results remain unknown. Sampling and full-shape sweeps do not prove
support between samples or predict the exact native physics trajectory. The
observer records spacing, sample results and resolved centres as diagnostic
evidence; `sampled_clear` gives no movement authority. The caller owns native
binding, lifecycle, query/retry budgets and subsequent feedback. Real geometry
controls and the full acceptance sequence remain prerequisites to deployment.

## Walking integration boundary

The native sensor adapter owns one retained floor-reader factory and exact
logical leases. A short-horizon guard composes that sensor with the sampled
observer; it never writes inventory, position, physics or route memory. Hold
input while checking actual-centre -> next selected walking target (including
the first remembered waypoint). Keep operation query/time/retry limits and
short-lived covered geometry; waypoint changes or departure from that geometry
require a fresh check. Native physics and actual grounded/progress feedback
remain authoritative after input. Query/sweep unknowns are specific failures,
not permission to step off or use the ordinary blind recovery ladder.

For short actual goals, a native or local complete-goal route takes precedence
over an unverified trap exit. Rejecting a memory entry routes the command through
the same held local planning path as missing native coverage, preserving memory.
At a far native partial endpoint, a bounded locally planned walking prefix can
advance under that guard; completion discards prefix authority and reobserves
under the original goal. It is never goal arrival. Bound prefix count, sampling
and repeated/no-progress attempts without resetting the total command deadline.
Existing typed jumps retain their separate execution/landing checks; new walking
admission does not invent jump range or reinterpret a drop as supported walking.

Additional actual search: `site:github.com/PrismarineJS/mineflayer-pathfinder
index.js partial path resetPath stuck tickTimeout` and
`site:docs.nav2.org path tracking local planner rolling window replanning progress checker`.
Opened actual [Mineflayer controller source](https://raw.githubusercontent.com/PrismarineJS/mineflayer-pathfinder/master/index.js)
and [Nav2 controller source](https://github.com/ros-navigation/navigation2/blob/main/nav2_regulated_pure_pursuit_controller/src/regulated_pure_pursuit_controller.cpp).
Reuse their bounded partial-plan/replan and fresh control-result patterns as
conceptual precedent. Neither is a native Dragonwilds backend. Root owns mover,
guard and integration tests; Terra owns walk_sense and its focused tests.

### Integration review and current limits

Astra cleared final source1089cbb9 (move),2f757746 (guard) and166831ed
(sensor) for the fresh full gate. Fixes cover reactive-hop and inherited-strafe
bypasses, actual-pose checks after native callbacks, moving actor identity,
retained exact cleanup, nav=false recovery, and preemption during sprint reads.
Memory selection waits for an existing airborne transaction, and immediately
latches guarded steering when it selects a proposal. Guarded sprint is withheld;
TryRequestStopSprinting(uint8) requests release and requires an observed false
IsSprinting before input. The reflected game ABI is in Dominion.hpp:35379;
actual stop acknowledgment is a required developer control, not yet proven.

New sprint research query: `site:dev.epicgames.com enhanced input sprint
Completed Canceled input actions`; opened
https://dev.epicgames.com/documentation/en-us/unreal-engine/enhanced-input-in-unreal-engine .
This documents input state transitions, not this game's custom sprint request.
Reuse the existing client request path, not a movement-speed property write.

This first integration guards memory, admitted local routes and their subsequent
recovery inputs; ordinary legacy local plans otherwise retain their existing
checks. Far local prefixes currently require immediate progress toward the goal.
A larger detour may therefore remain unavailable; rejection is not proof that no
route exists. No generic jump-gap acceptance is claimed. Guarded corner advance
uses10cm to avoid cutting outside sampled geometry, and total command deadlines
remain independent of planning/sampling pauses.

Independent fake-world corrections: walking admission fixtures now include the
claimed physical slope, ray normals distinguish slopes from vertical walls, and
fixtures restore their geometry afterward. With those truthful normals, direct
following can remain valid on the plateau test; its actual distance/elevation
arrival assertion remains, while an implementation-only demand for breadcrumb
selection was removed. Frozen judges are untouched.

## Acceptance and negative controls

### Fresh review amendments (Astra)

Approve bounded pure verification/fake-backend work only; native compatibility
and production movement authority remain separate gates. Each directed edge
must independently report `verified`, `blocked` or `unknown` for support
continuity, initial nonpenetration and swept passage, with source/binding and
configuration provenance. Known endpoints do not certify the intervening edge.
The adapter must define and validate its bounded spatial coverage, not invent a
continuity Boolean from two floor samples or MaxStepHeight arithmetic.

Cover actual pawn-to-first-node, every executed segment and any shortcut; the
candidate planner's self_r floor substitution and skipped near-pawn checks are
not admission evidence. Use native collision/ignore identities rather than a
blind zone. Rejecting a memory connector is temporary to this attempt/config,
not a deletion or declaration of impossible destination; recovery must not
bypass it with an unsupported step-off. Certificates include geometry/start,
world/life/owner/goal and actual collision shape/configuration. Stop before
leaving covered geometry and preserve cumulative query/retry/prefix exhaustion.
Ordinary-walk inability does not forbid the model's separately supported jump
or drop choices. Native controls precede any authority enablement.

Stationary native positives: current floor and physically walked ramp; negatives:
unsupported location/ledge, wall, low ceiling and actual initial penetration.
Do not infer penetration from Distance zero or clearance from false copied flags.
Log profile/capsule dimensions, observed floor position, source and unknowns.

Offline: same XY on different floors; gap, narrow passage, ceiling, unsupported
node, malformed/unknown/zero-distance readings, owner/life/world/goal changes and
budget exhaustion; no movement on unknown. An invalid memory connector must not
reappear through stuck recovery. A valid local route to the goal beats an old
trap proposal. Far partial path executes only a verified prefix, reobserves and
never reports false arrival or loops indefinitely. Preserve water, jump/link,
follow and old memory data. Live tests include changed target and another slope/
doorway, then the exact original three full-agent round trips.

## Search record

Root queries: `site:dev.epicgames.com CharacterMovement K2_FindFloor capsule
location walkable floor navigation mesh`, `site:docs.nav2.org collision checking
path validity local planning global path`, `site:github.com/PrismarineJS/mineflayer-pathfinder
movements collision path shortcut`. Terra independently searched native floor,
CapsuleTraceSingle, Recast partial-path and walkable-slope documentation.

Primary sources opened:

- https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/GameFramework/UCharacterMovementComponent/K2_FindFloor?application_version=5.5
  Capsule-centre floor sweep; reflected API exists, broader query behavior still
  needs current-runtime controls. Prior reader controls are in r26-floor-observations.
- https://dev.epicgames.com/documentation/en-us/unreal-engine/python-api/class/FindFloorResult?application_version=5.1
  Distinguishes support, distance, line fallback and initial penetration.
- https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/Engine/UKismetSystemLibrary/CapsuleTraceSingle
  Proposed clearance primitive, not yet validated profile/ABI here.
- https://github.com/recastnavigation/recastnavigation/blob/main/Detour/Source/DetourNavMeshQuery.cpp
  Native partial-path behavior is not a theorem about all player movement.
- https://dev.epicgames.com/documentation/en-us/unreal-engine/walkable-slope-in-unreal-engine
  Walkability derives from actual character/surface settings, not a place rule.
- https://github.com/PrismarineJS/mineflayer-pathfinder
  Reuse candidate/verified movement, bounded planning and real goal-result contracts;
  its voxel API/coordinate conventions are not a Dragonwilds backend.

The attempted Nav2 collision-monitor URL returned404; it is not evidence of an
available integration. Decision: reuse native and current modules, adapt evidence
and authority contracts, build only the missing bounded verifier/adapter glue.
Do not replace the Director, Controller, A*, Dijkstra or world streaming system.
