# Ledger triage: the 16 untagged runs of 2026-11-01 (2026-11-17)

Offline triage of the rows `failure_ledger report` listed as untagged (the 16 rows the last `scan` added; they are
uncommitted in `docs/failure_ledger.jsonl`). Each run was read from its record in `logs/evals/quest_runs.jsonl`, its
brain log (`logs/brain-live-*.jsonl`, named in the record; brain log names are local time, UTC+1) and
`logs/client/client.log` (UTC). All logs were present; none of the 16 is "unknown". Run ids are UTC.

A run is tagged with the first thing that went wrong (CLAUDE.md section 2, rules 2 and 3). Two exceptions, both said in
the row: two runs failed only a bar the grader could not judge, and one run's only miss was recovered inside the miss
bar while a later stand failed it.

The old code these runs ran on has changed a lot since. Where a later commit fixed the cause, its hash is given as
`--fix` so these rows do not inflate today's open counts; where the cause is still live, no `--fix` is given.

## Table

| run | item | class | void | cause | evidence |
|---|---|---|---|---|---|
| 20261101-154722 | Getting Started | harness | yes | The grader failed the time bar only because the record predates the human bar: it has no `ratio`, and `verdict` (tools/quest_run.py:393) fails `time` when `ratio` is None. Computed from its brain log the run is 26.7 s against a human 72.9 s (0.37x), done, 0 misses, no stand: a pass. | `quest_runs.jsonl` row 20261101-154722 has no `ratio` key; `quest_run report -n 400`: "20261101-154722 Getting Started quest complete 26.7s done=True PASS misses=0 ... human=72.9s ratio=0.37x". The human bar arrived in 5e3ed34 (2026-11-01 18:25Z); every record before it lacks `ratio`. |
| 20261101-155340 | Ratcatcher | model | no | Stopped with the quest's next part open: after the talk that gave "Kill rats and cook one rat roast" his turn was a line with no call, the request ended done and he stood 16.3 s until a situation review. | brain-live-20261101-165334-3708.jsonl 15:54:35Z `chain_turn` actions [] "got the quest. next is killing rats up the hill at the windmill..."; 15:54:35Z `request_state` ended "done"; 15:54:50Z `situation_review`. (Later: explore walked him off the cliff west of Vannaka, 29 m fall, 15:56:07Z; the rest went on graves 64 m below.) A movement agent ran `navmem_trap_purge_run.lua` at +22 s and +30 s (client.log 15:54:02Z, 15:54:10Z); it does not touch the first fault, so not void. |
| 20261101-162400 | Ratcatcher | skill | no | attack on a Giant Rat 57 m off on the windmill hill gave up after 11.6 s at 16.2 m as path_blocked (no_route), though the go_to to the same rat that followed brought him close enough for the combat reflex to kill it and a second rat in 54 s; that go_to then failed target_not_visible because the rat was dead (2 misses, quest complete at 1.3x). | brain-live-20261101-172354-4148.jsonl 16:25:18Z attack `path_blocked` {why no_route, best_m 16.2, chased_s 11.6, target BP_AI_GiantRat_Character_C_2147175419}; client.log 16:25:18Z "combat: fight end ok=false reason=path_blocked presses=0"; 16:26:18Z reflex `combat_end` killed, target_id ..._2147175419, kills 2; 16:26:29Z go_to `unknown_target` (target_not_visible). |
| 20261101-164159 | Rune Mysteries | skill | no | go_to my_grave walked 275 m in 64 s to a grave remembered 64 m below the cliff top west of Vannaka: the death record held the falling body (z -94), not the gravestone, which stood on the cliff top. Two more go_tos failed drop_ahead; the gravestone 7 m from him then opened in 1.7 s with 27 Ash Logs and his gear. | brain-live-20261101-174154-14856.jsonl 16:44:04Z go_to `path_blocked` "Walked 275 m in 64 s ... 7 m left; the goal is 64 m below me"; 16:44:13Z `unreachable` leader_pos [38.62, 1740.25, -93.96]; 16:44:32Z interact BP_PlayerGravestone_C_2147169681 ok in 1.7 s. DISCOVERIES "The grave lands at the last grounded spot, not where the body ends up". |
| 20261101-165120 | Rune Mysteries | skill | no | talk's quest diff matched quests by name and his log held two "Rune Mysteries": the hand-in read "Quest Rune Mysteries is complete" while the game's step was "Return to Zanik.", so he told the player "Rune Mysteries done" (false) and the run ended quiet at 102.7 s. | brain-live-20261101-175115-9748.jsonl 16:52:20Z talk result `quests_changed` [{step "Return to Zanik."}, {from given, to complete}]; record steps 61.8 s "Return to Zanik."; 16:52:22Z say "Rune Mysteries done, Zanik gave me a stone pickaxe...". DISCOVERIES "Two quests in his log share the name". |
| 20261101-170535 | Rune Mysteries | harness | yes | The grader failed the time bar only because the record has no `ratio` (before 5e3ed34); computed from its brain log it is 78.2 s against a human 56.8 s (1.38x), done, 0 misses, no stand: a pass. | `quest_runs.jsonl` row 20261101-170535 has no `ratio` key; `quest_run report -n 400`: "20261101-170535 Rune Mysteries quest complete 78.2s done=True PASS misses=0 ... human=56.8s ratio=1.38x". |
| 20261101-171926 | First Steps | skill | no | `ConversationComponent.CurrentNPC` reads nil on the client: talk {target, choose} on the open Wise Old Man dialogue was refused as mixed args, talk {target} said "already talking to nil", and the orphan sweep pressed Cancel on it, so talk {choose} found none: 3 misses in 3.5 s. | brain-live-20261101-181921-15608.jsonl 17:19:55Z talk `invalid_args` "Start a conversation with target first..."; 17:19:57Z "I'm already talking to nil"; client.log 17:19:57Z "talk: orphan conversation with nil: Cancel 1 -> true"; 17:19:59Z talk {choose} "I'm not talking to anyone". DISCOVERIES "Three talk misses in that run, all one cause". |
| 20261101-181344 | First Steps | skill | no | He began under the Bramblemead Wise Old Man's raised platform, 1 m from him and 3 m below; the way up is a switchback with a 1.6-1.8 m gap jump and the local planner had no gap jump: talk path_blocked after 25 s, go_to moved 0 m in 14 s, Windstep and a built stair did not help, talk timed out after 90 s; he asked for help and stood 107 s. | client.log 18:13:54Z "move: local plan failed: walls everywhere ... no admitted route (invalid_route)"; 18:14:14Z "talk: done false path_blocked ... no closer than 1 m in 25 s"; brain-live-20261101-191339-15192.jsonl 18:14:42Z go_to "Moved 0 m in 14 s ... the goal is 3 m above me"; 18:16:31Z talk `timeout`. DISCOVERIES "The Bramblemead Wise Old Man stands on a raised platform". A movement agent's `mv_floorgrid.lua` ran at 18:16:55Z and 18:18:15Z, after the first fault. |
| 20261101-185236 | Rune Mysteries | model | no | Stopped with the quest's next part open: the hand-in read "Quest Rune Mysteries is complete. New quest Rune Mysteries: Mine Rune Essence..." and his turn was a line with no call ("Next is mining rune essence"); the request ended done and he stood 40.3 s to the end (0.87x). | brain-live-20261101-195230-15868.jsonl 18:55:47Z `chain_turn` actions [] "Rune Mysteries done, Zanik gave me a pickaxe. Next is mining rune essence from the geysers"; 18:55:48Z `request_state` ended "done"; record idle {from 191.5, s 40.3, to_end}. |
| 20261101-191323 | Rune Mysteries | skill | no | gather swung 11 times (19:14:37-52Z) at split Ash log 2147463180, which stayed at hp 80, then ended with a false body_error "something is wrong with my controls" (inputs_not_reaching_game: the swing's stamina cost reached the client late, so misses read "unverified"); the retry chopped 47 logs. The false verdict is fixed (a5ff0c0); why the piece took no damage is still open (see below). | client.log 19:14:37Z-19:14:52Z "gather: swing 5..15 on BP_SplittableLog_Ash_C_2147463180: hp 80.0->80.0 ... unverified"; brain-live-20261101-201318-16260.jsonl 19:14:52Z gather `body_error` {why inputs_not_reaching_game, swings 15, hits 4, gathered 1}. |
| 20261101-193651 | Ratcatcher | harness | yes | The grader counted the combat reflex's fights as a stand and ended the run "quiet" at 150.8 s in the middle of a fight (2 reflex kills, a flee at 29 hp, then fighting back); the grader fix is 5950c71. | brain-live-20261101-203646-13244.jsonl 19:38:17Z reflex `combat_started` (rat ..._2147465155), 19:38:38Z `combat_end` killed + `combat_started` (rat ..._2147465115), 19:39:00Z `flee_started` hp 29, 19:39:12Z `flee_failed` "fighting back"; record idle {from 86.7, s 21.3} and {from 110.2, s 40.6, to_end}, ended "quiet". tools/quest_run.py timeline() comment cites this run ("live 19:38Z (ClaudeQ3)"). |
| 20261101-200805 | Ratcatcher | skill | no | attack on a Giant Rat 22 m off on the windmill hill gave up twice as path_blocked (no_route; 11.4 s, then 2.2 s, best 19.7 m), though the go_to that followed got within 2 m and the reflex killed the same rat 11 s later; that go_to then failed target_not_visible (3 misses, quest complete at 0.9x). | brain-live-20261101-210800-10992.jsonl 20:09:02Z attack `path_blocked` {why no_route, best_m 22.2, target ..._2147465669}; 20:09:07Z again (best_m 19.7); 20:09:25Z reflex `combat_end` killed ..._2147465669; 20:09:35Z go_to `unknown_target` (target_not_visible). `build_pieces_all.lua` (read-only census) ran at +45 s and +60 s. |
| 20261101-201104 | Rune Mysteries | model | no | Stopped with the quest's next part open: after the hand-in his turn was a line with no call ("Next is mining rune essence from the geysers"); the request ended done, a situation review 31 s later got an empty reply, and he stood 72 s to the quiet end at 400 s (1.57x). | brain-live-20261101-211059-16304.jsonl 20:16:30Z `chain_turn` actions [] ; 20:16:31Z `request_state` ended "done"; 20:17:01Z `situation_review`; 20:17:03Z `llm_response` tool_calls [] finish "stop". |
| 20261101-204344 | Rune Mysteries | model | no | Stopped with the quest's next part open although the talk result already said "One part of Rune Mysteries is complete, but Rune Mysteries is not over": his turn was a line with no call ("next up is mining rune essence"); the request ended done and he stood 41.1 s to the end. | brain-live-20261101-214338-8632.jsonl 20:47:51Z `chain_turn` actions [] "first part of Rune Mysteries done ... next up is mining rune essence from the floating rocks"; 20:47:51Z `request_state` ended "done". |
| 20261101-222847 | Ratcatcher | skill | no | go_to "the windmill" resolved to the Ratcatcher quest marker Windmill Area ("you are in it now") and still failed unknown_target after 10.5 s ("not in sight, and no player of that name"); he then walked to the marker's coordinates. (Later a night rat pack killed him: 2 more misses, deadline.) | brain-live-20261101-232841-1720.jsonl 22:29:33Z go_to `unknown_target` {resolved: "'the windmill' is the game map's Ratcatcher quest marker Windmill Area: you are in it now", detail: "the windmill is not in sight, and no player of that name..."}. `seed_fall_hazards.lua` ran at +40 s, during this go_to (it does not take part in name resolution). |
| 20261101-230404 | Growing Pains | model | no | The run failed on a 483 s stand: after a lookup that said Flax is bought from Domri, his turn was a line with no call ("flax grows wild in Bramblemead, I'll go look"), the request ended done and nothing followed to the deadline. Its one miss came first and was recovered inside the miss bar: build Ash Farming Plot near me refused a valid preview that landed 2.1 m from the aim (preview_off_target); 9 s later a build at [178, 1912, -30] placed it. | brain-live-20261102-000358-9988.jsonl 23:06:01Z lookup flax "How to get: buy 1 Flax from Domri"; 23:06:03Z `chain_turn` actions [] ; 23:06:04Z `request_state` ended "done"; record idle {from 119.4, s 483.2, to_end}. Miss: 23:04:41Z build `blocked` tried[0] {valid true, off_m 2.1, why preview_off_target}. |

Note on 230404: `failure_ledger.first_wrong` lists the build miss, because a run not done adds every miss. Its own
docstring says a miss inside the bar is not what failed the run, so this row is tagged by the stand. If the main session
prefers the strict first event, the alternative tag is `--class skill --cause "build near me refused a valid preview
that landed 2.1 m from the aim (preview_off_target); the next build placed it"` with no fix.

## Tag commands

Run from `C:\gameserver` in PowerShell, with `$env:PYTHONPATH='C:\gameserver'`.

```powershell
.venv\Scripts\python.exe -m tools.failure_ledger tag 20261101-154722 20261101-170535 --class harness --void --cause "the record predates the human bar (no ratio, before 5e3ed34) and verdict fails the time bar when ratio is None; from the brain log the runs are 0.37x and 1.38x, done, no miss, no stand: passes the grader could not judge"
.venv\Scripts\python.exe -m tools.failure_ledger tag 20261101-193651 --class harness --void --fix 5950c71 --cause "the grader counted the combat reflex's fights (2 kills, a flee at 29 hp, then fighting back) as a stand and ended the run quiet at 150.8 s mid-fight"
.venv\Scripts\python.exe -m tools.failure_ledger tag 20261101-155340 --class model --fix 64dd510 --cause "stopped with the quest's next part open: after the talk that gave the rat step his turn was a line with no call, the request ended done and he stood 16.3 s until a situation review"
.venv\Scripts\python.exe -m tools.failure_ledger tag 20261101-185236 20261101-201104 20261101-204344 --class model --fix 64dd510 --cause "stopped with the quest's next part open: after the hand-in that gave the essence part his turn was a line with no call ('next is mining rune essence'); the request ended done and he stood 40-72 s to the quiet end"
.venv\Scripts\python.exe -m tools.failure_ledger tag 20261101-230404 --class model --fix 64dd510 --cause "stopped with the ask open: after a lookup that said Flax is bought from Domri his turn was a line with no call ('flax grows wild in Bramblemead, I'll go look') and he stood 483 s to the deadline; his one earlier miss, a build that refused a valid preview 2.1 m off, was recovered in 9 s"
.venv\Scripts\python.exe -m tools.failure_ledger tag 20261101-162400 20261101-200805 --class skill --fix d933d0e --cause "attack on a Giant Rat on the windmill hill gave up as path_blocked (no_route, 16-22 m short) though the go_to that followed reached it and the reflex killed it; that go_to then failed target_not_visible on the dead rat"
.venv\Scripts\python.exe -m tools.failure_ledger tag 20261101-164159 --class skill --fix 818c8a4 --cause "go_to my_grave walked 275 m in 64 s to a grave remembered 64 m below the cliff top (the death record held the falling body, not the gravestone); the gravestone 7 m from him then opened in 1.7 s"
.venv\Scripts\python.exe -m tools.failure_ledger tag 20261101-165120 --class skill --fix 13c2031 --cause "talk's quest diff matched by name and two quests are called Rune Mysteries: the hand-in read 'Quest Rune Mysteries is complete' at step 'Return to Zanik.', he said so (false) and the run ended quiet"
.venv\Scripts\python.exe -m tools.failure_ledger tag 20261101-171926 --class skill --fix 13c2031 --cause "CurrentNPC reads nil on the client: talk {target, choose} on the open dialogue was refused, talk {target} said 'already talking to nil' and the orphan sweep cancelled the dialogue: 3 misses in 3.5 s"
.venv\Scripts\python.exe -m tools.failure_ledger tag 20261101-181344 --class skill --fix 16653dc --cause "under the Bramblemead Wise Old Man's platform, 1 m off and 3 m below, the planner had no gap jump for the switchback ('walls everywhere'): talk path_blocked 25 s, go_to 0 m in 14 s, talk timeout 90 s, then he stood 107 s"
.venv\Scripts\python.exe -m tools.failure_ledger tag 20261101-191323 --class skill --cause "gather swung 11 times at a split Ash log that stayed at hp 80, then called it 'something is wrong with my controls' (inputs_not_reaching_game; that verdict fixed in a5ff0c0); why the piece took no damage is open"
.venv\Scripts\python.exe -m tools.failure_ledger tag 20261101-222847 --class skill --fix f563845 --cause "go_to 'the windmill' resolved to the quest marker Windmill Area ('you are in it now') and still failed unknown_target after 10.5 s"
```

## Count by class

| class | runs | void | fix given |
|---|---|---|---|
| skill | 8 (162400, 164159, 165120, 171926, 181344, 191323, 200805, 222847) | 0 | 7 (191323 left open) |
| model | 5 (155340, 185236, 201104, 204344, 230404) | 0 | 5 (64dd510, but see below) |
| harness | 3 (154722, 170535, 193651) | 3 | 1 (5950c71) |
| game | 0 | | |
| unknown | 0 | | |

## Causes still open today

1. **A turn with a line and no call closes the ask (5 of these 16; 2 open runs today).** 155340, 185236, 201104,
   204344 and 230404 all end the same way: a turn whose only call is `say`, `request_state ended "done"`, then a stand
   to the end. Today's gear_up rows r1-20261117T171645Z and r1-20261117T172744Z ("a turn with no call closed a long job
   far short of its target") are the same mechanism, and b0ba3b4 pins it as strict xfail gap 1
   (`tests/test_long_job_gaps.py::test_an_ask_stays_open_while_the_game_shows_it_is_not_done`; brain/agent.py:666-671
   sets `_open_request = None` on any turn with no tool call). 204344 shows that better words in the talk result ("One
   part ... is complete, but ... not over") did not stop it. The `--fix 64dd510` above credits the "asked about once"
   change of that time; if the main session wants these runs counted with today's open gap, drop `--fix` from those
   two lines and the group becomes 7 runs, the largest open cause in the ledger.

2. **The "unhittable" split log is an aim at where the piece was (191323; still live).** The 12-swing give-up is still
   a TEMPORARY GUARD (client_mod/scripts/gather.lua:62 and :1558). The `gather: diag hit|nohit` lines in
   logs/client/client.log (added 2026-11-01 for this) answer it:
   - all 156 hit lines on `BP_SplittableLog_Ash_C` pieces: `aimed_cm` 0 at the 75th percentile, `d2_cm` (him to the
     piece's middle) 14-190 cm;
   - 82 no-hit lines on 42 split pieces: `aimed_cm` median 279 cm (quartiles 179-519), `d2_cm` median 419 cm; 78 of 82
     more than 2 m from the piece's middle. The other 4 had the piece 1.4-1.6 m below him (`dz_cm` -142 to -159).
   - `aimed_cm` is the distance from the point chosen at selection to the piece's middle now: the piece had moved (or the
     chosen point was not its middle) and he swung at the old spot, out of the hatchet's 115 cm-deep wedge
     (DISCOVERIES "The swing has a height"). Example: client.log 2026-11-17T01:07:31Z `..._2147464508` d2 303 cm,
     aimed 168 cm, `simulating` true.
   - By day: 2 lines (1 piece) on 2026-11-02, 33 (17 pieces) on 2026-11-16, 47 (24 pieces) on 2026-11-17.
   The likely fix is to re-read the piece's middle before each aim and re-approach when he is out of reach. Not tried.

3. **The grader fails the time bar of any record without `ratio`** (tools/quest_run.py:393), while `quest_run report`
   computes it from the brain log. Only 154722 and 170535 are affected (the only pre-5e3ed34 records that pass every
   other bar), and voiding them removes the effect, so this needs no fix unless old records are rescored again.

4. **attack no_route on the windmill hill** (162400, 200805) is the same symptom as 073510 and 120009, fixed by d933d0e
   (not among `tools.unseen`'s 8 open rows). It is given as their fix; a new attack path_blocked on that hill would
   reopen it.

The other five fixed causes (graves at the falling body, the same-named quest diff, CurrentNPC nil, the gap jump, the
marker go_to) have no newer runs in the ledger.
