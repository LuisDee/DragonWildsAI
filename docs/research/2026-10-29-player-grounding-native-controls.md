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

## Walking integration and additional native shape controls

The candidate now connects native walk_sense, sampled_ground_walk and walk_guard
to memory entry/recovery and admitted local routes. It can continue a far native
partial endpoint with bounded walking prefixes under the original goal, keeping
actual3D arrival and the whole-command deadline. Simulated mover cases cover
wrong-floor entry/recovery without jumping, actual-goal replanning, multiple
prefixes reaching30m, moving-target scans, inherited strafe and observed sprint
release/preemption. Focused preflight12pytest tests passed in113.14s; final full
gate subsequently passed1258tests/1knownskip,468.70s,CHECK_ALL:GREEN at
R/logs/recovery/g-walk-7a3b8913. Frozen Lua unchanged and judge diff zero;
native adapter/developer validation remain pending at this entry.

Astra reviewed fixes for reactive-hop/strafe bypasses, lifecycle/lease cleanup,
actor identity, explicit nav=false, sprint-stop preemption and inherited jumps;
final reviewed source hashes are recorded in the design note. Code does not
claim continuous floor proof, all-path protection, general gap crossing or a
new full-agent pass. Native deployment remains the earlier tested checkpoint.

`scene-shape-controls.json`: stationary current Player34/88 capsule +12m X sweep
hit an actual face with normal[-1,0,0], while other directions hit floor-facing
normals. Current +15m vertical was clear, so it is not a ceiling-negative control.
`headroom-controls.json` used hypothetical origins without moving the pawn:
offset[-400,-400]cm had a clear +10cm initial sweep, then a blocking +15m sweep
at time0.0983525 with normal[-0.0616283,-0.0616283,-0.9961947], impact
[4777.6126,188565.6534,-3272.3851]cm. This is an observed overhead face and
full-shape negative control; the hypothetical position is not a learned route.
Eight other origins were clear overhead or initially blocked and explicitly
separated. All calls preserved the real character position.

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

## Fresh tooling survey during the full gate

Actual queries: `site:github.com Unreal Engine MCP packaged game shipping UMG
navigation 2026` and `site:arxiv.org 2025 2026 game agent spatial memory mapping
navigation Minecraft`. Opened
[runtime Unreal-MCP Build.cs](https://github.com/IvanMurzak/Unreal-MCP/blob/main/UnrealMCP/Source/UnrealMcpRuntime/UnrealMcpRuntime.Build.cs),
[EngineWire FAQ](https://github.com/ChiR24/Unreal_mcp/wiki/FAQ) and
[Mine Odyssey abstract](https://arxiv.org/abs/2610.11328).

Runtime Unreal-MCP exists and has an explicit compiled shipping allowance gate.
The other plugin's FAQ says editor-only. Neither is verified drop-in support
for this already-built Steam client; that compatibility limitation is our
inference from their build/interface requirements, not a native test. Keep the
working UE4SS bridge and revisit only on a demonstrated integration path.
MCP transport itself does not supply collision or terrain perception.

Mine Odyssey (Oct8,2026) provides fresh benchmark precedent for ordered waypoints,
entrances, multi-floor traversal and feedback recovery. Only the abstract was
read here; no claim to have reviewed its complete methods or implementation.
It is not a UE backend or evidence of this companion's capability. No dependency,
rendering or judge change was made because of these searches.

## Published developer walk: real barriers and a local-window limit

Source65af2cb was pushed/deployed after CHECK_ALL: GREEN1258passed/1skip.
Its native adapter passed current/unsupported/penetrating floor, initial clear,
wall/overhead blocked, exact cleanup and reacquisition controls on ClaudeDev.
The first control invocation failed lifecycle preflight before native queries:
fresh boot had not initialized the idle mover/arbiter tables. Ordinary status
reads established idle ownership; corrected control02 passed. Query actually
run: `site:lua.org manual logical operators and or return operand nil false`;
opened https://www.lua.org/manual/5.4/manual.html#3.4.5. This was diagnostic
setup, not a gameplay repair or permission to reset ownership.

At10:27Z a developer normal `go_to` to an independently projected destination
about300m east ended after28.06seconds with `route_ended_before_goal`:
final horizontal error268.81m, vertical error24.18m, health100. There were no
intermediate hints, position writes or game-model calls. Native navigation and
ordinary local detours moved the pawn; the final observation-window candidate
failed lazy edge verification. This is a failed developer route, not autonomous
evidence. Private records are `grounding-20261029/developer-far-walk-result.json`,
`candidate-edge-controls.json` and `candidate-window-map.json` under recovery.

Reconstructed native rays on three logged edges hit vertical normals (Z near0)
at both knee and higher clearance heights. These particular hits are real
barriers; they do not justify ignoring a floor-like hit or raising a ray until
clear. Native endpoint floor queries were walkable, which does not make the
connection between them traversable. The readonly9m-radius map sampled338floor
nodes in755queries; after12distinct blocked candidates it returned
`unreachable_in_window` even with a96iteration diagnostic allowance. Merely
increasing the replan limit does not solve this sample. The bounded local
planner's two-cell improvement threshold and the rolling-prefix closer-to-goal
contract cannot represent every necessary detour. Absence of a local improving
route is not absence of a route through the world.

Actual queries:
`site:dev.epicgames.com Unreal CharacterMovement FindFloor capsule sweep ramp ground collision walking step up`,
`site:github.com PrismarineJS mineflayer-pathfinder movements diagonal safeToBreak collision landing`,
`site:ompl.kavrakilab.org LazyPRM lazy collision checking remove invalid edges`,
`site:github.com/ompl/ompl LazyPRM.cpp remove vertices edges solution`.
Opened [Epic FindFloor](https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/Engine/UCharacterMovementComponent/FindFloor),
[Mineflayer movement source](https://github.com/PrismarineJS/mineflayer-pathfinder/blob/master/lib/movements.js)
and [OMPL LazyPRM source](https://ompl.kavrakilab.org/LazyPRM_8cpp_source.html).
The latter removes invalid edges/vertices and replans while retaining the
roadmap. Decision: adapt that retained-connectivity pattern using existing
world memory and local observations; do not add a temple route or treat
collision checking as a replacement for global route selection. Walking control
still requires the real player-sized guard. A model-visible geometric map and
detour planning across windows remain work, not implemented capability.

Independent Terra review also found a separate walking-only defect:
`env.jump=0` remains truthy in Lua, so the low-obstacle verifier can query
`max_floor-30`, mark a hop and emit a jump despite zero jump capability. This
was not observed as the cause of this failed route. Its narrow design is to
require positive available jump reach both when proposing a hop and consuming
a remembered hop flag. Existing positive-height jumping remains unchanged.
Regression: a wall whose higher ray is clear must remain blocked for walking
only, while the same geometry permits a hop with sufficient jump reach. Do not
query a supposed high-clearance ray below the knee ray. This is a generic
capability contract fix, not a temple or gap-crossing workflow.

Principles: reuse real observations and localplanner; preserve model goal,
world data, actual-arrival verification and frozen judges. No outcomes are
emulated. Offline contract tests precede publication; developer walking then
full Sonnet/Haiku acceptance remain required. No new autonomous task passed.

### Terrain information delivery: next bounded repair

Actual additional root queries:
`site:arongranberg.com astar LayerGridGraph multiple layers raycast collision height testing`,
`site:github.com frontier_exploration frontier_search.cpp searchFrom costmap`,
`site:docs.nav2.org global planner costmap obstacle local controller global path replanning`.
Opened [LayerGridGraph documentation](https://arongranberg.com/astar/documentation/stable/layergridgraph.html)
and [m-explore-ros2 frontier source](https://raw.githubusercontent.com/robo-friends/m-explore-ros2/main/explore/src/frontier_search.cpp).
They separate stacked surfaces and unknown/known-free boundaries respectively.
These are conceptual patterns: Unity's library is not our Unreal backend, and
our line-hit candidate grid is not a known-free robotics occupancy map.

Independent Terra design review recommends feedback first: before `lp_work`
discards its candidate planner, copy a bounded primitive snapshot of exact
failure, sampled window/cell size/count, observed candidate surfaces, individual
barrier-ray hits and missing coverage. Carry it through actual movement result
and bridge data to Haiku and the Director. Reuse existing result/state transport;
do not assume raw state is included in either model's compact prompt. If retained
for later turns, key to the world and include age/source, truncation and explicit
staleness; do not retain native object references or promote stale data to
movement authority. Keep task-board intent and actual-arrival predicates.

Root source audit confirmed the current transport gap: Haiku's `next_turn`
appends actual tool results, but Director `_last_results` currently copies only
`tool`, `ok` and `reason` from action records before constructing replan
`last_actions`. Detailed route feedback is dropped there. This is code evidence,
not a measurement of the full agent using a future terrain snapshot. Extending
body observations without checking this compacting boundary would leave the
planner missing the new geometry and failure detail.

LP has at most two ray-hit layers, may collapse close layers and substitutes its
own floor near the pawn. Its graph search visits unchecked edges; its wall points
lack normals and actor identity. Therefore a node must not be labelled reachable
or capsule-clear, a point hit must not become a complete wall, and a missing
sample must not become a gap. Provisional side/endpoints remain candidate surfaces
until normal real movement and its guard verify passage. Returning a checked
route/frontier needs actual connected-edge evidence; neither diagonal grid
adjacency nor both endpoint floors proves it.

This incremental feedback repair is not a complete mapping or exploration
capability. Sustained navigation still needs retained geometric connectivity
across local windows and detours that temporarily increase destination distance.
Ability edges later need measured run-up/trajectory/landing and current ability
resources, not guessed gap reach. Required regressions cover different floors,
blocked side candidates, unknown coverage, stale/rebound worlds/owners/goals,
bounded serialized size, unchanged task intent and actual delivery to both
models. Then developer real controls and unassisted full-agent validation.
No new terrain tool or automatic model-choice rewrite is selected here.

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
