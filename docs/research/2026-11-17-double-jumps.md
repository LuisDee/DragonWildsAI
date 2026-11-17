# Double jumps up: why the 2.5 to 3 m ones miss in play (2026-11-17)

Offline study for goal item 2 (`docs/GOAL-2026-11-17-long-jobs.md`), following `2026-11-17-jump-untuned.md`. Nothing ran on the game, client, server or brain. No repo file but this one was written. Data:
- all 89 `move: jump verdict=... act=djump` lines in `logs/client/client.log`. The line exists only since 2026-11-17 18:18Z, so nothing earlier has one.
- the `move:` lines around each miss.
- `tools.jump_stats` outcomes for the path-level counts since 2026-11-16.
- `tools.jump_untuned` spans to split course, brain play and other (harness walks).
- `client_io/events/traversal.jsonl`.
- `client_mod/scripts/move.lua`.

Terms:
- **max rise**: his highest feet over the takeoff, `apex + (to.Z - takeoff.Z)`. The line's `apex` is relative to the landing cell.
- **true rise**: `to.Z - takeoff.Z`.
- **fast**: pressed at 300 cm/s or more.
- **slow**: pressed under 150 cm/s.

## 1. How many, where

| where | djump lines | landed | missed | route_changed |
|---|---|---|---|---|
| jump course windows | 80 | 60 | 18 | 2 |
| brain play | 5 | 2 | 3 | 0 |
| other (harness walks, 19:36 to 19:40Z) | 4 | 2 | 2 | 0 |

By true rise of 240 cm or more:
- **Course: 8 lines, and none was pressed faster than 0 cm/s.**
  - Six were at one 248 cm edge, (158,1750,-12.5) to (159,1749,-10.0), always the path's first edge after the teleported start. 6 of 6 landed.
  - Two were at hill east, a 255 cm edge from a standstill. 0 landed: max rise 103 (route_changed) and 242.
- The course's 9 fast djumps are all at hill east with a true rise of 159 to 166 cm (single-jump height, 160 cm of spare reach). 7 of the 9 landed.
- **So the course has never pressed a djump of 2.4 m or more after a walk.**
- Play and other, rise of 240 cm or more: 9 lines, 4 landed.

Path level, since 16 Nov (`jump_stats`): 269 djump edges were tried. In brain play before the verdict line (16 Nov to 17 Nov 18:18Z), 85 rose 245 cm or more: 66 landed, 19 missed, 13 real falls (rule C). The busiest place is the windmill-hill 3 m edge (156,1744,-9.3) to (157,1743,-6.3): 23 tried, 7 missed, 6 real falls, 22 of them after a walk.

## 2. Is 2.5 to 3 m within his double-jump reach? Yes, with 25 to 75 cm to spare

- Full flights (landed, air at least 1.0 s): max rise 298 to 325 cm in 59 of 61, median 323. From a standstill the median is 324 (n = 48).
- Every landed djump at 300 to 306 cm landed: 3 of 3 (19:37:56Z, 19:40:35Z, 19:57:53Z).
- The planner allows up to `env.djump` = 307 (`data/envelopes/Claude.json`, `dj_up_m` 3.07).
- From the envelope (JumpZVelocity 808, gravity 1813, second press at `dj_delay_s` 0.4 s):
  - At the second press he is at 178 cm and still rising at 83 cm/s. The press sets vz to about 725 cm/s, and the apex comes at 0.80 s.
  - **His feet are over a 250 cm lip only from 0.52 to 1.08 s after the first press, and over a 300 cm lip only from 0.64 to 0.96 s.**
- **The second press timing is not the fault.** 0.4 s sits near the first jump's own apex (0.45 s), the moment that gives the most height, and 59 of 61 full flights reach 298 cm or more.

## 3. The misses at 240 cm or more (verdict era, outside the course)

| time (Z) | where | press | true rise | max rise | air | what happened |
|---|---|---|---|---|---|---|
| 19:36:43 | other, (69,1865) to (70,1864), 41 m from home | 450, toward 1.00 | 258 | **185** | 1.25 | rise cut: back at the takeoff 32 cm from it |
| 19:39:27 | other, (70,1864) to (71,1863) | 450, toward 1.00 | 254 | **31** | 1.01 | rise cut: down 77 cm under the takeoff |
| 20:14:55 | play L2 201046, (194,1750) to (193,1750) | 450, toward 0.99 | 296 | **128** | 0.47 | rise cut: thrown 2.9 m north-west, 20 cm under the takeoff |
| 21:30:41 | play L2 212448, (161,1912) to the arch (162,1913) | 450, toward 0.99 | 243 | 323 | 1.48 | over the narrow top at +73, down 149 cm past it at the takeoff level |
| 21:30:45 | the same arch from the other side | **0** | 255 | 304 | 1.57 | over it at +49 (4 cm from the cell), down 185 cm on the far side |

```
20:14:55Z verdict=missed why=far_and_off_height act=djump rise=295 run=100 k=7/10 from=(19400,175000,-1582) to=(19300,175000,-1287) takeoff=(19407,175012,-1583) takeoff_off=14 v0=(-446,63,0) v0h=450 toward=0.99 air=0.47 apex=-168 nearest=83@-242 at=(19195,175215,-1602) feet_dz=-316 from_takeoff_dz=-20 off=239 floor=-1607 floor_nz=0.92
19:36:43Z verdict=missed why=far_and_off_height act=djump rise=269 run=141 k=10/12 ... v0h=450 toward=1.00 air=1.25 apex=-73 nearest=145@-204 at=(6895,186496,-3478) feet_dz=-262 from_takeoff_dz=-4
21:30:41Z verdict=missed why=far_and_off_height act=djump rise=246 run=141 k=8/10 from=(16100,191200,-3159) to=(16200,191300,-2914) ... v0h=450 toward=0.99 air=1.48 apex=+80 nearest=5@+73 at=(16293,191417,-3172) feet_dz=-259 from_takeoff_dz=-15 off=149
21:30:45Z verdict=missed why=far_and_off_height act=djump rise=256 run=141 k=2/7 from=(16300,191400,-3169) to=(16200,191300,-2914) ... v0=(0,0,0) v0h=0 toward=- air=1.57 apex=+49 nearest=4@+49 at=(16106,191141,-3157) feet_dz=-244 from_takeoff_dz=+12 off=185
```

The candidate causes, one by one:
- **Sideways takeoff: no.** Toward was 0.99 to 1.00 in all four fast misses.
- **Second press timing: no** (section 2).
- **Apex short of the rise for lack of reach: no.** In the three cut flights he rose 31 to 185 cm, less than a single jump (180). Something stopped the climb, not gravity. At 20:14:55 he rose 128 cm and was down 20 cm under the takeoff 0.47 s after the press. Free flight cannot do that: rising 128 and falling 148 needs at least 0.58 s even with a ceiling at the top. So he was thrown by the face he ran into.
- **Speed decides it.**

| djumps with a true rise of 240 cm or more | tried | landed | rise cut to 242 or less |
|---|---|---|---|
| fast (300 cm/s or more) | 6 | 2 (19:37:56 at 314, 19:57:53 at 450 and toward 0.60) | 3 |
| slow (under 150 cm/s) | 10 | 8 | 1 (18:58:49, hill east 255, 242) |

All djumps, rise cut short: fast 4 of 15 (the three above, plus course 20:33:08 at 450 cm/s, cut to 111) against slow 1 of 65, Fisher p = 0.004. Landed at 240 cm or more: fast 2 of 6 against slow 8 of 10, p = 0.12 at these counts.
- **The standstill rule of 8adf80f does not apply to djumps.**
  - The rule is move.lua 3461: `local up = p.act == "jump" and not p.leap and ...`. The commit says "double jumps keep their running jump".
  - Since it was committed, every djump took off at its run-up speed, for example 20:33:08Z `jump run-up: turning to the landing first (toward=0.60 at 450 cm/s)`, then the press at v0h 450.
  - Section 2 shows why speed hurts. At a 250 to 300 cm rise his feet clear the lip only 0.52 to 0.64 s after the press. At 450 cm/s, taking off within 50 cm of the start cell with the landing cell 100 to 141 cm away, he meets the face about 0.1 to 0.2 s after the press, 40 to 150 cm up and 1 to 2 m under the lip. This is the single-jump mechanism of `2026-11-17-jump-misses-left.md` (M2: met the face under the lip; M1: crossed a narrow top before coming down), with a narrower window.
  - Course djumps were exempt from the same fault because their rises were small: at 160 cm the djump has 160 cm of spare reach.
- **The landing cell on a flank, or a narrow top: yes, at the arch (2 of the 3 play misses, one trial, two minutes).**
  - (162,1913,-29.1) is the rock arch of DISCOVERIES l.3292 (StaticMeshActor by the run-6 house; underside about 1.2 m up). The plan crossed it across its narrow width: `163,1914,-31.7 162,1913,-29.1 161,1912,-31.6` (21:30:44Z, acts `wdd`), with floor about 31.6 to 31.7 m down on both sides.
  - Both flights rose over the cell (+73, +49, 4 to 5 cm from its centre) and came down on the far side at the takeoff level. One of them was from a standstill, so speed is not the cause here.
  - Air was 1.48 and 1.57 s against about 1.40 s for a free djump back to the takeoff height, so he touched the rock on the way down.
  - The cell is one centre trace on a curved spine no 68 cm capsule stands on: the Doric class (`2026-11-17-jump-doric.md`). That study's capsule-radius landing read covers it. A standstill press does not.

## 4. Root cause

**Two causes, ranked by the misses each explains.**
1. **A djump up is pressed at walking speed.** 8adf80f slows only `act == "jump"`. At a 2.5 to 3 m rise the lip is cleared only 0.5 to 0.65 s after the press, and at 450 cm/s he reaches the face well before that.
   - Fast djumps at 240 cm or more: 4 of 6 missed (three rises cut to 31 to 185 cm, one overshoot of the arch).
   - Slow: 2 of 10 missed.
   - This explains 2 of the 3 play misses (20:14:55, 21:30:41) and both harness-walk misses.
2. **A landing cell on a narrow top** (the arch). It explains 2 of the 3 play misses (21:30:41 and 21:30:45; 21:30:41 has both causes). The Doric-class fix applies to it.

**Visibility gap (rule 4, before a second djump fix).** The verdict line does not say whether the second press fired.
- `jump_tick` presses only if `ground_check` reads airborne 0.4 s after the first press. Otherwise it waits silently until 1.2 s.
- The second press and the vz after it are not in any line, so for the three cut flights the log cannot tell "the second press never fired" from "it fired and the face ate it".
- Add `dj2=<s after the first press | none> vz2=<cm/s>` to `jump_landing_line`, from `st.jump_t2` and the velocity read `jump_tick` already makes (log only).

## 5. The smallest change, and its number

**Body (one token, one window): include djumps in the standstill press.**
- The change, at move.lua 3461:
  ```lua
  local up = (p.act == "jump" or p.act == "djump") and not p.leap and prev ~= nil and p.Z - prev.Z > step_tol(st)
  ```
- Ship it with the `dj2=` log field, which is visibility, not behaviour.
- The evidence that a standstill djump reaches 2.5 to 3 m: the 248 cm course edge landed 6 of 6 at v0h 0; 274 cm at 5 cm/s (21:27:20Z) and 302 cm at 110 cm/s (19:40:35Z) landed; the median standstill peak is 324.
- Cost: about 0.25 s of braking per djump up.

**The number:**
- djumps of 240 cm or more pressed after a walk, landed: 2 of 6 now (33 %), predicted 8 of 10 or better (the slow rate).
- `tools.ab need 0.33 0.85` = 13 a side.
- On the course leg below: real falls 26 % (play history, 6 of 23) to about 3 %, which takes 36 a side (`tools.ab need 0.26 0.03`).

It will not fix the arch: that needs the capsule-radius landing read.

**The course leg that tests it (harness, the window before the body change, no body edit).** No course leg presses a 2.4 m or higher djump after a walk, so the body change cannot be measured on today's legs.
- **`jump_hill_ledge3m_walk`**: start capsule (156.0, 1746.0, -8.82), goal (158.0, 1739.0, -5.32), the same top as `jhl_b`.
  - The start is cell (156,1746,-9.7) + 0.88. It is the first point of three play plans (16 Nov 05:58:00Z, 10:31:35Z, 11:29:15Z). All three walked 2 to 4 cells and then took the 300 cm diagonal djump (156,1744,-9.3) to (157,1743,-6.3).
  - That edge was planned 21 times and tried 23 times since 16 Nov: 7 missed, 6 real falls.
  - It sits beside the existing windmill-hill legs, 160 m from home.
- **Near home, fewer data:** (69,1865,-34.9) to (70,1864,-32.2), 258 cm, 41 m from home (`standing_trees` (100,1892)), on the walk from home to the course.
  - Start capsule (60.95, 1870.90, -35.43): the 19:36:37Z "local plan #1 ... at (6095,187090,-3543)", a straight 9-cell walk south-east.
  - Goal (70.0, 1862.0, -31.32): path end (70,1862,-32.2) + 0.88.
  - Planned only twice, both fast presses, both rises cut (185, 31). A two-jump stair via (70,1866) also exists (self edges of 10-25 and 10-26), so the planner may not take the djump.
- **Also an option:** (193,1750) of 20:14:55Z.
  - Start capsule (199.47, 1747.17, -15.43), from "local plan #1 (wall_ahead) at (19947,174717,-1543)".
  - Goal (190.0, 1747.0, -12.02).
  - A straight 5-cell walk west, then the 295 cm djump onto a 4-cell flat top.
  - One try only.

**Order (rule 11):**
1. Window 1: the legs only, on the current body. Baseline: about 2 of 3 landed at speed, with rises cut to under 190 cm in the misses.
2. Window 2: the `up` change. Number: the legs' djump misses and their cut rises go to near 0. The `slowing for a jump up` line will appear before each djump.

## Limits

- 16 djumps of 240 cm or more in the verdict era, in four places. The arch pair and the (70,1864) pair are not independent.
- The 16 Nov counts were judged by the old judge, and their press speed is unknown.
- Why the face cuts the rise (an overhang, a bulge, a walkable lip that ends the flight) is not readable from the logs. The `dj2=` field is the first step to seeing it.
- 18:58:49Z shows a standstill djump cut too (hill east, 255 cm, max 242; 18:58:46Z max 103). So the standstill press will not make every face passable.
- The play misses are three, in two trials. The 31 % untuned rate needs 30 to 50 more L2 trials to read on its own (`2026-11-17-jump-untuned.md`).
