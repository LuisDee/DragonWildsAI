# Jump landings: what the logs show, the line to add, a course, ranked rule changes (2026-11-17)

Offline research for goal section 2 ("Jump landings", `docs/GOAL-2026-11-17-long-jobs.md`). Nothing ran on the game, client, server or brain. No Lua was edited. Tool: `tools/jump_stats.py` (tests `tests/test_jump_stats.py`, 10 tests).

## Need

About a third of the walking paths with a jump up hold a landing the code judges missed. After 61412a5 (the slope rule) it looked worse. The goal: make every landing readable, then bring the share under 10 % with no attack ended by it, and keep or bin 61412a5 on evidence.

## Searched

- Repo: `client_mod/scripts/move.lua`, `client_mod/scripts/localplan.lua`, `data/envelopes/Claude.json`, `docs/DISCOVERIES.md` (envelope, local planner), `docs/PROGRESS.md` (b59903c, c835589, 61412a5, the 13:56Z entry), `tools/travel_ladder.py`, `tools/bridge_cmd.py`, the earlier scratch scripts `lp_jumps.py` / `lp_after.py`.
- Logs: `logs/client/client.log` (21 MB, 236,729 lines), `client_io/events/traversal.jsonl` (548 `self_edge` rows: one per jump the body confirmed), 283 brain logs `logs/brain-live-2026111[4-7]*.jsonl` (368 MB, streamed).
- Web: UE CharacterMovementComponent (air control, perch, ledge), UE path following and nav links, Recast/Detour crowd and corridor, Valve NextBot (PathFollower, ground and player locomotion), mineflayer-pathfinder (movements, physics, stuck), Baritone (MovementAscend, Settings). Sources at the end.

## Found

### 1. The code

| what | where | value |
|---|---|---|
| jump edge chosen | `localplan.lua:216-234` `LP:edge` | rise over the step (45 cm) and over 0.9 x run: `jump` up to `env.jump`, `djump` up to `env.djump` |
| slope or step | `localplan.lua:465-497` `LP:verify` | midpoint trace; since 61412a5 also the quarters and the floor normal (`walk_z`), going up only |
| hop over a low obstacle | `localplan.lua:514-523` | blocked at knee, clear at jump height: the edge becomes a `jump` at any rise |
| jump reach | `move.lua:653`, `:669-671`; `data/envelopes/Claude.json` | `env.jump` = 164 cm (measured), `env.djump` = 307 cm (ClaudeDev has the double jump) |
| path log line | `move.lua:1715-1720` | acts letter per point: `w`, `j`, `d` (djump OR drop), `s`, `l`; points in m, x and y rounded to 1 m |
| takeoff | `move.lua:3354-3376` | aim at the jump's start (`f.aim = prev`); press `pawn:Jump()` within 50 cm of it, or within 75 cm after 0.6 s with no gain on the ground (c835589) |
| the press | `move.lua:828-839` `start_jump` | `pawn:Jump()` only; no velocity is set |
| in flight | `move.lua:3381-3383` | aim at the landing point; `saw_air` on the first airborne frame |
| landing judged | `move.lua:3384-3401` | at the first grounded frame after `saw_air`: landed if 2D distance < `within` AND height off < `step_tol` (65 cm) |
| `within` | `move.lua:3390-3391`, `:94`, `:124` | 130 cm when the edge changes level by more than `step_tol` (65 cm); otherwise `lp_radius_cm` 45 cm |
| unconfirmed | `move.lua:3402` | no landing 8 s after the press |
| after a miss | `move.lua:3307-3342` `traversal_failure` | the edge goes into `st.jump_fail` (left out of this trip's plans, `:1611`), `trav_fails` + 1, plan again from here after `lp_cooldown_s` 1.5 s; a follow (a fight's approach) ends `unreachable: no_route` on its third, which the attack reports as `path_blocked` |
| a confirmed landing | `move.lua:393-403`, `:3397` | `self_edge` row in `client_io/events/traversal.jsonl` |

Physics (DISCOVERIES, read live): `JumpZVelocity` 807.9, `GravityScale` 1.85 (gravity -1813 cm/s2), apex 180 cm, `MaxStepHeight` 45, `WalkableFloorAngle` 45.5, capsule half-height 88, walk 450 cm/s (sprint is dropped on local paths). The capsule radius is not recorded.

### 2. The counts, reproduced

`jump_stats report` and `jump_stats windows`:

| measure | PROGRESS | jump_stats | why they differ |
|---|---|---|---|
| paths with a jump up, 14 Nov to 61412a5 | 466 | 466 | same |
| missed landings in them | 166 | 164 paths with a miss | 166 counts every miss line; 2 were on paths with no jump up (a hop or a jump on one level) |
| s29 + s30, paths with a miss | 8 of 43 | 8 of 43 (of 95 paths) | same |
| s31, paths with a miss | 11 of 16 | 11 of 16 (of 33 paths) | same |

The PROGRESS band "drop-and-climb 120 to 200 cm" is the letter `d` that rises: a double jump, not a drop and a climb. The 248 edges "200 cm or more" are double jumps too.

After 61412a5 the log also holds 12 paths from 17:18Z to 17:25Z. With them: 13 of 28 paths after, against 78 of 294 in the measured period before (from b59903c, when the "landed" line began): p = 0.046.

### 3. Which misses were falls

From b59903c on, every miss has its "landed" line (distance and unsigned height), and the next plan or stuck line within 3 s gives where he stood, so the height can be signed. Measured period b59903c to 61412a5, 207 jump-up edges tried (landed or judged missed):

| what the 78 judged misses were | n |
|---|---|
| fell short: 65 cm or more under the point, no higher than the takeoff | 27 |
| on the point's level (under 65 cm off), beyond the allowed distance | 20 |
| off height but within a walkable slope of the point (no position after) | 19 |
| above the point (a higher shelf or a slope) | 8 |
| off height and away, unsigned | 4 |

Paths with a jump up that hold a strike, under each judging rule (`jump_stats report`, table "landing rule"):

| rule | 14 Nov to 61412a5 | b59903c to 61412a5 (measured) | after 61412a5 |
|---|---|---|---|
| as judged now | 164 of 466 (35 %) | 78 of 294 (27 %) | 13 of 28 (46 %) |
| A: a rise over the step gets the 130 cm window | 161 of 466 (35 %) | 75 of 294 (26 %) | 12 of 28 (43 %) |
| B: A, and on the level within 250 cm is a landing | 126 of 466 (27 %) | 56 of 294 (19 %) | 9 of 28 (32 %) |
| C: B, and a strike only if he came down no higher than takeoff + step | 108 of 466 (23 %) | 45 of 294 (15 %) | 5 of 28 (18 %) |

Before b59903c the 33 misses have no measure and count as strikes under every rule, so the 14 Nov column overstates B and C.

### 4. Real falls by edge (measured period, rule C)

| split | tried | judged missed | fell back (rule C) |
|---|---|---|---|
| jump, diagonal | 43 | 27 (63 %) | 19 (44 %) |
| jump, cardinal | 42 | 20 (48 %) | 6 (14 %) |
| djump, diagonal | 82 | 28 (34 %) | 17 (21 %) |
| djump, cardinal | 40 | 3 (8 %) | 3 (8 %) |
| all diagonal (run over 1.2 m) | 125 | 55 (44 %) | 36 (29 %) |
| all cardinal | 82 | 23 (28 %) | 9 (11 %) |
| rise 65 to 120 cm | 23 | 17 (74 %) | 11 (48 %) |
| rise 120 to 165 cm | 52 | 23 (44 %) | 12 (23 %) |
| rise over 165 cm (double jumps) | 122 | 32 (26 %) | 21 (17 %) |
| in slope range (rise at most 0.9 x run) | 35 | 26 (74 %) | 14 (40 %) |
| above slope range | 172 | 52 (30 %) | 31 (18 %) |
| from a standstill (first edge of the path) | 87 | 30 (34 %) | 20 (23 %) |
| with a walk before it | 120 | 48 (40 %) | 25 (21 %) |

- Diagonal against cardinal: 36 of 125 against 9 of 82 fell back, p = 0.003 (`tools.ab two 9 82 36 125`); single jumps 19 of 43 against 6 of 42, p = 0.004. It holds inside each busy place: (156.5, 1744.6) 10 of 55 against 0 of 32; (138.6, 1721.8) 10 of 29 against 1 of 16; (159.9, 1737.4) 5 of 11 against 2 of 11. Not explained by slope range: above slope range it is 29 of 110 against 6 of 80.
- A standstill start does not fall back more than one with a walk before it (23 % against 21 %).

### 5. The worst places (14 Nov to now, 5 m clusters of the landing point)

`jump_stats places`:

| x | y | floor z | tried | judged missed | landed | median rise cm | where |
|---|---|---|---|---|---|---|---|
| 138.6 | 1721.8 | -6.8 | 54 | 33 | 21 | 200 | windmill hill (the rats) |
| 156.5 | 1744.9 | -6.5 | 104 | 26 | 78 | 290 | windmill hill, the 3 m ledge |
| 159.7 | 1737.2 | -4.1 | 29 | 20 | 9 | 160 | windmill hill |
| 110.2 | 1847.5 | -31.2 | 36 | 18 | 18 | 80 | by Doric |
| 118.9 | 1931.0 | -27.4 | 9 | 8 | 1 | 300 | north of the pond |
| 112.4 | 1904.8 | -29.7 | 8 | 6 | 2 | 140 | north of the church |
| 107.0 | 1848.0 | -30.8 | 7 | 5 | 2 | 140 | by Doric |
| 164.0 | 1745.0 | -8.3 | 6 | 5 | 1 | 160 | windmill hill |
| 143.1 | 1705.9 | -5.0 | 9 | 4 | 5 | 120 | windmill hill, top |
| 289.2 | 1791.2 | -39.3 | 4 | 4 | 0 | 210 | Temple Woods |

By day (paths with a jump up, judged missed): 15 Nov 7 of 11; 16 Nov 107 of 263 (41 %); 17 Nov 61 of 208 (29 %). The place mix changes from day to day, so these are not trends.

### 6. Attacks

`jump_stats attacks`: 118 attack results in the brain logs from 16 Nov 04:50Z to 17 Nov 18:00Z (PROGRESS counted 74 for 14 to 17 Nov by another cut; my count to 09:30Z on 17 Nov is 92). 5 ended `path_blocked`, every one with a jump fault in `data.move.lp_fail`: 3 "jump landing missed" (16 Nov 09:53:59Z, 12:27:37Z; 17 Nov 14:00:02Z), 1 "jump takeoff not confirmed grounded" (07:36:11Z), 1 "jump route changed" (12:00:51Z). In the s31 one, the three strikes were 121 cm and 69 cm off, 185 cm and 1 cm off, 226 cm and 75 cm off: under rule B the second is a landing, so the third strike and the `no_route` would not have come.

### 7. What the logs cannot say about a landing

- Where he took off: only "within 50 cm" of the start (or the 3 "taking off N cm" lines).
- His speed and heading at takeoff. Sprint is dropped on local paths, so it is at most a walk, but how much of it points at the ledge is unknown.
- How high he got and how near the point he came in the air: so "never above the ledge" (too close to the face, too slow) and "reached the ledge and slid off" (a corner, a steep or small top) look the same.
- The sign of the height off: only through a plan or stuck line within 3 s (93 of 164 misses have one).
- The floor under him at the landing and its slope.
- Successful landings: only as `self_edge` rows in another file, with no measure of how far off they were.
- Which edge of a path missed: inferred (the first jump-up edge with no `self_edge`).
- Time in the air, and whether the judgement came at the first touch of a face edge before he slid.

## Proposal

### The log line (paste into `client_mod/scripts/move.lua`)

One line for every typed jump (landed, missed, unconfirmed, route changed): `move: jump verdict=...`. `tools.jump_stats verdicts --since <iso>` parses it (tested).

1. Above `local function steer_typed_jump` (move.lua:3304), add:

```lua
-- one line per typed jump: what was intended and what happened (docs/research/2026-11-17-jump-landings.md).
-- cm; heights are floor heights (feet = capsule centre - half height); apex and nearest are taken in flight.
local function jump_landing_line(st, pawn, me, p, j, verdict, why, t, log)
    if not log or not j or not p then return end
    local hh = st.half_h or 88
    local a = j.previous or p
    local feet = me.Z - hh
    local fz, fnz
    local okf, hit, out = pcall(raw_trace, pawn, { X = me.X, Y = me.Y, Z = me.Z }, { X = me.X, Y = me.Y, Z = feet - 300 })
    if okf and hit and type(out) == "table" and out.ImpactPoint then
        fz = out.ImpactPoint.Z
        fnz = out.ImpactNormal and out.ImpactNormal.Z
    end
    local tk, vv = j.takeoff or {}, j.v0 or {}
    local ex, ey = p.X - a.X, p.Y - a.Y
    local el = math.sqrt(ex * ex + ey * ey)
    local vh = vv.X and math.sqrt(vv.X * vv.X + vv.Y * vv.Y) or nil
    local toward = (vh and vh > 1 and el > 1) and (vv.X * ex + vv.Y * ey) / (vh * el) or nil
    local function f0(x) return x and string.format("%.0f", x) or "-" end
    local function p3(q, dz) return q and q.X and string.format("(%.0f,%.0f,%.0f)", q.X, q.Y, q.Z - (dz or 0)) or "-" end
    log(string.format("move: jump verdict=%s why=%s act=%s rise=%.0f run=%.0f k=%s/%s from=%s to=%s takeoff=%s"
        .. " takeoff_off=%s v0=%s v0h=%s toward=%s air=%.2f apex=%s nearest=%s at=%s feet_dz=%.0f"
        .. " from_takeoff_dz=%s off=%.0f floor=%s floor_nz=%s",
        verdict, why, p.leap and "leap" or tostring(p.act), p.Z - a.Z, el, tostring(st.lwp), tostring(st.lpath and #st.lpath),
        p3(a), p3(p), p3(tk, hh), tk.X and f0(math.sqrt((tk.X - a.X) ^ 2 + (tk.Y - a.Y) ^ 2)) or "-",
        p3(vv), f0(vh), toward and string.format("%.2f", toward) or "-", t - (j.started or t),
        j.apex and string.format("%+.0f", j.apex - hh - p.Z) or "-",
        j.nearest and string.format("%.0f@%+.0f", j.nearest, j.nearest_dz) or "-",
        p3(me, hh), feet - p.Z, tk.Z and string.format("%+.0f", me.Z - tk.Z) or "-",
        math.sqrt((me.X - p.X) ^ 2 + (me.Y - p.Y) ^ 2), f0(fz), fnz and string.format("%.2f", fnz) or "-"))
end
```

2. At the takeoff (move.lua:3370-3373), read his velocity just before the press and keep it with where he stood:

```lua
        local okv, vx, vy, vz = pcall(function() local u = pawn.CharacterMovement.Velocity; return u.X, u.Y, u.Z end)
        if not owned(bind) then return true end
        local jr = start_jump(st, t, pawn, p.act == "djump" and st.env and st.env.double_jump, log)
        if st.local_authority and not local_route_owned(st, gen, pawn, pc, goal) then return true end
        if jr == "accepted" then
            st.lp_jump_exec = { path = st.lpath, index = st.lwp, endpoint = p, previous = prev, token = st.owner_token, started = t, saw_air = false,
                takeoff = v(me), v0 = (okv and type(vx) == "number") and { X = vx, Y = vy, Z = vz } or nil }
```

   (`pawn:Jump()` only sets the press; the velocity read before it is the run-up. The same read is already made by `h_speed`, move.lua:1945.)

3. In flight (move.lua:3383), replace `if grounded == false then j.saw_air = true end` with:

```lua
    if grounded == false then
        j.saw_air = true
        if me.Z > (j.apex or -math.huge) then j.apex = me.Z end
        local dn = d2(me, p)
        if not j.nearest or dn < j.nearest then j.nearest, j.nearest_dz = dn, (me.Z - (st.half_h or 88)) - p.Z end
    end
```

4. At the judgement, right after `local within = ...` (move.lua:3391):

```lua
        local ok_land = off < within and dz < step_tol(st)
        pcall(jump_landing_line, st, pawn, me, p, j, ok_land and "landed" or "missed",
            ok_land and "within" or ((off >= within and dz >= step_tol(st)) and "far_and_off_height" or (off >= within and "far" or "off_height")), t, log)
        if not owned(bind) then return true end
```

5. Before `return traversal_failure("jump route changed")` (:3379) and `return traversal_failure("jump landing unconfirmed")` (:3402):
   `pcall(jump_landing_line, st, pawn, me, j.endpoint or p, j, "route_changed", "plan_changed", t, log)` and
   `pcall(jump_landing_line, st, pawn, me, p, j, "unconfirmed", "no_ground_8s", t, log)`.

Fields: `takeoff_off` = how far from the jump's start he pressed; `toward` = cosine between his run-up and the edge (1 = straight at it); `apex` = the highest his feet got above the landing floor; `nearest` = closest 2D approach to the point in the air and his feet height there; `feet_dz` signed; `from_takeoff_dz` = did he end above where he took off; `floor`, `floor_nz` = the ground under him and its slope (0.70 is the steepest he can stand on). Cost: one trace (about 1 ms) per jump. The existing "landed ..." line stays, so the old parser keeps working.

Before the window: a fake-engine case in `client_mod/tests/test_move.lua` that wants the line on a missed and a landed jump (negative test first); a row in `tools.unseen` with the log text `move: jump verdict=`. The trace and the velocity read are calls move.lua already makes elsewhere (`_crumb_floats`, `h_speed`); no struct is sent anywhere.

### The course (no model)

Short legs (under about 10 m, so the local planner leads; goals beyond 10 m get oracle routes, DISCOVERIES) from where he stood below each of the worst places to a point on top. Starts are capsule-centre positions from his own plan lines; goals are path end points + 0.88 m (`jump_stats course`).

| id | place | start (m, capsule) | goal (m, capsule) | judged missed there |
|---|---|---|---|---|
| jump_hill_rats | 138.6, 1721.8 | 134.94, 1718.0, -7.82 | 140.0, 1721.0, -3.02 | 33 of 54 |
| jump_hill_ledge3m | 156.5, 1744.9 | 154.52, 1747.16, -10.91 | 158.0, 1739.0, -5.32 | 26 of 104 |
| jump_hill_mid | 159.7, 1737.2 | 156.64, 1744.61, -8.52 | 159.0, 1737.0, -3.22 | 20 of 29 |
| jump_hill_east | 164.0, 1745.0 | 154.38, 1748.35, -11.36 | 164.0, 1745.0, -7.42 | 5 of 6 |
| jump_hill_top | 143.1, 1705.9 | 143.97, 1703.38, -4.87 | 144.0, 1706.0, -2.72 | 4 of 9 |
| jump_doric | 110.2, 1847.5 | 106.46, 1849.46, -31.36 | 109.0, 1847.0, -30.52 | 18 of 36 |
| (optional) jump_church_north | 112.4, 1904.8 | 114.0, 1903.0, -28.62 | 112.0, 1906.0, -29.52 | 6 of 8; start from a path point, check it first |

How to drive it: `tools/travel_ladder.py` already does exactly this through the body only: the dev `teleport` fixture to the start, then one bridge `go_to` on the debug channel, with the live lock, the dev-server guard, and a row per leg in `logs/evals/travel_ladder.jsonl`. Add the legs to its `P` and `OBSTACLES` (the main session's edit; `--only` selects from `JOURNEYS + OBSTACLES`):

```python
P.update({
    "jhr_a": [134.94, 1718.0, -7.82], "jhr_b": [140.0, 1721.0, -3.02],
    "jhl_a": [154.52, 1747.16, -10.91], "jhl_b": [158.0, 1739.0, -5.32],
    "jhm_a": [156.64, 1744.61, -8.52], "jhm_b": [159.0, 1737.0, -3.22],
    "jhe_a": [154.38, 1748.35, -11.36], "jhe_b": [164.0, 1745.0, -7.42],
    "jht_a": [143.97, 1703.38, -4.87], "jht_b": [144.0, 1706.0, -2.72],
    "jd_a": [106.46, 1849.46, -31.36], "jd_b": [109.0, 1847.0, -30.52],
})
OBSTACLES += [
    _j("jump_hill_rats", "jhr_a", "jhr_b", "jump: windmill hill, rat ledge", human_m=8),
    _j("jump_hill_ledge3m", "jhl_a", "jhl_b", "jump: windmill hill, the 3 m ledge", human_m=10),
    _j("jump_hill_mid", "jhm_a", "jhm_b", "jump: windmill hill, middle", human_m=9),
    _j("jump_hill_east", "jhe_a", "jhe_b", "jump: windmill hill, east", human_m=11),
    _j("jump_hill_top", "jht_a", "jht_b", "jump: windmill hill, top", human_m=4),
    _j("jump_doric", "jd_a", "jd_b", "jump: the ledges by Doric", human_m=5),
]
```

Then, on a named world (rule 9), with the brain stopped:

```
.venv\Scripts\python.exe -m tools.travel_ladder --only jump_hill_rats,jump_hill_ledge3m,jump_hill_mid,jump_hill_east,jump_hill_top,jump_doric --repeat 5 --label jumpcourse
.venv\Scripts\python.exe -m tools.jump_stats verdicts --since <the run's start, ISO Z>
.venv\Scripts\python.exe -m tools.jump_stats report --since <the run's start, ISO Z>
```

Six legs times five is 30 legs. A leg can arrive with no jump (a remembered route or a learned link round the ledge); `report` counts the paths that had one. Rats on the hill start fights (`reflex_busy` waits them out). One-off commands without a script: `.venv\Scripts\python.exe -m tools.bridge_cmd go_to "{\"target\": [140.0, 1721.0, -3.02]}"`.

### Mechanism candidates, ranked by the evidence

1. **Diagonal jump-up edges fall back.** For: 29 % of diagonal tries against 11 % of cardinal ones (p = 0.003), in every busy place, for jumps and double jumps alike, and outside slope range too. mineflayer-pathfinder removed diagonal jump-ups for this reason ("A diagonal jump can clip the corner of the raised block. Use the cardinal jump instead, where the executor can approach it head-on."), and Baritone ships `allowDiagonalAscend = false`. Against: the corner clip itself is not seen; `apex` and `nearest` in the new line will show it (near the point but never above it).
2. **The judge counts landings on the upper level as misses.** For: 20 of the 78 measured misses stood on the point's level 130 to 250 cm away; 7 hops of 45 to 65 cm got the 45 cm window because `level` compares the rise with `step_tol` (65), not the step (45) (move.lua:3390); 9 stood within 130 cm and 65 to 100 cm off height on a slope. Rules A to C take the paths with a strike from 27 % to 15 % offline. Against: rule B accepts a landing up to 250 cm off, which can be past a lip; the re-plan from there must still work (it does today after a "miss").
3. **Takeoff too close to the face for the rise.** For: at 450 cm/s his feet pass 120 cm only 85 cm after the press and 150 cm after 119 cm (ballistics from the measured envelope), while the press comes within 50 cm of a cell centre that can be 50 cm from the face; NextBot's player locomotion forces run speed and steers at the landing during a climb, and mineflayer simulates the press 0 to 6 ticks later before it jumps. Against: a standstill start does not fall back more than a run-up (23 % against 21 %), and higher single jumps fall back less, not more (48 % at 65 to 120 cm, 23 % at 120 to 165 cm). Not shown; `takeoff_off`, `v0h`, `toward` and `apex` will.
4. **The landing cell is no floor for his capsule.** For: rises in slope range (a step-like slope) fall back 40 % against 18 %; 65 to 120 cm rises fall back 48 %. One trace per 1 m cell can find a small rock top or a steep face; UE refuses to perch on an edge (`PerchRadiusThreshold`) and slides him off a floor steeper than `WalkableFloorAngle`. Against: no floor normal is logged; `floor_nz` will show it.
5. **61412a5 chose jumps where a walk would do.** For: after it, 5 of 5 slope-range jumps were judged missed. Against: only 1 of those 5 fell back, and paths with a real fall were 5 of 28 after against 45 of 294 before (p = 0.78). The rise in misses after 61412a5 is in the judge (candidate 2), not in falls.
6. **Judged too early** (at the first touch, before he slid or stepped up). Nothing in the logs for or against. `nearest`, `air` and `feet_dz` will show it.
7. **Height beyond the jump.** Against: one single jump over 165 cm in the whole period; double jumps up to 307 cm fall back 17 %.

### Rule changes, ranked

| # | change | adapts | number it should move (offline estimate) |
|---|---|---|---|
| 1 | Judge: a strike only when he came down no higher than the takeoff + the step; on the point's level (under 65 cm off) within 250 cm counts as landed (the plan goes on from there); a rise over the step (not over `step_tol`) gets the 130 cm window. Anything else that is not a fall is a re-plan with no strike and no `jump_fail`. | Baritone MovementAscend (UNREACHABLE only when the feet end below the source); NextBot PathFollower (a climb counts by height, not by distance to the point); Detour crowd (no strike count on a link; re-place and re-plan); UE path following (`OnLanded`, `IsOnPath`) | paths with a strike 27 % to 15 % (measured period), 46 % to 18 % after 61412a5; s31's `path_blocked` would not have ended (2 strikes, not 3) |
| 2 | Planner: no diagonal jump-up or double-jump-up edges in `LP:edge` (a diagonal pair that rises over the step and the slope test gets no edge; the plan goes cardinal). | mineflayer-pathfinder `getMoveDiagonal` (`if (y === 1) return`); Baritone `allowDiagonalAscend = false` | falls among tried jumps 29 % (diagonal) toward 11 % (cardinal); paths with a fall about 45 of 294 (15 %) to about 22 of 294 (7.5 %) if the diagonal ones fall at the cardinal rate |
| 3 | Takeoff: press where the arc clears the face, from the measured envelope and his speed (the face distance from the forward knee probe he already has), walking straight at the ledge. Only if the new line shows `apex` under the ledge at `nearest`. | mineflayer `canWalkJump` (simulate the press 0 to 6 ticks later); NextBot `PlayerLocomotion` climb (run speed, approach the landing every tick) | falls on cardinal 120 to 165 cm jumps |
| 4 | Landing cell: ask for floor under the capsule, not one trace: 4 traces at the capsule radius round the point and a normal at or over `walk_z`. | Recast `walkableRadius` erosion and `walkableSlopeAngle`; UE `PerchRadiusThreshold` | falls on slope-range jumps (40 %) and 65 to 120 cm rises (48 %) |

Order: the log line first (rule 4 of the loop), then 1 (it changes what counts, so it goes in with the course as its own window), then 2. One change per window (rule 11): for 1 the course's "paths with a strike" from about 30 % toward 15 % needs about 121 paths a side (`tools.ab need 0.3 0.15`), about four course runs of 30 legs.

**Keep or bin 61412a5.** Keep it if, with change 1 in, slope-range jumps on the course fall back in under 51 % of tries (the stuck rate of the 80 cm-plus walks it replaced: 70 of 137) and the course's paths with a strike are under 10 %. Bin it if slope-range jumps fall back in 51 % or more over at least 20 tries. Today: 1 of 5 fell back after it.

## Not taken

- `LaunchCharacter` with a velocity from `SuggestProjectileVelocity` (the usual UE NavLink jump): it emulates a jump, which the design rules forbid; he presses Jump like a player.
- Raising `jump_land_cm` alone: it lets falls 130 to 250 cm away and 160 cm low count as landings (57 of the misses fell short).
- Detour's off-mesh animation (a lerp over the link): not a physical jump.
- Bigger cells or a finer grid for the whole planner: Recast's fine grid would solve the shelf case, but it is a rebuild; the four-trace check (change 4) gets the capsule test at 4 traces per landing.

## Limits

- Paths inside a trial are not independent, so the p values are optimistic.
- The edge a miss belongs to is inferred (first jump-up edge with no `self_edge`). A `self_edge` is also written when `advance()` passes a jump point, so a few "landed" may be walks past it.
- The signed height comes from a position up to 3 s after the miss; he may have moved. 71 of 164 misses before 61412a5 have none.
- Rule C counts a miss with no position as a strike, so its estimate is high.
- The diagonal effect may partly be place: the cardinal and diagonal edges at one place are not the same piece of ground.
- After 61412a5 there are 28 paths (16 from s31). The 17:18Z to 17:25Z paths are from an unnamed window.
- The course starts and goals are positions he stood at or planned to; the optional church leg's start was not stood at. `human_m` is the straight line, a guess.
- Valve's `ClimbUpToLedge` in the ground locomotion is a stub (`return false`); only the player locomotion version climbs. UE's `UPathFollowingComponent` source was not read (Epic's GitHub needs a login; only the API pages).
- No search found a published per-link strike rule in UE or Detour; "no strike, re-plan" is what their code does, not a documented policy.

## Sources

- mineflayer-pathfinder `lib/movements.js` (diagonal jump-up removed, cardinal jump-up only): https://github.com/PrismarineJS/mineflayer-pathfinder/blob/master/lib/movements.js
- mineflayer-pathfinder `index.js` (point reached within 0.35 blocks and under 1 block of height; reset after 3.5 s with no node): https://github.com/PrismarineJS/mineflayer-pathfinder/blob/master/index.js
- mineflayer-pathfinder `lib/physics.js` (`canWalkJump`, `canSprintJump`: simulate the jump 0 to 6 ticks later): https://github.com/PrismarineJS/mineflayer-pathfinder/blob/master/lib/physics.js
- Baritone `MovementAscend.java` (feet below the source = UNREACHABLE): https://github.com/cabaletta/baritone/blob/1.19.4/src/main/java/baritone/pathing/movement/movements/MovementAscend.java
- Baritone `Settings.java` (`allowDiagonalAscend` false; `allowParkour` "falls off when cornering"): https://github.com/cabaletta/baritone/blob/1.19.4/src/api/java/baritone/api/Settings.java
- Valve NextBot `NextBotPathFollow.cpp` (climb judged by height, failure callbacks, no own stuck timer): https://github.com/ValveSoftware/source-sdk-2013/blob/master/src/game/server/NextBot/Path/NextBotPathFollow.cpp
- Valve NextBot `NextBotGroundLocomotion.cpp` (`JumpAcrossGap` launch, `ClimbUpToLedge` stub): https://github.com/ValveSoftware/source-sdk-2013/blob/master/src/game/server/NextBot/NextBotGroundLocomotion.cpp
- Valve NextBot `NextBotPlayerLocomotion.cpp` (climb: run speed, approach the landing each tick, done on the first ground): https://github.com/ValveSoftware/source-sdk-2013/blob/master/src/game/server/NextBot/Player/NextBotPlayerLocomotion.cpp
- Recast/Detour `DetourCrowd.cpp` (off-mesh traversal, `checkPathValidity`, no per-link failure count): https://github.com/recastnavigation/recastnavigation/blob/main/DetourCrowd/Source/DetourCrowd.cpp
- Detour `dtPathCorridor::moveOverOffmeshConnection`: https://recastnav.com/classdtPathCorridor.html
- Recast config (`walkableClimb`, `walkableSlopeAngle`, `walkableRadius`): https://recastnav.com/group__recast.html
- UE `UPathFollowingComponent` (`OnLanded`, `IsOnPath`, `UpdateBlockDetection`): https://docs.unrealengine.com/4.27/API/Runtime/AIModule/Navigation/UPathFollowingComponent/index.html
- UE `UCharacterMovementComponent` properties (perch radius, ledge check, air control, walkable floor angle): https://dev.epicgames.com/documentation/en-us/unreal-engine/python-api/class/CharacterMovementComponent
- UE `LimitAirControl` (air control after an impact while falling): https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/UCharacterMovementComponent/LimitAirControl
- UE forum, lateral movement stops on wall contact in the air: https://answers.unrealengine.com/questions/110803/view.html
- UE `SuggestProjectileVelocity_CustomArc` with `LaunchCharacter` (not taken): https://forums.unrealengine.com/t/launch-character-to-location-how-do-i-use-suggest-projectile-velocity/292765
