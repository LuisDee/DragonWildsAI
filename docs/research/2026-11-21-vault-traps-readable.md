# Vault traps: what the game lets the client read (dump study, 2026-11-21)

Offline only: no code changed, nothing run live, no API spend. The question comes from CLAUDE.md section 2 rule 4 ("visibility before a second fix"): before any trap-crossing behaviour, can the game's own state for a vault trap (where it hurts, when it fires) be read on Claude's headless client, through property reads (section 4)?

Sources:
- `dumps/26670300/`: the CXX header dump (`CXXHeaderDump/*.hpp`), the UHT header dump with the UPROPERTY specifiers (`UHTHeaderDump/Dominion/Public/*.h`), and the object dump (`UE4SS_ObjectDump.txt`).
- The live census of probe run 20261119-063427 (`logs/evals/vault_probe/20261119-063427_enter.json`, path `/census80/hazards`).
- Existing code: `client_mod/scripts/sense.lua` (`describe_trap` 993-1007, the hazards pass at 1191, the notes at 848-849), `combat.lua` (`evade_window` 2973-2999, the server clock at 5666), `hazard_profiles.lua`, `ground_hazards.lua`, `avoidzones.lua`.
- Docs: `docs/DISCOVERIES.md` (3384 dodge window, 1521 server clock, 2194 the fxguard audit list, 3687 the Crasorak probe), `docs/research/2026-11-17-vault-reads.md`, `docs/research/2026-11-21-vault-prep.md` (wiki and video facts on traps, which this note does not repeat).
- The wiki pages Spike Trap, Fire Trap, Fire Jet and Burning (dragonwilds.runescape.wiki, read 2026-11-21).

Line numbers below are for `dumps/26670300` unless another file is named. "CXX" means `CXXHeaderDump/Dominion.hpp`, "UHT X.h" means `UHTHeaderDump/Dominion/Public/X.h`, and "OBJ" means `UE4SS_ObjectDump.txt`.

## 0. Short answer

- **Timing is data, not hidden logic.** A vault trap is an `AAnimatingTrap`. Its cycle is a `UTrapTimelineEventData` asset: a length in seconds, plus events, each with `EventTime`, `DeactivationTime` and the indices of the behaviour modules it switches on (CXX 36678-36683, 7831-7838). The trap can be locked to world time (`bSyncWithWorldTime`, with a play rate and an offset: CXX 8897-8900). Two of its timing fields replicate: `RuntimeTimelineOffset` and `PausedReplicatedTime` (UHT AnimatingTrap.h 84-88). All of these are plain properties.
- **Where a trap hurts is data too.** A `UTrapDamageInflictionModule` holds a `UDominionShape_*` (box `Extents`, sphere `Radius`, capsule `Radius` and `HalfHeight`), a `DamageOriginComponent`, a `DamageEndpointOffset` and a `DamageCheckInterval` (CXX 36628-36644, 21138-21184).
- **Whether the client holds live values is not answered by the dump.** Only the two timeline fields above, the module array pointer and the movement module's server time are marked `Replicated`. The rest are either edit-time data, which the client loads from the same level and assets (readable if the objects exist there), or `Transient` runtime state such as `bActive` and `CurrentTrapAnimationTime`. That state is only filled on the client if the client runs the trap itself. The replicated offset fields and the movement module's latency-compensation fields strongly suggest it does. That is inference.
- **One live hint is against the module route.** The 26 trap rows of probe 20261119-063427 carry no `parts` or `active_parts`. `describe_trap` found **zero** modules whose `bActive` read as a boolean. The array may be empty on the client, or these older "v1 / v2 / DEPRECATED" Blueprints may not use modules at all.
- **The concrete trap Blueprints are not in any dump.** `BP_Trap_Magic_Bolt_v1_C` and `BP_DEPRECATED_Trap_Spike_v2_C` appear in none of the three object dumps (26161880, 26574459, 26670300). Their Blueprint variables (timelines, components) are unknown.
- **The dodge roll is invulnerable**, from 0.15 to 0.75 s after it starts. This was measured live (DISCOVERIES 3384) from `AnimNotifyState_Invulnerability_C`, which adds `GE_Invulnerable_Evade_C`. **Whether trap damage respects that invulnerability is not in the dump.**

## 1. Which classes are the vault traps

### 1.1 Seen live (probe 20261119-063427, Crasorak Kara, census 80 m)

| Live class (census `class`) | `UserReadableName` | Count | Positions (m, `position`) |
|---|---|---|---|
| `BP_Trap_Magic_Bolt_v1_C` | "Trap Magic Bolt v1" | 9 | Two stacked pairs at the same XY, 1 m apart in Z: (-1699.95, 1039.49, z -430.11 and -431.11) and (-1704.45, 1039.49). A row at Y 1020.48: X -1706.81, -1707.81, -1708.81, -1709.81 (1 m pitch), plus -1715.31 |
| `BP_DEPRECATED_Trap_Spike_v2_C` (actor ids still begin `BP_Trap_Spike_v2_C_UAID_...`, so the class was renamed after the actors were placed) | "DEPRECATED Trap Spike v2" | 17 | A grid at a **4.0 m pitch** in X and Y. Group A: X -1695.8 to -1707.9, Y 992.4 and 996.4, z -431.1. Group B: X -1724.31 to -1732.31, Y 1042.48 to 1050.48, z -429.11. Plus (-1715.81, 1014.68) |

- The DISCOVERIES 3687 summary writes "Magic Bolt v1". The game's own name is "Trap Magic Bolt v1".
- None of the three levers in range drives a trap. Their `drives` lists hold only `BP_SwitchableDoor_Vault_4x4_C` and `BP_FinalDoor_vault_C` (`logs/window_probe_1119n.txt` line 16). So these traps are probably free-running and not lever-gated. That fits the wiki's "rhythmic" spear traps and the timed fire traps.
- **What "Magic Bolt" is: inference.** The Crasorak walkthrough has "3 fire traps in a hall", and the wiki's Fire Trap page shows a Crasorak image and says the player is "struck by a fireball or blast", which applies Burning. The census within 80 m holds only these two trap classes. So "Magic Bolt v1" is very likely the wiki's Crasorak "fire trap", a wall launcher. The asset `NS_MagicBolt_Impact_Poison` under `/Game/Art/VFX/Library/Env/Vault_Traps/` (OBJ 270882 area, index assets) suggests magic-bolt traps come in element variants. Not verified: confirm by the status on the first hit (vitals `damage` row).

### 1.2 Native class chain (what FindAllOf can use)

| Class | Native base | Where |
|---|---|---|
| `ASwitchableActor` | `AWorldActor` | CXX 12497-12508; UHT SwitchableActor.h 8-9 (Abstract) |
| `ASwitchableTrap` | `ASwitchableActor` | CXX 12547-12563; OBJ 48360; UHT SwitchableTrap.h 14-15 |
| `AAnimatingTrap` | `ASwitchableTrap`, `IDeathInstigator` | CXX 8883-8918; OBJ 48382; UHT AnimatingTrap.h 19-20 (Abstract) |
| `AAnimatingTrapAgilityFireBallLauncher` | `AAnimatingTrap` (agility course; fires an `AAgilityProjectile`) | CXX 8920-8933, 8569; OBJ 48437 |
| `UTrapBehaviourModule` (Abstract, EditInlineNew) | `UObject` | CXX 36610-36617; OBJ 70302; UHT TrapBehaviourModule.h 6-7 |
| `UTrapDamageInflictionModule` | `UTrapBehaviourModule` | CXX 36628-36644; OBJ 70307 |
| `UTrapCollisionModule` | `UTrapBehaviourModule` | CXX 36619-36626; OBJ 70354 |
| `UTrapMovementModule` | `UTrapBehaviourModule` | CXX 36646-36667; OBJ 70322 |
| `UInterpMovementModule`, `USplineMovementModule`, `UInteractableSwitchMovementModule` | `UTrapMovementModule` | CXX 24793, 35585, 24701 |
| `ULightBeamEmitterModule` | `UTrapBehaviourModule` (light-beam puzzles) | CXX 26204 |
| `UTrapTimelineEventData` | `UDataAsset` | CXX 36678-36683; OBJ 70387 |
| `UTrapSubsystem` | `UTickableWorldSubsystem` | CXX 36669-36676; OBJ 70377 |
| `UDamageInflictionComponent` | `USceneComponent` | CXX 18600-18613 |
| `UDominionShape` + `_Box`, `_Sphere`, `_Capsule`, `_Arc`, `_Wedge` | `UObject` | CXX 21138-21184 |

- Both live trap classes derive from `AAnimatingTrap`: **inferred, strongly**. `UserReadableName` read on both (the census `name`), and that property is declared only on `AAnimatingTrap` (CXX 8885). `U.prop` reads only properties the live class chain declares (`mod/body/util.lua` 184, `client_mod/tests/test_prop_guard.lua`). The existing pass finds them with `FindAllOf("SwitchableTrap")` (sense.lua 1191).
- Damage effects in the game data (Blueprints, loaded): `GE_Damage_FireTraps_C : UDominionStatusEffectData` (OBJ 183856; `GE_Damage_FireTraps.hpp` 4), `GE_AddBurn_FireTraps_C : UDominionGameplayEffectData` with a `BurnAmount` float (OBJ 214072; `GE_AddBurn_FireTraps.hpp` 6), `GE_Damage_StaticSpikes_C` (OBJ 192315), and `GE_Slow_StaticSpikes_C` (OBJ 222367). Their default values (damage, burn amount) are CDO data and are not in the headers.
- Other vault-trap assets present: `SM_Vault_2m_Lane_01` under `Vault_Traps/Vault_Lane` (OBJ 270882), the exploding-plant meshes under `Vault_Traps/Exploding_Plant_Trap_01`, and the sound concurrency `DungeonTrapsGeneric_SC`. The one exploding-plant actor class in the dump, `BP_Plant_Explosive_CorpseCotton_FromRavannasRing_C`, is a plain `AActor` with a `UDelayedDamageInflictionComponent` (`BP_Plant_Explosive_CorpseCotton_FromRavannasRing.hpp` 4, 19, 24 `HasExploded`). It is not a vault trap class and is out of scope here.

## 2. Properties and functions that say when and where a trap fires

R = `Replicated`/`ReplicatedUsing` in UHT. E = edit-time data (level or asset), present on the client wherever the object exists. T = `Transient` runtime state, filled only where the code runs.

### 2.1 On the trap actor (`AAnimatingTrap`, CXX 8883-8918; UHT AnimatingTrap.h)

| Property | Type | Rep | Meaning (from the name and type; native code not seen) | CXX | UHT |
|---|---|---|---|---|---|
| `UserReadableName` | FText | E | Display name ("Trap Magic Bolt v1") | 8885 | 24-25 |
| `TrapDamage` | `FTrapDamage {DamageAmount f, DamageClass, DamageTypes tags, DamageForce f}` | E | **HP per hit** and its damage types | 8886; struct 7822-7829 | 27-28 |
| `SyncToleranceSecs` | float | E | How far the client's timeline may drift before it resyncs (implies client-side simulation) | 8887 | 30-31 |
| `CurrentAnimationTime` | float | - (not Transient, not R) | Current animation position | 8888 | 33-34 |
| `CurrentTrapAnimationTime` | double | - | **Current position in the trap timeline** (the phase) | 8889 | 36-37 |
| `TelegraphTimeOffset` | float | E | Warning lead before activation (the wiki's "glow yellow briefly before activating"; semantics unverified) | 8890 | 39-40 |
| `MovementDirection`, `MovementOffsetMinMax` | FVector, FVector2D | E | Spike travel axis and range | 8891-8892 | 42-46 |
| `TrapTimelineEventData` | `UTrapTimelineEventData*` | E | **The cycle** (section 2.2) | 8896 | 57-58 |
| `TrapTimelinePlayRate`, `TrapTimelineOffset` | double | E | Timeline speed and phase shift | 8897-8898 | 60-64 |
| `bFinishTimelineWhenDeactivated` | bool | E | | 8899 | 66-67 |
| `bSyncWithWorldTime` | bool | E | **Timeline locked to world time** | 8900 | 69-70 |
| `AnimationVectorCurve` | `UCurveVector*` | T | Spike height over the cycle | 8901 | 72-73 |
| `bUseLegacySequencerComponent` | bool | E | Old sequencer route (the "v1/v2" traps may use it) | 8902 | 75-76 |
| `ActorSequenceComponent` | `UActorSequenceComponent*` | E (Instanced) | The legacy route's sequence | 8895 | 54-55 |
| `RuntimeTimelineOffset` | float | **R** | Server-set phase offset sent to clients | 8905 | 84-85 |
| `PausedReplicatedTime` | float | **R** (OnRep) | The time at which the trap was paused | 8906 | 87-88 |

On `ASwitchableTrap` (CXX 12547-12563; UHT SwitchableTrap.h):

| Property | Type | Rep | CXX | UHT |
|---|---|---|---|---|
| `bInverseTrapActivation` | bool | E | 12549 | 19-20 |
| `TrapBehaviourModules` | `TArray<UTrapBehaviourModule*>` | **R** (Instanced) | 12550 | 22-23 |
| `TrapActiveVFXComponents`, `TrapActiveMeshComponents` | `TArray<UNiagaraComponent*>`, `TArray<UMeshComponent*>` | T | 12552, 12554 | 28-35 |
| `bTrackedComponentIsMoving` | bool | T | 12560 | 52-53 |

On `ASwitchableActor` (CXX 12497-12508): `TickRange` (12499) and `SwitchableTickType` (`ESwitchableTickType`: NeverTick 0, ActiveAndInRange 1, InactiveAndInRange 2, TickWhenInRange 3, AlwaysTick 4; `Dominion_enums.hpp` 3445-3452). There is **no on/off property**. On/off is only through the functions `IsSwitchableActive()` and `GetSwitchPosition()` (UHT SwitchableActor.h 30-34: BlueprintPure, const, no arguments).

Functions on the trap: `SetDamageEnabled(bool)` (CXX 8908; a write, never call), `OnRep_PausedReplicatedTime()`, `OnHitBoxBeginOverlap/EndOverlap(...)` (CXX 8911-8912; struct arguments, never call), `GetTrapTimelineEventData()` (BlueprintNativeEvent, UHT 111-112; use the property instead), and `GetComponentsToMove(TArray&)` / `GetComponentsToVertexAnimate(TArray&)` (BlueprintImplementableEvent, out-param arrays; avoid).

### 2.2 The cycle (`UTrapTimelineEventData`, CXX 36678-36683; UHT TrapTimelineEventData.h 13-20)

| Property | Type | Rep | Line |
|---|---|---|---|
| `TrapTimelineLength` | double (s) | E (asset) | CXX 36680; UHT 13-14 |
| `TrapTimelineEvents` | `TArray<FTrapTimelineEvent>` | E | CXX 36681; UHT 16-17 |
| `AnimationVectorCurve` | `UCurveVector*` | E | CXX 36682 |

`FTrapTimelineEvent` (CXX 7831-7838; UHT TrapTimelineEvent.h 10-23):
- `EventType`: `ETrapEventType`, BlueprintEvent 0 or ModuleActivation 1 (`Dominion_enums.hpp` 3546-3550).
- `EventTime` (double).
- `FunctionName` (FName).
- `DeactivationTime` (double).
- `ModuleIndexes` (`TArray<int32>`).

**So each danger window is `[EventTime, DeactivationTime]` of a ModuleActivation event whose `ModuleIndexes` name the damage module, repeating every `TrapTimelineLength`.** A data asset is loaded on the client like any asset. If the pointer reads, the schedule reads.

### 2.3 The modules (`TrapBehaviourModules[i]`)

`UTrapBehaviourModule` (CXX 36610-36617; UHT TrapBehaviourModule.h 11-21): `bShouldEverTick` E, `bActive` **T, not replicated** (UHT 14-15), `bInitialized` T, `bReplicates` T (UHT 20-21: whether the module replicates is decided at run time).

`UTrapDamageInflictionModule` (CXX 36628-36644; UHT TrapDamageInflictionModule.h 19-56; **nothing replicated**):

| Property | Meaning | CXX |
|---|---|---|
| `DamageInflictionComponent` (`UDamageInflictionComponent*`) | `DamageAmount`, `DamageCooldown`, `DamageClass`, `OnDamagedGameplayEffects`, `DamageForce` (CXX 18602-18608) | 36631 |
| `DamageOriginComponent` (`USceneComponent*`) | Where the damage starts | 36633 |
| `DamageEndpointOffset` (FVector) | Where it ends: a **line** for a bolt or jet | 36634 |
| `DamageShape` (`UDominionShape*`) | The area: `Offset`, `Pivot`, `Scale`, `RotationOffset` (21140-21144), plus `_Box.Extents` (21160), `_Sphere.Radius` (21173), `_Capsule.Radius/HalfHeight` (21166-21167), and `_Arc`/`_Wedge` fields | 36636 |
| `DamageCheckInterval` (float) | Seconds between damage checks while active | 36637 |
| `bApplyStatusEffectBuildUp`, `TrackedStatusEffectType` (`ETrackedStatusEffect`: Burning 3, Slow 5; `Dominion_enums.hpp` 3524-3531), `TrackedStatusEffectBuildUpAmount` | Burn or slow build-up per check | 36638-36640 |
| `CurrentTime`, `LastDamageShapeLocation` | T | 36641-36642 |

`UTrapMovementModule` (CXX 36646-36667; UHT TrapMovementModule.h 16-74), for the spikes going up and down:
- E fields: `bRequiresActivationToMove`, `MovementBehaviour` (`EInterpToBehaviourType`: OneShot 0, OneShot_Reverse 1, OneShot_Reset 2, PingPong 3, Loop_Reset 4; `Engine_enums.hpp` 1729-1736), `MovementDuration` (36653), `HoldEndpointDuration` (36654), `ReplicationFrequency`, `LatencyCompensationScale`.
- T fields: `MovementProgress` (36656), `ElapsedMovementTime`, `bReversing`.
- **R:** `ServerElapsedMovementTime` (36661; UHT 55-56, ReplicatedUsing). This and `LatencyCompensationScale` mean the client runs the movement itself and is corrected from the server.

`UTrapCollisionModule` (CXX 36619-36626): `CollisionComponents`, `DefaultCollisionType`, `bEnableCollisionOnActivate`.

### 2.4 The trap subsystem and the clock

- `UTrapSubsystem` (CXX 36669-36676; UHT TrapSubsystem.h 15-28): `TrapDamageCooldown` (Config float: the minimum time between two trap hits on one actor), `ActorTrapData` (`TArray<FActorTrapData {Actor, OverlappedTraps}>`, CXX 490-495, T: who stands in which trap; probably server-only), and `OnBeginOverlap/OnEndOverlap(trap, actor)` (never call).
- **Server clock:**
  - `AGameStateBase.ReplicatedWorldTimeSecondsDouble` (R, Engine.hpp 10336; UHT Engine GameStateBase.h 35-36).
  - `ServerWorldTimeSecondsDelta` (Engine.hpp 10337).
  - `GetServerWorldTimeSeconds()` (Engine.hpp 10348). It takes no arguments and is already called live in `combat.lua` 5666 (DISCOVERIES 1521, 3151).
  - The move and avoid-zone clock is `GameplayStatics:GetRealTimeSeconds` (avoidzones.lua 15). A schedule in server time therefore needs an offset (server minus real) taken at read time.

### 2.5 What a player sees, as a fallback signal

`TrapActiveVFXComponents[i]` / `TrapActiveMeshComponents[i]`: `UActorComponent.bIsActive` (Engine.hpp 11882; UHT Engine ActorComponent.h 52-53, ReplicatedUsing, but only if the component replicates), plus `bVisible` / `bHiddenInGame` on scene components. If the client toggles the trap's flame or spike visuals, these flip at the burst. That is the same cue a player sees. Unverified on a `-nullrhi` client.

## 3. Safe reads and risky calls

The vault-trap classes live in streamed cells, so R17 applies (vault-reads.md 58). Every read goes through `U.prop`. Objects are found again on every pass and never cached across a teleport (R16). Native classes are never freed, so their property layout is fixed.

| Read | Kind | Risk |
|---|---|---|
| Every actor property in 2.1, `TrapTimelineEventData` -> `TrapTimelineLength`, `TrapTimelineEvents[i].*` (struct array, read like `combat.lua` 2984 reads `Notifies`), module fields in 2.3, `DamageShape` subclass fields, `DamageInflictionComponent.*`, `UTrapSubsystem.TrapDamageCooldown`, `GameStateBase.ReplicatedWorldTimeSecondsDouble`, components' `bIsActive` / `bVisible` | **Property read** | Low (the hazard_profiles kind) |
| `GameStateBase:GetServerWorldTimeSeconds()` | Function, **no arguments** | Low: in live use (`combat.lua` 5666) |
| `comp:K2_GetComponentLocation()` on `DamageOriginComponent` | Function, no arguments | Low: used on PoisonEmitterBox (`ground_hazards.lua` 99-100) |
| `trap:IsSwitchableActive()`, `trap:GetSwitchPosition()` | Function, no arguments, BlueprintPure | Low to medium: **never called on a trap yet**. Try it on one trap first |
| `GetTrapTimelineEventData()` | Function, no arguments, BlueprintNativeEvent | Not needed: read the property |
| `GetComponentsToMove(TArray&)`, `GetComponentsToVertexAnimate(TArray&)` | **Out-param array** | **Higher: do not call** |
| `SetDamageEnabled(bool)`, `ActivateSwitchable(bool)`, `DeactivateSwitchable(bool)` | **Writes** | **Never** |
| `OnHitBoxBeginOverlap(...)`, `UTrapSubsystem:OnBeginOverlap(trap, actor)`, `UDamageInflictionComponent:InflictDamage(actor)` | **Arguments, struct or actor, server logic** | **Never** |

Two further risks:
- **Native crash.** DISCOVERIES 2194 lists `ASwitchableTrap` among the classes to check first if a null-VFX crash appears on the `-nullrhi` client. That is the fxguard audit list (`client_mod/scripts/fxguard.lua` 26-37 guards only the player pawn's map). The 063427 probe stood 38-70 m from the traps for a few seconds without a crash. Standing next to an animating trap on this client has never been tried.
- **Struct reads.** `FTrapDamage`, `FTrapTimelineEvent` and `FVector` are read field by field (`ss.SwitchPosition` style, sense.lua 978). They are never passed back into a call (R15: struct userdata inside Lua table params).

## 4. The dodge roll

- **It grants invulnerability, measured live:**
  - The window is 0.15-0.75 s after the roll starts (DISCOVERIES 3384), read from `pawn.EvadeComponent.DefaultAnimationSet.*Montage` -> `Notifies` by `combat.lua` `evade_window` (2973-2999).
  - The dump agrees. `AM_PlayerM_Dodge_Roll_Fwd/_Bck/_Lf/_Rt` and `AM_PlayerM_Dodge_Hop_Bck` each carry four `AnimNotifyState_Invulnerability_C` (OBJ 188392-188395, 188465-188468, 192283-192286, 191251-191254, 188214-188217). The four are probably one per equipment section: inference.
  - The Surge rolls carry it too (OBJ 211458, 211471, 211484, 211497), as does the air dash (OBJ 192327).
  - `UAnimNotifyState_Invulnerability_C : UAnimNotifyState_AddGameplayEffect` (`AnimNotifyState_Invulnerability.hpp` 4; base CXX 15223-15228: `EffectData`, `EffectDataToApplyAfterNotify`) applies a gameplay effect for the notify's span. The evade one is `GE_Invulnerable_Evade_C : GE_Invulnerable_C` (OBJ 172552, 172548; `GE_Invulnerable_Evade.hpp` 4).
  - The damage side is `UPlayerDamageComponent.InvulnerableEvadeTag` / `InvulnerableTags` (CXX 29790-29791; UHT PlayerDamageComponent.h 23-27). DISCOVERIES 3384 records the tag name "Player.Status.Invulnerable.Evade" and that it does not read on the client.
  - `EDamageProperties` has `Evaded = 8` and `Invulnerable = 128` (`Dominion_enums.hpp` 1083-1091), so a damage event records that it was dodged.
  - `ADominionPlayerCharacter` has a separate `TeleportInvulnerabilityLength` / `LoadInvulnerabilityLength` (CXX 9902-9903).
- **Rolling shortens burning.** `UPlayerEvadeComponent.ReduceBurningAmount` and `NoBurningReductionTags` (CXX 29984-29985) match the wiki's "duration can be reduced by dodge rolling" (Burning page). That matters after a fire-trap hit.
- **Rolling state on the client:** `EvadeComponent:IsEvading()` (CXX 29999; UHT PlayerEvadeComponent.h 157-158, BlueprintPure, no arguments, used live by `combat.lua` `my_evading`). `bMovementBlocked` is replicated (UHT 111-112). The evade input is `IA_Player_Evade` (DISCOVERIES 1208). There is no roll when over the carry weight (DISCOVERIES 3384).
- **Not in the dump:** whether trap damage checks the invulnerable tag. The trap path is overlap, then `UTrapSubsystem`, then `UDamageInflictionComponent`, or a status-effect GE. A status build-up (`TrackedStatusEffectBuildUpAmount`, burn) may skip the tag. Sources disagree: the wiki's Shock Ray page says "dodging into the trap negates the damage", while a video says acid pools hurt through a roll (vault-prep.md, section 4). **This is decided only by a live trial.**

**What the body needs to read to roll through a burst:**
1. The trap's next danger window in server time: section 2.2 (`EventTime`, `DeactivationTime`, `TrapTimelineLength`), the phase (2.1 `CurrentTrapAnimationTime`, or the world-time formula from `bSyncWithWorldTime`, `TrapTimelinePlayRate`, `TrapTimelineOffset`, `RuntimeTimelineOffset`, `PausedReplicatedTime`), and `GetServerWorldTimeSeconds()`.
2. The damage area: shape, origin, endpoint (2.3) and his capsule's position.
3. His roll: invulnerable 0.15-0.75 s, 2.15 m neutral or 4.85 m directional (DISCOVERIES 3384), and the stamina cost (20 per dodge per the wiki; `UEvadeStaminaCost`, CXX 22229).
4. The latency: actions are server-validated (DISCOVERIES 74), ping about 50 ms (DISCOVERIES 1439).

The roll is pressed so that `[press + 0.15 + L, press + 0.75 + L]` covers the time he is inside the shape while it is active, and the roll **ends outside the shape**. Damage is overlap-based and re-checked every `DamageCheckInterval`, so standing in the area when the window closes means a hit. When the gap between bursts (`TrapTimelineLength` minus the active span) is longer than the crossing time (width over speed; sprint 580 cm/s, DISCOVERIES 3384), walking through the gap needs no roll. That case is the existing avoidzones "wait outside" verdict with a known end.

## 5. Draft data rows for `hazard_profiles.lua` (data only, NOT applied)

Keys in the file's existing shape keep their meaning (file header lines 3-20). Keys marked `NEW` have **no reader yet**: `ground_hazards.lua` would need a module walk, a shape read and a schedule (a periodic zone: `avoidzones.lua` has only `circle` and `cone`, lines 14-26). `dps` stays nil because the file takes only MEASURED rates (line 15).

```lua
-- DRAFT from docs/research/2026-11-21-vault-traps-readable.md: field names from dump 26670300; NEW keys have no reader.
-- The trap cycle, shared by every AAnimatingTrap (CXX 8883-8918, 36678-36683, 7831-7838; UHT AnimatingTrap.h 84-88):
local TRAP_SCHEDULE = {                                         -- NEW
    sync = "bSyncWithWorldTime", rate = "TrapTimelinePlayRate", offset = "TrapTimelineOffset",
    runtime_offset = "RuntimeTimelineOffset",                   -- replicated
    paused = "PausedReplicatedTime",                            -- replicated
    phase = { "CurrentTrapAnimationTime", "CurrentAnimationTime" }, -- tried in order (client value unverified)
    timeline = "TrapTimelineEventData",                         -- -> length / events below (a data asset)
    length = "TrapTimelineLength", events = "TrapTimelineEvents",
    event_on = "EventTime", event_off = "DeactivationTime", event_modules = "ModuleIndexes",
    event_kind = "EventType", activation_kind = 1,              -- ETrapEventType.ModuleActivation
    clock = "GetServerWorldTimeSeconds",                        -- GameStateBase, no args (combat.lua 5666)
}
-- The damage area, on the TrapBehaviourModules element of this class (CXX 36628-36644, 21138-21184):
local TRAP_AREA = {                                             -- NEW
    modules = "TrapBehaviourModules", module = "TrapDamageInflictionModule",
    shape = "DamageShape", box = "Extents", sphere = "Radius", capsule = { "Radius", "HalfHeight" }, scale = "Scale",
    origin = "DamageOriginComponent", endpoint = "DamageEndpointOffset", interval = "DamageCheckInterval",
}

{ name = "vault_spike_floor", class = "AnimatingTrap", match = "Trap_Spike",   -- NEW match: pattern on the class name
  area = TRAP_AREA, schedule = TRAP_SCHEDULE,
  move = { duration = "MovementDuration", hold = "HoldEndpointDuration", progress = "MovementProgress",
           behaviour = "MovementBehaviour" },                   -- NEW: UTrapMovementModule (CXX 36646-36667)
  radius_default = 283,  -- prior: a 4 m tile's half-diagonal (tiles 4.0 m apart in census 20261119-063427)
  telegraph = "TelegraphTimeOffset", ttl_default = 1.0, standing = true,
  damage = { "TrapDamage", "DamageAmount" },                    -- NEW: HP per hit (FTrapDamage, CXX 7822-7829)
  status = "Slow",                                              -- NEW: GE_Slow_StaticSpikes (OBJ 222367); unverified
  words = "spike floor",
  effect = "spikes rise from the floor tiles in a cycle (the tiles glow just before); standing on one when they rise hurts again and again",
  -- dps: not measured. Wiki: "continually take damage". life: a trap lasts for ever, so no `life`.
},
{ name = "vault_bolt_trap", class = "AnimatingTrap", match = "Trap_Magic_Bolt",
  area = TRAP_AREA, schedule = TRAP_SCHEDULE,
  line = { origin = "DamageOriginComponent", endpoint = "DamageEndpointOffset" }, -- NEW: the danger is a segment
  radius_default = 150,  -- prior only: width of the bolt's path, unmeasured
  telegraph = "TelegraphTimeOffset", ttl_default = 1.0, standing = true,
  damage = { "TrapDamage", "DamageAmount" },
  status = "Burning",    -- NEW: UNVERIFIED that Magic Bolt v1 is the wiki's fire trap; confirm on the first hit
  words = "bolt trap",
  effect = "a wall launcher that fires bolts across the hall in bursts; a hit may set you burning",
  -- dps: not measured. Wiki Burning: 8 HP/s for 6 s. Confirm from vitals.jsonl before setting it.
},
```

The `effect` text is shown to the model, so it must be true before it ships. Confirm the bolt's status and the spikes' slow on the first live hits.

## 6. Read-only live probe plan (for later; not run)

**Where:**
- The dev world, from a named world (rule 9): `tools\stop_server.ps1 -Hold`, `tools.world_snapshot restore base --confirm`, `tools\start_server.ps1`, `tools\client_boot.ps1 -Target dev` with `DW_TELEPORT_HOOKS=1`.
- **On a fork, never ClaudeDev:** `tools.vault_probe enter --confirm` makes `ClaudeV<ddHHMMSS>` from ClaudeDev's save (read only), switches to it, and switches back before releasing the lock.
- No brain, no model calls, spend 0.

**What to add (offline, later):**
- A read-only command `client_mod/commands/trap_probe.lua`, run through `tools/client_cmd.sh`. It does property reads through `U.prop` and only the no-argument calls of section 3.
- An offline test in the style of `client_mod/tests/test_prop_guard.lua` before it goes live.
- The `vault_probe` `enter` step would run it right after the jump settles. The traps are 38-70 m from the arrival point, and the census already reaches them, so no walk is needed.
- The Hulk at 10 m on arrival still triggers the 20 m abort, so stage 2's sampling must fit before it, or stage 2 runs from a dev-fixture teleport to a spot 8-10 m from spike group A with no hostile within 20 m (option B).

**Stages, each its own window, stopping at the first surprise:**

| Stage | What it reads | Per trap | Pass |
|---|---|---|---|
| 1. Static, one sample | All of 2.1, `TrapTimelineEventData` -> length and every event, module count and each module's class, `bShouldEverTick`, `bReplicates`, `bInitialized`; damage module: shape class and fields, `DamageEndpointOffset`, `DamageCheckInterval`, `TrackedStatusEffectType`/`BuildUpAmount`, `DamageOriginComponent:K2_GetComponentLocation()`, `DamageInflictionComponent.DamageAmount/DamageCooldown`; movement module E fields; `UTrapSubsystem.TrapDamageCooldown` | id, class, position | It answers **why 063427 saw no modules**: the array is empty, unreadable, or present |
| 2. Sampling at 10 Hz for 12 s (at least 2 cycles of any length up to 6 s) | `GetServerWorldTimeSeconds()`, `GetRealTimeSeconds`, `CurrentTrapAnimationTime`, `CurrentAnimationTime`, `RuntimeTimelineOffset`, `PausedReplicatedTime`, each module's `bActive`, movement `MovementProgress`/`ElapsedMovementTime`/`ServerElapsedMovementTime`/`bReversing`, `bTrackedComponentIsMoving`, VFX/mesh components' `bIsActive`/`bVisible` | Up to 6 traps (3 spikes, 3 bolts), nearest first | The phase advances on the client and wraps at `TrapTimelineLength`. `(t_server + RuntimeTimelineOffset) * rate + offset mod length` (a guessed formula) predicts it within 0.1 s. `bActive`, progress or VFX flip at `EventTime`/`DeactivationTime` |
| 3. One no-argument call | `IsSwitchableActive()` and `GetSwitchPosition()` on **one** trap, then all | | No crash, and the value matches stage 2 |
| 4. Ground truth (a trial, not read-only) | Stand at the edge of one spike tile through one cycle; vitals.jsonl `damage` rows (`sense.read_damage`: source class, status) | | Every hit falls inside a computed window. The status (Slow or Burning) and HP per hit are recorded |
| 5. The roll (a trial) | A directional roll timed to the window across one tile; `IsEvading()` frames; damage rows | | Answers whether trap damage respects `GE_Invulnerable_Evade` |

**What to log:**
- One line per trap and stage: `[DWClient] trap_probe <id> class=<c> len=<s> events=<n> mods=<n> sync=<b> rate=<r> off=<o> rt_off=<o> phase=<s> shape=<kind>:<size>`.
- Full rows to `client_io/out/trap_probe.json`, copied to `logs/evals/vault_probe/<run>_traps.json`.
- One row in `logs/evals/vault_probe.jsonl` with the step, the run id, `prop_guard` counters, and a crash or abort.

**Abort:** the vault_probe rules (hostile within 20 m, health under 0.6, a fall). Also abort on any `prop_guard.errors > 0` or `stale > 0`. A stage that met a fight is void (rule 3).

**A cheaper first step:** a UE4SS object dump on the fork client while it stands inside the vault. That would load `BP_Trap_Magic_Bolt_v1_C` and `BP_DEPRECATED_Trap_Spike_v2_C`, giving their Blueprint variables, their components and their module subobjects (with level defaults) in one shot. It is offline-readable and answers stage 1 without new Lua. The cost: a game-thread stall of some seconds with a Hulk near, so it goes on the disposable fork only.

## 7. What the dump does not answer

1. **The trap Blueprints themselves.** `BP_Trap_Magic_Bolt_v1_C` and `BP_DEPRECATED_Trap_Spike_v2_C` are in no dump. Unknown: whether they use modules or the legacy sequencer or Blueprint timelines, their timeline asset, their shape, and their damage numbers.
2. **Client-side values.** Whether `TrapBehaviourModules` holds anything on the client: 063427 found no readable `bActive`. Whether the Transient phase and `bActive` are filled there. Only the replication flags are known.
3. **The phase formula.** How `bSyncWithWorldTime`, `TrapTimelinePlayRate`, `TrapTimelineOffset`, `RuntimeTimelineOffset` and `PausedReplicatedTime` combine is native code, not in headers.
4. **What `TelegraphTimeOffset` means:** a lead before activation, or something else.
5. **Whether trap damage or status build-up respects the dodge's invulnerability.**
6. **Numbers.** Damage per hit, burn per hit, spike slow, `DamageCheckInterval`, `TrapDamageCooldown` (CDO and level values, not headers).
7. **Whether "Magic Bolt v1" is the wiki's fire trap** (inferred), and whether its bolt is a projectile actor or a module line (the agility launcher variant fires projectiles; CXX 8920-8933).
8. **Whether `IsSwitchableActive()` is safe on a trap** (never called).
9. **Whether VFX components on a `-nullrhi` client flip `bIsActive` at a burst.**
