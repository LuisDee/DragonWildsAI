# jump_doric: why it reaches 0 of 7 (2026-11-17)

Offline study. Nothing ran on the game, client, server or brain; no repo file but this one was written. Data: the 21 `jump_doric` rows of the windows `jumpcourse-judge2` (19:18-19:28Z, `logs/window_jumpcourse_1117e.txt`), `jumpcourse-standstill` (20:27-20:37Z, `...f.txt`) and `jumpcourse-arrival` (20:51-21:02Z, `...g.txt`) in `logs/evals/travel_ladder.jsonl`, and every `move:` line of `logs/client/client.log` inside each trip; all 53 `jump verdict` lines aimed at the Doric cell since 18:53Z. Engine facts: max jump 180 cm (JumpZVelocity 808, gravity 1813, DISCOVERIES l.1123), capsule radius 34 cm and half height 88 cm (l.2220), planner `env.jump` = apex - 15 = 165 cm (move.lua 660).

## Finding

There is no 0.84 m ledge. The leg's goal (109.0, 1847.0, -30.52) is the planner's landing cell (109, 1847), floor -31.38, plus 0.86 m. `jump-landings.md` section 5 built every course goal as "path end points + 0.88 m". That cell is one line trace at a point on the steep flank of a rock, and his 34 cm capsule cannot stand there. The only floor near it is the rock's top, at -30.45 to -30.53 m (normal Z 0.83 to 0.96), 41 to 49 cm south of the cell, 88 to 96 cm above the cell, and 164 to 167 cm above the takeoff. That is inside the 180 cm single jump. **He gets onto that top in 20 of 20 trips. The body says `arrived`, and the ladder fails him on height:** end dz +0.9 to +1.0 m against `tol_dz` 0.5. The go_to never ends in `goal_above`, `not arrived` or a give-up. The movement fault is underneath: the first jump, aimed at the same point on the flank, misses in 20 of 20 trips. A 1 to 3 cm margin in the judge hides most of those misses.

## Every trip, the same five steps (20 of 20; only judge2 rep 3 differs at step 5)

1. **Plan #1** (`wall_ahead`, at (106.46, 1849.46)): `local path 5 pts [wwwwj] ... pts=106,1849,-32.3 106,1848,-32.2 107,1847,-32.2 108,1847,-32.2 109,1847,-31.4`. The last edge is a single jump, (108,1847,-32.16) to (109,1847,-31.38), rise 78, straight, run 100.
2. **Jump 1, from the west.** In judge2 he pressed at 450 cm/s: 6 of 6 `missed why=far`, landing 155 to 168 cm past the cell. From the standstill window onward: `jump run-up: slowing for a jump up`, pressed at v0h 0 to 39 cm/s. All 14 passed over the cell (nearest 1 to 13 cm) with his feet 65 to 98 cm above its Z (apex +102 to +104). None came down on it. All 14 landed 94 to 122 cm past it, on the east bench (floor -32.00 to -32.06), feet 62 to 66 cm under the cell, 10 to 14 cm above the takeoff:
   ```
   21:02:14Z verdict=landed why=within ... takeoff=(10775,184694,-3214) v0h=34 toward=1.00 air=0.89 apex=+104 nearest=2@+85 at=(11010,184723,-3201) feet_dz=-63 from_takeoff_dz=+13 off=112 floor=-3204 floor_nz=0.99
   21:00:31Z verdict=missed why=off_height ... v0h=35 ... nearest=1@+87 at=(10993,184711,-3204) feet_dz=-66 ... off=94 floor=-3206
   ```
   The judge splits these 14 identical outcomes 9 `landed within` (feet_dz -62 to -65 rounded, under the 65 cm step slack) and 5 `missed off_height` (-65 to -66). The leg summaries' "strike 2, fall 2" (standstill) and "strike 3, fall 3" (arrival) are exactly those 5 misses. Judged honestly, the strikes are 14 of 14.
3. **Nav back round.** He walks from the bench round the north of the rock and stops against its face: `stuck n=1 moved=3cm d=64 src=nav me=(10897,184765,-3121)`, 63 to 66 cm north of the cell, feet -32.09 to -32.10. Nav's aim at that moment is (106.24, 1847.68), 2.7 m back west. The stuck check triggers the next plan.
4. **Plan #2** (`stuck`): `local path 2 pts [wj] ... pts=109,1848,-32.1 109,1847,-31.4`, rise 71 to 72, the same cell. Pressed from a standstill (v0=0), 63 to 66 cm from the cell. He rises straight over it (nearest 0 to 4 cm at +107/+108 in 18 of 20 trips) and comes down 41 to 49 cm south on the rock top:
   ```
   21:02:17Z move: landed 43 cm from the jump's point (allowed 130) and 93 cm off its height (allowed 65)
   21:02:17Z verdict=landed why=above act=jump rise=71 ... takeoff=(10897,184765,-3209) v0=(0,0,0) air=0.60 apex=+108 nearest=0@+108 at=(10902,184657,-3045) feet_dz=93 from_takeoff_dz=+164 off=43 floor=-3051 floor_nz=0.85
   ```
   This happened in 20 of 20 trips (`landed above`; feet 91 to 96 cm over the cell, from_takeoff_dz +163 to +167).
5. **The end.** In 19 of 20 trips this was the path's last point, and the next line is `move: arrived`. He is 0.39 to 0.49 m from the goal in 2D, inside `go_tol` 0.5, and the stand rule (`_under_ledge`) refuses only arrivals under the spot's floor, never above it. The ladder then reads end ≈ (109.02, 1846.57, -29.57): 0.4 m in 2D but dz +0.9, so FAIL. Arrival rep 0 ended at 0.50 m, and the bridge's fresh check returned `verification_failed`: same place, same cause. Judge2 rep 3 (the one PASS in these windows) walked off the top, re-planned (#3, diagonal from (108,1846) at 412 cm/s) and ended at (109.29, 1847.26, -30.51). That landing line reads `at=(10934,184736,-3149) floor=-3210`: the floor under his centre was 61 cm below his feet, so he was perched on the rock's rim, not standing on a floor.

## The three questions

- **Can one jump climb it?** The real top is 164 to 167 cm above his feet at the takeoff. A single jump reaches 180 cm (16 cm margin), and the planner allows 165. From the north, from a standstill, 20 of 20 landed on it. The 78 cm "rise" the planner and the leg use is not a real height.
- **Ledge or slope?** The cell is on the rock's flank. The centre trace reads -31.38. The floor 41 to 49 cm south is +88 to +96 (about 64° on average). The floor where his capsule stops 64 cm north (its edge about 30 cm from the cell) is -72. The bench 1 m east is -62 to -68. A capsule centred on the cell would sit inside the rock to the south. In 53 verdict lines aimed at this cell since 18:53Z, he came to rest within 65 cm of its height only once, and that time he was perched. The cell's single centre trace (`localplan.cell_floors`, one point, no capsule radius) passed `walk_z`, so the planner took a notch on the rock's face for a floor.
- **Takeoff too close or too far?** Neither decides it. The west takeoffs (13 to 43 cm off the start cell, 1.0 to 1.4 m from the cell) pass over a point that has no floor at their height. The north takeoff is 63 to 66 cm from the cell, as close as the face lets him, and 1.07 m from the top. It lands every time because the top is right behind the cell along that line.

## Root cause

The leg's goal height is the planner's misread cell height, a height no capsule stands at. He reaches the only floor there and is graded as failing by 0.9 m. Under rule 3 this is a grader fault: the 14 FAILs of the standstill and arrival windows (and 5 of judge2) are void. Underneath it is a real movement defect with the same cause: the planner aims jump 1 at that point on the flank, so the west jump always comes down on the bench or past it (20 of 20), costing about 3 s and a second jump per trip.

## The smallest change, and its number

**The leg (harness):** in `tools/travel_ladder.py` set `"jd_b": [109.02, 1846.57, -29.57]`, where he stands on the rock top (19 of 20 trips, within 0.1 m and 0.02 m of it). With the rise now 1.79 m, `_jump` gives `tol_dz` 0.9. Keep `go_tol=0.5`. The goal still snaps to planner cell (109, 1847), so the plan and the trip stay the same, and the stand rule now refuses an arrival at the foot. Rename the note "the rock by Doric (1.65 m)": the leg becomes a single jump near the edge of his reach.
**Number:** jump_doric reached, 0 of 14 now, predicted 13 or 14 of 14 (19 of 20 traced trips end on the new goal). 4 trials a side (`tools.ab need 0.05 0.9`), so one 7-pass window.

**Next window, movement (`localplan.lua`), the fix the leg change does not make:** read a jump-up landing cell at the capsule radius. Add four traces 34 cm round the centre, and when the highest walkable read is more than a step above the centre's read, take it as the cell's floor (`jump-misses-left.md`, rank 3). The cell then reads the top at a 164 cm rise, still a single jump within `env.jump` 165. **Number:** west jumps that come down on the bench, 14 of 14 now, predicted 2 or fewer of 14. Jump paths per Doric leg, 2 to 1. Leg time, 6.4 to 7.5 s to about 4 s. Risk: a 164 cm standstill jump from the west, 1.4 m from the top, has never been tried. Only the north takeoff (1.07 m) is proven. Separately, the judge's `dz < 65` cannot tell the bench (feet -62) from a 78 cm ledge. That reading, not the body, is why the strike count says 3 of 14 instead of 14 of 14.

## Limits

- 20 trips at one place, all from one teleported start, so they are not independent.
- The rock's shape is inferred from about 60 point reads (landing floors, stuck points, verdict fields), not a scan. Where exactly the -31.38 notch is and how wide is not measured.
- The predicted 13 or 14 of 14 assumes the planner's goal snaps to the same cell. If the goal falls into cell (109, 1846) instead, plan #1 changes and the trips need re-reading.
