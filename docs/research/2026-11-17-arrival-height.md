# Arrival height: "arrived" at the foot of a ledge (2026-11-17)

**Finding (jump course, live today).** `go_to` said "arrived" 1.4 m short of a spot on a ledge with his feet 1.6 m under its floor: 18:53:45Z, end (143.37, 1704.77, -4.34) for goal (144.00, 1706.00, -2.72) after landing only the first of two jumps. The Doric ledge (0.84 m) went the same way between 18:20Z and 18:45Z. The cause is the arrival test in `move.lua` `reached()`: within the tolerance circle, any height difference up to 2 x half_h (176 cm) counts.

## Why the 2 x half_h slack exists

- `git log -S"2 * st.half_h"` leads to cde2000 (2026-10-27, "Verify navigation outcomes..."). Before it, arrival was 2D only. BUGS R19: go_to said "arrived" 1.32 m from a grave at Z -75.18 while he stood at -45.74, dying in a KillZ.
- The comment in that commit: "Target Z may be an actor origin or floor point. One capsule's full height covers the known pawn-centre/floor offset; closer stacked floors can still overlap this provisional allowance."
- So the slack was meant to catch gross wrong-floor arrivals (29 m) while accepting goals given in either height convention. His position is his capsule centre, 88 cm over his feet. A goal can be a floor point (a station's or item's actor origin, nav points), a capsule centre (players, NPCs, graves, the ladder's and jump course's own points, coordinates copied from his own position) or a point above the floor (a bush's or rock's origin). It was never meant to tell a 0.8 to 1.7 m ledge from the floor under it.

## Counts

Sources: `client_io/events/trips.jsonl` (every go_to and follow, 31 Oct to 17 Nov 19:28Z: 3,015 go_to with status arrived; `end` is his capsule centre). Each trip is linked to its command by `id` against the `bridge_send` lines in `logs/brain-live-*.jsonl` (627 files: 701 brain go_to arrivals with position and target_position; 1,992 of 3,323 trip ids matched).

Measure: dz = his centre minus the goal's Z. **dz < -0.6 m means his feet were more than 60 cm under the goal's floor whichever convention the goal used.** For a centre goal, feet minus floor equals dz; for a floor goal it is dz - 0.88, so even lower. The count is limited to arrivals inside the old slack (dz >= -1.76). Below that, other rules apply: right under a spot that hangs in the air, or in the water over one.

| target kind | arrived | feet > 60 cm under the goal's floor | beyond 1.76 (other rules) |
|---|---|---|---|
| harness: jump course, 17 Nov (centre coords) | 135 | **82 (61 %)** | 0 |
| harness: travel ladder and other legs (centre coords) | 875 | 38 | 7 |
| gather (go_to inside the skill) | 615 | 23 | 0 |
| explore (inside the skill, 3 m tolerance) | 98 | 21 | 27 |
| no id (before 1 Nov, or inside a skill) | 172 | 5 | 0 |
| grave (centre) | 56 | 3 | 0 |
| raw coordinates from the model | 401 | 2 | 0 |
| build (inside the skill) | 21 | 1 | 1 |
| creature, NPC or player (centre) | 197 | 0 | 0 |
| station, item or area by its origin (floor) | 72 | 0 (3 if read as floor points: dz < +0.28) | 0 |
| craft, attack, deconstruct, collect_water, interact, store, talk, give, consume, follow | 394 | 0 | 2 |
| **all** | **3,015** | **175** | **37** |

What this shows:
- The false arrivals are almost all the ladder's and jump course's own coordinate legs (120 of 175). The model's own `[x,y,z]` hit it twice in 401, for example 16 Nov 11:46Z, 1.3 m under a spot by Doric.
- Gather's 23 are not ledges. He ended 0.1 to 0.45 m from the spot (2D), so he stood on it, and the point lies above his centre: the resource's origin, not a floor. Explore's are optional legs with a 3 m tolerance. Neither is touched by the change below.
- Things (stations, items, NPCs, players) never ended under their floor. Their origin height is not a floor to stand on anyway: a chest on a table is reached from the floor.

## The change (`client_mod/scripts/move.lua`, `client_mod/scripts/client_bridge.lua`)

- **The bridge** passes `stand = true` to `move.go_to` when the target is an `[x,y,z]`: a spot to stand on. A thing's id or name, a grave and a player keep the old rule.
- **`M._under_ledge(st, pawn, me, goal)`** (a field of M: the main chunk is at the 200-local limit). For a stand go_to it traces down once per goal at the spot, from 30 cm over it to 2 x half_h + 60 cm under it (`raw_trace`, the same as `overhead()`). That reads the spot's floor whether the point is a floor or a centre. If his feet are more than `step_tol` under that floor (max(MaxStepHeight + 20, 60) = 65 cm), he is not there. The rule is not applied when the floor cannot be read, the goal is a tracked actor, the spot itself is within a step of his feet (no trace then), or the first read would be taken within 45 cm of the spot (the trace would cross his own gear).
- **`arrival()`**: when that rule refuses an arrival, `f.ledge` lets `overhead()` take over inside the old height. A floor within jump reach gets the local plan's jumps (bounded at 12 s, then `goal_above`). A higher floor gets one local plan looking for a way up, then `goal_above` ("the spot is on a floor 1.7 m above me, higher than I can jump, and I see no way up from here").
- **`give_up()`**'s "already there" shortcut and **`verify_arrival()`** apply the same rule.
- **Log line (unseen ledger):** `move: not arrived: my feet are 1.6 m below the goal's floor, 1.4 m from it` (once per goal).

## Tests

- `client_mod/tests/test_move.lua`: 6 new checks in the block after the overhead tests. Before the change, 3 failed: on the 0.84 m ledge he "arrived" at z = 0, the refusal line was missing, and on the 1.7 m ledge he "arrived" at the foot. After it the file passes in full: 373 ok, 0 failed, about 97 s. In the fake world he jumps onto the 0.84 m ledge and arrives in 4 s. On 1.7 m he fails `goal_above` within 3 s. A thing's position on the ledge (no stand) still arrives from the foot. A floor point and a centre point on his own level still arrive.
- `client_mod/tests/test_client_bridge.lua`: `[x,y,z]` passes `stand`, a player does not. The new assertion failed first, then the file passed: 63 PASS.

## The number to move

On the jump course (`--label` per side, the course's own `reached` grader), the count to watch is **go_to answered ok while the ladder's on-top test says not reached: 82 of 135 arrivals today (61 %), expected 0**. Those legs should now end on top or fail `goal_above` with the floor's height. Whether the legs' on-top pass rate rises is the open question. The change makes the miss honest and gives him up to 12 s of jumps; it does not make the jumps land. In job windows the effect is small: the model's raw coordinates hit this 2 times in 401.

## Limits

- Not run live. The trace at the spot uses the same `raw_trace` profile as `overhead()`, but its live behaviour for a goal at the edge of a ledge, or with a creature standing on the spot, is unmeasured.
- A model `[x,y,z]` copied from a thing on a raised surface, such as a chest on a table, now asks him to stand on that surface. He tries the jumps, then fails `goal_above` with the height. The 401 raw-coordinate arrivals hold no such case under the floor test, but a thing's coordinates were sometimes given raw.
- The 12 s clock in `overhead()` restarts each time he moves 50 cm (as before). A long struggle at a ledge then ends through `give_up()` (unreachable) or the deadline, not `goal_above`.
- The counts take a goal's height convention from its kind. Only the dz < -0.6 column is free of that assumption.
