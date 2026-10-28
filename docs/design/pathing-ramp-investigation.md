# Generic pathing repair: ramp evidence and next discrimination

Luis requested a pathing repair during the separate friend-server trial on
2026-10-28 and explicitly resumed the updated Goal on 2026-10-29 after returning
to DEV. The first deliverable is now the generic three-round-trip acceptance in
[NEXT-GOAL-PROMPT.md](../NEXT-GOAL-PROMPT.md). Friend-trial observations below
remain historical evidence; no further friend-server operation is authorized.
The [accepted steer](autonomy-plan.md#accepted-steer--luis-2026-10-28) applies:
generic controls, truthful observations and complete Sonnet/Haiku validation.
Frozen judges remain unchanged. The latest DEV controls and source reviews are
recorded in [the survey](../research/2026-10-29-traversal-perception-direction.md),
[Astra's navigation review](../research/2026-10-29-astra-navigation-review.md) and
[Sol's interaction review](../research/2026-10-29-sol-headless-interaction-review.md).

## Evidence and limits

- A developer used actual movement inputs to walk from
  `[69.35,1867.33,-32.70]` east to `[76.49,1867.33,-31.13]`, with health 100.
  Luis visually confirmed the character reached the top and was then caught in
  the doorway. This proves a walkable climb, not automatic pathing or exit success.
- Earlier northward movement rose and then descended behind the approach. Height
  gain alone was incorrectly described as ramp progress; that claim was corrected.
- A live follow snapshot steered almost vertically beneath the character:
  position approximately `[74.43,1864.92,-31.26]`, waypoint
  `[74.42,1864.93,-35.50]`. The local planner reported `no_progress_possible`.
  With the measured capsule half-height near 0.88 m, the waypoint was about
  3.36 m below the feet. Its origin and relationship to the ramp failure are unknown.
- Long requests returned partial native routes, including an endpoint near
  `[83.20,1873.92,-32.10]`. A partial path is not proof of an inaccessible goal.
- The local planner already samples two floor layers and distinguishes slopes
  from steps. A single-layer explanation or lack of all slope support is false.
- The agent does not get a rendered ramp view. Searching for the word `ramp`
  failed because nearby collision geometry is not exposed as a semantic ramp.
- An operator's new asynchronous planner replay stalled the friend client.
  The client was restored. Exact hang cause is unproven; do not rerun that probe
  on the friend client. Read-only native calls can still disrupt gameplay.

Private evidence is in runtime `logs/recovery/friend-trial-20261028/`:
`slope-status.json`, `ramp-help2.jsonl`, `ramp-surface-detail.json`,
`ramp-geometry.json` and `live-observations.jsonl`. These contain live data and
remain outside Git. Terra's bounded read-only review found no demonstrated
ramp-specific source defect warranting a production patch yet.

## Discriminating experiment before implementation

On DEV, bind the actual controller, pawn, life and world. Record a full native
query, selected nav-data identity, projected start/goal, current centre/feet,
waypoint index, local floor layers and rejected edges while attempting the proven
walkable approach. Compare existing default selection with explicit available
nav-data contexts, using actual agent dimensions. The server currently exposes
Default (radius 30 cm, height 150 cm) and Gigantic (200 cm, 420 cm); their existence
does not establish which one a nil context selects.

Distinguish incorrect agent/data selection, stale route binding, wrong-floor
projection and local collision verification. Do not skip an incompatible
waypoint, relax arrival elevation, disable route authority or encode the church
coordinates as the repair. A bounded requery may be appropriate for a proven
stale binding; it is not a substitute for resolving a projection/data defect.

Any diagnostic must be finite, budget native calls per frame, serialize with the
one live operator and stop on identity change. No new experimental callbacks on
the active friend client. Offline checks precede developer real-client controls,
then the full Sonnet Director + Haiku Controller attempt. Record manual assistance.

The proposed `mod/experiments/nav_route_probe.lua` diagnostic is synchronous and
read-only: enumerate available contexts separately, then query one explicitly
selected context per invocation (at most two projections and one path query).
Identity mismatch is a refusal, not selection of a different actor. The nil
baseline does not claim an inferred default nav-data identity. It must not spawn
anchors, rebuild tiles, stream cells or change production route selection.
It reports UObject validity separately and leaves native navigation-path validity
unknown: the inherited UE4SS `IsValid()` method must not be represented as the
game's similarly named path-validity function. Explicit NavData contexts and
indexed path points still require a controlled native measurement.

## Search record

Actual queries included `site:dev.epicgames.com UNavigationSystemV1 GetNavDataForProps
FindPathToLocationSynchronously PathfindingContext`, `site:dev.epicgames.com Unreal
navigation mesh ramps walkable slope collision simple complex character movement`,
`site:docs.ue4ss.com Lua ExecuteInGameThread UObject call`, and
`site:github.com PrismarineJS mineflayer-pathfinder path_reset stuck chunk_loaded`.

Primary pages opened by main or the bounded reviewer:

- https://dev.epicgames.com/documentation/en-us/unreal-engine/BlueprintAPI/AI/Navigation/FindPathtoLocationSynchronously
  documents Pawn, Controller and NavigationData query contexts.
- https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/NavigationSystem/UNavigationSystemV1/GetNavDataForProps
  documents choosing data for agent movement properties; reflection availability
  in this game remains to be checked before relying on that C++ API.
- https://dev.epicgames.com/documentation/en-us/unreal-engine/simple-versus-complex-collision-in-unreal-engine
  explains per-mesh collision choices; complex tracing is not universally correct.
- https://docs.ue4ss.com/lua-api/global-functions/executeingamethread.html
  documents game-thread execution, not freedom from callback stalls.
- https://docs.ue4ss.com/lua-api/classes/remoteobject.html
  documents the inherited object-validity method, distinct from an unverified
  call to the similarly named navigation UFunction.
- https://docs.ue4ss.com/lua-api/classes/tarray.html
  documents indexed array reads; the experiment bounds these rather than assuming
  `ForEach` can stop early.
- https://github.com/PrismarineJS/mineflayer-pathfinder
  provides conceptual precedent for stuck/environment replanning, not a verified
  Dragonwilds API or a replacement for the existing planner.

Decision: reuse the native oracle, local planner and existing trace profiles;
adapt only the demonstrated faulty binding or geometry interpretation after the
DEV discrimination. Do not build a new navigation framework on this evidence.
