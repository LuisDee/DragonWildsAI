# Capability benchmark: hard tasks that prove he can work things out himself

Status: **rev 2**, after the review `docs/reviews/2026-10-25-eval-benchmark-review.md` (APPROVE WITH CHANGES; all 21 findings are applied below; the table in §0 maps each one). Author: the Eval agent, 2026-10-25.
Build order: the mock pieces first (spec, leaves, BenchWorld, runner, controls as "lint"). `goal_check` may gate `/goal` only after the Critical items (§0 rows 1–6) are built and Luis has tagged the judge (§9.3).
Related: GOAL.md (§1 targets, §1b milestones, §3 rules), director.md (shared predicates), autonomy-plan.md, companion-quality.md, tools/scenario_run.py, data/spell_effects.json (spells agent).

## 0. Review changes (rev 2)
| # | Finding | Resolution (section) |
|---|---|---|
| 1 | Evidence self-reported by the code under test | A **harness-owned observer**: `bench_probe` on the client (read-only) plus a **server referee** on dev (read-only `mod/bench/referee.lua`). A leaf passes only when the probe delta and the skill reply agree; otherwise `sensor_mismatch`. A server audit per evidence kind gives "audited x/y" or "unaudited". Tallies are the benchmark's own (§4.1) |
| 2 | Shrinking denominators | **Frozen, data-derived manifests per build.** Only `pass` counts; unverifiable, skip, error and invalid all count against. A rise in n/a or unverifiable is flagged (§5.0) |
| 3 | Mock validity doesn't transfer | Validity only **on the scoring target**, keyed by case, judge, body and build hashes. Mock controls are renamed "lint" and never reach goal_check (§6) |
| 4 | Missing Goodhart controls | Controls `wrong_action`, `alt_means`, `partial` and `ambient` (plus `claims_only`) on the scoring target. Leaves tightened: attribution windows, travel = displacement within 2 s of the cast, `vital_change` with a direction, exact kind ids, generic GE/tag evidence rejected (§4.2, §6) |
| 5 | Judge writable by the judged | goal_check **re-derives** every metric from raw run directories (sha256-checked). Judge and companion hashes are recorded and printed. A **Luis-approved judge tag**; a judge diff since the tag = NOT MET. A deny rule plus a PreToolUse hook on judge files while `/goal` runs (§9.3) |
| 6 | `GOAL MET` printable without the goal | Subsets print only `MILESTONE Mn ...`. The full line is `GOAL MET sha=… judge=… runs=… at=…`, printed only on a clean tree at the measured hash. Test mode prints `GOAL MET (TEST)`. Luis's sign-off is the last gate (§9.4) |
| 7 | Small n, no error bars | Minimum n per target. The **Wilson 95% lower bound** must reach the target, and the interval is printed. Only full manifest runs count (`--only` = partial). Long tasks run k ≥ 3, with pass^k reported. Paired comparisons for loop step 6 (§8.2) |
| 8 | Held-out not sealed | The GOAL generalisation number comes from a **fresh post-freeze draw** seeded by HEAD. Rolling held-out runs are aggregate-only, logged to a separate root, with a deny rule and hook. The overfit test prints hashes only. Dedupe across the split. A **Luis-authored held-out set**. Stratified split, with the floor "held-out ≥ seen − 10" at its lower bound (§5.4) |
| 9 | Memory contamination | A **frozen state snapshot per case** (`DW_STATE_DIR` temp copy, `DW_WORLD_GUID=bench_<run>_<case>`). The run refuses if the store resolves to Shockbyte's. An explicit "with memory" variant measures learning (§7.3) |
| 10 | Predicates don't match the text; GOAL cases generated | GOAL-required cases are **hand-written** (drafted by Eval, reviewed by main and Luis, hashes pinned). A frozen **metric → case-selector table**. Craft uses no input fixtures, with a seeded depth-stratified sample. An independent predicate audit. Delivery, trips and lodestone leaves; a bag limit in BenchWorld (§3, §5.3, §8.1) |
| 11 | Targets without leaves | Combat leaves from referee events: `damage_type_dealt`, `defended`, `disengaged`, `prepared`. **Process metrics** (they never decide success) for knowledge use, efficiency and the damage trend (§4.3, §8.1) |
| 12 | Live confirmation contradicts GOAL | A separate **live-confirmation protocol**: Luis present, only his real chat, nothing injected; the target is proven from the trace; Luis records the confirmation himself (§7.4) |
| 13 | Fixture safety | (a) Non-circular address checks before every setup call and action. (b) Target by GUID, and refuse if other players are on. (c) **A dedicated dev character**, else a restore from backup with the client closed, and a hard alarm on any Shockbyte diff. (d) The lease renewed every tick, ≥ wall_s + margin; the brain killed on a server change. (e) No Shockbyte path. (f) Fixture verbs in one frozen, reviewed file. Watch for a run_live restart (§7.2) |
| 14 | Budgets can't run the suite | Per-tier call and wall budgets; three cadences (per-cycle smoke, nightly full, batched live); full-run numbers stated; hash freshness (§10) |
| 15 | Wall-clock freshness, mixed commits | Fresh = measured at the current companion hash and game build. Mixed hashes = NOT MET. Wall clock applies to obs only (§9.2) |
| 16 | Guards | A null guard → unverifiable (not passed). Guards are event-driven (referee and body events). One `lost` shape (§4.4) |
| 17 | Latency gameable | Real-model dev and live runs only; `stop`, `say` and `remember` excluded; a second figure (first action of the plan that passed) (§8.1, obs) |
| 18 | Obs without exposure | A minimum of **active** play hours at the current hash (brain on, tool calls per hour, real player chat), reported next to each value (§9.2) |
| 19 | Suite drift | **Versioned suite manifests**; new cases go to a candidate pool; trends only across identical manifests (§5.0) |
| 20 | Phrasings and hints | A held-out phrasing per spell. A fixed **hint ladder** L1 nudge → L2 pointer → L3 answer, with the level recorded (§3, §5.1) |
| 21 | Search record gaps | Added: BIG-bench canary, LiveBench, Miller's error bars, METR reward hacking, ImpossibleBench, SWE-bench Verified, the `/goal` docs |

GOAL.md revisions (c6d9c90, after rev 1) are folded in: spell **use** (§5.2), combat basics proven live and tactics (§4.3, §5.3), efficiency and knowledge use (§8.1), milestones M1–M4 (§9).

## 0b. Rev 3: scope changes from Luis (2026-10-25 late) and build status
**Scope changes** (GOAL.md §1b and goal_targets.json at commits 0d7115b and 899c88f):
- **Scoring world = the DEV server** (the real game build, real client and server, a dedicated dev character).
  - Shockbyte is forbidden during /goal. Live confirmation is no longer required, so §7.4 is optional.
  - goal_check counts rows only where `target == scoring_world.world`, with real models (`run.json llm == "real"`).
  - `min_live_cases_per_family` is read as "real-model dev cases".
- **Milestones M1–M6:**
  - **M3 every_skill:** 12 skills from the game data (SKILL_* in perks and recipes) × three modes (asked, initiative, plus5), each verified by the harness probe's XP and levels.
  - **M6 capstone:** the Brynmoor progression stages, plus `slay_velgar_solo` on dev.
- **The every-spell stress suite.** Each manifest spell is run under five situations:
  - combat;
  - cooldown pressure;
  - low runes, with runes lying nearby;
  - target out of reach;
  - moving target (dev only).
  Each runs ×3 repeats. The report has a per-spell table: reliability, latency p50 and failure reasons.

**Built (offline-tested; all green except the noted RED test):**

| Area | Status |
|---|---|
| `evals/bench/` | spec, hashes, leaves (12 + `casts`, `xp_gained`), observer, BenchWorld, agents (companion + 6 controls), runner (plan/run/controls/lint/generate/report), report (Wilson, McNemar, per-spell), generator (T0, use cases, stress, proposer with audit and repair, stratified split, dedupe), goal_drafts |
| Cases | 39 T0 spell cases plus a 13-spell n/a list (data-derived); 38 spell-use cases (2 mock-runnable suite, 36 drafts that need a phrasing, dev scene or observability); 127 stress cases; 60 GOAL drafts in `evals/bench/goal_cases/` |
| Mock lint | 22 of 39 T0 proofs are observable. The other 17 are perception gaps (`needs_live_observation`, enchant held effect, generic GE only for Personal Chest / Eye of Oculus) and count against the target |
| Dev side | `client_mod/commands/bench_probe.lua` (read-only); `mod/bench/referee.lua` (read-only polling of damage, death, item changes and teleports; UNVERIFIED on dev); `mod/bench/fixtures.lua` (frozen verbs; only `spawn` uses a verified primitive, every other verb answers `unverified`); `mod/scripts/bench.lua` (the debug_run entry). The dev target in the runner refuses to run until these are verified on dev with main's go-ahead |
| goal_check v2 | All of §9, M1–M6, the gates and the exact lines (25 tests) |
| `tools/hooks/judge_guard.py` | 21 tests; main installs it |

**A decision rule that can't be met (for Luis).**
- With a Wilson 95% lower bound, a 95% target needs about 74 all-pass trials, but the spell manifest has 39 spells. Even 39/39 gives a lower bound of about 91%, so `spells_effect_coverage_pct` can never be MET as written.
- Options:
  - (a) count k = 2 repeats per spell as trials (78/78 → lower bound 95.3%);
  - (b) apply the point estimate with n ≥ 39 for that target;
  - (c) lower the target.
- `craft_from_scratch_pct` (90%) needs n ≥ 35 all-pass.

## 1. Goal (what Luis will see)
- One command runs a suite of tasks phrased as a player would say them ("can you get me 50 coal? use the lodestones if it's far"). Each task is scored only from **independently observed** game state and events: never from what Claude says, and never from his own skill's claims alone.
- **The run report** (`logs/evals/<date>/<run_id>/report.md` + `report.json`) holds:
  - the coverage matrices: spells (cast / use), stations and recipes, creatures and weaknesses, combat basics;
  - pass rates, each with a Wilson interval and a minimum-n check;
  - latency, model calls and cost;
  - failure clusters (seen cases only);
  - perception gaps (unverifiable);
  - predicate validity;
  - the trend across identical suite manifests.
- **"Every spell usable"** is two numbers over a frozen build manifest:
  - **cast with the observed effect** (T0);
  - **used for its purpose** in a situation that needs it, without being told the spell's name (T1).
- **`tools/goal_check.py`** grades `docs/goal_targets.json` milestone by milestone. It prints exactly one of:
  - `GOAL MET sha=… judge=… runs=… at=…`, only when everything is met, confirmed, at the current hash, on a clean tree, under Luis's judge tag;
  - `GOAL NOT MET (M1 x/y, …, focus=Mn)`.
  After a GOAL MET, Luis's own "done" is the last gate.
- The suite grows itself. A Sonnet proposer drafts new hard cases into a candidate pool. Cases join the scored suite only at a manifest bump, and only after their controls have run on the scoring target.

## 2. Files (owned by the Eval agent unless noted)
| File | Owns |
|---|---|
| `evals/bench/spec.py` | The case spec (pydantic), its lint (chat language, no tool names, no `USD_`/`ITEM_`/`BP_` ids), `case_hash` |
| `evals/bench/leaves.py` | Benchmark leaves registered into `brain/predicates.py` (Director-owned; `register()`) |
| `evals/bench/observer.py` | **The harness observer.** It wraps any `GameInterface` (mock or bridge) and probes before and after every world-changing call. On the mock it reads BenchWorld's true state; on dev and live it calls the client probe and, on dev, the server referee log |
| `client_mod/commands/bench_probe.lua` | **Needs main's OK** (it is client Lua, though a read-only command and not `scripts/`). It reads inventory counts, pawn GE classes and tags, `LastCastTimeBySpellData`, position, held item and held effects, vitals, skills, and census rows within r (class, id, position, health) |
| `mod/bench/referee.lua`, `mod/bench/fixtures.lua` | **Dev server only, needs main's OK.** The referee is a read-only server-authoritative event log (damage dealt and taken with type, parry and dodge outcomes, deaths, item grants and inventory changes, teleports, crafting completions). Fixtures are the frozen setup verbs (§7.1) |
| `evals/bench/world.py` | `BenchWorld(MockGame)` from the catalogs: spells with runes, cast types and effects per module; bag capacity; creatures with kind ids, weakness and telegraphed attacks; lodestones; a deposit chest; a fault switch for a "lying body" (to test `sensor_mismatch`). Crafting reuses the Director's `GearWorld` when present |
| `evals/bench/agents.py` | `companion` (the real LiveAgent stack), controls (`oracle`, `do_nothing`/`ambient`, `claims_only`, `wrong_action`, `alt_means`, `partial`) |
| `evals/bench/runner.py` | `python -m evals.bench plan|run|controls|generate|report|compare|freeze` |
| `evals/bench/generator.py` | T0 from data; the T1–T3 proposer and adversarial transforms; the predicate audit; dedupe; the stratified split; the post-freeze fresh draw |
| `evals/bench/report.py` | Matrices, Wilson intervals, pass^k, the trend over identical manifests, paired comparisons |
| `evals/bench/manifests/<build>/` | Frozen suite manifests and n/a lists (judge files) |
| `evals/bench/cases/` | Seen cases (committed). `evals/bench/goal_cases/`: the hand-written GOAL cases (pinned) |
| `tools/goal_check.py`, `tools/goal_confirm.py` | The grader; the live-confirmation recorder Luis runs |
| tests | `test_bench_*.py`, `test_goal_check.py`, `test_design_notes.py`, `test_overfit.py` |

These are reused, not replaced:
- scenario_run (`Ops`, the lease, the boot switch, backups, nav-memory isolation);
- timeline;
- the brain's JSONL logs, which form the trace;
- `tools.obs` (metrics and spend);
- `tools.spend.load_prices()`.

No edits to `brain/` (except through the `register` hook), `client_mod/scripts/`, or the running brain.

## 3. Case spec
```json
{
  "id": "goal_gather_coal_multitrip", "version": 1, "tier": "T3", "family": "long_task", "long_task": "gather_coal_multitrip",
  "authored_by": "human", "tags": {"skills": ["Mining"], "items": ["ITEM_Resources_Coal"], "uses": ["lodestone", "wiki", "storage"]},
  "chat": [{"at_s": 0, "text": "can you get me 50 coal? check the wiki for where, and use the lodestones if it's far"}],
  "phrasing_heldout": "need about fifty coal for the blast furnace, sort it out?",
  "fixtures": {"requires": [{"have": {"item": "Law Rune", "at_least": 20}}], "setup": [{"verb": "grant", "item": "ITEM_Rune_Law", "count": 20}],
               "state_snapshot": "fresh_dev_v1", "player_body": true},
  "success": {"all": [{"delivered": {"to": "player", "item": "Coal", "at_least": 50}},
                      {"trips": {"deposits_at_least": 2}}, {"teleports": {"via": "lodestone", "at_least": 1}}]},
  "guards": [{"no_event": {"kind": "damage_to_player"}}, {"no_event": {"kind": "death", "who": "self"}},
             {"not": {"lost": {"item": "<his equipped weapon>", "at_least": 1}}}],
  "controls": {"alt_means": [{"verb": "grant_to_ground", "item": "ITEM_Resources_Coal", "count": 50}],
               "wrong_action": "walk_only", "partial": {"count_minus": 1}},
  "limits": {"wall_s": 5400, "model_calls": {"haiku": 500, "sonnet": 40}, "hints_max": 1, "idle_s": 180, "repeat": 3},
  "hints": {"ladder": ["any luck?", "coal's usually in rocky areas, try the wiki", "Fellhollow has coal nodes; the lodestone by the bridge goes there"]},
  "targets": ["dev", "live_confirm"], "risk": "medium",
  "oracle": {"dev": "scripted:coal_trip_v1"},
  "provenance": {"by": "eval-agent draft", "reviewed_by": null, "sources": ["https://dragonwilds.runescape.wiki/w/Coal"]}
}
```
Rules (lint, in tests):
- Chat and hints are player language: no tool names, no asset ids.
- `success` and `guards` read only observer evidence: the probe, the referee, harness snapshots and body episodes confirmed by the probe. They never read `say` text or tool arguments.
- **Delivery** ("get me") needs `delivered` (§4.2), not "in his bag".
- **Multi-trip** needs `trips`, and BenchWorld enforces bag capacity.
- **A required lodestone** needs `teleports{via: lodestone}`.
- **Hint ladder:** fixed, with the level recorded (L1 a generic nudge, L2 a pointer, L3 the answer). `hints_max` caps it, and a case that needs L3 is reported as such.
- **Limits are per tier** (§10). The harness never stops a case by a cap that is lower than the case's realistic need; caps exist for cost safety.
- **`oracle`** is a scripted positive control per target (`scripted:<file>`). Mock oracles never count. Dev oracles use dev places and ids.

## 4. Evidence and predicates
### 4.1 The observer (finding 1)
- Before the first chat line, the harness takes the **baseline**: a probe snapshot, plus a referee log offset on dev.
- Around every world-changing tool call it takes a probe before and after, with timestamps. A world-changing call is anything except `look`, `inspect`, `inventory`, `lookup`, `say`, `remember` and `get_state`.
- At the end it takes a final probe.
- **Each leaf** evaluates on the observer's evidence:
  - probe deltas;
  - referee events (dev);
  - harness tallies, computed from the probes, never from `goals.json`.
  Where the skill's reply makes a claim (the cast reply's `runes_spent`, `cooldown_started`, `effects`, `spell_actor`; a craft output; a `combat_end` kill), the leaf compares the two. When they disagree, the result is `error: sensor_mismatch`, which counts as not passed and is listed.
- **Server audit:** on dev, each evidence kind (runes, cooldown, GE or tag, spell actor, item grant, damage type, parry or dodge, teleport, craft) is sampled per build against the referee. The report prints "audited k/n agree" or "unaudited". An unaudited kind can't count for GOAL (§9.2).

### 4.2 Leaves
- **Core** (Director, `brain/predicates.py`): have, gained, tally, skill, skill_gain, equipped, gear_better, bag, near, moved, killed, quest, lost, on_ground, elapsed, station and vital, combined with all, any and not. Results carry `measures` (monotonic raw amounts). `lost` and `on_ground` are core, so delivery as written by the Director is `all[lost, on_ground near player]`; the benchmark's `delivered` adds the referee's player-side evidence on dev. **Requested from the Director:**
  - `killed` matches an exact kind id from the catalog, not a substring;
  - `validate` rejects a generic class or tag (below) through a hook.
- **Benchmark leaves** (`evals/bench/leaves.py`). All are attribution-windowed: the evidence must fall within [action start, action end + w] for the action the leaf names, with no other world-changing call inside that window.

| Leaf | Passes when (observer evidence) |
|---|---|
| `spell_effect {spell, effect?}` | The probe shows the spell's rune cost spent (the exact cost from the manifest) and its `LastCastTimeBySpellData` entry changed inside the window, **and** one *specific* effect from `spell_effects.json` holds: a tag or GE class unique to that spell (the validator rejects base classes such as `DominionGameplayEffect` and `DominionStatusEffect`, and any class or tag that matches GEs of more than one spell); a spell actor of that spell's class; a displacement ≥ min within 2 s of the cast; a `vital_change {stat, dir, min}`; drops spawned. The cast reply must agree, else `sensor_mismatch`. An effect marked `observable: false` evaluates `null` |
| `purpose {id, …}` | The spell-use success predicate from `spell_effects.json` `purposes` (built from core leaves plus these), with `<…>` placeholders bound by the scene builder, **and** the purpose's spell cast inside the case window. A different means to the same end (walking around the ledge) is the `alt_means` control, which must fail |
| `station_used {station_kind, recipe}` | The referee or probe shows the recipe's outputs gained at that station kind, with its inputs consumed |
| `delivered {to: player, item, at_least}` | Items left his bag (probe) by `drop` or `give` episodes within 3 m of the player, and (dev) the referee shows them in the player's inventory or picked up from the ground near the player |
| `trips {deposits_at_least}` | Separate deposit episodes (a container's contents rose, from the referee or probe), each preceded by a gather run |
| `teleports {via, at_least}` | A displacement ≥ 300 m within 10 s, plus (dev) a referee teleport event naming a lodestone or spell |
| `damage_type_dealt {types ⊇ weakness}` | Referee damage events against the target creature carry the weakness damage type, which comes from data (the wiki infobox `weakness` mapped to `DamageType.*`) |
| `defended {kind: parry\|dodge, against: telegraph, at_least}` | Referee events: a telegraphed attack aimed at him resolved as parried, dodged or missed |
| `disengaged {then: health_rise\|vital_rise, reengaged: bool}` | Distance to the enemy rose above its aggro range, then health or a vital rose (eat or drink), then (optionally) he hit it again |
| `prepared {before: first_hit, any: [buff_tag, enchant_type, equipped_tier, food_carried]}` | The state before the first hit of a "hard" fight, where hard means the creature's PL exceeds his gear PL, from data |
| `hit_rate {weapon_category, min_pct, min_shots, range_m, target_moving}` | Referee projectile hits ÷ shots in the window (the ranged-aim agent's shots, cross-checked) |
| `no_event {kind, who?}` | A guard: no referee or body event of that kind (damage to a player, own death, attack on a player) |

### 4.3 Process metrics (never decide `success`; listed separately; finding 11)
- **Knowledge use.**
  - A case may declare `needs_fact {kind: recipe|location|weakness|quest_step, truth}`, with the truth taken from data or the wiki.
  - `lookup_when_needed` = a `lookup` call happened before the first action that depends on the fact.
  - `fact_correct` = the action's argument matches the truth: the place he went to (within r of a true node), the damage type he used, the recipe he crafted.
  - `needless_lookup` = lookups on cases with `needs_fact: none` whose answer was already in perception.
  - All three are deterministic over the trace's tool calls.
- **Efficiency.**
  - `rate` = units gained (or XP) per minute, from probe tallies, divided by the scripted dev baseline's rate on the same case (or Luis's run, when recorded).
  - Reported as a median over the case family.
  - Also: abilities used that speed up the activity (from the purposes), and a trend over repeats.
- **Damage trend.** Damage taken per fight (referee) over ≥ 5 repeat fights with the same creature kind, as a slope with a CI.
- **Latency** (finding 17, mainly obs): chat → first world-changing action, excluding `stop`, `say` and `remember`. Only real-model dev and live runs count. A second figure: chat → first action of the plan that eventually passed.

### 4.4 Guards (finding 16)
- Guards are evaluated on the event stream (referee and body), not by polling.
- A guard that evaluates `null` makes the case `unverifiable` (not passed); it never counts as "held".
- A broken guard stops the run at once, and the case is `fail: guard`.

## 5. Suites, tiers and the generator
### 5.0 Frozen manifests, n/a lists, versions (findings 2, 19)
- `evals/bench/manifests/<build>/suite_v<N>.json` lists, per target metric, the case ids and their hashes, and the **denominator**. The denominator is all items of the kind in the build's data, minus a data-derived n/a list:
  - **spells:** no display name, or `needs_unlocking=false` with no rune cost;
  - **recipes:** entitlement-only, a vendor currency (`GOLD[...]`, a shard currency), deprecated or test assets;
  - **stations:** kinds with no player-buildable recipe.
- The manifest is printed in full and approved by Luis once per build (the judge tag, §9.3).
- **Only `pass` counts.** Unverifiable, skip, error, invalid and sensor_mismatch all count against the target. Each is still reported in its own column.
- A rise in n/a, unverifiable or skip versus the previous manifest run is flagged in red.
- **New cases** (generated or hand-written) go into `candidates/`. They join a suite only at a manifest bump (`evals.bench freeze`), after their controls (§6) have passed on the scoring target. Trends are drawn only across identical manifest versions; a bump re-baselines.
- **Proposed GOAL.md wording change** (main/Luis): "unlocked spells" → "spells in the build manifest". Locked spells are unlocked by the dev fixtures (Luis's option B).

### 5.1 T0 (from data, no model)
- **One cast case per manifest spell.** The chat comes from the spell's own description: one seen phrasing plus a held-out phrasing, the latter sealed (§5.4).
- The proof is `spell_effect`. Fixtures set the unlock, the wheel slot, the runes and `setup_checks` (e.g. a logging axe), through the dev fixtures.
- **One station case per station kind,** a sanity check that the station works. The `craft_from_scratch` metric is separate (§8.1).

### 5.2 T1 spell use (GOAL "can USE")
- **One case per purpose** in `spell_effects.json` (38 today, 21 observable). The scene builder binds `world.needs` from data and puts the scene in place with dev fixtures, for example:
  - a ledge 2.5–6 m high, chosen by the ledge probe;
  - a group of ≥ 3 low-PL creatures spawned;
  - a felled log;
  - an ore node;
  - a telegraphing creature;
  - an enemy weak to type X.
- The chat states the **need**, never the spell. For example, "can you get up there?", "these rats are swarming me", or "we need planks from that log".
- The success predicate is `purpose`.
- Controls:
  - `alt_means`: reach the goal without the spell, e.g. walk around, chop by hand, kill one by one. It must fail.
  - `wrong_action`: cast a sibling spell. It must fail.

### 5.3 T1–T3 (hand-written GOAL cases + generated candidates)
- **Hand-written (finding 10a).** The cases GOAL requires are drafted by the Eval agent, reviewed by main and Luis, and pinned by hash in `goal_targets.json` (`goal_cases`):
  - the 5 long tasks;
  - the 3 combat basics: `dodge_directional`, `parry`, `disengage_heal`;
  - the tactics cases: prep before a hard fight, telegraph-timed dodges against a dragon-class creature on dev, damage trend over 5 fights;
  - the knowledge cases: a recipe, a location, a weakness, a quest step.
  The drafts are in `evals/bench/goal_cases/` (`status: draft`).
- **Generated candidates (T1–T3).** The proposer reads catalog summaries, wiki infobox extracts (Monster weakness, resistance, PL, location, drops; Quest; Resource Node; Lodestone) and the **seen** archive with its outcomes (OMNI-EPIC, Voyager). It never sees held-out cases or traces. It drafts spec JSON with the predicate, the controls' means and a dev oracle sketch.
  - **Independent predicate audit (10c):** a second call sees only the chat line and the predicate (not the oracle) and answers "would the player say this was done? what's missing?". Its objections go into one repair round.
- **Adversarial transforms:** `inject_failure`, `vague_chat`, `interrupt` (a real pre-empting line, then "ok carry on"), `contradiction` and `missing_prereq`. On dev, failures are only those the harness can cause safely: a blocked path via a spawned obstacle, the resource removed, a creature spawned.

### 5.4 Held-out (finding 8)
- **The GOAL generalisation number** comes from a **fresh draw** after the code freeze. `goal_check --draw-heldout` seeds the generator from the HEAD sha, generates a stratified batch (the same tier and family mix as the seen suite), runs its controls, and then runs it once (LiveBench-style). The target is: held-out Wilson lower bound ≥ seen pass rate − 10 points, with n ≥ 30.
- **The Luis-authored set:** 10–20 of his real request lines, kept sealed. It is reported as its own number.
- **Rolling held-out** (for monitoring only) reports aggregates by tier: no per-case reasons, texts or traces in any report.
  - Brain and body logs go to `logs/evals/heldout_runs/`. The overfit test prints only shingle hashes and file paths.
  - Read access is blocked by a deny rule plus a PreToolUse hook (Read, Grep, Bash) on `logs/evals/heldout/**` and `logs/evals/heldout_runs/**`. Main or Luis installs them; they are listed in §9.3.
- Dedupe runs across the split (embedding-free: 4-shingle Jaccard ≥ 0.5 = duplicate). The split is stratified by tier and family.
- Every case file carries a **canary** string (BIG-bench practice), so leaked case text can be found anywhere: the overfit test also scans `data/` and the state stores.

## 6. The eval of the eval (findings 3, 4)
- **On the scoring target** (dev, or the live-confirmation protocol), each case must:
  - **pass** its `oracle` (a scripted dev run);
  - **fail** `ambient`: no actions, reflexes on, for the case's full `wall_s` (this replaces the mock `do_nothing`);
  - **fail** `claims_only`: chat and `remember` claims only, reflexes on;
  - **fail** `wrong_action`: the oracle with a sibling substituted (a spell of the same cast type, another recipe at the same station);
  - **fail** `alt_means`: the predicate's proxy produced another way (walk N m, gather by hand, eat, take from the ground or a chest), declared per case;
  - **fail** `partial`: the oracle cut before its last step, or count − 1.
- A negative control that evaluates `null` is not a fail: the case is invalid.
- **Validity key:** `case_hash` + sha256 of `brain/predicates.py`, `evals/bench/leaves.py`, `evals/bench/observer.py` and the case's `spell_effects.json` entry + the **body hash** (the git tree of `client_mod/scripts`) + the game build. Any change re-opens validity.
- Results go to `logs/evals/validity/<key>.json`, with the trace hashes.
- **Mock runs of the controls are "lint":** they catch broken predicates early and never reach goal_check.
- A control that passes is a predicate bug. It is listed in the report and the case is excluded until it is fixed and re-validated.
- **Cost:** controls are mostly scripted, so few model calls. `ambient` costs wall time (§10).

## 7. Targets, fixtures and safety
### 7.1 Targets
| Target | Brain | Player lines | Fixtures | Counts for GOAL |
|---|---|---|---|---|
| `mock` | in process, the real brain code | the harness (test player) | written into BenchWorld | **never** (lint and dev of the harness) |
| `dev` | a harness-run LiveSession over the client bridge (run_live stopped, its supervisor checked every tick) | injected `chat_heard` from the test player (dev only) | `mod/bench/fixtures.lua` verbs (Luis's OK, broadened): grant items and runes, unlock perks, set time, spawn creatures, reset, server mods | yes |
| `live_confirm` | **the normal live brain** (run_live) | **only Luis's real chat**: nothing injected | none | yes, as confirmations (§7.4) |

### 7.2 Dev fixture safety (finding 13)
**Primary guarantee.** `debug_run` is a local file read by the local server process. It cannot act on Shockbyte, which is vanilla. The harness checks that the trigger was consumed by the dev server's PID.
- **(a) Addresses.** All of these must hold:
  - dev address ≠ `server.txt` address;
  - the dev address resolves to loopback or this VM;
  - the joined `LoadMap` address = dev, re-checked before **every** setup call and **every** brain action (an observer hook). On a mismatch the brain session is killed at once.
- **(b) Who is touched.** Claude's dev character is addressed by GUID, never by name. Setup is refused if any other player is connected to the dev server; Luis has joined it before.
- **(c) The character-save leak.** Use a **dedicated dev character**: its own save slot or GUID, or the dev Steam account. This needs a `client_boot.ps1 -Character` option (main or the ops owner).
  - Until that exists: back up `Claude.json` before the run, and restore it with the client closed before rejoining Shockbyte.
  - scenario_run's post-run Shockbyte diff becomes a **hard alarm**: stop, hold the client, tell Luis.
- **(d) Lease.** Renewed on every tick, and ≥ the case's `wall_s` + 10 min. Any server change kills the harness brain at once.
- **(e) No Shockbyte path.** The bench never exposes `--here --allow-shockbyte`. The `live_confirm` target can never call setup, and the code has no route from it to the fixture module.
- **(f) Frozen verbs.** The fixture verbs live in one small file (`mod/bench/fixtures.lua`), frozen and reviewed, with a test that lists its verbs. Deleting legacy `mod/` code can't widen or remove them silently.
- **Two brains on one pawn:** the harness checks every tick that run_live and its supervisor are not running.
- **Claude himself** still acts only through real client paths (PRINCIPLES #1). The fixtures are the test rig, and every setup step is in the trace.

### 7.3 State isolation (finding 9)
- Each case starts from a **frozen state snapshot** (`evals/bench/state_snapshots/<name>/`: notes, places, skills library, map memory and goals, empty or seeded as the case says). It is copied to a temp `DW_STATE_DIR` with `DW_WORLD_GUID=bench_<run>_<case>`, and client nav memory goes to `bench_<run>_<case>` (scn_world). All of it is discarded afterwards.
- The harness refuses to start if the state dir or skills dir resolves to the live or Shockbyte store.
- A **"with memory" variant** (principle #8) runs a case twice in one store and reports the second run's calls, time and success.

### 7.4 Live-confirmation protocol (finding 12)
- Luis is present and plays; nothing is injected; Claude runs as the normal live brain.
- The trace proves the target: the game log's `LoadMap` address = `server.txt`, and Luis's player row is present.
- **Luis records the confirmation himself** in one of two ways:
  - `tools/goal_confirm.py <case_id>`, which he runs, shows the trace summary and the predicate result and asks him to type `yes`;
  - typing `confirm <code>` in game chat, where the code is the trace hash prefix that goal_confirm shows.
  The record holds his choice, the trace sha256, the companion hash and the time.
- goal_check counts only these. **Residual risk:** an agent on this VM could forge a confirmation file. The judge tag and the deny rule on `logs/evals/confirmations/**` reduce that, and Luis's final sign-off (§9.4) is the backstop.

## 8. Metrics
### 8.1 Metric → case selector (frozen in the manifest; finding 10b)
| Target (goal_targets.json) | Cases | Rule |
|---|---|---|
| `spells_effect_coverage_pct` | T0 `spell_cast`, one per manifest spell | pass ÷ manifest spells; Wilson LB ≥ target |
| `spell_use_cases_pct` | T1 `spell_use`, one per purpose | pass ÷ purposes in the manifest |
| `craft_from_scratch_pct` | T1 `craft`: a seeded random sample of ≥ 20 recipes from the full graph, stratified by depth, **no input fixtures** (gather → process → craft) | pass ÷ sample; manifest n/a list |
| `combat_cases_pct` | T1 `combat` (weakness, kill, defend) | pass ÷ cases |
| `combat_basics_live_proven` | hand-written `combat_basic` × 3 | dev pass with controls + a live confirmation each |
| `combat_tactics.*` | T2 `tactics` (hand-written): `prepared`, `defended{against: telegraph}`, damage trend | pct / rate / slope with CI |
| `ranged_hit_rate_15m_moving_pct` | `hit_rate` over referee shots, ≥ 30 shots | Wilson LB |
| `adversarial_cases_pct` | the adversarial transforms of seen cases | pass ÷ cases |
| `knowledge_use.*` | `knowledge` cases (hand-written + generated) | process metrics (§4.3) |
| `efficiency_vs_baseline_pct` | T1/T2 rate cases with a dev baseline | median ratio, CI |
| `long_tasks:*` | hand-written T3 × 5 | dev pass at k = 3 (pass^k reported; ≥ 2 of 3 with ≤ 1 hint), and a live confirmation |
| `heldout_gap_max_points` | the fresh post-freeze draw | held-out LB ≥ seen − 10 |

### 8.2 Statistics (finding 7)
- **Minimum valid n per target:** ≥ 20 for percentages, ≥ 30 held-out, ≥ 3 live confirmations per family where live is required, ≥ 30 shots for the hit rate. This is proposed for `goal_targets.json`.
- The decision uses the Wilson 95% lower bound, and the interval is printed.
- **Only full manifest runs count.** `--only` runs are marked `partial` and ignored by goal_check.
- **Loop step 6** ("keep the change only if it improves"): `evals.bench compare <runA> <runB>` runs a paired comparison on the same case ids (McNemar exact test plus a paired bootstrap CI on the difference; Miller 2024).

## 9. Scoreboard, judge integrity, goal_check
### 9.1 Run records
- Each run directory holds `report.json`, `cases.jsonl` (per case: result, evidence summary, controls ref, hint level, trace sha256), traces, and `manifest.json` (the suite version).
- The scoreboard row records:
  - `run_id`, `at`, `target`, `full` (bool), `suite_manifest` + sha, and `git_sha` + `dirty`;
  - `companion_hash`: the git tree ids of `brain/` and `client_mod/scripts/` plus the data profiles that aren't judge files;
  - `judge_hash`: the judge files (§9.3);
  - the game build;
  - sha256 of `report.json` and `cases.jsonl`;
  - calls and cost.
- **goal_check never uses a precomputed metric.** It re-reads `cases.jsonl` from every counted run, checks each sha256, and recomputes everything.

### 9.2 Freshness and exposure (findings 15, 18)
- **Benchmark data** is fresh when its `companion_hash`, `judge_hash` and build equal the current ones. Mixed hashes = NOT MET. A run made on a dirty tree never counts.
- **Obs metrics** (latency, anomalies, stability, deaths, voice): the wall clock applies (24 h), plus a **minimum active exposure** at the current companion hash: brain sessions totalling ≥ N active hours with ≥ X tool calls per hour and real player chat present. The exposure is printed next to each value. This needs `obs` to report `companion_sha` per session and an `exposure` block (asked of the observability agent).
- **Unaudited evidence kinds** (§4.1) can't count for GOAL.

### 9.3 Judge files and the judge tag (finding 5)
- **Judge files:**
  - `docs/goal_targets.json` and `docs/GOAL.md`;
  - `tools/goal_check.py` and `tools/goal_confirm.py`;
  - `evals/bench/**` (spec, leaves, observer, runner, report, manifests, goal_cases, state_snapshots);
  - `brain/predicates.py`;
  - `data/spell_effects.json` and `data/spell_purposes.json`;
  - `client_mod/commands/bench_probe.lua` and `mod/bench/*`.
- **Luis approves a judge baseline** with a git tag `goal-judge-YYYYMMDD` over the judge files. `git diff --quiet <tag> -- <judge files>` must hold, else NOT MET: "judge changed since Luis's approval: <files>". goal_check prints the judge hash and the tag.
- **Coupling, stated:** `brain/predicates.py` is shared with the Director, so a Director change to it re-opens the judge and needs a new tag.
- **Blocking edits while `/goal` runs** (main or Luis installs; not this agent's config):
  - deny rules in `.claude/settings.json` for Edit and Write on the judge files;
  - a PreToolUse hook (`tools/hooks/judge_guard.py`, drafted by Eval) that also blocks Bash writes (redirects, `sed -i`, `git checkout`) into those paths, and blocks reads of the held-out paths.
  Changing a judge file becomes a "stop and ask Luis" item in GOAL.md §5.

### 9.4 Output (finding 6; main's interface)
- `--milestone Mn` → the last line is exactly `MILESTONE Mn MET` or `MILESTONE Mn NOT MET (x/y)`. It never prints the words GOAL MET.
- `--all` (the default) → `GOAL MET sha=<HEAD> judge=<judge hash> runs=<ids> at=<UTC>` only when all of these hold:
  - every milestone is met **and** confirmed: two consecutive goal_check runs on different data, both all-met;
  - the tree is clean;
  - HEAD's companion hash = the measured one;
  - the judge tag holds.
  Otherwise it prints `GOAL NOT MET (M1 x/y, M2 x/y, M3 x/y, M4 x/y, focus=Mn)`.
- **Test mode:** `DW_GOAL_CHECK_TEST=1` makes the met line `GOAL MET (TEST)`, so tests never produce the real literal.
- **Recommended `/goal` condition:** "`python -m tools.goal_check --all` was run in this turn, exited 0, its final line starts with `GOAL MET sha=`, and that sha equals `git rev-parse HEAD` printed in the same turn".
- **Luis's sign-off** is the last gate (a proposed GOAL.md §1b line): GOAL MET means "ready for Luis", and Luis says done.

## 10. Budgets and cadences (finding 14)
**Per-tier limits per case:**

| Tier | Haiku calls | Sonnet calls | Wall time |
|---|---|---|---|
| T0 | 10 | 0 | 5 min |
| T1 | 60 | 5 | 20 min |
| T2 | 300 | 30 | 60 min |
| T3 | 800 | 60 | 120 min |

Caps exist for cost safety. A case stopped by a cap is `error: budget`, not a capability fail, and it is listed.

**A full measurement (estimate, serial on dev, k = 1, long tasks at k = 3 spread over nights):**

| Block | Model calls | Dev wall time |
|---|---|---|
| T0 spells | ~45 cases, ~135 Haiku | 2.5–3 h |
| Spell use | ~38 cases, ~600 Haiku + ~40 Sonnet | 3–4 h |
| Craft | ~20 cases, ~300 Haiku + ~40 Sonnet | 4–6 h |
| Combat, tactics, adversarial | ~40 cases, ~400 Haiku | ~3 h |
| Long tasks | 5 × k = 3, ~1.3–3.6k Haiku + 300–600 Sonnet | 15–30 h |
| Validity on dev (scripted) | few calls | `ambient` adds +50–100% wall time |

- **Cost.** At the shared price table (`data/model_prices.json`): Haiku ≈ $0.0007 per call (13k prompt, 65% cached); Sonnet ≈ $0.016–0.05 per call. A full measurement without long tasks is ≈ $2–4. Each long-task night is ≈ $3–8.
- **Daily cap ($10, everything included):**
  - every batch preflights `tools.obs spend --json`;
  - it refuses if the spend command fails, if `state == "cap"`, or if spent + the worst case of the planned batch (the dearest tier per model × the calls cap) > the cap;
  - the planned call counts are printed before every real-model run.
- **Cadences:**
  - **per cycle:** a smoke subset (the full mock lint plus ~10 dev cases in the changed area); not GOAL-counting;
  - **nightly:** a full dev run of the frozen manifest, with long tasks rotated so that each gets k = 3 within a week at the same hash;
  - **live:** confirmation batches with Luis when he plays.
  Hash freshness means only changed areas need re-runs.
- **First real-model runs** keep the brief's cap of ≤ 40 calls per run until main approves these budgets.

## 11. Precedent (what is reused)
- **MineDojo:** a programmatic success function over state, which is our predicates.
- **Mindcraft / MineCollab:** the task JSON shape; `initial_inventory` corresponds to our fixtures.
- **MCU:** atomic tasks composed into harder ones, with LLM-generated configs verified in a simulator; this is our generator plus validity.
- **OMNI-EPIC:** an archive of learned and failed tasks, plus an interestingness filter.
- **Voyager:** zero-shot transfer to new tasks.
- **BALROG:** a progress percentage for long games.
- **Crafter:** a geometric-mean breadth score.
- **τ-bench:** pass^k for reliability.
- **ABC:** task and outcome validity, which our controls implement.
- **LiveBench:** a fresh draw after a freeze for contamination-free numbers.
- **BIG-bench:** a canary string in every case file.
- **Miller (2024):** error bars and paired comparisons.
- **SWE-bench Verified:** a human-validated subset, which is our hand-written GOAL cases.
- **METR and ImpossibleBench:** frontier models game scorers, hence the judge integrity rules and the harness observer.
- **The `/goal` docs:** the evaluator reads only the transcript and runs nothing, hence the exact, sha-bound final line.
- **Inspect AI:** considered and not adopted (§ Search record).

## 12. Generality check
- No spell, item, station, creature, quest or place names in code. Cases, purposes and manifests are data.
- A new spell or recipe in a patch enters the next manifest from data. An observer evidence kind is generic (tag, GE, actor class, displacement, damage type).
- The benchmark never changes the companion. The overfit detector (seen cases, canaries; hash-only output) and the principle tests guard that.

## 13. Principles touched
- **#1:** Claude acts only through real client paths. The dev fixtures (Luis approved, 2026-10-25) are harness-only and on the dev server only, with the guards in §7.2.
- **#2:** predicates never read the model's words. Process metrics read tool calls and are never success.
- **#5:** done is decided by verified, independently observed state.
- **#9:** one tester at a time; the harness watches for run_live.
- **#10:** offline lint, then dev, then live confirmations.

## 14. Acceptance tests (offline)
1. **Spec lint:** no tool names or asset ids in chat or hints; delivery, trips and lodestone predicates required where the chat implies them (a fixture of "get me" with a bag predicate fails the lint).
2. **Observer:** on BenchWorld with the lying-body switch, a cast reply that claims runes the probe didn't see yields `sensor_mismatch`; the agreeing case passes.
3. **Leaves:** attribution windows (an effect outside the window doesn't count); a generic `class_contains` is rejected; travel displacement must fall within 2 s; `vital_change` direction.
4. **Controls (as lint on the mock):** for every T0 and spell-use case, the oracle passes and ambient, claims_only, wrong_action, alt_means and partial fail. A deliberately weak proof (runes only, or a generic GE) is caught by a control.
5. **Manifests:** the denominator stays fixed when results go unverifiable; a rise in n/a is flagged.
6. **Isolation:** each case gets a fresh state dir; a Shockbyte store path is refused.
7. **goal_check:**
   - re-derivation (a tampered `metrics` field is ignored; a sha mismatch → NOT MET);
   - mixed hashes;
   - a judge diff against the tag;
   - the dirty tree;
   - the `GOAL MET sha=…` line only under every condition, and `GOAL MET (TEST)` in tests;
   - milestone lines;
   - the confirmation re-run;
   - Wilson LB and minimum n;
   - partial runs ignored;
   - live confirmations only from goal_confirm records.
8. **test_design_notes, test_overfit** (hash-only output, canaries), and test_principles stay green.

## Search record
- Need: a capability benchmark for an embodied LLM game companion (task format, programmatic success, generated tasks, validity, coverage); rev 2 adds contamination control, error bars and resistance to reward hacking by the optimiser.
- Searched: BALROG; MCU; MineDojo programmatic tasks; the Mindcraft task JSON; MineCollab; the Voyager evaluation; Crafter scoring; τ-bench pass^k; ABC agentic benchmark validity; Inspect AI; OMNI-EPIC; PUBG Ally evaluation; METR reward hacking; ImpossibleBench; Wilson intervals for small n; the Claude Code `/goal` evaluator.
- Found:
  - BALROG: https://arxiv.org/abs/2411.13543
  - MCU: https://arxiv.org/abs/2310.08367
  - MineDojo: https://arxiv.org/abs/2206.08853 · https://docs.minedojo.org/sections/getting_started/sim.html
  - Mindcraft: https://github.com/mindcraft-bots/mindcraft
  - MineCollab: https://arxiv.org/abs/2504.17950
  - Voyager: https://arxiv.org/abs/2305.16291
  - Crafter: https://arxiv.org/abs/2109.06780
  - τ-bench: https://arxiv.org/abs/2406.12045
  - ABC: https://arxiv.org/abs/2507.02825
  - OMNI-EPIC: https://arxiv.org/abs/2405.15568
  - Inspect AI: https://inspect.aisi.org.uk
  - PUBG Ally evaluation: https://www.invenglobal.com/articles/22987/ai-pubg-teammate-raised-through-tens-of-thousands-of-matches-at-internet-cafes-krafton-reveals-development-story
  - LiveBench (fresh questions after a cut-off): https://arxiv.org/abs/2406.19314
  - BIG-bench canary: https://github.com/google/BIG-bench
  - Miller, "Adding Error Bars to Evals": https://arxiv.org/abs/2411.00640
  - Wilson vs other intervals for small n: https://metricgate.com/blogs/wilson-vs-agresti-coull-vs-clopper-pearson/
  - METR, "Recent Frontier Models Are Reward Hacking" (models edit tests and scorers): https://metr.org/blog/2025-06-05-recent-reward-hacking
  - ImpossibleBench (cheating rate on impossible tasks): https://arxiv.org/abs/2510.20270
  - SWE-bench Verified: https://openai.com/index/introducing-swe-bench-verified/
  - Claude Code `/goal` (the evaluator reads the transcript, runs no commands): https://code.claude.com/docs/en/goal
- Decision: **adapt.** Spec from Mindcraft and MineDojo; generator from MCU and OMNI-EPIC; scoring from Crafter, BALROG and τ-bench with Wilson bounds; validity from ABC; contamination control from LiveBench and BIG-bench; judge integrity from the METR and ImpossibleBench lessons. The thin harness is **built** on scenario_run, timeline, the brain JSONL logs and tools.obs. Inspect AI is not adopted: our solver is a whole game session, and Inspect would add a dependency without removing any of our code. Its vocabulary is reused.
