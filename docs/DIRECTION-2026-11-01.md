# Direction after co-play session 1 (Luis, 2026-11-01): what he asked, and how we attack it

Read with `docs/RETRO-2026-11-01-coplay.md` (ranked root causes) and `docs/ISSUES-2026-11-01-coplay.md` (every
issue, with evidence). This file records Luis's direction so it survives context loss. It also records my analysis,
the plan, and the questions back to him. Research reports land in `docs/research/2026-11-01-*.md`.

## What Luis asked (his points, condensed, not reworded into something else)

1. **Document every issue** from the session: they are major blockers. "I wasn't able to truly test him, it was painful."
   The list: no grave recognition, pathing stuck, the cliff jump, no stack split, not knowing where Luis was, not
   knowing the temple, and ages between tasks and within them.
2. **Emulate his testing.** Analyse the kinds of requests he makes and emulate him, "then you need me less often".
3. **Building perception is a prerequisite.** "His character is just placing shit down randomly." Make it a task to
   iterate and test, and map what he can and can't do. Goals: square foundations for a flat surface, a crate, and
   storing items in it. Eventually a house, and a platform or stairs to the chest on the church roof.
4. **Telemetry for everything:**
   - time to complete each task, from the moment it is given, at every step;
   - where he idled 10-20 s, and why;
   - why he chose a tool call;
   - server and client data correlated.
   Luis suggested DBOS + Postgres for turn calls, "maybe not optimal, web-search the latest idioms".
5. **Pickup analysis:** count the tries, misses, adjustments and small moves. "A human would grab sticks whilst
   running, so seamless. He runs to a stone, stops, stares at it 5 s, tries, adjusts a few times, then grabs it."
6. **Efficient needs, not reflexes.** "Low food -> berries" is wrong. The question is "what's the most efficient way to fill
   my hunger?": sticks + stone -> club -> kill animals -> cook meat beats berries for 0-100 food. That detour is
   worth it once pickups and interaction are efficient.
7. **Background knowledge from the wiki or game data:**
   - he should have his own campfire and crafting table;
   - a spinning wheel, flax -> string;
   - farming (plots, spade, seeds, water from a well or rain catcher, compost bins);
   - foresight: "I'll need more flax later, so I'll build plots now".
   All of it without wiring in edge cases: give him the tools and knowledge to work it out.
8. **Ranged and magic** are an extreme but valuable challenge:
   - real-time lock-on (the game has one: X);
   - tracking the target, bullet drop, crits;
   - making a bow or crossbow from flax.
   Evaluating it needs hit feedback (archery targets?).
9. **The quests remain the backbone.** The Wise Old Man storyline and side quests force competence and expose bugs.
   But "question me: what should he be able to do seamlessly to play this game?". Examples: combat styles, looking up
   armour ingredients, knowing his armour is low for his power level, planning all of a recipe's ingredients, using
   the wiki and finding that place in game.
10. **Evals are the hardest and most valuable thing.**
    - Pass only to a human standard: speed, no misses, no jitter.
    - Be an adversary to every "passed": to what standard?
    - Combat must be fluid, not "stood there like an idiot getting pounded by a goblin". The many gravestones near
      the goblins suggest this has happened a lot.
11. **No token-burning death loops.** Iterate fast on the real client and server, review evals adversarially, and stop
    an approach that isn't working and try another. Don't be afraid to delete code that's wrong. Step back: "maybe
    we built machinery around an operation that isn't efficient and need to tear it out".
12. **Question him.** He may be prescribing what he thinks might work; the end goal is a competent player.
13. **Live is the eval.** "Codex got into the trap of writing loads of code and offline tests. They mean nothing if the
    character doesn't show the behaviour in game. Keeping that client busy and working is the real eval, and it tells
    us straight away whether it ACTUALLY works." The adversarial pass asks: he did the task at a high level, but did
    he REALLY do it properly, to the standard of a real player, or would it be the same painful experience when Luis
    tests it?
14. **Open source only, nothing paid** (LangSmith, the Logfire SaaS: out). Self-hostable OSS is fine; otherwise close
    the gaps ourselves.

## What the session data says (2026-11-01, measured)

- **The brain is not the slow part:**
  - model calls take 0.8-2.6 s each (mean about 1.3 s);
  - first words come 2-5 s after a line;
  - the first action comes 2-4 s after a line.
- **The body is the slow part:** body requests take 20-190 s, often end in failure, and needed Luis to steer.
  Examples: 135 s for a pickup request; 189 s for the temple trip, 147 s of it silent.
- **Missing human affordances:**
  - the compass (players at any distance);
  - accepting what the interact prompt highlights;
  - build preview/snap feedback;
  - lock-on;
  - his own encumbrance and capacity.
  We rebuilt these from raw traces, slowly and wrongly, instead of reading what the game shows a player.
- **The ladders measured the wrong thing:** 8/8 on clean single lines from a pawnless sender, against about 4/14 in free
  play with a person.

## How others succeeded at this, and what we take from it

- **Mindcraft / Voyager (Minecraft): a mature body library.** Mineflayer has pathfinder, collectBlock, pvp and
  auto-eat. The LLM only picks and parameterises skills, and the skills are robust because the library is. Ours is
  hand-built, so **each body skill needs its own fast, model-free ladder timed against a human**. travel_ladder does
  this for walking; we need the same for pickup, combat, build and inventory.
- **PUBG Ally (KRAFTON + NVIDIA ACE): an event-driven LLM over a fast gameplay layer.** Beta players reported
  hesitation, delayed responses and unfinished tasks, which is exactly what Luis saw. **The fix is in the gameplay
  layer and in reporting progress, not in a bigger model.**
- **GITM / DEPS: knowledge-driven decomposition.** Recipes and knowledge let the planner choose a route. For food and
  farming, the idiom is **GOAP-style options with costs, generated from game data** (recipes, food values, sources),
  compared by the model or planner. These are not hand-written rules, which answers point 7 without edge cases.
- **τ-bench and similar: an LLM user simulator** for interactive evals. That is our **Luis emulator**, seeded from his 119
  real lines, together with a **server-side tester pawn** so that "come to me", "near me" and "give" can be emulated
  without him.
- **Embodied-AI metrics:** success weighted by efficiency (SPL-style), time vs a human baseline, attempts per success,
  idle ratio.
- **Observability:** the OpenTelemetry GenAI conventions for agent, tool and LLM spans. My early read on DBOS:
  it gives durable workflow execution (resuming after a crash), not analysis. What we need is a trace of every
  step with shared ids, and queries over it. The telemetry agent is checking this, and its verdict goes in
  `docs/research/2026-11-01-telemetry.md`.

## The plan (in order; each step is measured, and an approach is dropped after 3 live iterations that don't move its number)

1. **The measuring kit first:**
   - **Session timeline report.** `tools/session_report.py`: per request, time to first word, time to first action,
     every step, time to complete; idle gaps over 5 s with their cause; pickup attempts and misses.
   - **The missing telemetry.** One correlation id from the chat line to the body's move trip; 1 Hz position and
     state samples from the client; pickup attempt events.
   - **Body skill ladders, model-free and timed.** Covering pickup (clusters, overlapping hitboxes, water edges),
     combat (fight back when hit), build (piece where asked, verified), inventory (split, store) and grave
     recovery. **Human baselines from Luis** (see Q2).
   - **Luis emulator + tester pawn.** Sessions without Luis count.
2. **The fixes in flight:**
   - pickups;
   - players from the compass registry and "near me";
   - chat no longer cutting actions;
   - truthful builds (done);
   - combat;
   - grave memory (done);
   - explore drops (done).
   Each is re-run on its skill ladder against the human standard. A cold reviewer then attacks the "pass".
3. **The seamless basics** (the first competence rung, the prerequisite for every quest):
   - pick up while moving;
   - come and follow from anywhere;
   - fight back when hit;
   - recover his newest grave;
   - feed himself sensibly by comparing options;
   - an own campfire, table and crate where asked;
   - store items; split stacks;
   - rest when exhausted and say so.
4. **Building perception** (in progress, `docs/research/2026-11-01-autonomous-building.md`):
   - heights, his own pieces and free snap points in his context;
   - attaching to a snap point;
   - `site` and `climb_to`;
   - small blueprints;
   - then the church-roof chest.
5. **Knowledge and planning:**
   - options with costs from game data (food, recipes, sources, stations);
   - Sonnet plans multi-step routes (club -> kill -> cook; flax -> plots);
   - the quests as the backbone (competence map: `docs/research/2026-11-01-competence-map.md`).
6. **Ranged and magic:** a feasibility study first (lock-on, projectile data, hit feedback), then a dummy-target ladder.

## Questions back to Luis

1. **DBOS + Postgres:** I'd rather not. It solves crash-resume, not "what happened and why". My early proposal: keep
   the JSONL we already write, add shared ids and 1 Hz samples, query with DuckDB, and render a per-run timeline.
   We'd use OpenTelemetry GenAI field names so we can plug in Phoenix or Langfuse later if we want a UI. This is pending
   the research verdict.
2. **Human baselines:** would you spend about 10 minutes doing a fixed set of tasks while my client records you, so
   "human standard" is a number, not a guess? Pick up 10 sticks and stones, kill 3 kebbits, build table + fire + crate,
   go to a named place, recover a grave.
3. **Order:** I agree the quests are the backbone, but the seamless basics (step 3) come first, because every quest
   needs them. Ranged and magic come after melee and the basics. Do you agree?
4. **The goal:** the current /goal (Rung 2 with "80% of requests completed") would pass a bot that is as painful as
   today's, so I'd replace it. Proposed text below.

## Proposed /goal (for Luis to set or edit)

"Make Claude a competent co-player to a human standard on the dev world. First the measuring kit: per-run telemetry
(time to complete, idle gaps and their cause, pickup misses, the context of every tool call), model-free body skill
ladders timed against Luis's own baselines, and a Luis emulator (an LLM tester plus a server-side tester pawn), so most
sessions need no human. Then fix worst-first until the basics pass to the human standard 3 runs in a row:
- pick up nearby items (<= 1.5x human time, <= 1 miss each);
- come and follow from anywhere;
- fight back when hit;
- recover his newest grave;
- feed himself by comparing options;
- build table + fire + crate where asked and store items in it;
- split stacks;
- rest when exhausted.
Every report is truthful (LLM judge). Keep Rung 1 green. Drop an approach after 3 live iterations that don't move its
number. Stop at the $10/day cap or for Steam Guard."
