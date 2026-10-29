# Floor probes follow observed support

## Goal

Remove a demonstrated false walking rejection without bypassing collision or
adding a route for the temple. Preserve Accepted steer in autonomy-plan.md and
the original frozen M1-M6 judges.

## Evidence and approach

Private native-input-ab-a705 recorded a rejected nav segment. Production-matched
normal input crossed its remaining 117.82cm in0.77s, grounded/health100; independent
post-control confirmed stopped at the aim with no owner. The earlier0.2/50ms
control was inconclusive. This is developer evidence, not an autonomous pass.

Read-only historical support-query replay resolved five samples to the same flat
floor. The sixth raised probe missed: the interpolated navigation height had
raised its origin beyond the measured47.4001cm native search distance. No blocking
hit was observed. The replay omitted the initial-position check because the pawn
had already moved; it grants no movement authority.

Adapt the existing sampler: each forward probe uses the previously resolved
capsule height, not interpolated target elevation. A known, nonpenetrating,
nonblocking raised miss gets one budgeted lower probe at that previous height.
Never retry a blocking nonwalkable hit, penetration, unknown fields, callback
failure or start-floor failure. A second miss means support unknown, not a wall.
Resolve height from the actual query origin; bound the delta against previous
observed support by MaxStepHeight. Keep full capsule sweeps, initial checks,
bindings, finite budgets, freshness and final goal/floor verification.

The first full gate caught a wrong-floor remembered-connector regression
(1278passed,1failed,1skip): removing interpolated probes also removed all
requested-height consistency. After the final support and full sweep, compare
the resolved centre with finite to_feet.Z+half_height+clearance within one step;
otherwise report unknown target_support_mismatch. This comparison does not
position probes. Keep existing no-input/jump/step-off and actual-goal-replan
integration assertions; update only their more accurate failure classification.
Fresh Terra review CLEAR. A rolling-horizon height remains an estimate, so a
nonlinear slope may still conservatively return unknown; this is not floor
identity proof (especially for layers separated by less than a step). Measure
such failures before choosing another repair. Include the actual mover's
grounded-walking integration subset in preflight before the next full gate.

Retain bounded primitive failure details (phase, query, flags/distances/normal)
for truthful diagnostics. No new native backend or movement authority.

## Search record

Queries actually run2026-10-29: `site:dev.epicgames.com FindFloor capsule location
vertical sweep MaxStepHeight ComputeFloorDist walkable floor` and
`site:github.com Unreal Engine CharacterMovementComponent FindFloor
FloorSweepTraceDist MaxStepHeight MAX_FLOOR_DIST`.

Opened primary documentation:
- https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/UCharacterMovementComponent/FindFloor?lang=en-US
- https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/Engine/UCharacterMovementComponent/ComputeFloorDist
- https://dev.epicgames.com/documentation/en-us/unreal-engine/BlueprintAPI/Pawn/Input/AddMovementInput
- https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/Engine/APawn/ConsumeMovementInputVector

FindFloor is a capsule-location vertical query; it does not guarantee arbitrary
downward range. ComputeFloorDist exposes explicit sweep/line ranges. Input is
scaled and consumed during updates. These docs contextualize the runtime
measurements, not proof of this game's API compatibility. Decision: adapt the
existing measured native floor service and sampler; no library replacement.

## Generality and principles review

Fresh Terra design review CLEAR with the bounded fallback conditions above.
Cold review subsequently required two admission checks: a fallback must also
observe the hit's blocking flag as known false; contradictory/unknown hit flags
cannot qualify. Starting support distance must be within5cm, matching the native
sensor's existing grounded-clearance bound. Small signed negative distances are
preserved (the existing-0.58cm case); penetration remains a separate flag.
Successful samples record the actual query origin and fallback use so telemetry
does not mistake the initial raised position for a lower query.

This fixes
probe geometry for any floor/target; no entity, location or recipe logic.
PRINCIPLES1/2/3/4/5/6/9 remain intact. Developer fixtures were declared, cannot
establish independent survival. Native guard and real collision stay in place.

## Acceptance test

Offline misleading-height flat floor, ascending/descending support, bounded
lower fallback across polls, no fallback on unsafe/unknown hits, excessive delta,
budget and binding failure, primitive failure details. Fresh cold review and
required gate; developer actual go_to on deployed controls; then complete
Sonnet Director+Haiku unassisted200m round trips/generalization. No new autonomous
pass is claimed by this note or the short native control.
