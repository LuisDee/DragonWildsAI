# Vel'gar: what the body needs for `capstone:slay_velgar_solo` (M6) (2026-10-26, combat agent)

GOAL M6 says: slay Vel'gar SOLO on the dev world. That means research, preparation (anti-poison, upgraded and levelled gear, food, an enchant), reading and answering his attacks live, and surviving. This note covers what is known about him, what the body already covers, the gaps, and a staged plan for the Director. It describes the body side only; no live data yet.

## 1. What he is

The data comes from the wiki snapshot `data/wiki/pages` (Velgar, Velgar/Strategies, Velgar's Rise, the item pages) and from the class dump `dumps/26161880/CXXHeaderDump`.

- **Stats:** a boss at **PL 4 with 6,000 HP**, race Dragon, aggressive.
  - **No weakness and no resistance. Immune to the Poison and Burning effects**, so weapon poison is useless and fire hits do no burn.
  - Drops: Velgar's Head, plus 30–40 Ascension Shards (PL 4).
- **Arena:** the top of Velgar's Rise (Fractured Plains), reached during Dragon Slayer.
  - He is summoned with a **Challenge Horn** on the dragonkin altar. The horn is crafted at a blacksmith's bench from a Dragon Tooth, Bloodwood Sap and 5 Bronze Bars.
  - In the dump the arena is `APhasedDragonArenaAILevelData`: `ArenaVolume`, `AttackZones` (a shape collection), `DragonPositions`, `TeleportPlayerIntoDragonArena`, and the phase data below.
  - He also **attacks in the wild** now and then, with poison breath or meteor barrages.
- **Phases** (wiki): at about every 25% of his health he flies up and rains poison barrages on red-orange circles, until the last 25%.
  - Dump: `FDragonBossPhaseData {HealthThresholdPercent, PhaseTransitionTime, …}`, replicated `FDragonBossPhase_Runtime {PhaseIndex, bTransitioningToNext}` (`OnRep_PhaseRuntimeData`), `BP_OnPhaseTransitionStarted/Ended`.
- **Melee attacks.** These are `UAiAttackData` classes on `BP_DragonVelgar_AttackComponent`, a subclass of `UBP_AiAttackComponent_C`:
  - `ATK_DragonVelgar_BiteAttack_{Left,Right}`, plus `_Hold` variants;
  - `ClawAttack_{Left,Right}`;
  - combos: `ClawBite_{L,R}_Combo1/2`, `ClawClaw_{L,R}_Combo1/2`;
  - `HeadSwipe_{L,R}`.
  - The wiki names them: Claw Slam, Claw Strike, Bite, Head Swing. Bite and claw strike are used only at close range.
- **Abilities.** These are `UDominionAIAction` classes (`DAA_*`), started by `UDominionAIActionsComponent:Multicast_StartAIAction(ActionId)`, **not** by the attack component:
  - `DAA_DragonVelgar_PoisonBreath_{Front,Left,Right}`: a cone. The breath is chosen per player zone: `LH_DragonVelgar_Zone_{FrontLongRange,LeftLongRange,RightLongRange,FarAwayOnly}`.
  - `DAA_DragonVelgar_EarthSpikes`: a claw slam that sends `BP_DragonVelgar_EarthSpikes_GroundProjectile` (an `AAIGroundProjectile`) along the ground toward the target. The `_InitialBlast` actor is the slam itself.
  - `DAA_DragonVelgar_MeteorStrike`: during flight, `BP_DragonVelgar_MeteorStrike_MeteorProjectile` (an `AAIMeteorProjectile`, `Multicast_OnActivate(Radius, TelegraphTime, TargetLocation, …)`) lands and leaves `…_PoisonCloud` (a `UPoisonEmitterSphere` with `NetworkedRadius`, `Initialize(Radius, Duration)`).
  - `DAA_DragonVelgar_Reposition`: flies to one of the `DragonPositions`.
  - `BP_DragonVelgar_LandingDamageInfliction`: an `ADelayedDamageAttack` with `TelegraphTime`, i.e. the landing hit.
  - `LH_DragonVelgar_LowHealthAttack`: a low-health attack weighting.
- **Ground hazards in general** (`AAIGroundProjectile`):
  - fields: `Speed`, `MaxTravelDistance`, `TelegraphTime`, `ExplosionTriggerRadius`, `PeriodicDamageConfig`;
  - client multicasts: `Multicast_TelegraphExplosion`, `Multicast_SetTarget`, `Multicast_SetTargetLocation`, `Multicast_OnActivate`.
  - The poison breath leaves a periodic-damage goop trail (`…PoisonBreath_GroundProjectile`, then `…_PoisonCloud`).
- **Poison:** about 4 HP/s until cured (wiki), a tracked status (`ETrackedStatusEffect.Poison`). Two counters stack:
  - **Lesser Antipoison** (Toadflax, Swamp Weed and a Clay Vessel at a brewing cauldron) removes the stacks and gives 33% resistance for 600 s;
  - **Fungal Fortitude** (Mushroom Kebab, Forager's Sandwich, Grilled Mushrooms…) gives another 33%, for 66% together.
- **Recommended setup** (wiki strategies, normal difficulty, first kill):
  - **PL 4 gear**: Iron helmet, platebody and platelegs, or studded leather for ranged, or Dark Mage for magic;
  - a weapon: Iron Mace or Greataxe, Iron Crossbow, or a Blightwood staff or wand;
  - **Anti-Dragon Shield**: a PL 3 masterwork shield that blocks the breath without stagger; recipe from Vertentis Kara;
  - **20+ Berry Drizzle Pan-Seared** (160 HP);
  - **20+ Lesser Antipoison**;
  - an infusion that matches his combat style;
  - Sanguine Urns for max HP.
  - Spells: **Tempest Shield** (it blocks even unblockable attacks), **Surge** (3 free long dodges), **Enchant Weapon: Air** (melee) or Spectral Arrows (ranged). Water, air or earth runes are better than fire.

## 2. What the body covers today

| Threat | Covered? | By |
|---|---|---|
| Bite, claw, head-swipe and combo telegraphs | **Yes** | The `AiAttackComponent:Multicast_PerformAttackOnSimulatedProxies` hook fires for his subclassed component too. It reads attack data (damage time, shape, flags, `combo_next`), and per-attack learning applies: timing, lunge, reach, damage, response bandit, cadence. Reach scales with his capsule. |
| Block or parry the melee | **Yes**, with a shield and Attack 5 | parry or block; Tempest Shield precast; `defence_reserve` keeps stamina for it |
| Dodge direction | **Yes** | IA_Movement plus evade, facing the attacker |
| Phase Dash or Tempest Shield on dangerous hits | **Yes** | defense.lua bandit plus the spells contract |
| Disengage, eat, re-engage | **Yes** (proven live) | orders.disengage |
| Fight-or-flight information, prepared odds | **Yes**, now with the **wiki** as a labelled source (PL 4, 6,000 HP, immune to Poison/Burning) | `fight_odds`, `known_affinities`, `combat_brief.weaknesses.wiki` |
| Memory over repeat attempts | **Yes** | combat memory (per-attack learning and fight history survive restarts) |
| A target that leaves reach | ⚠️ ends the fight | L34's chase budget (30 s) would end a boss fight while he is airborne; see gap 3 |

## 3. Gaps (body side), in build order

1. **Ability telegraphs (DAA)**
   - Hook `UDominionAIActionsComponent:Multicast_StartAIAction(ActionId)` and `Multicast_StopCurrentAIAction`. Then read `CurrentAction` (class name) on the next tick. Never send anything.
   - Map the class to a threat `{kind = breath_cone | ground_spikes | meteor | reposition | landing, side = front|left|right}` from **data**: a small `ability_profiles` file keyed by class-name tokens (PoisonBreath, EarthSpikes, MeteorStrike, Reposition), never by creature.
   - Learn its timing per class, like the attacks.
   - Reusable for every dragon (Green and Blue Dragon, Blightscale) and for any `DAA_*` user.
   - Verify read-only first, on a wild Vel'gar flyover or the arena.
2. **Ground hazards: perceive and step out**
   - A hazard census of `AAIGroundProjectile`, `AAIMeteorProjectile`, `ADelayedDamage` and `UEffectEmitterSphere` owners near him: position, radius (`ExplosionTriggerRadius`, `Radius`, `NetworkedRadius`), time to damage (`TelegraphTime`), heading (`Speed`, `TargetLocation`).
   - Hook their client multicasts (`Multicast_OnActivate`, `Multicast_TelegraphExplosion`), read-only.
   - The answer is **movement, not an i-frame**: choose the nearest point outside every live circle and cone, inside the arena volume, and go there. When the time to impact is shorter than the walk, dodge or Phase Dash outward.
   - This needs a `move.lua` hook from the locomotion owner: an "avoid zones" cost or an escape-point request. Coordinate, don't edit.
   - Reusable for every ground AoE: poison vines, vault creatures, dragons.
3. **Boss phases and flight**
   - Read `APhasedDragonArenaAILevelData.PhaseRuntimeData` (replicated: `PhaseIndex`, `bTransitioningToNext`) and `PhaseData` (thresholds), plus the airborne state (`Reposition` running, or no navmesh path to him).
   - While he is up or transitioning, the fight **stays** in a `hold` phase: dodge meteors, heal, top up buffs, re-cast Tempest Shield. L34's chase budget and the stall checks are suspended. Announce the phase in activity events (`boss_phase {index, airborne}`) so the brain can say "he's taking off, I'm dodging the meteors".
4. **Poison status and cures**
   - Perception of his own tracked statuses: Poison stacks and DoT; active perks such as Antipoison, Fungal Fortitude, Tempest Shield and infusions, with time left.
   - Consumable effects from **item data**: cure or resistance per item.
   - The fight eats a cure when poisoned and keeps the resistance up between waves. This is the same `try_eat` path with a "cure" kind beside "heal".
   - Show the statuses in the digest ("poisoned −4 HP/s; Antipoison 3 min left").
5. **Prepared-odds model, for him**
   - Count the poison DoT in their DPS, from wiki or learned data.
   - Count antipoison and Fungal Fortitude as damage reduction.
   - Count food per item heal (Berry Drizzle 160 HP), not a fixed cap. The 2× max-HP cap is too low for 20+ items over a long fight.
   - Count ranged and magic DPS (staff and rune damage: currently "not counted").
   - Count the Anti-Dragon Shield against the breath.
   - Model a long fight as **phases**: four melee windows plus three flights.
   - Keep the boss label visible and say what isn't counted.
6. **Arena logistics.** These are Director skills, not combat:
   - craft the Challenge Horn;
   - reach Velgar's Rise;
   - a lodestone at the entrance;
   - re-entry after a death (the graveyard and grave run).

   The wiki's pedestal trick (teleport out and back so the horn holder stays) is a known strategy, but it looks like an exploit. Luis's call; I won't build it unasked.
7. **Repeat-attempt telemetry:** a per-attempt summary into the fight history: phase reached, damage taken per threat kind, cause of death. Then `damage_taken_trend` measures progress against him specifically.

## 3b. Built (offline, 2026-10-26): gaps 1, 3, 4

- **Gap 1, ability telegraphs** (`combat.lua`):
  - Read-only hooks on `DominionAIActionsComponent:Multicast_StartAIAction(int32 ActionId)` and `Multicast_StopCurrentAIAction`. The hook stores only the component and the scalar id; `CurrentAction`'s class is read on the next fight tick, as a property.
  - Data profile `client_mod/scripts/ability_profiles.lua`, keyed by class-name tokens (PoisonBreath, EarthSpikes, MeteorStrike, Reposition…; side Front/Left/Right).
  - A threatening ability near him is defended like a telegraph, with the key `<creature>:<action class>` and learned like an attack. It is unblockable (a dodge, never a jump over a breath) and the timings are labelled priors. Each ability emits a `creature_ability` activity event.
  - The signatures are checked against the dump in `tests/test_dump_signatures.py`.
- **Gap 3, phases and flight:**
  - In a fight with a boss, the arena's replicated `PhaseRuntimeData {PhaseIndex, bTransitioningToNext}` and the `PhaseData` count are read once a second.
  - While he is airborne (Reposition or MeteorStrike running) or transitioning, the L34 stall, chase and lost-target budgets are suspended (`fight.boss_hold`).
  - `combat_status.boss`, get_state `boss_fight` (a digest line) and a `boss_phase` activity event on change.
- **Gap 4, statuses and cures:**
  - His tracked statuses are read by **property only**: `TrackedStatusEffectInstances` → `EffectType`, `CurrentValue`, `Config.MaximumValue`.
  - Cure and resist data come from the wiki snapshot: `tools/gen_consumable_wiki.py` → `client_mod/scripts/consumable_wiki.lua`, 320 consumables, 21 of them cure or resist a status.
  - In a fight, a harmful status above 5% of its maximum gets the best carried cure, curing before resisting and the hotbar before the bag. It is verified (`cured` event), or reported once if he has none (`status`, have_cure=false).
  - The perks taken are remembered with the wiki duration. get_state shows `status_effects` and `buffs_remembered` as digest lines.
- **Gap 5, prepared odds for a long boss fight** (`combat.boss_prepared`, used by `prepared_odds` for a boss; an estimate with every prior named in `priors`):
  - **Time:** his damage window (boss HP / his prepared DPS) split into the arena's phase count (prior 4) melee windows, plus one fewer flights of 20 s with no damage dealt.
  - **Intake:**
    - their melee DPS, reduced by `breath_share 0.3 × dragon_shield_block 0.7` when he carries an Anti-Dragon Shield (matched by name);
    - plus poison DoT when the creature poisons (wiki `inflicts`, from the page's prose, or an observed poison ability): `4 HP/s × uptime 0.5 × (1 − resistance)`. Resistance is his best carried poison resist ×2 (a potion plus a Fungal Fortitude food: 66%);
    - meteors at 2 HP/s during flights.
  - **Supply:** HP + Tempest Shield + **every** carried food, eaten no faster than once per 8 s.
  - **DPS:** melee, or a carried ranged weapon with its ammo, or a staff with runes (rune damage is a labelled estimate).
  - **Check against the wiki:** PL 4 with the wiki's kit (Iron Mace, 20 Berry Drizzle, 20 Lesser Antipoison, Anti-Dragon Shield, Tempest Shield) is a **likely win**. The same kit at PL 3 or lower is a likely loss. Bare at PL 4, he dies in about 9 s. This matches the wiki's "difficult without PL 4 gear and being prepared".
  - Not counted: blocking, dodging (meteors assumed mostly dodged), armour, infusions and potions' damage buffs, a second fighter.
- **Gap 7, boss attempts:**
  - Every hit taken in a fight is attributed: the defence window it fell in (`ability:<kind>` or `melee:<attack class>`), else `poison` while poisoned, else `other`.
  - A boss fight's end records an attempt: phase reached, phases, damage taken, `damage_by`, cause of death (the last threat before dying), boss HP left %, duration, heals, cures.
  - It is persisted in the combat memory (last 20 per boss) and shown in `combat_brief.boss_attempts`, so the damage and phase trend across attempts is measurable.
- **Still to verify live** (S2/S3, read-only first):
  - that the multicasts fire on the client for him;
  - that `CurrentAction` is set when read;
  - the arena actor's replication;
  - that the status instance values match the HUD.

## 3c. What combat needs from `move.lua` (gap 2, for the locomotion owner)

Hazards are not a combat input; they are terrain that changes every second. Requested interface, all optional arguments with defaults that keep today's behaviour:

```lua
-- 1. Zones to keep out of while any move runs (go_to / follow / escape), replaced on every call (no merge):
move.set_avoid_zones(log, zones)          -- zones = { {id, x, y, z, r_cm, until_s, kind = "circle"},
                                          --           {id, x, y, z, r_cm, until_s, kind = "cone", yaw_deg, half_angle_deg} }
                                          -- scalars only (R15); until_s = game-clock expiry; [] clears.
-- 2. "Get me out now": the nearest point outside every zone, inside a bound (the arena volume, or a radius), reachable
--    on the navmesh; walks there at once (sprint when time_s is short). Reports truthfully.
move.escape_zones(log, { time_s = 1.2, bound = { x, y, z, r_cm } })
  -> { ok, at = {x,y,z}, eta_s, why = nil | "no_safe_point" | "no_route" | "too_slow" }   -- too_slow: combat dodges instead
-- 3. Path costs: while zones are set, go_to/follow plans around them (a cost, not a wall: when no other way exists,
--    it may cross a zone that expires soonest, and says so in status().avoid = {crossing = id}).
move.status().avoid = { zones = n, inside = id | nil, crossing = id | nil }
```

Combat fills the zones from a hazard census and the hooks (the projectile multicasts: `AAIGroundProjectile`, `AAIMeteorProjectile`, `ADelayedDamage`, `UEffectEmitterSphere` owners). It calls `escape_zones` when it is inside a zone that lands in less than its walk time, and dodges or Phase Dashes outward when `escape_zones` answers `too_slow`.

## 4. Staged plan (practice first, then him)

| Stage | Creatures (dev world) | Proves | Body gaps it needs |
|---|---|---|---|
| S0 (done) | Kebbit, Goblin Runt PL 1 | dodge, parry, disengage-heal, memory | none |
| S1 | Goblin Thug PL 2, Wolf PL 3, Dire Wolf PL 3 (packs, bleed) | telegraphed melee at higher PL, more than one attacker, damage trend over 5 fights | none (live proof) |
| S2 | Wild Jade Vine PL 3 / Wild Lapulis Vine PL 4 (poison projectiles), Vault Incinerator PL 3 / Vault Corruptor PL 4 (poison areas) | poison cure use, hazard avoidance | 2, 4 |
| S3 | Vel'gar's wild flyovers (breath, meteors) | read-only capture of DAA and hazard multicasts and timings | 1, 2 (read-only first) |
| S4 | Green Dragon PL 5 (breath, weak to Water), optional | a dragon's melee plus breath at higher PL | 1, 2, 5 |
| S5 | Vel'gar arena attempts, repeated (memory on) | phases, flight hold, full prep | 1–7 |

**S1 is ready offline (2026-10-26).** Pack handling in `combat.lua`, test §10f:
- When two pack members swing, the one that lands first is answered first, and the other is queued for right after.
- A disengage backs away from the pack's centroid.
- When the target runs off while another creature is biting him in reach, he fights that one.
- `combat_end` reports `pack`, `kills` and `multi_swings`. The "outnumbered" verdict (more than 2 hostiles) stays information for commanded fights.

The live driver is `tools/combat_s1.py`:
- `survey` is read-only: creatures within 200 m with their classes, his state, food, memory and history.
- `fights --kind Wolf --n 5 [--spawn <loaded class>] [--pack 2] [--restart-at 3]` runs the fights. It writes each fight's damage and the server's evidence, then the damage-taken slope across fights. `--restart-at` checks the memory reload after a client restart.
- Its offline test is `tests/test_combat_s1.py`.
- Spawning works only for classes loaded on the dev world (the survey shows them). Wolf and Thug paths for `evals/bench/spawn_classes.json` are the eval agent's.

**Gear and level milestones for the Director** (from the wiki and item data; he must craft or earn each himself):

- **M6-a. PL 4 kit.** A PL 4 armour set (Iron helmet, platebody, platelegs; or studded leather or Dark Mage) and a PL 4 weapon in his chosen style. The Iron Mace is the wiki's melee pick; ascended gear is better.
- **M6-b. Anti-Dragon Shield.** Recipe from Vertentis Kara (Whispering Swamp vault), crafted at a blacksmith's bench (repair: Blightwood).
- **M6-c. Consumables, 20+ each:**
  - Berry Drizzle Pan-Seared: smoked herring, seared anchovies and dried dwellberries at a cooking range;
  - Lesser Antipoison: toadflax, swamp weed and a clay vessel at a brewing cauldron;
  - Mushroom Kebabs once he reaches Cooking 36;
  - one combat infusion.
- **M6-d. Sanguine Urns,** each +10 max HP, permanent (21 exist, up to 310 HP).
- **M6-e. Levels and perks:**
  - Attack 5 (parry, already unlocked on ClaudeDev);
  - Attack 8 (weapon specials);
  - Tempest Shield and Surge unlocked, with Enchant Weapon: Air if melee;
  - runes for them.
- **M6-f. Access:**
  - Dragon Slayer progress to Velgar's Rise;
  - the Challenge Horn: Dragon Tooth, Bloodwood Sap and 5 Bronze Bars at a blacksmith's bench;
  - a lodestone near the Rise.

## Search record (search-before-building)

- **Wiki** (local snapshot, CC BY-NC-SA, pages fetched 2026-09/10):
  - [Velgar](https://dragonwilds.runescape.wiki/w/Velgar)
  - [Velgar/Strategies](https://dragonwilds.runescape.wiki/w/Velgar/Strategies)
  - Velgar's Rise; Challenge Horn; Anti-Dragon Shield; Lesser Antipoison Potion; Fungal Fortitude; Berry Drizzle Pan-Seared; Mushroom Kebab; Sanguine Urn.
  - The strategy page itself notes it is being updated for 1.0 combat and Ascension Cores, so re-check after patches.
- **Web** (cross-checks; they agree on breath, slam with spikes, flight and meteors at about 25% steps, and antipoison prep):
  - [games.gg: how to beat Velgar](https://games.gg/runescape-dragonwilds/guides/runescape-dragonwilds-how-to-beat-velgar/)
  - [whisperofthehouse: Dragon Slayer](https://www.whisperofthehouse.com/runescape-dragonwilds/dragon-slayer)
  - [deltiasgaming: Dragon Slayer walkthrough](https://deltiasgaming.com/?p=210654)
  - [allthings.how](https://allthings.how/?p=261685)
- **Game data:** the class dump, build 26161880: the `DragonVelgar` classes, `AAIGroundProjectile`, `AAIMeteorProjectile`, `ADelayedDamage(Attack)`, `UDominionAIActionsComponent`, `APhasedDragonArenaAILevelData`, `UEffectEmitterSphere`, `ETrackedStatusEffect`. Attack timings and radii are Blueprint defaults, readable only live; this is to do in S3.
- **Built from it now** (small and reusable): `tools/gen_creature_wiki.py` generates `client_mod/scripts/creature_wiki.lua`, monster infobox facts for 107 creatures: PL, HP, race, weak/resist/immune as damage-type tags, and immune effects. `combat.known_affinities` reads it with the label `wiki` (below learned and journal, above the hand-written priors). `combat_brief.weaknesses.wiki` and the digest ("immune to Poison, Burning effects (wiki)") show it.
