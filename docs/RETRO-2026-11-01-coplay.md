# Retro: first Rung 2 co-play session with Luis (2026-11-01, 10:51-11:50 UTC)

Luis played from GFN on the dev world for about 55 minutes of free play (character `luisdeburnaybast`). The
brain ran Haiku 5.5 with him as the player. He sent 119 lines, 15 of them `note:` lines. Log:
`logs/brain-live-20261101-115554-7128.jsonl`. About 270 model calls, about $0.20. Luis's verdict: "very
disappointed". He spent the session babying him, and every task took far too long.

## Scorecard (his requests, scored from the log)

| request | outcome | what it cost |
|---|---|---|
| eat / drink (he started at 0.5 HP, 0 food, 0 water) | done, slowly | ~10 min of berries, lake, fumbled pickups |
| destroy and rebuild the campfire + table by Doric | can't: no deconstruct | told truthfully |
| shelter / rest | failed: "wedged" 2 m from the shelter | |
| build a crafting table + fire here (first time) | refused: searched "crafting bench" literally | Luis had to say "Crafting Table is the first item" |
| craft a stone club | done | ~12 min, with heavy steering |
| pick up the sticks / the 2 stone near me | done after 3-4 corrections | ran 100-200 m off to other stone |
| come here, pick up this food, eat until full | done | |
| sleep | done (Summon Shelter) | |
| kill 3 kebbits | first try: explore walked off a cliff, 29 m fall, dead | |
| get your stuff from your grave | failed for ~15 min | went to week-old graves; Luis led him in the end |
| come to me (Luis > 150 m away) | failed: "can't see you" x6 | |
| go to the temple | done via lodestone (his own idea) | 2.5 min; "the temple" did not resolve |
| kill the 2-3 kebbits by me | done (2 of 3) | |
| make inventory space / pick up loot | done | |
| drop 40 stone, keep 80 | failed: no way to split a stack | |
| build a crafting table + fire pit here (second time) | done | |
| build a crate | placed twice, he said "failed" twice | burned 16 ash |

About 4 of ~14 distinct requests were done cleanly. Rung 2's bar is 80%.

## Root causes, ranked by how much babying they cost

1. **Pickups are slow and refuse the obvious item.** 28 interacts failed with `not_interactable`, e.g. "the game targets
   Ash Logs, not the Ash Logs", "targets BP_WaterVolume, not the Ash Logs". He aims at one exact actor. When
   the game's interact prompt is on a different stick or stone of the same kind (overlapping hitboxes), or on the
   water, he refuses and re-aims for 10-20 s. A player presses E on whatever is highlighted.
   **Fix:** press when the highlighted target is the same item kind; treat water as "step out", not a refusal;
   no alignment dance within reach.
2. **Every chat line cut the running action.** Dozens of actions came back `interrupted` ("the player spoke;
   the body may still be doing it"; brain/bridge_client.py L2(a)). The model then often re-issued the same
   go_to, which restarts the trip, so "where are you going?" froze him. **Fix:** a chat line gives the model
   the floor, but the action keeps running and is reported as running (progress, metres left), not as a
   failure. A repeat of the same go_to/follow while it runs re-attaches instead of restarting.
3. **He can't find a player out of net relevancy (~150 m).** `go_to luisdeburnaybast` answered
   `target_not_visible` 6 times. The game already replicates every player's position to every client for the
   compass and map: `AGameplayObjectRegistry.PlayerCharacters` ({Location, OwningPlayerName, ...},
   DISCOVERIES "Map and compass presence"). We read the same registry for lodestones and landmarks.
   **Fix:** come / follow / go_to a player fall back to the registry position and walk the oracle route
   toward it. Luis's suggestion: the compass shows the player and the distance, so a player beelines.
4. **"Near me" meant near him.** "The 2 stone in front of me" and "grab these sticks near me" sent him
   searching around himself, 100-200 m from Luis. **Fix:** gather / pick up take a "near <player>" anchor,
   and his context lists what lies within ~15 m of the speaking player.
5. **Grave memory wiped his newest death (FIXED, b70292f).** Emptying any grave that matched no remembered
   death marked the NEWEST death recovered (`skills.lua death_recovered` fell back to it). At 11:22 an old
   grave 15 m off erased the cliff death, and he only knew 10-28 graves after that.
6. **Build results read as failures.** The crate build returned `ok: true` (8 ash spent, +29 XP). The result also
   listed the preview spots he had tried first as `not_valid` and had `structure: null`, so he said "crate keeps
   failing", built a second one, and later claimed "the build call reported failure". **Fix:** the result leads
   with what was placed and where; the rejected previews are labelled as such; the new structure is found
   in the census.
7. **No way to drop part of a stack.** `drop Stone 40` failed verification three times (HandleDropItem with a
   partial amount does not shrink the stack); only a whole stack (99) dropped. He told Luis "drop only takes
   the whole pile". **Fix:** split via the inventory UI's split handler, then drop the split stack.
8. **Combat: stood still while a goblin hit him, then ate mid-fight.** When hit, he must defend (fight or
   back off) first. Open from the Rung 1 night: "losing" at react vs Goblin Runts. He also spent the
   session at endurance 0 (no sprint, jumps fail).
9. **Explore walked off a 29 m cliff.** No navmesh route for the leg, so the local planner chose a 4.8 m "drop"
   whose landing sample was wrong (the real floor was 29 m down; he died at the exact planned landing XY).
   **Fix:** an explore leg never takes a drop; drop landings need a verified floor.
10. **Smaller ones:**
    - "the temple" did not resolve to Forgotten Temple;
    - "crafting bench" did not match Crafting Table;
    - "Club" was ambiguous;
    - total weight (475) was given when Luis asked for capacity;
    - one silent reply: the model wrote its answer as a note instead of saying it;
    - he started the session at 0.5 HP with no food or water and nobody noticed (me included).

## What worked

- He used a lodestone on his own to reach the temple.
- The Summon Shelter cast for sleep worked.
- Kebbit kills worked once he was next to them.
- He built the table and fire on the second ask.
- His failure reasons were mostly specific and true: wedged, fell 29 m, no deconstruct, can't split.

## What I got wrong

- I tuned Rung 1 on clean single-line legs from a pawnless sender. None of that measured talking to a real
  player who moves, points at things near himself, and talks while he works.
- I didn't check his vitals, inventory or endurance before Luis joined.
- I started the session with the scripted ladder's brain, which only listens to "Tester", so Luis's first lines
  went unanswered.

## Plan

1. Fix 1-7, and 9's drop rule. Fix 1, 2, 5, 6 and 7 can be tested live on Claude alone: drop a cluster of
   stone and ash and pick it up; chat mid-walk; build a crate; split and drop.
2. Add a **Luis-replay ladder** (tools/coplay_ladder.py requests built from his real lines): "the 2 stone in
   front of me", "where are you going?" mid-walk, "get your stuff from your grave" after a death, "drop 40
   keep 80", "build a crate", "come to me" from 300 m. The ones needing a second player wait for Luis.
3. Then fix 8 (combat) and 3-4 live with Luis.
