# Natural interruptions in the logs of 16-18 Nov (measure first)

Goal item 1 asks for one ask carried through hunger and thirst, a fight, his death and grave, a full bag and a brain restart. Before any induced trial: how did he handle the interruptions that hit him on their own while a player's ask was open? 279 brain-live logs (16-18 Nov), 183 interruptions after he had acted on the ask; 18 left out (ask already done, or the run ended within 30 s). Rows: `data/measure/natural_interruptions_20261118.json`; script: `tools/natural_interruptions.py` (agent-written, 2026-11-18).

**Resume rule:** after the interruption ended and before the ask closed or a new player line, a body call that serves the ask (not eating, drinking, water-finding, cooking, the grave, gear swaps, reads; nor a walk or gather whose next call is one of those). A serving call running across it that ended ok counts as resumed at 0 s. Quest asks set what serves. Heuristic, checked by hand on about 8 runs.

| kind | judged | resumed | median s to resume | not resumed |
|---|---|---|---|---|
| I1a reflex ate/drank, body went on | 29 | 16 at 0 s, 21 in all | 0 | 8 |
| I1b he stopped to eat, drink or fetch water | 95 | 77 | 2.2 (p75 4.2) | 18 (a thirst spiral: exploring for water until the run ended, or asking the player for a drink) |
| I2 a fight the ask did not call for | 27 | 14 | 6.6 (p75 55) | 13 (7 fights ended in his death) |
| I3 death | 10 (12 deaths, 9 runs) | 5 | 274 | 5; he tried his grave after 4 deaths and opened it after 3 |
| I4 full bag | 0 | - | - | (only 2 full-hotbar results) |
| I5 brain restart | not natural | - | - | induced N1-I5: resumed 16.4 s after |

**Most open runs:** the thirst spiral (18) and fights (13, seven of them fatal), then death (5 of 10 never resumed). By rule 2 the first induced interruption to work alone from a checkpoint is I1 (thirst) with I2 behind it; death has the worst rate.

## Correction (same day, after reading the 26 I1 non-resumes)

Only one of the 18 I1b non-resumes was a thirst spiral. 13 (8 I1b, 5 I1a) were a sub-goal that ended with the ask still open (the Zanik runs: "One part of Rune Mysteries is complete, but Rune Mysteries is not over"; he drank in the same turn and stood), all before the open-ask turn (3ec85ff); since it, 8 I1 rows, and every non-resume among them was an honest park on the blocked copper ask (the agent gave 5 resumed and 5 parks, which do not add to 8: recount before quoting). 7 were blocked before the drink (copper out of reach, a grave he could not see, a talk that did not open), 4 were asks already done (the measure's fault: a completed quest or finished request must end the ask). The one real spiral (B03): `collect_water` said "I can't see any water I could collect near me" (150 m search) with ponds at 111 m and 113 m, and two explores passed 49-51 m from them; not yet explained.

So by rule 2 the biggest open target is fights (13 not resumed, 7 of them fatal), then death and the grave; thirst is mostly covered. Report: the agent's thirst_spiral.md (scratchpad, 2026-11-18).
