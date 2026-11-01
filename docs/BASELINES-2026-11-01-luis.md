# Human baselines: Luis's recorded run (2026-11-01, 12:40-13:21 UTC, dev world)

Luis played 41 tasks on the dev server and marked each one in chat (`start <task>` ... `done`/`stop`). The server's
read-only recorder captured him the whole time: position 5 times a second, every inventory change, and every action
he sent to the server. These are the bars Claude is judged against: **the same task, live, at about 1.5x his time or
better, with the misses and idle a player would have**. Claude's first co-play session for comparison: a club took
about 12 min with steering, "pick up the sticks/stones" 135 s, "kill 3 kebbits" 94 s ending in a death, a crate placed
twice (see `docs/RETRO-2026-11-01-coplay.md`).

- Data: `evals/baselines/rec_luis_20261101T123634Z.jsonl.gz` (the recording, a backup of the read-only
  `logs/recorder/rec_20261101T123634Z.jsonl`) and `evals/baselines/chat_luis_20261101.jsonl.gz` (his chat lines).
- Per-task numbers (machine-readable, read by the scorer): `evals/baselines/luis_20261101_tasks.json`.
- Regenerate, or measure a Claude run the same way: `.venv\Scripts\python.exe -m tools.baseline_tasks --player
  <name> --rec <recording> --chat client_io\events\chat.jsonl --json <out>` (parser: `tools/recorder_motion.py`).

## What a real player looks like (the patterns to copy, not just the times)

1. **He picks things up on the move.** In the pickup tasks, 85 of 97 presses happened while he was moving, and 85
   presses got an item. Dense clusters go at about one item a second: sticks 11 in 10 s, water 12 in 14 s,
   cabbage 6 in 7 s, rocks 15 in 22 s. On the walk back to his base he grabbed berries, fur and flax on the way, and
   killed kebbits that were on his route, without being asked.
2. **He starts at once.** The median time from his `start` line to his first movement or press is 1.2 s. For Claude
   the clock starts at the request, so the bar allows model latency: first action within about 3 s.
3. **He runs.** Moving speed is 5.0-6.7 m/s on every long task (sprinting). Claude in session 1 walked 1.6-2.2 m/s at
   endurance 0 and never said so.
4. **Standing is fine when it is work.** Chopping (13 logs in 47 s, 42 s standing), crafting at the bench (axe 11 s,
   pickaxe 6 s, club 8 s), building and farming are mostly standing. Bad standing is standing without work.
   Use the presses and inventory changes during a stand to tell which is which.
5. **He plans from knowledge.**
   - Kebbits drop no meat (fur and skin scraps), so for food he hunted chickens (3 in 67 s, 384 m) and a cow
     (74 s, 14 meat), then cooked.
   - The spade needed string, so the spinning wheel came first, then flax to thread.
   - The tannery gave leather, which went into armour.
   - Water: he gathered dirty water and boiled it.
   - Farming: he built 6 plot pieces in 13 s, then planted, watered with a watering can, and composted.
6. **Building is quick.**
   - The crafting table and firepit took 11 s (2 pieces).
   - A foundation of 8 pieces took 21 s.
   - The base took 146 s (24 pieces, with steak and logs gathered in between).
   - The tannery took 35 s.
7. **Fights are short.** A goblin took 11 s. With the bow: 5 arrows about 5 s apart, 3 kills (2 birds and a game
   animal) in about 35 s, and he picked an arrow back up.
8. **Spells:** splinter, rocksplosion, astral projection and trunk totem took 10-28 s each, including finding a
   target. The second splinter gave 112 ash logs in 22 s.

## The bars for Claude (applied by the scorer to every live run)

- Duration of each task at most 1.5x his (the table below), measured from the request to the verified result.
- First action within about 3 s of the request.
- Pickups: at least 75% of presses while moving in a cluster, and at most 1 miss per item. "Miss" means a press that
  gets nothing; opening a station also gets nothing, so it doesn't count in a crafting task.
- Moving speed of at least 4.5 m/s when endurance allows. Otherwise he must say that he's exhausted.
- No stand longer than 5 s without work (a press, an inventory change or a cast) unless he says why.
- Everything he reports is true, judged against these same recordings (LLM judge).

## Every task

Columns:
- **start**: UTC.
- **s**: duration in seconds.
- **first**: seconds to his first move or press.
- **m**: metres travelled, excluding teleports.
- **move / stand**: seconds moving / seconds standing.
- **E presses / got / moving**: interact presses / presses that gained an item within 1.5 s / presses made while
  moving.
- **other actions**: server RPCs.
- **gained**: the top items gained.

| start | task | s | first | m | move / stand | E presses / got / moving | other actions | gained |
|---|---|---|---|---|---|---|---|---|
| 12:40:22 | gather water | 14 | 0.4 | 75 | 13 / 1 | 12 / 8 / 12 | - | Water Dirty 12 |
| 12:40:41 | sticks | 10 | 1.1 | 33 | 8 / 2 | 13 / 10 / 13 | - | Wood Ash 11, Water Dirty 2 |
| 12:40:58 | stones | 18 | 0.8 | 47 | 11 / 7 | 10 / 9 / 4 | - | Stone 8, Wood Ash 1 |
| 12:42:07 | pile | 23 | 3.7 | 3 | 1 / 22 | 1 / 1 / 1 | drop 8 | Stone 8 |
| 12:42:39 | split | 10 | - | 0 | 0 / 10 | 0 / 0 / 0 | split_put 1, drop 1 | - |
| 12:43:11 | craft axe | 11 | 1.1 | 6 | 1 / 10 | 1 / 0 / 0 | craft 1 | Logging Axe Stone 1 |
| 12:44:15 | chop | 47 | 1.2 | 22 | 5 / 42 | 0 / 0 / 0 | - | Wood Ash 13 |
| 12:45:06 | gather rocks | 22 | 1.1 | 89 | 16 / 6 | 15 / 14 / 12 | - | Stone 15 |
| 12:45:38 | make pickaxe | 6 | 0.7 | 8 | 1 / 5 | 1 / 0 / 0 | craft 1 | Pickaxe Stone 1 |
| 12:45:50 | boil water | 14 | 0.4 | 11 | 3 / 11 | 2 / 0 / 1 | move 2, use_item 1 | Water Clean 2 |
| 12:46:17 | splinter | 28 | 19.8 | 15 | 2 / 26 | 0 / 0 / 0 | - | Wood Ash 4 |
| 12:46:52 | sleep | 28 | 0.9 | 31 | 6 / 22 | 1 / 0 / 0 | - | Water Clean 10 |
| 12:47:20 | mine rock | 15 | 0.8 | 15 | 2 / 13 | 0 / 0 / 0 | - | Stone 10 |
| 12:47:40 | rocksplosion | 13 | 6.8 | 5 | 1 / 12 | 0 / 0 / 0 | - | - |
| 12:48:04 | astral projection | 13 | 4.0 | 5 | 1 / 12 | 0 / 0 / 0 | - | Wood Ash 1, Farming TreeSeed Ash 1, BirdNest 1 |
| 12:48:41 | trunk totem | 10 | 7.9 | 10 | 1 / 9 | 0 / 0 / 0 | - | - |
| 12:48:55 | splinter | 22 | 11.6 | 58 | 8 / 14 | 0 / 0 / 0 | - | Wood Ash 112 |
| 12:49:20 | foundation | 21 | 1.7 | 32 | 8 / 13 | 0 / 0 / 0 | build_spawn 8 | - |
| 12:50:02 | crafting table and firepit | 11 | 2.6 | 8 | 3 / 8 | 0 / 0 / 0 | build_spawn 2 | - |
| 12:50:28 | club | 8 | 3.1 | 1 | 0 / 8 | 1 / 0 / 1 | craft 1 | Club Stone 1 |
| 12:50:47 | hunt (kebbits) | 36 | 2.1 | 123 | 22 / 14 | 0 / 0 / 0 | use_item 1 | Wood Ash 15, Coarse Animal Fur 4, Skin Scraps 1, Weeds 1 |
| 12:52:03 | cook | 22 | 0.9 | 4 | 1 / 21 | 1 / 0 / 1 | - | - |
| 12:52:25 | hunt chicken | 67 | 1.2 | 384 | 60 / 7 | 0 / 0 / 0 | - | Meat Bird 3, Feathers 3, Egg 3 |
| 12:53:35 | pick flax | 26 | 1.3 | 132 | 23 / 3 | 3 / 3 / 2 | - | Flax 3 |
| 12:54:18 | kill goblin | 11 | 0.9 | 18 | 7 / 4 | 0 / 0 / 0 | - | GoblinPack 1 |
| 12:54:39 | pick up cabbage | 7 | 1.0 | 30 | 5 / 2 | 6 / 6 / 6 | - | Cabbage 6 |
| 12:54:51 | kill cow | 74 | 1.5 | 184 | 44 / 30 | 0 / 0 / 0 | use_item 1 | Animal Hide 15, AnimalBone 14, Meat Farm 14 |
| 12:56:27 | return back to foundation | 89 | 4.3 | 384 | 62 / 27 | 6 / 6 / 6 | - | Fruit Redberry 6, Skin Scraps 5, Coarse Animal Fur 5, Flax 3 |
| 12:57:59 | cook | 23 | 1.1 | 16 | 5 / 18 | 2 / 0 / 0 | move 2, use_item 1 | Farm Steak 1 |
| 12:58:24 | make base | 146 | 4.2 | 194 | 37 / 109 | 11 / 9 / 11 | build_spawn 24 | Farm Steak 13, Wood Ash 12 |
| 13:02:14 | make plot | 13 | 2.3 | 17 | 5 / 8 | 0 / 0 / 0 | build_spawn 6 | - |
| 13:02:32 | make spade | 47 | 0.3 | 50 | 12 / 36 | 3 / 0 / 1 | build_spawn 1, move 1, craft 1 | Thread Coarse 2, Spade T1 Wood 1 |
| 13:03:58 | farm | 176 | 0.5 | 277 | 50 / 126 | 18 / 2 / 9 | craft 2, build_spawn 1, use_item 4, move 2 | Weeds 6, Water Dirty 3, Bucket Compost 1, WateringCan Wood 1 |
| 13:07:34 | general gather | 247 | 1.0 | 1371 | 206 / 41 | 32 / 29 / 30 | drop 1, use_item 2 | Flax 14, Fruit Redberry 9, Cabbage 8, Meat Bird 5 |
| 13:11:45 | make thread | 56 | 0.4 | 79 | 13 / 43 | 2 / 1 / 2 | move 1 | Thread Coarse 13 |
| 13:13:43 | make tannery | 35 | 1.4 | 20 | 5 / 30 | 1 / 0 / 1 | build_spawn 1, move 1 | Leather 3 |
| 13:14:43 | more farming | 126 | 5.7 | 208 | 41 / 84 | 10 / 0 / 6 | move 2, use_item 2 | Weeds 12 |
| 13:17:13 | animal fur to thread | 22 | 0.7 | 4 | 2 / 20 | 1 / 0 / 1 | move 1 | Thread Coarse 2 |
| 13:17:41 | make armour | 33 | 1.6 | 0 | 0 / 32 | 1 / 0 / 0 | craft 2 | Armour T2 Body Reinforced 1, Armour T2 Head Reinforced 1 |
| 13:18:25 | make bow | 25 | 0.7 | 0 | 0 / 25 | 1 / 0 / 0 | craft 3 | Arrows Stone Bodkin 528, Longbow Wood 1, Shield Wood 1 |
| 13:20:20 | use bow | 39 | 1.3 | 86 | 16 / 24 | 0 / 0 / 0 | - | Meat Bird 2, Feathers 2, Egg 2, AnimalBone 2 |

## Caveats (read before comparing)

- **Spells and attacks don't show as actions.** The recorder's ability hook never fired: the game activates
  abilities by another call. Shots are counted from arrow changes, and kills from loot. The hook will be fixed at the
  next server restart.
- **"pile"** was 8 stones dropped one at a time, then 1 press that picked up all 8. A dropped pile is one pickup.
  **"split"**: one split, then one drop, in 10 s.
- **"kill cow"** gained 15 hides and 14 meat, so it was probably several cows in a herd.
- **"make bow"** shows +528 stone bodkin arrows. That is either a large craft batch or a stack moved in; check before
  using it as a bar.
- **His inventory and stations were his own.** He had the materials and the knowledge (where the cows and flax
  are) at the start. A Claude run should start from comparable stock, or be scored on the steps that match.
- Times start at his `start` line, which he typed just before acting. Claude's start at the request instead, so
  model latency is included in his bar's 1.5x.
