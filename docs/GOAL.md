# The long-running goal: an autonomous companion that works things out himself

Luis set this on 2026-10-25. It is the contract for unattended iteration: what "done" means, how progress is measured, how dead ends are avoided, and when to stop and ask. PRINCIPLES.md stays binding; this file says what to optimise.

## 1. Definition of done (all measured by the benchmark and the observability tools; no self-assessment)
| Area | Target | Measured by |
|---|---|---|
| Spells: can cast | ≥ 95% of unlocked spells cast with the game-observed effect (not just runes spent) | T0 spell cases, auto-generated from spell data |
| Spells: can USE | each spell achieves its purpose in a situation that needs it, chosen by him without being told the spell name. Examples: Windstep up onto a ledge he can't jump; Phase Dash through an attack in combat; a Windstep landing that stuns low/medium mobs; Rocksplosion while mining; Splinter on felled logs; Axtral on trees; enchant the weapon with the type the enemy is weak to; Tempest Shield before a hard fight. ≥ 80% of the T1 "use" cases | T1 use cases generated from spell_effects.json purposes + situations |
| Stations and crafting | ≥ 90% of recipes craftable from scratch at their station (gather → process → craft) | T0/T1 craft cases from the recipe graph |
| Combat basics (proven live) | standard dodge (direction + evade) avoids a telegraphed hit; parry lands in the window; disengage, eat, re-engage; ranged hit rate ≥ 60% at 15 m on moving targets | T1 combat cases + server hit/parry/damage events |
| Combat tactics | prepares before a hard fight (gear, weapon for weakness, enchant type, shield, food) from creature data and wiki; times a dodge or Phase Dash to each attack's telegraph, learned per attack from outcomes; damage taken per fight drops over repeated fights with the same creature | T2 tactics cases (a dragon-class fight on the dev world) + the per-attack learning curve |
| Efficiency | resource/xp per minute within 70% of a scripted baseline (Luis's or an oracle run) on the same task; uses the abilities that speed the activity up; target and area selection improves over repeats | T1/T2 rate metrics + optimisation trend |
| Knowledge use | on cases that need a fact not in his perception (a recipe, where a resource is, a creature weakness, a quest step), he looks it up (game data first, then wiki), and the fact he acts on is correct | T1/T2 knowledge cases: lookup-needed vs not, judged by the trace |
| Thinking on his feet | ≥ 80% on adversarial cases (failure injection, vague chat, interruptions) | T1/T2 adversarial cases |
| Long tasks, unaided | each completes on the dev world with ≤ 1 player hint, then once live with Luis: (a) gather 50 coal (wiki + lodestones, multi-trip); (b) farm a mob drop with the right weapon; (c) upgrade gear one tier on his own initiative; (d) one Brynmoor quest chain from the wiki; (e) farm desert weed at "our farm" | T3 cases |
| Generalisation | held-out generated tasks within 10 points of the seen-task pass rate | generator holds out 30% of each batch |
| Speed | chat → first action p50 ≤ 2.5 s, p90 ≤ 4 s | `tools/obs.py metrics` |
| Voice | voice-eval score ≥ target; 0 stat narration and 0 talk-without-action per hour of play | voice eval + anomaly detectors |
| Stability | 2 h of play without a crash or a stall over 30 s | watchdog + anomalies |

## 1b. Milestones (run /goal one milestone at a time: `tools/goal_check.py --milestone Mn`)
- **M1 Foundation:** speed, voice, stability, no deadlocks, needs→options (no starving), T0 spells ≥ 95%, basic combat proven live.
- **M2 Use and tactics:** spells-USE cases, combat tactics, knowledge use, efficiency baselines.
- **M3 Director:** the task board; T2 multi-trip jobs (coal with lodestones, farm a mob drop).
- **M4 Long horizon:** gear progression on his own initiative, a quest chain, desert-weed farming, held-out generalisation, the live confirmations.
Each milestone has its own targets in goal_targets.json. The full goal = all four met.

## 2. The iteration loop (every cycle, in this order)
1. **Measure.** Run the benchmark (dev world first) and the observability metrics; append to `logs/evals/scoreboard.jsonl`.
2. **Pick** the biggest failure cluster (failures × impact on the targets above), from traces, not hunches.
3. **Root-cause** it from the episode trace (`tools/obs.py`). Write it in `docs/BUGS.md`.
4. **Design.** Write a design note with a Search record (≥ 3 sources; enforced by `tests/test_design_notes.py`) and get a fresh-context review against PRINCIPLES.md.
5. **Build.** Implement with a regression test; `tools/check_all.ps1` must be GREEN.
6. **Re-measure.** Keep the change only if its target metric improves and nothing else regresses; otherwise revert.
7. **Persist.** Commit; update BUGS, PROGRESS, DISCOVERIES and the scoreboard.

## 3. Rules that prevent dead ends and fake progress
- **Progress check:** if no target metric improves for 3 cycles, stop that line. Write a dead-end note (what was tried, the evidence), search for a different approach, and if that also stalls, ask Luis.
- **Time box per bug:** 2 failed fixes → re-research and redesign; 3 → park it with evidence and move to the next cluster.
- **No spoon-feeding / overfitting:**
  - benchmark tasks are phrased as chat, never tool names;
  - no task-specific code (the test_principles guards: no item, place or creature names in logic);
  - an **overfit detector** fails a diff that adds strings from benchmark task texts to brain/ or client_mod/scripts;
  - held-out tasks are never shown to the implementer.
- **The eval of the eval (predicate validity):** before a case counts, it must pass a positive control (a scripted or human run on the dev world achieves it) and a negative control (a do-nothing agent and a claims-only fake agent both fail it). Predicates read game state and events only, never the model's words. Weak proxies are banned (e.g. "runes spent" alone for a spell).
- **Live safety:** Shockbyte cases are short and low risk. Luis's character and other players are never touched. Announce restarts. Never reload the bridge with a command in flight. One live tester at a time.
- **Budget (Luis, 2026-10-25):** **$10/day hard cap** on model API spend (ANTHROPIC_API_KEY: the live brain, the Director, evals, generators). Spend is measured from logged token usage × list prices. At 80% → warn in PROGRESS and the scoreboard; at 100% → evals, generators and the Director stop, and the live Controller says he's out of thinking budget for today. State call counts before each benchmark run.
- **Dev world (Luis, 2026-10-25):** the local dev server is the autonomous test world. Anything goes there: fixtures, item/rune grants, spawns, time of day, resets, server mods, by the TEST HARNESS. Claude's own play still uses only real client paths, so the capability being measured is real. Never on Shockbyte.

## 4. Where this can go wrong (watch-list)
1. Goodharting a weak predicate → the eval of the eval, and spot audits of traces.
2. Overfitting to generated tasks → held-out sets, the overfit detector, the principle tests.
3. Mock/dev-world success that doesn't transfer to live → each tier needs a live confirmation before it counts.
4. Agents colliding (hot reload, shared files) → one owner per file; copy-ins only when the arbiter is idle.
5. Context loss across compaction → everything is in files (this file, BUGS, PROGRESS, scoreboard).
6. Game patches → RUNBOOK-patch smoke test first.
7. Things not observable (no visuals) → numeric traces for aim, projectiles and placement; Luis confirms visuals on request.
8. Cost runaway → budgets and call counts in the scoreboard.
9. Primitive gaps (lodestone teleport, storage, farming, quest dialogue) → the Director's capability-gap log drives the build order.

## 5. When to stop and ask Luis
- Binary or memory patching.
- Spending beyond the daily cap.
- Anything affecting other players or the Shockbyte world beyond Claude's own character.
- A dead end after re-research.
- Visual confirmation that data can't give.

## 6. Pointers
- Plans: `docs/design/autonomy-plan.md`, `docs/design/companion-quality.md`.
- In design or build: `docs/design/director.md`, `docs/design/eval-benchmark.md`, `docs/design/observability.md`, `docs/design/ranged-aim.md`.
- Bugs: `docs/BUGS.md`. Principles: `docs/design/PRINCIPLES.md`.
