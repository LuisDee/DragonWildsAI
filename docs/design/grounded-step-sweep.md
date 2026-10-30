# Sampled walking checks for bounded steps and descents

## Goal and measured cause

Follow [Accepted steer](autonomy-plan.md#accepted-steer--luis-2026-10-28),
[PRINCIPLES](PRINCIPLES.md), and Astra's execution plan. Original M1-M6, frozen
judges and complete Sonnet Director + Haiku Controller acceptance are unchanged;
temple round trips remain 0/3. Root authorized the freshly reviewed deferred-
descent implementation; source cold review, gate and live validation remain.
Park [blocked-native local recovery/batching](blocked-native-local-recovery.md)
until the walking primitive's demonstrated mismatch is repaired or ruled out.

Evidence under `C:/gameserver/logs/recovery/npg-trial-a832/`:

- a844: hypothetical full-capsule supported chords reject approximate route
  node5→6. a845/a846: ordinary developer player controls cross that vicinity.
- `step-trajectory-a848.json`: 114 samples over four seconds; eleven active
  generation7 samples are grounded, jump_count0, hops0, no link/local jump or
  Windstep. Velocity.Z stays0 while centre rises from -3086.167 to -3050.930 cm
  (35.24 cm) and returns to -3087.762 cm. Ordinary goal succeeds, health100.
  This establishes native groundwalking; it does not distinguish the engine's
  exact stepping, ramp response or sliding internals.
- `same-start-step-a849.json`: using the observed start centre
  `[7703.3343028396,185498.93608937,-3086.1674565941]` toward floor
  `[7800,185500,-3178.55]`, the current sampler still rejects,39 queries, cleanup
  true. Its last failed depth2 chord descends25.49 cm over3.45 cmXY from
  `[7796.5477,185499.9620,-3061.9398]` to `[7800,185500,-3087.4309]`.
  Even finer splitting blocks. Source-position mismatch and companion jump are
  no longer sufficient explanations of the conservative walking rejection.
- `actual-poses-a850.json`: all13 recorded actual poses pass upward1 cm capsule
  checks; eleven of twelve interpose chords clear. The final descent chord is
  blocked, but horizontal-then-down at that same failed a849 segment is clear
  on BOTH legs. Up45/forward/down also clears, but is unnecessary for the narrow
  cause.46 queries, .054 CPU seconds, fresh lease cleanup and unchanged pawn.
- `deferred-segment-a851.json`: complete recorded ~1 m segment becomes
  `sampled_clear` with descending-only decomposition,26 actual native queries,
  .039 CPU seconds. The existing rising refinement is still needed once; a
  terminal33.33 cm descent uses the two clear legs. This private callback's
  sampler-local consumed count excludes its extra sweeps; only its global
  diagnostic counter includes all26. Production must charge those separately.

## Proposed observation, not movement emulation

Retain ordinary support-following floor resolution and direct sweeps first. Only a
known `sweep_blocking` on an otherwise supported short ordinary walking sample
may test an additional, explicitly named **sampled step/settle candidate**.
Unknowns, initial overlap, missing floor, wrong floor, traversal or lifecycle
changes remain failclosed. Do not loosen radius, step limits, floor distance,
collision profiles or final-arrival tolerance, and never call StepUp/move/teleport
to manufacture an outcome.

Order is explicit: floor→direct sweep→(if known blocked AND descending)
horizontal/down candidate→(if an alternative leg is known blocked) existing
subdivision. Non-descending blocks go directly to existing subdivision.

Let A be the last supported capsule centre and B the freshly floor-resolved
next sample at its commanded XY. Both support records must be known walkable,
nonpenetrating and compatible with the same measured capsule/clearance/profile.
Net floor rise or drop must stay within the measured `MaxStepHeight` (45 cm in
this case); preserve the existing short sample spacing and floor tests between
them. An endpoint across missing support or a deeper drop does not qualify.

Selected minimum candidate:

1. **Deferred descent only:** if B is lower, sweep horizontally A→(B.X,B.Y,A.Z), then
   vertically to B. This tests whether prematurely lowering the centre caused
   the diagonal chord to collide. It is not sliding or a jump.

The up/forward/down envelope is PARKED: a850 shows it can clear, but a851
establishes that the smaller descending-only observation explains this case.
Do not add rising/flat-step escape, arbitrary heights, collision penetration,
capsule shrinking or synthetic displacement. This remains an observation
candidate pending measured negatives, fresh review and implementation approval.

**Downward collision is unresolved unless explicitly classified.** A normal
floor landing may block a downward sweep, while a side contact is different.
The existing sweep callback exposes only known/blocking; that Boolean alone
cannot authorize treating a hit as landing. Initially require all legs clear.
If a down leg blocks, record exact start/end and independent typed floor support;
remain blocked/unknown. Any later acceptance of a blocking landing requires a
separately reviewed typed native hit/contact contract and evidence tying it to
the walkable support. Do not infer a safe landing from loose historical out-hit
flags, normal alone, or a broad Z tolerance. Endpoint perching/round-capsule
geometry may explain a remaining mismatch and is not solved by assertion.

The guard may eventually report clear for a validated geometric walking
envelope, not claim native StepUp equivalence or guaranteed locomotion. Epic's
CanStepUp actor/component restrictions are not currently queried by this API.
Ordinary real inputs, grounded feedback, physical progress and bounded stall
handling must still establish execution; waypoint and arrival rules stay intact.

## State, freshness and implementation boundary

Behavior-change scope: `sampled_ground_walk.lua`, `walk_guard.lua`, their focused
Lua tests and this note. The separately reviewed telemetry addition also touches
`move.lua` and `test_move.lua` (below). No planner, model interface, native API
or route-selection changes.

Sampler: after a known blocked ordinary sweep with lower already-supported B,
record the failed diagonal and enter separate `descent_horizontal` then
`descent_down` phases. Every phase issues at most one charged callback before
the shared poll/budget check. Keep A/current and pending support unchanged until
BOTH legs are known clear; then commit one sample with an explicit `via=C`
centre plus resolved B and a truthful deferred-descent tag/count. Never relabel
the original diagonal as clear. If either alternative leg blocks, retain its
exact failure observation and continue the existing bounded subdivision of the
original sample. Unknown/error/binding change fails closed. Rising or flat
blocked samples use their existing behavior. No repeated descent retry at the
same refinement task and no extra refinement beyond the current depth limit.

Guard cache audit: it currently builds the cached polyline from `sample.resolved`
only, which would recreate the known blocked diagonal. Validate optional `via`
as finite, exact resolved endpoint XY, previous committed centre Z, and a
strictly descending delta within the measured step bound; append C then B.
Malformed/mismatched metadata cannot become clear. Existing direct samples
retain their format. A vertical zero-XY leg is currently ignored by `inside()`;
represent its XY point and clamped measured Z interval for membership, applying
the existing residual tolerance and nearest-Z tie handling where it meets
adjacent horizontal legs. Same XY never means unbounded Z membership. Do not add vertical
distance to horizontal reserve/advance or enlarge existing tolerances. Keep
cached geometry attached to observed piecewise legs, never recreate the discarded
diagonal from its endpoints. Existing corridor/height residuals remain bounded
control observations, not proof of clearance at every nearby pose. Test the
actual descent's intermediate/lower/upper poses, outside the vertical interval
plus residual tolerance, wrong-floor poses and insufficient forward reserve. Refresh
when membership cannot be established rather than inheriting stale clearance.

Preserve every native-query charge and per-poll limit: pending work does not
become clear. Retain actual initial-overlap checks, exact lease cleanup,
world/life/owner/goal/capsule binding, actual-start drift and cache freshness.
Expose a bounded deferred-descent count in existing sampled/guard diagnostics
so the real replay can attribute use without new native calls or raw log floods.

Future hypothetical starts are diagnostic proposals, not actual initial poses.
Never bypass `sensor.initial`'s actual-position invariant; remote proposal
overlaps must be explicitly labelled as such. Before actual movement, the
existing fresh guard still starts at the actual pawn. Batch/fallback, model
planning and graph-edge invalidation remain separate parked work.

## Minimal private stationary discriminator

Root is sole native/live operator. Acquire a FRESH exact-owned sensor lease
through the existing service/reader protocol and always close it. Reuse a849's
typed callbacks/protocol, never its closed lease/token. Keep unchanged
world/CurrentFloor/capsule/actual-pawn binding, and
record historical query origin separately from current actual pawn. No input,
relocation, module/global replacement, model calls or world-memory writes.

- At the recorded final failed a849 chord, independently reobserve both support
  endpoints. Compare the rejected diagonal with deferred-descent
  legs; record every Boolean, floor result, centre and derived drop. Then
  test the complete observed ~1 m segment using the same bounded rule, so a local
  success cannot hide another rejected part of the trajectory.
- Bound the first probe to96 native floor/sweep calls and two CPU seconds,
  existing per-poll4 budget if asynchronous; exact cleanup always. A budget or
  field failure reports unknown and supplies no movement authority. No serial
  threshold sweep or extra subdivision campaign.
- Negative controls must remain rejected: known loaded tall side-wall corridor
  (a834 memory contact is ~101 cm above feet), a confirmed unsupported/deeper-than-
  step drop, and a confirmed overhead obstruction in the capsule corridor. Root
  must first confirm those negative geometries with native observations; invented
  target heights or unknown unloaded space are not measured cliff/head controls.
  Also retain offline analytical wall/cliff/ceiling, wrong-floor and gap cases.

Measured negative results now available (same private evidence folder):

- `deferred-wall-a852.json`: original loaded tall-side-wall corridor remains
  blocked with the descending shim,23 queries. This is a real rejection control.
- `negative-geometry-a853.json`: confirms observed overhead geometry: initial
  upward10 cm shape check clear, upward1500 cm sweep blocked. This establishes
  overhead collision sensing, not a new up-step need or a low-ceiling replay of
  the horizontal/down candidate. No upward step is proposed.
- `confirmed-drop-a854.json`: supported/nonoverlapping start atop observed raised
  geometry; after four samples, `no_floor_support` at
  `[6800,185971.4286,-2823.8716]` centre cm is UNKNOWN and attempts no deferred
  descent. A roughly3.2 m lower line-hit surface exists, but its capsule support
  is unestablished. Call this missing-nearby-support rejection, not a proven
  traversable lower landing or a quantified safe cliff. The earlier a852 drop
  fixture began overlapped and is explicitly not cliff evidence.

Implementation/regression requirements before a code freeze:

- Replay recorded a849 rejection versus complete a851 positive via the real
  sampler/guard contracts, not a callback that reports extra sweeps as consumed1.
  Preserve immutable native requests/results in a bounded fixture; unknown
  geometry never becomes clear. Actual ordinary input still needs live replay.
- Independent descending obstacle geometry where the direct chord blocks and
  BOTH orthogonal legs clear; either leg blocked; either leg unknown; flat/rising
  blocked chord; support missing/too-deep/wrong floor; malformed support or via.
- Poll budgets1/2/4 and exact total-budget exhaustion before horizontal or down:
  every query counts, pending state cannot commit B, no phase repeats indefinitely,
  and a failed alternative can only use existing bounded refinement afterward.
- Reentry, pause, owner/life/world/goal/capsule changes between both legs fail
  closed without returning retained clearance. Lease cleanup failures stay unknown.
- Real guard cache includes C and B, validates via geometry/count, handles the
  zero-XY vertical leg with clamped Z and nearest-Z ties, retains TTL/drift/target
  invalidation and horizontal reserve, and rejects wrong-floor/unbounded-Z or
  stale cached evidence. Existing direct-sample behavior stays covered.

**Current status: design CLEAR and implementation authorized by root.** a850/a851
support a narrow deferred-descent repair; they do not authorize an arbitrary
StepUp emulator or prove autonomous movement. Root owns all further native
measurements, integration and the ordinary-controls/full-agent acceptance order.

## Separate telemetry amendment — review before implementation

Root's ordinary return a858 fails after24.812 s on
`floor_resolution_out_of_bounds`, health100, final centre
`[90.39757116105,1878.8229717107,-30.723623266856]` m. A stationary final-pose
replay a860 toward the same native waypoint is clear in13 queries. Thus the
final position alone cannot reconstruct the failed scan; this is NOT evidence
for a floor-policy fix. Retain useful existing evidence rather than guess.

Propose a behavior-neutral addition in `walk_guard.lua`: when an existing
sampler poll terminates blocked/unknown, retain a bounded primitive diagnostic
with sampler reason, the already computed `failure_detail`, captured
`scan.start`/`scan.far`, and the measured shape radius/half-height/step plus
clearance kind/value. Capture before releasing scan/sensor, return independent
copies through existing guard result/terminal diagnostics, and hide it when
binding/world/life/owner becomes stale. Existing native status observers can
persist this packet; no extra native query/callback is needed. The pre-cleanup
mover trace copy below is also required to make terminal failures observable.

Do not recursively copy arbitrary data or all samples. Whitelist: bounded
phase/status strings (<=80), finite position vectors (`query/from/to`, scan
endpoints), depth0..2, finite actual/expected Z, callback count, and existing
primitive floor flag/distance/normal fields. Cap numbers/positions to finite
reasonable serialized magnitudes and omit malformed individual diagnostics;
diagnostic validity must not alter collision/floor policy or clear/fail outcome.
Shape fields come from the already validated scan configuration. No raw native
objects, metatables, arbitrary keys, route arrays or hidden state are exposed.
Retain the exact same lease cleanup, freshness and source ownership behavior.
If lease release is ambiguous, conservatively omit the retained failure packet;
the existing `cleanup_pending` fast path must not expose stale evidence before
new-aim or lifecycle checks. This adds no live callbacks or cleanup-policy change.

Focused regressions: failure packet survives ordinary cleanup and is independent
of later mutation; scan origin/far and clearance reference match that failed scan;
invalid/oversized/native-like fields are omitted without changing its outcome;
new aim/scan and stale binding clear the packet; no additional query or live
callback counts. Fresh review cleared this amendment and root authorized its
implementation, including the pre-cleanup mover trace copy below.

Root's additional cleanup audit finds the guard alone is insufficient:
`move.lua` calls `WALK.close`, clearing `st.walk_report`, before non-memory
failure finishes. Extend telemetry-only scope to `move.lua` and `test_move.lua`:
copy the bounded diagnostic into the existing64-entry primitive `route_trace`
BEFORE cleanup for every rejected guarded source. Non-memory rows use
`walking_guard_rejected:<reason>`; preserve the existing single memory rejection
row/reason (move its snapshot before cleanup, do not add a duplicate). No new
native calls or decision changes. Copies cannot alias later report/state
mutation and must not survive as current-generation evidence after replacement.
Test non-memory cleanup/terminal retention and generation/source identity.
Root's private observer must snapshot once after completion before issuing stop;
that helper fix is outside production scope owned by this worker.

Telemetry search/reuse: reviewer searched
`site.dev.epicgames.com Visual Logger snapshot transient data structured logging Unreal Engine`
and opened https://dev.epicgames.com/documentation/en-us/unreal-engine/visual-logger-in-unreal-engine .
Reuse the mover's existing transient primitive snapshot pattern; do not assume
native Visual Logger availability. Put this direct URL near adapted code.

Broader known limit remains: a856's whole ray detour still rejects a rising
hypothetical chord; a857's separate45 cm step-envelope probe clears that edge
but fails the next on floor resolution. Neither is part of deferred-descent
implementation, and no whole-detour or arbitrary-step success is claimed.

## Focused implementation verification

The minimized a849/a851 native request/result fixture is embedded only in the
sampler regression, with unknown requests failing closed. Published sampler
replay is `blocked/sweep_blocking`,31 callback queries, zero unknown queries.
The candidate is `sampled_clear`,23 queries separately charged, zero unknown,
one existing rising refinement and one deferred descent, at poll budgets1/2/4.
Private a851's26-query total included diagnostic preflight/direct queries not
issued by the production sampler; the regression checks its own actual calls.

Independent configuration-space geometry tests cover both legs, unknowns,
wall/landing barriers, non-descending rejection, reentry/lifecycle and budget
exhaustion before either leg can commit. Guard tests use the real sampler,
cache the explicit piecewise geometry, check bounded vertical membership and
horizontal reserve, reject malformed metadata and retain bounded failure packets.
Actual mover tests verify a non-memory floor failure is copied before cleanup,
retains original generation, and cannot leak into a successor's current state.
The root-owned full gate and real ordinary controls remain outstanding.

Only after the positive AND negatives discriminate: fresh design/code review,
focused actual-mover/real-guard regressions, one frozen full gate, developer
ordinary controls with ground/input/trajectory trace, then full Sonnet/Haiku.
No claim that stationary clear, offline success or a taught crossing is autonomous
completion. If safe candidates remain blocked, report it; do not disable guard.

## Generality and principles

The trigger is a supported ordinary walking collision and measured native step
capability. There are no place names, stored route coordinates or model hints in
the proposed runtime rule. Real inputs remain the only movement; observation
does not award progress/arrival or rewrite model choices. No principle or judge
exception. Recorded coordinates above are diagnostic evidence only.

## Search record

2026-10-30: read Accepted steer, PRINCIPLES, current sensor/guard/sampler code,
a848/a849 raw records and the parked recovery design. Actual fresh queries:

- `site:dev.epicgames.com UCharacterMovementComponent StepUp step down floor`
- `site:dev.epicgames.com UCharacterMovementComponent ComputeGroundMovementDelta ramp movement`
- `PhysX Character Controllers auto stepping capsule stepOffset documentation NVIDIA`

Opened primary sources:

- https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/GameFramework/UCharacterMovementComponent/StepUp?application_version=5.5
  — stepping may include a final floor check, conditional on CanStepUp. API
  semantics only; do not invoke this native movement function directly.
- https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/GameFramework/UCharacterMovementComponent/MoveAlongFloor?application_version=5.5
  — uses CurrentFloor and ComputeGroundMovementDelta; straight supported endpoint
  interpolation is not documented as equivalent to native walking.
- https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/GameFramework/UCharacterMovementComponent/CanStepUp?application_version=5.5
  — actor-specific stepping permission prevents claiming exact native equivalence.
- https://nvidia-omniverse.github.io/PhysX/physx/5.3.0/docs/CharacterControllers.html
  — stable conceptual explanation of stepping, round-capsule behavior, contact
  skin and game-specific controllers. Dragonwilds UE5 uses its own controller;
  this is not proof it uses PhysX CCT or its thresholds.
- https://raw.githubusercontent.com/NVIDIA-Omniverse/PhysX/main/physx/source/physxcharacterkinematic/src/CctCharacterController.cpp
  — explicit bounded up/side/down passes motivate the observation experiment.
  No source copied, no native API or full algorithm equivalence inferred.

Decision: adapt a bounded swept observation pattern only if actual positive and
negative probes support it; reuse existing native floor/sweep APIs and real input
execution. Do not build a replacement character controller. The attempted
ComputeGroundMovementDelta direct page was inaccessible; its semantics above
come from the opened Epic MoveAlongFloor/component documentation, not invented
implementation details.
