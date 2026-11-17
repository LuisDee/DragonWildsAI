# Why he believes gear_up is done: what he was shown, and a replay (2026-11-17)

Offline study for `docs/GOAL-2026-11-17-long-jobs.md` item 1 (the whole job "gear up for a vault" and the rung 4 item `gear_up`). Follows `docs/research/2026-11-17-open-ask-replay.md`, where gear_up went on in 0 of 6 replays in every variant and, given `request_done`, he claimed it done 4 of 6 times at armour PL 1 against a reachable 3. Nothing was run against the game, the client or a live brain. No repo file was changed except this one.

## The job and its end test

- Line: "claude get all your stuff together and gear up properly" (Luis 2026-11-01: "get him to get all his shit and put his good armour on"). `data/jobs.json` L3 ("gear up for the vault") uses the same target.
- End test (`tools/rung4_gate.py` `gear_target`, `it_gear_up`): his worn armour PL reaches `brain/gear_plan.plan(...)["pl_full_set"]` at the start, and he holds kit of the best PL he can reach. Armour PL is the mean of the head, body and legs pieces' PL, rounded down. Weapons, shields and capes do not count.
- On 17 Nov: worn Leather Cowl (PL 2), Adventurer's Tunic (PL 1), Adventurer's Leggings (PL 1), so PL 1. The target is PL 3: a whole Bronze, Hard Leather or Wizard set. The heavy set is short 20 Bronze Bar, 8 Hard Leather and 7 Wool Thread, and its recipes unlock once he holds Bronze Bar. Sword and shield (PL 3) were already at the kit target, or lying 8 m away.

## Cases

The Planner (Sonnet) was not called in any of the 8 runs (0 `planner` rows; run 5 of 2 Nov called the Director). Everything below is what the Controller (Haiku) saw.

| Run (brain log), ask UTC | What he did and said at the end | Armour line at the ask | What his last results told him |
|---|---|---|---|
| `20261117-181801-22264`, 11-17 17:18:26Z | Picked up a sword and shield, equipped them, read `inventory`, then said "sword and shield on, body gear's still on. I'm wiped, putting up a shelter to rest" and cast Summon Shelter. Next turn: no call, no text. The ask closed at 17:19:02Z. | **none**: the gate hid it (Magpie PL 1 is not above his armour PL 1) | `equip` gave `{"name": "Bronze Sword", "held": "right", ...}` with no PL. `inventory` gave `worn` as names only, and stats for the hotbar sword (PL 3) but not for the worn armour. |
| `20261117-182130-17296`, 17:21:54Z | Went 577 m to his remembered grave ("most of my gear is in my grave"). `look` found no grave. Said "still no grave in sight, just ash logs. might be a bug". The ask closed at 17:26:03Z. Later: "I'll stop looking and sort out a new kit instead" (no call). | **none at the ask**. At the grave, Deer PL 2 was in sight, so the line came in (270.7 s) **before the stopping turn**, and he stopped anyway. | The situation's grave row said "1 m away ... about 185 items: Goblin Pack x48, Bronze Sword x1, Bronze Shield x1". Three `look` calls said no grave was there. The grave memory was stale or the grave was gone, which is a separate fault. |
| `20261117-182835-26604`, 17:28:58Z | `recipes` (default: craftable now) listed 4 recipes, all `ready`: Community Cape, Tattered Cape, Rat Roast and Burnt Fillet (166 unlocked). He made and wore the Community Cape. Text: "Gear is sorted: Community Cape on, Bronze Sword and Bronze Shield in hand". The ask closed at 17:29:17Z. Gate: untruthful. | **none**: no creature in sight | `equip` cape gave `{"worn": true, "loadout_slot": "Cape"}`, and the shield gave `{"already": true}`. Neither had a PL, and neither said that a cape does not count toward PL. |
| `20261102-003236-16800`, 11-01 23:32:48Z | "checking what I've got and what gear I can make": `craft_plan` Apprentice Robe, then three graves (deaths). | shown: "you are PL 0 ... enemies here: Kebbit PL 1. Best armour you can reach makes you PL 2 ..." | |
| `20261102-005154-15372`, 23:52:07Z | `recipes`, then `craft_plan` Apprentice Robe and Hat, then `craft` Apprentice Hat: missing_materials (1 thread short; the wheel needs a roof). Said so and stopped. | shown (PL 0, enemies PL 1, best PL 2) | |
| `20261102-013020-15324`, 11-02 00:30:31Z | `craft` Leather and Coarse Thread both failed (tannery input, roofless wheel). "armour needs more mats ... short on bones and leather". | shown, with the whole-set bill | |
| `20261102-023341-8528`, 01:33:54Z | Grave, sword and shield, then "need a head and body piece next". Then a crafting table and flax. Died twice. | shown | |
| `20261102-031731-15808`, 02:18:00Z | "grabbing my gear from the graves first, then leather armour". Crafted a **Leather Cowl**, then stuck 400 s on the roofless Spinning Wheel. | shown | |

On every turn of all 8 runs, the "You:" line read **"PL 0"**. That is the game's `BP_GetPowerLevel`, shown with no gloss. On 17 Nov, `gear_plan` and the gate compute **PL 1** from the same worn pieces.

## Answers

1. **Does anything he sees say what "geared up" means in numbers (target against current)?** On 17 Nov, no: 0 of 3 asks. The only line that carries it, `situation.gear_line` ("Gear vs this area: you are PL 1 ... Best armour you can reach makes you PL 3" plus each style's whole bill), is shown only while a creature in sight outranks his armour (`brain/situation.py:1101`). His armour is PL 1 now, after the cowl, and Temple Woods creatures are PL 1, so the gate hid it in 3 of 3 asks. On 2 Nov he was at PL 0 and the line was shown in 5 of 5 asks. In 5 of 5 of those runs he went after armour (craft_plan, crafts, "need a head and body piece next", a Leather Cowl made). The two sets of runs differ in code and character state too, so this comparison is observational, not proof. The only number he always sees is "PL 0" in "You:", and it disagrees with the gate's PL 1.
2. **Is the armour he could make next visible?** No. `recipes` with no item lists only what is craftable now: 4 recipes, capes and food. That is true but partial: no armour recipe is listed, because he lacks inputs for every one. So "make what I can" became the Community Cape. Nothing he was shown on 17 Nov names a better armour piece or what it needs. `craft_plan` answers only for an item he already names.
3. **Did a result tell him something false or partial?** Partial, yes. The equip results say `worn: true`, `held: right` or `already: true`, with no PL and no word that capes and held items do not count toward PL. `inventory` lists `worn` by name with no PL. One thing was false: the situation's grave row ("1 m away, about 185 items") when `look` found no grave (182130). The "PL 0" against PL 1 is a contradiction he cannot resolve (see the rule 4 note below).

## Replay

- Harness: `tools/replay_open_ask.py` functions (`episode_calls`, `body_states`, `outcome`), with the exact logged messages, tools and effort. The scripts are in the session scratchpad: `gearup_replay.py`, `toldback.py`. Results: `logs/evals/replay_gearup_done-20261117-200346.jsonl` and `logs/evals/replay_gearup_done-T-20261117-200637.jsonl`.
- **U**: the logged call as it was.
- **G**, the one candidate change: the ask's situation carries the armour line the gate hid. That is `situation.gear_line` with its enemy gate removed: PL now, best PL he can reach, each style's whole bill with what is short and where it is made, built by the code's own `gear_plan.lines` and `set_line` from the state at the ask. It is inserted where the code puts it (before "Skills").
- **T**, a second probe on the stopping turn only: each `equip` result in the history also carries `armour_power_level: {now, counts: "worn head, body and legs only; weapons, shields and capes don't count", worn: per piece with PL, best_you_can_reach}`.
- Turns:
  - **stop**: the call that closed the ask.
  - **first**: his first call on the ask.
  - **done control**: the closing turn of 3 quest asks that really were done (`20261117-023623`, `-032318`, `-083457`), to see whether the line starts unasked-for work.
- 3 replays per case and variant. Haiku 5.5, effort as logged (low).

| Turn | U (unchanged) | G (armour line at the ask) | T (equip told back) |
|---|---|---|---|
| gear_up stop: went on (a world call) | 0 of 9 | 0 of 9 | 0 of 9 |
| gear_up stop: names the armour gap | 0 of 9 | 1 of 9 ("real armour upgrade needs bronze bars or hard leather, want me to start on that?") | 1 of 9 ("still only bronze gear though, need better armour from somewhere") |
| gear_up first turn: an armour-directed call or line | 0 of 9 | 2 of 9 (182835: `craft_plan` Hard Leather Body; "then I'll see what armour we can make") | |
| done asks: new work started | 0 of 9 | 0 of 9 | |

Per case on the first turn:
- In 182835 (no pressing need), G turned armour-ward in 2 of 3, and U in 0 of 3.
- In 181801 (exhausted, sword and shield lying 8 m away) and 182130 (peckish), both arms went for the loose gear, food or drink first.

`tools.ab two 0 9 2 9`: p = 0.47, not told apart. The done control found no false work. The earlier study's D block, which put the quest log and gear block after the close, caused 4 of 36.

## Finding

He believes gear_up is done because his reading of the ask forms on its first turn, and on 17 Nov nothing at that turn gave "geared up" a number. With the gate hiding the armour line, the equip results confirming each step with no PL, and a `recipes` read whose craftable-now list held only capes, "gear up" became "sword, shield (and cape) on, armour still worn". Each step's result confirmed that reading.

Once he has acted on that reading, numbers do not dislodge it. At the stopping turn, the line (G), the told-back PL (T) and the earlier D block moved him 0 of 24 times. In run 182130 the line was in his own observation at the live stop, and he stopped anyway. When he does name the gap, he treats it as a next project and asks, rather than as the unfinished ask. The 2 Nov runs, which saw the line at the ask, all went after armour. The replayed first turn moves the same way, but weakly (0 to 2 of 9).

## One recommended structural change

**Show the armour line whenever his worn armour is below the best he can reach, not only while a creature in sight outranks it.** In `brain/situation.gear_line`, the gate `p["enemy_pl"] is None or p["pl_now"] >= p["enemy_pl"]` becomes "no armour slot below its best reachable PL". Nothing else changes: the same line, the same `gear_plan` data, and no word about what to do. This changes what he is shown at the ask (rule 10, structural). It is not a recipe: the line appears whatever the ask is. On the done-ask control it started no work (0 of 9).

- **Log line** (for `tools.unseen`): one row per Controller request whose situation carries the line where the old gate would have hidden it: `{"kind": "gear_line_ungated", "pl_now": 1, "pl_best": 3, "enemy_pl": 1, "episode_id": ...}`. Signature: `"kind": "gear_line_ungated"`.
- **Number a live window should move:** of gear_up trials, the share whose ask episode makes an armour-directed call (`craft_plan`, `recipes` or `craft` for an armour piece or its inputs, gathering those inputs, building their station) before the ask ends. Today 0 of 3 (17 Nov). With the line on 2 Nov: 5 of 5. Expect at least 50 %. `tools.ab need 0.0 0.6` gives 8 trials per side, so about 8 gear_up trials from the 17 Nov start. Second number, which should not rise: new work on done asks (replay 0 of 9).
- **What it will not fix:** the stop itself (0 of 24 at the stopping turn), and the size of the job. PL 3 here means smelting 20 Bronze Bars, plus Hard Leather and roofed-wheel thread, so `done` stays far off even when he starts. The told-back fix on a done claim (the `request_done` result carrying armour PL now against best) is the next candidate. It was not replayed here; it needs a two-call replay.

## Faults found on the way (not fixed; for the main session)

- **Rule 4, before a fix shows numbers:**
  - The "You: PL 0" he always sees is the game's `BP_GetPowerLevel`. On 17 Nov it read 0, while `gear_plan`'s formula over the catalog PLs (cowl 2, tunic 1, leggings 1) gives 1.
  - `docs/DISCOVERIES.md:1212` already records two game numbers that differ: `BP_GetPowerLevel` 2 against `GetCurrentEquipmentPowerLevel` 1.
  - Which one is armour PL needs settling, or the line and "You:" will contradict each other.
- **Grader (`rung4_gate.gear_up_t_h`):**
  - On 17 Nov, T_h was 50 s ("'make armour' 32.6 s / 2 per piece + an equip, x 3") for a target that needs 20 Bronze Bar, 8 Hard Leather and 7 Wool Thread.
  - The formula prices only Leather and Animal Bone shortfalls, so the time bar cannot be met for this target.
  - Also, the target (the best set he can craft) reads more than Luis's words ("put his good armour on"). That is a question for Luis, not a change to the grader.
- **Stale grave memory** (182130): the row said "1 m away, about 185 items", and `look` found nothing. The grave was 13 h old.

## Spend

64 Haiku 5.5 calls (1 lost to a logging bug in the first launch, 54 in the batch, 9 for T), $0.131 by LiteLLM's cost: $0.0055, $0.1016 and $0.0242. Under the $0.15 cap. Today's total was $3.57 before this study.

## Not checked

- Only one call per sample. A world call or a read on the first turn is not a finished armour job, and later turns were not replayed.
- 3 cases, all from one character state. The 2 Nov comparison is a natural experiment, confounded by code and state.
- G's line at the ask leaves the later history (made without the line) unchanged. Live, the line would also be in every later observation that carries the situation.
- The cache was not reset between replays of a case.
