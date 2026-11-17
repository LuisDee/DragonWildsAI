# Capstone (Rung 6): a job definition proposal for Crasorak Kara (2026-11-17)

For the main session. Goal item 4 (`docs/GOAL-2026-11-17-long-jobs.md` section 4): from one ask he prepares for a vault, clears it and kills its boss. This is a proposal. Nothing here is in `data/jobs.json` yet, and nothing goes into a prompt, a tool description or a recipe. Offline: no body, no brain, no model call.

Builds on `docs/research/2026-11-17-vault-capstone.md` ("the capstone note"), `-vault-reads.md` ("the reads note"), `-crasorak-route.md` ("the route note") and `tools/vault_probe.py` (0770d69, and its fork window in this commit).

## 1. The ask

- **Tuned line:** `claude, let's take on Crasorak Kara. Clear it out and get the boss`
- **Held-out line** (scored, never fixed against, trace closed for its first three trials): `claude, that vault in the temple woods, the one east of home. think you can beat whatever's at the bottom of it?`

Both say where and what, as a player would. Neither says to make armour, bring food, pull a lever, or look anything up. Preparing is his decision; whether he does it is measured (section 2, "prepared"), never told.

## 2. The end predicate: game reads only

Every part is a read of the game made by his body (get_state, look, census, the damage event), never a word of the model's. A part that cannot be read is UNREAD, never a pass or a fail (the rule of `tools/job_run.done`).

| part | the read | where it comes from today | confirmed live? |
|---|---|---|---|
| **in this vault** | get_state `in_vault` is true and `vault` is "Crasorak Kara" | `sense.vault_here` (sense.lua l. 913-921): `ULocalPlayerAudioSubsystem.bInDungeon`, and the registry box that holds him; passed into get_state by client_bridge.lua l. 480 | no: P3 |
| **boss killed, by him** | (a) the game's damage event marks the fatal hit and its instigator: combat.lua l. 752-768 (`bIsFatalHit`, `by = "me"`) -> get_state `recent_kills` (combat `state_extras`, l. 4880) holds `{creature: "Vault Overlord", mine: true}`, and the `combat_end` activity names target "Vault Overlord" with `kills > 0`; (b) **and** a sample while `in_vault` and `vault` hold, within the fight's time, so the kill is this vault's | combat.lua `emit_combat_end` (l. 1725-1732) | no: no boss met yet |
| boss killed, corroboration (reported, not gated) | a census or get_state creature row with `boss: true` (`LoadedData.bIsBoss`, sense.lua l. 377) or `name` "Vault Overlord", read `dead: true` (`HealthComponent:IsDead`, l. 370); the boss's fixed drop (15 Stone, page 1331) as a bag delta | sense.lua `describe_creature` | no: A5 (is `bIsBoss` set on the Overlord?) |
| **vault cleared** | the boss part above **and** the core past the boss carried (`ITEM_Resources_VaultCore` gained in the run: page 3515 puts core 3 after the Overlord) **and** he ends outside (`in_vault` false after it was true) | get_state inventory; `snapshot().carried` | no: a core was never seen |
| cleared, reported (not gated) | the boss lever's `switch_position` changed from its first read (`BP_BinaryLever_C`, look row `switch_position`, `switch_highest`, `drives`); chests read `chest_state` "opened" or "emptied"; guardians killed (`recent_kills` / `combat_end`); deaths and graves | sense.lua `vault_row` (l. 862-891) | no: P4 |
| **prepared** (scored apart, at the entry) | at the first sample with `in_vault` true: worn gear and carried food and drink against the L3 target computed grader-side from the vault's enemy list (`brain/gear_plan.plan()` fed the wiki's Crasorak list, never shown to him) | job_run `gear_target`, `consumables_carried` | the enemy-list input to `plan()` does not exist (capstone note section 5) |

Why "cleared" is not "every guardian dead": the game has no cleared flag (reads note, `ADungeon` has none), a player may walk past guardians, and the wiki's own route ends at the boss and the core after him. The definition is provisional until Luis's recorded run (section 5, W4): what he did there is what a real player calls cleared. If his run skips the core, the core drops out of the gate.

What is not used: `KilledOnceAIs` in the character save (ids without names, written only at autosave: capstone A8); the boss's drop alone (Stone is common); XP alone.

**What `job_run` needs before this job can go into `data/jobs.json`** (not built here): `snapshot()` keeps `in_vault`, `vault` and `recent_kills` from each sample; two predicates, `boss_killed {creature, vault}` and `left_vault {vault}`, over the samples of the run (a sample every 15 s: a corpse that despawns between samples is caught by the fatal-hit record, which lasts 5 kills); the existing `carried_gain` for the core; a `--until at_door` end (a place end) to save `vault_door` by `--save-as` (rule 8).

## 3. The named world and the starts

- **World:** `vault_fresh`, a `world_snapshot` kept after window W1 shows the vault uncleared on this world (guardians alive, chests `unopened`, cores on their plinths: capstone A1) and before any body enters it. Until it exists, `base` (2026-11-17 17:12Z). Every window restores it with the server stopped (rule 9); a trial that met what an earlier one left is void.
- **Character for the whole job:** a fork of ClaudeDev (as L3: `start: "ClaudeDev"`), so the job measures his real state, not a hand-built bag. Rule 8: no grant, no fixture placement, in a scored trial.
- **Checkpoints for items worked alone** (capstone note proposal 3): `vault_door`, saved by `--save-as` from the first whole trial that reaches the door (needs the place end above); V-clear trials start from it on `vault_fresh`.
- **Probes** (`tools/vault_probe.py`) are harness looks, never scored: `door` on ClaudeDev (read-only), `enter` on a fork that is parked afterwards, with fixture teleports and a `tools.supply` top-up.

## 4. What the probe must show first

In order, each before the next is tried (the route note section 4, the reads note section 4):

1. **P1b, at home:** the door family's two teleporters and two targets, the `Dungeons` registry (`vault_list complete=` in the UE4SS log; today `n=32 complete=false`). Needs the read command `client_mod/commands/vault_probe_p1.lua` (missing). Without a complete registry, `leads_to` never reads "outside" and the exit row falls back to the nearest teleporter.
2. **Door** (`vault_probe door --confirm`, ClaudeDev): the door row with `name` "Crasorak Kara", `prompt`, `destination`, `arrives_at`, `leads_to` "Crasorak Kara", `locked` not true; `in_vault` false outside. Stops: a hostile within 20 m, HP under 60 %, a fall.
3. **Enter** (`vault_probe enter --confirm`, a fork; hooks armed with `DW_TELEPORT_HOOKS=1`; ProcDump on the client): one press, a jump over 50 m, `teleport_begin` and `teleport_end` in client.log, no `crash_*.dmp`, then `in_vault` true and `vault` "Crasorak Kara". This is the first in-map door teleport on this client (R16/R17 risk).
4. **A read inside** (P4, same window): lever rows with `switch_position`; chest rows with `chest_state`; `hazards` traps; creature rows with `power_level`; whether any row carries `boss: true` (the boss door is to the right of the entry on page 3515, so the Overlord may be inside the 80 m census); the inside teleporter's `leads_to` "outside". Then P5, out by that door.
5. **A6, the reset:** after a restore, a second `enter` on a new fork reads the same P4 rows. Without it rule 9 cannot hold for this vault.

Each of these is a read the end predicate leans on. If `in_vault` does not read on the client, the "in this vault" part falls back to his position inside the registry box from P1b; if `recent_kills` never names the boss, the corroboration row becomes the gate and A5 decides whether it can.

## 5. Windows, in order, with cost

Spend counts only brain trials (Haiku Controller, Sonnet Planner). The basis: the three L2 trials of 2026-11-17 cost $0.12 to $0.14 each over 2 to 16 minutes (`logs/evals/job_runs.jsonl`). A vault trial is longer and has more fights; $0.4 to $1.0 a trial is a guess to be replaced by the first three trials' numbers, with `--usd 1.5` as the per-trial cap. A switch of character costs about 70 s (`quest_run.SWITCH_S`), twice per fork window.

| # | window | what | time | spend |
|---|---|---|---|---|
| W0 | offline | this note; `vault_probe enter` on a fork (this commit); `vault_probe_p1.lua`; the `job_run` predicates and place end of section 2, tested with fakes | none | $0 |
| W1 | window A | restore `base`; P1b; arm the hooks, stand 60 s; `vault_probe door --confirm` (ClaudeDev). Then keep `vault_fresh` if the door reads as expected | about 10 min | $0 |
| W2 | window B | restore `vault_fresh`; ProcDump; `vault_probe enter --confirm` (fork ClaudeV<ddHHMMSS>, parked after); P3 to P5 | about 15 min plus 2 switches | $0 |
| W3 | reset check | restore `vault_fresh`; `enter` on a new fork; compare P4 with W2 (A6) | about 15 min | $0 |
| W4 | Luis's run (his decision, asked once) | restore `vault_fresh`, recorder armed; he plays the door to the dead Overlord and out. Gives the human bar and fixes what "cleared" means. Restore afterwards (his OK of 2026-11-17, `--others-ok`) | his time | $0 |
| W5 | prerequisites, not capstone windows | L1 to L3 at standard, I3 (death and grave) at standard, the jump course passing (goal section 4) | as their own windows | as theirs |
| W6 | V-whole, first three trials (held out: scored before the trace is read) | restore `vault_fresh`; `job_run trial --job V1 -k 3` from ClaudeDev forks; `--save-as vault_door` from the first that reaches the door | 3 x up to 60 min | about $1.5 to $3 |
| W7 onward | items alone (rule 1) | the failing part from `vault_door` (V-clear) or from the start (prepare, V-door), `-k 5` per window; the gate (3 in a row of V-whole) only when the item passes about 9 of 10 alone (rule 6) | per window | about $2 to $5 a window; the $10/day guard holds |

Stop rules carried from the route note: a new crash dump ends the window and no second entry happens before its cdb stack is read; a death inside in W2 or W3 ends the window and the grave's place is read (the wiki puts it at the outside entrance).

## Limits

- Every read in section 2 except the creature fields and the inventory is unconfirmed on the client: the vault fields (6d78811) were written from a server dump made with nobody near a vault. W1 to W3 exist to confirm them.
- Whether the game sets `bIsBoss` on the Vault Overlord, and its HP at PL 2 (1,300 or 650), are open (capstone A5).
- The fatal-hit attribution was built against rats and goblins (live 2026-11-01). A boss kill shared with another player would read as not his; the dev world has no other player in a trial.
- The costs and times are estimates from three L2 trials and the route note, not measurements.
- The ask lines are mine. Luis may word it differently; the held-out line is there so the tuned one is not the only one scored.
