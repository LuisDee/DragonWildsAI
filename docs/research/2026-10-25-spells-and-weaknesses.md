# Spells, damage types, weaknesses, stun and stat mirroring: what the dump says (build 26161880, 2026-10-25)

This note answers the goals in `docs/design/robustness-and-item-catalog.md` sections 3–4, plus Luis's follow-up request: Tempest Shield, Windstep, weapon enchants, Spectral Arrows, and mirroring his stats and unlocks onto the bot.

**Reference keys**
- `DOM:n` is a line in `dumps/26161880/CXXHeaderDump/Dominion.hpp`.
- `ENUM:n` is a line in `CXXHeaderDump/Dominion_enums.hpp`.
- `O:n` is a line in `dumps/26161880/UE4SS_ObjectDump.txt`.
- `UHT <file>` is a header in `UHTHeaderDump/Dominion/Public/`.

**Confidence levels**
- **HIGH:** read directly from the dump or from a wiki infobox.
- **MEDIUM:** inferred from names, layout or several consistent clues.
- **LOW:** a guess that needs testing.

**Caveat:** the object dump holds only what was loaded when it was taken. No goblin AI character class was loaded (only goblin animation blueprints and journal entries), so goblin data below comes from the journal and the wiki.

---

## 0. Summary

1. **Spells are not on the `BP_PerformAttack` path.**
   - The Tempest Shield and Windstep spells are `UUtilitySpellData` assets made of modules (cast, item cost, gameplay effect, montage). They run through `UPlayerUtilityMagicComponent` on the character.
   - Spell selection lives on `USpellcastingComponent`, which sits on the **PlayerController**.
   - The player's cast reaches the server inside the movement stream, like melee. There is no `Server_Cast*` RPC and no `BP_Perform*` on either magic component.
   - Best server-side entry: **`UDominionRuntimeBlueprintLibrary::TriggerModularAbilityForPlayer(ADominionPlayerCharacter*, const UDominionSpellData*)`**. It takes two object pointers and no structs (DOM:20918, O:73095, UHT `DominionRuntimeBlueprintLibrary.h:74`, BlueprintCallable).
   - Fallback: apply the spell's own gameplay effect with `UDominionGameplayEffectsComponent:InstantiateGameplayEffect(TSubclassOf, nil, false)` (DOM:20369+, O:46777, BlueprintAuthorityOnly). Its arguments are simple; it returns a struct.
2. **Resources are runes, as normal inventory items. There is no mana.**
   - `SpellModule_CostItems.ItemsCostInfo: TArray<FSpellItemCostInfo{UItemData*, int32 Count}>` (DOM:34378, DOM:7229).
   - Wiki costs: Tempest Shield 15 Air; Windstep 5 Air; Spectral Arrows 5 Air + 15 Astral.
   - Cooldowns: `UUtilitySpellData.CooldownDuration` (O:70536), with the last cast time per spell in `UPlayerUtilityMagicComponent.LastCastTimeBySpellData` (DOM:30567, on the **character**).
3. **"Wind Stomp" (the stun on landing) is a separate perk-gated actor.**
   - `BP_PlayerCharacter_C:OnLandedWindstep` (O:218230) checks `IsSkillPerkUnlocked`, then spawns **`/Game/Gameplay/UtilityMagic/PerkSpells/Windstep/BP_WindstepExplosion.BP_WindstepExplosion_C`** (O:213120). That actor applies area damage and force through a `UDelayedDamageInflictionComponent` (DOM: class `UDelayedDamageInflictionComponent`).
   - The perk is `PerkV2_Agility_Spell_Windstep_Upgrade` (O:211540), which the wiki puts at Agility level 40.
   - For the bot, **spawn the explosion directly**: `SpawnActor`, then `DelayedDamageInfliction:StartDelayedDamage(0.0)`. Both calls take simple arguments.
4. **Weaknesses are per enemy, live and readable.**
   - `ADominionAICharacter.AIAttributesComponent` (DOM:9510) → `UAIAttributesComponent.DamageTypeAffinities: TMap<FGameplayTag, EDamageTypeAffinity{Weakness, Resistance, Immunity}>` and `ActiveImmunityTags` (DOM:13553–13560, O:46284–46285).
   - The global multipliers are in the loaded asset **`/Game/Gameplay/AI/DamageClassAndTypeData.DamageClassAndTypeData`** (O:266274; class at DOM:18362). Its fields are `TypeWeaknessAffinity` and `TypeResistanceAffinity` (`TMap<Tag, float>`), and class-level equivalents.
   - Every hit reports `FDominionDamageEvent.TypeDamagesOutcome: TArray<ETypeDamageOutcome{Neutral, Weak, Resistant, Immune}>` (DOM `struct FDominionDamageEvent`, O:119591). This is what the hitsplat colour shows.
5. **Stun/stagger is a hit reaction, not a status effect.**
   - Force thresholds come from `UAIDataAsset.HitReactionConfig` (`LightForceThreshold`, `HeavyForceThreshold`, `KnockDownForceThreshold`, DOM:698–734).
   - The AI then plays a stumble (`UAiHitReactionsComponent:Multicast_Stumble`, `IsStumbling()`; DOM:14759–14761, O:47084, O:47087), or enters a knockdown state that BP code marks with a gameplay tag (`BP_DominionAICharacter_C:OnAIKnockdownState_Begin/End` use `MakeLiteralGameplayTag`, O:218440, O:269220).
   - Poll `AiHitReactionsComponent:IsStumbling()` (BlueprintPure, returns a bool) and read the `GameplayTagsComponent` stacks.
6. **Stats and unlocks live on the PlayerController** (skills, perks, spells unlocked, the selected spell wheel, the rune inventory). Our puppet has an AIController.
   - So: **read Luis's** controller (read-only, safe), keep a mirror in the brain, and pay for spells from a virtual rune budget.
   - Perk checks take a PlayerController (`SkillBlueprintFunctionLibrary:IsSkillPerkUnlocked(PC, Perk)`, DOM:33468). Server-side casts on the puppet will most likely run the **base** spell only, with upgrades off. The bot emulates the upgrades instead (section 5).

---

## 1. Spells

### 1.1 Assets: names and exact paths (HIGH unless marked)

| In-game name | Spell data (cast this) | Effect / actor | Gating perk | Wiki facts |
|---|---|---|---|---|
| **Tempest Shield** | `/Game/Gameplay/UtilityMagic/PerkSpells/TempestShield/USD_TempestShield.USD_TempestShield` (O:250746). Modules: `SpellModule_Cast_0`, `SpellModule_CostItems_1`, `SpellModule_GameplayEffect_0`, `SpellModule_PlayMontage_0` (O:250747–250750) | GE `/Game/Gameplay/UtilityMagic/PerkSpells/TempestShield/GE_TempestShield.GE_TempestShield_C` (O:250719); upgraded `GE_TempestShield_Upgraded_C` (O:250716); expiry burst `BP_TempestShieldExplosion_C` (O:250617, `DelayedDamageInfliction` with a wedge shape, O:250640/250642); visual `BP_TempestShieldActor_C` (O:250481); montage `AM_PlayerM_Sorcery_Spellcast_TempestShield` (O:250722) | `/Game/Gameplay/Character/Player/PerksV2/Attack/PerkV2_Attack_TempestShield` (O:250751) | Attack 11; 15 Air runes; 45 s cooldown; 1 min shield; burst on expiry knocks foes down if the shield is raised ([wiki](https://dragonwilds.runescape.wiki/w/Tempest_Shield)) |
| **Windstep** | `/Game/Gameplay/UtilityMagic/PerkSpells/Windstep/USD_Windstep.USD_Windstep` (O:250469). Modules: `SpellModule_Blueprint_0/1` (graphs `BP_SMBG_WindstepVFX`, `BP_SMBG_WindstepInhibitJumpOnLanding`), `SpellModule_Cast_0`, `SpellModule_CostItems_0`, `SpellModule_GameplayEffect_0`, `SpellModule_PlayMontage_0` (O:250470–250475) | GE `/Game/Gameplay/UtilityMagic/PerkSpells/Windstep/GE_Windstep.GE_Windstep_C` (O:246171). It has child GEs `GE_ModifyJumpHeight`, `GE_ModifyGravityScale`, `GE_ModifyAirControl` and `GE_Modify{Min,Max}FallDamageHeight`/`FallDamageMultiplier` (subobjects of `Default__GE_Windstep_C`, just after O:246171), and is removed on landing by `BP_SpellGERemovalStrategy_Windstep_C`. Montage `AM_PlayerM_Sorcery_Spellcast_Windstep` | `/Game/Gameplay/Character/Player/PerksV2/Runecrafting/PerkV2_Runecraftng_Windstep` (O:250476; the typo is in the asset name) | Agility 5 (the infobox also says 8); 5 Air runes; 3 s cooldown; jump up to 16 m, slow fall, reduced fall damage; 7 s to use it ([wiki](https://dragonwilds.runescape.wiki/w/Windstep)) |
| **Wind Stomp** (Windstep upgrade, the stun) | no spell data; spawned on landing | `/Game/Gameplay/UtilityMagic/PerkSpells/Windstep/BP_WindstepExplosion.BP_WindstepExplosion_C` (O:213120): `DelayedDamageInfliction` (sphere), `ExplosionVFX`, `ExplosionSFX`, `ServerTimeOfCreation` | `/Agility/Gameplay/Character/Player/PerksV2/PerkV2_Agility_Spell_Windstep_Upgrade` (O:211540) | Agility 40; "staggering effect on nearby enemies when the player lands" (wiki) |
| **Jump attack** (weapon slam from the air; *not* Windstep) | `/Game/Gameplay/Character/Player/Spells/Combat/Weapons/DA_Spell_<Weapon>_JumpAttack` (`DominionSpellData`; Sword at O:237852). Modules: `Collision`, `Shape`, `Damage`, `CostStamina`, `LaunchCharacter`, `ExpireOnMovementMode`, `GameplayEffect`, `PlayMontage` (see the Dagger version, O:213248–213263) | action `/Game/Gameplay/Character/Player/Attacks/Sword/PA_Spell_Sword_JumpAttack.PA_Spell_Sword_JumpAttack_C` (O:213271), a `UPlayerSpecificMagicSpellAction` that soft-references the DA. Wired through `UHeldEquipmentData.PrimaryJumpActionClass` (DOM:23739+). Requirement `BP_SpellRequirement_CanExecuteJumpAttack` (ground must not be too close) | `/Game/Gameplay/Character/Player/PerksV2/Attack/PerkV2_Attack_JumpAttack` (O:190235) | MEDIUM: Luis may combine Windstep with this (attack while airborne) |
| **Enchant Weapon** (Fire / Water / Air / Earth) | `/Game/Gameplay/UtilityMagic/PerkSpells/EnchantWeapon/USD_EnchantWeapon_{Fire,Water,Air,Earth}` (O:248097, 248006, 250461, 252698). Modules: `Cast`, `CostItems`, `ExpireAfterDuration`, **`HeldEquipmentEffect`**, `PlayMontage` | `HEED_EnchantWeapon{Fire,Water,Air,Earth}` (Fire at O:239337), class `BP_BaseEnchantWeaponHeldEquipmentEffectData_C : UHeldEquipmentEffectData`. Also `GE_EnchantWeapon_Earth_OnApplyDamage_Data`, `GE_EnchantWeapon_Water_OnFatalHit_Data` | `PerkV2_Attack_EnchantWeapon_{Air,Fire,Water}` (Attack tree); no Earth perk was loaded | Fire: level 20, 15 Fire + 5 Astral, 90 s cooldown, burn on crit. Air: level 30, 15 Air + 5 Astral, attack speed ([PCGamesN](https://www.pcgamesn.com/runescape-dragonwilds/spells), [Destructoid](https://www.destructoid.com/?p=1053074)) |
| **Spectral Arrows** | MEDIUM: `/Game/Gameplay/UtilityMagic/PerkSpells/CorruptionArrows/USD_CorruptionArrows.USD_CorruptionArrows` (O:250810). Modules: `Cast`, `CostItems`, `HeldEquipmentEffect`, `PlayMontage` | `HEED_CorruptionArrows` (O:239486), class `BP_BaseCorruptionArrowsHeldEquipmentEffectData_C`; `GE_CorruptionShot_C` | `/Game/Gameplay/Character/Player/PerksV2/Ranged/PerkV2_Ranged_SpectralArrows` (O:250815, directly after the USD; perks follow their spells in the dump, as with Tempest Shield and Windstep). Confirm by reading `PerkModules[1].SpellData` (Lua index 1, section 4) | Ranged 25; 5 Air + 15 Astral; cooldown 90; 5 min; arrows pierce and **bypass Ranged resistances and immunities**; two-handed bows only; not crossbows ([wiki](https://dragonwilds.runescape.wiki/w/Spectral_Arrows)). Bypassing resistances fits a separate `Corruption` damage type (`UDamageTypeCorruptionMultiplierAttribute`, DOM:18576) |

Runes are `/Game/Gameplay/Items/Resources/Magic/ITEM_Rune_Air.ITEM_Rune_Air` (O:216927, a `MagicAmmoData`, so it also serves as staff ammo) and `ITEM_Rune_Astral` (O:206738). Fire, Water, Earth and Nature runes sit beside them. HIGH.

### 1.2 How a player casts (classes HIGH; flow MEDIUM)

1. **Spell wheel (UI, controller):**
   - `ADominionPlayerController.SpellcastingComponent` (DOM:10224) → `USpellcastingComponent` (DOM:35205).
   - Fields: `SelectedSpells: TArray<UUtilitySpellData*>` (the wheel, O:68327), `NumSpellRadials`, `NumSpellSlotsPerRadial`.
   - RPCs: `Server_UpdateSpellData(Spell, Slot)`, `Server_SwapSpells`, `Server_NotifySpellRadialSelected`, `Server_SpawnSpellPlacementVisualizer` (for placed spells), `Client_CancelSpellcasting`.
2. **Preparation:** `UPlayerUtilityMagicComponent:Server_NotifyPreparingSpell(const UUtilitySpellData*)` (DOM:30570, O:64859; Server, Reliable) sets the replicated `SpellBeingPreparedOrCast: FReplicatedSpellData{bIsAlternativeMontageUnlocked, SpellBeingPreparedOrCastData}` (UHT `PlayerUtilityMagicComponent.h:15`).
3. **The cast itself:**
   - It goes through the action and mover pipeline (`EDomMoverActionTypeIndex::PlayerActions = 8`, ENUM:1374), the same transport as melee in the companion-dump note A.4.
   - The server runs the spell's modules. `UPlayerMagicComponent` keeps `CurrentSpellActor: ADominionSpellActor*` and `SpellCastingActionInstance: TOptional<FPlayerActionInstance>` (DOM:30140–30166).
   - It multicasts `Multicast_SendPayloadForSpellCasting(FDominionDataAssetNetId)` (O:63667). `ADominionSpellActor` (DOM:10462) carries `Data`, `SpellInstance`, `OwningMagicComponent` and `PlayerActionInstance`.
   - Cancel: `Server_CancelSpell()`.
   - **There is no BlueprintCallable "cast" on either magic component.** HIGH (full member list at DOM:30140–30166 and DOM:30564–30573).
4. **Costs:**
   - `SpellModule_CostItems` (runes; `bUseMagicAmmo` for staff ammo; `ItemCostMultiplierAttribute`, e.g. `ATT_WindstepRuneCostMultiplierAttribute`).
   - `SpellModule_CostStamina` (jump attacks), `SpellModule_CostSpecialCharge`.
   - Item costs come out of the **controller's** `InventoryComponent` (DOM:10212). MEDIUM: the component that consumes them was not traced, but no inventory exists on the pawn.
5. **Cooldown:** `UUtilitySpellData.CooldownDuration` (O:70536), optionally changed by `CooldownModifierPerk{CooldownPerk, ModifiedCooldown}` (DOM:8014). Server state is `LastCastTimeBySpellData` (DOM:30567). The client is told through `Client_NotifySpellOnCooldown` (DOM:30572). HIGH.
6. **Cast type:** `UUtilitySpellData.CastType: EUtilitySpellCastType{Instant, Placed, Aimed, AllowMovementThenCastInstant}` (ENUM:3630). Tempest Shield and Windstep are self-cast; the value has to be read (section 4).
7. **Combat magic** (staves and wands) uses `UPlayerPrimaryMagicAttackAction`/`UPlayerSecondaryMagicAttackAction` (DOM:30238, 30518). The spell comes from `UHeldEquipmentData.MagicAttackCollection` → `UPlayerMagicAttackCollection.EquippedMagicAmmoToPrimaryStarterSpell: TMap<UMagicAmmoData*, UDominionSpellData*>` (DOM:30133): the rune loaded as ammo picks the element. Example spells: `/Game/Gameplay/Character/Player/Spells/Combat/{Air,Fire,Water}/DA_Spell_Primary_*` (O:216929–218984).

### 1.3 Server-side cast on the puppet: feasibility and the arguments needed

| # | Path | Arguments | Expected | Risk / confidence |
|---|---|---|---|---|
| A | `UDominionRuntimeBlueprintLibrary::TriggerModularAbilityForPlayer(puppet, spellData)`. Call it on the CDO: `StaticFindObject("/Script/Dominion.Default__DominionRuntimeBlueprintLibrary")` | 2 object pointers, **no structs** | Runs the spell's module graph for that character, as the game itself does for "modular abilities". | MEDIUM that it casts. **Crash risk:** the `CostItems` module may dereference `PC->InventoryComponent`, and for an AIController that PC is null (the same bug class as the `LoadoutComponent` unpossess crash, DISCOVERIES "ROOT CAUSES"). Test first with `DA_Spell_Sword_JumpAttack` (stamina cost only), then with a USD. Perk-gated upgrades (`PerkForUpgradedGameplayEffect`, `SkillPerkRequiredForAlternativeMontage`) will evaluate as not unlocked. |
| B | `puppet.GameplayEffectsComponent:InstantiateGameplayEffect(StaticFindObject(".../GE_TempestShield.GE_TempestShield_C"), nil, false)` (component at DOM:9894) | class, nil, bool; returns `FDominionGameplayEffectHandle` | Applies the shield effect directly. `UTempestShieldGameplayEffectInstance` (DOM:35932) has `TargetCharacter: ADominionPlayerCharacter*` and `MaxHealth`. `UTempestShieldGameplayEffectData` (DOM:35919) has `EffectHealthBase`, `EffectHealthPerAttackSkillLevel`, `EffectDurationInGameTime`, `BlockingRepulseForce` and `ActorClassToSpawnOnExpiry` | MEDIUM. The skill-level lookup for shield health may go through the null PC. Expect either a base-health shield or a crash; the watchdog recovers. No cost and no cooldown are applied (the brain enforces them). |
| C | Windstep, emulated: `InstantiateGameplayEffect(GE_Windstep_C)`, plus `puppet:LaunchCharacter({X=0,Y=0,Z=v}, false, true)`. On landing (poll `CharacterMovement.MovementMode`, or bind the `OnLandedWindstepEvent` delegate on the movement component, DOM:20591), spawn `BP_WindstepExplosion_C` at the feet with Owner = puppet. Then call `DelayedDamageInfliction:StartDelayedDamage(0.0)` (O:52340; BlueprintCallable, one float) | simple | The stun lands on clients through the normal damage and hit-reaction multicasts | MEDIUM. `LaunchCharacter` takes an FVector struct, which UE4SS marshals fine (SpawnActor already takes vectors; the crash was `TArray<FTypeDamage>`). The explosion BP reads `GetOwner()` and `HasAuthority()` (O:213131–213134), so set the owner at spawn. |
| D | Melee-style: `BP_PerformAttack` | n/a | **Not applicable to spells.** Only `UPlayerAttackComponent` subclasses (melee `UPlayerMeleeAttackComponent`, ranged `UPlayerRangedAttackComponent`) have `BP_PerformAttack` (DOM:29322–29341). There is no PlayerSpell or Magic attack component with a `BP_Perform*`. | HIGH |
| E | Enchant on the puppet's weapon | struct write | `UHeldEquipmentItem:ImbueHeldEquipmentEffect(HEED, OwningPC)` (DOM:23860, O:57630) needs a held *item* (the puppet's is nil, DISCOVERIES "Held weapon") and a PC. **Alternative:** write `heldActor.PhysicalHeldEquipmentEffectInfo = {EffectData=HEED_EnchantWeaponFire, ServerExpirationTime=t}` (DOM:11131; struct DOM:3649), then call `OnRep_PhysicalHeldEquipmentEffectInfo(nil)` (O:56593) for the visuals. | LOW that the damage changes (damage probably reads the item instance); MEDIUM for the visuals. A safer way to switch damage type is to equip a weapon with a different `DamageTypes`. |

**`FPlayerActionInstance` fields**, if a spell action is ever driven like melee (DOM:5721, size 0x60): `Data` (the action CDO, e.g. `PA_Spell_Sword_JumpAttack_C` CDO), `ActionGranter: UEquipment*` (nil), `PlayerOwner` (puppet), `EquipmentHand` (1 = Right), `ActionInputType` (0 Primary), `DesiredActionTarget` (enemy). No function takes one for spells; this is listed only for completeness.

---

## 2. Damage types and enemy weaknesses

### 2.1 The system (HIGH)

- **Damage class** (one per hit): `EDamageClass {None, Melee, Magical, Ranged}` (ENUM:1067).
- **Damage types** (gameplay tags, several per hit): `FTypeDamage {EStatusEffectType StatusEffect; FGameplayTagContainer Types; float Amount}` (DOM:7842).
  - The tag names are not in the dump.
  - The per-type incoming multiplier attributes name the set: **Stab, Slash, Crush, Ranged, Air, Water, Earth, Fire, DragonFire, Corruption** (`UDamageType<X>MultiplierAttribute`, DOM:18572–18628).
  - Outgoing multipliers exist for Air, Burn, Earth, Fire and Water.
  - Class resistances: `UMeleeResistance`, `UMagicResistance`, `URangedResistance`.
  - Status resistances: `UFireResistance`, `UPoisonResistance`, `UBleedingResistance`, `UShockResistance`, `UDrainResistance`.
- **Status effects:** `EStatusEffectType {Poison, Burning, Bleeding, Shock, Starvation, Dehydration, Toxicity, Scorch}` (ENUM:3382).
- **Per-enemy affinity:**
  - `UAIAttributesComponent.DamageTypeAffinities: TMap<FGameplayTag, EDamageTypeAffinity>` (DOM:13556); `EDamageTypeAffinity {Weakness, Resistance, Immunity}` (ENUM:1095).
  - Runtime changes use `OverrideDamageTypeAffinity(Tag, Affinity)` / `ResetDamageTypeAffinity(Tag)` (O:46290) and GE `UDamageTypeAffinityModifierGameplayEffectData{DamageType, Affinity}` (DOM:18561).
  - The Kalphite Guardian's colour-changing shade, which "blocks one damage type" ([wiki](https://dragonwilds.runescape.wiki/w/Kalphite_Guardian)), is almost certainly this mechanism or `ActiveImmunityTags`. **Weapon choice against a Guardian must read the live map, not the table.** MEDIUM.
- **Global multipliers:** asset `/Game/Gameplay/AI/DamageClassAndTypeData.DamageClassAndTypeData` (O:266274), class `UDamageClassAndTypeData` (DOM:18362):
  - `ClassWeakness`, `ClassResistance: TMap<EDamageClass, EDamageClass>`
  - `ClassWeaknessAffinity`, `ClassResistanceAffinity: TMap<EDamageClass, float>`
  - `TypeWeaknessAffinity`, `TypeResistanceAffinity: TMap<FGameplayTag, float>` (the multipliers to use in scoring)
  - `DamageTypeAttributeData` / `OutgoingDamageTypeAttributeData` / `DamageReceiverTypeAttributeData: TMap<Tag, UDominionAttributeData*>`
- **Per-hit result:** `FDominionDamageEvent.TypeDamagesOutcome: TArray<ETypeDamageOutcome {Neutral, Weak, Resistant, Immune}>` (ENUM:3587), plus `AmountAbsorbedByShield` and `ModifierMessageTags`. This lets the bot learn weaknesses from hits.
- **Receiver-type bonuses** (attacker-side attributes): `UDamageModifierReceiverType{Demon, Dragon, Mage, Spectral, Undead, Wolf}` and `UDamageModifierRecieverTypeKalphite` (DOM:18493–18517; note the "Reciever" typo).
  - Example: `GE_Keris_DamageModifierReceiverTypeKalphite` (O:222698). **The Keris dagger has a Kalphite damage bonus.** The weapon scorer should include receiver-type GEs from the weapon's data.
- **World difficulty sliders:** `DA_DS_<Faction>_{Damage,Health,Resistances}` (e.g. `/Game/Gameplay/DifficultySettings/AI/CategoryScaling/Kalphite/DA_DS_Kalphite_Resistances`, O:171992; goblin version at O:171919). These scale a whole faction; they are not type-specific. MEDIUM.
- **Damage modifiers:** `UDamageComponent.DamageModifiers: TArray<UDamageModifier*>` (DOM:18376+, O:46497). These are per-target data assets with `ModifyDamage(...)`.

### 2.2 How a weapon's damage type is defined (HIGH)

- **`UHeldEquipmentData.DamageTypes: FGameplayTagContainer`** (DOM:23739+, O:56668): the weapon's base types. Also `DamageMultiplier`, `AdditionalDamageMultiplier`, `BaseHeldEquipmentPowerLevelRowHandle`, `bAssignDamageTypesToLaunchedProjectiles`, `AmmoType`.
- **Attack data** (`UPlayerAttackData`, DOM:29344): `DamageAmount`, `DamageClass`, `bUsesWeapon`, `bHasOverrideWeaponDamageTypes` + `OverrideWeaponDamageTypes`, `Force` (feeds stun thresholds), `TimedDamageShapes`, `GameplayEffectsToApply`. **A special move can change the type.**
- **Spells:** `SpellModule_Damage.DamageTypes`, `DamageClass`, `DamageAmount`, `Force` (DOM:34421, O:68581). The jump-attack variant is `SpellModule_DamageByEquipment` (it uses the weapon's types).
- **Enchants and arrow spells:** `UHeldEquipmentEffectData.AdditiveDamageTypes`, `AdditionalDamageTypes`, `AdditiveDamageMultiplier`, `ForceMultiplier`, `GameplayEffectToApplyOnHit` (DOM:23799). Enchant Fire, for example, adds the Fire type plus burning.
- **Staff magic:** the element is chosen by the loaded rune ammo (section 1.2, item 7).
- Our catalog (`mod/scripts/catalog.lua`) already reads `DamageClass` and `DamageAmount` from attack CDOs. It should add `DamageTypes`, `OverrideWeaponDamageTypes` and `Force` (tag names via `TagName`).

### 2.3 Kalphites and goblins

| Enemy | Class / data in this build | HP | Wiki (weak / resist) | Confidence |
|---|---|---|---|---|
| Kalphite Worker | `/UmbralSands/Gameplay/AI/Kalphite_Faction/Kalphite_Worker/BP_AI_KalphiteWorker_Character.BP_AI_KalphiteWorker_Character_C` (O:269602); journal `/UmbralSands/UI/JournalData/Entries/World/Factions/JOURNAL_World_Factions_KalphiteWorker` (O:244923) | 495 (PL7) | Weak: none listed. Resist: Crush, Slash, Stab, Range, Air, Water ([wiki](https://dragonwilds.runescape.wiki/w/Kalphite_worker)) | wiki HIGH; game values unread |
| Kalphite Soldier | `.../Kalphite_Soldier/BP_AI_KalphiteSoldier_Character_C` (O:269203); journal O:244921. Acid-spit poison `GE_Poison_KalphiteSoldier_AcidSpit` | 825 (PL7) | same resist list; spawns at night ([wiki](https://dragonwilds.runescape.wiki/w/Kalphite_soldier)) | wiki HIGH |
| Kalphite Guardian | `.../Kalphite_Guardian/BP_AI_KalphiteGuardian_Character_C` (O:270264); journal O:244919. Acid cloud and melee poison GEs; `BP_VFX_KalphiteGuardianOverlayManager` (the shade colour) | 2475 (PL7) | same list. Shade: red blocks melee, blue blocks magic, green blocks ranged ([wiki](https://dragonwilds.runescape.wiki/w/Kalphite_Guardian)) | wiki HIGH; the mechanism is MEDIUM |
| Goblins (Runt, Grunt, Bruiser, Shooter) | journals `/Game/UI/JournalData/Entries/World/Factions/JOURNAL_World_Factions_Goblin_{Bruiser,Grunt,Runt,Shooter}` (O:243044–243047); **no goblin AI class loaded** | Runt 60; a Goblin Warrior has 140 at PL2 (Brynmoor) and 490 at PL6 (Dowdun Reach) | **Fire** weakness (Bruiser on the wiki; Runt/Warrior/Bruiser per [gamever](https://gamever.io/knowledge-base/every-enemy-weakness-in-dragonwilds-all-83-sorted-by-damage-type)); one source says the Runt journal reads "Weak: Magic, Air; resists Ranged" ([gamever bestiary](https://gamever.io/knowledge-base/the-journal-press-j-dragonwilds-hidden-bestiary-and-every-enemy-weakness), [metaforge](https://metaforge.app/runescape-dragonwilds/database/creatures-npcs/goblin-runt), [wiki Goblin Bruiser](https://dragonwilds.runescape.wiki/w/Goblin_Bruiser)) | MEDIUM (sources disagree; read the journal in game) |

**Reading the Kalphite rows**
- The wiki gives the same six resistances for all three Kalphites and lists no weakness.
- That leaves **Fire, Earth, Corruption and DragonFire not resisted**. Spectral Arrows (Corruption, if section 1.1 is right) bypass Ranged resistance.
- That fits Luis's experience that Windstep, whose stun works by force and not by damage type, is strong against Kalphites. MEDIUM.
- Treat this as provisional until the in-game journal (`UJournalEntryWorldData.Weaknesses: TArray<FText>`, DOM:25716, O:59897) and the live `DamageTypeAffinities` are read (section 4).

HP scales with power level and player count (`Curve_AIMaxHealthPerPlayerNeaby`, `UAIDataAsset.HealthMultiplayerScalingOverride`/`HealthPowerLevelScalingOverride`, DOM:13748+). Read live `HealthComponent.MaxHealth`; do not rely on table values.

---

## 3. Stun and stagger: how it is applied and detected

- **Applied by force.**
  - Every damage event carries `Force` (attack data, spell module, `DelayedDamageInfliction.Force` at O:52323, held-effect `ForceMultiplier`).
  - The target compares it against `FAiHitReactionConfig` (in `UAIDataAsset.HitReactionConfig`, DOM:698; property O:46626): `LightForceThreshold`, `HeavyForceThreshold`, `KnockDownForceThreshold`, `IncomingForceReductionWhileAttacking`, `DamageOutcomeForceMultipliers: TMap<ETypeDamageOutcome, float>` (**hitting a weakness adds force**), `LightStunImmunityTag`, `bCanStumble`, and the stun-breaker values (`StunBreakerAIActions`, `MaxStunBreakerValue`, `StunBreakerValueIncreasePerHitReaction`, ...).
  - Forces map to `EHitReactionForce {Minimum, Light, Heavy, KnockDown}` (ENUM ~2007).
  - Rows come from `HitReactionsDataTable` (`FHitReactionsDataTableRow{bWasParried, bStumble, bAlreadyKnockedDown, HitForce, ...}`, DOM:3751).
  - Parries add `ParriedTags` for `ParriedTagsDuration`. HIGH for the fields; MEDIUM for the exact pipeline.
- **Three observable states:**
  1. **Stumble** (the stagger state): `ADominionAICharacter.AiHitReactionsComponent` (DOM ~9520 `0x0BA8`) → `IsStumbling()` (BlueprintPure, O:47087). It is entered through `Multicast_Stumble(FDominionDamageEvent, bool)` (O:47084). **Reflex: poll `IsStumbling()`, or hook `Multicast_Stumble` and read only `self`.** HIGH that these exist.
  2. **Knockdown:** `BP_DominionAICharacter_C:OnAIKnockdownState_Begin/End` (O:218440); Kalphite overrides at O:269220. It sets a literal gameplay tag in the actor's `GameplayTagsComponent` (`ReplicatedGameplayTagStackContainer.Stacks[].Tag/StackCount`, DOM:23200). **Reflex: hook `OnAIKnockdownState_Begin`/`_End` (no parameters), which is the cleanest signal.** MEDIUM-HIGH.
  3. **Additive flinch:** `IsPlayingAdditiveHitReaction()` and `UHitReactionsComponent:IsPlayingHitReaction()` (DOM:23941+). It does not interrupt the enemy.
- **Other crowd control:** `GE_Rooted_C` (`UAIDataAsset.bCanBeRooted`, `RootedDurationMultiplier`), Confuse (`GE_Confuse_C`, `ConfuseRequirements`), slow/hamstrung status GEs. `UAIDataAsset.PlayerSpellImmunities` lists the spells an enemy ignores (DOM:13748+).
- **Staggered bonus:** `UStaggeredTargetDamageModifierAttribute` (DOM:35433) is a player attribute (Heavy T3 set bonus) that increases damage against staggered targets. So "stagger" is a recognised target state. MEDIUM.
- **Tag names:** the dump does not contain the tag strings. Get them at runtime by dumping `Stacks[].Tag.TagName` on an enemy while Luis knocks it down (experiment X2).

---

## 4. Property-read recipe: `data/enemies_<build>.json` (Lua, UE4SS)

**Rules**
- Read properties only.
- Call only functions whose arguments are nil, objects, numbers or bools: `GetComponentByClass`, `GetSkillLevel(obj)`, `IsStumbling()`, `GetCDO()`.
- Never pass a Lua table to a struct or array parameter (that is what crashed `PredictDamage`; DISCOVERIES).
- Wrap everything in `pcall`, cap loops, and write crumbs to the log before each risky step, so a crash dump can be tied to the step (same pattern as `catalog.lua`).

Reuse the helpers from `mod/scripts/catalog.lua`: `try`, `valid`, `opath`, `str`, `num`, `get`, `each`, `tag`, `tags`, `row`, `softref`.

```lua
-- mod/scripts/enemies.lua  (sketch; run through debug_run {module="enemies", fn="run"})
local AFF = { [0] = "Weakness", "Resistance", "Immunity" }       -- EDamageTypeAffinity (ENUM:1095)
local CLS = { [0] = "None", "Melee", "Magical", "Ranged" }        -- EDamageClass (ENUM:1067)

-- TMap read. UE4SS experimental supports TMap:ForEach(k, v); guard it anyway.
local function each_map(m, fn, cap)
    local n = 0
    pcall(function() m:ForEach(function(k, v)
        n = n + 1; if n > (cap or 128) then return true end
        fn(unwrap(k), unwrap(v)) end) end)
end

local function affinities(ai)
    local out, imm = {}, {}
    local ac = get(ai, "AIAttributesComponent")                    -- DOM:9510
    if not valid(ac) then return out, imm end
    each_map(get(ac, "DamageTypeAffinities"), function(k, v)        -- DOM:13556
        local t = tag(k); if t then out[t] = AFF[num(v)] or num(v) end
    end)
    imm = tags(get(ac, "ActiveImmunityTags"))                       -- FGameplayTagContainer
    return out, imm
end

local function attributes(ac)            -- UDominionAttributesComponent (DOM:19806)
    local out = {}
    local vals = {}; each(get(ac, "AttributeValues"), function(v) vals[#vals + 1] = num(v) end)
    local i = 0
    each(get(ac, "FloatAttributes"), function(a)                    -- UFloatAttribute (DOM:22799)
        i = i + 1
        local data = get(a, "AttributeData")                        -- UDominionAttributeData
        local name = str(get(data, "DevName")) or opath(a)
        -- keep only damage-relevant ones: DamageType*Multiplier, *Resistance, DamageModifier*
        if name and (name:find("Damage") or name:find("Resist")) then
            out[name] = { base = num(get(a, "BaseValue")), current = vals[i] }
        end
    end, 512)
    return out
end

local function enemy_record(ai)           -- ai: a live ADominionAICharacter (or a CDO)
    local r = { class = opath(try(function() return ai:GetClass() end)) }
    local hc = get(ai, "HealthComponent")                           -- UAiHealthComponent
    r.max_hp = num(get(hc, "MaxHealth")); r.hp = num(get(hc, "AuthoritativeHealth"))
    r.power_level = num(get(ai, "PowerLevel"))
    r.ai_data_class = softref({ soft = true }, get(ai, "AIDataClass"), true)
    local d = get(ai, "LoadedData")                                 -- UAIDataAsset (DOM:13748)
    if valid(d) then
        r.name = str(get(d, "AIName"))
        r.tags = tags(get(d, "GameplayTags"))                       -- receiver type (Kalphite, Undead...)
        r.damage_multiplier = num(get(d, "DamageMultiplier"))
        r.hp_row = row(get(d, "AIDataTableRowHandle"))              -- FAIDataTableRow.MaxHealth (table, row only)
        local hr = get(d, "HitReactionConfig")                      -- FAiHitReactionConfig (DOM:698)
        r.stun = { can_stumble = bool(get(hr, "bCanStumble")),
                   light = num(get(hr, "LightForceThreshold")),
                   heavy = num(get(hr, "HeavyForceThreshold")),
                   knockdown = num(get(hr, "KnockDownForceThreshold")),
                   stun_immunity_tag = tag(get(hr, "LightStunImmunityTag")) }
        r.can_be_rooted = bool(get(d, "bCanBeRooted"))
        r.spell_immunities = tags(get(d, "PlayerSpellImmunities"))  -- a container: read .GameplayTags
    end
    r.affinity, r.immune_tags = affinities(ai)
    r.attributes = attributes(get(ai, "AIAttributesComponent"))
    return r
end

-- Global multipliers (one per build)
local function global_table()
    local g = StaticFindObject("/Game/Gameplay/AI/DamageClassAndTypeData.DamageClassAndTypeData")
    local out = { type_weak = {}, type_resist = {}, class_weak = {}, class_resist = {} }
    if not valid(g) then return out end
    each_map(get(g, "TypeWeaknessAffinity"),   function(k, v) out.type_weak[tag(k) or "?"] = num(v) end)
    each_map(get(g, "TypeResistanceAffinity"), function(k, v) out.type_resist[tag(k) or "?"] = num(v) end)
    each_map(get(g, "ClassWeaknessAffinity"),  function(k, v) out.class_weak[CLS[num(k)] or k] = num(v) end)
    each_map(get(g, "ClassResistanceAffinity"),function(k, v) out.class_resist[CLS[num(k)] or k] = num(v) end)
    return out
end

-- Journal: human-readable weaknesses, keyed by the AI data class they unlock on
local function journal()
    local out = {}
    for _, j in ipairs(FindAllOf("JournalEntryWorldData") or {}) do
        local w = {}; each(get(j, "Weaknesses"), function(t) w[#w + 1] = str(t) end)   -- TArray<FText>
        local uc = get(j, "UnlockCondition")
        out[#out + 1] = { entry = opath(j), name = str(get(j, "DisplayName")), weaknesses = w,
                          power_level = num(get(j, "PowerLevel")),
                          ai_data = softref({ soft = true }, get(uc, "AIData"), true) }
    end
    return out
end

function M.run(log)
    local doc = { build = 26161880, global = global_table(), journal = journal(), enemies = {} }
    local seen = {}
    for _, ai in ipairs(FindAllOf("DominionAICharacter") or {}) do    -- live, scaled values
        local rec = enemy_record(ai)
        local key = rec.class .. "@" .. tostring(rec.power_level)
        if not seen[key] then seen[key] = true; doc.enemies[#doc.enemies + 1] = rec end
    end
    -- write doc as JSON to <repo>/data/enemies_26161880.json via jsonutil
end
```

**Notes on the recipe**
- **Run it where the enemies are.** `FindAllOf` only sees spawned or loaded actors, so ask Luis to stand among Kalphites, and separately near goblins. The JSON merges by class across runs. Class CDOs (`cls:GetCDO()`) give the authored defaults; live actors give the scaled values. Record both when available.
- Join journal and enemy rows on `ai_data.path == enemy.ai_data_class.path`. Both are soft class paths to the AI data asset (DOM `FJournalEntryUnlockCondition.AIData`, DOM:13748 `ADominionAICharacter.AIDataClass`).
- **Spell table (same pass, `data/spells_<build>.json`):** for each `FindAllOf("UtilitySpellData")`, read:
  - `SpellDisplayName`, `CooldownDuration`, `CastType`, `OwningPerk`
  - for each `Modules` entry, its class name and fields: `CostItems.ItemsCostInfo[] {ItemData, Count}`, `GameplayEffect.GameplayEffect/UpgradedGameplayEffect/PerkForUpgradedGameplayEffect`, `HeldEquipmentEffect.HeldEquipmentEffectData → AdditiveDamageTypes`, `Damage.DamageTypes/Force/DamageAmount`
  - The path is `spell.Modules.Modules[i].Module`: `FDominionSpellModulesContainer{TArray<FDominionSpellModuleWrapper> Modules}` (DOM:2762), where each wrapper is `{UDominionSpellModule_Static* Module}` (DOM:2756).
- For Spectral Arrows, confirm the mapping with `StaticFindObject("/Game/Gameplay/Character/Player/PerksV2/Ranged/PerkV2_Ranged_SpectralArrows.PerkV2_Ranged_SpectralArrows").PerkModules[1].SpellData` (`USkillPerkModule_Spell.SpellData`, DOM:33724).
- **Learning on the fly:** register a hook on `/Script/Dominion.DamageComponent:BP_OnDamageReceived` (O:46577) **only if** it fires for native damage (to test), or on `AiHitReactionsComponent:Multicast_Stumble`. From the damage-event parameter, read `TypeDamagesOutcome` and `TypeDamagesArray.TypeDamages[].Types`. This reads a struct and does not pass one, which is the safe direction. Merge every "Weak" or "Resistant" result into the enemy table as `observed`.

---

## 5. Stat and unlock mirroring (Luis's request: the bot should have his spells and levels)

### 5.1 Where things live (HIGH)

| Data | Owner | Member |
|---|---|---|
| Skill XP and levels | **PlayerController** (`ADominionPlayerControllerBase.SkillComponent`, DOM:10359) | `USkillComponent.Skills: TArray<FSkill{CurrentXP, SkillData}>` (DOM:33472, O:67695); `GetSkillLevel(USkillData*)` (O:67723); `DamageModifierRate`, `CalculateDamageModifier(Skill)` |
| Perks (incl. spell perks, Wind Stomp, Jump Attack) | **PC** `SkillPerkComponent` (DOM:10220) | `SkillPerkRuntimeStates: TArray<FSkillPerkRuntimeState{AssociatedSkill, ActivePerkDatas[], Perks[]}>` (DOM:33636, O:67897); `IsPerkUnlocked(USkillPerkData*)` (O:67902); static `SkillBlueprintFunctionLibrary:IsSkillPerkUnlocked(PC, Perk)` (O:67680) |
| Spells unlocked | **PC** `ProgressComponent` (DOM:10215) | `SpellsUnlocked: TSet<UUtilitySpellData*>` (O:73365); `IsSpellUnlocked(Spell)` (O:73427); `UnlockSpells(TArray)` |
| Spell wheel (what he has slotted) | **PC** `SpellcastingComponent` | `SelectedSpells: TArray<UUtilitySpellData*>` (O:68327) |
| Journal unlocks | **PC** `JournalComponent` | not traced; `ProgressComponent.AIsKilledOnce: TSet<FString>` is a proxy for "has met this enemy" |
| Runes (the only spell resource) | **PC** `InventoryComponent` (DOM:10212) and the loadout | item stacks of `ITEM_Rune_*` |
| Cooldowns | **Character** `PlayerUtilityMagicComponent` (DOM:9907) | `LastCastTimeBySpellData: TMap<USD*, float>` |
| Attributes and active effects | **Character** `AttributesComponent` / `GameplayEffectsComponent` (DOM:9893–9894) | perk stat buffs arrive here as GEs (`USkillPerkModule_GameplayEffect`) |
| PlayerState | `ADominionPlayerState` (DOM:10401) | identity only (GUID, colour, display name). **No stats.** |

### 5.2 Can the server copy them onto the puppet?

- **Not directly.** HIGH.
  - Every store above except cooldowns and attributes is a component **on the PlayerController**.
  - The puppet is possessed by a plain AIController, and a server-spawned `DominionPlayerController` never becomes ready (companion-dump note A.5).
  - Dominion code reads `PC->X` without null checks (the `LoadoutComponent` crash).
  - Perk checks are keyed on a PC (`IsSkillPerkUnlocked(PC, ...)`), so for the puppet they return false, or crash if a path dereferences the null PC.
- **Bypass.** MEDIUM.
  - A server-side cast through `TriggerModularAbilityForPlayer` or `InstantiateGameplayEffect` most likely skips the *unlock* gate. That gate sits in the UI and spell-wheel path (`SpellcastingComponent`, `ProgressComponent.IsSpellUnlocked`).
  - It does **not** turn on perk-gated *upgrades*: `SpellModule_GameplayEffect.PerkForUpgradedGameplayEffect`, `SpellModule_PlayMontage.SkillPerkRequiredForAlternativeMontage`, Wind Stomp in `OnLandedWindstep`.
  - Skill-scaled numbers (Tempest Shield `EffectHealthPerAttackSkillLevel`, attack damage `DamageModifierRate`) will use level 0/1, or crash on a null skill component.
- **What can be copied** (character-side, HIGH that writes are possible; MEDIUM that the game honours them):
  - Attribute base values on the puppet's `AttributesComponent` (`FloatAttributes[i].BaseValue`, then `OnRep_AttributeValues`).
  - Perk stat GEs, by applying each `USkillPerkModule_GameplayEffect.GameplayEffectsToApply` class from Luis's active perks onto the puppet with `InstantiateGameplayEffect`.

### 5.3 Recommended design

1. **Mirror read-only.**
   - On `ClientRestart` and every few minutes (event-driven, cheap), read Luis's PC: `Skills` → levels via `GetSkillLevel`, `ActivePerkDatas`, `SpellsUnlocked` (or `IsSpellUnlocked(USD)` per known spell), `SelectedSpells`, rune counts.
   - Write `state/mirror_luis.json`. The brain only offers spells he has unlocked; Luis's request is the policy.
2. **Emulate the upgrades** from the mirror:
   - Wind Stomp → spawn `BP_WindstepExplosion_C` on landing, if Luis has `PerkV2_Agility_Spell_Windstep_Upgrade`.
   - Upgraded Tempest Shield → apply `GE_TempestShield_Upgraded_C` instead of `GE_TempestShield_C`.
   - Jump attack → only if `PerkV2_Attack_JumpAttack` is unlocked.
3. **Copy perk stat GEs** onto the puppet once at spawn (step 2 of experiment X6). This gives approximately his passive bonuses.
4. **Costs and cooldowns in the brain:**
   - A virtual rune pouch seeded from Luis's counts, or from a "give the bot N runes" command that removes them from Luis with `TakeItemAmountFromPlayer(LuisPC, ITEM_Rune_Air, n)`. That is a static library function with simple arguments (UHT `DominionRuntimeBlueprintLibrary.h:80`), and it keeps the game fair.
   - Cooldown values come from `CooldownDuration` in `data/spells_<build>.json`.
5. **Skill-scaled values:** pass Luis's levels into our own formulas, e.g. shield HP = `EffectHealthBase + EffectHealthPerAttackSkillLevel × AttackLevel`. Then write `UTempestShieldGameplayEffectInstance.MaxHealth` after instantiation if the game used level 0. LOW–MEDIUM; to test.

---

## 6. Ranked in-game experiments (all through `debug_run`; the watchdog must be running)

| # | Experiment | Needs Luis | Risk | What it settles |
|---|---|---|---|---|
| X1 | **Read-only dumps**: `enemies.run` (section 4) near Kalphites, then near goblins; `spells.run` (all `UtilitySpellData` modules); `mirror.run` (Luis's PC: skills, perks, `SpellsUnlocked`, `SelectedSpells`, runes); read `PerkV2_Ranged_SpectralArrows.PerkModules[1].SpellData` | stand near the enemies | very low (reads only) | HP, affinities, global multipliers, journal weaknesses, spell costs and cooldowns, the Spectral Arrows asset, the mirror data |
| X2 | **Hook-only observation**: register hooks on `PlayerUtilityMagicComponent:Server_NotifyPreparingSpell`, `PlayerMagicComponent:Multicast_SendPayloadForSpellCasting`, `DominionMovementComponent:OnLandedWindstep` (if reflected as a function; otherwise `BP_PlayerCharacter_C:OnLandedWindstep`), `AiHitReactionsComponent:Multicast_Stumble`, `BP_DominionAICharacter_C:OnAIKnockdownState_Begin/End`, and `DamageComponent:BP_OnDamageReceived` (log only `TypeDamagesOutcome` and the type tag names). Luis casts Tempest Shield, then Windstep onto a Kalphite group, then hits with two weapon types. Also dump the enemy's `GameplayTagsComponent` stacks during the knockdown. | yes, about 3 min | low | the real cast path on the server, the stun tag names, observed weak/resist results |
| X3 | **Wind Stomp emulation**: spawn `BP_WindstepExplosion_C` at a Kalphite's feet with Owner = puppet (also try Owner = Luis's pawn for kill credit), then `DelayedDamageInfliction:StartDelayedDamage(0.0)`. Verify `IsStumbling()` or the knockdown hook on the targets. | yes, to see it | low–medium | the stun reflex primitive |
| X4 | **Tempest Shield via GE**: `puppet.GameplayEffectsComponent:InstantiateGameplayEffect(GE_TempestShield_C, nil, false)`, then read `ReplicatedInstances` for the `UTempestShieldGameplayEffectInstance` and its `MaxHealth`/`TargetCharacter`. Let a Kebbit hit the blocking puppet. | yes, for visuals | medium (possible null-PC crash) | the shield primitive without casting |
| X5 | **`TriggerModularAbilityForPlayer`**: first `(puppet, DA_Spell_Sword_JumpAttack)` after `LaunchCharacter` upward (stamina cost, no runes); then `(puppet, USD_TempestShield)`; then `(puppet, USD_Windstep)`. | yes | medium–high (CostItems → null PC inventory) | whether real casts work on the puppet, with montage and VFX for free |
| X6 | **Mirror perks onto the puppet**: for Luis's `ActivePerkDatas`, apply each `USkillPerkModule_GameplayEffect.GameplayEffectsToApply` to the puppet; diff the puppet's attribute values before and after. | no | low–medium | how close a stat mirror can get |
| X7 | **Weapon enchant on the held actor**: write `PhysicalHeldEquipmentEffectInfo {EffectData=HEED_EnchantWeaponFire, ServerExpirationTime=now+60}`, call `OnRep_PhysicalHeldEquipmentEffectInfo(nil)`, swing at a dummy, check `TypeDamagesOutcome` and the types through the X2 hook. If the damage type does not change, fall back to swapping weapons. | yes, for the glow | medium (struct write on an actor; not a function argument) | whether enchant type-switching is possible for the bot |
| X8 | **Spectral Arrows**: depends on a ranged puppet (`UPlayerRangedAttackComponent:BP_PerformAttack`); same approach as X7 with `HEED_CorruptionArrows` | yes | medium | lowest priority |

Before X4/X5/X7, write a crumb to the log so a crash dump can be tied to the step. Each one is a single call per `debug_run`.

---

## Sources

- Dump: `dumps/26161880/` (CXXHeaderDump `Dominion.hpp`, `Dominion_enums.hpp`, UHTHeaderDump `Dominion/Public/*.h`, `UE4SS_ObjectDump.txt`); line references inline.
- [Dragonwilds wiki: Windstep](https://dragonwilds.runescape.wiki/w/Windstep) · [Tempest Shield](https://dragonwilds.runescape.wiki/w/Tempest_Shield) · [Spectral Arrows](https://dragonwilds.runescape.wiki/w/Spectral_Arrows) · [Kalphite Worker](https://dragonwilds.runescape.wiki/w/Kalphite_worker) · [Kalphite Soldier](https://dragonwilds.runescape.wiki/w/Kalphite_soldier) · [Kalphite Guardian](https://dragonwilds.runescape.wiki/w/Kalphite_Guardian) · [Goblin Bruiser](https://dragonwilds.runescape.wiki/w/Goblin_Bruiser)
- [PCGamesN: spells](https://www.pcgamesn.com/runescape-dragonwilds/spells) · [Destructoid: spells](https://www.destructoid.com/?p=1053074) · [gamever: every enemy weakness](https://gamever.io/knowledge-base/every-enemy-weakness-in-dragonwilds-all-83-sorted-by-damage-type) · [gamever: journal bestiary](https://gamever.io/knowledge-base/the-journal-press-j-dragonwilds-hidden-bestiary-and-every-enemy-weakness) · [gamever: region scaling](https://gamever.io/knowledge-base/dragonwilds-enemies-scale-to-the-region-not-to-you-here-are-the-numbers) · [metaforge: Goblin Runt](https://metaforge.app/runescape-dragonwilds/database/creatures-npcs/goblin-runt)
