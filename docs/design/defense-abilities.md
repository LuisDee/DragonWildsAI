# Defensive abilities, telegraphs and fight prep (2026-10-25)

Luis: "Can he successfully use Phase Dash to dodge in combat? For dragons, predict their attacks and Phase Dash before a lunge. Windstep into the air and, when he lands, stun low and medium mobs. How do we make him KNOW when to use them?"

Code:
- `client_mod/scripts/defense.lua`: threat model, choice of answer, learning;
- `client_mod/scripts/defense_abilities.lua`: the abilities as data;
- `client_mod/scripts/combat.lua`: executing the answer, the spells contract, `combat_brief`.

Tests: `client_mod/tests/test_combat.lua` sections 14–16 (166 checks in the file). Live proof is owed for these and for the basics (directional dodge, parry, disengage). That slot comes once Claude has recovered his own gear.

## 1. Answers to an attack, chosen per attack, learned

The candidates for each telegraphed attack:
- **Plain inputs:** parry, block, dodge (directional), jump, retreat.
- **Abilities (data file):**
  - **Phase Dash:** cast `USD_PhaseDash` (Instant, 20 Air + 10 Astral, 45 s cooldown, perk `PerkV2_Agility_Spell_PhaseDash`, Agility 44). Its Blueprint module opens a 2 s dash window (`ExpireAfterDuration`), and the evade input inside that window is the phase dash.
  - **Windstep:** `USD_Windstep` (Instant, 5 Air, 3 s cooldown): a super-jump out of reach. With `PerkV2_Agility_Spell_Windstep_Upgrade` the landing explosion staggers within 7 m (force 1000).
  - **Tempest Shield:** `USD_TempestShield` (Instant, 15 Air, 45 s cooldown): a damage shield (`GE_TempestShield`, shield health 50 + 7.5 × Attack level). Guides say it prevents damage while blocking, so the follow-up is to hold block.

How it decides (no creature-specific code; everything is keyed by the attack's key, `<creature name>:<attack data asset>`):
1. **Threat** (`D.threat`), from the attack's data:
   - impact time (`UAiAttackData.GetDamageTime()` / `Damage[].Time`);
   - reach (the damage shape) plus the learned lunge distance (how far the attacker moved between the telegraph and the impact);
   - expected damage (learned from hits taken);
   - flags (`AttackPropertyFlags`: Unblockable, Unparryable, Special, ComboFinisher, ForceBlast);
   - shape low or area.
   - From these come danger (expected damage as a share of max HP) and tags (lunge, low, aoe, unblockable).
2. **Feasible set:** stamina for each input; ability available (unlocked, runes, cooldown, read through the spells module); and **time**: the telegraph must leave reaction (150–300 ms) + cast latency (learned per spell) + lead before the impact. A too-short telegraph rules out casting, as it does for a person.
3. **Prior = the rules:**
   - parry if able;
   - block;
   - dodge or jump for unblockable or low attacks;
   - an ability's prior rises when its `avoids` tags fit the threat, and with danger.
4. **Learning, a bandit per (attack, answer):**
   - Thompson sampling over Beta posteriors seeded by the prior.
   - Reward: avoided or parried = 1, blocked = 0.75, a hit is scaled by the damage taken, a whiff gives no update.
   - Abilities carry a cost (runes, cooldown) scaled by (1 − danger), so they are spent on dangerous attacks.
   - With no outcome seen yet for an attack, it acts on the priors, as a sensible player would on a first encounter.
   - Offline: a lunge that hurts unless answered with an ability is avoided in 4–5 of the last 5 tries in the live-like test and in 8+ of the last 10 in the unit test.
5. **Policy from the model:** `combat_orders` takes `defense` (auto, parry, block, dodge, none), `allow_jump` and `abilities` (for example `{"tempest_shield": false}` forbids it). An explicit style is obeyed as the model's order; only `auto` explores.

## 2. What the client can read ahead of a hit (telegraph detection)

- **At the attack's start:** the NetMulticast `AiAttackComponent:Multicast_PerformAttackOnSimulatedProxies` (live-verified: it fired for every Goblin Runt attack). At that moment `CurrentAttack.AttackData` gives:
  - damage times (`Damage[].Time`, several entries for multi-hit attacks);
  - the montage and its length;
  - `MaximumRootMotionScaling` (lunges move by root motion) and `bLeaveNavMesh`;
  - `NextAttack` / `ComboTimer` (the follow-up in a combo);
  - the flags and the damage shape.
- **The lead time** is the damage time. Its real value is learned per attack from the telegraph-to-verdict time, which strips latency.
- **The lunge distance** is learned from the attacker's displacement during the attack. It feeds the reach, so an attack that starts out of reach is still answered once it is known to lunge.
- **Not used (yet):** the AI's `PreemptParryWindowOpening(ParryWindowLength)` (hooked for evidence later), and the AI's own movement components (charge states). Montage position sampling is possible (the AI mesh's `GetAnimInstance():Montage_GetPosition`) if per-attack timing ever needs it.

## 3. Prep facts for the model (`combat_brief {target}`, read-only, llm=true)

- **The creature:** power level vs his, HP, attitude, boss, distance.
- **Weaknesses by source:**
  1. live `DamageTypeAffinities` (empty on the client so far);
  2. what he learned from his own hits (`TypeDamagesOutcome`);
  3. the game's journal entry (`JournalEntryWorldData.Weaknesses`, matched by display name);
  4. the wiki priors data file.
- **Each weapon he carries:** damage types, the verdict against the target (weak, resist, immune, neutral), DPS, block value, ammo kind.
- **Spells, from the spells module's own list:** weapon-buff (enchants), defence, crowd-control and damage spells, with `use_when`, castable state, reason and remaining cooldown.
- **Food** that heals (heal amount and count).
- **The estimate:** verdict, estimated seconds to kill and to die, power-level gap.
- **What he learned** about this creature's attacks: impact time, damage, lunge, outcomes.
- **The current orders.**
- The model decides the prep (enchant type, weapon, shield, gear, food, or not fighting). Code only informs.

## 4. Contract with the spells module (`spells.lua`, owned by the spells work)

Combat casts abilities in the middle of a fight, while it holds the pawn at reflex level. The spells module's `cast` refuses while fighting, and its wheel route takes about 0.5–1.5 s. Needed:
- `spells.ability_status(asset)` → `{available, why, latency_s, cooldown_s, runes_ok}`: unlocked, runes and cooldown, plus the measured latency of the fastest route (a quick-access key if the spell is on one, else the wheel).
- `spells.cast_now(log, asset, {owner_token})` → a job with `poll()` → nil, or `{ok, cast_t, reason}`. It acts under the caller's arbiter token (no new request), uses the same real inputs, and reports the moment the cast took effect.
- Until these exist, combat reports the abilities as unavailable (`no_fast_cast_route`) and uses the plain inputs. Nothing is faked.

## 5. Search record (search-before-building)

- **Bandit choice:**
  - UCB and Thompson sampling are the standard stationary bandits. Both can lock onto early winners, so a prior and continued exploration matter: https://arxiv.org/pdf/1912.06910
  - Thompson sampling was chosen over UCB1 because UCB1 can be "stubborn" toward a suboptimal arm, while Thompson adjusts its exploration to the evidence: https://arxiv.org/pdf/2409.16291
  - Per-player bandits over legal actions in games: https://arxiv.org/pdf/2012.12186
  - No source was found on bandits choosing combat answers in a shipped game.
  - Decision: ADAPT (Thompson sampling with rule priors and a cost term), BUILD a small Lua version.
- **Dragonwilds:**
  - Windstep lets you jump higher and descend slowly; Tempest Shield prevents damage while blocking, then bursts and knocks back: https://www.pcgamesn.com/runescape-dragonwilds/spells
  - Players defend with parry, dodge, block and Tempest Shield: https://steamcommunity.com/app/1374490/discussions/0/604155320470645919
  - No public source describes Phase Dash or Wind Stomp. They come from the game data here (spells catalog and perks).
- **Telegraphs:** the game's own attack data (dump, build 26161880) plus the live-verified attack multicast. No external precedent needed.
