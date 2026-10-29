# Guarded intermediate waypoint crossing

## Goal and observed evidence

Follow [Accepted steer](autonomy-plan.md#accepted-steer--luis-2026-10-28)
and the [independent reset review](../research/2026-10-29-astra-independent-reset-review.md).
Original M1-M6, frozen judges and complete Sonnet Director + Haiku Controller
acceptance remain unchanged. Root owns the single DEV client. This proposal is
an offline candidate, not a live or autonomous pass; the temple streak is 0/3.

Observation-only revision `ccfd357` was deployed. Developer normal outward
`go_to` a810 succeeded in 32.953 seconds, health 100, using disclosed
developer-learned route memory. Developer return a812 failed after approximately
13 seconds with `target_support_mismatch`, health 100. Private evidence is
`C:/gameserver/logs/recovery/nct-trial-a804/normal-entry-a810.json` and
`return-lodestone-a812-samples.jsonl`. These are developer diagnostics.

The first return-memory aim was [8523,185530,-3138] cm (capsule centre), with
initial pose [8548.6330,185523.0666,-3138.5206] cm, approximately 26.55 cm away.
The memory route remained at waypoint 1. Observations bracket both sides of
that waypoint: a later position was [8481.8889,185541.1209,-3137.5457] cm;
the discard position was [8567.1235,185518.0639,-3139.4870] cm. The first
invalidation was `guarded_stall`: clear sampled corridor, 1.0028744 seconds of
admitted-input exposure and 19.1553 cm displacement against the existing
1 second / 50 cm stall check. On the next tick the preexisting partial native
path became selected. No complete-native replacement or memory-binding failure
preceded this discard.

The trace proves repeated sides of a tight waypoint and the first discard.
Sparse observations do not prove the exact per-frame trajectory, friction,
acceleration or braking. Current code always submits a normalized direction at
ScaleValue 1 and advances guarded waypoints only when a sampled pose is inside
a 10 cm disk. Missing a disk between control samples is the targeted hypothesis.
The downstream support mismatch is not evidence that the memory connector was
physically blocked.

## Approach and review

Root selected one physical mechanism: recognize bounded, observed crossing of
an ordinary intermediate waypoint. Do not change input magnitude, tolerance,
stall limits, guard geometry, destination, model choice or route discovery.
Analog approach taper is deferred until this candidate is measured, so two
physical mechanisms do not obscure attribution.

Retain the existing point-nearness advancement. Add a crossing alternative only
for ordinary guarded walking intermediate points, using the immediately previous
owned input sample and the current actual pose. The proposed contract is:

- The previous sample actually submitted guarded input to this exact path table,
  waypoint index and endpoint, under the same command, owner, world, life,
  character, controller and requested goal. No pending or paused interval,
  route replacement, changed target or traversal may supply a crossing sample.
- Both endpoint samples are observed grounded. The elapsed interval must be
  positive and at most the existing guard freshness horizon (0.35 seconds), and
  horizontal displacement at most the existing sampled walking horizon
  (`walk_horizon_cm`, currently 100 cm). These are conservative admission bounds
  from existing execution policy, not a claimed universal motor/braking envelope.
  A long interval, teleport or implausible displacement cannot earn crossing.
- The ordinary waypoint projects strictly inside the previous-to-current
  horizontal motion segment. The projected position is within the unchanged
  10 cm waypoint corridor and its interpolated feet height satisfies the existing
  floor/step bound. Both observed feet heights must also remain compatible with
  this ordinary waypoint's existing slope allowance; a wrong-floor chord must
  not interpolate its way into validity.
- Never cross-advance a final route point, gap, air point, native link or typed
  jump/double-jump/superjump endpoint; retain their existing landing semantics.
  Advance at most the one waypoint actually targeted by the prior input. Do not
  extrapolate, search forward for a closer point or consume multiple corners.
- Withhold crossing samples for dynamic actor targets (`target_name`). Their
  existing point-nearness behavior remains; this wave repairs fixed coordinate
  routes only. A moving actor can change coordinates inside a native callback,
  and additional target re-reads could themselves stale the pose/guard. This
  conservative scope does not prove improved actor-landmark navigation.
- Crossing changes the selected waypoint only. It does not itself assert
  arrival or synthesize distance/progress. Existing actual-position novelty and
  route-progress checks govern liveness. Repeated oscillation cannot repeatedly
  renew credit for one index, and a stationary motor must still stall.
- Before input toward the next point, the existing guard must admit the current
  actual pose to that next aim. A corner shortcut receives no inherited guard
  clearance. Ownership is rechecked across native callbacks as today.

The chord between consecutive poses is a bounded local motion approximation,
not proof of every point on the physical trajectory. Restricting it to prior
admitted input, short intervals, one intermediate target, unchanged floor and
fresh next-segment admission bounds the inference. Live measurements must
determine whether this removes the demonstrated first discard. If the candidate
still stalls, inspect actual per-frame input/velocity and investigate the motor
response; do not repeatedly increase the crossing bounds.

The same wave explicitly invalidates dormant native route authority when a
guarded memory route is rejected or stalls. Clear the old native path/binding,
request correlation and pose-dependent planning state before requesting again
from the current pose, preserving the command deadline, cumulative guard spend,
world memory and failure evidence. A previously partial path is a proposal based
on an older pose, not an automatic recovery executor. Late old responses must
not regain authority. Reuse the existing memory-prefix exhaustion invalidation
pattern rather than adding another route selector or changing native completeness
criteria. Current valid pending/local-route cases must retain their intended
independent ownership.

Sol owns `client_mod/scripts/move.lua`, `client_mod/tests/test_move.lua` and this
note in the isolated navigation-cause tree. Root integrates. No code edits until
a fresh design review. No live/native/model actions, restarts or full gate by
this worker.

## Search record

Repository search: `.claude/skills/search-before-building/SKILL.md`,
`docs/DISCOVERIES.md`, `docs/ARCHITECTURE.md`, `docs/design/active-guard-progress.md`,
the saved independent reset review, waypoint/progress/collision research and the
actual mover/guard/tests. `DISCOVERIES.md` records runtime MaxWalkSpeed 450 cm/s;
that is not a calibrated bound on this slope or scheduler. The current offline
fake ignores AddMovementInput's ScaleValue and has instantaneous motor response;
it needs an independent delayed motor fixture to expose the causal failure.

Actual fresh web queries:

- `site.docs.nav2.org regulated pure pursuit velocity scaled lookahead velocity overshoot waypoint`
- `site.github.com/recastnavigation/recastnavigation dtCrowd corner overshoot slowdown radius`
- `site:dev.epicgames.com APawn AddMovementInput ScaleValue analog input CharacterMovement MinAnalogWalkSpeed`

Opened primary sources:

- https://api.nav2.org/nav2-rolling/html/md_nav2_regulated_pure_pursuit_controller_README.html
  describes local path pruning, lookahead tied to speed and collision checking
  along the next control horizon. This is conceptual precedent, not a Dragonwilds
  API or a borrowed ROS implementation.
- https://raw.githubusercontent.com/recastnavigation/recastnavigation/v1.6.0/DetourCrowd/Source/DetourCrowd.cpp
  separates steering, acceleration-limited integration and path-end slowdown.
  This pinned source demonstrates why steering direction alone is not a stopping
  guarantee. Its code is not copied; upstream licence applies to copied code.
- https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/GameFramework/APawn/AddMovementInput?application_version=5.5
  documents normalized world direction and analog ScaleValue. The existing game
  AddMovementInput path is runtime-proven, but this search does not establish the
  game's analog/braking response. Tapering remains deferred.
- Existing directly referenced corridor precedent:
  https://recastnav.com/classdtPathCorridor.html
  already informs `advance`: a closer next point alone cannot prove a valid
  shortcut. This URL was inherited from nearby code; it was not newly opened
  for this investigation.

Decision: **adapt** established local path-following/corridor progress concepts
within the current real-input executor. Build only the narrow owned sample
bookkeeping and geometric crossing check; no navigation framework dependency,
new game API, hidden waypoints or task/temple-specific logic. Direct primary
URLs must accompany the code that adapts these ideas.

## Generality and principles

The rule concerns sampling of any guarded walking route, independent of place,
entity, item, language or task. Models retain intent and route selection.
Movement continues through the real character input path. Actual guard/floor
observations, owned samples and physical outcomes remain authoritative. It
preserves PRINCIPLES 1-6 and the single-owner resource rules. It neither proves
unfamiliar discovery nor changes M1-M6, learned route provenance or frozen judges.

## Acceptance test

Run the actual mover and sampled guard against an independent fake motor with
coarse/jittered control intervals, finite acceleration/braking and the disclosed
approximately 26.55 cm entry offset. Demonstrate the old behavior fails to
advance the entry while the candidate advances once, retains selected memory
authority and reaches the actual endpoint. This is an offline diagnostic, not
live motor calibration. Preserve the real sparse trace as evidence, not as a
script that supplies a successful route to the model.

Adversarial cases: same XY on a different floor; a sharp corner with a blocked
next chord; blocked connector; gap/air/jump/link; final endpoint overshoot;
long interval/teleport; paused/pending interval; changed route/index/endpoint,
goal/owner/world/life; stationary or repeated non-progress motion. All must
preserve truthful hold/failure and arrival behavior. Verify stale partial native
route and late response cannot regain control after memory rejection/stall,
while normal independent pending/local ownership still works. Assert next aim
gets its own real guard admission before input. Existing budget/deadline and
1 second / 50 cm stall checks remain unchanged.

Run focused mover cases and `tests/test_design_notes.py`, then the whole mover
suite. Root performs the reviewed release gate once the coherent wave is ready,
then repeats developer ordinary public controls with causal sampling. If it
succeeds, promptly run the complete Sonnet Director + Haiku Controller under the
unchanged criteria. Every result states driver, assistance, actual outcome,
revision, first failing boundary, model delivery and resource/cleanup evidence.
