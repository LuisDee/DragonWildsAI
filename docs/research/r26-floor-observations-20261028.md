# R26 floor observations, 2026-10-28

## Contrasting query-origin controls and scoped reader (2026-10-28, 04:03 UTC)

DEV client10824, deployedc145862 (companion9b93dd8d5b1eed87), stationary
ClaudeDev at centre `[5841,181986.90782694,-3075.4965129417]` cm. The
character never moved: only the location passed to K2_FindFloor changed. Typed
posthook values, not packed output-table flags, produced:

| Query Z offset cm | Floor blocking | Walkable | Hit blocking | Hit starts penetrating | FloorDist cm | Hit Distance cm |
|---:|---|---|---|---|---:|---:|
| 0 | true | true | true | false | 2.1523433 | 7.5523453 |
| +100 | false | false | false | false | 47.4001007 | 0 |
| -20 | true | true | true | false | -17.8476582 | 30.7523403 |
| -100 | false | false | true | true | -34 | 0 |

All line-trace flags were false. The0/+100 anchors were repeated as part of the
second three-query batch. A zero hit distance occurs both with no hit and with
initial penetration. A negative floor distance can coexist with walkable floor
and no reported initial penetration. Neither distance zero nor penetration=false
certifies full capsule clearance. The reduced-capsule/retry explanation for the
-20 result is a hypothesis; it was not directly traced in the installed engine.
The -100 query establishes a contrasting typed initial-penetration result at
this plane; it is not an actual actor overlap, ledge or a safe-drop experiment.

Queries used the preexisting healthy exclusive native floor hook. Both private
batches completed with exact subscriber cleanup, same position/health100, both
velocities zero, idle body/arbiter and unchanged per-world nav-memory SHA.
`r26_controls_cd5996936ea4` used0/+100/-20;
`r26_controls_2d0a991d01a0` used0/+100/-100. Independent watchdog arm-to-reply
intervals were0.515/0.532s including event writes, queue and IPC; same-frame
game-clock deltas were0. These do not measure per-query processor cost.

A separate diagnostic loaded the GREEN eac2503 source floor_read.lua from W,
SHA256 `2bcb2d38184938f690ae13dc80319240be476a01686b2af7e42a1501469ec068`,
while the ordinary deployed client files remainedc145862. Two sequential fresh
non-yielding acquire-one-current-query-close scopes both returned observed,
consumed1, cleanup=true and ledger=closed; native registration count was
unchanged. `r26_scoped_6a7edeb937ce` arm-to-reply was0.516s including IPC.
This verifies these two scoped reads, not rejoin continuity or an arbitrary
late callback. The continuity declaration is limited to the reviewed synchronous
game-thread ordering and observed bindings. No lease crossed a tick/rejoin;
closed version2 process marker remains and belongs to that private factory.
Do not reset it, recreate a foreign factory or blindly rerun the old source
smoke. Normal future behavior integration will need its reviewed fresh-process
window or exact-owner retained factory; no migration is approved.

Raw results/operators/designs are archived under
`R/logs/recovery/floor-controls-1348bed1/`. All three operators are TERMINAL
and released the slot only after confirmed cleanup. No model calls, movement,
physics/health writes, world-memory migration or resets occurred. Declared
setup4Bread/8CleanWater was consumed through the normal reflex; total R26
harness nutrition is22Bread/37CleanWater. No autonomous survival credit.

Search: actual queries `site:dev.epicgames.com UCharacterMovementComponent FindFloor ComputeFloorDist sweep distance penetration capsule` and
`site:github.com UnrealEngine CharacterMovementComponent.cpp ComputeFloorDist ShrinkHeight bStartPenetrating`. Opened primary
[Epic ComputeFloorDist5.5](https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/Engine/GameFramework/UCharacterMovementComponent/ComputeFloorDist?application_version=5.5),
[Epic FindFloorResult4.27](https://dev.epicgames.com/documentation/en-us/unreal-engine/python-api/class/FindFloorResult?application_version=4.27)
and [Epic FindFloor](https://dev.epicgames.com/documentation/en-us/unreal-engine/BlueprintAPI/Pawn/Components/CharacterMovement/FindFloor).
The documented distinction between floor blocking and nested hit evidence is
consistent with the -100 observation; cross-version docs are conceptual
precedent, not proof of the exact installed implementation. Reuse the existing
masked typed reader/hub and scoped ownership; adapt geometry interpretation;
build no collision/physics workaround or no-fall claim from these controls.


These are developer diagnostics on ClaudeDev, local DEV, client build 26162923,
Unreal 5.6.1 and logged UE4SS SHA `83330635`. They do not establish the cause of
the earlier KillZ entry, safe traversal, or an autonomous milestone pass.

## Observations

- The stationary character's capsule radius is 34 cm and half-height 88 cm.
  Its reflected `CurrentFloor` has `FloorDist=2.149995803833` cm,
  `bBlockingHit=true`, `bWalkableFloor=true`, `bLineTrace=false`, and nested
  `HitResult.bStartPenetrating=false`.
- A single current-position `K2_FindFloor` query returned matching numerical
  geometry in its Lua output table, but copied `bLineTrace` and
  `bStartPenetrating` were both true. Treat **every copied packed Boolean** as
  unknown, including apparent blocking/walkable positives. This is not evidence
  of penetration. Distance zero alone also does not certify penetration or
  support; older notes suggesting that shortcut are superseded.
- The pinned UE4SS source explains the discrepancy: `push_boolproperty` uses
  the field mask for `Operation::Get`, but its `GetNonTrivialLocal` branch reads
  the byte as a Boolean without that mask. Struct-to-table output copying takes
  the latter path. Reflected `UScriptStruct` field access uses the former.
- After separate design/code review and 22 fake cases using the real hook hub,
  queue run `20261028-022154` made one current-position compatibility query with
  a temporary typed posthook subscriber. Exactly one callback copied primitive
  fields synchronously; typed flags and numerical geometry matched reflected
  `CurrentFloor`. Pawn/component identities, position and zero velocity were
  unchanged, HP stayed 0.5, and body action/waiters and arbiter owner/stack were
  empty. The queue verdict was **observed**, not a traversal pass.
- The diagnostic subscriber was removed. The native hook for
  `/Script/Engine.CharacterMovementComponent:K2_FindFloor` remains registered
  and dormant until process restart, with no subscribers or pending query.
  Never unregister it or repeat the one-attempt probe blindly. Native wrapper
  materialization before Lua is outside `pcall` protection.
- At the stationary slope, the roughly 1.99424 cm difference between a vertical
  line-floor distance and capsule half-height plus native floor distance agrees
  with the spherical-capsule slope geometry. One consistent sample cannot set a
  safety threshold or turn sparse rays into a capsule-footprint measurement.

## Stationary adapter verification

A separately reviewed snapshot-only adapter (13 fake cases plus six invalid
configurations) was observed once in queue `20261028-022558`, 2.2 s active plus
14 s readiness. It read matching pawn/component addresses, capsule dimensions,
current-floor fields and zero actor/component velocity. Namespace `dev` came
from `joined`; independent external DEV/forbidden-target checks still establish
the target. HP was 0.5, sustenance/hydration zero and endurance about 2.806,
so this is not readiness for movement. Position and HP were unchanged, body and
arbiter idle. The probe started no sampler, timers, lease or input. It labels
`GameplayStatics.GetRealTimeSeconds` as world time and refuses sampler wiring
while the independent monotonic clock contract is unresolved. This is a single
within-call identity check, not cross-sample continuity or moving-velocity proof.
Raw evidence: `logs/recovery/r26-release-adapter-stationary-result-20261028.json`.

## Nearby queries and first input trial

Three bounded stationary batches (`20261028-023151`, `023459`, `023534`) made
nine typed floor queries: origin, Y+50/+100 cm, X-34/+34 cm, Y-50/-100 cm,
and X-34/+34 at Y+50 cm. Each had exactly one scoped callback, blocking
walkable floor, nonpenetrating hit and distinct geometry. Position, identities
and HP100 stayed unchanged. Upslope FloorDist could be negative; that alone
is not penetration. The native hook was reused and subscribers removed.
External command times were 0.265/0.500/0.266 seconds without expiry. Sparse
samples describe local slope geometry; they do not certify an obstacle-free
runway or full footprint support.

The supervised trial `r26_one_c2e48fb3b0b9`, queue `20261028-024427`, recorded
exactly one AddMovementInput call and ended `stable_observed`. Independent
native positions moved Y+1.392664 cm and Z-0.116089 cm. HP stayed100; final
body action/waiters and arbiter owner/stack were empty. Own cleanup was
acknowledged and the slot released. The pre-input and release samples were
66.7115 ms apart in game-world time, not exact engine application timing.
Four post-release samples had unchanged position and zero actor/CMC velocity.
Requested50 ms intervals produced66.667 ms gaps and one120.958 ms gap; use
measured cadence. This proves diagnostic operation, not full-speed braking,
fall prevention or an autonomous achievement.

The watchdog was alive before admission and terminal after acknowledgment.
Its fresh exact-ID file can signal cancellation independently of a blocked
main request, but cannot preempt native code or eliminate a post-read race.
An actual blocked-parent test verified signal writing and stale-file refusal.
The input cap bounds injections, not physical drift. Driver20 and sampler108
fake checks preceded the pilot. Later data-only sampler instrumentation passed
113 checks and cold review, adding copied input/release velocities and observed
sample-to-sample displacement/time. Those new fields have NOT been captured live.

The first movement preflight refused food15.28/water13.95 before issuing input.
Declared DEV supplies were replenished and consumed before the pilot. Total
R26 setup to date is **five Bread and seven Clean Water**, including earlier
stationary setup; exclude these from autonomous survival results. No health
write, save restore, restart or model API call was used. Endurance was zero in
the walking-only pilot; there is no sprint or recovered-rest claim.

Raw evidence stays in `R/logs/recovery/r26-near-floor-{scan,sides,width}-result-20261028.json`,
`r26-one-input-release-result-20261028.json`,
`r26-one-input-release-summary-20261028.json` and
`r26-release-operator-result-20261028.json`. A SHA256 manifest of58 private
tools, designs, fakes and raw files is in local archive
`C:/gameserver/logs/recovery/r26-private-checkpoint-b662bb5f/`.

## Walking-speed and source-reader checkpoint

Further staged diagnostics used the same DEV character and native movement:

| Queue run | Input cap / requested interval | Release speed (cm/s) | Observed horizontal travel after release | Result |
|---|---|---:|---:|---|
| 025603 | 2 / 50ms | 0 | 0 | Stable; isolated tiny steps, not representative walking |
| 025913 | 2 / 1ms | 130.138 | 0.361cm | Stable; native speed agreed with sampled displacement |
| 030438 | 8 / 1ms | 372.343 | 5.259cm | Partial: later observation read exceeded timing proxy |
| 030842 | 12 / 1ms | 450.000 | 7.399cm | Stable; released at the inner boundary |

The final trial reached the recorded MaxWalkSpeed450cm/s. Actor and CMC
velocities agreed; post-release samples were182.81,39.15, then0cm/s, with
stable position afterward. Samples were about33.33ms apart despite requested
1ms input/10ms observation timers. HP100 was retained, exact-ID cleanup was
acknowledged, and arbiter/body/slot ended idle/free. This is ONE slope trial
with zero endurance, not sprint or a general braking envelope, guard margin,
exact input-consumption time, benign-drop calibration or fall-prevention pass.
The reported displacement is horizontal along the input direction; terrain
also caused a small vertical change. Input and release are sampled states.

The 8-input result remains partial. A13ms snapshot exceeded the provisional
10ms os.clock admission proxy after input had already been canceled. The
reviewed correction keeps startup/injection strict, while separately recording
unknown/overbudget costs during verified observation after the input handle is
cleared and generation advances. Other guards remain unchanged. The subsequent
12-input run recorded23 known1-3ms deltas without overrun. os.clock is accurately
labeled as its own clock: Lua's C-clock binding and MSVC's documented elapsed
semantics are precedent, not independently verified hard wall-time preemption.

Production source now has standalone `floor_read.lua` plus33 actual-hub fake
checks and a design note. Startup/bridge/steering never load or enable it.
Full gate52513 completed **1158 passed,1 skipped, CHECK_ALL: GREEN**,382.51s;
log `W/logs/recovery/cf-92b34b84/check-all.log`. Then one explicitly enabled
current-position source smoke (`20261028-031825`) returned one correlated typed
observation, all required fields known, position/health/native identities
unchanged, and owned subscriber cleanup succeeded. Native registrations stayed
15 before/after; no new hook was registered. The process marker is now closed;
never reset it or blindly rerun that smoke. General movement integration remains
unimplemented and needs its own lifecycle and geometry validation.

Two review defects were corrected before the source gate: ambiguous hub pending
state must be preserved, and cleanup must check exact factory ownership rather
than removing a replaced subscriber. Root's smoke separately rejects absent or
replaced existing native records, including changes during lifecycle checks.

Additional declared nutrition buffers this stage were1Bread/2CleanWater and
4Bread/4CleanWater. Total R26 fixtures to date: **10 Bread,13 Clean Water**;
exclude them from autonomous survival credit. No health/physics write, restart,
save restore, judged success or model API call occurred. Private exact tools,
raw evidence and SHA256 manifest are archived at
`C:/gameserver/logs/recovery/r26-walking-checkpoint-04724d0c/` (95 files).
Native pulse results and operator traces use the corresponding r26-two-input,
r26-fast-two-input, r26-walk-eight-input, r26-walk-twelve-input prefixes under
`R/logs/recovery/`; source smoke is r26-source-reader-stationary-result-20261028.json.
The next integration design is private `r26-support-integration-design-20261028.md`.
It identifies jump/spell side effects before the common input point and separate
combat/gather inputs; a common move.lua guard must not claim wider coverage.

## Remaining work

Nearby queries and a walking-speed slope trial are now observed. Repeated
walking/sprint and varied-terrain braking, wider calibrated envelopes and the
production guard remain unvalidated. Latest velocity recording has live evidence
for these specific pulses; do not generalize it beyond measured conditions. Its adapter must distinguish configured/cached world
namespace from verified server identity, and game-world time from an independent
monotonic wall clock. A stationary adapter probe must not start the sampler,
timers, an arbiter lease or input. Follow the existing
[forward-floor design](../design/forward-floor-integrity.md) before rollout.

Resource provenance: a prior measurement setup granted two Bread and three
Clean Water on DEV; actual reflex consumption raised vitals temporarily. They
had depleted again before the typed stationary observation. No health/physics
write, restart, save restoration or model API call was used in these probes.
Fresh resources and a separately reviewed corridor are required for movement.

Raw evidence stays private in `logs/recovery/`: `r26-stationary-profile-result-20261028.json`,
`r26-findfloor-current-result-20261028.json`, `r26-typed-floor-result-20261028.json`,
`r26-typed-floor-preflight-20261028.json` and `r26-capsule-slope-consistency-20261028.json`.
The native header dump is build 26161880, older than this client; it is precedent,
not a current-binary ABI certificate.

## Search record

Actual searches included `site:dev.epicgames.com K2_FindFloor UCharacterMovementComponent OutFloorResult`,
`"FindOutParamValueAddress" "OutParms" LuaMod`,
`site:docs.ue4ss.com RegisterHook "LocalUnrealParam" get`, and
`site:docs.ue4ss.com Lua out parameters struct UFunction call out parameter table`.
The private ABI, Boolean-marshalling and typed-observer design notes retain the
full queries and source audit. Opened primary sources:

- [Pinned LuaUObject conversion source](https://github.com/UE4SS-RE/RE-UE4SS/blob/83330635/UE4SS/src/LuaType/LuaUObject.cpp)
- [Pinned reflected struct accessor](https://github.com/UE4SS-RE/RE-UE4SS/blob/83330635/UE4SS/src/LuaType/LuaUScriptStruct.cpp)
- [Pinned native hook dispatch](https://github.com/UE4SS-RE/RE-UE4SS/blob/83330635/UE4SS/src/Mod/LuaMod.cpp)
- [UE4SS UScriptStruct API](https://docs.ue4ss.com/lua-api/classes/uscriptstruct.html)
- [UE4SS RegisterHook API](https://docs.ue4ss.com/lua-api/global-functions/registerhook.html)
- [Epic CharacterMovementComponent](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/UCharacterMovementComponent)

Decision: reuse the existing hook hub and mask-aware reflected accessor for this
bounded diagnostic; do not patch binaries/memory or assume an upstream upgrade
fixes the issue. Epic documents the conceptual floor API; only the single live
observation establishes this client's current-position compatibility. The pinned
UEPseudo helper source was unavailable, leaving pre-Lua failure handling unknown.
