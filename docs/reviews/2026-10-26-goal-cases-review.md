# Review: draft GOAL cases (`evals/bench/goal_cases/`), 2026-10-26

Reviewer: a fresh-context agent. I did not write the cases or the leaves.

**Read:**
- `docs/GOAL.md`, `docs/goal_targets.json`, `docs/design/PRINCIPLES.md`;
- `docs/reviews/2026-10-25-eval-benchmark-review.md`, findings 1, 4 and 10–12, 16 and 20;
- `brain/predicates.py`, `evals/bench/leaves.py`, `evals/bench/spec.py`, `evals/bench/goal_drafts.py`.

**Also checked:** what each leaf can actually see on dev:
- `evals/bench/runner.py` (`probe_state`, `judge`), `evals/bench/observer.py` (`evidence_ctx`), `evals/bench/devrun.py` and `evals/bench/devtarget.py`;
- `client_mod/commands/bench_probe.lua`, `mod/bench/referee.lua`, `mod/bench/fixtures.lua`;
- the selectors in `tools/goal_check.py`, the catalogs `data/*_26161880.json`, and the local wiki pages (Velgar, Velgar/Strategies, Goblin Runt, Dragon Slayer, Goblin Diplomacy, Lodestone, Desert Weed, Skills).

**Results of those checks:**
- All 60 cases lint clean (`spec.lint`), and every predicate validates (`P.errors`). The problems below are about meaning and evidence, not syntax.
- I did not edit any case.

## Verdicts

| File | Cases | Verdict |
|---|---|---|
| `long_tasks.json` | 5 | **Changes needed.** Two cases can never pass as written (the `delivered` leaf). None of the five proves its GOAL text. |
| `combat_basics.json` | 3 | **Changes needed.** No referee for `defended`. `disengaged` turns a perception gap into a failure. Direction and eating are unchecked. |
| `tactics_knowledge.json` | 6 | **Changes needed.** The "hard fight" is a power-level 1 runt. Prep is `any` of three. One hit of fire passes "weakness". |
| `m3_every_skill.json` | 36 | **Changes needed.** The leaf is the right one (observer XP), but the threshold is 1 XP. Agility, Mining, Woodcutting and Magic XP come incidentally, and a fixture verb is missing. |
| `m6_capstone.json` | 10 | **Changes needed.** The Vel'gar prep needs only one item. Gear, food and live attack answering are missing. Stage 9's threshold is off by one tier. The stage chat hands him the walkthrough. |

**Do not pin any hash yet.** `case_hash` covers `oracle` and `controls`, and 59 of the 60 cases have neither. Adding the positive controls the GOAL requires (§3, "eval of the eval") would change every pinned hash and force a second approval. Pin once cross-cutting fixes C1–C8 are done and each case has a dev oracle.

---

## Cross-cutting findings (they apply to several files; fix them once)

**C1. The `delivered` leaf can't pass a "gather, then give" task.**
- `leaves._delivered` computes `lost = probe0[item] − probe1[item]`, which is *his* bag at the start minus his bag at the end.
- He starts with 0 coal, mines 50 and hands over 50, so `lost = 0`. Then `arrived = min(lost, got + near) = 0`, and the result is FAIL.
- The same applies to `goal_farm_mob_drop`. Both GOAL long tasks with a delivery are impossible to pass.
- **Fix (a judge change in `leaves.py`):**
  - Count what he handed over from the referee's `item_change` stream: the sum of his negative deltas of the item that coincide with a positive delta for `to`, within a few seconds.
  - Alternatively, count gross outflow from the harness's own per-observation probes. Do not use the start/end difference.
  - Add a regression test, "0 at start, 0 at end, 50 delivered → pass".

**C2. Evidence the dev target can't produce yet.** These leaves read fields that the probe doesn't have (its `gaps` are `held_effects, ground, creatures, players_inventory`; there is also no `gear`, `bag` or `quests`) or event kinds the referee doesn't emit. `REFEREE_SUPPORTS` is only `item_change, damage, death`. Referee `damage` has no `by` field and no `damage_type`.

| Leaf | On dev today | Cases affected |
|---|---|---|
| `trips` (deposit) | null; there is no deposit kind at all | coal, mob drop |
| `teleports` with `via` | null; once supported, still 0, because the referee's `teleport` has no `via` | coal |
| `no_event damage_to_player` | null, so the guard makes the case **unverifiable** forever | mob drop |
| `defended` | null | dodge, parry |
| `quest` | null | quest chain, capstone stages 1–6 |
| `gear_better` | null (no `gear` in the probe) | gear upgrade, stage 9 |
| `delivered` | null (no `players`/`ground`), then C1 | coal, mob drop |
| `prepared` enchant_type | never matches (held_effects gap) | prep, Vel'gar |
| **`damage_type_dealt`** | **FALSE, not null**: it filters `by == "self"`, which the referee never sets, so 0/0 hits | mob drop, weakness |
| **`disengaged`** | **FALSE, not null**: it reads `creatures`, which the probe doesn't have, so it never leaves stage 0 | disengage |

- **Fix:** any leaf whose evidence is missing must return `None` and list it in `missing`. Change `damage_type_dealt` and `disengaged` to do that.
- Each case should declare the evidence kinds it needs, so `goal_check` can say "blocked on referee:deposit" instead of reporting a capability failure.
- Add the kinds to the referee before pinning. The event schema (`via`, `by`, `damage_type`, `direction`, `telegraphed`) decides what the cases can ask for, so it must exist first.

**C3. The kill credit isn't attributed to him.** `evidence_ctx` turns every referee `death` within the radius into a `combat_end killed`. Kills by another mob, fall damage or a harness despawn all count as his.
- **Fix:** the referee records the last damager (`by`), and `killed` on dev requires `by == "self"`.

**C4. `player_body` is declared but not implemented.**
- The coal, mob-drop and desert-weed cases need a "Tester" body: something to deliver to, and something whose inventory the referee watches.
- Nothing spawns that body, and the dev setup assumes no other player is on the server.
- **Fix:** define the Tester body (what class, how it is spawned, that the referee tracks its inventory) and make the guard allow exactly that body.

**C5. The snapshots don't exist and aren't hashed.**
- There is no `evals/bench/state_snapshots/` directory, so `fresh_dev_v1`, `capstone_v1` and `empty` are undefined.
- `case_hash` covers only the snapshot's *name*. Editing a snapshot (for example, adding an antipoison potion to `capstone_v1`) changes the result without changing the hash, so the judge freeze can be bypassed.
- **Fix:**
  - Hash the snapshot's contents into `case_hash` (or store its digest in the case).
  - Write each snapshot's manifest: gear per slot, bag, skills, quests done, lodestones built and unlocked, spawn position.
  - Review the manifests with the cases.

**C6. Fixture verbs that don't exist.** `mod/bench/fixtures.lua` supports `grant, grant_runes, unlock, set_time, spawn, reset_skills, teleport, clear_area`. The cases use more than that:
- `raise_other_skills`: all 12 initiative cases;
- `grant_to_ground`: three alt_means controls;
- `ground_item`: the no-lookup case;
- `place`: the desert-weed case.

Also, `reset_skills` ignores its `level` argument (it calls `domResetSkillXP`).
- **Fix:** specify and verify these verbs (as dev-only setup) before pinning, or rewrite the cases to use existing verbs.

**C7. No positive controls and almost no negative controls.**
- Only `goal_knowledge_no_lookup_needed` has an oracle.
- Only 4 cases declare any control.
- Every `na` is `{}`, with no reasons recorded.
- GOAL §3 says a case does not count until it has a dev positive control and fails `do_nothing`, `claims_only`, and the review's `wrong_action`, `alt_means`, `partial` and `ambient`.
- The per-file sections below list the controls that matter for each case.

**C8. The chat names the method, and the case still feeds `knowledge_use`.**
- Four chat lines tell him how to do it: "check the wiki … use the lodestones" (coal), "the wiki has the steps" (quest), "read up on him" (Vel'gar), and the stage chat in m6.
- GOAL §3 says "phrased as chat, never tool names"; M3 adds "no tool or method named".
- Cases with `needs_fact` feed `lookup_when_needed_pct`, and an instruction to look it up inflates that number.
- **Fix:** take the method out of the scored phrasing, or drop `needs_fact` from that case. Either way, add `forbid_terms` (C9).

**C9. `forbid_terms` is empty in all 60 cases.** Without it, a later phrasing edit can leak the answer silently. Add the answer words per case. Each file section below gives the list.

**C10. The aggregation in `goal_check` doesn't match the case design.**
- `combat_tactics:prep_before_hard_fight_pct` uses `family == "tactics"`. That family includes `goal_tactics_damage_trend`, whose success is "killed a runt", so a kill counts as "prepared".
  - Fix: give the trend case its own family or tag.
- `combat_basics_live_proven` and `capstone:slay_velgar_solo` are scored pass^1, but the basics declare `repeat: 3`.
  - Fix: decide k for each (I recommend k = 3 for Vel'gar, like the long tasks) and make the case and `goal_check` agree.
- None of the drafts feeds `telegraph_dodge_success_pct` (see T-7).

---

## `long_tasks.json`: changes needed

**L-1. `goal_gather_coal_multitrip`: C1 makes the case impossible.** Fix C1.

**L-2. `goal_gather_coal_multitrip`: "multi-trip" isn't forced.**
- Coal stacks to 99 (`recipes_26161880.json`), so 50 coal is one slot and one trip.
- `trips` counts *any* deposit event: no item filter, no `who`. Two deposits of his starting junk would pass it.
- It is also unclear what a trip deposits *into*, given that success is delivery to Tester.
- **Fix:**
  - Constrain the bag with a fixture, for example fill it so that at most about 25 coal fits.
  - Define a trip as ≥ 2 separate delivery events of coal to Tester (from referee `item_change`, C1), each ≥ 1 coal and separated by mining.
  - Or, if a trip means storage, filter `trips` by item and by `who == self`.

**L-3. `goal_gather_coal_multitrip`: the predicate doesn't prove he gathered the coal.**
- Taking 50 coal from a shared chest, which Luis allows for items in general, would satisfy delivery.
- **Fix:** add a harness-side gather proof:
  - `xp_gained {skill: Mining, at_least: 50 × coal XP per ore − tolerance}`, which comes from the observer;
  - and/or referee `item_change self +coal` events that are not paired with a container. Container interaction needs a referee kind of its own.
- Add `alt_means: coal in a nearby shared chest`, which must fail.

**L-4. `goal_gather_coal_multitrip`: lodestones.**
- Lodestones are player-built (wiki: Stone ×32, Rune Essence ×20, Vault Core). On a fresh world, the only one is the Temple lodestone, which becomes active once a first lodestone exists.
- The chat says to use them "if it's far", yet the predicate *always* requires a lodestone teleport.
- **Fix:**
  - The `fresh_dev_v1` manifest (C5) must state which lodestones exist and are attuned.
  - The start position must be set (with `teleport`) so that every coal region is far, which makes the condition in the chat true.
  - The referee must emit `via` (C2).
  - The 30 Law runes are fine as setup (cost = distance/1000 × weight/1000, minimum 1).
  - A death and respawn also creates a jump of ≥ 300 m. The death guard covers that today, but `_teleported` should still exclude jumps that coincide with a death.

**L-5. `goal_gather_coal_multitrip`: leaks.**
- "check the wiki for where it is, and use the lodestones" names the method (C8), and `needs_fact: location` is set.
- **Fix:** score on a method-free phrasing, e.g. "can you get me 50 coal? I'm at the base". Keep the current line as a hint-ladder L1/L2 at most.
- The held-out phrasing "fifty-ish" contradicts `at_least: 50`. Say "fifty", or accept 45.
- `forbid_terms`: Fellhollow, Dowdun, Umbral, lodestone, wiki.

**L-6. `goal_farm_mob_drop`: C1 makes the case impossible, and C2 makes it unverifiable** (the `damage_to_player` guard has no referee). Fix C1 and C2, or replace the guard with `no_event {kind: damage, who: Tester}` once player damage carries `by`.

**L-7. `goal_farm_mob_drop`: "with the right weapon" is one hit.**
- `damage_type_dealt` passes on a single fire hit, out of a farm of 20 kills.
- **Fix:** add a `min_share` (or `min_kills`) argument and require, for example, ≥ 60% of his damage to runts to be fire, or ≥ 15 of 20 killing blows with fire.
- Add `wrong_action`: the oracle using a non-fire weapon must fail.

**L-8. `goal_farm_mob_drop`: the source isn't proven.**
- Packs from a chest, or from another goblin type, pass.
- **Fix:** add `killed {kind_id: BP_AI_RuntGoblin_Character_C, at_least: 20}`, attributed to him (C3).
- The `trips ≥ 2` requirement has no support in GOAL (b), and packs stack to 99. Drop it, or force it as in L-2.
- Add a death guard, as the other long tasks have.

**L-9. `goal_farm_mob_drop`: leaks and controls.**
- "gear up for them first" nudges the preparation being measured. That is optional; I'd score without it.
- `forbid_terms`: fire, burn, weak.
- `partial`: 19 packs.

**L-10. `goal_gear_upgrade_self_initiated`: the predicate is narrow and partly unverifiable.**
- It covers only `body`, `pickaxe` and `sword`, so an upgraded bow, staff, axe, helmet or legs is a false fail.
- `pickaxe` with `where: equipped` contradicts the predicates doc ("for tools and weapons use carried").
- `gear` isn't probed (C2).
- **Fix:**
  - Use one `any` over every equipment slot and every tool and weapon category, generated from the catalog.
  - Use `where: carried` for tools and weapons, plus proof of use: referee damage with it, or Mining/Woodcutting XP after he got it.
  - `power_level` steps in whole tiers (T3 Bronze = PL3, T4 Iron = PL4, …), so `>` start is "one tier". That's good.

**L-11. `goal_gear_upgrade_self_initiated`: the start gear decides whether the case means anything.**
- Against an empty slot, `gear_better` passes for *any* new item ("a NEW matching item beats nothing"). Picking up an Adventurer's Tunic would count as an upgrade.
- Entitlement items, such as `ITEM_Armour_T1_Body_GildedPaladin` at PL4, would be a free "+3 tiers".
- **Fix:**
  - `fresh_dev_v1` gives known gear in every slot (for example a full T2/T3 set).
  - Exclude entitlement/GOLD items through the data-derived n/a list.
- L3 hint "a bronze pickaxe would help" implies he has no pickaxe or a worse one. Make it consistent with the snapshot.
- `forbid_terms`: gear, armour, weapon, pickaxe, upgrade, craft.
- Controls:
  - `partial`: crafted the better item but never equipped or used it, which must fail;
  - `alt_means`: a better item in a shared chest. Decide with Luis whether it counts.

**L-12. `goal_brynmoor_quest_chain`: a single quest isn't a chain.**
- Goblin Diplomacy is a single *secondary* quest.
- Its prerequisite is Rune Mysteries. Is that done in `fresh_dev_v1`?
- **Fix:**
  - Define the chain with Luis, e.g. Rune Mysteries → Goblin Diplomacy.
  - Success = `all` of the chain's quests completed, in order.
  - Add stage predicates for progress and the `partial` control.
- `quest` needs quest state from the **probe or referee**, never from Claude's `get_state` (C2).
- "the wiki has the steps" is C8. Score "let's do the Brynmoor quests, start with Goblin Diplomacy".

**L-13. `goal_farm_desert_weed`: the predicate doesn't prove farming.**
- `gained ≥ 20` plus `near our farm (30 m)` *at the end* passes if he picks wild weed in Umbral Sands (1–2 per plant, which also drops seeds) and walks back to the farm.
- It also passes the declared `grant_to_ground` alt_means if the grant lands near the farm. That means the case fails its own control.
- **Fix:** require planting and harvesting at the plots:
  - seeds lost (referee `item_change self −seed`) while within the plot radius;
  - then desert weed gained in multiples of the plot yield (5 per harvest) while within the plot radius;
  - or a plot-state read in the probe or referee.
- Add `alt_means: wild gather in Umbral Sands` and `alt_means: chest`, both of which must fail.

**L-14. `goal_farm_desert_weed`: the threshold, the wording and the time.**
- "a stack" is 99 in this build, so 20 isn't a stack.
  - Fix: say "twenty-odd" in the chat, or set `at_least` to 99 (and check that this fits in `wall_s`).
- Growth time and the watering cadence are not recorded. With `idle_s: 300`, the runner ends the run if he waits more than 5 minutes between tool calls for a crop to grow.
  - Fix: measure the stage times on dev and set `idle_s` above the longest wait.
- The `place` verb and the `<farm plots position on dev>` placeholder must be resolved (C6). The placeholder lint only fires at status `suite`.
- State whether the plots, seeds, water and compost are fixtures. Plots: yes, that's setup. Seeds: no, getting them is part of farming.
- `forbid_terms`: yew, plot, seed, water.

---

## `combat_basics.json`: changes needed

**B-1. All three are blocked on dev.** `defended` has no referee kind, and `disengaged` reads the probe's missing `creatures` (C2). Until those exist, M1 `combat_basics_live_proven` can't be met. Add the referee `defended` kind with fields `how`, `outcome`, `telegraphed`, `attack_id`, `direction`.

**B-2. `goal_basic_dodge_directional`: direction isn't checked, and "missed" counts.**
- `_defended` accepts `outcome ∈ {parried, dodged, missed, negated}` for `how == dodge`. A dodge pressed while the swing would have missed anyway (out of range, or he had walked off) counts.
- Nothing checks "direction".
- **Fix:**
  - For dodges, accept only `outcome == "dodged"`, meaning i-frames or the hitbox avoided, judged by the referee.
  - Require `direction_ok`, meaning the dodge vector was away from or across the attack.
  - Add a rate: `at_least 3` **and** ≥ X% of the telegraphed attacks during the window were dodged. Spamming dodge must not pass.
- Make sure ≥ 3 telegraphs happen within 300 s:
  - the runt must survive, e.g. no weapon in the `empty` snapshot, or spawn it with a high `level` (the `spawn` verb takes one);
  - check that the runt actually has a telegraphed "big swing"; if it doesn't, pick a creature that does.
- Controls:
  - `alt_means`: walk out of range, which must fail;
  - `wrong_action`: block instead, which must fail;
  - `ambient`: if a dodge reflex exists, decide whether it counts as "him" (two speeds says yes; write that down).

**B-3. `goal_basic_parry`: the wording contradicts the measure.**
- "block its hits" asks for a held block, but GOAL asks "parry lands in the window", and the leaf has no `against: telegraph`.
- **Fix:**
  - Chat: "parry its swings", or "time your blocks"; "parry" isn't a tool name, so it passes lint.
  - Success: `defended {kind: parry, outcome: parried, at_least: 3}` plus a parried/attempted rate, so that block spam doesn't pass.
  - Add the death guard the other two cases have.
- The wooden shield grant is fine as setup.

**B-4. `goal_basic_disengage_heal`: GOAL's "eat" isn't checked, and the re-engage evidence is his own tool call.**
- Stage 2 accepts *any* rise in health, sustenance or hydration, so natural regen or a drink counts.
- Stage 3 is `o.tool == "attack"`, his own call, even if it failed.
- **Fix:**
  - Stage 2 requires a referee `item_change self −1` of a food item (the granted Seared Anchovies) after he disengaged.
  - Stage 3 requires referee damage `by: self` on *any* of the three runts after he ate.
- Make the chat true when it is said:
  - "you're getting hammered" at t = 0, at full health, is false;
  - trigger the line when the probe's health is below about 50%, or set his health low with a dev fixture;
  - check that 15 m actually breaks runt aggro (measure it), otherwise "disengaged" can't be reached.
- Controls:
  - `alt_means`: eat in place without disengaging, which must fail;
  - `partial`: no re-engage;
  - `ambient`: stand still and regenerate.

---

## `tactics_knowledge.json`: changes needed

**T-1. `goal_tactics_prep_hard_fight`: it isn't a hard fight, and prep is `any`.**
- The "boss" is a power-level 1 runt (60 HP), the weakest mob in the data. The chat calls it "nasty", which is false, so a correct agent may skip preparing.
- GOAL asks for "a dragon-class fight".
- `prepared.any` passes on one item: carrying a single Seared Anchovy.
- **Fix:**
  - Spawn a creature whose power level is ≥ 2 above his gear, using the data and the `spawn` `level` argument.
  - Require ≥ 2 distinct preparations taken from that creature's data: the right damage type or enchant for its weakness, a shield spell, food *eaten* or ≥ N carried, gear above the start.
  - Add a `min` to `prepared` (`at_least: k`), which is a leaf change.

**T-2. `prepared` anchors to the wrong moment.** It takes the snapshot before the *first referee damage event of the run*, which can be a rat on the way, or him being hit.
- **Fix (a leaf change):** a `target_kind_id` argument, so the snapshot is taken before the first damage involving the target. Use it in T-1 and in Vel'gar.
- Enchant evidence needs `held_effects` in the probe (C2).

**T-3. `goal_tactics_damage_trend`: the success predicate is a trivial kill, and the trend may be impossible to show.**
- The real target (damage taken drops over 5 fights) is a process metric outside the predicate.
- A runt at power level 1 may deal 0 damage to him from fight 1, which gives a flat trend.
- `repeat: 5` as five separate runs only shows learning if per-world memory carries over between repeats. The benchmark design resets memory to stop contamination (review finding 9).
- **Fix:**
  - One case with 5 sequential spawns of a creature that hurts (the chat already says "these", plural), with memory explicitly kept within the case.
  - Success = all 5 killed (C3) plus the trend computed from referee damage to `self`.
  - Move the case out of the `tactics` family (C10).
  - Add a death guard.

**T-4. `goal_knowledge_weakness`: one fire hit passes, and he has no fire source.**
- From the `empty` snapshot he can't deal fire in 600 s without crafting. The case then tests crafting, not knowledge.
- **Fix:**
  - Grant a *choice* as setup: a sword, a staff, and fire, water and air runes, so the choice is what's tested.
  - Success = the runt killed (C3) and ≥ 60% of his damage to it is fire (L-7's `min_share`).
- `damage_type_dealt` is currently FALSE on dev (C2).
- `wrong_action`: the same oracle with water runes.
- `forbid_terms`: fire, burn, flame.

**T-5. `goal_knowledge_recipe` and `goal_knowledge_location`: alt means and the start position.**
- `have Bronze Pickaxe` and `gained Clay ≥ 5` pass from a chest or ground items.
- **Fix:**
  - The recipe case adds proof that he crafted it: referee craft events (C2), or Artisan XP gained (`xp_gained`, from the observer).
  - The location case adds Mining XP gained, because clay is mined (wiki).
  - Both set the start position (with `teleport`) so that the fact is *not* in his perception: no clay within census range, and no recipe shown in a station UI in sight.
- "find **us** some clay" implies he brings it back. Either say "go get some clay" or add `delivered`.
- `needs_fact.truth: "Whispering Swamp"`: confirm clay isn't also in other regions, otherwise the fact check will mark a correct alternative as wrong.

**T-6. `goal_knowledge_no_lookup_needed`: it may pass `ambient`.**
- The body has a loot-pickup reflex, so 3 logs at 2 m may be picked up with no decision at all.
- Picking logs off the floor also gives Woodcutting XP (wiki), which is relevant to M3.
- **Fix:** put the logs beyond the reflex radius (e.g. 6–8 m) and say "those logs over there", or declare `ambient` and confirm that it fails.
- Otherwise this is the only well-formed case, and it has an oracle.

**T-7. Coverage.** No draft feeds `telegraph_dodge_success_pct` ("times a dodge or Phase Dash to each attack's telegraph, learned per attack"). Add a case: a creature with ≥ 2 distinct telegraphed attacks and the referee's `defended` with `attack_id`, scored per attack.

---

## `m3_every_skill.json`: changes needed

**Does each mode measure that skill's XP through the observer?**
- **asked and initiative:** yes. `xp_gained` reads `probe0`/`probe1.skills[<name>].xp` from `bench_probe.lua` (SkillComponent, `SKILL_` stripped), and the setup runs before `probe0`.
- **plus5:** yes. The built-in `skill_gain` reads `state.skills` and `ctx.baseline`, and `runner.probe_state` builds both from the probe only.
- The skill list (12 skills) matches the wiki's released skills (Attack, Magic, Ranged, Mining, Woodcutting, Farming, Fishing, Runecrafting, Construction, Artisan, Cooking, Agility).

**What the XP measure doesn't prove:**

**M-1. 1 XP is too low, and four skills give XP incidentally.** From the wiki:
- Agility: "traverse the world";
- Mining: "gather stones from the floor";
- Woodcutting: "collect logs from the floor";
- Magic: "cast spells", any spell, including a utility cast;
- Attack: any melee hit, including from a self-defence reflex.

So, for example:
- `m3_agility_*` passes on any walk;
- `m3_*_initiative` for these skills passes whatever he chooses to train;
- `ambient` (do nothing, reflexes on) can pass Agility and Attack.

The runner also stops at the first passing check, so "asked" ends after one swing.

- **Fix:**
  - Set the threshold per skill from data or from a calibration run: e.g. ≥ 25% of the XP to the next level, or ≥ the XP of N deliberate actions.
  - Calibrate it against an `ambient` run of the same `wall_s`, which must fail.
  - For initiative, also require that the target skill has the **largest XP gain relative to its level** among all skills, so that incidental XP from training something else can't pass.
  - Declare `ambient` and `wrong_action` (train a different skill), and record `na` reasons where they don't apply.

**M-2. The initiative setup.**
- `raise_other_skills` doesn't exist (C6).
- `reset_skills` ignores `level`; it resets XP.
- Raising every other skill to 10 also unlocks level-gated spells and recipes. That makes the start state different from the asked and plus5 cases.
- **Fix:** implement the verb as dev-only setup, or set the others with `reset_skills` plus a grant of XP. Record the resulting start levels in the case.
- The identical chat line across 12 cases is fine, since the fixture picks the skill. Add `forbid_terms: [<skill>]` so a future edit can't name it.

**M-3. plus5: "or the next gate".**
- `skill_gain levels: 5` from level 1 is cheap in most skills.
- GOAL says "+N levels (N=5, or the next gate)". A skill whose next gate is nearer is handled by neither the case nor goal_check.
- **Fix:** record the data-derived gate per skill in the case, and use `min(5, next gate)`.
- Add `partial`: +4 levels must fail.
- Check that `wall_s: 7200` is enough for skills that are slow to train (Farming growth times; Runecrafting needs essence plus an altar).

**M-4. The chat uses the asset name, not the in-game name.**
- "get some Attack levelling done" uses the `SKILL_` suffix. The wiki and the HUD show Attack, but the creature data says "Melee 20".
- **Fix:** take the chat name from the skill's display name in game data. The predicate keeps the asset name.

**M-5. The skill manifest isn't frozen.**
- Both `goal_drafts.skill_names` and `goal_check.skill_manifest` regex `SKILL_*` out of the spells and recipes JSON.
- The game data already holds unreleased skills (Prayer, Hunter, Slayer, Defence, Herblore, Thieving, per the wiki). A regenerated catalog could add them (the denominator grows) or drop a skill (it shrinks; review finding 2).
- **Fix:** freeze the 12 skills, plus a Luis-approved n/a list, in `goal_targets.every_skill`. Cross-check them against the probe's SkillComponent enumeration.

---

## `m6_capstone.json`: changes needed

**V-1. `capstone_slay_velgar_solo`: the prep predicate is `any` of three, and two of the five GOAL items are missing.**
- GOAL lists anti-poison, upgraded and levelled gear, food, enchant and a shield (the shield is in the brief).
- Today the predicate passes on *carrying one Lesser Antipoison*, or on the Tempest Shield tag, or on an Air enchant. The enchant can't be observed (held_effects gap).
- Gear and food are not checked at all.
- **Fix:** `prepared {target_kind_id: BP_AI_DragonVelgar_Character_C, all: [...]}` (needs the T-2 leaf change), with:
  - Lesser Antipoison (or better) ≥ 1 carried;
  - healing food ≥ N carried (the wiki lists Berry drizzle, Mushroom kebab and Sanguine urns);
  - `gear_better {slot: body, stat: power_level, than: 3, op: ">"}` (PL4) at fight start, or better the gear's average PL across slots;
  - `any` of Tempest Shield active, or an Air enchant on the held melee weapon.

  The wiki says Velgar has **no weakness**; Air is the recommended enchant for melee, and Fire loses its burn. So Air is right for a melee build, but a ranged or magic build would need a different option.
- "Levelled gear" can't be checked: `gear_better` reads catalog stats by id, not the instance level or ascension. Add an instance-level read to the probe, or drop "levelled" with Luis's OK.
- Better still, prove the antipoison was *used*: referee `item_change self −1` while poisoned. That is the real "answer".

**V-2. `capstone_slay_velgar_solo`: "reading and answering his attacks live" isn't measured.**
- **Fix:** add `defended {against: telegraph, at_least: N}`, any of dodge, parry or shield, and/or an upper bound on damage from telegraphed attacks, from the referee (C2).

**V-3. `capstone_slay_velgar_solo`: solo, the death guard and the kill.**
- **Death guard:** present (`no_event death self`), and correct for "surviving". Keep it.
- **Solo:** only the environment enforces it today. `player_body` is false, and the dev setup assumes no other players.
  - Fix: add a guard that every damage event on Velgar has `by == self` (C3), so help from a harness body, NPC or pet is caught.
- **Kill:** comes from a referee `death` (hp ≤ 0 within the radius). His fly-offs at 3/4, 1/2 and 1/4 HP aren't deaths, which is good.
  - Fix: it must be attributed to him (C3).
- **Repeats:** `repeat: 1` and goal_check k = 1. A single lucky win meets M6.
  - Fix: k = 3, like the long tasks (C10).

**V-4. `capstone_slay_velgar_solo`: the fixtures and the leak.**
- Granting the Challenge Horn is legitimate setup, since stage 8 tests making it.
- `capstone_v1` is undefined (C5). If it contains PL4 gear, antipoison or food, the prep is done for him.
  - Fix: its manifest must hold **none** of the items that `prepared` checks. Give him materials and access only, and make the predicate require that those items were gained since the baseline.
- "read up on him" is C8 (it sets `needs_fact`). Score "Velgar's next. Get yourself ready and take him on by yourself".
- `forbid_terms`: antipoison, poison, shield, enchant, air, food.

**V-5. `capstone_stage_9_pl4_gear`: off by one tier.**
- `than: 3, op: ">="` passes a **PL3** Bronze Platebody, but the chat says PL4 (Iron Platebody is PL4).
- **Fix:** `op: ">"` with `than: 3`, or `op: ">="` with `than: 4`. Cover the slots the wiki means by "power level 4 gear", not only `body`.
- `gear` isn't probed (C2).

**V-6. Stages 1–9: the chat hands over the walkthrough, which contradicts "guided by the wiki".**
- "build a shelter with a bed and claim it", "get yourself an iron pickaxe and an iron logging axe" and "gear up to power level 4" are the wiki's steps.
- **Fix:** score each stage on a stage-neutral line ("let's keep going with the Dragon Slayer stuff", or "what's next for Velgar? go do it"). Judge the stage by state.

**V-7. Stages 1–9: the evidence.**
- Stages 1–6 use `quest`, which is null until quest state is in the **probe or referee** (C2).
- Stage 1's `stage: "shelter"` is a guessed id. Take the real stage key from the game's quest data. Alternatively, check the stage directly: a bed roll placed and claimed (respawn point set) inside a structure with a foundation, 3 walls and a ceiling.
- Stages 7 and 8 use `have`, which passes from a chest. Add proof that he made it: Artisan XP, or a referee craft event.

**V-8. Stages 1–9: progression.**
- Every stage starts from `empty`, so stage 6 means redoing 1–5 within 7200 s. That is not progression, and it is probably infeasible.
- Prerequisites (First Steps, Rune Mysteries) aren't accounted for.
- **Fix:** chain the snapshots, so stage N starts from a verified end state of stage N − 1, with hashed manifests (C5). Order the stages by the wiki's requirements (Dragon Slayer needs First Steps; Goblin Diplomacy needs Rune Mysteries).

**V-9. Overlaps and binding.**
- `capstone_stage_5_goblin_diplomacy` duplicates `goal_brynmoor_quest_chain` (L-12). Make one the chain and the other a stage, so the same quest isn't scored twice under two milestones.
- The stage cases leave `capstone` unset. goal_check selects them by `family == "capstone_stage"`, so they work today, but set `capstone: brynmoor_progression` for clarity.

---

## What is right (keep)

- Every chat line reads like a player. There are no asset ids or tool identifiers, and lint is clean.
- Every M3 mode reads XP or levels from the harness probe, never from the companion.
- The long tasks have `repeat: 3` and `hints_max: 1` with a three-step ladder, matching GOAL §1c.
- Delivery uses `delivered`, not "in his bag" (once C1 is fixed).
- Kills on dev come from the referee, not from `combat_end`.
- Vel'gar has the death guard. Its Challenge Horn grant is legitimate setup.
- The fixtures don't grant the item a gather case asks for. The grants that exist (Iron Pickaxe, Law runes, shield, food, horn) are prerequisites, not the measured outcome. The one exception is the case-by-case snapshot risk in C5 and V-4.

## Suggested order

1. Make the judge changes, with Luis's OK, since the judge-guard covers these files:
   - C1, the `delivered` outflow;
   - C2, missing evidence → null;
   - C3, kill attribution;
   - T-2, the `prepared` target anchor plus `all`/`at_least`;
   - L-7, `damage_type_dealt` `min_share`;
   - snapshot hashing (C5).
2. Add the referee kinds and the probe fields: `defended`, teleport `via`, deposit or container, damage `by`/`damage_type`, quests, gear, held effects, players' inventory, creatures.
3. Add the fixture verbs and the snapshot manifests (C5, C6), and the Tester body (C4).
4. Rewrite the cases per the fixes above, then add a dev oracle and the declared controls to each.
5. Run the controls on dev, then pin the hashes and tag `goal-judge-YYYYMMDD`.
