# R26 stationary route controls, 2026-10-28

Sol drove these diagnostics through the existing live queue on deployed source
`83f0ce315a9b44130491da349a6eb1426374d4a4`, before publishing the route-authority
candidate. DEV client 12340, ClaudeDev, pawn
`BP_PlayerCharacter_C_2147473119`, and local server 7016 were retained. There
were no model calls, movement commands, health writes or memory resets.

The starting position was `[63.153,1875.565,-35.446]` metres. A query to the same
XY and 50 metres above returned `no_path`, zero points, and the legacy fields
`partial=false, goal_projected=false` (11 ms reported by the experiment). A
query two metres east at the original Z returned two points, a 2.02 m route,
and `partial=false, goal_projected=true` (2 ms reported). These timings exclude
IPC and are not movement or throughput measurements. The legacy native getter
handling can collapse errors into false; these recorded fields do not establish
that every negative native read succeeded.

The character's before/after position was identical at probe precision, health
was 100, and the terminal client ping had no action or waiters. The queue case
`route_oracle_stationary_baseline_20261028` was observed, not scored as an
autonomous pass. Its active duration was 2.1 seconds. Raw evidence is private at
`R/logs/recovery/route-oracle-baseline-20261028.json` and in the 2026-10-28 live
queue log. Here `R` means `C:/gameserver`.

Before the controls, a separate declared harness setup supplied eight Bread and
eight Clean Water. The existing real-input reflex consumed one Bread and two
Water during its first observation; health subsequently recovered to 100. The
setup took 17.6 seconds and is assistance, not autonomous resource acquisition.
R26 declared nutrition totals are now 40 Bread and 59 Clean Water. Existing
world, death and learned navigation data were preserved.

These controls establish a useful negative/positive contrast for the next
deployment. They do not prove that movement holds during failed planning, that
the new protocol works live, or that the companion can craft an axe or fell a
tree. Repeat the relevant contrast after the candidate is reviewed, gated and
published, then validate actual route admission and a benign nearby arrival.
Further live travel is waiting for those candidate checks, rather than repeating
the failed grave route or already observed easy cases.

## Search record

This diagnostic reuses the reviewed route-authority research. Actual queries:
`site:recastnav.com Detour findPath partial result DT_PARTIAL_RESULT path corridor`;
`site:dev.epicgames.com navigation path partial path project point navigation Unreal Engine`;
`site:github.com/recastnavigation/recastnavigation DT_PARTIAL_RESULT findPath last best`.
Opened primary sources include [Detour findPath](https://github.com/recastnavigation/recastnavigation/blob/main/Detour/Source/DetourNavMeshQuery.cpp),
[DetourCrowd](https://github.com/recastnavigation/recastnavigation/blob/main/DetourCrowd/Source/DetourCrowd.cpp),
[Epic partial paths](https://dev.epicgames.com/documentation/en-us/unreal-engine/BlueprintAPI/AI/Navigation/HasPartialPath)
and [Epic projection](https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/NavigationSystem/ANavigationData/ProjectPoint?application_version=5.5).
Reuse the existing DEV navigation experiment and queue. The established APIs
explain projection and incomplete paths conceptually; this game's actual
responses above supply the runtime evidence. No new native API was introduced.
