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
