# Native walking progress on uneven ground

## Goal and evidence

Follow [Accepted steer](autonomy-plan.md#accepted-steer--luis-2026-10-28),
[PRINCIPLES](PRINCIPLES.md), and the
[independent reset review](../research/2026-10-29-astra-independent-reset-review.md).
Original M1-M6, frozen judges, complete Sonnet Director + Haiku Controller
acceptance and the three unassisted round trips remain unchanged. This note is
a bounded repair approved by fresh design review. Implementation remains subject
to cold source review, the final combined gate and live measurement. No
autonomous pass is established.

Developer replay a828 on published `35d8d61` passed the earlier 3 cm memory
splice. Memory subsequently rejected `scan_timeout`, then generation 8 selected
a complete five-point native path. That timeout is a separate unresolved cause;
this proposal addresses the subsequent false no-progress recovery only.

Private evidence is under `C:/gameserver/logs/recovery/lpc-trial-a819/`:
`outbound-input-a828.json`, `outbound-input-a828-samples.jsonl`, and the later
read-only `retained-segment-a829.json`. Calculated predicates and the executable
exact-helper discriminator are in `native-segment-a828/`.

The native leg is floor coordinates `[8760,180527,-2998]` to
`[13312,181024,-3030]` cm, length 4579.05 cm. Its retained progress state has
`mark=315.9223`, `high=409.4601`. The requested original goal and binding metadata
both remain `[18212,181469,-2878]`; native waypoint remains 2. Native response
coordinates are multiplied by 100 without a Z offset; the progress helper
compares them to actual pawn centre minus its measured 88 cm half-height.

| Actual centre X (m) | Along leg (cm) | Lateral (cm) | Feet minus linear Z (cm) | Observation |
|---|---:|---:|---:|---|
| 90.740 | 315.92 | 0.419 | -57.81 | Last credited pose |
| 92.556 | 498.61 | 0.403 | -69.27 | Guard pending; already outside Z predicate |
| 101.051 | 1353.09 | 0.317 | -112.94 | Grounded, moving, sampled guard clear |
| 104.893 | 1739.57 | 0.279 | -114.71 | Grounded, moving, sampled guard clear |
| 105.944 | 1845.36 | 0.271 | -117.21 | Grounded, moving, sampled guard clear |

The segment helper requires feet within 65 cm of a straight interpolation of
the two distant waypoint heights. Later poses pass its XY bounds but fail that
height test, so high-water freezes before the next 150 cm credit. Actual motion
continues: trace 21 selects backtrack at X104.467 m; trace 23 invokes Bug2 at
X106.230 m, with the same X90.740 m progress baseline (15.58 m displacement).
Guard holds extend the timer but do not explain the clear-tick rejection.

This is distinct from the previous early waypoint-credit bug: there is no
waypoint transition to credit, a segment baseline was installed, and its
high-water advanced before the Z predicate began rejecting. Endpoint/origin and
the complete path agree with the selected-source trace. Stop increments the
generation and closes the guard, but does not clear path or segment state;
retained state is corroboration, not a historical guard-clear assertion.

## Reviewed approach

Adapt existing `WALK.credit` ownership/goal/world validation and existing fresh
guarded-input evidence for **liveness along the selected native walking leg**.
Keep the helper's monotonic XY high-water, endpoint/replan compatibility,
150 cm threshold, bounded physical novelty history and original deadline.
Replacing a path or reseeding a guard supplies no credit.

For an ordinary guarded native walking tick, permit fresh actual supported
movement to satisfy the pose-height eligibility for segment liveness, instead
of requiring the long native corner chord to model the terrain surface. Retain
the XY corridor/projection test and reference-leg compatibility tests. The
alternative needs the exact selected path/index/endpoint and binding metadata,
current goal/world/life/owner, actual unchanged pose, grounded observation and
fresh `sampled_corridor` clearance for that exact aim. Reuse the already
validated input sample or a tightly scoped primitive record from its final
admission site, before later native callbacks can stale it. Consume/revalidate
that record through existing ownership checks; no report-status-only shortcut.
Start with fixed coordinate native targets, matching existing conservative
dynamic-target exclusions. Preserve old actor-target behavior.

No alternative credit for pending/blocked/unknown/stale guards, missing input,
airborne state, jump/link/Windstep execution, changed route/aim/binding, stale
pose, pause/death/world/owner changes, lateral escape or novel-history loops.
Held ticks may keep their existing time accounting but must not mint movement.
Actual pre-input pose movement, rather than submitted input count or elapsed
time, drives projection and novelty. A first valid baseline earns no credit.

This deliberately separates liveness from endpoint validity. A fresh local
guard observes a short supported corridor; it does not prove identity with a
distant endpoint floor or global native mesh polygon. Genuine walking on a
different supported floor can be physical liveness, but must never advance an
unreached waypoint, credit a link landing, or report arrival. Existing endpoint
height/support, guarded waypoint and final original-goal checks remain intact.
Do not enlarge 65 cm, remove Z for unguarded routes, relax the terrain guard,
change recovery thresholds, or alter native/memory source selection here.

Implementation scope: `client_mod/scripts/move.lua`, focused
`client_mod/tests/test_move.lua` regression, and this note. No new navigation
framework, native API or observer is needed. Put the relevant direct source URLs
next to any adapted code.

## Acceptance test and limits

The private discriminator reads `novel_progress` and `segment_progress` directly
from current production source, with retained path/history and recorded poses.
It verifies six actual later poses all reject without changing high-water;
changing only one pose's Z to the linear chord causes credit. Lateral escape,
wrong-height and repeated-pose novelty controls reject. This proves a predicate
cause, not a full mover repair or actual floor mesh.

Before publication, use one bounded actual-mover test with the real guard and
an independently specified uneven supported surface under a long native leg.
Baseline must physically advance, retain waypoint 2, lose segment credit and
enter recovery; candidate must keep physical high-water credit and avoid that
false recovery without forcing helper returns or progress state. Use existing
finite-step harness, not a physics calibration project. Include no-motion,
oscillation/loop, wrong-floor destination (never arrives), missing/blocked/stale
guard, airborne/traversal, changed owner/world/goal/pose during callbacks, and
compatible replan controls. Focused tests only; root runs the final full gate
once on frozen bytes, then developer real controls and full Sonnet/Haiku.

Implemented by extending `WALK.credit` with an optional validated walking sample.
It rechecks exact path/index/endpoint/aim/guard, binding metadata, actual ground,
guard freshness including callback elapsed time, then actual unchanged pose and
primitive ownership/life/world/goal checks before mutating the existing segment
state. The additional guard call normally reads its fresh cache; real query and
latency cost still require the developer replay. Ordinary unguarded routes,
dynamic targets and typed traversal retain their prior behavior. No waypoint
index or arrival predicate changes.

Focused actual-mover discriminator (same fixture and independent terrain):

- Published `35d8d61`: advances 1080 cm, last physical credit 300 cm, selects
  backtrack at world time 16.9 seconds; expected baseline failure.
- Candidate: arrives at X2955 cm within the ordinary 50 cm target tolerance,
  19 observed physical credits, 198 held ticks, 122 clear observations below the
  native chord, no backtrack/Bug2. Native endpoint remains Z=-90 cm.
- Airborne, blocked/unknown sensor, absent effective input and wrong-floor
  destination controls cannot manufacture the new progress or arrival. Airborne
  control retains pre-existing chord-based credit before leaving its height
  band; it cannot use the new supported-movement alternative.
- Thirteen reentrant ground callbacks change world, goal, path, index, endpoint,
  pose, owner, guard, metadata, life, pause, clock freshness or jump state. Every
  case leaves its pre-callback progress baseline and novelty count unchanged.

The synthetic surface descends 120 cm over 6 m, stays low for 10 m and rises
over the remaining 14 m; it is not calibrated game terrain. Input speed is the
existing harness's 150 cm/s detour control at a finite 0.1 second cadence, so the
unchanged five active-second give-up window can expire inside the low section.
The fixture sets the same guarded execution mode reached after memory in a828;
live tests must reach that state naturally from the ordinary outward command,
without setting guard flags. An initial surface boundary seam was corrected
before the baseline comparison; no gameplay thresholds were tuned.

Commands (unique private roots beneath this worktree):

```powershell
$env:MOVE_NATIVE_SEGMENT_ONLY='1'
$env:MOVE_NATIVE_SEGMENT_REPLAY_ONLY='1'
$env:MOVE_FILE='C:/gameserver/client_mod/scripts/move.lua'
lua client_mod/tests/test_move.lua logs/recovery/native-segment-baseline-a6
# Expected baseline exit 1: x=1080, progress=300, recovery=16.9.
# Fresh process, without MOVE_FILE or MOVE_NATIVE_SEGMENT_REPLAY_ONLY:
$env:MOVE_NATIVE_SEGMENT_ONLY='1'
lua client_mod/tests/test_move.lua logs/recovery/native-segment-final-a10
# NATIVE SEGMENT OK. Log: logs/recovery/native-segment-final-a10.log.
```

The existing `MOVE_PROGRESS_CREDIT_ONLY=1` focused suite also passes on the
candidate (`logs/recovery/native-segment-credit-a8.log`): real guarded 40 m
execution uses four local prefixes with 17 credits and zero lost credits;
revisited poses, early native/memory ownership, callback invalidation, dynamic
targets' prior behavior and local no-progress ownership remain covered.
Design-note checks pass (five tests). Whole-mover certification is reserved for
root's combined full gate, not duplicated by this worker.

## Generality and principles

Long sparse native corners need not linearly describe intervening walkable
height. The change belongs in generic progress accounting and uses observations
already required for real movement. It adds no place, route, model hint or
synthetic physical progress. Floor-sensitive reach/arrival remain separate.
No principles or judges require an exception.

## Search record

2026-10-29: read the repository search-before-building skill, Accepted steer,
PRINCIPLES, Astra reset review, current segment/helper/input/guard code, and
earlier guarded-waypoint/local-progress notes. Actual fresh queries:

- `site:recastnav.com dtPathCorridor movePosition height corridor`
- `site:docs.nav2.org SimpleProgressChecker movement distance path progress`

Opened primary sources:

- https://recastnav.com/classdtPathCorridor.html — actual movement feeds back into
  a corridor constrained to the mesh surface. Conceptual precedent only; the
  game bridge does not expose Detour corridor polygons here.
- https://raw.githubusercontent.com/recastnavigation/recastnavigation/v1.6.0/DetourCrowd/Source/DetourPathCorridor.cpp
  — `movePosition` uses `moveAlongSurface` then `getPolyHeight` at the resulting
  polygon, rather than interpolating the distant corner heights. Stable v1.6.0
  source; no upstream code copied.
- https://raw.githubusercontent.com/ros-navigation/navigation2/main/nav2_controller/plugins/simple_progress_checker.cpp
  — renews a baseline from observed physical displacement; its XY movement
  radius is separate from arrival. Conceptual precedent, not a license to
  remove our route high-water, novelty or floor checks.
- https://docs.nav2.org/rolling/configuration_and_development/configuration_guide/core_servers/controller_server/controller_server_plugins/simple_progress_checker/
  — documents distinct movement-radius and time-allowance controls. No Nav2
  thresholds adopted and no claim that those APIs exist in this runtime.

Decision: **adapt** existing validated mover admission/ownership and progress
accounting. Do not build a new planner or copy Nav2/Recast implementation. Real
runtime evidence establishes only the recorded sampled observations and helper
predicate mismatch; surface topology between distant points remains unknown.
