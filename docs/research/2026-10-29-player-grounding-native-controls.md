# Player-grounding controls, 2026-10-29

## Status and scope

Accepted steer in [autonomy-plan](../design/autonomy-plan.md) controls. Original
M1-M6 and frozen judges remain unchanged. Goal service confirmed ACTIVE following
Luis's explicit UI resume; historical paused heartbeat text is not current status.
No new autonomous task passed. No movement or game-model calls occurred during
these stationary controls. Source deployment remains 453e543/d01c574; new modules
are isolated candidates, not deployed movement improvements.

Root adopted the existing DEV ClaudeDev client9436, server7016, Steam3284 and
oracle3228/1980. Target was checked as127.0.0.1:7777 with Shockbyte forbidden.
Food/water supplied through declared DEV harness setup before diagnostics is
assistance, not autonomous survival. All per-world memory was preserved.

## Native observations

Private raw evidence: `R/logs/recovery/grounding-20261029/`, R=C:/gameserver.
Actor/capsule centre matched exactly, radius34cm, half-height88cm, Player
collision profile, no movement-ignore actors/components, step45cm, slope45.5deg.
The pawn stayed at [51.7258049458,1889.6685776557,-35.075178744435]metres.

- `floor-current.json`: typed FindFloor observation, blocking and walkable,
  explicit nested start-penetrating=false, FloorDist2.13610649cm.
- `floor-above.json`, +100cm: not walkable/no support, not penetrating.
- `floor-below.json`, -100cm: floor not walkable, nested hit blocking and
  start-penetrating=true. Copied Distance was0 for both missing support and
  penetration; it cannot distinguish them.
- `capsule-compat.json`: current->up10cm full Player capsule sweep returned
  native Boolean false; the same sweep starting100cm below returned true.
  Both copied distances were0. Compatibility requires the two Boolean controls,
  not merely the outer script's unchanged-position `ok`.
- Floor queries used exactly one typed callback/query. The retained factory
  reacquired its own logical lease. Native hook registrations rose13->14 once,
  then stayed14 across reuse; logical subscribers were removed after each probe.
  No native hook unregister or foreign-ledger adoption was attempted.

## Endpoint interpolation counterexample

`segment-compat-geometry.json` tested four one-metre endpoint sweeps. The negative-X
candidate had walkable/nonpenetrating endpoint floor results but the single
capsule sweep blocked after17.19cm. Its impact normal
[0.162466,-0.118039,0.979628] was floor-facing, not evidence of a wall.
Raising the endpoint floor query40cm preserved this result; a raised floor search
alone did not fix the straight chord. The positive-X and both Y sweeps were clear.

`segment-subdivided-compat.json` then used five20cm floor-following segments:
all five full-size capsule sweeps were clear. The final candidate module's
`sampler-compat.json` used seven14.2857cm segments with raised native floor
queries,16 total queries, current full-shape upward-sweep control and a separate
actual-start floor observation. It returned `sampled_clear`; all seven passage
sweeps were clear and the real character remained stationary.

This is a local endpoint-interpolation counterexample and positive sensor/control
test, not proof of temple-ramp traversal, gap-free support, general wall/ceiling
discrimination or autonomous navigation. Initial shape evidence is specifically
a current->up10cm capsule sweep, not an arbitrary-overlap API. Additional native
negative controls and movement integration remain required.

## Design decision

The first pure `player_grounding` prototype required a full-edge continuity
certificate. Review correctly found that finite floor samples cannot supply
that proof; a validated label would not make it true. Root changed that design,
not the frozen goal criteria. Preserve the prototype privately as an abandoned
design experiment, and do not introduce its certificate API into steering.

Adapt finite sampled, receding-horizon control instead. Use the native full
capsule and floor observations, short input horizons, real character physics,
fresh support/position/progress feedback and finite query/retry limits. Unknown
and blocked readings must be explicit. A remembered route is a proposal; its
wrong-floor entry must not become authority or reappear through recovery. Read
[current design](../design/player-grounded-route-admission.md) before integrating.

The diagnostic `sampled_ground_walk.lua` has34 fake assertions and a native
positive control on final source SHA256
`8e3bf29d0c884853d09f16d60a5e5282e30f206d6cbf0dac165ee7d374620009`
(`sampler-compat-final.json`,16 queries/seven samples). It has no movement
authority or caller integration. The
floor-probe command has28 fake assertions and the native controls above.

## Terrain and gap traversal follow-up

Luis confirmed that the terrain/perception repair must support future single
jump, double jump and Windstep gap crossing. The current local planner already
samples up to two floor layers and types adjacent-cell moves by elevation. Its
`plan` neighbour loop connects only adjacent grid cells; that alone does not
discover a distant landing across missing cells. Measured envelopes and learned
directed traversal links exist elsewhere, but neither constitutes a fresh
autonomous general-gap acceptance pass. Files named terrain.lua/traverse.lua in
the older architecture proposal are not implemented files at this checkpoint.

Actual follow-up queries:
`site:dev.epicgames.com automatic navigation link generation jump length trajectory sampling height Unreal 5.5`,
`site:github.com/PrismarineJS/mineflayer-pathfinder movements.js getMoveParkourForward landing headroom`,
`site:github.com/recastnavigation/recastnavigation recastdemomod off mesh links jump traversal`.
Opened Epic's [automatic links](https://dev.epicgames.com/documentation/unreal-engine/automatic-navigation-link-generation?lang=en-US),
the [5.5 jump-link configuration](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/NavigationSystem/NavMesh/FNavLinkGenerationJumpDownConfig?application_version=5.5)
and actual [Mineflayer movement source](https://raw.githubusercontent.com/PrismarineJS/mineflayer-pathfinder/master/lib/movements.js).

Epic's engine recipe samples takeoff/landing trajectories with configurable
horizontal reach, height, depth, endpoint tolerance and spacing; it primarily
targets NPC jumping/falling and is not an automatically verified player-ability
adapter. Mineflayer's `getMoveParkourForward` searches beyond the unsupported
neighbour for a landing, checks overhead/path cells and distinguishes sprint
availability; its Minecraft dimensions/physics are not transferable constants.
Decision: adapt those candidate-generation and execution/landing-feedback
patterns to native player observations and measured abilities after the walking
repair. Reuse the existing planner, envelope and traversal-link services rather
than creating separate place-specific jumping scripts or a second world map.

## Search record

Queries actually run include:

- `site:dev.epicgames.com CharacterMovement K2_FindFloor capsule location walkable floor navigation mesh`
- `site:dev.epicgames.com CapsuleTraceSingleByProfile UPrimitiveComponent GetCollisionProfileName`
- `site:dev.epicgames.com UPrimitiveComponent MoveIgnoreActors GetMoveIgnoreActors capsule trace profile`
- `site:dev.epicgames.com bAllowClientSideNavigation NavigationSystem client`
- `site:dev.epicgames.com NavMesh Agent Max Step Height player navigation mesh slope`
- `site:dev.epicgames.com Unreal FFindFloorResult FloorDist LineDist bLineTrace capsule floor distance`
- `site:docs.nav2.org regulated pure pursuit collision detection forward simulation time collision`
- `site:github.com/ros-navigation/navigation2 collision_checker.cpp regulated_pure_pursuit resolution`

Primary sources opened:

- https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/GameFramework/UCharacterMovementComponent/K2_FindFloor?application_version=5.5
- https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/Engine/FFindFloorResult
- https://dev.epicgames.com/documentation/en-us/unreal-engine/BlueprintAPI/Collision/CapsuleTraceByProfile
- https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/Components/UPrimitiveComponent/MoveIgnoreActors?application_version=5.5
- https://dev.epicgames.com/documentation/unreal-engine/navigation-mesh-settings-in-the-unreal-engine-project-settings?lang=en-US
- https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/NavigationSystem/UNavigationSystemV1
- https://github.com/ros-navigation/navigation2/blob/main/nav2_regulated_pure_pursuit_controller/README.md
- https://github.com/ros-navigation/navigation2/blob/main/nav2_regulated_pure_pursuit_controller/src/collision_checker.cpp
- https://github.com/PrismarineJS/mineflayer-pathfinder

Reuse native queries and the existing local planner; adapt Nav2's finite
forward-check/feedback pattern. Nav2 is conceptual/source precedent, not a UE
backend. Client-side navigation is an existing documented investigation lead;
enabling it is not evidence of different player-compatible ramp coverage, so it
must not defer the demonstrated memory-entry repair. No new navigation library,
rendered client or collision-setting change is justified by these controls.
