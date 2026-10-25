# Design review: capability benchmark (`docs/design/eval-benchmark.md`), 2026-10-25

Reviewer: a fresh-context agent that did not write the note. I reviewed it against `docs/GOAL.md`, `docs/goal_targets.json`, `docs/design/PRINCIPLES.md` and `docs/design/director.md`. I also read `brain/predicates.py`, `data/spell_effects.json`, `data/spells_26161880.json`, `tools/scenario_run.py`, `brain/mock/game.py`, the DISCOVERIES entries on character saves, and the untracked `tools/goal_check.py` and `tests/test_goal_check.py`. I read those two as evidence of how the design is being implemented; they were not reviewed as code.

**Snapshot caveat.** Several of these files changed while I was reviewing:
- `data/spell_effects.json` was regenerated: 39 entries became 52, and empty `proof.effect` lists became `needs_live_observation`.
- `docs/goal_targets.json` gained `milestones`, `combat_basics_live_proven`, `combat_tactics`, `knowledge_use`, `efficiency_vs_baseline_pct` and `spell_use_cases_pct`.
- `tools/goal_check.py` and its tests already exist, although they are untracked.

Findings cite what I saw.

## Verdict: **approve with changes**

The skeleton is right:
- predicates over state rather than words, with `null` never counting as a pass;
- a chat-language lint on case text;
- a positive control and negative controls;
- `case_hash` invalidation;
- goal_check's rules that mock-only results don't count and that a live confirmation is required;
- one trace format for every target.

Building the spec, the leaves, BenchWorld and the runner **on the mock** can start now.

`goal_check` must **not** be used as the stop condition for `/goal` until findings 1–6 (Critical) are fixed. In the current design, GOAL MET can be reached through:
- evidence the companion's own code reports;
- denominators that shrink;
- controls run only on the mock;
- judge files the optimising agent can edit;
- a subset command that prints the literal `GOAL MET`.

## Summary

| # | Sev | Section | One line |
|---|---|---|---|
| 1 | Critical | §4, §5.1 | Effect evidence comes from the body's own replies, i.e. from the code under test. Nothing observes it independently. |
| 2 | Critical | §4, §5.1, §8 | `unverifiable` and `skip` drop out of denominators. 14 of 52 spells are `needs_live_observation` today. |
| 3 | Critical | §6 | Validity is established on the mock, where BenchWorld simulates the very effect it checks. That doesn't transfer to the game. |
| 4 | Critical | §6, §4 | The controls are missing wrong-action, alternative-means, partial and ambient cases. Several current proofs pass on unrelated effects. |
| 5 | Critical | §8 | The judge can be tampered with. Scoreboard, validity, targets, leaves and the spell proofs are all writable by the agent being judged. |
| 6 | Critical | §1, §8 | `GOAL MET` can be printed without the goal: by `--milestone`, by test output, or by `echo`. |
| 7 | High | §5.2, §8 | Small n and no error bars. One case can stand in for a family, and one held-out case moves the gap by about 14 points. |
| 8 | High | §2, §5.2 | The held-out split is not sealed: logs, reports, the overfit-test output and the generator archive all leak it. |
| 9 | High | §7 | Persisted companion memory (skill library, map memory, places) carries solutions across cases and pollutes the live stores. |
| 10 | High | §3, §5 | Predicates don't match the task text (coal example, station cases). The cases GOAL requires are left to the generator. |
| 11 | High | §4, §8 | GOAL targets have no leaves: parry/dodge/disengage-heal, weakness, tactics, knowledge use. |
| 12 | High | §7 | Live-confirmation rules contradict GOAL: long combat tasks must be confirmed live, but the live target forbids them. Injected chat would impersonate Luis. |
| 13 | High | §7 Option B | Fixture safety: a circular address check, the character-save leak path to Shockbyte, lease expiry mid-case, and Luis present on the dev server. |
| 14 | High | §9 | The call and runtime budgets can't run the suite. A full measurement is about 15–25 h of serial dev-server time, against a 24 h freshness rule. |
| 15 | Med | §8 | Freshness is by wall clock rather than code hash. Metrics from different commits can be mixed. |
| 16 | Med | §4 | Guards: Kleene `null` semantics are undefined, guards are polled rather than event-driven, and the `lost` spec is inconsistent. |
| 17 | Med | §3 | The latency metric is gameable (a trivial first action, or FakeLLM runs on the mock). |
| 18 | Med | §8 | Obs targets have no minimum exposure: an idle client meets "0 anomalies/h" and "2 h stable". |
| 19 | Med | §8, §5.2 | Suite drift: trends compare different case sets. |
| 20 | Low | §5.1, §3 | T0 need-phrasings are all seen. Hints are generator-written and may give the answer away. |
| 21 | Low | Search record | Adequate for format and scoring. Missing contamination, error bars and reward hacking by the optimiser. |

---

## Critical

### 1. The evidence is self-reported by the code under test (§4 `spell_effect`, `station_used`, `killed`; director §2.1 tallies)
**What happens.**
- `spell_effect` reads `ctx.results`, the cast reply. `runes_spent`, `cooldown_started`, `effects.{ge,tags}`, `spell_actor` and `landed_at` are all fields that `client_mod` computes inside the cast skill.
- `killed` reads `combat_end` episodes, which `combat.lua` emits.
- `tally` reads the Director's own `goals.json` tallies.
- The proofs themselves (`data/spell_effects.json`) are generated by the spells agent, an implementer, from its own live evidence.

**Why that matters.** In an unattended `/goal` loop, the cheapest way to raise `spells_effect_coverage_pct` is to make the cast reply more generous. A bug that reports a stale `LastCastTimeBySpellData` as `cooldown_started` would pass the oracle and the companion alike. The negative controls can't catch it, because they never call the body.

**Fix.**
- **(a) A harness-owned observer.**
  - Add a read-only probe owned by the Eval agent, kept separate from the skills (e.g. `client_mod/commands/bench_probe.lua`). The harness calls it before and after each action, with timestamps.
  - It reads the rune counts in inventory, the pawn's GE and tag lists, `LastCastTimeBySpellData`, position, held effect, census rows, and the server verdict from the crafting result handler.
  - A leaf passes only when the probe's delta and the skill's reply agree. If they disagree, the result is `error: sensor_mismatch`, which counts as not passed and is listed.
- **(b) Server-authoritative audit on dev.**
  - For each build and each evidence kind, sample cases and read the same facts server-side through `mod/`, read-only, on the dev server only.
  - Record the agreement rate in the report. An evidence kind without an audit is reported as "unaudited".
- **(c) Benchmark-side tallies.** The benchmark computes `tally` from its own snapshots and never reads `goals.json`.
- **(d) Freeze and review the judge inputs** (finding 5). In particular, a change to `spell_effects.json` that weakens a proof must invalidate validity and needs a reviewer's sign-off.

### 2. Shrinking denominators (§4 "`unverifiable` is excluded from pass rates", §5.1 `skip: precondition`, goal_check `COUNTED` excludes `skip`)
**What happens.**
- §1 promises "out of every spell in the build's spell data". §4 then excludes `null`, and §5.1 excludes `skip`.
- Today 14 of the 52 spells are `data_weak` / `needs_live_observation`. The enchant spells' `held_item_effect` is `observable: false`.
- So 95% "coverage" could be met on roughly 30 spells. Worse, a regression that makes the probe fail to read something turns a fail into `unverifiable` and **raises** the score.
- The same applies to:
  - `unlocked spells` (GOAL.md's wording): unlocking fewer spells shrinks the denominator;
  - `skip` when a fixture is missing (all of Option A);
  - recipes and stations (finding 10).

**Fix.**
- For every coverage target, the denominator is a frozen, per-build **manifest**: all spells (or recipes, or station kinds) minus an n/a list.
- That list is computed **only from game-data fields** (no name, `needs_unlocking=false` with no runes), never from results. It is printed in full and approved by Luis once per build.
- Only `pass` counts. `unverifiable`, `skip`, `error` and `invalid` count as not passed. They are still reported separately so the gap list keeps driving the work.
- A rise in n/a or in unverifiable between runs is flagged in the report.
- Change GOAL.md's "unlocked spells" to "spells in the build manifest".

### 3. Validity on the mock doesn't transfer (§6; GOAL.md §3 says "a scripted or human run **on the dev world**")
**What happens.**
- §6 runs all three controls on the mock, and uses dev for the positive control only "when a case can't be mocked". That is weaker than GOAL.md.
- On BenchWorld the effect is simulated by the harness in response to `cast`, so `spell_effect` on the mock only checks that the right tool was called with the right name.
- The mock also differs from the game in many ways:
  - no ambient change (weather, hunger, other players);
  - no reflexes (stay-fed, loot pickup);
  - no bag capacity, so "multi-trip" is a single trip;
  - instant `gather` and `attack`;
  - `get_state.places` hands the model the place names;
  - the tool set comes from `GameInterface`, not the client manifest.
- The existing `goal_check.case_valid` already requires the positive control on dev or live, which is good. It accepts negative controls from any target, though.

**Fix.**
- A case counts towards GOAL only if, **on the target where it is scored** (dev or live), the positive control passed and every negative control failed, the new ones from finding 4 included.
- Validity is keyed on `case_hash` **plus**:
  - the hashes of `brain/predicates.py`, `evals/bench/leaves.py` and the case's `spell_effects.json` entry;
  - the companion body hash (`client_mod/scripts`);
  - the game build.
- Any change re-opens validity.
- Mock validity is renamed "lint" and never feeds goal_check.

### 4. The controls miss the real Goodhart paths (§6)
`do_nothing` and `claims_only` catch only predicates that pass trivially. The current data has proofs that pass on the **wrong** cause:

| Case | How it passes without the capability |
|---|---|
| Personal Chest, Eye of Oculus: `ge_added class_contains "DominionGameplayEffect"` | any GE on the pawn (food buff, wet, status) |
| Windstep: an alternative `ge_added "DominionStatusEffect"` | any status effect. "Any of `proof.effect`" means the weakest alternative decides |
| Recall, teleports (§5.1 fallback `moved ≥ N m` from the baseline) | walking N m |
| Harvest (`inventory_gain`) | gathering by hand, or a loot-pickup reflex |
| Internal Alchemy (`vital_change`) | the stay-fed reflex, or vitals simply decaying over time |
| "get me 50 coal" (`gained Coal ≥ 50`) | taking it from a shared chest (Luis allows that), from ground items, or from a vendor |
| `killed {kind:"wolf"}` (substring match in `predicates._killed`) | killing a "werewolf" |

**Fix: add four controls, run on the scoring target.**
- **`wrong_action`**: the oracle with a sibling substituted, e.g. a different spell of the same `cast_type`, or a different recipe at the same station. It must fail. This catches generic evidence.
- **`alt_means`**: produce the leaf's proxy by other means (walk N m, gather, eat, pick up from the ground or a chest). It must fail whenever the case is about the means. The generator declares the means for each case.
- **`partial`**: the oracle cut short before its last step, or with count − 1. It must fail. This shows the threshold matters.
- **`ambient`**: `do_nothing` on dev for the case's full `wall_s`, with reflexes **on**. This replaces the mock-only `do_nothing`.

**And tighten the leaves.**
- Every effect needs an **attribution window**: the evidence is timestamped within [cast start, cast end + w], and no other world-changing tool call happens inside that window.
- `moved` for travel means a displacement within 2 s of the cast, not cumulative distance.
- `vital_change` carries a direction and a minimum magnitude.
- `killed` matches an exact kind id from the catalog.
- `predicates.validate` rejects a `class_contains` that is a base class or that matches GEs of more than one spell.

### 5. The judge is writable by the agent being judged (§2, §8)
**What happens.** These files are all writable by the agent that `/goal` is evaluating:
- `logs/evals/scoreboard.jsonl` and `validity.json`, which are gitignored and unversioned;
- `docs/goal_targets.json` ("Only Luis changes targets" is a comment, not a check; the file changed during this review);
- `data/spell_effects.json`, `brain/predicates.py`, `evals/bench/*` and `tools/goal_check.py`.

Also, goal_check takes the runner's precomputed `metrics` as given.

**Fix.**
- **(a) Re-derive.** goal_check recomputes every metric from the raw run directories (`report.json`, trace and per-case results, each with a sha256 recorded in the scoreboard row). It never uses a precomputed `metrics` value.
- **(b) Record hashes.** Every run records:
  - the git SHA and the dirty flag;
  - the sha256 of each judge file (targets, predicates, leaves, the spec and runner, the spell_effects entries, the task manifest, goal_check itself);
  - the companion hash (`brain/`, `client_mod/scripts`, `data/` profiles).
- **(c) A Luis-approved judge baseline.** For example, a git tag `goal-judge-YYYYMMDD` over the judge files. A diff since that tag means NOT MET, with "judge changed since Luis's approval: <files>".
- **(d) Print it.** goal_check prints the judge hash and the companion hash.
- **(e) Block edits during unattended runs.** A Claude Code `PreToolUse` hook, or a settings deny rule, blocks Edit and Write on the judge files while a `/goal` run is active. Changing them then becomes a "stop and ask Luis" item in GOAL.md §5.

### 6. `GOAL MET` can be printed without the goal (§1, §8)
**What happens.**
- `/goal`'s evaluator reads the transcript.
- The existing `goal_check --milestone M1` prints exactly `GOAL MET` when only M1's subset is met.
- `tests/test_goal_check.py::test_cli_last_line_and_exit_code` produces the literal in captured output, and a failing assert or a `-s` run would echo it.
- Any `echo` or `grep` of a report would too.

**Fix.**
- Subset runs print `MILESTONE M1 MET` and never `GOAL MET`.
- The real final line is `GOAL MET sha=<HEAD> judge=<hash> runs=<ids> at=<UTC>`, printed only when the tree is clean and HEAD equals the measured companion hash.
- Tests set `DW_GOAL_CHECK_TEST=1`, which prints `GOAL MET (TEST)`.
- Word the `/goal` condition as "the final line of `python -m tools.goal_check` run in the same turn, with exit 0 and the sha equal to `git rev-parse HEAD`".
- Add **Luis's sign-off** to GOAL.md as the last gate. goal_check says "ready for Luis", and Luis says "done".

## High

### 7. Small n, no error bars (§5.2, §8; goal_check `family_target`, `live_confirmed`)
**What happens.**
- A family's percentage comes from the newest fresh run that has *any* case of that family, so a `--only` run with one case can give 100%.
- One passing live case "confirms" a whole family.
- The held-out arm of a 24-case batch is about 7 cases, so one case moves the gap by about 14 points.
- Long tasks pass on one lucky run.
- GOAL.md loop step 6 ("keep only if the metric improves") then becomes a coin flip.

**Fix.**
- Set a minimum valid n per target in `goal_targets.json`: for example ≥ 20 for percentage targets, ≥ 30 held-out, ≥ 3 live cases per family.
- Decide on the **Wilson lower bound**, which must reach the target, and print the interval.
- Long tasks use `--repeat k≥3`, and pass^k is reported.
- Metrics come only from **full runs of a frozen suite manifest**. `--only` runs are marked `partial` and ignored by goal_check.
- Step 6 uses a paired comparison on the same cases, with the confidence interval (Miller 2024, see finding 21).

### 8. The held-out split isn't sealed (§2 "gitignored and never included in a brief", §5.2)
**What happens.**
- On one VM with one main agent, gitignored is not hidden.
- The brain's JSONL logs of held-out runs contain the injected chat text and the model's whole solution.
- The report lists failure clusters (reason × tool), which loop step 2 then fixes.
- `test_overfit.py` must read the held-out texts, and its failure message would print the matching phrase.
- The generator's archive "with pass/fail history" can steer new seen cases towards near-duplicates of held-out ones.
- 4-word shingles miss paraphrase, and nothing scans `data/` or the per-world state stores, which hold "profiles" and memory.

**Fix.**
- **(a) The GOAL generalisation number comes from a fresh draw.** A batch is generated **after** the code freeze, seeded from the HEAD sha by goal_check, and run once (LiveBench-style time split). This is the only leak-proof option on a shared VM.
- **(b) Rolling held-out runs report aggregates only**: pass rate by tier, with no per-case reasons or traces in `report.md`. Their brain and body logs go to a separate root (`DW_LOG_DIR=logs/evals/heldout_runs/`). A deny rule plus a PreToolUse hook covers Read, Grep and Bash on `logs/evals/heldout/**` and that root.
- **(c) Generator hygiene.** The overfit test prints only shingle hashes and file paths. The generator never sees held-out texts, and dedupe runs across the split.
- **(d) A Luis-authored held-out set**: 10–20 lines taken from his real chat requests. It is the truest distribution, because the generator's tasks only measure in-distribution transfer.
- **(e) A sounder gap metric.**
  - Stratify the 30% split by tier and family, so the two arms have the same mix.
  - Replace "gap ≤ 10 points" with "held-out pass rate ≥ seen − 10, with a lower bound". The plain gap can be "closed" by doing worse on the seen cases.

### 9. Persisted memory contaminates cases (§7)
**What happens.**
- These stores persist across runs: the skill library, `map_memory.json`, `places.json`, `notes.json`, `goals.json`, `capability_gaps.json` ("all worlds") and nav memory.
- A seen case's learned skill solves its held-out sibling.
- Run 2 of a case replays run 1's answer.
- Mock names such as `far_quarry` can leak into live Claude's stores.

**Fix.**
- Every case starts from a **frozen state snapshot**. It is copied into `DW_WORLD_GUID=bench_<run>_<case>` and discarded afterwards.
- The harness refuses to start if the state dir resolves to the Shockbyte store.
- Principle #8 ("remember what worked") gets its **own** explicit "with memory" variant (run the case twice, and measure the second run's calls and time), so learning is measured rather than leaking.

### 10. Predicates don't match the task text; the required cases are generated (§3, §5)
**What happens.**
- The §3 example says "get me 50 coal … use the lodestones". Its predicate is `gained Coal ≥ 50` in *his* bag. That checks neither delivery ("me"), nor multiple trips (the mock has no bag limit), nor lodestone use.
- The T0 station cases give the inputs as fixtures and pick the **cheapest** recipe, yet `craft_from_scratch_pct` means "gather → process → craft" over recipes. No metric definition links cases to that number.
- The five GOAL long tasks and the combat basics would come from Sonnet, together with their own oracle, so the predicate and the positive control share one author.

**Fix.**
- **(a) Hand-write the GOAL cases.** Main writes the GOAL-required cases (the 5 long tasks, the combat basics, the craft sample), Luis reviews them, and their hashes are pinned in `goal_targets.json`.
- **(b) A frozen metric → case-selector table:** which family, tier and fixture policy feed each target.
  - `craft_from_scratch_pct` uses **no input fixtures** and a seeded random sample of recipes from the full graph, stratified by depth.
  - The n/a list is data-derived: entitlement-only recipes and `GOLD[...]` unlocks.
- **(c) Independent predicate audit.** For generated cases, a second model call sees only the chat line and the predicate (not the oracle) and answers "would the player say this was done? what's missing?". Together with the `partial` control, that catches thresholds that are too weak.
- **(d) Delivery and trips.** "Get me" means a delivery predicate (`near player` + `lost` from his bag, or a body `give` or `drop` episode at the player). Multi-trip means a harness tally, ≥ 2 deposit episodes, and a bag limit in BenchWorld. A required lodestone use is a body teleport episode.

### 11. GOAL targets with no leaves (§4, §8 vs `goal_targets.json`)
**What happens.**
- These targets have no leaf or metric in the design:
  - "parry/dodge/disengage-heal" and "weapon chosen for weakness";
  - `combat_tactics` (preparation, telegraph dodge, damage trend);
  - `knowledge_use`;
  - `efficiency_vs_baseline_pct`.
- `knowledge_use.lookup_when_needed_pct` must read the model's tool calls, which §4 bans for predicates.

**Fix.** Add leaves from body episodes:
- `damage_type_dealt {types ⊇ creature weakness from data}`;
- `defended {kind: parry|dodge, min, against: telegraph}`;
- `disengaged {then: vital_or_health_rise}`.

Then define **process metrics** (they read the trace's tool calls, may never decide `success`, and are listed separately) for knowledge use and efficiency. Add all of them to §8, with their denominators.

### 12. Live confirmation contradicts GOAL (§7)
**What happens.**
- The live target is limited to `risk: low`, ≤ 5 minutes, no combat and no fixtures.
- GOAL requires live confirmation of hour-long tasks that include combat (farming a mob drop).
- The target label in a scoreboard row is self-declared.
- On live, injected `chat_heard` lines from "the test player" would make Claude answer, in a public world, things Luis never said.

**Fix: a separate *live-confirmation protocol*.**
- Luis is present, and only his real chat counts; nothing is injected live.
- The target is proven from the trace: the game log's `LoadMap` address equals `server.txt`, and Luis's player row is present.
- Luis records the confirmation himself (a CLI `tools/goal_confirm.py <case>` that he runs, or a chat line he types), and it is stored with the trace hash.
- goal_check counts only those confirmations.

### 13. Fixture safety (§7 Option B) and the risk to Shockbyte
Physically, the `mod/` debug_run trigger is a local file read by the local server process, so it **cannot** act on Shockbyte, which is vanilla. Make that the stated primary guarantee, and check that the trigger is consumed by the dev server's PID. The real risks are elsewhere:
- **(a) The address check is circular.** "The target address must be the dev target file's" compares a file with itself. Require all of these:
  - the dev address ≠ the `server.txt` address;
  - the dev address resolves to loopback or this VM;
  - the joined `LoadMap` address = dev, re-checked before **every** setup call and every brain action, not only at preflight.
- **(b) Who gets touched.** Target Claude's dev character by GUID, never by name. Refuse setup if any other player is connected to the dev server; Luis has joined it as Zezima before, per DISCOVERIES.
- **(c) Character-save leak (the main residual risk to Shockbyte).**
  - The dev server writes `Claude.json` through `Client_SaveToDisk`, and Steam Cloud syncs it.
  - On Shockbyte, the cached copy wins *for a GUID it already knows*. But Jagex's "most-frequently-visited world overrides on login" rule is unverified, and many benchmark hours on dev could make dev the most-visited world.
  - Any loss of Shockbyte's cache would also adopt a file full of granted runes. That would be cheating in the group's world.
  - **Fix:** use a dedicated dev character (its own slot or GUID, or the dev Steam account). Otherwise, restore `Claude.json` from the pre-run backup with the client closed before rejoining Shockbyte.
  - Turn scenario_run's post-run Shockbyte diff into a **hard alarm** (stop, tell Luis) instead of a report line.
- **(d) Lease expiry mid-case.** T3 has `wall_s` 3600, and the lease defaults to 45 minutes. When the lease expires, the watchdog rejoins Shockbyte while the harness's brain is still acting (combat, AoE spells near the group). Renew the lease on every tick, make it at least `wall_s` + margin, and kill the brain session at once on any server change.
- **(e) No Shockbyte path in the bench.** Don't expose scenario_run's `--here --allow-shockbyte` path. The bench's live target can never call setup.
- **(f) Dependency on legacy code.** `mod/` is legacy and is being deleted skill by skill. Keep the fixture verbs in one small, frozen, reviewed file, so that deleting `mod/` doesn't silently remove them or widen them.
- Also add a check that `run_live` or its supervisor doesn't restart mid-run, which would put two brains on one pawn. Preflight-only checking misses that.

With (a) to (e) in place, the risk to Shockbyte is low. Without (c) it is not negligible.

### 14. The budgets can't run the suite (§9)
**What happens.**
- "≤ 40 calls per run" and a per-case `model_calls: 40` conflict with director.md's own rates (20 Sonnet calls/h plus 60–120 Haiku runs/h). A 1-hour T2 or T3 case would be stopped by the cap, which is a capability failure manufactured by the harness.
- My rough estimate for **one** full GOAL measurement on dev, serial (one pawn):

| Block | Cases | Model calls | Dev wall time |
|---|---|---|---|
| T0 spells | about 45 | about 135 Haiku | 2.5–3 h (setup, travel, cooldowns of up to 120 s) |
| Craft from scratch | about 20 sampled | about 300 Haiku + about 40 Sonnet | 4–6 h |
| Combat + adversarial | about 30 | about 300 Haiku | about 2 h |
| Long tasks | 5, at k = 3 | 1,300–3,600 Haiku + 300–600 Sonnet (at k = 1: 450–1,200 Haiku + 100–200 Sonnet) | 15–30 h at k = 3 (5–10 h at k = 1) |
| Validity on dev | every case | oracle, partial, wrong_action and alt_means: few model calls | `ambient` runs for the full wall time: +50–100% |

- At k = 1, that is about **1.2–2k Haiku and 150–250 Sonnet calls, and 15–25 h of dev time**. The k ≥ 3 that finding 7 asks for multiplies the long-task block by three, which puts it beyond any single day.
- The money is modest: at director.md's ~$0.02 per Sonnet call, Sonnet comes to a few dollars per measurement, and Haiku adds tokens. The binding constraint is **wall time**, combined with the 24 h freshness rule and a Luis live session per family per day.
- The generator's 3–6 Sonnet calls per 24 cases is realistic for drafting. Not budgeted: the independent predicate audit (+1 per batch), and **turning mock oracles into dev oracles** (mock place ids like `far_quarry` don't exist on dev).

**Fix.**
- Use per-tier call and wall budgets, sized from director.md's rates.
- Run three cadences:
  - a per-cycle **smoke subset** (mock plus about 10 dev cases touching the changed area);
  - a **nightly full** dev run;
  - **live confirmations** batched with Luis.
- State the full-run numbers in §9 before the first run.
- Freshness by code hash (finding 15) removes the need for daily full re-runs.

## Medium

### 15. Freshness by wall clock, mixed commits (§8)
**What happens.** "Older than 24 h = NOT MET" forces costly re-runs, yet a commit one hour ago invalidates nothing. Spells measured at SHA A, crafting at SHA B and live confirmations at SHA C can combine into GOAL MET.

**Fix.**
- Fresh means measured at the current companion hash and game build.
- Every counted row must share that hash; mixed hashes mean NOT MET.
- Keep a wall-clock limit only for obs metrics.

### 16. Guards (§3, §4)
**What happens.** With Kleene `not`, `not null` is `null`, and the design doesn't say what a `null` guard does.

**Fix.**
- A `null` guard makes the case `unverifiable` (not passed), never "held".
- "Never attack a player" and "no death" read the body's **event stream** (hit and death events), not polled state, so a violation between polls isn't missed.
- The spec example `{"not": {"lost": {"item": "*", "equipped": true}}}` lacks the `at_most` that §4's `lost` defines. Pick one shape and test it.

### 17. The latency metric is gameable (§3)
**What happens.** The "first body `tool_call` that isn't a read" can be a trivial `stop` or `say`, and FakeLLM runs on the mock have near-zero latency.

**Fix.**
- Latency targets come only from real-model dev and live runs.
- Exclude `stop`, `say` and `remember`.
- Report a second figure: the time to the first action of the plan that eventually passed.

### 18. Obs targets need minimum exposure (§8, GOAL §1)
**What happens.** "0 anomalies/h" and "2 h without crash" are met by an idle client.

**Fix.** Require at least N hours of **active** play at the current hash: the brain running, ≥ X tool calls per hour, and real player chat present. Report the exposure next to each value.

### 19. Suite drift (§8 trend, §5.2 "grows by itself")
**What happens.** The trend compares different case sets.

**Fix.**
- Use versioned suite manifests. New cases enter a `candidate` pool and join the GOAL suite only at a manifest bump.
- Trends are drawn only across identical manifests.
- A bump re-baselines.

## Low

### 20. Phrasings and hints (§5.1, §3)
**What happens.**
- The T0 need-phrasings are generated once and are all seen, so persona and tool-description tuning can fit them.
- Hints such as "coal's in Fellhollow, there's a lodestone near the bridge" are written by the generator and hand over the answer.

**Fix.**
- Add a held-out phrasing for each spell.
- Use a fixed hint ladder (a generic nudge, then a pointer, then the specific answer), and record the hint level used in the result.

### 21. The search record (adequate for its purpose)
**What is there.** Twelve relevant sources, which meets the ≥ 3 URL rule, and a sound adapt-vs-build decision (Inspect AI was considered).

**What is missing.** Sources on exactly the risks above. Suggested additions:
- contamination control: the BIG-bench canary string (https://github.com/google/BIG-bench) and LiveBench's time-split fresh questions (https://arxiv.org/abs/2406.19314);
- error bars for small eval sets: Miller, "Adding Error Bars to Evals" (https://arxiv.org/abs/2411.00640);
- reward hacking by the optimising model: METR's 2025 report on frontier models reward hacking, and the ImpossibleBench line of work;
- human-validated task subsets: SWE-bench Verified;
- how Claude Code's `/goal` evaluator reads the transcript, which matters for finding 6.

---

## Answers to the brief's questions
1. **Goodhart, per tier.**
   - **T0:** generic or self-reported evidence (findings 1, 4), denominators that shrink (2), and mock-tautological effects (3).
   - **T1:** inputs given as fixtures, the cheapest recipe chosen, "gained" items coming from chests (4, 10), and weakness that is never checked (11).
   - **T2:** a bag predicate instead of delivery, a bagless mock that removes the multiple trips, lodestones that are never verified, and Director tallies (1, 10).
   - **T3:** generator-authored predicates, oracle and hints (10, 20), `quest` returning null and so dropping out (2), memory carried over between runs (9), and one lucky run (7).
   - **Implementer-side:** editing the judge, the proofs or the scoreboard (5), and leakage through logs (8).
2. **Validity controls.** `oracle`, `do_nothing` and `claims_only` are not enough. Add `wrong_action`, `alt_means`, `partial` and `ambient` (finding 4). Validity on the mock doesn't transfer. For a case to count, its positive and all negative controls must pass and fail respectively on dev or live, keyed to the judge, body and build hashes (finding 3). On top of that, each evidence kind needs a server-side audit (finding 1).
3. **Held-out.** The split isn't sealed on a shared VM. Use a fresh post-freeze draw for GOAL, aggregate-only rolling results, deny rules and hooks, and a Luis-authored set. The gap metric needs stratification, an absolute floor, a minimum n and a confidence bound (findings 7, 8).
4. **Denominators.** Yes, they can be gamed through `unverifiable`, `skip`, "unlocked" and cheapest-recipe selection. Freeze data-derived manifests, and count every non-pass against the target (findings 2, 10).
5. **goal_check paths to a false GOAL MET.**
   - `--milestone` printing `GOAL MET`, test output, or an echo (finding 6);
   - editable scoreboard, validity and targets files, and a weakened `spell_effects.json` or leaves (5);
   - precomputed metrics taken as given (5);
   - subset runs and n = 1 families (7);
   - a single live case confirming a family, or a self-declared live label (12);
   - negative controls run only on the mock (3);
   - mixed SHAs, or wall-clock freshness after a commit (15);
   - targets with no leaves (11);
   - idle exposure (18);
   - unverifiable or skip dropping out of denominators (2);
   - held-out leakage (8).
6. **Fixtures.** Mostly safe, because the trigger is local and Shockbyte is vanilla. Fix the circular address check, target by GUID with no other players present, close the character-save leak, renew the lease, and never expose the Shockbyte path (finding 13).
7. **Cost and runtime.** The dollar cost is fine. Wall time is not: about 15–25 h per full measurement at k = 1, more at the k ≥ 3 finding 7 asks for. The per-run cap of 40 calls contradicts the Director's rates. Use per-tier budgets and three cadences (finding 14).
8. **Search record.** Adequate for the format and scoring choices; add the contamination, error-bar and reward-hacking sources (finding 21).
