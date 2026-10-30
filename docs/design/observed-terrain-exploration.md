# Observed terrain exploration: read, choose, move, retain

2026-10-30. **Stage1 implementation candidate after design CLEAR and root authorization; release pending cold code review and validation.** Supersedes the larger private draft's strict route-reference prerequisite. Root explicitly narrowed the first slice after a879/a883: a terrain read, retained observations/attempts and both-model delivery, using existing ordinary coordinate `go_to` unchanged. No future-stance adapter or selected-route authority is required in Stage1. Autonomous acceptance remains0/3.

## Goal and controlling steer

Give the complete Sonnet Director + Haiku Controller factual local terrain choices and retain what was observed/tried across an away move. The model chooses whether to survey, move, continue exploration or retry its original job. Adopt Accepted steer in `autonomy-plan.md`, PRINCIPLES and Astra independent review section5.3. Original M1–M6/frozen judges and three unassisted temple200m round trips remain unchanged, currently0/3. No scripted routes, place rules or hidden waypoints.

## Measured cause and new evidence

Private artifacts are under `R/logs/recovery/full-agent-a873/` and `npg-trial-a832/`:

- a875 baseline original-goal local search exhausts13 failures/751 queries. Private batching still fails,11 failures/838 queries/`unreachable_in_window`. Batching alone is not a demonstrated fix.
- An interior away-first recorded-ray chain is admitted by the current production sampler in a877. a879 ordinary coordinate go_to reaches its endpoint in2.406s,H100,actual `[52.4461,1906.9637,-31.1461]`m, using a4point native route. This proves away movement, not execution of every stationary proposal point or discovery of an escape.
- a880 immediately retries the original goal and returns to the earlier failure neighborhood,13.30mXY/5.05mZ short. It does not survey at the away endpoint first. Thus strict corridor references have not been shown necessary for this first handoff; the demonstrated gap is observing/retaining information there before resetting the plan.
- On published08f2f6d, root stages ordinary movement again and executes a883 **at the actual away position**, without movement in the survey:754 queries/0.835CPU seconds/max16/unchanged binding. All361 columns sampled. Relative to the union of a875 scans:179 newly queried columns,173 with candidates,177 candidate heights. Four columns have two heights, including `[46,1900]`m at floorZ approximately-35.734/-30.748m and `[46,1901]` at-35.768/-28.871m. These are newly observed candidate layers, not proven walking connectors.
- a883 retains23 successful directed ray edges and24 start-connected nodes. One reaches the current window boundary at floor `[44,1902,-32.108]`m. **Capsule clearance remains unknown.** None of the four multilayer columns has a layer in that recorded start-connected ray component. Original-goal search still exhausts12 walls/1 slope rejection. This proves useful observation gain and the need to preserve layers, not an exit, reachable lower floor or a physically closed basin. See `away-window-components-a883.json`.

The a883 current snap is `[53,1907]`, producing179 new columns, not the192 predicted for a hypothetical `[52,1907]` snap. Model facts must use measured counts. No further probe chain is a prerequisite for reviewing this slice.

## Reuse and exact Stage1 scope

`skills.lua:1764–1854 explore` chooses eight same-Z distant directions, least-visited10m cells and lexical object matches. Preserve and disclose this object-search behavior. It does not select observed terrain frontiers. Reuse job conventions and visit context, not compass targets or assumed Z.

Reuse `localplan.lua` finite layer sampling and ray verification; the exact production `move.lua` envelope/observation-trace routine already exercised by a875/a883; existing real-input coordinate `go_to`; per-world atomic-save patterns; existing action/board correlation. `map_memory` is census memory and `navmem` experienced-route memory: preserve their schemas and data. Stage1 adds a small body-owned terrain record, not a competing task scheduler or global mapper.

Add one read primitive, proposed `terrain`, that surveys current actual position or queries retained results. Optional original-goal coordinates are context for a bounded baseline local-plan observation and distance reporting, not a movement command. With no objective, perform only the plain floor survey: do not invent a goal to manufacture ray candidates, and returning0 candidates/connectivity unknown is valid. With an objective, return any ray-connected observation candidates plus raw layer facts, each with explicit physical unknowns. The model then uses ordinary `go_to(target=[x,y,z])` if it chooses. This tool supplies no route to the mover and never auto-retries the parent goal. A model may choose a ray-only candidate as a probe; the existing mover must still produce its ordinary truthful outcome.

Persist ordinary go_to outcomes associated with the current episode: actual start/end when available, requested destination, partial endpoint, source/result/failure, correlation and observation revision. Do not infer that the mover followed a survey path. Body result handlers can append this through a pure-data `note_move_result` function; no native query or change to mover decision paths is needed. Repeated goal attempts returning near the same prior failure remain visible facts, not a command veto.

## Floor coordinates, candidates and honest frontier labels

Current `observation_snapshot.position_m` is **floor Z**, whereas go_to accepts **capsule-centre XYZ**. Never copy it directly into an action target. For each suggested position return separate fields:

- `floor_position_m`: measured candidate floor or explicitly labelled self-feet substitution.
- `derived_capsule_center_m`: sameXY, floorZ plus the freshly observed capsule half-height; include half-height, observationID/time and `derivation=floor_plus_current_half_height`. It is an estimated destination centre, not a supported stance or clearance certificate. Hover/target tolerance remains existing movement behavior.
- `connection=recorded_directed_rays` or `unknown`; `capsule_clearance=unknown`; path length, current/original-goal distance and source/age.

Use at most3 ray-connected candidate positions, diversified by recorded path branch and potential new observation coverage. No final-goal-improvement requirement for presenting an away choice; no place semantics. Disconnected successful suffixes are not start-connected candidates. A multilayer floor sample not connected by recorded rays is a **layer observation**, not an inferred destination to walk to.

An interior safe/ray-connected node is not automatically a frontier. Label either predicted new scan columns (subtract retained scan union) or a precise adjacent unknown connection. Reserve `frontier` for the boundary of a named observed connected space beside that named unknown; specify ray versus walking evidence. Existing ray evidence cannot justify `traversable`. Predicted coverage is not measured new layers, visual visibility, an exit or knowledge of an unseen connector. Actual next survey reports measured gain separately.

## Owned read-job lifecycle and budgets

Stage1 uses ordinary line traces only, like production `make_observation_trace`/a883. It **does not acquire `walk_sense`, `DWFloorReader`, a floor hook or a future-stance lease**, does not call `sensor.initial`, and cannot borrow or close the movement guard's reader. The reviewer contracts about a new hypothetical full-capsule protocol therefore apply to deferred Stage2, not this slice.

Implement the survey as one bridge waiter using the existing `{wait=w,wait_s=8}`/`poll`/`expire` route contract and existing contextID/channel/deadline. Never return `pending`: dispatch unconditionally writes that into `S.action`, even for a read tool. Ping already reports waiterIDs for the caller's lost-request tracking. Before a survey starts require the existing authorized-target policy, a nonpaused live character, `DW_MOVE.mode=idle`, no active movement action, arbiter owner/stack empty, and no other terrain read. Current validation is DEV-only; the generic feature binds the actual world identity like existing services, rather than hardcoding a world name. Otherwise return `busy` with the actual known owner; never call `move.stop`, `A.request`, `A.release`, `skills.run_job` or preempt an action to obtain observations. A single terrain-job marker prevents parallel survey requests from multiplying the per-poll budget. Pure history/window queries use the active-world record and recorded source timestamps without native calls or refreshed live claims; they need no idle-pawn reservation.

Capture actual source pose, pawn/PC/capsule identity, life/world/build, generation, profile and native envelope at entry. A latched predicate checks these and exact stationary source before/after each native query and at each poll; source is never a historical hardcoded point. A new action, pose/configuration change, stop/cancellation, channel replacement or timeout invalidates remaining work. The job's finalizer is idempotent and pure Lua: clear marker/pending queries, discard live authority and retain only completed primitive observations as explicitly partial. No sensor lease exists to clean up. Add the existing action-style optional `pause_cleanup` handling to terrain waiters so pause/drop cannot strand its marker; it performs no native calls. Poll exceptions/expiry must run the same finalizer before reply. An invalidated/expired job is terminal and cannot later publish success; partial evidence accompanies its specific failed/interrupted result, never a delayed successful scan. Existing pause behavior and other actions remain unchanged.

Use existing9m/1m/up-to2-layer grid and finite baseline planner; no standalone batching or new goal-directed exploration loop. At most16 actual geometry rays per bridge poll,2000 total,8 cumulative CPU seconds and8wall seconds per survey. Existing bridge poll cadence is100ms; the full2000-query cap may therefore be unreachable before the wall deadline, and that is an honest partial observation. `BridgeClient` default deadline is10s and ResearchProxy20s: return before that earliest caller deadline, leaving transport margin, rather than silently increasing all callers' timeouts. Existing bridge clock is coarse `os.time`; use its early deadline consistently and test the worst alignment. Identity/property reads are not geometry rays; CPU/wall bounds still cover them. Count every attempted native geometry invocation including unknown/error outcomes and profile validation. Preserve one cumulative deadline/query/rejection budget across all phases; no reset after a rejected candidate. Hard-check remaining budget **before** each invocation: the existing LP midpoint+horizontal boundary can request an extra ray, so the read driver must stop with labelled partial-budget observation instead of issuing ray17. Do not modify legacy movement LP or fabricate an unchecked edge to resume. No budget/cancel result means no physical route exists.

## Retained coverage, rare layers and attempts

One body writer atomically saves a bounded per-world `data/skills/<world>/terrain_observations.json`. Initial scope:4 windows TOTAL, including complete, partial and aborted observations (at most361columns and2 heights each), bounded recorded directed ray edges,128 ordinary-move outcomes plus compact attempted/visited summary. Reserve a window slot before starting; no separate unbounded aborted/partial queue. Raw native trace logs are not persisted in normal model memory. Whole-window retention is only at most2888 candidate heights; preserving this small structure is simpler and more truthful than selecting24 points and losing rare layers. Do not erase particular layers in an evenly spaced summary.

Default packet: coverage counts/age/provenance, up to3 ray candidates, up to8 multilayer columns (count/truncation if more),4 recent attempts, and actual new columns/layers/edges since prior observation. `terrain` supports read-only column/window/attempt queries with pagination over retained complete records; no new sensing or guessed data for a historical query. Empty, unqueried, no-candidate and evicted are distinct. An actual first-hit surface may occlude another layer; absence is not a solid wall.

Retain per-window IDs and separate layer heights. SameXY/proximity does not join floors or create graph edges; historical ray proofs stay directed. Preserve old/current query heights and raw differences without claiming stable cross-window layer identity. Evict complete inactive windows coherently; active read/result references are pinned. If capacity cannot be freed, return explicit partial/capacity reason. Keep bounded attempt summary/coverage-truncation flags so evicted places are not silently unvisited. Unknown operator provenance remains unknown; actor=self is not proof of unaided control. Restart retains historical observations/attempts, with no live movement authority to restore.

## Both-model delivery and unchanged goals

The actual Haiku capability/result/current-state paths and Sonnet research/current-task snapshots must receive the same episode/revision/world/age, candidate centre derivation, ray/capsule distinction, rare-layer facts and recent requested-goal/partial-endpoint/outcome history. Here newly observed layers means newly observed candidate-height records; stable cross-window layer identity remains unknown. Pass existing task/action/tool-call correlation through broker/Controller/Director compaction; do not refresh timestamps when composing prompts. A log alone is not delivery. Keep packet bounded and details queryable.

Facts in this case should distinguish: away endpoint reached; a883 survey acquired179 new columns and four multilayer columns; their lower candidates are not known connected; an earlier unsurveyed original-goal retry returned near a prior failure. The models decide whether to continue surveying. Do not veto a repeated explicit go_to, rewrite the objective, auto-select a branch or auto-award parent progress. A successful survey/candidate movement is never the original destination or autonomous goal completion. Existing deadlines, no-progress budgets and frozen judges remain unchanged.

## Stage1 wire contract for body/Python owners

Tool name `terrain`, manifest kind `read`, `moves=false`. Exact flat arguments:

- `mode`: `survey` (default), `history`, or `window`.
- `toward`: optional finite3-number capsule-centre XYZ in metres; valid for `survey` only, diagnostic planning context.
- `window_id`: required for `window`, otherwise absent.
- `column_m`: optional finite2-number XY, valid for `window` only; identifies an exact retained lattice column, never a movement target.
- `cursor`: nonnegative integer, default0; `limit`: integer1–24, default8; apply to historical window detail pages. Survey/default summary remains capped3 candidates/8 multilayer columns/4 attempts.

Existing envelope remains `{ok,reason,data}`; structured payload is **`data.terrain`**. Stable fields shared by both owners:

`version=1`, `mode`, `status=complete|partial|historical`, `window_id`, monotonic record `revision`, existing `request_id`/tool-call/task correlation when supplied, actual `world`, build/sensor version or explicit unknown, `provenance`, and `source={actual_capsule_center_m,half_height_m,observed_at,clock,age_s}`. Never invent task/operator IDs. Snapshot age is computed against the recorded clock when valid; otherwise unknown. The original `toward` is retained as `objective_center_m`, not a parent-goal achievement.

`coverage` carries sampled/total/unvisited columns, no-candidate count, new/overlap relative to named retained windowIDs, and whether prior history was truncated. `candidates` contains `observation_candidate_id` (query/correlation only), `window_id`, `floor_position_m`, `derived_capsule_center_m`, `half_height_m`, `derivation=floor_plus_current_half_height`, candidate source, directed-ray connection status, `capsule_clearance=unknown`, path-length/goal-distance metrics and predicted coverage/unknown-connection purpose. No raw route is accepted by any action. An observationID is not a terrain route reference or actor ID; Stage1 movement uses only existing coordinate go_to.

`layered_columns` carries exactXY and every observed floor-height candidate in that column with source, plus total/returned/truncated counts. `attempts` carries actual existing ordinary go_to request/result fields, correlation, captured observation revision and source/age; unknown starts/provenance remain unknown. `limitations` explicitly distinguishes rays, candidate layers and absent capsule evidence. `window` pages return `columns` (candidate floor heights including empty/no-candidate state), cursor/next_cursor/total, with per-window timestamp and no new native calls. `history` returns bounded window summaries and attempts. Missing/evicted window or column returns a specific `data.detail`/`not_retained` observation outcome, not a fresh scan under the old ID.

On cancellation/binding/timeout/budget failure: `ok=false`, specific existing protocol reason, and any completed primitive evidence under `data.terrain` with `status=partial` and explicit `detail`; never later publish a successful result for the same request. The read job itself produces no new reason-table/judge exception. Pure `note_move_start`/`note_move_result` integration consumes already available bridge request/result fields; it performs no native reads, movement or inference of the route followed. Retain actual floor/centre conventions reported by existing fields or mark convention unknown rather than silently converting a partial endpoint.

The Python owner must preserve `data.terrain` through actual Controller result/state and Director research/snapshot paths and expose the body-provided manifest/schema. It does not rescore physical candidates, synthesize absent observation fields, or make a successful survey/candidate move satisfy the parent destination. Body and Python tests share this exact wire shape before integration.

## Deferred Stage2 and representation limits

Strict candidate route references become justified only if ordinary go_to demonstrably prevents reaching a separately sampled-admitted selected candidate. Stage1 a879 proves ordinary endpoint movement can work; different path selection alone is not a defect. A future route-reference design must separately review exact owned `walk_sense.acquire`/`floor`/`sweep`/`initial`/`close` lifecycle, future support/nonpenetration without bypassing actual-only `initial`, partial cleanup, immutable source/build/revision/endpoint references, fresh actual connector and every-input guard, and suppression of late route substitution. No such authority is added here.

Retained local windows/attempts are already justified. A global graph is not prerequisite to showing new observations from one away handoff. Expand topology only after measured multiwindow/backtracking needs exceed the bounded record. Multilayer representation is required now by a883; a new sensing method for a hidden lower connector remains unproven. Rendered observation is relevant only when paired evidence demonstrates a necessary semantic/physical connector native observations cannot expose. Do not infer a GPU/VLM requirement or physically closed basin from finite local failure.

## Acceptance and later file ownership

After fresh design review: regress actual a875/a883 statuses and floor/centre conversion; preserve all four rare-layer observations and their lack of ray connection. Exercise real read-job polling/budget16/2000/CPU/wall limits, concurrent movement/busy, pause/cancel/error cleanup and no input or reader interference. Test shifted/overlap/evicted coverage and retained ordinary-go_to failures across plan/context/restart; no fabricated unknowns, reverse edges or floor merges. Verify public manifest/schema and actual both-model packets, including correlation, centre derivation, history and no parent-goal pass. Held-out away-first and stacked-floor cases must require no area-specific code.

Main runs one combined gate, published-code developer survey→ordinary-go_to→survey with retained observations, then complete unassisted Sonnet+Haiku with the ordinary unchanged objective. Tag diagnostic assistance; acceptance remains three temple200m round trips/generalization and original frozen judges.

Likely later ownership groups: small terrain read/record module with exact observation-trace reuse/export; bridge waiter/manifest/pure outcome hook; Python schema/capability and both-model projection; focused tests. No planned sampler/guard/movement behavior changes. No principle exception, task-specific route, raw model waypoint input or new model calls. Main assigns file owners after review.

## Search record — 2026-10-30

Read Accepted steer/PRINCIPLES/search-before-building skill, Astra5.3, existing explore/localplan/move/walk_sense/floor_read/arbiter/bridge, map_memory/interface/capabilities/Director and a873–a883. Actual fresh queries for this problem:

- `frontier based exploration Yamauchi 1997 reachable frontiers primary paper`
- `site.arxiv.org VLFM vision language frontier maps exploration navigation frontier`
- `site:github.com bdaiinstitute vlfm frontier map target frontier explored`
- `site:arxiv.org NavGPT explicit reasoning vision language navigation topological map history`
- `site:github.com GengzeZhou NavGPT history candidate viewpoints`
- `site:ompl.kavrakilab.org LazyPRM clearQuery retained roadmap frontier`
- `site:github.com/rai-opensource/vlfm frontier map update reset`

Primary sources actually opened:

- https://www.cs.cmu.edu/~motionplanning/papers/sbp_papers/integrated2/yamauchi_frontier_explor.pdf — known/unknown frontiers and retained visited/inaccessible outcomes. Adapt terms/history, not automatic closest-frontier policy or ideal-sensor completeness.
- https://arxiv.org/abs/2305.16986 and https://github.com/GengzeZhou/NavGPT — LLM decisions supplied with observations/history/explorable options. Conceptual input precedent; no benchmark navigation graph or visual descriptions exist here.
- https://arxiv.org/abs/2312.03275 and https://github.com/rai-opensource/vlfm — physical mapping and language-informed exploration selection are separate. No RGB/depth/VLM dependency proposed.
- https://raw.githubusercontent.com/rai-opensource/vlfm/main/vlfm/mapping/frontier_map.py and https://raw.githubusercontent.com/rai-opensource/vlfm/main/vlfm/policy/base_objectnav_policy.py — frontier update/history and exploration/object-goal separation, no code copied.
- https://ompl.kavrakilab.org/classompl_1_1geometric_1_1LazyPRM.html — retained query/roadmap state and unknown validity; historical facts are not fresh movement authority. Reopened alongside VLFM source after a883; root independently searched retention/frontier precedent too.

Decision: **reuse** current finite native observation/planner, ordinary real-input go_to, world persistence and board correlation. **Adapt** frontier/history and model-selected observation concepts. **Build only** missing bounded terrain read/record/projection. No external library fits the current UE4SS Lua evidence contract without incompatible assumptions. Direct primary URLs must be near later informed code with conceptual/runtime attribution and licensing preserved. Design approval alone does not authorize release; root separately authorized the implementation below.

## Stage1 implementation and focused evidence

Root subsequently authorized the reviewed Stage1 body/Python implementation. Body files add `terrain.lua`, the manifest/read waiter/state/pure go_to-outcome hooks, an optional budget callback on the existing observation-trace factory and read-only planner-start metadata. Legacy movement callers do not provide that callback; movement, sampler, guard and route selection are unchanged. `planner_root_ray_checks` is explicitly relative to the selected planner root, with root floor position, `actual_source_connector=unknown`, root-relative `planner_path_length_m` and common knee/self-region scope. Neither the planner's nearest/fallback start nor sticky first_ok is actual-source connection proof. Candidate centres are floor-plus-currentHH estimates only.

Normal state/history retains four complete-or-partial windows with full bounded column/layer records and128 move outcomes. Default view preserves up to8 rare multilayer columns,3 candidates and4 attempts. Historical window-list entries contain timestamp/age summaries; full prior source geometry is available through window detail. The maximal focused regular packet (4windows,8rare columns,3candidates,4long-ID/target/failure outcomes) remains below7KiB and the existing8KiB retained-result cap, including root/unknown-connector qualification. Python projection is independently owned/tested; no body-side clipping of rare layers is delegated to a generic summarizer.

Focused body tests use real localplan through the read-job driver and the public JSONL bridge. They cover floor-only/no invented goal, layered detail paging/restart, shifted measured coverage, ordinary go_to outcomes, bounded aborted windows/attempts, busy/nonpreemption, lifecycle invalidation, pause, deadlines, reentry, a real slope midpoint+horizontal poll boundary, and an uncooperative producer hitting2000 total without issuing query2001. The planner's explicitly selected observation start is the only graph seed; no nearest arbitrary sampled node is promoted to a connected start. A valid nonactual root with ray successors is separately regressed: candidates disclose unknown actual connector and root-relative distance even when first_ok is sticky.

Private offline replay of all actual a883 queries through the final body driver reproduces754 requests/zero missing,179new/182overlap columns and all4multilayer columns. Actual replay default packet is3141bytes including root/unknown-connector qualification. This is offline measured-geometry evidence, not a new native/game run or an autonomous pass. Root owns the combined gate, published-code developer session and complete Sonnet+Haiku validation.
