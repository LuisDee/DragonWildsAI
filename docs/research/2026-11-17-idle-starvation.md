# ClaudeDev starving between windows (2026-11-17)

Offline study of logs only, with no bridge calls. Sources: `client_io/events/vitals.jsonl` (survival rows every 30 s, reflex rows, damage rows), the `logs/brain-live-20261117-*.jsonl` state reads, `logs/window_*1117*.txt`, the SaveCharacters write times and `client_mod/scripts/inventory.lua` (R.tick). All times are UTC. Build 26574459, dev world, ClaudeDev.

## 1. How fast the bars fall

Measured from survival rows over clean stretches with no eating, drinking or death in them:

| stretch | what he was doing | water /min | food /min |
|---|---|---|---|
| 20:20:40-20:25:10 | idle at home, before course window f | 5.49 | 4.16 |
| 20:25:10-20:30:12 | jump course (running, jumping) | 5.50 | 4.15 |
| 19:50:01-19:56:32 | L2 fork a, brain walking explore legs | 5.49 | 4.14 |
| 20:09:07-20:15:41 | L2 fork b, brain | 5.47 | 4.13 |
| 18:16:52-18:20:00 | ClaudeDev, freshly loaded | 5.50 | 4.17 |
| 20:31:12-20:39:12 | course, water under 25 | **2.75** | 2.84 (food crossed 25) |
| 18:46:56-18:55:00, 20:41:52-20:47:00 | idle at 1 HP, food under 25 | 0 (empty) | **2.07** |

- **Activity makes no difference.** Idle, walking, the course and brain play all give the same rate to within 0.03/min. The game drains these bars on a clock.
- **The bottom quarter drains at half rate.** Under 25 % of the maximum, water falls 2.75/min and food 2.07/min. This is the component's `LastQuarterDecayRateMultiplier` 0.5. The component's `DecayRatePerHour` (5.5 water, 4.15 food) is the rate per real minute.
- **Time to empty, carrying nothing:**

| starting from | water empty after | food empty after |
|---|---|---|
| full (100) | 22.7 min | 30.1 min |
| the 95 % harness rescue | about 21.8 min | — |
| the 40 % fit gate (`chat_ladder.body_unfit`) | 11.8 min | 15.7 min |

- **At 0 water:** dehydration hits **5 HP every second** (status `dehydration`): 100 to 1 HP in 19 s (18:46:10-18:46:29, and again at 20:39). After that, HP holds at 0.5-1.5, with 1 HP dehydration ticks against regeneration. He held there for 45 min (18:46-19:31) and did not die. Any hit then kills him: the L2 forks that inherited this body were killed by Giant Rats at 19:38:11 and 19:40:42.
- **Rest (endurance)** falls about 0.77/min. Under 25 it caps food and water at 75 (DISCOVERIES).

**What these numbers correct in DISCOVERIES:**
- Line about 1038 gives "about 1.4 points per real minute". The real rate is 5.5.
- The 2026-11-01 line "drain at rest under 25: hydration 2.8/min, sustenance 4.2/min" mixes the two bands. 2.8 is water under 25; 4.2 is food above 25.
- Dehydration damage was 1 HP/s on 2026-11-01. It is now 5 HP/s.
- What still holds: thirst and hunger alone stop at about 1 HP and do not kill.

## 2. What he carried and when it ran out

**Chain 1:**
- The client switched back to ClaudeDev at 18:16:52, loading the bars from his 5-minute autosave (water 59.9, food 53.0).
- His stock was **4 Fillet and 3 Clean Water**. The fork cloned from him at 17:45 (ClaudeJ171745a) read the same at 17:50:08, alongside 1 Raw Stringy Meat and a GoblinPack, neither of which is edible.
- No brain ran on ClaudeDev after 17:29. During the body-only course windows (`jumpcourse-base`, `-runup`) the reflex used all of it at the 40 % policy line:
  - Clean Water at 18:20:29, 18:25:03 and **18:29:36 (the last)**;
  - Fillet at 18:20:02, 18:24:51, 18:29:41 and **18:34:33 (the last)**.
- From there: the first `no_drink` at 18:34:12 and `no_food` at 18:39:26; water 0 at 18:46:20 (HP 1 by 18:46:29); food 0 at 18:55:29.

**Chain 2:**
- The 19:43:51 rescue set the bars only (set_stat and set_health). His bag stayed empty.
- The L2 forks taken at 19:48 carried **5 Raw Stringy Meat and the GoblinPack, with no food or drink**. The meat came from somewhere between 18:16 and 19:48, probably rats killed on the course.
- On the brain's side, both forks did the right thing. Fork a heard `reflex_no_drink` at 19:56:55, boiled Clean Water at 20:01:42 and cooked Rat Roast at 20:02:50. Fork b heard it at 20:16:04 and drank boiled water at 20:17:09.
- **None of this came back to ClaudeDev.** Each fork's bag is its own save file.
- At 20:20:39 the client came back on ClaudeDev with the 19:48 bars (water 77.9, food 80.9) and the same empty bag. `no_drink` came at 20:27:34 and `no_food` at 20:30:32.
- Course window f (about 20:25-20:37) passed the fit gate at water 53 %, a level that lasts about 14.5 min with nothing to drink. Water reached 0 at 20:39:42, two minutes after the window ended.
- Window g was refused at 20:47 (exit 3). The rescue followed at 20:49:53, with the bag still empty.

**Note:**
- ClaudeDev.json is not only read: **the game autosaves it every 5 min** (written 20:55:49Z, with the .backup at 20:50:49Z). So every body-only window and every idle minute changes the job's start character's bars and bag. The 17:44:12, 17:47:38 and 18:16:52 loads all read the same 59.9/53.0 because no autosave ran on ClaudeDev in between.
- A world restore leaves his character alone (DISCOVERIES 17:44Z), so a world restore never refills him.
- **Off the server the bars do not drain.** ClaudeDev was off between 17:47:38 and 18:16:52 (29 min) and came back with the same values.

## 3. Did the reflex say anything?

**Yes to the log, no to anyone.**
- From 18:34 to 19:31 and from 20:27 to 20:49 the reflex wrote a `no_drink` / `no_food` row once a minute per kind, with a true reason ("no drink carried, hotbar or bag", `floor: true` under 10 %). That is 81 rows in the 19:00 hour alone.
- `client_bridge.lua` `forward_vitals` passes these rows to the brain as `activity` events (`reflex_no_drink`, `reflex_no_food`). With no brain connected they reach nobody: no chat line, and no harness reads them.
- A player on the server would have seen him stand at home at 1 HP for 45 minutes without a word. This breaks the communication rule (CLAUDE.md section 3) in the body-only case.

**Windows that ran on a starved body:**
- Course windows d (ended 19:05) and e (`jumpcourse-judge2`, 19:20-19:30) ran while he was at 1 HP, water 0 and food 0. They ran before `body_unfit` (3f32da0, 19:36Z) existed.
- At water 0 the game applies its stamina-regen scale and delay effects (HydrationEffectLevels, DISCOVERIES). Sprint and jump stamina in those passes may therefore differ from the other windows'.
- Whether to void those trials under rule 3 (harness fault) is the main session's call. At the least, they should be marked.

## 4. Does the brain's needs handling ever restock between windows?

**No.**
- **When the brain runs, it acts:** both forks above restocked within 1-5 min of the first `no_drink`.
- **On ClaudeDev:**
  - No brain has run on him since 17:29.
  - Body-only windows (`tools.travel_ladder`) and the idle time between windows have no brain.
  - Job windows play forks, whose gains stay in the forks.
- **The fit gate** looks at the bars at the start, not at what he carries or how long the window is. A body with no water passes at 40 % and is dry 11.8 min later. Today's course windows ran 12-20 min.

## 5. Root cause

The live body between windows, and during body-only windows, is ClaudeDev himself: the job's start character, on the server, with no brain. The reflex can only use what he carries. Nothing that runs there ever fetches food or water:
- the brain is down;
- the fork trials' gains never return to him;
- the rescue sets the bars, not the bag.

His last stock (4 Fillet, 3 Clean Water) went in the 18:16-18:34 course windows. After that, every stretch longer than about 22 min (from full) ends at 1 HP. The reflex's warnings are written down, and nobody reads them.

## 6. Options, ranked

**1. Body-only windows play a throwaway fork of ClaudeDev, topped up with `tools.supply`. Recommended.**
- What: `quest_clone fork` plus the character switch that `quest_run step` already does, then `tools.supply` (6 Fillet and 6 Clean Water through the dev `grant` fixture).
- The reflex then feeds him for the whole window the way it fed him from 18:16 to 18:34.
- **Rules it respects:**
  - Luis approved supply on 2026-11-01 ("every run give claude some food and water so he doesnt block testing"), and it is a dev-only harness fixture.
  - ClaudeDev stays the job's untouched start (rule 8, and "ClaudeDev.json is only read" in its intent).
  - The course measures movement, not survival.
- **Cost:**
  - One switch per window, about 1-2 min, using existing tools.
  - The rule that the live lock is held until the client is back on ClaudeDev applies, as in `step`.
  - About 30-60 lines in `travel_ladder` (or a shared "body-only window" wrapper).
- It also ends the drift in ClaudeDev's bag between windows (food eaten, meat gained), so L2 and I1 trials start from the same bag.

**2. Off the server when nobody is playing him.**
- What: when the live lock is released and no brain runs, the client leaves the world (main menu, or the server's player list empty). It rejoins at the next window's `client_boot`.
- Evidence it works: no drain off the server (17:47-18:16).
- **Rules it respects:**
  - A real player logs off when he walks away.
  - No grants, no spend.
  - It keeps "the lock is only released on ClaudeDev".
- **Cost:**
  - One rejoin per window, about 1 min. The client already relaunched 15 times in the 19:00 hour.
  - A "park" step in the lock release.
  - A watchdog rule so that a menu with the lock released is not treated as a fault and rejoined.
- It does not cover a window that is longer than his stock.
- Pair it with option 1.

**3. The reflex is heard when no brain is listening (communication).**
- What, on the first `no_drink` / `no_food` at the floor with no brain connected:
  - the client says it once in game chat, with the bar and the time to 1 HP from the measured rates ("Out of water at 8 %, about 3 minutes to 1 HP");
  - `travel_ladder`, `chat_ladder` and `job_run` read the reflex rows during a window and stop with a harness reason ("he says he has no water"), instead of measuring a dying body.
- **Rules it respects:** communication is paramount, and code reports outcomes.
- **Cost:**
  - Small: about 20 Lua lines for a status line to the existing `say` path, plus a tail on `vitals.jsonl` in the ladders.
  - Risk: a code-written chat line has to be a report only, never a decision.
- It does not feed him. It makes every case of not feeding visible.

**4. A stock-aware fit gate.**
- What: `body_unfit` also refuses (or calls `tools.supply`) when the minutes his carried food and water buy, plus his bars, at 5.5 and 4.15/min (half under 25 %), are fewer than the window's expected length.
- **Rules it respects:** rule 3 (a harness fault voids, never runs on), "gate before, not after".
- **Cost:** about 25 Python lines, using the measured rates.
- It prevents a window from outrunning the stock. It does not cover the idle gap.

**5. The brain up during body-only windows.**
- **For it:** it fixes the hole in principle. The forks show the brain restocks within 1-5 min of `reflex_no_drink`.
- **Against it:**
  - It costs model calls per window, and Haiku and Sonnet calls while he idles.
  - It changes what the course measures: the brain takes the body off the course to boil water. That breaks "one change per window, its number named first".
  - The idle gap would need a brain running at all times, against the $10/day guard.
- Not recommended for the course. It is the right state for real play.

**6. ClaudeDev's checkpoint carries food.**
- What: keep a pristine ClaudeDev with food and water, and restore it before each job window.
- **Against it:**
  - It writes ClaudeDev.json, which needs the main session's or Luis's call.
  - The game's 5-minute autosave overwrites it as soon as he plays.
  - The food is a hand-built bag at the job's start (rule 8).
- Only worth doing if option 1 is rejected.

## 7. Recommendation

Do options 1 and 2 as the structural fix, with option 4 as the cheap guard and option 3 for the communication gap. The single smallest change that stops today's two starvations is option 1, since both came from body-only windows emptying ClaudeDev's own stock. Option 2 closes the idle gap at no cost.

**Unseen-row log lines:**
- option 1: `supply: topped up fork ClaudeB… to 6 food / 6 water` in the window file;
- option 2: a `park: left the world (lock released, no brain)` line in the watchdog log.

**Live, at the time of this study:** at 20:59:24 he was on ClaudeDev at water 40.8 % with no drink carried. At the measured rates, water reaches 0 and HP 1 at about **21:11Z**, unless a window or rescue intervenes.
