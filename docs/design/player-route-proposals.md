# Let observed player routes compete with NPC navigation

## Goal and evidence

Follow Accepted steer in autonomy-plan.md and unchanged frozen M1-M6. No temple
code, route coordinates or hidden model hints are added to production.

On7ccecf6, default navigation from the demonstrated ramp approach chose a partial
NPC route behind the ramp, failing sweep_blocking about2.9m below its target.
The same character followed the human's actual approach with ordinary straight
movement in3.135s, climbing4.2m, HP100. It continued through the upper doorway in
3.88s. These are developer-directed diagnostics; observed routes r126/r127 were
automatically stored in DEV memory as src=self. Their developer provenance must
remain explicit in evidence; they are not autonomous passes or fresh-map proof.

Astra confirmed move.lua makes native authority mandatory beyond10m or a large
height difference, then excludes initial remembered paths. Ordinary memory also
requires over30m. Thus it cannot initially reuse the player-compatible route
that gameplay just recorded.

## Approach

Allow a same-world successful recorded route to propose movement when current
native routing is partial/unavailable; a complete native route keeps preference.
Reuse the existing route graph/Dijkstra in an explicit forward-proposal mode,
preserving other callers' semantics. Historical records without traversal tags
are proposals, not proof that every recorded frame was grounded walking.

Use only observed forward order for this proposal: no inferred reverse edges,
static seeds, stale trap exits or arbitrary jumps. Interior recorded points may
provide entry/exit if current and goal are genuinely close under existing finite
connector bounds. Joins and endpoints are proposals, never assumed clear. Fresh
actual-position guard checks apply to connectors and execution. Preserve world,
life, pawn/owner/goal/generation bindings, cumulative budgets, deadline and real
3D arrival. A rejection tries the normal native alternative once and cannot
reselect the same failed proposal in a loop. Ending a record is never arrival
short of the actual goal.

Fresh Astra follow-up approved a bounded prefix extension before freezing:
complete recorded connection first, otherwise one reachable recorded frontier
that improves distance to the original goal by existing progress_cm, with path
cost as tie break. This must combine connected forward records, otherwise it
cannot reuse a spawn->base->ramp->doorway chain for a novel distant target. Use
existing finite graph/join/height bounds; guard every join during execution.
Do not append the distant goal to a prefix. Prefix completion closes its guard,
invalidates old native path/request/binding/failure/local state and replans from
actual pose. Preserve original goal, t0/deadline and cumulative spending; retain
forward_checked so only one proposal occurs per command. It is never arrival.
Stable named-object snapshots are eligible; movement/identity changes abandon
the proposal immediately and use ordinary current-target navigation.

Do not alter sweep geometry from the failed behind-ramp chord: it was a different
line from the physical success. The measured80cm natural descent is separate;
it does not authorize blind cliff traversal or interpreting unknown as clear.

## Search record

Actual queries2026-10-29: `site:docs.nav2.org route server follow route graph
validated path replan` and `site:github.com/PrismarineJS/mineflayer-pathfinder
setPath path_reset movements_updated`. Opened primary source/context:
- https://github.com/PrismarineJS/mineflayer-pathfinder/blob/master/index.js
- https://github.com/PrismarineJS/mineflayer-pathfinder/blob/master/lib/astar.js
- https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/UCharacterMovementComponent/MoveAlongFloor?lang=en-US

Implementation worker additionally searched `site:docs.nav2.org route server
path validation navigation route graph` and
`site:github.com/PrismarineJS/mineflayer-pathfinder path reset path update`,
opening the same primary Mineflayer index source. The attempted Nav2 config
URL404 was not used as evidence.

Reuse the repository's successful-trip memory and guarded connectors; adapt the
existing path proposal/invalidation pattern. External backends are conceptual
precedent, not drop-in Dragonwilds APIs. No new dependency or native ABI.

## Review and principles

Fresh Astra read-only reassessment supports this bounded route-selection repair.
Root owns integration and live operation. PRINCIPLES1/2/3/4/5/6/8/9 remain intact:
models choose goals, real controls execute, physical observations establish
progress, memories stay per world. Preserve all state and disclose operator
demonstration provenance. A fresh cold code review is required before publishing.

## Acceptance test

Offline: partial/unavailable NPC route does not suppress a verified connected
forward player route; wrong-floor/blocked joins, stale world/life/goal/owner,
reverse-only record and seeds stay rejected; rejection falls back once, deadline
and final actual arrival remain. Run memory plus actual mover integration suites
before the gate. Include three-record forward chain, reverse-only/seed/tagged
exclusion, blocked/wrong-floor join, cycles, unchanged complete-native U detour,
prefix fresh-request ID/nonce and no stale steering, deadline/spending and
one-prefix preservation, plus static/moving actor snapshots. Developer normal
guarded go_to must climb the recorded ramp and
doorway with selected source/connector/failed-sweep evidence. Then complete
Sonnet+Haiku trial under unchanged acceptance; no autonomous pass is implied by
route replay. Require held-out slope/destination before claiming generality.

## Actual-memory size and planning cost follow-up

Prepublication preflight found125eligibleDEVrecords/2394points. The new2000-node
all-or-nothing cap would suppress every proposal on this preserved memory; remove
that arbitrary newcap, retaining existing400-record storage semantics. Never trim
real memory to make a candidate pass. Read-onlycopy measurement: uppercomplete
8points1.642sCPU, distantprefix73points1.618s. Synchronous cost is material.

Actual follow-up queries: `site.github.com/PrismarineJS/mineflayer-pathfinder astar
heap openHeap` and `site:docs.nav2.org route server spatial index graph nearest
nodes`. Opened primary sources:
- https://raw.githubusercontent.com/PrismarineJS/mineflayer-pathfinder/master/lib/astar.js
- https://raw.githubusercontent.com/PrismarineJS/mineflayer-pathfinder/master/lib/heap.js
- https://docs.nav2.org/rolling/configuration_and_development/configuration_guide/core_servers/route_server/configuring_route_server/

Mineflayer uses a priority heap and tick budgeting; Nav2 documents graph routing
with localized feasible planning. These are conceptual precedents, not runtime
APIs. Narrow adaptation: forward-modeXYjoin buckets (nine neighbouringcells,
then exact original3D/Z/tag/directional-cost checks) and minheap Dijkstra with
stale-entry rejection, deterministic ties and both recorded-edge states. Default
planner semantics unchanged. Astra approved this bounded performance approach;
root retains integration/oneDEVoperator. No inference or gameplay outcomes are
substituted. Privateactualcopy baselineupper1.626s(join.932/search.682) versus
bucket+heap.350s(join.255/search.082), far1.829->.341; exact measuredpaths/costs
and endpoints agree. Remaining synchronous cost needs source/safety review before
publication; it is not a40ms frame-budget guarantee.

Regression requires >2000points and reference equivalence at join boundaries,
negativecoordinates, stackedfloors, water/taboo asymmetry, cycles and equalcost
choices (equalcost waypoint sequences may differ). Measure dense overlapping
records too; bucketing alone has a quadraticworstcase. No new fullgate until
actual-memory and equivalence preflights settle the candidate.

The performance worker also actually searched `uniform spatial grid neighbor
search fixed radius particle cell list algorithm documentation`,
`site:github.com/PrismarineJS/mineflayer-pathfinder heap astar priority queue`,
`site:docs.lammps.org neighbor bins neighbor list cutoff spatial bin` and
`site:docs.scipy.org cKDTree query_ball_point radius spatial`, opening LAMMPS
Developer_flow/neigh_modify and Mineflayer astar/heap primarysources. Bin precedent:
https://docs.lammps.org/latest/Developer_flow.html . Dense500point overlap was
slower: .619s baseline(.466join/.151search) vs .732s(.604/.125); allpairs may
remain candidates and sorting adds work. Therefore do not advertise boundedframe
latency or general responsiveness from the sparseactualcase improvement. Reference
equivalence and200randomvariedgraphs passed, but live performance remains unproven.

Astra source review permits the measured .35s search as declared initial-planning
latency for a bounded idle-start developer trial after equivalence/dense checks.
It does not claim every invocation starts from idle: moving actors or short
trips may become route-required after earlier input. Add fresh postsearch
commanddeadline and captured ownership/world/life/goal revalidation before
adopting a proposal, preserving the fresh actual-position guard before input.
Record searchduration and pre/post pose in developer telemetry; measure live
firstinput latency/displacement. Dense .732s remains a known worstcase sample;
cooperativeplanning is deferred unless live evidence justifies it, not claimed
solved. No controls or cancellation guarantees follow from the sparse benchmark.
