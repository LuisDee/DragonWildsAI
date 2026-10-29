# Preserve path corners and count actual route progress

## Goal and evidence

Keep generic admitted paths intact and avoid calling a correct detour stalled.
This is a bounded subrepair of Luis's [first traversal deliverable](../NEXT-GOAL-PROMPT.md),
not a claim to solve the missing temple navmesh or unsafe memory connectors.
The [Accepted steer](autonomy-plan.md) and original frozen M1-M6 judges apply.

Astra found `advance()` skips an unreached point whenever the next point is
closer than the intervening segment length. Counterexample in metres:
character `(0,0)`, mandatory corner `(10,0)`, following point `(0,10)`. The
condition is true immediately although the corner has not been approached.
The rule runs on native, local, memory and leader routes. Nearer does not prove
a collision-free shortcut. Existing height slack can also admit a wrong level
at a large horizontal separation; only proximity may trigger advancement.

Native index progress is tested against an index copied immediately before the
test, without advancement between those operations. Actual native advancement
occurs earlier. The bounded stagnation clock otherwise measures only progress
toward the final goal, which can decrease on a legitimate detour.

## Approach and boundary

Owner of implementation: one bounded worker assigned by root after fresh review.
Files: `client_mod/scripts/move.lua` and focused movement tests. Retain point
reach radius, floor/centre convention, explicit traversal/link landing checks
and all movement ownership/life/world guards. Remove the unsupported
next-point-nearer shortcut. Record actual native index advancement where it
happens, and measure forward progress on the current admitted route segment
without treating changing route identity, oscillation or arbitrary displacement
as perpetual progress. Retain finite stagnation and action deadlines.

Do not relax arrival elevation, accept partial routes as arrival, bypass native
authority, activate unverified memory connectors or alter jump admission. If
strict radius advancement exposes overshoot, first measure that case; any passed
point alternative must prove segment continuity/corridor and floor, not restore
the nearer-next heuristic under another name. Preserve all per-world data.

## Acceptance

Use the existing fake-native movement harness with physical obstacles: an L/U
detour must retain required corners; an outgoing point across a wall cannot
justify skipping; same XY on another floor is not reached; links still require
landing; a real detour making progress away from the final goal must not time
out as stagnant. Overshoot must terminate or recover rather than oscillate
forever. A motionless or repeatedly repathed agent still fails within its bound.
Run focused movement tests, cold review, then the full gate before deployment.
Developer real-client checks precede full Sonnet/Haiku acceptance. The temple
round trip remains unmet until separately measured.

### First implementation: cold review requested changes

The first implementation passed the focused tests and complete fake movement
harness, including a genuine dense-water-waypoint regression fixed during
development. A fresh Astra review nevertheless blocked the full gate: lifetime
endpoint histories can reject a legitimate persistent-follow revisit; exact
endpoint keys allow jittered intermediate corners to bypass oscillation checks;
three unbounded histories add lifetime work/state. New negative assertions also
ran beyond the action timeout and did not prove the stagnation bound itself.
Do not interpret those test passes as publication approval.

The revision must preserve equivalent-segment high-water through jittered
replans, allow genuinely new traversal episodes without granting time merely
for a new route, bound retained state/work, and make negative controls fail by
stagnation before the action deadline. Persistent follow must revisit a long
edge and approach a reused endpoint from a different valid leg successfully.
Actual oracle replacements must jitter intermediate endpoints, not only starts.
The author owns movement/tests; main owns integration; fresh review precedes
the full gate. Native coverage and remembered-floor entry remain separate work.

### Approved bounded revision

Astra approved one active segment with a monotonic high-water, retaining its
original geometry across equivalent jittered replacements. Initialize a new
segment only at a pose inside its corridor and interpolated floor; initialization
does not earn time. Route and waypoint progress share one physical-novelty check
and bounded pose FIFO; consume forward high-water even when novelty refuses
credit. Eviction only follows actual new credit and earns nothing itself.

Seed each episode at the current pose; reset evidence only after verified
near-to-resume or material live-target displacement from a stable epoch anchor,
never a route table/nonce or frame jitter. Evidence reset preserves stall age.
The FIFO is bounded local liveness, not a global no-cycle proof; unchanged fixed
goal deadlines and three-dimensional arrival checks retain their separate roles.
Add actual follow revisit and new incoming-leg positives, jittered intermediate
endpoint/stagnation negatives before action timeout, and a bounded-state longevity
check. This revises the implementation approach, not the final goal or judges.

### Verification of the revised candidate

Fresh Astra cold review cleared the bounded revision. Focused protocol tests,
all movement Lua checks including the original water controls, and preflights
passed. Full `tools/check_all.ps1` completed: 1,250 passed, 1 skipped in 452.78 s,
CHECK_ALL: GREEN. Frozen judges were unchanged and candidate file hashes match
the pre-review freeze. The live risk of a sparse curved segment departing over
65 cm from its interpolated height must be measured before claiming autonomous
acceptance. No new live or full-agent pass is implied by this gate.

## Search record

Root searched `site:docs.nav2.org regulated pure pursuit path pruning collision
checking carrot corners`, `site:github.com ros-navigation navigation2
SimpleProgressChecker path progress distance goal detour`, and `site:github.com
"waypoint" "dot product" "segment" path follower waypoint passed`. Primary
documentation/source opened:

- https://docs.nav2.org/jazzy/configuration_and_development/configuration_guide/controller_plugins/configuring_regulated_pp/
  Collision-checked lookahead is distinct from skipping an arbitrary route corner.
- https://raw.githubusercontent.com/ros-navigation/navigation2/main/nav2_controller/plugins/simple_progress_checker.cpp
  Bounded pose-motion detection is a liveness signal, not proof of goal completion.
- https://raw.githubusercontent.com/ros-navigation/navigation2/main/nav2_bt_navigator/src/navigators/navigate_to_pose.cpp
  Tracks path-relative remaining distance and updates for path changes.

Decision: adapt the established distinction between path progress, liveness and
arrival inside the existing mover; reuse tests and control paths. Do not import
ROS or copy its coordinate conventions. These are conceptual precedents, not
verified Dragonwilds APIs. Principles: generic, real inputs, truthful outcomes,
two-speed control, one owner; none require an exception.
