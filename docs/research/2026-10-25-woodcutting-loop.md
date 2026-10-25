# Woodcutting loop: "chop trees until you have 4 stacks of oak logs, then drop them at my feet" (build 26161880, 2026-10-25)

Research only. Nothing was run in game and nothing outside this file was changed. Every claim carries a confidence tag and a source.

Source key:
- `DOM:n` = `dumps/26161880/CXXHeaderDump/Dominion.hpp` line n (`ENUM:n` = `Dominion_enums.hpp`, `BP:Name` = `CXXHeaderDump/Name.hpp`).
- `UHT:File.h` = `dumps/26161880/UHTHeaderDump/Dominion/Public/File.h` (carries the UFUNCTION flags the CXX dump lacks).
- `O:n` = `dumps/26161880/UE4SS_ObjectDump.txt` line n. The object dump lists classes, default objects and asset names. It has **no property values**.
- `CAT` = `data/items_26161880.json` (equipment only; it has no resource items such as logs).
- `DISC` = `docs/DISCOVERIES.md`. `wiki` = dragonwilds.runescape.wiki, fetched today.
- Confidence: HIGH = read directly from the dump or verified in game. MED = strong inference from names, signatures and wiki. LOW = guess that needs an experiment.

---

## 0. Summary (the answers that matter)

1. **Trees are foliage until something needs them.** The world's trees are instanced-static-mesh foliage (`BP_InteractableFoliageISMC_Tree_C` components named after the mesh, e.g. `SM_FH_Oak_Tree_01`). The game converts an instance to a real `AFellableTree` actor on demand (`UInteractableFoliageFunctionLibrary::Convert*`). A cheap "find oaks" is therefore a read of the ISM components plus a conversion call near the bot, not `FindAllOf` on actors alone. HIGH for the structure, MED for the cost.
2. **The oak is a class, not a data flag.** `ABP_FellableTree_Oak_C` and six BP subclasses. Yew and Maple trees inherit from the *Ash* class, so test "is oak" against the Oak class, never "not Ash". HIGH.
3. **Chopping is a melee attack by the axe.** The axe's primary action is `PA_Attack_Hatchet` (attack `BP_Player_Axe_Woodcut1`, "Chop") and its special is `PA_Attack_Hatchet_Special` (`BP_Player_Axe_Woodcut2`, "Overhead Chop"). The puppet already swings the sword through `PlayerMeleeAttackComponent:BP_PerformAttack` and did damage; the same call with the hatchet pair is the first thing to try. Whether the *tree* accepts the puppet's hit is the biggest unknown for step 2 (section 2.3). HIGH for the asset names, MED for "it works".
4. **A server-side fallback with no args exists.** `AFellableTree:ForceSplitIntoLogAndStump()` (BlueprintAuthorityOnly, no parameters) fells a tree directly. HIGH for the signature, LOW for exactly what it spawns.
5. **Felling is a chain of three actor types:** standing `AFellableTree` -> stump (same actor, `bIsStump`) plus a toppling `AFelledTree` -> `ASplittableTreeLog` / `ATreeLog` trunk pieces -> `ARuntimeSpawnedWorldItem` log stacks on the ground. The log pieces are what the player chops with the overhead chop. MED: the type names and fields are HIGH, the exact hand-over between them is inferred.
6. **Logs are not in the tree's own drop list.** The server log line `DropItems() : No ItemDataClass specified; no items will be dropped` (DISC "Observed in the server log") fits a standing tree whose own `ItemDropOnDestructionComponent` is empty; the logs come from the `ATreeLog` pieces (they carry `PrimaryAssociatedItemData`). MED.
7. **Oak log item:** `/Game/Gameplay/Items/Resources/Wood/ITEM_Resources_Wood_Oak.ITEM_Resources_Wood_Oak` (class `FuelItemData`, O:195768). Stack size 99 and weight 1.5 per the wiki; read the live `MaxStackSize` before trusting it. **4 stacks = 396 logs = about 15 oak trees** (the wiki says a whole oak with its stump yields 28). HIGH for the path, MED for 99/28.
8. **Pickup by the puppet cannot use the game's path** (`HandleInteraction(ADominionPlayerCharacter*)` grants into a controller inventory the puppet does not have). Use "read the world item, destroy it, add to a bot-side store". The puppet pawn has an `ItemMagnet` component, which is a crash risk to check first (section 4.3). MED.
9. **Delivery:** `UItemHelperLibrary:SpawnAndLaunchItem_Sync(world, FItemSpawnParameters, &reason)` builds a normal `ARuntimeSpawnedWorldItem` with a count. It is the safest shape for clients because the game builds all state itself. Its argument is a large struct, and a struct-marshalling crash is on record (DISC "Damage-call crash"), so test it offline first. HIGH for the signature, LOW for safety.
10. **Spells:** "Astral Projection" is spelled **Axtral Projection** in the game and wiki, and it is not a scouting spell. It throws an axe that fells standing trees in a line. Trunk Totem is `PileEmUp` internally. None of the three can be cast normally by the puppet (rune costs and "axe in inventory" checks need a controller inventory). Section 7 gives the emulation route.

---

## 1. Trees

### 1.1 Classes and how to tell oak from other species

| Class | Role | Ref | Conf |
|---|---|---|---|
| `AWorldActor` -> `ADestructibleWorldActor` | base of everything destructible. Has `HealthComponent` (`UWorldActorHealthComponent`), `DamageComponent` (`UWorldActorDamageComponent`), `ItemDropOnDestructionComponent` (`UItemDropComponent`), `bDestroyActorOnZeroHealth`, `bDestroyActorIsPending`, `bIsHidden` | DOM:9303 | HIGH |
| **`AFellableTree`** | the standing tree *and* its stump (one actor) | DOM:10705, UHT:FellableTree.h | HIGH |
| `ABP_FellableTree_Base_C` | adds leaf VFX, `GetTrampleDamage()` (falling-tree damage), `MakeTrunkVisuallyShake()` | BP:BP_FellableTree_Base | HIGH |
| **`ABP_FellableTree_Oak_C`** | species class. Path `/Game/Gameplay/World/Trees/Oak/BP_FellableTree_Oak.BP_FellableTree_Oak_C` | O:240639 | HIGH |
| Oak leaves | `BP_Tree_Oak_01/02`, `BP_FH_Tree_Oak_01/02`, `BP_BM_Tree_Oak_01/02` (all `/Game/Gameplay/World/Trees/<name>`), each `: ABP_FellableTree_Oak_C` with no extra members | BP:BP_Tree_Oak_01, BP:BP_FH_Tree_Oak_01, BP:BP_BM_Tree_Oak_01; O:240790-240870 | HIGH |
| Other species | `BP_FellableTree_Ash` (Ash **and Yew `BP_YewTree_01..03` and Maple `BP_DR_Tree_Maple_01/02` inherit from it**), `BP_FellableTree_Willow`, `BP_FellableTree_MagicTree` | BP:BP_YewTree_01, BP:BP_DR_Tree_Maple_01, BP:BP_FellableTree_MagicTree | HIGH |
| Saplings | `ABP_Sapling_*_C : ASaplingBase`, **not** `AFellableTree`. Farmed trees, exclude them | BP:BP_Sapling_Oak_01 | HIGH |
| `AFelledTree` | the toppling trunk plus canopy after a split | DOM:10735 | HIGH |
| `ATreeLog`, `ASplittableTreeLog` | trunk pieces you chop into logs | DOM:12535, DOM:12339 | HIGH |
| `APileEmUpTotem` (BP `ABP_PileEmUp_Totem_C`) | the Trunk Totem spell's actor | DOM:11646, BP:BP_PileEmUp_Totem | HIGH |

**Species test (cheapest first):**
1. `tree:IsA(StaticFindObject("/Game/Gameplay/World/Trees/Oak/BP_FellableTree_Oak.BP_FellableTree_Oak_C"))`, or `FindAllOf("BP_FellableTree_Oak_C")`. The existing code already does `FindAllOf("DominionAICharacter")` across subclasses (DISC E3), so the base-class lookup should return subclasses too. MED.
2. For un-converted foliage: the ISM component's name carries the mesh (`SM_FH_Oak_Tree_01`, `SM_FH_Oak_Tree_02` are the oak meshes; Ash is `SM_FH_Ash_Tree_*`, Willow `SM_Willow_*`; counts in the dump: 6 + 6 oak components, 21 ash, 8 willow, 7 bare ash, O:grep of `BP_InteractableFoliageISMC_Tree_C /Game/Maps`). The component also has `ActorClass: TSubclassOf<AActor>` (the BP the instance converts into) and `FoliageType` (DOM:24510). Reading `ActorClass` is the exact species test. HIGH for the property, MED for naming.
3. Tree data assets also name the species: `/Game/Gameplay/World/Trees/Oak/TD_FH_Oak_01`, `TD_FH_Oak_02`, `TD_BM_Oak_01/02`, `TD_GF_Oak_01/02` (O: `Package /Game/Gameplay/World/Trees/Oak/TD_*`). `AFellableTree.TreeData` is a soft pointer to one of them (DOM:10705).

**Resource type / item drop data on the tree:** there is none on the standing tree itself that names logs.
- `AFellableTree` has `ItemDropOnDestructionComponent` and `ItemDropOnSplitComponent` (both `UItemDropComponent`, DOM:9303, DOM:10705). Their `ItemsToDrop: TArray<FItemDropData>` (DOM:25382, DOM:4094) can be read, but expect them empty (the "No ItemDataClass specified" log line).
- `UTreeData` (DOM:36452) carries the three actor classes (`FelledTreeActorClass`, `SplittableLogActorClass`, `NonSplittableLogActorClass`), the meshes of each log type, the stump and canopy meshes, and `MaxInitialToppleForce`. No item. HIGH.
- The log piece carries the item: `ATreeLog.PrimaryAssociatedItemData: UItemData*` (+ `GetPrimaryAssociatedItemData()`), `TreeDataAndLogType {TreeData, LogType}`, and `BP_TTFS_LogType.MinResourceToDrop/MaxResourceToDrop/MaximumDropGrouping` for the transmute path (DOM:12535, DOM:7780, BP:BP_TTFS_LogType). HIGH for the fields, MED for what values they hold.

### 1.2 Health and state properties

| Question | Property / function | Ref | Conf |
|---|---|---|---|
| Health (tree, stump, log) | `actor.HealthComponent` (`UWorldActorHealthComponent : UHealthComponent`): `MaxHealth`, `AuthoritativeHealth` (floats), `GetAuthoritativeHealth()`, `GetNormalizedHealth()`, `IsDead()`, `SetHealth(Value, Context)`, `DecreaseHealth(Amount, Context)`, `SetHealthReductionBarrier(float)` / `ClearHealthReductionBarrier()` | DOM:23641, DOM:37115 | HIGH |
| Standing vs stump | `AFellableTree.bIsStump` (SaveGame) and `IsStump()`; visible state `EFellableTreeVisibleState {Tree=0, Stump=1, Hidden=2}`; BP event `BP_OnVisibleStateUpdated(State)` | DOM:10705, ENUM:1722 | HIGH |
| Damage needed to fell | `GetDamageRequiredToSplitIntoLogAndStump()` and `SplitDamageFraction` (float) | DOM:10705, UHT:FellableTree.h | HIGH |
| Felled but not yet collapsed | `AFelledTree.CollapseState`: `EFelledTreeCollapseState {None=0, CollapsedNormal=1, CollapsedSkillcape=2}`; also `ToppleTimeout`, `UprightThresholdDegrees`, `MinLinearVelocityToKeepFalling` (the topple is physics driven) | DOM:10735, ENUM:1729 | HIGH |
| Trunk on the ground | `FindAllOf("TreeLog")` / `FindAllOf("SplittableTreeLog")`. Per piece: `GetLogType()` = `ETreeLogType {Whole, ThreeQuartersBottom/Top, HalfBottom/Middle/Top, QuarterBottom/MiddleBottom/MiddleTop/Top}`, `GetMidPointWorldLocation(out)`, `GetLogHeight/GetLogRadius`, `TrunkMeshComponents` | DOM:12535, ENUM:3544 | HIGH |
| Log is being piled (Trunk Totem) | `ATreeLog.bPileThemUpStarted`, `PileThemUp_Started()` | DOM:12535 | HIGH |
| Regrowth | `ResourceRespawnComponent` (`UResourceRespawnComponent`): `ResourcesAvailable`, `GetQuantityAvailable()`, `GetMaxResources()`, `TimeOfLastResourceChange`, `PersistedTimeOfLastResourceChange`, `bIsRespawningPaused`, `RespawnPreventingBuildings`, delegate `OnResourceRespawned` | DOM:32184 | HIGH |
| Regrowth time | wiki Oak Tree: stump regrows the tree after **3 in-game days (72 h)** unless something is built on the node; **cutting the stump stops regrowth**. The general Woodcutting page quotes a 12-minute respawn for ash and oak (conflict, not resolved) | wiki Oak_Tree, Woodcutting | MED |
| Tree actor reverts to foliage | `FoliageDepictableComponent`: `bCanBeConvertedToInstance`, `bFoliageDepictionIsRedundant`, `ActorDepictionTimeout`, `ConvertBackToFoliage()`, `MakeFoliageDepictionRedundant()` | DOM:22949 | HIGH |
| Trample damage while it falls | `ABP_FellableTree_Base_C.GetTrampleDamage()`, `AFelledTree.PhysicsBasedDamageInflictionComponent` | BP:BP_FellableTree_Base, DOM:10735 | MED |

**Gotchas for verification:**
- A converted tree actor can silently go back to being foliage after `ActorDepictionTimeout`. Do not use "actor is still valid" as a signal; use the health, `bIsStump` and the log census. MED.
- `OnHealthChanged` hooks did not fire when Luis's trees fell (DISC "Phase 2 hooks": two trees felled in one adamant-axe hit, no hook). Polling is the only signal. HIGH.

### 1.3 Finding nearby trees cheaply

| Tier | Method | Cost / catch | Conf |
|---|---|---|---|
| A. Foliage census (no conversion) | `FindAllOf("BP_InteractableFoliageISMC_Tree_C")` (48 components were loaded in the dump, `L_World:PersistentLevel.BP_PCG_TileSpawner_C_*.SM_*`). For each: component name (species), `ActorClass`, `GetInstanceCount()`, and `GetInstanceTransform(i, outT, true)` (standard `UInstancedStaticMeshComponent`) for world positions | Components exist per generated tile and mesh, so the list covers only loaded tiles. Counts are small (about 100 components worst case), so a full pass is cheap. The `GetInstanceTransform` out-struct call is untested in UE4SS | MED |
| B. Already-materialised actors | `FindAllOf("BP_FellableTree_Oak_C")`, filter `not IsStump()` and `not HealthComponent:IsDead()` | trivial; only returns trees near players (converted ones) | MED |
| C. Convert foliage near a point and return it | `UInteractableFoliageFunctionLibrary:ConvertFoliageToGetNearbyActorsOfClass(world, oakClass, location, distanceCm, outActors)` (all simple args, one out array), or `ConvertFoliageNearbyLocation(world, location, dist, bConvertDamageable=true, bConvertInteractable=false, requirer)`. `UInteractableFoliageFunctionLibrary` is BlueprintCallable static (UHT:InteractableFoliageFunctionLibrary.h) | The right call to make just before walking to a tree, because the swing needs an actor. Convert only a small radius at a time (each conversion spawns actors) | MED |
| D. Native helper | `IsTreeNearbyLocation` / `GetTreeNearbyLocation(world, TreeClass, Location, Distance, bCountStumps)` in a BP function library (DOM:20936, DOM:20944). `bCountStumps=false` gives live trees. Return types are not shown in the CXX dump | Likely the game's own "is there a tree here" helper (building/farming rules). Worth one read-only call | LOW-MED |

**Does the bot's streaming source matter?** The AI director spawns creatures only around players (DISC "Idle world": 0 AI characters with nobody connected), and world tiles/foliage are streamed. The dump's 48 loaded tree components are for tiles around a connected player. **Assume trees (and nav mesh) exist only near a connected player** until proven otherwise. Consequence: the woodcutter must stay within the loaded area around Luis, or the "no trees nearby" failure fires. Experiment W0 measures how far from a player the census still returns trees. MED.

---

## 2. Chopping by the puppet

### 2.1 Is woodcutting a melee attack with the axe?

Yes, by every available signal. HIGH.
- `UHeldEquipmentData.PrimaryActionClass / SecondaryActionClass / SpecialActionClass` (DOM:23739) hold the axe's actions. Read from the catalogue for **all** `ITEM_Logging_Axe_*` (Stone, Bronze, Iron, Steel, Mithril, Adamant, Rune; CAT):
  - primary: `/Game/Gameplay/Character/Player/Attacks/Axe/PA_Attack_Hatchet.PA_Attack_Hatchet_C`, kind `melee`, name **"Chop"**, damage `[10.0]`, damage class Melee, chain `[BP_Player_Axe_Woodcut1_C]`.
  - special: `PA_Attack_Hatchet_Special_C`, name **"Overhead Chop"**, chain `[BP_Player_Axe_Woodcut2_C]`.
  - secondary: `PA_Block_PickAxe` ("Block").
  - weapon damage type tag: `DamageType.Physical.Slash`; category tag `Item.Equipment.Tool.Hatchet`; filter tag `ItemFilter.Type.Equipment.Tool.LoggingAxe`; durability 1800 (Bronze).
- Both attack classes derive from `UPlayerAttackData` and both actions from `UPA_MeleeAttack_BaseAction_C` (BP:PA_Attack_Hatchet, BP:PA_Attack_Hatchet_Special, BP:BP_Player_Axe_Woodcut1).
- The puppet's proven swing: `p.PlayerMeleeAttackComponent:BP_PerformAttack(attackClass, {Data=actionCDO, PlayerOwner=p, EquipmentHand=1, ActionInputType=0, DesiredActionTarget=target})` (DISC "Combat (E3)", `mod/scripts/puppet_combat.lua` `actions.swing`).

**Per-use rule from the wiki:** use the standard Chop on standing trees and the **Overhead Chop on fallen logs**. The Techniques section says overhead chop does only 1-3 damage to standing trees (wiki Woodcutting; MED). That matches the XP split `HorizontalChopXpEvent` / `VerticalChopXpEvent` on `AFellableTree` and `ATreeLog` (DOM:10705, DOM:12535).

Ready-to-use paths (all from the catalogue/dump):
```
CHOP_ATTACK   /Game/Gameplay/Character/Player/Attacks/Axe/BP_Player_Axe_Woodcut1.BP_Player_Axe_Woodcut1_C
CHOP_ACTION   /Game/Gameplay/Character/Player/Attacks/Axe/PA_Attack_Hatchet.Default__PA_Attack_Hatchet_C       (O:192854)
OVERHEAD_ATK  /Game/Gameplay/Character/Player/Attacks/Axe/BP_Player_Axe_Woodcut2.BP_Player_Axe_Woodcut2_C
OVERHEAD_ACT  /Game/Gameplay/Character/Player/Attacks/Axe/PA_Attack_Hatchet_Special.Default__PA_Attack_Hatchet_Special_C   (O:207987)
```

### 2.2 What damages trees; tool tier requirement

- **Tier gate = a damage modifier on the tree.** `AFellableTree.DamageModifiersWhenTree` and `DamageModifiersWhenStump` (DOM:10705) hold `UDamageModifier` assets. The game ships `BP_DamageModifier_SpecificWeapon_C` assets `DA_HatchetOnly`, `DA_HatchetOnly_Tier3`, `_Tier4`, `_Tier5`, `_Tier6`, `_Tier7`, `_Tier8` (O:233871-233874, 240637, 240993, 264202). The class has `RequiredTier: int32`, `RequiredCategory: FGameplayTag`, `ExceptionSources`, and failure tags/hook (`NoWeaponFailureReasonTag`, `WeakWeaponFailureReasonTag`, `WeakWeaponPlayerHook`) (BP:BP_DamageModifier_SpecificWeapon). Its helper `GetHeldEquipmentThatInflictedDamage(IncomingDamage)` reads the held equipment from the damage's `Instigator`/`Source` (`FHealthComponentIncomingDamageInfo`, DOM:3605). HIGH for existence, MED for which asset each species uses.
- **Tier numbers match the wiki:** Stone 1 (ash), Bronze 3 (oak and ash), Iron 4, Steel 5, Mithril 6, Adamant 7, Rune 8 (wiki Woodcutting). So **oak needs at least a Bronze axe; the Stone axe does nothing** (also: the FTUE hook `PH_FirstHitOakTreeWithStoneAxe` exists, O:grep). MED.
- **Damage type:** the axe's `DamageTypes` is `DamageType.Physical.Slash`; `UWorldActorDamageComponent.DamageTypeMultipliers: TArray<{DamageType tag, multiplier}>` (DOM:37109) can scale by type. Nothing in the dump says "chop" is a separate type; the tier modifier is the gate. MED.
- **Power per hit:** the attack data says `[10.0]` for all tiers; the tier effect comes from the equipment (`BaseHeldEquipmentPowerLevelRowHandle`, `DamageMultiplier`, `FHeldEquipmentPowerLevelDataRow Tier1..9`, DOM:23739, DOM:3671). Luis felled two trees in one adamant-axe hit each (DISC "Phase 2 hooks"), so a high-tier axe collapses the chop count. **Recommend Adamant** (Luis's own, `/UmbralSands/Gameplay/Character/Player/Equipment/Held/Hatchet/ITEM_Logging_Axe_Adamant`; its `held_actor_class` is in the CAT). If a base-game-only path is wanted, Steel is the highest `/Game` axe. MED.
- **Equipment the puppet needs:** a Hatchet-category `UHeldEquipmentData` visible to the damage code. The puppet's held weapon is a rendering-only `AHeldEquipmentActor` with `HeldEquipmentData` set and `HeldEquipmentItem` nil (DISC "Route 1: puppet dressed and armed"). Because the modifier reads "the equipment that inflicted the damage", this is exactly where it could fail (MED-LOW). Experiment W3 tests it.

### 2.3 Risks specific to the puppet hitting a tree

| # | Risk | Why | Mitigation |
|---|---|---|---|
| R1 | XP award path dereferences the instigator's controller | `FelledXpEvent`, `HorizontalChopXpEvent`, `DamageXPEvent`, `bAwardsXPThroughPlayerDamageComponent` (DOM:10705, DOM:18376) feed the *player's* progress component. The puppet has no PlayerController. The unpossess crash was exactly an un-null-checked controller field (DISC "Unpossess crash") | First test with nobody connected and the watchdog running. If it crashes, pass Luis as the damage credit (`credit="luis"` exists in `puppet_combat.hit`) or use the no-arg fallback (2.4). |
| R2 | Weak-weapon failure path calls a `UPlayerHook` on a null controller | `WeakWeaponPlayerHook` (BP:BP_DamageModifier_SpecificWeapon) | Equip an axe of sufficient tier so the failure branch never runs. |
| R3 | Falling tree damages the puppet | `GetTrampleDamage`, `PhysicsBasedDamageInflictionComponent` on `AFelledTree` | Stand beside the trunk line, keep `HealthComponent:SetIsImmortal(true, puppet)` (verified in E3), and after the first hit step back 3 m. |
| R4 | Stamina | `GE_Woodcutting_StaminaCost` exists; `UPlayerAttackData.StaminaCost` (DOM:29344). Unknown for a puppet with no stamina component state | Verify by swing count vs health drop; treat "swing started but no damage" as a distinct failure (section 6). |
| R5 | Facing | The melee trace uses the puppet's forward and `DesiredActionTarget`; `TraceObjectTypes` limits what it can hit (DOM:30176) | Face the tree (`K2_SetActorRotation` or `SetControlRotation`) at 1.5-2.5 m before each swing; pass the tree as `DesiredActionTarget`. |
| R6 | The swing may not convert foliage | Players presumably call `ConvertTracedFoliage` from their own attack processing; unknown for `BP_PerformAttack` | Convert explicitly first (1.3 tier C). |

### 2.4 Server-side route if the swing does not damage trees

All of these are simple-argument calls on actors the census gave us. None were run. Ranked:
1. **`tree:ForceSplitIntoLogAndStump()`** (UHT: `BlueprintAuthorityOnly, BlueprintCallable`, no args; DOM:10705). Result presumably equals a normal fell (stump stays, felled tree spawns). HIGH for the signature, LOW for the content. No XP credit goes to anyone, which also avoids R1.
2. **`tree.HealthComponent:DecreaseHealth(amount, "bot")`** with `amount = GetDamageRequiredToSplitIntoLogAndStump()` or `AuthoritativeHealth` (all floats and FString). This should run the same `OnHealthChanged` -> split logic as a hit. The hook list shows this path is native, so the effect, not the call, is what to check. MED.
3. **`tree.HealthComponent:SetHealth(0, "bot")`**. Cruder; may skip the split and destroy the actor. LOW.
4. `ForceReduceToStump()` (UHT: BlueprintCallable) is for the second stage (tree -> stump), not for logs. LOW.
Not recommended: `DamageComponent:PredictDamage` / `ApplyDamageFromGameplayEffect`. The marshalling of `TArray<FTypeDamage>` crashed the server (DISC "Damage-call crash").

---

## 3. Felled tree to logs

### 3.1 Which actor appears and how it is chopped into items (MED; structure HIGH, hand-over inferred)

1. The standing `AFellableTree` takes damage until its health crosses the split threshold (`SplitDamageFraction`, `GetDamageRequiredToSplitIntoLogAndStump`). `Multicast_InstantaneousSplit` plays the split FX (DOM:10705).
2. The same actor becomes a **stump** (`bIsStump = true`, `EFellableTreeVisibleState::Stump`, `DamageModifiersWhenStump` now apply, `StumpStaticMeshComponent` shown). A `UTreeData.FelledTreeActorClass` actor (`AFelledTree`) is spawned and topples under physics (`CollapseState` `None` -> `CollapsedNormal`; `OnCanopyCollapsed` fires; `LifeSpanAfterCanopyCollapse` bounds the canopy's life). DOM:36452, DOM:10735.
3. The trunk becomes `UTreeData.SplittableLogActorClass` (`ASplittableTreeLog`, log type `Whole`); the non-splittable class `NonSplittableLogActorClass` (`ATreeLog`) is the leaf piece. DOM:36452. LOW-MED: whether `AFelledTree` is *replaced* by the log or *is* the log is not settled by names.
4. Chopping (overhead chop) a `Whole` log splits it into 3/4 + 1/4, halves or quarters (`ETreeLogType`; `Multicast_InstantaneousSplit(SplitLocation)`, `SetShouldSpawnLogsOnSplit(bool)`), and the smallest pieces are destroyed into items. `SetShouldSpawnLogsOnSplit` suggests logs may spawn at *each* split, not only at the end. DOM:12339. LOW-MED.
5. Each destruction runs the actor's `ItemDropOnDestructionComponent:DropItems(instigator)` (BlueprintCallable, UHT:ItemDropComponent.h) and spawns **log world items** (next section). The oak log asset is `PrimaryAssociatedItemData`.
6. With the Woodcutting skillcape a small chance finishes a tree instantly (`CollapsedSkillcape`, `bHideVisualForSkillcapeDamage`; wiki cape page). Ignore.
7. The stump is chopped too (it takes part of the 28-log total per the wiki: "28 oak logs in total upon chopping the entire tree and the stump"). Chopping the stump **ends regrowth** (wiki Oak Tree). Policy decision: leave stumps for a few logs less, or take them for speed. MED.

**Yield facts (wiki):** one whole oak plus stump = 28 oak logs, always (bird nests 25%, oak seeds 5% as side drops). Splinter yields 2-3 fewer logs than manual splitting; Trunk Totem gives less total XP. HIGH that these are the wiki's words, MED that they match build 26161880.

### 3.2 The drop spawning path: `DropItems`, `ItemDataClass`, `RuntimeSpawnedWorldItem`

- `UItemDropComponent` (DOM:25382): `ItemActorClass` (world-item class to spawn), `ItemsToDrop: TArray<FItemDropData>`, `LaunchSpeed`, `LaunchAngleVariance`, `ItemSpawnPositionalVariance`, `WorldLocationOffset`, `bLaunchFromCenterOfParent`, `bSkipFloorSafetyCheck`, `bAlwaysLaunchUpwards`. Functions: `DropItems(Instigator)`, `DropItemsOfClass`, `DropItemsFromConfig`, `ReplaceItemsToDrop`, `AddItemsToDrop`, `ResetItemsToDrop`, `GetItemsToDrop`. HIGH.
- `FItemDropData` (DOM:4094): `ItemDataClass` (**soft** pointer to `UItemData`), `MinToDrop`, `MaxToDrop`, `MaximumGrouping` (how many items per world item), `ProbabilityOfDrop`, `RequiredTagQuery`, `ProbabilityModifierAttribute`, `ExtraDropPercentageForPlayerAmount`. A lone `ItemDataClass` that is empty is what logs `No ItemDataClass specified; no items will be dropped`. HIGH.
- Each drop goes through `UItemHelperLibrary:SpawnAndLaunchItem(WorldContext, FItemSpawnParameters)` (DOM:25422), which returns nothing; `SpawnAndLaunchItem_Sync(...)` returns the `AWorldItem*` and an `OutFailureReason` string. HIGH.
- The world item is `ARuntimeSpawnedWorldItem : AWorldItem` (DOM:12114). BP classes: `BP_RuntimeSpawnedWorldItem_C`, `_NoExpiry_C`, `_NoDelayForMagnet_C`, `_ProcessingStation_C` under `/Game/Gameplay/WorldItems/` (O:170595, 170617, 228913, 229452). HIGH.
- **Grouping:** a tree's 28 logs therefore arrive as several world items of 1..`MaximumGrouping` logs each, launched with spread. Expect about 10-30 `ARuntimeSpawnedWorldItem` per tree. LOW-MED; W1 measures it.

### 3.3 The oak log item data

| Fact | Value | Source | Conf |
|---|---|---|---|
| Asset path | `/Game/Gameplay/Items/Resources/Wood/ITEM_Resources_Wood_Oak.ITEM_Resources_Wood_Oak` | O:195768 | HIGH |
| Class | `FuelItemData` (a `UItemData` subclass; logs are also fuel) | O:195768 | HIGH |
| Max stack size property | `UItemData.MaxStackSize: int32` (`item:GetMaxStackSize()`) | DOM:25279 | HIGH |
| Max stack size value | **99** (raised from 50 in 0.8.0) | wiki Oak_Logs, gamever.io | MED (read it live) |
| Weight | 1.5 each (`UItemData.Weight`, `GetRawWeight()`) | wiki | MED |
| Display name | `UItemData.Name: FText`; wiki "Oak Logs" (`item:GetName()` or `item.Name:ToString()`) | DOM:25279, wiki | MED |
| Related | planks `/Game/Gameplay/Items/Resources/Wood/ITEM_Resources_Plank_Oak` (O:223375) | | HIGH |
| Not in the catalogue | `CAT` holds equipment only (466 items, no resources), so stack size has to be read live in the first experiment | `data/items_26161880.json` | HIGH |

**Goal arithmetic (MED):** 4 stacks = 4 x `MaxStackSize` = 396 logs (if 99). At 28 per oak (tree + stump) that is 14.1, so **15 trees**; with Splinter's 2-3 fewer per tree, 16. The goal check is `store.oak_logs >= 4 * MaxStackSize` with `MaxStackSize` read from the item asset, never hard-coded.

---

## 4. Picking up

### 4.1 `ARuntimeSpawnedWorldItem` fields (HIGH)

- `AWorldItem` (DOM:12734): `ItemData: UItemData*` (`OnRep_ItemData`), `MagneticComponentGrantItem: UMagneticComponent_GrantItem*`, `LaunchableComponent`, `ItemMesh`, `bCanExpire`, `ExpirationLifetimeInGameDuration`, `ExpirationTimeInGameEndTicks`, `SpawnHeightOffset`, dropper identifiers (`OwnerGuidOfUserThatDroppedItem`, `GuidOfPlayerCharacterThatDroppedItem`, `NameOfPlayerCharacterThatDroppedItem`), `bCacheInWorldItemRuntimeCache`.
  - Functions (UHT:WorldItem.h): `GetStackSize()` (BlueprintCallable, pure), `RemoveFromStack(NumToRemove)` returns int, `GetMagneticComponent()`, `IsBeingManipulated()`, `SetBeingManipulated(obj, bool)`.
- **Stack count:** `item.MagneticComponentGrantItem.SpawnedItem: UItem*`; `UItem.Count` (DOM:25230) and `GetStackSize()`. `MagneticComponentGrantItem.ItemData` also holds the data (DOM:26700). The count lives on the `UItem`, not on the world item.
- `ARuntimeSpawnedWorldItem` (DOM:12114): `InteractionComponent`, `InteractionCollision`, `NetCullDistanceBand`, `bExpireEvenIfDroppedAndNoAutoMagnetize`.
- Census recipe: `for _, w in ipairs(FindAllOf("RuntimeSpawnedWorldItem") or {})` -> `w.ItemData:GetFullName()` (compare to the oak path), `w:GetStackSize()`, `w:K2_GetActorLocation()`. `FindAllOf("WorldItem")` was the recipe already proposed in the humanoid note (section C). HIGH for the fields, MED for the recipe.

### 4.2 How the game moves it into a player's inventory

- Player E-press: `PlayerInteractionManager:Server_RequestInteraction(...)` -> the item's `InteractionComponent.OnInteractionEvent` -> `ARuntimeSpawnedWorldItem:HandleInteraction(ADominionPlayerCharacter*)` (DOM:12114; verified chain for a stick pickup, DISC "Phase 2 hooks" items 1-4). That call grants into the interactee's controller inventory. HIGH.
- Magnet path: `UMagneticComponent:BP_MagnetizeToPlayer(Player, bIgnoreMinTimeBeforeMoving)` and `DelayedMagnetizeToPlayer(Player, DelayTime, bIgnoreEncumbrance, bIgnoreMinTimeBeforeMoving)` (DOM:26685). The item flies to the player and is granted on contact (`ContactRange`). `UMagneticComponent_GrantItem` has `bAllowAutoMagnetization`, `AutoMagnetizationCategory` (`EItemAutoMagnetizeCategory {None, Generic, ProcessingStationOutput}`), `bMagnetizeWithFullInventory`, `bHasBeenGranted` (DOM:26700, ENUM:2092). The player preference is `DominionPlayerController:Server_AutoMagnetizeItems(bitflags)` (DOM:10278). HIGH.
- The `BP_RuntimeSpawnedWorldItem_NoDelayForMagnet_C` variant (O:228913) skips the `MinTimeBeforeMoving` delay, so it magnetises instantly. MED.

### 4.3 Can the puppet pick up, and the bot-side-store alternative

- **`HandleInteraction(puppet)` / `BP_MagnetizeToPlayer(puppet)` will most likely fail or crash.** The puppet is an `ADominionPlayerCharacter` but has no controller inventory (humanoid note section C: "most likely fail or no-op; a crash is possible"). Do not call it. MED.
- **Recommended pickup = bot-side store:**
  1. Walk the puppet to within about 150 cm of the world item (`MoveToActor`).
  2. Read `ItemData` and `GetStackSize()`; accept only items whose `ItemData` is the oak asset.
  3. `w:K2_DestroyActor()` (or `w:RemoveFromStack(n)` for a partial take; a stack that reaches 0 is presumably removed).
  4. Add `n` to the store **in the same tick**, and write the store to disk with an atomic rename before the next tick. If the process dies between destroy and write the logs are lost; if the order is reversed they duplicate. Prefer losing over duplicating (an exploitable duplicate is worse for Luis's economy).
  5. Verify: the actor is invalid or garbage-flagged (use `HasAnyInternalFlags(0x200000)` like the zombie-puppet check, DISC "Zombie actors"), the store grew by exactly `n`.
- Risks: (a) `bCacheInWorldItemRuntimeCache` registers world items in a runtime cache for persistence; destroying the actor should remove it through `EndPlay`, but that was not checked (MED); (b) a player's `ItemMagnet` may snatch the log first (see below).
- **Crash risk to check before any drop happens near the puppet:** `BP_PlayerCharacter_C` has `BP_Components_ItemMagnet` (`UItemMagnet.MagnetRange`, DOM:9903, DOM:25442, BP:BP_PlayerCharacter:67). If the world's `UItemMagnetizationSubsystem` (DOM:25448) treats the puppet as a player, a log landing within `MagnetRange` would be magnetised to the puppet and granted into a null controller inventory. The puppet has already stood near Kebbit loot without a recorded crash (unconfirmed that loot dropped), so this may be inert. Read `puppet.BP_Components_ItemMagnet.MagnetRange` in W0 and, if non-zero, set it to 0 or deactivate the component before the first fell. MED-LOW.
- **If Luis is near the trees**, his own magnet or auto-magnetise preference will pull the logs to him first (a feature for co-op, a surprise for the store count). Treat the store as authoritative only for logs the puppet itself destroyed.
- Decay: `bCanExpire` + `ExpirationLifetimeInGameDuration` means dropped logs can despawn. The loop must pick up within seconds of a fell, and the delivery drop should use the `_NoExpiry` class (next section).

### 4.4 Magnetise for delivery

`item.MagneticComponentGrantItem:BP_MagnetizeToPlayer(luisPawn, true)` flies the item into Luis's real inventory, but it is blocked by encumbrance (parameter `bIgnoreEncumbrance` exists only on `DelayedMagnetizeToPlayer`), and 396 logs at 1.5 each is about 594 kg, far more than a normal carry capacity. Ground drops that he collects at his own pace are the better delivery. MED.

---

## 5. Dropping and delivering

### 5.1 Spawning a world item with given item data and count (HIGH for signatures)

`UItemHelperLibrary:SpawnAndLaunchItem_Sync(WorldContextObject, FItemSpawnParameters ItemParameter, FString& OutFailureReason) -> AWorldItem*` (UHT:ItemHelperLibrary.h, BlueprintCallable static; DOM:25422). The struct (DOM:4111, UHT:ItemSpawnParameters.h) and the values to use:

| Field | Value for the delivery drop | Why |
|---|---|---|
| `ItemClass` | `/Game/Gameplay/WorldItems/BP_RuntimeSpawnedWorldItem_NoExpiry.BP_RuntimeSpawnedWorldItem_NoExpiry_C` | does not despawn while Luis walks over (O:170617) |
| `bCreateItem` | `true` | the world item creates its own `UItem` from `SpawnedItemData` + `Count` |
| `SpawnedItemData` | the oak `UItemData` (3.3) | |
| `Count` | up to `MaxStackSize` (99), 4 separate drops | stays a legal stack |
| `CopiedItem` | `nil` | |
| `Transform` | translation = Luis's location + 1 m toward the bot, rotation identity, scale 1 | drop "at his feet" without clipping into him |
| `LaunchDirection` / `LaunchSpeed` / `LaunchAngleVariance` | `{0,0,0}` / `0` / `0` | no flinging; if the helper rejects zero, use a tiny upward speed (about 100) |
| `bSkipFloorSafetyCheck` | `false` | lets the game place it on the floor |
| `OwnerController`, `PlayerControllerThatDroppedItem` | `nil` | no player owns it; the dropper-name fields stay empty |
| `bSpawnOnlyForController` | **`false`** | `true` would spawn a client-only (non-replicated) item |
| `bAddToWorldItemRuntimeCache` | `true` | normal persistence for a player-visible drop |
| `bMagnetize`, `bMagnetizeToInstigatorOnSpawn` | `false` | Luis picks it up himself |

If the call returns `nil` read `OutFailureReason`; it exists to tell us why. The FItemSpawnParameters has `FTransform` (double precision), `FVector`, two object pointers and 5 bools. **UE4SS struct marshalling of a table into this is the same kind of operation that crashed the server for `TArray<FTypeDamage>` (DISC).** Rules: first run offline; build all fields explicitly (including defaults); never pass a partial table. LOW for safety, HIGH for design.

### 5.2 Properties that matter for a correct client view

- `AWorldItem.ItemData` (replicated, `OnRep_ItemData`) and `MagneticComponentGrantItem.SpawnedItem` (replicated `UItem*`, `OnRep_SpawnedItem`) must both be set consistently. With `bCreateItem` the game does this itself. HIGH.
- `AWorldActor.bRegisterAsRuntimeSpawned` and `bCacheInWorldItemRuntimeCache` keep the item in the save/runtime cache. MED.
- `NetCullDistanceBand` on `ARuntimeSpawnedWorldItem` decides how far away a client sees it; irrelevant at Luis's feet. MED.

### 5.3 Safest shape and the alternatives (recommendation)

| Rank | Route | Client risk | Notes |
|---|---|---|---|
| 1 | `SpawnAndLaunchItem_Sync` as in 5.1, Count = 99, 4 times, offline test first | lowest: the game constructs the object and its replicated state | struct-marshal crash risk is on our side of the call |
| 2 | `ItemDropComponent`-based: spawn a harmless actor, set `ItemsToDrop` via `ReplaceItemsToDrop`, call `DropItems(luis)` | low | needs an `FItemDropData` array with a soft pointer and a tag query: worse marshalling than option 1 |
| 3 | `luisPC.InventoryController` / `PersonalInventory:AddItemByData(oakData, 99, ...)` straight into Luis's inventory (`AddItemByData(ItemData, Count, DurabilityPercentage, GameplayTags)`, DOM:24736; `CanAddItemByData` first, DOM:24728) | low (it is the normal server path), but it hits his weight/space limits and is not a drop at his feet | acceptable fallback for a small count; also used by the "give" skill |
| 4 | Hand-built actor: `SpawnActor(BP_RuntimeSpawnedWorldItem_NoExpiry_C, loc)` then set `ItemData` and construct a `UItem` for `SpawnedItem` | **highest**: a half-initialised replicated `UItem` is exactly the "malformed object sent to clients" case (cf. DISC "Client freeze from injected chat RPCs") | do not use |
| 5 | Teleport the real dropped world items to Luis's feet with `K2_SetActorLocation` (no store at all) | low | the stacks stay small (several per tree), so Luis gets dozens of piles, not 4 clean stacks; fine for a prototype |

**Recommendation:** route 1, falling back to route 3 for what does not fit. Test order in W6.

---

## 6. The behaviour: state machine, verification, failures, LLM versus code

### 6.1 Placement

- **Planner (strong model, rare):** turns "chop trees until you have 4 stacks of oak logs, then drop them at my feet" into two tasks, `gather(oak_logs, 4 stacks)` and `give(luis, oak_logs, count)` (these already exist in `brain/interface.py`; `gather(resource, count)` and `give(player, item, count)`). Replans on a failure *reason* (below).
- **Controller (fast model, event driven):** chat, "stop", "come here", status lines ("14 of 15 trees done"), one voice.
- **Executor (Python, deterministic):** runs the two tasks, verifies with fresh state: `state["inventory"]["oak_logs"]` from the bot store (the executor's `_COUNTED` table already treats gather/give as inventory deltas, `brain/executor.py`), retries a hard-capped number of times, hands reasons back to the planner.
- **Body (Lua, game-thread, no LLM):** one long-running async skill `gather{resource="oak_logs", count=N}` that owns the whole inner loop below and emits `progress` events, `task_done` / `task_failed(reason)`. The loop is a state machine ticked on the game thread, exactly the pattern of `mod/body/skills.lua` (one current action, preempted by a new action, never blocking).
- The LLM never touches the inner loop. It sets parameters (`count`, species, `radius_m`, `chop_stumps`) and handles `task_failed`.

### 6.2 Inner state machine (body)

```
START      equip axe (tier >= 3) if not held; set immortal; read MaxStackSize; goal = N
           verify: held item's category is Hatchet
SCAN       census (1.3 A+B) -> candidate oaks (not stump, not dead), sorted by path distance
           none within radius -> widen radius x1.5 up to R_max; at R_max -> FAIL no_trees
           verify: >= 1 candidate
APPROACH   convert foliage near target (1.3 C); MoveToLocation to a stand point 2 m from the trunk
           arrive tolerance 1 m, timeout T_walk (path blocked -> mark tree bad, SCAN)
           verify: distance to trunk < 3 m
CHOP_TREE  face tree, BP_PerformAttack(Chop) every swing_interval; poll health each tick
           until tree is stump or health unchanged for K swings
           verify: tree.IsStump() or FelledTree/TreeLog actors appear near the tree
           K swings with no health change -> try fallback ForceSplit (2.4) once, else mark tree bad
STEP_BACK  move 3 m off the fall line; wait for CollapseState != None (timeout T_fall)
CHOP_LOGS  for each TreeLog within 8 m (largest first): approach, Overhead Chop until it is gone
           verify: log actor invalid and WorldItems of oak appear near it
COLLECT    for each oak RuntimeSpawnedWorldItem within 10 m: approach, destroy, add to store
           verify: store += stack; the world item is gone; repeat until none left for 3 s
           (also sweep once more after the stump, which is optional per chop_stumps)
CHECK      store.oak_logs >= goal ? -> DONE : goto SCAN
DONE       emit task_done{count=store.oak_logs, trees=n, seconds=t}
```

Delivery is a **second task**, not a state in this one (principle 8 and the planner owns task boundaries):

```
GIVE       go_to(luis) within 3 m (follow already does this)
           k = floor(have / MaxStackSize) stacks; SpawnAndLaunchItem_Sync(count=MaxStackSize) x k at his feet
           store -= MaxStackSize per success (only after the call returned an AWorldItem)
           verify: the new world items exist within 3 m of Luis, ItemData == oak, GetStackSize == 99;
                   then ask Luis a yes/no ("do you see 4 stacks of logs at your feet?")
           failure -> route 3 (AddItemByData) for the remainder, else task_failed(drop_failed)
```

### 6.3 Failure modes and what happens

| Failure | Detection | Handling | Reason code to the planner |
|---|---|---|---|
| No oak trees in range | SCAN returns 0 after widening to R_max; or the census is empty because tiles are not loaded around the bot | stop, say so, ask Luis where trees are; planner may `go_to(notes.oak_forest)` and retry | `no_trees_in_range` |
| Path blocked / stuck | no progress toward the stand point for T_walk; `MoveToLocation` result != `RequestSuccessful` | mark that tree bad for 10 min, pick the next; after 3 bad trees ask for help | `path_blocked` |
| Axe too weak / missing | swings produce no health change (R2), or the equip check fails | equip the best axe; if tier < 3, fail early (no point swinging) | `axe_tier_too_low` / `no_axe` |
| Swing does nothing | health unchanged for K swings (R4/R5) | face and re-approach once; then fallback 2.4; then mark tree bad | `swing_no_effect` |
| Tree vanished (reverted to foliage) | `IsValid` false mid-chop | re-convert at the same position; if the instance is gone, count it as done | none (self-heal) |
| Logs not found after fell | no oak WorldItem within 10 m after T_wait | widen the sweep to 20 m once (items are launched), then continue; the discrepancy is logged (W1 gives the expected number per tree) | none (log only) |
| Item magnetised away / taken by Luis | oak WorldItem disappears while the puppet is 5+ m away | do not count; log `stolen_by=player` | none |
| Bot inventory ("full") | the store has no cap; the **user-visible** cap is weight (594 kg) | not a failure of the loop; delivery handles it. If a cap is added later: stop at cap and deliver first | `store_full` (future) |
| Danger | attacked (`attacked` event) | the combat reflex pre-empts; resume the chop state afterwards. Falling-tree damage is covered by immortality | `interrupted` |
| Goal changes | Luis says "stop" / "come" | preempt (existing mechanism); keep store and progress in the state file | `interrupted` |
| Crash / restart | server watchdog restart | the store file and `progress.json` (trees done, bad trees) survive; the planner resumes the task | n/a |

### 6.4 Verified-state rules for this task

- "Logs gathered" = bot store (changed only where a world item was actually destroyed), cross-checked against the expected per-tree yield; a large mismatch is logged, not hidden.
- "Tree felled" = `IsStump()` or a `FelledTree` / `TreeLog` near its position, never "swing returned".
- "Dropped" = the world item exists at Luis's feet with the right item and count, then one yes/no to Luis.
- Every state transition and each census goes to `logs/` as JSONL (CLAUDE.md section 8) so the first runs can be replayed.

---

## 7. Spells that fit the loop (Luis's addition)

Casting mechanics are with the spells agent (`docs/research/2026-10-25-spells-and-weaknesses.md`). This section only covers woodcutting usage. Names: the game files and wiki say **"Axtral Projection"** (Luis wrote Astral).

| Spell | Internal assets | Wiki facts | Role in the loop |
|---|---|---|---|
| **Axtral Projection** | `USD_AxtralProjection` (`/Game/Gameplay/UtilityMagic/PerkSpells/AxtralProjection/`, O:250817): modules Cast, 3 x Collision, CostItems, 3 x DamageByEquipment, 3 x DestroyActor, 2 x ExpireAfterDistance. Actor `BP_Spell_AxtralProjection_C` (a spinning axe, `EvaluateIfSpellUpgraded`), `BP_AxtralProjection_Projectile_Trail_C`, damage strategy `BP_SDS_AxtralProjectionSpellDamage_C`, destroy rule `SDAS_AxtralProjectionDestroyActorStrategy_C`. Perks `PerkV2_Woodcutting_AxtralProjection` and `..._AxtralProjectionUpgrade` (three axes, level 78) (O:249866, 250233) | level 11; 10 Air + 5 Astral; cooldown 45 s; **30 m line**, fells every standing tree in the line, needs a logging axe *in inventory* (highest tier decides which trees); cannot split logs; monsters in the path take 1-3 damage and aggro; may remove stumps (conflicting 0.12.1 note) | **It is a felling spell, not a scouting spell.** Cast when >= 3 oaks line up inside 30 m. For scouting there is no woodcutting detection spell in the dump (the only "Detect" spell assets are mining: `DetectOre`); use the census (1.3). |
| **Splinter** | `USD_Splinter` (O:249613): Cast, Collision, CostItems, DamageByEquipment, PlayMontage, **Shape (sphere)**, UtilityMagic. Damage strategy `BP_SDS_Splinter_SpellDamage_C::GetDamageAmountForTarget` casts the hit target to `TreeLog` and reads `GetAuthoritativeHealth` (O:246567-246574), i.e. **damage = the log's remaining health, so each log in the sphere is destroyed in one cast**. Perk `PerkV2_Woodcutting_Splinter` | level 27; 10 Earth + 5 Nature; cooldown 45 s; chops fallen trees into logs, many at once; 2-3 fewer logs than manual; 25 XP per quarter; "never affects stumps"; needs a logging axe in inventory; does not use axe durability | Cast after trees have fallen and collapsed, when >= 3 `TreeLog` pieces lie inside the sphere. Replaces the whole CHOP_LOGS state for that cluster. |
| **Trunk Totem** | internal name **PileEmUp**: `USD_PileEmUp` (O:251103: Blueprint, Cast, CostItems, PlayMontage), graph `BP_SMBG_PileEmUp` (`CollectTargetedLogs`, `SpawnTotem`, `ShouldExpire`), actor `BP_PileEmUp_Totem_C : APileEmUpTotem` with `Init(TArray<ATreeLog*>)`, `MaxLogsForFirstSection`, `NumLogsRequiredPerAdditionalSection`, `TreeTypeResourceDropsPerSection`, `HealthPerSection`, `ActiveSectionIndices`, plus perk `PerkV2_Woodcutting_PileEmUp` (DOM:11646, BP:BP_SMBG_PileEmUp) | level 52 (spell table; 50 in the level-up table); 30 Nature + 10 Law; **600 s cooldown**; turns fallen trees into one totem; fewer swings, less total XP; combines with Splinter | Low value for a bot: long cooldown and Law runes. Use only when many logs sit together and swings are the bottleneck. Default off. |

**Can the puppet cast them? Not normally.**
- Spell selection, rune costs and the "axe in inventory" check live on the PlayerController/Inventory (`SpellcastingComponent` on the PC; `SpellModule_CostItems` reads the caster's inventory). The puppet has none (spells doc sections 1.2-1.3).
- The server-side attempt is `DominionRuntimeBlueprintLibrary::TriggerModularAbilityForPlayer(puppet, spellData)` (spells doc X5). Whether the cost and unlock gates run for it is untested.
- **Emulate the effect instead** (all simple args, same state we verify anyway), and keep a virtual cooldown and a virtual rune count in the bot store:
  - Axtral Projection ~ `ForceSplitIntoLogAndStump()` on each standing oak within 30 m of the line from the puppet. Effect state: `bIsStump` true, `FelledTree` actors appear, 45 s virtual cooldown.
  - Splinter ~ for each `TreeLog` in a sphere around the puppet: `log.HealthComponent:SetHealth(0, "splinter")`, or `DecreaseHealth(AuthoritativeHealth, ...)`, which is the same quantity the real damage strategy returns. Effect state: the log disappears and oak world items appear; drop 2-3 fewer logs per tree if matching the spell is wanted.
  - Trunk Totem ~ `SpawnActor(BP_PileEmUp_Totem_C)` then `Init(logs)`. Needs an experiment; skip in v1.
- If the real spell does run for the puppet, the effect state to read is the same census plus `PlayerUtilityMagicComponent.LastCastTimeBySpellData[usd]` (character-side, spells doc 1.2).
- Cost-benefit for the Phase 8 gate: Axtral + Splinter cut a tree from several swings and a walk-around to two casts per cluster. The plain-swing loop must work first (it is the fallback when cooldown or runes are missing).

---

## 8. Ranked experiments (all via `debug_run`; propose module `mod/scripts/wood_probe.lua`)

Rules: read-only first; one change per run; the watchdog (`tools/start_watchdog.ps1`) must be running; no client-facing calls without Luis's go-ahead and a warning; log every step to `logs/`. API calls: none (no model needed).

| # | Experiment | Needs Luis? | Risk | Learn |
|---|---|---|---|---|
| **W0** | **Read-only census.** (a) `FindAllOf` counts for `FellableTree`, `BP_FellableTree_Oak_C`, `FelledTree`, `TreeLog`, `SplittableTreeLog`, `PileEmUpTotem`, `RuntimeSpawnedWorldItem`, `BP_InteractableFoliageISMC_Tree_C` (names, `ActorClass`, `GetInstanceCount`, a few `GetInstanceTransform`); time each. (b) Read the oak item: `MaxStackSize`, `Name`, `Weight`, `PowerLevel`, class. (c) Read an oak actor's `HealthComponent.MaxHealth`, `SplitDamageFraction`, `GetDamageRequiredToSplitIntoLogAndStump()`, `ItemDropOnDestructionComponent.ItemsToDrop`, `TreeData`, `ResourceRespawnComponent.GetMaxResources()`. (d) Read `puppet.BP_Components_ItemMagnet.MagnetRange`. (e) Distance test: how far from a connected player trees are still listed | Luis connected, standing somewhere with oaks | none | Sections 1.2, 1.3, 3.3, 4.3; whether trees exist without a player nearby |
| **W1** | **Observe a real fell and chop (zero risk).** A 1 Hz poller logs, to one JSONL, every `FellableTree` / `FelledTree` / `TreeLog` / `RuntimeSpawnedWorldItem` (class, location, health, log type, `CollapseState`, `bIsStump`, `ItemData` path, stack size, `bCanExpire`, expiry ticks) within 25 m of Luis. Ask Luis (one instruction): "Chop one oak tree down with your axe, chop the trunk into logs with the overhead chop, then chop the stump, then walk away and don't pick anything up for 30 s, then pick them up." | yes | none | Section 3 timeline exactly: actor chain, hand-over, number and size of drops, per-tree total (28?), stump yield, expiry, whether logs magnetise to Luis |
| **W2** | **Foliage conversion.** `ConvertFoliageNearbyLocation(world, luisLoc, 1500, true, false, nil)` (or the `...ToGetNearbyActorsOfClass` variant), then the W0 census; compare the ISM instance counts before and after. Expect oak actors to appear and the ISM counts to drop | yes (near trees) | low (spawns actors) | 1.3 tier C works; cost per conversion; revert behaviour |
| **W3** | **Puppet chops a standing oak.** Offline first (nobody connected) if W0(e) says trees exist; otherwise with Luis far away. Arm the puppet with the highest available axe (`puppet_gear`), immortal, `MoveToLocation` to 2 m from a converted oak, face it, one `BP_PerformAttack(CHOP_ATTACK, {Data=CHOP_ACTION,...DesiredActionTarget=tree})`; log health before/after; repeat to 5 swings | no (first run) | **medium**: R1/R2 (null controller in XP or weak-weapon path) | Section 2.1-2.3; whether damage is applied at all |
| **W4** | **Puppet fallbacks.** Offline, one oak each: `ForceSplitIntoLogAndStump()`; then a second oak: `HealthComponent:DecreaseHealth(required, "bot")`. Compare with W1 | no | low-medium | Section 2.4; the tree -> log chain without swings |
| **W5** | **Puppet overhead chop on a log** left by W1/W4: `OVERHEAD_ATK` + `OVERHEAD_ACT`, `DesiredActionTarget=log`; watch the log health and the world-item output | no | medium (same as W3) | 3.1 step 4, whether the puppet can split logs |
| **W6** | **Pickup emulation.** With the puppet immortal and its magnet component neutralised: `w:GetStackSize()`, `w.ItemData` check, `w:K2_DestroyActor()` on one log item (then one stack); verify the actor goes invalid and no crash. Separate step: with Luis connected, ask him to drop a stack beside the puppet and watch whether the log flies to the puppet (read-only) | step 2 yes | medium (magnet) | Section 4.3 |
| **W7** | **Drop at his feet.** (i) offline: `SpawnAndLaunchItem_Sync` with `Count=1`, `NoExpiry` class, 5 m from nobody; check the returned object, `GetStackSize()`, `OutFailureReason`; destroy it. (ii) Luis connected, warned: drop 1 log 3 m from him, ask "do you see one oak log on the floor you can pick up?" (iii) the same with `Count=99`, then 4 stacks. Pass criteria: Luis picks it up and `GetNumItemsByData(oak)` on his inventory rose by exactly the count | (ii), (iii) yes | struct marshalling crash (offline), client-visible object (online) | Section 5 |
| **W8** | **Full-loop dry run** with the real skill on 2 trees, target 50 logs, with a deliberate failure (set the radius to 5 m in an empty area -> `no_trees_in_range`) to check the planner replans or asks for help (Phase 8 gate shape) | yes, briefly | medium | Section 6 |
| **W9** | **Spells on the puppet** (after W3): `TriggerModularAbilityForPlayer(puppet, USD_Splinter)` with logs near it, then `USD_AxtralProjection`; if no effect, test the emulations of section 7. Coordinate with the spells agent's X5 | no | medium-high | Section 7 |

**Order rationale:** W0 and W1 first (read-only, answer ~60% of the unknowns with no crash risk), W2 (one benign call), W3-W5 (the crash-risk bundle, run offline with the watchdog), W6-W7 (the pickup and drop pair that the Phase 8 gate needs), W8 only when the pieces pass.

---

## 9. Open questions that only an experiment closes

1. Does `BP_PerformAttack` with the hatchet damage a tree when the instigator is a controller-less puppet (R1, R2)?
2. The exact hand-over felled tree -> log -> world items, the number and size of drops, and the stump's share of the 28 logs.
3. Is the live `MaxStackSize` 99, and do the 4 delivered stacks stay 99 each?
4. Do trees and the nav mesh exist away from a connected player (streaming source)?
5. Is the puppet's `ItemMagnet` inert?
6. Does `SpawnAndLaunchItem_Sync` survive our table-to-struct marshalling?
7. Real regrow time (3 in-game days versus 12 minutes), which decides whether a second pass over the same forest is a plan.

## Sources
- Dump and repo: files listed in the source key; DISC sections "Phase 2 hooks", "Observed in the server log", "Route 1 works", "Route 1: puppet dressed and armed", "Combat (E3)", "Unpossess crash", "Damage-call crash", "Client freeze"; `docs/research/2026-10-25-humanoid-companion-dump.md` section C; `docs/research/2026-10-25-spells-and-weaknesses.md` sections 1.1-1.3; `docs/research/2026-10-25-dump-chat-inventory.md` section 3; `docs/design/robustness-and-item-catalog.md` section 7-8; `mod/scripts/puppet_combat.lua`; `mod/body/skills.lua`; `brain/executor.py`; `brain/interface.py`.
- Wiki (fetched 2026-10-25): [Woodcutting](https://dragonwilds.runescape.wiki/w/Woodcutting), [Oak Tree](https://dragonwilds.runescape.wiki/w/Oak_Tree), [Oak Logs](https://dragonwilds.runescape.wiki/w/Oak_Logs), [Axtral Projection](https://dragonwilds.runescape.wiki/w/Axtral_Projection), [Splinter](https://dragonwilds.runescape.wiki/w/Splinter), [Trunk Totem](https://dragonwilds.runescape.wiki/w/Trunk_Totem), [Woodcutting Cape (Trimmed)](https://dragonwilds.runescape.wiki/w/Woodcutting_Cape_(Trimmed)); [gamever.io logs and planks](https://gamever.io/knowledge-base/logs-and-planks-in-dragonwilds-five-woods-an-axe-ladder-and-a-plank-with-no-use) (stack 99, weight 1.5, secondary). Wiki facts (yields, stack, cooldowns) can change with patches; the in-game values are the truth and are read in W0.
