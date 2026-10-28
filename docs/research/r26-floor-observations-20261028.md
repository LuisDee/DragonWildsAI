# R26 floor observations, 2026-10-28

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

## Remaining work

No future-position typed query, safe runway, movement-release distance, guard
threshold or production guard has been validated. The private walk sampler has
94 offline checks, including paused timer/arbiter/native-call sentinels, but no
native movement run. Its adapter must distinguish configured/cached world
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
