# Combat basics on the dev world: diagnosis and live plan (M1, 2026-10-26)

Cases: `evals/bench/goal_cases/combat_basics.json`. Each needs k = 3: directional dodge, parry, disengage-eat-re-engage.

## 1. Why earlier dev fights showed no parry and no dodge for the referee (from the logs)

Evidence: client.log, `client_io/events/vitals.jsonl`, the client game log (`%LOCALAPPDATA%\RSDragonwilds\Saved\Logs\*backup-2026.10.26-07.14.13*`) and the dev server log (`...\Saved\Logs\RSDragonwilds.log`, category `EvadeAttack` at Verbose).

- **Dodges DID work (22:56 fight, bare hands, Kebbit).**
  - The server logged `TryPerformAttack ... against player`, then about 1.2 s later `Action Accepted : START : Evade`, `Applying evade invulnerability`, and `PredictPointDamage ... evaded 0.000000 damage`, 3 times out of 3. HP stayed at 100.
  - The referee missed them because its client hooks don't fire for these. **The authoritative evidence is the server's `EvadeAttack` log** (see §3).
- **Blocks failed (23:39 fight, Stone Logging Axe, Kebbit):** all 8 Kebbit hits landed (−7 HP each), even though combat "blocked". Causes:
  1. **Input mode:** an Eye of Oculus build menu (`DIM_OculusBuildMenu`) was still open from a spell test. The first block reached the game 1.2 s after the telegraph, and the mode flipped back to Gameplay only when the viewport refocused. In a non-gameplay mode, gameplay inputs don't act.
  2. **Timing vs the server's BlockDelay:** the server applies a block 0.116–0.117 s after receiving it (`AuthorityApplyBlocking: BlockDelay [0.117] for REMOTE player`). The block STARTs arrived 3–50 ms before the impact, so the block was not yet active. The Kebbit's damage lands 1.30 s after the client sees the attack (`Multicast_SendDamageCacheData` at +1.30 s; the attack data says 1.35 s).
  3. **Combat's verdicts were blind:** no damage multicast reached the client for these hits (only HP polls dropped), and no blocked/parried notify fired. Every defence was scored a "whiff", so nothing was learned. Our own hits on creatures also counted 0, for the same reason.
- **Parry was impossible:**
  - The Stone Logging Axe's block action (`PA_Block_PickAxe`) cannot parry at all. Only shield and dagger blocks can (`bCanParry`, needs `PerkV2_Attack_Parry`).
  - **ClaudeDev is a fresh character: total level 12, Attack 1.** Parry unlocks at Attack 5 and weapon specials at Attack 8, so **both are locked on ClaudeDev** (see §2).

Fixed offline (test_combat 186/186, stable across 10 seeds; test_equip 18/18):
- **Impact:** the AI damage-cache multicast is hooked as the impact signal.
- **HP as the judge of damage:** an HP drop counts as a hit taken by Claude, and a target HP drop as a hit by Claude.
- **Blocks scored correctly:** an impact with no damage under a block counts as "blocked".
- **Parry timing:** the press now leads by the server BlockDelay (`block_delay_s` 0.11).
- **Input mode guard:**
  - In a non-Gameplay `CurrentInputMode`, combat presses that mode's own back/cancel key (raw, past the gate), at most 4 times.
  - After 5 s it fails with `body_error`, why `input_mode_blocked`, naming the mode.
  - All combat presses also go through `input.gate()`: none while build or container screens are open.

## 2. Dependency: parry needs Attack 5 on ClaudeDev

- The fixture `unlock` verb unlocks spells (ProgressComponent), not skill perks, and `raise_skills` is unverified.
- Options (main / eval agent decide):
  - (a) raise ClaudeDev's Attack XP in his dev save file (character saves live on the client, as Luis's edited `Claude.json` did at 21:19);
  - (b) a verified `raise_skills` fixture;
  - (c) Claude levels Attack by fighting first, which is a real but slow prerequisite.
- The dodge and disengage cases do not depend on this.

## 3. Evidence the referee should use (authoritative, server side, dev only)

From the dev server log, category EvadeAttack at Verbose (already enabled):
- `TryPerformAttack() ... <AI> starting attack on authority against player <pawn> with id N`: the telegraph.
- `PredictPointDamage() ... <pawn> will receive D damage at T from <AI>`: a hit.
- `PredictPointDamage() ... <pawn> evaded 0.000000 damage ...`: **a successful dodge**.
- `DomNetActIntIds: AUTH : Action Accepted : START : Evade` / `START : Block`.
- `AuthorityApplyBlocking() : BlockDelay [x]`.
- For blocked and parried hits the exact wording is still to be captured. Likely candidates are the `PredictPointDamage` text with a reduced amount, and the `Multicast_NotifyActorsToDamagePending{Blocked,Parried}Attack` lines. Capture them on the first shield fight.

On the client, combat reports per fight: `combat_status.fight.defense` / `activity combat_end` {parries, blocks, dodges, hits_taken, abilities, precasts}, and `last_defence` {action, outcome, impact_s}.

## 4. Live plan for the eval agent (one slot through `tools/client_slot.py enqueue combat`; never disconnect/rejoin, L24)

Pre-flight, read-only:
1. `combat_probe_live` and `combat_probe_defense`: input mode is `DIM_Gameplay`, held items, perks (`PerkV2_Attack_Parry`), ping.
2. Bridge reload only if no command is in flight (one `bridge_start` loads the new combat, defense, input and skills code).
3. Fixtures:
   - grant a Bronze Shield, a one-handed weapon (Bone Dagger) and healing food (a Forager's Sandwich stack);
   - spawn ONE Goblin Runt 6 m away (`spawn` verb, verified);
   - keep the area clear of other hostiles.

Cases (k = 3 each; between runs reset with `set_health` 100 and re-spawn the runt):
- **dodge_directional:** `combat_orders {defense:"dodge"}` is the model's choice, so the case chat must lead him there, not name it. Expect:
  - per attack: server `START : Evade`, then `evaded 0 damage`;
  - client: `last_defence.action = dodge`, `moved.right_cm` or `toward_cm` matching the planned direction (left/right sideways).
  - Pass: ≥ 3 telegraphs answered, ≥ 50% evaded.
- **parry** (needs §2): shield held (`equip` is now verified from the held actor class).
  - Expect server `START : Block` arriving 0.11–0.21 s before the impact, plus a parried verdict (the `...PendingParriedAttack` multicast on Claude's PlayerBlockingComponent, or a `*Parry*` montage on Claude).
  - Learning: `D.status().attacks["Goblin Runt:<attack>"]` offset converges if the first ones block.
- **disengage_heal:** `set_health` 40 at fight start (fixture), `heal_hp` 0.5. Expect phase `disengage`, then a `go_to` away (≥ 8 m from the runt), then an eat (inventory use, `healed` activity, HP up), then phase `approach` once HP ≥ `reengage_hp`. 3 runs.
- Abort a run if HP < 25 and the runt keeps hitting (`set_health` 100, note it).
- Report per run: the server `EvadeAttack` lines (counts), `combat_status.fight.defense`, `last_defence`, the activity `combat_end` line.
