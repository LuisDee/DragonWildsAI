# Unfamiliar routes: remaining selection contract

Read Accepted steer in ../design/autonomy-plan.md. Taught-route execution does
not prove discovery. Original M1-M6 and frozen judges remain unchanged.

Astra's read-only source review on 7142526 found that an explicitly partial NPC
path remains st.path, suppressing independent observed local planning toward the
requested destination. Valid native replies can also cancel that observation.
Fresh NPC-only moves are not automatically walk_guarded: reactive wall/water
planning normally uses far_goal(), which prioritizes the native waypoint. Thus
that recovery repairs the NPC proposal rather than independently trying the
original destination. A retained inactive NPC path can also win far_goal priority
while another source steers. These are source facts, not a new live proof.

Existing observed planning already has a9m layered window, lazy edge checks and
guarded walking prefixes. Its frontier rules require heuristic improvement;
the mover also requires1.5m net horizontal prefix progress. Some detours moving
away first can therefore remain unresolved. Failure packets contain candidate
surfaces/barriers with connectivity and clearance unknown. Provider-delivery
tests exist for both models; current live delivery is not established.

After the active geometry repair, isolate one selection question: on identical
walkable ramp terrain with no recorded routes, compare native no_path against a
partial NPC route toward a blocked alternative. Record observation invocation,
planning goal, candidate endpoint and guard admission. If only no_path observes
the terrain, the selection gate is isolated. If both fail, inspect actual floor
or edge rejection. Do not substitute an injected plan for planner discovery.

The narrow candidate is one bounded observed-local attempt toward the original
goal when the native response is explicitly partial and no remembered proposal
is selected. Keep the native partial route as fallback, complete-native
preference, guards, budgets, deadline and retry limits. An equivalent late partial
must not cancel that repair. Do not simultaneously loosen frontier criteria or
provide temple waypoints. This is a proposal, not implemented behavior.

Astra searched and opened the primary Nav2 invalid-path replanning documentation:
https://docs.nav2.org/rolling/getting_started/nav2_behavior_trees/trees/nav_to_pose_with_consistent_replanning_and_if_path_becomes_invalid/
It supports separating execution and bounded replanning toward an unchanged goal;
it is conceptual precedent, not a Dragonwilds API. Subsequent live validation
must use a documented held-out case without recorded path/demonstration/hints,
preserving all existing memories.
