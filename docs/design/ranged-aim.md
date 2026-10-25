# Ranged aim: crossbows, bows and projectile spells (2026-10-25)

Luis asked: "How do we know he can use a crossbow and aim in real time at an enemy and predict arrow or bolt drop?"

This note describes how the client body (route R2) aims and fires ranged weapons through the game's own inputs, how it predicts drop and leads moving targets, and how it learns from real shots.

- Code:
  - `client_mod/scripts/ranged.lua`: solver, aimer, fitting, learning and metrics;
  - `client_mod/scripts/combat.lua`: ranged engage;
  - `tools/gen_weapon_profiles.py`: ammo kind and reload time per weapon.
- Tests:
  - `client_mod/tests/test_ranged.lua` (29 checks);
  - `client_mod/tests/test_combat.lua` section 13 (a crossbow fight against a strafing goblin with a fake bolt model).
- Live verification: still to do (the defence/ranged slot).

## 1. What the game data says (reflection dump, build 26161880)

- **Ammo carries the flight parameters.** `URangedAmmoData.ProjectileData` (`FProjectileData`) has:
  - `LaunchSpeed`, `OverrideGravityZ`;
  - `TimeWithoutGravity` (a straight segment before the drop starts);
  - `MaxSimulationTime`, `LookAhead`, `TraceChannel`.
- **The equipped ammo for the held weapon:** `PlayerRangedAttackComponent:GetEquippedRangedAmmoDataForCurrentWeapon()`.
- **Charge:**
  - `PlayerRangedAttackCollection` has `LaunchSpeedCurve` and `OverrideGravityZCurve` (both `UCurveFloat`, read with `GetFloatValue(charge)`), `MaxChargeUpDuration` and `TimeBeforeFullAccuracy`.
  - The catalog has Crossbow `max_charge_up` 0.75 s and Bow/Longbow 1.55 s.
- **Accuracy:**
  - `BaseInaccuracy`, `MinimumInaccuracy`, `GetCurrentArrowInaccuracy()`;
  - `HasReachedFullAccuracy` (property), `OnFullAccuracyReached`, `IsAimModeActive()`;
  - `HasRequiredAmmoEquipped()`.
- **Aim path:**
  - The component traces from the camera (`AimOffsetTraceChannel`, `MaxProjectileTraceDistance`, `AimOffsetAngles`). The projectile leaves the weapon actor's `ProjectileSocketName` toward the aimed point.
  - So the input that aims is the camera (control rotation), as with spells.
  - `MaxPitchAngleWhenAiming` / `MinPitchAngleWhenAiming` clamp the pitch.
- **The fired projectile** is an `ADominionProjectile` actor:
  - `LaunchInfo` (replicated, `OnRep_LaunchInfo`): `StartPosition`, `StartDirection`, `LaunchSpeed`, `OverrideGravityZ`, `LaunchTime`;
  - `ParentEquipmentActor`;
  - hit multicast `Multicast_OnProjectileHit(FDominionProjectilePerformableHit)`.
  - The weapon actor keeps `OwnedProjectiles` / `LoadedProjectile`.
  - The catalog's crossbow `projectile_class` is `BP_Arrow_Base_C`.
- **Spell projectiles:** an `ADominionSpellProjectile` has `ProjectileMovement` (`UDominionProjectileMovementComponent : UProjectileMovementComponent`: `InitialSpeed`, `MaxSpeed`, `ProjectileGravityScale`, `HomingTargetLocation`).
- **Engine helpers (reflected, `UGameplayStatics`):**
  - `BlueprintSuggestProjectileVelocity`, `SuggestProjectileVelocity_CustomArc`, `SuggestProjectileVelocity_MovingTarget`;
  - `Blueprint_PredictProjectilePath_ByTraceChannel`.
- **Crossbow inputs (catalog):** primary = "Shoot" (`PA_RangedAttack_Crossbow`), secondary = aim, special = "Heavy Bolt" (32 damage, 50 charge), `reload_duration` 2.0 s, ammo kind `CrossbowBolts` (loadout slot 9).
- All of this is to be read live during the slot. None of the values has been read live yet.

## 2. The solution

1. **Parameters:**
   - Seeded from the live ammo `ProjectileData` (and the charge curves when present), else defaults (4000 cm/s, -980 cm/s², no straight segment).
   - A profile is kept per launcher key (`<weapon item>|<ammo item>`, or a spell id).
2. **Ballistic solution with lead (`R.solve`):**
   - Find the flight time τ where the projectile, straight for t0 and then falling with gz, meets the target's predicted position: `|T + V·τ − M − G(τ)| = s·τ`, with `G(τ) = (0, 0, gz/2 · max(0, τ − t0)²)`.
   - A bracketed 1-D root search over τ ∈ (0, max_time] finds every arc: the smallest root is the direct (low) arc and the largest the high arc.
   - With no root, the target is **out of range**: the reply gives the flat-ground max range, and combat closes in to 75% of the distance.
   - Target velocity comes from the last second of observed positions (horizontal only).
3. **Aim through the real input:**
   - The camera rotation is chosen so the camera ray passes through `muzzle + dir · 5000 cm`; the game shoots from the muzzle toward the point under the crosshair.
   - It is set every frame while aiming (the target moves), plus a learned pitch/yaw bias.
4. **Firing, like a player:**
   - Hold the aim key (`IA_SecondaryAction`).
   - Wait for the game's full-accuracy flag (or `TimeBeforeFullAccuracy`).
   - Tap fire (`IA_PrimaryAction`).
   - Wait out the reload (`reload_duration`).
   - Keep distance: engage from up to 25 m, close to about 12 m when farther. A melee attacker within 6 m makes him drop the aim and defend.
5. **Learning from real shots:**
   - The new projectile actor (one that wasn't there before the shot) is sampled every frame.
   - `R.fit` recovers its real speed (first samples), gravity (vertical second differences) and straight time (where the drop departs from the line).
   - The profile blends 35% toward the measurement.
   - The closest approach to the target track (sampled on the same frames) gives the miss (vertical, lateral). A miss also nudges a pitch/yaw bias (±3° cap), which absorbs what the model can't explain: muzzle offset and camera parallax.
   - Hit = our own damage multicast on the target after the shot (the server's verdict), checked 0.3 s after the bolt is gone.
6. **Metrics:** shots and hits per launcher, overall and by distance (0–10, 10–20, 20–35, 35–60, 60+ m) and by target speed (<0.5, 0.5–3, 3–7, 7+ m/s); `combat_status.ranged` and `ranged.metrics()`.

Offline result (fake game: true bolt 5600 cm/s, −1700 cm/s², 0.1 s straight; Claude seeded with 4000/−980/0; goblin strafing at 3 m/s at 20 m):
- the first 2 shots missed and the next 5 hit;
- the profile converged to 5520 / −1665 / 0.08;
- the goblin died.

## 3. Spells (aimed projectile spells)

- The same aimer applies:
  - `R.read_spell_params(projectile_class)` reads the spell projectile's `InitialSpeed` and `ProjectileGravityScale`;
  - `R.new_aimer("<spell id>", seed)` returns the camera rotation with lead;
  - tracking `DominionSpellProjectile` actors gives the same fit, learning and metrics.
- `spells.lua` (owned by the spells work) currently aims the camera straight at the target point (`W.aim`). That is right for placed spells, but has no drop or lead for projectile spells.
- Contract for it: for an aimed spell that spawns a projectile, call:
  - `ranged.new_aimer(spell_id, ranged.read_spell_params(cls))`;
  - `:observe(t, target_pos)` each tick;
  - `:solve(muzzle, camera)` → rotation;
  - after the cast, `:fired` / `:sample` / `:finish(hit)`.
  Nothing else in spells.lua changes.

## 4. Decisions and Search record (search-before-building)

- **Closed form vs root search:**
  - Forrest Smith's "Solving Ballistic Trajectories" gives the closed form for static targets (a quadratic in tan θ) and a quartic for fixed-speed moving targets, with the author's own warning that the quartic solver is untested and numerically fragile.
  - It has no straight segment (`TimeWithoutGravity`).
  - Our 1-D root search on τ handles the straight segment, lead and both arcs, and is a few hundred evaluations per frame.
  - Source: https://www.forrestthewoods.com/blog/solving_ballistic_trajectories/
- **Engine functions:** `SuggestProjectileVelocity` (start, end, launch speed, gravity override, favour high arc, accept closest) and `SuggestProjectileVelocity_MovingTarget` (gravity only, needs a time to target). Both are reflected, but they model neither the straight segment nor our learned parameters, so they are not used. They remain a cross-check option. Sources:
  - https://dev.epicgames.com/documentation/en-us/unreal-engine/BlueprintAPI/Game/SuggestProjectileVelocity
  - https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/UGameplayStatics/SuggestProjectileVelocity_Moving-
- **Standard practice for moving targets:**
  - Constant-velocity lead: solve for the intercept time, then aim at the predicted point.
  - With gravity, iterate or simulate, cap the simulated time, and score candidates by closest approach. Fitting recorded positions is a cheap alternative.
  - A target that changes velocity after the shot can still dodge it. That is accepted; learning does not chase it, because the bias is capped.
  - Sources:
    - https://gamedev.net/forums/topic/676862-figuring-out-where-a-projectile-will-go
    - https://gamedeveloper.com/programming/predictive-aim-mathematics-for-ai-targeting
    - https://click.gamedev.net/tutorials/programming/math-and-physics/leading-the-target-r4223
- **Decision:** ADAPT (standard intercept-time lead plus simulation-style closest-approach scoring) and BUILD the small solver and fitter in Lua. REUSE the game's own data for the seed, and its inputs for aim and fire.

## 5. Open, live

- Read `ProjectileData`, the charge curves and the full-accuracy flag on the real crossbow, and check the curve semantics (absolute speed or multiplier). Learning corrects either way.
- The muzzle: whether `ProjectileSocketName` on the weapon actor's mesh is readable. Otherwise the weapon actor or pawn location is used, and the bias absorbs the offset.
- Bolts must be in the loadout's CrossbowBolts slot (`HasRequiredAmmoEquipped`). Combat reports `not_enough_resources` (why `no_ammo`) instead of guessing which item is ammo.
- The reflex does not pick ranged weapons by itself yet. The model chooses them with `attack {weapon}`, and a held ranged weapon is kept.
