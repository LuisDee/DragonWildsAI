# Outnumbered melee fights: the game's rules, what other bots do, three small rule changes

Date: 2026-11-16. Research only (web reading plus `client_mod/scripts/defense.lua`, `client_mod/scripts/combat.lua`,
`docs/DISCOVERIES.md`). Nothing was run and no code was changed.

Marking used below:
- **[source]** a statement quoted from a page I read (URL given).
- **[snippet]** seen only in a search result excerpt, the page itself was not read.
- **[local]** a fact already verified on this VM and recorded in `docs/DISCOVERIES.md` (line given).
- **[inference]** my own conclusion. Not verified.

## 0. The short answer

He dies when outnumbered for three reasons that the sources agree on:

1. **He rolls when the shield would have absorbed the whole hit.** Below 50 % health `D.plan` picks dodge over
   block. A Bronze Shield blocks 39 and a Goblin Runt hits for 18. A block costs stamina only when it absorbs a
   hit, does not move him, and leaves him in reach.
2. **Every roll is a directional roll.** `D.plan` always sets `dir` to left or right. Measured here: a directional
   roll moves him about 4.85 m, a neutral one about 2.15 m. Players name the neutral evade as the one to use in a
   group because it keeps the follow-up.
3. **He does not thin the group.** One Bronze Sword press kills a 60 hp Goblin Runt. Each kill removes one stream
   of telegraphs. The fight keeps its target until it is out of reach or three swings miss.

## 1. Dragonwilds' own rules

### 1.1 Block

- **[source]** "Blocking reduces the incoming damage from the attack of a monster by the block value of the
  equipped shield." https://dragonwilds.runescape.wiki/w/Armour (Shields section; `/w/Block` redirects here)
- **[source]** Block values: Wooden 26, Leather 33, Bronze 39, Iron 46. "they do not add bonuses to armour or
  health, but instead have their own hitsplat when blocking attacks."
  https://dragonwilds.runescape.wiki/w/Shield and https://dragonwilds.runescape.wiki/w/Bronze_Shield
- **[source]** "Holding a block does not consume stamina. Only when an attack is successfully blocked will the cost
  be incurred." Cost table: "Any shield | 17". https://dragonwilds.runescape.wiki/w/Stamina
- **[source]** "If a player runs out of stamina, they will be unable to attack or dodge, and blocking will cause
  them to stagger." https://dragonwilds.runescape.wiki/w/Combat
- **[source]** The player is staggered by "Blocking while stamina is depleted" and "Attempting to block an
  unblockable attack (without the use of Tempest Shield)". https://dragonwilds.runescape.wiki/w/Stagger
- **[source]** Jagex, combat rework: "We're reducing the Block animation and starting the block window earlier,
  which means you'll be able to block more often, and more effectively." and "You'll be able to animation cancel
  from combat actions." https://dragonwilds.runescape.com/news/0-12-1-combat
- **[local]** `BP_Components_PlayerBlocking`: `BlockingAngle` 120, `MinimumBlockDuration` 0.75 s,
  `BareHandsBlockingDamageNegation` 5 (DISCOVERIES L1210). Server `BlockDelay` 0.117 s: a block that starts inside
  it does not count (L1807-1815). A "block" with no shield took full damage (L1888). Shield block action cost 10
  stamina in the class defaults (L1430).
- **[inference]** A flat reduction of 39 against a hit of 18 means a blocked Goblin Runt hit does 0. The wiki's
  sentence supports this and no source contradicts it, but the live number for a blocked runt or rat hit while
  below 50 % health has not been read here.
- **[inference]** A held block covers every attacker inside the 120 degree arc in front of him and none behind
  him. No published source says whether one held block covers several attackers. Only the local `BlockingAngle`
  suggests it.

### 1.2 Parry

- **[source]** "Parrying is when the beginning of a block coincides with the timing of an attack of a monster. An
  audible "clang" will sound, and the enemy becomes staggered as long as they are not immune (e.g., Velgar)."
  https://dragonwilds.runescape.wiki/w/Armour
- **[source]** "Parry is an unlockable ability at level 5 Attack ... prevent damage, and stagger the attacker for
  roughly 3 seconds. ... After a successful parry, there is a minimum delay of 0.550s where the player finishes
  the parry animation and cannot initiate an attack." https://dragonwilds.runescape.wiki/w/Parry
- **[source]** "When either the player or monster is staggered after being blocked by a parry, the incoming damage
  to the attacker is dealt 25% more damage." "Enemies take 0.5s after a stagger wears off to regain consciousness
  and aggression." https://dragonwilds.runescape.wiki/w/Stagger (stagger times for Giant rat and Goblin runt are
  blank in its table)
- **[source]** "Parrying successfully will grant you 50% of your max stamina back." and one "cinematic Visceral
  Attack". https://dragonwilds.runescape.com/news/0-12-1-combat
- **[local]** `ParryWindowLength` 100 ms (L1210); parry needs the perk `PerkV2_Attack_Parry`; a pickaxe cannot
  parry (L1430-1435); three runts with Bronze Sword, Bronze Shield and the perk: parried, 0 damage (L2327-2330).
- **Not found:** an exact parry window in any public source. A Reddit comment says a parry "affects other enemies
  if close enough" (https://www.reddit.com/r/RSDragonwilds/comments/1s5bob4/noob_i_feel_squishy). No other source
  repeats it. Treat it as unverified.

### 1.3 Dodge

- **[source]** "After the player takes no stamina-requiring actions for 3s, stamina regeneration will begin."
  "Dodging can animation cancel most player animations in the game." Maximum stamina 100, capped to 80 / 60 / 40
  by rest. https://dragonwilds.runescape.wiki/w/Stamina
- **[source, second hand]** Dodge 20 stamina, jump 10, one-handed sword 15 per swing: gamever.io citing the wiki
  (https://gamever.io/knowledge-base/dragonwilds-stamina-every-cost-and-the-two-meters-that-cap-it). The wiki's own
  mobility table was not in my extract.
- **[source]** YouTube, "Runescape Dragonwilds 1.0 Ultimate Beginners Guide"
  (https://www.youtube.com/watch?v=1SAoIF3lGL8, transcript at 13:21): "you can actually just tap the evade button
  without putting any input here on movement. And I find this extremely effective for close-range combat. So, you
  can basically follow up right away. Whereas, if you were to roll out of the way, you then have to basically walk
  back over to the enemy ... especially if you're in a group of enemies and you want a follow-up attack." Also: "if
  you just tap the evade button, your character will actually move and it will still give you eye frames".
- **[source]** Reddit (https://www.reddit.com/r/RSDragonwilds/comments/1wlllyj/melee_tips): "Consider using the
  backstep instead of any other dodge if youre wanting iframes instead of movement, you can become essentially
  invincible when chaining backsteps."
- **[local]** The roll is invulnerable from 0.15 to 0.75 s after it starts. "A neutral dodge moves him about
  2.15 m, a directional one about 4.85 m." A dodge cancels his own swing within 1-4 frames (DISCOVERIES, "Dodge,
  encumbrance and fleeing in a fight", live 2026-11-16, about L3381-3384). Dodges left and right carried him 2 to
  2.5 m sideways (L1821). A dodge-only bare-handed fight became a loop, 7 presses in a minute, dead (L2358).
- **Not found:** roll distance or the length of the invulnerable window in any published source; whether the
  neutral evade has the same invulnerable window as the roll (`M.evade_window` reads the Left, Right, Backward and
  Forward montages and keeps one window for all of them).

### 1.4 Stamina, the two numbers that disagree

- Wiki: block 17, dodge 20, maximum 100. Local class defaults: block and parry 10, evade default 15 in
  `D.plan`, maximum stamina read 60 (L1549). Jagex said shield and weapon costs were being rebalanced in 0.12.1.
  **[inference]** The fight code should trust the live read, not either table.
- **[inference]** With 60 stamina and 20 a roll, three rolls empty the bar. Under alternating telegraphs from two
  enemies the 3 s regeneration delay never elapses, and at 0 stamina he can neither swing nor dodge and a block
  staggers him. Dodge-everything therefore starves his own swings (15 each). A parry gives half the bar back. A
  block costs only when it absorbs.

### 1.5 The two enemies

- **[source]** Giant Rat: power level 1-5, health 50 / 100 / 162 / 225 / 288, weak to Stab, resists Crush,
  aggressive. No damage and no attack timing on the page. https://dragonwilds.runescape.wiki/w/Giant_Rat
  (matching the five health values to the five levels is my inference from their order)
- **[source]** Goblin Runt: power level 1 / 3 / 6, health 60 / 195 / 420, weak to Fire, aggressive. No damage and
  no attack timing. The page is in the category "Needs health information".
  https://dragonwilds.runescape.wiki/w/Goblin_Runt
- **[local]** A goblin hit is 18. One Bronze Sword press deals 60, which kills a 60 hp runt (L2327-2330). Goblin
  Runt Attack1 and Attack2 land 0.9-0.95 s after the telegraph, SlowAttack 1.1-1.3 s (about L3385). Goblin Runts
  keep up with a sprinting player over 25 m.
- **Not found:** Giant Rat damage and attack timing anywhere, in public or in DISCOVERIES. The game has
  `AiAttackTicketsManager:OnAiAttackStarted` (L492), so attacks are rationed by tickets, but how many tickets a
  player has was not read and no public source gives it.

### 1.6 What players recommend against several weak melee enemies

- **[source]** Same YouTube guide at 19:26: "You don't need to pull off the parries here. If there's multiple, it's
  better to just try and block to be safe than have to constantly worry about the perfect parry timing."
- **[source]** "If another opponent is closing in, consider using the opening to reposition. ... parrying one
  attack does not deal with every nearby threat." "attack in short bursts, keep Stamina available for defense".
  https://mobalytics.gg/gamebase/guides/runescape-dragonwilds-combat
- **[source]** "Against a single isolated target, the Visceral follow-up is usually the right call. Against a
  group, that same opening might be better used to step back into a safer position."
  https://games.gg/runescape-dragonwilds/guides/runescape-dragonwilds-combat-guide/
- **[source]** Reddit (https://www.reddit.com/r/RSDragonwilds/comments/1s5bob4/noob_i_feel_squishy): "When there's
  just 1 or 2 enemies I use a shield and the wooden sword. Wait for them to attack, block it, then hit back."
  "You will always need to rely on blocking with a shield". One dissent: "dodging -> hitting seems like it's almost
  always a better use of stamina ... than ... sitting there holding block". Some of this thread is older than the
  0.12.1 rework, when a block sometimes "still take full damage".
- **[source]** Reddit melee tips: "when in doubt, just do a one or two hit combo until [you] can guarantee your
  safety."
- **[source]** Steam (https://steamcommunity.com/app/1374490/discussions/0/840629022687843480): "I would pick my
  opponents and their numbers".
- **[source]** The wiki's strategy page has nothing on groups beyond lodestones to leave a fight, Windstep,
  Confuse and Tempest Shield. https://dragonwilds.runescape.wiki/w/Attack/Strategies
- **Not found:** "guard break" as a mechanic. The only forms are the stagger at 0 stamina and the stagger from
  blocking an unblockable attack.

## 2. What open-source bots and published combat AI do

I found **no open-source bot with an explicit rule for being outnumbered**. Every one I read fights one target
and takes the nearest. What can be reused is small.

| Project | Licence | What it does (read from source) |
|---|---|---|
| mineflayer-pvp, https://github.com/PrismarineJS/mineflayer-pvp (`src/PVP.ts`) | MIT (README) | One target, given by the caller. Swings on a timer whenever inside `attackRange` 3.0, follows at `followRange` 2. With a shield: lowers it, waits 100 ms, hits, waits 150 ms, raises it again. So the shield is up between swings by default, not raised per telegraph. |
| Mindcraft, https://github.com/mindcraft-bots/mindcraft (`src/agent/modes.js`, `src/agent/library/skills.js`) | MIT (repo page) | `self_defense`: nearest hostile within 8 blocks. `defendSelf` picks the nearest hostile again after every hit, chases when it is 4 or more blocks off and backs away when it is within 2 (`GoalInvert(GoalFollow(enemy, 2))`). `cowardice`: flee to 24 blocks from a hostile within 16. No health threshold and no count of enemies. |
| Wurst7 Killaura, https://github.com/Wurst-Imperium/Wurst7 (`KillauraHack.java`) | GPL v3 (file header) | Target picked again for every attack: filter by range, then by field of view, then `stream.min(priority)` with priority `DISTANCE`, `ANGLE` (default) or `HEALTH` (lowest first). A cheat client, cited only for this comparator. |
| Dark-Souls-PvP-AI, https://github.com/metal-crow/Dark-Souls-PvP-AI (`Dark Souls AI C/AIDecisions.c`) | GPL v2 (`LICENSE.md`) | One opponent. Answers an attack only when `distanceByLine <= Enemy.weaponRange` and the hurtbox is about to be live, otherwise "not about to be hit" and it stays neutral. "dont attack, enemy windup". Roll by default, perfect block "if we dont have enough time to roll". A backstab chance overrides defence: "If AI can BS, always take it". No stamina check. README to-do: "If behind enemy, dont have to dodge, if their attack wont hit me." |
| @nxg-org/mineflayer-custom-pvp (npm README) | MIT (README badge) | Strafing, shield modes, crit timing. Target in its example is `nearestEntity`. No group logic in the README. Source not read and repository URL not confirmed. |

Published material on attack rationing, read from the player's side:

- **[source]** Game AI Pro chapter 28, "Beyond the Kung-Fu Circle" (Kingdoms of Amalur):
  "Grid capacity will work to place a limit on the number of creatures that can attack the player at once, while
  attack capacity will limit the number and types of attacks that they can use." A creature with no slot "cannot
  approach the player and must wait outside the grid area."
  https://www.gameaipro.com/GameAIPro/GameAIPro_Chapter28_Beyond_the_Kung-Fu_Circle_A_Flexible_System_for_Managing_NPC_Attacks.pdf
- **[source]** DOOM (2016), GDC talk "Embracing Push Forward Combat in DOOM"
  (https://www.youtube.com/watch?v=2KQNpQD8Ayo, transcript about 41:40-43:22): "if there are only X tokens of a
  certain type then those behaviors can only be done by X AI at a time"; on a harder setting "instead of
  one-on-one you've got two and three"; the AI "immediately in front of the player" may steal a token. Also
  https://www.gamedeveloper.com/design/cyber-demons-the-ai-of-doom-2016-
- **[inference]** Dragonwilds has a ticket manager too. If its count for a player is 1 or 2, telegraphs overlap
  far less than three enemies suggest, and the cost of the present rule is displacement and stamina, not the
  number of hits he cannot answer. This fits the fights on record: telegraphs "alternated".
- **[snippet]** Souls-like advice: "Move around to separate them so you only have to engage a few enemies at a
  time" (https://primagames.com/tips/how-stay-alive-dark-souls-3). A Tuts+ article on battle circles warns of
  "poke-and-run tactics" when too many may attack at once (page returned 403).

**Not found:** a Monster Hunter or Valheim bot with fight logic; a souls-like bot that fights more than one
enemy (EldenRL and similar are reinforcement learning on single boss fights, and I did not read them or check
their licences); any academic paper on the player's side of a token system; any source for "back to a wall" or
"keep them in one arc" beyond general advice. The 120 degree block arc makes such a rule plausible here, but it
is not small and nothing was found to copy.

## 3. Three small rule changes

All three are general, live in the body's fight skill, and name no quest, place or creature. The model still
decides what to fight and when to leave.

Baseline to measure against, from the run of today (Bronze Sword, Bronze Shield, 64/100 hp, one Giant Rat and one
Goblin Runt): 2 swings in 22 s (0.9 per 10 s of melee), 78 damage in 22 s (35 per 10 s), dead.

### Rule 1. A hit the shield absorbs whole is blocked, at any health

- **Rule:** in `D.plan` (`auto`), when he holds a shield, the attack is blockable, he has the stamina for a block,
  and the attack's learned damage (`th.damage`) is at most the shield's block value, the answer is a block (or a
  parry when above the heal threshold, as now). Low health no longer turns it into a dodge. When the damage is
  unknown or larger than the block value, the present rule stays.
- **Rests on:** wiki Armour page, "Blocking reduces the incoming damage ... by the block value of the equipped
  shield"; Bronze Shield 39 against a goblin hit of 18 [local]; "Only when an attack is successfully blocked will
  the cost be incurred"; the guide at 19:26, "If there's multiple, it's better to just try and block"; a block
  does not move him, a roll moves him 2 to 4.85 m [local].
- **Needs first (visibility):** `ctx` carries no block value today. Add the equipped shield's Block stat to `ctx`
  and log the damage of a blocked hit, so the flat-reduction reading is confirmed on a runt and on a rat. Keep the
  block inside the 120 degree arc: he already turns to the attacker.
- **Number it should move:** swings per 10 s of melee up from about 1 to 3 or more; damage taken per 10 s down from
  about 35 to under 10; deaths in the two-enemy step trial.
- **Negative test that fails today:** `D.plan` with a fresh learning state and a fixed `rng`, an attack whose
  learned damage is 18, `ctx = {hp_frac = 0.4, heal_hp = 0.5, can_block = true, can_parry = true, stamina = 60,
  block_value = 39, dist_cm` in reach`}`. Expected rule pick `block`. Today it is `dodge` (the branch
  `elseif low_hp and can_dodge then pick = "dodge"`). A second case with learned damage 50 must still give
  `dodge`.

### Rule 2. With an enemy in reach, an evade is the neutral one

- **Rule:** when the answer is a dodge and his target, or the attacker, is inside his melee reach, `D.plan` sets no
  direction, so the evade key goes in with no movement input. Left or right stays for attacks that leave ground
  behind them (area tags) and for when nothing is in reach.
- **Rests on:** local measurement, neutral 2.15 m against directional 4.85 m; the guide at 13:21 ("tap the evade
  button without putting any input ... you can basically follow up right away ... especially if you're in a group
  of enemies"); Reddit, "backstep ... if youre wanting iframes instead of movement".
- **Needs first (visibility):** which montage the neutral evade plays and its invulnerable window, read the same
  way as `M.evade_window`, so `dodge_lead_s` is right for it. It still moves him about 2 m, so it halves the walk
  back, it does not remove it.
- **Number it should move:** the "dodge ... moved" distance in the fight log, median from about 4 m to about 2 m;
  swings per 10 s of melee up; the avoided rate must stay where it is (23 of 24 and 10 of 14 on record). If the
  avoided rate falls, bin it.
- **Negative test that fails today:** `D.plan` forced to a dodge (`orders.defense = "dodge"`) with `ctx.dist_cm`
  inside reach, over 20 seeds: `p.dir` is always `left` or `right` today
  (`p.dir = (rng() < 0.5) and "left" or "right"`). Expected: no direction.

### Rule 3. Among the enemies on him and in reach, the one that dies soonest goes first

- **Rule:** when two or more creatures that attacked him stand inside his reach, the fight takes the one with the
  fewest presses to kill (its health divided by his damage per press on it), nearest on a tie, and says so. The
  one the model sent him for is taken up again when the others are down, as `M.swap_target` already does. Today
  that swap happens only when the target has been out of reach or three swings missed.
- **Rests on:** one Bronze Sword press deals 60 and a Goblin Runt has 60 hp [local, wiki]; a Giant Rat of 100 hp
  needs two; each kill ends one stream of telegraphs, and every telegraph he answers costs him a swing. Wurst7's
  `HEALTH` priority (GPL v3) is the same comparator. Reddit: "do a one or two hit combo until [you] can guarantee
  your safety".
- **Needs first (visibility):** each attacker's current health and his own damage per press must be readable in
  the fight frame. I did not check that both are there.
- **Number it should move:** seconds to the first kill in a two or three enemy fight; telegraphs answered per
  10 s after the first kill; deaths.
- **Negative test that fails today:** a fight frame with the target a Giant Rat at 100 hp in reach, a Goblin Runt
  at 60 hp that hit him 1 s ago also in reach, damage per press 60. Expected: the target becomes the runt. Today
  `M.swap_target` returns false because the rat is in reach and no swing has missed.

### Considered and left out

- **Swing in the wind-up before a block or parry as well as before a dodge.** `M.windup_swing` covers only the
  plain dodge, and its comment says a block, a parry and a cast were not probed. Jagex says combat actions can be
  cancelled and Mobalytics says "Blocking or dodging can interrupt attacks". Worth a probe once rule 1 is in,
  because rule 1 turns most dodges into blocks.
- **Do not answer a telegraph when the swing in progress kills the attacker first.** No source says a kill or a
  stagger cancels an attack already started.
- **Back to a wall, or turning so all attackers sit inside the 120 degree block arc.** Plausible, not small, and
  no source to copy.
- **The learning reward.** `D.feedback` scores avoided 1 and blocked 0.75. It does not count the swings a roll
  costs, so the bandit will keep drifting to the dodge. [inference] Worth a look after rules 1 and 2.
