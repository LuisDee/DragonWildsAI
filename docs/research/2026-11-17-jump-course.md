# The jump course: how to run it, how long, how many passes (2026-11-17)

The course proposed in `docs/research/2026-11-17-jump-landings.md` ("The course (no model)"), made runnable in `tools/travel_ladder.py`. Offline work only: nothing ran on the game, client, server or brain. Tests: `tests/test_travel_ladder_jumpcourse.py`.

## The legs

Six short `go_to`s, from where he stood below each of the worst jump-up places to a point on top. Starts and goals are the study's (capsule centre, m); counts are `jump_stats places` (jump-up edges tried / judged missed, 14 to 17 Nov).

| id | place | start | goal | 2D m | tried / judged missed | reached: 2D, height |
|---|---|---|---|---|---|---|
| jump_hill_rats | windmill hill, the rats (138.6, 1721.8) | 134.94, 1718.0, -7.82 | 140.0, 1721.0, -3.02 | 5.9 | 54 / 33 | 2.0 m, 1.8 m |
| jump_hill_ledge3m | windmill hill, the 3 m ledge (156.5, 1744.9) | 154.52, 1747.16, -10.91 | 158.0, 1739.0, -5.32 | 8.9 | 104 / 26 | 2.0 m, 1.8 m |
| jump_hill_mid | windmill hill, middle (159.7, 1737.2) | 156.64, 1744.61, -8.52 | 159.0, 1737.0, -3.22 | 8.0 | 29 / 20 | 2.0 m, 1.8 m |
| jump_hill_east | windmill hill, east (164.0, 1745.0) | 154.38, 1748.35, -11.36 | 164.0, 1745.0, -7.42 | 10.2 | 6 / 5 | 2.0 m, 1.8 m |
| jump_hill_top | windmill hill, top (143.1, 1705.9) | 143.97, 1703.38, -4.87 | 144.0, 1706.0, -2.72 | 2.6 | 9 / 4 | 2.0 m, 1.07 m |
| jump_doric | the ledges by Doric (110.2, 1847.5) | 106.46, 1849.46, -31.36 | 109.0, 1847.0, -30.52 | 3.5 | 36 / 18 | 2.0 m, 0.5 m |

- **Start:** the ladder's own way, the dev `teleport` fixture (server `K2_TeleportTo`), then the settle wait. A fight with the rats is waited out (`reflex_busy`) and he is placed again.
- **Reached:** the body answered ok, and the fresh end position is on top: within 2 m (2D) of the goal and within half the leg's rise in height (at least 0.5 m, at most the ladder's 1.8 m). The ladder's usual 3 m / 1.8 m test would count the Doric and top legs as reached from the foot of the ledge (their starts are 3.5 m and 2.6 m away). The body's own `go_to` tolerance is 1.5 m.
- **Guards:** before each jump leg the ladder runs `dev.guard()` again, which refuses unless the client is on the local dev server (never Shockbyte) with no live brain. If the teleport fixture refuses because another player is on, the leg is refused, recorded as ERR and not counted. The ladder's other legs walk to their start in that case, but the jump legs never do: the walk would pass the other player and add its own jumps to the counts.
- `jump_hill_east` is 10.2 m in 2D. That is past the 10 m beyond which goals get oracle routes (DISCOVERIES). It is the study's leg, kept as given. If its rows show oracle routes, shorten it.

### The real-play legs (2026-11-18)

Real (brain) play since 8adf80f: 15 strikes in 52 jump paths, from two causes the legs above never meet (study `jump_real_1118`): (a) hops under the step slack (rise 46-64 cm), 7 strikes, 6 at the pond bank by home; (b) one-cell rocks of 1-3 m he climbs and drops off instead of walking round, 6 of the 8 real falls. Starts are the client log's plan lines' own position (capsule centre), goals the path end + 0.88 m, so the local planner meets the same edge. No move.lua or localplan.lua change came with them (rule 1).

| id | real paths it reproduces | start | goal | reached |
|---|---|---|---|---|
| jump_pond_bank | 18 Nov 10:48:54Z, 11:00:30Z, 14:46:27Z: `[wwwjwww]` hop 161,1915,-31.9 to 160,1914,-31.3 (rise 63) mid-path, pressed 1.0-1.24 m early at 216-230 cm/s | 162.79, 1914.44, -30.88 | 157.0, 1911.0, -30.82 | through: 2 m, 0.5 m (`past`) |
| jump_pond_top | 18 Nov 11:16:54Z, 13:50:07Z: `[wwwj]` from the dip 157,1914,-32.0 onto 157,1915,-31.4 (rise 61) at 450 cm/s, overshot 1.7-1.8 m | 159.21, 1911.83, -30.74 | 157.0, 1915.0, -30.52 | on top: 2 m, 0.5 m over the dip (`foot`); go_to circle 0.5 m |
| jump_rock_cell | 17 Nov 21:30:43Z: `[wddwwww]` djump 256 from a standstill onto the rock arch 162,1913,-29.1, then off to 161,1912 | 163.20, 1913.95, -30.81 | 157.0, 1912.0, -30.92 | through: 2 m, 0.5 m (`past`) |
| jump_rock_step | 18 Nov 13:35:11Z: `[wdw]` djump 230 from a standstill onto 152,1921,-30.4, step off to 153,1920 | 150.67, 1920.94, -31.85 | 153.0, 1920.0, -30.12 | 2 m, 0.87 m; go_to circle 0.5 m |

A `past` leg's goal lies beyond the hump or rock at about the start's level: reaching it says nothing of the jump; the strike and fall counts (`jump_stats`) are the measure. A player walks round the rock (human_m 8 and 4).

```
.venv\Scripts\python.exe -m tools.travel_ladder --only jump_pond_bank,jump_pond_top,jump_rock_cell,jump_rock_step --repeat 5 --label jumpcourse-real
```

## The command

On a named world (rule 9), with the brain stopped and the live lock free:

```
.venv\Scripts\python.exe -m tools.travel_ladder --only jump_hill_rats,jump_hill_ledge3m,jump_hill_mid,jump_hill_east,jump_hill_top,jump_doric --repeat 5 --label jumpcourse
```

After the usual per-leg lines and the summary, the ladder prints a jump summary from `tools/jump_stats.py`. It reads the client log and `traversal.jsonl` and counts only paths planned during a leg's `go_to`: placements and fights between legs are left out. It prints:
- legs with a jump up, legs with a strike, and legs with a real fall;
- paths with a jump up, paths with a strike (as judged now), and paths with a real fall (jump_stats rule C: he came down no higher than the takeoff plus the step);
- the counts of the `move: jump verdict=` lines (these read "none" until the line is in move.lua);
- a line per leg.

The run's counts also go into its summary row (`jump_course`). The same summary is then printed again over every run with the same `--label` so far, so you can see when a side has its 121 paths. Use one label per side, for example `--label jumpcourse-before` and `--label jumpcourse-rule1`.

A strike makes the mover plan again, so a judge with more strikes also produces more paths. The leg count does not move with the judge, so compare both numbers.

## How long one pass takes

From the ladder's own records (`logs/evals/travel_ladder.jsonl`):
- **Between legs:** 4.3 s median (teleport, settle and rest check; n = 102, quartiles 4.2 to 4.4 s).
- **Short obstacle legs:** `obstacle_doric` and its reverse (9.3 m) took 3.0 s and 4.0 s.
- **Jump paths at these places:** in the client log they last 1 to 3 s each (median, by place), and each miss adds about 1.5 s of cooldown and a re-plan.

So a clean leg is about 8 to 12 s and one pass of six legs about 1 to 1.5 min. Add up to 45 s plus a second teleport when the rats start a fight. Plan on about 2 min a pass, so `--repeat 5` is about 10 min.

## How many paths with a jump up a pass gives, and how many passes

The study's path-level counts are paths whose jump-up landing is in each place's 5 m cluster, with how many were judged missed. Expected jump paths per leg take a miss to start another plan, up to three:

| leg | paths at the place / judged missed | miss rate | expected jump paths per leg (1 + m + m²) |
|---|---|---|---|
| rats | 82 / 33 | 0.40 | 1.56 |
| ledge3m | 118 / 29 | 0.25 | 1.31 |
| mid | 81 / 20 | 0.25 | 1.31 |
| east | 9 / 6 | 0.67 | 2.11 |
| top | 33 / 4 | 0.12 | 1.14 |
| doric | 42 / 22 | 0.52 | 1.80 |
| **one pass** | | | **about 9** |

The floor is 6 per pass (one jump path per leg, every leg with a jump). A leg that goes round the ledge on a remembered route gives none. So 121 paths a side (`tools.ab need 0.3 0.15`) takes about 14 passes at 9 a pass and about 21 at 6. That is three to four runs of `--repeat 5`, about 30 to 40 min a side. In legs, about 20 passes give 120 legs, the same order. The first run measures the real yield: read "every run labelled ..." after each run and stop the side when paths with a jump up reach 121.

## Limits

- The per-pass yield is an estimate from 14 to 17 Nov traffic at these places, not from course runs. The place mix and the routes he remembers may differ.
- The paths inside one leg are not independent. Neither are legs that repeat one place, so the p values from `tools.ab two` are optimistic.
- The times come from two short obstacle legs and the jump paths' own durations, not from a jump course run.
