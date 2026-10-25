# Capability benchmark: hard tasks that prove he can work things out himself

Status: **design, for the review gate**. Author: the Eval agent, 2026-10-25. Nothing below is built yet. Offline only (mock world plus fake and scripted agents) until main approves the call counts and live runs in section 9.
Related: GOAL.md (targets, the eval of the eval, the overfit detector), director.md (the shared predicate format), autonomy-plan.md, companion-quality.md, tools/scenario_run.py.

## 1. Goal (what Luis will see)
- One command runs a suite of tasks phrased as a player would say them in chat ("can you grab me 50 coal? use the lodestones if it's far"). Each task is scored only from game state and body events, never from what Claude says.
- One report per run, at `logs/evals/<date>/<run_id>/report.md` plus `report.json`. It holds:
  - a coverage matrix: spells, stations, creatures and skills × pass, fail or unverifiable;
  - pass rates per tier;
  - latency (chat → first action), model calls and cost, and the failure reasons;
  - the trend against earlier runs, from `logs/evals/scoreboard.jsonl`.
- "Every spell usable" becomes one measured number: the share of spell cases that pass with the game-observed effect, out of every spell in the build's spell data. Each spell's case is generated automatically, so a new spell in a patch adds a case without anyone writing it.
- `tools/goal_check.py` prints MET, NOT MET or NO DATA for every target in `docs/goal_targets.json`, then exactly `GOAL MET` or `GOAL NOT MET (n/m)`. Claude Code's `/goal` evaluator can read that from the transcript.
- The suite grows by itself. A Sonnet proposer reads the game data and the wiki and writes new hard tasks with their predicates. 30% of every batch is held out, and a task counts only after its predicate has passed one positive control and failed two negative controls.

## 2. Approach: layers and files (all new, all owned by the Eval agent)
| File | Owns |
|---|---|
| `evals/bench/spec.py` | The task spec (pydantic, as in brain/interface.py), load and validate, JSON Schema export, and `case_hash` (task text + predicate + fixtures). |
| `evals/bench/leaves.py` | Benchmark predicate leaves registered into the shared `brain/predicates.py` (section 4); the Director owns the core. |
| `evals/bench/trace.py` | **One trace format for every target.** It is built from the brain's own JSONL log (`tool_call`, `tool_result`, `llm_response.usage`, `say`, `chat_decision`, `event`) plus body episodes (`client_io/events/activity.jsonl`, or the mock's episode list) and the state snapshots the harness takes. Mock and live runs are therefore scored by the same code. |
| `evals/bench/world.py` | `BenchWorld(MockGame)`: a mock driven by the catalogs. It applies fixtures; every spell comes from `data/spells_<build>.json` with its runes, cast type and an effect simulated per game module kind (section 5.1); creatures can carry a weakness; failures can be injected (it reuses `MockGame.script_failure`). Crafting builds on the Director's `GearWorld` when it lands, rather than duplicating it. |
| `evals/bench/agents.py` | The things that play a case: `companion` (the real LiveAgent, Controller and Planner over the world, with a FakeLLM script, the dry-run models or a real model); the negative controls `do_nothing` and `claims_only`; and the positive control `oracle`, which replays the case's scripted tool sequence. |
| `evals/bench/runner.py` | `python -m evals.bench run|plan|validate|generate|report`. It plays the player (chat lines, hints, interruptions), runs the loop, checks the predicate after every step on fresh state, enforces the limits, and writes the report and the scoreboard row. |
| `evals/bench/generator.py` | Deterministic T0 cases from data (every spell, every station); the Sonnet proposer for T1–T3 and the adversarial variants; validation, a dedupe archive and the held-out split. |
| `evals/bench/report.py` | Coverage matrix, tier pass rates, breadth score, pass^k and the trend. |
| `evals/bench/tasks/*.json` | The seen cases (committed). Held-out cases live in `logs/evals/heldout/`, which is gitignored and never included in an implementer's brief. |
| `tools/goal_check.py` | Grades the GOAL targets (section 8). |
| `tests/test_bench_*.py`, `tests/test_goal_check.py`, `tests/test_design_notes.py`, `tests/test_overfit.py` | Section 10. |

Two existing tools are wrapped, not replaced:
- **`tools/scenario_run.py`** supplies the dev-server plumbing: preflight, the target lease, the boot switch to dev and back, the backup, nav-memory isolation and the baseline diff. The benchmark's dev and live targets import `Ops`, `write_lease`, `target_address` and `snapshot` from it. scenario_run stays the place for body-only primitive scenarios (no model), and the benchmark is the place for chat-driven tasks with the brain in the loop.
- **`tools/timeline.py`** renders each case's merged timeline in the report.

No edits to `brain/`, `client_mod/` or the running brain. The only shared file is `brain/predicates.py`, which the Director owns; I use a `register_leaf` hook that I've asked it to add.

## 3. Task spec (JSON, one file per case or a list per file)
```json
{
  "id": "t2_coal_lodestone_50",
  "tier": "T2",
  "family": "gather_multitrip",
  "tags": {"skills": ["Mining"], "items": ["Coal"], "uses": ["lodestone", "wiki"]},
  "chat": [{"at_s": 0, "from": "player", "text": "can you get me 50 coal? the wiki says where, use the lodestones if it's far"}],
  "fixtures": {
    "requires": [{"have": {"item": "Law Rune", "at_least": 10}}, {"tool_category": "pickaxe", "tier_at_least": 2}],
    "setup": [],
    "world": {"mock": {"nodes": [{"resource": "Coal", "at": "far_quarry", "remaining": 80}]}}
  },
  "success": {"all": [{"gained": {"item": "Coal", "at_least": 50}}]},
  "guards": [{"not": {"lost": {"item": "*", "equipped": true}}}],
  "limits": {"wall_s": 3600, "sim_s": 7200, "model_calls": 40, "hints": 1, "idle_s": 120},
  "hints": [{"after_idle_s": 90, "text": "coal's in Fellhollow, there's a lodestone near the bridge"}],
  "adversarial": null,
  "targets": ["mock", "dev"],
  "risk": "medium",
  "needs_player_body": false,
  "oracle": [{"tool": "lookup", "args": {"query": "coal node location"}}, {"tool": "go_to", "args": {"target": "far_quarry"}},
             {"tool": "gather", "args": {"resource": "Coal", "count": 50}}],
  "provenance": {"by": "generator", "model": "anthropic/claude-sonnet-5-5", "batch": "2026-10-26T10:00Z", "heldout": false,
                 "sources": ["https://dragonwilds.runescape.wiki/w/Coal"]}
}
```
Rules (checked by `spec.validate` and the tests):
- **Chat is player language.** `chat[].text` and `hints[].text` may not contain any tool name from `brain/interface.TOOLS` or the client manifest as a word, nor an id like `USD_`, `ITEM_` or `BP_` (Luis: no spoon-feeding).
- **Predicates read only state and body events** (`success`, `guards`). They never read `say` text or the model's arguments.
- **`fixtures.requires` are preconditions.** If they are not met on the target, the case is `skip: precondition` with the unmet leaf, unless the case's tier says Claude must obtain them himself, in which case they are not listed. `setup` holds harness-only steps (section 7).
- **Limits** are wall time, simulated time (mock), model calls (a hard cap, so a run stops at 40), hints (the player's help lines; using one is counted and reported, and exceeding `hints` fails the case) and an idle stall (no tool call, no progress and no chat for `idle_s` ends the run, or triggers the next hint).
- **Metrics per case:**
  - result (`pass`, `fail`, `unverifiable` or `skip`) and the predicate `detail` and `progress`;
  - wall and simulated time;
  - chat → first action latency, measured from the injected line's timestamp to the first body `tool_call` that isn't a read, for every chat line;
  - model calls, tokens and cost per component (from `llm_response.usage`; prices from `evals/bench/prices.json`, which main fills from the API price list, with tokens only when it is empty);
  - failures, each as `{tool, reason, detail}`;
  - hints used;
  - `voice` (a hook: `voice_scorer(trace) -> {score, notes}`, None by default; the voice agent's rubric plugs in);
  - anomalies (talk without action, stat narration), counted by the observability detectors when available.
- **`oracle`** is the scripted solution, which serves as the positive control on the mock and on dev. Every generated case must have one.

## 4. Predicates: the shared format (`brain/predicates.py`, owned by the Director) plus benchmark leaves
- **Core (Director):** `have`, `gained`, `tally`, `skill`, `skill_gain`, `equipped`, `gear_better`, `bag`, `near`, `killed`, `quest`, combined with `all`, `any` and `not`. `evaluate(p, state, ctx) -> {passed: true|false|null, detail, progress, missing}`. **`null` means "can't be checked from what the body reports"**: the result is `unverifiable` (excluded from pass rates, listed as a perception gap), and it never counts as a pass.
- **Benchmark leaves** (registered from `evals/bench/leaves.py`, reading `ctx.results` (the tool results) and `ctx.episodes` (body activity) since the baseline):
  - **`spell_effect {spell, effect, min_m?}`** passes only if all three hold:
    - the body's cast result (or a `cast_late_success` episode) for that spell id reports `runes_spent` non-empty;
    - it reports `cooldown_started`;
    - it shows the **effect-specific evidence**, chosen from the spell's game modules (section 5.1).
    Runes alone never pass (GOAL.md bans weak proxies). An effect the body can't observe evaluates `null`.
  - `station_used {station_kind | station, recipe?}`: a body-verified craft or process result at that station, with the output gained.
  - `hit_rate {weapon_category?, min_pct, min_shots, range_m?, target_moving?}`: from the ranged-aim agent's per-shot episodes (hit or miss, range, target speed). It is `null` until those episodes exist.
  - `moved {min_m}`: the 2D distance from the baseline position (for travel spells, lodestones and Recall).
  - `lost {item, at_most, equipped?}`: a guard, e.g. never drop his weapon.
  - `latency {p50_s_at_most}`: a guard over the chat → action times. This is the only leaf that uses chat, and it reads timestamps only.
- **Guards** are predicates that must hold through the whole run: never attack a player, never lose gear, no death unless the case allows it. Breaking a guard fails the case whatever `success` says.

## 5. Tiers and the generator
### 5.1 T0 from data, deterministic, no model
- **One case per spell**, for every spell in `spells_<build>.json`.
  - Spells with no name, and the held-equipment variants the game itself marks `needs_unlocking=false` with no runes (Siphon*, Weapon Poison, Whetstone, Magic Focus, GetWater), are listed as `n/a` with that reason. They are not dropped silently, so the denominator is stated.
  - The chat text comes from the spell's own description (`usage.use_when` / the game's DescriptionText), phrased by a fixed template set over the description's verb, e.g. "can you cast that spell that &lt;description, lower-cased&gt;?". The spell's name appears in one variant only. The other variant describes the need ("I need a shelter for the night"), so it tests inference, not name matching. Those need phrasings are generated by Sonnet once per build and cached, under the same generator budget.
- **The effect check comes from `data/spell_effects.json` when it has the spell.** That file is the spells agent's per-spell signature, generated by `tools/gen_spell_effects.py` from the spell data plus live evidence. Its `proof.required` must all hold and one of its `proof.effect` must hold; `confidence` is `live` or `data`. Spells it doesn't cover fall back to a generic mapping from the spell's game module kinds (never spell names):

  | Module kind (game data) | Evidence | Leaf |
  |---|---|---|
  | `GameplayEffect` | GE instance or tag added on self | `spell_effect{effect: ge}` |
  | `HeldEquipmentEffect` | held-item effect added | `{effect: held_effect}` |
  | `UtilityMagic`, `SpawnActor`, `Blueprint` (placed or aimed) | own spell actor spawned, with `landed_at` within its radius of the target | `{effect: actor}` |
  | `Harvest`, `Grow`, `Compost`, `Humidify` | an item gained, or the target's state changed (crop stage, moisture) | `{effect: inventory_gain}`, or `null` until farm perception exists |
  | `Uneat` | sustenance or hydration changed | `{effect: vital_change}` |
  | role `travel` (teleport, Recall, Phase Dash) | position moved ≥ N m | `{effect: moved, min_m}` |
  | none of the above | `null` (unverifiable) | |

- **Fixtures for T0 spells:** the spell unlocked, on the wheel, its runes carried, and its special requirement met. The requirement comes from the game's `SpecialRequirementsStrategy`, e.g. a Logging Axe for Axtral (BUGS L1). It is provided by the harness on dev (section 7). Otherwise the case is `skip: precondition`, and the matrix shows exactly what is missing.
- **One case per station kind** from `recipes_<build>.json` (`stations`, kind crafting or processing): "make me a &lt;cheapest recipe output at that station&gt;", with its inputs as fixtures. The `success` is `station_used` plus `gained`.
### 5.2 T1–T3 (Sonnet proposer) and adversarial variants
- **Inputs (information, never instructions):**
  - catalog summaries: recipe graph roots and depths, station list, spells with roles;
  - wiki extracts from the mirror: Monster infoboxes (`weakness`, `resistance`, `power_level`, location, drops), Quest pages (start, steps, region), Resource Node pages (regions), Lodestone;
  - the archive of existing cases with their pass and fail history (OMNI-EPIC, Voyager: propose what is new and just beyond the frontier);
  - the tier definitions:
    - **T1** short chains: craft X from scratch (gather → process → craft), kill X with the weapon type it is weak to;
    - **T2** multi-trip and multi-system: 50 coal with lodestone hops, farm a mob drop over several trips, farm desert weed at a named place;
    - **T3** long horizon: a gear upgrade on his own initiative, a Brynmoor quest chain.
- **Output:** spec JSON (section 3), validated by `spec.validate` plus `predicates.validate` against the catalogs. Unknown names come back with candidates for one repair round. A case with no checkable predicate, i.e. one whose every leaf is `null` today, is kept but tagged `blocked_by_perception`, so the gap list drives the build order (GOAL.md §4.9).
- **Adversarial variants** (a generic transform per case, chosen by the generator):
  - `inject_failure`: a body failure scripted at step k (`path_blocked`, `nothing_in_range`, `attacked`, `on_cooldown`; mock via `script_failure`, dev only for reasons the harness can cause safely);
  - `vague_chat`: the same goal with typos, slang, pronouns ("grab me some of that black rock stuff");
  - `interrupt`: a player line mid-task that must pre-empt it ("hold on, come here"), then "ok carry on", with the success predicate unchanged;
  - `contradiction`: the player changes their mind;
  - `missing_prereq`: a fixture is removed, and the success predicate becomes "obtained the prerequisite and then the goal".
  Their pass rate is the "thinking on his feet" target.
- **Held-out:** a deterministic 30% of each batch (by `case_hash`) goes to `logs/evals/heldout/`. The report shows the seen and held-out pass rates and the gap (target ≤ 10 points).
- **Budget:** 1 call per batch of about 8 cases, plus at most 1 repair call per batch. A typical `generate --tiers T1,T2,T3 --n 24` is 3–6 Sonnet calls, stated before it runs.

## 6. The eval of the eval (validity controls, GOAL.md §3)
- For every case, `evals.bench validate` runs three agents on the mock (and on dev for the positive control when a case can't be mocked):
  - **positive** `oracle` (scripted tools) must pass;
  - **negative** `do_nothing` (no tool calls, sits idle) must fail;
  - **negative** `claims_only` (says "Done! got the 50 coal / cast it" in chat and calls `remember` with a claim, nothing else) must fail.
- The results go to `logs/evals/validity.json` as `{case_hash: {positive, do_nothing, claims_only, target, at}}`. A changed case hash invalidates them.
- A case counts towards any target only if it is **valid**: positive passed, and both negatives failed.
- The report and goal_check show **predicate-validity coverage**: valid cases / all cases, per tier and target.
- A case whose negative control passes (e.g. "have 5 logs" when the fixture already gives 5) is a predicate bug. It is listed and excluded. This is the ABC "outcome validity" check (the τ-bench do-nothing finding).

## 7. Targets, fixtures and safety
| Target | What runs | Who acts | Fixtures |
|---|---|---|---|
| `mock` (default) | BenchWorld in process, the real brain code | the companion, or the control agents | `fixtures.world.mock` plus `requires` written straight into the mock |
| `dev` (preferred for risky or long cases) | a brain session started by the harness (LiveSession over the client bridge, run_live stopped), Claude's client switched to the dev server by scenario_run's Ops | Claude's real client only | `requires` checked from `get_state`, `setup` by the harness (decision below) |
| `live` (Shockbyte) | the same, without switching | Claude's real client | none: `requires` must already hold; short and low-risk cases only (`risk: low`, ≤ 5 min, no combat near players, no fixtures); Luis's OK per run |

- **Player lines on dev:** the harness injects them as `chat_heard` events into its own brain session (`agent.heard(ChatHeard(player=<test player name>))`). Cases that need a player's body (follow, give, come here) are `needs_player_body: true` and run only on mock, or live with Luis.
- **Safety:** live runs reuse scenario_run's preflight (on the right server, no hold file, run_live stopped, lease) and its restore. Guards such as never attacking a player are checked continuously, and a broken guard stops the run at once.

**Decision for Luis (fixtures on the dev server). Not built without main's and Luis's OK.**
- **Option A (now, no bend):** no fixtures. Cases whose `requires` aren't met are skipped with the missing leaf. T0 coverage is then limited to what Claude's dev character already has, and the matrix says so.
- **Option B (recommended):** a **harness-only** setup step on **our dev server only**, through the server-side `mod/` debug_run, which is ours and exists on that server. It gives Claude's dev character a case's runes and items, unlocks a spell perk, sets time of day, or spawns one creature from its class. It runs *before* the case starts and is logged as `setup` in the trace. The companion never calls it: everything Claude does still goes through real client paths (PRINCIPLES #1). It is the test rig, like Mindcraft's `initial_inventory` and MineDojo's task initialisation.
  - Hard limits: the target address must be the dev target file's, and the code refuses any other server; no player other than Claude's dev character is touched; Shockbyte keeps its own per-character copy, which scenario_run already diffs before and after.
  - Principles touched: #1's "never grant items" is about the companion, not the rig, but it is close enough that Luis should say yes explicitly.
- **Option C:** player-assisted, where Luis drops items on dev. It costs his time, and is for visuals only.

## 8. Report, scoreboard and goal_check
- **Report (`report.md`, `report.json`):**
  - per-tier pass rates (valid cases only), the seen vs held-out gap, and pass^k when `--repeat k`;
  - a **breadth score**, the Crafter geometric mean over coverage cells, so breadth beats repetition;
  - **progress %** for long cases from the predicate's `progress`, as in BALROG;
  - the coverage matrix: spells, stations, creatures (with weakness used or not) and skills × pass, fail, unverifiable or skip;
  - the failure clusters (reason × tool, counted), latency p50 and p90, calls, tokens and cost, hints;
  - perception gaps (`null` leaves); the validity coverage; the trend (the last N scoreboard rows).
- **Scoreboard:** `logs/evals/scoreboard.jsonl`, one row per run: `{run_id, at, target, agent, models, git_sha, counts, metrics: {spells_effect_coverage_pct, craft_from_scratch_pct, combat_cases_pct, adversarial_cases_pct, heldout_gap_points, ...}, long_tasks: {id: {result, hints, target}}, validity_coverage_pct, calls, cost}`.
- **`tools/goal_check.py`:**
  - It reads `docs/goal_targets.json`, the newest scoreboard rows, the newest report and `tools/obs.py metrics --json` (interface proposed to the observability agent).
  - For each target it prints a row: `MET`, `NOT MET` or `NO DATA`, with the measured value, the run id and its age.
  - These count as NOT MET: missing data, data older than 24 h, values measured only on mock (except where the target allows it), long tasks without a live confirmation (`live_confirmed_required`), and cases that aren't valid.
  - The last line is exactly `GOAL MET` or `GOAL NOT MET (n/m)`.
  - The exit code is 0 only for GOAL MET.

## 9. Budget, and what needs main's OK first
- **Offline (no API):**
  - the unit tests;
  - mock runs with FakeLLM scripts and the dry-run models;
  - the control agents;
  - T0 generation (no model).
- **Real-model runs** are capped at ≤ 40 calls per run, and the count is announced before each one. These need main's OK.
  - A first real mock run: about 12 T0 spell cases on Haiku, ≤ 3 calls each, ≤ 36 calls.
  - The first generator batch: ≤ 6 Sonnet calls.
- **Dev or live runs:** main's OK, one at a time (PRINCIPLES #9).

## 10. Acceptance tests (offline)
1. Spec: schema round-trip; tool names or `USD_`/`ITEM_` ids in chat are rejected; limits are enforced.
2. T0 generator: exactly one case per catalogued spell plus the stated `n/a` list; the effect kind follows the module mapping. A held-out check: a synthetic spell added to a copy of the data gets a case with no code change.
3. Controls on BenchWorld: for every T0 spell case, the oracle passes, do_nothing fails and claims_only fails. A deliberately weak predicate (runes only) is detected by a failing negative control in a test fixture.
4. Runner: a FakeLLM companion casting a spell on BenchWorld passes; a scripted failure becomes a failure reason in the report; a hint is injected after an idle stall and counted; the model-call cap stops a run; the chat → first-action latency is computed from the trace.
5. Report: the coverage matrix, the trend from a two-row scoreboard, and the breadth score match hand-computed values.
6. `tests/test_goal_check.py`: MET, NOT MET and NO DATA per target; stale data counts as NOT MET; a missing live confirmation counts as NOT MET; invalid cases are excluded; the last line is exact; the exit code.
7. `tests/test_overfit.py`: a diff adding a 4-word sequence from any benchmark task text (seen or held-out) to `brain/` or `client_mod/scripts/` fails. Common English shingles are ignored. The diff is the working tree plus untracked files vs a recorded baseline commit.
8. `tests/test_design_notes.py`: every `docs/design/*.md` that is new or modified (not in the explicit allowlist of notes as of commit fc6fe31, or changed in git since then, or uncommitted) needs a `## Search record` section with ≥ 3 distinct `http(s)` URLs.
9. `tests/test_principles.py` stays green. No item, spell or creature names in harness logic: they come from data files and case JSON.

## 11. Precedent (what is reused)
- **MineDojo:** programmatic tasks scored by a deterministic function of simulator state; this is our `success` predicate. Its creative tasks with no checker are our `unverifiable`.
- **Mindcraft / MineCollab:** task JSON with `goal`, `initial_inventory`, `target`, `timeout` and `blocked_actions`; this is our spec, where `fixtures` maps to `initial_inventory`. The shape is adapted, not imported (theirs is JS and Minecraft-specific).
- **MCU:** atomic tasks composed into harder ones, with an LLM generating each task's setup and the setup verified in a simulator; this is our generator plus the controls on BenchWorld.
- **OMNI-EPIC:** an archive of learned and failed tasks, with a model proposing the next interestingly new one and filtering near-duplicates; this is our proposer's archive and dedupe.
- **Voyager:** tech-tree milestones and zero-shot transfer to unseen tasks; this is our held-out split.
- **BALROG:** a progress % rather than only binary success for long games; this is our `progress`.
- **Crafter:** the geometric mean over achievement success rates, which rewards breadth; this is our breadth score.
- **τ-bench:** pass^k for reliability, and the do-nothing agent that passed 38% of tasks; together with **ABC** (Zhu, Kang et al.) task and outcome validity, these give our negative controls.
- **Inspect AI (UK AISI):** considered as the runner, with dataset, solver and scorer. It is not adopted now: our "solver" is a whole game session behind the existing scenario_run plumbing, and Inspect would add a dependency without removing any of our code. We adapt its vocabulary (task, solver, scorer, epochs = `--repeat`) and keep the option of exporting traces to its log format.
- **PUBG Ally:** KRAFTON's weighted internal metric diverged from what testers valued. Hence the voice hook and Luis's spot checks next to the numbers.

## 12. Generality check
- No spell, item, station, creature, quest or place names in code. T0 comes from the catalogs, the effect check from module kinds, T1–T3 from the generator's data, and all names live in case JSON.
- A new spell, recipe or creature in a patch produces new cases with no code change. The held-out test in section 10.2 checks this.
- The benchmark never changes the companion. The overfit detector and the principle tests keep benchmark text out of `brain/` and `client_mod/scripts/`.

## 13. Principles touched
- **#1:** the companion acts only through real client paths. The harness's dev fixtures (option B) are the one open point and need Luis's OK.
- **#2:** predicates never read the model's words, and the harness never steers the model, beyond the player lines a real player would say.
- **#5:** done is decided by predicates on fresh state.
- **#10:** offline first, then dev, then short live checks.
- No principle is bent without the decision in section 7.

## Search record
- Need: a capability benchmark for an embodied LLM game companion: task format, programmatic success, generated tasks, validity, and coverage reporting.
- Searched: BALROG; MCU (Minecraft Universe) task generation; MineDojo programmatic tasks; the Mindcraft task JSON; MineCollab; the Voyager evaluation; Crafter scoring; τ-bench pass^k; agent benchmark validity (ABC, do-nothing agents); Inspect AI; OMNI-EPIC; PUBG Ally evaluation.
- Found:
  - BALROG (progress %, NetHack progression): https://arxiv.org/abs/2411.13543
  - MCU (atomic tasks, LLM-generated configs verified in a simulator): https://arxiv.org/abs/2310.08367
  - MineDojo (programmatic tasks = a deterministic state→bool success function): https://arxiv.org/abs/2206.08853 · https://docs.minedojo.org/sections/getting_started/sim.html
  - Mindcraft task JSON (goal, initial_inventory, target, timeout, blocked_actions): https://github.com/mindcraft-bots/mindcraft
  - MineCollab (cooking, crafting, construction; communication is the bottleneck): https://arxiv.org/abs/2504.17950
  - Voyager (tech-tree milestones, zero-shot transfer): https://arxiv.org/abs/2305.16291
  - Crafter (geometric-mean score over 22 achievements): https://arxiv.org/abs/2109.06780
  - τ-bench (pass^k): https://arxiv.org/abs/2406.12045
  - ABC, "Establishing Best Practices for Building Rigorous Agentic Benchmarks" (task and outcome validity; τ-bench's do-nothing agent passes 38%): https://arxiv.org/abs/2507.02825
  - OMNI-EPIC (task archive and interestingness): https://arxiv.org/abs/2405.15568
  - Inspect AI (task, solver, scorer): https://inspect.aisi.org.uk
  - PUBG Ally (weighted metric vs tester preference): https://www.invenglobal.com/articles/22987/ai-pubg-teammate-raised-through-tens-of-thousands-of-matches-at-internet-cafes-krafton-reveals-development-story
- Decision: **adapt.** The spec shape comes from Mindcraft and MineDojo, the generator from MCU and OMNI-EPIC, the scoring from Crafter, BALROG and τ-bench, and the validity controls from ABC. The thin harness is **built** on our existing scenario_run, timeline and brain JSONL logs. Inspect AI was considered and not adopted, for the reasons in section 11.
