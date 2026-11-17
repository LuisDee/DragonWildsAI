# He ran back off a ledge he had just climbed: where a route picks up after a local plan (2026-11-17)

### A route's index after a detour that ends on the route (2026-11-17)
- Need: an attack's approach on the hill behind Vannaka ended `path_blocked` in 3 Ratcatcher runs (20261116-095259's class, 20261117-073510, 20261117-120009). Two fixes at the jump itself (the landing tolerance on a ledge, the take-off when he cannot get nearer to its start) did not end it.
- What the client log and the navigation memory show (run 120009, 12:00:22Z to 12:00:51Z; the route planned again offline from `data/skills/dev/nav_memory.json` with `NM.plan`):
  - He walked a remembered route of 27 points. Its points 21 and 22 lie 0.7 m apart at the foot of a 3 m ledge; points 23 to 25 are on top.
  - A wall-ahead local plan was made toward point 25 (the first point 6 m ahead). It took him up the ledge 1.2 m to the side of points 21 and 22 and ended at point 25, 10 m from the rat.
  - The route then steered him to point 21: `advance()` counts a point as passed when he is nearer to the next point than the point itself is, and with two points 0.7 m apart that never held. He ran back off the ledge (fell 6 m in all), and three jumps from the foot missed. The attack ended `path_blocked` after 29 s.
  - Run 073510 shows the same at 07:35:50Z and 07:35:54Z: twice at point 5 of 6 of the plan, then at the foot again.
- Searched: path following after local avoidance, pruning a global plan, a waypoint index that goes backward; Unreal `PathFollowingComponent`.
- Found:
  - Nav2's Regulated Pure Pursuit prunes the global plan to the pose closest to the robot on every cycle, within a bounded search window, so progress along the plan never goes back to poses already behind it.
  - Unreal forum reports of the same class: a start segment picked by distance to the first points sends the agent back.
  - This repo already does it for one detour: past a water detour the route picks up at the index of the dry spot (`M._steer_wet`, `w.k`).
- Decision: adapt the repo's own idiom. A local plan keeps which point of which route it was made toward. When the plan's segment ends and he stands at that point (within 2.4 m, on its level), the remembered or oracle route picks up there. Nothing is skipped when the plan ended short of the point.
- Not taken: a search of the whole route for the nearest point (Nav2's way). A route that comes back past itself on the other side of a wall would be cut through.
- Sources: https://docs.nav2.org/configuration/packages/configuring-regulated-pp.html , https://api.nav2.org/nav2-jazzy/html/nav2__regulated__pure__pursuit__controller_2src_2path__handler_8cpp_source.html , https://forums.unrealengine.com/t/bug-ai-moves-to-0-0-0-despite-not-being-told-to/284910 , https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/AIModule/UPathFollowingComponent
