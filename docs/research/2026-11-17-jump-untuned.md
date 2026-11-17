# Jump landings in real play: the untuned rate beside the course's (2026-11-17)

Goal item 2 (`docs/GOAL-2026-11-17-long-jobs.md`): paths with a landing judged missed under 10 %, and the untuned rate
reported beside the tuned one. The tuned figure is the jump course (`tools/travel_ladder.py` legs): 5 of 69 (7 %) in
`logs/window_jumpcourse_1117f.txt` and 4 of 77 (5 %) in `..._1117g.txt`, together 9 of 146 = 6 % (95 %: 3 to 11 %).
This note measures the same figure in brain-run play.

Tool: `.venv\Scripts\python.exe -m tools.jump_untuned` (new, read only; `--since`, `--until`, `--outside`).

## How it was counted

- Same counting as `travel_ladder.jump_course_summary`, per path, with the functions of `tools/jump_stats.py`: a path
  with a jump up (`jump_path`: a jump, leap, superjump or double jump edge that rises), with a strike (the path holds a
  landing judged missed, `path.miss`, as judged at the time), with a real fall (any of its jump-up edges a strike under
  rule C, `strike_under(o, 3)`: he came down no higher than the takeoff plus the step). Self edges from
  `client_io/events/traversal.jsonl` as there.
- Brain play: only paths inside a brain session, from a `logs/brain-live-*.jsonl` file's first to last stamped row
  (+30 s). That holds the L2 job trials (`logs/evals/job_runs.jsonl`: 19:52Z, 20:10Z, 21:19Z, 21:24Z) and the earlier
  Ratcatcher step trials and other brain runs.
- Left out: every path inside a jump course window (`travel_ladder.jsonl` labels `jumpcourse-*`: base 18:13 to 18:26Z,
  runup 18:33 to 18:43Z, judge 18:52 to 19:05Z, judge2 19:16 to 19:28Z, standstill 20:25 to 20:37Z, arrival 20:49 to
  21:02Z; 2 min before and 1 min after each), and paths outside any brain session (harness walks to a trial's start
  place, hand probes; counted apart below).
- Period boundaries are the commit stamps; the first log line each change writes agrees with them:
  - run-up 3932462, 18:33:04Z (first "move: jump run-up: turning to the landing first" 18:33:34Z);
  - the whole judge, 874f73d 18:51:57Z, ee6a78b 19:11:12Z and efd12e3 19:16:14Z (first why=over 18:52:45Z);
  - the standstill press 8adf80f, 19:56:52Z. Its first "slowing for a jump up" line is 20:25:36Z, in the course. Between
    19:56:52Z and 20:25Z brain play pressed no single jump up over the threshold: the 20:09Z and 20:12Z jumps rose 66 and
    68 cm (the next, 69 cm at 21:25:49Z, was slowed), and double jumps keep their running jump by design. The client also
    reloaded at 20:08:34Z. So 19:56:52Z and 20:25Z give the same split.
- The brain session still running at the time of writing is counted up to about 21:32Z.

## Result

| period (brain play) | paths | with a jump up | with a strike (judged missed) | with a real fall (rule C) |
|---|---|---|---|---|
| 14 Nov to 61412a5 (13:56Z), older planner, for context | 1258 | 414 | 135 = 33 % (28 to 37 %) | 83 = 20 % (16 to 24 %) |
| before the run-up (61412a5 13:56Z to 18:33Z), old judge | 75 | 29 | 13 = 45 % (28 to 62 %) | 5 = 17 % (8 to 35 %) |
| run-up, before the whole judge (18:33 to 19:16Z) | 0 | 0 | none: no brain play | none |
| whole judge, before the standstill press (19:16 to 19:57Z) | 10 | 0 | none: no jump up | none |
| after the standstill press (19:57Z on) | 65 | 13 | 4 = 31 % (13 to 58 %) | 4 = 31 % (13 to 58 %) |
| jump course after the standstill press (f + g), tuned | 176 | 146 | 9 = 6 % (3 to 11 %) | 9 = 6 % (3 to 11 %) |

Intervals are Wilson 95 % (`tools/ab.py`). Before against after in play: strikes Fisher p = 0.50, real falls p = 0.42,
not told apart. Untuned after against the course after: strikes 4 of 13 against 9 of 146, p = 0.013. Before 18:52Z a
strike was judged by the old judge, which counted landings that passed over the cell as misses (874f73d), so the strike
column before and after is not one measure; the real fall column is.

Paths outside brain play (harness walks and hand probes, model-free but not course legs): 19:16 to 19:57Z, 8 with a jump
up, 5 with a strike, 2 with a real fall (19:36 to 19:40Z); after 19:57Z, 6 with a jump up, 1 strike (21:23:42Z, a 46 cm
gap jump pressed at 270 cm/s, why=far), no real fall.

## What the four misses after the changes were

| time (Z) | trial | edge | rise | press speed | verdict |
|---|---|---|---|---|---|
| 20:14:55 | 20261117-201046-L2 | double jump | 295 cm | 450 cm/s | missed, far_and_off_height, apex -168: came down 316 cm under the cell |
| 21:29:08 | 20261117-212448-L2 | single jump, from a standstill (slowed from 270) | 100 cm | 86 cm/s | missed, air 0.33 s, apex +25: did not rise onto the ledge, stayed at the takeoff |
| 21:30:41 | 20261117-212448-L2 | double jump | 246 cm | 450 cm/s | missed, far_and_off_height, 259 cm under the cell |
| 21:30:45 | 20261117-212448-L2 | double jump, the same ledge again | 256 cm | 0 cm/s | missed, far_and_off_height, apex +49 (rose 49 cm against a 256 cm rise), 244 cm under the cell |

- Three of the four are double jumps of 246 to 295 cm. Neither the run-up nor the standstill press touches a double jump,
  and the course has few of them (jump_hill_rats, 174 cm). After the changes: single jumps up, 5 paths, 1 strike (3 tried,
  2 landed); double jumps, 8 paths, 3 strikes (5 tried, 2 landed).
- The three strikes of 21:29 to 21:31Z fall in one trial and two minutes, two on one ledge near (162, 1913, -29). The
  paths are not independent; by trial it is 3 trials with a jump up, 2 of them with a strike.

## Is the play after the changes enough to judge?

No. 13 paths with a jump up in about 45 minutes of brain play (three L2 trials) give 31 % with an interval of 13 to 58 %.
That is above 10 % at face value, but three of the four strikes are one trial's two minutes on one ledge.

- To show the untuned rate under 10 % if it is really the course's 5 to 6 %: about 130 to 200 paths with a jump up, so
  about 115 to 190 more (Wilson upper bound under 10 %). At the L2 rate of about 4 jump paths a trial, that is 30 to 50
  trials.
- To tell untuned play from the course (31 % against 6 %): `tools.ab need 0.31 0.06` = 37 paths a side, so about 24 more.
- To tell 30 % from 10 %: `tools.ab need 0.3 0.1` = 62 a side, about 49 more.

The double jump is the open item that play shows and the course does not exercise: a course leg with a 2.5 to 3 m double
jump (the ledge near (162, 1913) of 21:30Z, and (194, 1750) of 20:14Z) would make the tuned figure cover it.
