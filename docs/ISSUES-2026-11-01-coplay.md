# Issue register: co-play session 1 (2026-11-01, 10:51-11:50 UTC, Luis on GFN)

Every problem found in the session log (`logs/brain-live-20261101-115554-7128.jsonl`; 79 request episodes; 119 lines from Luis, 15
`note:` lines), with its evidence (UTC time) and its status. Luis: "I wasn't able to truly test him, it was
painful." The ranked root causes and the plan are in `docs/RETRO-2026-11-01-coplay.md`. This file is the full
list, and every item needs a test to a human standard before it counts as fixed.

Status key: **FIXED** (commit, live-checked unless noted) · **AGENT** (being fixed now) · **OPEN**.

## Timing, the headline

- **The brain is not the slow part.** A model call takes 0.8-2.6 s (mean about 1.3 s). His first words came 2-5 s
  after a line, and his first action 2-4 s after.
- **The body is the slow part.** Requests that needed the body took 20-190 s, and most needed Luis to correct
  them:
  - 135 s for "pick up the sticks/stones" (11:05);
  - 94 s for "kill 3 kebbits", ending in death (11:17);
  - 125 s for "go to the temple" (11:29);
  - 189 s for "the temple", with **147 s of silence** before his first word (11:34).
- **He idled while Luis waited:** "you aren't doing anything, you are stood still unresponsive by the tent" (11:03:58),
  "you aren't moving, why not" (11:25:19). We can't yet measure idle time, because there are no position samples
  (telemetry agent, T1).

## A. Finding things: perception and knowledge

| id | issue | evidence | status |
|---|---|---|---|
| A1 | Can't find a player beyond ~150 m (net relevancy); the compass registry is unused | go_to luis -> target_not_visible x6, 11:31-11:34; "where are you?" | FIXED 496d3a5 (live: his map marker found at 362-435 m; the walk ended short on nav coverage, movement agent) |
| A2 | "Near me" searched near himself, not near Luis | 11:10:52 ran far for sticks; 11:15:32 "you are like 100-200 m away"; 11:16:29; 11:40:22 "can't see any kebbits" while they were by Luis | FIXED 496d3a5 (near=<player>, near_speaker context; live check needs Luis in sight) |
| A3 | Grave memory wiped his newest death, so he went to week-old graves | 11:20-11:39; notes 11:22:13, 11:28:21 | FIXED b70292f (offline test; recheck after a death) |
| A4 | "The temple" didn't resolve: it isn't a landmark, Temple Woods is the region and Forgotten Temple is 1.7 km away | 11:29:35, 11:33:36 unknown_target | FIXED 39e8493 (candidates listed); a building in a region still isn't a map name |
| A5 | "Crafting bench" / "workbench" didn't match "Crafting Table" | 11:00:57, 11:02:41 "I don't know a station called workbench"; note 11:03:39 | OPEN |
| A6 | "Club" was ambiguous (several clubs) and he gave up instead of listing them | 11:02:39 craft_plan ambiguous_target | OPEN |
| A7 | Didn't know that picking up sticks gives Ash Logs | note 11:12:12 | OPEN (knowledge: the pickup -> item mapping should be in his context) |
| A8 | Couldn't see what he had built: structures aren't in his context, and the crate's name differs between buildables ("Crate") and the "Usable" line ("Base Building Crate") | 11:49:26-11:50:08 | FIXED d86f3bb (built pieces from GlobalBuildingManager, buildables names, ids) |
| A9 | Doesn't know his carry capacity or encumbrance (answered "475 weight total, no cap") | 11:44:08-11:44:47 | OPEN |
| A10 | Hotbar vs bag confusion: sandwiches in the bag can't be eaten, the hotbar was full, and he said "inventory" meaning the hotbar | 11:42:45-11:43:28 | OPEN |
| A11 | Built the fire and table in the lake (earlier runs); placement doesn't see water | note 10:58:23 | OPEN (building perception) |

## B. Doing things: body skills

| id | issue | evidence | status |
|---|---|---|---|
| B1 | Pickups refuse a same-kind item under the prompt and re-aim for 10-20 s (28 not_interactable) | notes 11:07:45, 11:08:02, 11:08:55 ("he stares... adjusts for 10-20 s, a human would grab instantly"); 11:14:20 overlapping hitboxes | FIXED 5d098d8 (same-kind neighbour under the prompt, 0.6-0.9 s); on-the-move sweep: agent (1.49 s/item live) |
| B2 | Water volume under the prompt blocks pickups | 10:58:50, 10:59:12 "the game targets BP_WaterVolume" | FIXED 5d098d8 (step out of the water) |
| B3 | No partial stack drop (drop 40 of 120 fails) | 11:45:14-11:46:21; note 11:46:28 | FIXED 5d098d8 (drop N; live 114 -> 74 -> 14); split + give: agent |
| B4 | Explore walked off a 29 m cliff (planned 4.8 m drop, mis-sampled floor, KillZ) | 11:18:46; note 11:18:59 (stood 20 s at the edge first) | FIXED 39e8493 (offline only; live check pending) |
| B5 | Walks into a rock edge or a log for 1+ min when a clear path existed the other way | note 11:26:40, 11:28:21; 11:38:44 "walking into a log", "jump over or walk around" | AGENT (movement) |
| B6 | Jumped onto the tent and "shimmered along on top" for 10-15 s | 11:05:06 | OPEN |
| B7 | Wedged 2 m from the shelter for 25 s | 11:02:15 path_blocked | OPEN |
| B8 | Exhausted (endurance 0) the whole session: no sprint, jumps fail, 1.6-2.2 m/s; never rested, never said it was why he was slow | 11:39:31 "why aren't you running?"; trips at 1.5-2.2 m/s | AGENT (survival) |
| B9 | Combat: stood still while a goblin hit him, then ate mid-fight | 11:28:21; note 11:29:12 | FIXED 9b9a163 (live: 3 runt fights won at 100/100/82 HP; root cause of lease_expired: navmem plan 9-11 s, now 0.42 s) |
| B10 | Combat: lost the third kebbit; "can't see it anymore" | 11:41:55 | OPEN |
| B11 | Didn't pick up loot after kills until asked; bag full | 11:41:56 "you aren't picking their stuff" | OPEN |
| B12 | Started the session at 0.5/100 HP with no food or water; the stay-fed reflex had nothing to use and nobody noticed for hours | boot probe 10:50; vitals; again 13:01 (hydration 5/75, nothing carried; died 12:46 of thirst + poison with dirty water about) | AGENT (survival) |
| B13 | Can't deconstruct buildings | 11:00:57; note 11:01:21 | FIXED d36a500 (deconstruct the player's way; live: Luis's house, 29 pieces, full refund) |
| B14 | Built two crates when one was asked for, believing the first failed | 11:48:57-11:49:15 | FIXED a6b7242 (truthful build result) |
| B15 | Follow kept within 6 m only 64% of the time (scripted leg), with no word about falling behind | coplay ladder 10:55 | OPEN |

## C. Talking and listening: the brain

| id | issue | evidence | status |
|---|---|---|---|
| C1 | Every chat line cut the running action ("interrupted, the player spoke"); re-issued go_tos restarted trips, which looked like freezing | dozens of rows; 11:25:19 "you aren't moving" | FIXED 39e38b5 (still_running + body status; the same call re-attaches; live: answered mid-walk, arrived 157 m) |
| C2 | Silent for 147 s on a 274 m walk to a lodestone | 11:34:20-11:36:47 | OPEN (a progress line on long actions) |
| C3 | One reply never spoken (the model wrote it as a note) | 11:50:11 reply_silent | FIXED 39e38b5 (an unspoken reply gets one more turn to call say) |
| C4 | Followed the wrong part of compound instructions ("the stone near me FIRST, then find more") | 11:13:23 "you missed the part where I said..." | OPEN (eval case) |
| C5 | "Do not wander off, build them here": walked away while Luis said "come to me" | 11:47:12-11:47:44 | OPEN |
| C6 | Answered "levels" (skills) when Luis meant hunger/thirst levels, which was a fair ambiguity; then fine | 11:48:09-11:48:24 | minor |

## D. Deciding what to do: planning

| id | issue | evidence | status |
|---|---|---|---|
| D1 | Food: "low food -> berries" instead of "what fills me best?" (cooked meat via club -> kill -> cook is worth the detour) | Luis's note; 10:56-11:09 berries; 11:20 berries before the grave | FIXED IN PART (needs-options agent, 2026-11-01): `brain/needs_options.py` lists every option with [~time -> +gain, level after, lasts], where, steps and risk, from live game data; hunts include cooked value per kill and the odds; a `food_options` read tool gives it on demand. Eval 4/10 before the outcome-first format (berries bias, persona example fixed). Live 15:20Z: he chose the Fillet in his bag (2 s), not berries. Re-eval 16:30Z (12 calls): hunt+cook 2/6. He still gathers the berries 1 m away first; after the follow-up turn got the digest, 4 of 6 ate them raw. Live 15:48-16:35Z (set_stat 12-30%): he takes the best carried items (Pumpkin Spice +80, Fillets), no berries. The Rung 1 gate eat_drink fails on time only (12.9-27.9 s against a provisional 4.5 s T_h, below the game's ~6 s per-use lock). The reflex/brain double-use is told to the model now, but it still doubles up (see DISCOVERIES). |
| D2 | After death, berries before his own grave (with 45 sandwiches in it) | 11:19:47, Luis 11:20:30 | FIXED IN PART: the newest grave with its food and death is an option (and the bogus drain read across the death, which claimed "empty in ~1 min" at 42% food, is fixed in skills.lua). Eval 3/3 on the [time -> gain] format (16:24Z: go_to his grave first). One of the 3 said "starving and parched" at a bit peckish 42% / thirsty 27%: persona example 2's "while starving" label is now "while you're out of food". "Graves of yours not in sight" always lists his newest grave (item_stats.graves_for_line). Not re-run live: it needs a fresh death. |
| D3 | No base thinking: own campfire, table, crate, storage | Luis's direction | OPEN (competence map) |

## E. Honesty

| id | issue | evidence | status |
|---|---|---|---|
| E1 | "I'm by you now, grabbing the ones here" while 100-200 m away | 11:15:35 | OPEN (truth judge eval case) |
| E2 | "I'm at the spot by the temple cliff" (he wasn't) | 11:23:02 | OPEN |
| E3 | "The build call reported failure" (it reported ok) | 11:50:11 | FIXED in the tool (a6b7242); the model side still needs an eval |
| E4 | "Got 4 of 5", "got the 2 I missed" while 2 were still on the floor | 11:14:23-11:15:20 | OPEN (claims of counts must come from the inventory delta) |

## F. Session and ops

| id | issue | evidence | status |
|---|---|---|---|
| F1 | The scripted ladder's brain answers only "Tester", so Luis's first lines went unanswered | 10:53-10:55 | FIXED in practice (the free-play brain answers the player); a co-play run should take both |
| F2 | No pre-session check of his vitals, inventory and endurance | 10:50 | AGENT (survival: tools preflight) |
| F3 | The client watchdog reports nav_oracle "missing" every 10 s while it is running (its process query misses it) | client_watchdog.jsonl, 94 rows today | OPEN (harmless noise) |
| F4 | The scripted ladders said 8/8 while free play got about 4/14: they measure clean single lines from a pawnless sender, not a person | retro | AGENT (evals research) |
