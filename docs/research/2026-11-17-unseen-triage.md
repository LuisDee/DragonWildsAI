# The unseen ledger against the logs (2026-11-17)

What the existing logs already prove for each of the 20 open rows of `docs/unseen_fixes.jsonl`, and the smallest confirm window for the rest (CLAUDE.md section 2, rule 12). Offline only: nothing was run on the body, no model call was made, the ledger was not changed. The main session applies the verdicts with `tools.unseen confirm|bin`.

Sources: `logs/client/client.log` (UTC stamps), `logs/brain-live-*.jsonl` and `logs/brain-20261117.jsonl` (epoch `ts`), `logs/evals/quest_runs.jsonl`. Logs read up to 17:47Z, so the rung4 gate that ran 17:18Z to 17:25Z is included. Scratch reader: `tools/unseen_triage_scan.py` (a regex, a time, the rows after each match). Counts of the 61412a5 jumps come from `lp_jumps.py` in the session scratchpad.

## Verdicts

Summary: **10 confirm, 0 bin, 9 live, 1 decided by goal item 2.** Every fix's code is still in HEAD; none was superseded.

| sha | area | verdict | evidence or trigger | count |
|---|---|---|---|---|
| c2a9835 | explore find in sight; interact magnet pickup | **confirm** | both halves ran once, each followed by the intended outcome (E1) | 1 + 1 |
| 235f401 | craft: reopen a closed station menu | **confirm** | every reopen was followed by the craft finishing ok (E2) | 4 of 4 |
| 4df3901 | craft: his station leftovers kept on disk | **confirm** | after a client boot he took his own leftover out of a fire and cooked (E3) | 1 |
| 62d7fc7 | move: arrival in water over a pond-bed spot | **confirm** (water half) | two harness walks to a start spot under water were verified and the trial went on (E4). The failed-arrival words were never produced | 2 |
| eb68bfb | look: map names only when fuller | **confirm** | 10 trials looked at Vannaka's spot; 20 Ash Logs and 10 Lore Item rows kept their names; the 2 renames made were right (E5) | 10 looks, 0 wrong |
| 46c0ca9 | combat: camera on the attacker for a block | **confirm** | 57 blocks began turned over 60 deg away; 49 were facing it by the hit and blocked or parried; 6 of the 7 still turned away were hit (E6) | 93 blocks |
| d5f57ad | combat: camera on the swing target | **confirm** | swings over 45 deg off: 12 of 33 before, 58 of 393 after (p = 0.005); swings that did not hit: 17 of 33 against 92 of 393 (p = 0.001) (E7) | 393 swings |
| 13959e8 | bridge: state read anew after an action | **confirm** | first state after a talk that moved a quest on showed the new step 168 of 168 after, 100 of 221 the day before; no `client_module_error` (E8) | 168 |
| 93ec959 | move: chase budget, ground made good | **confirm** (aggregate, no line of its own) | "keeps moving away faster than I can catch up" in 3 of 28 attacks in the two days before, 0 of 90 after (p = 0.012). The 3 `chased_s` replies after were true path_blocked on the hill (E9) | 90 attacks |
| c835589 | move: take off where he stands | **confirm** (takeoff part) | 3 takeoffs at the hill ledge (14262,170558); all 3 got him past it within 6 s, 1 after a re-plan (E10). The stall-reason part has no line | 3 |
| 02d2cfd | tools: player list in a player argument | **live** | ran in every prompt since (107 hits). Give-to-NPC in Getting Started: 7 of 38 runs before, 0 of 17 after, p = 0.086, not yet told apart. Trigger: `gs_start` k=5 | 0 of 17 |
| 1cffdc4 | craft: name every missing input | **live** | never ran: no craft short of two inputs since. Only the fresh chain's bag (4 Stone, no logs) does it, 2 of about 25 runs. `gs_start` bags are short of Ash Logs only. Trigger: a direct `craft` probe | 0 |
| 07f1cb3 | buildables: what can_build_now hides | **live** | never ran: no `buildables` call since 16 Nov 21:02Z. Trigger: a direct `buildables` probe | 0 |
| c96dc9e | goal keeps the queued request | **live** | 13 goal ends since, all 13 carry the request, but in all 13 the goal started straight after `start_goal` (no body-only run in between), so the fixed case never came. Needs a log line first | 0 |
| c9fb8ff | brain: told when back in the world after a drop | **live** | no drop since the commit. The ledger regex can never match (see below) | 0 |
| e5b851c | move: resumed walk to a target the fight killed | **live** | 7 walks resumed after a fight since; all 7 arrived (their targets were places). The fixed case did not come. Needs a log line to be specific | 0 |
| f1108be | situation: "Creatures: none in sight within 50 m" | **live** (a rate) | 14 prompts carried the line; none was followed by `attack` (talk, go_to, craft, gather). Only 1 was a hunting decision (11:40:04Z, run 113957: go_to "Windmill Area"). 18 attacks since, 1 on a name not in a non-empty list. Telling 17 % from 2 % takes about 59 empty-list decisions | 14 exposures |
| 82a9824 | brain: run_skill that cannot start | **live** | no `run_skill` call at all since. A rare model slip (1 run in about 250); no quest step reaches it | 0 |
| d6f9e8a | talk/interact: bag read at the press | **live** | "no conversation opened" never came. 17 interact presses since gave plausible gains, but the bag-at-the-press half has no line. Trigger: a talk held up by a fight (about 1 in 60 Rune Mysteries trials) | 0 |
| 61412a5 | localplan slope rule | **decided by goal item 2** | counts reproduced below | 16 paths |

### Ledger fixes the main session may want (not made here)
- **c9fb8ff's regex is broken.** `now\?": \?"back in the game world` asks for a literal `?` after `now`, so it matches nothing. Tested on `"now": "back in the game world"` and its escaped form: no match. Use `back in the game world` (log brain).
- **e5b851c's words are shared** with c835589's walk to a thing that is gone. To count only the resumed case, log a client line where the resumed walk starts with `st.seen_before` set (`client_mod/scripts/move.lua`, the line `st.seen_before, opts.resume_seen = opts.resume_seen, nil` in `go_to`), for example `move: resumed walk had seen its target (<kind>)`, and point the row at it.
- **c96dc9e has no line of its own.** Add a brain row in `brain/agent.py` where `asked, self._pending_asked = self._pending_asked or self._asked, None` runs, logged only when `_pending_asked` was used and `self._asked` was empty or different (for example `kind: goal_request_kept`).
- **d6f9e8a's interact half** (the bag read at the press) has no line. A line at `if not e.based then e.before, e.based = api.counts() ...` in `client_mod/scripts/skills.lua` would show it; low value, since only a gain that lands between walk start and press tells.

## Evidence for the confirms

**E1, c2a9835.**
- Interact half. `brain-live-20261117-125058-24784.jsonl`, 11:52:14Z, bridge_recv: `"target": "BP_RuntimeSpawnedWorldItem_ProcessingStation_C_2147463900", "gained": {"ITEM_Consumable_Meat_Rat_Roast": 1}, ... "The Rat Roast came to my bag as I walked up to it, before I pressed anything: +1 Rat Roast."` Next: 11:52:14Z tool_result interact ok; 11:52:32Z talk to Vannaka: "Seems your hunt was successful, I see you've gathered the food I asked for."
- Explore half. `brain-live-20261117-151932-23576.jsonl`, 14:20:40Z, tool_result explore ok: `Giant Rat is already in sight (11.45 m ...), so I did not walk anywhere`. Next: 14:20:45Z say "rats right here, going in"; 14:21:02Z attack ok; 14:21:24Z craft "I made 1 Rat Roast"; 14:21:55Z talk Vannaka, quest step done. Before the fix this was the failed result `already_in_sight` (4 misses).

**E2, 235f401.** `client.log`, 4 cases (16 Nov 22:00:57Z; 17 Nov 04:48:42Z, 07:32:05Z, 09:50:55Z). Example 09:50:55Z: `crafting: the Campfire's menu is no longer open (at load): opening it again (1)`, then `HandleSplitToExternalSlot(3, InventoryItems, 1, 0) ITEM_Resources_Raw_Stringy_Meat`, `ProcessingStationUIAPI:ToggleProcessingStationStarted()`, `arbiter: released skill:craft (done)`. The brain's craft result at 09:51:13Z is ok (Rat Roast). The other three also ended with a craft ok (22:01:11Z Rat Roast, 04:49:06Z Clean Water, 07:32:20Z "I made 1 Rat Roast in the Campfire.").

**E3, 4df3901.** `client.log` 16 Nov 21:26:05Z: `HandleSplitToExternalSlot(1, QuickAction, 2, 0) ITEM_Consumable_Water_Dirty` (he loads a fire). Client boots again at 21:29:37Z, 21:34:45Z, 21:39:52Z, 21:41:09Z and 21:53:21Z (`DWClient loaded`, `boot_join_server.lua`; new fork ClaudeS162140b), so station ids are new. 21:56:28Z `crafting: HandleExternalQuickTransfer(0)`. `brain-live-20261116-225430`, 21:56:54Z, craft ok: `"took_out": [{"item": "ITEM_Consumable_Water_Dirty", "count": 1}]`, "I made 1 Rat Roast in the Campfire. First I took out what I'd left in it from before: 1 Dirty Water (back in my bag)." Record on disk: `client_io/state/my_loads_dev.json` (written 14:21Z). No "someone else left" reply since the commit.

**E4, 62d7fc7.** `brain-20261117.jsonl` (harness traffic), 11:26:11Z: go_to `[149.85, 1913.77, -32.73]` answered ok, "the spot is under water, 1.2 m below me; I'm in the water over it". Next rows: `speech_direct register Tester`, then the chat line "claude, go and talk to the Wise Old Man" (the trial starts; run 20261117-112716 passed). Again 11:32:39Z (1.1 m below), and run 113352 (Getting Started from `gs_chain`) started and passed. Before the fix such a walk ended `verification_failed` (5 in Getting Started runs).

**E5, eb68bfb.** Before the fix, prompts carried `Ash Logs -> Vannaka` and `Lore Item -> Vannaka` renames (11 and 7 in a sample of 16 and 17 Nov). After it, 10 trials (brain logs 082142, 082537, 083457, 103050, 104407, 120140, 120534, 125058, 125956, 145916) looked at Vannaka's spot (151.83, 1788.53): Ash Logs at (150.0, 1790.85) and (149.4, 1786.8) and the Lore Item at (155.12, 1788.38) reached 4 to 9 prompts each with no `seen_as`. The only renames after the fix are in `brain-live-20261117-140049`: `Anima Vent -> Earth Anima Vent` and `Anima Vent -> Astral Anima Vent`, both right.

**E6, 46c0ca9.** `client.log` 16 Nov 23:29:00Z: `combat: defence block -> blocked (key Giant Rat:ATK_GiantRat_Attack_01, impact 1.06s, dmg 0, ..., turned 99 deg from it at the key, 63 deg at the hit)`; 23:29:08Z `... turned 167 deg from it at the key, 0 deg at the hit` blocked. After the commit: 93 blocks that met a swing (8 more were whiffs), 78 blocked, 3 parried, 12 hit; 86 of 93 faced within 60 deg at the hit. Of the 57 that began over 60 deg away, 52 faced it by the hit (47 blocked, 2 parried, 3 hit) and 5 did not (4 hit). Of all 7 blocks still over 60 deg off at the hit, 6 were hit. Block hit rate 10 of 35 before, 12 of 93 after (p = 0.063 alone; the facing data is the clearer proof).

**E7, d5f57ad.** The commit's own words: 60 lines (`, a plain hit)`, `m off, taken to reach`). Outcome by `combat: swing at the Giant Rat from 1.8 m (-0.1 m in height, facing 2 deg off): hit` lines: before (16 Nov 22:19Z to 23:56Z) 33 swings, 12 over 45 deg off, 16 hit; after 393 swings, 58 over 45 deg off, 301 hit. The before set overlaps 46c0ca9 for 30 minutes.

**E8, 13959e8.** For each talk whose result said "<Quest>, next step: X" or "New quest", the first get_state after it in the same brain log: after the commit 168 of 168 showed step X; in the 24 h before, 100 of 221 (79 stale, 42 quest absent). The PROGRESS count was 18 of 20 stale in s14 and s15. `client_module_error`: 0 in both logs.

**E9, 93ec959.** Attack results in the brain logs, two days before the commit against all after: `too_far / cant_catch` "the Giant Rat keeps moving away faster than I can catch up" 3 of 28 (runs 065655, 122822, 194934 of 16 Nov) against 0 of 90. The 3 `chased_s` replies after: 07:36:11Z `path_blocked`, why `target_above_jump_height`, chased 31.2 s; 12:00:51Z `no_route`, 29.0 s, `lp_fail: jump route changed`; 14:00:02Z `no_route`, 21.4 s, `lp_fail: jump landing missed`. None is a false stall; the last is the landing judgement of goal item 3. Weakness: no line shows the setback rule itself.

**E10, c835589.** `client.log`:
- 08:52:10Z `move: taking off 57 cm from the jump's start (I get no nearer to it)`, then `go_to d=2837cm`, 08:52:12Z `d=1749cm`, 08:52:16Z trip "Walked 66 m ... 1 m left". Before it, four stucks at the same spot in 9 s.
- 11:41:33Z same words, then `stuck n=1 moved=31cm`, `jump route changed; re-planning`, 11:41:39Z trip "Walked 39 m ... 1 m left".
- 12:43:46Z `taking off 56 cm`, 12:43:47Z trip from z -4.34 to -3.09 (up the ledge), then the fight goes on.
Run 073510 before the fix stuck at this ledge and the attack ended `path_blocked`.

## 61412a5: the counts (verdict left to goal item 2)

`lp_jumps.py` over `client.log`, reproduced:

| window | paths | with a jump up | landings judged missed |
|---|---|---|---|
| s29 + s30, `rc_chain2`, 11:39Z to 12:47Z (before) | 95 | 43 | 8 |
| s31, `rc_chain2`, 13:59Z to 14:25Z (after) | 33 | 16 | 11 |
| rung4 gate, 17:18Z to 17:25Z (after, another place, not compared) | 25 | 12 | 2 |

8 of 43 against 11 of 16 is p = 0.0005 (`tools.ab two 8 43 11 16`). Paths in one trial are not independent. By edge after the change: hops under 65 cm 2 of 2 missed, 65 to 120 cm 2 of 6, 120 to 200 cm 4 of 6. The rung4 gate's 2 of 12 is from a different place and run type and does not move the comparison.

## The confirm window

Ten rows confirm now, so 10 stay open (9 live and 61412a5). The cap is 8: the window has to settle at least 2. Three rows can be settled in about 35 minutes; the rest wait for situations no quest step makes on demand.

**Before it:** fix c9fb8ff's regex; add the c96dc9e and e5b851c log lines if those rows are to be counted in later windows (that is a brain and Lua change, so commit it before the window; `quest_run` refuses uncommitted code). Restore the named world (rule 9).

**Block A: direct probes, no brain, no model calls (about 5 minutes).** On ClaudeDev in the dev world, with the brain stopped (`tools.bridge_cmd`, debug channel):
1. `bridge_cmd get_state`: read his bag.
2. **1cffdc4:** `bridge_cmd craft '{"item": "<a recipe short of two inputs in that bag>"}'`. The check runs before any walk (0.3 s in runs 211833 and 090028). Confirm when the reason is `missing_materials` and the detail matches `I need \d+ .* for that and I have \d+, and \d+ ` with both counts true to the bag. Expected: 1 trigger.
3. **07f1cb3:** `bridge_cmd buildables '{"about": "<a piece he cannot afford>", "can_build_now": true}'`. Confirm when the reply holds `"cannot_build_now": {"matched": ..., "pieces": [...]}` and each piece's need matches the bag. Expected: 1 trigger.

**Block B: `quest_run step --from gs_start --quest "Getting Started" -k 5` (about 20 to 25 minutes).** Settles **02d2cfd**: the player enum is in every prompt (5 of 5 trials expose it). Confirm if no `give` to an NPC comes in the 5: 0 of 22 against 7 of 38 is p = 0.04 (`tools.ab two 7 38 0 22`). One give to Doric bins nothing but leaves it open. `gs_start` is 10 of 10, so the trials cost little risk. Nothing else open is reached here.

**Total:** about 35 minutes with the switch and its reserve. If Blocks A and B confirm, the ledger is at 7 open, under the cap.

**Optional Block C: `quest_run step --from rc_chain2 --quest "Ratcatcher" -k 5` (about 25 minutes).** It settles nothing alone, but adds to three rates: f1108be (about 0.1 empty-list hunting decisions per trial), e5b851c (a resumed walk to a rat the reflex killed: about 2 in 60 Ratcatcher trials before the fix), c835589 (the hill ledge is met in about 1 trial in 8). It also gives goal item 2 more jump paths from the same checkpoint. Run it only after landings are readable (goal item 3), so its paths count there too.

**Rows no quest step reaches on demand.**
- **c96dc9e:** needs a body-only run between `start_goal` and the goal's start. The I1 trial of the first long-job window makes it if food and water are set low just before the chat line (hunger run queued while the chat run plans). Count it there, with the log line added.
- **c9fb8ff:** needs a client drop of 5 s or more while a request is open: stop the client mid-gather in a step trial and boot it back (`tools\stop_client.ps1`, `tools\client_boot.ps1 -Target dev`). Fits beside I5 in the long-job window.
- **d6f9e8a (talk half):** a talk held up by a fight. Seen once (194849, a goblin fight at Zanik); no fixture makes it.
- **82a9824:** a made-up skill name from the model. Seen once in about 250 runs; no trigger short of prompting for it.
- **f1108be and e5b851c:** see Block C.

## What I could not decide
- **93ec959** is confirmed on an aggregate (0 of 90 against 3 of 28), with no line for its own rule. Other combat changes landed in the same days (5d07a74, 46c0ca9, d5f57ad), so the drop is not cleanly its alone. The main session may prefer to keep it open.
- **f1108be:** 0 attacks after 14 empty-list prompts looks good, but only 1 of them was a hunting decision. The before rate (about 1 attack in 6 on nothing) was per attack call, not per prompt, so the two do not compare. Whether to keep it open as a rate or accept the replay (6 of 15 to 0 of 15) is the main session's call.
- **62d7fc7 and c835589** are confirmed on one half each. The failed-arrival words of 62d7fc7 and the stall reason after a climb in c835589 were never produced. Split rows if those halves matter.
- **c96dc9e:** the new code ran in all 13 goal ends (the request is always taken from `_pending_asked`), and all 13 carried it. That shows no harm, not the fix: the body-only run in between never came.
- **02d2cfd:** whether no give in 17 runs is the enum or chance is not settled at p = 0.086.
