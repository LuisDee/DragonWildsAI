# Navigation causal trace (2026-10-29)

## Goal and boundary
Capture the first cause of the a747 ordinary-movement failure before changing behaviour. Follow Accepted steer in autonomy-plan.md and the independent Astra review saved in the feedback-loop tree. Complete Sonnet Director + Haiku Controller remains primary acceptance; this developer reproducer counts zero autonomous passes. Preserve frozen judges, world memory and the unpublished candidate in feedback-loop.

## Approach and principles
Baseline is published 8b49235. Add observation only in move.lua: a bounded in-memory ring of primitive snapshots at memory invalidation, complete-native replacement, memory exhaustion, guarded stall and selected-source changes. Include exact branch reason before clearing state, command generation, cached route binding/world/life/owner identity, original goal and aim, cm position, waypoint, active stall time/displacement, cached guard report and progress baseline. Copy only already computed values, without native queries, timers, logging callbacks or disk writes in the motion loop. Keep a bounded dropped count and explicit game-time/CPU-time units. External existing observer timestamps samples with wall/monotonic time and copies the ring to its private evidence file. No coordinate constants, decision changes or added route planner. Tests exercise the actual stall branch and verify snapshot survives invalidation, is copied, bounded and has no mutable route/native references.

## Acceptance and stop rule
`world_real_s`, progress and scan duration/age values use the existing Unreal `GameplayStatics:GetRealTimeSeconds` clock in seconds, which is frame-latched here. They are not external monotonic time or scaled game time. The private observer separately records its wall/CPU time and Python monotonic time, reads `_G.DW_MOVE.route_trace` directly (not `M.status`), and must verify stationary and terminal persistence including drop count before interpreting a trial. Selected-source binding evidence is unknown when unavailable; native routes do not borrow a memory binding.

Focused real-mover fake tests plus required full gate precede deployment. Root sole live operator: verify stationary observer, short flat positive control, then one ordinary public reproduction with finally-stop and verified idle/health. Record first discard and next selected source. Missing cause is an invalid experiment, never grounds for a new behaviour patch. No DBOS/Postgres installation and no model calls for this diagnostic.

## Search record
- Queries: `site.dev.epicgames.com Visual Logger debugging AI navigation snapshots events`; `site.recastnav.com dtPathCorridor movePosition path corridor`; opened existing Nav2 progress-checker source from repo comments.
- https://dev.epicgames.com/documentation/en-us/unreal-engine/visual-logger-in-unreal-engine documents capturing transient actor state for timeline diagnosis. Adapt snapshot/event principle; editor Visual Logger availability in shipping game is NOT assumed.
- https://recastnav.com/classdtPathCorridor.html distinguishes selected corridor position, target and repair. Adapt explicit source/target evidence only; no callable Detour API assumed.
- https://docs.nav2.org/jazzy/configuration_and_development/configuration_guide/core_servers/controller_server/controller_server_plugins/simple_progress_checker/ describes displacement and time checks. Retain current guard algorithm unchanged; record its actual baseline, exposure and thresholds.
- Decision: adapt these diagnostic contracts using existing Lua state and private observer. Reuse existing observation transport; no framework, new native calls or SQL in frame control.
