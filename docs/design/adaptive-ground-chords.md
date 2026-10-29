# Refine a blocked ground-following chord without relaxing collision checks

## Goal and evidence

Follow Accepted steer in autonomy-plan.md and preserve original M1-M6/judges.
This repairs a generic motion-validation defect; it does not supply a temple
route or establish unfamiliar-route discovery.

On tested 7142526 the original short entry passed and the mover followed five
recorded points, climbing about 3.2m, before rejecting an upper-ramp sweep. The
native sampler uses intervals capped at half the capsule radius: about 17cm for
the measured Player capsule (radius34cm, half-height88cm, step45cm).

A fresh stationary query from the actual pose reported blocking along the
retained target segment. Its surface normal faced upward. After exact-pose and
cleanup checks, real developer movement crossed that segment, ending grounded
and healthy. No driver jump/teleport command was issued. This is a developer
physics discriminator, not autonomous gameplay or a StepUp capability proof.

Stationary native sampler controls: the ordinary interval blocked after13queries;
10cm,5cm,2cm spacing produced sampled_clear after35,67,165queries respectively,
with unchanged capsule, native support checks, binding and cleanup. The actual
failed subspan was then tested directly: its original full-capsule chord still
blocked, but freshly resolving its midpoint floor and then its original endpoint
made both full-capsule subsegments clear. The midpoint centre is about3.2cm above
the original straight interpolation. This is a different supported trajectory,
not a declaration that the original blocked chord was clear.

Private evidence: R/logs/recovery/rp-trial-a719/{original-connector-a730.json,
actual-query-then-input-a735.json,sampler-segment-a737.json,
midpoint-native-a738.json}. Actor/component identities remain unknown; no unsafe
weak-handle dereference was attempted. Copied trace Boolean bitfields are not
treated as native truth; native return Boolean and finite vector/scalar geometry
were recorded separately. All diagnostics were DEV-only and root-operated.

## Approach and review

Reuse the existing floor-resolution and full-capsule sweep sampler. Only after a
known blocking sweep, replace that candidate chord by two ordered subsegments.
Freshly resolve the midpoint support from the current supported centre, sweep
the full capsule to it, then freshly resolve the original endpoint from the new
support and sweep again. Keep completed coarse samples. Maximum subdivision
depth two. Do not refine unknown queries, initial overlaps or invalid floors.

Every failed parent and refinement query consumes the unchanged cumulative and
per-poll budgets. Inserted samples count against the unchanged maximum128.
Preserve initial admission, finite fields, native walkability/penetration,
height/step bounds, final layer, binding, scan age, horizon, freshness and cleanup.
An unresolvable leaf remains blocked; exhaustion remains unknown/blocked. Keep
the ordinary clear path fast rather than globally increasing sampling density.

Return the actual accepted sample count/polyline, plus bounded primitive
original-block and refinement metadata. Preserve sanitized evidence through
walk_guard cleanup so future rejection is inspectable. Never label the original
blocked chord clear, shrink the capsule, ignore a hit or add location rules.

Astra approved this bounded design conditional on the native midpoint control;
that control passed with valid binding/cleanup and unchanged health100. Root
owns design/integration/live operation. Terra owns sampler/guard and their tests;
no movement-controller or task-policy changes belong in this patch.

## Search record

Repository precedents: sampled_ground_walk.lua, walk_guard.lua, prior stationary
segment compatibility diagnostics, active-guard-progress.md and saved navigation
reviews. Root actually searched `site:dev.epicgames.com UCharacterMovementComponent
MoveAlongFloor StepUp ComputeGroundMovementDelta blocking hit slope capsule sweep`
and opened:

- https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/GameFramework/UCharacterMovementComponent/MoveAlongFloor?application_version=5.5
- https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/GameFramework/UCharacterMovementComponent/StepUp?application_version=5.5

Root also searched `site:ompl.kavrakilab.org stateValidation DiscreteMotionValidator
checkMotion resolution subdivision` and opened:

- https://ompl.kavrakilab.org/stateValidation.html
- https://raw.githubusercontent.com/ompl/ompl/main/src/ompl/base/src/DiscreteMotionValidator.cpp

The worker searched `site:ompl.kavrakilab.org discrete motion validation resolution
state space midpoint collision` and `site:github.com/ompl/ompl
DiscreteMotionValidator.cpp checkMotion midpoint validity`, opening the same
documentation and the GitHub source view. Unreal documents floor-derived motion
and stepping; OMPL documents subdivision and its accuracy/cost tradeoff. These
are conceptual precedents, not APIs directly callable in this Lua runtime.
Unlike interpolation-only subdivision, this adaptation obtains new native floor
support and validates a different grounded polyline with full sweeps.

## Generality and principles

The rule depends on current capsule geometry, native floor evidence and a
bounded failed motion segment, independent of place, recipe or goal wording.
PRINCIPLES1/2/3/4/5/6/8/9 remain intact. Models retain intent. No memory is erased
or taught route counted as independent discovery. Unknown remains unknown.

## Acceptance test

Pure sampler/guard regressions: one/two-level supported curve succeeds with every
new full sweep observed; flat clear path adds no queries. Tall wall, low ceiling,
unsupported/unknown/penetrating midpoint, wrong floor, second-half obstruction,
initial overlap and unknown sweep stay rejected. Per-poll/cumulative/sample and
depth bounds hold. Reentry/lifecycle change cannot leak evidence or authority.
Actual sample count, order and bounded metadata survive cleanup accurately.

Run focused modules, actual mover integration and cold review before the required
gate. Then stationary candidate replay on native geometry, developer normal
guarded walking through the original connector/ramp and doorway, followed by full
Sonnet+Haiku only after positive developer execution. A separate unfamiliar-route
test without recorded path, demonstration or hidden hints remains required.
