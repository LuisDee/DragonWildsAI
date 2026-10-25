# Proposal: changes to `docs/goal_targets.json` (for Luis's approval)

From: the Eval agent, 2026-10-26.

**Why:** the goal-cases review (`docs/reviews/2026-10-26-goal-cases-review.md`) plus what dev verification showed.

**Status:** nothing here is applied. `goal_targets.json` is Luis's file, and main applies the approved items.

Each item gives the change, why, and what `tools/goal_check.py` would read.

## 1. Repeats (k): review C10
| Target | Today | Proposed | Why |
|---|---|---|---|
| `combat_basics_live_proven` (each of the 3) | pass^1 | **k = 3, all pass** | The cases declare `repeat: 3`. One lucky dodge proves nothing. |
| `capstone:slay_velgar_solo` | pass^1 | **k = 3, all pass** | Matches the long tasks. A single lucky win shouldn't meet M6. |
| `long_tasks:*` | k = 3 | unchanged | |

**Proposed keys:**
```json
"decision_rule": { ..., "combat_basics_repeats_k": 3, "capstone_repeats_k": 3 }
```

## 2. M3 `every_skill`: a frozen skill list (review M-5)
- **Freeze the 12 released skills.** The probe's SkillComponent enumeration on ClaudeDev matched the game data on 2026-10-25. The skills are: Agility, Artisan, Attack, Construction, Cooking, Farming, Fishing, Magic, Mining, Ranged, Runecrafting, Woodcutting.
- **An n/a list Luis approves** (in the data or wiki, but not released): Prayer, Hunter, Slayer, Defence, Herblore, Thieving. A catalog regeneration then can't grow or shrink the denominator.
- **Thresholds per skill (M-1).** The XP that counts as "trained" is calibrated on dev against a do-nothing run of the same length (Agility, Attack, Mining, Woodcutting and Magic gain XP incidentally). Until calibrated, a placeholder of 100 XP applies.
- **"Initiative" mode:** the target skill must have the largest XP gain relative to its level (leaf `xp_top`).
- **plus5:** `min(5, next gate)`. The gates come from the data per skill (perk unlock levels), and are listed for Luis to confirm.

**Proposed keys:**
```json
"every_skill": { ...,
  "skills_frozen": ["Agility","Artisan","Attack","Construction","Cooking","Farming","Fishing","Magic","Mining","Ranged","Runecrafting","Woodcutting"],
  "skills_na": {"Prayer": "unreleased", "Hunter": "unreleased", "Slayer": "unreleased", "Defence": "unreleased", "Herblore": "unreleased", "Thieving": "unreleased"},
  "xp_threshold": "calibrated per skill on dev vs an ambient run (evals/bench/manifests/<build>/skill_thresholds.json)" }
```

**Blocked:** "initiative" needs a fixture that raises the other skills (`raise_skills`). No safe route is verified yet. The candidate is copying a live XP event row handle into `SkillComponent:AddXpFromEvent`.

## 3. Families and metric sources (review C10, T-3, T-7)
- `combat_tactics:prep_before_hard_fight_pct` would read **family `tactics_prep`** only. The trend case moves to `tactics_trend`.
- `combat_tactics:damage_taken_trend` would read **family `tactics_trend`**: one case with 5 sequential fights inside the case.
- `combat_tactics:telegraph_dodge_success_pct` would read the **`dodged` / `telegraphs` process fields of family `tactics_telegraph`**. It's a new case: a creature with ≥ 2 distinct telegraphed attacks, scored per `attack_id`.

## 4. Validity controls (review C7)
```json
"eval_validity": { "positive_control_required": true,
                   "negative_controls": ["do_nothing", "claims_only", "wrong_action", "alt_means", "partial"] }
```
goal_check already requires all five, unless the case's validity record gives an `na` reason. This makes the file say the same.

## 5. Long tasks: definitions needed from Luis
1. **`gather_coal_multitrip`.** "Multi-trip" **can't be forced** in this build: coal stacks to 99 per slot, and the bag is slot-based. Options:
   - (a) drop "multi-trip" and keep delivery, proof of mining (Mining XP) and a lodestone teleport;
   - (b) raise the amount to more than one bag of coal;
   - (c) define a trip as ≥ 2 lodestone round trips.
2. **`brynmoor_quest_chain`.** Proposed chain: **Rune Mysteries → Goblin Diplomacy**. Rune Mysteries is Goblin Diplomacy's prerequisite per the wiki. Goblin Diplomacy then leaves the M6 stage list, so it isn't scored twice (V-9).
3. **`gear_upgrade_self_initiated`.** Count any slot or category from the catalog, and exclude the **15 entitlement items** in a data-derived n/a list (e.g. `ITEM_Armour_T1_Body_GildedPaladin` is PL4 for free). The start gear is the known T1 set ClaudeDev has: Adventurer's body and legs (probe). Also decide whether a better item taken from a shared chest counts.
4. **`farm_desert_weed`.** We need the position of "our farm" on the dev world (or permission to build plots there as setup). The wording should be "twenty-odd" rather than "a stack", because a stack is 99 in this build.
5. **Vel'gar "levelled gear"** can't be checked: catalog stats are per item id, not per instance level or ascension. Drop "levelled", or wait for an instance-level read in the probe.

## 6. M6 capstone stage list (review V-6–V-9)
Order taken from the wiki's prerequisites, with each stage starting from the previous stage's verified end state (chained snapshots):
1. shelter with a claimed bed (Dragon Slayer part I);
2. Growing Pains;
3. Shrimp Catcher;
4. Restless Ghosts;
5. Highlighting the Problem;
6. iron tools (pickaxe and logging axe), with Artisan XP as proof of crafting;
7. the challenge horn (made), with Artisan XP;
8. PL4 gear (`op: ">"`, `than: 3`, all armour slots).

Vel'gar solo is the final case.

```json
"goal_cases": { "pinned_by_hash": {}, "capstone_stage_order": ["shelter","growing_pains","shrimp_catcher","restless_ghosts","highlighting_the_problem","iron_tools","challenge_horn","pl4_gear"] }
```

## 7. Already decided (recorded here for completeness)
- **Spells:** k = 2 trials per manifest spell (78 trials), under the Wilson rule (main, 2026-10-25).
- **Craft from scratch:** sample n ≥ 35 (main).
- **Game build key:** the server build (26161880), never the client's Steam build id (main).
