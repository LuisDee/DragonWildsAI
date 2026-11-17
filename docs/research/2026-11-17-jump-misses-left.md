# Jump misses left after the run-up and the judge (2026-11-17)

Offline study for goal section 2 (`docs/GOAL-2026-11-17-long-jobs.md`). Nothing ran on the game, client, server or brain; no repo file but this one was written. Data: the 172 `move: jump verdict=` lines in `logs/client/client.log` from 18:18Z to 19:36Z (four course windows plus one line in play), the `move: jump run-up` lines (49 inside the windows), `logs/window_jumpcourse_1117{b,c,d,e}.txt` and `logs/evals/travel_ladder.jsonl` for the window times. Scratch scripts (not in the repo): the parser uses `tools.jump_stats.parse_verdict`.

Windows: base 18:18-18:26Z (29 lines), run-up 3932462 18:33-18:43Z (34), judge 874f73d 18:52-19:05Z (51), judge2 = current code (874f73d + ee6a78b + efd12e3) 19:16-19:28Z (57), play 19:36Z (1).

Terms. **Current judge**: move.lua 3444-3474 applied to each line's own fields: level = rise over 65 cm; within 130 cm and under 65 cm off = `within`; else `over` if under 65 cm off, nearest in the air under 130 cm and feet above minus half the rise; else `above` if within 130 cm and 0 to 130 cm above. **Real fall** (rule C): feet 65 cm or more under the cell and no more than 45 cm above the takeoff. **True rise**: the cell's Z minus his feet at the press (`to.Z - takeoff.Z`), not the planner's `rise`.

## 1. The recount

| window | lines | missed as logged | missed, current judge | real falls |
|---|---|---|---|---|
| base | 29 | 19 | 11 | 7 |
| run-up | 34 (1 route_changed) | 15 | 2 | 1 |
| judge | 51 (2 route_changed) | 11 | 9 | 4 |
| judge2 (current code) | 57 | 14 | 13 | 5 |
| play 19:36Z | 1 | 1 | 1 | 1 |
| **all** | 172 | 60 | **36** (+3 route_changed) | **18** |

- The current judge turns 29 logged misses into landings (22 `over`: 8 base, 13 run-up, 1 judge2; 7 `above` at Doric in the judge window) and 5 landings back into misses: the five Doric `over` of the judge window that ee6a78b removed. No landing under the current judge is a real fall.
- One line disagrees with the current rules on its own numbers: 19:20:59Z, `djump rise=200 nearest=18@+88 feet_dz=31 off=158` was judged `missed why=far` live although `over` holds on its fields. Worth a look (is `prev` at the judgement the line's `from`?).
- Paths with a jump up that hold a strike, judge2: 13 of 62 (21 %). Since the run-up (run-up + judge + judge2): 24 strikes in 166 paths (14 %); 12 of the 24 are the Doric cell.
- 32 of the 133 landings stand with the floor under the capsule's centre 60 cm or more below the cell (he is perched on the lip, or on a lower slope past it). They are landings, but thin ones: 9 are the diagonal edge onto the hill-east cell, each perched 56 to 96 cm to the side.

## 2. The misses left, by mechanism

All windows (36 missed + 3 route_changed, 18 falls), and since the run-up (25 missed incl. play + 2 route_changed, 11 falls).

| # | mechanism | all: missed / falls | since run-up: missed / falls |
|---|---|---|---|
| M1 | Doric: a running jump flies over a narrow top whose cell Z is about 88 cm under it | 12 / 1 | 12 / 1 |
| M2 | Hill east: a single jump at the edge of its reach meets the face under the lip | 9 (+1 rc) / 9 | 4 (+1 rc) / 4 |
| M3 | Sideways run-up | 7 / 3 | 1 / 1 |
| M4 | Came down by the cell and ran or slid off the top | 2 / 1 | 2 / 1 |
| M5 | Double jump never rose to the level | 3 (+1 rc) / 3 | 3 (+1 rc) / 3 |
| M6 | Pressed from the level below the jump's start | 1 / 1 | 1 / 1 |
| M7 | Judge strict: on or above the upper level, past 130 cm | 2 / 0 | 2 / 0 |
| | route_changed during a fight pause (air 45 s) | rc 1 | rc 1 |

**M1, Doric (to=(10900,184700,-3138), from (10800,184700,-3216), rise 78, straight).** Every running try missed: 12 of 12 at 450 cm/s, toward 0.99 to 1.00, apex +102 to +104, passing 7 to 23 cm from the cell at 75 to 103 cm over it, then down 152 to 175 cm past it on a bench 55 cm under the cell, 20 cm above the takeoff. The jump that follows from that bench is pressed from a standstill and lands 39 to 55 cm from the cell, 91 to 96 cm over it (`above`, 11 of 11): the floor beside the cell is about 88 cm higher than the cell's Z. So the top is a narrow rock about 164 cm over the takeoff (the single jump's whole reach), the planner's one trace per cell reads its foot (a planner cell whose height is wrong; floor - to.Z = +86 to +92 next to the cell, -57 past it), and at 450 cm/s he skims it at the apex and goes over. Only 1 of the 12 is a real fall by the cell's Z (row 69, feet -68); the other 11 are at the takeoff level by the real top.

```
18:53:56Z verdict=missed why=off_height act=jump rise=78 run=100 k=5/5 from=(10800,184700,-3216) to=(10900,184700,-3138) takeoff=(10794,184695,-3214) takeoff_off=8 v0=(450,1,0) v0h=450 toward=1.00 air=0.92 apex=+104 nearest=20@+103 at=(10978,184707,-3206) feet_dz=-68 from_takeoff_dz=+8 off=78 floor=-3208 floor_nz=0.99
19:18:16Z verdict=missed why=far act=jump rise=78 run=100 k=5/5 from=(10800,184700,-3216) to=(10900,184700,-3138) takeoff=(10782,184695,-3214) takeoff_off=19 v0=(450,-12,0) v0h=450 toward=1.00 air=0.89 apex=+103 nearest=8@+78 at=(11052,184729,-3195) feet_dz=-57 from_takeoff_dz=+19 off=155 floor=-3197 floor_nz=0.99
```

**M2, hill east (to=(16400,174500,-832)).** True rise 153 to 163 cm. The cardinal start cell's Z reads 20 to 45 cm above where he stands (from Z -947 to -975, his feet -990 to -995), so the planner saw a rise of 124 to 143 and chose a single jump; when the start cell read -997 to -1000 (rise over 164) it chose a double jump. Apex only +16 to +28 over the level; nearest approach 56 to 65 cm from the cell with his feet 97 to 162 cm under it: he reached the face before he was over the lip and fell back to the takeoff (`from_takeoff_dz` -12 to +4). Same edge, same takeoff height: single jump 5 of 12 landed (one of them perched), 7 real falls; double jump 6 of 6 landed (Fisher p = 0.04). Takeoff_off (3 to 49) and toward (0.19 to 0.78) do not separate the single jumps that landed from those that fell; two of the falls (53, 137) were at 680 cm/s, a sprint not dropped.

```
18:20:28Z verdict=missed why=off_height act=jump rise=131 run=100 k=2/2 from=(16400,174600,-963) to=(16400,174500,-832) takeoff=(16448,174609,-990) takeoff_off=49 v0=(-442,-84,0) v0h=450 toward=0.19 air=0.91 apex=+20 nearest=59@-152 at=(16362,174543,-993) feet_dz=-160 from_takeoff_dz=-2 off=58 floor=-995 floor_nz=0.97
19:23:13Z verdict=missed why=off_height act=jump rise=141 run=100 k=2/2 from=(16400,174600,-973) to=(16400,174500,-832) takeoff=(16419,174597,-992) takeoff_off=19 v0=(-357,-248,0) v0h=435 toward=0.57 air=0.91 apex=+19 nearest=56@-150 at=(16376,174551,-991) feet_dz=-159 from_takeoff_dz=+1 off=56 floor=-994 floor_nz=0.97
```

**M3, sideways run-up.** Six in the base window (toward -0.07 to 0.25 at 300 to 450 cm/s; 2 falls), which 3932462 removed. After it, one more (19:25:58Z, 283 cm/s, cos 0.35 to the landing from where he pressed): no `jump run-up` line came before it, nor before row 137 of M2 (680 cm/s, cos 0.17). The rule should have fired on both; it did not, and both fell. No "still sideways ... jumping anyway" line exists: every one of the 49 turns came straight within 0.6 s.

```
18:25:10Z verdict=missed why=far act=jump rise=148 run=141 k=5/5 from=(13500,172100,-950) to=(13600,172000,-802) takeoff=(13473,172081,-951) takeoff_off=33 v0=(340,295,0) v0h=450 toward=0.07 air=0.84 apex=+31 nearest=140@-38 at=(13681,172172,-820) feet_dz=-18 from_takeoff_dz=+131 off=190 floor=-863 floor_nz=0.92
19:25:58Z verdict=missed why=off_height act=jump rise=136 run=141 k=3/4 from=(14300,170400,-641) to=(14400,170500,-505) takeoff=(14263,170386,-646) takeoff_off=40 v0=(246,-139,0) v0h=282 toward=0.27 air=0.88 apex=+39 nearest=117@-106 at=(14461,170406,-629) feet_dz=-124 from_takeoff_dz=+17 off=113 floor=-636 floor_nz=0.99
```

**M4, near the cell then off it (to=(13800,172300,-769)).** Row 64 passed 25 cm from the cell 25 cm over it and ended 186 cm away, 105 cm under; row 154 ended 265 cm away, 85 cm under. The floor past this cell slopes away (the seven `over` landings here rest 43 to 57 cm under the cell with the floor 88 to 98 cm under the capsule's centre, nz 0.89 to 0.92).

```
18:52:28Z verdict=missed why=far_and_off_height act=jump rise=147 run=100 k=2/2 from=(13800,172400,-916) to=(13800,172300,-769) takeoff=(13755,172421,-911) takeoff_off=50 v0=(123,-58,0) v0h=136 toward=0.43 air=1.21 apex=+38 nearest=25@+25 at=(13646,172195,-874) feet_dz=-105 from_takeoff_dz=+37 off=186 floor=-880 floor_nz=0.89
19:24:43Z verdict=missed why=far_and_off_height act=jump rise=147 run=100 k=3/3 from=(13800,172400,-916) to=(13800,172300,-769) takeoff=(13788,172403,-913) takeoff_off=13 v0=(-266,-361,0) v0h=448 toward=0.80 air=1.09 apex=+49 nearest=69@-51 at=(13633,172094,-853) feet_dz=-85 from_takeoff_dz=+59 off=265 floor=-885 floor_nz=0.90
```

**M5, double jump short of the level (apex under the cell).** Diagonal double jumps with a true rise of 254 to 269 (the 307 cm `env.djump` is not reached on a 141 cm run): 3 of 3 failed (18:58:46Z route_changed and 18:58:49Z at one edge, 19:36:43Z in play). One more, 19:20:32Z, rose 127 cm and was judged on the ground at the takeoff height 0.25 s later, which gravity does not allow: a position snap (server correction?), not a jump.

```
18:58:49Z verdict=missed why=far act=djump rise=254 run=141 k=2/5 from=(16300,174500,-998) to=(16200,174400,-743) takeoff=(16309,174547,-998) takeoff_off=47 v0=(0,0,0) v0h=0 toward=- air=0.99 apex=-13 nearest=146@-27 at=(16278,174507,-776) feet_dz=-33 from_takeoff_dz=+222 off=132 floor=-781 floor_nz=0.92
19:36:43Z verdict=missed why=far_and_off_height act=djump rise=269 run=141 k=10/12 from=(6900,186500,-3485) to=(7000,186400,-3216) takeoff=(6877,186522,-3474) takeoff_off=31 v0=(338,-298,0) v0h=450 toward=1.00 air=1.25 apex=-73 nearest=145@-204 at=(6895,186496,-3478) feet_dz=-262 from_takeoff_dz=-4 off=142 floor=-3491 floor_nz=0.77
```

**M6, pressed from the level below.** 19:04:34Z, right after a 45 s fight pause: the takeoff was 23 cm (2D) from the start cell but 160 cm under it, so the true rise was 313. The takeoff test is 2D only. One line.

```
19:04:34Z verdict=missed why=off_height act=jump rise=152 run=141 k=2/9 from=(15500,174400,-770) to=(15600,174300,-617) takeoff=(15518,174386,-930) takeoff_off=23 v0=(-40,-144,0) v0h=149 toward=0.49 air=0.88 apex=-149 nearest=123@-276 at=(15525,174389,-930) feet_dz=-313 from_takeoff_dz=-0 off=116 floor=-933 floor_nz=1.00
```

**M7, judge strict (no fall).** 78 cm above the cell at 137 cm on a 51° floor (nz 0.63); 70 cm above at 133 cm after a double jump. Both on or over the upper level, just past the window.

```
18:36:38Z verdict=missed why=far_and_off_height act=jump rise=98 run=100 k=4/4 from=(14200,170400,-668) to=(14200,170500,-569) takeoff=(14189,170414,-656) takeoff_off=18 v0=(10,450,0) v0h=450 toward=1.00 air=0.62 apex=+94 nearest=12@+44 at=(14217,170636,-492) feet_dz=78 from_takeoff_dz=+164 off=137 floor=-510 floor_nz=0.63
19:26:51Z verdict=missed why=far_and_off_height act=djump rise=201 run=141 k=2/2 from=(13700,172300,-878) to=(13800,172200,-677) takeoff=(13739,172331,-887) takeoff_off=49 v0=(-113,-90,0) v0h=145 toward=-0.11 air=1.05 apex=+113 nearest=6@+92 at=(13915,172135,-606) feet_dz=70 from_takeoff_dz=+281 off=133 floor=-613 floor_nz=0.89
```

### Diagonal against straight

| since the run-up | tried | missed | real falls |
|---|---|---|---|
| jump, diagonal (run 141) | 35 | 2 | 2 (6 %) |
| jump, straight (run 100) | 66 | 19 (12 Doric) | 6 (9 %) |
| djump, diagonal | 13 | 3 | 1 |
| djump, straight | 26 | 1 | 1 |

All windows: diagonal single jumps 5 falls in 44, straight 10 in 78. The diagonal effect of the research note (29 % against 11 %, before the run-up and the line) is not in today's data. The diagonal falls left each have another cause (M3, M5, M6). Diagonal double jumps fail only at true rises over 250 (M5).

## 3. The one change for real falls: press a jump up from a standstill

**The finding.** Split by his speed at the press, single jumps:

| v0h at the press | tried | missed (current judge) | real falls |
|---|---|---|---|
| under 100 cm/s | 40 | 0 | 0 |
| 100 to 300 cm/s | 13 | 4 | 4 |
| 300 cm/s and over | 69 | 28 | 11 |

Since the run-up: 34 / 0 / 0 against 67 / 21 / 8. Falls 0 of 40 against 15 of 82 for all faster presses (Fisher p = 0.0066 against the 69 at 300 and over; misses 0 of 40 against 28 of 69, p < 0.0001). Standing presses cover every rise band: under 100 cm 15, 100 to 130 13, 130 to 150 6, 150 and over 6, all landed. At the one cell tried both ways, Doric, the standing presses (from the far bench) landed 11 of 11 at a real rise of about 160, the running ones 0 of 12 (one, diagonal at 412 cm/s, landed at the lip). Double jumps from a standstill: 35 tried, 2 missed, 1 fall (the 0.25 s position snap).

Why speed hurts, from the measured envelope (JumpZVelocity 808, gravity 1813, apex 180 at 0.45 s): at a true rise of 160 his feet are over the lip only from about 0.30 to 0.59 s after the press. At 450 cm/s the face, 50 to 100 cm ahead, is reached at 0.1 to 0.2 s, still under the lip (M2: nearest 56 cm at -150), and a narrow top is crossed in about 0.3 s, so he is past it before he comes down (M1: 160 cm past). From a standstill he rises in place and air control carries him onto the top at the apex.

**The change.** At a typed jump up (act `jump`, rise over the step), when his horizontal speed at the takeoff is over about 100 cm/s, he stops pushing (no input, facing the landing) for up to about 0.5 s and presses once he is under 100 cm/s, then steers at the landing in the air as now; logged `move: jump run-up: stopping first (... cm/s)`. It is the run-up rule (3932462) made about speed, not only heading: the heading rule turns him and then presses at full speed, and straight runs at full speed still missed 12 of 12 at Doric. A player does the same at a chest-high ledge: walk up, stop, jump. Cost: about 0.25 s of braking per jump up. To check in move.lua before writing it: how the tick treats a steer that returns without input (whether he brakes or coasts), and that the stuck window (1 s, 50 cm) does not count the stop.

**What it should remove.** Of the 11 real falls since the run-up, 8 were single jumps pressed at 100 cm/s or more (M2 4, M1 1, M3 1, M4 1, M6 1; M6 also needs the takeoff to test height); the other 3 are double jumps (M5). Of the 24 strikes since the run-up, 21 were single jumps pressed at speed (all 12 of M1). Expected on the course: real falls 6 of 62 paths (10 %) to about 2 %; paths with a strike 13 of 62 (21 %) to about 5 %. Named number: paths with a strike, 21 % to 5 %: `tools.ab need 0.21 0.05` = 69 paths a side, about 7 passes (judge2 gave 62 paths in 6), one window. Falls 10 % to 1 % needs 100 a side.

**Against.** The standing presses are mostly a path's first edge (37 of 40 at k=2: he stood next to the jump after a placement or a re-plan), and they sit at partly different cells from the running ones, so place is part of the contrast; only Doric has both. Standing presses at the hill-east face itself have never been tried. The prediction can fail there; the window will show it.

**The others, ranked by falls removed since the run-up:**
1. Standstill press (above): 8 of 11.
2. Double jump when the true rise from his feet is over about 140 cm (at the press, or the planner reading the lowest floor of the start cell): 4 of 11 (M2). Same-edge evidence 6 of 6 against 5 of 12. Does nothing for Doric, whose landing cell reads low.
3. Landing cell floor read under the capsule (research note change 4: four traces at the capsule radius, the highest walkable): turns Doric into a 164 cm rise, so it would get a double jump (and from a run it would still overshoot); 1 fall by the cell's Z, 12 strikes.
4. No diagonal jumps up (research rule 2): at most 2 single-jump falls and the 2 M5 double jumps (whose cause is reach, not angle). Not supported by today's split.
5. Run-up thresholds (cos 0.7, 150 cm/s, 0.6 s): nothing to tune. Every turn finished inside 0.6 s, aligned runs miss as much (Doric), and the two sideways falls after 3932462 had no run-up line at all: find why the rule did not fire at 19:21:03Z (680 cm/s, sprint still on) and 19:25:58Z (283 cm/s, after a fight pause) before touching its numbers.
6. Takeoff point (`takeoff_off`): medians 23 cm (falls), 34 cm (misses), 28.5 cm (landed): no signal.
7. Takeoff height test (press only with his feet within a step of the start cell): 1 (M6).

## 4. 61412a5 against its keep rule

Keep if slope-range jumps (rise at most 0.9 x run) fall back in under 51 % of tries and the course's paths with a strike are under 10 %; bin if they fall back in 51 % or more over 20 tries.

| | tried | missed (current judge) | real falls (rule C) | back at the takeoff level |
|---|---|---|---|---|
| slope-range jumps, all windows | 41 | 12 | 1 | 12 (29 %) |
| of them at Doric (rise 71 to 78) | 25 | 12 | 1 | 12 (48 %) |
| of them elsewhere (rise 84 to 114) | 16 | 0 | 0 | 0 |

- Fall-back share: 12 of 41 (29 %), under 51 % over more than 20 tries. The bin condition is not met.
- Paths with a strike: 13 of 62 (21 %) under the current judge in judge2, over 10 %. The keep condition is not met either.
- The only slope-range failures are Doric, and that edge is not a slope: the floor 40 cm from the cell is 86 to 92 cm higher (a face of about 65°). 61412a5 made it a jump, which is right; the planner's cell height makes it look like a slope-range rise. No evidence today that 61412a5 picked a jump where a walk would do.
- So 61412a5 stays, undecided. If the standstill press lands Doric, both conditions should be met in the same window (slope-range fall-back near 0, strikes near 5 %), and it can be kept on that window's counts.

## Limits

- 172 lines from four short windows on six legs; legs repeat one place and paths in a leg are not independent, so the p values are optimistic.
- "Real fall" is measured against the cell's Z, which is wrong at Doric (M1): by the real top, 11 more of today's misses ended at the takeoff level.
- The standing against running contrast is partly place (see Against).
- Window boundaries come from `travel_ladder.jsonl` timestamps; the one 19:36Z line is from play, not the course.
- `toward` in the line is measured against the start cell to the landing, while the run-up rule measures from where he stands; the two differ by up to about 0.3 when he is off the start cell's axis.
